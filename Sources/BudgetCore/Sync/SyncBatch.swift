import Foundation
import GRDB
import os

/// What an `importRun` record says about its batch (sync spec §5.2).
public struct SyncBatchManifest: Codable, Equatable, Sendable {
    /// 1 for the import, 2 for its Undo: each is a batch of its own.
    public var generation: Int
    /// True while the sender is uploading the batch; false once it all went (the run is sent again,
    /// closed, with its final counts).
    public var isOpen: Bool
    /// The manifest proper: how many tagged records of each type the batch saves (the run itself not
    /// counted). Open: this generation's members. Closed: every member of the run still on the server,
    /// whatever generation it carries.
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
///   record the run wrote (each pending change since the mark) a member of the run's batch, generation n.
/// - Members carry `importRunUuid` and their generation every time they are sent (the tag is permanent,
///   so the server's copy keeps it), and the run's record carries the manifest, computed when it is sent.
/// - The run's record is queued first (rowid order), so a receiver knows the batch before its members
///   and its deletes. The engine sends pending changes in that order.
/// - Once nothing of the batch is pending any more, `closeUploaded` closes it and queues the run again with
///   its final counts.
///
/// Receiving (inside `SyncTranslator.apply`):
/// - members and the run wait in `syncStaging` (with the run's UUID) until the manifest's counts are all
///   there, open or closed; a device that was offline for the whole upload sees only the closed run, and
///   its members may come over several fetch pages, so they wait too;
/// - then they apply in one savepoint of the caller's transaction, with the batch's deletes, and only if
///   every record of it applies (a record waiting for a parent outside the batch holds it all back);
/// - a closed batch whose counts can't be met any more (a member edited since by a device that didn't tag
///   it, or deleted) applies at `flushClosed`, which the engine calls once a fetch has caught up.
public enum SyncBatch {
    private static let log = Logger(subsystem: "com.personal.budget", category: "Sync")

    static let waitingForBatch = "waiting for its import batch"

    enum State: String {
        /// This device is uploading the batch.
        case sending
        /// This device uploaded the batch and closed it.
        case sent
        /// Received open, not applied yet.
        case open
        /// Received open and applied here; the sender hasn't closed it yet.
        case complete
        /// Received closed, not applied yet.
        case closed
        /// Received closed (or open, then closed) and applied here.
        case done

        var isApplied: Bool { self == .complete || self == .done }
        var isWaiting: Bool { self == .open || self == .closed }
        var isOwn: Bool { self == .sending || self == .sent }
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

    /// Opens the next batch of run `runId`: every record queued since `mark` is a member of it. `revives` are
    /// the records it brings back under their old identity (`reviveIdentity`). Returns the manifest as it
    /// stands, or nil when the run has no sync identity (sync bookkeeping missing).
    @discardableResult
    public static func open(runId: Int64, since mark: Int64, revives: [String] = [], db: Database) throws -> SyncBatchManifest? {
        guard try db.tableExists("syncBatch"),
              let run = try SyncRecordStore.existingUUID(table: ImportRun.databaseTableName, localId: runId, db: db) else { return nil }
        let generation = (try Int.fetchOne(db, sql: "SELECT generation FROM syncBatch WHERE runUuid = ?", arguments: [run]) ?? 0) + 1
        try db.execute(sql: """
            INSERT INTO syncBatchMember(uuid, runUuid, tableName, generation)
            SELECT uuid, ?, tableName, ? FROM syncPending WHERE revision > ? AND uuid <> ? ORDER BY rowid
            ON CONFLICT(uuid) DO UPDATE SET runUuid = excluded.runUuid, tableName = excluded.tableName, generation = excluded.generation
            """, arguments: [run, generation, mark, run])
        try save(run: run, Batch(generation: generation, state: .sending, manifest: nil, revives: revives), db: db)
        // The run goes with its batch even if the run itself didn't change.
        try SyncMerge.queue(uuid: run, table: ImportRun.databaseTableName, localId: runId, kind: .update, db: db)
        return try manifest(runUuid: run, db: db)
    }

