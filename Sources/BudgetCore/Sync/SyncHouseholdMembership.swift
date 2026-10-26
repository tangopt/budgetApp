import Foundation
import GRDB

/// A member device's household (step 7a): the iCloud user record name of the household's owner (the admin), whose zone
/// this device reaches through its shared database. Local only (`syncState`), set when the invite is accepted here and
/// forgotten when she leaves or is removed. None: this device's household is in its own private database (the admin's
/// devices).
///
/// Joined only after a pull (Task 7, carried M4): right after accepting, CloudKit may not list the zone in her shared
/// database yet, which looks like removal. So a missing household counts as leaving (`SyncPullReport.leftHousehold`)
/// only once a household pull through the shared database has succeeded here (`hasJoined`).
public enum SyncHouseholdMembership {
    static let ownerKey = "householdOwner"
    static let joinedKey = "householdJoined"

    /// The invite was accepted on this device: the household is in `ownerRecordName`'s zone, reached through the shared
    /// database. Not joined yet (`hasJoined`): that waits for the first household pull.
    public static func record(ownerRecordName: String, db: Database) throws {
        try SyncImportGate.setState(Data(ownerRecordName.utf8), key: ownerKey, db: db, now: Date())
    }

    /// Whether a household pull through the shared database has succeeded on this device since it accepted.
    public static func hasJoined(db: Database) throws -> Bool {
        try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM syncState WHERE key = ?)", arguments: [joinedKey]) ?? false
    }

    /// The engine: a household pull through the shared database succeeded (in the pull's own transaction).
    static func joined(db: Database) throws {
        guard try !hasJoined(db: db) else { return }
        try SyncImportGate.setState(Data("1".utf8), key: joinedKey, db: db, now: Date())
    }

    public static func current(db: Database) throws -> String? {
        try Data.fetchOne(db, sql: "SELECT value FROM syncState WHERE key = ?", arguments: [ownerKey])
            .flatMap { String(data: $0, encoding: .utf8) }
            .flatMap { $0.isEmpty ? nil : $0 }
    }

    public static func forget(db: Database) throws {
        try db.execute(sql: "DELETE FROM syncState WHERE key IN (?, ?)", arguments: [ownerKey, joinedKey])
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
