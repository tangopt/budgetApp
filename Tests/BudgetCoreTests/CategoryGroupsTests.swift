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

    func testCreateStoresTheGroupsType() throws {
        let m = try makeDB()
        let (salary, plain) = try m.dbQueue.write { db in
            (try CategoryGroups.create(db: db, name: "Pay", type: .income),
             try CategoryGroups.create(db: db, name: "Home"))
        }
        XCTAssertEqual(salary.type, .income)
        XCTAssertEqual(try m.dbQueue.read { db in try CategoryGroup.fetchOne(db, key: salary.id)?.type }, .income)
        XCTAssertEqual(try m.dbQueue.read { db in try CategoryGroup.fetchOne(db, key: plain.id)?.type }, .expense)
    }

    func testTypeMigrationBackfillsTheMajorityTypeOfEachGroup() throws {
        let m = try DatabaseManager(path: nil)
        try m.migrate(upTo: "addAccountIsMain")
        try m.dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO categoryGroup (id, name) VALUES (1, 'Pay'), (2, 'Tie'), (3, 'Empty'), (4, 'Moves'), (5, 'TieNoExpense');
                INSERT INTO category (name, type, groupId) VALUES
                    ('Salary', 'income', 1), ('Bonus', 'income', 1), ('Payroll fee', 'expense', 1),
                    ('Rent', 'expense', 2), ('Lodger', 'income', 2),
                    ('To savings', 'transfer', 4),
                    ('Gift', 'income', 5), ('To ISA', 'transfer', 5);
                """)
        }
        try m.migrate()
        let types = try m.dbQueue.read { db in
            Dictionary(uniqueKeysWithValues: try CategoryGroup.fetchAll(db).map { ($0.name, $0.type) })
        }
        XCTAssertEqual(types, ["Pay": .income, "Tie": .expense, "Empty": .expense, "Moves": .transfer, "TieNoExpense": .expense])
    }
}
