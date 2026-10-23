import CryptoKit
import Foundation

/// `LeaseStore` over `SyncTransport` (sync spec §5.2): the lease is one `importLease` record in the zone,
/// written only with `.ifServerRecordUnchanged`. Releasing saves it empty (CloudKit deletes aren't
/// compare-and-set). The server's modification time and clock decide expiry where the transport knows
/// them. A lost compare-and-set is `LeaseStoreError.changed`; anything that passes (no connection, a
/// busy zone) is `.unavailable`.
///
/// Ruling R15: the record names a device, so it is sealed like every record (`FieldSealing`), under the zone key
/// `sealingKey`; it is read with any key in `keys`. Without the key a lease can't be written here, and one sealed
/// under a key not held here can't be read: both are `.unavailable` (the device waits for the household key).
public struct TransportLeaseStore: LeaseStore {
    public static let recordType = "importLease"
    public static let recordName = "importLease"

    private let transport: any SyncTransport
    private let zone: String
    private let sealingKey: SymmetricKey?
    private let keys: [String: SymmetricKey]

    public init(transport: any SyncTransport, zone: String = SyncRecordStore.householdZone, sealingKey: SymmetricKey?,
                keys: [String: SymmetricKey]) {
        self.transport = transport
        self.zone = zone
        self.sealingKey = sealingKey
        self.keys = keys
    }

    public func currentLease() async throws -> StoredLease? {
        let server: SyncServerRecord?
        do {
            server = try await transport.fetch(Self.recordName, zone: zone)
        } catch SyncTransportError.zoneNotFound {
            return nil
        } catch let error as SyncTransportError {
            throw Self.leaseError(error)
        }
        guard let server else { return nil }
        let fields: [String: SyncValue]
        do {
            fields = try SyncLargePayload.payload(from: server.wire, keys: keys).fields
        } catch FieldSealing.SealingError.keyMissing {
            throw LeaseStoreError.unavailable("the lease is sealed under a household key not held here yet")
        }
        func string(_ key: String) -> String { if case .string(let value) = fields[key] { return value } else { return "" } }
        func date(_ key: String) -> Date { if case .date(let value) = fields[key] { return value } else { return .distantPast } }
        let record = ImportLeaseRecord(holderId: string("holderId"), holderName: string("holderName"),
                                       takenAt: date("takenAt"), expiresAt: date("expiresAt"))
        return StoredLease(record: record, tag: Self.encode(server.stamp), serverModifiedAt: server.stamp.modifiedAt)
    }

    public func saveLease(_ record: ImportLeaseRecord, ifTag tag: String?) async throws -> StoredLease {
        let payload = SyncPayload(recordType: Self.recordType, recordName: Self.recordName, zone: zone, fields: [
            "holderId": .string(record.holderId), "holderName": .string(record.holderName),
            "takenAt": .date(record.takenAt), "expiresAt": .date(record.expiresAt),
        ])
        let systemFields = tag.flatMap { Data(base64Encoded: $0) }
        guard let sealingKey else { throw LeaseStoreError.unavailable("no household key here yet") }
        let (wire, _) = try SyncLargePayload.wire(for: payload, key: sealingKey)
        let results: [SaveResult]
        do {
            results = try await transport.save([wire], ifUnchanged: systemFields.map { [Self.recordName: $0] } ?? [:],
                                               atomic: false)
        } catch let error as SyncTransportError {
            throw Self.leaseError(error)
        }
        switch results.first?.outcome {
        case .saved(let stamp):
            return StoredLease(record: record, tag: Self.encode(stamp), serverModifiedAt: stamp.modifiedAt)
        case .changed, .deleted:
            throw LeaseStoreError.changed
        case .tooLarge, .batchRequestFailed, .zoneNotFound, .failed, nil:
            throw LeaseStoreError.unavailable("\(String(describing: results.first?.outcome))")
        }
    }

    public func deleteLease(ifTag tag: String) async throws {
        _ = try await saveLease(ImportLeaseRecord(holderId: "", holderName: "", takenAt: .distantPast, expiresAt: .distantPast), ifTag: tag)
    }

    public func serverTime() async throws -> Date? {
        do {
            return try await transport.serverTime()
        } catch let error as SyncTransportError {
            throw Self.leaseError(error)
        }
    }

    /// What a transport failure means for the lease: signed out of iCloud or out of space reaches the caller as
    /// it is (it needs the person, final review M3); anything else passes with time (`unavailable`).
    static func leaseError(_ error: SyncTransportError) -> Error {
        switch error {
        case .notAuthenticated, .quotaExceeded: return error
        default: return LeaseStoreError.unavailable("\(error)")
        }
    }

    /// The lease's tag is its system fields (what a save against it needs), base64.
    private static func encode(_ stamp: SyncServerStamp) -> String { stamp.systemFields.base64EncodedString() }
}
