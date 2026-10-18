import GRDB
import Foundation

/// HMRC's average exchange rates per tax year (spec §6.2): the published average for the year
/// to 31 March, pre-filled for past years from the filed returns, with manual override.
/// Stored per year and currency; a fetch never replaces a manual or filed-return rate.
public enum HMRCRates {
    /// The rate of `currencyCode` for the year, if stored.
    public static func rate(db: Database, startYear: Int, currencyCode: String) throws -> HMRCRate? {
        try HMRCRate.filter(Column("startYear") == startYear && Column("currencyCode") == currencyCode.uppercased()).fetchOne(db)
    }

    /// Every stored rate, latest year first, then by currency.
    public static func all(db: Database) throws -> [HMRCRate] {
        try HMRCRate.order(Column("startYear").desc, Column("currencyCode")).fetchAll(db)
    }

    /// Stores (replacing whatever is there) the rate for the year and currency.
    @discardableResult
    public static func set(db: Database, startYear: Int, currencyCode: String, gbpPerUnit: Double, unitsPerPound: Double? = nil,
                           source: HMRCRateSource, fetchedAt: Date? = nil, notes: String? = nil) throws -> HMRCRate {
        let code = try normalizedCode(currencyCode)
        guard gbpPerUnit.isFinite, gbpPerUnit > 0 else { throw TaxError.invalidRate }
        if let units = unitsPerPound {
            // The two forms must say the same rate.
            guard units.isFinite, units > 0, abs(gbpPerUnit * units - 1) < 1e-4 else { throw TaxError.invalidRate }
        }
        var row = try rate(db: db, startYear: startYear, currencyCode: code)
            ?? HMRCRate(startYear: startYear, currencyCode: code, gbpPerUnit: gbpPerUnit, source: source)
        row.gbpPerUnit = gbpPerUnit
        row.unitsPerPound = unitsPerPound
        row.source = source
        row.fetchedAt = fetchedAt.map(EvidenceLinks.wholeSeconds)
        row.notes = Transaction.normalizedNote(notes)
        try row.save(db)
        return row
    }

    /// Removes the rate; `false` when there was none.
    @discardableResult
    public static func remove(db: Database, startYear: Int, currencyCode: String) throws -> Bool {
        try HMRCRate.filter(Column("startYear") == startYear && Column("currencyCode") == currencyCode.uppercased()).deleteAll(db) > 0
    }

    /// Stores published rates for the year, for the currencies in `codes` (all when nil),
    /// leaving manual and filed-return rates alone unless `replaceAll`. Returns what was stored.
    @discardableResult
    public static func storePublished(db: Database, startYear: Int, rates: [HMRCPublishedRate], codes: Set<String>? = nil,
                                      replaceAll: Bool = false, now: Date = Date()) throws -> [HMRCRate] {
        var stored: [HMRCRate] = []
        let wanted = codes.map { Set($0.map { $0.uppercased() }) }
        for published in rates where wanted.map({ $0.contains(published.currencyCode) }) ?? true {
            if let existing = try rate(db: db, startYear: startYear, currencyCode: published.currencyCode),
               existing.source != .hmrcPublished, !replaceAll {
                continue
            }
            stored.append(try set(db: db, startYear: startYear, currencyCode: published.currencyCode, gbpPerUnit: published.gbpPerUnit,
                                  unitsPerPound: published.unitsPerPound, source: .hmrcPublished, fetchedAt: now,
                                  notes: "HMRC average for the year to 31 March \(startYear + 1)"))
        }
        return stored
    }

    static func normalizedCode(_ code: String) throws -> String {
        let code = code.trimmingCharacters(in: .whitespaces).uppercased()
        guard code.count == 3, code.allSatisfy({ $0.isASCII && $0.isLetter }) else { throw TaxError.invalidCurrencyCode }
        return code
    }
}

// MARK: - Fetched automatically

