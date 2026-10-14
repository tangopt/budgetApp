import Foundation
import GRDB

public enum CategoryCreationError: Error, Equatable, LocalizedError {
    case emptyName
    /// Another category already has this name (ignoring case); carries the existing name.
    case duplicateName(String)
    case groupNotFound

    public var errorDescription: String? {
        switch self {
        case .emptyName: return "Enter a name for the category."
        case .duplicateName(let existing): return "A category named “\(existing)” already exists."
        case .groupNotFound: return "That category group no longer exists."
        }
    }
}

public enum CategoryEditError: Error, Equatable, LocalizedError {
    case notFound
    /// Reserves are managed on the Budget grid, not deleted from the Categories screen.
    case reserve(name: String)
    /// Built-in categories (Balance adjustment, Market movement) can't be renamed, moved or deleted.
    case builtIn(name: String)
    /// Delete refused: transactions (`pending` of them still in review, included in
    /// `transactions`) or planned items still use it. A planned item is a forecast series
    /// in this category or with an occurrence moved into it.
    case inUse(name: String, transactions: Int, pending: Int, plannedItems: Int)

    public var errorDescription: String? {
        switch self {
        case .notFound:
            return "That category no longer exists."
        case .reserve(let name):
            return "\(name) is a reserve — manage it on the Budget grid."
        case .builtIn(let name):
            return "\(name) is built in — it can't be renamed, moved or deleted."
        case let .inUse(name, transactions, pending, plannedItems):
            var parts: [String] = []
            if transactions > 0 {
                var part = transactions == 1 ? "1 transaction" : "\(transactions) transactions"
                if pending > 0 { part += pending == transactions && transactions == 1 ? " (pending review)" : " (\(pending) pending review)" }
                parts.append(part)
            }
            if plannedItems > 0 { parts.append(plannedItems == 1 ? "1 planned item" : "\(plannedItems) planned items") }
            let pronoun = transactions + plannedItems == 1 ? "it" : "them"
            return "\(name) has \(parts.joined(separator: " and ")) — move or recategorise \(pronoun) first."
        }
    }
}

/// Categories created on the spot from the category picker's "New category…" (spec §4), and
/// the Categories screen's rename / move / delete.
public enum Categories {
    /// Inserts an assignable (never reserved) category named `name`, trimmed, of `type`, in
    /// the optional group. Names are unique ignoring case.
    @discardableResult
    public static func create(db: Database, name: String, type: CategoryType, groupId: Int64?) throws -> Category {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw CategoryCreationError.emptyName }
        if let existing = try Category.fetchAll(db).first(where: { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            throw CategoryCreationError.duplicateName(existing.name)
        }
        if let groupId, try CategoryGroup.fetchOne(db, key: groupId) == nil {
            throw CategoryCreationError.groupNotFound
        }
        var category = Category(name: trimmed, type: type, groupId: groupId)
        try category.insert(db)
        return category
    }

    /// Renames to `name`, trimmed; unique ignoring case (its own name in another case is fine).
    public static func rename(db: Database, id: Int64, name: String) throws {
        guard var category = try Category.fetchOne(db, key: id) else { throw CategoryEditError.notFound }
        guard !category.isBuiltIn else { throw CategoryEditError.builtIn(name: category.name) }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw CategoryCreationError.emptyName }
        if let existing = try Category.fetchAll(db).first(where: { $0.id != id && $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            throw CategoryCreationError.duplicateName(existing.name)
        }
        category.name = trimmed
        try category.update(db, columns: ["name"])
    }

    /// Sets the category's SF Symbol, trimmed; nil or blank clears it (back to the type's
    /// generic symbol).
    public static func setIcon(db: Database, id: Int64, iconName: String?) throws {
        guard var category = try Category.fetchOne(db, key: id) else { throw CategoryEditError.notFound }
        let trimmed = iconName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        category.iconName = trimmed.isEmpty ? nil : trimmed
        try category.update(db, columns: ["iconName"])
    }

    /// Puts every category in `ids` into the group (nil = ungrouped). A group may hold
    /// categories of any type. Refused when any of them is built in.
    public static func move(db: Database, ids: [Int64], toGroupId groupId: Int64?) throws {
        if let groupId, try CategoryGroup.fetchOne(db, key: groupId) == nil {
            throw CategoryCreationError.groupNotFound
        }
        guard !ids.isEmpty else { return }
        if let builtIn = try Category.filter(ids.contains(Column("id")) && Column("builtInRole") != nil).fetchOne(db) {
            throw CategoryEditError.builtIn(name: builtIn.name)
        }
        try Category.filter(ids.contains(Column("id"))).updateAll(db, Column("groupId").set(to: groupId))
    }

    /// Deletes the category and the rules filing into it. Refused for a reserve, and
    /// (`inUse`, with counts) while any transaction, forecast entry — budget or scenario — or
    /// moved planned occurrence refers to it (an occurrence's category would otherwise be
    /// silently cleared back to its series').
    public static func delete(db: Database, id: Int64) throws {
        guard let category = try Category.fetchOne(db, key: id) else { throw CategoryEditError.notFound }
        guard !category.isReserved else { throw CategoryEditError.reserve(name: category.name) }
        guard !category.isBuiltIn else { throw CategoryEditError.builtIn(name: category.name) }
        let transactions = try Transaction.filter(Column("categoryId") == id).fetchCount(db)
        let pending = try Transaction.filter(Column("categoryId") == id && Column("status") == TransactionStatus.pendingReview.rawValue).fetchCount(db)
        let planned = try Int.fetchOne(db, sql: """
            SELECT COUNT(*) FROM (
                SELECT id FROM forecastEntry WHERE categoryId = ?
                UNION
                SELECT entryId FROM plannedOccurrenceException WHERE categoryId = ?
            )
            """, arguments: [id, id]) ?? 0
        guard transactions == 0, planned == 0 else {
            throw CategoryEditError.inUse(name: category.name, transactions: transactions, pending: pending, plannedItems: planned)
        }
        try Rule.filter(Column("categoryId") == id).deleteAll(db)
        _ = try Category.deleteOne(db, key: id)
    }
}
