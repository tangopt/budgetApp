import XCTest
import GRDB
import CryptoKit
@testable import BudgetCore
@testable import BudgetDemo

/// The migration rehearsal (plan Task 8), on the synthetic demo database only: copied, migrated and backfilled,
/// every existing table compared with the original, the whole outgoing payload set generated offline (an
/// in-memory cloud, nothing sent), and applied into an empty database through the checked pull.
final class SyncRehearsalTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("SyncRehearsalTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    /// The demo database as the installed app (before step 3) would hold it: migrated up to the last migration
    /// before `createSync`, so the rehearsal's migration does the real work.
    private func preSyncDemo() throws -> (database: String, library: URL) {
        let path = folder.appendingPathComponent("demo.sqlite").path
        let library = folder.appendingPathComponent("Evidence", isDirectory: true)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        let manager = try DatabaseManager(path: path)
        try manager.migrate(upTo: "createAppUser")
        try manager.dbQueue.write { db in try DemoMarker.mark(db) }
        try DemoDatabase.build(dbQueue: manager.dbQueue, evidenceRoot: library)
        try manager.dbQueue.close()
        return (path, library)
    }

    private func digest(_ url: URL) throws -> String {
        var hashes: [String] = []
        let paths = (FileManager.default.enumerator(atPath: url.path)?.allObjects as? [String] ?? []).sorted()
        for path in paths {
            let file = url.appendingPathComponent(path)
            var isFolder: ObjCBool = false
            guard FileManager.default.fileExists(atPath: file.path, isDirectory: &isFolder), !isFolder.boolValue else { continue }
            hashes.append(path + ":" + SHA256.hash(data: try Data(contentsOf: file)).map { String(format: "%02x", $0) }.joined())
        }
        return hashes.joined(separator: "\n")
    }

    func testRehearsalOnThePreSyncDemo() async throws {
        let (database, library) = try preSyncDemo()
        let sourceBefore = try digest(folder)

        let report = try await SyncRehearsal.run(databasePath: database, libraryPath: library.path)

        XCTAssertEqual(try digest(folder), sourceBefore, "the source database and library are never written")
        XCTAssertTrue(report.migrationsRun.contains("createSync"))
        XCTAssertGreaterThan(report.backfilled, 2_000)
        // Every pre-existing table identical, after the migration and after generating the payloads.
        XCTAssertGreaterThan(report.tables.count, 40)
        XCTAssertEqual(report.tables.filter { !$0.identical }.map(\.table), [])
        XCTAssertEqual(report.tablesAfterPayloads.filter { !$0.identical }.map(\.table), [])
        XCTAssertTrue(report.tables.contains { $0.table == "transaction_" && $0.rows > 100 })
        XCTAssertEqual(report.taxFiguresChanged, 0)
        // The outgoing payload set.
        XCTAssertGreaterThan(report.recordsByType["transaction_"] ?? 0, 100)
        XCTAssertEqual(report.recordsByType.values.reduce(0, +), report.records)
        XCTAssertGreaterThan(report.records, report.backfilled - 1)
        XCTAssertGreaterThan(report.recordBytes, 0)
        XCTAssertEqual(report.totalBytes, report.recordBytes + report.assetBytes)
        XCTAssertNotNil(report.largest)
        XCTAssertGreaterThan(report.documents, 0)
        XCTAssertEqual(report.documents, report.recordsByType[SyncDocumentFile.recordType])
        XCTAssertGreaterThan(report.documentBytes, 0)
        XCTAssertEqual(report.plaintextFields, [])
        // Applied into an empty database through the checked pull.
        XCTAssertEqual(report.apply.received, report.records - (report.recordsByType[SyncDocumentFile.recordType] ?? 0)
                       - (report.recordsByType[SyncZoneKeys.recordType] ?? 0))
        XCTAssertEqual(report.apply.staged, 0)
        XCTAssertEqual(report.apply.unreadable, 0)
        XCTAssertEqual(report.apply.held, 0)
        XCTAssertEqual(report.apply.rowCountMismatches, [])
        XCTAssertEqual(report.apply.taxFiguresChanged, 0)
        XCTAssertGreaterThan(report.apply.seconds, 0)
        XCTAssertGreaterThan(report.apply.peakFootprintBytes, 0)
        XCTAssertTrue(report.passed)
        XCTAssertTrue(report.text.contains("createSync"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: report.workFolder.path), "the working folder is removed")
    }

    func testWithoutALibraryDocumentsGoWithoutFiles() async throws {
        let (database, _) = try preSyncDemo()
        let report = try await SyncRehearsal.run(databasePath: database, libraryPath: nil)
        XCTAssertEqual(report.documents, 0)
        XCTAssertGreaterThan(report.recordsByType["document"] ?? 0, 0)
        XCTAssertTrue(report.passed)
    }

    // MARK: Parts

    func testTheComparisonCatchesAnyChangedByte() throws {
        let original = try DatabaseQueue(path: folder.appendingPathComponent("a.sqlite").path)
        try original.write { db in
            try db.execute(sql: "CREATE TABLE t(id INTEGER PRIMARY KEY, amount REAL, n INTEGER, label TEXT)")
            try db.execute(sql: "INSERT INTO t(amount, n, label) VALUES (0.1, 1, 'x'), (2.5, 2, 'y')")
            try db.execute(sql: "CREATE TABLE grdb_migrations(identifier TEXT NOT NULL PRIMARY KEY)")
            try db.execute(sql: "INSERT INTO grdb_migrations VALUES ('one')")
        }
        func compare(_ change: String?) throws -> [SyncRehearsal.TableComparison] {
            let path = folder.appendingPathComponent("b-\(UUID().uuidString).sqlite").path
            let copy = try DatabaseQueue(path: path)
            try original.backup(to: copy)
            try copy.write { db in
                // What a migration may do: a new table, a new column, a migration appended.
                try db.execute(sql: "CREATE TABLE syncRecord(uuid TEXT)")
                try db.execute(sql: "ALTER TABLE t ADD COLUMN rowUuid TEXT")
                try db.execute(sql: "INSERT INTO grdb_migrations VALUES ('two')")
                if let change { try db.execute(sql: change) }
            }
            return try original.read { a in try copy.read { b in try SyncRehearsal.compareTables(original: a, copy: b) } }
        }
        XCTAssertEqual(try compare(nil).filter { !$0.identical }.map(\.table), [])
        XCTAssertEqual(try compare(nil).map(\.table).sorted(), ["grdb_migrations", "t"], "only tables that were there before")
        XCTAssertEqual(try compare("UPDATE t SET amount = 0.1 + 1e-17 * 10 WHERE id = 1").filter { !$0.identical }.map(\.table), ["t"])
        XCTAssertEqual(try compare("UPDATE t SET n = 1.0 WHERE id = 1").filter { !$0.identical }.map(\.table), [],
                       "SQLite stores an integral REAL in an INTEGER column as the integer")
        XCTAssertEqual(try compare("UPDATE t SET label = 'X' WHERE id = 1").filter { !$0.identical }.map(\.table), ["t"])
        XCTAssertEqual(try compare("UPDATE t SET label = CAST('x' AS BLOB) WHERE id = 1").filter { !$0.identical }.map(\.table), ["t"])
        XCTAssertEqual(try compare("UPDATE t SET rowUuid = 'u' WHERE id = 1").filter { !$0.identical }.map(\.table), [],
                       "a column the migration added isn't compared")
        XCTAssertEqual(try compare("DELETE FROM t WHERE id = 2").filter { !$0.identical }.map(\.table), ["t"])
        XCTAssertEqual(try compare("DELETE FROM grdb_migrations WHERE identifier = 'one'").filter { !$0.identical }.map(\.table),
                       ["grdb_migrations"], "migrations are only ever appended")
    }

    func testPlaintextOutsideEncryptedFieldsIsFound() throws {
        let clean = try SyncWireRecord(SyncPayload(recordType: "account", recordName: "A", zone: "household", fields: ["name": .string("Synthetic")]))
        var leaking = clean
        leaking.recordName = "B"
        leaking.unencryptedFields = ["name": Data("Synthetic".utf8)]
        let assetDirectory = folder.appendingPathComponent("assets", isDirectory: true)
        XCTAssertEqual(try SyncRehearsal.plaintextFields(in: [clean], assetDirectory: assetDirectory), [])
        XCTAssertEqual(try SyncRehearsal.plaintextFields(in: [clean, leaking], assetDirectory: assetDirectory), ["account.name"])
    }

    func testTheAppsOwnDatabaseIsRefused() throws {
        let path = folder.appendingPathComponent("budget.sqlite").path
        FileManager.default.createFile(atPath: path, contents: Data())
        XCTAssertThrowsError(try SyncRehearsal.checkPaths(databasePath: path, libraryPath: nil, isAppData: { _ in true })) { error in
            XCTAssertEqual(error as? SyncRehearsal.PathError, .appData(SyncRehearsal.normalized(path)))
        }
        XCTAssertNoThrow(try SyncRehearsal.checkPaths(databasePath: path, libraryPath: nil, isAppData: { _ in false }))
        XCTAssertThrowsError(try SyncRehearsal.checkPaths(databasePath: path + "-missing", libraryPath: nil, isAppData: { _ in false }))
        XCTAssertThrowsError(try SyncRehearsal.checkPaths(databasePath: path, libraryPath: path, isAppData: { _ in false }), "the library is a folder")
    }
}
