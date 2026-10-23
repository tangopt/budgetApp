import XCTest
import GRDB
@testable import BudgetCore

final class SyncChangeTrackerTests: XCTestCase {
    private var manager: DatabaseManager!
    private var tracker: SyncChangeTracker!

    override func setUpWithError() throws {
        manager = try DatabaseManager(path: nil)
        try manager.migrate()
        tracker = try SyncChangeTracker.install(on: manager.dbQueue)
    }

    private func insertAccount(_ db: Database, _ name: String = "Current") throws -> Int64 {
        var account = Account(name: name, currency: .gbp, kind: .cash, trackingMode: .imported)
        try account.insert(db)
        return account.id!
    }

    private func pending() throws -> [PendingChange] {
        try manager.dbQueue.read { db in try SyncChangeTracker.pending(db: db) }
    }

    // MARK: Identity

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

    func testBackfillGivesEveryRowOneStableUUID() throws {
        // A database written before tracking existed: rows in several tables, none with an identity.
        let plain = try DatabaseManager(path: nil)
        try plain.migrate()
        try plain.dbQueue.write { db in
            for name in ["A", "B", "C"] { _ = try insertAccount(db, name) }
            try db.execute(sql: "INSERT INTO person(name) VALUES ('Synthetic Person')")
        }
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
        }

