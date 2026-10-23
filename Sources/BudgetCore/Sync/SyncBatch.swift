import Foundation
import GRDB
import os

/// What an `importRun` record says about its batch (sync spec §5.2).
public struct SyncBatchManifest: Codable, Equatable, Sendable {
    /// 1 for the import, 2 for its Undo: each is a batch of its own.
    public var generation: Int
    /// True while the sender is uploading the batch; false once it all went (the run is sent again,
    /// closed). A receiver applies a closed batch's records as they come.
    public var isOpen: Bool
    /// The manifest proper: how many records of each type the batch saves (the run itself not counted).
    public var counts: [String: Int]
    /// The records the batch deletes. They travel as plain deletes, which carry no run; the receiver holds
    /// them until the batch applies, and applies them with it.
    public var deletes: [String]
    /// Records the batch brings back that it had deleted (an Undo re-inserting what its import removed,
    /// ruling R7): receivers that hold their tombstone take them back.
    public var revives: [String]

    public init(generation: Int, isOpen: Bool, counts: [String: Int] = [:], deletes: [String] = [], revives: [String] = []) {
        self.generation = generation
        self.isOpen = isOpen
        self.counts = counts
        self.deletes = deletes
        self.revives = revives
    }
}

/// Import batches (sync spec §5.2): what a confirmed import, or its Undo, writes arrives on other devices
/// all at once or not at all.
///
/// Sending:
/// - `mark` before the run's first write and `open` after its last, in the same transaction, make every
///   record the run wrote (each pending change since the mark) a member of the run's batch.
/// - While the batch is open, outgoing members carry `importRunUuid` and the generation, and the run's
///   record carries the manifest, computed when it is sent.
/// - The run's record is queued first (rowid order), so a receiver knows the batch before its members
///   and its deletes. The engine sends pending changes in that order.
/// - Once nothing of the batch is pending any more, `closeUploaded` closes it and queues the run again;
///   later edits of its records are ordinary edits.
///
/// Receiving (inside `SyncTranslator.apply`):
/// - members and the open run wait in `syncStaging` (with the run's UUID) until the counts are all there,
///   or the run arrives closed;
/// - then they apply in one savepoint of the caller's transaction, with the batch's deletes.
public enum SyncBatch {
    private static let log = Logger(subsystem: "com.personal.budget", category: "Sync")

    static let waitingForBatch = "waiting for its import batch"

    enum State: String {
        /// This device is uploading the batch.
        case sending
        /// Received open, not all here yet.
        case open
        /// Received open and applied here; the sender hasn't closed it yet.
        case complete
        /// Fully uploaded.
        case closed
    }

    struct Batch {
        var generation: Int
        var state: State
        var manifest: SyncBatchManifest?
        var revives: [String]
    }

    // MARK: Sending

    /// Where the pending changes stand now: call before a run's first write.
    public static func mark(db: Database) throws -> Int64 {
        guard try db.tableExists("syncPending") else { return 0 }
        return try Int64.fetchOne(db, sql: "SELECT COALESCE(MAX(revision), 0) FROM syncPending") ?? 0
    }

    /// Opens the next batch of run `runId`: every record queued since `mark` is a member. `revives` are the
    /// records it brings back under their old identity (`reviveIdentity`). Returns the manifest as it stands,
    /// or nil when the run has no sync identity (sync bookkeeping missing).
    @discardableResult
    public static func open(runId: Int64, since mark: Int64, revives: [String] = [], db: Database) throws -> SyncBatchManifest? {
        guard try db.tableExists("syncBatch"),
              let run = try SyncRecordStore.existingUUID(table: ImportRun.databaseTableName, localId: runId, db: db) else { return nil }
        let generation = (try Int.fetchOne(db, sql: "SELECT generation FROM syncBatch WHERE runUuid = ?", arguments: [run]) ?? 0) + 1
        try db.execute(sql: "DELETE FROM syncBatchMember WHERE runUuid = ?", arguments: [run])
        try db.execute(sql: """
            INSERT INTO syncBatchMember(uuid, runUuid, tableName)
            SELECT uuid, ?, tableName FROM syncPending WHERE revision > ? AND uuid <> ? ORDER BY rowid
            ON CONFLICT(uuid) DO UPDATE SET runUuid = excluded.runUuid, tableName = excluded.tableName
            """, arguments: [run, mark, run])
        try save(run: run, Batch(generation: generation, state: .sending, manifest: nil, revives: revives), db: db)
        // The run goes with its batch even if the run itself didn't change.
        try SyncMerge.queue(uuid: run, table: ImportRun.databaseTableName, localId: runId, kind: .update, db: db)
        return try manifest(runUuid: run, db: db)
    }

