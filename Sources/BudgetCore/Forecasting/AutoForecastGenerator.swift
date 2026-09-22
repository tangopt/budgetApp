// Sources/BudgetCore/Forecasting/AutoForecastGenerator.swift
import GRDB
import Foundation

public enum AutoForecastGenerator {
    private static let detectedRecurringGroupName = "Detected recurring"

    @discardableResult
    public static func ensureDetectedRecurringGroup(db: Database) throws -> ForecastGroup {
        if let existing = try ForecastGroup.filter(Column("name") == detectedRecurringGroupName).fetchOne(db) {
            return existing
        }
        var group = ForecastGroup(name: detectedRecurringGroupName, note: "Auto-detected from transaction history", isEnabled: true, isSystemManaged: true)
        try group.insert(db)
        return group
    }

    /// Buckets confirmed expense/transfer/income transactions into `actualPeriods`,
    /// sums per category per period, and creates or refreshes an `auto`-status
    /// ForecastEntry per category in the "Detected recurring" group. Entries whose
    /// status has been changed away from `.auto` (i.e. the user tuned them) are left untouched.
    public static func regenerate(db: Database, actualPeriods: [PayPeriod]) throws {
        guard !actualPeriods.isEmpty else { return }
        let group = try ensureDetectedRecurringGroup(db: db)
        let sortedPeriods = actualPeriods.sorted { $0.startDate < $1.startDate }
        let categories = try Category.filter(Column("type") != CategoryType.transfer.rawValue || Column("type") == CategoryType.transfer.rawValue).fetchAll(db)

        for category in categories {
            var perPeriodSums: [Int] = []
            for period in sortedPeriods {
                let sum = try Int.fetchOne(db, sql: """
                    SELECT COALESCE(SUM(amountMinorUnits), 0) FROM transaction_
                    WHERE categoryId = ? AND status = 'confirmed' AND date >= ? AND date <= ?
                    """, arguments: [category.id!, period.startDate, period.endDate]) ?? 0
                if sum != 0 { perPeriodSums.append(abs(sum)) }
            }
            guard perPeriodSums.count >= 2 else { continue }

            let mean = Double(perPeriodSums.reduce(0, +)) / Double(perPeriodSums.count)
            let variance = perPeriodSums.reduce(0.0) { $0 + pow(Double($1) - mean, 2) } / Double(perPeriodSums.count)
            let relativeStdDev = mean == 0 ? 0 : sqrt(variance) / mean
            let isFixed = relativeStdDev < 0.15

            let forecastAmount = isFixed ? perPeriodSums.last! : Int(mean.rounded())
            let signedAmount = category.type == .income ? forecastAmount : -forecastAmount
            let nextPeriodStart = sortedPeriods.last!.startDate

            if var existing = try ForecastEntry
                .filter(Column("categoryId") == category.id! && Column("groupId") == group.id!)
                .fetchOne(db) {
                guard existing.status == .auto else { continue } // respect manual tuning
                existing.amountMinorUnits = signedAmount
                try existing.update(db)
            } else {
                var entry = ForecastEntry(
                    groupId: group.id!, categoryId: category.id!, amountMinorUnits: signedAmount,
                    frequency: .monthly, interval: 1, startDate: nextPeriodStart, endDate: nil,
                    isEnabled: true, status: .auto, note: nil
                )
                try entry.insert(db)
            }
        }
    }
}
