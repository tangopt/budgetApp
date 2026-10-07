// Tests/BudgetCoreTests/PlannedItemsTests.swift
import XCTest
import GRDB
@testable import BudgetCore

final class PlannedItemsTests: XCTestCase {
    private func manager() throws -> DatabaseManager {
        let manager = try DatabaseManager(path: nil)
        try manager.migrate()
        return manager
    }
    private func utc(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!
        return c.date(from: DateComponents(year: y, month: m, day: d))!
    }

    func testAddCreatesTheGroupOnceAndAConfirmedEntry() throws {
        try manager().dbQueue.write { db in
            var gym = Category(name: "Gym", type: .expense)
            try gym.insert(db)
            var bonus = Category(name: "Bonus", type: .income)
            try bonus.insert(db)

            let first = try PlannedItems.add(db: db, categoryId: gym.id!, amountMinorUnits: -4_500, frequency: .monthly, interval: 1, startDate: utc(2026, 11, 1), endDate: utc(2027, 10, 31))
            let second = try PlannedItems.add(db: db, categoryId: bonus.id!, amountMinorUnits: 100_000, frequency: .once, interval: 1, startDate: utc(2026, 12, 20), endDate: nil)

            let groups = try ForecastGroup.filter(Column("name") == PlannedItems.groupName).fetchAll(db)
            XCTAssertEqual(groups.count, 1)
            let group = try XCTUnwrap(groups.first)
            XCTAssertEqual(PlannedItems.groupName, "Planned")
            XCTAssertTrue(group.isEnabled)
            XCTAssertFalse(group.isSystemManaged)
            XCTAssertEqual(first.groupId, group.id)
            XCTAssertEqual(second.groupId, group.id)

            let stored = try XCTUnwrap(ForecastEntry.fetchOne(db, key: first.id!))
            XCTAssertEqual(stored.categoryId, gym.id)
            XCTAssertEqual(stored.amountMinorUnits, -4_500)
            XCTAssertEqual(stored.frequency, .monthly)
            XCTAssertEqual(stored.interval, 1)
            XCTAssertEqual(stored.startDate, utc(2026, 11, 1))
            XCTAssertEqual(stored.endDate, utc(2027, 10, 31))
            XCTAssertTrue(stored.isEnabled)
            XCTAssertEqual(stored.status, .confirmed)
        }
    }

    func testAddExcludesTheCategoryFromAutoForecastAndKeepsItsDetectedItems() throws {
        try manager().dbQueue.write { db in
            var rent = Category(name: "Rent", type: .expense)
            try rent.insert(db)
            var detected = ForecastGroup(name: "Detected recurring", note: nil, isEnabled: true, isSystemManaged: true)
            try detected.insert(db)
            var existing = ForecastEntry(groupId: detected.id!, categoryId: rent.id!, amountMinorUnits: -217_108, frequency: .monthly, interval: 1, startDate: utc(2026, 2, 3), endDate: nil, isEnabled: true, status: .manual, note: nil)
            try existing.insert(db)

            let planned = try PlannedItems.add(db: db, categoryId: rent.id!, amountMinorUnits: -4_500, frequency: .monthly, interval: 1, startDate: utc(2026, 11, 1), endDate: nil)

            XCTAssertTrue(try XCTUnwrap(Category.fetchOne(db, key: rent.id!)).excludeFromAutoForecast)
            XCTAssertNotNil(try ForecastEntry.fetchOne(db, key: existing.id!), "existing planned items are kept")
            XCTAssertNotNil(try ForecastEntry.fetchOne(db, key: planned.id!))
            XCTAssertEqual(try ForecastEntry.filter(Column("categoryId") == rent.id!).fetchCount(db), 2)
        }
    }

