import GRDB

public final class ImportProfileStore {
    private let dbQueue: DatabaseQueue

    public init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
    }

    public func find(accountId: Int64, format: ImportFormat) throws -> ImportProfile? {
        try dbQueue.read { db in
            try ImportProfile
                .filter(Column("accountId") == accountId && Column("format") == format.rawValue)
                .fetchOne(db)
        }
    }

    @discardableResult
    public func save(_ profile: ImportProfile) throws -> ImportProfile {
        try dbQueue.write { db in try Self.save(db: db, profile) }
    }

    /// Saves the account's profile for its format in the caller's transaction: the existing one
    /// replaced (keeping its id), else inserted.
    @discardableResult
    public static func save(db: Database, _ profile: ImportProfile) throws -> ImportProfile {
        var saved = profile
        if let existing = try ImportProfile
            .filter(Column("accountId") == profile.accountId && Column("format") == profile.format.rawValue)
            .fetchOne(db) {
            saved.id = existing.id
            try saved.update(db)
        } else {
            try saved.insert(db)
        }
        return saved
    }

    /// Forgets the account's saved mapping (CSV) or layout (PDF) for `format`, so the next
    /// import of that format asks for it again (spec 2026-10-15 §4). Returns whether one existed.
    @discardableResult
    public func delete(accountId: Int64, format: ImportFormat) throws -> Bool {
        try dbQueue.write { db in
            try ImportProfile
                .filter(Column("accountId") == accountId && Column("format") == format.rawValue)
                .deleteAll(db) > 0
        }
    }
}
