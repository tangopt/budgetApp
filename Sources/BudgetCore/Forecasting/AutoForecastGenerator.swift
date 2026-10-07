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
    /// pay periods from salary paydays (see `PaydaySource`) and adds planned items for
    /// newly detected recurring categories (see `regenerate`). Called after every committed
    /// import. No-op until at least two paydays exist.
    public static func refresh(db: Database) throws {
        let paydays = try PaydaySource.paydayDates(db: db)
        let actualPeriods = PayPeriodDetector.generateActualPeriods(incomeDates: paydays)
        try regenerate(db: db, actualPeriods: actualPeriods)
    }

    /// Buckets confirmed transactions into `actualPeriods`, sums per category per
    /// period (signed), and — for a category with no planned item at all (no
    /// non-hypothetical entry in any group, enabled or not) — adds one ordinary planned
    /// item (status `.manual`) in the "Detected recurring" group according to
    /// `detectRecurrence`. Detection only ever adds: once a category has a plan, the user
    /// owns it, so existing entries are never updated or deleted. Reserves and categories
    /// excluded from the auto-forecast are skipped.
    public static func regenerate(db: Database, actualPeriods: [PayPeriod]) throws {
        guard !actualPeriods.isEmpty else { return }
        let group = try ensureDetectedRecurringGroup(db: db)
        let sortedPeriods = actualPeriods.sorted { $0.startDate < $1.startDate }
        let categories = try Category.fetchAll(db)
        let plannedCategoryIds = Set(try Int64.fetchAll(db, sql: """
            SELECT DISTINCT categoryId FROM forecastEntry WHERE status != ?
            """, arguments: [ForecastEntryStatus.hypothetical.rawValue]))

        for category in categories {
            guard let categoryId = category.id else { continue }
            // Reserves and categories maintained by hand keep whatever entries the user has.
            if category.isReserved || category.excludeFromAutoForecast { continue }
            if plannedCategoryIds.contains(categoryId) { continue }
            var perPeriodSums: [Int] = []
            for period in sortedPeriods {
                let sum = try Int.fetchOne(db, sql: """
                    SELECT COALESCE(SUM(amountMinorUnits), 0) FROM transaction_
                    WHERE categoryId = ? AND status = 'confirmed' AND date >= ? AND date <= ?
                    """, arguments: [categoryId, period.startDate, period.endDate]) ?? 0
                perPeriodSums.append(sum)
            }
            guard let recurrence = detectRecurrence(perPeriodSums: perPeriodSums) else { continue }

            let startDate: Date
            switch recurrence.anchor {
            case .lastPeriodStart:
                startDate = sortedPeriods.last!.startDate
            case .lastTransactionDate:
                startDate = try Date.fetchOne(db, sql: """
                    SELECT MAX(date) FROM transaction_ WHERE categoryId = ? AND status = 'confirmed'
                    """, arguments: [categoryId]) ?? sortedPeriods.last!.startDate
            }
            var entry = ForecastEntry(
                groupId: group.id!, categoryId: categoryId, amountMinorUnits: recurrence.amountMinorUnits,
                frequency: recurrence.frequency, interval: recurrence.interval, startDate: startDate, endDate: nil,
                isEnabled: true, status: .manual, note: nil
            )
            try entry.insert(db)
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
