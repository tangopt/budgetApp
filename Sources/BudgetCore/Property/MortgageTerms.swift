import GRDB
import Foundation

/// A property's mortgage facts, as the user enters them in Profile: when its variable rate is
/// revised (the months, revised on their 1st: by default every quarter, 1 January, April,
/// July and October), what the rate follows (a note such as "Euribor 3M + 1.00%"), and, for
/// the loan's projection, the day of its final instalment, the balloon left to repay with it
/// and the rate charged now (else derived from the interest on the loan). One row per
/// property; none means the defaults.
public struct PropertyMortgageTerms: Codable, Equatable, FetchableRecord, PersistableRecord, Sendable {
    public var propertyId: Int64
    /// The months (1–12) the rate is revised in, on their 1st, stored as "1,4,7,10".
    public var revisionMonthsText: String
    /// What the rate follows ("Euribor 3M + 1.00%"), shown beside the schedule.
    public var rateNote: String?
    /// The day of the last instalment (a UTC midnight); `nil` when not known.
    public var finalInstalmentDate: Date?
    /// The capital left to repay with the final instalment, positive, in the property's currency.
    public var balloonMinorUnits: Int?
    /// The annual rate charged now (TAN, %), when entered; else derived from the loan's interest.
    public var annualRatePercent: Double?

    public static let databaseTableName = "propertyMortgageTerms"

    enum CodingKeys: String, CodingKey {
        case propertyId
        case revisionMonthsText = "revisionMonths"
        case rateNote, finalInstalmentDate, balloonMinorUnits, annualRatePercent
    }

    public init(propertyId: Int64, revisionMonths: [Int] = MortgageTerms.defaultRevisionMonths, rateNote: String? = nil,
                finalInstalmentDate: Date? = nil, balloonMinorUnits: Int? = nil, annualRatePercent: Double? = nil) {
        self.propertyId = propertyId
        self.revisionMonthsText = MortgageTerms.text(revisionMonths)
        self.rateNote = rateNote
        self.finalInstalmentDate = finalInstalmentDate
        self.balloonMinorUnits = balloonMinorUnits
        self.annualRatePercent = annualRatePercent
    }

    /// The revision months, 1–12, in order (the default when the stored text reads as none).
    public var revisionMonths: [Int] {
        get {
            let months = MortgageTerms.months(revisionMonthsText)
            return months.isEmpty ? MortgageTerms.defaultRevisionMonths : months
        }
        set { revisionMonthsText = MortgageTerms.text(newValue) }
    }

    /// The days the rate is revised in `[from, to)`: the 1st of each revision month.
    public func revisionDates(from: Date, to: Date) -> [Date] {
        MortgageTerms.revisionDates(months: revisionMonths, from: from, to: to)
    }
}

public enum MortgageTermsError: Error, Equatable {
    /// No month chosen, or one outside 1–12.
    case invalidRevisionMonths
    case negativeBalloon
    /// A rate below 0% or above 50%.
    case invalidRate
}

public enum MortgageTerms {
    /// Every quarter: 1 January, 1 April, 1 July, 1 October.
    public static let defaultRevisionMonths = [1, 4, 7, 10]

    /// The property's terms, or the defaults when none are saved.
    public static func terms(db: Database, propertyId: Int64) throws -> PropertyMortgageTerms {
        try PropertyMortgageTerms.fetchOne(db, key: propertyId) ?? PropertyMortgageTerms(propertyId: propertyId)
    }

    /// Saves the terms (replacing any): revision months 1–12, at least one; a balloon of 0 or
    /// more; a rate of 0–50%; the final day as a day; a blank note as none.
    public static func save(db: Database, _ terms: PropertyMortgageTerms) throws {
        guard try Property.fetchOne(db, key: terms.propertyId) != nil else { throw PropertyError.propertyNotFound }
        let months = Self.months(terms.revisionMonthsText)
        guard !months.isEmpty, Self.allMonthsValid(terms.revisionMonthsText) else { throw MortgageTermsError.invalidRevisionMonths }
        if let balloon = terms.balloonMinorUnits, balloon < 0 { throw MortgageTermsError.negativeBalloon }
        if let rate = terms.annualRatePercent, !(0...50).contains(rate) { throw MortgageTermsError.invalidRate }
        var terms = terms
        terms.revisionMonthsText = text(months)
        terms.finalInstalmentDate = terms.finalInstalmentDate.map(PropertyDates.day)
        let note = terms.rateNote?.trimmingCharacters(in: .whitespacesAndNewlines)
        terms.rateNote = note?.isEmpty == false ? note : nil
        try terms.save(db)
    }

    /// The 1st of each of `months` in `[from, to)`, in order.
    public static func revisionDates(months: [Int], from: Date, to: Date) -> [Date] {
        let months = Set(months.filter { (1...12).contains($0) })
        guard !months.isEmpty, from < to else { return [] }
        let calendar = MonthRange.calendar
        let (year, month) = MonthRange.components(of: from)
        var monthStart = MonthRange.of(year: year, month: month).start
        var dates: [Date] = []
        while monthStart < to {
            if monthStart >= from, months.contains(MonthRange.components(of: monthStart).month) { dates.append(monthStart) }
            monthStart = calendar.date(byAdding: .month, value: 1, to: monthStart)!
        }
        return dates
    }

    /// "every 3 months on 1 Jan, 1 Apr, 1 Jul and 1 Oct", "every year on 1 Jan",
    /// "on 1 Mar and 1 Sep": how Profile and the projection's caption say the schedule.
    public static func scheduleText(_ months: [Int]) -> String {
        let sorted = Array(Set(months.filter { (1...12).contains($0) })).sorted()
        guard !sorted.isEmpty else { return "never" }
        let names = sorted.map { "1 \(shortMonthName($0))".unbroken }
        let list = names.count == 1 ? names[0] : names.dropLast().joined(separator: ", ") + " and " + names.last!
        // Evenly spaced: "every n months".
        let gaps = zip(sorted, sorted.dropFirst() + [sorted[0] + 12]).map { $1 - $0 }
        if Set(gaps).count == 1 {
            let gap = gaps[0]
            let every = gap == 12 ? "every year" : gap == 1 ? "every month" : "every \(gap) months"
            return "\(every) on \(list)"
        }
        return "on \(list)"
    }

    /// "Jan" … "Dec".
    public static func shortMonthName(_ month: Int) -> String {
        ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"][(month - 1) % 12]
    }

    static func months(_ text: String) -> [Int] {
        Array(Set(text.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }.filter { (1...12).contains($0) })).sorted()
    }

    static func allMonthsValid(_ text: String) -> Bool {
        text.split(separator: ",").allSatisfy { part in Int(part.trimmingCharacters(in: .whitespaces)).map { (1...12).contains($0) } ?? false }
    }

    static func text(_ months: [Int]) -> String {
        Array(Set(months)).sorted().map(String.init).joined(separator: ",")
    }
}

func registerPropertyMortgageTermsMigration(_ migrator: inout DatabaseMigrator) {
    migrator.registerMigration("createPropertyMortgageTerms") { db in
        try db.create(table: "propertyMortgageTerms") { t in
            t.primaryKey("propertyId", .integer).references("property", onDelete: .cascade)
            t.column("revisionMonths", .text).notNull().defaults(to: "1,4,7,10")
            t.column("rateNote", .text)
            t.column("finalInstalmentDate", .datetime)
            t.column("balloonMinorUnits", .integer)
            t.column("annualRatePercent", .double)
        }
    }
}
