import XCTest
import GRDB
@testable import BudgetCore
import TestSupport

/// Step 6 task 1: ownership, levels and summary storage, and the write origin the triggers stamp.
final class SharingStorageTests: XCTestCase {
    /// The last migration before step 6.
    private static let preSharingMigration = "createImportWaitingFile"
    private static let newAccountColumns: Set<String> = ["ownerPersonId", "sharingLevel"]

    private func tableInfo(_ db: Database) throws -> [String: [Row]] {
        let tables = try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name")
        return Dictionary(uniqueKeysWithValues: try tables.map { name in
            (name, try Row.fetchAll(db, sql: "SELECT * FROM pragma_table_info(?)", arguments: [name]))
        })
    }

    func testMigrationAddsColumnsWithEverythingAndNoOwner() throws {
        let manager = try DatabaseManager(path: nil)
        try manager.migrate(upTo: Self.preSharingMigration)
        let before = try manager.dbQueue.write { db -> [Row] in
            XCTAssertFalse(try db.columns(in: "account").map(\.name).contains("sharingLevel"))
            for (name, currency) in [("Synthetic A", "gbp"), ("Synthetic B", "eur"), ("Synthetic C", "gbp")] {
                try db.execute(sql: "INSERT INTO account(name, currency, kind, trackingMode, alias, sortOrder) VALUES (?, ?, 'cash', 'imported', ?, ?)",
                               arguments: [name, currency, name + " alias", name.count])
            }
            return try Row.fetchAll(db, sql: "SELECT * FROM account ORDER BY id")
        }
        XCTAssertEqual(before.count, 3)

        try manager.migrate()

        try manager.dbQueue.read { db in
            let after = try Row.fetchAll(db, sql: "SELECT * FROM account ORDER BY id")
            XCTAssertEqual(after.count, 3)
            for (old, new) in zip(before, after) {
                XCTAssertEqual(new["ownerPersonId"] as Int64?, nil)
                XCTAssertEqual(new["sharingLevel"] as String?, SharingLevel.everything.rawValue)
                let kept = new.columnNames.filter { !Self.newAccountColumns.contains($0) }
                XCTAssertEqual(Set(kept), Set(old.columnNames))
                for column in kept {
                    XCTAssertEqual(new[column] as DatabaseValue, old[column] as DatabaseValue, "account.\(column) changed")
                }
            }
            let accounts = try Account.order(Column("id")).fetchAll(db)
            XCTAssertEqual(accounts.map(\.ownerPersonId), [nil, nil, nil])
            XCTAssertEqual(accounts.map(\.sharingLevel), [.everything, .everything, .everything])
            for table in ["personSharing", "memberPermission", "accountBalancePoint", "accountSummaryMonth",
                          "syncZoneMove", "syncCompanion", "syncAccessRevert"] {
                XCTAssertTrue(try db.tableExists(table), table)
                XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)"), 0, table)
            }
            XCTAssertTrue(try db.columns(in: "syncRecord").map(\.name).contains("origin"))
            XCTAssertTrue(try db.columns(in: "syncWriter").map(\.name).contains("origin"))
        }
    }

    func testSharingMigrationRunsTwiceWithoutChange() throws {
        let queue = try TestDatabase.migrated()
        let before = try queue.read { db in try tableInfo(db) }
        let schemaBefore = try queue.read { db in
            try String.fetchAll(db, sql: "SELECT COALESCE(sql, '') FROM sqlite_master ORDER BY type, name")
        }
        try queue.write { db in try SharingMigration.apply(db: db) }
        let after = try queue.read { db in try tableInfo(db) }
        let schemaAfter = try queue.read { db in
            try String.fetchAll(db, sql: "SELECT COALESCE(sql, '') FROM sqlite_master ORDER BY type, name")
        }
        XCTAssertEqual(after, before)
        XCTAssertEqual(schemaAfter, schemaBefore)
    }

    func testLevelCheckRejectsUnknownValue() throws {
        let queue = try TestDatabase.migrated()
        try queue.write { db in
            var account = Account(name: "Synthetic", currency: .gbp, kind: .cash, trackingMode: .imported)
            try account.insert(db)
            XCTAssertThrowsError(try db.execute(sql: "UPDATE account SET sharingLevel = 'secret' WHERE id = ?", arguments: [account.id]))
            for level in SharingLevel.allCases {
                try db.execute(sql: "UPDATE account SET sharingLevel = ? WHERE id = ?", arguments: [level.rawValue, account.id])
                XCTAssertEqual(try Account.fetchOne(db, key: account.id)?.sharingLevel, level)
            }

            try db.execute(sql: "INSERT INTO person(name) VALUES ('Synthetic person')")
            let personId = db.lastInsertedRowID
            XCTAssertThrowsError(try db.execute(sql: "INSERT INTO personSharing(personId, taxIncomeLevel) VALUES (?, 'categoryTotals')",
                                                arguments: [personId]))
            var sharing = PersonSharing(personId: personId)
            try sharing.insert(db)
            XCTAssertEqual(try PersonSharing.fetchOne(db, key: sharing.id)?.taxIncomeLevel, .everything)

            try db.execute(sql: "INSERT INTO appUser(personId, displayName, isAdmin, createdAt) VALUES (?, 'Synthetic', 1, ?)",
                           arguments: [personId, Date()])
            let appUserId = db.lastInsertedRowID
            XCTAssertThrowsError(try db.execute(sql: "INSERT INTO memberPermission(appUserId, area, level) VALUES (?, 'documents', 'admin')",
                                                arguments: [appUserId]))
            try db.execute(sql: "INSERT INTO memberPermission(appUserId, area, level) VALUES (?, 'documents', 'edit')", arguments: [appUserId])
        }
    }

    func testLevelsOrderLowToHighWithTitles() {
        XCTAssertEqual(SharingLevel.allCases.sorted(), [.hidden, .balanceOnly, .categoryTotals, .everything])
        XCTAssertEqual(SharingLevel.allCases.map(\.title), ["Hidden", "Balance only", "Category totals", "Everything"])
        XCTAssertLessThan(SharingLevel.balanceOnly, SharingLevel.categoryTotals)
    }

    func testSummaryRowsRoundTrip() throws {
        let queue = try TestDatabase.migrated()
        try queue.write { db in
            var account = Account(name: "Synthetic", currency: .gbp, kind: .cash, trackingMode: .imported)
            try account.insert(db)
            var point = AccountBalancePoint(accountId: account.id!, payMonth: "2026-09", date: Date(timeIntervalSince1970: 1_790_000_000),
                                            balanceMinorUnits: 12_345)
            try point.insert(db)
            var current = AccountBalancePoint(accountId: account.id!, payMonth: "current", date: Date(timeIntervalSince1970: 1_791_000_000),
                                              balanceMinorUnits: 10_000)
            try current.insert(db)
            var month = AccountSummaryMonth(accountId: account.id!, payMonth: "2026-09", categoryId: nil,
                                            amountMinorUnits: -4_200, transactionCount: 3)
            try month.insert(db)
            XCTAssertEqual(try AccountBalancePoint.fetchCount(db), 2)
            XCTAssertEqual(try AccountSummaryMonth.fetchOne(db, key: month.id), month)
            var duplicate = AccountBalancePoint(accountId: account.id!, payMonth: "2026-09", date: Date(), balanceMinorUnits: 1)
            XCTAssertThrowsError(try duplicate.insert(db))
        }
    }

    func testDerivedUUIDIsStableAndV4Shaped() throws {
        let pattern = try NSRegularExpression(pattern: "^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$")
        for name in ["x", "mango.accountBalancePoint.1.2026-09", ""] {
            let uuid = SyncRecordStore.derivedUUID(name)
            XCTAssertEqual(uuid, SyncRecordStore.derivedUUID(name))
            XCTAssertNotNil(pattern.firstMatch(in: uuid, range: NSRange(uuid.startIndex..., in: uuid)), uuid)
        }
        XCTAssertNotEqual(SyncRecordStore.derivedUUID("x"), SyncRecordStore.derivedUUID("y"))
        XCTAssertEqual(SyncRecordStore.builtInCategoryUUID("salary"),
                       SyncRecordStore.derivedUUID("mango.category.builtInRole.salary"))
        // Pinned: the built-in category UUIDs every device already shares must not move.
        XCTAssertEqual(SyncRecordStore.builtInCategoryUUID("salary"), Self.salaryUUID)
    }

    func testTriggersStampOrigin() throws {
        let queue = try TestDatabase.migrated()
        try queue.write { db in
            try SyncChangeTracker.setWriter("u1", origin: "import", db: db)
            var account = Account(name: "Synthetic", currency: .gbp, kind: .cash, trackingMode: .imported)
            try account.insert(db)
            try db.execute(sql: "INSERT INTO importBatch (accountId, sourceFileName, importedAt) VALUES (?, 'a.csv', ?)",
                           arguments: [account.id, Date()])
            try db.execute(sql: """
                INSERT INTO transaction_ (importBatchId, accountId, date, rawDescription, amountMinorUnits, status, categorizedBy, fingerprint)
                VALUES (?, ?, ?, 'Synthetic', -1000, 'pendingReview', 'none', 'fp-1')
                """, arguments: [db.lastInsertedRowID, account.id, Date()])
            let id = db.lastInsertedRowID
            let record = try XCTUnwrap(try Row.fetchOne(db, sql: "SELECT origin, modifiedBy FROM syncRecord WHERE tableName = 'transaction_' AND localId = ?",
                                                        arguments: [id]))
            XCTAssertEqual(record["origin"] as String?, "import")
            XCTAssertEqual(record["modifiedBy"] as String?, "u1")

            // An update stamps the current origin; no origin set stamps NULL.
            try SyncChangeTracker.setWriter("u1", origin: nil, db: db)
            try db.execute(sql: "UPDATE transaction_ SET rawDescription = 'Changed' WHERE id = ?", arguments: [id])
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT origin FROM syncRecord WHERE tableName = 'transaction_' AND localId = ?",
                                               arguments: [id]), nil)
        }
    }

    private static let salaryUUID = "9a94e21d-4b6d-4ff4-adaf-391f4fdd7a1f"
}
