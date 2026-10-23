import CryptoKit
import Foundation
import GRDB
import os

public struct SyncPushReport: Equatable, Sendable {
    /// Records the server took.
    public var saved = 0
    /// Deletes sent.
    public var deleted = 0
    /// Saves refused because the server held a newer version: merged with it here and sent again.
    public var merged = 0
    /// Saves not taken this time (too large, a passing failure, a failed batch); they stay pending.
    public var refused = 0
    /// Records that went with their payload as an encrypted asset (ruling R4).
    public var asAssets = 0
    /// Local edits not sent because the server's version of the record waits in staging here.
    public var heldBack = 0

    public init() {}
}

public struct SyncPullReport: Equatable, Sendable {
    /// Records and deletions received (each record once, at its latest version).
    public var received = 0
    /// Received records this device already held at that version (its own uploads coming back).
    public var alreadyHeld = 0
    /// Received records waiting in staging after the apply.
    public var staged = 0
    /// Received records that couldn't be read: staged for attention.
    public var unreadable = 0
    /// Rows here a full fetch didn't list, queued to go up again (ruling R12).
    public var reconciled = 0
    /// Received records held because applying them would change a filed or paid tax year (sync spec §5.4).
    public var held = 0
    /// What they would have changed, and who wrote them; nil when nothing was held.
    public var filedYearAlert: FiledYearSyncAlert?

    public init() {}
}

public struct SyncReport: Equatable, Sendable {
    public var pull: SyncPullReport
    public var push: SyncPushReport
}