/// Remembers when each tax year's HMRC file was last asked for, so a rate that isn't there
/// yet (offline, not published) is asked for again at most once a day.
public protocol HMRCRateFetchLog: AnyObject {
    func lastAttempt(startYear: Int) -> Date?
    func recordAttempt(startYear: Int, at date: Date)
}

/// The attempts of this run of the app (or tool) only.
public final class HMRCRateFetchMemoryLog: HMRCRateFetchLog, @unchecked Sendable {
    /// One log for the process: the default of `HMRCRates.fetchMissing`.
    public static let shared = HMRCRateFetchMemoryLog()
    private let lock = NSLock()
    private var attempts: [Int: Date] = [:]

    public init() {}

    public func lastAttempt(startYear: Int) -> Date? {
        lock.lock(); defer { lock.unlock() }
        return attempts[startYear]
    }

    public func recordAttempt(startYear: Int, at date: Date) {
        lock.lock(); defer { lock.unlock() }
        attempts[startYear] = date
    }
}

/// The attempts kept in `UserDefaults` (across launches): one dictionary, start year → time.
public final class HMRCRateFetchDefaultsLog: HMRCRateFetchLog, @unchecked Sendable {
    public static let defaultKey = "hmrcRateFetchAttempts"
    private let defaults: UserDefaults
    private let key: String
    private let lock = NSLock()

    public init(defaults: UserDefaults = .standard, key: String = HMRCRateFetchDefaultsLog.defaultKey) {
        self.defaults = defaults
        self.key = key
    }

    public func lastAttempt(startYear: Int) -> Date? {
        lock.lock(); defer { lock.unlock() }
        return (defaults.dictionary(forKey: key)?[String(startYear)] as? Double).map(Date.init(timeIntervalSince1970:))
    }

    public func recordAttempt(startYear: Int, at date: Date) {
        lock.lock(); defer { lock.unlock() }
        var attempts = defaults.dictionary(forKey: key) ?? [:]
        attempts[String(startYear)] = date.timeIntervalSince1970
        defaults.set(attempts, forKey: key)
    }
}

extension HMRCRates {
    /// What an automatic fetch did.
    public struct AutoFetchOutcome: Equatable, Sendable {
        /// The rates stored, by year then currency.
        public var fetched: [HMRCRate] = []
        /// Years whose file couldn't be read, or lacked a currency wanted: asked again on a later day.
        public var failedYears: [Int] = []
        /// Years with a rate missing that were asked for less than a day ago: left for now.
        public var throttledYears: [Int] = []

        public init(fetched: [HMRCRate] = [], failedYears: [Int] = [], throttledYears: [Int] = []) {
            self.fetched = fetched
            self.failedYears = failedYears
            self.throttledYears = throttledYears
        }
    }

    /// The start of an automatically fetched rate's notes (`HMRCRate.isFetchedAutomatically`).
    public static let autoFetchedNotePrefix = "Fetched automatically"
    /// A year is asked for at most once in this long.
    public static let retryInterval: TimeInterval = 86_400

