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
    /// `CKRecord.encodeSystemFields`: the opaque blob a save needs; nil until the record has been to the server.
    public var systemFields: Data?
    /// The server's change tag of the version `systemFields` names: what the engine compares.
    public var changeTag: String?
    /// The `appUser` UUID of the last writer.
    public var modifiedBy: String?
    public var modifiedAt: Date?

    public init(tableName: String, localId: Int64, uuid: String, zone: String,
                systemFields: Data? = nil, modifiedBy: String? = nil, modifiedAt: Date? = nil, changeTag: String? = nil) {
        self.tableName = tableName
        self.localId = localId
        self.uuid = uuid
        self.zone = zone
        self.systemFields = systemFields
        self.changeTag = changeTag
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
    /// When the record first waited here (ruling R8); a newer version of it keeps the time.
    public var firstSeenAt: Date?
    /// How many applies of it SQLite refused; at `SyncTranslator.maxApplyAttempts` it needs attention.
    public var attempts: Int

    public init(id: Int64? = nil, tableName: String, uuid: String, payloadJSON: String, reason: String,
                importRunUuid: String? = nil, receivedAt: Date, batchGeneration: Int? = nil, firstSeenAt: Date? = nil, attempts: Int = 0) {
        self.id = id
        self.tableName = tableName
        self.uuid = uuid
        self.payloadJSON = payloadJSON
        self.reason = reason
        self.importRunUuid = importRunUuid
        self.receivedAt = receivedAt
        self.batchGeneration = batchGeneration
        self.firstSeenAt = firstSeenAt ?? receivedAt
        self.attempts = attempts
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

/// A redirect made from a record the server already has must be saved over that record's server version:
/// the tombstone keeps the record's `systemFields` (the server version it last saw), as `syncRecord` did.
func registerSyncRedirectStampMigration(_ migrator: inout DatabaseMigrator) {
    // Only adds a nullable column to a local table.
    migrator.registerMigration("syncTombstoneSystemFields") { db in
        try db.alter(table: "syncTombstone") { t in
            t.add(column: "systemFields", .blob)
        }
    }
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
            t.column("changeTag", .text)
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
            // Ruling R8: when the record first waited here, and how many applies SQLite refused (bounded).
            t.column("firstSeenAt", .datetime)
            t.column("attempts", .integer).notNull().defaults(to: 0)
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
            // Ruling R12: 1 queued again by reconciliation (missing on the server), 2 an edit whose save found
            // the record deleted on the server; either is sent as `resent` (`SyncTranslator.resent…`).
            t.column("resent", .integer).notNull().defaults(to: 0)
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
            t.column("state", .text).notNull().check { ["sending", "sent", "open", "complete", "closed", "done"].contains($0) }
            // A received run's manifest; the records an Undo sent here brings back (`revives`).
            t.column("manifestJSON", .text)
            t.column("revivesJSON", .text)
        }
        // The records of each import run's batches as this device knows them (written by it, or received
        // tagged): each record belongs to the latest generation that wrote it, and keeps that tag.
        try db.create(table: "syncBatchMember") { t in
            t.primaryKey("uuid", .text)
            t.column("runUuid", .text).notNull().indexed()
            t.column("tableName", .text).notNull()
            t.column("generation", .integer).notNull()
        }
        // A row here only inside an incoming apply's transaction: the triggers skip while it exists.
        try db.create(table: "syncApplying") { t in
            t.primaryKey("id", .integer).check { $0 == 1 }
        }
    }
    // Ruling R7 (append-only): the sync identity of the row each change names, recorded when the run is
    // captured, so an Undo restores a deleted row under exactly the UUID the run deleted.
    migrator.registerMigration("importChangeRowUuid") { db in
        try db.alter(table: "importChange") { t in
            t.add(column: "rowUuid", .text)
        }
    }
}
