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

final class CategoriesEditingTests: XCTestCase {
    private func makeDB() throws -> DatabaseManager {
        let m = try DatabaseManager(path: nil)
        try m.migrate()
        return m
    }

    private func addTransactions(_ m: DatabaseManager, categoryId: Int64, count: Int) throws {
        try m.dbQueue.write { db in
            var account = Account(name: "Lloyds \(categoryId)", currency: .gbp, kind: .cash, trackingMode: .imported)
            try account.insert(db)
            var batch = ImportBatch(accountId: account.id!, sourceFileName: "a.csv", importedAt: Date())
            try batch.insert(db)
            for index in 0..<count {
                var transaction = Transaction(importBatchId: batch.id!, accountId: account.id!, date: Date(), rawDescription: "T\(index)", amountMinorUnits: -100,
                                              categoryId: categoryId, status: .confirmed, categorizedBy: .manual, fingerprint: "f\(categoryId)-\(index)")
                try transaction.insert(db)
            }
        }
    }

    private func addPlanned(_ m: DatabaseManager, categoryId: Int64, count: Int) throws {
        try m.dbQueue.write { db in
            for _ in 0..<count {
                _ = try PlannedItems.add(db: db, categoryId: categoryId, amountMinorUnits: -100, frequency: .monthly, interval: 1, startDate: Date(), endDate: nil)
            }
        }
    }

    func testRenamesTrimmed() throws {
        let m = try makeDB()
        let rent = try m.dbQueue.write { db in try Categories.create(db: db, name: "Rent", type: .expense, groupId: nil) }
        try m.dbQueue.write { db in try Categories.rename(db: db, id: rent.id!, name: "  Mortgage ") }
        XCTAssertEqual(try m.dbQueue.read { db in try Category.fetchOne(db, key: rent.id)?.name }, "Mortgage")
        try m.dbQueue.write { db in try Categories.rename(db: db, id: rent.id!, name: "mortgage") }
        XCTAssertEqual(try m.dbQueue.read { db in try Category.fetchOne(db, key: rent.id)?.name }, "mortgage")
    }

    func testRenameRefusesAnotherCategorysNameWithAReadableError() throws {
        let m = try makeDB()
        let rent = try m.dbQueue.write { db -> Category in
            _ = try Categories.create(db: db, name: "Garden", type: .expense, groupId: nil)
            return try Categories.create(db: db, name: "Rent", type: .expense, groupId: nil)
        }
        XCTAssertThrowsError(try m.dbQueue.write { db in try Categories.rename(db: db, id: rent.id!, name: "garden") }) {
            XCTAssertEqual($0 as? CategoryCreationError, .duplicateName("Garden"))
            XCTAssertEqual($0.localizedDescription, "A category named “Garden” already exists.")
        }
        XCTAssertThrowsError(try m.dbQueue.write { db in try Categories.rename(db: db, id: rent.id!, name: " ") }) {
            XCTAssertEqual($0 as? CategoryCreationError, .emptyName)
        }
        XCTAssertThrowsError(try m.dbQueue.write { db in try Categories.rename(db: db, id: 999, name: "X") }) {
            XCTAssertEqual($0 as? CategoryEditError, .notFound)
        }
    }

    func testMovesSeveralToAGroupAndBackToUngrouped() throws {
        let m = try makeDB()
        let (group, ids) = try m.dbQueue.write { db -> (CategoryGroup, [Int64]) in
            let group = try CategoryGroups.create(db: db, name: "Home")
            let a = try Categories.create(db: db, name: "Rent", type: .expense, groupId: nil)
            let b = try Categories.create(db: db, name: "Salary", type: .income, groupId: nil)
            _ = try Categories.create(db: db, name: "Fuel", type: .expense, groupId: nil)
            return (group, [a.id!, b.id!])
        }
        try m.dbQueue.write { db in try Categories.move(db: db, ids: ids, toGroupId: group.id) }
        var categories = try m.dbQueue.read { db in try Category.fetchAll(db) }
        XCTAssertEqual(Set(categories.filter { $0.groupId == group.id }.map(\.name)), ["Rent", "Salary"])
        XCTAssertNil(categories.first { $0.name == "Fuel" }?.groupId)

        try m.dbQueue.write { db in try Categories.move(db: db, ids: [ids[0]], toGroupId: nil) }
        categories = try m.dbQueue.read { db in try Category.fetchAll(db) }
        XCTAssertNil(categories.first { $0.name == "Rent" }?.groupId)
        XCTAssertEqual(categories.first { $0.name == "Salary" }?.groupId, group.id)
    }

