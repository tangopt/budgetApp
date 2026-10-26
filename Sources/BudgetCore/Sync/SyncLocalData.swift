import Foundation
import GRDB
import os

/// Dropping a zone's data from this device (step 7a): when the member is removed from the household, or when this
/// iPhone's iCloud user changes. Local only: nothing is queued, nothing is sent, nothing on the server changes, and no
/// tombstone is left (a later pull of the zone, if this device follows it again, brings its records back as new).
public enum SyncLocalData {
    private static let log = Logger(subsystem: "com.personal.budget", category: "Sync")

    /// Deletes every row whose `syncRecord.zone` is `zone`, children first (as a move marker drops a row: a shared
    /// transaction of a dropped import batch stays, filed under this device's placeholder batch), with tracking off
    /// (`SyncChangeTracker.applyingIncoming`), so nothing is queued. Also forgets their identities, clocks, pending
    /// entries, presence, conflicts and file references; whatever is staged from `zone`; the companion records of
    /// `zone` (clearing the private account columns they filled in); the zone's tombstones, moves, token, readiness
    /// and key marker. A row of another zone that still points at a dropped row and can't lose it is kept, logged for
    /// attention. Returns how many rows were dropped. Runs in the caller's transaction.
    @discardableResult
    public static func dropZone(_ zone: String, db: Database) throws -> Int {
        try SyncChangeTracker.applyingIncoming(db: db) {
            var dropped: Set<String> = []
            // Parents are listed before children in `SyncSchema.tables`: children go first.
            for schema in SyncSchema.tables.reversed() where try db.tableExists(schema.name) {
                let records = try Row.fetchAll(db, sql: "SELECT uuid, localId FROM syncRecord WHERE tableName = ? AND zone = ? ORDER BY rowid DESC",
                                               arguments: [schema.name, zone])
                for record in records {
                    let uuid: String = record["uuid"]
                    let localId: Int64 = record["localId"]
                    if try deleteRow(schema, localId: localId, uuid: uuid, zone: zone, db: db) { dropped.insert(uuid) }
                }
            }
            // Rows of other zones a cascade took with a dropped row: forgotten like it.
            for table in SyncSchema.tables where try db.tableExists(table.name) {
                let gone = try String.fetchAll(db, sql: """
                    SELECT s.uuid FROM syncRecord s WHERE s.tableName = ?
                    AND NOT EXISTS (SELECT 1 FROM \(SyncChangeTracker.quoted(table.name)) t WHERE t.\(SyncChangeTracker.quoted(table.localIdColumn)) = s.localId)
                    """, arguments: [table.name])
                gone.forEach { dropped.insert($0) }
            }
            for uuid in dropped { try forget(uuid: uuid, db: db) }
            try dropCompanions(zone: zone, db: db)
            try db.execute(sql: "DELETE FROM syncStaging WHERE json_extract(payloadJSON, '$.zone') = ?", arguments: [zone])
            try db.execute(sql: "DELETE FROM syncPresence WHERE zone = ?", arguments: [zone])
            try db.execute(sql: "DELETE FROM syncTombstone WHERE zone = ?", arguments: [zone])
            try db.execute(sql: "DELETE FROM syncZoneMove WHERE zone = ? OR toZone = ?", arguments: [zone, zone])
            try db.execute(sql: "DELETE FROM syncZoneCleanup WHERE zone = ?", arguments: [zone])
            try db.execute(sql: "DELETE FROM syncState WHERE key IN (?, ?, ?, ?)",
                           arguments: [SyncEngineCore.tokenKey(zone), SyncEngineCore.zoneKey(zone), SyncZoneKeys.stateKey(zone),
                                       SyncZoneKeys.legacyStateKey(zone)])
            log.notice("Sync: dropped this device's copy of a zone (\(dropped.count, privacy: .public) records)")
            return dropped.count
        }
    }

