import XCTest
import GRDB
@testable import BudgetCore
import struct BudgetCore.Category

final class CategoryGroupsTests: XCTestCase {
    private func makeDB() throws -> DatabaseManager {
        let m = try DatabaseManager(path: nil)
        try m.migrate()
        return m
    }

    func testCreatesATrimmedGroup() throws {
        let m = try makeDB()
        let group = try m.dbQueue.write { db in try CategoryGroups.create(db: db, name: "  Home  ") }
        XCTAssertNotNil(group.id)
        XCTAssertEqual(try m.dbQueue.read { db in try CategoryGroup.fetchOne(db, key: group.id)?.name }, "Home")
    }

    func testCreateRefusesBlankAndDuplicateNames() throws {
        let m = try makeDB()
        try m.dbQueue.write { db in _ = try CategoryGroups.create(db: db, name: "Home") }
        XCTAssertThrowsError(try m.dbQueue.write { db in try CategoryGroups.create(db: db, name: "  ") }) {
            XCTAssertEqual($0 as? CategoryGroupError, .emptyName)
        }
        XCTAssertThrowsError(try m.dbQueue.write { db in try CategoryGroups.create(db: db, name: "home") }) {
            XCTAssertEqual($0 as? CategoryGroupError, .duplicateName("Home"))
            XCTAssertEqual($0.localizedDescription, "A group named “Home” already exists.")
        }
    }

    func testCreateMovesTheChosenCategoriesIntoTheNewGroup() throws {
        let m = try makeDB()
        let (rent, fuel, food) = try m.dbQueue.write { db -> (Category, Category, Category) in
            let car = try CategoryGroups.create(db: db, name: "Car")
            return (try Categories.create(db: db, name: "Rent", type: .expense, groupId: nil),
                    try Categories.create(db: db, name: "Fuel", type: .expense, groupId: car.id),
                    try Categories.create(db: db, name: "Food", type: .expense, groupId: nil))
        }
        let home = try m.dbQueue.write { db in try CategoryGroups.create(db: db, name: "Home", moving: [rent.id!, fuel.id!]) }
        let categories = try m.dbQueue.read { db in try Category.fetchAll(db) }
        XCTAssertEqual(categories.first { $0.id == rent.id }?.groupId, home.id)
        XCTAssertEqual(categories.first { $0.id == fuel.id }?.groupId, home.id)
        XCTAssertNil(categories.first { $0.id == food.id }?.groupId)
    }

    func testCreateWithABuiltInMemberIsRefusedAndCreatesNothing() throws {
        let m = try makeDB()
        let builtIn = try m.dbQueue.read { db in try Category.filter(Column("builtInRole") != nil).fetchOne(db) }
        let id = try XCTUnwrap(builtIn?.id)
        XCTAssertThrowsError(try m.dbQueue.write { db in try CategoryGroups.create(db: db, name: "Home", moving: [id]) }) {
            XCTAssertEqual($0 as? CategoryEditError, .builtIn(name: builtIn!.name))
        }
        XCTAssertEqual(try m.dbQueue.read { db in try CategoryGroup.fetchCount(db) }, 0)
    }

    func testRenames() throws {
        let m = try makeDB()
        let group = try m.dbQueue.write { db in try CategoryGroups.create(db: db, name: "Home") }
        try m.dbQueue.write { db in try CategoryGroups.rename(db: db, id: group.id!, name: " House ") }
        XCTAssertEqual(try m.dbQueue.read { db in try CategoryGroup.fetchOne(db, key: group.id)?.name }, "House")
        // Changing only the case of its own name is fine.
        try m.dbQueue.write { db in try CategoryGroups.rename(db: db, id: group.id!, name: "house") }
        XCTAssertEqual(try m.dbQueue.read { db in try CategoryGroup.fetchOne(db, key: group.id)?.name }, "house")
    }

    func testRenameRefusesAnotherGroupsNameBlankAndUnknown() throws {
        let m = try makeDB()
        let home = try m.dbQueue.write { db in try CategoryGroups.create(db: db, name: "Home") }
        try m.dbQueue.write { db in _ = try CategoryGroups.create(db: db, name: "Car") }
        XCTAssertThrowsError(try m.dbQueue.write { db in try CategoryGroups.rename(db: db, id: home.id!, name: "CAR") }) {
            XCTAssertEqual($0 as? CategoryGroupError, .duplicateName("Car"))
        }
        XCTAssertThrowsError(try m.dbQueue.write { db in try CategoryGroups.rename(db: db, id: home.id!, name: "") }) {
            XCTAssertEqual($0 as? CategoryGroupError, .emptyName)
        }
        XCTAssertThrowsError(try m.dbQueue.write { db in try CategoryGroups.rename(db: db, id: 999, name: "X") }) {
            XCTAssertEqual($0 as? CategoryGroupError, .notFound)
        }
    }

    func testDeleteUngroupsItsMembers() throws {
        let m = try makeDB()
        let (home, car) = try m.dbQueue.write { db -> (CategoryGroup, CategoryGroup) in
            let home = try CategoryGroups.create(db: db, name: "Home")
            let car = try CategoryGroups.create(db: db, name: "Car")
            _ = try Categories.create(db: db, name: "Rent", type: .expense, groupId: home.id)
            _ = try Categories.create(db: db, name: "Fuel", type: .expense, groupId: car.id)
            return (home, car)
        }
        try m.dbQueue.write { db in try CategoryGroups.delete(db: db, id: home.id!) }
        let (groups, categories) = try m.dbQueue.read { db in (try CategoryGroup.fetchAll(db), try Category.fetchAll(db)) }
        XCTAssertEqual(groups.map(\.name), ["Car"])
        XCTAssertNil(categories.first { $0.name == "Rent" }?.groupId)
        XCTAssertEqual(categories.first { $0.name == "Fuel" }?.groupId, car.id)
    }
}
