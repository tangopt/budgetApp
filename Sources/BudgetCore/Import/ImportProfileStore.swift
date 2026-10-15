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
        var mutableProfile = profile
        try dbQueue.write { db in
            if let existing = try ImportProfile
                .filter(Column("accountId") == profile.accountId && Column("format") == profile.format.rawValue)
                .fetchOne(db) {
                mutableProfile.id = existing.id
                try mutableProfile.update(db)
            } else {
                try mutableProfile.insert(db)
            }
        }
        return mutableProfile
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
