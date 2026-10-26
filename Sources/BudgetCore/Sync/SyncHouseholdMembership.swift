import Foundation
import GRDB

/// A member device's household (step 7a): the iCloud user record name of the household's owner (the admin), whose zone
/// this device reaches through its shared database. Local only (`syncState`), set when the invite is accepted here and
/// forgotten when she leaves or is removed. None: this device's household is in its own private database (the admin's
/// devices).
public enum SyncHouseholdMembership {
    static let ownerKey = "householdOwner"

    public static func record(ownerRecordName: String, db: Database) throws {
        try SyncImportGate.setState(Data(ownerRecordName.utf8), key: ownerKey, db: db, now: Date())
    }

    public static func current(db: Database) throws -> String? {
        try Data.fetchOne(db, sql: "SELECT value FROM syncState WHERE key = ?", arguments: [ownerKey])
            .flatMap { String(data: $0, encoding: .utf8) }
            .flatMap { $0.isEmpty ? nil : $0 }
    }

    public static func forget(db: Database) throws {
        try db.execute(sql: "DELETE FROM syncState WHERE key = ?", arguments: [ownerKey])
    }

    /// This device is no longer in the household (`SyncPullReport.leftHousehold`): its copy of the household is dropped
    /// (`SyncLocalData.dropZone`, local only) and the membership forgotten, in one transaction. Returns the rows dropped.
    @discardableResult
    public static func left(db: Database) throws -> Int {
        let dropped = try SyncLocalData.dropZone(SyncZones.household, db: db)
        try forget(db: db)
        return dropped
    }
}
