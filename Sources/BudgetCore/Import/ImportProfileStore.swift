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
}
