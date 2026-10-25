import XCTest
import GRDB
@testable import BudgetCore

/// Plan step 4 Task 4 (Review Focus 1): the iPhone's database before its first pull holds no row of any synced
/// table and nothing pending, so nothing it made could collide with the household's records on arrival.
final class PhoneDatabaseTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("PhoneDatabaseTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    func testFreshPhoneDatabaseHasNoSyncedRowsAndNothingPending() throws {
        let manager = try PhoneDatabasePolicy.open(at: folder.appendingPathComponent("budget.sqlite").path)
        try manager.dbQueue.read { db in
            XCTAssertEqual(try PhoneDatabasePolicy.syncedRowCount(db: db), 0, "no seeded category, transfer category or anything else")
            XCTAssertTrue(try SyncChangeTracker.pending(db: db).isEmpty)
            // The only rows of a synced table are the built-in categories the migrations seed on every device,
            // with the same UUID everywhere (they merge by identity on the first pull).
            let builtIn = try String.fetchAll(db, sql: "SELECT builtInRole FROM category ORDER BY builtInRole")
            XCTAssertEqual(builtIn, ["balanceAdjustment", "marketMovement"])
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM syncRecord"), 0)
        }
        // Opening again (the next launch) still makes nothing.
        let again = try PhoneDatabasePolicy.open(at: folder.appendingPathComponent("budget.sqlite").path)
        try again.dbQueue.read { db in
            XCTAssertEqual(try PhoneDatabasePolicy.syncedRowCount(db: db), 0)
            XCTAssertTrue(try SyncChangeTracker.pending(db: db).isEmpty)
        }
    }

    func testPhoneOpenMigratesToTheLatest() throws {
        let manager = try PhoneDatabasePolicy.open(at: folder.appendingPathComponent("budget.sqlite").path)
        XCTAssertFalse(try manager.hasPendingMigrations())
    }

    func testSyncedRowCountCountsEverySyncedTable() throws {
        let manager = try PhoneDatabasePolicy.open(at: folder.appendingPathComponent("budget.sqlite").path)
        try manager.dbQueue.write { db in
            try CategorySeeder.seedDefaults(db)
        }
        let seeded = try manager.dbQueue.read { db in try PhoneDatabasePolicy.syncedRowCount(db: db) }
        XCTAssertGreaterThan(seeded, 0, "what the Mac's launch seeds is counted")
        // A row of a table other than category counts too.
        try manager.dbQueue.write { db in
            try db.execute(sql: "INSERT INTO person (name) VALUES ('Test person')")
        }
        try manager.dbQueue.read { db in
            XCTAssertEqual(try PhoneDatabasePolicy.syncedRowCount(db: db), seeded + 1)
        }
    }

    /// Review M1: a DEBUG simulator build's `BUDGET_DB_PATH` opens only a demo database outside any app data,
    /// refused before anything opens or migrates it.
    func testOverrideOpensOnlyADemoDatabaseOutsideAppData() throws {
        func make(_ url: URL, demo: Bool) throws {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let queue = try DatabaseQueue(path: url.path)
            try queue.write { db in
                try db.execute(sql: "CREATE TABLE t (x INTEGER)")
                if demo { try DemoMarker.mark(db) }
            }
        }
        let demo = folder.appendingPathComponent("demo/budget.sqlite")
        try make(demo, demo: true)
        let real = folder.appendingPathComponent("real/budget.sqlite")
        try make(real, demo: false)
        // A demo-marked file under a Mac app's data folder (as the simulator would see the host's).
        let hostAppData = folder.appendingPathComponent("Library/Application Support/Budget/budget.sqlite")
        try make(hostAppData, demo: true)
        let hostContainer = folder.appendingPathComponent("Library/Containers/x/Data/budget.sqlite")
        try make(hostContainer, demo: true)
        let realBytes = try Data(contentsOf: real)

        XCTAssertNil(PhoneDatabasePolicy.overrideRefusal(path: demo.path))
        XCTAssertNotNil(PhoneDatabasePolicy.overrideRefusal(path: real.path), "not the demo database")
        XCTAssertNotNil(PhoneDatabasePolicy.overrideRefusal(path: hostAppData.path), "a Mac app's data")
        XCTAssertNotNil(PhoneDatabasePolicy.overrideRefusal(path: hostContainer.path), "a Mac app container's data")
        XCTAssertNotNil(PhoneDatabasePolicy.overrideRefusal(path: "demo/budget.sqlite"), "relative")
        XCTAssertNotNil(PhoneDatabasePolicy.overrideRefusal(path: "file:" + demo.path), "a URI")
        XCTAssertNotNil(PhoneDatabasePolicy.overrideRefusal(path: folder.appendingPathComponent("missing.sqlite").path), "no file")
        XCTAssertNotNil(PhoneDatabasePolicy.overrideRefusal(path: folder.path), "a folder")
        // The process's own app data (the phone's folder, the Mac's), by path only: nothing is created there.
        let support = try XCTUnwrap(FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first)
        XCTAssertNotNil(PhoneDatabasePolicy.overrideRefusal(path: support.appendingPathComponent("Mango/budget.sqlite").path))
        XCTAssertNotNil(PhoneDatabasePolicy.overrideRefusal(path: support.appendingPathComponent("Budget/budget.sqlite").path))
        // Checking opened nothing for writing: the refused database is byte-for-byte unchanged.
        XCTAssertEqual(try Data(contentsOf: real), realBytes)
    }

    /// The phone keeps its database at `Application Support/Mango/budget.sqlite`: the app-data refusal (sync
    /// activation, the tools) treats it as the app's own data.
    func testThePhonesFolderIsAppData() throws {
        let support = try XCTUnwrap(FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first)
        XCTAssertEqual(PhoneDatabasePolicy.folderName, "Mango")
        XCTAssertTrue(TaxRegression.appDataFolders().contains { $0.standardizedFileURL == support.appendingPathComponent("Mango", isDirectory: true).standardizedFileURL })
        XCTAssertTrue(TaxRegression.isAppData(support.appendingPathComponent("Mango/budget.sqlite").path))
    }
}
