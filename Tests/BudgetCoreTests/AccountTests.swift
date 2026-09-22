import XCTest
import GRDB
@testable import BudgetCore

final class AccountTests: XCTestCase {
    func testInsertAndFetchAccount() throws {
        let manager = try DatabaseManager(path: nil)
        try manager.migrate()
        var account = Account(name: "Lloyds Classic", currency: .gbp, kind: .cash, trackingMode: .imported)
        try manager.dbQueue.write { db in try account.insert(db) }
        let fetched = try manager.dbQueue.read { db in
            try Account.filter(Column("name") == "Lloyds Classic").fetchOne(db)
        }
        XCTAssertEqual(fetched?.currency, .gbp)
        XCTAssertEqual(fetched?.trackingMode, .imported)
    }

    func testManualInvestmentAccount() throws {
        let manager = try DatabaseManager(path: nil)
        try manager.migrate()
        var account = Account(name: "Lloyds Investment ISA", currency: .gbp, kind: .investment, trackingMode: .manual)
        try manager.dbQueue.write { db in try account.insert(db) }
        XCTAssertNotNil(account.id)
    }
}
