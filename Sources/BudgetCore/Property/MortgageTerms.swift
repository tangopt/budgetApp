import GRDB
import Foundation

/// How a revision's index value is chosen.
public enum MortgageFixingConvention: String, Codable, CaseIterable, Sendable {
    /// The index's average over the month before the revision month (Euribor 3M's September
    /// average for 1 October): as Portuguese housing loans commonly do.
    case previousMonthAverage
    /// The index's daily fixing `fixingBusinessDays` TARGET business days before the revision.
    case businessDaysBefore
}

/// How a month's interest is counted.
public enum MortgageDayCount: String, Codable, CaseIterable, Sendable {
    /// Every month is 30 days of a 360-day year: interest = owed × rate ÷ 12.
    case thirty360 = "30/360"
    /// The days between instalments over 360: interest = owed × rate × days ÷ 360.
    case actual360 = "actual/360"
}

/// How an instalment's interest is rounded to the cent.
public enum MortgageInterestRounding: String, Codable, CaseIterable, Sendable {
    case nearest
    case down
}

/// A property's mortgage facts, as the user enters them in Profile: the loan's rules — what
/// its rate follows (a Euribor tenor plus a spread, or a fixed rate), how a revision's index
/// value is chosen (the fixing convention), when it's revised (the months, on their 1st: by
/// default every quarter, 1 January, April, July and October), how interest is counted (30/360
/// or Actual/360) and rounded — and its instalments: how many in all, the first one's day (or
/// the final one's), the balloon left to repay with the final one. `MortgageRate` works the
/// rate and instalment of each revision out from these. One row per property; none means the
/// defaults.
public struct PropertyMortgageTerms: Codable, Equatable, FetchableRecord, PersistableRecord, Sendable {
    public var propertyId: Int64
    /// The months (1–12) the rate is revised in, on their 1st, stored as "1,4,7,10".
    public var revisionMonthsText: String
    /// A note on the rate (kept from before the rules; not shown when the rules are set).
    public var rateNote: String?
    /// The day of the last instalment (a UTC midnight), when entered; else worked out from the
    /// first instalment's day and the number of instalments (`effectiveFinalInstalmentDate`).
    public var finalInstalmentDate: Date?
    /// The capital left to repay with the final instalment, positive, in the property's currency.
    public var balloonMinorUnits: Int?
    /// The fixed rate (TAN, %) when `rateIndex` is `.fixed`.
    public var annualRatePercent: Double?
    /// What the rate follows; nil: not set (the rate is then derived from the loan's interest).
    public var rateIndex: InterestIndex?
    /// Added to the index (%, e.g. 1.000).
    public var spreadPercent: Double?
    public var fixingConvention: MortgageFixingConvention
    /// For `.businessDaysBefore`: how many TARGET business days before the revision.
    public var fixingBusinessDays: Int
    public var dayCount: MortgageDayCount
    /// All the loan's instalments, the final one included (480 for 40 years).
    public var totalInstalments: Int?
    /// The day the first instalment was due (a UTC midnight).
    public var firstInstalmentDate: Date?
    /// The index value is rounded to this many decimals before the spread is added.
    public var indexDecimals: Int
    public var interestRounding: MortgageInterestRounding
    /// The capital first lent (the amount borrowed), positive, in the property's currency:
    /// with the first instalment's day it lets the loan's history be estimated back to its
    /// start (`MortgageHistory`).
    public var amountBorrowedMinorUnits: Int?

    public static let databaseTableName = "propertyMortgageTerms"

    enum CodingKeys: String, CodingKey {
        case propertyId
        case revisionMonthsText = "revisionMonths"
        case rateNote, finalInstalmentDate, balloonMinorUnits, annualRatePercent
        case rateIndex, spreadPercent, fixingConvention, fixingBusinessDays, dayCount, totalInstalments, firstInstalmentDate
        case indexDecimals, interestRounding, amountBorrowedMinorUnits
    }

    public init(propertyId: Int64, revisionMonths: [Int] = MortgageTerms.defaultRevisionMonths, rateNote: String? = nil,
                finalInstalmentDate: Date? = nil, balloonMinorUnits: Int? = nil, annualRatePercent: Double? = nil,
                rateIndex: InterestIndex? = nil, spreadPercent: Double? = nil,
                fixingConvention: MortgageFixingConvention = .previousMonthAverage, fixingBusinessDays: Int = 2,
                dayCount: MortgageDayCount = .thirty360, totalInstalments: Int? = nil, firstInstalmentDate: Date? = nil,
                indexDecimals: Int = 3, interestRounding: MortgageInterestRounding = .nearest, amountBorrowedMinorUnits: Int? = nil) {
        self.propertyId = propertyId
        self.revisionMonthsText = MortgageTerms.text(revisionMonths)
        self.rateNote = rateNote
        self.finalInstalmentDate = finalInstalmentDate
        self.balloonMinorUnits = balloonMinorUnits
        self.annualRatePercent = annualRatePercent
        self.rateIndex = rateIndex
        self.spreadPercent = spreadPercent
        self.fixingConvention = fixingConvention
        self.fixingBusinessDays = fixingBusinessDays
        self.dayCount = dayCount
        self.totalInstalments = totalInstalments
        self.firstInstalmentDate = firstInstalmentDate
        self.indexDecimals = indexDecimals
        self.interestRounding = interestRounding
        self.amountBorrowedMinorUnits = amountBorrowedMinorUnits
    }

