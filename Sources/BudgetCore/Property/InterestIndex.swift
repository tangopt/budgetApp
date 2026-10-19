import GRDB
import Foundation

/// What a mortgage's rate follows: a Euribor tenor (plus the loan's spread), or a fixed rate.
public enum InterestIndex: String, Codable, CaseIterable, Sendable {
    case euribor1M = "euribor1m"
    case euribor3M = "euribor3m"
    case euribor6M = "euribor6m"
    case euribor12M = "euribor12m"
    /// No index: the terms' fixed rate (`PropertyMortgageTerms.annualRatePercent`).
    case fixed

    /// The Euribor tenors, in order.
    public static let euribors: [InterestIndex] = [.euribor1M, .euribor3M, .euribor6M, .euribor12M]

    /// "Euribor 3M", "Fixed rate".
    public var displayName: String {
        switch self {
        case .euribor1M: return "Euribor 1M"
        case .euribor3M: return "Euribor 3M"
        case .euribor6M: return "Euribor 6M"
        case .euribor12M: return "Euribor 12M"
        case .fixed: return "Fixed rate"
        }
    }

    /// The tenor's code in the ECB's FM dataset (`EURIBOR3MD_`); nil for a fixed rate.
    public var ecbInstrument: String? {
        switch self {
        case .euribor1M: return "EURIBOR1MD_"
        case .euribor3M: return "EURIBOR3MD_"
        case .euribor6M: return "EURIBOR6MD_"
        case .euribor12M: return "EURIBOR1YD_"
        case .fixed: return nil
        }
    }
}

/// How long an index value covers: a month's average (dated the 1st) or one day's fixing.
public enum InterestIndexPeriod: String, Codable, Sendable {
    case month
    case day
}

/// Where an index value came from.
public enum InterestIndexSource: String, Codable, Sendable {
    /// The ECB Data Portal (fetched automatically).
    case ecb
    /// Entered by the user: never replaced by a fetch.
    case manual
}

/// One stored value of an index: a monthly average (dated the month's 1st, UTC) or a daily
/// fixing, in percent a year.
public struct InterestIndexValue: Codable, Equatable, FetchableRecord, MutablePersistableRecord, Sendable {
    public var id: Int64?
    public var index: InterestIndex
    public var period: InterestIndexPeriod
    /// The month's 1st (monthly average) or the day (daily), a UTC midnight.
    public var date: Date
    public var valuePercent: Double
    public var source: InterestIndexSource
    public var fetchedAt: Date?

    public static let databaseTableName = "interestIndexValue"

    enum CodingKeys: String, CodingKey {
        case id
        case index = "indexName"
        case period, date, valuePercent, source, fetchedAt
    }

