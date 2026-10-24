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
        try manager.dbQueue.read { db in
            XCTAssertGreaterThan(try PhoneDatabasePolicy.syncedRowCount(db: db), 0, "what the Mac's launch seeds is counted")
        }
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
