import XCTest
import GRDB
@testable import BudgetCore

/// A file manager whose Application Support folder is a test folder, so "the app's data folder" can be exercised
/// without going near the real one.
private final class RedirectedSupportFileManager: FileManager, @unchecked Sendable {
    let support: URL

    init(support: URL) {
        self.support = support
        super.init()
    }

    override func urls(for directory: FileManager.SearchPathDirectory, in domainMask: FileManager.SearchPathDomainMask) -> [URL] {
        directory == .applicationSupportDirectory ? [support] : super.urls(for: directory, in: domainMask)
    }
}

/// Plan step 4 Task 1 (Review Focus 5): the real database never syncs in this step. `SyncActivation` allows sync
/// only for a Debug `--sync-demo` launch on a demo database outside the app's data folder, signed for iCloud.
final class SyncActivationTests: XCTestCase {
    private var folder: URL!
    private var files: RedirectedSupportFileManager!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("SyncActivationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        files = RedirectedSupportFileManager(support: folder.appendingPathComponent("Support", isDirectory: true))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    /// A SQLite file at `path`, marked as the demo's when `demo`.
    private func database(_ path: URL, demo: Bool) throws {
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        let queue = try DatabaseQueue(path: path.path)
        try queue.write { db in
            try db.execute(sql: "CREATE TABLE t (x INTEGER)")
            if demo { try DemoMarker.mark(db) }
        }
    }

    private func decide(_ path: String?, arguments: [String] = ["Mango", SyncActivation.demoArgument], isDebug: Bool = true,
                        entitled: Bool = true) -> SyncActivation.Decision {
        SyncActivation.decision(databasePath: path, arguments: arguments, isDebug: isDebug, hasCloudKitEntitlement: entitled, fileManager: files)
    }

    private func assertRefused(_ decision: SyncActivation.Decision, _ phrase: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(decision.allowed, file: file, line: line)
        let reason = decision.reason ?? ""
        XCTAssertTrue(reason.contains(phrase), "\(reason) should say \(phrase)", file: file, line: line)
    }

    func testActivationRefusesEverythingButADemoDatabaseInDebug() throws {
        let demo = folder.appendingPathComponent("demo/budget.sqlite")
        try database(demo, demo: true)
        let real = folder.appendingPathComponent("real/budget.sqlite")
        try database(real, demo: false)
        // A demo-marked file inside the app's data folder is still the app's data.
        let appData = folder.appendingPathComponent("Support/Budget/budget.sqlite")
        try database(appData, demo: true)

        // No argument: sync is off, whatever the database.
        assertRefused(decide(demo.path, arguments: ["Mango"]), "Sync is off")
        // A Release build never syncs in this step.
        assertRefused(decide(demo.path, isDebug: false), "Debug build")
        // The argument without a database path.
        assertRefused(decide(nil), "needs BUDGET_DB_PATH")
        assertRefused(decide(""), "needs BUDGET_DB_PATH")
        // A relative path, or a URI.
        assertRefused(decide("demo/budget.sqlite"), "absolute file path")
        assertRefused(decide("file:" + demo.path), "absolute file path")
        // No such file.
        assertRefused(decide(folder.appendingPathComponent("missing.sqlite").path), "no database file")
        // The app's own database.
        assertRefused(decide(appData.path), "never syncs the app's own database")
        // A database that isn't the demo's.
        assertRefused(decide(real.path), "only the demo database")
        // A build without the iCloud entitlement.
        assertRefused(decide(demo.path, entitled: false), "iCloud entitlement")

        // The one accepted launch.
        let accepted = decide(demo.path)
        XCTAssertEqual(accepted, SyncActivation.Decision(allowed: true, reason: nil))
    }

    /// Step 6 Task 11: the iPhone's own database (read-only, its own) syncs in a Release build signed for iCloud;
    /// demo data never does; `--sync-demo` keeps the rules above.
    func testPhoneDecisionAllowsRealSyncOnlyWithEntitlementAndNeverDemoData() throws {
        let allow = SyncActivation.Decision(allowed: true, reason: nil)
        // Demo data never syncs, whatever else holds.
        for syncDemo in [false, true] {
            for entitled in [false, true] {
                for debug in [false, true] {
                    assertRefused(SyncActivation.phoneDecision(isDemoData: true, isSyncDemoLaunch: syncDemo, hasCloudKitEntitlement: entitled,
                                                               isDebug: debug), "Demo data")
                }
            }
        }
        // The phone's own database: with the entitlement, in a Release build.
        XCTAssertEqual(SyncActivation.phoneDecision(isDemoData: false, isSyncDemoLaunch: false, hasCloudKitEntitlement: true, isDebug: false), allow)
        assertRefused(SyncActivation.phoneDecision(isDemoData: false, isSyncDemoLaunch: false, hasCloudKitEntitlement: false, isDebug: false), "iCloud entitlement")
        assertRefused(SyncActivation.phoneDecision(isDemoData: false, isSyncDemoLaunch: false, hasCloudKitEntitlement: true, isDebug: true),
                      "Release build")

        // `--sync-demo`: today's rules (a Debug launch on a demo database outside the app's data, entitled).
        let demo = folder.appendingPathComponent("demo/budget.sqlite")
        try database(demo, demo: true)
        let real = folder.appendingPathComponent("real/budget.sqlite")
        try database(real, demo: false)
        func syncDemo(_ path: String?, debug: Bool = true, entitled: Bool = true) -> SyncActivation.Decision {
            SyncActivation.phoneDecision(isDemoData: false, isSyncDemoLaunch: true, hasCloudKitEntitlement: entitled, isDebug: debug,
                                         databasePath: path, fileManager: files)
        }
        XCTAssertEqual(syncDemo(demo.path), allow)
        assertRefused(syncDemo(real.path), "only the demo database")
        assertRefused(syncDemo(demo.path, debug: false), "Debug build")
        assertRefused(syncDemo(demo.path, entitled: false), "iCloud entitlement")
        assertRefused(syncDemo(nil), "needs BUDGET_DB_PATH")
    }
}
