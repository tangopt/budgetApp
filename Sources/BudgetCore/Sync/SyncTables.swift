import Foundation
import GRDB

// The five sync bookkeeping tables (sync spec §4.1). All of them are local-only: they describe this
// device's copy and are never synced themselves (`SyncSchema.localOnlyTables`).

/// The stable identity of one synced local row: its UUID (the CloudKit record name), zone and change tag.
public struct SyncRecordRow: Codable, Equatable, FetchableRecord, PersistableRecord, Sendable {
    public var tableName: String
    public var localId: Int64
    public var uuid: String
    /// `"household"` for every row in build step 3; `"private-<person uuid>"` later.
    public var zone: String
    /// `CKRecord.encodeSystemFields` (the change tag); nil until the record has been to the server.
    public var systemFields: Data?
    /// The `appUser` UUID of the last writer.
    public var modifiedBy: String?
    public var modifiedAt: Date?

    public init(tableName: String, localId: Int64, uuid: String, zone: String,
                systemFields: Data? = nil, modifiedBy: String? = nil, modifiedAt: Date? = nil) {
        self.tableName = tableName
        self.localId = localId
        self.uuid = uuid
        self.zone = zone
        self.systemFields = systemFields
        self.modifiedBy = modifiedBy
        self.modifiedAt = modifiedAt
    }

    public static let databaseTableName = "syncRecord"
}

/// An incoming record that can't apply yet: its parent hasn't arrived, or its import batch is incomplete.
public struct SyncStagingRow: Codable, Equatable, Identifiable, FetchableRecord, MutablePersistableRecord, Sendable {
    public var id: Int64?
    public var tableName: String
    /// One staged payload per record: a newer arrival replaces the older one.
    public var uuid: String
    public var payloadJSON: String
    /// Why it waits, e.g. a missing parent; never carries amounts or names.
    public var reason: String
    /// Set when the record belongs to an import batch (sync spec §5.2).
    public var importRunUuid: String?
    public var receivedAt: Date
    /// Which of the run's batches it belongs to (1: the import, 2: its Undo; `SyncBatch`).
    public var batchGeneration: Int?

    public init(id: Int64? = nil, tableName: String, uuid: String, payloadJSON: String, reason: String,
                importRunUuid: String? = nil, receivedAt: Date, batchGeneration: Int? = nil) {
        self.id = id
        self.tableName = tableName
        self.uuid = uuid
        self.payloadJSON = payloadJSON
        self.reason = reason
        self.importRunUuid = importRunUuid
        self.receivedAt = receivedAt
        self.batchGeneration = batchGeneration
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }

    public static let databaseTableName = "syncStaging"
}

/// A field-level merge loser (sync spec §5.1): the value that was overwritten, and by whom.
public struct SyncConflictRow: Codable, Equatable, Identifiable, FetchableRecord, MutablePersistableRecord, Sendable {
    public var id: Int64?
    public var tableName: String
    public var uuid: String
    public var field: String
    public var losingValueJSON: String
    public var winningWriter: String?
    public var losingWriter: String?
    public var recordedAt: Date

    public init(id: Int64? = nil, tableName: String, uuid: String, field: String, losingValueJSON: String,
                winningWriter: String?, losingWriter: String?, recordedAt: Date) {
        self.id = id
        self.tableName = tableName
        self.uuid = uuid
        self.field = field
        self.losingValueJSON = losingValueJSON
        self.winningWriter = winningWriter
        self.losingWriter = losingWriter
        self.recordedAt = recordedAt
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }

    public static let databaseTableName = "syncConflict"
}

/// A deleted synced row, kept so the delete can be sent and so a late edit doesn't resurrect it.
public struct SyncTombstoneRow: Codable, Equatable, FetchableRecord, PersistableRecord, Sendable {
    public var uuid: String
    public var tableName: String
    public var localId: Int64
    public var zone: String
    public var deletedBy: String?
    public var deletedAt: Date
    /// Set when the record wasn't deleted but merged into another (both devices made it): its UUID. Other
    /// devices re-key their row to it, and references to this UUID resolve to it.
    public var mergedInto: String?

    public init(uuid: String, tableName: String, localId: Int64, zone: String, deletedBy: String?, deletedAt: Date,
                mergedInto: String? = nil) {
        self.uuid = uuid
        self.tableName = tableName
        self.localId = localId
        self.zone = zone
        self.deletedBy = deletedBy
        self.deletedAt = deletedAt
        self.mergedInto = mergedInto
    }

    public static let databaseTableName = "syncTombstone"
}

