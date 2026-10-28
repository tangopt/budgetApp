import Foundation

/// The server's stamp on a record version: `systemFields` is the opaque blob the transport needs to save
/// the record again against this version (CloudKit's `encodeSystemFields`); `changeTag` names the version
/// and is what the engine compares; `modifiedAt` is the server's clock when it was written.
public struct SyncServerStamp: Equatable, Sendable {
    public var systemFields: Data
    public var changeTag: String
    public var modifiedAt: Date

    public init(systemFields: Data, changeTag: String, modifiedAt: Date) {
        self.systemFields = systemFields
        self.changeTag = changeTag
        self.modifiedAt = modifiedAt
    }
}

/// A record as the server holds it: as written, with its stamp, and who the server says wrote this version.
public struct SyncServerRecord: Equatable, Sendable {
    public var wire: SyncWireRecord
    public var stamp: SyncServerStamp
    /// The iCloud user record name the server says wrote this version (CloudKit's `lastModifiedUserRecordID`), never
    /// a claim the record makes about itself; nil when the transport can't tell.
    public var lastModifiedBy: String?

    public init(wire: SyncWireRecord, stamp: SyncServerStamp, lastModifiedBy: String? = nil) {
        self.wire = wire
        self.stamp = stamp
        self.lastModifiedBy = lastModifiedBy
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

/// One entry of a zone's change feed, in feed order.
public enum SyncFeedChange: Equatable, Sendable {
    case record(SyncServerRecord)
    case deletion(SyncDeletion)
}

/// One page of a zone's change feed (`CKFetchRecordZoneChangesOperation`): the latest version of every
/// record changed since the token and the records deleted since, in feed order; the token to continue
/// from; whether more pages follow.
public struct SyncChanges: Equatable, Sendable {
    public var changes: [SyncFeedChange]
    public var token: Data
    public var moreComing: Bool

    public init(changes: [SyncFeedChange], token: Data, moreComing: Bool) {
        self.changes = changes
        self.token = token
        self.moreComing = moreComing
    }

    public var records: [SyncServerRecord] {
        changes.compactMap { if case .record(let record) = $0 { return record } else { return nil } }
    }

    public var deletions: [SyncDeletion] {
        changes.compactMap { if case .deletion(let deletion) = $0 { return deletion } else { return nil } }
    }
}

/// What one modify operation may carry (CloudKit: 400 records, and a request size limit).
public struct SyncOperationLimits: Equatable, Sendable {
    public var maxRecords: Int
    /// Sum of the records' sizes (`SyncWireRecord.size`; assets don't count).
    public var maxBytes: Int

    public init(maxRecords: Int, maxBytes: Int) {
        self.maxRecords = maxRecords
        self.maxBytes = maxBytes
    }

    public static let unlimited = SyncOperationLimits(maxRecords: .max, maxBytes: .max)
}

/// What happened to one record of a save.
public struct SaveResult: Equatable, Sendable {
    public enum Outcome: Equatable, Sendable {
        /// Saved, with its new stamp.
        case saved(SyncServerStamp)
        /// Refused by `.ifServerRecordUnchanged` (`serverRecordChanged`): the server holds another version, or
        /// the save had no system fields for a record the server has. The server's record comes back.
        case changed(SyncServerRecord)
        /// Refused: the save named a version but the server has no such record (`unknownItem`).
        case deleted
        /// Refused: the record is over the server's size limit (`limitExceeded` for one record).
        case tooLarge(bytes: Int)
        /// Not saved because another record of an atomic operation failed (`batchRequestFailed`).
        case batchRequestFailed
        /// The record's zone doesn't exist on the server (`zoneNotFound`).
        case zoneNotFound
        /// Not saved this time, for a reason that passes (`zoneBusy`, `serviceUnavailable`): sent again later.
        case failed(String)
    }

    public var recordName: String
    public var outcome: Outcome
    /// For a passing failure (`.failed`): how long the server asked to wait before sending it again, if it said.
    public var retryAfter: TimeInterval?

    public init(recordName: String, outcome: Outcome, retryAfter: TimeInterval? = nil) {
        self.recordName = recordName
        self.outcome = outcome
        self.retryAfter = retryAfter
    }
}

public enum SyncTransportError: Error, Equatable {
    /// No connection, or the reply was lost (the operation may have been applied).
    case networkUnavailable
    /// The operation as a whole was too large (records or bytes): split it.
    case limitExceeded
    /// The change token is no longer valid: fetch the zone again from the start.
    case changeTokenExpired
    case zoneNotFound(String)
    case unreadableRecord(String)
    /// The service can't take the operation now (CloudKit: no network, a failed connection, the service
    /// unavailable or busy, rate limited): try again, not before `retryAfter` seconds when the server says.
    case unavailable(retryAfter: TimeInterval?)
    /// No iCloud account is signed in (CloudKit `notAuthenticated`): sync waits for the person, not for time.
    case notAuthenticated
    /// The iCloud storage is full (CloudKit `quotaExceeded`): sync waits for the person to make room.
    case quotaExceeded

    /// Passes with time: the operation is tried again later as it is.
    public var isPassing: Bool {
        switch self {
        case .networkUnavailable, .unavailable: return true
        case .limitExceeded, .changeTokenExpired, .zoneNotFound, .unreadableRecord, .notAuthenticated, .quotaExceeded: return false
        }
    }

    /// How long the server asked to wait before trying again, if it said.
    public var retryAfter: TimeInterval? {
        if case .unavailable(let seconds) = self { return seconds }
        return nil
    }
}

/// The cloud as the sync engine sees it (plan Task 5, ruling R11): shaped like `CKDatabase` operations
/// (`CKModifyRecordZonesOperation`, `CKModifyRecordsOperation`, `CKFetchRecordZoneChangesOperation`,
/// `CKFetchRecordsOperation`). `FakeCloud` implements it in memory; the CloudKit transport (App target,
/// Task 8) over `CKDatabase`. Records travel as `SyncWireRecord`s: every value in encrypted fields.
public protocol SyncTransport: Sendable {
    /// What one save operation may carry.
    func operationLimits() async -> SyncOperationLimits
    /// Creates the zone if it doesn't exist.
    func createZone(_ zone: String) async throws
    /// Saves records with `.ifServerRecordUnchanged`: `ifUnchanged` holds, by record name, the system fields
    /// of the version each record was last seen at; a record without them may only be created. `atomic`:
    /// all or nothing (CloudKit's default in custom zones). One result per record; throws
    /// `limitExceeded` when the operation as a whole is too large.
    func save(_ records: [SyncWireRecord], ifUnchanged: [String: Data], atomic: Bool) async throws -> [SaveResult]
    /// The zone's changes since `token` (nil: from the start), one page.
    func changes(since token: Data?, zone: String) async throws -> SyncChanges
    /// `changes`, without the contents of document files: a `documentFile` record comes with its name and type but not
    /// its `file` asset (`SyncFeedKeys.withoutDocumentFiles`). For readers that only judge records (the invite's audit,
    /// the orphan-file clean): reading the whole household that way doesn't download every document in it.
    func changesWithoutFiles(since token: Data?, zone: String) async throws -> SyncChanges
    /// Deletes records (unconditionally, like CloudKit; a record already gone is fine).
    func delete(_ recordNames: [String], zone: String) async throws
    /// One record, or nil when the server has none by that name.
    func fetch(_ recordName: String, zone: String) async throws -> SyncServerRecord?
    /// The server's clock now, where the transport can tell it.
    func serverTime() async throws -> Date?
}

extension SyncTransport {
    public func serverTime() async throws -> Date? { nil }
    /// A transport that can't leave file contents out reads them too.
    public func changesWithoutFiles(since token: Data?, zone: String) async throws -> SyncChanges {
        try await changes(since: token, zone: zone)
    }
}

/// The record keys a feed reads (`SyncTransport.changesWithoutFiles`).
public enum SyncFeedKeys {
    /// Every key this app writes but a document file's contents: the sealed fields, their key id and a large payload's
    /// asset (`FieldSealing`, `SyncLargePayload`). A key outside these isn't the app's and isn't read.
    public static let withoutDocumentFiles = [FieldSealing.sealedField, FieldSealing.keyIdField, SyncLargePayload.assetField]
}

// MARK: Wire records

/// A record as it is written to the server (sync spec §4.2): the record type, name and zone are the only
/// plaintext. What the engine sends is sealed (ruling R15, `FieldSealing`): exactly `sealed` and `keyId`. Built
/// from a payload (`init(_:)`), it is the *inner* record the seal holds: every synced value is a field
/// `f_<column>`; everything else the payload says (clocks, writers, batch tags, manifests…) is the field `meta`,
/// the payload itself encoded with its fields cleared, so no property can be left out. `assets` are asset fields
/// holding ciphertext the app sealed itself; they are saved with the record and don't count towards its size.
public struct SyncWireRecord: Equatable, Sendable {
    public var recordType: String
    public var recordName: String
    public var zone: String
    public var encryptedFields: [String: Data]
    /// Always empty for what BudgetCore builds; the fake records any it sees.
    public var unencryptedFields: [String: Data]
    public var assets: [String: Data]

    static let fieldPrefix = "f_"
    static let metaField = "meta"

    public init(recordType: String, recordName: String, zone: String, encryptedFields: [String: Data] = [:],
                unencryptedFields: [String: Data] = [:], assets: [String: Data] = [:]) {
        self.recordType = recordType
        self.recordName = recordName
        self.zone = zone
        self.encryptedFields = encryptedFields
        self.unencryptedFields = unencryptedFields
        self.assets = assets
    }

    public init(_ payload: SyncPayload) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var fields: [String: Data] = [:]
        for (column, value) in payload.fields { fields[Self.fieldPrefix + column] = try encoder.encode(value) }
        var meta = payload
        meta.fields = [:]
        // Only the receiving engine says who wrote (from the server), never the sender.
        meta.serverWriter = nil
        fields[Self.metaField] = try encoder.encode(meta)
        self.init(recordType: payload.recordType, recordName: payload.recordName, zone: payload.zone, encryptedFields: fields)
    }

    /// The payload the record holds (a large payload's stub as it is; `SyncLargePayload` opens it).
    public func payload() throws -> SyncPayload {
        let decoder = JSONDecoder()
        guard let meta = encryptedFields[Self.metaField] else { throw SyncTransportError.unreadableRecord(recordName) }
        var payload = try decoder.decode(SyncPayload.self, from: meta)
        guard payload.recordName == recordName, payload.recordType == recordType else { throw SyncTransportError.unreadableRecord(recordName) }
        payload.zone = zone
        for (key, data) in encryptedFields where key.hasPrefix(Self.fieldPrefix) {
            payload.fields[String(key.dropFirst(Self.fieldPrefix.count))] = try decoder.decode(SyncValue.self, from: data)
        }
        return payload
    }

    /// The record's size as the server counts it: names and field values; assets don't count.
    public var size: Int {
        let count = { (fields: [String: Data]) in fields.reduce(0) { $0 + $1.key.utf8.count + $1.value.count } }
        return [recordType, recordName, zone].map(\.utf8.count).reduce(0, +) + count(encryptedFields) + count(unencryptedFields)
    }
}
