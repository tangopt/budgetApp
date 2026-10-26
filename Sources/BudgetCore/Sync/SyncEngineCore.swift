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
    /// Server versions of refused saves held because merging them would change a filed tax year (§5.4): the
    /// local edit waits (`heldBack` from the next push on).
    public var held = 0
    /// What they would have changed, and who wrote them; nil when nothing was held.
    public var filedYearAlert: FiledYearSyncAlert?
    /// Evidence files sealed and uploaded (sync spec §9.1).
    public var documentsSealed = 0
    /// Document records not sent because their file record couldn't be uploaded now: they stay pending. Not
    /// counted in `refused`.
    public var documentsDeferred = 0
    /// Why nothing was sent (ruling R15): the household key isn't held here yet, or its marker couldn't be read or
    /// published now. Everything stays pending; nil when the push ran.
    public var keyWait: SyncKeyError?
    /// With `keyWait == .unavailable`: the passing transport error that kept the key marker from being fetched or
    /// published (offline, busy, a retry-after), so the scheduler shows it as offline, not as waiting for the key.
    public var keyWaitCause: SyncTransportError?

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
    /// Received records sealed under a household key this device doesn't hold yet: kept sealed in staging, opened
    /// and applied by a later pull once iCloud Keychain delivers the key (ruling R15).
    public var waitingForKey = 0
    /// Rows here a full fetch didn't list, queued to go up again (ruling R12).
    public var reconciled = 0
    /// Received records held because applying them would change a filed or paid tax year (sync spec §5.4).
    public var held = 0
    /// What they would have changed, and who wrote them; nil when nothing was held.
    public var filedYearAlert: FiledYearSyncAlert?
    /// Evidence files downloaded, opened, checked and placed in the library (eager policy, the Mac).
    public var documentsDownloaded = 0
    /// Downloaded files not saved because they don't open or don't match their record's hash (needs attention).
    public var documentsNeedingAttention = 0

    public init() {}
}

/// Whose device this is, for the zones it syncs (step 6): the household zone, and the private zone of
/// `personUuid` (the person's `person` record UUID) when set. A device never fetches another person's private zone.
public struct SyncViewer: Equatable, Sendable {
    public var personUuid: String?

    public init(personUuid: String?) {
        self.personUuid = personUuid
    }

