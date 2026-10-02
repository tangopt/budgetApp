import Foundation

/// UTC calendar-month helpers shared by the dashboard and the grid/forecast view models,
/// so "the end of March" means the same instant everywhere.
public enum MonthRange {
    public static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    /// `start` is 00:00:00 UTC on the 1st; `end` is the LAST MOMENT of the month's last day
    /// (next month's start minus one second) — see `FrequencyExpander`'s inclusive
    /// occurrence check; midnight at the start of the last day would silently exclude a
    /// same-day-later occurrence.
    public static func of(year: Int, month: Int) -> (start: Date, end: Date) {
        let start = calendar.date(from: DateComponents(year: year, month: month, day: 1))!
        let end = calendar.date(byAdding: .month, value: 1, to: start)!.addingTimeInterval(-1)
        return (start, end)
    }

    public static func components(of date: Date) -> (year: Int, month: Int) {
        let parts = calendar.dateComponents([.year, .month], from: date)
        return (parts.year!, parts.month!)
    }

    /// Orderable month index: `year * 12 + (month - 1)`.
    public static func index(year: Int, month: Int) -> Int { year * 12 + (month - 1) }
}
