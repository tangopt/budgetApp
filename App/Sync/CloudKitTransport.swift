import CloudKit
import Foundation
import os
import BudgetCore

/// `SyncTransport` over CloudKit (plan Task 8, ruling R11): `CKDatabase` operations, not `CKSyncEngine` — the
/// sync engine (`SyncEngineCore`) owns the change tokens, the batching and the order.
///
/// - Saves: `CKModifyRecordsOperation` with `.ifServerRecordUnchanged`, each record rebuilt on the archived
///   system fields of the version last seen (none: create only), keys that version had and this record doesn't
///   cleared, `isAtomic` as asked; one result per record (`CloudKitRecordMapping.saveResult`, assembled by
///   `CloudKitSaveAssembly`).
/// - Changes: `CKFetchRecordZoneChangesOperation`, one page per call (`fetchAllChanges = false`), records and
///   deletions in the order CloudKit reports them, the server change token archived as `Data`. A record's own
///   failure stays that record's (`CloudKitRecordMapping.feedChange`); only a passing one fails the page.
/// - Records arrive already sealed by the engine (ruling R15: `sealed` + `keyId`); every value goes in
///   `encryptedValues` as a second layer (`CloudKitRecordMapping.record`); assets are `CKAsset`s written to this
///   instance's temporary folder, one subfolder per operation, removed when it finishes.
/// - Errors: `CloudKitRecordMapping.operationError` (no network, busy, rate limited → `unavailable` with the
///   server's retry-after; `limitExceeded`, `changeTokenExpired`, `zoneNotFound`, `notAuthenticated`,
///   `quotaExceeded`). A cancelled task cancels its operation.
/// - Feed pages fetch every key (`desiredKeys` nil), so `documentFile` assets download with each page although
///   the engine reads them only through `fetch` (fix round 1, M9). Not narrowed: `SyncTransport.changes` has no
///   lazy flag, and `desiredKeys` is an allow-list — leaving out `file` means naming every other key, which would
///   silently drop the fields a newer build adds. A future iOS step can move file records to their own zone or
///   give the protocol a "without file assets" page.
///
/// Build step 3: the household zone in the admin's **private** database. Not reachable from the UI: only the
/// DEBUG `--sync-demo` launch argument with a demo database makes one (`SyncDemoMode`).
final class CloudKitTransport: SyncTransport {
    static let containerIdentifier = "iCloud.ubberninja.mango"
    private static let log = Logger(subsystem: "com.personal.budget", category: "Sync")

    private let database: CKDatabase
    /// This instance's folder for asset files waiting for an upload (one subfolder per operation). Other
    /// instances' folders are never touched unless a day old.
    private let assetFolder: URL

    init(database: CKDatabase = CKContainer(identifier: CloudKitTransport.containerIdentifier).privateCloudDatabase,
         assetRoot: URL = FileManager.default.temporaryDirectory.appendingPathComponent("MangoSyncAssets", isDirectory: true),
         now: Date = Date()) {
        self.database = database
        assetFolder = assetRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        CloudKitAssetFolders.sweepStale(in: assetRoot, now: now)
    }

    deinit { try? FileManager.default.removeItem(at: assetFolder) }

    func operationLimits() async -> SyncOperationLimits { CloudKitRecordMapping.operationLimits }

    func createZone(_ zone: String) async throws {
        let operation = CKModifyRecordZonesOperation(recordZonesToSave: [CKRecordZone(zoneID: CloudKitRecordMapping.zoneID(zone))],
                                                     recordZoneIDsToDelete: nil)
        try await run(operation, zone: zone, perRecordResults: false) { finish in
            operation.modifyRecordZonesResultBlock = { result in finish(result) }
        }
    }

    func save(_ records: [SyncWireRecord], ifUnchanged: [String: Data], atomic: Bool) async throws -> [SaveResult] {
        guard !records.isEmpty else { return [] }
        let folder = assetFolder.appendingPathComponent(UUID().uuidString, isDirectory: true)
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
        if let results = CloudKitSaveAssembly.resultsWithoutSending(records, refused: refused, atomic: atomic) { return results }
        let wires = Dictionary(records.map { ($0.recordName, $0) }, uniquingKeysWith: { _, last in last })
        let operation = CKModifyRecordsOperation(recordsToSave: built, recordIDsToDelete: nil)
        operation.savePolicy = .ifServerRecordUnchanged
        operation.isAtomic = atomic
        let taken = OSAllocatedUnfairLock(initialState: [String: SaveResult]())
        try await run(operation, zone: records[0].zone, perRecordResults: true) { finish in
            operation.perRecordSaveBlock = { id, result in
                guard let wire = wires[id.recordName] else { return }
                let saved = CloudKitRecordMapping.saveResult(wire, result)
                taken.withLock { $0[id.recordName] = saved }
            }
            operation.modifyRecordsResultBlock = { result in finish(result) }
        }
        return CloudKitSaveAssembly.results(records, refused: refused, taken: taken.withLock { $0 })
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
            /// The page's failure: a passing per-record one, or the zone's (any error, as mapped).
            var failure: Error?
        }
        let page = OSAllocatedUnfairLock(initialState: Page())
        try await run(operation, zone: zone, perRecordResults: true) { finish in
            operation.recordWasChangedBlock = { id, result in
                switch CloudKitRecordMapping.feedChange(id, result, zone: zone) {
                case .change(let change): page.withLock { $0.changes.append(change) }
                case .failPage(let error): page.withLock { $0.failure = $0.failure ?? error }
                }
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
                    let mapped = CloudKitRecordMapping.operationError(error, zone: zone)
                    page.withLock { $0.failure = mapped }
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
        try await run(operation, zone: zone, perRecordResults: true) { finish in
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
        try await run(operation, zone: zone, perRecordResults: true) { finish in
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

    /// Adds `operation` to the database and waits for its final block; cancelling the task cancels the operation.
    /// `configure` sets the blocks and hands the final one to `finish`. The final error is mapped
    /// (`CloudKitRecordMapping.finalError`: with per-record results a `partialFailure` is theirs, not the call's).
    private func run(_ operation: CKDatabaseOperation, zone: String, perRecordResults: Bool,
                     configure: (@escaping @Sendable (Result<Void, Error>) -> Void) -> Void) async throws {
        operation.qualityOfService = .utility
        // A task already cancelled never adds the operation: CloudKit isn't guaranteed to call the final block of an
        // operation cancelled before it was added, which would leave the continuation waiting (final review M2).
        // Note: `SyncEngineCore.serialized` runs each entry point in its own unstructured Task, so a caller's
        // cancellation doesn't reach the transport today; this matters for direct callers and a later scheduler.
        try Task.checkCancellation()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                configure { result in
                    switch result {
                    case .success:
                        continuation.resume()
                    case .failure(let error):
                        if let mapped = CloudKitRecordMapping.finalError(error, zone: zone, perRecordResults: perRecordResults) {
                            Self.log.error("Sync CloudKit operation failed: \(String(describing: mapped), privacy: .public)")
                            continuation.resume(throwing: mapped)
                        } else {
                            continuation.resume()
                        }
                    }
                }
                database.add(operation)
            }
        } onCancel: {
            operation.cancel()
        }
    }
}