    public init(id: Int64? = nil, index: InterestIndex, period: InterestIndexPeriod, date: Date, valuePercent: Double,
                source: InterestIndexSource, fetchedAt: Date? = nil) {
        self.id = id
        self.index = index
        self.period = period
        self.date = date
        self.valuePercent = valuePercent
        self.source = source
        self.fetchedAt = fetchedAt
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

public enum InterestIndexError: Error, Equatable {
    /// A fixed rate has no index values.
    case notAnIndex
    /// A value outside −5%…50%.
    case invalidValue
}

/// The stored index values: read, set by hand, and stored from a fetch (which never replaces
/// a manual value).
public enum InterestIndexValues {
    /// The day a value is stored under: the month's 1st for a monthly average, else the day.
    public static func key(_ date: Date, period: InterestIndexPeriod) -> Date {
        switch period {
        case .month:
            let (year, month) = MonthRange.components(of: date)
            return MonthRange.of(year: year, month: month).start
        case .day:
            return PropertyDates.day(date)
        }
    }

    public static func value(db: Database, index: InterestIndex, period: InterestIndexPeriod, date: Date) throws -> InterestIndexValue? {
        try InterestIndexValue.filter(Column("indexName") == index.rawValue && Column("period") == period.rawValue
                                      && Column("date") == key(date, period: period)).fetchOne(db)
    }

    /// Every stored value of the index, oldest first.
    public static func all(db: Database, index: InterestIndex, period: InterestIndexPeriod? = nil) throws -> [InterestIndexValue] {
        var request = InterestIndexValue.filter(Column("indexName") == index.rawValue)
        if let period { request = request.filter(Column("period") == period.rawValue) }
        return try request.order(Column("date")).fetchAll(db)
    }

    /// Stores (replacing whatever is there) a value of the index.
    @discardableResult
    public static func set(db: Database, index: InterestIndex, period: InterestIndexPeriod, date: Date, valuePercent: Double,
                           source: InterestIndexSource, fetchedAt: Date? = nil) throws -> InterestIndexValue {
        guard index != .fixed else { throw InterestIndexError.notAnIndex }
        guard valuePercent.isFinite, (-5...50).contains(valuePercent) else { throw InterestIndexError.invalidValue }
        var row = try value(db: db, index: index, period: period, date: date)
            ?? InterestIndexValue(index: index, period: period, date: key(date, period: period), valuePercent: valuePercent, source: source)
        row.valuePercent = valuePercent
        row.source = source
        row.fetchedAt = fetchedAt.map(EvidenceLinks.wholeSeconds)
        try row.save(db)
        return row
    }

    /// Removes a value; `false` when there was none.
    @discardableResult
    public static func remove(db: Database, index: InterestIndex, period: InterestIndexPeriod, date: Date) throws -> Bool {
        try InterestIndexValue.filter(Column("indexName") == index.rawValue && Column("period") == period.rawValue
                                      && Column("date") == key(date, period: period)).deleteAll(db) > 0
    }

    /// Stores fetched monthly averages: new months added, ECB months whose value changed
    /// updated, manual values left alone. Returns how many rows were added or changed.
    @discardableResult
    public static func storeFetched(db: Database, index: InterestIndex, values: [ECBEuriborFile.Observation], now: Date) throws -> Int {
        var changed = 0
        for observation in values {
            if let existing = try value(db: db, index: index, period: .month, date: observation.month) {
                guard existing.source == .ecb, existing.valuePercent != observation.valuePercent else { continue }
            }
            try set(db: db, index: index, period: .month, date: observation.month, valuePercent: observation.valuePercent,
                    source: .ecb, fetchedAt: now)
            changed += 1
        }
        return changed
    }

    /// The indices the properties' mortgage terms follow (Euribor 3M when none are saved).
    public static func indicesInUse(db: Database) throws -> [InterestIndex] {
        let used = Set(try PropertyMortgageTerms.fetchAll(db).compactMap { $0.rateIndex }.filter { $0 != .fixed })
        let indices = InterestIndex.euribors.filter { used.contains($0) }
        return indices.isEmpty ? [.euribor3M] : indices
    }
}

// MARK: - The ECB's file

/// The ECB Data Portal's Euribor monthly averages (dataset FM, series
/// `M.U2.EUR.RT.MM.<tenor>.HSTA`: "Euribor <tenor> - Historical close, average of observations
/// through period", from Refinitiv), as CSV. The portal publishes no daily Euribor series.
public enum ECBEuriborFile {
    public struct Observation: Equatable, Sendable {
        /// The month's 1st (UTC).
        public var month: Date
        public var valuePercent: Double

        public init(month: Date, valuePercent: Double) {
            self.month = month
            self.valuePercent = valuePercent
        }
    }

    public enum ParseError: Error, Equatable {
        case missingColumns
    }

    /// The monthly-average series of `index` from `startPeriod` ("2010-01").
    public static func monthlyURL(for index: InterestIndex, startPeriod: String) -> URL? {
        guard let instrument = index.ecbInstrument else { return nil }
        return URL(string: "https://data-api.ecb.europa.eu/service/data/FM/M.U2.EUR.RT.MM.\(instrument).HSTA?format=csvdata&detail=dataonly&startPeriod=\(startPeriod)")
    }

    /// The rows with a month (`TIME_PERIOD`, "2026-09") and a value (`OBS_VALUE`), oldest first.
    public static func parse(_ text: String) throws -> [Observation] {
        let lines = text.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard let header = lines.first else { throw ParseError.missingColumns }
        let columns = CSVRowSplitter.split(line: header.trimmingCharacters(in: CharacterSet(charactersIn: "\u{FEFF}")), delimiter: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).uppercased() }
        guard let periodIndex = columns.firstIndex(of: "TIME_PERIOD"), let valueIndex = columns.firstIndex(of: "OBS_VALUE") else {
            throw ParseError.missingColumns
        }
        var result: [Observation] = []
        for line in lines.dropFirst() {
            let fields = CSVRowSplitter.split(line: line, delimiter: ",")
            guard fields.count > max(periodIndex, valueIndex) else { continue }
            let parts = fields[periodIndex].trimmingCharacters(in: .whitespaces).split(separator: "-").compactMap { Int($0) }
            guard parts.count == 2, (1...12).contains(parts[1]),
                  let value = Double(fields[valueIndex].trimmingCharacters(in: .whitespaces)), value.isFinite else { continue }
            result.append(Observation(month: MonthRange.of(year: parts[0], month: parts[1]).start, valuePercent: value))
        }
        return result.sorted { $0.month < $1.month }
    }
}

/// Fetches an index's monthly averages; `nil` on any failure (offline, unreadable), so the
/// caller keeps what's stored.
public protocol InterestIndexFetching {
    func fetchMonthlyAverages(for index: InterestIndex, startPeriod: String) async -> [ECBEuriborFile.Observation]?
}

public final class ECBEuriborFetcher: InterestIndexFetching {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func fetchMonthlyAverages(for index: InterestIndex, startPeriod: String) async -> [ECBEuriborFile.Observation]? {
        guard let url = ECBEuriborFile.monthlyURL(for: index, startPeriod: startPeriod) else { return nil }
        do {
            var request = URLRequest(url: url)
            request.setValue("text/csv", forHTTPHeaderField: "Accept")
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let text = String(data: data, encoding: .utf8) else { return nil }
            let values = try ECBEuriborFile.parse(text)
            return values.isEmpty ? nil : values
        } catch {
            return nil
        }
    }
}

// MARK: - Fetched automatically

/// Remembers when each index was last asked for, so it's asked at most once a day.
public protocol InterestIndexFetchLog: AnyObject {
    func lastAttempt(index: InterestIndex) -> Date?
    func recordAttempt(index: InterestIndex, at date: Date)
}

/// The attempts of this run only.
public final class InterestIndexFetchMemoryLog: InterestIndexFetchLog, @unchecked Sendable {
    private let lock = NSLock()
    private var attempts: [InterestIndex: Date] = [:]

