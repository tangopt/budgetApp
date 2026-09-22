import XCTest
import GRDB
@testable import BudgetCore

final class RuleTests: XCTestCase {
    func testInsertAndFetchRule() throws {
        let manager = try DatabaseManager(path: nil)
        try manager.migrate()
        try manager.dbQueue.write { db in try CategorySeeder.seedDefaults(db) }
        let groceries = try manager.dbQueue.read { db in
            try Category.filter(Column("name") == "Groceries").fetchOne(db)!
        }
        var rule = Rule(matchPattern: "SAINSBURYS", matchType: .contains, categoryId: groceries.id!, priority: 10)
        try manager.dbQueue.write { db in try rule.insert(db) }
        let fetched = try manager.dbQueue.read { db in
            try Rule.filter(Column("matchPattern") == "SAINSBURYS").fetchOne(db)
        }
        XCTAssertEqual(fetched?.categoryId, groceries.id)
    }
}
