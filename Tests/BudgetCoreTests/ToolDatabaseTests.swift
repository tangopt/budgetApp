import XCTest
import GRDB
@testable import BudgetCore

/// One-off tools open the database through `ToolDatabase`, which sets `recursive_triggers` as `DatabaseManager` does
/// (step 3 follow-up: a `REPLACE` that removes a row fires the sync delete triggers only with it on).
final class ToolDatabaseTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("ToolDatabaseTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    func testToolOpenPathSetsRecursiveTriggers() throws {
        let path = folder.appendingPathComponent("tool.sqlite").path
        let app = try DatabaseManager(path: path)
        try app.migrate()
        try app.dbQueue.close()

        let writer = try ToolDatabase.open(path: path)
        XCTAssertEqual(try writer.read { db in try Int.fetchOne(db, sql: "PRAGMA recursive_triggers") }, 1)
        try writer.close()

        var readOnly = Configuration()
        readOnly.readonly = true
        let reader = try ToolDatabase.open(path: path, configuration: readOnly)
        XCTAssertEqual(try reader.read { db in try Int.fetchOne(db, sql: "PRAGMA recursive_triggers") }, 1)
        try reader.close()

        // The app's own connections use the same configuration.
        let reopened = try DatabaseManager(path: path)
        XCTAssertEqual(try reopened.dbQueue.read { db in try Int.fetchOne(db, sql: "PRAGMA recursive_triggers") }, 1)
    }

    /// A `REPLACE` through a tool's connection leaves a tombstone at once (not only at the next app open).
    func testReplaceThroughTheToolPathLeavesATombstone() throws {
        let path = folder.appendingPathComponent("replace.sqlite").path
        let app = try DatabaseManager(path: path)
        try app.migrate()
        try app.dbQueue.close()

        let tool = try ToolDatabase.open(path: path)
        // `property.name` is unique: REPLACE removes the old row (another rowid) and inserts a new one.
        let old = try tool.write { db -> String in
            try db.execute(sql: "INSERT INTO property(name, country) VALUES ('Synthetic Replaced', 'PT')")
            return try SyncRecordStore.uuid(for: "property", localId: db.lastInsertedRowID, db: db)
        }
        try tool.write { db in
            try db.execute(sql: "INSERT OR REPLACE INTO property(id, name, country) VALUES (500, 'Synthetic Replaced', 'GB')")
        }
        XCTAssertNotNil(try tool.read { db in try SyncTombstoneRow.fetchOne(db, key: old) })
        try tool.close()
    }

    /// Every one-off tool target (each `Sources/<Tool>/` but the libraries) opens databases only through `ToolDatabase`.
    func testToolsNeverOpenABareDatabaseQueueOnAFile() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources", isDirectory: true)
        let libraries: Set<String> = ["BudgetCore", "MangoSync", "MangoUI"]
        let fileManager = FileManager.default
        var offenders: [String] = []
        var checked = 0
        for target in try fileManager.contentsOfDirectory(atPath: sources.path).sorted() where !libraries.contains(target) {
            let folder = sources.appendingPathComponent(target, isDirectory: true)
            guard let files = fileManager.enumerator(atPath: folder.path) else { continue }
            for case let file as String in files where file.hasSuffix(".swift") {
                checked += 1
                let text = try String(contentsOf: folder.appendingPathComponent(file), encoding: .utf8)
                if text.contains("DatabaseQueue(path:") { offenders.append("\(target)/\(file)") }
            }
        }
        XCTAssertGreaterThan(checked, 10)
        XCTAssertEqual(offenders, [])
    }
}
