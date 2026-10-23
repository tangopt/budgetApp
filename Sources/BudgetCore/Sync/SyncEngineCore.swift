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
    /// Saves refused for good this time (too large; or still conflicting after every try); they stay pending.
    public var refused = 0
    /// Records that went as an encrypted asset (ruling R4).
    public var asAssets = 0

    public init() {}
}

public struct SyncPullReport: Equatable, Sendable {
    /// Records and deletions received (each record once, at its latest version).
    public var received = 0
    /// Received records this device already held at that version (its own uploads coming back).
    public var alreadyHeld = 0
    /// Received records waiting in staging after the apply.
    public var staged = 0

    public init() {}
}

public struct SyncReport: Equatable, Sendable {
    public var pull: SyncPullReport
    public var push: SyncPushReport
}

/// The sync engine's core (plan Task 5), written against `SyncTransport`, so it runs the same over the
/// in-memory `FakeCloud` and over CloudKit. It composes Tasks 2–4:
/// - **Push** sends `SyncChangeTracker.pending` in its order (an import's run first): saves first, with
///   each record's change tag (`.ifServerRecordUnchanged`), then deletes, holding back a batch's deletes
///   until its run's record is on the server. A save the server refuses because it holds a newer version
///   is merged with that version (`SyncTranslator.apply`) and sent again. Taken records are acknowledged
///   (revision-safe), then `SyncBatch.closeUploaded` closes finished batches; the import lease is released
///   once a batch's close is uploaded. A record too large for the server goes as an encrypted asset (R4).
/// - **Pull** fetches every page of the zone's changes since the stored token, then applies the whole pull
///   in one transaction (`SyncTranslator.apply`: parents first, children-first deletes, staging, batches),
///   stores the change tags of what applied and the new token in the same transaction, and, having caught
///   up, applies closed batches that can't complete any more (`SyncBatch.flushClosed`).
/// - **Import lease** (sync spec §5.2): `acquireImportLease` before Confirm and Undo; with sync on,
///   BudgetCore refuses both without it (`SyncImportGate`).
///
/// Change tags are kept in `syncRecord.systemFields` (the transport's tag string, UTF-8); the change token
/// per zone is in `syncState`.
public actor SyncEngineCore {
    /// The zones synced in build step 3.
    public static let zones = [SyncRecordStore.householdZone]
    /// Records in the zone that are the engine's own, never data (the import lease).
    static let reservedRecordTypes: Set<String> = [TransportLeaseStore.recordType]
    /// A payload whose record would be larger than this goes as an encrypted asset (ruling R4).
    public static let largePayloadThreshold = 900_000
    /// How many times one push tries one record before leaving it for the next sync.
    static let triesPerPush = 4
    /// The lease is renewed once it is this old.
    static let leaseRenewalAge: TimeInterval = 10 * 60

    private static let log = Logger(subsystem: "com.personal.budget", category: "Sync")

    private let db: any DatabaseWriter
    private let transport: any SyncTransport
    public nonisolated let device: SyncDevice
    private let batchSize: Int
    private let clock: @Sendable () -> Date
    private let leaseStore: TransportLeaseStore

    public init(db: any DatabaseWriter, transport: any SyncTransport, device: SyncDevice, batchSize: Int = 200,
                clock: @escaping @Sendable () -> Date = { Date() }) {
        self.db = db
        self.transport = transport
        self.device = device
        self.batchSize = max(1, batchSize)
        self.clock = clock
        leaseStore = TransportLeaseStore(transport: transport)
    }

    // MARK: Sync

    /// Pull, then push.
    @discardableResult
    public func syncNow() async throws -> SyncReport {
        let pulled = try await pull()
        let pushed = try await pushPending()
        return SyncReport(pull: pulled, push: pushed)
    }

    // MARK: Pull

    @discardableResult
    public func pull() async throws -> SyncPullReport {
        try await markSyncOn()
        var report = SyncPullReport()
        for zone in Self.zones {
            let zoneReport = try await pull(zone: zone)
            report.received += zoneReport.received
            report.alreadyHeld += zoneReport.alreadyHeld
            report.staged += zoneReport.staged
        }
        return report
    }

    private func pull(zone: String) async throws -> SyncPullReport {
        var token = try await db.read { db in try Self.token(zone: zone, db: db) }
        var order: [String] = []
        var changes: [String: SyncIncomingChange] = [:]
        var tags: [String: String] = [:]
        while true {
            let page = try await transport.changes(since: token, zone: zone)
            for record in page.records where !Self.reservedRecordTypes.contains(record.payload.recordType) {
                let payload = try await reassemble(record.payload)
                if changes[payload.recordName] == nil { order.append(payload.recordName) }
                // A record seen again on a later page changed since: the later version is the newer one.
                changes[payload.recordName] = .save(payload)
                tags[payload.recordName] = record.changeTag
            }
            for deletion in page.deletions where !Self.reservedRecordTypes.contains(deletion.recordType ?? "") {
                if changes[deletion.recordName] == nil { order.append(deletion.recordName) }
                changes[deletion.recordName] = .delete(recordName: deletion.recordName, recordType: deletion.recordType)
                tags[deletion.recordName] = nil
            }
            token = page.token
            if !page.moreComing { break }
        }
        let finalToken = token
        let received = order.compactMap { changes[$0] }
        let receivedTags = tags
        let now = clock()
        return try await db.write { db in
            var report = SyncPullReport()
            report.received = received.count
            let user = try Self.deviceUser(db: db)
            // A record already held at the server's version (this device's own upload coming back) is skipped.
            var incoming: [SyncIncomingChange] = []
            for change in received {
                if case .save(let payload) = change, let tag = receivedTags[payload.recordName],
                   try Self.storedTag(uuid: payload.recordName, db: db) == tag {
                    report.alreadyHeld += 1
                    continue
                }
                incoming.append(change)
            }
            let results = incoming.isEmpty ? [:] : try SyncTranslator.apply(incoming, db: db, deviceUser: user, now: now)
            for (name, result) in results {
                if case .staged = result {
                    report.staged += 1
                } else if let tag = receivedTags[name] {
                    // Only a record whose version is now merged here takes the server's tag: one still staged
                    // must not, or a later save would overwrite a version this device never merged.
                    try Self.storeTag(tag, uuid: name, db: db)
                }
            }
            if let finalToken { try Self.setToken(finalToken, zone: zone, db: db) }
            // Caught up: a closed batch that can't complete any more applies now.
            _ = try SyncBatch.flushClosed(db: db, deviceUser: user, now: now)
            return report
        }
    }

    // MARK: Push

    @discardableResult
    public func pushPending() async throws -> SyncPushReport {
        try await markSyncOn()
        try await renewLeaseIfDue()
        var report = SyncPushReport()
        var tries: [String: Int] = [:]
        var pulled = false
        while true {
            var needsPull = false
            let triesNow = tries
            // Saves, oldest first (an import's run before its members).
            let saves = try await db.read { db in
                try SyncChangeTracker.pending(db: db).filter { $0.kind != .delete && triesNow[$0.uuid, default: 0] < Self.triesPerPush }
            }
            for start in stride(from: 0, to: saves.count, by: batchSize) {
                let chunk = Array(saves[start..<min(start + batchSize, saves.count)])
                for change in chunk { tries[change.uuid, default: 0] += 1 }
                // A long upload keeps the lease alive (it expires 30 minutes after it was last renewed).
                try await renewLeaseIfDue()
                if try await pushSaves(chunk, report: &report) { needsPull = true }
            }
            // Deletes, after the saves, except a batch's while its run's record isn't on the server yet.
            let triesAfterSaves = tries
            let deletes = try await db.read { db in
                try Self.sendableDeletes(db: db).filter { triesAfterSaves[$0.uuid, default: 0] < Self.triesPerPush }
            }
            for start in stride(from: 0, to: deletes.count, by: batchSize) {
                let chunk = Array(deletes[start..<min(start + batchSize, deletes.count)])
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
            if needsPull, !pulled {
                // A save named a record the server no longer has: the pull brings its deletion (a delete wins
                // over an edit made offline) before anything is sent again.
                pulled = true
                try await pull()
                continue
            }
            let triesLeft = tries
            let more = try await db.read { db in
                try SyncChangeTracker.pending(db: db).contains { $0.kind != .delete && triesLeft[$0.uuid, default: 0] < Self.triesPerPush }
                    || Self.sendableDeletes(db: db).contains { triesLeft[$0.uuid, default: 0] < Self.triesPerPush }
            }
            if !more { break }
        }
        try await releaseLeaseIfDone()
        return report
    }

    /// Sends one chunk of saves and takes in the results. True when a save named a record the server no
    /// longer has (a pull should come first).
    private func pushSaves(_ chunk: [PendingChange], report: inout SyncPushReport) async throws -> Bool {
        let built = try await db.write { db -> [(PendingChange, SyncPayload?, String?)] in
            try chunk.map { change in
                let payload = try SyncTranslator.outgoing(change, db: db)
                return (change, payload, try payload.flatMap { try Self.storedTag(uuid: $0.recordName, db: db) })
            }
        }
        var payloads: [SyncPayload] = []
        var tags: [String: String] = [:]
        var sent: [String: PendingChange] = [:]
        var nothingToSend: [PendingChange] = []
        for (change, payload, tag) in built {
            guard var payload else {
                nothingToSend.append(change)
                continue
            }
            if let packed = try SyncLargePayload.pack(payload) {
                try await transport.saveAsset(packed.ciphertext, for: packed.stub.largePayload!.assetName)
                payload = packed.stub
                report.asAssets += 1
            }
            payloads.append(payload)
            sent[payload.recordName] = change
            if let tag { tags[payload.recordName] = tag }
        }
        let results = payloads.isEmpty ? [] : try await transport.save(payloads, ifUnchanged: tags)
        var servers: [String: SyncServerRecord] = [:]
        for result in results {
            if case .changed(var server) = result.outcome {
                server.payload = try await reassemble(server.payload)
                servers[result.recordName] = server
            }
        }
        let now = clock()
        let sentChanges = sent
        let unsent = nothingToSend
        let serverRecords = servers
        let outcome = try await db.write { db -> (SyncPushReport, Bool) in
            var delta = SyncPushReport()
            var needsPull = false
            var acknowledged = unsent
            let user = try Self.deviceUser(db: db)
            for result in results {
                guard let change = sentChanges[result.recordName] else { continue }
                switch result.outcome {
                case .saved(let tag, _):
                    acknowledged.append(change)
                    try Self.storeTag(tag, uuid: result.recordName, db: db)
                    delta.saved += 1
                case .changed:
                    guard let server = serverRecords[result.recordName] else { continue }
                    // Merged field by field with the server's version; the merged record goes again next round
                    // with the server's tag (unless the server's version had to wait in staging here).
                    let merged = try SyncTranslator.apply([.save(server.payload)], db: db, deviceUser: user, now: now)
                    if case .staged = merged[result.recordName] {} else {
                        try Self.storeTag(server.changeTag, uuid: result.recordName, db: db)
                    }
                    delta.merged += 1
                case .deleted:
                    try Self.storeTag(nil, uuid: result.recordName, db: db)
                    needsPull = true
                case .tooLarge(let bytes):
                    Self.log.error("Sync save of a \(change.table, privacy: .public) record refused: \(bytes) bytes")
                    delta.refused += 1
                case .failed(let reason):
                    Self.log.error("Sync save of a \(change.table, privacy: .public) record failed (\(reason, privacy: .public)); sent again later")
                    delta.refused += 1
                }
            }
            try SyncChangeTracker.acknowledge(acknowledged, db: db)
            _ = try SyncBatch.closeUploaded(db: db)
            return (delta, needsPull)
        }
        report.saved += outcome.0.saved
        report.merged += outcome.0.merged
        report.refused += outcome.0.refused
        return outcome.1
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

    // MARK: Import lease

    /// Takes the household's import lease for this device: call before Confirm and before Undo. Throws
    /// `ImportLeaseError.heldBy` ("Importing on <device>") while another device holds it.
    public func acquireImportLease() async throws {
        try await markSyncOn()
        let lease = try await ImportLease.acquire(device: device, now: clock(), transport: leaseStore)
        try await db.write { db in try SyncImportGate.setHeldLease(HeldImportLease(record: lease.record, tag: lease.tag), db: db) }
    }

    /// Gives the lease up without importing (the user cancelled). A batch's lease is released by the push
    /// that uploads the batch's close.
    public func releaseImportLease() async throws {
        guard let held = try await db.read({ db in try SyncImportGate.heldLease(db: db) }) else { return }
        try await ImportLease.release(ImportLease.Lease(record: held.record, tag: held.tag), transport: leaseStore)
        try await db.write { db in try SyncImportGate.setHeldLease(nil, db: db) }
    }

    /// Who holds the lease now ("Importing on <device>"), or nil.
    public func importLeaseHolder() async throws -> ImportLeaseRecord? {
        try await ImportLease.holder(now: clock(), transport: leaseStore)
    }

    private func renewLeaseIfDue() async throws {
        guard let held = try await db.read({ db in try SyncImportGate.heldLease(db: db) }) else { return }
        let now = clock()
        guard now.timeIntervalSince(held.record.expiresAt.addingTimeInterval(-ImportLease.duration)) >= Self.leaseRenewalAge else { return }
        do {
            let renewed = try await ImportLease.renew(ImportLease.Lease(record: held.record, tag: held.tag), now: now, transport: leaseStore)
            let updated = HeldImportLease(record: renewed.record, tag: renewed.tag, used: held.used)
            try await db.write { db in try SyncImportGate.setHeldLease(updated, db: db) }
        } catch ImportLeaseError.lost {
            // Another device took over: this device's batch still uploads (it is tagged with its own run).
            Self.log.error("Sync import lease lost to another device")
            try await db.write { db in try SyncImportGate.setHeldLease(nil, db: db) }
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
        try await ImportLease.release(ImportLease.Lease(record: done.record, tag: done.tag), transport: leaseStore)
        try await db.write { db in try SyncImportGate.setHeldLease(nil, db: db) }
    }

    // MARK: Large payloads (R4)

    private func reassemble(_ payload: SyncPayload) async throws -> SyncPayload {
        guard let reference = payload.largePayload else { return payload }
        let ciphertext = try await transport.asset(for: reference.assetName)
        let opened = try SyncLargePayload.open(ciphertext, reference: reference)
        guard opened.recordName == payload.recordName else { throw SyncTransportError.unreadableRecord(payload.recordName) }
        return opened
    }

    // MARK: State

    private func markSyncOn() async throws {
        try await db.write { db in try SyncImportGate.setSyncOn(true, db: db) }
    }

    static func tokenKey(_ zone: String) -> String { "changeToken." + zone }

    static func token(zone: String, db: Database) throws -> Data? {
        try Data.fetchOne(db, sql: "SELECT value FROM syncState WHERE key = ?", arguments: [tokenKey(zone)])
    }

    static func setToken(_ token: Data, zone: String, db: Database) throws {
        try SyncImportGate.setState(token, key: tokenKey(zone), db: db)
    }

    static func storedTag(uuid: String, db: Database) throws -> String? {
        try Data.fetchOne(db.cachedStatement(sql: "SELECT systemFields FROM syncRecord WHERE uuid = ?"), arguments: [uuid])
            .map { String(decoding: $0, as: UTF8.self) }
    }

    static func storeTag(_ tag: String?, uuid: String, db: Database) throws {
        try db.cachedStatement(sql: "UPDATE syncRecord SET systemFields = ? WHERE uuid = ?").execute(arguments: [tag.map { Data($0.utf8) }, uuid])
    }

    static func deviceUser(db: Database) throws -> String? {
        try String.fetchOne(db, sql: "SELECT appUserUuid FROM syncWriter WHERE id = 1")
    }
}

// MARK: Large payloads

/// Ruling R4: a payload whose record would exceed `SyncEngineCore.largePayloadThreshold` travels as an
/// asset, sealed with AES-GCM under a random key; the record that names it carries the key in its
/// encrypted fields and nothing else.
enum SyncLargePayload {
    static func pack(_ payload: SyncPayload, threshold: Int = SyncEngineCore.largePayloadThreshold) throws -> (stub: SyncPayload, ciphertext: Data)? {
        guard try SyncWireRecord(payload).size > threshold else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let key = SymmetricKey(size: .bits256)
        guard let sealed = try AES.GCM.seal(try encoder.encode(payload), using: key).combined else {
            throw SyncTransportError.unreadableRecord(payload.recordName)
        }
        // A new asset per version, so a receiver never reads a newer version's asset with an older key.
        var stub = SyncPayload(recordType: payload.recordType, recordName: payload.recordName, zone: payload.zone, fields: [:])
        stub.largePayload = SyncLargePayloadReference(assetName: payload.recordName + ".payload." + UUID().uuidString.lowercased(),
                                                      key: key.withUnsafeBytes { Data($0) })
        return (stub, sealed)
    }

    static func open(_ ciphertext: Data, reference: SyncLargePayloadReference) throws -> SyncPayload {
        let box = try AES.GCM.SealedBox(combined: ciphertext)
        let plaintext = try AES.GCM.open(box, using: SymmetricKey(data: reference.key))
        return try JSONDecoder().decode(SyncPayload.self, from: plaintext)
    }
}

// MARK: The lease over the transport

/// `LeaseStore` over `SyncTransport` (sync spec §5.2): the lease is one `importLease` record in the zone,
/// written only with `.ifServerRecordUnchanged`. Releasing saves it empty (CloudKit deletes aren't
/// compare-and-set). The server's modification time and clock decide expiry where the transport knows them.
public struct TransportLeaseStore: LeaseStore {
    public static let recordType = "importLease"
    public static let recordName = "importLease"

    private let transport: any SyncTransport
    private let zone: String

    public init(transport: any SyncTransport, zone: String = SyncRecordStore.householdZone) {
        self.transport = transport
        self.zone = zone
    }

    public func currentLease() async throws -> StoredLease? {
        guard let server = try await transport.fetch(Self.recordName, zone: zone) else { return nil }
        let fields = server.payload.fields
        func string(_ key: String) -> String { if case .string(let value) = fields[key] { return value } else { return "" } }
        func date(_ key: String) -> Date { if case .date(let value) = fields[key] { return value } else { return .distantPast } }
        let record = ImportLeaseRecord(holderId: string("holderId"), holderName: string("holderName"),
                                       takenAt: date("takenAt"), expiresAt: date("expiresAt"))
        return StoredLease(record: record, tag: server.changeTag, serverModifiedAt: server.modifiedAt)
    }

    public func saveLease(_ record: ImportLeaseRecord, ifTag tag: String?) async throws -> StoredLease {
        let payload = SyncPayload(recordType: Self.recordType, recordName: Self.recordName, zone: zone, fields: [
            "holderId": .string(record.holderId), "holderName": .string(record.holderName),
            "takenAt": .date(record.takenAt), "expiresAt": .date(record.expiresAt),
        ])
        let results = try await transport.save([payload], ifUnchanged: tag.map { [Self.recordName: $0] } ?? [:])
        guard case .saved(let newTag, let at) = results.first?.outcome else { throw LeaseStoreError.changed }
        return StoredLease(record: record, tag: newTag, serverModifiedAt: at)
    }

    public func deleteLease(ifTag tag: String) async throws {
        _ = try await saveLease(ImportLeaseRecord(holderId: "", holderName: "", takenAt: .distantPast, expiresAt: .distantPast), ifTag: tag)
    }

    public func serverTime() async throws -> Date? { try await transport.serverTime() }
}

// MARK: The gate on Confirm and Undo

public enum SyncImportGateError: Error, Equatable, Sendable {
    /// Sync is on and this device doesn't hold the import lease.
    case leaseRequired

    public var message: String { "Confirming needs a moment online to take the import lease: try again when connected" }
}

/// The lease this device holds, as BudgetCore checks it at Confirm and Undo. `used`: a batch was confirmed
/// under it, so it is released once that batch's close is uploaded.
public struct HeldImportLease: Codable, Equatable, Sendable {
    public var record: ImportLeaseRecord
    public var tag: String
    public var used: Bool

    public init(record: ImportLeaseRecord, tag: String, used: Bool = false) {
        self.record = record
        self.tag = tag
        self.used = used
    }
}

/// One import (or Undo) confirmed at a time per household (sync spec §5.2), enforced in BudgetCore: once
/// this device takes part in sync, `ImportApplier` and `ImportUndo` refuse without a lease it holds.
public enum SyncImportGate {
    static let syncOnKey = "syncOn"
    static let leaseKey = "importLease"

    public static func isSyncOn(db: Database) throws -> Bool {
        guard try db.tableExists("syncState") else { return false }
        return try Data.fetchOne(db, sql: "SELECT value FROM syncState WHERE key = ?", arguments: [syncOnKey]) == Data([1])
    }

    public static func setSyncOn(_ on: Bool, db: Database) throws {
        guard try isSyncOn(db: db) != on else { return }
        try setState(Data([on ? 1 : 0]), key: syncOnKey, db: db)
    }

    public static func heldLease(db: Database) throws -> HeldImportLease? {
        guard try db.tableExists("syncState"),
              let data = try Data.fetchOne(db, sql: "SELECT value FROM syncState WHERE key = ?", arguments: [leaseKey]) else { return nil }
        return try? JSONDecoder().decode(HeldImportLease.self, from: data)
    }

    static func setHeldLease(_ lease: HeldImportLease?, db: Database) throws {
        if let lease {
            try setState(try JSONEncoder().encode(lease), key: leaseKey, db: db)
        } else {
            try db.execute(sql: "DELETE FROM syncState WHERE key = ?", arguments: [leaseKey])
        }
    }

    /// Throws `leaseRequired` when sync is on and this device holds no unexpired lease.
    public static func check(db: Database, now: Date = Date()) throws {
        guard try isSyncOn(db: db) else { return }
        guard let held = try heldLease(db: db), held.record.expiresAt > now else { throw SyncImportGateError.leaseRequired }
    }

    /// `check`, inside the transaction that confirms (or undoes): the lease is then marked used.
    public static func require(db: Database, now: Date = Date()) throws {
        try check(db: db, now: now)
        guard var held = try heldLease(db: db), !held.used else { return }
        held.used = true
        try setHeldLease(held, db: db)
    }

    static func setState(_ value: Data, key: String, db: Database) throws {
        try db.execute(sql: """
            INSERT INTO syncState(key, value, updatedAt) VALUES (?, ?, ?)
            ON CONFLICT(key) DO UPDATE SET value = excluded.value, updatedAt = excluded.updatedAt
            """, arguments: [key, value, Date()])
    }
}
