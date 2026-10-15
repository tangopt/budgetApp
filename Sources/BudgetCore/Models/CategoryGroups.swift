import Foundation
import GRDB

public enum CategoryGroupError: Error, Equatable, LocalizedError {
    case emptyName
    /// Another group already has this name (ignoring case); carries the existing name.
    case duplicateName(String)
    case notFound

    public var errorDescription: String? {
        switch self {
        case .emptyName: return "Enter a name for the group."
        case .duplicateName(let existing): return "A group named “\(existing)” already exists."
        case .notFound: return "That category group no longer exists."
        }
    }
}

/// The Categories screen's group editing (spec §4). Names are trimmed and unique ignoring case.
public enum CategoryGroups {
    /// Creates the group named `name` (trimmed, unique ignoring case) and moves the categories
    /// in `ids` into it (`Categories.move`: refused when any is built in). Run inside one
    /// write, so a refusal creates nothing.
    @discardableResult
    public static func create(db: Database, name: String, moving ids: [Int64] = []) throws -> CategoryGroup {
        let trimmed = try validName(db: db, name, excluding: nil)
        var group = CategoryGroup(name: trimmed)
        try group.insert(db)
        if !ids.isEmpty, let id = group.id {
            try Categories.move(db: db, ids: ids, toGroupId: id)
        }
        return group
    }

    public static func rename(db: Database, id: Int64, name: String) throws {
        guard var group = try CategoryGroup.fetchOne(db, key: id) else { throw CategoryGroupError.notFound }
        group.name = try validName(db: db, name, excluding: id)
        try group.update(db)
    }

    /// Deletes the group; its categories become ungrouped.
    public static func delete(db: Database, id: Int64) throws {
        try db.execute(sql: "UPDATE category SET groupId = NULL WHERE groupId = ?", arguments: [id])
        _ = try CategoryGroup.deleteOne(db, key: id)
    }

    private static func validName(db: Database, _ name: String, excluding id: Int64?) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw CategoryGroupError.emptyName }
        if let existing = try CategoryGroup.fetchAll(db).first(where: {
            $0.id != id && $0.name.caseInsensitiveCompare(trimmed) == .orderedSame
        }) {
            throw CategoryGroupError.duplicateName(existing.name)
        }
        return trimmed
    }
}