    /// Closes every batch this device was sending whose records (and run) have all been uploaded, and
    /// queues each run again so receivers learn it is closed. Returns the runs closed. The engine calls it
    /// after acknowledging an upload; the lease can be released once the run's close is uploaded.
    @discardableResult
    public static func closeUploaded(db: Database) throws -> [String] {
        var closed: [String] = []
        for run in try String.fetchAll(db, sql: "SELECT runUuid FROM syncBatch WHERE state = 'sending' ORDER BY runUuid") {
            let waiting = try Bool.fetchOne(db, sql: """
                SELECT EXISTS (SELECT 1 FROM syncPending WHERE uuid = ? OR uuid IN (SELECT uuid FROM syncBatchMember WHERE runUuid = ?))
                """, arguments: [run, run]) ?? true
            guard !waiting, var batch = try batch(run: run, db: db) else { continue }
            batch.state = .closed
            batch.revives = []
            try save(run: run, batch, db: db)
            try db.execute(sql: "DELETE FROM syncBatchMember WHERE runUuid = ?", arguments: [run])
            if let localId = try SyncRecordStore.localId(table: ImportRun.databaseTableName, uuid: run, db: db) {
                try SyncMerge.queue(uuid: run, table: ImportRun.databaseTableName, localId: localId, kind: .update, db: db)
            }
            closed.append(run)
        }
        return closed
    }

    /// The manifest the run's record carries when sent now: computed from the members while this device
    /// sends the batch, as received otherwise; nil for a run that never was a batch here.
    public static func manifest(runUuid run: String, db: Database) throws -> SyncBatchManifest? {
        guard let batch = try batch(run: run, db: db) else { return nil }
        switch batch.state {
        case .sending:
            var counts: [String: Int] = [:]
            for row in try Row.fetchAll(db, sql: """
                SELECT m.tableName, COUNT(*) FROM syncBatchMember m JOIN syncRecord s ON s.uuid = m.uuid
                WHERE m.runUuid = ? GROUP BY m.tableName
                """, arguments: [run]) {
                counts[row[0]] = row[1]
            }
            let deletes = try String.fetchAll(db, sql: """
                SELECT m.uuid FROM syncBatchMember m WHERE m.runUuid = ? AND NOT EXISTS (SELECT 1 FROM syncRecord s WHERE s.uuid = m.uuid)
                ORDER BY m.uuid
                """, arguments: [run])
            return SyncBatchManifest(generation: batch.generation, isOpen: true, counts: counts, deletes: deletes, revives: batch.revives.sorted())
        case .open, .complete:
            return batch.manifest ?? SyncBatchManifest(generation: batch.generation, isOpen: true)
        case .closed:
            return SyncBatchManifest(generation: batch.generation, isOpen: false)
        }
    }

    /// Tags an outgoing payload: a member of a batch being sent gets its run and generation; a run's
    /// record gets its manifest.
    static func decorate(_ payload: inout SyncPayload, db: Database) throws {
        if payload.recordType == ImportRun.databaseTableName {
            payload.manifest = try manifest(runUuid: payload.recordName, db: db)
        }
        if let row = try Row.fetchOne(db.cachedStatement(sql: """
            SELECT m.runUuid, b.generation FROM syncBatchMember m JOIN syncBatch b ON b.runUuid = m.runUuid AND b.state = 'sending'
            WHERE m.uuid = ?
            """), arguments: [payload.recordName]) {
            payload.importRunUuid = row[0]
            payload.batchGeneration = row[1]
        }
    }

