import CryptoKit
import Foundation
import GRDB
import os

/// Step 15: a new household key when someone is removed, and the re-seal sweep (sync spec §9.1 "Rotation", §9 "Rotation
/// re-wraps, it doesn't re-seal"). Local only (`syncState`): what the sweep has done so far, whether a removal's rotation
/// is still to finish, and every key id a removed person held (never handed out again, `SyncKeyExchange.Granter.grant`).
public enum SyncKeyRotation {
    /// How far the sweep has got: records re-sealed under the current key, of all it has found so far.
    public struct Progress: Codable, Equatable, Sendable {
        public var done: Int
        public var total: Int

        public init(done: Int, total: Int) {
            self.done = done
            self.total = total
        }
    }

    struct State: Codable, Equatable {
        /// Key ids a removed person held: never granted again.
        var revoked: [String] = []
        /// A removal's rotation or sweep hasn't finished (resumed after a quit, a crash or going offline).
        var pending = false
        /// The sweep's progress (kept while pending, so a resume continues the count).
        var progress = Progress(done: 0, total: 0)
    }

    static func stateKey(_ zone: String) -> String { "keyRotation." + zone }

    static func state(zone: String = SyncZones.household, db: Database) throws -> State {
        try Data.fetchOne(db, sql: "SELECT value FROM syncState WHERE key = ?", arguments: [stateKey(zone)])
            .flatMap { try? JSONDecoder().decode(State.self, from: $0) } ?? State()
    }

    static func store(_ state: State, zone: String = SyncZones.household, db: Database, now: Date) throws {
        try SyncImportGate.setState(try JSONEncoder().encode(state), key: stateKey(zone), db: db, now: now)
    }

    /// Whether a removal's new key or its re-seal sweep is still to finish.
    public static func isPending(db: Database) throws -> Bool { try state(db: db).pending }

    /// The sweep's progress while a removal's is pending; nil otherwise.
    public static func progress(db: Database) throws -> Progress? {
        let state = try state(db: db)
        return state.pending ? state.progress : nil
    }

    /// Every household key id a removed person held.
    public static func revokedKeyIds(db: Database) throws -> Set<String> { Set(try state(db: db).revoked) }
}

/// What a re-seal sweep did.
public struct SyncResealReport: Equatable, Sendable {
    /// Records re-sealed under the current key (in this run).
    public var resealed: Int
    /// Records still sealed under another key that the sweep could convert (a later run takes them).
    public var remaining: Int
    /// Records under a key this device doesn't hold, or a lease in use: left as they are.
    public var skipped: Int
    /// Since the removal's sweep began (all runs).
    public var progress: SyncKeyRotation.Progress
}

extension SyncEngineCore {
    private static let rotationLog = Logger(subsystem: "com.personal.budget", category: "SyncKeys")
    /// Passes over the zone in one sweep: a record changed by someone else while it ran is read again on the next.
    static let resealPasses = 3

    /// The re-seal sweep (Mac only): every record of the household that the server holds sealed under a key other than
    /// the current one is opened, sealed again under the current key and saved over the version read, so a retired
    /// key opens nothing that changes from now on. A document record's wrapped data key is re-wrapped too (its file
    /// isn't uploaded again). Never the zone key marker, a document file (sealed under its own data key), the key
    /// exchange's records, or a lease in use. Resumable: progress is kept after each operation; a passing transport
    /// error stops it with what is done kept.
    @discardableResult
    public func resealSweep(progress: @escaping @Sendable (SyncKeyRotation.Progress) -> Void = { _ in }) async throws -> SyncResealReport {
        guard mode.ownsZones else { throw ReadOnlyError.readOnly }
        return try await serialized { try await self.resealSweepNow(progress: progress) }
    }