    /// The rates the years need and don't have: for each UK tax year that has ended by
    /// `today` (6 April after it), from the first year of the Tax years list (the first year
    /// anyone owns a property, or has a tax year or employment record) to the last ended one,
    /// the codes of the non-GBP currencies its people's properties and sources use (each
    /// property's currency and its accounts', the year's manual items and other income),
    /// without a stored rate. Start year → codes; years with nothing missing are left out.
    public static func missing(db: Database, today: Date) throws -> [Int: Set<String>] {
        let rows = try TaxOverview.rows(db: db, now: today).filter { $0.year.end <= today }
        let currencies = Dictionary(uniqueKeysWithValues: try Account.fetchAll(db).compactMap { a in a.id.map { ($0, a.currency) } })
        var propertyCurrencies: [Int64: Set<Currency>] = [:]
        func used(by property: Property) throws -> Set<Currency> {
            guard let id = property.id else { return [property.currency] }
            if let known = propertyCurrencies[id] { return known }
            let accounts = try Properties.accounts(db: db, propertyId: id).compactMap { currencies[$0.accountId] }
            let set = Set([property.currency] + accounts)
            propertyCurrencies[id] = set
            return set
        }
        var wanted: [Int: Set<Currency>] = [:]
        for row in rows {
            guard let personId = row.person.id else { continue }
            let startYear = row.year.startYear
            var set = wanted[startYear] ?? []
            for property in row.properties { set.formUnion(try used(by: property)) }
            set.formUnion(try TaxManualItems.items(db: db, startYear: startYear, personId: personId).map(\.currency))
            set.formUnion(try OtherIncomes.incomes(db: db, startYear: startYear, personId: personId).map(\.currency))
            wanted[startYear] = set
        }
        var missing: [Int: Set<String>] = [:]
        for (startYear, set) in wanted {
            let codes = Set(try set.filter { $0 != .gbp }.map { $0.rawValue.uppercased() }
                .filter { try rate(db: db, startYear: startYear, currencyCode: $0) == nil })
            if !codes.isEmpty { missing[startYear] = codes }
        }
        return missing
    }

    /// Fetches HMRC's published average (the year to 31 March) for every rate `missing`
    /// finds, and stores it (`hmrcPublished`, noted as fetched automatically). Never replaces
    /// a stored rate of any source: a rate entered meanwhile is kept. A failure (offline, the
    /// file not published yet, a currency not in it) is quiet: the year is asked for again
    /// once `retryInterval` has passed since its last attempt (`log`), as is every year.
    @discardableResult
    public static func fetchMissing(db: some DatabaseWriter, today: Date = Date(), fetcher: HMRCRateFetching,
                                    log: HMRCRateFetchLog = HMRCRateFetchMemoryLog.shared) async throws -> AutoFetchOutcome {
        let missing = try await db.read { db in try Self.missing(db: db, today: today) }
        var outcome = AutoFetchOutcome()
        for startYear in missing.keys.sorted() {
            let codes = missing[startYear]!
            if let last = log.lastAttempt(startYear: startYear), abs(today.timeIntervalSince(last)) < retryInterval {
                outcome.throttledYears.append(startYear)
                continue
            }
            // Recorded before asking, so a second run meanwhile leaves the year alone.
            log.recordAttempt(startYear: startYear, at: today)
            guard let published = await fetcher.fetchAverageRates(for: UKTaxYear(startYear: startYear)) else {
                outcome.failedYears.append(startYear)
                continue
            }
            let stored = try await db.write { db -> [HMRCRate] in
                var stored: [HMRCRate] = []
                for rate in published where codes.contains(rate.currencyCode) {
                    guard try Self.rate(db: db, startYear: startYear, currencyCode: rate.currencyCode) == nil else { continue }
                    stored.append(try set(db: db, startYear: startYear, currencyCode: rate.currencyCode, gbpPerUnit: rate.gbpPerUnit,
                                          unitsPerPound: rate.unitsPerPound, source: .hmrcPublished, fetchedAt: today,
                                          notes: "\(autoFetchedNotePrefix): HMRC average for the year to 31 March \(startYear + 1)"))
                }
                return stored
            }
            outcome.fetched += stored.sorted { $0.currencyCode < $1.currencyCode }
            if !Set(published.map(\.currencyCode)).isSuperset(of: codes) { outcome.failedYears.append(startYear) }
        }
        return outcome
    }
}

extension HMRCRate {
    /// Stored by `HMRCRates.fetchMissing` (not by a Fetch the user asked for).
    public var isFetchedAutomatically: Bool {
        source == .hmrcPublished && (notes?.hasPrefix(HMRCRates.autoFetchedNotePrefix) ?? false)
    }