    /// After an Undo re-inserted a row its run had deleted: the row takes back the identity it had (its
    /// tombstone's UUID) instead of the new one its insert got, and is queued under it, so every device
    /// brings back the same record (ruling R7). Returns that UUID, or nil when it had none.
    public static func reviveIdentity(table: String, localId: Int64, db: Database) throws -> String? {
        guard SyncSchema.table(table) != nil, localId != 0, try db.tableExists("syncTombstone"),
              let tombstone = try SyncTombstoneRow.fetchOne(db, sql: """
                SELECT * FROM syncTombstone WHERE tableName = ? AND localId = ? AND mergedInto IS NULL ORDER BY deletedAt DESC LIMIT 1
                """, arguments: [table, localId]) else { return nil }
        let old = tombstone.uuid
        if let fresh = try SyncRecordStore.existingUUID(table: table, localId: localId, db: db) {
            if fresh != old {
                try db.execute(sql: "DELETE FROM syncPending WHERE uuid = ?", arguments: [fresh])
                try db.execute(sql: "UPDATE syncRecord SET uuid = ?, zone = ? WHERE tableName = ? AND localId = ?",
                               arguments: [old, tombstone.zone, table, localId])
            }
        } else {
            try db.execute(sql: "INSERT INTO syncRecord(tableName, localId, uuid, zone) VALUES (?, ?, ?, ?)",
                           arguments: [table, localId, old, tombstone.zone])
        }
        try db.execute(sql: "DELETE FROM syncTombstone WHERE uuid = ?", arguments: [old])
        try db.execute(sql: """
            INSERT INTO syncPending(uuid, tableName, localId, kind, revision)
            VALUES (?, ?, ?, 'insert', (SELECT COALESCE(MAX(revision), 0) + 1 FROM syncPending))
            ON CONFLICT(uuid) DO UPDATE SET localId = excluded.localId, kind = 'insert', revision = excluded.revision
            """, arguments: [old, table, localId])
        return old
    }

    // MARK: Receiving

    struct Routed {
        /// Changes to apply as they are.
        var direct: [SyncIncomingChange] = []
        /// Changes held for their batch.
        var results: [String: IncomingResult] = [:]
        /// Runs whose batch may now be complete, in arrival order.
        var runs: [String] = []
    }

    /// Splits incoming changes into those that apply now and those that wait for their batch. A run's
    /// record goes first: it says which batch its members belong to.
    static func route(_ changes: [SyncIncomingChange], db: Database, now: Date) throws -> Routed {
        var routed = Routed()
        func touch(_ run: String) { if !routed.runs.contains(run) { routed.runs.append(run) } }
        var held: Set<String> = []
        for case .save(let payload) in changes where payload.recordType == ImportRun.databaseTableName {
            guard let manifest = payload.manifest, try receive(header: payload, manifest, db: db) else { continue }
            try stage(payload, run: payload.recordName, generation: manifest.generation, db: db, now: now)
            routed.results[payload.recordName] = .staged(waitingForBatch)
            held.insert(payload.recordName)
            touch(payload.recordName)
        }
        let open = try openDeletes(db: db)
        for change in changes {
            switch change {
            case .save(let payload):
                if held.contains(payload.recordName) { continue }
                if let run = payload.importRunUuid, try waits(member: payload, run: run, db: db) {
                    try stage(payload, run: run, generation: payload.batchGeneration ?? 0, db: db, now: now)
                    routed.results[payload.recordName] = .staged(waitingForBatch)
                    touch(run)
                } else {
                    routed.direct.append(change)
                }
            case .delete(let name, _):
                if open[name] != nil {
                    // Applied with its batch (`flushIfComplete`).
                    routed.results[name] = .staged(waitingForBatch)
                } else {
                    routed.direct.append(change)
                }
            }
        }
        return routed
    }

