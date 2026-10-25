import XCTest
import GRDB
@testable import BudgetCore
@testable import BudgetDemo
import TestSupport

/// The shared test databases (`TestDatabase`): every copy is independent, and a copy of the migrated
/// template is the database a fresh migration makes, with the same connection settings.
final class TestDatabaseTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("TestDatabaseTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func accountNames(_ queue: DatabaseQueue) throws -> [String] {
        try queue.read { db in try String.fetchAll(db, sql: "SELECT name FROM account ORDER BY name") }
    }

    func testCopiesAreIndependent() throws {
        let a = try TestDatabase.migrated()
        let b = try TestDatabase.migrated()
        XCTAssertFalse(a === b)
        try a.write { db in try db.execute(sql: "INSERT INTO account (name, currency, kind, trackingMode) VALUES ('Only in A', 'gbp', 'cash', 'manual')") }
        XCTAssertEqual(try accountNames(a), ["Only in A"])
        XCTAssertEqual(try accountNames(b), [])
        XCTAssertEqual(try accountNames(try TestDatabase.migrated()), [], "a later copy doesn't see an earlier copy's write")
    }

    func testDemoCopiesAreIndependent() throws {
        let a = try TestDatabase.demo()
        let b = try TestDatabase.demo()
        let before = try accountNames(b)
        XCTAssertFalse(before.isEmpty)
        try a.write { db in try db.execute(sql: "UPDATE account SET name = name || ' (changed)'") }
        XCTAssertNotEqual(try accountNames(a), before)
        XCTAssertEqual(try accountNames(b), before)
        XCTAssertEqual(try accountNames(try TestDatabase.demo()), before, "a later copy doesn't see an earlier copy's write")
    }

    /// Every table's rows, in rowid order, as text (`updatedAt`-style stamps included).
    private func dump(_ queue: DatabaseQueue) throws -> [String: [String]] {
        try queue.read { db in
            var result: [String: [String]] = [:]
            let tables = try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name")
            for table in tables {
                result[table] = try Row.fetchAll(db, sql: "SELECT * FROM \"\(table)\"").map(\.description)
            }
            return result
        }
    }

    private func schema(_ queue: DatabaseQueue) throws -> [String] {
        try queue.read { db in
            try Row.fetchAll(db, sql: "SELECT type, name, tbl_name, sql FROM sqlite_master ORDER BY type, name").map(\.description)
        }
    }

    func testAMigratedCopyIsWhatAFreshMigrationMakes() throws {
        let fresh = try DatabaseManager(path: nil)
        try fresh.migrate()
        let copy = try TestDatabase.migratedManager()

        let applied = { (queue: DatabaseQueue) in try queue.read { db in try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations ORDER BY rowid") } }
        XCTAssertEqual(try applied(copy.dbQueue), try applied(fresh.dbQueue))
        XCTAssertFalse(try copy.hasPendingMigrations())
        XCTAssertEqual(try schema(copy.dbQueue), try schema(fresh.dbQueue), "tables, indexes and triggers, sync triggers included")
        let triggers = try copy.dbQueue.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sqlite_master WHERE type = 'trigger'")! }
        XCTAssertGreaterThan(triggers, 0)

        // The rows the migrations seed, the same (the sync schema stamp's time aside: a migration made earlier).
        var copied = try dump(copy.dbQueue), migrated = try dump(fresh.dbQueue)
        copied["syncState"] = nil
        migrated["syncState"] = nil
        XCTAssertEqual(copied, migrated)
        // Its values are JSON (key order varies between processes): compared decoded.
        let state = { (queue: DatabaseQueue) -> [String: NSObject] in
            try queue.read { db in
                var values: [String: NSObject] = [:]
                for row in try Row.fetchAll(db, sql: "SELECT key, value FROM syncState") {
                    let data: Data = row["value"]
                    values[row["key"]] = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? NSObject
                }
                return values
            }
        }
        let copiedState = try state(copy.dbQueue)
        XCTAssertFalse(copiedState.isEmpty)
        XCTAssertEqual(copiedState, try state(fresh.dbQueue))
    }

    func testACopyHasTheConnectionSettingsAndWorkingSyncTriggers() throws {
        let copy = try TestDatabase.migrated()
        try copy.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "PRAGMA foreign_keys"), 1)
            XCTAssertEqual(try Int.fetchOne(db, sql: "PRAGMA recursive_triggers"), 1)
        }
        let pendingBefore = try copy.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM syncPending")! }
        try copy.write { db in try db.execute(sql: "INSERT INTO account (name, currency, kind, trackingMode) VALUES ('Tracked', 'gbp', 'cash', 'manual')") }
        let pendingAfter = try copy.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM syncPending")! }
        XCTAssertGreaterThan(pendingAfter, pendingBefore, "the sync triggers came with the copy and fire")
        // Foreign keys enforced on the copy's connection.
        XCTAssertThrowsError(try copy.write { db in
            try db.execute(sql: "INSERT INTO balanceSnapshot (accountId, date, balanceMinorUnits) VALUES (999999, '2026-01-01', 0)")
        })
    }

    func testAFileCopyCanBeReopenedAndIsNeverWrittenOverAnExistingFile() throws {
        let path = folder.appendingPathComponent("db.sqlite").path
        do {
            let manager = try TestDatabase.migratedManager(path: path)
            try manager.dbQueue.write { db in try db.execute(sql: "INSERT INTO account (name, currency, kind, trackingMode) VALUES ('On file', 'gbp', 'cash', 'manual')") }
        }
        let reopened = try DatabaseManager(path: path)
        XCTAssertFalse(try reopened.hasPendingMigrations())
        XCTAssertEqual(try accountNames(reopened.dbQueue), ["On file"])
        XCTAssertThrowsError(try TestDatabase.migratedManager(path: path))
    }

    func testADemoCopyCarriesItsEvidenceFiles() throws {
        let evidence = folder.appendingPathComponent("Evidence", isDirectory: true)
        let manager = try TestDatabase.demoManager(evidenceRoot: evidence)
        let stored = try manager.dbQueue.read { db in try String.fetchAll(db, sql: "SELECT storedRelativePath FROM document") }
        XCTAssertFalse(stored.isEmpty)
        for path in stored {
            XCTAssertTrue(FileManager.default.fileExists(atPath: evidence.appendingPathComponent(path).path), path)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("Waiting", isDirectory: true).path))
        XCTAssertThrowsError(try TestDatabase.fillDemo(manager.dbQueue, evidenceRoot: nil), "refuses a database that holds data")
    }

    /// A demo copy holds what a fresh build into a fresh migration holds.
    func testADemoCopyIsWhatAFreshBuildMakes() throws {
        let fresh = try DatabaseManager(path: nil)
        try fresh.migrate()
        try DemoDatabase.build(dbQueue: fresh.dbQueue, evidenceRoot: folder.appendingPathComponent("FreshEvidence", isDirectory: true))
        let copy = try TestDatabase.demo()
        XCTAssertEqual(try schema(copy), try schema(fresh.dbQueue))
        let copied = try dump(copy), built = try dump(fresh.dbQueue)
        XCTAssertEqual(Set(copied.keys), Set(built.keys))
        // Only rows stamped with the build's clock time (`createdAt`, sync times) or a random sync UUID may differ,
        // as they differ between any two fresh builds; those tables still hold as many rows.
        let stampedOrRandom: Set<String> = ["evidenceRequirement", "documentLink", "syncState", "syncRecord", "syncFieldClock", "syncPending"]
        for table in copied.keys where copied[table] != built[table] {
            XCTAssertTrue(stampedOrRandom.contains(table), "\(table) differs from a fresh build")
            XCTAssertEqual(copied[table]?.count, built[table]?.count, table)
        }
    }

    func testConcurrentCallsGetTheirOwnCopies() throws {
        let queues = UnsafeMutableBufferPointer<DatabaseQueue?>.allocate(capacity: 16)
        defer { queues.deallocate() }
        queues.initialize(repeating: nil)
        DispatchQueue.concurrentPerform(iterations: 16) { index in
            queues[index] = try? TestDatabase.migrated()
        }
        let all = queues.compactMap { $0 }
        XCTAssertEqual(all.count, 16)
        for (index, queue) in all.enumerated() {
            try queue.write { db in try db.execute(sql: "INSERT INTO account (name, currency, kind, trackingMode) VALUES (?, 'gbp', 'cash', 'manual')", arguments: ["A\(index)"]) }
        }
        for (index, queue) in all.enumerated() {
            XCTAssertEqual(try accountNames(queue), ["A\(index)"])
        }
    }
}