    /// The household zone only (a device before step 6, a tool).
    public static let none = SyncViewer(personUuid: nil)
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
/// - **Zones** (step 6): a device syncs `household` and its viewer's private zone (`zones(db:)`), each sealed under its
///   own key. Once ownership is confirmed every save is placed by `SyncZoneRouter` and checked by `SyncZoneGuard`
///   (loaded once per push; a violation stops the push before anything of its chunk is sent); a record whose zone
///   changed moves (its new copy first, then a marker over the old one, `SyncZoneMoves`); a household stub goes with
///   its `accountDetails` companion. Pulls take the private zone first, then the household.
/// - **Import lease** (sync spec §5.2): `acquireImportLease` before Confirm and Undo; with sync on,
///   BudgetCore refuses both without it (`SyncImportGate`).
///
/// The public entry points run one at a time, in call order. Stamps are kept in `syncRecord` (the opaque
/// `systemFields` and the `changeTag` compared); the change token per zone is in `syncState`.
public actor SyncEngineCore {
    /// Records in the zone that are the engine's own, never data: the import lease, the zone key marker and the
    /// sealed document files (sync spec §9.1).
    static let reservedRecordTypes: Set<String> = [TransportLeaseStore.recordType, SyncZoneKeys.recordType, SyncDocumentFile.recordType]
    /// A payload whose record would be larger than this goes as an encrypted asset (ruling R4).
    public static let largePayloadThreshold = 900_000
    /// How many times one push tries one record before leaving it for the next sync.
    static let triesPerPush = 4
    /// A used lease is renewed once it is this old.
    static let leaseRenewalAge: TimeInterval = 10 * 60

    private static let log = Logger(subsystem: "com.personal.budget", category: "Sync")

    let db: any DatabaseWriter
    let transport: any SyncTransport
    public nonisolated let device: SyncDevice
    private let batchSize: Int
    let clock: @Sendable () -> Date
    /// Where evidence files live here and when they download; nil: this device doesn't sync files (it still
    /// keeps and sends each document's file reference).
    let documents: SyncDocumentFiles?
    /// Where the zone keys are (iCloud Keychain in the apps; ruling R15).
    let keyStore: any SyncKeyStore
    /// Pulls only, never writes to the server (the read-only iPhone, plan step 4 Task 12): no zone is created (a
    /// missing one is "nothing to download yet"), nothing is pushed, no key marker is published, no lease is taken.
    public nonisolated let readOnly: Bool
    /// Whose device this is: which private zone it syncs besides the household (step 6).
    public nonisolated let viewer: SyncViewer
    /// Whether incoming changes are re-validated against the writer's permissions (the Mac; step 6 Task 9).
    public nonisolated let revalidatesAccess: Bool
    /// Each zone's current key for the push under way.
    var pushKeys: [String: HouseholdKey] = [:]
    /// Tests only: an assignment that replaces the router's for a record (table, local id), to prove the guard.
    var assignmentOverride: (@Sendable (String, Int64) -> ZoneAssignment?)?

    func setAssignmentOverride(_ override: (@Sendable (String, Int64) -> ZoneAssignment?)?) {
        assignmentOverride = override
    }

    /// A read-only engine was asked to write.
    public enum ReadOnlyError: Error, Equatable {
        case readOnly
    }
    /// The last entry point started: the next one waits for it.
    private var tail: Task<Void, Never>?
    /// The passing transport error behind the last `SyncKeyError.unavailable` (set by the key fetch and publish).
    var keyTransportError: SyncTransportError?

    public init(db: any DatabaseWriter, transport: any SyncTransport, device: SyncDevice, keyStore: any SyncKeyStore, batchSize: Int = 200,
                clock: @escaping @Sendable () -> Date = { Date() }, documents: SyncDocumentFiles? = nil, readOnly: Bool = false,
                viewer: SyncViewer = .none, revalidatesAccess: Bool = false) {
        self.db = db
        self.readOnly = readOnly
        self.viewer = viewer
        self.revalidatesAccess = revalidatesAccess
        self.documents = documents
        self.transport = transport
        self.device = device
        self.keyStore = keyStore
        self.batchSize = max(1, batchSize)
        self.clock = clock
    }

    /// The zones this device syncs: `household`, and the viewer's private zone when there is a viewer. Never
    /// another person's private zone (sync spec §3.1).
    public nonisolated func zones(db: Database) throws -> [String] { zoneList }

    nonisolated var zoneList: [String] {
        [SyncZones.household] + (viewer.personUuid.map { [SyncZones.privateZone(personUuid: $0)] } ?? [])
    }

    /// The lease store, sealing with `key` (the zone's current key) and reading with every key held here.
    private func leaseStore(_ key: HouseholdKey?) throws -> TransportLeaseStore {
        TransportLeaseStore(transport: transport, sealingKey: key?.key, keys: try keyStore.allKeys(zone: SyncRecordStore.householdZone))
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
    /// `ImportLeaseError.heldBy` ("Importing on <device>") while another device holds it, and
    /// `SyncKeyError.waitingForHouseholdKey` while this device doesn't hold the household key yet.
    public func acquireImportLease() async throws {
        guard !readOnly else { throw ReadOnlyError.readOnly }
        try await serialized {
            try await self.prepare()
            let key = try await self.householdKey(zone: SyncRecordStore.householdZone, create: true)
            let now = self.clock()
            let lease = try await ImportLease.acquire(device: self.device, now: now, transport: try self.leaseStore(key))
            try await self.db.write { db in
                try SyncImportGate.setHeldLease(HeldImportLease(record: lease.record, tag: lease.tag), db: db, now: now)
            }
        }
    }

    /// Gives the lease up without importing (the user cancelled). A batch's lease is released by the push
    /// that uploads the batch's close.
    public func releaseImportLease() async throws {
        guard !readOnly else { throw ReadOnlyError.readOnly }
        try await serialized {
            guard let held = try await self.db.read({ db in try SyncImportGate.heldLease(db: db) }) else { return }
            let key = try await self.householdKey(zone: SyncRecordStore.householdZone, create: false)
            try await ImportLease.release(ImportLease.Lease(record: held.record, tag: held.tag), transport: try self.leaseStore(key))
            let now = self.clock()
            try await self.db.write { db in try SyncImportGate.setHeldLease(nil, db: db, now: now) }
        }
    }

    /// Who holds the lease now ("Importing on <device>"), or nil. Read only: it doesn't wait its turn.
    public func importLeaseHolder() async throws -> ImportLeaseRecord? {
        try await ImportLease.holder(now: clock(), transport: try leaseStore(nil))
    }

    /// Runs `body` after every entry point called before it has finished (actor methods are reentrant at
    /// each `await`, so without this two syncs would interleave: double sends, a token going back). Cancelling the
    /// caller cancels the run (plan step 4 Task 1): it stops at its next operation, and the transport sees it.
    func serialized<T: Sendable>(_ body: @escaping @Sendable () async throws -> T) async throws -> T {
        let previous = tail
        let task = Task<T, Error> {
            await previous?.value
            try Task.checkCancellation()
            return try await body()
        }
        tail = Task { _ = try? await task.value }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    // MARK: Pull

    func pullAll() async throws -> SyncPullReport {
        try await prepare()
        var report = SyncPullReport()
        // The private zone first, then the household: a record moving out of the household is here from its new zone
        // before its marker comes, and a stub's companion waits for the stub.
        for zone in zoneList.reversed() {
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
            report.waitingForKey += zoneReport.waitingForKey
            report.reconciled += zoneReport.reconciled
        }
        // The Mac keeps every file (sync spec §5.7).
        let files = try await downloadMissingDocuments()
        report.documentsDownloaded = files.downloaded
        report.documentsNeedingAttention = files.needingAttention
        return report
    }

    private enum Entry: Sendable {
        case save(SyncPayload, SyncServerStamp)
        case delete(SyncDeletion)
        case unreadable(recordType: String)
        case waiting(SyncServerRecord)
        case companionDeleted
    }

    /// Tests only: one zone's pull (to deliver a move's two halves in either order).
    func pullZone(_ zone: String) async throws -> SyncPullReport {
        try await serialized {
            try await self.prepare()
            return try await self.pull(zone: zone)
        }
    }

    private func pull(zone: String) async throws -> SyncPullReport {
        var token = try await db.read { db in try Self.token(zone: zone, db: db) }
        var entries: [String: (position: Int, entry: Entry)] = [:]
        var position = 0
        var alreadyHeld = 0
        // A fetch from the start lists every record the zone holds (ruling R12 reconciles against it).
        var full = token == nil
        var listed: Set<String> = []
        var zoneKeys: [String: SyncServerRecord] = [:]
        // Every key held here for the zone (ruling R15): what one of them sealed opens; the rest waits for its key.
        let keys = try keyStore.allKeys(zone: zone)
        while true {
            // Cancelled: stops before the next page; nothing fetched so far is applied, the token stays.
            try Task.checkCancellation()
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
                zoneKeys = [:]
                continue
            } catch SyncTransportError.zoneNotFound {
                // Read-only: the household hasn't been shared up yet; nothing to download, nothing made here.
                if readOnly { return SyncPullReport() }
                try await recoverMissingZone(zone)
                return SyncPullReport()
            }
            let records = page.records
            let held = try await db.read { db in try Self.heldTags(records, db: db) }
            for change in page.changes {
                position += 1
                switch change {
                case .record(let record):
                    let name = record.wire.recordName
                    listed.insert(name)
                    if record.wire.recordType == SyncZoneKeys.recordType { zoneKeys[name] = record }
                    guard !Self.reservedRecordTypes.contains(record.wire.recordType) else { continue }
                    if let tag = held[name], tag == record.stamp.changeTag {
                        // Already held at this version (this device's own upload coming back): skipped,
                        // before any asset is opened.
                        entries[name] = nil
                        alreadyHeld += 1
                        continue
                    }
                    do {
                        entries[name] = (position, .save(try SyncLargePayload.payload(from: record.wire, keys: keys), record.stamp))
                    } catch FieldSealing.SealingError.keyMissing {
                        entries[name] = (position, .waiting(record))
                    } catch {
                        entries[name] = (position, .unreadable(recordType: record.wire.recordType))
                    }
                case .deletion(let deletion):
                    guard !Self.reservedRecordTypes.contains(deletion.recordType ?? "") else { continue }
                    if deletion.recordType == SyncZoneRouter.companionRecordType {
                        // A companion deleted: never the account it names.
                        entries[deletion.recordName] = (position, .companionDeleted)
                        continue
                    }
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
        let keyRecords = Array(zoneKeys.values)
        let now = clock()
        try Task.checkCancellation()
        let (pulled, discarded) = try await db.write { db -> (SyncPullReport, [String]) in
            var report = SyncPullReport()
            report.alreadyHeld = skipped
            report.received = ordered.count + skipped
            let user = try Self.deviceUser(db: db)
            var incoming: [SyncIncomingChange] = []
            var stamps: [String: SyncServerStamp] = [:]
            // Markers and companions keep their stamps apart from their records' (step 6).
            var markers: [String: SyncPayload] = [:]
            var companions: Set<String> = []
            let followed = Set(self.zoneList)
            // Records that waited for their key and now open (ruling R15) go first, as received then, with their
            // stamps, through the same checked apply; a newer version in this pull replaces one.
            let arriving = Set(ordered.map(\.0))
            for (payload, stamp) in try SyncTranslator.takeWaitingForKey(keys: keys, db: db, now: now) where !arriving.contains(payload.recordName) {
                incoming.append(.save(payload))
                stamps[payload.recordName] = stamp
                if payload.movedTo != nil, payload.mergedInto == nil { markers[payload.recordName] = payload }
                if payload.recordType == SyncZoneRouter.companionRecordType { companions.insert(payload.recordName) }
            }
            for (name, entry) in ordered {
                switch entry {
                case .save(let payload, let stamp):
                    incoming.append(.save(payload))
                    stamps[name] = stamp
                    if payload.movedTo != nil, payload.mergedInto == nil { markers[name] = payload }
                    if payload.recordType == SyncZoneRouter.companionRecordType { companions.insert(name) }
                case .delete(let deletion):
                    // Only where the record lives here: a deletion in a zone it left (or never was in) isn't its delete.
                    // (Or where a marker said it went from the zone it lives in here, and its save from there hasn't come.)
                    if let local = try String.fetchOne(db, sql: "SELECT zone FROM syncRecord WHERE uuid = ?", arguments: [name]), local != zone,
                       try !SyncZoneMoves.knowsMarker(uuid: name, zone: local, db: db) {
                        continue
                    }
                    incoming.append(.delete(recordName: deletion.recordName, recordType: deletion.recordType))
                case .companionDeleted:
                    if try SyncCompanions.stamp(name: name, db: db)?.zone == zone { try SyncCompanions.remove(name: name, db: db) }
                case .unreadable(let type):
                    try SyncTranslator.stageUnreadable(recordType: type, recordName: name, db: db, now: now)
                    report.unreadable += 1
                case .waiting(let record):
                    try SyncTranslator.stageWaitingForKey(record, db: db, now: now)
                    report.waitingForKey += 1
                }
            }
            // Files kept for later deleted on another device: their hashes, so the copies here go once the rows have.
            var waitingDeleted: [String] = []
            for case (let name, .delete) in ordered {
                if let id = try SyncRecordStore.localId(table: SyncFileTables.importWaitingFile, uuid: name, db: db),
                   let sha = try String.fetchOne(db, sql: "SELECT sha256 FROM importWaitingFile WHERE id = ?", arguments: [id]) {
                    waitingDeleted.append(sha)
                }
            }
            // Sync spec §5.4: the apply (and the batches it completes or flushes) is kept only while it moves no
            // figure on a filed or paid return; the records that would are held, the rest applies.
            // Staged records left by an older build are retried here, through the check (not at open).
            let retryAll = try Self.retryStagedRequested(db: db)
            // (Nothing to apply or retry and no closed batch to flush: nothing can move, nothing is taken.)
            let closedWaiting = try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM syncBatch WHERE state = 'closed')") ?? true
            let baseline = incoming.isEmpty && !closedWaiting && !retryAll ? FiledYearBaseline.none : try FiledYearSyncCheck.baseline(db: db)
            // Caught up: a closed batch that can't complete any more applies now (`SyncBatch.flushClosed`, inside).
            // Read-only (the phone): re-filing the apply does here stays untracked, since it is never sent.
            // Step 6: what this device places in a private zone of its own never comes in from the household (an
            // edit made there to a copy the record has left): such a save is applied, found by the placement after the
            // apply, rolled back and refused, logged for attention, and the marker goes over it again.
            let checksZones = (try? Self.placesRecords(db: db)) ?? false
            // Where each arriving record lives here before the apply: a copy coming in from another zone takes it out
            // of that one, which then needs its marker (and its old file's delete), as a move of this device's would.
            var before: [String: (zone: String, stamp: Data?, file: String?)] = [:]
            if checksZones, !self.readOnly {
                for case .save(let payload) in incoming where payload.movedTo == nil && payload.mergedInto == nil
                    && SyncSchema.table(payload.recordType) != nil {
                    guard let record = try SyncRecordRow.fetchOne(db, sql: "SELECT * FROM syncRecord WHERE uuid = ?", arguments: [payload.recordName]),
                          record.zone != zone, try SyncPresence.isIn(uuid: record.uuid, zone: record.zone, db: db) else { continue }
                    before[payload.recordName] = (record.zone, record.systemFields, try SyncDocumentFile.reference(uuid: record.uuid, db: db)?.recordName)
                }
            }
            var refused: [String: String] = [:]
            var outcome = FiledYearSyncCheck.Outcome()
            while true {
                let taking = incoming.filter { refused[$0.recordName] == nil }
                let applyAll = { try FiledYearSyncCheck.apply(taking, baseline: baseline, db: db, deviceUser: user, now: now, retryAll: retryAll) }
                var misplaced: [(uuid: String, table: String)] = []
                try db.inSavepoint {
                    outcome = try self.readOnly ? SyncChangeTracker.readOnlyApply(db: db, applyAll) : applyAll()
                    guard checksZones else { return .commit }
                    misplaced = try Self.misplaced(results: outcome.results, followed: followed, db: db)
                    return misplaced.isEmpty ? .commit : .rollback
                }
                if misplaced.isEmpty { break }
                for record in misplaced {
                    refused[record.uuid] = record.table
                    // A held or waiting save of it (applied from staging in this apply) is refused too.
                    try db.execute(sql: "DELETE FROM syncStaging WHERE uuid = ?", arguments: [record.uuid])
                    try SyncMerge.logConflict(table: record.table, uuid: record.uuid, field: "*",
                                              losing: .string(Self.privateInHouseholdMessage), winner: nil, loser: nil, db: db, now: now)
                    try SyncZoneMoves.markerAgain(uuid: record.uuid, tableName: record.table, zone: SyncZones.household,
                                                  systemFields: stamps[record.uuid]?.systemFields, db: db)
                    try SyncPresence.add(uuid: record.uuid, zone: SyncZones.household, db: db)
                }
            }
            incoming.removeAll { refused[$0.recordName] != nil }
            // Where the server has each record now: its copy (or a marker) in this zone, or nothing after a deletion.
            for change in incoming {
                switch change {
                case .save(let payload): try SyncPresence.add(uuid: payload.recordName, zone: zone, db: db)
                case .delete(let name, _): try SyncPresence.remove(uuid: name, zone: zone, db: db)
                }
            }
            if retryAll { try db.execute(sql: "DELETE FROM syncState WHERE key = ?", arguments: [Self.retryStagedKey]) }
            let results = outcome.results
            report.filedYearAlert = outcome.alert
            report.held = outcome.alert?.records.count ?? 0
            for (name, result) in results {
                if case .staged = result {
                    report.staged += 1
                } else if let stamp = stamps[name] {
                    if let marker = markers[name] {
                        // A marker over a record's old copy here: kept as that place's version, where this device
                        // follows the record (it may move back there); never the record's own stamp.
                        if let target = marker.movedTo, followed.contains(target) {
                            try SyncZoneMoves.takeServerStamp(uuid: name, tableName: marker.recordType, zone: zone,
                                                              systemFields: stamp.systemFields, db: db)
                        }
                    } else if companions.contains(name) {
                        try SyncCompanions.store(name: name, zone: zone, stamp: stamp, db: db)
                    } else {
                        // Only a record whose version is now merged here takes the server's stamp: one still staged
                        // must not, or a later save would overwrite a version this device never merged.
                        try Self.storeStamp(stamp, uuid: name, db: db)
                    }
                }
            }
            // Document files (sync spec §9.1): the zone key adopted, each document's file reference kept.
            report.unreadable += try Self.takeDocumentFiles(zoneKeys: keyRecords, saves: incoming.compactMap { if case .save(let payload) = $0 { return payload } else { return nil } },
                                       deletions: ordered.compactMap { if case .delete = $0.1 { return $0.0 } else { return nil } },
                                       zone: zone, keyStore: self.keyStore, db: db, now: now)
            for case .save(let payload) in incoming {
                guard let prior = before[payload.recordName] else { continue }
                if case .staged? = results[payload.recordName] { continue }
                guard try String.fetchOne(db, sql: "SELECT zone FROM syncRecord WHERE uuid = ?", arguments: [payload.recordName]) == zone else { continue }
                let file = try SyncDocumentFile.reference(uuid: payload.recordName, db: db)?.recordName
                try SyncZoneMoves.record(uuid: payload.recordName, tableName: payload.recordType, from: prior.zone, to: zone,
                                         systemFields: prior.stamp, oldFile: prior.file == file ? nil : prior.file, toFile: file, db: db)
            }
            if let reconcile {
                report.reconciled = try SyncTranslator.reconcile(zone: zone, listed: reconcile, db: db, now: now).count
            }
            if let finalToken { try Self.setToken(finalToken, zone: zone, db: db, now: now) }
            return (report, waitingDeleted)
        }
        // A row deleted remotely takes its local copy with it (never one whose hash has a row here again).
        if let documents, !discarded.isEmpty {
            ImportWaitingList(root: documents.waitingRoot, database: db).removeCopies(sha256s: discarded)
        }
        return pulled
    }

    static let privateInHouseholdMessage = SyncTranslator.needsAttention + "arrived in the household but is private here; not taken"

    /// The records an apply wrote that now sit in the household here though this device places them in a private
    /// zone of its own (by the router, after the apply): a household copy taken in, from this pull or from staging (a
    /// held or waiting save applied now). Markers, redirects and companions never land there.
    static func misplaced(results: [String: IncomingResult], followed: Set<String>, db: Database) throws -> [(uuid: String, table: String)] {
        let applied = results.compactMap { name, result -> String? in
            switch result {
            case .applied, .conflicted: return name
            case .staged, .discarded, .kept: return nil
            }
        }
        guard !applied.isEmpty, let router = try? SyncZoneRouter(db: db) else { return [] }
        var found: [(uuid: String, table: String)] = []
        for name in applied.sorted() {
            guard let row = try Row.fetchOne(db, sql: "SELECT tableName, localId, zone FROM syncRecord WHERE uuid = ?", arguments: [name]),
                  (row["zone"] as String) == SyncZones.household,
                  let placed = try? router.assignment(table: row["tableName"], localId: row["localId"]),
                  placed.isPrivate, followed.contains(placed.zone) else { continue }
            found.append((name, row["tableName"]))
        }
        return found
    }

    // MARK: Push

    func pushAll() async throws -> SyncPushReport {
        // Read-only: nothing is ever sent (nor a key made or a lease renewed).
        if readOnly { return SyncPushReport() }
        try await prepare()
        var report = SyncPushReport()
        // Step 6: the summaries of the viewer's own accounts are rebuilt first when something they read changed, so
        // what changed goes up with this push. Only the owner's devices build them (the viewer's own accounts only).
        if let personUuid = viewer.personUuid {
            let today = clock()
            try await db.write { db in
                guard try AccountSummaryBuilder.isDirty(db: db),
                      let person = try SyncRecordStore.localId(table: "person", uuid: personUuid, db: db) else { return }
                try AccountSummaryBuilder.rebuild(ownerPersonId: person, db: db, today: today)
            }
        }
        let busy = try await db.read { db in
            try !SyncChangeTracker.pending(db: db).isEmpty || SyncImportGate.heldLease(db: db) != nil
                || !SyncZoneMoves.unfinished(db: db).isEmpty || !SyncCleanup.all(db: db).isEmpty
        }
        guard busy else { return report }
        // Step 6: once the ownership sheet is saved every record is placed in its zone (`SyncZoneRouter`) and every
        // save checked by the guard, loaded once for the push. Before it only a demo database pushes (everything to
        // the household, as before step 6); real data is refused.
        let guardian = try await db.read { db -> SyncZoneGuard? in try Self.placesRecords(db: db) ? try SyncZoneGuard(db: db) : nil }
        // Every record goes sealed under its zone's current key (ruling R15): without it here, nothing is sent and
        // no key is made while another device's marker names one (it waits for iCloud Keychain).
        var key: HouseholdKey
        keyTransportError = nil
        pushKeys = [:]
        do {
            key = try await sealingKey(zone: SyncRecordStore.householdZone)
        } catch let wait as SyncKeyError {
            Self.log.error("Sync push waits for the household key (\(String(describing: wait), privacy: .public))")
            report.keyWait = wait
            report.keyWaitCause = wait == .unavailable ? keyTransportError : nil
            return report
        }
        try await renewLeaseIfDue(key)
        var tries: [String: Int] = [:]
        var pulled = false
        var recovered = false
        var movesTried = false
        do {
            while true {
                var needsPull = false
                var missingZones: Set<String> = []
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
                    // Cancelled: stops before the next operation; what wasn't acknowledged stays pending.
                    try Task.checkCancellation()
                    let chunk = Array(saves[start..<min(start + chunkSize, saves.count)])
                    for change in chunk { tries[change.uuid, default: 0] += 1 }
                    // A long upload keeps a used lease alive (it expires 30 minutes after it was last renewed).
                    try await renewLeaseIfDue(key)
                    let flags = try await pushSaves(chunk, limits: limits, guardian: guardian, report: &report)
                    needsPull = needsPull || flags.needsPull
                    missingZones.formUnion(flags.missingZones)
                }
                // Moves (step 6): markers over the old copies and the old file records' deletes, once the new copies
                // are saved; then what is left to delete on the server.
                missingZones.formUnion(try await finishMoves(limits: limits, guardian: guardian, tries: &tries, counted: !movesTried))
                movesTried = true
                try await cleanUp()
                // Deletes, after the saves, except a batch's while its run's record isn't on the server yet.
                let triesAfterSaves = tries
                let deletes = try await db.read { db in
                    try Self.sendableDeletes(db: db).filter { triesAfterSaves[$0.uuid, default: 0] < Self.triesPerPush }
                }
                for start in stride(from: 0, to: deletes.count, by: chunkSize) {
                    try Task.checkCancellation()
                    let chunk = Array(deletes[start..<min(start + chunkSize, deletes.count)])
                    for change in chunk { tries[change.uuid, default: 0] += 1 }
                    let zoneSet = Set(zoneList)
                    let zones = try await db.read { db in
                        guardian == nil ? try Self.zones(of: chunk, db: db) : try Self.presentZones(of: chunk, db: db).filter { zoneSet.contains($0.key) }
                    }
                    for (zone, names) in zones.sorted(by: { $0.key < $1.key }) {
                        try await transport.delete(names, zone: zone)
                    }
                    try await db.write { db in
                        try SyncChangeTracker.acknowledge(chunk, db: db)
                        for (zone, names) in zones {
                            for name in names { try SyncPresence.remove(uuid: name, zone: zone, db: db) }
                        }
                        for change in chunk {
                            try SyncCompanions.remove(name: SyncZoneRouter.companionRecordName(accountUuid: change.uuid), db: db)
                        }
                        _ = try SyncBatch.closeUploaded(db: db)
                    }
                    report.deleted += chunk.count
                }
                if !missingZones.isEmpty {
                    guard !recovered else { throw SyncTransportError.zoneNotFound(missingZones.sorted().joined(separator: ",")) }
                    recovered = true
                    for zone in missingZones.sorted() { try await recoverMissingZone(zone) }
                    tries = [:]
                    // The marker went with the zone: published again (the same key) before anything is sent.
                    keyTransportError = nil
                    pushKeys = [:]
                    key = try await sealingKey(zone: SyncRecordStore.householdZone)
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
                let zoneSet = zoneList
                let more = try await db.read { db in
                    let staged = try Set(String.fetchAll(db, sql: "SELECT uuid FROM syncStaging"))
                    return try SyncChangeTracker.pending(db: db).contains {
                        $0.kind != .delete && !staged.contains($0.uuid) && triesLeft[$0.uuid, default: 0] < Self.triesPerPush
                    } || Self.sendableDeletes(db: db).contains { triesLeft[$0.uuid, default: 0] < Self.triesPerPush }
                        || SyncZoneMoves.unfinished(db: db).contains {
                            zoneSet.contains($0.zone) && triesLeft[Self.markerTryKey($0.uuid, $0.zone), default: 0] < Self.triesPerPush
                        }
                }
                if !more { break }
            }
        } catch let wait as SyncKeyError {
            // A private zone's key isn't held here yet (or its marker can't be read now): the rest waits too.
            Self.log.error("Sync push waits for a zone key (\(String(describing: wait), privacy: .public))")
            report.keyWait = wait
            report.keyWaitCause = wait == .unavailable ? keyTransportError : nil
            return report
        }
        try await releaseLeaseIfDone(key)
        return report
    }

    /// The zone's current key for this push (made for a zone of this device's own when it has none, ruling R15).
    private func sealingKey(zone: String) async throws -> HouseholdKey {
        if let known = pushKeys[zone] { return known }
        let key = try await householdKey(zone: zone, create: true)
        pushKeys[zone] = key
        return key
    }

    /// Whether records are placed in zones (step 6): once the admin has confirmed who owns each account. Before that
    /// only a demo database (`DemoMarker`) pushes, everything to `household` as before step 6 (every account is at
    /// Everything then; one that isn't stops it). Real data is never uploaded before every account has its owner and
    /// level (sharing spec §1, §10): `ownershipNotConfirmed`.
    static func placesRecords(db: Database) throws -> Bool {
        if try SharingSetup.isConfirmed(db: db) { return true }
        guard try DemoMarker.isDemo(db) else { throw SyncZoneRouterError.ownershipNotConfirmed }
        if try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM account WHERE sharingLevel <> ?)",
                             arguments: [SharingLevel.everything.rawValue]) == true {
            throw SyncZoneRouterError.ownershipNotConfirmed
        }
        return false
    }

    static func markerTryKey(_ uuid: String, _ zone: String) -> String { "marker:\(zone):\(uuid)" }

    /// Deleted records by the zones the server has them in (`SyncPresence`: their copy, or a marker over one), with a
    /// deleted account's companion in its zone. A record the server never had is in none: nothing is sent for it.
    static func presentZones(of changes: [PendingChange], db: Database) throws -> [String: [String]] {
        var result: [String: [String]] = [:]
        for change in changes {
            for zone in try SyncPresence.zones(uuid: change.uuid, db: db) { result[zone, default: []].append(change.uuid) }
            let companion = SyncZoneRouter.companionRecordName(accountUuid: change.uuid)
            if let stamp = try SyncCompanions.stamp(name: companion, db: db), stamp.systemFields != nil {
                result[stamp.zone, default: []].append(companion)
            }
        }
        return result
    }

    /// What one save of a push is.
    private enum SendKind {
        /// A record; `move` when it is leaving another zone.
        case record(PendingChange, move: Move?)
        /// The `accountDetails` companion of an account stub.
        case companion
    }

    /// A record leaving `from`, where its copy is at `oldStamp` and its file record is `oldFile`.
    private struct Move {
        var from: String
        var oldStamp: Data?
        var oldFile: String?
    }

    private struct ZonedName: Hashable {
        var zone: String
        var name: String
    }

    /// One built record of a chunk: what it is and what to write once it is saved. Building writes nothing of step 6.
    private struct Built {
        var change: PendingChange
        var outgoing: SyncTranslator.Outgoing?
        var move: Move?
        var systemFields: Data?
        var companionFields: Data?
        /// A companion this account no longer has (Hidden, or Everything): deleted once the account is saved.
        var obsoleteCompanion: (zone: String, name: String)?
        /// A resent record's log line, written once the chunk passes the guard (placement on).
        var resentReconciled = false
    }

    /// Sends one chunk of saves and takes in the results. Nothing of step 6 is written before the guard has passed
    /// the exact payloads that go (file references included) and the server has taken them: a halt leaves this
    /// device's state as it was.
    private func pushSaves(_ chunk: [PendingChange], limits: SyncOperationLimits, guardian: SyncZoneGuard?,
                           report: inout SyncPushReport) async throws -> (needsPull: Bool, missingZones: Set<String>) {
        let buildTime = clock()
        let zoneSet = zoneList
        let override = assignmentOverride
        let placing = guardian != nil
        let built = try await db.write { db -> [Built] in
            let placement = try placing ? Self.placement(SyncZoneRouter(db: db), override: override, db: db) : nil
            return try chunk.map { change in
                guard let outgoing = try SyncTranslator.outgoing(change, db: db, placement: placement) else {
                    return Built(change: change, outgoing: nil)
                }
                var item = Built(change: change, outgoing: outgoing)
                let resent = try Int.fetchOne(db, sql: "SELECT resent FROM syncPending WHERE uuid = ?", arguments: [change.uuid]) ?? 0
                if resent != 0 {
                    item.outgoing?.payload.resent = true
                    if resent == SyncTranslator.resentAfterServerDelete {
                        if placing {
                            item.resentReconciled = true
                        } else {
                            // No deletion came with the pull that followed (a full fetch lists none): the edit brings
                            // the record back, visibly, as ruling R12 does.
                            try Self.logResentEdit(change, db: db, now: buildTime)
                        }
                    }
                }
                let payload = outgoing.payload
                guard placing, payload.mergedInto == nil,
                      let record = try SyncRecordRow.fetchOne(db, sql: "SELECT * FROM syncRecord WHERE uuid = ?", arguments: [change.uuid]) else {
                    item.systemFields = try Self.systemFields(uuid: payload.recordName, db: db)
                    return item
                }
                if record.zone != payload.zone, try Self.isOnTheServer(record, db: db) {
                    // A move: the new copy first, the marker and the old file's delete once it is saved.
                    let file = SyncFileTables.names.contains(change.table) ? try SyncDocumentFile.reference(uuid: change.uuid, db: db) : nil
                    item.move = Move(from: record.zone, oldStamp: record.systemFields, oldFile: file?.recordName)
                }
                item.systemFields = try Self.saveStamp(uuid: change.uuid, zone: payload.zone, record: record, db: db)
                if let companion = outgoing.companion {
                    item.companionFields = try SyncCompanions.stamp(name: companion.recordName, db: db).flatMap { $0.zone == companion.zone ? $0.systemFields : nil }
                } else if change.table == "account" {
                    let name = SyncZoneRouter.companionRecordName(accountUuid: change.uuid)
                    if let stale = try SyncCompanions.stamp(name: name, db: db) { item.obsoleteCompanion = (stale.zone, name) }
                }
                return item
            }
        }
        // Only the zones this device syncs: a record placed elsewhere (another person's) waits.
        var nothingToSend: [PendingChange] = []
        var payloads: [SyncPayload] = []
        var kinds: [ZonedName: SendKind] = [:]
        var systemFields: [ZonedName: Data] = [:]
        var items: [String: Built] = [:]
        for item in built {
            guard let outgoing = item.outgoing else {
                nothingToSend.append(item.change)
                continue
            }
            guard zoneSet.contains(outgoing.payload.zone) else {
                Self.log.error("Sync left a \(item.change.table, privacy: .public) record unsent: its zone isn't one this device syncs")
                report.heldBack += 1
                continue
            }
            items[item.change.uuid] = item
            let name = ZonedName(zone: outgoing.payload.zone, name: outgoing.payload.recordName)
            payloads.append(outgoing.payload)
            kinds[name] = .record(item.change, move: item.move)
            if let fields = item.systemFields { systemFields[name] = fields }
            if let companion = outgoing.companion, zoneSet.contains(companion.zone) {
                let companionName = ZonedName(zone: companion.zone, name: companion.recordName)
                payloads.append(companion)
                kinds[companionName] = .companion
                if let fields = item.companionFields { systemFields[companionName] = fields }
            }
        }
        // Evidence files sealed (sync spec §9.1) in their record's zone, under its key; a moving record's file is
        // sealed again. Nothing is uploaded yet.
        var sealed: [String: SealedFiles] = [:]
        var final: [SyncPayload] = []
        for zone in Self.sendingOrder(Set(payloads.map(\.zone))) {
            let key = try await sealingKey(zone: zone)
            let inZone = payloads.filter { $0.zone == zone }
            let reseal = Set(inZone.filter { items[$0.recordName]?.move != nil && kinds[ZonedName(zone: zone, name: $0.recordName)] != nil }
                .map(\.recordName))
            let files = try await sealDocumentFiles(inZone, key: key, keys: try keyStore.allKeys(zone: zone), zone: zone, reseal: reseal)
            sealed[zone] = files
            final += files.payloads
        }
        // The last check (sharing spec §5, anti-goal 1), on exactly what goes: nothing of this chunk goes, and nothing
        // here changes, when any of it would leak.
        try await review(final, guardian: guardian)
        try await logMismatchedFiles(sealed.values.flatMap(\.mismatched))
        let resentLogs = built.filter(\.resentReconciled).map(\.change)
        if !resentLogs.isEmpty {
            try await db.write { db in for change in resentLogs { try Self.logResentEdit(change, db: db, now: buildTime) } }
        }
        // The files' records go first; a record whose file couldn't be uploaded now waits, still pending.
        var uploaded: [String: Set<String>] = [:]
        for (zone, files) in sealed {
            let saved = try await uploadFileRecords(files.files)
            uploaded[zone] = saved
            report.documentsSealed += saved.count
            if !placing {
                // As before step 6: a sealed file's reference is kept as soon as its record is on the server.
                let keep = files.references.filter { files.files.map(\.uuid).contains($0.key) ? saved.contains($0.key) : true }
                let now = clock()
                try await db.write { db in for (uuid, reference) in keep { try SyncDocumentFile.setReference(reference, uuid: uuid, db: db, now: now) } }
            }
        }
        var wires: [String: [SyncWireRecord]] = [:]
        var sent: [ZonedName: SyncPayload] = [:]
        for payload in final {
            let name = ZonedName(zone: payload.zone, name: payload.recordName)
            let needsFile = sealed[payload.zone]?.files.contains { $0.uuid == payload.recordName } ?? false
            if needsFile, uploaded[payload.zone]?.contains(payload.recordName) != true {
                report.documentsDeferred += 1
                kinds[name] = nil
                continue
            }
            let (wire, packed) = try SyncLargePayload.wire(for: payload, key: try await sealingKey(zone: payload.zone).key)
            if packed { report.asAssets += 1 }
            wires[payload.zone, default: []].append(wire)
            sent[name] = payload
        }
        var results: [ZonedName: SaveResult] = [:]
        for zone in Self.sendingOrder(Set(wires.keys)) {
            let fields = systemFields.filter { $0.key.zone == zone }.reduce(into: [String: Data]()) { $0[$1.key.name] = $1.value }
            for operation in Self.operations(wires[zone] ?? [], limits: limits) {
                for result in try await save(operation, ifUnchanged: fields) { results[ZonedName(zone: zone, name: result.recordName)] = result }
            }
        }
        var servers: [ZonedName: (SyncPayload?, SyncServerRecord)] = [:]
        for (name, result) in results {
            if case .changed(let server) = result.outcome {
                servers[name] = (try? SyncLargePayload.payload(from: server.wire, keys: try keyStore.allKeys(zone: name.zone)), server)
            }
        }
        let now = clock()
        let saveResults = results
        let sentKinds = kinds
        let unsent = nothingToSend
        let serverRecords = servers
        let sealedFiles = sealed
        let sentPayloads = sent
        let uploadedFiles = uploaded
        let builtItems = items
        let outcome = try await db.write { db -> (SyncPushReport, Bool, Set<String>) in
            var delta = SyncPushReport()
            var needsPull = false
            var missingZones: Set<String> = []
            var acknowledged = unsent
            var savedRecords: Set<String> = []
            let user = try Self.deviceUser(db: db)
            // Server versions to merge (refused saves), applied together through the filed-year check below.
            var merges: [SyncPayload] = []
            var mergeStamps: [String: SyncServerStamp] = [:]
            for (name, result) in saveResults.sorted(by: { ($0.key.zone, $0.key.name) < ($1.key.zone, $1.key.name) }) {
                guard let kind = sentKinds[name] else { continue }
                guard case .record(let change, let move) = kind else {
                    try Self.takeCompanionResult(result, name: name.name, zone: name.zone, server: serverRecords[name]?.1, db: db)
                    if case .zoneNotFound = result.outcome { missingZones.insert(name.zone) }
                    continue
                }
                switch result.outcome {
                case .saved(let stamp):
                    acknowledged.append(change)
                    savedRecords.insert(name.name)
                    try Self.storeStamp(stamp, uuid: name.name, db: db)
                    try SyncPresence.add(uuid: name.name, zone: name.zone, db: db)
                    if placing {
                        // Where it lives now; back over a marker it left here, that marker is gone.
                        try db.execute(sql: "UPDATE syncRecord SET zone = ? WHERE uuid = ?", arguments: [name.zone, name.name])
                        try SyncZoneMoves.arrived(uuid: name.name, zone: name.zone, db: db)
                        if let move {
                            try SyncZoneMoves.record(uuid: name.name, tableName: change.table, from: move.from, to: name.zone,
                                                     systemFields: move.oldStamp, oldFile: move.oldFile,
                                                     toFile: sentPayloads[name]?.documentFile?.recordName, db: db)
                        }
                        if let files = sealedFiles[name.zone] {
                            if let reference = files.references[name.name] {
                                try SyncDocumentFile.setReference(reference, uuid: name.name, db: db, now: now)
                            } else if files.unsealable.contains(name.name) {
                                // Moved without its file (not on this device): the old zone's file record still goes.
                                try SyncDocumentFile.setReference(nil, uuid: name.name, db: db, now: now)
                                try SyncDocumentFile.logAttention(table: change.table, uuid: name.name, message: Self.fileNotMovedMessage, db: db, now: now)
                            }
                        }
                        if let stale = builtItems[name.name]?.obsoleteCompanion {
                            try SyncCleanup.add(zone: stale.zone, recordName: stale.name, db: db)
                            try SyncCompanions.remove(name: stale.name, db: db)
                        }
                    }
                    // `resent` stays on an edit made meanwhile (still pending at a newer revision): change feeds carry
                    // only a record's latest version, so a device that deleted it may never see the save that
                    // recreated it, and would discard a plain update (divergence). It can't override a delete that
                    // reached the server since: that save is refused (`deleted`) and the pull brings the delete.
                    delta.saved += 1
                case .changed:
                    guard let (payload, server) = serverRecords[name] else { continue }
                    if try SyncTombstoneRow.fetchOne(db, key: name.name)?.mergedInto != nil {
                        // A redirect: merged here, so the server's version (edited elsewhere meanwhile) is that record's
                        // past; the redirect is sent again over it.
                        try db.execute(sql: "UPDATE syncTombstone SET systemFields = ? WHERE uuid = ?",
                                       arguments: [server.stamp.systemFields, name.name])
                        // Not an error: it goes again in this push, like a merged save.
                        delta.merged += 1
                        continue
                    }
                    if let payload, payload.movedTo != nil {
                        // The place is held by a marker: its version is taken and the record goes again over it.
                        try SyncZoneMoves.takeServerStamp(uuid: name.name, tableName: change.table, zone: name.zone,
                                                          systemFields: server.stamp.systemFields, db: db)
                        try SyncPresence.add(uuid: name.name, zone: name.zone, db: db)
                        delta.merged += 1
                        continue
                    }
                    if let payload, let move, payload.recordType == change.table {
                        // A copy of the record is already in the zone it is moving to (an earlier attempt whose reply was
                        // lost, or another device of this person's): the move stands. It is recorded now, with the old
                        // copy's stamp and file, and the record lives in the new zone from here on, at the server's
                        // version. A copy holding what was sent counts as this save done; any other is merged (the
                        // merge never moves the record back, nor drops the move).
                        try SyncZoneMoves.record(uuid: name.name, tableName: change.table, from: move.from, to: name.zone,
                                                 systemFields: move.oldStamp, oldFile: move.oldFile, toFile: payload.documentFile?.recordName, db: db)
                        try db.execute(sql: "UPDATE syncRecord SET zone = ? WHERE uuid = ?", arguments: [name.zone, name.name])
                        try Self.storeStamp(server.stamp, uuid: name.name, db: db)
                        try SyncPresence.add(uuid: name.name, zone: name.zone, db: db)
                        try SyncZoneMoves.arrived(uuid: name.name, zone: name.zone, db: db)
                        if payload.fields == sentPayloads[name]?.fields {
                            acknowledged.append(change)
                            if let reference = payload.documentFile {
                                try SyncDocumentFile.setReference(reference, uuid: name.name, db: db, now: now)
                            }
                            delta.saved += 1
                        } else {
                            merges.append(payload)
                            mergeStamps[name.name] = server.stamp
                        }
                        continue
                    }
                    guard let payload else {
                        // The server's version can't be read: kept (sealed, when only its key is missing here, else
                        // for attention); the local edit waits for it.
                        if let id = FieldSealing.keyId(of: server.wire), try self.keyStore.allKeys(zone: name.zone)[id] == nil {
                            try SyncTranslator.stageWaitingForKey(server, db: db, now: now)
                        } else {
                            try SyncTranslator.stageUnreadable(recordType: server.wire.recordType, recordName: name.name, db: db, now: now)
                        }
                        delta.refused += 1
                        continue
                    }
                    merges.append(payload)
                    mergeStamps[name.name] = server.stamp
                case .deleted:
                    if try SyncTombstoneRow.fetchOne(db, key: name.name)?.mergedInto != nil {
                        // A redirect whose record the server no longer has: saved afresh (its stale stamp would be
                        // refused on every push). Not a resurrected edit (R12): nothing to reconcile.
                        try db.execute(sql: "UPDATE syncTombstone SET systemFields = NULL WHERE uuid = ?", arguments: [name.name])
                        needsPull = true
                        continue
                    }
                    if move != nil {
                        // The marker this device knew there is gone: the record is created there afresh.
                        try SyncZoneMoves.arrived(uuid: name.name, zone: name.zone, db: db)
                        continue
                    }
                    try Self.clearStamp(uuid: name.name, db: db)
                    try db.execute(sql: "UPDATE syncPending SET resent = ? WHERE uuid = ? AND kind <> 'delete'",
                                   arguments: [SyncTranslator.resentAfterServerDelete, name.name])
                    needsPull = true
                case .zoneNotFound:
                    missingZones.insert(name.zone)
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
            if placing {
                // A file sealed for a record that didn't go: deleted on the server (a later push seals again).
                for (zone, files) in sealedFiles {
                    for file in files.files where uploadedFiles[zone]?.contains(file.uuid) == true && !savedRecords.contains(file.uuid) {
                        try SyncCleanup.add(zone: zone, recordName: file.wire.recordName, db: db)
                    }
                }
            }
            if !merges.isEmpty {
                // The server's document file references are kept here (the merged record goes with them).
                for zone in Set(merges.map(\.zone)).sorted() {
                    try Self.takeDocumentFiles(zoneKeys: [], saves: merges.filter { $0.zone == zone }, deletions: [], zone: zone,
                                               keyStore: self.keyStore, db: db, now: now)
                }
                // Merged field by field with the server's version, unless that would move a filed tax year (§5.4):
                // then the server's version is held, without its stamp, and the local edit waits for it. The merged
                // record goes again next round against the server's version (unless that version waits here).
                let baseline = try FiledYearSyncCheck.baseline(db: db)
                let outcome = try FiledYearSyncCheck.apply(merges.map { .save($0) }, baseline: baseline, db: db, deviceUser: user, now: now,
                                                           flush: false)
                let held = Set(outcome.alert?.records.map(\.recordName) ?? [])
                for payload in merges {
                    let name = payload.recordName
                    if held.contains(name) {
                        delta.held += 1
                        continue
                    }
                    if case .staged = outcome.results[name] {} else if let stamp = mergeStamps[name] {
                        try Self.storeStamp(stamp, uuid: name, db: db)
                    }
                    if mergeStamps[name] != nil { delta.merged += 1 }
                }
                delta.filedYearAlert = outcome.alert
            }
            try SyncChangeTracker.acknowledge(acknowledged, db: db)
            _ = try SyncBatch.closeUploaded(db: db)
            return (delta, needsPull, missingZones)
        }
        report.saved += outcome.0.saved
        report.merged += outcome.0.merged
        report.held += outcome.0.held
        if let alert = outcome.0.filedYearAlert {
            var merged = report.filedYearAlert ?? FiledYearSyncAlert(records: [], impacts: [])
            merged.records += alert.records
            merged.impacts += alert.impacts
            report.filedYearAlert = merged
        }
        report.refused += outcome.0.refused
        return (outcome.1, outcome.2)
    }

    static let fileNotMovedMessage = SyncTranslator.needsAttention + "moved to another zone without its file (not on this device)"

    /// Ruling R12's line for an edit that brought back a record deleted on iCloud.
    private static func logResentEdit(_ change: PendingChange, db: Database, now: Date) throws {
        try SyncMerge.logConflict(table: change.table, uuid: change.uuid, field: "*", losing: .string(SyncTranslator.reconciledEdit),
                                  winner: nil, loser: nil, db: db, now: now)
        try db.execute(sql: "UPDATE syncPending SET resent = ? WHERE uuid = ?", arguments: [SyncTranslator.resentReconciled, change.uuid])
    }

    /// Whether the record's copy in its zone is on the server (an acknowledged save or a pull put it there).
    static func isOnTheServer(_ record: SyncRecordRow, db: Database) throws -> Bool {
        if record.systemFields != nil || record.changeTag != nil { return true }
        return try SyncPresence.isIn(uuid: record.uuid, zone: record.zone, db: db)
    }

    /// The guard's review of what is about to be sent (step 6): a violation stops the push before anything of it
    /// is saved or changed here, logged for attention (fields named, never values), and thrown.
    private func review(_ payloads: [SyncPayload], guardian: SyncZoneGuard?) async throws {
        guard let guardian else { return }
        let review = guardian.review(payloads)
        guard let first = review.violations.first else { return }
        let now = clock()
        let violations = review.violations
        try await db.write { db in
            for violation in violations {
                try SyncMerge.logConflict(table: violation.recordType, uuid: violation.recordName, field: "*",
                                          losing: .string(SyncTranslator.needsAttention + "not sent: " + violation.reason),
                                          winner: nil, loser: nil, db: db, now: now)
            }
        }
        Self.log.error("Sync push stopped: \(violations.count) records failed the zone check")
        throw first
    }

    /// Private zones first, then `household`: a record moving out of the household is in its new zone before the
    /// household hears it left, and a stub's companion is there before the stub.
    static func sendingOrder(_ zones: Set<String>) -> [String] {
        zones.sorted { ($0 == SyncZones.household ? 1 : 0, $0) < ($1 == SyncZones.household ? 1 : 0, $1) }
    }

    /// Records placed by `router` (or the test stand-in), and record UUIDs to their zones for the batch tags.
    static func placement(_ router: SyncZoneRouter, override: (@Sendable (String, Int64) -> ZoneAssignment?)?,
                          db: Database) -> SyncTranslator.Placement {
        func assignment(_ table: String, _ localId: Int64) throws -> ZoneAssignment {
            if let forced = override?(table, localId) { return forced }
            return try router.assignment(table: table, localId: localId)
        }
        return SyncTranslator.Placement(assignment: { change in try assignment(change.table, change.localId) }, zones: { uuid in
            if let row = try Row.fetchOne(db.cachedStatement(sql: "SELECT tableName, localId FROM syncRecord WHERE uuid = ?"), arguments: [uuid]) {
                return try assignment(row["tableName"], row["localId"]).zone
            }
            return try String.fetchOne(db.cachedStatement(sql: "SELECT zone FROM syncTombstone WHERE uuid = ?"), arguments: [uuid])
        })
    }

    /// The version a save of the record into `zone` names: its own there; a marker this device knows there; else
    /// none (create).
    static func saveStamp(uuid: String, zone: String, record: SyncRecordRow, db: Database) throws -> Data? {
        if record.zone == zone { return record.systemFields }
        return try SyncZoneMoves.markerStamp(uuid: uuid, zone: zone, db: db)
    }

    /// A companion's save result: its stamp kept; refused or failed, its account goes again (with it).
    static func takeCompanionResult(_ result: SaveResult, name: String, zone: String, server: SyncServerRecord?, db: Database) throws {
        switch result.outcome {
        case .saved(let stamp):
            try SyncCompanions.store(name: name, zone: zone, stamp: stamp, db: db)
        case .changed:
            try SyncCompanions.store(name: name, zone: zone, stamp: server?.stamp, db: db)
            try requeueAccount(ofCompanion: name, db: db)
        case .deleted:
            try SyncCompanions.store(name: name, zone: zone, stamp: nil, db: db)
            try requeueAccount(ofCompanion: name, db: db)
        case .zoneNotFound, .tooLarge, .batchRequestFailed, .failed:
            try requeueAccount(ofCompanion: name, db: db)
        }
    }

    private static func requeueAccount(ofCompanion name: String, db: Database) throws {
        guard let (id, uuid) = try SyncCompanions.account(named: name, db: db) else { return }
        try SyncMerge.queue(uuid: uuid, table: "account", localId: id, kind: .update, db: db)
    }

    /// Finishes the moves this device knows of (`SyncZoneMoves.unfinished`), each judged against where the record is
    /// *now*, not where it was when the move was decided:
    /// - **gone here** (deleted): its old copy and every old file record are deleted in the zone it left;
    /// - **back in the zone it left** (it moved back, or a copy there came in on a pull): no marker goes there, the old
    ///   file records its copy there names again are kept and the others deleted; a copy left in the zone it had gone
    ///   to gets a move of its own (a marker over it, and its file deleted);
    /// - **elsewhere**: a marker (sealed with the old zone's key, checked by the guard) over the old copy, then the old
    ///   file records' deletes.
    /// Each step is cleared only once the server has taken it; a move still unfinished is counted (`counted`, once per
    /// push) and logged for attention after a few pushes. Returns the zones found missing.
    private func finishMoves(limits: SyncOperationLimits, guardian: SyncZoneGuard?, tries: inout [String: Int],
                             counted: Bool) async throws -> Set<String> {
        let zoneSet = zoneList
        let triesNow = tries
        let now = clock()
        struct Plan {
            var move: SyncZoneMoves.Unfinished
            /// Where the record is here now (nil: deleted).
            var current: String?
            var marker: (SyncPayload, Data?)?
            /// File records to delete in the zone it left (and, when gone, the record itself).
            var deletes: [String] = []
            /// Old file records needing no delete (its copy there names them again).
            var kept: [String] = []
        }
        // Back in the zone it left: settled first (in one transaction), so the copy it left elsewhere gets its own move.
        let plans = try await db.write { db -> [Plan] in
            var plans: [Plan] = []
            for move in try SyncZoneMoves.unfinished(db: db) where zoneSet.contains(move.zone)
                && triesNow[Self.markerTryKey(move.uuid, move.zone), default: 0] < Self.triesPerPush {
                let current = try String.fetchOne(db, sql: "SELECT zone FROM syncRecord WHERE uuid = ?", arguments: [move.uuid])
                let reference = try SyncDocumentFile.reference(uuid: move.uuid, db: db)?.recordName
                var plan = Plan(move: move, current: current)
                switch current {
                case nil:
                    let there = try SyncPresence.isIn(uuid: move.uuid, zone: move.zone, db: db)
                    plan.deletes = move.oldFiles + (move.markerPending || there ? [move.uuid] : [])
                case move.zone?:
                    plan.kept = move.oldFiles.filter { $0 == reference }
                    plan.deletes = move.oldFiles.filter { $0 != reference }
                    if move.markerPending { try SyncZoneMoves.acknowledge(uuid: move.uuid, zone: move.zone, stamp: nil, db: db) }
                    let strayThere = try move.toZone.map { try SyncPresence.isIn(uuid: move.uuid, zone: $0, db: db) } ?? false
                    let markedThere = try move.toZone.map { try SyncZoneMoves.knowsMarker(uuid: move.uuid, zone: $0, db: db) } ?? false
                    if let away = move.toZone, away != move.zone, zoneSet.contains(away), strayThere, !markedThere {
                        // The copy it left there: a marker over it (the server's version is taken on the first refusal),
                        // and its file record deleted unless the copy here names it.
                        try SyncZoneMoves.record(uuid: move.uuid, tableName: move.tableName, from: away, to: move.zone, systemFields: nil,
                                                 oldFile: move.toFile == reference ? nil : move.toFile, db: db)
                    }
                    try SyncZoneMoves.forgetDestination(uuid: move.uuid, zone: move.zone, db: db)
                    plan.move.markerPending = false
                case let current?:
                    if move.markerPending {
                        plan.marker = (SyncZoneMoves.marker(uuid: move.uuid, tableName: move.tableName, zone: move.zone, movedTo: current),
                                       try SyncZoneMoves.markerStamp(uuid: move.uuid, zone: move.zone, db: db))
                    }
                    plan.deletes = move.oldFiles
                    if move.toZone != current, move.toZone != nil {
                        // It moved on since: the later move follows that copy.
                        try SyncZoneMoves.forgetDestination(uuid: move.uuid, zone: move.zone, db: db)
                    }
                }
                plans.append(plan)
            }
            return plans
        }
        guard !plans.isEmpty else { return [] }
        for plan in plans { tries[Self.markerTryKey(plan.move.uuid, plan.move.zone), default: 0] += 1 }
        let markers = plans.compactMap(\.marker)
        try await review(markers.map(\.0), guardian: guardian)
        var missing: Set<String> = []
        var results: [ZonedName: SaveResult] = [:]
        for zone in Self.sendingOrder(Set(markers.map(\.0.zone))) {
            let key = try await sealingKey(zone: zone)
            let inZone = markers.filter { $0.0.zone == zone }
            let wires = try inZone.map { try SyncLargePayload.wire(for: $0.0, key: key.key).0 }
            let fields = inZone.reduce(into: [String: Data]()) { result, item in if let stamp = item.1 { result[item.0.recordName] = stamp } }
            for operation in Self.operations(wires, limits: limits) {
                for result in try await save(operation, ifUnchanged: fields) {
                    results[ZonedName(zone: zone, name: result.recordName)] = result
                    if case .zoneNotFound = result.outcome { missing.insert(zone) }
                }
            }
        }
        // The deletes go once no marker is still pending there (the marker covers the old copy first).
        var deletes: [String: [String]] = [:]
        for plan in plans {
            let name = ZonedName(zone: plan.move.zone, name: plan.move.uuid)
            var markerDone = plan.marker == nil
            if case .saved? = results[name]?.outcome { markerDone = true }
            if case .deleted? = results[name]?.outcome { markerDone = true }
            if markerDone, !plan.deletes.isEmpty { deletes[plan.move.zone, default: []] += plan.deletes }
        }
        var deleted: Set<ZonedName> = []
        for (zone, names) in deletes.sorted(by: { $0.key < $1.key }) {
            do {
                try await transport.delete(names, zone: zone)
                for name in names { deleted.insert(ZonedName(zone: zone, name: name)) }
            } catch let error as SyncTransportError where error.isPassing {
                Self.log.error("Sync couldn't finish a move's deletes now; tried again later")
            }
        }
        let taken = results
        let removed = deleted
        try await db.write { db in
            for plan in plans {
                let move = plan.move
                let name = ZonedName(zone: move.zone, name: move.uuid)
                switch taken[name]?.outcome {
                case .saved(let stamp)?:
                    try SyncZoneMoves.acknowledge(uuid: move.uuid, zone: move.zone, stamp: stamp, db: db)
                    try SyncPresence.add(uuid: move.uuid, zone: move.zone, db: db)
                case .changed(let server)?:
                    // Edited there meanwhile (or another marker): the marker goes again over that version.
                    try SyncZoneMoves.markerAgain(uuid: move.uuid, tableName: move.tableName, zone: move.zone,
                                                  systemFields: server.stamp.systemFields, db: db)
                case .deleted?:
                    // The old copy is gone: nothing readable stays there.
                    try SyncZoneMoves.acknowledge(uuid: move.uuid, zone: move.zone, stamp: nil, db: db)
                    try SyncPresence.remove(uuid: move.uuid, zone: move.zone, db: db)
                default:
                    break
                }
                if plan.current == nil, removed.contains(name) {
                    // Deleted here before its marker went: its old copy is deleted instead.
                    try SyncZoneMoves.acknowledge(uuid: move.uuid, zone: move.zone, stamp: nil, db: db)
                    try SyncPresence.remove(uuid: move.uuid, zone: move.zone, db: db)
                }
                let filesGone = move.oldFiles.filter { removed.contains(ZonedName(zone: move.zone, name: $0)) }
                try SyncZoneMoves.filesDone(filesGone + plan.kept, uuid: move.uuid, zone: move.zone, db: db)
                if plan.current == nil, move.oldFiles.allSatisfy({ removed.contains(ZonedName(zone: move.zone, name: $0)) }),
                   !move.markerPending || removed.contains(name) {
                    try SyncZoneMoves.forgetDestination(uuid: move.uuid, zone: move.zone, db: db)
                }
                // Settled where it went: nothing pending, no file left, the record lives where it moved to.
                if let row = try SyncZoneMoves.unfinished(db: db).first(where: { $0.uuid == move.uuid && $0.zone == move.zone }),
                   !row.markerPending, row.oldFiles.isEmpty, row.toZone == plan.current {
                    try SyncZoneMoves.forgetDestination(uuid: move.uuid, zone: move.zone, db: db)
                }
                if counted, try SyncZoneMoves.unfinished(db: db).contains(where: { $0.uuid == move.uuid && $0.zone == move.zone }) {
                    try SyncZoneMoves.tried(uuid: move.uuid, zone: move.zone, tableName: move.tableName, db: db, now: now)
                }
            }
        }
        return missing
    }

    /// Deletes what `SyncCleanup` lists on the server (only in the zones this device syncs); a row goes once the
    /// server has taken its delete.
    private func cleanUp() async throws {
        let zoneSet = Set(zoneList)
        let pending = try await db.read { db in try SyncCleanup.all(db: db) }.filter { zoneSet.contains($0.key) }
        for (zone, names) in pending.sorted(by: { $0.key < $1.key }) {
            do {
                try await transport.delete(names, zone: zone)
            } catch let error as SyncTransportError where error.isPassing {
                continue
            }
            try await db.write { db in try SyncCleanup.done(zone: zone, recordNames: names, db: db) }
        }
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

    /// Deleted records by zone (from their tombstones; household when there is none): before step 6's placement.
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
    func prepare() async throws {
        let now = clock()
        let zones = zoneList
        // Ruling R15 decision 6: a step 3 keyring kept here moves into the key store, once.
        for zone in zones { try SyncZoneKeys.migrateLocalKeyring(zone: zone, db: db, keyStore: keyStore, now: now) }
        // Where this device's records already are on the server, from before `syncPresence` (once).
        if try await db.read({ db in try Data.fetchOne(db, sql: "SELECT value FROM syncState WHERE key = ?", arguments: [Self.presenceKey]) }) == nil {
            try await db.write { db in
                try SyncPresence.backfill(db: db)
                try SyncImportGate.setState(Data([1]), key: Self.presenceKey, db: db, now: now)
            }
        }
        let (on, ready, known) = try await db.read { db in
            (try SyncImportGate.isSyncOn(db: db), try zones.filter { try Self.zoneReady($0, db: db) }, try SyncZoneSet.current(db: db))
        }
        // Read-only: zones are the Mac's to make; none is marked ready here.
        let missing = readOnly ? [] : zones.filter { !ready.contains($0) }
        for zone in missing { try await transport.createZone(zone) }
        guard !on || !missing.isEmpty || known != Set(zones) else { return }
        try await db.write { db in
            try SyncImportGate.setSyncOn(true, db: db, now: now)
            for zone in missing { try SyncImportGate.setState(Data([1]), key: Self.zoneKey(zone), db: db, now: now) }
            // What the apply needs to know of this device's zones (`SyncZoneSet`).
            try SyncZoneSet.store(zones, db: db, now: now)
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
            // The zone's file records and key marker went with it: files are sealed and uploaded again, under the
            // same key, its marker published again (or the one another device published first).
            for uuid in try String.fetchAll(db, sql: "SELECT uuid FROM syncRecord WHERE zone = ?", arguments: [zone]) {
                try db.execute(sql: "DELETE FROM syncState WHERE key IN (?, ?)",
                               arguments: [SyncDocumentFile.referencePrefix + uuid, SyncDocumentFile.failedPrefix + uuid])
            }
            // Its markers and companions went with it.
            try db.execute(sql: "DELETE FROM syncZoneMove WHERE zone = ?", arguments: [zone])
            try db.execute(sql: "DELETE FROM syncPresence WHERE zone = ?", arguments: [zone])
            try db.execute(sql: "DELETE FROM syncZoneCleanup WHERE zone = ?", arguments: [zone])
            try db.execute(sql: "UPDATE syncCompanion SET systemFields = NULL, changeTag = NULL WHERE zone = ?", arguments: [zone])
            if var keys = try SyncZoneKeys.local(zone: zone, db: db) {
                keys.systemFields = nil
                try SyncZoneKeys.store(keys, zone: zone, db: db, now: now)
            }
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
    private func renewLeaseIfDue(_ key: HouseholdKey) async throws {
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
            let renewed = try await ImportLease.renew(ImportLease.Lease(record: held.record, tag: held.tag), now: now, transport: try leaseStore(key))
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
    private func releaseLeaseIfDone(_ key: HouseholdKey) async throws {
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
            try await ImportLease.release(ImportLease.Lease(record: done.record, tag: done.tag), transport: try leaseStore(key))
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
    /// Set once `syncPresence` has been filled from what this device had already saved or pulled.
    static let presenceKey = "presenceBackfilled"
    /// Set at open when records wait in staging (an older build left them): the next pull retries them all,
    /// through the filed-year check.
    static let retryStagedKey = "retryStaged"

    /// Asks the next pull to retry every staged record (at open; nothing is applied there).
    public static func requestStagedRetry(db: Database, now: Date = Date()) throws {
        try SyncImportGate.setState(Data([1]), key: retryStagedKey, db: db, now: now)
    }

    public static func retryStagedRequested(db: Database) throws -> Bool {
        try Data.fetchOne(db, sql: "SELECT value FROM syncState WHERE key = ?", arguments: [retryStagedKey]) != nil
    }
    static func zoneKey(_ zone: String) -> String { "zoneReady." + zone }

    static func zoneReady(_ zone: String, db: Database) throws -> Bool {
        try Data.fetchOne(db, sql: "SELECT value FROM syncState WHERE key = ?", arguments: [zoneKey(zone)]) != nil
    }

    /// Whether this database has pulled the household zone at least once (it holds a change token). The phone's
    /// first download is the time before it does.
    public static func hasChangeToken(db: Database) throws -> Bool {
        try token(zone: SyncRecordStore.householdZone, db: db) != nil
    }

    static func token(zone: String, db: Database) throws -> Data? {
        try Data.fetchOne(db, sql: "SELECT value FROM syncState WHERE key = ?", arguments: [tokenKey(zone)])
    }

    static func setToken(_ token: Data, zone: String, db: Database, now: Date) throws {
        try SyncImportGate.setState(token, key: tokenKey(zone), db: db, now: now)
    }

    /// The change tag this device holds of each fetched record: a companion's own, any other record's.
    static func heldTags(_ records: [SyncServerRecord], db: Database) throws -> [String: String] {
        var result = try changeTags(records.filter { $0.wire.recordType != SyncZoneRouter.companionRecordType }.map(\.wire.recordName), db: db)
        for record in records where record.wire.recordType == SyncZoneRouter.companionRecordType {
            if let tag = try SyncCompanions.stamp(name: record.wire.recordName, db: db)?.changeTag { result[record.wire.recordName] = tag }
        }
        return result
    }

    static func changeTags(_ uuids: [String], db: Database) throws -> [String: String] {
        var result: [String: String] = [:]
        let statement = try db.cachedStatement(sql: "SELECT changeTag FROM syncRecord WHERE uuid = ?")
        for uuid in uuids {
            if let tag = try String.fetchOne(statement, arguments: [uuid]) { result[uuid] = tag }
        }
        return result
    }

    /// The server version a save names: the record's, or for a redirect (its row merged into another here) the
    /// one its tombstone kept.
    static func systemFields(uuid: String, db: Database) throws -> Data? {
        if try Bool.fetchOne(db.cachedStatement(sql: "SELECT EXISTS (SELECT 1 FROM syncRecord WHERE uuid = ?)"), arguments: [uuid]) ?? false {
            return try Data.fetchOne(db.cachedStatement(sql: "SELECT systemFields FROM syncRecord WHERE uuid = ?"), arguments: [uuid])
        }
        return try Data.fetchOne(db.cachedStatement(sql: "SELECT systemFields FROM syncTombstone WHERE uuid = ? AND mergedInto IS NOT NULL"),
                                 arguments: [uuid])
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

/// A record as it goes to the server (ruling R15): its fields sealed under the zone key (`FieldSealing`). Ruling
/// R4: a payload whose sealed record would exceed `SyncEngineCore.largePayloadThreshold` travels in an asset field
/// of its own record (`payload`), sealed under the zone key like the fields; the sealed fields then hold only a
/// stub naming the asset.
enum SyncLargePayload {
    static let assetField = "payload"

    /// The record to save for `payload`, sealed under `key`, and whether it was packed.
    static func wire(for payload: SyncPayload, key: SymmetricKey, threshold: Int = SyncEngineCore.largePayloadThreshold) throws -> (SyncWireRecord, Bool) {
        let plain = try FieldSealing.seal(try SyncWireRecord(payload), key: key)
        guard plain.size > threshold else { return (plain, false) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var stub = SyncPayload(recordType: payload.recordType, recordName: payload.recordName, zone: payload.zone, fields: [:])
        stub.largePayload = SyncLargePayloadReference(assetField: assetField)
        var inner = try SyncWireRecord(stub)
        inner.assets[assetField] = try encoder.encode(payload)
        return (try FieldSealing.seal(inner, key: key), true)
    }

    /// The payload a sealed record holds, opening its asset when it is a large one. Throws
    /// `FieldSealing.SealingError.keyMissing` when it was sealed under a key not in `keys`.
    static func payload(from wire: SyncWireRecord, keys: [String: SymmetricKey]) throws -> SyncPayload {
        let inner = try FieldSealing.open(wire, keys: keys)
        let stub = try inner.payload()
        guard let reference = stub.largePayload else { return stub }
        guard let plaintext = inner.assets[reference.assetField] else { throw SyncTransportError.unreadableRecord(wire.recordName) }
        var payload = try JSONDecoder().decode(SyncPayload.self, from: plaintext)
        guard payload.recordName == wire.recordName, payload.recordType == wire.recordType, payload.largePayload == nil else {
            throw SyncTransportError.unreadableRecord(wire.recordName)
        }
        payload.zone = wire.zone
        return payload
    }
}