    func testAOneOffItemLeavesTheCategoryAndItsDetectedItemsAlone() throws {
        try manager().dbQueue.write { db in
            var salary = Category(name: "Salary", type: .income)
            try salary.insert(db)
            var detected = ForecastGroup(name: "Detected recurring", note: nil, isEnabled: true, isSystemManaged: true)
            try detected.insert(db)
            var existing = ForecastEntry(groupId: detected.id!, categoryId: salary.id!, amountMinorUnits: 300_000, frequency: .monthly, interval: 1, startDate: utc(2026, 1, 25), endDate: nil, isEnabled: true, status: .manual, note: nil)
            try existing.insert(db)

            let bonus = try PlannedItems.add(db: db, categoryId: salary.id!, amountMinorUnits: 100_000, frequency: .once, interval: 1, startDate: utc(2026, 12, 20), endDate: nil)

            XCTAssertFalse(try XCTUnwrap(Category.fetchOne(db, key: salary.id!)).excludeFromAutoForecast)
            XCTAssertNotNil(try ForecastEntry.fetchOne(db, key: existing.id!))
            XCTAssertNotNil(try ForecastEntry.fetchOne(db, key: bonus.id!))
        }
    }

    func testAddReenablesADisabledPlannedGroup() throws {
        try manager().dbQueue.write { db in
            var gym = Category(name: "Gym", type: .expense)
            try gym.insert(db)
            var group = ForecastGroup(name: PlannedItems.groupName, note: nil, isEnabled: false, isSystemManaged: false)
            try group.insert(db)
            let entry = try PlannedItems.add(db: db, categoryId: gym.id!, amountMinorUnits: -4_500, frequency: .monthly, interval: 1, startDate: utc(2026, 11, 1), endDate: nil)
            XCTAssertEqual(entry.groupId, group.id)
            XCTAssertTrue(try XCTUnwrap(ForecastGroup.fetchOne(db, key: group.id!)).isEnabled)
        }
    }

    func testAddRejectsAReservedCategory() throws {
        try manager().dbQueue.write { db in
            let reserve = try ReservedCategories.create(db: db, name: "Remaining")
            XCTAssertThrowsError(try PlannedItems.add(db: db, categoryId: reserve.id!, amountMinorUnits: -10_000, frequency: .monthly, interval: 1, startDate: utc(2026, 11, 1), endDate: nil)) {
                XCTAssertEqual($0 as? PlannedItemsError, .reservedCategory)
            }
            XCTAssertEqual(try ForecastEntry.fetchCount(db), 0)
            XCTAssertEqual(try ForecastGroup.filter(Column("name") == PlannedItems.groupName).fetchCount(db), 0)
        }
    }

    func testAddWithNewCategoryCreatesTheCategoryAndTheItem() throws {
        try manager().dbQueue.write { db in
            let (category, entry) = try PlannedItems.add(db: db, newCategoryName: "  Side gig ", type: .income, amountMinorUnits: 50_000, frequency: .monthly, interval: 1, startDate: utc(2026, 11, 1), endDate: nil)
            XCTAssertEqual(category.name, "Side gig")
            XCTAssertEqual(category.type, .income)
            XCTAssertFalse(category.isReserved)
            XCTAssertEqual(entry.categoryId, category.id)
            XCTAssertEqual(try Category.filter(Column("name") == "Side gig").fetchCount(db), 1)
        }
    }

    func testAddWithNewCategoryRejectsBlankOrDuplicateNamesWithoutWriting() throws {
        let m = try manager()
        try m.dbQueue.write { db in
            var gym = Category(name: "Gym", type: .expense)
            try gym.insert(db)
        }
        let before = try m.dbQueue.read { db in try Category.fetchCount(db) }
        for (name, expected) in [("   ", PlannedItemsError.emptyCategoryName), ("Gym", .duplicateCategoryName)] {
            XCTAssertThrowsError(try m.dbQueue.write { db in
                try PlannedItems.add(db: db, newCategoryName: name, type: .expense, amountMinorUnits: -100, frequency: .once, interval: 1, startDate: utc(2026, 11, 1), endDate: nil)
            }) { XCTAssertEqual($0 as? PlannedItemsError, expected) }
        }
        XCTAssertEqual(try m.dbQueue.read { db in try Category.fetchCount(db) }, before)
        XCTAssertEqual(try m.dbQueue.read { db in try ForecastEntry.fetchCount(db) }, 0)
    }
}
