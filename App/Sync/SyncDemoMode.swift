#if DEBUG
import Foundation
import GRDB
import os
import Security
import BudgetCore
import MangoSync

/// The one way the Mac reaches `CloudKitTransport` in build step 4 (plan Global Constraints): a DEBUG build launched
/// with `--sync-demo` and `BUDGET_DB_PATH` naming the demo database (`DemoMarker`), as `SyncActivation` decides.
/// Anything else with a demo argument refuses to start, with the reason; without one nothing here runs and sync
/// stays `.off`. For the user-attended runs (Task 15), never run by tests or tools.
///
/// - `--sync-demo`: a `SyncScheduler` around `SyncEngineCore` (Development container), started once the database
///   has loaded; it syncs at launch, then on its own schedule and on Settings ▸ Sync's "Sync now". Each status
///   change is logged (no data in the lines) and published to Settings ▸ Sync. Records go sealed under the
///   household key, kept in iCloud Keychain under the **demo** scope (`CloudKitTransport.demoKeyScope`), never
///   the real data's.
/// - `--sync-demo --print-demo-key`: as `--sync-demo`, and once the launch sync has put the key's marker on the
///   server, the demo household key goes to stderr as 64 hex (the simulator's `MANGO_DEMO_HOUSEHOLD_KEY`). Demo
///   scope only.
/// - `--sync-demo --sync-demo-reset`: deletes the demo zone, removes the key the earlier demo runs kept under the
///   real scope, forgets the zone in the demo database (`SyncDemoReset`), and exits. Nothing else runs.
enum SyncDemoMode {
    static let argument = SyncActivation.demoArgument
    private static let log = Logger(subsystem: "com.personal.budget", category: "Sync")

    static var isRequested: Bool { CommandLine.arguments.contains(argument) }
    private static var asksForDemoTool: Bool {
        CommandLine.arguments.contains(SyncDemoReset.resetArgument) || CommandLine.arguments.contains(SyncDemoReset.printKeyArgument)
    }
    static var isResetRequested: Bool { CommandLine.arguments.contains(SyncDemoReset.resetArgument) }
    static var isPrintKeyRequested: Bool { CommandLine.arguments.contains(SyncDemoReset.printKeyArgument) }

    /// Why the launch can't sync the demo (or run a demo tool), or nil when it may: the rules are BudgetCore's
    /// (`SyncActivation.decision`, then `SyncDemoReset.refusal` for the tools), so the iPhone applies the same ones.
    static func refusal(environment: [String: String] = ProcessInfo.processInfo.environment,
                        arguments: [String] = CommandLine.arguments) -> String? {
        let decision = SyncActivation.decision(databasePath: environment["BUDGET_DB_PATH"], arguments: arguments,
                                               isDebug: true, hasCloudKitEntitlement: hasCloudKitEntitlement())
        if let tool = SyncDemoReset.refusal(arguments: arguments, decision: decision) { return tool }
        return decision.allowed ? nil : decision.reason
    }

    /// Whether this process is signed with the iCloud container entitlement for Mango's container.
    static func hasCloudKitEntitlement() -> Bool {
        guard let task = SecTaskCreateFromSelf(nil),
              let value = SecTaskCopyValueForEntitlement(task, "com.apple.developer.icloud-container-identifiers" as CFString, nil),
              let containers = value as? [String] else { return false }
        return containers.contains(CloudKitTransport.containerIdentifier)
    }

    /// Called first thing at launch: a refused demo launch stops here, before any database is opened.
    static func checkOrExit() {
        guard isRequested || asksForDemoTool else { return }
        if let refusal = refusal() {
            FileHandle.standardError.write(Data("Mango: \(refusal)\n".utf8))
            exit(2)
        }
    }

    @MainActor private static var started = false

