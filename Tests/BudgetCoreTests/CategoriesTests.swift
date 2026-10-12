import XCTest
import GRDB
@testable import BudgetCore
import struct BudgetCore.Category
import struct BudgetCore.Transaction

final class CategoriesTests: XCTestCase {
    private func makeDB() throws -> DatabaseManager {
        let m = try DatabaseManager(path: nil)
        try m.migrate()
        return m
    }

    func testCreatesATrimmedAssignableCategoryOfTheGivenTypeAndGroup() throws {
        let m = try makeDB()
        let created = try m.dbQueue.write { db -> Category in
            var group = CategoryGroup(name: "Home")
            try group.insert(db)
            return try Categories.create(db: db, name: "  Garden  ", type: .expense, groupId: group.id)
        }
        let fetched = try m.dbQueue.read { db in try Category.fetchOne(db, key: created.id) }
        XCTAssertEqual(fetched?.name, "Garden")
        XCTAssertEqual(fetched?.type, .expense)
        XCTAssertNotNil(fetched?.groupId)
        XCTAssertEqual(fetched?.groupId, created.groupId)
        XCTAssertEqual(fetched?.isReserved, false)
        XCTAssertEqual(fetched?.excludeFromAutoForecast, false)
    }

    func testCreatesWithoutAGroup() throws {
        let m = try makeDB()
        let created = try m.dbQueue.write { db in try Categories.create(db: db, name: "Bonus", type: .income, groupId: nil) }
        XCTAssertNotNil(created.id)
        XCTAssertEqual(created.type, .income)
        XCTAssertNil(created.groupId)
    }

    func testRefusesABlankName() throws {
        let m = try makeDB()
        XCTAssertThrowsError(try m.dbQueue.write { db in try Categories.create(db: db, name: "   ", type: .expense, groupId: nil) }) { error in
            XCTAssertEqual(error as? CategoryCreationError, .emptyName)
        }
    }

    func testRefusesADuplicateNameIgnoringCaseWithAReadableError() throws {
        let m = try makeDB()
        try m.dbQueue.write { db in _ = try Categories.create(db: db, name: "Garden", type: .expense, groupId: nil) }
        XCTAssertThrowsError(try m.dbQueue.write { db in try Categories.create(db: db, name: " garden ", type: .expense, groupId: nil) }) { error in
            XCTAssertEqual(error as? CategoryCreationError, .duplicateName("Garden"))
            XCTAssertEqual(error.localizedDescription, "A category named “Garden” already exists.")
        }
    }

    func testRefusesAnUnknownGroup() throws {
        let m = try makeDB()
        XCTAssertThrowsError(try m.dbQueue.write { db in try Categories.create(db: db, name: "Garden", type: .expense, groupId: 999) }) { error in
            XCTAssertEqual(error as? CategoryCreationError, .groupNotFound)
        }
    }
}