    /// Takes a run's record's manifest into this device's view of the batch. True when the record waits
    /// with its batch; false when it applies as an ordinary record (a stale one, this device's own, or one
    /// whose batch already applied here).
    private static func receive(header payload: SyncPayload, _ manifest: SyncBatchManifest, db: Database) throws -> Bool {
        let run = payload.recordName
        let known = try batch(run: run, db: db)
        if let known {
            if known.state == .sending { return false }
            if manifest.generation < known.generation { return false }
            if manifest.generation == known.generation {
                switch (known.state, manifest.isOpen) {
                case (.complete, true), (.closed, _):
                    return false
                case (.complete, false):
                    try save(run: run, Batch(generation: known.generation, state: .closed, manifest: known.manifest, revives: []), db: db)
                    return false
                case (.open, false):
                    // Closed: what is held applies now, deletes and revivals as the open manifest said.
                    var kept = known.manifest ?? manifest
                    kept.isOpen = false
                    try save(run: run, Batch(generation: known.generation, state: .closed, manifest: kept, revives: []), db: db)
                    return true
                case (.open, true), (.sending, _):
                    break
                }
            }
        }
        try save(run: run, Batch(generation: manifest.generation, state: manifest.isOpen ? .open : .closed, manifest: manifest, revives: []), db: db)
        return true
    }

    /// Whether a member waits for its batch: when its run's batch isn't known here, is newer, or is the open
    /// one not yet complete. A member of a batch this device sends, or of one already applied or closed,
    /// applies at once.
    private static func waits(member payload: SyncPayload, run: String, db: Database) throws -> Bool {
        guard let batch = try batch(run: run, db: db) else { return true }
        let generation = payload.batchGeneration ?? 0
        switch batch.state {
        case .sending: return false
        case .open: return generation >= batch.generation
        case .complete, .closed: return generation > batch.generation
        }
    }

    /// The deletes of every open batch here, with their run.
    private static func openDeletes(db: Database) throws -> [String: String] {
        var result: [String: String] = [:]
        for row in try Row.fetchAll(db, sql: "SELECT runUuid, manifestJSON FROM syncBatch WHERE state = 'open' AND manifestJSON IS NOT NULL") {
            guard let manifest = decode(row["manifestJSON"]) else { continue }
            for name in manifest.deletes { result[name] = row["runUuid"] }
        }
        return result
    }

    /// Applies the run's staged batch in one transaction when it is complete here (every count of its
    /// manifest met, or the run closed); true when the batch is complete here (now or before), false while
    /// it waits. Inside the caller's transaction.
    public static func applyIfComplete(runUuid: String, db: Database, deviceUser: String? = nil, now: Date = Date()) throws -> Bool {
        guard db.isInsideTransaction else { throw SyncTranslatorError.notInTransaction }
        return try SyncChangeTracker.applyingIncoming(db: db) {
            try flushIfComplete(run: runUuid, db: db, deviceUser: deviceUser, now: now).complete
        }
    }