    /// "€1 = £0.8467 (1.1811 per £1)": the rate both ways, as the year page notes it.
    public var bothWaysText: String {
        let symbol = Currency(rawValue: currencyCode.lowercased())?.symbol ?? "\(currencyCode) "
        let units = unitsPerPound ?? 1 / gbpPerUnit
        return String(format: "%@1 = £%.4f (%.4f per £1)", symbol, gbpPerUnit, units)
    }
}

extension HMRCRate {
    /// `minorUnits` of the currency in pence: divided by the published units per £1 when
    /// stored (as HMRC and the accountant convert), else times `gbpPerUnit`; rounded.
    public func gbp(_ minorUnits: Int) -> Int {
        if let unitsPerPound, unitsPerPound > 0 { return Int((Double(minorUnits) / unitsPerPound).rounded()) }
        return Int((Double(minorUnits) * gbpPerUnit).rounded())
    }
}

/// One currency's line of HMRC's average-rates file.
public struct HMRCPublishedRate: Equatable, Sendable {
    public var currencyCode: String
    /// "Currency Units per £1".
    public var unitsPerPound: Double
    /// `1 / unitsPerPound` (more precise than the file's 4-decimal sterling value).
    public var gbpPerUnit: Double { 1 / unitsPerPound }

    public init(currencyCode: String, unitsPerPound: Double) {
        self.currencyCode = currencyCode
        self.unitsPerPound = unitsPerPound
    }
}

/// HMRC's average exchange rates file (Trade Tariff service, CSV): Country, Unit Of Currency,
/// Currency Code, Sterling value of Currency Unit £, Currency Units per £1.
public enum HMRCRateFile {
    public enum ParseError: Error, Equatable {
        case missingColumns
    }

    /// The average for the UK tax year (the year to 31 March after it starts).
    public static func averageURL(for year: UKTaxYear) -> URL {
        URL(string: "https://www.trade-tariff.service.gov.uk/api/v2/exchange_rates/files/average_csv_\(year.startYear + 1)-3.csv")!
    }

    /// The rows with a readable code and a positive units-per-pound; a currency listed twice
    /// (several countries) keeps its first row.
    public static func parse(_ text: String) throws -> [HMRCPublishedRate] {
        let lines = text.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard let header = lines.first else { throw ParseError.missingColumns }
        let columns = CSVRowSplitter.split(line: header.trimmingCharacters(in: CharacterSet(charactersIn: "\u{FEFF}")), delimiter: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        guard let codeIndex = columns.firstIndex(of: "currency code"),
              let unitsIndex = columns.firstIndex(where: { $0.hasPrefix("currency units per") }) else { throw ParseError.missingColumns }
        var seen: Set<String> = []
        var rates: [HMRCPublishedRate] = []
        for line in lines.dropFirst() {
            let fields = CSVRowSplitter.split(line: line, delimiter: ",")
            guard fields.count > max(codeIndex, unitsIndex),
                  let code = try? HMRCRates.normalizedCode(fields[codeIndex]),
                  let units = Double(fields[unitsIndex].replacingOccurrences(of: ",", with: "").trimmingCharacters(in: .whitespaces)), units > 0,
                  seen.insert(code).inserted else { continue }
            rates.append(HMRCPublishedRate(currencyCode: code, unitsPerPound: units))
        }
        return rates
    }
}

/// Fetches HMRC's average rates for a tax year; `nil` on any failure (offline, not yet
/// published, unreadable), so the caller keeps what's stored.
public protocol HMRCRateFetching {
    func fetchAverageRates(for year: UKTaxYear) async -> [HMRCPublishedRate]?
}

public final class HMRCTradeTariffRateFetcher: HMRCRateFetching {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func fetchAverageRates(for year: UKTaxYear) async -> [HMRCPublishedRate]? {
        do {
            let (data, response) = try await session.data(from: HMRCRateFile.averageURL(for: year))
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let text = String(data: data, encoding: .utf8) else { return nil }
            let rates = try HMRCRateFile.parse(text)
            return rates.isEmpty ? nil : rates
        } catch {
            return nil
        }
    }
}
