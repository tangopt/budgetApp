import Foundation
import GRDB

public enum SyncRecordStoreError: Error, Equatable {
    /// The table isn't synced (`SyncSchema.tables`), so its rows have no cloud identity.
    case notSynced(String)
}

/// The stable identity of each synced local row (sync spec §4.1): one `syncRecord` row holding the
/// UUID that names its CloudKit record. Local ids stay local; the UUID is what other devices see.
public enum SyncRecordStore {
    /// Every row's zone in build step 3.
    public static let householdZone = "household"

    /// The row's UUID, created (zone `household`) the first time it is asked for.
    public static func uuid(for table: String, localId: Int64, db: Database) throws -> String {
        guard SyncSchema.table(table) != nil else { throw SyncRecordStoreError.notSynced(table) }
        if let existing = try existingUUID(table: table, localId: localId, db: db) { return existing }
        let uuid = UUID().uuidString
        try db.cachedStatement(sql: "INSERT INTO syncRecord(tableName, localId, uuid, zone) VALUES (?, ?, ?, ?)")
            .execute(arguments: [table, localId, uuid, householdZone])
        return uuid
    }

    /// The row's UUID if it has one.
    static func existingUUID(table: String, localId: Int64, db: Database) throws -> String? {
        try String.fetchOne(db.cachedStatement(sql: "SELECT uuid FROM syncRecord WHERE tableName = ? AND localId = ?"),
                            arguments: [table, localId])
    }

    /// This device's local id for the record, or nil when it names no row of `table` here.
    public static func localId(table: String, uuid: String, db: Database) throws -> Int64? {
        try Int64.fetchOne(db.cachedStatement(sql: "SELECT localId FROM syncRecord WHERE uuid = ? AND tableName = ?"),
                           arguments: [uuid, table])
    }

    /// Gives every existing synced row without one a UUID, and queues each as a pending insert so the
    /// first upload sends it. Returns how many it assigned; a second run assigns none.
    @discardableResult
    public static func backfill(db: Database) throws -> Int {
        var assigned = 0
        for table in SyncSchema.tables {
            let key = "\"" + table.localIdColumn + "\""
            let ids = try Int64.fetchAll(db, sql: """
                SELECT t.\(key) FROM "\(table.name)" t
                WHERE NOT EXISTS (SELECT 1 FROM syncRecord s WHERE s.tableName = ? AND s.localId = t.\(key))
                ORDER BY t.\(key)
                """, arguments: [table.name])
            for id in ids {
                let uuid = try uuid(for: table.name, localId: id, db: db)
                try SyncChangeTracker.enqueue(PendingChange(table: table.name, localId: id, uuid: uuid, kind: .insert), db: db)
            }
            assigned += ids.count
        }
        return assigned
    }
}