    public init() {}

    public func lastAttempt(index: InterestIndex) -> Date? {
        lock.lock(); defer { lock.unlock() }
        return attempts[index]
    }

    public func recordAttempt(index: InterestIndex, at date: Date) {
        lock.lock(); defer { lock.unlock() }
        attempts[index] = date
    }
}

/// The attempts kept in `UserDefaults` (across launches): one dictionary, index → time.
public final class InterestIndexFetchDefaultsLog: InterestIndexFetchLog, @unchecked Sendable {
    public static let defaultKey = "interestIndexFetchAttempts"
    private let defaults: UserDefaults
    private let key: String
    private let lock = NSLock()

    public init(defaults: UserDefaults = .standard, key: String = InterestIndexFetchDefaultsLog.defaultKey) {
        self.defaults = defaults
        self.key = key
    }

    public func lastAttempt(index: InterestIndex) -> Date? {
        lock.lock(); defer { lock.unlock() }
        return (defaults.dictionary(forKey: key)?[index.rawValue] as? Double).map(Date.init(timeIntervalSince1970:))
    }

    public func recordAttempt(index: InterestIndex, at date: Date) {
        lock.lock(); defer { lock.unlock() }
        var attempts = defaults.dictionary(forKey: key) ?? [:]
        attempts[index.rawValue] = date.timeIntervalSince1970
        defaults.set(attempts, forKey: key)
    }
}

extension InterestIndexValues {
    /// What an automatic fetch did.
    public struct AutoFetchOutcome: Equatable, Sendable {
        /// Months added or changed, by index.
        public var stored: [InterestIndex: Int] = [:]
        /// Indices that couldn't be fetched: asked again on a later day.
        public var failed: [InterestIndex] = []
        /// Indices asked for less than a day ago: left for now.
        public var throttled: [InterestIndex] = []