    func testMoveRefusesAnUnknownGroup() throws {
        let m = try makeDB()
        let rent = try m.dbQueue.write { db in try Categories.create(db: db, name: "Rent", type: .expense, groupId: nil) }
        XCTAssertThrowsError(try m.dbQueue.write { db in try Categories.move(db: db, ids: [rent.id!], toGroupId: 999) }) {
            XCTAssertEqual($0 as? CategoryCreationError, .groupNotFound)
        }
    }

    func testDeleteRemovesTheCategoryAndItsRules() throws {
        let m = try makeDB()
        let (garden, fuel) = try m.dbQueue.write { db -> (Category, Category) in
            let garden = try Categories.create(db: db, name: "Garden", type: .expense, groupId: nil)
            let fuel = try Categories.create(db: db, name: "Fuel", type: .expense, groupId: nil)
            var rule = Rule(matchPattern: "B&Q", matchType: .contains, categoryId: garden.id!, priority: 0)
            try rule.insert(db)
            var other = Rule(matchPattern: "SHELL", matchType: .contains, categoryId: fuel.id!, priority: 0)
            try other.insert(db)
            return (garden, fuel)
        }
        try m.dbQueue.write { db in try Categories.delete(db: db, id: garden.id!) }
        let (categories, rules) = try m.dbQueue.read { db in (try Category.fetchAll(db), try Rule.fetchAll(db)) }
        XCTAssertEqual(categories.map(\.id), [fuel.id])
        XCTAssertEqual(rules.map(\.matchPattern), ["SHELL"])
    }

    func testDeleteIsRefusedWithCountsWhenTransactionsOrPlannedItemsReferToIt() throws {
        let m = try makeDB()
        let rent = try m.dbQueue.write { db in try Categories.create(db: db, name: "Rent", type: .expense, groupId: nil) }
        try addTransactions(m, categoryId: rent.id!, count: 73)
        try addPlanned(m, categoryId: rent.id!, count: 2)
        XCTAssertThrowsError(try m.dbQueue.write { db in try Categories.delete(db: db, id: rent.id!) }) {
            XCTAssertEqual($0 as? CategoryEditError, .inUse(name: "Rent", transactions: 73, plannedItems: 2))
            XCTAssertEqual($0.localizedDescription, "Rent has 73 transactions and 2 planned items — move or recategorise them first.")
        }
        XCTAssertEqual(try m.dbQueue.read { db in try Category.fetchCount(db) }, 1)
    }

    func testRefusalMessagesNameOnlyWhatIsThereInTheSingular() {
        XCTAssertEqual(CategoryEditError.inUse(name: "Gym", transactions: 1, plannedItems: 0).localizedDescription,
                       "Gym has 1 transaction — move or recategorise it first.")
        XCTAssertEqual(CategoryEditError.inUse(name: "Gym", transactions: 0, plannedItems: 1).localizedDescription,
                       "Gym has 1 planned item — move or recategorise it first.")
        XCTAssertEqual(CategoryEditError.inUse(name: "Gym", transactions: 1, plannedItems: 1).localizedDescription,
                       "Gym has 1 transaction and 1 planned item — move or recategorise them first.")
    }

    func testDeleteRefusesAnUnknownCategory() throws {
        let m = try makeDB()
        XCTAssertThrowsError(try m.dbQueue.write { db in try Categories.delete(db: db, id: 999) }) {
            XCTAssertEqual($0 as? CategoryEditError, .notFound)
        }
    }
}
