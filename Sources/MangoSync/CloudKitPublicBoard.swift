import CloudKit
import Foundation
import BudgetCore

/// `SyncPublicBoard` over the container's public database (step 7a Task 8): the member's key request
/// (`SyncKeyExchange`). The public database has no encrypted fields, so values are plain `Data` fields; only what
/// isn't secret goes here (a request id, a commitment, a public key and a nonce). Records live in its default zone;
/// CloudKit's default security roles apply (signed-in users create, everyone reads, only the creator writes or
/// deletes). Records are fetched by name only, so no query index is needed. Kept apart from `CloudKitTransport`, whose
/// mapping refuses every plain field.
///
/// Compile-checked only: the real exchange is run with the user present (plan, controller-only steps). The
/// `keyRequest` record type must exist in the Production schema with plain `Bytes` fields `requestId`, `commitment`,
/// `publicKey` and `nonce`.
public final class CloudKitPublicBoard: SyncPublicBoard {
    private let container: CKContainer
    private let database: CKDatabase

    public init(container: CKContainer = CKContainer(identifier: CloudKitTransport.containerIdentifier)) {
        self.container = container
        database = container.publicCloudDatabase
    }

    private func recordID(_ name: String) -> CKRecord.ID { CKRecord.ID(recordName: name, zoneID: .default) }

    /// Saves over any version (`.allKeys`): only the creator's save is allowed by the security roles.
    public func postPublic(_ record: SyncPublicRecord) async throws {
        let built = CKRecord(recordType: record.recordType, recordID: recordID(record.recordName))
        for (key, value) in record.fields { built[key] = value as NSData }
        do {
            let (saved, _) = try await database.modifyRecords(saving: [built], deleting: [], savePolicy: .allKeys, atomically: false)
            if case .failure(let error) = saved[built.recordID] { throw error }
        } catch {
            throw CloudKitRecordMapping.operationError(error, zone: CKRecordZone.ID.default.zoneName)
        }
    }

    public func fetchPublic(_ recordName: String) async throws -> SyncPublicRecord? {
        let record: CKRecord
        do {
            record = try await database.record(for: recordID(recordName))
        } catch where CloudKitRecordMapping.isMissingRecord(error) {
            return nil
        } catch {
            throw CloudKitRecordMapping.operationError(error, zone: CKRecordZone.ID.default.zoneName)
        }
        var fields: [String: Data] = [:]
        for key in record.allKeys() {
            if let data = record[key] as? Data { fields[key] = data }
        }
        let me = try? await container.userRecordID().recordName
        return SyncPublicRecord(recordType: record.recordType, recordName: recordName, fields: fields,
                                lastModifiedBy: CloudKitRecordMapping.writer(of: record, currentUser: me), modifiedAt: record.modificationDate)
    }

    public func deletePublic(_ recordName: String) async throws {
        do {
            let (_, deleted) = try await database.modifyRecords(saving: [], deleting: [recordID(recordName)], atomically: false)
            if case .failure(let error) = deleted[recordID(recordName)], !CloudKitRecordMapping.isMissingRecord(error) { throw error }
        } catch where CloudKitRecordMapping.isMissingRecord(error) {
            return
        } catch {
            throw CloudKitRecordMapping.operationError(error, zone: CKRecordZone.ID.default.zoneName)
        }
    }
}