        public init(stored: [InterestIndex: Int] = [:], failed: [InterestIndex] = [], throttled: [InterestIndex] = []) {
            self.stored = stored
            self.failed = failed
            self.throttled = throttled
        }
    }

    /// An index is asked for at most once in this long.
    public static let retryInterval: TimeInterval = 86_400
    /// The first month fetched.
    public static let fetchStartPeriod = "2000-01"

    /// Fetches the monthly averages of every index in use (`indicesInUse`) and stores them
    /// (`storeFetched`: never over a manual value). Each index is asked at most once per
    /// `retryInterval` (`log`); a failure is quiet.
    @discardableResult
    public static func fetchInUse(db: some DatabaseWriter, today: Date = Date(), fetcher: InterestIndexFetching,
                                  log: InterestIndexFetchLog) async throws -> AutoFetchOutcome {
        let indices = try await db.read { db in try Self.indicesInUse(db: db) }
        var outcome = AutoFetchOutcome()
        for index in indices {
            if let last = log.lastAttempt(index: index), abs(today.timeIntervalSince(last)) < retryInterval {
                outcome.throttled.append(index)
                continue
            }
            log.recordAttempt(index: index, at: today)
            guard let values = await fetcher.fetchMonthlyAverages(for: index, startPeriod: fetchStartPeriod) else {
                outcome.failed.append(index)
                continue
            }
            let count = try await db.write { db in try Self.storeFetched(db: db, index: index, values: values, now: today) }
            outcome.stored[index] = count
        }
        return outcome
    }
}

func registerInterestIndexAndMortgageRulesMigration(_ migrator: inout DatabaseMigrator) {
    migrator.registerMigration("createInterestIndexAndMortgageRules") { db in
        try db.create(table: "interestIndexValue") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("indexName", .text).notNull()
            t.column("period", .text).notNull()
            t.column("date", .datetime).notNull()
            t.column("valuePercent", .double).notNull()
            t.column("source", .text).notNull()
            t.column("fetchedAt", .datetime)
            t.uniqueKey(["indexName", "period", "date"])
        }
        try db.alter(table: "propertyMortgageTerms") { t in
            t.add(column: "rateIndex", .text)
            t.add(column: "spreadPercent", .double)
            t.add(column: "fixingConvention", .text).notNull().defaults(to: MortgageFixingConvention.previousMonthAverage.rawValue)
            t.add(column: "fixingBusinessDays", .integer).notNull().defaults(to: 2)
            t.add(column: "dayCount", .text).notNull().defaults(to: MortgageDayCount.thirty360.rawValue)
            t.add(column: "totalInstalments", .integer)
            t.add(column: "firstInstalmentDate", .datetime)
            t.add(column: "indexDecimals", .integer).notNull().defaults(to: 3)
            t.add(column: "interestRounding", .text).notNull().defaults(to: MortgageInterestRounding.nearest.rawValue)
        }
        // A rate entered before ("the rate charged now") stays the loan's rate: a fixed one.
        try db.execute(sql: "UPDATE propertyMortgageTerms SET rateIndex = 'fixed' WHERE annualRatePercent IS NOT NULL")
        try db.create(table: "mortgageRateOverride") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("propertyId", .integer).notNull().indexed().references("property", onDelete: .cascade)
            t.column("periodStart", .datetime).notNull()
            t.column("ratePercent", .double).notNull()
            t.column("note", .text)
            t.uniqueKey(["propertyId", "periodStart"])
        }
    }
}
