import Foundation
import os

public enum FakeCloudError: Error, Equatable {
    /// A change token that isn't one of this fake's, or is from another zone.
    case badToken
    /// The acting user may read the zone but not write it (CloudKit `permissionFailure`), or isn't its owner.
    case permissionFailure
}

/// `CKDatabase` in memory (ruling R11), for tests and the App's debug harness. It models what the engine
/// relies on:
/// - custom zones that must be created before use (`zoneNotFound` otherwise) and can be deleted;
/// - per-record change tags, and system-field blobs that differ from them; `.ifServerRecordUnchanged`
///   compare-and-set (no system fields: create only; a stale version: `changed` with the server's record;
///   a version of a deleted record: `deleted`); a deleted record can be created again;
/// - `CKModifyRecordsOperation`'s atomic default in custom zones (one failure fails the rest with
///   `batchRequestFailed`), per-operation record and byte limits (`limitExceeded`), the ~1 MB record limit;
/// - asset fields stored with the record version (a replaced asset goes with its old version);
/// - change feeds with only each record's latest version and tombstones for deletions (none from
///   scratch), in feed order, in pages; tokens that can expire (`changeTokenExpired`);
/// - a server clock stamping every write;
/// - failure modes: a dropped connection, a lost reply (applied on the server, an error to the client),
///   passing per-record failures;
/// - a call log, and the names of any field a record carried outside its encrypted fields;
/// - iCloud users (step 7a): the cloud itself acts as `ownerRecordName`; `session(as:)` acts as another user. A
///   zone is owned by the user who created it; another user reaches it only as an accepted participant of its
///   zone-wide share (`invite`, `accept`, `removeParticipant`): reads, plus writes when the share lets them. Only the
///   owner creates or deletes the zone and edits its share; a participant leaves by deleting the share record
///   (`zoneShareRecordName`).
///   Anyone else gets `zoneNotFound`, as a zone missing from their databases; a read-only participant's saves fail
///   with `permissionFailure`. Every saved version and deletion is stamped with the acting user
///   (`SyncServerRecord.lastModifiedBy`, `deletedBy`).
public actor FakeCloud: SyncTransport, SyncShareTransport {
    public enum Call: Equatable, Sendable {
        case createZone(String)
        case save([String], atomic: Bool)
        /// `since`: the token's position, nil from scratch.
        case changes(zone: String, since: Int?)
        case delete([String])
        case fetch(String)
    }

    private struct Stored {
        var wire: SyncWireRecord
        var tag: String
        var modifiedAt: Date
        var sequence: Int
        /// The user who saved this version.
        var modifiedBy: String
    }

    private struct Zone {
        var records: [String: Stored] = [:]
        var tombstones: [String: (type: String, sequence: Int, by: String)] = [:]
        var latest = 0
    }

    private struct Token: Codable {
        var zone: String
        var sequence: Int
        var epoch: Int
    }

    /// What a `systemFields` blob holds here: the version, wrapped so it is not the tag itself.
    private struct SystemFields: Codable {
        var recordName: String
        var zone: String
        var tag: String
    }

    private var zones: [String: Zone] = [:]

    /// Who owns each zone and its share, outside the actor so the share sheet's stand-ins (`invite`, `accept`) are
    /// synchronous. A zone's owner is set when it is created (or by an invite made before that), and cleared with it.
    private struct Sharing {
        var owners: [String: String] = [:]
        var shares: [String: [SyncShareParticipant]] = [:]
    }

    private enum Access { case owner, write, read }

    private let sharing = OSAllocatedUnfairLock(initialState: Sharing())
    /// The iCloud user the cloud itself acts as (the admin).
    public nonisolated let ownerRecordName: String
    private var sequence = 0
    private var tags = 0
    private var epoch = 0
    private var saveOperationsLeft: Int?
    private var saveFailure = SyncTransportError.networkUnavailable
    private var failing: [String: Int] = [:]
    private var loseNextReply = false

    /// The server's clock: every write moves it on by a millisecond (and, `followsWallClock`, up to the wall clock);
    /// tests move it with `advanceClock`.
    public private(set) var now: Date
    private let followsWallClock: Bool
    public private(set) var pageSize: Int
    public let recordSizeLimit: Int
    /// The limits enforced per save operation.
    public let limits: SyncOperationLimits
    private let advertisesLimits: Bool
    public private(set) var calls: [Call] = []
    /// `"<recordType>.<field>"` for every field a saved record carried outside `encryptedFields`.
    public private(set) var unencryptedFieldNames: Set<String> = []
    /// How many save operations were refused as too large as a whole.
    public private(set) var limitExceededCount = 0

    /// `advertisesLimits`: false to tell the engine none, so it meets them only as `limitExceeded`.
    /// `zones`: zones that exist from the start. `followsWallClock`: the server's time of a save is never earlier than the
    /// devices' (`Date()`), as with a real server, so their clocks aren't clamped back (step 7a).
    public init(start: Date = Date(timeIntervalSinceReferenceDate: 800_000_000), pageSize: Int = 400, recordSizeLimit: Int = 1_000_000,
                limits: SyncOperationLimits = SyncOperationLimits(maxRecords: 400, maxBytes: 2_000_000), advertisesLimits: Bool = true,
                zones: [String] = [], ownerRecordName: String = "fake-owner", followsWallClock: Bool = false) {
        now = start
        self.followsWallClock = followsWallClock
        self.ownerRecordName = ownerRecordName
        self.pageSize = pageSize
        self.recordSizeLimit = recordSizeLimit
        self.limits = limits
        self.advertisesLimits = advertisesLimits
        for zone in zones { self.zones[zone] = Zone() }
        sharing.withLock { sharing in for zone in zones { sharing.owners[zone] = ownerRecordName } }
    }

    // MARK: Test controls

    public func advanceClock(by seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
    public func setPageSize(_ size: Int) { pageSize = max(1, size) }
    /// Lets `count` more save operations through, then fails every save with `error` (`networkUnavailable`, or
    /// `unavailable` as CloudKit's busy or rate-limited service).
    public func failSaveOperations(after count: Int, with error: SyncTransportError = .networkUnavailable) {
        saveOperationsLeft = count
        saveFailure = error
    }
    public func restoreConnection() { saveOperationsLeft = nil }
    /// The next `times` saves of each named record fail with a passing error (`.failed`).
    public func failSaves(of names: Set<String>, times: Int) { for name in names { failing[name] = times } }
    /// The next save operation is applied, but its reply is lost: the caller gets `networkUnavailable`.
    public func loseTheNextReply() { loseNextReply = true }
    /// Every change token issued so far stops working (`changeTokenExpired`).
    public func expireChangeTokens() { epoch += 1 }
    /// Deletes a zone and everything in it (another device reset it, or the user did).
    public func deleteZone(_ name: String) {
        zones[name] = nil
        sharing.withLock { sharing in
            sharing.owners[name] = nil
            sharing.shares[name] = nil
        }
        epoch += 1
    }
    /// Damages a stored asset's bytes (for unreadable-record tests).
    public func corruptAsset(of recordName: String, field: String) {
        for (name, var zone) in zones {
            guard var stored = zone.records[recordName], var data = stored.wire.assets[field], !data.isEmpty else { continue }
            data[data.startIndex] ^= 0xFF
            stored.wire.assets[field] = data
            zone.records[recordName] = stored
            zones[name] = zone
        }
    }

    /// Every record the server holds, as written (all zones).
    public func storedRecords() -> [SyncWireRecord] {
        zones.values.flatMap { $0.records.values.map(\.wire) }.sorted { $0.recordName < $1.recordName }
    }

    /// A record by name, in any zone.
    public func record(named name: String) -> SyncServerRecord? {
        for zone in zones.values { if let stored = zone.records[name] { return server(stored) } }
        return nil
    }

    /// The payload a record holds, opened with the zone keys of `keys` (ruling R15), and its asset if it is a
    /// large one (`SyncLargePayload`).
    public func payload(named name: String, keys: any SyncKeyStore) throws -> SyncPayload? {
        guard let server = record(named: name) else { return nil }
        return try SyncLargePayload.payload(from: server.wire, keys: try keys.allKeys(zone: server.wire.zone))
    }

    // MARK: SyncTransport

    public func operationLimits() async -> SyncOperationLimits { advertisesLimits ? limits : .unlimited }

    public func createZone(_ zone: String) async throws { try createZone(zone, as: ownerRecordName) }

    public func save(_ records: [SyncWireRecord], ifUnchanged: [String: Data], atomic: Bool) async throws -> [SaveResult] {
        try save(records, ifUnchanged: ifUnchanged, atomic: atomic, as: ownerRecordName)
    }

    public func changes(since token: Data?, zone: String) async throws -> SyncChanges {
        try changes(since: token, zone: zone, as: ownerRecordName)
    }

    public func delete(_ recordNames: [String], zone: String) async throws { try delete(recordNames, zone: zone, as: ownerRecordName) }

    public func fetch(_ recordName: String, zone: String) async throws -> SyncServerRecord? {
        try fetch(recordName, zone: zone, as: ownerRecordName)
    }

    public func serverTime() async throws -> Date? { now }

    // MARK: SyncShareTransport (as the owner)

    public func currentUserRecordName() async throws -> String { ownerRecordName }
    public func zoneShare(_ zone: String) async throws -> SyncZoneShare? { try zoneShare(zone, as: ownerRecordName) }
    public func makeZoneShare(_ zone: String, title: String) async throws -> SyncZoneShare {
        try makeZoneShare(zone, title: title, as: ownerRecordName)
    }
    public func removeParticipant(userRecordName: String, zone: String) async throws {
        try removeParticipant(userRecordName: userRecordName, zone: zone, as: ownerRecordName)
    }

    // MARK: Users and the zone share

    /// The cloud as another iCloud user.
    public nonisolated func session(as userRecordName: String) -> FakeCloudSession {
        FakeCloudSession(cloud: self, userRecordName: userRecordName)
    }

    /// The system share sheet's stand-in: adds `userRecordName` to the zone's share as invited (the share is made
    /// when there is none; a zone not created yet is reserved for this cloud's owner). Inviting again replaces
    /// the participant's permission and status.
    public nonisolated func invite(_ userRecordName: String, zone: String, canWrite: Bool = true) {
        sharing.withLock { sharing in
            if sharing.owners[zone] == nil { sharing.owners[zone] = ownerRecordName }
            var participants = sharing.shares[zone] ?? []
            participants.removeAll { $0.userRecordName == userRecordName }
            participants.append(SyncShareParticipant(userRecordName: userRecordName, status: .invited, canWrite: canWrite))
            sharing.shares[zone] = participants
        }
    }

    /// `userRecordName` accepts the zone's share (opens the link): the zone becomes reachable for them. Nothing
    /// happens for someone the share doesn't list.
    public nonisolated func accept(zone: String, as userRecordName: String) {
        sharing.withLock { sharing in
            guard let index = sharing.shares[zone]?.firstIndex(where: { $0.userRecordName == userRecordName }) else { return }
            sharing.shares[zone]?[index].status = .accepted
        }
    }

    /// Who deleted the record (its tombstone's user), if the zone holds a tombstone for it.
    public func deletedBy(_ recordName: String, zone: String) -> String? {
        zones[zone]?.tombstones[recordName]?.by
    }

    private nonisolated func access(_ zone: String, by user: String) -> Access? {
        sharing.withLock { sharing in
            guard let owner = sharing.owners[zone] else { return nil }
            if owner == user { return .owner }
            guard let participant = sharing.shares[zone]?.first(where: { $0.userRecordName == user }),
                  participant.status == .accepted else { return nil }
            return participant.canWrite ? .write : .read
        }
    }

    /// The zone as `user` reaches it: throws `zoneNotFound` when it doesn't exist or isn't theirs or shared with them.
    private func reachable(_ zone: String, by user: String) throws -> Access {
        guard zones[zone] != nil, let access = access(zone, by: user) else { throw SyncTransportError.zoneNotFound(zone) }
        return access
    }

    private nonisolated func share(_ zone: String) -> SyncZoneShare? {
        sharing.withLock { sharing in
            guard let participants = sharing.shares[zone], let owner = sharing.owners[zone] else { return nil }
            return SyncZoneShare(zone: zone, url: URL(string: "https://www.icloud.com/share/fake-\(zone)"), ownerRecordName: owner,
                                 participants: participants)
        }
    }

    func zoneShare(_ zone: String, as user: String) throws -> SyncZoneShare? {
        _ = try reachable(zone, by: user)
        return share(zone)
    }

    func makeZoneShare(_ zone: String, title: String, as user: String) throws -> SyncZoneShare {
        guard try reachable(zone, by: user) == .owner else { throw FakeCloudError.permissionFailure }
        sharing.withLock { sharing in
            if sharing.shares[zone] == nil { sharing.shares[zone] = [] }
        }
        return share(zone)!
    }

    /// The owner removes a participant (only the owner edits the share: a participant leaves by deleting the share,
    /// `zoneShareRecordName`, from their shared database).
    func removeParticipant(userRecordName: String, zone: String, as user: String) throws {
        guard try reachable(zone, by: user) == .owner else { throw FakeCloudError.permissionFailure }
        sharing.withLock { sharing in sharing.shares[zone]?.removeAll { $0.userRecordName == userRecordName } }
    }

    /// The zone-wide share's record name (CloudKit `CKRecordNameZoneWideShare`): a participant deleting it leaves the
    /// share; the owner deleting it stops sharing the zone.
    public static let zoneShareRecordName = "cloudkit.zoneshare"

    /// The zone deleted by `user`: only its owner can (a participant's shared database can't delete it).
    func deleteZone(_ name: String, as user: String) throws {
        guard try reachable(name, by: user) == .owner else { throw FakeCloudError.permissionFailure }
        deleteZone(name)
    }

    // MARK: Operations as a user

    func createZone(_ zone: String, as user: String) throws {
        calls.append(.createZone(zone))
        if zones[zone] != nil {
            // Already there: nothing to do for its owner; a participant can't save zones in their shared database.
            guard try reachable(zone, by: user) == .owner else { throw FakeCloudError.permissionFailure }
            return
        }
        // A zone reserved for its owner by an invite made before it existed is theirs to create.
        let reserved = sharing.withLock { $0.owners[zone] }
        if let reserved, reserved != user { throw SyncTransportError.zoneNotFound(zone) }
        zones[zone] = Zone()
        sharing.withLock { $0.owners[zone] = user }
    }

    func save(_ records: [SyncWireRecord], ifUnchanged: [String: Data], atomic: Bool, as user: String) throws -> [SaveResult] {
        calls.append(.save(records.map(\.recordName), atomic: atomic))
        if let left = saveOperationsLeft {
            guard left > 0 else { throw saveFailure }
            saveOperationsLeft = left - 1
        }
        guard records.count <= limits.maxRecords, records.map(\.size).reduce(0, +) <= limits.maxBytes else {
            limitExceededCount += 1
            throw SyncTransportError.limitExceeded
        }
        let saved = zones
        var results = records.map { save(wire: $0, ifUnchanged: ifUnchanged[$0.recordName], as: user) }
        if atomic, results.contains(where: { if case .saved = $0.outcome { return false } else { return true } }) {
            // All or nothing: what saved is undone; those that would have saved fail with the batch.
            zones = saved
            results = results.map { result in
                if case .saved = result.outcome { return SaveResult(recordName: result.recordName, outcome: .batchRequestFailed) }
                return result
            }
        }
        if loseNextReply {
            loseNextReply = false
            throw SyncTransportError.networkUnavailable
        }
        return results
    }

    /// Saves one record as written, with compare-and-set on the version `systemFields` names.
    func save(wire: SyncWireRecord, ifUnchanged systemFields: Data?, as user: String? = nil) -> SaveResult {
        let user = user ?? ownerRecordName
        for field in wire.unencryptedFields.keys { unencryptedFieldNames.insert(wire.recordType + "." + field) }
        if let left = failing[wire.recordName], left > 0 {
            failing[wire.recordName] = left - 1
            return SaveResult(recordName: wire.recordName, outcome: .failed("zoneBusy"))
        }
        let size = wire.size
        guard size <= recordSizeLimit else { return SaveResult(recordName: wire.recordName, outcome: .tooLarge(bytes: size)) }
        guard var zone = zones[wire.zone], let access = access(wire.zone, by: user) else {
            return SaveResult(recordName: wire.recordName, outcome: .zoneNotFound)
        }
        guard access != .read else { return SaveResult(recordName: wire.recordName, outcome: .failed("permissionFailure")) }
        let tag = systemFields.flatMap { try? JSONDecoder().decode(SystemFields.self, from: $0) }?.tag
        if let existing = zone.records[wire.recordName] {
            guard tag == existing.tag else { return SaveResult(recordName: wire.recordName, outcome: .changed(server(existing))) }
        } else if systemFields != nil {
            return SaveResult(recordName: wire.recordName, outcome: .deleted)
        }
        tick()
        tags += 1
        let stored = Stored(wire: wire, tag: "tag-\(tags)", modifiedAt: now, sequence: sequence, modifiedBy: user)
        zone.records[wire.recordName] = stored
        zone.tombstones[wire.recordName] = nil
        zone.latest = sequence
        zones[wire.zone] = zone
        return SaveResult(recordName: wire.recordName, outcome: .saved(stamp(stored, zone: wire.zone)))
    }

    func changes(since token: Data?, zone name: String, as user: String) throws -> SyncChanges {
        var since: Int?
        if let token {
            guard let decoded = try? JSONDecoder().decode(Token.self, from: token), decoded.zone == name else { throw FakeCloudError.badToken }
            since = decoded.sequence
            calls.append(.changes(zone: name, since: since))
            guard decoded.epoch == epoch else { throw SyncTransportError.changeTokenExpired }
        } else {
            calls.append(.changes(zone: name, since: nil))
        }
        guard let zone = zones[name], access(name, by: user) != nil else { throw SyncTransportError.zoneNotFound(name) }
        let after = since ?? 0
        var items: [(Int, SyncFeedChange)] = zone.records.values.filter { $0.sequence > after }.map { ($0.sequence, .record(server($0))) }
        if since != nil {
            // From scratch there is nothing to delete: only what exists is listed.
            items += zone.tombstones.filter { $0.value.sequence > after }
                .map { ($0.value.sequence, .deletion(SyncDeletion(recordName: $0.key, recordType: $0.value.type))) }
        }
        items.sort { $0.0 < $1.0 }
        let page = Array(items.prefix(pageSize))
        let moreComing = items.count > page.count
        let reached = moreComing ? (page.last?.0 ?? after) : max(after, zone.latest)
        let next = try JSONEncoder().encode(Token(zone: name, sequence: reached, epoch: epoch))
        return SyncChanges(changes: page.map(\.1), token: next, moreComing: moreComing)
    }

    func delete(_ recordNames: [String], zone name: String, as user: String) throws {
        calls.append(.delete(recordNames))
        guard var zone = zones[name] else { return }
        guard let access = access(name, by: user) else { throw SyncTransportError.zoneNotFound(name) }
        if recordNames.contains(Self.zoneShareRecordName) {
            // Deleting the share: a participant leaves it; its owner stops sharing.
            sharing.withLock { sharing in
                if access == .owner { sharing.shares[name] = nil } else { sharing.shares[name]?.removeAll { $0.userRecordName == user } }
            }
        }
        let records = recordNames.filter { $0 != Self.zoneShareRecordName }
        guard !records.isEmpty else { return }
        guard access != .read else { throw FakeCloudError.permissionFailure }
        for recordName in records {
            guard let existing = zone.records.removeValue(forKey: recordName) else { continue }
            tick()
            zone.tombstones[recordName] = (existing.wire.recordType, sequence, user)
            zone.latest = sequence
        }
        zones[name] = zone
    }

    func fetch(_ recordName: String, zone: String, as user: String) throws -> SyncServerRecord? {
        calls.append(.fetch(recordName))
        guard let stored = zones[zone], access(zone, by: user) != nil else { throw SyncTransportError.zoneNotFound(zone) }
        return stored.records[recordName].map(server)
    }

    // MARK: Helpers

    private func tick() {
        sequence += 1
        now = now.addingTimeInterval(0.001)
        if followsWallClock { now = max(now, Date()) }
    }

    private func stamp(_ stored: Stored, zone: String) -> SyncServerStamp {
        let fields = SystemFields(recordName: stored.wire.recordName, zone: zone, tag: stored.tag)
        return SyncServerStamp(systemFields: (try? JSONEncoder().encode(fields)) ?? Data(), changeTag: stored.tag, modifiedAt: stored.modifiedAt)
    }

    private func server(_ stored: Stored) -> SyncServerRecord {
        SyncServerRecord(wire: stored.wire, stamp: stamp(stored, zone: stored.wire.zone), lastModifiedBy: stored.modifiedBy)
    }
}

/// `FakeCloud` as one iCloud user (`FakeCloud.session(as:)`): their view of the zones, and their writes.
public struct FakeCloudSession: SyncTransport, SyncShareTransport {
    public let cloud: FakeCloud
    public let userRecordName: String

    public func operationLimits() async -> SyncOperationLimits { await cloud.operationLimits() }
    public func createZone(_ zone: String) async throws { try await cloud.createZone(zone, as: userRecordName) }
    public func save(_ records: [SyncWireRecord], ifUnchanged: [String: Data], atomic: Bool) async throws -> [SaveResult] {
        try await cloud.save(records, ifUnchanged: ifUnchanged, atomic: atomic, as: userRecordName)
    }
    public func changes(since token: Data?, zone: String) async throws -> SyncChanges {
        try await cloud.changes(since: token, zone: zone, as: userRecordName)
    }
    public func delete(_ recordNames: [String], zone: String) async throws {
        try await cloud.delete(recordNames, zone: zone, as: userRecordName)
    }
    public func fetch(_ recordName: String, zone: String) async throws -> SyncServerRecord? {
        try await cloud.fetch(recordName, zone: zone, as: userRecordName)
    }
    public func serverTime() async throws -> Date? { try await cloud.serverTime() }
    /// Deletes the zone: its owner only (`FakeCloudError.permissionFailure` for a participant).
    public func deleteZone(_ zone: String) async throws { try await cloud.deleteZone(zone, as: userRecordName) }

    public func currentUserRecordName() async throws -> String { userRecordName }
    public func zoneShare(_ zone: String) async throws -> SyncZoneShare? { try await cloud.zoneShare(zone, as: userRecordName) }
    public func makeZoneShare(_ zone: String, title: String) async throws -> SyncZoneShare {
        try await cloud.makeZoneShare(zone, title: title, as: userRecordName)
    }
    public func removeParticipant(userRecordName: String, zone: String) async throws {
        try await cloud.removeParticipant(userRecordName: userRecordName, zone: zone, as: self.userRecordName)
    }
}
