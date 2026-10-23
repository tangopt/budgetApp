import Foundation

/// A record as the server holds it: the payload, its change tag (CloudKit's `recordChangeTag`, opaque to
/// the engine) and when the server last wrote it, by the server's clock (`modificationDate`).
public struct SyncServerRecord: Equatable, Sendable {
    public var payload: SyncPayload
    public var changeTag: String
    public var modifiedAt: Date

    public init(payload: SyncPayload, changeTag: String, modifiedAt: Date) {
        self.payload = payload
        self.changeTag = changeTag
        self.modifiedAt = modifiedAt
    }
}

/// A record deleted on the server, as a change feed reports it (CloudKit gives the record type too).
public struct SyncDeletion: Equatable, Sendable {
    public var recordName: String
    public var recordType: String?

    public init(recordName: String, recordType: String?) {
        self.recordName = recordName
        self.recordType = recordType
    }
}

/// One page of a zone's change feed: the latest version of every record changed since the token, the
/// records deleted since, the token to continue from, and whether more pages follow.
public struct SyncChanges: Equatable, Sendable {
    public var records: [SyncServerRecord]
    public var deletions: [SyncDeletion]
    public var token: Data
    public var moreComing: Bool

    public init(records: [SyncServerRecord], deletions: [SyncDeletion], token: Data, moreComing: Bool) {
        self.records = records
        self.deletions = deletions
        self.token = token
        self.moreComing = moreComing
    }

    public var payloads: [SyncPayload] { records.map(\.payload) }
}

/// What happened to one record of a save.
public struct SaveResult: Equatable, Sendable {
    public enum Outcome: Equatable, Sendable {
        /// Saved; its new change tag and the server's modification time.
        case saved(changeTag: String, modifiedAt: Date)
        /// Refused by `ifServerRecordUnchanged`: the server holds another version (or the save had no tag
        /// for a record the server has). The server's record comes back to be merged and saved again.
        case changed(SyncServerRecord)
        /// Refused: the save named a change tag but the server has no such record (deleted there).
        case deleted
        /// Refused: the record is over the server's size limit (CloudKit's `limitExceeded`, about 1 MB).
        case tooLarge(bytes: Int)
        /// Not saved this time, for a reason that passes (CloudKit's per-record `zoneBusy`,
        /// `serviceUnavailable` or `batchRequestFailed`): sent again later.
        case failed(String)
    }

    public var recordName: String
    public var outcome: Outcome

    public init(recordName: String, outcome: Outcome) {
        self.recordName = recordName
        self.outcome = outcome
    }
}

/// The cloud as the sync engine sees it (plan Task 5). `FakeCloud` implements it in memory; the CloudKit
/// transport (App target, Task 8) implements it over `CKDatabase`. Every value travels inside the
/// record's encrypted fields (`SyncWireRecord`, sync spec §4.2).
public protocol SyncTransport: Sendable {
    /// Saves records with `.ifServerRecordUnchanged`: `ifUnchanged` holds the change tag each record was
    /// last seen with; a record without one may only be created. One result per payload.
    func save(_ payloads: [SyncPayload], ifUnchanged: [String: String]) async throws -> [SaveResult]
    /// The zone's changes since `token` (nil: from the start), one page.
    func changes(since token: Data?, zone: String) async throws -> SyncChanges
    /// Deletes records (unconditionally, like CloudKit; a record already gone is fine).
    func delete(_ recordNames: [String], zone: String) async throws
    /// One record, or nil when the server has none by that name.
    func fetch(_ recordName: String, zone: String) async throws -> SyncServerRecord?
    /// Stores ciphertext the app encrypted itself (a document, or a payload too large for a record).
    func saveAsset(_ ciphertext: Data, for recordName: String) async throws
    func asset(for recordName: String) async throws -> Data
    /// The server's clock now, where the transport can tell it.
    func serverTime() async throws -> Date?
}

extension SyncTransport {
    public func serverTime() async throws -> Date? { nil }
}

public enum SyncTransportError: Error, Equatable {
    case assetNotFound(String)
    case unreadableRecord(String)
}

// MARK: Wire records

/// A record as it is written to the server (sync spec §4.2): the record type, name and zone are the only
/// plaintext; every synced value, and everything the payload says about it (clocks, writers, batch tags,
/// manifests), is in `encryptedFields`, which the CloudKit transport writes to `encryptedValues`.
/// References are UUID strings inside encrypted fields, never `CKRecord.Reference`.
public struct SyncWireRecord: Equatable, Sendable {
    public var recordType: String
    public var recordName: String
    public var zone: String
    public var encryptedFields: [String: Data]
    /// Always empty for what BudgetCore builds; the fake records any it sees.
    public var unencryptedFields: [String: Data]

    /// Field names: a column's value is `f_<column>`; the rest of the payload is `meta`.
    static let fieldPrefix = "f_"
    static let metaField = "meta"

    private struct Meta: Codable {
        var clocks: [String: SyncClock]
        var modifiedBy: String?
        var modifiedAt: Date?
        var mergedInto: String?
        var importRunUuid: String?
        var batchGeneration: Int?
        var manifest: SyncBatchManifest?
        var deletedReferences: [String]?
        var largePayload: SyncLargePayloadReference?
    }

    public init(_ payload: SyncPayload) throws {
        recordType = payload.recordType
        recordName = payload.recordName
        zone = payload.zone
        unencryptedFields = [:]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var fields: [String: Data] = [:]
        for (column, value) in payload.fields { fields[Self.fieldPrefix + column] = try encoder.encode(value) }
        let meta = Meta(clocks: payload.clocks, modifiedBy: payload.modifiedBy, modifiedAt: payload.modifiedAt, mergedInto: payload.mergedInto,
                        importRunUuid: payload.importRunUuid, batchGeneration: payload.batchGeneration, manifest: payload.manifest,
                        deletedReferences: payload.deletedReferences, largePayload: payload.largePayload)
        fields[Self.metaField] = try encoder.encode(meta)
        encryptedFields = fields
    }

    public func payload() throws -> SyncPayload {
        let decoder = JSONDecoder()
        guard let metaData = encryptedFields[Self.metaField] else { throw SyncTransportError.unreadableRecord(recordName) }
        let meta = try decoder.decode(Meta.self, from: metaData)
        var fields: [String: SyncValue] = [:]
        for (key, data) in encryptedFields where key.hasPrefix(Self.fieldPrefix) {
            fields[String(key.dropFirst(Self.fieldPrefix.count))] = try decoder.decode(SyncValue.self, from: data)
        }
        var payload = SyncPayload(recordType: recordType, recordName: recordName, zone: zone, fields: fields, clocks: meta.clocks,
                                  modifiedBy: meta.modifiedBy, modifiedAt: meta.modifiedAt, mergedInto: meta.mergedInto,
                                  importRunUuid: meta.importRunUuid, batchGeneration: meta.batchGeneration, manifest: meta.manifest,
                                  deletedReferences: meta.deletedReferences)
        payload.largePayload = meta.largePayload
        return payload
    }

    /// The record's size as the server counts it (names and values; assets don't count).
    public var size: Int {
        let parts = [recordType, recordName, zone].map(\.utf8.count).reduce(0, +)
        let count = { (fields: [String: Data]) in fields.reduce(0) { $0 + $1.key.utf8.count + $1.value.count } }
        return parts + count(encryptedFields) + count(unencryptedFields)
    }
}
