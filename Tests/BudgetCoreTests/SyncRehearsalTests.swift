import XCTest
import GRDB
import CryptoKit
@testable import BudgetCore
@testable import BudgetDemo
import TestSupport

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
    /// before `createSync`, so the rehearsal's migration does the real work. The demo is built by today's
    /// code, which writes columns later migrations add, so it's built in a fully migrated database and its
    /// rows are copied into the pre-sync one, column by column of the pre-sync schema.
    private func preSyncDemo() throws -> (database: String, library: URL) {
        let path = folder.appendingPathComponent("demo.sqlite").path
        let library = folder.appendingPathComponent("Evidence", isDirectory: true)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        let builtPath = folder.appendingPathComponent("built.sqlite").path
        let built = try TestDatabase.demoManager(path: builtPath, evidenceRoot: library)
        try built.dbQueue.close()

        let manager = try DatabaseManager(path: path)
        try manager.migrate(upTo: "createAppUser")
        try manager.dbQueue.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA foreign_keys = OFF")
            try db.execute(sql: "ATTACH DATABASE ? AS built", arguments: [builtPath])
            try db.inTransaction {
                let tables = try String.fetchAll(db, sql: """
                    SELECT name FROM main.sqlite_master WHERE type = 'table' AND name NOT IN ('grdb_migrations') AND name NOT LIKE 'sqlite_%'
                    """)
                // Every table emptied first, so delete triggers find nothing left to remove.
                for table in tables { try db.execute(sql: "DELETE FROM main.\"\(table)\"") }
                for table in tables {
                    let columns = try db.columns(in: table, in: "main").map { "\"\($0.name)\"" }.joined(separator: ", ")
                    try db.execute(sql: "INSERT INTO main.\"\(table)\" (\(columns)) SELECT \(columns) FROM built.\"\(table)\"")
                }
                try db.execute(sql: "DELETE FROM main.sqlite_sequence")
                try db.execute(sql: "INSERT INTO main.sqlite_sequence SELECT * FROM built.sqlite_sequence WHERE name IN (SELECT name FROM main.sqlite_master)")
                return .commit
            }
            try db.execute(sql: "DETACH DATABASE built")
            try db.execute(sql: "PRAGMA foreign_keys = ON")
            try DemoMarker.mark(db)
        }
        try manager.dbQueue.close()
        try FileManager.default.removeItem(atPath: builtPath)
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
        XCTAssertEqual(report.sealingFindings, [], "R15: every record sealed, no source value readable")
        XCTAssertNil(report.push.keyWait)
        // Applied into an empty database through the checked pull.
        XCTAssertEqual(report.apply.received, report.records - (report.recordsByType[SyncDocumentFile.recordType] ?? 0)
                       - (report.recordsByType[SyncZoneKeys.recordType] ?? 0))
        XCTAssertEqual(report.apply.stagingRows, 0, "what waited for its parents during the pull was applied")
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
        // The assertions are about documents going without files, not about volume: only the first transactions
        // stay (the rehearsal's cost grows with every row it backfills, encrypts and applies), every document stays.
        let pre = try DatabaseManager(path: database)
        try await pre.dbQueue.write { db in
            try db.execute(sql: "DELETE FROM transaction_ WHERE id NOT IN (SELECT id FROM transaction_ ORDER BY id LIMIT 200)")
        }
        try pre.dbQueue.close()
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

    /// Ruling R15: every data record is exactly `sealed` + `keyId`, opens with the household key, and holds no source
    /// value's bytes; the marker and sealed files have their own exact shapes.
    func testTheSealingCheckFindsAnythingButSealedRecords() throws {
        let keys = InMemorySyncKeyStore()
        let key = DocumentCrypto.newZoneKey()
        try keys.store(key, zone: "household")
        let uuid = "6C1E0E0A-3F4B-4C2D-9A1B-2C3D4E5F6A7B"
        let payload = SyncPayload(recordType: "account", recordName: uuid, zone: "household", fields: ["name": .string("Synthetic Account")])
        let sealed = try SyncLargePayload.wire(for: payload, key: key).0
        let marker = SyncZoneKeys.wire(.init(keyId: DocumentCrypto.zoneKeyId(key), createdAt: Date()), zone: "household")
        let file = SyncWireRecord(recordType: SyncDocumentFile.recordType, recordName: uuid + ".file.0a1b2c3d", zone: "household",
                                  assets: [SyncDocumentFile.assetField: Data(count: 64)])
        XCTAssertEqual(try SyncRehearsal.sealingFindings(in: [sealed, marker, file], keys: keys), [])
        // The step 3 format, readable values in the encrypted fields.
        XCTAssertEqual(try SyncRehearsal.sealingFindings(in: [try SyncWireRecord(payload)], keys: keys), ["account: not exactly sealed + keyId"])
        var extra = sealed
        extra.encryptedFields["f_name"] = Data("{\"string\":\"Synthetic Account\"}".utf8)
        XCTAssertEqual(try SyncRehearsal.sealingFindings(in: [extra], keys: keys), ["account: not exactly sealed + keyId"])
        XCTAssertEqual(try SyncRehearsal.sealingFindings(in: [sealed], keys: InMemorySyncKeyStore()), ["account: doesn't open"])
        // Readable bytes appended to the box: it no longer authenticates.
        let leaky = SyncWireRecord(recordType: "account", recordName: uuid, zone: "household",
                                   encryptedFields: [FieldSealing.sealedField: (sealed.encryptedFields[FieldSealing.sealedField] ?? Data()) + Data("Synthetic Account".utf8),
                                                     FieldSealing.keyIdField: Data(DocumentCrypto.zoneKeyId(key).utf8)])
        XCTAssertEqual(try SyncRehearsal.sealingFindings(in: [leaky], keys: keys), ["account: doesn't open"])
        var keyed = marker
        keyed.encryptedFields["keys"] = Data("{}".utf8)
        XCTAssertEqual(try SyncRehearsal.sealingFindings(in: [keyed], keys: keys), ["zoneKey: not exactly a key marker"])
        var fileWithFields = file
        fileWithFields.encryptedFields["meta"] = Data([1])
        XCTAssertEqual(try SyncRehearsal.sealingFindings(in: [fileWithFields], keys: keys), ["documentFile: not exactly a sealed file"])
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

    // MARK: Step 6: zones, ownership and a member stand-in

    /// The demo as a real database would be before the turn-on: not the demo's (no marker), no owner confirmed, no
    /// summaries. Returns its path, its evidence folder and the account ids by name.
    private func unconfirmedDemo() throws -> (database: String, library: URL, accounts: [String: Int64]) {
        let path = folder.appendingPathComponent("real-like.sqlite").path
        let library = folder.appendingPathComponent("RealLikeEvidence", isDirectory: true)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        let manager = try TestDatabase.demoManager(path: path, evidenceRoot: library)
        let accounts = try manager.dbQueue.write { db -> [String: Int64] in
            try db.execute(sql: "PRAGMA application_id = 0")
            try db.execute(sql: "DELETE FROM accountBalancePoint")
            try db.execute(sql: "DELETE FROM accountSummaryMonth")
            try db.execute(sql: "DELETE FROM memberPermission")
            try db.execute(sql: "DELETE FROM personSharing")
            try db.execute(sql: "UPDATE account SET ownerPersonId = NULL, sharingLevel = 'everything'")
            return Dictionary(uniqueKeysWithValues: try Row.fetchAll(db, sql: "SELECT id, name FROM account").map { ($0["name"] as String, $0["id"] as Int64) })
        }
        XCTAssertFalse(try manager.dbQueue.read { db in try DemoMarker.isDemo(db) })
        try manager.dbQueue.close()
        return (path, library, accounts)
    }

    func testRehearsalOnDemoPassesWithZones() async throws {
        let (database, library, accounts) = try unconfirmedDemo()
        let balanceOnly = try XCTUnwrap(accounts[DemoSharing.balanceOnlyAccount])
        let joint = try XCTUnwrap(accounts[DemoSharing.jointAccount])
        // One Balance only account; one joint; every other account at Everything.
        var ownership = RehearsalOwnership(joint: [joint])
        for (_, id) in accounts where id != joint { ownership.levels[id] = .everything }
        ownership.levels[balanceOnly] = .balanceOnly
        let source = try DatabaseQueue(path: database)
        let privateTransactions = try await source.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM transaction_ WHERE accountId = ?", arguments: [balanceOnly]) ?? 0
        }
        try source.close()
        XCTAssertGreaterThan(privateTransactions, 10, "the Balance only account has transactions to keep private")

        let report = try await SyncRehearsal.run(databasePath: database, libraryPath: library.path, ownership: ownership)

        XCTAssertTrue(report.ownership.savedHere)
        XCTAssertEqual(report.ownership.accountsByLevel["Balance only"], 1)
        XCTAssertEqual(report.ownership.joint, 1)
        XCTAssertEqual(report.turnOn.stage, .done)
        XCTAssertEqual(report.turnOn.sent, report.turnOn.total)
        XCTAssertGreaterThan(report.turnOn.total, 2_000)
        XCTAssertNotNil(report.backupFile.range(of: #"^budget\.sqlite\.pre-sync-backup-\d{8}-\d{6}(-\d+)?$"#, options: .regularExpression))
        XCTAssertNil(report.guardRefusal)
        XCTAssertEqual(report.householdViolations, [])
        XCTAssertGreaterThan(report.recordsByZone["household"] ?? 0, 1_000)
        XCTAssertGreaterThan(report.recordsByZone["private (admin)"] ?? 0, privateTransactions)
        XCTAssertNil(report.recordsByZone["private (other)"])
        XCTAssertGreaterThan(report.summaries["accountBalancePoint"] ?? 0, 0)
        XCTAssertEqual(report.sealingFindings, [])
        XCTAssertEqual(report.plaintextFields, [])
        XCTAssertEqual(report.taxFiguresChanged, 0, "ownership and the turn-on change no tax figure")
        // The admin's other device: both zones, everything.
        XCTAssertEqual(report.apply.rowCountMismatches, [])
        XCTAssertEqual(report.apply.taxFiguresChanged, 0)
        XCTAssertEqual(report.apply.stagingRows, 0)
        // The member stand-in: the household only.
        XCTAssertGreaterThan(report.member.received, 1_000)
        XCTAssertEqual(report.member.privateTransactionsHeld, 0)
        XCTAssertEqual(report.member.privateRecordsHeld, 0)
        XCTAssertEqual(report.member.privateAccountFieldsHeld, 0)
        XCTAssertEqual(report.member.stagingRows, 0)
        XCTAssertEqual(report.member.unreadable, 0)
        // Every device computes the same figures (sharing spec §10): the member's equal the owner's, nothing held.
        XCTAssertEqual(report.member.taxFiguresChanged, 0)
        XCTAssertEqual(report.member.held, 0)
        XCTAssertNil(report.turnOnError)
        XCTAssertTrue(report.passed, report.text)
        var differs = report
        differs.member.taxFiguresChanged = 1
        XCTAssertFalse(differs.passed, "a member figure that differs fails the rehearsal")
        var held = report
        held.member.held = 1
        XCTAssertFalse(held.passed, "a change held by the member's filed-year check fails the rehearsal")
        XCTAssertTrue(report.text.contains("Member stand-in"))
        XCTAssertFalse(report.text.contains(DemoSharing.balanceOnlyAccount), "counts only, never names")
    }

    func testRehearsalOwnershipChoicesAreChecked() async throws {
        let (database, _, accounts) = try unconfirmedDemo()
        do {
            _ = try await SyncRehearsal.run(databasePath: database, libraryPath: nil, ownership: RehearsalOwnership(joint: [999_999]))
            XCTFail("an unknown account id is refused")
        } catch {
            XCTAssertEqual(error as? SyncRehearsal.RehearsalError, .unknownAccounts([999_999]))
        }
        // A copy already confirmed keeps its owners: choices given would be ignored, so they are refused.
        let confirmed = folder.appendingPathComponent("confirmed.sqlite").path
        try TestDatabase.demoManager(path: confirmed).dbQueue.close()
        let anyAccount = try XCTUnwrap(accounts.values.first)
        do {
            _ = try await SyncRehearsal.run(databasePath: confirmed, libraryPath: nil, ownership: RehearsalOwnership(levels: [anyAccount: .everything]))
            XCTFail("choices on a confirmed copy are refused")
        } catch {
            XCTAssertEqual(error as? SyncRehearsal.RehearsalError, .ownershipAlreadyConfirmed)
        }
    }

    func testOwnershipChoicesReadFromJSONAndFlags() throws {
        let json = Data(#"{"joint": [3], "levels": {"7": "everything", "9": "balanceOnly", "11": "categoryTotals", "12": "hidden"}}"#.utf8)
        let decoded = try JSONDecoder().decode(RehearsalOwnership.self, from: json)
        XCTAssertEqual(decoded, RehearsalOwnership(joint: [3], levels: [7: .everything, 9: .balanceOnly, 11: .categoryTotals, 12: .hidden]))
        XCTAssertEqual(try JSONDecoder().decode(RehearsalOwnership.self, from: Data("{}".utf8)), RehearsalOwnership())
        XCTAssertEqual(try JSONDecoder().decode(RehearsalOwnership.self, from: try JSONEncoder().encode(decoded)), decoded)
        XCTAssertThrowsError(try JSONDecoder().decode(RehearsalOwnership.self, from: Data(#"{"levels": {"7": "some"}}"#.utf8)))
        XCTAssertThrowsError(try JSONDecoder().decode(RehearsalOwnership.self, from: Data(#"{"levels": {"seven": "everything"}}"#.utf8)))

        var flags = RehearsalOwnership()
        try flags.addJoint("3")
        try flags.addLevel("7=everything")
        try flags.addLevel("9=balanceOnly")
        XCTAssertEqual(flags, RehearsalOwnership(joint: [3], levels: [7: .everything, 9: .balanceOnly]))
        XCTAssertThrowsError(try flags.addJoint("x")) { XCTAssertEqual($0 as? RehearsalOwnership.ParseError, .notAnAccountId("x")) }
        XCTAssertThrowsError(try flags.addLevel("7")) { XCTAssertEqual($0 as? RehearsalOwnership.ParseError, .notALevel("7")) }
        XCTAssertThrowsError(try flags.addLevel("7=Everything")) { XCTAssertEqual($0 as? RehearsalOwnership.ParseError, .notALevel("Everything")) }
    }

    /// Review I-3: a refused choice is reported with counts and kinds only, never a name, as a bad argument.
    func testARefusedChoicePrintsCountsOnly() async throws {
        let (database, _, _) = try unconfirmedDemo()
        let source = try DatabaseQueue(path: database)
        let (linked, names) = try await source.read { db -> (Int64, [String]) in
            let linked = try Int64.fetchOne(db, sql: "SELECT accountId FROM propertyAccount ORDER BY accountId LIMIT 1")!
            var names: [String] = []
            for sql in ["SELECT name FROM account", "SELECT name FROM property", "SELECT name FROM category", "SELECT name FROM person"] {
                names += try String.fetchAll(db, sql: sql)
            }
            return (linked, names.filter { $0.count >= 4 })
        }
        try source.close()
        XCTAssertGreaterThan(names.count, 20)
        do {
            _ = try await SyncRehearsal.run(databasePath: database, libraryPath: nil, ownership: RehearsalOwnership(levels: [linked: .hidden]))
            XCTFail("Hidden on a property-linked account is refused")
        } catch {
            guard case .choiceRefused(let account, let reasons)? = error as? SyncRehearsal.RehearsalError else {
                return XCTFail("refused as a choice, not \(type(of: error))")
            }
            XCTAssertEqual(account, linked)
            XCTAssertFalse(reasons.isEmpty)
            let failure = SyncRehearsal.failure(error)
            XCTAssertEqual(failure.exitCode, 2)
            XCTAssertTrue(failure.message.contains("\(linked)"), failure.message)
            for name in names { XCTAssertFalse(failure.message.contains(name), "the message names \(name)") }
        }
        // Any other error: its kind only, never its text (a database error can quote values).
        let leaky = DatabaseError(resultCode: .SQLITE_CONSTRAINT, message: "UNIQUE constraint failed: Synthetic Secret Name")
        let failure = SyncRehearsal.failure(leaky)
        XCTAssertEqual(failure.exitCode, 1)
        XCTAssertFalse(failure.message.contains("Synthetic Secret Name"), failure.message)
        XCTAssertEqual(SyncRehearsal.failure(SyncRehearsal.RehearsalError.unknownAccounts([7])).exitCode, 2)
        XCTAssertEqual(SyncRehearsal.failure(SyncRehearsal.RehearsalError.ownershipAlreadyConfirmed).exitCode, 2)
    }
}
