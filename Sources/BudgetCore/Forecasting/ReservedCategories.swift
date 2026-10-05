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
