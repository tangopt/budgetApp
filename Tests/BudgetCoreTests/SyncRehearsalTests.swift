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
        // Spec ⚠️1 / R13: the protected years at least (2020/21–2024/25), with every stored year.
        XCTAssertTrue(Set(report.taxYears).isSuperset(of: 2020...2024))
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
        XCTAssertTrue(report.text.contains("SelfAssessmentRegression"), "the report says how to run the SA regression on a kept copy")
    }

    func testWithoutALibraryDocumentsGoWithoutFiles() async throws {
        let (database, _) = try preSyncDemo()
        let report = try await SyncRehearsal.run(databasePath: database, libraryPath: nil, keep: true)
        defer { try? FileManager.default.removeItem(at: report.workFolder) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: report.workFolder.appendingPathComponent("copy.sqlite").path), "--keep keeps the migrated copy")
        XCTAssertTrue(report.text.contains(report.workFolder.appendingPathComponent("copy.sqlite").path))
        XCTAssertEqual(report.documents, 0)
        XCTAssertGreaterThan(report.recordsByType["document"] ?? 0, 0)
        XCTAssertTrue(report.passed)
    }

    // MARK: Parts

    func testTheComparisonCatchesAnyChangedByte() throws {
        let original = try DatabaseQueue(path: folder.appendingPathComponent("a.sqlite").path)
        try original.write { db in
            try db.execute(sql: "CREATE TABLE t(id INTEGER PRIMARY KEY AUTOINCREMENT, amount REAL, n INTEGER, label TEXT)")
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
        XCTAssertEqual(try compare(nil).map(\.table).sorted(), ["grdb_migrations", "sqlite_sequence", "t"], "only tables that were there before")
        // M1: TEXT compares by its bytes (GRDB's String decoding stops at a NUL).
        XCTAssertEqual(try compare("UPDATE t SET label = 'x' || char(0) || 'y' WHERE id = 1").filter { !$0.identical }.map(\.table), ["t"])
        // M2: a new AUTOINCREMENT table's sequence row isn't an existing table's change.
        XCTAssertEqual(try compare("CREATE TABLE newAuto(id INTEGER PRIMARY KEY AUTOINCREMENT); INSERT INTO newAuto DEFAULT VALUES")
            .filter { !$0.identical }.map(\.table), [])
        XCTAssertEqual(try compare("UPDATE sqlite_sequence SET seq = seq + 1 WHERE name = 't'").filter { !$0.identical }.map(\.table),
                       ["sqlite_sequence"])
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
        let uuid = "6C1E0E0A-3F4B-4C2D-9A1B-2C3D4E5F6A7B"
        let clean = try SyncWireRecord(SyncPayload(recordType: "account", recordName: uuid, zone: "household", fields: ["name": .string("Synthetic")]))
        var leaking = clean
        leaking.recordName = "6C1E0E0A-3F4B-4C2D-9A1B-2C3D4E5F6A7C"
        leaking.unencryptedFields = ["name": Data("Synthetic".utf8)]
        let assetDirectory = folder.appendingPathComponent("assets", isDirectory: true)
        XCTAssertEqual(try SyncRehearsal.plaintextFields(in: [clean], assetDirectory: assetDirectory), [])
        XCTAssertEqual(try SyncRehearsal.plaintextFields(in: [clean, leaking], assetDirectory: assetDirectory), ["account.name"])
    }

    /// M3: assets must be ciphertext: never readable JSON, never holding a library file's bytes.
    func testAnAssetThatIsPlaintextIsFound() throws {
        let library = folder.appendingPathComponent("Library", isDirectory: true)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        let pdf = Data("%PDF-1.7 synthetic invoice, never real, long enough to be recognised".utf8) + Data((0..<512).map { UInt8($0 % 251) })
        try pdf.write(to: library.appendingPathComponent("invoice.pdf"))
        let name = "6C1E0E0A-3F4B-4C2D-9A1B-2C3D4E5F6A7B"
        let assetDirectory = folder.appendingPathComponent("assets", isDirectory: true)
        func found(_ assets: [String: Data], type: String = "documentFile", recordName: String = name + ".file.0a1b2c3d") throws -> [String] {
            try SyncRehearsal.plaintextFields(in: [SyncWireRecord(recordType: type, recordName: recordName, zone: "household", assets: assets)],
                                              assetDirectory: assetDirectory, library: library)
        }
        let sealed = Data((0..<600).map { UInt8(($0 * 97 + 13) % 256) })
        XCTAssertEqual(try found(["file": sealed]), [])
        XCTAssertEqual(try found(["file": pdf]), ["documentFile.file (library file bytes)"])
        XCTAssertEqual(try found(["file": Data(repeating: 7, count: 40) + pdf.prefix(200)]), ["documentFile.file (library file bytes)"], "contained")
        XCTAssertEqual(try found(["payload": Data(#"{"fields":{"name":"Synthetic"}}"#.utf8)], type: "importChange", recordName: name),
                       ["importChange.payload (JSON)"])
    }

    /// M3: record names are the only plaintext besides types: opaque UUIDs (and the engine's fixed names).
    func testARecordNameThatIsntOpaqueIsFound() throws {
        let assetDirectory = folder.appendingPathComponent("assets", isDirectory: true)
        func found(_ name: String) throws -> [String] {
            try SyncRehearsal.plaintextFields(in: [SyncWireRecord(recordType: "account", recordName: name, zone: "household",
                                                                 encryptedFields: ["meta": Data([1])])], assetDirectory: assetDirectory)
        }
        XCTAssertEqual(try found("6C1E0E0A-3F4B-4C2D-9A1B-2C3D4E5F6A7B"), [])
        XCTAssertEqual(try found("6c1e0e0a-3f4b-4c2d-9a1b-2c3d4e5f6a7b.file.0a1b2c3d"), [])
        XCTAssertEqual(try found(SyncZoneKeys.recordName(zone: "household")), [])
        XCTAssertEqual(try found(TransportLeaseStore.recordName), [])
        XCTAssertEqual(try found("Synthetic current account"), ["account.recordName"])
        XCTAssertEqual(try found("6C1E0E0A-3F4B-4C2D-9A1B-2C3D4E5F6A7B.Synthetic"), ["account.recordName"])
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
