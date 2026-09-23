import XCTest
import GRDB
@testable import BudgetCore

final class CategoryGroupTests: XCTestCase {
    func testInsertAndFetchCategoryGroup() throws {
        let manager = try DatabaseManager(path: nil)
        try manager.migrate()
        var group = CategoryGroup(name: "Car")
        try manager.dbQueue.write { db in try group.insert(db) }
        let fetched = try manager.dbQueue.read { db in try CategoryGroup.filter(Column("name") == "Car").fetchOne(db) }
        XCTAssertNotNil(fetched)
    }

    func testCategoryCanBeAssignedToGroup() throws {
        let manager = try DatabaseManager(path: nil)
        try manager.migrate()
        try manager.dbQueue.write { db in
            var group = CategoryGroup(name: "Car")
            try group.insert(db)
            var category = Category(name: "Car Tax", type: .expense, groupId: group.id)
            try category.insert(db)
        }
        let fetched = try manager.dbQueue.read { db in try Category.filter(Column("name") == "Car Tax").fetchOne(db) }
        XCTAssertNotNil(fetched?.groupId)
    }

    func testUngroupedCategoryHasNilGroupId() throws {
        let manager = try DatabaseManager(path: nil)
        try manager.migrate()
        try manager.dbQueue.write { db in
            var category = Category(name: "Rent", type: .expense)
            try category.insert(db)
        }
        let fetched = try manager.dbQueue.read { db in try Category.filter(Column("name") == "Rent").fetchOne(db) }
        XCTAssertNil(fetched?.groupId)
    }
}
