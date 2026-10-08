// Sources/BudgetCore/Forecasting/RecurrenceEnd.swift
import Foundation

/// Turns "ends after N occurrences" into the end date the forecast entries store.
public enum RecurrenceEnd {
    private static let calendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }()

    /// The date of the Nth occurrence (N >= 1). N = 1 and `.once` give `start`.
    public static func endDate(start: Date, frequency: ForecastFrequency, interval: Int, anchorDay: Int?, occurrences: Int) -> Date {
        guard frequency != .once, occurrences > 1 else { return start }
        let step = max(interval, 1)
        let unit: Calendar.Component
        switch frequency {
        case .weekly: unit = .day
        case .monthly: unit = .month
        case .annually: unit = .year
        case .once: return start
        }
        let stepValue = frequency == .weekly ? step * 7 : step
        // One extra step of slack so the Nth occurrence is always inside the period.
        guard let limit = calendar.date(byAdding: unit, value: stepValue * (occurrences + 1), to: start) else { return start }
        let entry = ForecastEntry(groupId: 0, categoryId: 0, amountMinorUnits: 0, frequency: frequency, interval: step, startDate: start, endDate: nil, isEnabled: true, status: .manual, note: nil, anchorDay: anchorDay)
        let dates = FrequencyExpander.occurrences(for: entry, in: PayPeriod(startDate: start, endDate: limit, type: .projected))
        assert(dates.count >= occurrences, "RecurrenceEnd: expected \(occurrences) occurrences, generated \(dates.count)")
        return dates.count >= occurrences ? dates[occurrences - 1] : (dates.last ?? start)
    }
}
