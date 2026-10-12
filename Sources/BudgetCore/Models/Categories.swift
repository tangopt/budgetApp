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

/// Categories created on the spot from the category picker's "New category…" (spec §4).
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
}
