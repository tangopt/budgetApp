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
}
