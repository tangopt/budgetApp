// Sources/BudgetCore/PayPeriods/PayPeriodDetector.swift
import Foundation

public struct PayCadence: Equatable {
    public let averageIntervalDays: Double
    public let lastPayDate: Date

    public init(averageIntervalDays: Double, lastPayDate: Date) {
        self.averageIntervalDays = averageIntervalDays
        self.lastPayDate = lastPayDate
    }
}

public enum PayPeriodDetector {
    private static let calendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }()

    /// Requires at least 2 income dates to establish an interval.
    /// Tolerates weekend/bank-holiday shifts of a few days either side of a ~30-day cadence.
    public static func detectCadence(incomeDates: [Date]) -> PayCadence? {
        let sorted = incomeDates.sorted()
        guard sorted.count >= 2 else { return nil }

        let intervals: [Double] = zip(sorted, sorted.dropFirst()).map { earlier, later in
            Double(calendar.dateComponents([.day], from: earlier, to: later).day ?? 0)
        }
        // Only consider intervals that look like "one pay period" (20-45 days),
        // to avoid a missed month (≈60 days) skewing the average.
        let plausibleIntervals = intervals.filter { $0 >= 20 && $0 <= 45 }
        guard !plausibleIntervals.isEmpty else { return nil }

        let average = plausibleIntervals.reduce(0, +) / Double(plausibleIntervals.count)
        return PayCadence(averageIntervalDays: average, lastPayDate: sorted.last!)
    }

    public static func generateActualPeriods(incomeDates: [Date]) -> [PayPeriod] {
        let sorted = incomeDates.sorted()
        guard sorted.count >= 2 else { return [] }

        var periods: [PayPeriod] = []
        for i in 0..<(sorted.count - 1) {
            let start = sorted[i]
            let nextStart = sorted[i + 1]
            let end = calendar.date(byAdding: .day, value: -1, to: nextStart)!
            periods.append(PayPeriod(startDate: start, endDate: end, type: .actual))
        }
        // The most recent period is still open; estimate its end from the detected cadence.
        if let cadence = detectCadence(incomeDates: sorted) {
            let start = sorted.last!
            let end = calendar.date(byAdding: .day, value: Int(cadence.averageIntervalDays.rounded()) - 1, to: start)!
            periods.append(PayPeriod(startDate: start, endDate: end, type: .actual))
        }
        return periods
    }

    public static func generateProjectedPeriods(cadence: PayCadence, horizon: Date) -> [PayPeriod] {
        var periods: [PayPeriod] = []
        var cursor = cadence.lastPayDate
        let intervalDays = Int(cadence.averageIntervalDays.rounded())
        while true {
            guard let nextStart = calendar.date(byAdding: .day, value: intervalDays, to: cursor) else { break }
            // Stop once the *next* period's start would fall past the horizon, rather than
            // checking the previous cursor — checking cursor here would let one extra period
            // slip through whose start (and end) land up to a full interval beyond horizon.
            guard nextStart <= horizon else { break }
            let end = calendar.date(byAdding: .day, value: intervalDays - 1, to: nextStart)!
            periods.append(PayPeriod(startDate: nextStart, endDate: end, type: .projected))
            cursor = nextStart
        }
        return periods
    }
}
