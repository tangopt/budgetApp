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
        /// A removal's rotation or sweep hasn't finished (resumed after a quit, a crash or going offline), or a record
        /// arrived sealed under a revoked key after it had (a device with a stale marker): the sweep runs again.
        var pending = false
        /// Taking her off the share hasn't been confirmed yet (it is retried before anything is rotated). Optional so a
        /// state written before it decodes.
        var shareRemovalOwed: Bool?
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

    /// Whether taking the removed member off the share is still to be confirmed (`HouseholdRemoval` retries it first).
    public static func isShareRemovalOwed(db: Database) throws -> Bool {
        let state = try state(db: db)
        return state.pending && state.shareRemovalOwed == true
    }

    /// Before a member is taken off the share: every key in `held` is revoked (never granted again) and a rotation is
    /// owed; with `removingFromShare`, taking her off the share is owed first.
    static func begin(revoking held: Set<String>, removingFromShare: Bool, db: Database, now: Date) throws {
        var state = try state(db: db)
        state.revoked = Array(Set(state.revoked).union(held)).sorted()
        if !state.pending { state.progress = Progress(done: 0, total: 0) }
        state.pending = true
        if removingFromShare { state.shareRemovalOwed = true }
        try store(state, db: db, now: now)
    }

    /// She is off the share (confirmed by iCloud).
    static func shareRemoved(db: Database, now: Date) throws {
        var state = try state(db: db)
        state.shareRemovalOwed = nil
        try store(state, db: db, now: now)
    }

    /// The backstop (security review I1): a pull brought records sealed under a revoked key (a device that sealed
    /// before it saw the new marker), so the sweep is owed again. Returns whether it reopened.
    @discardableResult
    static func reopenIfRevoked(_ keyIds: Set<String>, db: Database, now: Date) throws -> Bool {
        var state = try state(db: db)
        guard !state.pending, !keyIds.isDisjoint(with: state.revoked) else { return false }
        state.pending = true
        state.progress = Progress(done: 0, total: 0)
        try store(state, db: db, now: now)
        return true
    }
}

/// What a re-seal sweep did.
public struct SyncResealReport: Equatable, Sendable {
    /// Records re-sealed or sent again under the current key (in this run).
    public var resealed: Int
    /// Records still sealed under another key that the sweep can convert (a later run takes them), a lease in use among
    /// them.
    public var remaining: Int
    /// Records left as they are: under a key this device doesn't hold, or a version this Mac hasn't applied (staged,
    /// held for a filed year: the pull path decides on it first).
    public var skipped: Int
    /// Since the removal's sweep began (all runs).
    public var progress: SyncKeyRotation.Progress
}

extension SyncEngineCore {
    private static let rotationLog = Logger(subsystem: "com.personal.budget", category: "SyncKeys")
    /// Passes over the zone in one sweep: a record changed by someone else while it ran is read again on the next.
    static let resealPasses = 3

    /// The re-seal sweep (Mac only), after a pull and a push: every record of the household that the server holds sealed
    /// under a key other than the current one goes up again under the current key, so a retired key opens nothing that
    /// changes from now on. Security review C1: the server's version is never trusted as it is. A version this Mac's own
    /// user wrote, and this Mac holds at that change tag, is sealed again as it is (a document record's data key
    /// re-wrapped, its file not uploaded again); a version anyone else wrote, once this Mac has applied it (re-validated,
    /// its clocks clamped), goes up as this Mac holds it, through the push; a version this Mac hasn't applied is left
    /// for the pull path. An expired lease is sealed again as it is; a lease in use waits. Never the zone key marker, a
    /// document file (sealed under its own data key) or the key exchange's records. Resumable: progress is kept after
    /// each operation; a passing transport error stops it with what is done kept.
    @discardableResult
    public func resealSweep(progress: @escaping @Sendable (SyncKeyRotation.Progress) -> Void = { _ in }) async throws -> SyncResealReport {
        guard mode.ownsZones else { throw ReadOnlyError.readOnly }
        return try await serialized {
            _ = try await self.pullAll()
            _ = try await self.pushAll()
            return try await self.resealSweepNow(progress: progress)
        }
    }

