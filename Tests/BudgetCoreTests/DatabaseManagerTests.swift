import XCTest
@testable import BudgetCore

final class DatabaseManagerTests: XCTestCase {
    func testMoneyFormatsGBP() {
        XCTAssertEqual(Money.format(180050, currency: .gbp), "£1,800.50")
    }

    func testMoneyFormatsNegative() {
        XCTAssertEqual(Money.format(-500, currency: .gbp), "-£5.00")
    }

    func testDatabaseManagerMigratesInMemory() throws {
        let manager = try DatabaseManager(path: nil)
        try manager.migrate()
        let tableExists = try manager.dbQueue.read { db in
            try db.tableExists("category")
        }
        XCTAssertTrue(tableExists)
    }

    func testImportProfileTableHasBalanceColumn() throws {
        let manager = try DatabaseManager(path: nil)
        try manager.migrate()
        let columns = try manager.dbQueue.read { db in try db.columns(in: "importProfile").map(\.name) }
        XCTAssertTrue(columns.contains("csvBalanceColumnIndex"))
    }

    func testImportProfileHasNegateColumnDefaultingFalse() throws {
        let manager = try DatabaseManager(path: nil)
        // Seed a profile row before the new migration exists, as in a real upgrade.
        try manager.migrate(upTo: "createScenarios")
        try manager.dbQueue.write { db in
            // Raw SQL: the Account record has columns from later migrations.
            try db.execute(sql: "INSERT INTO account (name, currency, kind, trackingMode) VALUES ('A', 'gbp', 'cash', 'imported')")
            let accountId = db.lastInsertedRowID
            try db.execute(sql: "INSERT INTO importProfile (accountId, format) VALUES (?, 'csv')", arguments: [accountId])
        }
        try manager.migrate()
        let columns = try manager.dbQueue.read { db in try db.columns(in: "importProfile").map(\.name) }
        XCTAssertTrue(columns.contains("csvNegateAmounts"))
        let profile = try manager.dbQueue.read { try ImportProfile.fetchOne($0)! }
        XCTAssertFalse(profile.csvNegateAmounts)
    }

    func testTransactionNoteMigrationKeepsExistingRowsWithNoNote() throws {
        let manager = try DatabaseManager(path: nil)
        try manager.migrate(upTo: "addCSVNegateAmounts")
        try manager.dbQueue.write { db in
            // Raw SQL: the Account record has columns from later migrations.
            try db.execute(sql: "INSERT INTO account (name, currency, kind, trackingMode) VALUES ('A', 'gbp', 'cash', 'imported')")
            let accountId = db.lastInsertedRowID
            try db.execute(sql: "INSERT INTO importBatch (accountId, sourceFileName, importedAt) VALUES (?, 'a.csv', ?)", arguments: [accountId, Date()])
            let batchId = db.lastInsertedRowID
            try db.execute(sql: """
                INSERT INTO transaction_ (importBatchId, accountId, date, rawDescription, amountMinorUnits, status, categorizedBy, fingerprint)
                VALUES (?, ?, ?, 'X', -100, 'pendingReview', 'none', 'f')
                """, arguments: [batchId, accountId, Date()])
        }
        try manager.migrate()
        let columns = try manager.dbQueue.read { db in try db.columns(in: "transaction_").map(\.name) }
        XCTAssertTrue(columns.contains("note"))
        XCTAssertNil(try manager.dbQueue.read { try Transaction.fetchOne($0)!.note })
    }
}
