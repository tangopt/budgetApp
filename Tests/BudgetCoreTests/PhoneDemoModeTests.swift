import XCTest
import GRDB
@testable import BudgetCore
import TestSupport

/// "Try with demo data" on the iPhone: the demo's folder is never the real database's, demo data never syncs,
/// and leaving deletes the folder and the flag.
final class PhoneDemoModeTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("PhoneDemoModeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private var caches: URL { root.appendingPathComponent("Library/Caches", isDirectory: true) }
    private var realPath: String { root.appendingPathComponent("Library/Application Support/Mango/budget.sqlite").path }

    /// The builder the app passes (`DemoDatabase.build`, which marks what it builds), from the test template.
    private func build(_ path: String, _ evidence: URL) throws {
        let manager = try TestDatabase.demoManager(path: path)
        try manager.dbQueue.write { db in try DemoMarker.mark(db) }
    }

    // MARK: The folder

    func testDemoFolderIsItsOwnAndNeverTheRealDatabase() throws {
        let folder = try PhoneDemoMode.folder(in: caches, realDatabasePath: realPath)
        XCTAssertEqual(folder.lastPathComponent, "Mango-Demo")
        let path = PhoneDemoMode.databasePath(in: folder)
        XCTAssertNotEqual(path, realPath)
        XCTAssertFalse(path.hasPrefix(URL(fileURLWithPath: realPath).deletingLastPathComponent().path + "/"))
        XCTAssertTrue(PhoneDemoMode.isInDemoFolder(path))
        XCTAssertFalse(PhoneDemoMode.isInDemoFolder(realPath))
    }

    func testDemoFolderOverlappingTheRealDatabaseIsRefused() {
        // The real database inside the would-be demo folder, and the demo folder inside the real one's.
        let inside = caches.appendingPathComponent("Mango-Demo/budget.sqlite").path
        XCTAssertThrowsError(try PhoneDemoMode.folder(in: caches, realDatabasePath: inside))
        let realFolder = URL(fileURLWithPath: realPath).deletingLastPathComponent()
        XCTAssertThrowsError(try PhoneDemoMode.folder(in: realFolder, realDatabasePath: realPath))
    }

    // MARK: Building and leaving

    func testPrepareBuildsTheDemoOnceAndLeavingDeletesTheFolderAndTheFlag() throws {
        let folder = try PhoneDemoMode.folder(in: caches, realDatabasePath: realPath)
        var builds = 0
        let path = try PhoneDemoMode.prepare(folder: folder) { path, evidence in
            builds += 1
            try build(path, evidence)
        }
        XCTAssertTrue(DemoMarker.isDemoDatabase(atPath: path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: path + ".building"))
        // The next launch reuses it.
        _ = try PhoneDemoMode.prepare(folder: folder) { path, evidence in
            builds += 1
            try build(path, evidence)
        }
        XCTAssertEqual(builds, 1)

        let defaults = try XCTUnwrap(UserDefaults(suiteName: "PhoneDemoModeTests-\(UUID().uuidString)"))
        defaults.set(true, forKey: PhoneDemoMode.defaultsKey)
        try PhoneDemoMode.leave(folder: folder, defaults: defaults)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
        XCTAssertFalse(defaults.bool(forKey: PhoneDemoMode.defaultsKey))
    }

    func testAnythingButTheDemoIsRefusedAndNothingIsDeleted() throws {
        let other = root.appendingPathComponent("Mango", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "PhoneDemoModeTests-\(UUID().uuidString)"))
        XCTAssertThrowsError(try PhoneDemoMode.leave(folder: other, defaults: defaults))
        XCTAssertTrue(FileManager.default.fileExists(atPath: other.path))
        // A builder that makes something other than the demo: refused, nothing left behind.
        let folder = try PhoneDemoMode.folder(in: caches, realDatabasePath: realPath)
        XCTAssertThrowsError(try PhoneDemoMode.prepare(folder: folder) { path, _ in
            // Test databases carry the demo marker: this one is made without it.
            try TestDatabase.migratedManager(path: path).dbQueue.write { db in try db.execute(sql: "PRAGMA application_id = 0") }
        }) { error in
            XCTAssertEqual(error as? PhoneDemoMode.Failure, .notDemoDatabase)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
    }

    // MARK: Sync

    func testSyncRefusesDemoData() throws {
        let folder = try PhoneDemoMode.folder(in: caches, realDatabasePath: realPath)
        let demoPath = try PhoneDemoMode.prepare(folder: folder, build: build)
        // The demo folder's database never syncs, not even on a --sync-demo launch.
        XCTAssertNotNil(PhoneDemoMode.syncRefusal(databasePath: demoPath, demoModeOn: false, isSyncDemoLaunch: false))
        XCTAssertNotNil(PhoneDemoMode.syncRefusal(databasePath: demoPath, demoModeOn: false, isSyncDemoLaunch: true))
        // A demo database anywhere else syncs only on the developer's --sync-demo launch.
        let elsewhere = root.appendingPathComponent("demo-elsewhere.sqlite").path
        try build(elsewhere, root)
        XCTAssertNotNil(PhoneDemoMode.syncRefusal(databasePath: elsewhere, demoModeOn: false, isSyncDemoLaunch: false))
        XCTAssertNil(PhoneDemoMode.syncRefusal(databasePath: elsewhere, demoModeOn: false, isSyncDemoLaunch: true))
        // Demo mode on: nothing syncs, whatever the database.
        let real = root.appendingPathComponent("real.sqlite").path
        // Test databases carry the demo marker: this one stands for real data.
        try TestDatabase.migratedManager(path: real).dbQueue.write { db in try db.execute(sql: "PRAGMA application_id = 0") }
        XCTAssertNotNil(PhoneDemoMode.syncRefusal(databasePath: real, demoModeOn: true, isSyncDemoLaunch: false))
        XCTAssertNil(PhoneDemoMode.syncRefusal(databasePath: real, demoModeOn: false, isSyncDemoLaunch: false))
    }

    func testRealDataIsAPullOrASyncedRow() throws {
        let empty = try TestDatabase.migrated()
        XCTAssertFalse(try empty.read { db in try PhoneDemoMode.hasRealData(db: db) })
        let demo = try TestDatabase.demo()
        XCTAssertTrue(try demo.read { db in try PhoneDemoMode.hasRealData(db: db) })
    }
}
