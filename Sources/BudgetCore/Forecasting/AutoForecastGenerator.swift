// Sources/BudgetCore/Forecasting/AutoForecastGenerator.swift
import GRDB
import Foundation

/// A recurrence detected from a category's per-pay-period actuals.
public struct DetectedRecurrence: Equatable {
    public let amountMinorUnits: Int
    public let frequency: ForecastFrequency
    public let interval: Int
    /// `.lastPeriodStart` anchors monthly entries on the latest period start (so they
    /// fire once per month-stepped projected period); sparse entries anchor on the
    /// category's most recent transaction date so they recur on the right date.
    public let anchor: Anchor

    public enum Anchor: Equatable {
        case lastPeriodStart
        case lastTransactionDate
    }
}

public enum AutoForecastGenerator {
    private static let detectedRecurringGroupName = "Detected recurring"
    private static let fixedAmountRelativeStdDev = 0.15

    @discardableResult
    public static func ensureDetectedRecurringGroup(db: Database) throws -> ForecastGroup {
        if let existing = try ForecastGroup.filter(Column("name") == detectedRecurringGroupName).fetchOne(db) {
            return existing
        }
        var group = ForecastGroup(name: detectedRecurringGroupName, note: "Auto-detected from transaction history", isEnabled: true, isSystemManaged: true)
        try group.insert(db)
        return group
    }

    /// Recomputes the default forecast from everything in the database: derives actual
    /// pay periods from salary paydays (see `PaydaySource`) and regenerates the
    /// "Detected recurring" group. Called after every committed import so forecasts
    /// refresh whenever new actuals land. No-op until at least two paydays exist.
    public static func refresh(db: Database) throws {
        let paydays = try PaydaySource.paydayDates(db: db)
        let actualPeriods = PayPeriodDetector.generateActualPeriods(incomeDates: paydays)
        try regenerate(db: db, actualPeriods: actualPeriods)
    }

    /// Buckets confirmed transactions into `actualPeriods`, sums per category per
    /// period (signed), and creates, refreshes or removes an `auto`-status
    /// ForecastEntry per category in the "Detected recurring" group, according to
    /// `detectRecurrence`. Entries whose status has been changed away from `.auto`
    /// (i.e. the user tuned them) are left untouched.
    public static func regenerate(db: Database, actualPeriods: [PayPeriod]) throws {
        guard !actualPeriods.isEmpty else { return }
        let group = try ensureDetectedRecurringGroup(db: db)
        let sortedPeriods = actualPeriods.sorted { $0.startDate < $1.startDate }
        let categories = try Category.fetchAll(db)

        for category in categories {
            guard let categoryId = category.id else { continue }
            var perPeriodSums: [Int] = []
            for period in sortedPeriods {
                let sum = try Int.fetchOne(db, sql: """
                    SELECT COALESCE(SUM(amountMinorUnits), 0) FROM transaction_
                    WHERE categoryId = ? AND status = 'confirmed' AND date >= ? AND date <= ?
                    """, arguments: [categoryId, period.startDate, period.endDate]) ?? 0
                perPeriodSums.append(sum)
            }

            let existing = try ForecastEntry
                .filter(Column("categoryId") == categoryId && Column("groupId") == group.id!)
                .fetchOne(db)
            if let existing, existing.status != .auto { continue } // respect manual tuning

            guard let recurrence = detectRecurrence(perPeriodSums: perPeriodSums) else {
                // No clear pattern (any more): drop a stale auto entry rather than keep
                // forecasting it, e.g. a one-off purchase that briefly looked monthly.
                if let existing { try existing.delete(db) }
                continue
            }

            let startDate: Date
            switch recurrence.anchor {
            case .lastPeriodStart:
                startDate = sortedPeriods.last!.startDate
            case .lastTransactionDate:
                startDate = try Date.fetchOne(db, sql: """
                    SELECT MAX(date) FROM transaction_ WHERE categoryId = ? AND status = 'confirmed'
                    """, arguments: [categoryId]) ?? sortedPeriods.last!.startDate
            }

            if var existing {
                existing.amountMinorUnits = recurrence.amountMinorUnits
                existing.frequency = recurrence.frequency
                existing.interval = recurrence.interval
                existing.startDate = startDate
                try existing.update(db)
            } else {
                var entry = ForecastEntry(
                    groupId: group.id!, categoryId: categoryId, amountMinorUnits: recurrence.amountMinorUnits,
                    frequency: recurrence.frequency, interval: recurrence.interval, startDate: startDate, endDate: nil,
                    isEnabled: true, status: .auto, note: nil
                )
                try entry.insert(db)
            }
        }
    }

    /// Classifies a category's signed per-period sums (one per actual pay period, in
    /// order, zeros included). Deliberately simple:
    ///
    /// - **Monthly** — activity in every period, allowing one gap (typically the still-
    ///   open current period where the bill isn't due yet, or a bill that slipped into
    ///   the neighbouring period). Amount = last actual if near-identical
    ///   (relative std-dev < 15%), otherwise the mean of the active periods.
    /// - **Every N periods** — sparser activity whose gaps (in pay periods) are all
    ///   within ±1 of a common N ≥ 2. Needs ≥ 3 occurrences (two agreeing gaps) for
    ///   N < 11; for N in 11...13 (annual: TV licence, car tax, insurance) two
    ///   occurrences a year apart suffice, since more history is rarely available.
    ///   Amount = the most recent occurrence (latest renewal price).
    /// - **Otherwise nil** — no auto-forecast. Previously every category with ≥ 2
    ///   active periods was forecast monthly at the mean of its non-zero periods, so an
    ///   annual bill was projected every month.
    public static func detectRecurrence(perPeriodSums sums: [Int]) -> DetectedRecurrence? {
        let activeIndices = sums.indices.filter { sums[$0] != 0 }
        guard activeIndices.count >= 2 else { return nil }
        let activeSums = activeIndices.map { sums[$0] }

        if activeIndices.count >= sums.count - 1 {
            let mean = Double(activeSums.reduce(0, +)) / Double(activeSums.count)
            let variance = activeSums.reduce(0.0) { $0 + pow(Double($1) - mean, 2) } / Double(activeSums.count)
            let relativeStdDev = mean == 0 ? .infinity : sqrt(variance) / abs(mean)
            let amount = relativeStdDev < fixedAmountRelativeStdDev ? activeSums.last! : Int(mean.rounded())
            guard amount != 0 else { return nil }
            return DetectedRecurrence(amountMinorUnits: amount, frequency: .monthly, interval: 1, anchor: .lastPeriodStart)
        }

        let gaps = zip(activeIndices, activeIndices.dropFirst()).map { $1 - $0 }
        let typicalGap = Int((Double(gaps.reduce(0, +)) / Double(gaps.count)).rounded())
        guard typicalGap >= 2, gaps.allSatisfy({ abs($0 - typicalGap) <= 1 }) else { return nil }

        if (11...13).contains(typicalGap) {
            return DetectedRecurrence(amountMinorUnits: activeSums.last!, frequency: .annually, interval: 1, anchor: .lastTransactionDate)
        }
        guard activeIndices.count >= 3 else { return nil }
        return DetectedRecurrence(amountMinorUnits: activeSums.last!, frequency: .monthly, interval: typicalGap, anchor: .lastTransactionDate)
    }
}
