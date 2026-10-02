// Tests/BudgetCoreTests/CatchAllCategoryTests.swift
import XCTest
import GRDB
@testable import BudgetCore

final class CatchAllCategoryTests: XCTestCase {
    private func manager() throws -> DatabaseManager {
        let manager = try DatabaseManager(path: nil)
        try manager.migrate()
        return manager
    }

    func testNewCategoriesAreNotCatchAllByDefault() throws {
        let manager = try manager()
        try manager.dbQueue.write { db in
            var category = Category(name: "Bulk other", type: .expense)
            try category.insert(db)
            XCTAssertFalse(try XCTUnwrap(Category.fetchOne(db, key: category.id!)).isCatchAll)
        }
    }

    func testDesignatingClearsThePreviousCatchAllAndPromotesItsAutoEntry() throws {
        let manager = try manager()
        try manager.dbQueue.write { db in
            var first = Category(name: "Other A", type: .expense, isCatchAll: true)
            var second = Category(name: "Other B", type: .expense)
            try first.insert(db)
            try second.insert(db)
            var group = ForecastGroup(name: "Detected recurring", note: nil, isEnabled: true, isSystemManaged: true)
            try group.insert(db)
            var entry = ForecastEntry(groupId: group.id!, categoryId: second.id!, amountMinorUnits: -17_139, frequency: .monthly, interval: 1, startDate: Date(), endDate: nil, isEnabled: true, status: .auto, note: nil)
            try entry.insert(db)

            try CatchAllCategory.designate(db: db, categoryId: second.id!)

            XCTAssertFalse(try XCTUnwrap(Category.fetchOne(db, key: first.id!)).isCatchAll)
            XCTAssertTrue(try XCTUnwrap(Category.fetchOne(db, key: second.id!)).isCatchAll)
            XCTAssertEqual(try XCTUnwrap(ForecastEntry.fetchOne(db, key: entry.id!)).status, .manual)
        }
    }

    func testOnlyExpenseCategoriesCanBeCatchAll() throws {
        let manager = try manager()
        try manager.dbQueue.write { db in
            var income = Category(name: "Pay", type: .income)
            try income.insert(db)
            XCTAssertThrowsError(try CatchAllCategory.designate(db: db, categoryId: income.id!)) { error in
                XCTAssertEqual(error as? CatchAllError, .notAnExpenseCategory)
            }
        }
    }

    func testClearRemovesTheFlagOnly() throws {
        let manager = try manager()
        try manager.dbQueue.write { db in
            var category = Category(name: "Bulk other", type: .expense)
            try category.insert(db)
            try CatchAllCategory.designate(db: db, categoryId: category.id!)
            try CatchAllCategory.clear(db: db, categoryId: category.id!)
            XCTAssertFalse(try XCTUnwrap(Category.fetchOne(db, key: category.id!)).isCatchAll)
        }
    }
}