    func resealSweepNow(progress: @escaping @Sendable (SyncKeyRotation.Progress) -> Void) async throws -> SyncResealReport {
        let zone = SyncZones.household
        try await prepare()
        // The marker as the server holds it: never sealed under a key that isn't the zone's.
        let current = try await refreshHouseholdKey(zone: zone, create: false)
        let keys = try keyStore.allKeys(zone: zone)
        var state = try await db.read { db in try SyncKeyRotation.state(db: db) }
        var report = SyncResealReport(resealed: 0, remaining: 0, skipped: 0, progress: state.progress)
        for _ in 0..<Self.resealPasses {
            let stale = try await staleRecords(zone: zone, current: current.id)
            var outgoing: [(server: SyncServerRecord, wire: SyncWireRecord, reference: SyncDocumentFileReference?)] = []
            var skipped = 0
            let now = clock()
            for record in stale {
                do {
                    guard let resealed = try Self.resealed(record, current: current, keys: keys, now: now) else {
                        skipped += 1
                        continue
                    }
                    outgoing.append((record, resealed.wire, resealed.reference))
                } catch {
                    Self.rotationLog.error("Re-seal: \(record.wire.recordType, privacy: .public) \(record.wire.recordName, privacy: .public) can't be opened here; left")
                    skipped += 1
                }
            }
            report.skipped = skipped
            report.remaining = outgoing.count
            state.progress.total = state.progress.done + outgoing.count
            try await persist(state)
            progress(state.progress)
            guard !outgoing.isEmpty else { break }
            let byName = Dictionary(outgoing.map { ($0.wire.recordName, $0) }, uniquingKeysWith: { first, _ in first })
            let limits = await transport.operationLimits()
            for operation in Self.operations(outgoing.map(\.wire), limits: limits) {
                let stamps = operation.reduce(into: [String: Data]()) { $0[$1.recordName] = byName[$1.recordName]?.server.stamp.systemFields }
                let results = try await save(operation, ifUnchanged: stamps)
                let now = clock()
                let converted = try await db.write { db -> Int in
                    var converted = 0
                    for result in results {
                        guard let sent = byName[result.recordName] else { continue }
                        switch result.outcome {
                        case .saved(let stamp):
                            try Self.keepResealed(sent.server, stamp: stamp, reference: sent.reference, db: db, now: now)
                            converted += 1
                        case .changed(let server) where FieldSealing.keyId(of: server.wire) == current.id:
                            // Changed meanwhile, and sealed under the current key already.
                            converted += 1
                        case .deleted:
                            converted += 1
                        default:
                            // Changed under another key, or not saved this time: the next pass reads it again.
                            continue
                        }
                    }
                    return converted
                }
                report.resealed += converted
                report.remaining -= converted
                state.progress.done += converted
                try await persist(state)
                progress(state.progress)
            }
            if report.remaining == 0 { break }
        }
        report.progress = state.progress
        Self.rotationLog.notice("Re-seal: \(report.resealed, privacy: .public) re-sealed, \(report.remaining, privacy: .public) left, \(report.skipped, privacy: .public) skipped")
        return report
    }

    // MARK: A removal's revocation (step 15)

    /// Before a member is taken off the household's share (Mac only): every household key held now is one she may hold,
    /// so each is revoked (never granted again) and a rotation is pending until `finishKeyRevocation` completes it.
    public func beginKeyRevocation() async throws {
        guard mode.ownsZones else { throw ReadOnlyError.readOnly }
        try await serialized {
            let held = Set(try self.keyStore.allKeys(zone: SyncZones.household).keys)
            let now = self.clock()
            try await self.db.write { db in
                var state = try SyncKeyRotation.state(db: db)
                state.revoked = Array(Set(state.revoked).union(held)).sorted()
                if !state.pending { state.progress = SyncKeyRotation.Progress(done: 0, total: 0) }
                state.pending = true
                try SyncKeyRotation.store(state, db: db, now: now)
            }
            Self.rotationLog.notice("Key revocation begun: \(held.count, privacy: .public) key(s) revoked")
        }
    }

    /// A pending revocation finished: a new household key unless the current one is already newer than every revoked
    /// one (a resume after the rotation), then the re-seal sweep. The revocation stays pending until the sweep leaves
    /// nothing to convert; a passing transport error stops it with what is done kept (`resumeIfPending` goes on later).
    /// Nil when nothing is pending.
    @discardableResult
    public func finishKeyRevocation(progress: @escaping @Sendable (SyncKeyRotation.Progress) -> Void = { _ in }) async throws -> SyncResealReport? {
        guard mode.ownsZones else { throw ReadOnlyError.readOnly }
        return try await serialized { () -> SyncResealReport? in
            let zone = SyncZones.household
            let revoked = try await self.db.read { db -> Set<String>? in
                let state = try SyncKeyRotation.state(db: db)
                return state.pending ? Set(state.revoked) : nil
            }
            guard let revoked else { return nil }
            try await self.prepare()
            let current = try await self.refreshHouseholdKey(zone: zone, create: false)
            if revoked.contains(current.id) {
                let rotation = try await self.rotateZoneKeyNow()
                Self.rotationLog.notice("Key revocation: new household key, \(rotation.rewrapped, privacy: .public) data key(s) re-wrapped")
            }
            let report = try await self.resealSweepNow(progress: progress)
            if report.remaining == 0 {
                let now = self.clock()
                try await self.db.write { db in
                    var state = try SyncKeyRotation.state(db: db)
                    state.pending = false
                    try SyncKeyRotation.store(state, db: db, now: now)
                }
                Self.rotationLog.notice("Key revocation finished")
            }
            return report
        }
    }

