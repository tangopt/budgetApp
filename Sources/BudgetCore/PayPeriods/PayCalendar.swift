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
    /// Effective close dates for the span of known (salary/manual) months, forced non-decreasing.
    private let effectiveByMonth: [PayMonth: Date]
    private let lastKnownMonth: PayMonth?

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
        let known = Array(salaries.keys) + Array(manual.keys)
        if let first = known.min(), let last = known.max() {
            var effective: [PayMonth: Date] = [:]
            var previous = Self.rawCloseDate(of: first.previous, salaryByMonth: salaries, manualByMonth: manual, salaryMonthsSorted: self.salaryMonthsSorted)
            var month = first
            while month <= last {
                let raw = Self.rawCloseDate(of: month, salaryByMonth: salaries, manualByMonth: manual, salaryMonthsSorted: self.salaryMonthsSorted)
                previous = max(raw, previous)
                effective[month] = previous
                month = month.next
            }
            self.effectiveByMonth = effective
            self.lastKnownMonth = last
        } else {
            self.effectiveByMonth = [:]
            self.lastKnownMonth = nil
        }
    }

    /// The calendar the Dashboard and the scenario lab read: paydays from the loaded
    /// transactions, and today never earlier than the latest transaction (a clock behind the
    /// data counts as "today = D").
    public static func forData(transactions: [Transaction], categories: [Category], manualCloses: [PayMonthClose], today: Date) -> PayCalendar {
        let dataThrough = transactions.map(\.date).max()
        return PayCalendar(salaryDates: PaydaySource.paydayDates(transactions: transactions, categories: categories),
                           manualCloses: manualCloses, today: dataThrough.map { max(today, $0) } ?? today)
    }

    public static func load(db: Database, today: Date) throws -> PayCalendar {
        PayCalendar(salaryDates: try PaydaySource.paydayDates(db: db), manualCloses: try PayMonthClose.fetchAll(db), today: today)
    }

    public func closeSource(of month: PayMonth) -> PayCloseSource {
        if manualByMonth[month] != nil { return .manual }
        if salaryByMonth[month] != nil { return .salary }
        return .projected
    }

    /// Close date as imported/overridden/projected, before the non-decreasing rule.
    private func rawCloseDate(of month: PayMonth) -> Date {
        Self.rawCloseDate(of: month, salaryByMonth: salaryByMonth, manualByMonth: manualByMonth, salaryMonthsSorted: salaryMonthsSorted)
    }

    private static func rawCloseDate(of month: PayMonth, salaryByMonth: [PayMonth: Date], manualByMonth: [PayMonth: Date], salaryMonthsSorted: [PayMonth]) -> Date {
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

    /// Effective close: never earlier than the previous month's, so an overtaken month is empty.
    public func closeDate(of month: PayMonth) -> Date {
        if let effective = effectiveByMonth[month] { return effective }
        if let last = lastKnownMonth, month > last, let floor = effectiveByMonth[last] {
            return max(rawCloseDate(of: month), floor) // raw projection beyond the known span is monotonic
        }
        return rawCloseDate(of: month)
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
        while date >= range(of: month.next).start { month = month.next }
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
        if day >= rawCloseDate(of: month.next) { throw PayCalendarError.invalidCloseDate }
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

extension PayCalendar {
    /// The close date the Close month sheet starts on: today for the current month, the
    /// projected close for earlier months (`min(today, close)`), never before the month's
    /// start (a future month). UTC start of day.
    public func suggestedCloseDate(of month: PayMonth) -> Date {
        let today = Self.calendar.startOfDay(for: self.today)
        return max(range(of: month).start, min(today, closeDate(of: month)))
    }

    /// 00:00 UTC on the calendar day `date` falls on in `timeZone`. A date picker's value is
    /// local midnight — BST midnight is 23:00 UTC the day before — so a picked day goes
    /// through this before `close(db:month:on:today:)`.
    public static func utcDay(sameDayAs date: Date, in timeZone: TimeZone) -> Date {
        var local = Calendar(identifier: .gregorian)
        local.timeZone = timeZone
        let parts = local.dateComponents([.year, .month, .day], from: date)
        return calendar.date(from: DateComponents(year: parts.year, month: parts.month, day: parts.day))!
    }

    /// The inverse of `utcDay`: midnight in `timeZone` on the calendar day `utcDate` falls
    /// on in UTC, for showing a pay-calendar day in a date picker.
    public static func localDay(sameDayAs utcDate: Date, in timeZone: TimeZone) -> Date {
        var local = Calendar(identifier: .gregorian)
        local.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day], from: utcDate)
        return local.date(from: DateComponents(year: parts.year, month: parts.month, day: parts.day))!
    }
}
