import XCTest
import GRDB
@testable import BudgetCore
import TestSupport

/// Step 7b: the admin's iPhone, read-only until now, drops what it queued while read-only before its first push, once.
/// Synthetic data only (`SharingFixture`).
final class SyncFirstWriterTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!

    override func setUpWithError() throws {
        suite = "SyncFirstWriterTests-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
    }

    private let writer = SyncWriteMode.device(zones: [SyncZones.household])

    private func pendingCount(_ db: some DatabaseReader) async throws -> Int {
        try await db.read { db in try SyncChangeTracker.pending(db: db).count }
    }

    private func readOnlyDatabase() async throws -> DatabaseQueue {
        let db = try TestDatabase.migrated()
        _ = try await db.write { db in try SharingFixture.build(db) }
        let pending = try await pendingCount(db)
        XCTAssertGreaterThan(pending, 0, "rows queued while read-only")
        return db
    }

    func testStillReadOnlyKeepsEverything() async throws {
        let db = try await readOnlyDatabase()
        let before = try await pendingCount(db)
        let discarded = try await SyncFirstWriter.prepare(mode: .readOnly, wasReadOnly: true, defaults: defaults, db: db)
        XCTAssertEqual(discarded, 0)
        let after = try await pendingCount(db)
        XCTAssertEqual(after, before)
        XCTAssertNil(defaults.object(forKey: SyncFirstWriter.defaultsKey))
    }

    func testFirstSwitchToWriterDropsWhatWasQueuedWhileReadOnly() async throws {
        let db = try await readOnlyDatabase()
        let before = try await pendingCount(db)
        let discarded = try await SyncFirstWriter.prepare(mode: writer, wasReadOnly: true, defaults: defaults, db: db)
        XCTAssertEqual(discarded, before)
        let after = try await pendingCount(db)
        XCTAssertEqual(after, 0, "nothing left to push")
        XCTAssertNotNil(defaults.object(forKey: SyncFirstWriter.defaultsKey))
    }

    func testLaterSwitchDoesNotDropAgain() async throws {
        let db = try await readOnlyDatabase()
        _ = try await SyncFirstWriter.prepare(mode: writer, wasReadOnly: true, defaults: defaults, db: db)
        // An edit made as a writer, then read-only and a writer again.
        try await db.write { db in try db.execute(sql: "UPDATE transaction_ SET note = 'edited' WHERE id = (SELECT MIN(id) FROM transaction_)") }
        let edited = try await pendingCount(db)
        XCTAssertGreaterThan(edited, 0)
        _ = try await SyncFirstWriter.prepare(mode: .readOnly, wasReadOnly: false, defaults: defaults, db: db)
        let discarded = try await SyncFirstWriter.prepare(mode: writer, wasReadOnly: true, defaults: defaults, db: db)
        XCTAssertEqual(discarded, 0)
        let after = try await pendingCount(db)
        XCTAssertEqual(after, edited)
    }

    func testIPadAlreadyWritingKeepsItsQueue() async throws {
        let db = try await readOnlyDatabase()
        let before = try await pendingCount(db)
        let discarded = try await SyncFirstWriter.prepare(mode: writer, wasReadOnly: false, defaults: defaults, db: db)
        XCTAssertEqual(discarded, 0)
        let after = try await pendingCount(db)
        XCTAssertEqual(after, before)
    }
}
