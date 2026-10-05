// Sources/BudgetCore/PayPeriods/PayCalendar.swift
import Foundation
import GRDB

/// A month as the spreadsheet meant it: from the day after the previous month's salary up
/// to and including this month's salary date (spec: 2026-10-05-pay-months-design.md).
public struct PayMonth: Hashable, Comparable, Codable {
    public let year: Int
    public let month: Int
    public init(year: Int, month: Int) { self.year = year; self.month = month }
    var index: Int { year * 12 + (month - 1) }
    init(index: Int) { self.init(year: Int((Double(index) / 12).rounded(.down)), month: ((index % 12) + 12) % 12 + 1) }
    public var previous: PayMonth { PayMonth(index: index - 1) }
    public var next: PayMonth { PayMonth(index: index + 1) }
    public static func < (a: PayMonth, b: PayMonth) -> Bool { a.index < b.index }
}

public enum PayCloseSource: Equatable { case manual, salary, projected }
public enum PayCalendarError: Error, Equatable { case invalidCloseDate }

public struct PayCalendar {
    public let today: Date
    private let salaryByMonth: [PayMonth: Date]   // start of day
    private let manualByMonth: [PayMonth: Date]   // start of day
    private let salaryMonthsSorted: [PayMonth]

    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    public init(salaryDates: [Date], manualCloses: [PayMonthClose], today: Date) {
        let cal = Self.calendar
        var salaries: [PayMonth: Date] = [:]
        for date in PayPeriodDetector.paydayAnchors(salaryDates) {
            let day = cal.startOfDay(for: date)
            let parts = cal.dateComponents([.year, .month], from: day)
            let month = PayMonth(year: parts.year!, month: parts.month!)
            salaries[month] = max(salaries[month] ?? day, day) // the later salary wins within a month
        }
        var manual: [PayMonth: Date] = [:]
        for close in manualCloses { manual[PayMonth(year: close.year, month: close.month)] = cal.startOfDay(for: close.closeDate) }
        self.salaryByMonth = salaries
        self.manualByMonth = manual
        self.salaryMonthsSorted = salaries.keys.sorted()
        self.today = today
    }

    public static func load(db: Database, today: Date) throws -> PayCalendar {
        PayCalendar(salaryDates: try PaydaySource.paydayDates(db: db), manualCloses: try PayMonthClose.fetchAll(db), today: today)
    }

    public func closeSource(of month: PayMonth) -> PayCloseSource {
        if manualByMonth[month] != nil { return .manual }
        if salaryByMonth[month] != nil { return .salary }
        return .projected
    }

    public func closeDate(of month: PayMonth) -> Date {
        if let manual = manualByMonth[month] { return manual }
        if let salary = salaryByMonth[month] { return salary }
        let cal = Self.calendar
        let first = cal.date(from: DateComponents(year: month.year, month: month.month, day: 1))!
        let length = cal.range(of: .day, in: .month, for: first)!.count
        guard let reference = salaryMonthsSorted.last(where: { $0 <= month }) ?? salaryMonthsSorted.first else {
            return cal.date(byAdding: .day, value: length - 1, to: first)!
        }
        let day = min(cal.component(.day, from: salaryByMonth[reference]!), length)
        return cal.date(byAdding: .day, value: day - 1, to: first)!
    }

    public func range(of month: PayMonth) -> (start: Date, end: Date) {
        let cal = Self.calendar
        let start = cal.date(byAdding: .day, value: 1, to: closeDate(of: month.previous))!
        let end = cal.date(byAdding: .day, value: 1, to: closeDate(of: month))!.addingTimeInterval(-1)
        return (start, end)
    }

    public func month(containing date: Date) -> PayMonth {
        let parts = Self.calendar.dateComponents([.year, .month], from: date)
        var month = PayMonth(year: parts.year!, month: parts.month!)
        while date > range(of: month).end { month = month.next }
        while date < range(of: month).start { month = month.previous }
        return month
    }

    public func isClosed(_ month: PayMonth) -> Bool { closeSource(of: month) != .projected }

    public func monthClass(_ month: PayMonth) -> MonthClass {
        if isClosed(month) { return .actual }
        return range(of: month).start <= today ? .blended : .forecast
    }

    public var current: PayMonth { month(containing: today) }

    public func validateClose(_ month: PayMonth, on date: Date) throws {
        let day = Self.calendar.startOfDay(for: date)
        guard day >= Self.calendar.startOfDay(for: range(of: month).start) else { throw PayCalendarError.invalidCloseDate }
        if isClosed(month.next), day >= closeDate(of: month.next) { throw PayCalendarError.invalidCloseDate }
    }

    public static func close(db: Database, month: PayMonth, on date: Date, today: Date) throws {
        try load(db: db, today: today).validateClose(month, on: date)
        try PayMonthClose.filter(Column("year") == month.year && Column("month") == month.month).deleteAll(db)
        var close = PayMonthClose(year: month.year, month: month.month, closeDate: calendar.startOfDay(for: date))
        try close.insert(db)
    }

    public static func reopen(db: Database, month: PayMonth) throws {
        try PayMonthClose.filter(Column("year") == month.year && Column("month") == month.month).deleteAll(db)
    }
}

public enum PayMonthTotals {
    /// Confirmed, categorised transactions summed per category per pay month — the same shape
    /// as the old calendar lookup, so every reader just swaps the builder.
    public static func lookup(transactions: [Transaction], calendar: PayCalendar) -> [Int64: [Int: [Int: Int]]] {
        var result: [Int64: [Int: [Int: Int]]] = [:]
        for transaction in transactions {
            guard transaction.status == .confirmed, let categoryId = transaction.categoryId else { continue }
            let month = calendar.month(containing: transaction.date)
            result[categoryId, default: [:]][month.year, default: [:]][month.month, default: 0] += transaction.amountMinorUnits
        }
        return result
    }
}
