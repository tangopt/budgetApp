import Foundation

/// `LeaseStore` over `SyncTransport` (sync spec §5.2): the lease is one `importLease` record in the zone,
/// written only with `.ifServerRecordUnchanged`. Releasing saves it empty (CloudKit deletes aren't
/// compare-and-set). The server's modification time and clock decide expiry where the transport knows
/// them. A lost compare-and-set is `LeaseStoreError.changed`; anything that passes (no connection, a
/// busy zone) is `.unavailable`.
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
        let server: SyncServerRecord?
        do {
            server = try await transport.fetch(Self.recordName, zone: zone)
        } catch SyncTransportError.zoneNotFound {
            return nil
        } catch let error as SyncTransportError {
            throw LeaseStoreError.unavailable("\(error)")
        }
        guard let server else { return nil }
        let fields = try server.wire.payload().fields
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
        let results: [SaveResult]
        do {
            results = try await transport.save([try SyncWireRecord(payload)], ifUnchanged: systemFields.map { [Self.recordName: $0] } ?? [:],
                                               atomic: false)
        } catch let error as SyncTransportError {
            throw LeaseStoreError.unavailable("\(error)")
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
            throw LeaseStoreError.unavailable("\(error)")
        }
    }

    /// The lease's tag is its system fields (what a save against it needs), base64.
    private static func encode(_ stamp: SyncServerStamp) -> String { stamp.systemFields.base64EncodedString() }
}