    /// Closes every batch this device was sending whose records (and run) have all been uploaded, and
    /// queues each run again so receivers learn it is closed and its final counts. Returns the runs closed.
    /// The engine calls it after acknowledging an upload; the lease can be released once the run's close is
    /// uploaded.
    @discardableResult
    public static func closeUploaded(db: Database) throws -> [String] {
        var closed: [String] = []
        for run in try String.fetchAll(db, sql: "SELECT runUuid FROM syncBatch WHERE state = 'sending' ORDER BY runUuid") {
            let waiting = try Bool.fetchOne(db, sql: """
                SELECT EXISTS (SELECT 1 FROM syncPending WHERE uuid = ? OR uuid IN (SELECT uuid FROM syncBatchMember WHERE runUuid = ?))
                """, arguments: [run, run]) ?? true
            guard !waiting, var batch = try batch(run: run, db: db) else { continue }
            batch.state = .sent
            batch.revives = []
            try save(run: run, batch, db: db)
            if let localId = try SyncRecordStore.localId(table: ImportRun.databaseTableName, uuid: run, db: db) {
                try SyncMerge.queue(uuid: run, table: ImportRun.databaseTableName, localId: localId, kind: .update, db: db)
            }
            closed.append(run)
        }
        return closed
    }

    /// The manifest the run's record carries when sent now; nil for a run that never was a batch here.
    ///
    /// Why the counts hold:
    /// - Open (`sending`): this generation's members with a record here, counted when the run's record is
    ///   sent. The run is queued first and the lease keeps any other device from writing a batch meanwhile;
    ///   a member deleted after the run went out leaves its count one short, which the close repairs.
    /// - Closed (`sent`): counted when the close is sent, after every member was uploaded: each member is on
    ///   the server with its tag (tags are permanent, so this device's later edits keep it). A member edited
    ///   since by a device that doesn't know it, or deleted after the close, makes the count unreachable;
    ///   such a batch applies at `flushClosed`.
    /// - Received: as received (a device re-sending a run it received passes the sender's manifest on).
    public static func manifest(runUuid run: String, db: Database) throws -> SyncBatchManifest? {
        guard let batch = try batch(run: run, db: db) else { return nil }
        switch batch.state {
        case .sending:
            let counts = try liveCounts(run: run, generation: batch.generation, db: db)
            let deletes = try String.fetchAll(db, sql: """
                SELECT m.uuid FROM syncBatchMember m
                WHERE m.runUuid = ? AND m.generation = ? AND NOT EXISTS (SELECT 1 FROM syncRecord s WHERE s.uuid = m.uuid)
                ORDER BY m.uuid
                """, arguments: [run, batch.generation])
            return SyncBatchManifest(generation: batch.generation, isOpen: true, counts: counts, deletes: deletes, revives: batch.revives.sorted())
        case .sent:
            return SyncBatchManifest(generation: batch.generation, isOpen: false, counts: try liveCounts(run: run, generation: nil, db: db))
        case .open, .complete:
            return batch.manifest ?? SyncBatchManifest(generation: batch.generation, isOpen: true)
        case .closed, .done:
            var manifest = batch.manifest ?? SyncBatchManifest(generation: batch.generation, isOpen: false)
            manifest.isOpen = false
            manifest.deletes = []
            manifest.revives = []
            return manifest
        }
    }

    /// Members with a record here, by type: of one generation, or of every one.
    private static func liveCounts(run: String, generation: Int?, db: Database) throws -> [String: Int] {
        var counts: [String: Int] = [:]
        for row in try Row.fetchAll(db, sql: """
            SELECT m.tableName, COUNT(*) FROM syncBatchMember m JOIN syncRecord s ON s.uuid = m.uuid
            WHERE m.runUuid = ? AND (? IS NULL OR m.generation = ?) GROUP BY m.tableName
            """, arguments: [run, generation, generation]) {
            counts[row[0]] = row[1]
        }
        return counts
    }

    /// Tags an outgoing payload: a member of a run's batch gets its run and generation; a run's record gets
    /// its manifest.
    static func decorate(_ payload: inout SyncPayload, db: Database) throws {
        if payload.recordType == ImportRun.databaseTableName {
            payload.manifest = try manifest(runUuid: payload.recordName, db: db)
        }
        if let row = try Row.fetchOne(db.cachedStatement(sql: "SELECT runUuid, generation FROM syncBatchMember WHERE uuid = ?"),
                                      arguments: [payload.recordName]) {
            payload.importRunUuid = row[0]
            payload.batchGeneration = row[1]
        }
    }

