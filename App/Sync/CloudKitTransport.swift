import CloudKit
import Foundation
import os
import BudgetCore

/// `SyncTransport` over CloudKit (plan Task 8, ruling R11): `CKDatabase` operations, not `CKSyncEngine` — the
/// sync engine (`SyncEngineCore`) owns the change tokens, the batching and the order.
///
/// - Saves: `CKModifyRecordsOperation` with `.ifServerRecordUnchanged`, each record rebuilt on the archived
///   system fields of the version last seen (none: create only), `isAtomic` as asked; one result per record,
///   mapped by `CloudKitRecordMapping.saveOutcome`.
/// - Changes: `CKFetchRecordZoneChangesOperation`, one page per call (`fetchAllChanges = false`), records and
///   deletions in the order CloudKit reports them, the server change token archived as `Data`.
/// - Every value goes in `encryptedValues` (`CloudKitRecordMapping.record`); assets are `CKAsset`s written to a
///   temporary folder per operation and removed when it finishes.
/// - Errors: `CloudKitRecordMapping.operationError` (no network, busy, rate limited → `unavailable` with the
///   server's retry-after; `limitExceeded`, `changeTokenExpired`, `zoneNotFound`).
///
/// Build step 3: the household zone in the admin's **private** database. Not reachable from the UI: only the
/// DEBUG `--sync-demo` launch argument with a demo database makes one (`SyncDemoMode`).
final class CloudKitTransport: SyncTransport {
    static let containerIdentifier = "iCloud.ubberninja.mango"

    private static let log = Logger(subsystem: "com.personal.budget", category: "Sync")

    private let database: CKDatabase
    /// Where asset files wait for an upload: one folder per operation, removed when it ends.
    private let assetRoot: URL

    init(database: CKDatabase = CKContainer(identifier: CloudKitTransport.containerIdentifier).privateCloudDatabase,
         assetRoot: URL = FileManager.default.temporaryDirectory.appendingPathComponent("MangoSyncAssets", isDirectory: true)) {
        self.database = database
        self.assetRoot = assetRoot
        // Folders a crash left behind (ciphertext only, but not kept).
        try? FileManager.default.removeItem(at: assetRoot)
    }

    func operationLimits() async -> SyncOperationLimits { CloudKitRecordMapping.operationLimits }

    func createZone(_ zone: String) async throws {
        let operation = CKModifyRecordZonesOperation(recordZonesToSave: [CKRecordZone(zoneID: CloudKitRecordMapping.zoneID(zone))],
                                                     recordZoneIDsToDelete: nil)
        try await run(operation, zone: zone) { finish in
            operation.modifyRecordZonesResultBlock = { result in finish(result) }
        }
    }

    func save(_ records: [SyncWireRecord], ifUnchanged: [String: Data], atomic: Bool) async throws -> [SaveResult] {
        guard !records.isEmpty else { return [] }
        let folder = assetRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        var built: [CKRecord] = []
        var refused: [String: SaveResult.Outcome] = [:]
        for wire in records {
            do {
                built.append(try CloudKitRecordMapping.record(from: wire, systemFields: ifUnchanged[wire.recordName], assetDirectory: folder))
            } catch {
                Self.log.error("Sync record not sent: \(String(describing: error), privacy: .public)")
                refused[wire.recordName] = .failed("not sent: \(error)")
            }
        }
        if !refused.isEmpty, atomic || built.isEmpty {
            // All or nothing: one record that can't be built fails the operation before anything is sent.
            return records.map { SaveResult(recordName: $0.recordName, outcome: refused[$0.recordName] ?? .batchRequestFailed) }
        }
        let wires = Dictionary(records.map { ($0.recordName, $0) }, uniquingKeysWith: { _, last in last })
        let operation = CKModifyRecordsOperation(recordsToSave: built, recordIDsToDelete: nil)
        operation.savePolicy = .ifServerRecordUnchanged
        operation.isAtomic = atomic
        let outcomes = OSAllocatedUnfairLock(initialState: [String: SaveResult.Outcome]())
        let zone = records[0].zone
        try await run(operation, zone: zone, partialFailureIsPerRecord: true) { finish in
            operation.perRecordSaveBlock = { id, result in
                let name = id.recordName
                let outcome: SaveResult.Outcome
                switch result {
                case .success(let record): outcome = .saved(CloudKitRecordMapping.stamp(of: record))
                case .failure(let error):
                    outcome = wires[name].map { CloudKitRecordMapping.saveOutcome(for: error, wire: $0) } ?? .failed("unknown record")
                }
                outcomes.withLock { $0[name] = outcome }
            }
            operation.modifyRecordsResultBlock = { result in finish(result) }
        }
        let taken = outcomes.withLock { $0 }
        return records.map { wire in
            SaveResult(recordName: wire.recordName, outcome: refused[wire.recordName] ?? taken[wire.recordName] ?? .failed("no result"))
        }
    }

