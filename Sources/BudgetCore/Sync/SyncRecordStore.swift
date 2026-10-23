import CryptoKit
import Foundation
import GRDB

public enum SyncRecordStoreError: Error, Equatable {
    /// The table isn't synced (`SyncSchema.tables`), so its rows have no cloud identity.
    case notSynced(String)
    /// No row of the table has this local id, so there is nothing to name.
    case noSuchRow(table: String, localId: Int64)
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

    /// The row's UUID. The tracking triggers give every row they see one; a row written without them
    /// (an incoming apply, a row from before tracking) gets one here, zone `household`, queued as a
    /// pending insert like `backfill` would. A local id that names no row is refused.
    public static func uuid(for table: String, localId: Int64, db: Database) throws -> String {
        guard let schema = SyncSchema.table(table) else { throw SyncRecordStoreError.notSynced(table) }
        if let existing = try existingUUID(table: table, localId: localId, db: db) { return existing }
        let exists = try Bool.fetchOne(db, sql: """
            SELECT EXISTS (SELECT 1 FROM \(SyncChangeTracker.quoted(table)) WHERE \(SyncChangeTracker.quoted(schema.localIdColumn)) = ?)
            """, arguments: [localId]) ?? false
        guard exists else { throw SyncRecordStoreError.noSuchRow(table: table, localId: localId) }
        if let fixed = try seededUUID(table: table, localId: localId, db: db) {
            try db.execute(sql: "INSERT INTO syncRecord(tableName, localId, uuid, zone) VALUES (?, ?, ?, ?)",
                           arguments: [table, localId, fixed, householdZone])
        } else {
            try db.cachedStatement(sql: "INSERT INTO syncRecord(tableName, localId, uuid, zone) VALUES (?, ?, \(uuidSQL), ?)")
                .execute(arguments: [table, localId, householdZone])
        }
        let uuid = try existingUUID(table: table, localId: localId, db: db)!
        try db.cachedStatement(sql: """
            INSERT INTO syncPending(uuid, tableName, localId, kind, revision)
            VALUES (?, ?, ?, 'insert', (SELECT COALESCE(MAX(revision), 0) + 1 FROM syncPending))
            ON CONFLICT(uuid) DO NOTHING
            """).execute(arguments: [uuid, table, localId])
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
    /// first upload sends it. Returns how many it assigned; a second run assigns none. Rows written
    /// before tracking have no field clocks: their fields date from no time and lose to any dated edit.
    @discardableResult
    public static func backfill(db: Database) throws -> Int {
        var assigned = 0
        for table in SyncSchema.tables {
            // Seeded rows every device has get the same UUID everywhere (`seededUUID`); they are queued with
            // the rest below, being above the mark.
            let seededMark = try Int64.fetchOne(db, sql: "SELECT COALESCE(MAX(rowid), 0) FROM syncRecord") ?? 0
            if table.name == "category" {
                for row in try Row.fetchAll(db, sql: """
                    SELECT c.id, c.builtInRole FROM category c WHERE c.builtInRole IS NOT NULL
                    AND NOT EXISTS (SELECT 1 FROM syncRecord s WHERE s.tableName = 'category' AND s.localId = c.id) ORDER BY c.id
                    """) {
                    try db.execute(sql: "INSERT INTO syncRecord(tableName, localId, uuid, zone) VALUES ('category', ?, ?, ?) ON CONFLICT DO NOTHING",
                                   arguments: [row["id"] as Int64, builtInCategoryUUID(row["builtInRole"]), householdZone])
                    assigned += db.changesCount
                }
            }
            let key = SyncChangeTracker.quoted(table.localIdColumn)
            // New identities get rowids above every existing one, which is how they are found to queue.
            try db.execute(sql: """
                INSERT INTO syncRecord(tableName, localId, uuid, zone)
                SELECT ?, t.\(key), \(uuidSQL), ? FROM \(SyncChangeTracker.quoted(table.name)) t
                WHERE NOT EXISTS (SELECT 1 FROM syncRecord s WHERE s.tableName = ? AND s.localId = t.\(key))
                ORDER BY t.\(key)
                """, arguments: [table.name, householdZone, table.name])
            let added = db.changesCount
            let newest = try Int64.fetchOne(db, sql: "SELECT COALESCE(MAX(rowid), 0) FROM syncRecord") ?? 0
            guard newest > seededMark else { continue }
            let base = try Int64.fetchOne(db, sql: "SELECT COALESCE(MAX(revision), 0) FROM syncPending") ?? 0
            try db.execute(sql: """
                INSERT INTO syncPending(uuid, tableName, localId, kind, revision)
                SELECT uuid, tableName, localId, 'insert', ? + rowid - ? FROM syncRecord WHERE rowid > ? ORDER BY rowid
                ON CONFLICT(uuid) DO NOTHING
                """, arguments: [base, seededMark, seededMark])
            assigned += added
        }
        return assigned
    }

    /// The UUID of a row every device seeds alike, the same on all of them (so the first sync merges them
    /// instead of re-keying): built-in categories, by their role. Nil for any other row.
    static func seededUUID(table: String, localId: Int64, db: Database) throws -> String? {
        guard table == "category",
              let role = try String.fetchOne(db, sql: "SELECT builtInRole FROM category WHERE id = ?", arguments: [localId]) else { return nil }
        return builtInCategoryUUID(role)
    }

    /// A name-based UUID in the canonical lowercase v4 shape (version digit 4, variant 8–b).
    static func builtInCategoryUUID(_ role: String) -> String {
        var hex = Array(SHA256.hash(data: Data("mango.category.builtInRole.\(role)".utf8)).prefix(16).map { String(format: "%02x", $0) }.joined())
        hex[12] = "4"
        hex[16] = Array("89ab")[Int(String(hex[16]), radix: 16)! % 4]
        let s = String(hex)
        func part(_ a: Int, _ b: Int) -> String { String(s[s.index(s.startIndex, offsetBy: a)..<s.index(s.startIndex, offsetBy: b)]) }
        return [part(0, 8), part(8, 12), part(12, 16), part(16, 20), part(20, 32)].joined(separator: "-")
    }
}