    /// Drops every private zone this device holds anything of (`private-*`), never the household. Returns how many
    /// rows were dropped.
    @discardableResult
    public static func dropPrivateZones(db: Database) throws -> Int {
        var zones = Set(try String.fetchAll(db, sql: "SELECT DISTINCT zone FROM syncRecord"))
        zones.formUnion(try String.fetchAll(db, sql: "SELECT DISTINCT zone FROM syncCompanion"))
        zones.formUnion(try String.fetchAll(db, sql: "SELECT DISTINCT json_extract(payloadJSON, '$.zone') FROM syncStaging WHERE json_valid(payloadJSON)"))
        let tokenPrefix = SyncEngineCore.tokenKey("")
        for key in try String.fetchAll(db, sql: "SELECT key FROM syncState WHERE key LIKE ?", arguments: [tokenPrefix + "%"]) {
            zones.insert(String(key.dropFirst(tokenPrefix.count)))
        }
        var dropped = 0
        for zone in zones.sorted() where SyncZones.personUuid(ofPrivateZone: zone) != nil {
            dropped += try dropZone(zone, db: db)
        }
        return dropped
    }

    /// Deletes one row (an import batch's rows of other zones stay, filed under the placeholder). False when a row of
    /// another zone still points at it: kept, logged.
    private static func deleteRow(_ schema: SyncTableSchema, localId: Int64, uuid: String, zone: String, db: Database) throws -> Bool {
        try db.execute(sql: "SAVEPOINT syncDropRow")
        do {
            if schema.name == "importBatch",
               let account = try Int64.fetchOne(db, sql: "SELECT accountId FROM importBatch WHERE id = ?", arguments: [localId]),
               try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM transaction_ WHERE importBatchId = ?)", arguments: [localId]) == true {
                try db.execute(sql: "UPDATE transaction_ SET importBatchId = ? WHERE importBatchId = ?",
                               arguments: [try SyncTranslator.placeholderBatch(accountId: account, db: db), localId])
            }
            if schema.name == "account" {
                // This device's own placeholder batches for the account, emptied by the drop, go with it.
                let placeholders = try Int64.fetchAll(db, sql: """
                    SELECT b.id FROM importBatch b JOIN syncRecord s ON s.tableName = 'importBatch' AND s.localId = b.id AND s.zone = ?
                    WHERE b.accountId = ? AND NOT EXISTS (SELECT 1 FROM transaction_ t WHERE t.importBatchId = b.id)
                    """, arguments: [SyncZoneSet.deviceOnlyZone, localId])
                for batch in placeholders {
                    try db.execute(sql: "DELETE FROM importBatch WHERE id = ?", arguments: [batch])
                    try db.execute(sql: "DELETE FROM syncRecord WHERE tableName = 'importBatch' AND localId = ?", arguments: [batch])
                }
            }
            try db.execute(sql: "DELETE FROM \(SyncChangeTracker.quoted(schema.name)) WHERE \(SyncChangeTracker.quoted(schema.localIdColumn)) = ?",
                           arguments: [localId])
            try db.execute(sql: "RELEASE syncDropRow")
            return true
        } catch let error as DatabaseError where error.resultCode == .SQLITE_CONSTRAINT {
            try db.execute(sql: "ROLLBACK TO syncDropRow")
            try db.execute(sql: "RELEASE syncDropRow")
            try SyncMerge.logConflict(table: schema.name, uuid: uuid, field: "*",
                                      losing: .string(SyncTranslator.needsAttention + "its zone was removed from this device, but records here still point at it"),
                                      winner: nil, loser: nil, db: db, now: Date())
            return false
        }
    }

    /// A dropped record's identity, clocks, pending entry, presence, batch membership, conflict entries and file
    /// reference.
    private static func forget(uuid: String, db: Database) throws {
        if let row = try Row.fetchOne(db, sql: "SELECT tableName, localId FROM syncRecord WHERE uuid = ?", arguments: [uuid]) {
            try db.execute(sql: "DELETE FROM syncFieldClock WHERE tableName = ? AND localId = ?",
                           arguments: [row["tableName"] as String, row["localId"] as Int64])
        }
        try db.execute(sql: "DELETE FROM syncRecord WHERE uuid = ?", arguments: [uuid])
        try db.execute(sql: "DELETE FROM syncPending WHERE uuid = ?", arguments: [uuid])
        try db.execute(sql: "DELETE FROM syncPresence WHERE uuid = ?", arguments: [uuid])
        try db.execute(sql: "DELETE FROM syncBatchMember WHERE uuid = ?", arguments: [uuid])
        try db.execute(sql: "DELETE FROM syncConflict WHERE uuid = ?", arguments: [uuid])
        try db.execute(sql: "DELETE FROM syncAccessRevert WHERE uuid = ?", arguments: [uuid])
        try db.execute(sql: "DELETE FROM syncState WHERE key IN (?, ?)",
                       arguments: [SyncDocumentFile.referencePrefix + uuid, SyncDocumentFile.failedPrefix + uuid])
    }

    /// `zone`'s `accountDetails` companions: the private columns they filled in on a household stub are cleared
    /// (with their clocks), and their stamps forgotten.
    private static func dropCompanions(zone: String, db: Database) throws {
        let names = try String.fetchAll(db, sql: "SELECT uuid FROM syncCompanion WHERE recordType = ? AND zone = ?",
                                        arguments: [SyncZoneRouter.companionRecordType, zone])
        guard !names.isEmpty else { return }
        let declared = Set(try db.columns(in: "account").map(\.name))
        let columns = SyncZoneRouter.privateAccountColumns.filter(declared.contains)
        for name in names {
            if let account = try SyncCompanions.account(named: name, db: db), !columns.isEmpty {
                try db.execute(sql: "UPDATE account SET \(columns.map { "\(SyncChangeTracker.quoted($0)) = NULL" }.joined(separator: ", ")) WHERE id = ?",
                               arguments: [account.id])
                let fields = columns.flatMap { [$0, SyncMerge.basePrefix + $0] }
                let fieldPlaceholders = fields.map { _ in "?" }.joined(separator: ", ")
                try db.execute(sql: "DELETE FROM syncFieldClock WHERE tableName = 'account' AND localId = ? AND field IN (\(fieldPlaceholders))",
                               arguments: StatementArguments([account.id] + fields.map { $0 as (any DatabaseValueConvertible) }))
            }
            try SyncCompanions.remove(name: name, db: db)
        }
    }
}