    /// Whether the rules give a rate: a fixed rate entered, or an index with its spread.
    public var hasRateRules: Bool {
        switch rateIndex {
        case .fixed?: return annualRatePercent != nil
        case nil: return false
        default: return spreadPercent != nil
        }
    }

    /// The final instalment's day: as entered, else the first instalment's day plus
    /// `totalInstalments` − 1 months (on the first's day of the month, clamped to short months).
    public var effectiveFinalInstalmentDate: Date? {
        if let finalInstalmentDate { return finalInstalmentDate }
        guard let first = firstInstalmentDate, let total = totalInstalments, total >= 1 else { return nil }
        return MortgageTerms.dueDate(monthsAfter: total - 1, first: first)
    }

    /// The day of the month instalments are due on, from the first instalment's day.
    public var paymentDay: Int? { firstInstalmentDate.map { MonthRange.calendar.component(.day, from: $0) } }

    /// The number (1…) of the instalment due in `date`'s month, from the first instalment.
    public func instalmentNumber(dueIn date: Date) -> Int? {
        guard let first = firstInstalmentDate else { return nil }
        let a = MonthRange.components(of: first), b = MonthRange.components(of: date)
        return MonthRange.index(year: b.year, month: b.month) - MonthRange.index(year: a.year, month: a.month) + 1
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
    /// A spread below −5% or above 20%.
    case invalidSpread
    /// Fewer than 1 or more than 1,200 instalments, or business days outside 0–10, or decimals outside 0–6.
    case invalidCount
    /// The final instalment is before the first.
    case finalBeforeFirst
    /// An amount borrowed of zero or less, or not more than the balloon.
    case invalidAmountBorrowed
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
        if let borrowed = terms.amountBorrowedMinorUnits, borrowed <= max(0, terms.balloonMinorUnits ?? 0) {
            throw MortgageTermsError.invalidAmountBorrowed
        }
        if let rate = terms.annualRatePercent, !(0...50).contains(rate) { throw MortgageTermsError.invalidRate }
        if let spread = terms.spreadPercent, !(-5...20).contains(spread) { throw MortgageTermsError.invalidSpread }
        if let total = terms.totalInstalments, !(1...1_200).contains(total) { throw MortgageTermsError.invalidCount }
        guard (0...10).contains(terms.fixingBusinessDays), (0...6).contains(terms.indexDecimals) else { throw MortgageTermsError.invalidCount }
        var terms = terms
        terms.revisionMonthsText = text(months)
        terms.finalInstalmentDate = terms.finalInstalmentDate.map(PropertyDates.day)
        terms.firstInstalmentDate = terms.firstInstalmentDate.map(PropertyDates.day)
        if let first = terms.firstInstalmentDate, let final = terms.effectiveFinalInstalmentDate, final < first {
            throw MortgageTermsError.finalBeforeFirst
        }
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

    /// The day an instalment is due `months` after the first (on the first's day of the month,
    /// clamped to short months).
    public static func dueDate(monthsAfter months: Int, first: Date) -> Date {
        dueDate(monthsAfter: months, from: first, day: MonthRange.calendar.component(.day, from: first))
    }

    /// The instalment day `months` after `from`'s month, on `day` (clamped to short months).
    public static func dueDate(monthsAfter months: Int, from: Date, day: Int) -> Date {
        let calendar = MonthRange.calendar
        let (year, month) = MonthRange.components(of: from)
        let start = calendar.date(byAdding: .month, value: months, to: MonthRange.of(year: year, month: month).start)!
        let length = calendar.range(of: .day, in: .month, for: start)!.count
        return calendar.date(byAdding: .day, value: min(max(day, 1), length) - 1, to: start)!
    }

    /// "1 Jan 2027".
    public static func dayText(_ date: Date) -> String {
        let parts = MonthRange.calendar.dateComponents([.year, .month, .day], from: date)
        return "\(parts.day!) \(shortMonthName(parts.month!)) \(parts.year!)"
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

func registerMortgageAmountBorrowedMigration(_ migrator: inout DatabaseMigrator) {
    migrator.registerMigration("addMortgageAmountBorrowed") { db in
        try db.alter(table: "propertyMortgageTerms") { t in
            t.add(column: "amountBorrowedMinorUnits", .integer)
        }
    }
}
