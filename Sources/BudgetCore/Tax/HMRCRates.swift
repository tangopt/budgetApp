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