/// Whether this iPhone's iCloud user changed since it last synced (step 7a): only a known, different record name drops
/// the private zones' data. Undetermined (no account, offline, an account-status blip) never drops anything.
public enum SyncAccountSwitch {
    /// `syncState` key of the iCloud user record name this device's data was last synced for (local only).
    public static let deviceUserKey = "deviceICloudUser"

    public enum Action: Equatable, Sendable {
        /// Nothing to do: the same user, or the user can't be told now.
        case keep
        /// The first user seen here: stored, nothing dropped.
        case remember
        /// A different user: drop the private zones' data (`SyncLocalData.dropPrivateZones`). The new name is stored.
        case dropPrivate
    }

    /// The record name stored for this device, if any.
    public static func stored(db: Database) throws -> String? {
        try Data.fetchOne(db, sql: "SELECT value FROM syncState WHERE key = ?", arguments: [deviceUserKey])
            .flatMap { String(data: $0, encoding: .utf8) }
    }

    /// What `current` (this iPhone's iCloud user's record name now; nil when it can't be told) means for the data here.
    /// Stores `current` when it is new or different. Run the drop in the same transaction.
    public static func check(current: String?, db: Database) throws -> Action {
        guard let current, !current.isEmpty else { return .keep }
        let stored = try stored(db: db)
        if stored == current { return .keep }
        try SyncImportGate.setState(Data(current.utf8), key: deviceUserKey, db: db, now: Date())
        return stored == nil ? .remember : .dropPrivate
    }

    /// `check`, then on `dropPrivate` the private zones' data is dropped, in the same transaction (the iPhone runs this
    /// with its engine stopped). Local only: nothing is queued or sent.
    public static func apply(current: String?, db: Database) throws -> Action {
        let action = try check(current: current, db: db)
        if action == .dropPrivate { try SyncLocalData.dropPrivateZones(db: db) }
        return action
    }
}
