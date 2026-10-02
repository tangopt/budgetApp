// Sources/BudgetCore/Forecasting/CatchAllCategory.swift
import GRDB

public enum CatchAllError: Error, Equatable {
    case notAnExpenseCategory
}

public enum CatchAllCategory {
    /// Marks `categoryId` as THE catch-all expense category: clears the flag on every
    /// other category and promotes this category's `.auto` forecast entries to `.manual`
    /// so the amount sticks (the auto-forecast also skips catch-all categories entirely).
    public static func designate(db: Database, categoryId: Int64) throws {
        guard let category = try Category.fetchOne(db, key: categoryId), category.type == .expense else {
            throw CatchAllError.notAnExpenseCategory
        }
        try db.execute(sql: "UPDATE category SET isCatchAll = 0 WHERE isCatchAll = 1 AND id != ?", arguments: [categoryId])
        try db.execute(sql: "UPDATE category SET isCatchAll = 1 WHERE id = ?", arguments: [categoryId])
        try db.execute(sql: "UPDATE forecastEntry SET status = 'manual' WHERE categoryId = ? AND status = 'auto'", arguments: [categoryId])
    }

    public static func clear(db: Database, categoryId: Int64) throws {
        try db.execute(sql: "UPDATE category SET isCatchAll = 0 WHERE id = ?", arguments: [categoryId])
    }
}
