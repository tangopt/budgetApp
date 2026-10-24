#if DEBUG
import Foundation
import os
import Security
import BudgetCore
import MangoSync

/// The one way to reach `CloudKitTransport` in build step 3 (plan Global Constraints): a DEBUG build launched
/// with `--sync-demo` and `BUDGET_DB_PATH` naming the demo database (`DemoMarker`). Anything else with the
/// argument refuses to start, with the reason; without the argument nothing here runs. It syncs once after
/// the database has loaded (development container) and logs the counts — for the user-attended step 4
/// kick-off, never run by tests or tools. Records go sealed under the household key, which it keeps in iCloud
/// Keychain (`KeychainSyncKeyStore`, ruling R15).
enum SyncDemoMode {
    static let argument = SyncActivation.demoArgument
    private static let log = Logger(subsystem: "com.personal.budget", category: "Sync")

    static var isRequested: Bool { CommandLine.arguments.contains(argument) }

    /// Why the launch can't sync the demo, or nil when it may: the rules are BudgetCore's (`SyncActivation`), so
    /// the iPhone applies the same ones.
    static func refusal(environment: [String: String] = ProcessInfo.processInfo.environment,
                        arguments: [String] = CommandLine.arguments) -> String? {
        let decision = SyncActivation.decision(databasePath: environment["BUDGET_DB_PATH"], arguments: arguments,
                                               isDebug: true, hasCloudKitEntitlement: hasCloudKitEntitlement())
        return decision.allowed ? nil : decision.reason
    }

    /// Whether this process is signed with the iCloud container entitlement for Mango's container.
    static func hasCloudKitEntitlement() -> Bool {
        guard let task = SecTaskCreateFromSelf(nil),
              let value = SecTaskCopyValueForEntitlement(task, "com.apple.developer.icloud-container-identifiers" as CFString, nil),
              let containers = value as? [String] else { return false }
        return containers.contains(CloudKitTransport.containerIdentifier)
    }

    /// Called first thing at launch: a refused `--sync-demo` stops here, before any database is opened.
    static func checkOrExit() {
        guard isRequested else { return }
        if let refusal = refusal() {
            FileHandle.standardError.write(Data("Mango: \(refusal)\n".utf8))
            exit(2)
        }
    }

    /// Syncs the loaded demo database once through CloudKit (checked again: never another database).
    @MainActor
    static func start(_ environment: AppEnvironment) {
        guard isRequested, refusal() == nil, let path = environment.databasePath,
              TaxRegression.resolvedPath(path) == TaxRegression.resolvedPath(ProcessInfo.processInfo.environment["BUDGET_DB_PATH"] ?? "") else { return }
        let dbQueue = environment.dbQueue
        let root = environment.evidenceRoot
        Task.detached {
            do {
                let assigned = try await dbQueue.write { db in try SyncRecordStore.backfill(db: db) }
                let engine = SyncEngineCore(db: dbQueue, transport: CloudKitTransport(),
                                            device: SyncDevice(id: "sync-demo-mac", name: "Demo Mac"),
                                            // Ruling R15: the household key in iCloud Keychain, never in CloudKit.
                                            keyStore: KeychainSyncKeyStore(),
                                            documents: SyncDocumentFiles(root: root, policy: .eager))
                let report = try await engine.syncNow()
                log.info("Sync demo: backfilled \(assigned) · received \(report.pull.received) · saved \(report.push.saved) · refused \(report.push.refused) · files \(report.push.documentsSealed)")
            } catch {
                log.error("Sync demo failed: \(String(describing: error), privacy: .public)")
            }
        }
    }
}
#endif
