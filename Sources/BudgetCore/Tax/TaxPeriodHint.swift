import Foundation

/// A period written in free text (a transaction's note or description) that tells the tax
/// rules what a payment covers: "2024-07-01 – 2024-12-31", "2024-07..2024-12", "07/2024-12/2024",
/// "2025-01" or "01/2025" (one month) or "2024" (the calendar year). Ranges are `[start, end)` at 00:00 UTC.
public enum TaxPeriodHint {
    /// The first period found, most specific form first; `nil` when there is none.
    public static func period(in text: String?) -> DateInterval? {
        guard let text, !text.isEmpty else { return nil }
        let calendar = MonthRange.calendar
        func day(_ y: Int, _ m: Int, _ d: Int) -> Date? {
            guard (1...12).contains(m), (1...31).contains(d) else { return nil }
            let components = DateComponents(year: y, month: m, day: d)
            guard components.isValidDate(in: calendar) else { return nil }
            return calendar.date(from: components)
        }
        func month(_ y: Int, _ m: Int) -> Date? { day(y, m, 1) }
        func nextMonth(_ date: Date) -> Date { calendar.date(byAdding: .month, value: 1, to: date)! }
        func ints(_ match: [String]) -> [Int] { match.compactMap { Int($0) } }

        // Two ISO days.
        if let m = firstMatch(#"(?<!\d)(\d{4})-(\d{2})-(\d{2})(?!\d).*?(?<!\d)(\d{4})-(\d{2})-(\d{2})(?!\d)"#, in: text) {
            let v = ints(m)
            if let start = day(v[0], v[1], v[2]), let last = day(v[3], v[4], v[5]), start <= last {
                return DateInterval(start: start, end: PropertyDates.nextDay(last))
            }
        }
        // Two months, ISO or MM/YYYY.
        if let m = firstMatch(#"(?<![\d/-])(\d{4})-(\d{2})(?![\d/-]).*?(?<![\d/-])(\d{4})-(\d{2})(?![\d/-])"#, in: text) {
            let v = ints(m)
            if let start = month(v[0], v[1]), let last = month(v[2], v[3]), start <= last {
                return DateInterval(start: start, end: nextMonth(last))
            }
        }
        if let m = firstMatch(#"(?<![\d/])(\d{1,2})/(\d{4})(?![\d/]).*?(?<![\d/])(\d{1,2})/(\d{4})(?![\d/])"#, in: text) {
            let v = ints(m)
            if let start = month(v[1], v[0]), let last = month(v[3], v[2]), start <= last {
                return DateInterval(start: start, end: nextMonth(last))
            }
        }
        // One month.
        if let m = firstMatch(#"(?<![\d/-])(\d{4})-(\d{2})(?![\d/-])"#, in: text) {
            let v = ints(m)
            if let start = month(v[0], v[1]) { return DateInterval(start: start, end: nextMonth(start)) }
        }
        if let m = firstMatch(#"(?<![\d/])(\d{1,2})/(\d{4})(?![\d/])"#, in: text) {
            let v = ints(m)
            if let start = month(v[1], v[0]) { return DateInterval(start: start, end: nextMonth(start)) }
        }
        // A calendar year (not part of a longer number, e.g. a BBVA reference).
        if let m = firstMatch(#"(?<![\d/-])(20\d{2})(?![\d/-])"#, in: text), let year = Int(m[0]), let start = month(year, 1) {
            return DateInterval(start: start, end: month(year + 1, 1)!)
        }
        return nil
    }

    /// The capture groups of the first match.
    static func firstMatch(_ pattern: String, in text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range) else { return nil }
        return (1..<match.numberOfRanges).map { index in
            Range(match.range(at: index), in: text).map { String(text[$0]) } ?? ""
        }
    }
}