    static func flushIfComplete(run: String, db: Database, deviceUser: String?, now: Date) throws -> (complete: Bool, results: [String: IncomingResult]) {
        guard var batch = try batch(run: run, db: db) else { return (false, [:]) }
        if batch.state == .sending { return (true, [:]) }
        let staged = try SyncStagingRow.filter(Column("importRunUuid") == run).order(Column("id")).fetchAll(db)
        let current = staged.filter { $0.uuid == run || ($0.batchGeneration ?? 0) <= batch.generation }
        let manifest = batch.manifest ?? SyncBatchManifest(generation: batch.generation, isOpen: batch.state == .open)
        if batch.state == .open {
            var arrived: [String: Int] = [:]
            for row in staged where row.uuid != run && row.batchGeneration == batch.generation { arrived[row.tableName, default: 0] += 1 }
            guard manifest.counts.allSatisfy({ arrived[$0.key, default: 0] >= $0.value }) else { return (false, [:]) }
        } else if current.isEmpty {
            return (true, [:])
        }
        var changes: [SyncIncomingChange] = []
        for row in current {
            guard let payload = try? JSONDecoder().decode(SyncPayload.self, from: Data(row.payloadJSON.utf8)) else {
                log.error("Sync staging row of an import batch can't be read; marked for attention")
                try db.execute(sql: "UPDATE syncStaging SET importRunUuid = NULL, reason = ? WHERE id = ?",
                               arguments: [SyncTranslator.needsAttention + "unreadable payload", row.id])
                continue
            }
            changes.append(.save(payload))
        }
        // Deletes and revivals apply with the batch that announced them (an open one, or one closed after
        // it was seen open).
        let deletes = manifest.deletes
        changes += deletes.map { SyncIncomingChange.delete(recordName: $0, recordType: nil) }
        var revivals: [String: Int64] = [:]
        for name in manifest.revives {
            if let tombstone = try SyncTombstoneRow.fetchOne(db, key: name), tombstone.mergedInto == nil { revivals[name] = tombstone.localId }
        }
        var results: [String: IncomingResult] = [:]
        try db.inSavepoint {
            let ids = current.compactMap(\.id)
            if !ids.isEmpty { try db.execute(sql: "DELETE FROM syncStaging WHERE id IN (\(ids.map(String.init).joined(separator: ",")))") }
            results = try SyncTranslator.applyChanges(changes, db: db, deviceUser: deviceUser, now: now, revivals: revivals)
            return .commit
        }
        if batch.state == .open {
            batch.state = .complete
        }
        // Applied: its deletes and revivals are done.
        batch.manifest?.deletes = []
        batch.manifest?.revives = []
        try save(run: run, batch, db: db)
        return (true, results)
    }

    // MARK: Storage

    private static func stage(_ payload: SyncPayload, run: String, generation: Int, db: Database, now: Date) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try db.execute(sql: """
            INSERT INTO syncStaging(tableName, uuid, payloadJSON, reason, importRunUuid, receivedAt, batchGeneration) VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(uuid) DO UPDATE SET tableName = excluded.tableName, payloadJSON = excluded.payloadJSON, reason = excluded.reason,
                importRunUuid = excluded.importRunUuid, receivedAt = excluded.receivedAt, batchGeneration = excluded.batchGeneration
            """, arguments: [payload.recordType, payload.recordName, String(decoding: try encoder.encode(payload), as: UTF8.self),
                             waitingForBatch, run, now, generation])
    }

    static func batch(run: String, db: Database) throws -> Batch? {
        guard let row = try Row.fetchOne(db.cachedStatement(sql: "SELECT generation, state, manifestJSON, revivesJSON FROM syncBatch WHERE runUuid = ?"),
                                         arguments: [run]),
              let state = State(rawValue: row["state"]) else { return nil }
        let revives = (row["revivesJSON"] as String?).flatMap { try? JSONDecoder().decode([String].self, from: Data($0.utf8)) } ?? []
        return Batch(generation: row["generation"], state: state, manifest: decode(row["manifestJSON"]), revives: revives)
    }

    private static func save(run: String, _ batch: Batch, db: Database) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let manifest = try batch.manifest.map { String(decoding: try encoder.encode($0), as: UTF8.self) }
        let revives = batch.revives.isEmpty ? nil : String(decoding: try encoder.encode(batch.revives), as: UTF8.self)
        try db.execute(sql: """
            INSERT INTO syncBatch(runUuid, generation, state, manifestJSON, revivesJSON) VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(runUuid) DO UPDATE SET generation = excluded.generation, state = excluded.state,
                manifestJSON = excluded.manifestJSON, revivesJSON = excluded.revivesJSON
            """, arguments: [run, batch.generation, batch.state.rawValue, manifest, revives])
    }

    private static func decode(_ json: String?) -> SyncBatchManifest? {
        json.flatMap { try? JSONDecoder().decode(SyncBatchManifest.self, from: Data($0.utf8)) }
    }
}
