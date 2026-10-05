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

    func testAddExcludesTheCategoryFromAutoForecastAndRemovesItsAutoEntries() throws {
        try manager().dbQueue.write { db in
            var gym = Category(name: "Gym", type: .expense)
            try gym.insert(db)
            var detected = ForecastGroup(name: "Detected recurring", note: nil, isEnabled: true, isSystemManaged: true)
            try detected.insert(db)
            var auto = ForecastEntry(groupId: detected.id!, categoryId: gym.id!, amountMinorUnits: -4_000, frequency: .monthly, interval: 1, startDate: utc(2026, 2, 3), endDate: nil, isEnabled: true, status: .auto, note: nil)
            try auto.insert(db)

            let planned = try PlannedItems.add(db: db, categoryId: gym.id!, amountMinorUnits: -4_500, frequency: .monthly, interval: 1, startDate: utc(2026, 11, 1), endDate: nil)

            XCTAssertTrue(try XCTUnwrap(Category.fetchOne(db, key: gym.id!)).excludeFromAutoForecast)
            XCTAssertNil(try ForecastEntry.fetchOne(db, key: auto.id!))
            XCTAssertNotNil(try ForecastEntry.fetchOne(db, key: planned.id!))
        }
    }

    func testAOneOffItemLeavesTheAutoForecastAlone() throws {
        try manager().dbQueue.write { db in
            var salary = Category(name: "Salary", type: .income)
            try salary.insert(db)
            var detected = ForecastGroup(name: "Detected recurring", note: nil, isEnabled: true, isSystemManaged: true)
            try detected.insert(db)
            var auto = ForecastEntry(groupId: detected.id!, categoryId: salary.id!, amountMinorUnits: 300_000, frequency: .monthly, interval: 1, startDate: utc(2026, 1, 25), endDate: nil, isEnabled: true, status: .auto, note: nil)
            try auto.insert(db)

            let bonus = try PlannedItems.add(db: db, categoryId: salary.id!, amountMinorUnits: 100_000, frequency: .once, interval: 1, startDate: utc(2026, 12, 20), endDate: nil)

            XCTAssertFalse(try XCTUnwrap(Category.fetchOne(db, key: salary.id!)).excludeFromAutoForecast)
            XCTAssertNotNil(try ForecastEntry.fetchOne(db, key: auto.id!))
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
}