/// The sync engine's core (plan Task 5), written against `SyncTransport` (shaped like `CKDatabase`
/// operations, ruling R11), so it runs the same over the in-memory `FakeCloud` and over CloudKit. It
/// composes Tasks 2–4:
/// - **Push** sends `SyncChangeTracker.pending` in its order (an import's run first): saves first, in
///   non-atomic operations within the transport's limits, each with the system fields of the version it
///   was last seen at (`.ifServerRecordUnchanged`), then deletes, holding back a batch's deletes until its
///   run's record is on the server. A save refused because the server holds a newer version is merged with
///   it (`SyncTranslator.apply`) and sent again; a record whose server version waits in staging here isn't
///   sent. Taken records are acknowledged (revision-safe), then `SyncBatch.closeUploaded` closes finished
///   batches; the import lease is renewed while a batch uploads and released once its close is uploaded.
///   A record too large for the server carries its payload as an encrypted asset (ruling R4).
/// - **Pull** fetches every page of the zone's changes since the stored token, then applies the whole pull
///   in feed order in one transaction (`SyncTranslator.apply`), with the stamps of what applied and the new
///   token, then `SyncBatch.flushClosed` (it has caught up). The apply and the flush are checked against the
///   filed and paid tax years (`FiledYearSyncCheck`, sync spec §5.4): records that would move a filed figure
///   are held for attention and named in the report's alert; the rest applies. A record that can't be read is staged for
///   attention. An expired token fetches again from the start; a missing zone is created again and
///   everything here is queued to go up again.
/// - **Import lease** (sync spec §5.2): `acquireImportLease` before Confirm and Undo; with sync on,
///   BudgetCore refuses both without it (`SyncImportGate`).
///
/// The public entry points run one at a time, in call order. Stamps are kept in `syncRecord` (the opaque
/// `systemFields` and the `changeTag` compared); the change token per zone is in `syncState`.
public actor SyncEngineCore {
    /// The zones synced in build step 3.
    public static let zones = [SyncRecordStore.householdZone]
    /// Records in the zone that are the engine's own, never data (the import lease).
    static let reservedRecordTypes: Set<String> = [TransportLeaseStore.recordType]
    /// A payload whose record would be larger than this goes as an encrypted asset (ruling R4).
    public static let largePayloadThreshold = 900_000
    /// How many times one push tries one record before leaving it for the next sync.
    static let triesPerPush = 4
    /// A used lease is renewed once it is this old.
    static let leaseRenewalAge: TimeInterval = 10 * 60

    private static let log = Logger(subsystem: "com.personal.budget", category: "Sync")

    private let db: any DatabaseWriter
    private let transport: any SyncTransport
    public nonisolated let device: SyncDevice
    private let batchSize: Int
    private let clock: @Sendable () -> Date
    private let leaseStore: TransportLeaseStore
    /// The last entry point started: the next one waits for it.
    private var tail: Task<Void, Never>?

    public init(db: any DatabaseWriter, transport: any SyncTransport, device: SyncDevice, batchSize: Int = 200,
                clock: @escaping @Sendable () -> Date = { Date() }) {
        self.db = db
        self.transport = transport
        self.device = device
        self.batchSize = max(1, batchSize)
        self.clock = clock
        leaseStore = TransportLeaseStore(transport: transport)
    }

    // MARK: Entry points (one at a time)

    /// Pull, then push.
    @discardableResult
    public func syncNow() async throws -> SyncReport {
        try await serialized {
            let pulled = try await self.pullAll()
            let pushed = try await self.pushAll()
            return SyncReport(pull: pulled, push: pushed)
        }
    }

    @discardableResult
    public func pull() async throws -> SyncPullReport {
        try await serialized { try await self.pullAll() }
    }

    @discardableResult
    public func pushPending() async throws -> SyncPushReport {
        try await serialized { try await self.pushAll() }
    }

    /// Takes the household's import lease for this device: call before Confirm and before Undo. Throws
    /// `ImportLeaseError.heldBy` ("Importing on <device>") while another device holds it.
    public func acquireImportLease() async throws {
        try await serialized {
            try await self.prepare()
            let now = self.clock()
            let lease = try await ImportLease.acquire(device: self.device, now: now, transport: self.leaseStore)
            try await self.db.write { db in
                try SyncImportGate.setHeldLease(HeldImportLease(record: lease.record, tag: lease.tag), db: db, now: now)
            }
        }
    }

    /// Gives the lease up without importing (the user cancelled). A batch's lease is released by the push
    /// that uploads the batch's close.
    public func releaseImportLease() async throws {
        try await serialized {
            guard let held = try await self.db.read({ db in try SyncImportGate.heldLease(db: db) }) else { return }
            try await ImportLease.release(ImportLease.Lease(record: held.record, tag: held.tag), transport: self.leaseStore)
            let now = self.clock()
            try await self.db.write { db in try SyncImportGate.setHeldLease(nil, db: db, now: now) }
        }
    }

    /// Who holds the lease now ("Importing on <device>"), or nil. Read only: it doesn't wait its turn.
    public func importLeaseHolder() async throws -> ImportLeaseRecord? {
        try await ImportLease.holder(now: clock(), transport: leaseStore)
    }

    /// Runs `body` after every entry point called before it has finished (actor methods are reentrant at
    /// each `await`, so without this two syncs would interleave: double sends, a token going back).
    private func serialized<T: Sendable>(_ body: @escaping @Sendable () async throws -> T) async throws -> T {
        let previous = tail
        let task = Task<T, Error> {
            await previous?.value
            return try await body()
        }
        tail = Task { _ = try? await task.value }
        return try await task.value
    }

    // MARK: Pull

    private func pullAll() async throws -> SyncPullReport {
        try await prepare()
        var report = SyncPullReport()
        for zone in Self.zones {
            let zoneReport = try await pull(zone: zone)
            report.held += zoneReport.held
            if let alert = zoneReport.filedYearAlert {
                var merged = report.filedYearAlert ?? FiledYearSyncAlert(records: [], impacts: [])
                merged.records += alert.records
                merged.impacts += alert.impacts
                report.filedYearAlert = merged
            }
            report.received += zoneReport.received
            report.alreadyHeld += zoneReport.alreadyHeld
            report.staged += zoneReport.staged
            report.unreadable += zoneReport.unreadable
            report.reconciled += zoneReport.reconciled
        }
        return report
    }

    private enum Entry: Sendable {
        case save(SyncPayload, SyncServerStamp)
        case delete(SyncDeletion)
        case unreadable(recordType: String)
    }

    private func pull(zone: String) async throws -> SyncPullReport {
        var token = try await db.read { db in try Self.token(zone: zone, db: db) }
        var entries: [String: (position: Int, entry: Entry)] = [:]
        var position = 0
        var alreadyHeld = 0
        // A fetch from the start lists every record the zone holds (ruling R12 reconciles against it).
        var full = token == nil
        var listed: Set<String> = []
        while true {
            let page: SyncChanges
            do {
                page = try await transport.changes(since: token, zone: zone)
            } catch SyncTransportError.changeTokenExpired where token != nil {
                // Fetched again from the start (which lists what exists, not what was deleted meanwhile).
                Self.log.error("Sync change token expired; fetching the zone again")
                token = nil
                entries = [:]
                alreadyHeld = 0
                full = true
                listed = []
                continue
            } catch SyncTransportError.zoneNotFound {
                try await recoverMissingZone(zone)
                return SyncPullReport()
            }
            let names = page.records.map(\.wire.recordName)
            let held = try await db.read { db in try Self.changeTags(names, db: db) }
            for change in page.changes {
                position += 1
                switch change {
                case .record(let record):
                    let name = record.wire.recordName
                    listed.insert(name)
                    guard !Self.reservedRecordTypes.contains(record.wire.recordType) else { continue }
                    if let tag = held[name], tag == record.stamp.changeTag {
                        // Already held at this version (this device's own upload coming back): skipped,
                        // before any asset is opened.
                        entries[name] = nil
                        alreadyHeld += 1
                        continue
                    }
                    do {
                        entries[name] = (position, .save(try SyncLargePayload.payload(from: record.wire), record.stamp))
                    } catch {
                        entries[name] = (position, .unreadable(recordType: record.wire.recordType))
                    }
                case .deletion(let deletion):
                    guard !Self.reservedRecordTypes.contains(deletion.recordType ?? "") else { continue }
                    entries[deletion.recordName] = (position, .delete(deletion))
                }
            }
            token = page.token
            if !page.moreComing { break }
        }
        // Feed order: a record seen again later is at its later place.
        let ordered = entries.sorted { $0.value.position < $1.value.position }.map { ($0.key, $0.value.entry) }
        let finalToken = token
        let skipped = alreadyHeld
        let reconcile = full ? listed : nil
        let now = clock()
        return try await db.write { db in
            var report = SyncPullReport()
            report.alreadyHeld = skipped
            report.received = ordered.count + skipped
            let user = try Self.deviceUser(db: db)
            var incoming: [SyncIncomingChange] = []
            var stamps: [String: SyncServerStamp] = [:]
            for (name, entry) in ordered {
                switch entry {
                case .save(let payload, let stamp):
                    incoming.append(.save(payload))
                    stamps[name] = stamp
                case .delete(let deletion):
                    incoming.append(.delete(recordName: deletion.recordName, recordType: deletion.recordType))
                case .unreadable(let type):
                    try SyncTranslator.stageUnreadable(recordType: type, recordName: name, db: db, now: now)
                    report.unreadable += 1
                }
            }
            // Sync spec §5.4: the apply (and the batches it completes or flushes) is kept only while it moves no
            // figure on a filed or paid return; the records that would are held, the rest applies.
            // (Nothing to apply and no closed batch to flush: nothing can move, nothing is taken.)
            let closedWaiting = try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM syncBatch WHERE state = 'closed')") ?? true
            let baseline = incoming.isEmpty && !closedWaiting ? FiledYearBaseline.none : try FiledYearSyncCheck.baseline(db: db)
            // Caught up: a closed batch that can't complete any more applies now (`SyncBatch.flushClosed`, inside).
            let outcome = try FiledYearSyncCheck.apply(incoming, baseline: baseline, db: db, deviceUser: user, now: now)
            let results = outcome.results
            report.filedYearAlert = outcome.alert
            report.held = outcome.alert?.records.count ?? 0
            for (name, result) in results {
                if case .staged = result {
                    report.staged += 1
                } else if let stamp = stamps[name] {
                    // Only a record whose version is now merged here takes the server's stamp: one still staged
                    // must not, or a later save would overwrite a version this device never merged.
                    try Self.storeStamp(stamp, uuid: name, db: db)
                }
            }
            if let reconcile {
                report.reconciled = try SyncTranslator.reconcile(zone: zone, listed: reconcile, db: db, now: now).count
            }
            if let finalToken { try Self.setToken(finalToken, zone: zone, db: db, now: now) }
            return report
        }
    }

    // MARK: Push

    private func pushAll() async throws -> SyncPushReport {
        try await prepare()
        try await renewLeaseIfDue()
        var report = SyncPushReport()
        var tries: [String: Int] = [:]
        var pulled = false
        var recovered = false
        while true {
            var needsPull = false
            var zoneMissing = false
            let limits = await transport.operationLimits()
            let chunkSize = max(1, min(batchSize, limits.maxRecords))
            let triesNow = tries
            let (saves, heldBack) = try await db.read { db in
                let pending = try SyncChangeTracker.pending(db: db).filter { $0.kind != .delete && triesNow[$0.uuid, default: 0] < Self.triesPerPush }
                let staged = try Set(String.fetchAll(db, sql: "SELECT uuid FROM syncStaging"))
                // Not sent while the server's version waits here: it would overwrite a version never merged.
                return (pending.filter { !staged.contains($0.uuid) }, pending.filter { staged.contains($0.uuid) }.count)
            }
            report.heldBack = heldBack
            for start in stride(from: 0, to: saves.count, by: chunkSize) {
                let chunk = Array(saves[start..<min(start + chunkSize, saves.count)])
                for change in chunk { tries[change.uuid, default: 0] += 1 }
                // A long upload keeps a used lease alive (it expires 30 minutes after it was last renewed).
                try await renewLeaseIfDue()
                let flags = try await pushSaves(chunk, limits: limits, report: &report)
                needsPull = needsPull || flags.needsPull
                zoneMissing = zoneMissing || flags.zoneMissing
            }
            // Deletes, after the saves, except a batch's while its run's record isn't on the server yet.
            let triesAfterSaves = tries
            let deletes = try await db.read { db in
                try Self.sendableDeletes(db: db).filter { triesAfterSaves[$0.uuid, default: 0] < Self.triesPerPush }
            }
            for start in stride(from: 0, to: deletes.count, by: chunkSize) {
                let chunk = Array(deletes[start..<min(start + chunkSize, deletes.count)])
                for change in chunk { tries[change.uuid, default: 0] += 1 }
                let zones = try await db.read { db in try Self.zones(of: chunk, db: db) }
                for (zone, names) in zones.sorted(by: { $0.key < $1.key }) {
                    try await transport.delete(names, zone: zone)
                }
                try await db.write { db in
                    try SyncChangeTracker.acknowledge(chunk, db: db)
                    _ = try SyncBatch.closeUploaded(db: db)
                }
                report.deleted += chunk.count
            }
            if zoneMissing {
                guard !recovered else { throw SyncTransportError.zoneNotFound(Self.zones.joined(separator: ",")) }
                recovered = true
                for zone in Self.zones { try await recoverMissingZone(zone) }
                tries = [:]
                continue
            }
            if needsPull, !pulled {
                // A save named a record the server no longer has: the pull brings its deletion (a delete wins
                // over an edit made offline) before anything is sent again.
                pulled = true
                _ = try await pullAll()
                continue
            }
            let triesLeft = tries
            let more = try await db.read { db in
                let staged = try Set(String.fetchAll(db, sql: "SELECT uuid FROM syncStaging"))
                return try SyncChangeTracker.pending(db: db).contains {
                    $0.kind != .delete && !staged.contains($0.uuid) && triesLeft[$0.uuid, default: 0] < Self.triesPerPush
                } || Self.sendableDeletes(db: db).contains { triesLeft[$0.uuid, default: 0] < Self.triesPerPush }
            }
            if !more { break }
        }
        try await releaseLeaseIfDone()
        return report
    }

    /// Sends one chunk of saves and takes in the results.
    private func pushSaves(_ chunk: [PendingChange], limits: SyncOperationLimits,
                           report: inout SyncPushReport) async throws -> (needsPull: Bool, zoneMissing: Bool) {
        let buildTime = clock()
        let built = try await db.write { db -> [(PendingChange, SyncPayload?, Data?)] in
            try chunk.map { change in
                var payload = try SyncTranslator.outgoing(change, db: db)
                let resent = try Int.fetchOne(db, sql: "SELECT resent FROM syncPending WHERE uuid = ?", arguments: [change.uuid]) ?? 0
                if resent != 0, payload != nil {
                    payload?.resent = true
                    if resent == SyncTranslator.resentAfterServerDelete {
                        // No deletion came with the pull that followed (a full fetch lists none): the edit brings
                        // the record back, visibly, as ruling R12 does.
                        try SyncMerge.logConflict(table: change.table, uuid: change.uuid, field: "*", losing: .string(SyncTranslator.reconciledEdit),
                                                  winner: nil, loser: nil, db: db, now: buildTime)
                        try db.execute(sql: "UPDATE syncPending SET resent = ? WHERE uuid = ?", arguments: [SyncTranslator.resentReconciled, change.uuid])
                    }
                }
                return (change, payload, try payload.flatMap { try Self.systemFields(uuid: $0.recordName, db: db) })
            }
        }
        var wires: [SyncWireRecord] = []
        var systemFields: [String: Data] = [:]
        var sent: [String: PendingChange] = [:]
        var nothingToSend: [PendingChange] = []
        for (change, payload, fields) in built {
            guard let payload else {
                nothingToSend.append(change)
                continue
            }
            let (wire, packed) = try SyncLargePayload.wire(for: payload)
            if packed { report.asAssets += 1 }
            wires.append(wire)
            sent[wire.recordName] = change
            if let fields { systemFields[wire.recordName] = fields }
        }
        var results: [SaveResult] = []
        for operation in Self.operations(wires, limits: limits) {
            results += try await save(operation, ifUnchanged: systemFields)
        }
        var servers: [String: (SyncPayload?, SyncServerRecord)] = [:]
        for result in results {
            if case .changed(let server) = result.outcome {
                servers[result.recordName] = (try? SyncLargePayload.payload(from: server.wire), server)
            }
        }
        let now = clock()
        let sentChanges = sent
        let unsent = nothingToSend
        let serverRecords = servers
        let outcome = try await db.write { db -> (SyncPushReport, Bool, Bool) in
            var delta = SyncPushReport()
            var needsPull = false
            var zoneMissing = false
            var acknowledged = unsent
            let user = try Self.deviceUser(db: db)
            for result in results {
                guard let change = sentChanges[result.recordName] else { continue }
                switch result.outcome {
                case .saved(let stamp):
                    acknowledged.append(change)
                    try Self.storeStamp(stamp, uuid: result.recordName, db: db)
                    // `resent` stays on an edit made meanwhile (still pending at a newer revision): change feeds carry
                    // only a record's latest version, so a device that deleted it may never see the save that
                    // recreated it, and would discard a plain update (divergence). It can't override a delete that
                    // reached the server since: that save is refused (`deleted`) and the pull brings the delete.
                    delta.saved += 1
                case .changed:
                    guard let (payload, server) = serverRecords[result.recordName] else { continue }
                    guard let payload else {
                        // The server's version can't be read: kept for attention; the local edit waits for it.
                        try SyncTranslator.stageUnreadable(recordType: server.wire.recordType, recordName: result.recordName, db: db, now: now)
                        delta.refused += 1
                        continue
                    }
                    // Merged field by field with the server's version; the merged record goes again next round
                    // against the server's version (unless that version had to wait in staging here).
                    let merged = try SyncTranslator.apply([.save(payload)], db: db, deviceUser: user, now: now)
                    if case .staged = merged[result.recordName] {} else {
                        try Self.storeStamp(server.stamp, uuid: result.recordName, db: db)
                    }
                    delta.merged += 1
                case .deleted:
                    try Self.clearStamp(uuid: result.recordName, db: db)
                    try db.execute(sql: "UPDATE syncPending SET resent = ? WHERE uuid = ? AND kind <> 'delete'",
                                   arguments: [SyncTranslator.resentAfterServerDelete, result.recordName])
                    needsPull = true
                case .zoneNotFound:
                    zoneMissing = true
                case .tooLarge(let bytes):
                    Self.log.error("Sync save of a \(change.table, privacy: .public) record refused: \(bytes) bytes")
                    delta.refused += 1
                case .batchRequestFailed:
                    delta.refused += 1
                case .failed(let reason):
                    Self.log.error("Sync save of a \(change.table, privacy: .public) record failed (\(reason, privacy: .public)); sent again later")
                    delta.refused += 1
                }
            }
            try SyncChangeTracker.acknowledge(acknowledged, db: db)
            _ = try SyncBatch.closeUploaded(db: db)
            return (delta, needsPull, zoneMissing)
        }
        report.saved += outcome.0.saved
        report.merged += outcome.0.merged
        report.refused += outcome.0.refused
        return (outcome.1, outcome.2)
    }

    /// One non-atomic save operation; split in half while the server says it is too large.
    private func save(_ records: [SyncWireRecord], ifUnchanged: [String: Data]) async throws -> [SaveResult] {
        let names = Set(records.map(\.recordName))
        do {
            return try await transport.save(records, ifUnchanged: ifUnchanged.filter { names.contains($0.key) }, atomic: false)
        } catch SyncTransportError.limitExceeded {
            guard records.count > 1 else { return [SaveResult(recordName: records[0].recordName, outcome: .tooLarge(bytes: records[0].size))] }
            let half = records.count / 2
            return try await save(Array(records[..<half]), ifUnchanged: ifUnchanged) + save(Array(records[half...]), ifUnchanged: ifUnchanged)
        }
    }

    /// Records split into operations within the limits (count and bytes), in order.
    static func operations(_ records: [SyncWireRecord], limits: SyncOperationLimits) -> [[SyncWireRecord]] {
        var result: [[SyncWireRecord]] = []
        var current: [SyncWireRecord] = []
        var bytes = 0
        for record in records {
            let size = record.size
            if !current.isEmpty, current.count >= limits.maxRecords || bytes + size > limits.maxBytes {
                result.append(current)
                current = []
                bytes = 0
            }
            current.append(record)
            bytes += size
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    /// Pending deletes that may go now: all but those of a batch whose run's record is still pending (a
    /// receiver must know the batch before its deletes, or it would apply them on their own).
    static func sendableDeletes(db: Database) throws -> [PendingChange] {
        let held = try Set(String.fetchAll(db, sql: """
            SELECT m.uuid FROM syncBatchMember m JOIN syncPending p ON p.uuid = m.runUuid
            """))
        return try SyncChangeTracker.pending(db: db).filter { $0.kind == .delete && !held.contains($0.uuid) }
    }

    /// Deleted records by zone (from their tombstones; household when there is none).
    static func zones(of changes: [PendingChange], db: Database) throws -> [String: [String]] {
        var result: [String: [String]] = [:]
        for change in changes {
            let zone = try String.fetchOne(db, sql: "SELECT zone FROM syncTombstone WHERE uuid = ?", arguments: [change.uuid])
                ?? SyncRecordStore.householdZone
            result[zone, default: []].append(change.uuid)
        }
        return result
    }

    // MARK: Zones

    /// Before the first sync: sync is on here, and the zones exist on the server.
    private func prepare() async throws {
        let now = clock()
        let (on, ready) = try await db.read { db in
            (try SyncImportGate.isSyncOn(db: db), try Self.zones.filter { try Self.zoneReady($0, db: db) })
        }
        let missing = Self.zones.filter { !ready.contains($0) }
        for zone in missing { try await transport.createZone(zone) }
        guard !on || !missing.isEmpty else { return }
        try await db.write { db in
            try SyncImportGate.setSyncOn(true, db: db, now: now)
            for zone in missing { try SyncImportGate.setState(Data([1]), key: Self.zoneKey(zone), db: db, now: now) }
        }
    }

    /// The zone is gone from the server (deleted, or reset): created again, and every record of it here is
    /// queued to go up again, with no stamps and no token.
    private func recoverMissingZone(_ zone: String) async throws {
        Self.log.error("Sync zone missing on the server; creating it again and re-sending this device's records")
        try await transport.createZone(zone)
        let now = clock()
        try await db.write { db in
            try db.execute(sql: "DELETE FROM syncState WHERE key = ?", arguments: [Self.tokenKey(zone)])
            try db.execute(sql: "UPDATE syncRecord SET systemFields = NULL, changeTag = NULL WHERE zone = ?", arguments: [zone])
            let base = try Int64.fetchOne(db, sql: "SELECT COALESCE(MAX(revision), 0) FROM syncPending") ?? 0
            try db.execute(sql: """
                INSERT INTO syncPending(uuid, tableName, localId, kind, revision)
                SELECT uuid, tableName, localId, 'insert', ? + rowid FROM syncRecord WHERE zone = ? ORDER BY rowid
                ON CONFLICT(uuid) DO NOTHING
                """, arguments: [base, zone])
            try SyncImportGate.setState(Data([1]), key: Self.zoneKey(zone), db: db, now: now)
        }
    }

    // MARK: Import lease

    /// A used lease (a batch confirmed under it) is renewed once it is 10 minutes old; an unused one is never
    /// renewed, and is dropped once it has expired.
    private func renewLeaseIfDue() async throws {
        guard let held = try await db.read({ db in try SyncImportGate.heldLease(db: db) }) else { return }
        let now = clock()
        guard held.used else {
            if held.record.expiresAt <= now {
                try await db.write { db in try SyncImportGate.setHeldLease(nil, db: db, now: now) }
            }
            return
        }
        guard now.timeIntervalSince(held.record.expiresAt.addingTimeInterval(-ImportLease.duration)) >= Self.leaseRenewalAge else { return }
        do {
            let renewed = try await ImportLease.renew(ImportLease.Lease(record: held.record, tag: held.tag), now: now, transport: leaseStore)
            let updated = HeldImportLease(record: renewed.record, tag: renewed.tag, used: held.used)
            try await db.write { db in try SyncImportGate.setHeldLease(updated, db: db, now: now) }
        } catch LeaseStoreError.unavailable {
            // Tried again before the next chunk; the save that follows meets the same connection.
            Self.log.error("Sync import lease couldn't be renewed now")
        } catch ImportLeaseError.lost {
            // Another device took over: this device's batch still uploads (it is tagged with its own run).
            Self.log.error("Sync import lease lost to another device")
            try await db.write { db in try SyncImportGate.setHeldLease(nil, db: db, now: now) }
        }
    }

    /// Releases the lease once the batch it was taken for has closed and its close is uploaded.
    private func releaseLeaseIfDone() async throws {
        let done = try await db.read { db -> HeldImportLease? in
            guard let held = try SyncImportGate.heldLease(db: db), held.used else { return nil }
            let open = try Bool.fetchOne(db, sql: """
                SELECT EXISTS (SELECT 1 FROM syncBatch WHERE state = 'sending')
                    OR EXISTS (SELECT 1 FROM syncPending p JOIN syncBatch b ON b.runUuid = p.uuid WHERE b.state = 'sent')
                """) ?? true
            return open ? nil : held
        }
        guard let done else { return }
        do {
            try await ImportLease.release(ImportLease.Lease(record: done.record, tag: done.tag), transport: leaseStore)
        } catch LeaseStoreError.unavailable {
            // Everything is uploaded: the release is tried again by the next push.
            Self.log.error("Sync import lease couldn't be released now")
            return
        }
        let now = clock()
        try await db.write { db in try SyncImportGate.setHeldLease(nil, db: db, now: now) }
    }

    // MARK: State

    static func tokenKey(_ zone: String) -> String { "changeToken." + zone }
    static func zoneKey(_ zone: String) -> String { "zoneReady." + zone }

    static func zoneReady(_ zone: String, db: Database) throws -> Bool {
        try Data.fetchOne(db, sql: "SELECT value FROM syncState WHERE key = ?", arguments: [zoneKey(zone)]) != nil
    }

    static func token(zone: String, db: Database) throws -> Data? {
        try Data.fetchOne(db, sql: "SELECT value FROM syncState WHERE key = ?", arguments: [tokenKey(zone)])
    }

    static func setToken(_ token: Data, zone: String, db: Database, now: Date) throws {
        try SyncImportGate.setState(token, key: tokenKey(zone), db: db, now: now)
    }

    static func changeTags(_ uuids: [String], db: Database) throws -> [String: String] {
        var result: [String: String] = [:]
        let statement = try db.cachedStatement(sql: "SELECT changeTag FROM syncRecord WHERE uuid = ?")
        for uuid in uuids {
            if let tag = try String.fetchOne(statement, arguments: [uuid]) { result[uuid] = tag }
        }
        return result
    }

    static func systemFields(uuid: String, db: Database) throws -> Data? {
        try Data.fetchOne(db.cachedStatement(sql: "SELECT systemFields FROM syncRecord WHERE uuid = ?"), arguments: [uuid])
    }

    static func storeStamp(_ stamp: SyncServerStamp, uuid: String, db: Database) throws {
        try db.cachedStatement(sql: "UPDATE syncRecord SET systemFields = ?, changeTag = ? WHERE uuid = ?")
            .execute(arguments: [stamp.systemFields, stamp.changeTag, uuid])
    }

    static func clearStamp(uuid: String, db: Database) throws {
        try db.execute(sql: "UPDATE syncRecord SET systemFields = NULL, changeTag = NULL WHERE uuid = ?", arguments: [uuid])
    }

    static func deviceUser(db: Database) throws -> String? {
        try String.fetchOne(db, sql: "SELECT appUserUuid FROM syncWriter WHERE id = 1")
    }
}

// MARK: Large payloads

/// Ruling R4: a payload whose record would exceed `SyncEngineCore.largePayloadThreshold` travels in an
/// asset field of its own record, sealed with AES-GCM under a random key (authenticating the record name
/// and the field). The record's encrypted fields carry the key and nothing else of the payload.
enum SyncLargePayload {
    static let assetField = "payload"

    /// The record to save for `payload`, and whether it was packed.
    static func wire(for payload: SyncPayload, threshold: Int = SyncEngineCore.largePayloadThreshold) throws -> (SyncWireRecord, Bool) {
        let plain = try SyncWireRecord(payload)
        guard plain.size > threshold else { return (plain, false) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let key = SymmetricKey(size: .bits256)
        guard let sealed = try AES.GCM.seal(try encoder.encode(payload), using: key,
                                            authenticating: additionalData(payload.recordName, assetField)).combined else {
            throw SyncTransportError.unreadableRecord(payload.recordName)
        }
        var stub = SyncPayload(recordType: payload.recordType, recordName: payload.recordName, zone: payload.zone, fields: [:])
        stub.largePayload = SyncLargePayloadReference(assetField: assetField, key: key.withUnsafeBytes { Data($0) })
        var wire = try SyncWireRecord(stub)
        wire.assets[assetField] = sealed
        return (wire, true)
    }

    /// The payload a record holds, opening its asset when it is a large one.
    static func payload(from wire: SyncWireRecord) throws -> SyncPayload {
        let stub = try wire.payload()
        guard let reference = stub.largePayload else { return stub }
        guard let ciphertext = wire.assets[reference.assetField] else { throw SyncTransportError.unreadableRecord(wire.recordName) }
        let plaintext = try AES.GCM.open(try AES.GCM.SealedBox(combined: ciphertext), using: SymmetricKey(data: reference.key),
                                         authenticating: additionalData(wire.recordName, reference.assetField))
        let payload = try JSONDecoder().decode(SyncPayload.self, from: plaintext)
        guard payload.recordName == wire.recordName, payload.recordType == wire.recordType else {
            throw SyncTransportError.unreadableRecord(wire.recordName)
        }
        return payload
    }

    private static func additionalData(_ recordName: String, _ field: String) -> Data { Data((recordName + "|" + field).utf8) }
}
