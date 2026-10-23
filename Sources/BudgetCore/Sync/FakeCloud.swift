import Foundation

public enum FakeCloudError: Error, Equatable {
    /// The connection dropped (`failSaveOperations(after:)`).
    case networkUnavailable
    /// A change token from another zone, or not one of this fake's.
    case badToken
}

/// CloudKit in memory, for tests and the App's debug harness (plan Task 5). It models what the engine
/// relies on:
/// - zones, each with its own change feed;
/// - per-record change tags and `.ifServerRecordUnchanged` compare-and-set (a save without a tag only
///   creates; a stale tag is refused with the server's record; a tag for a deleted record is refused);
/// - change feeds that carry only each record's latest version, and tombstones for deletions (not on a
///   fetch from scratch), in pages with continuation tokens;
/// - a server clock stamping every write (`modificationDate`);
/// - the ~1 MB record size limit (assets don't count);
/// - assets, stored as given (the app encrypts them first);
/// - a call log, and the names of any field a record carried outside its encrypted fields.
public actor FakeCloud: SyncTransport {
    public enum Call: Equatable, Sendable {
        case save([String])
        case changes(zone: String)
        case delete([String])
        case fetch(String)
        case saveAsset(String, bytes: Int)
        case asset(String)
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
    }

    private var zones: [String: Zone] = [:]
    private var sequence = 0
    private var tags = 0
    private var assets: [String: Data] = [:]
    private var saveOperationsLeft: Int?
    private var failing: [String: Int] = [:]

    /// The server's clock: every write moves it on by a millisecond; tests move it with `advanceClock`.
    public private(set) var now: Date
    public private(set) var pageSize: Int
    public let recordSizeLimit: Int
    public private(set) var calls: [Call] = []
    /// `"<recordType>.<field>"` for every field a saved record carried outside `encryptedFields`.
    public private(set) var unencryptedFieldNames: Set<String> = []

    public init(start: Date = Date(timeIntervalSinceReferenceDate: 800_000_000), pageSize: Int = 400, recordSizeLimit: Int = 1_000_000) {
        now = start
        self.pageSize = pageSize
        self.recordSizeLimit = recordSizeLimit
    }

    // MARK: Test controls

    public func advanceClock(by seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
    public func setPageSize(_ size: Int) { pageSize = max(1, size) }
    /// Lets `count` more save operations through, then fails every save with `networkUnavailable`.
    public func failSaveOperations(after count: Int) { saveOperationsLeft = count }
    public func restoreConnection() { saveOperationsLeft = nil }
    /// The next `times` saves of each named record fail with a passing error (`.failed`).
    public func failSaves(of names: Set<String>, times: Int) { for name in names { failing[name] = times } }

    /// Every record the server holds, as written (all zones).
    public func storedRecords() -> [SyncWireRecord] {
        zones.values.flatMap { $0.records.values.map(\.wire) }.sorted { $0.recordName < $1.recordName }
    }

    public func storedAssets() -> [String: Data] { assets }

    /// A record by name, in any zone.
    public func record(named name: String) -> SyncServerRecord? {
        for zone in zones.values { if let stored = zone.records[name] { return server(stored) } }
        return nil
    }

    // MARK: SyncTransport

    public func save(_ payloads: [SyncPayload], ifUnchanged: [String: String]) async throws -> [SaveResult] {
        calls.append(.save(payloads.map(\.recordName)))
        if let left = saveOperationsLeft {
            guard left > 0 else { throw FakeCloudError.networkUnavailable }
            saveOperationsLeft = left - 1
        }
        return try payloads.map { save(wire: try SyncWireRecord($0), ifUnchanged: ifUnchanged[$0.recordName]) }
    }

    /// Saves one record as written, with compare-and-set on `tag`.
    func save(wire: SyncWireRecord, ifUnchanged tag: String?) -> SaveResult {
        for field in wire.unencryptedFields.keys { unencryptedFieldNames.insert(wire.recordType + "." + field) }
        if let left = failing[wire.recordName], left > 0 {
            failing[wire.recordName] = left - 1
            return SaveResult(recordName: wire.recordName, outcome: .failed("zoneBusy"))
        }
        let size = wire.size
        guard size <= recordSizeLimit else { return SaveResult(recordName: wire.recordName, outcome: .tooLarge(bytes: size)) }
        var zone = zones[wire.zone] ?? Zone()
        if let existing = zone.records[wire.recordName] {
            guard tag == existing.tag else { return SaveResult(recordName: wire.recordName, outcome: .changed(server(existing))) }
        } else if tag != nil {
            return SaveResult(recordName: wire.recordName, outcome: .deleted)
        }
        tick()
        tags += 1
        let stored = Stored(wire: wire, tag: "tag-\(tags)", modifiedAt: now, sequence: sequence)
        zone.records[wire.recordName] = stored
        zone.tombstones[wire.recordName] = nil
        zone.latest = sequence
        zones[wire.zone] = zone
        return SaveResult(recordName: wire.recordName, outcome: .saved(changeTag: stored.tag, modifiedAt: stored.modifiedAt))
    }

    public func changes(since token: Data?, zone name: String) async throws -> SyncChanges {
        calls.append(.changes(zone: name))
        var since = 0
        if let token {
            guard let decoded = try? JSONDecoder().decode(Token.self, from: token), decoded.zone == name else { throw FakeCloudError.badToken }
            since = decoded.sequence
        }
        let zone = zones[name] ?? Zone()
        enum Item { case record(Stored), deletion(String, String, Int) }
        var items: [(Int, Item)] = zone.records.values.filter { $0.sequence > since }.map { ($0.sequence, .record($0)) }
        if token != nil {
            // From scratch there is nothing to delete: only what exists is listed.
            items += zone.tombstones.filter { $0.value.sequence > since }.map { ($0.value.sequence, .deletion($0.key, $0.value.type, $0.value.sequence)) }
        }
        items.sort { $0.0 < $1.0 }
        let page = items.prefix(pageSize)
        let moreComing = items.count > page.count
        var records: [SyncServerRecord] = []
        var deletions: [SyncDeletion] = []
        for (_, item) in page {
            switch item {
            case .record(let stored): records.append(server(stored))
            case .deletion(let name, let type, _): deletions.append(SyncDeletion(recordName: name, recordType: type))
            }
        }
        let reached = moreComing ? (page.last?.0 ?? since) : max(since, zone.latest)
        let next = try JSONEncoder().encode(Token(zone: name, sequence: reached))
        return SyncChanges(records: records, deletions: deletions, token: next, moreComing: moreComing)
    }

    public func delete(_ recordNames: [String], zone name: String) async throws {
        calls.append(.delete(recordNames))
        var zone = zones[name] ?? Zone()
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
        return zones[zone]?.records[recordName].map(server)
    }

    public func saveAsset(_ ciphertext: Data, for recordName: String) async throws {
        calls.append(.saveAsset(recordName, bytes: ciphertext.count))
        assets[recordName] = ciphertext
    }

    public func asset(for recordName: String) async throws -> Data {
        calls.append(.asset(recordName))
        guard let data = assets[recordName] else { throw SyncTransportError.assetNotFound(recordName) }
        return data
    }

    public func serverTime() async throws -> Date? { now }

    // MARK: Helpers

    private func tick() {
        sequence += 1
        now = now.addingTimeInterval(0.001)
    }

    private func server(_ stored: Stored) -> SyncServerRecord {
        let payload = (try? stored.wire.payload())
            ?? SyncPayload(recordType: stored.wire.recordType, recordName: stored.wire.recordName, zone: stored.wire.zone, fields: [:])
        return SyncServerRecord(payload: payload, changeTag: stored.tag, modifiedAt: stored.modifiedAt)
    }
}
