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
        try manager.migrate()
        let columns = try manager.dbQueue.read { db in try db.columns(in: "importProfile").map(\.name) }
        XCTAssertTrue(columns.contains("csvNegateAmounts"))
        let id = try manager.dbQueue.write { db -> Int64 in
            var account = Account(name: "A", currency: .gbp, kind: .cash, trackingMode: .imported)
            try account.insert(db)
            try db.execute(sql: "INSERT INTO importProfile (accountId, format) VALUES (?, 'csv')", arguments: [account.id])
            return account.id!
        }
        XCTAssertNotNil(id)
        let profile = try manager.dbQueue.read { try ImportProfile.fetchOne($0)! }
        XCTAssertFalse(profile.csvNegateAmounts)
    }
}