    /// After an Undo re-inserted a row its run had deleted: the row takes back the identity the run deleted
    /// (`uuid`, recorded in the change log; for a log from before that, the latest tombstone at its local id)
    /// instead of the new one its insert got, and is queued under it, so every device brings back the same
    /// record (ruling R7). Returns that UUID, or nil when it had none.
    public static func reviveIdentity(table: String, localId: Int64, uuid: String? = nil, db: Database) throws -> String? {
        guard SyncSchema.table(table) != nil, localId != 0, try db.tableExists("syncTombstone") else { return nil }
        let tombstone: SyncTombstoneRow?
        if let uuid {
            tombstone = try SyncTombstoneRow.fetchOne(db, key: uuid).flatMap { $0.tableName == table && $0.mergedInto == nil ? $0 : nil }
        } else {
            tombstone = try SyncTombstoneRow.fetchOne(db, sql: """
                SELECT * FROM syncTombstone WHERE tableName = ? AND localId = ? AND mergedInto IS NULL ORDER BY deletedAt DESC LIMIT 1
                """, arguments: [table, localId])
        }
        guard let tombstone else { return nil }
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
    }

    /// Splits incoming changes into those that apply now and those that wait for their batch. A run's
    /// record goes first: it says which batch its members belong to.
    static func route(_ changes: [SyncIncomingChange], db: Database, now: Date) throws -> Routed {
        var routed = Routed()
        var held: Set<String> = []
        for case .save(let payload) in changes where payload.recordType == ImportRun.databaseTableName {
            guard let manifest = payload.manifest, try receive(header: payload, manifest, db: db) else { continue }
            try stage(payload, run: payload.recordName, generation: manifest.generation, db: db, now: now)
            routed.results[payload.recordName] = .staged(waitingForBatch)
            held.insert(payload.recordName)
        }
        let open = try heldDeletes(db: db)
        for change in changes {
            switch change {
            case .save(let payload):
                if held.contains(payload.recordName) { continue }
                if let run = payload.importRunUuid, try waits(member: payload, run: run, db: db) {
                    try stage(payload, run: run, generation: payload.batchGeneration ?? 0, db: db, now: now)
                    routed.results[payload.recordName] = .staged(waitingForBatch)
                } else {
                    if let run = payload.importRunUuid { try remember(payload, run: run, db: db) }
                    routed.direct.append(change)
                }
            case .delete(let name, _):
                if open.contains(name) {
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
            if manifest.generation < known.generation { return false }
            if known.state.isOwn && manifest.generation == known.generation { return false }
            if manifest.generation == known.generation {
                switch (known.state, manifest.isOpen) {
                case (.complete, true), (.done, _):
                    return false
                case (.complete, false):
                    try save(run: run, Batch(generation: known.generation, state: .done, manifest: closed(manifest), revives: []), db: db)
                    return false
                case (.open, false), (.closed, false):
                    // Closed: its final counts; the deletes and revivals the open manifest announced still apply
                    // with it.
                    var final = manifest
                    final.deletes = known.manifest?.deletes ?? []
                    final.revives = known.manifest?.revives ?? []
                    try save(run: run, Batch(generation: known.generation, state: .closed, manifest: final, revives: []), db: db)
                    return true
                case (.open, true):
                    try save(run: run, Batch(generation: known.generation, state: .open, manifest: manifest, revives: []), db: db)
                    return true
                case (.closed, true):
                    // An older copy of the run than the close already seen: it waits with its batch, the close's
                    // counts kept.
                    return true
                case (.sending, _), (.sent, _):
                    return false
                }
            }
        }
        // A newer generation (or the first seen). What an older one that never applied here still held —
        // its deletes and revivals — applies with this one, unless this one undoes it.
        var current = manifest
        if let known, known.state.isWaiting, let older = known.manifest {
            current.deletes = Array(Set(older.deletes).union(manifest.deletes).subtracting(manifest.revives)).sorted()
            current.revives = Array(Set(older.revives).union(manifest.revives).subtracting(manifest.deletes)).sorted()
        }
        try save(run: run, Batch(generation: manifest.generation, state: manifest.isOpen ? .open : .closed, manifest: current, revives: []), db: db)
        return true
    }

    private static func closed(_ manifest: SyncBatchManifest) -> SyncBatchManifest {
        var result = manifest
        result.isOpen = false
        result.deletes = []
        result.revives = []
        return result
    }

    /// Whether a member waits for its batch: when its run's batch isn't known here, waits itself, or is
    /// older than the member. A member of this device's own batch, or of one already applied, applies at
    /// once.
    private static func waits(member payload: SyncPayload, run: String, db: Database) throws -> Bool {
        guard let batch = try batch(run: run, db: db) else { return true }
        let generation = payload.batchGeneration ?? 0
        switch batch.state {
        case .sending, .sent, .complete, .done: return generation > batch.generation
        case .open, .closed: return true
        }
    }

    /// The deletes of every batch waiting here.
    private static func heldDeletes(db: Database) throws -> Set<String> {
        var result: Set<String> = []
        for json in try String.fetchAll(db, sql: "SELECT manifestJSON FROM syncBatch WHERE state IN ('open', 'closed') AND manifestJSON IS NOT NULL") {
            result.formUnion(decode(json)?.deletes ?? [])
        }
        return result
    }

    /// A tagged member applied here: this device now knows it belongs to the run's batch (and keeps the tag
    /// when it sends it).
    private static func remember(_ payload: SyncPayload, run: String, db: Database) throws {
        guard payload.mergedInto == nil else { return }
        try db.execute(sql: """
            INSERT INTO syncBatchMember(uuid, runUuid, tableName, generation) VALUES (?, ?, ?, ?)
            ON CONFLICT(uuid) DO UPDATE SET runUuid = excluded.runUuid, tableName = excluded.tableName, generation = excluded.generation
            WHERE excluded.generation >= syncBatchMember.generation
            """, arguments: [payload.recordName, run, payload.recordType, payload.batchGeneration ?? 0])
    }

    /// Applies the run's staged batch in one transaction when it is complete here (every count of its
    /// manifest met and every record of it able to apply); true when the batch is complete here (now or
    /// before), false while it waits. Inside the caller's transaction.
    static func applyIfComplete(runUuid: String, db: Database, deviceUser: String? = nil, now: Date = Date()) throws -> Bool {
        guard db.isInsideTransaction else { throw SyncTranslatorError.notInTransaction }
        return try SyncChangeTracker.applyingIncoming(db: db) {
            try flushIfComplete(run: runUuid, db: db, deviceUser: deviceUser, now: now).complete
        }
    }

    /// Applies every closed batch still waiting here, whatever its counts say: the engine calls it once a
    /// fetch has caught up with the server, when nothing more of those batches can arrive. A record that
    /// still can't apply (its parent outside the batch is missing) waits in staging on its own. Returns the
    /// runs applied.
    @discardableResult
    static func flushClosed(db: Database, deviceUser: String? = nil, now: Date = Date()) throws -> [String] {
        guard db.isInsideTransaction else { throw SyncTranslatorError.notInTransaction }
        return try SyncChangeTracker.applyingIncoming(db: db) {
            var flushed: [String] = []
            for run in try String.fetchAll(db, sql: "SELECT runUuid FROM syncBatch WHERE state = 'closed' ORDER BY runUuid") {
                if try flushIfComplete(run: run, db: db, deviceUser: deviceUser, now: now, force: true).complete { flushed.append(run) }
            }
            return flushed
        }
    }

    /// The runs with records waiting here for their batch.
    static func waitingRuns(db: Database) throws -> [String] {
        try String.fetchAll(db, sql: "SELECT DISTINCT importRunUuid FROM syncStaging WHERE importRunUuid IS NOT NULL ORDER BY importRunUuid")
    }

    static func flushIfComplete(run: String, db: Database, deviceUser: String?, now: Date,
                                force: Bool = false) throws -> (complete: Bool, results: [String: IncomingResult]) {
        guard var batch = try batch(run: run, db: db) else { return (false, [:]) }
        // Held because it would change a filed tax year (sync spec §5.4): it never applies without the records held.
        if try FiledYearSyncCheck.runIsHeld(run, db: db) { return (false, [:]) }
        let staged = try SyncStagingRow.filter(Column("importRunUuid") == run).order(Column("id")).fetchAll(db)
        let current = staged.filter { $0.uuid == run || ($0.batchGeneration ?? 0) <= batch.generation }
        let manifest = batch.manifest ?? SyncBatchManifest(generation: batch.generation, isOpen: batch.state == .open)
        switch batch.state {
        case .open, .closed:
            if !force {
                // Open: this generation's members. Closed: every member the run has on the server.
                var arrived: [String: Int] = [:]
                for row in current where row.uuid != run && (batch.state == .closed || row.batchGeneration == batch.generation) {
                    arrived[row.tableName, default: 0] += 1
                }
                guard manifest.counts.allSatisfy({ arrived[$0.key, default: 0] >= $0.value }) else { return (false, [:]) }
            }
        case .sending, .sent, .complete, .done:
            if current.isEmpty { return (true, [:]) }
        }
        var changes: [SyncIncomingChange] = []
        var saved: [SyncPayload] = []
        for row in current {
            guard let payload = try? JSONDecoder().decode(SyncPayload.self, from: Data(row.payloadJSON.utf8)) else {
                log.error("Sync staging row of an import batch can't be read; marked for attention")
                try db.execute(sql: "UPDATE syncStaging SET importRunUuid = NULL, reason = ? WHERE id = ?",
                               arguments: [SyncTranslator.needsAttention + "unreadable payload", row.id])
                continue
            }
            changes.append(.save(payload))
            saved.append(payload)
        }
        // Deletes and revivals apply with the batch that announced them.
        let applying = batch.state.isWaiting
        if applying { changes += manifest.deletes.map { SyncIncomingChange.delete(recordName: $0, recordType: nil) } }
        var revivals: [String: Int64] = [:]
        for name in applying ? manifest.revives : [] {
            if let tombstone = try SyncTombstoneRow.fetchOne(db, key: name), tombstone.mergedInto == nil { revivals[name] = tombstone.localId }
        }
        var results: [String: IncomingResult] = [:]
        var applied = false
        try db.inSavepoint {
            let ids = current.compactMap(\.id)
            if !ids.isEmpty { try db.execute(sql: "DELETE FROM syncStaging WHERE id IN (\(ids.map(String.init).joined(separator: ",")))") }
            results = try SyncTranslator.applyChanges(changes, db: db, deviceUser: deviceUser, now: now, revivals: revivals)
            // All or nothing: a record of the batch that can't apply yet (its parent outside the batch hasn't
            // arrived) holds the whole batch back, unless the fetch has caught up (`force`).
            if !force, applying {
                let names = saved.map(\.recordName)
                let stuck = try names.isEmpty ? 0 : Int.fetchOne(db, sql: """
                    SELECT COUNT(*) FROM syncStaging WHERE uuid IN (\(Array(repeating: "?", count: names.count).joined(separator: ",")))
                    """, arguments: StatementArguments(names)) ?? 0
                if stuck > 0 { return .rollback }
            }
            for payload in saved where payload.importRunUuid == run { try remember(payload, run: run, db: db) }
            applied = true
            return .commit
        }
        guard applied else { return (false, [:]) }
        switch batch.state {
        case .open: batch.state = .complete
        case .closed: batch.state = .done
        default: break
        }
        if let applied = batch.manifest { batch.manifest = closedOrKept(applied, state: batch.state) }
        try save(run: run, batch, db: db)
        return (true, results)
    }

    /// An applied batch's manifest: its deletes and revivals are done.
    private static func closedOrKept(_ manifest: SyncBatchManifest, state: State) -> SyncBatchManifest {
        var result = manifest
        result.deletes = []
        result.revives = []
        if state == .done { result.isOpen = false }
        return result
    }

    // MARK: Storage

    private static func stage(_ payload: SyncPayload, run: String, generation: Int, db: Database, now: Date) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try db.execute(sql: """
            INSERT INTO syncStaging(tableName, uuid, payloadJSON, reason, importRunUuid, receivedAt, batchGeneration, firstSeenAt)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(uuid) DO UPDATE SET tableName = excluded.tableName, payloadJSON = excluded.payloadJSON, reason = excluded.reason,
                importRunUuid = excluded.importRunUuid, receivedAt = excluded.receivedAt, batchGeneration = excluded.batchGeneration
            """, arguments: [payload.recordType, payload.recordName, String(decoding: try encoder.encode(payload), as: UTF8.self),
                             waitingForBatch, run, now, generation, now])
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
