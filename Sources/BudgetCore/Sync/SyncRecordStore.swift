import Foundation
import GRDB

public enum SyncRecordStoreError: Error, Equatable {
    /// The table isn't synced (`SyncSchema.tables`), so its rows have no cloud identity.
    case notSynced(String)
}

/// The stable identity of each synced local row (sync spec §4.1): one `syncRecord` row holding the
/// UUID that names its CloudKit record. Local ids stay local; the UUID is what other devices see.
/// The tracking triggers (`SyncChangeTracker`) create identities as rows are written.
public enum SyncRecordStore {
    /// Every row's zone in build step 3.
    public static let householdZone = "household"

    /// A random version 4 UUID in its canonical lowercase form (8-4-4-4-12 hex digits, version digit 4,
    /// variant digit 8, 9, a or b), made by SQLite so the triggers and Swift share one format.
    static let uuidSQL = """
        (lower(hex(randomblob(4))) || '-' || lower(hex(randomblob(2))) || '-4' || substr(lower(hex(randomblob(2))), 2) || '-' || \
        substr('89ab', 1 + (abs(random()) % 4), 1) || substr(lower(hex(randomblob(2))), 2) || '-' || lower(hex(randomblob(6))))
        """

    /// The row's UUID, created (zone `household`) the first time it is asked for.
    public static func uuid(for table: String, localId: Int64, db: Database) throws -> String {
        guard SyncSchema.table(table) != nil else { throw SyncRecordStoreError.notSynced(table) }
        if let existing = try existingUUID(table: table, localId: localId, db: db) { return existing }
        try db.cachedStatement(sql: "INSERT INTO syncRecord(tableName, localId, uuid, zone) VALUES (?, ?, \(uuidSQL), ?)")
            .execute(arguments: [table, localId, householdZone])
        return try existingUUID(table: table, localId: localId, db: db)!
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
    /// first upload sends it. Returns how many it assigned; a second run assigns none. Rows written
    /// before tracking have no field clocks: their fields date from no time and lose to any dated edit.
    @discardableResult
    public static func backfill(db: Database) throws -> Int {
        var assigned = 0
        for table in SyncSchema.tables {
            let key = SyncChangeTracker.quoted(table.localIdColumn)
            // New identities get rowids above every existing one, which is how they are found to queue.
            let mark = try Int64.fetchOne(db, sql: "SELECT COALESCE(MAX(rowid), 0) FROM syncRecord") ?? 0
            try db.execute(sql: """
                INSERT INTO syncRecord(tableName, localId, uuid, zone)
                SELECT ?, t.\(key), \(uuidSQL), ? FROM \(SyncChangeTracker.quoted(table.name)) t
                WHERE NOT EXISTS (SELECT 1 FROM syncRecord s WHERE s.tableName = ? AND s.localId = t.\(key))
                ORDER BY t.\(key)
                """, arguments: [table.name, householdZone, table.name])
            let added = db.changesCount
            guard added > 0 else { continue }
            let base = try Int64.fetchOne(db, sql: "SELECT COALESCE(MAX(revision), 0) FROM syncPending") ?? 0
            try db.execute(sql: """
                INSERT INTO syncPending(uuid, tableName, localId, kind, revision)
                SELECT uuid, tableName, localId, 'insert', ? + rowid - ? FROM syncRecord WHERE rowid > ? ORDER BY rowid
                ON CONFLICT(uuid) DO NOTHING
                """, arguments: [base, mark, mark])
            assigned += added
        }
        return assigned
    }
}
