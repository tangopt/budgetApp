#if DEBUG
import Foundation
import os
import BudgetCore

/// The one way to reach `CloudKitTransport` in build step 3 (plan Global Constraints): a DEBUG build launched
/// with `--sync-demo` and `BUDGET_DB_PATH` naming the demo database (`DemoMarker`). Anything else with the
/// argument refuses to start, with the reason; without the argument nothing here runs. It syncs once after
/// the database has loaded (development container) and logs the counts — for the user-attended step 4
/// kick-off, never run by tests or tools.
enum SyncDemoMode {
    static let argument = "--sync-demo"
    private static let log = Logger(subsystem: "com.personal.budget", category: "Sync")

    static var isRequested: Bool { CommandLine.arguments.contains(argument) }

    /// Why the launch can't sync the demo, or nil when it may.
    static func refusal(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        guard let raw = environment["BUDGET_DB_PATH"], !raw.isEmpty else {
            return "\(argument) needs BUDGET_DB_PATH pointing at the demo database (MakeDemoDatabase builds one)."
        }
        guard raw.hasPrefix("/"), !raw.lowercased().hasPrefix("file:") else {
            return "\(argument): BUDGET_DB_PATH must be an absolute file path."
        }
        let resolved = TaxRegression.resolvedPath(raw)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved, isDirectory: &isDirectory), !isDirectory.boolValue else {
            return "\(argument): there is no database file at BUDGET_DB_PATH."
        }
        guard !TaxRegression.isAppData(resolved) else {
            return "\(argument) never syncs the app's own database."
        }
        guard DemoMarker.isDemoDatabase(atPath: resolved) else {
            return "\(argument) syncs only the demo database; BUDGET_DB_PATH isn't one (MakeDemoDatabase builds it)."
        }
        return nil
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