    private func persist(_ state: SyncKeyRotation.State) async throws {
        let now = clock()
        try await db.write { db in try SyncKeyRotation.store(state, db: db, now: now) }
    }

    /// Every record of `zone` on the server sealed under a key other than `current` (read from the start, without the
    /// documents' contents), but the engine's own that the sweep leaves.
    private func staleRecords(zone: String, current: String) async throws -> [SyncServerRecord] {
        let leftAlone = Set([SyncZoneKeys.recordType, SyncDocumentFile.recordType]).union(SyncKeyExchange.recordTypes)
        var stale: [SyncServerRecord] = []
        var token: Data?
        while true {
            let page = try await transport.changesWithoutFiles(since: token, zone: zone)
            for record in page.records where !leftAlone.contains(record.wire.recordType) {
                guard let id = FieldSealing.keyId(of: record.wire), id != current else { continue }
                stale.append(record)
            }
            token = page.token
            if !page.moreComing { break }
        }
        return stale
    }

    /// `record` sealed again under `current` (a file-bearing record's data key re-wrapped too, with the reference it
    /// now carries); nil for a lease still in use (its holder saves it again). Throws when it doesn't open here.
    static func resealed(_ record: SyncServerRecord, current: HouseholdKey, keys: [String: SymmetricKey], now: Date) throws
        -> (wire: SyncWireRecord, reference: SyncDocumentFileReference?)? {
        let outer = record.wire
        if outer.recordType == TransportLeaseStore.recordType {
            let payload = try SyncLargePayload.payload(from: outer, keys: keys)
            if case .date(let expires) = payload.fields["expiresAt"], expires > now { return nil }
        }
        if SyncFileTables.names.contains(outer.recordType) {
            var payload = try SyncLargePayload.payload(from: outer, keys: keys)
            if let reference = payload.documentFile, let id = try? DocumentCrypto.zoneKeyId(ofWrapped: reference.wrappedKey),
               id != current.id, let old = keys[id] {
                let rewrapped = SyncDocumentFileReference(recordName: reference.recordName,
                                                          wrappedKey: try DocumentCrypto.rewrap(reference.wrappedKey, from: old, to: current.key))
                payload.documentFile = rewrapped
                payload.zone = outer.zone
                return (try SyncLargePayload.wire(for: payload, key: current.key).0, rewrapped)
            }
        }
        return (try FieldSealing.seal(try FieldSealing.open(outer, keys: keys), key: current.key), nil)
    }

    /// After a re-sealed record is saved: where this device held the version the sweep read, it now holds the new one
    /// (its own re-seal doesn't come back as a change), and a re-wrapped data key replaces the one kept for that file.
    static func keepResealed(_ read: SyncServerRecord, stamp: SyncServerStamp, reference: SyncDocumentFileReference?, db: Database, now: Date) throws {
        let name = read.wire.recordName
        if read.wire.recordType == SyncZoneRouter.companionRecordType {
            if let held = try SyncCompanions.stamp(name: name, db: db), held.changeTag == read.stamp.changeTag {
                try SyncCompanions.store(name: name, zone: held.zone, stamp: stamp, db: db)
            }
        } else if try changeTags([name], db: db)[name] == read.stamp.changeTag {
            try storeStamp(stamp, uuid: name, db: db)
        }
        if let reference, let held = try SyncDocumentFile.reference(uuid: name, db: db), held.recordName == reference.recordName {
            try SyncDocumentFile.setReference(reference, uuid: name, db: db, now: now)
        }
    }
}
