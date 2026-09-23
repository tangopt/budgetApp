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

    /// Paydays closer together than this are treated as the same pay event (e.g. a
    /// salary split into two payments, or two salary-sized credits on one day).
    /// Matches the lower bound of the plausible-interval filter in `detectCadence`.
    static let minimumPaydayGapDays = 20
    private static let maxProjectedPeriods = 600

    /// Sorts payday dates and collapses any date falling fewer than
    /// `minimumPaydayGapDays` days after the previously kept payday (which also
    /// removes exact same-day duplicates). Guarantees every returned date is a
    /// distinct period start with a strictly positive period length, so callers
    /// can rely on `startDate` being unique (e.g. as a SwiftUI `ForEach` id).
    /// Original `Date` values are kept unchanged (no start-of-day normalisation).
    public static func paydayAnchors(_ incomeDates: [Date]) -> [Date] {
        var anchors: [Date] = []
        for date in incomeDates.sorted() {
            if let previous = anchors.last {
                let gap = calendar.dateComponents([.day], from: previous, to: date).day ?? 0
                if gap < minimumPaydayGapDays { continue }
            }
            anchors.append(date)
        }
        return anchors
    }

    /// Requires at least 2 distinct paydays to establish an interval.
    /// Tolerates weekend/bank-holiday shifts of a few days either side of a ~30-day cadence.
    public static func detectCadence(incomeDates: [Date]) -> PayCadence? {
        let sorted = paydayAnchors(incomeDates)
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
        let sorted = paydayAnchors(incomeDates)
        guard sorted.count >= 2 else { return [] }

        var periods: [PayPeriod] = []
        for i in 0..<(sorted.count - 1) {
            let start = sorted[i]
            let nextStart = sorted[i + 1]
            let end = calendar.date(byAdding: .day, value: -1, to: nextStart)!
            periods.append(PayPeriod(startDate: start, endDate: end, type: .actual))
        }
        // The most recent period is still open; it runs until the day before the next
        // expected payday (same day-of-month next month), which is exactly where the
        // first projected period from `generateProjectedPeriods` starts.
        if detectCadence(incomeDates: sorted) != nil {
            let start = sorted.last!
            let nextPayday = calendar.date(byAdding: .month, value: 1, to: start)!
            let end = calendar.date(byAdding: .day, value: -1, to: nextPayday)!
            periods.append(PayPeriod(startDate: start, endDate: end, type: .actual))
        }
        return periods
    }

    /// Extrapolates paydays forward by calendar month, keeping the same day-of-month as
    /// `cadence.lastPayDate` (per spec), rather than stepping a fixed number of days —
    /// fixed-day steps drift across short/long months and made monthly forecast entries
    /// occasionally fire twice or not at all within a period.
    ///
    /// Each payday is computed from the anchor (anchor + n months) rather than from the
    /// previous projected payday, so an anchor on the 31st yields 28 Feb then 31 Mar,
    /// not 28 Feb then 28 Mar forever after.
    public static func generateProjectedPeriods(cadence: PayCadence, horizon: Date) -> [PayPeriod] {
        var periods: [PayPeriod] = []
        let anchor = cadence.lastPayDate
        for monthOffset in 1...maxProjectedPeriods {
            guard let start = calendar.date(byAdding: .month, value: monthOffset, to: anchor),
                  let nextStart = calendar.date(byAdding: .month, value: monthOffset + 1, to: anchor) else { break }
            // Stop once this period's start would fall past the horizon.
            guard start <= horizon else { break }
            let end = calendar.date(byAdding: .day, value: -1, to: nextStart)!
            periods.append(PayPeriod(startDate: start, endDate: end, type: .projected))
        }
        return periods
    }

    /// Convenience: actual periods from the payday history plus projected periods
    /// through `horizon` (when a cadence can be detected).
    public static func allPeriods(incomeDates: [Date], horizon: Date) -> [PayPeriod] {
        var periods = generateActualPeriods(incomeDates: incomeDates)
        if let cadence = detectCadence(incomeDates: incomeDates) {
            periods += generateProjectedPeriods(cadence: cadence, horizon: horizon)
        }
        return periods
    }
}
