// Sources/BudgetCore/Forecasting/FrequencyExpander.swift
import Foundation

public enum FrequencyExpander {
    private static let calendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }()
    private static let maxIterations = 2000

    public static func occurrences(for entry: ForecastEntry, in period: PayPeriod) -> [Date] {
        guard entry.startDate <= period.endDate else { return [] }
        if let endDate = entry.endDate, endDate < period.startDate { return [] }

        var results: [Date] = []

        if entry.frequency == .once {
            if entry.startDate >= period.startDate && entry.startDate <= period.endDate {
                results.append(entry.startDate)
            }
            return results
        }

        let component: Calendar.Component
        switch entry.frequency {
        case .weekly: component = .day
        case .monthly: component = .month
        case .annually: component = .year
        case .once: return results // handled above
        }
        let stepValue = entry.frequency == .weekly ? entry.interval * 7 : entry.interval

        // Each occurrence is computed from startDate (start + n steps), not from the
        // previous occurrence: stepping iteratively drifts month-end dates permanently
        // (31 Jan → 28 Feb → 28 Mar …), which then double-fires or skips against pay
        // periods that are themselves anchored to a fixed day-of-month.
        var cursor = entry.startDate
        var stepIndex = 0
        while cursor <= period.endDate && stepIndex < maxIterations {
            if let entryEnd = entry.endDate, cursor > entryEnd { break }
            if cursor >= period.startDate && cursor <= period.endDate {
                results.append(cursor)
            }
            stepIndex += 1
            guard let next = calendar.date(byAdding: component, value: stepValue * stepIndex, to: entry.startDate) else { break }
            cursor = next
        }
        return results
    }

    public static func amount(for entry: ForecastEntry, in period: PayPeriod) -> Int {
        occurrences(for: entry, in: period).count * entry.amountMinorUnits
    }
}
