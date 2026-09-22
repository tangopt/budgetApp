import XCTest
import GRDB
@testable import BudgetCore

final class CategoryTests: XCTestCase {
    func testInsertAndFetchCategory() throws {
        let manager = try DatabaseManager(path: nil)
        try manager.migrate()
        var category = Category(name: "Rent", type: .expense)
        try manager.dbQueue.write { db in
            try category.insert(db)
        }
        let fetched = try manager.dbQueue.read { db in
            try Category.filter(Column("name") == "Rent").fetchOne(db)
        }
        XCTAssertEqual(fetched?.type, .expense)
    }

    func testSeedDefaultsCreatesKnownCategories() throws {
        let manager = try DatabaseManager(path: nil)
        try manager.migrate()
        try manager.dbQueue.write { db in
            try CategorySeeder.seedDefaults(db)
        }
        let count = try manager.dbQueue.read { db in
            try Category.fetchCount(db)
        }
        XCTAssertGreaterThanOrEqual(count, 40)
        let rent = try manager.dbQueue.read { db in
            try Category.filter(Column("name") == "Rent").fetchOne(db)
        }
        XCTAssertNotNil(rent)
        XCTAssertEqual(rent?.type, .expense)
        let income = try manager.dbQueue.read { db in
            try Category.filter(Column("name") == "Income").fetchOne(db)
        }
        XCTAssertEqual(income?.type, .income)
    }
}