        // Idempotent: nothing new, nothing changed.
        XCTAssertEqual(try plain.dbQueue.write { db in try SyncRecordStore.backfill(db: db) }, 0)
        let second = try plain.dbQueue.read { db in try SyncRecordRow.order(Column("tableName"), Column("localId")).fetchAll(db) }
        XCTAssertEqual(second, first)
        XCTAssertEqual(try plain.dbQueue.read { db in try SyncChangeTracker.pending(db: db).count }, expected)
    }

    func testEveryLocalIdIsTheRowId() throws {
        // The tracker identifies rows by the update hook's rowid: each synced table's local id must be it.
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
        try manager.dbQueue.write { db in try db.execute(sql: "UPDATE account SET alias = 'y' WHERE id = ?", arguments: [id]) }
        XCTAssertEqual(try pending().map(\.kind), [.update])
        XCTAssertEqual(try pending().first?.uuid, uuid)
    }

    func testAcknowledgeKeepsAChangeMadeSince() throws {
        let id = try manager.dbQueue.write { db in try insertAccount(db) }
        let sent = try pending()
        try manager.dbQueue.write { db in try db.execute(sql: "UPDATE account SET alias = 'later' WHERE id = ?", arguments: [id]) }
        try manager.dbQueue.write { db in try SyncChangeTracker.acknowledge(sent, db: db) }
        XCTAssertEqual(try pending().count, 1, "the edit after the upload began is still pending")
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
        // A whole transaction rolled back (ImportUndo.conflicts(dbQueue:)), and a rolled-back savepoint
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
            XCTAssertEqual(try SyncChangeTracker.pending(db: db),
                           [PendingChange(table: "account", localId: id, uuid: uuid, kind: .delete,
                                          revision: try SyncChangeTracker.pending(db: db).first!.revision)])
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
        let (propertyId, child) = try manager.dbQueue.write { db -> (Int64, Int64) in
            try db.execute(sql: "INSERT INTO property(name, country) VALUES ('Synthetic flat', 'PT')")
            let propertyId = db.lastInsertedRowID
            try db.execute(sql: "INSERT INTO propertyMortgageTerms(propertyId) VALUES (?)", arguments: [propertyId])
            return (propertyId, propertyId)
        }
        let uuids = try pending().map(\.uuid)
        XCTAssertEqual(uuids.count, 2)
        try manager.dbQueue.write { db in try db.execute(sql: "DELETE FROM property WHERE id = ?", arguments: [propertyId]) }
        try manager.dbQueue.read { db in
            let tombstones = try SyncTombstoneRow.fetchAll(db)
            XCTAssertEqual(Set(tombstones.map(\.uuid)), Set(uuids))
            XCTAssertTrue(tombstones.contains { $0.tableName == "propertyMortgageTerms" && $0.localId == child })
        }
    }

    func testWriterAndTimeAreStamped() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let other = try DatabaseManager(path: nil)
        try other.migrate()
        let stamped = try SyncChangeTracker.install(on: other.dbQueue, now: { now })
        stamped.modifiedBy = "USER-UUID"
        let id = try other.dbQueue.write { db in try insertAccount(db) }
        let row = try other.dbQueue.read { db in
            try SyncRecordRow.fetchOne(db, sql: "SELECT * FROM syncRecord WHERE tableName = 'account' AND localId = ?", arguments: [id])
        }
        XCTAssertEqual(row?.modifiedBy, "USER-UUID")
        XCTAssertEqual(row?.modifiedAt, now)
    }

    func testIgnoredChangesAreNotTracked() throws {
        // Incoming records applied by the engine must not echo back as pending changes.
        try manager.dbQueue.write { db in
            try tracker.ignoringChanges { _ = try insertAccount(db, "Incoming") }
        }
        XCTAssertEqual(try pending(), [])
        try manager.dbQueue.write { db in _ = try insertAccount(db, "Local") }
        XCTAssertEqual(try pending().count, 1)
    }

    func testTrackerSurvivesReopen() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("SyncTracker-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("db.sqlite").path

        var written: [PendingChange] = []
        do {
            let first = try DatabaseManager(path: path)
            try first.migrate()
            _ = try SyncChangeTracker.install(on: first.dbQueue)
            try first.dbQueue.write { db in
                _ = try insertAccount(db, "One")
                _ = try insertAccount(db, "Two")
            }
            written = try first.dbQueue.read { db in try SyncChangeTracker.pending(db: db) }
            XCTAssertEqual(written.count, 2)
            try first.dbQueue.close()
        }
        let second = try DatabaseManager(path: path)
        try second.migrate()
        _ = try SyncChangeTracker.install(on: second.dbQueue)
        XCTAssertEqual(try second.dbQueue.read { db in try SyncChangeTracker.pending(db: db) }, written)
        try second.dbQueue.write { db in try db.execute(sql: "UPDATE account SET alias = 'z' WHERE id = ?", arguments: [written[0].localId]) }
        let after = try second.dbQueue.read { db in try SyncChangeTracker.pending(db: db) }
        XCTAssertEqual(after.map(\.uuid), written.map(\.uuid), "the same records, in the same order")
        XCTAssertGreaterThan(after[0].revision, written[1].revision, "revisions keep counting after a reopen")
    }

    // MARK: Import capture (ruling R3)

    func testSyncWriteDuringImportCaptureSurvivesUndo() throws {
        let plain = try DatabaseManager(path: nil)
        try plain.migrate()
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("SyncUndo-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let library = EvidenceLibrary(root: base.appendingPathComponent("Evidence", isDirectory: true), database: plain.dbQueue)
        let accountId = try plain.dbQueue.write { db in try insertAccount(db) }

        let (runId, uuid) = try plain.dbQueue.write { db -> (Int64, String) in
            var run = ImportRun(confirmedAt: Date(), entryPoint: "Import…", summary: "s")
            try run.insert(db)
            try ImportChangeCapture.begin(db: db)
            try db.execute(sql: "UPDATE account SET alias = 'imported' WHERE id = ?", arguments: [accountId])
            let uuid = try SyncRecordStore.uuid(for: "account", localId: accountId, db: db)
            try SyncStateRow(key: "engine", value: Data([9]), updatedAt: Date()).insert(db)
            let changes = try ImportChangeCapture.finish(db: db, runId: run.id!)
            XCTAssertFalse(changes.contains { $0.tableName.hasPrefix("sync") }, "sync bookkeeping is not logged")
            return (run.id!, uuid)
        }
        _ = try ImportUndo.undo(dbQueue: plain.dbQueue, library: library, runId: runId)
        try plain.dbQueue.read { db in
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT alias FROM account WHERE id = ?", arguments: [accountId]), nil)
            XCTAssertEqual(try SyncRecordStore.localId(table: "account", uuid: uuid, db: db), accountId)
            XCTAssertEqual(try SyncStateRow.fetchOne(db, key: "engine")?.value, Data([9]))
        }
        for table in ["syncRecord", "syncStaging", "syncConflict", "syncTombstone", "syncState"] {
            XCTAssertTrue(ImportChangeCapture.untrackedTables.contains(table), table)
        }
    }

    func testUndoOfATrackedImportTombstonesWhatItAdded() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("SyncUndo-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let library = EvidenceLibrary(root: base.appendingPathComponent("Evidence", isDirectory: true), database: manager.dbQueue)
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
}
