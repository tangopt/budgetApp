import Foundation

public enum FakeCloudError: Error, Equatable {
    /// A change token that isn't one of this fake's, or is from another zone.
    case badToken
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
/// - a call log, and the names of any field a record carried outside its encrypted fields.
public actor FakeCloud: SyncTransport {
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
    }

    private struct Zone {
        var records: [String: Stored] = [:]
        var tombstones: [String: (type: String, sequence: Int)] = [:]
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
    private var sequence = 0
    private var tags = 0
    private var epoch = 0
    private var saveOperationsLeft: Int?
    private var saveFailure = SyncTransportError.networkUnavailable
    private var failing: [String: Int] = [:]
    private var loseNextReply = false

    /// The server's clock: every write moves it on by a millisecond; tests move it with `advanceClock`.
    public private(set) var now: Date
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
    /// `zones`: zones that exist from the start.
    public init(start: Date = Date(timeIntervalSinceReferenceDate: 800_000_000), pageSize: Int = 400, recordSizeLimit: Int = 1_000_000,
                limits: SyncOperationLimits = SyncOperationLimits(maxRecords: 400, maxBytes: 2_000_000), advertisesLimits: Bool = true,
                zones: [String] = []) {
        now = start
        self.pageSize = pageSize
        self.recordSizeLimit = recordSizeLimit
        self.limits = limits
        self.advertisesLimits = advertisesLimits
        for zone in zones { self.zones[zone] = Zone() }
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

    public func createZone(_ zone: String) async throws {
        calls.append(.createZone(zone))
        if zones[zone] == nil { zones[zone] = Zone() }
    }

    public func save(_ records: [SyncWireRecord], ifUnchanged: [String: Data], atomic: Bool) async throws -> [SaveResult] {
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
        var results = records.map { save(wire: $0, ifUnchanged: ifUnchanged[$0.recordName]) }
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
    func save(wire: SyncWireRecord, ifUnchanged systemFields: Data?) -> SaveResult {
        for field in wire.unencryptedFields.keys { unencryptedFieldNames.insert(wire.recordType + "." + field) }
        if let left = failing[wire.recordName], left > 0 {
            failing[wire.recordName] = left - 1
            return SaveResult(recordName: wire.recordName, outcome: .failed("zoneBusy"))
        }
        let size = wire.size
        guard size <= recordSizeLimit else { return SaveResult(recordName: wire.recordName, outcome: .tooLarge(bytes: size)) }
        guard var zone = zones[wire.zone] else { return SaveResult(recordName: wire.recordName, outcome: .zoneNotFound) }
        let tag = systemFields.flatMap { try? JSONDecoder().decode(SystemFields.self, from: $0) }?.tag
        if let existing = zone.records[wire.recordName] {
            guard tag == existing.tag else { return SaveResult(recordName: wire.recordName, outcome: .changed(server(existing))) }
        } else if systemFields != nil {
            return SaveResult(recordName: wire.recordName, outcome: .deleted)
        }
        tick()
        tags += 1
        let stored = Stored(wire: wire, tag: "tag-\(tags)", modifiedAt: now, sequence: sequence)
        zone.records[wire.recordName] = stored
        zone.tombstones[wire.recordName] = nil
        zone.latest = sequence
        zones[wire.zone] = zone
        return SaveResult(recordName: wire.recordName, outcome: .saved(stamp(stored, zone: wire.zone)))
    }

    public func changes(since token: Data?, zone name: String) async throws -> SyncChanges {
        var since: Int?
        if let token {
            guard let decoded = try? JSONDecoder().decode(Token.self, from: token), decoded.zone == name else { throw FakeCloudError.badToken }
            since = decoded.sequence
            calls.append(.changes(zone: name, since: since))
            guard decoded.epoch == epoch else { throw SyncTransportError.changeTokenExpired }
        } else {
            calls.append(.changes(zone: name, since: nil))
        }
        guard let zone = zones[name] else { throw SyncTransportError.zoneNotFound(name) }
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

    public func delete(_ recordNames: [String], zone name: String) async throws {
        calls.append(.delete(recordNames))
        guard var zone = zones[name] else { return }
        for recordName in recordNames {
            guard let existing = zone.records.removeValue(forKey: recordName) else { continue }
            tick()
            zone.tombstones[recordName] = (existing.wire.recordType, sequence)
            zone.latest = sequence
        }
        zones[name] = zone
    }

    public func fetch(_ recordName: String, zone: String) async throws -> SyncServerRecord? {
        calls.append(.fetch(recordName))
        guard let stored = zones[zone] else { throw SyncTransportError.zoneNotFound(zone) }
        return stored.records[recordName].map(server)
    }

    public func serverTime() async throws -> Date? { now }

    // MARK: Helpers

    private func tick() {
        sequence += 1
        now = now.addingTimeInterval(0.001)
    }

    private func stamp(_ stored: Stored, zone: String) -> SyncServerStamp {
        let fields = SystemFields(recordName: stored.wire.recordName, zone: zone, tag: stored.tag)
        return SyncServerStamp(systemFields: (try? JSONEncoder().encode(fields)) ?? Data(), changeTag: stored.tag, modifiedAt: stored.modifiedAt)
    }

    private func server(_ stored: Stored) -> SyncServerRecord {
        SyncServerRecord(wire: stored.wire, stamp: stamp(stored, zone: stored.wire.zone))
    }
}