    /// How the sweep takes one stale record.
    private enum Reseal {
        /// Sealed again as it is.
        case asIs(SyncServerRecord)
        /// Sent again as this Mac holds it (by the push).
        case resend(SyncServerRecord, table: String, localId: Int64)
        /// A lease in use: it waits.
        case wait
        case skip
    }

    /// The sweep itself (the caller has pulled and pushed, inside an entry point already serialized).
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
            // The server's clock judges a lease, not this Mac's (review M2).
            let serverNow = (try? await transport.serverTime()) ?? clock()
            let plans = try await db.read { db in try stale.map { try Self.plan($0, keys: keys, serverNow: serverNow, db: db) } }
            var outgoing: [(server: SyncServerRecord, wire: SyncWireRecord, reference: SyncDocumentFileReference?)] = []
            var resend: [(server: SyncServerRecord, table: String, localId: Int64)] = []
            var waiting = 0
            var skipped = 0
            for plan in plans {
                switch plan {
                case .asIs(let record):
                    do {
                        let resealed = try Self.resealed(record, current: current, keys: keys)
                        outgoing.append((record, resealed.wire, resealed.reference))
                    } catch {
                        Self.rotationLog.error("Re-seal: \(record.wire.recordType, privacy: .public) \(record.wire.recordName, privacy: .public) can't be opened here; left")
                        skipped += 1
                    }
                case .resend(let record, let table, let localId): resend.append((record, table, localId))
                case .wait: waiting += 1
                case .skip: skipped += 1
                }
            }
            report.skipped = skipped
            report.remaining = outgoing.count + resend.count + waiting
            state.progress.total = state.progress.done + report.remaining
            try await persist(state)
            progress(state.progress)
            guard !outgoing.isEmpty || !resend.isEmpty else { break }
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
                try await count(converted, into: &report, state: &state, progress: progress)
            }
            if !resend.isEmpty {
                // Anyone else's version goes up as this Mac holds it (re-validated, clocks clamped), through the push.
                try await db.write { db in
                    for record in resend {
                        try SyncMerge.queue(uuid: record.server.wire.recordName, table: record.table, localId: record.localId, kind: .update, db: db)
                    }
                }
                _ = try await pushAll()
                let tags = try await db.read { db in try Self.changeTags(resend.map(\.server.wire.recordName), db: db) }
                let converted = resend.filter { tags[$0.server.wire.recordName] != $0.server.stamp.changeTag }.count
                try await count(converted, into: &report, state: &state, progress: progress)
            }
            if report.remaining == waiting { break }
        }
        report.progress = state.progress
        Self.rotationLog.notice("Re-seal: \(report.resealed, privacy: .public) re-sealed, \(report.remaining, privacy: .public) left, \(report.skipped, privacy: .public) skipped")
        return report
    }

    private func count(_ converted: Int, into report: inout SyncResealReport, state: inout SyncKeyRotation.State,
                       progress: @Sendable (SyncKeyRotation.Progress) -> Void) async throws {
        report.resealed += converted
        report.remaining -= converted
        state.progress.done += converted
        try await persist(state)
        progress(state.progress)
    }

    /// How the sweep takes `record` (security review C1): by who wrote the version and whether this Mac holds it.
    private static func plan(_ record: SyncServerRecord, keys: [String: SymmetricKey], serverNow: Date, db: Database) throws -> Reseal {
        let name = record.wire.recordName
        if record.wire.recordType == TransportLeaseStore.recordType {
            guard let payload = try? SyncLargePayload.payload(from: record.wire, keys: keys) else { return .skip }
            if case .date(let expires) = payload.fields["expiresAt"], expires > serverNow { return .wait }
            return .asIs(record)
        }
        let heldTag: String?
        if record.wire.recordType == SyncZoneRouter.companionRecordType {
            heldTag = try SyncCompanions.stamp(name: name, db: db)?.changeTag
        } else {
            heldTag = try changeTags([name], db: db)[name]
        }
        // Not applied here at this version: staged, held, or newer than the pull saw; the pull path decides first.
        guard heldTag == record.stamp.changeTag else { return .skip }
        if try writtenBySelf(record, db: db) { return .asIs(record) }
        guard record.wire.recordType != SyncZoneRouter.companionRecordType,
              let row = try Row.fetchOne(db, sql: "SELECT tableName, localId FROM syncRecord WHERE uuid = ?", arguments: [name]) else {
            return .skip
        }
        return .resend(record, table: row["tableName"], localId: row["localId"])
    }

    /// Whether the server says this Mac's own user saved the version (never what the record claims).
    private static func writtenBySelf(_ record: SyncServerRecord, db: Database) throws -> Bool {
        guard let writer = record.lastModifiedBy,
              let selfUser = try AccessRevalidation.selfUser(deviceUser: deviceUser(db: db), db: db),
              let id = try Int64.fetchOne(db, sql: "SELECT id FROM appUser WHERE cloudKitUserRecordName = ?", arguments: [writer]) else {
            return false
        }
        return try SyncRecordStore.existingUUID(table: "appUser", localId: id, db: db) == selfUser
    }

    // MARK: A removal's revocation (step 15)

    /// Before a member is taken off the household's share (Mac only): every household key held now is one she may hold,
    /// so each is revoked (never granted again) and a rotation is pending until `finishKeyRevocation` completes it. With
    /// `removingFromShare`, taking her off the share is owed first (`HouseholdRemoval`).
    public func beginKeyRevocation(removingFromShare: Bool = false) async throws {
        guard mode.ownsZones else { throw ReadOnlyError.readOnly }
        try await serialized {
            let held = Set(try self.keyStore.allKeys(zone: SyncZones.household).keys)
            let now = self.clock()
            try await self.db.write { db in
                try SyncKeyRotation.begin(revoking: held, removingFromShare: removingFromShare, db: db, now: now)
            }
            Self.rotationLog.notice("Key revocation begun: \(held.count, privacy: .public) key(s) revoked")
        }
    }

    /// A pending revocation finished: a pull first (what she wrote is re-validated and clamped before anything is sealed
    /// again), a new household key unless the current one is already not a revoked one (a resume after the rotation),
    /// then the re-seal sweep. The revocation stays pending until the sweep leaves nothing to convert; a passing transport
    /// error stops it with what is done kept (`resumeIfPending` goes on later). Nil when nothing is pending, or while
    /// taking her off the share is still owed (nothing is rotated before she is off it).
    @discardableResult
    public func finishKeyRevocation(progress: @escaping @Sendable (SyncKeyRotation.Progress) -> Void = { _ in }) async throws -> SyncResealReport? {
        guard mode.ownsZones else { throw ReadOnlyError.readOnly }
        return try await serialized { () -> SyncResealReport? in
            let zone = SyncZones.household
            let revoked = try await self.db.read { db -> Set<String>? in
                let state = try SyncKeyRotation.state(db: db)
                return state.pending && state.shareRemovalOwed != true ? Set(state.revoked) : nil
            }
            guard let revoked else { return nil }
            try await self.prepare()
            _ = try await self.pullAll()
            let current = try await self.refreshHouseholdKey(zone: zone, create: false)
            if revoked.contains(current.id) {
                let rotation = try await self.rotateZoneKeyNow()
                Self.rotationLog.notice("Key revocation: new household key, \(rotation.rewrapped, privacy: .public) data key(s) re-wrapped")
            } else {
                // What the pull reverted goes up (under the current key) before the sweep reads the zone.
                _ = try await self.pushAll()
            }
            // Review M1: a marker adopted in a race must not name a revoked key.
            let adopted = try await self.refreshHouseholdKey(zone: zone, create: false)
            guard !revoked.contains(adopted.id) else {
                Self.rotationLog.error("Key revocation: the household's key is still a revoked one; trying again later")
                throw SyncKeyError.unavailable
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

    /// `record` sealed again under `current`, as it is (a file-bearing record's data key re-wrapped too, with the
    /// reference it now carries). Only for versions this Mac's own user wrote, or an expired lease. Throws when it doesn't
    /// open here.
    static func resealed(_ record: SyncServerRecord, current: HouseholdKey, keys: [String: SymmetricKey]) throws
        -> (wire: SyncWireRecord, reference: SyncDocumentFileReference?) {
        let outer = record.wire
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
