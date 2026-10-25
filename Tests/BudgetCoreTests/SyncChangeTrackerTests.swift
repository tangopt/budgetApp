import XCTest
import GRDB
import SQLite3
@testable import BudgetCore

final class SyncChangeTrackerTests: XCTestCase {
    private var manager: DatabaseManager!
    private var folder: URL!

    override func setUpWithError() throws {
        manager = try DatabaseManager(path: nil)
        try manager.migrate()
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("SyncTracker-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func insertAccount(_ db: Database, _ name: String = "Current") throws -> Int64 {
        var account = Account(name: name, currency: .gbp, kind: .cash, trackingMode: .imported)
        try account.insert(db)
        return account.id!
    }

    private func pending(_ queue: DatabaseQueue? = nil) throws -> [PendingChange] {
        try (queue ?? manager.dbQueue).read { db in try SyncChangeTracker.pending(db: db) }
    }

    private func clocks(_ table: String, _ id: Int64, _ queue: DatabaseQueue? = nil) throws -> [String: Row] {
        try (queue ?? manager.dbQueue).read { db in
            Dictionary(uniqueKeysWithValues: try Row.fetchAll(db, sql: "SELECT * FROM syncFieldClock WHERE tableName = ? AND localId = ?",
                                                              arguments: [table, id]).map { ($0["field"] as String, $0) })
        }
    }

    private func filePath() -> String { folder.appendingPathComponent("db-\(UUID().uuidString).sqlite").path }

    private static let uuidPattern = try! NSRegularExpression(pattern: "^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$")

    private func assertUUID(_ value: String, file: StaticString = #filePath, line: UInt = #line) {
        let range = NSRange(value.startIndex..., in: value)
        XCTAssertNotNil(Self.uuidPattern.firstMatch(in: value, range: range), "\(value) is not a lowercase v4 UUID", file: file, line: line)
    }

    // MARK: Identity

    func testUUIDsAreLowercaseVersion4() throws {
        let made = try manager.dbQueue.read { db in
            try String.fetchAll(db, sql: "WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 2000) SELECT \(SyncRecordStore.uuidSQL) FROM n")
        }
        XCTAssertEqual(made.count, 2000)
        XCTAssertEqual(Set(made).count, 2000)
        made.forEach { assertUUID($0) }
        XCTAssertEqual(Set(made.map { $0[$0.index($0.startIndex, offsetBy: 19)] }), ["8", "9", "a", "b"], "every variant digit appears")
        // Made by a trigger, and by Swift (a row written untracked).
        try manager.dbQueue.write { db in
            let id = try insertAccount(db)
            assertUUID(try SyncRecordStore.uuid(for: "account", localId: id, db: db))
            let untracked = try SyncChangeTracker.applyingIncoming(db: db) { try insertAccount(db, "Untracked") }
            assertUUID(try SyncRecordStore.uuid(for: "account", localId: untracked, db: db))
        }
    }

    func testUUIDIsCreatedOnFirstUseAndStable() throws {
        try manager.dbQueue.write { db in
            let id = try insertAccount(db)
            let first = try SyncRecordStore.uuid(for: "account", localId: id, db: db)
            XCTAssertEqual(try SyncRecordStore.uuid(for: "account", localId: id, db: db), first)
            XCTAssertEqual(try SyncRecordStore.localId(table: "account", uuid: first, db: db), id)
            XCTAssertNil(try SyncRecordStore.localId(table: "person", uuid: first, db: db))
            XCTAssertNil(try SyncRecordStore.localId(table: "account", uuid: "nope", db: db))
            XCTAssertEqual(try SyncRecordRow.fetchOne(db, sql: "SELECT * FROM syncRecord WHERE uuid = ?", arguments: [first])?.zone,
                           "household")
            XCTAssertThrowsError(try SyncRecordStore.uuid(for: "localSetting", localId: 1, db: db))
        }
    }

    func testUUIDForAnUntrackedRowQueuesItAndRefusesAMissingRow() throws {
        let id = try manager.dbQueue.write { db in
            try SyncChangeTracker.applyingIncoming(db: db) { try insertAccount(db, "Untracked") }
        }
        XCTAssertEqual(try pending(), [])
        let uuid = try manager.dbQueue.write { db in try SyncRecordStore.uuid(for: "account", localId: id, db: db) }
        XCTAssertEqual(try pending().map(\.uuid), [uuid])
        XCTAssertEqual(try pending().map(\.kind), [.insert], "a new identity is a record to send")
        try manager.dbQueue.write { db in
            XCTAssertThrowsError(try SyncRecordStore.uuid(for: "account", localId: 999_999, db: db)) { error in
                XCTAssertEqual(error as? SyncRecordStoreError, .noSuchRow(table: "account", localId: 999_999))
            }
            XCTAssertNil(try SyncRecordStore.existingUUID(table: "account", localId: 999_999, db: db))
        }
    }

    func testBackfillGivesEveryRowOneStableUUID() throws {
        // Rows written before the sync tables and their triggers existed: no identities.
        let plain = try DatabaseManager(path: nil)
        try plain.migrate(upTo: "createAppUser")
        try plain.dbQueue.write { db in
            for name in ["A", "B", "C"] {
                try db.execute(sql: "INSERT INTO account(name, currency, kind, trackingMode) VALUES (?, 'GBP', 'cash', 'imported')", arguments: [name])
            }
            try db.execute(sql: "INSERT INTO person(name) VALUES ('Synthetic Person')")
        }
        try plain.migrate()
        XCTAssertEqual(try plain.dbQueue.read { db in try SyncRecordRow.fetchCount(db) }, 0)
        let expected = try plain.dbQueue.read { db in
            try SyncSchema.tables.reduce(0) { sum, table in
                sum + (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \"\(table.name)\"") ?? 0)
            }
        }
        XCTAssertGreaterThan(expected, 4, "seeded rows count too")

        let assigned = try plain.dbQueue.write { db in try SyncRecordStore.backfill(db: db) }
        XCTAssertEqual(assigned, expected)
        let first = try plain.dbQueue.read { db in try SyncRecordRow.order(Column("tableName"), Column("localId")).fetchAll(db) }
        XCTAssertEqual(first.count, expected)
        XCTAssertEqual(Set(first.map(\.uuid)).count, expected, "UUIDs are distinct")
        XCTAssertTrue(first.allSatisfy { $0.zone == "household" })
        first.forEach { assertUUID($0.uuid) }
        try plain.dbQueue.read { db in
            for table in SyncSchema.tables {
                let missing = try Int.fetchOne(db, sql: """
                    SELECT COUNT(*) FROM "\(table.name)" t
                    WHERE NOT EXISTS (SELECT 1 FROM syncRecord s WHERE s.tableName = ? AND s.localId = t."\(table.localIdColumn)")
                    """, arguments: [table.name])
                XCTAssertEqual(missing, 0, table.name)
            }
            // The first upload sends everything: every backfilled row is a pending insert.
            let queued = try SyncChangeTracker.pending(db: db)
            XCTAssertEqual(queued.count, expected)
            XCTAssertTrue(queued.allSatisfy { $0.kind == .insert })
            XCTAssertEqual(Set(queued.map(\.revision)).count, expected, "revisions are distinct")
        }

        // Idempotent: nothing new, nothing changed.
        XCTAssertEqual(try plain.dbQueue.write { db in try SyncRecordStore.backfill(db: db) }, 0)
        let second = try plain.dbQueue.read { db in try SyncRecordRow.order(Column("tableName"), Column("localId")).fetchAll(db) }
        XCTAssertEqual(second, first)
        XCTAssertEqual(try pending(plain.dbQueue).count, expected)
        // An acknowledged record isn't queued again by a later backfill.
        try plain.dbQueue.write { db in try SyncChangeTracker.acknowledge(try SyncChangeTracker.pending(db: db), db: db) }
        XCTAssertEqual(try plain.dbQueue.write { db in try SyncRecordStore.backfill(db: db) }, 0)
        XCTAssertEqual(try pending(plain.dbQueue), [])
    }

