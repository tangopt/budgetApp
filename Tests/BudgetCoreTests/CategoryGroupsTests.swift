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

    func testCreateUntitledPicksTheNextFreeName() throws {
        let m = try makeDB()
        let first = try m.dbQueue.write { db in try CategoryGroups.createUntitled(db: db) }
        let second = try m.dbQueue.write { db in try CategoryGroups.createUntitled(db: db) }
        let third = try m.dbQueue.write { db in try CategoryGroups.createUntitled(db: db) }
        XCTAssertEqual([first.name, second.name, third.name], ["New group", "New group 2", "New group 3"])
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
