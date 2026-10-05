// Sources/BudgetCore/Forecasting/PlannedItems.swift
import Foundation
import GRDB

public enum PlannedItemsError: Error, Equatable {
    case categoryNotFound
    /// Reserves get allowances through `ReservedCategories`, not planned items.
    case reservedCategory
}

/// Confirmed forecast items the user adds by hand from the Forecast grid's Income /
/// Expenses / Transfers headers. Kept in the "Planned" group.
public enum PlannedItems {
    public static let groupName = "Planned"

    /// Adds a confirmed entry to the "Planned" group (created on first use). A recurring
    /// item also excludes the category from the auto-forecast so it can't add a duplicate —
    /// which deletes the category's existing `.auto` entries. A one-off (`.once`) item adds
    /// on top of the auto-forecast instead (e.g. a bonus on top of the detected salary), so
    /// the category and its `.auto` entries are left alone.
    @discardableResult
    public static func add(db: Database, categoryId: Int64, amountMinorUnits: Int, frequency: ForecastFrequency, interval: Int, startDate: Date, endDate: Date?) throws -> ForecastEntry {
        guard let category = try Category.fetchOne(db, key: categoryId) else { throw PlannedItemsError.categoryNotFound }
        guard !category.isReserved else { throw PlannedItemsError.reservedCategory }
        let group = try ensureGroup(db: db)
        var entry = ForecastEntry(groupId: group.id!, categoryId: categoryId, amountMinorUnits: amountMinorUnits, frequency: frequency, interval: interval, startDate: startDate, endDate: endDate, isEnabled: true, status: .confirmed, note: nil)
        try entry.insert(db)
        if frequency != .once {
            try ReservedCategories.setExcludedFromAutoForecast(db: db, categoryId: categoryId, true)
        }
        return entry
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
        var group = ForecastGroup(name: groupName, note: "Confirmed items added from the Forecast grid", isEnabled: true, isSystemManaged: false)
        try group.insert(db)
        return group
    }
}
