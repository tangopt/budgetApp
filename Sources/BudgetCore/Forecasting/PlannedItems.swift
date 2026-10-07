// Sources/BudgetCore/Forecasting/PlannedItems.swift
import Foundation
import GRDB

public enum PlannedItemsError: Error, Equatable {
    case categoryNotFound
    /// Reserves get allowances through `ReservedCategories`, not planned items.
    case reservedCategory
    /// A new category's name is blank, or another category already has it.
    case emptyCategoryName
    case duplicateCategoryName
    /// A scenario add needs the "Planned" group enabled: it never switches the budget's group on.
    case plannedGroupDisabled
}

/// Confirmed forecast items the user adds by hand from the Budget grid's Income /
/// Expenses / Transfers headers. Kept in the "Planned" group.
public enum PlannedItems {
    public static let groupName = "Planned"

    /// Adds a confirmed entry to the "Planned" group (created on first use). It adds to
    /// whatever the category already has planned — existing items (including "Detected
    /// recurring" ones) are kept, since two items in one category can be intended; the add
    /// sheet shows what's already planned so the user can tell. A recurring item also sets
    /// the category's `excludeFromAutoForecast`, which only stops future detection adding
    /// another series for it. A one-off (`.once`) item (e.g. a bonus on top of the salary)
    /// leaves the flag alone.
    ///
    /// With a `scenarioId` the item goes into that scenario instead, marked `added`; the
    /// budget and the category's flags are left alone: the "Planned" group is created if
    /// missing but never switched on (a disabled one throws `plannedGroupDisabled`).
    @discardableResult
    public static func add(db: Database, categoryId: Int64, amountMinorUnits: Int, frequency: ForecastFrequency, interval: Int, startDate: Date, endDate: Date?, scenarioId: Int64? = nil) throws -> ForecastEntry {
        guard let category = try Category.fetchOne(db, key: categoryId) else { throw PlannedItemsError.categoryNotFound }
        guard !category.isReserved else { throw PlannedItemsError.reservedCategory }
        let group = scenarioId == nil ? try ensureGroup(db: db) : try existingOrNewGroup(db: db)
        var entry = ForecastEntry(groupId: group.id!, categoryId: categoryId, amountMinorUnits: amountMinorUnits, frequency: frequency, interval: interval, startDate: startDate, endDate: endDate, isEnabled: true, status: .confirmed, note: nil,
                                  scenarioId: scenarioId, scenarioChange: scenarioId == nil ? nil : .added)
        try entry.insert(db)
        if frequency != .once && scenarioId == nil {
            try ReservedCategories.setExcludedFromAutoForecast(db: db, categoryId: categoryId, true)
        }
        return entry
    }

    /// `add` for a category created on the spot ("+ New category…"): a non-reserved category
    /// of `type` named `categoryName` (trimmed), then the item. Call it inside one write, so
    /// a failed add leaves no orphaned category behind.
    @discardableResult
    public static func add(db: Database, newCategoryName categoryName: String, type: CategoryType, amountMinorUnits: Int, frequency: ForecastFrequency, interval: Int, startDate: Date, endDate: Date?, scenarioId: Int64? = nil) throws -> (category: Category, entry: ForecastEntry) {
        let trimmed = categoryName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw PlannedItemsError.emptyCategoryName }
        guard try Category.filter(Column("name") == trimmed).fetchCount(db) == 0 else { throw PlannedItemsError.duplicateCategoryName }
        var category = Category(name: trimmed, type: type)
        try category.insert(db)
        let entry = try add(db: db, categoryId: category.id!, amountMinorUnits: amountMinorUnits, frequency: frequency, interval: interval, startDate: startDate, endDate: endDate, scenarioId: scenarioId)
        return (category, entry)
    }

    /// The "Planned" group for a scenario add: created when missing, but a disabled one is
    /// left as it is (switching it on would change the budget) and refused.
    private static func existingOrNewGroup(db: Database) throws -> ForecastGroup {
        guard let existing = try ForecastGroup.filter(Column("name") == groupName).fetchOne(db) else { return try ensureGroup(db: db) }
        guard existing.isEnabled else { throw PlannedItemsError.plannedGroupDisabled }
        return existing
    }

    /// The "Planned" group, created on first use. A group the user switched off is switched
    /// back on: a confirmed item in a disabled group would silently count for nothing.
    @discardableResult
    static func ensureGroup(db: Database) throws -> ForecastGroup {
        if var existing = try ForecastGroup.filter(Column("name") == groupName).fetchOne(db) {
            if !existing.isEnabled {
                existing.isEnabled = true
                try existing.update(db, columns: ["isEnabled"])
            }
            return existing
        }
        var group = ForecastGroup(name: groupName, note: "Confirmed items added from the Budget grid", isEnabled: true, isSystemManaged: false)
        try group.insert(db)
        return group
    }
}