    func changes(since token: Data?, zone: String) async throws -> SyncChanges {
        let zoneID = CloudKitRecordMapping.zoneID(zone)
        let configuration = CKFetchRecordZoneChangesOperation.ZoneConfiguration()
        configuration.previousServerChangeToken = try token.map(CloudKitRecordMapping.unarchiveToken)
        let operation = CKFetchRecordZoneChangesOperation(recordZoneIDs: [zoneID], configurationsByRecordZoneID: [zoneID: configuration])
        operation.fetchAllChanges = false
        struct Page: Sendable {
            var changes: [SyncFeedChange] = []
            var token: Data?
            var moreComing = false
            var failure: SyncTransportError?
        }
        let page = OSAllocatedUnfairLock(initialState: Page())
        try await run(operation, zone: zone) { finish in
            operation.recordWasChangedBlock = { id, result in
                let change: SyncFeedChange
                switch result {
                case .success(let record):
                    do {
                        change = .record(try CloudKitRecordMapping.serverRecord(record))
                    } catch {
                        change = .record(Self.unreadable(id))
                    }
                case .failure(let error):
                    // A passing failure fails the page (fetched again from the same token); any other leaves
                    // the record staged as unreadable rather than blocking the zone.
                    if let mapped = CloudKitRecordMapping.operationError(error, zone: zone) as? SyncTransportError, mapped.isPassing {
                        page.withLock { $0.failure = $0.failure ?? mapped }
                        return
                    }
                    change = .record(Self.unreadable(id))
                }
                page.withLock { $0.changes.append(change) }
            }
            operation.recordWithIDWasDeletedBlock = { id, recordType in
                page.withLock { $0.changes.append(.deletion(SyncDeletion(recordName: id.recordName, recordType: recordType))) }
            }
            operation.recordZoneFetchResultBlock = { _, result in
                switch result {
                case .success(let (serverToken, _, moreComing)):
                    let archived = try? CloudKitRecordMapping.archiveToken(serverToken)
                    page.withLock {
                        $0.token = archived
                        $0.moreComing = moreComing
                    }
                case .failure(let error):
                    let mapped = CloudKitRecordMapping.operationError(error, zone: zone) as? SyncTransportError
                    page.withLock { $0.failure = mapped ?? .unavailable(retryAfter: nil) }
                }
            }
            operation.fetchRecordZoneChangesResultBlock = { result in finish(result) }
        }
        let fetched = page.withLock { $0 }
        if let failure = fetched.failure { throw failure }
        guard let next = fetched.token else { throw SyncTransportError.unavailable(retryAfter: nil) }
        return SyncChanges(changes: fetched.changes, token: next, moreComing: fetched.moreComing)
    }

    func delete(_ recordNames: [String], zone: String) async throws {
        guard !recordNames.isEmpty else { return }
        let operation = CKModifyRecordsOperation(recordsToSave: nil,
                                                 recordIDsToDelete: recordNames.map { CloudKitRecordMapping.recordID($0, zone: zone) })
        operation.isAtomic = false
        let failure = OSAllocatedUnfairLock<Error?>(initialState: nil)
        try await run(operation, zone: zone, partialFailureIsPerRecord: true) { finish in
            operation.perRecordDeleteBlock = { _, result in
                guard case .failure(let error) = result else { return }
                // Already gone (the record, or its zone): fine, like CloudKit's own unconditional delete.
                if let code = (error as? CKError)?.code, [.unknownItem, .zoneNotFound, .userDeletedZone].contains(code) { return }
                let mapped = CloudKitRecordMapping.operationError(error, zone: zone)
                failure.withLock { $0 = $0 ?? mapped }
            }
            operation.modifyRecordsResultBlock = { result in finish(result) }
        }
        if let error = failure.withLock({ $0 }) { throw error }
    }

    func fetch(_ recordName: String, zone: String) async throws -> SyncServerRecord? {
        let id = CloudKitRecordMapping.recordID(recordName, zone: zone)
        let operation = CKFetchRecordsOperation(recordIDs: [id])
        let fetched = OSAllocatedUnfairLock<Result<SyncServerRecord?, Error>?>(initialState: nil)
        try await run(operation, zone: zone, partialFailureIsPerRecord: true) { finish in
            operation.perRecordResultBlock = { _, result in
                let value: Result<SyncServerRecord?, Error>
                switch result {
                case .success(let record):
                    value = Result { try CloudKitRecordMapping.serverRecord(record) }
                case .failure(let error) where CloudKitRecordMapping.isMissingRecord(error):
                    value = .success(nil)
                case .failure(let error):
                    value = .failure(CloudKitRecordMapping.operationError(error, zone: zone))
                }
                fetched.withLock { $0 = value }
            }
            operation.fetchRecordsResultBlock = { result in finish(result) }
        }
        return try fetched.withLock({ $0 })?.get() ?? nil
    }

    // MARK: Running operations

    /// Adds `operation` to the database and waits for its final block. `configure` sets the blocks and hands
    /// the final one to `finish`. A whole-operation error is mapped (`partialFailure` is left to the per-record
    /// blocks where they carry the results).
    private func run(_ operation: CKDatabaseOperation, zone: String, partialFailureIsPerRecord: Bool = false,
                     configure: (@escaping @Sendable (Result<Void, Error>) -> Void) -> Void) async throws {
        operation.qualityOfService = .utility
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            configure { result in
                switch result {
                case .success:
                    continuation.resume()
                case .failure(let error):
                    if partialFailureIsPerRecord, (error as? CKError)?.code == .partialFailure {
                        continuation.resume()
                    } else {
                        let mapped = CloudKitRecordMapping.operationError(error, zone: zone)
                        Self.log.error("Sync CloudKit operation failed: \(String(describing: mapped), privacy: .public)")
                        continuation.resume(throwing: mapped)
                    }
                }
            }
            database.add(operation)
        }
    }

    /// A record the feed named but that couldn't be read: no payload, so the engine stages it as unreadable.
    private static func unreadable(_ id: CKRecord.ID) -> SyncServerRecord {
        SyncServerRecord(wire: SyncWireRecord(recordType: "", recordName: id.recordName, zone: id.zoneID.zoneName),
                         stamp: SyncServerStamp(systemFields: Data(), changeTag: "", modifiedAt: .distantPast))
    }
}