/// Opaque sync state by key: the engine's serialized state and change token.
public struct SyncStateRow: Codable, Equatable, FetchableRecord, PersistableRecord, Sendable {
    public var key: String
    public var value: Data
    public var updatedAt: Date

    public init(key: String, value: Data, updatedAt: Date) {
        self.key = key
        self.value = value
        self.updatedAt = updatedAt
    }

    public static let databaseTableName = "syncState"
}

func registerSyncMigration(_ migrator: inout DatabaseMigrator) {
    // Only adds tables: no existing table, column or value changes.
    migrator.registerMigration("createSync") { db in
        try db.create(table: "syncRecord") { t in
            t.column("tableName", .text).notNull()
            t.column("localId", .integer).notNull()
            t.column("uuid", .text).notNull().unique()
            t.column("zone", .text).notNull()
            t.column("systemFields", .blob)
            t.column("modifiedBy", .text)
            t.column("modifiedAt", .datetime)
            t.primaryKey(["tableName", "localId"])
        }
        try db.create(table: "syncStaging") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("tableName", .text).notNull()
            t.column("uuid", .text).notNull().unique()
            t.column("payloadJSON", .text).notNull()
            t.column("reason", .text).notNull()
            t.column("importRunUuid", .text).indexed()
            t.column("receivedAt", .datetime).notNull()
            t.column("batchGeneration", .integer)
        }
        try db.create(table: "syncConflict") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("tableName", .text).notNull()
            t.column("uuid", .text).notNull()
            t.column("field", .text).notNull()
            t.column("losingValueJSON", .text).notNull()
            t.column("winningWriter", .text)
            t.column("losingWriter", .text)
            t.column("recordedAt", .datetime).notNull()
        }
        try db.create(index: "syncConflict_on_uuid", on: "syncConflict", columns: ["uuid"])
        try db.create(table: "syncTombstone") { t in
            t.primaryKey("uuid", .text)
            t.column("tableName", .text).notNull()
            t.column("localId", .integer).notNull()
            t.column("zone", .text).notNull()
            t.column("deletedBy", .text)
            t.column("deletedAt", .datetime).notNull()
            t.column("mergedInto", .text)
        }
        try db.create(table: "syncState") { t in
            t.primaryKey("key", .text)
            t.column("value", .blob).notNull()
            t.column("updatedAt", .datetime).notNull()
        }
        // Written by the change-tracking triggers (`SyncChangeTracker`), in the same transaction as the
        // data change: one entry per record waiting to be sent, in the order first queued (rowid).
        try db.create(table: "syncPending") { t in
            t.primaryKey("uuid", .text)
            t.column("tableName", .text).notNull()
            t.column("localId", .integer).notNull()
            t.column("kind", .text).notNull().check { ["insert", "update", "delete"].contains($0) }
            t.column("revision", .integer).notNull().indexed()
        }
        // When each synced field last changed here, for field-level last writer wins (sync spec §5.1).
        // Field `*` is the row's insert: every field without its own entry dates from it.
        try db.create(table: "syncFieldClock") { t in
            t.column("tableName", .text).notNull()
            t.column("localId", .integer).notNull()
            t.column("field", .text).notNull()
            t.column("modifiedAt", .datetime).notNull()
            t.column("modifiedBy", .text)
            t.primaryKey(["tableName", "localId", "field"])
        }
        // At most one row: the signed-in app user's UUID, which the triggers stamp as the writer.
        try db.create(table: "syncWriter") { t in
            t.primaryKey("id", .integer).check { $0 == 1 }
            t.column("appUserUuid", .text)
        }
        // Import batches (sync spec §5.2, `SyncBatch`): one row per import run whose batch this device sent
        // or received, with its latest generation (1: the import, 2: its Undo) and where it stands.
        try db.create(table: "syncBatch") { t in
            t.primaryKey("runUuid", .text)
            t.column("generation", .integer).notNull()
            t.column("state", .text).notNull().check { ["sending", "open", "complete", "closed"].contains($0) }
            // A received run's manifest; the records an Undo sent here brings back (`revives`).
            t.column("manifestJSON", .text)
            t.column("revivesJSON", .text)
        }
        // The records of a batch this device is sending, until it is fully uploaded.
        try db.create(table: "syncBatchMember") { t in
            t.primaryKey("uuid", .text)
            t.column("runUuid", .text).notNull().indexed()
            t.column("tableName", .text).notNull()
        }
        // A row here only inside an incoming apply's transaction: the triggers skip while it exists.
        try db.create(table: "syncApplying") { t in
            t.primaryKey("id", .integer).check { $0 == 1 }
        }
    }
}
