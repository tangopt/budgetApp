// Sources/BudgetCore/Budget/BudgetGridExporter.swift
import Foundation

/// CSV of the Budget grid's actuals: one column per pay month (spec 2026-10-05-pay-months:
/// "one definition of month for actual flows"), with the same per-category totals the grid
/// shows (`PayMonthTotals.lookup`). Covers every year the grid offers, up to the pay month
/// in progress; months that haven't started yet have no actuals and are left out.
public enum BudgetGridExporter {
    private static let labelFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_GB")
        formatter.dateFormat = "MMMM yyyy"
        return formatter
    }()

    /// "September 2026" — the pay month's name, as on the grid's column header.
    static func label(_ month: PayMonth) -> String {
        labelFormatter.string(from: MonthRange.of(year: month.year, month: month.month).start)
    }

    /// The pay months exported for `years`: every month that has started (actual or blended).
    public static func months(years: [Int], calendar: PayCalendar) -> [PayMonth] {
        years.sorted().flatMap { year in (1...12).map { PayMonth(year: year, month: $0) } }
            .filter { calendar.monthClass($0) != .forecast }
    }

    /// - Parameters:
    ///   - years: the grid's years (`BudgetGridCalculator.yearsWithData`).
    ///   - monthTotals: `PayMonthTotals.lookup` for the same calendar.
    public static func export(categories: [Category], years: [Int], calendar: PayCalendar, monthTotals: [Int64: [Int: [Int: Int]]]) -> String {
        let columns = months(years: years, calendar: calendar)
        var lines = ["Category," + columns.map { csvField(label($0)) }.joined(separator: ",")]
        for category in categories {
            let values = columns.map { month -> String in
                let total = category.id.flatMap { monthTotals[$0]?[month.year]?[month.month] } ?? 0
                return String(format: "%.2f", Double(total) / 100.0)
            }
            lines.append(([csvField(category.name)] + values).joined(separator: ","))
        }
        return lines.joined(separator: "\n")
    }

    /// Convenience: builds the totals from `transactions` and the years from the calendar.
    public static func export(categories: [Category], transactions: [Transaction], calendar: PayCalendar) -> String {
        export(categories: categories,
               years: BudgetGridCalculator.yearsWithData(transactions: transactions, calendar: calendar),
               calendar: calendar,
               monthTotals: PayMonthTotals.lookup(transactions: transactions, calendar: calendar))
    }

    private static func csvField(_ text: String) -> String {
        guard text.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" }) else { return text }
        return "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