    /// Starts the demo once the demo database has loaded (checked again: never another database).
    @MainActor
    static func start(_ environment: AppEnvironment) {
        guard isRequested, !started, refusal() == nil, let path = environment.databasePath,
              TaxRegression.resolvedPath(path) == TaxRegression.resolvedPath(ProcessInfo.processInfo.environment["BUDGET_DB_PATH"] ?? "") else { return }
        started = true
        if isResetRequested {
            reset(environment)
            return
        }
        let dbQueue = environment.dbQueue
        // Ruling R15: the household key in iCloud Keychain, never in CloudKit — under the demo scope.
        let keyStore = KeychainSyncKeyStore(container: CloudKitTransport.keyScope(demo: true))
        let engine = SyncEngineCore(db: dbQueue, transport: CloudKitTransport(),
                                    device: SyncDevice(id: "sync-demo-mac", name: "Demo Mac"),
                                    keyStore: keyStore,
                                    documents: SyncDocumentFiles(root: environment.evidenceRoot, policy: .eager))
        let scheduler = SyncScheduler(engine: engine, db: dbQueue)
        environment.syncScheduler = scheduler
        Task { @MainActor [weak environment] in
            for await status in await scheduler.statusStream() {
                log.info("Sync demo status: \(describe(status), privacy: .public)")
                environment?.syncStatus = status
            }
        }
        let printKey = isPrintKeyRequested
        Task { @MainActor [weak environment] in
            do {
                let assigned = try await dbQueue.write { db in try SyncRecordStore.backfill(db: db) }
                log.info("Sync demo: backfilled \(assigned)")
                await scheduler.start()
                let report = try await scheduler.syncNowAndWait()
                environment?.syncLastReport = report
                log.info("Sync demo: received \(report.pull.received) · saved \(report.push.saved) · refused \(report.push.refused) · files \(report.push.documentsSealed)")
                if printKey { printDemoKey(dbQueue: dbQueue, keyStore: keyStore) }
            } catch {
                log.error("Sync demo launch sync didn't finish: \(String(describing: type(of: error)), privacy: .public) \(String(describing: error), privacy: .private)")
                if printKey { printDemoKey(dbQueue: dbQueue, keyStore: keyStore) }
            }
        }
    }

    /// `--print-demo-key`: the demo-scope key the server's marker names, once it is there; never another scope's.
    private static func printDemoKey(dbQueue: some DatabaseReader, keyStore: KeychainSyncKeyStore) {
        guard keyStore.scope == CloudKitTransport.demoKeyScope else {
            FileHandle.standardError.write(Data("Mango: \(SyncDemoReset.printKeyArgument) prints only the demo scope's key; nothing printed.\n".utf8))
            return
        }
        do {
            if let hex = try DemoHouseholdKey.confirmedKeyHex(db: dbQueue, keyStore: keyStore) {
                FileHandle.standardError.write(Data("\(DemoHouseholdKey.environmentVariable)=\(hex)\n".utf8))
            } else {
                FileHandle.standardError.write(Data("Mango: no demo household key to print yet: the launch sync hasn't put its marker on the server.\n".utf8))
            }
        } catch {
            FileHandle.standardError.write(Data("Mango: the demo household key couldn't be read (\(String(describing: type(of: error)))).\n".utf8))
        }
    }

    /// `--sync-demo-reset`: the Development zone, the real scope's leftover demo key and this database's sync state
    /// for the zone, then exit (0 when done, 1 when the zone couldn't be deleted).
    @MainActor
    private static func reset(_ environment: AppEnvironment) {
        let dbQueue = environment.dbQueue
        Task.detached {
            let transport = CloudKitTransport()
            // The scope the real data will use: only the ids the demo zone's marker names are removed from it.
            let realScope = KeychainSyncKeyStore(container: CloudKitTransport.keyScope(demo: false))
            do {
                let outcome = try await SyncDemoReset.run(
                    transport: transport,
                    deleteZone: { zone in try await transport.deleteZone(zone) },
                    removeRealScopeKey: { id in try realScope.remove(keyId: id, zone: SyncRecordStore.householdZone) },
                    db: dbQueue, now: Date())
                let line = "Mango: sync demo reset done: zone \(outcome.zoneDeleted ? "deleted" : "was already gone"); "
                    + "\(outcome.removedRealScopeKeys.count) of \(outcome.keyIds.count) marker key(s) removed from the real scope "
                    + "(\(outcome.keyIds.joined(separator: ", "))); the demo database will upload everything again.\n"
                FileHandle.standardError.write(Data(line.utf8))
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("Mango: sync demo reset stopped (\(String(describing: type(of: error))))\n".utf8))
                exit(1)
            }
        }
    }

    /// A status for the log: its kind and counts, never data.
    private static func describe(_ status: SyncStatus) -> String {
        switch status {
        case .failed(let reason): "failed (\(reason))"
        default: SyncStatusCopy.text(status, now: Date()).text
        }
    }
}
#endif
