// Sources/BudgetCore/Forecasting/ReservedCategories.swift
import Foundation
import GRDB

public enum ReservedCategoryError: Error, Equatable {
    case emptyName
    case duplicateName
    case notReserved
}

/// Reserved categories: forecast-only expense buckets for expected but uncategorised
/// spending (e.g. the spreadsheet's "Remaining for expenses"). Their allowances are
/// ordinary forecast entries, kept in the "Reserved" group.
public enum ReservedCategories {
    public static let groupName = "Reserved"

    public static func create(db: Database, name: String) throws -> Category {
        let trimmed = try validatedName(db: db, name)
        var category = Category(name: trimmed, type: .expense, isReserved: true)
        try category.insert(db)
        return category
    }

    @discardableResult
    public static func ensureGroup(db: Database) throws -> ForecastGroup {
        if let existing = try ForecastGroup.filter(Column("name") == groupName).fetchOne(db) {
            return existing
        }
        var group = ForecastGroup(name: groupName, note: "Allowances for expected but uncategorised spending", isEnabled: true, isSystemManaged: false)
        try group.insert(db)
        return group
    }

    public static func rename(db: Database, categoryId: Int64, to name: String) throws {
        var category = try reserve(db: db, categoryId)
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != category.name else { return }
        category.name = try validatedName(db: db, name)
        try category.update(db, columns: ["name"])
    }

    /// Deletes the reserve and every forecast entry for it. Safe because a reserve never
    /// has transactions or rules.
    public static func delete(db: Database, categoryId: Int64) throws {
        let category = try reserve(db: db, categoryId)
        try ForecastEntry.filter(Column("categoryId") == categoryId).deleteAll(db)
        try category.delete(db)
    }

    /// Turning the flag on deletes the category's `.auto` entries (manual, confirmed and
    /// hypothetical entries are kept). Returns how many entries were deleted.
    @discardableResult
    public static func setExcludedFromAutoForecast(db: Database, categoryId: Int64, _ excluded: Bool) throws -> Int {
        try db.execute(sql: "UPDATE category SET excludeFromAutoForecast = ? WHERE id = ?", arguments: [excluded, categoryId])
        guard excluded else { return 0 }
        return try ForecastEntry
            .filter(Column("categoryId") == categoryId && Column("status") == ForecastEntryStatus.auto.rawValue)
            .deleteAll(db)
    }

    /// Grids (which have no blended month): a reserve's allowance counts from the current
    /// calendar month on; earlier months show nothing.
    public static func countsAllowance(year: Int, month: Int, today: Date) -> Bool {
        let now = MonthRange.components(of: today)
        return MonthRange.index(year: year, month: month) >= MonthRange.index(year: now.year, month: now.month)
    }

    /// What a month's reserves lose to spending nobody planned for: the confirmed spend in
    /// the calendar month across expense categories (not reserves) with nothing forecast
    /// that month. Net signed sum, so refunds reduce it; returned as a positive magnitude,
    /// never below 0. Unreviewed transactions aren't in `calendarTotals`, so never count.
    public static func unforecastSpend(year: Int, month: Int, categories: [Category], calendarTotals: [Int64: [Int: [Int: Int]]], entries: [ForecastEntry], groups: [ForecastGroup]) -> Int {
        let range = MonthRange.of(year: year, month: month)
        let period = PayPeriod(startDate: range.start, endDate: range.end, type: .projected)
        var net = 0
        for category in categories where category.type == .expense && !category.isReserved {
            guard let categoryId = category.id, let actual = calendarTotals[categoryId]?[year]?[month], actual != 0 else { continue }
            guard ForecastCalculator.confirmedTotal(categoryId: categoryId, period: period, entries: entries, groups: groups) == 0 else { continue }
            net += actual
        }
        return max(0, -net)
    }

    /// Each reserve's allowance (signed, negative) reduced by `unforecastSpend` (positive),
    /// absorbed in name order: the first reserve takes the spend until it reaches 0, then
    /// the next. Every result lies in `allowance...0`.
    public static func remainingAllowances(_ reserves: [(id: Int64, name: String, allowance: Int)], unforecastSpend: Int) -> [Int64: Int] {
        var left = max(0, unforecastSpend)
        var result: [Int64: Int] = [:]
        for reserve in reserves.sorted(by: { $0.name < $1.name }) {
            let absorbed = min(left, max(0, -reserve.allowance))
            result[reserve.id] = reserve.allowance + absorbed
            left -= absorbed
        }
        return result
    }

    private static func reserve(db: Database, _ categoryId: Int64) throws -> Category {
        guard let category = try Category.fetchOne(db, key: categoryId), category.isReserved else {
            throw ReservedCategoryError.notReserved
        }
        return category
    }

    private static func validatedName(db: Database, _ name: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ReservedCategoryError.emptyName }
        guard try Category.filter(Column("name") == trimmed).fetchCount(db) == 0 else {
            throw ReservedCategoryError.duplicateName
        }
        return trimmed
    }
}