    func testEveryLocalIdIsTheRowId() throws {
        // syncRecord.localId is the row's key; REPLACE and the sweep reason about rowids.
        try manager.dbQueue.read { db in
            for table in SyncSchema.tables {
                let withoutRowId = try String.fetchOne(db, sql: "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = ?",
                                                       arguments: [table.name])?.uppercased().contains("WITHOUT ROWID") ?? true
                XCTAssertFalse(withoutRowId, table.name)
                let pk = try Row.fetchAll(db, sql: "PRAGMA table_info(\"\(table.name)\")").filter { ($0["pk"] as Int) > 0 }
                XCTAssertEqual(pk.count, 1, "\(table.name) has a single-column key")
                XCTAssertEqual(pk.first?["name"], table.localIdColumn, table.name)
                XCTAssertEqual((pk.first?["type"] as String?)?.uppercased(), "INTEGER", "\(table.name).\(table.localIdColumn) aliases the rowid")
            }
        }
    }

    // MARK: Triggers

    func testInstalledTriggersMatchSyncSchema() throws {
        try manager.dbQueue.read { db in
            let installed = try Row.fetchAll(db, sql: "SELECT name, tbl_name, sql FROM sqlite_master WHERE type = 'trigger' AND name LIKE 'syncTrack\\_%' ESCAPE '\\'")
            var expected: Set<String> = []
            for table in SyncSchema.tables {
                expected.formUnion(["ins", "del", "key"].map { "syncTrack_\(table.name)_\($0)" })
                if table.syncedColumns.contains(where: { $0 != table.localIdColumn }) { expected.insert("syncTrack_\(table.name)_upd") }
            }
            XCTAssertEqual(Set(installed.map { $0["name"] as String }), expected)
            for row in installed {
                let name: String = row["name"], table: String = row["tbl_name"]
                XCTAssertNotNil(SyncSchema.table(table), "\(name) is on a synced table")
                XCTAssertTrue(name.hasPrefix("syncTrack_\(table)_"), name)
            }
            for table in SyncSchema.tables {
                let update = try String.fetchOne(db, sql: "SELECT sql FROM sqlite_master WHERE name = ?", arguments: ["syncTrack_\(table.name)_upd"]) ?? ""
                for column in table.syncedColumns where column != table.localIdColumn {
                    XCTAssertTrue(update.contains("NEW.\"\(column)\" IS NOT OLD.\"\(column)\""), "\(table.name).\(column) is watched")
                }
                for column in table.localOnlyColumns {
                    XCTAssertFalse(update.contains("\"\(column)\""), "\(table.name).\(column) is local-only")
                }
            }
            for table in SyncSchema.localOnlyTables {
                XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sqlite_master WHERE type = 'trigger' AND tbl_name = ? AND name LIKE 'syncTrack%'",
                                                arguments: [table]), 0, table)
            }
        }
        // Refreshing again changes nothing (no schema write on an ordinary open).
        let version = try manager.dbQueue.read { db in try Int.fetchOne(db, sql: "PRAGMA schema_version") }
        try manager.migrate()
        XCTAssertEqual(try manager.dbQueue.read { db in try Int.fetchOne(db, sql: "PRAGMA schema_version") }, version)
    }

    func testAddedColumnIsTrackedAfterRefresh() throws {
        let id = try manager.dbQueue.write { db -> Int64 in
            try db.execute(sql: "ALTER TABLE account ADD COLUMN somethingNew TEXT")
            return try insertAccount(db)
        }
        try manager.dbQueue.write { db in try SyncChangeTracker.acknowledge(try SyncChangeTracker.pending(db: db), db: db) }
        try manager.dbQueue.write { db in try db.execute(sql: "UPDATE account SET somethingNew = 'a' WHERE id = ?", arguments: [id]) }
        XCTAssertEqual(try pending(), [], "unlisted, so not watched yet")

        let schema = SyncSchema.tables.map { table -> SyncTableSchema in
            guard table.name == "account" else { return table }
            return SyncTableSchema(table.name, localIdColumn: table.localIdColumn, synced: table.syncedColumns + ["somethingNew"],
                                   foreignKeys: table.foreignKeys, localOnly: table.localOnlyColumns, batchKey: table.batchKey)
        }
        try manager.dbQueue.write { db in try SyncChangeTracker.refreshSyncTriggers(db: db, schema: schema) }
        try manager.dbQueue.write { db in try db.execute(sql: "UPDATE account SET somethingNew = 'b' WHERE id = ?", arguments: [id]) }
        XCTAssertEqual(try pending().map(\.kind), [.update])
        XCTAssertNotNil(try clocks("account", id)["somethingNew"])
        // Back to the real schema: the extra trigger text goes again.
        try manager.dbQueue.write { db in try SyncChangeTracker.refreshSyncTriggers(db: db) }
        let sql = try manager.dbQueue.read { db in try String.fetchOne(db, sql: "SELECT sql FROM sqlite_master WHERE name = 'syncTrack_account_upd'") }
        XCTAssertFalse(sql?.contains("somethingNew") ?? true)
    }

    func testRefreshSkipsWhatTheDatabaseDoesNotHaveYet() throws {
        // A schema listing a column and a table a later migration would add (as after migrate(upTo:)).
        var schema = SyncSchema.tables.map { table -> SyncTableSchema in
            guard table.name == "account" else { return table }
            return SyncTableSchema(table.name, localIdColumn: table.localIdColumn, synced: table.syncedColumns + ["notYet"],
                                   foreignKeys: table.foreignKeys, localOnly: table.localOnlyColumns, batchKey: table.batchKey)
        }
        schema.append(SyncTableSchema("notYetTable", synced: ["name"]))
        try manager.dbQueue.write { db in try SyncChangeTracker.refreshSyncTriggers(db: db, schema: schema) }
        try manager.dbQueue.read { db in
            let update = try String.fetchOne(db, sql: "SELECT sql FROM sqlite_master WHERE name = 'syncTrack_account_upd'") ?? ""
            XCTAssertTrue(update.contains("\"alias\""), "the columns that exist are still watched")
            XCTAssertFalse(update.contains("notYet"))
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sqlite_master WHERE name LIKE 'syncTrack_notYetTable%'"), 0)
        }
        // Writes still work and are tracked.
        let id = try manager.dbQueue.write { db in try insertAccount(db) }
        try manager.dbQueue.write { db in try db.execute(sql: "UPDATE account SET alias = 'ok' WHERE id = ?", arguments: [id]) }
        XCTAssertEqual(try pending().map(\.localId), [id])
    }

    func testSchemaHashIsPinnedToItsVersion() throws {
        // Changing SyncSchema or the trigger template changes the hash: bump SyncSchema.version and
        // update this pin, so an older build can tell its triggers are older than the database's.
        XCTAssertEqual(SyncSchema.version, 8)
        XCTAssertEqual(SyncChangeTracker.schemaHash(SyncSchema.tables), Self.pinnedHash)
    }

    func testOlderBuildLeavesANewerSchemasTriggers() throws {
        try manager.dbQueue.read { db in
            let stamp = try XCTUnwrap(try SyncChangeTracker.installedSchema(db: db))
            XCTAssertEqual(stamp.version, SyncSchema.version)
            XCTAssertEqual(stamp.hash, SyncChangeTracker.schemaHash(SyncSchema.tables))
        }
        // A newer build installed version + 1 with a column this build doesn't list.
        let newer = SyncSchema.tables.map { table -> SyncTableSchema in
            guard table.name == "account" else { return table }
            return SyncTableSchema(table.name, localIdColumn: table.localIdColumn, synced: table.syncedColumns.filter { $0 != "alias" },
                                   foreignKeys: table.foreignKeys, localOnly: table.localOnlyColumns, batchKey: table.batchKey)
        }
        try manager.dbQueue.write { db in try SyncChangeTracker.refreshSyncTriggers(db: db, schema: newer, version: SyncSchema.version + 1) }
        let installed = try manager.dbQueue.read { db in try String.fetchOne(db, sql: "SELECT sql FROM sqlite_master WHERE name = 'syncTrack_account_upd'") }
        let version = try manager.dbQueue.read { db in try Int.fetchOne(db, sql: "PRAGMA schema_version") }
        // This (older) build opens the database: it leaves the newer triggers alone.
        try manager.migrate()
        try manager.dbQueue.read { db in
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT sql FROM sqlite_master WHERE name = 'syncTrack_account_upd'"), installed)
            XCTAssertEqual(try Int.fetchOne(db, sql: "PRAGMA schema_version"), version)
            XCTAssertEqual(try SyncChangeTracker.installedSchema(db: db)?.version, SyncSchema.version + 1)
        }
    }

    // MARK: Tracking

    func testInsertUpdateAndDeleteAreTrackedAndCoalesced() throws {
        let id = try manager.dbQueue.write { db in try insertAccount(db) }
        var queued = try pending()
        XCTAssertEqual(queued.map(\.kind), [.insert])
        XCTAssertEqual(queued.first?.table, "account")
        XCTAssertEqual(queued.first?.localId, id)
        let uuid = try XCTUnwrap(queued.first?.uuid)
        XCTAssertEqual(try manager.dbQueue.read { db in try SyncRecordStore.localId(table: "account", uuid: uuid, db: db) }, id)

        try manager.dbQueue.write { db in try db.execute(sql: "UPDATE account SET alias = 'x' WHERE id = ?", arguments: [id]) }
        queued = try pending()
        XCTAssertEqual(queued.map(\.kind), [.insert], "an update to a row not yet sent stays an insert")

        try manager.dbQueue.write { db in try SyncChangeTracker.acknowledge(queued, db: db) }
        XCTAssertEqual(try pending(), [])
        try manager.dbQueue.write { db in try db.execute(sql: "UPDATE account SET alias = 'x' WHERE id = ?", arguments: [id]) }
        XCTAssertEqual(try pending(), [], "an update that changes nothing isn't a change")
        try manager.dbQueue.write { db in try db.execute(sql: "UPDATE account SET alias = 'y' WHERE id = ?", arguments: [id]) }
        XCTAssertEqual(try pending().map(\.kind), [.update])
        XCTAssertEqual(try pending().first?.uuid, uuid)
        try manager.dbQueue.write { db in try db.execute(sql: "DELETE FROM account WHERE id = ?", arguments: [id]) }
        XCTAssertEqual(try pending().map(\.kind), [.delete], "a delete replaces what was queued")
    }

    func testFieldClocksRecordWhatChangedAndWho() throws {
        let start = Date().addingTimeInterval(-1)
        let id = try manager.dbQueue.write { db -> Int64 in
            try SyncChangeTracker.setWriter("user-uuid", db: db)
            return try insertAccount(db)
        }
        var clock = try clocks("account", id)
        XCTAssertEqual(Set(clock.keys), ["*"], "an insert dates every field at once")
        let inserted: Date = try XCTUnwrap(clock["*"]?["modifiedAt"])
        XCTAssertGreaterThanOrEqual(inserted, start)
        XCTAssertLessThanOrEqual(inserted, Date().addingTimeInterval(1))
        XCTAssertEqual(clock["*"]?["modifiedBy"], "user-uuid")
        let record = try manager.dbQueue.read { db in try SyncRecordRow.fetchOne(db, sql: "SELECT * FROM syncRecord WHERE tableName = 'account' AND localId = ?", arguments: [id]) }
        XCTAssertEqual(record?.modifiedBy, "user-uuid")
        XCTAssertNotNil(record?.modifiedAt)

        try manager.dbQueue.write { db in
            try SyncChangeTracker.setWriter(nil, db: db)
            try db.execute(sql: "UPDATE account SET alias = 'x', sortOrder = sortOrder WHERE id = ?", arguments: [id])
        }
        clock = try clocks("account", id)
        XCTAssertEqual(Set(clock.keys), ["*", "alias"], "only the column that changed")
        XCTAssertNil(clock["alias"]?["modifiedBy"] as String?, "signed out: no writer")
        XCTAssertEqual(clock["*"]?["modifiedBy"], "user-uuid")

        try manager.dbQueue.write { db in try db.execute(sql: "DELETE FROM account WHERE id = ?", arguments: [id]) }
        XCTAssertEqual(try clocks("account", id), [:])
    }

    func testCaseOnlyRenameOfANoCaseColumnIsTracked() throws {
        // person.name is COLLATE NOCASE: the comparison must still see "ana" -> "Ana".
        let id = try manager.dbQueue.write { db -> Int64 in
            try db.execute(sql: "INSERT INTO person(name) VALUES ('synthetic ana')")
            return db.lastInsertedRowID
        }
        try manager.dbQueue.write { db in try SyncChangeTracker.acknowledge(try SyncChangeTracker.pending(db: db), db: db) }
        try manager.dbQueue.write { db in try db.execute(sql: "UPDATE person SET name = 'Synthetic Ana' WHERE id = ?", arguments: [id]) }
        XCTAssertEqual(try pending().map(\.kind), [.update])
        XCTAssertNotNil(try clocks("person", id)["name"])
    }

    func testLocalOnlyColumnChangeIsNotTracked() throws {
        let runId = try manager.dbQueue.write { db -> Int64 in
            var run = ImportRun(confirmedAt: Date(), entryPoint: "Import…", summary: "s")
            try run.insert(db)
            return run.id!
        }
        try manager.dbQueue.write { db in try SyncChangeTracker.acknowledge(try SyncChangeTracker.pending(db: db), db: db) }
        try manager.dbQueue.write { db in try db.execute(sql: "UPDATE importRun SET backupPath = '/synthetic/backup' WHERE id = ?", arguments: [runId]) }
        XCTAssertEqual(try pending(), [])
        // The insert's clock and the base the acknowledge took from it; nothing for the local-only column.
        XCTAssertEqual(Set(try clocks("importRun", runId).keys), ["*", SyncMerge.basePrefix + "*"])
    }

    func testAcknowledgeStampsOnlyWhatTheServerTook() throws {
        let (taken, edited) = try manager.dbQueue.write { db in (try insertAccount(db, "Taken"), try insertAccount(db, "Edited")) }
        let sent = try pending()
        try manager.dbQueue.write { db in try db.execute(sql: "UPDATE account SET alias = 'during upload' WHERE id = ?", arguments: [edited]) }
        try manager.dbQueue.write { db in try SyncChangeTracker.acknowledge(sent, db: db) }
        XCTAssertNotNil(try clocks("account", taken)[SyncMerge.basePrefix + "*"])
        XCTAssertNil(try clocks("account", edited)[SyncMerge.basePrefix + "*"], "an edit made during the upload is still unsent")
        XCTAssertEqual(try pending().map(\.localId), [edited])
    }

    func testAcknowledgeKeepsAChangeMadeSince() throws {
        let id = try manager.dbQueue.write { db in try insertAccount(db) }
        let sent = try pending()
        try manager.dbQueue.write { db in try db.execute(sql: "UPDATE account SET alias = 'later' WHERE id = ?", arguments: [id]) }
        try manager.dbQueue.write { db in try SyncChangeTracker.acknowledge(sent, db: db) }
        XCTAssertEqual(try pending().count, 1, "the edit after the upload began is still pending")
        try manager.dbQueue.write { db in try SyncChangeTracker.acknowledge(try SyncChangeTracker.pending(db: db), db: db) }
        XCTAssertEqual(try pending(), [])
    }

    func testLocalOnlyWritesAreNotTracked() throws {
        try manager.dbQueue.write { db in
            try db.execute(sql: "INSERT INTO localSetting(key, value) VALUES ('k', 'v')")
            try db.execute(sql: "INSERT INTO sourceFolder(path, bookmark, name) VALUES ('/synthetic', x'00', 'Synthetic')")
            try SyncStateRow(key: "engine", value: Data([1]), updatedAt: Date()).insert(db)
        }
        XCTAssertEqual(try pending(), [])
        XCTAssertEqual(try manager.dbQueue.read { db in try SyncRecordRow.fetchCount(db) }, 0)
    }

    func testRolledBackWritesLeaveNothingPending() throws {
        // A whole transaction rolled back (ImportUndo.conflicts(dbQueue:)), and rolled-back savepoints
        // inside a committed one (the filed-year guard's simulations).
        try manager.dbQueue.inTransaction { db in
            _ = try insertAccount(db, "Rolled back")
            return .rollback
        }
        let kept = try manager.dbQueue.write { db -> Int64 in
            try db.inSavepoint {
                _ = try insertAccount(db, "Simulated")
                try db.inSavepoint {
                    _ = try insertAccount(db, "Nested simulation")
                    return .rollback
                }
                return .rollback
            }
            return try insertAccount(db, "Kept")
        }
        XCTAssertEqual(try pending().map(\.localId), [kept])
        XCTAssertEqual(try manager.dbQueue.read { db in try SyncRecordRow.fetchCount(db) }, 1)
        XCTAssertEqual(try manager.dbQueue.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM syncFieldClock") }, 1)
    }

    func testChangeAndPendingCommitTogetherOrNotAtAll() throws {
        let path = filePath()
        let setup = try DatabaseManager(path: path)
        try setup.migrate()
        try setup.dbQueue.close()

        // A writer that dies mid-transaction (a bare SQLite connection closed without committing, as
        // a crash leaves it): neither the row nor its pending entry survives.
        var raw: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(path, &raw, SQLITE_OPEN_READWRITE, nil), SQLITE_OK)
        func exec(_ sql: String) { XCTAssertEqual(sqlite3_exec(raw, sql, nil, nil, nil), SQLITE_OK, String(cString: sqlite3_errmsg(raw))) }
        func count(_ sql: String) -> Int32 {
            var statement: OpaquePointer?
            sqlite3_prepare_v2(raw, sql, -1, &statement, nil)
            defer { sqlite3_finalize(statement) }
            return sqlite3_step(statement) == SQLITE_ROW ? sqlite3_column_int(statement, 0) : -1
        }
        exec("BEGIN IMMEDIATE")
        exec("INSERT INTO account(name, currency, kind, trackingMode) VALUES ('Never committed', 'GBP', 'cash', 'imported')")
        XCTAssertEqual(count("SELECT COUNT(*) FROM syncPending"), 1, "queued inside the same transaction")
        XCTAssertEqual(count("SELECT COUNT(*) FROM syncRecord"), 1)
        XCTAssertEqual(sqlite3_close_v2(raw), SQLITE_OK)

        let after = try DatabaseQueue(path: path)
        try after.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM account WHERE name = 'Never committed'"), 0)
            XCTAssertEqual(try SyncChangeTracker.pending(db: db), [])
            XCTAssertEqual(try SyncRecordRow.fetchCount(db), 0)
        }
        // Committed: both.
        let id = try after.write { db in try insertAccount(db, "Committed") }
        try after.close()
        let reopened = try DatabaseQueue(path: path)
        XCTAssertEqual(try pending(reopened).map(\.localId), [id])
        try reopened.close()
    }

    func testWriteThroughAnIndependentQueueIsTracked() throws {
        // A one-off tool opens its own queue on the file, without DatabaseManager.
        let path = filePath()
        let app = try DatabaseManager(path: path)
        try app.migrate()
        let tool = try DatabaseQueue(path: path)
        let id = try tool.write { db -> Int64 in
            let id = try insertAccount(db, "From a tool")
            try db.execute(sql: "UPDATE account SET alias = 'tool' WHERE id = ?", arguments: [id])
            return id
        }
        try tool.close()
        let queued = try pending(app.dbQueue)
        XCTAssertEqual(queued.map(\.localId), [id])
        XCTAssertEqual(queued.map(\.kind), [.insert])
        XCTAssertNil(try app.dbQueue.read { db in
            try SyncRecordRow.fetchOne(db, sql: "SELECT * FROM syncRecord WHERE tableName = 'account' AND localId = ?", arguments: [id])
        }?.modifiedBy, "no one signed in")
    }

    func testDeleteLeavesATombstone() throws {
        let id = try manager.dbQueue.write { db in try insertAccount(db) }
        let uuid = try XCTUnwrap(try pending().first?.uuid)
        try manager.dbQueue.write { db in try SyncChangeTracker.acknowledge(try SyncChangeTracker.pending(db: db), db: db) }

        try manager.dbQueue.write { db in try db.execute(sql: "DELETE FROM account WHERE id = ?", arguments: [id]) }
        try manager.dbQueue.read { db in
            let tombstone = try XCTUnwrap(try SyncTombstoneRow.fetchOne(db, key: uuid))
            XCTAssertEqual(tombstone.tableName, "account")
            XCTAssertEqual(tombstone.localId, id)
            XCTAssertEqual(tombstone.zone, "household")
            XCTAssertNil(try SyncRecordStore.localId(table: "account", uuid: uuid, db: db), "the identity is retired")
            let queued = try SyncChangeTracker.pending(db: db)
            XCTAssertEqual(queued.map(\.uuid), [uuid])
            XCTAssertEqual(queued.map(\.kind), [.delete])
        }

        // A new row that reuses the local id is a different record.
        let reused = try manager.dbQueue.write { db -> Int64 in
            var account = Account(id: id, name: "Again", currency: .gbp, kind: .cash, trackingMode: .imported)
            try account.insert(db)
            return account.id!
        }
        XCTAssertEqual(reused, id)
        let fresh = try manager.dbQueue.write { db in try SyncRecordStore.uuid(for: "account", localId: id, db: db) }
        XCTAssertNotEqual(fresh, uuid)
        XCTAssertEqual(Set(try pending().map(\.kind)), [.delete, .insert])
    }

    func testCascadeDeleteLeavesTombstonesForChildren() throws {
        let propertyId = try manager.dbQueue.write { db -> Int64 in
            try db.execute(sql: "INSERT INTO property(name, country) VALUES ('Synthetic flat', 'PT')")
            let propertyId = db.lastInsertedRowID
            try db.execute(sql: "INSERT INTO propertyMortgageTerms(propertyId) VALUES (?)", arguments: [propertyId])
            return propertyId
        }
        let uuids = try pending().map(\.uuid)
        XCTAssertEqual(uuids.count, 2)
        try manager.dbQueue.write { db in try db.execute(sql: "DELETE FROM property WHERE id = ?", arguments: [propertyId]) }
        try manager.dbQueue.read { db in
            let tombstones = try SyncTombstoneRow.fetchAll(db)
            XCTAssertEqual(Set(tombstones.map(\.uuid)), Set(uuids))
            XCTAssertTrue(tombstones.contains { $0.tableName == "propertyMortgageTerms" && $0.localId == propertyId })
        }
    }

    func testReplaceOfARowWithAnotherRowIdLeavesATombstone() throws {
        // `property.name` is unique: REPLACE removes the old row (another rowid) and inserts a new one.
        func replace(_ queue: DatabaseQueue) throws -> (old: String, new: Int64) {
            let old = try queue.write { db -> String in
                try db.execute(sql: "INSERT INTO property(name, country) VALUES ('Replaced', 'PT')")
                return try SyncRecordStore.uuid(for: "property", localId: db.lastInsertedRowID, db: db)
            }
            let new = try queue.write { db -> Int64 in
                try db.execute(sql: "INSERT OR REPLACE INTO property(id, name, country) VALUES (500, 'Replaced', 'GB')")
                return db.lastInsertedRowID
            }
            return (old, new)
        }
        // The app's connection (recursive triggers on): at once.
        let (old, new) = try replace(manager.dbQueue)
        XCTAssertEqual(new, 500)
        try manager.dbQueue.read { db in
            XCTAssertNotNil(try SyncTombstoneRow.fetchOne(db, key: old))
            XCTAssertEqual(Set(try SyncChangeTracker.pending(db: db).filter { $0.table == "property" }.map(\.kind)), [.delete, .insert])
        }

        // A tool's connection (recursive triggers off): swept on the next open.
        let path = filePath()
        let app = try DatabaseManager(path: path)
        try app.migrate()
        try app.dbQueue.close()
        let tool = try DatabaseQueue(path: path)
        let (toolOld, _) = try replace(tool)
        XCTAssertNil(try tool.read { db in try SyncTombstoneRow.fetchOne(db, key: toolOld) })
        try tool.close()
        let reopened = try DatabaseManager(path: path)
        try reopened.migrate()
        try reopened.dbQueue.read { db in
            XCTAssertNotNil(try SyncTombstoneRow.fetchOne(db, key: toolOld))
            XCTAssertNil(try SyncRecordStore.localId(table: "property", uuid: toolOld, db: db))
            XCTAssertTrue(try SyncChangeTracker.pending(db: db).contains { $0.uuid == toolOld && $0.kind == .delete })
        }
    }

    func testPrimaryKeyUpdateIsRefused() throws {
        let id = try manager.dbQueue.write { db in try insertAccount(db) }
        XCTAssertThrowsError(try manager.dbQueue.write { db in
            try db.execute(sql: "UPDATE account SET id = 4242 WHERE id = ?", arguments: [id])
        }) { error in
            XCTAssertTrue("\(error)".contains("account.id is a sync identity and cannot change"), "\(error)")
        }
        try manager.dbQueue.write { db in try db.execute(sql: "UPDATE account SET id = id, alias = 'same id' WHERE id = ?", arguments: [id]) }
        XCTAssertEqual(try manager.dbQueue.read { db in try String.fetchOne(db, sql: "SELECT alias FROM account WHERE id = ?", arguments: [id]) }, "same id")
    }

    func testTrackerSurvivesReopen() throws {
        let path = filePath()
        var written: [PendingChange] = []
        do {
            let first = try DatabaseManager(path: path)
            try first.migrate()
            try first.dbQueue.write { db in
                _ = try insertAccount(db, "One")
                _ = try insertAccount(db, "Two")
            }
            written = try pending(first.dbQueue)
            XCTAssertEqual(written.count, 2)
            try first.dbQueue.close()
        }
        let second = try DatabaseManager(path: path)
        try second.migrate()
        XCTAssertEqual(try pending(second.dbQueue), written)
        try second.dbQueue.write { db in try db.execute(sql: "UPDATE account SET alias = 'z' WHERE id = ?", arguments: [written[0].localId]) }
        let after = try pending(second.dbQueue)
        XCTAssertEqual(after.map(\.uuid), written.map(\.uuid), "the same records, in the same order")
        XCTAssertGreaterThan(after[0].revision, written[1].revision, "revisions keep counting after a reopen")
    }

    // MARK: Incoming applies

    /// Re-filing an apply makes is tracked (it must reach the other devices), except on a read-only device, which
    /// never sends anything: there it would only pile up pending rows (final review M4).
    func testTrackedWritesInsideAReadOnlyApplyQueueNothing() throws {
        try manager.dbQueue.write { db in
            try SyncChangeTracker.applyingIncoming(db: db) {
                _ = try SyncChangeTracker.trackingWrites(db: db) { try insertAccount(db, "Re-filed here") }
            }
        }
        XCTAssertEqual(try pending().count, 1, "a writable device sends what it re-filed")
        try manager.dbQueue.write { db in
            try SyncChangeTracker.readOnlyApply(db: db) {
                try SyncChangeTracker.applyingIncoming(db: db) {
                    _ = try SyncChangeTracker.trackingWrites(db: db) { try insertAccount(db, "Re-filed on the phone") }
                }
            }
            XCTAssertFalse(try SyncChangeTracker.inReadOnlyApply(db: db), "the marker goes with the apply")
        }
        XCTAssertEqual(try pending().count, 1, "a read-only device queues nothing")
    }

    func testIncomingApplyIsNotTracked() throws {
        try manager.dbQueue.write { db in
            try SyncChangeTracker.applyingIncoming(db: db) {
                _ = try insertAccount(db, "Incoming")
                try SyncChangeTracker.applyingIncoming(db: db) { _ = try insertAccount(db, "Nested") }
                XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM syncApplying"), 1, "still applying after a nested apply")
            }
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM syncApplying"), 0)
            _ = try insertAccount(db, "Local, same transaction")
        }
        XCTAssertEqual(try pending().count, 1)
        try manager.dbQueue.write { db in _ = try insertAccount(db, "Local") }
        XCTAssertEqual(try pending().count, 2)
    }

    func testApplyMarkerCannotOutliveItsTransaction() throws {
        struct Failure: Error {}
        // A failing apply whose error is caught, and its transaction committed anyway.
        try manager.dbQueue.write { db in
            XCTAssertThrowsError(try SyncChangeTracker.applyingIncoming(db: db) {
                _ = try insertAccount(db, "Half applied")
                throw Failure()
            })
        }
        XCTAssertEqual(try manager.dbQueue.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM syncApplying") }, 0)
        // Outside a transaction it refuses (the marker would commit on its own).
        try manager.dbQueue.writeWithoutTransaction { db in
            XCTAssertThrowsError(try SyncChangeTracker.applyingIncoming(db: db) {}) { error in
                XCTAssertEqual(error as? SyncChangeTrackerError, .notInTransaction)
            }
        }
        XCTAssertEqual(try manager.dbQueue.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM syncApplying") }, 0)
        // A marker left in the file by any other route is cleared on the next open.
        let path = filePath()
        let app = try DatabaseManager(path: path)
        try app.migrate()
        try app.dbQueue.write { db in try db.execute(sql: "INSERT INTO syncApplying(id) VALUES (1)") }
        try app.dbQueue.close()
        let reopened = try DatabaseManager(path: path)
        try reopened.migrate()
        let id = try reopened.dbQueue.write { db in try insertAccount(db) }
        XCTAssertEqual(try pending(reopened.dbQueue).map(\.localId), [id])
    }

    // MARK: Import capture (ruling R3)

    func testSyncWriteDuringImportCaptureSurvivesUndo() throws {
        let library = EvidenceLibrary(root: folder.appendingPathComponent("Evidence", isDirectory: true), database: manager.dbQueue)
        let accountId = try manager.dbQueue.write { db in try insertAccount(db) }
        let uuid = try manager.dbQueue.write { db in try SyncRecordStore.uuid(for: "account", localId: accountId, db: db) }

        // A person with no identity yet (applied untracked); the import gives it one without changing it.
        let personId = try manager.dbQueue.write { db -> Int64 in
            try SyncChangeTracker.applyingIncoming(db: db) {
                try db.execute(sql: "INSERT INTO person(name) VALUES ('Synthetic Person')")
                return db.lastInsertedRowID
            }
        }
        try manager.dbQueue.write { db in try SyncChangeTracker.acknowledge(try SyncChangeTracker.pending(db: db), db: db) }

        var during: (aliasClock: Date, accountRevision: Int64, personUuid: String, personRevision: Int64)!
        let runId = try manager.dbQueue.write { db -> Int64 in
            var run = ImportRun(confirmedAt: Date(), entryPoint: "Import…", summary: "s")
            try run.insert(db)
            try ImportChangeCapture.begin(db: db)
            try db.execute(sql: "UPDATE account SET alias = 'imported' WHERE id = ?", arguments: [accountId])
            let personUuid = try SyncRecordStore.uuid(for: "person", localId: personId, db: db)
            try SyncStateRow(key: "engine", value: Data([9]), updatedAt: Date()).insert(db)
            try SyncChangeTracker.setWriter("user-uuid", db: db)
            let queued = try SyncChangeTracker.pending(db: db)
            during = (try Date.fetchOne(db, sql: "SELECT modifiedAt FROM syncFieldClock WHERE tableName = 'account' AND localId = ? AND field = 'alias'",
                                        arguments: [accountId])!,
                      queued.first { $0.uuid == uuid }!.revision, personUuid, queued.first { $0.uuid == personUuid }!.revision)
            let changes = try ImportChangeCapture.finish(db: db, runId: run.id!)
            XCTAssertEqual(changes.map(\.tableName), ["account"], "sync bookkeeping is not logged")
            return run.id!
        }
        _ = try ImportUndo.undo(dbQueue: manager.dbQueue, library: library, runId: runId)
        try manager.dbQueue.read { db in
            XCTAssertNil(try String.fetchOne(db, sql: "SELECT alias FROM account WHERE id = ?", arguments: [accountId]))
            XCTAssertEqual(try SyncRecordStore.localId(table: "account", uuid: uuid, db: db), accountId)
            XCTAssertEqual(try SyncStateRow.fetchOne(db, key: "engine")?.value, Data([9]))
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT appUserUuid FROM syncWriter"), "user-uuid")
            // The import's field clock is kept (the undo moves it on), and so is its revision (likewise).
            let aliasClock = try XCTUnwrap(try Date.fetchOne(db, sql: "SELECT modifiedAt FROM syncFieldClock WHERE tableName = 'account' AND localId = ? AND field = 'alias'",
                                                             arguments: [accountId]))
            XCTAssertGreaterThanOrEqual(aliasClock, during.aliasClock)
            let queued = try SyncChangeTracker.pending(db: db)
            XCTAssertEqual(queued.first { $0.uuid == uuid }?.kind, .update, "the undo is itself a change to send")
            XCTAssertGreaterThan(try XCTUnwrap(queued.first { $0.uuid == uuid }?.revision), during.accountRevision)
            // What the undo doesn't touch is exactly as the import left it.
            XCTAssertEqual(try SyncRecordStore.localId(table: "person", uuid: during.personUuid, db: db), personId)
            XCTAssertEqual(queued.first { $0.uuid == during.personUuid },
                           PendingChange(table: "person", localId: personId, uuid: during.personUuid, kind: .insert, revision: during.personRevision))
        }
        for table in SyncSchema.localOnlyTables where table.hasPrefix("sync") {
            XCTAssertTrue(ImportChangeCapture.untrackedTables.contains(table), table)
        }
    }

    func testUndoOfAnImportTombstonesWhatItAdded() throws {
        let library = EvidenceLibrary(root: folder.appendingPathComponent("Evidence", isDirectory: true), database: manager.dbQueue)
        let (runId, added) = try manager.dbQueue.write { db -> (Int64, Int64) in
            var run = ImportRun(confirmedAt: Date(), entryPoint: "Import…", summary: "s")
            try run.insert(db)
            try ImportChangeCapture.begin(db: db)
            let id = try insertAccount(db, "Imported")
            _ = try ImportChangeCapture.finish(db: db, runId: run.id!)
            return (run.id!, id)
        }
        let uuid = try manager.dbQueue.write { db in try SyncRecordStore.uuid(for: "account", localId: added, db: db) }
        // The conflict check simulates the undo in a rolled-back transaction: no tombstone from it.
        XCTAssertEqual(try ImportUndo.conflicts(dbQueue: manager.dbQueue, runId: runId), [])
        XCTAssertEqual(try manager.dbQueue.read { db in try SyncTombstoneRow.fetchCount(db) }, 0)
        _ = try ImportUndo.undo(dbQueue: manager.dbQueue, library: library, runId: runId)
        try manager.dbQueue.read { db in
            XCTAssertNotNil(try SyncTombstoneRow.fetchOne(db, key: uuid))
            XCTAssertTrue(try SyncChangeTracker.pending(db: db).contains { $0.uuid == uuid && $0.kind == .delete })
        }
    }

    /// `SyncChangeTracker.schemaHash(SyncSchema.tables)` for `SyncSchema.version` 8.
    private static let pinnedHash = "fb1a98a1eb783ec74ad677b925bc99bf00a077192a44a7e91d8390b440b13fa6"
}
