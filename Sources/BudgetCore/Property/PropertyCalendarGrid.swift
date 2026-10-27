// Sources/BudgetCore/Property/PropertyCalendarGrid.swift
import Foundation

/// The property's obligations laid out for the iPad's Calendar (step 10, Task 15): an agenda grouped by month and a
/// month grid of whole weeks. Nothing is calculated here that the obligations don't already say: this only places them.
public enum PropertyCalendarGrid {
    /// One cell of the month grid.
    public struct GridDay: Equatable, Identifiable, Sendable {
        /// The day's first instant in the grid's calendar.
        public var date: Date
        /// Whether the day belongs to the month shown (false: a leading or trailing day of a neighbouring month).
        public var isInMonth: Bool
        /// What falls due that day, in date order.
        public var items: [PropertyObligation]
        public var id: Date { date }

        public init(date: Date, isInMonth: Bool, items: [PropertyObligation]) {
            self.date = date
            self.isInMonth = isInMonth
            self.items = items
        }
    }

    /// The weeks a month grid shows: always six, so the grid keeps its height from month to month.
    public static let weeks = 6

    /// The 42 days (6 whole weeks, the first on `calendar.firstWeekday`) that show `month`, each with the `items` due that
    /// day. Days before the month's first and after its last are flagged `isInMonth == false` (and still carry their items).
    public static func month(_ month: Date, items: [PropertyObligation], calendar: Calendar) -> [GridDay] {
        let first = calendar.dateInterval(of: .month, for: month)?.start ?? calendar.startOfDay(for: month)
        let weekday = calendar.component(.weekday, from: first)
        let lead = (weekday - calendar.firstWeekday + 7) % 7
        let start = calendar.date(byAdding: .day, value: -lead, to: first)!
        let byDay = Dictionary(grouping: items) { calendar.startOfDay(for: $0.date) }
        return (0..<(weeks * 7)).map { offset in
            let day = calendar.date(byAdding: .day, value: offset, to: start)!
            return GridDay(date: day, isInMonth: calendar.isDate(day, equalTo: first, toGranularity: .month),
                           items: (byDay[day] ?? []).sorted { ($0.date, $0.id) < ($1.date, $1.id) })
        }
    }

    /// A month of the agenda.
    public struct AgendaMonth: Equatable, Identifiable, Sendable {
        /// The month's first day.
        public var start: Date
        public var obligations: [PropertyObligation]
        public var id: Date { start }

        public var hasEstimates: Bool { obligations.contains { $0.isEstimate && $0.expectedMinorUnits != nil } }

        /// What's expected, added up by currency.
        public var totals: [(currency: Currency, minorUnits: Int)] {
            var sums: [Currency: Int] = [:]
            for obligation in obligations {
                guard let amount = obligation.expectedMinorUnits, let currency = obligation.currency else { continue }
                sums[currency, default: 0] += amount
            }
            return sums.keys.sorted { $0.rawValue < $1.rawValue }.map { (currency: $0, minorUnits: sums[$0]!) }
        }

        public static func == (lhs: AgendaMonth, rhs: AgendaMonth) -> Bool {
            lhs.start == rhs.start && lhs.obligations == rhs.obligations
        }
    }

    /// The obligations due from `today`'s month to the end of the month `months` months on, grouped by month in date order (a month with
    /// nothing due is left out). With `months` negative, the months back from today's (this one included), nearest first, are
    /// listed instead, the latest day first in each.
    public static func agenda(_ items: [PropertyObligation], from today: Date, months: Int = 12, calendar: Calendar) -> [AgendaMonth] {
        let thisMonth = calendar.dateInterval(of: .month, for: today)?.start ?? calendar.startOfDay(for: today)
        // Forward, through the end of the month `months` months on (so what a read of `months` months from `today` found is all here).
        let lastMonth = calendar.dateInterval(of: .month, for: calendar.date(byAdding: .month, value: max(months, 0), to: today)!)!
        let window = months >= 0
            ? DateInterval(start: thisMonth, end: lastMonth.end)
            : DateInterval(start: calendar.date(byAdding: .month, value: months, to: thisMonth)!,
                           end: calendar.date(byAdding: .month, value: 1, to: thisMonth)!)
        let inWindow = items.filter { $0.date >= window.start && $0.date < window.end }
        let grouped = Dictionary(grouping: inWindow) { calendar.dateInterval(of: .month, for: $0.date)?.start ?? $0.date }
        let sorted = grouped.keys.sorted()
        return (months >= 0 ? sorted : sorted.reversed()).map { start in
            let ordered = grouped[start]!.sorted { ($0.date, $0.id) < ($1.date, $1.id) }
            return AgendaMonth(start: start, obligations: months >= 0 ? ordered : ordered.reversed())
        }
    }
}
