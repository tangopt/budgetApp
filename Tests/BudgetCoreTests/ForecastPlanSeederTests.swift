// Tests/BudgetCoreTests/ForecastPlanSeederTests.swift
import XCTest
import GRDB
@testable import BudgetCore
import struct BudgetCore.Category

final class ForecastPlanSeederTests: XCTestCase {
    private static let utc: Calendar = { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }()
    private func month(_ y: Int, _ m: Int) -> Date { Self.utc.date(from: DateComponents(year: y, month: m, day: 1))! }

    /// The real category names, with the real types (UK Taxes and Accountant start as
    /// transfers), plus the auto entries the real database has.
    private func fixture() throws -> DatabaseManager {
        let manager = try DatabaseManager(path: nil)
        try manager.migrate()
        try manager.dbQueue.write { db in
            let transfers: Set<String> = ["Transfer: Lloyds Joint", "UK Taxes", "Accountant"]
            for name in ForecastPlanSeeder.requiredCategoryNames {
                var category = Category(name: name, type: transfers.contains(name) ? .transfer : .expense)
                try category.insert(db)
            }
            var detected = ForecastGroup(name: "Detected recurring", note: nil, isEnabled: true, isSystemManaged: true)
            try detected.insert(db)
            func auto(_ name: String, _ amount: Int, _ frequency: ForecastFrequency, _ interval: Int) throws {
                let id = try XCTUnwrap(Category.filter(Column("name") == name).fetchOne(db)?.id)
                var entry = ForecastEntry(groupId: detected.id!, categoryId: id, amountMinorUnits: amount, frequency: frequency, interval: interval, startDate: month(2026, 2), endDate: nil, isEnabled: true, status: .auto, note: nil)
                try entry.insert(db)
            }
            try auto("Rent", -217_108, .monthly, 1)
            try auto("TV License", -17_450, .annually, 1)
            try auto("Thames Water", -32_441, .monthly, 6)
            try auto("Confirmed other expenses", -17_139, .monthly, 1)
            try auto("House Decor / Move Expenses", -6_025, .monthly, 2)
        }
        return manager
    }

    private func category(_ db: Database, _ name: String) throws -> Category {
        try XCTUnwrap(Category.filter(Column("name") == name).fetchOne(db))
    }
    private func entries(_ db: Database, _ name: String) throws -> [ForecastEntry] {
        try ForecastEntry.filter(Column("categoryId") == category(db, name).id!).fetchAll(db)
    }

    func testSeedsTheReserve() throws {
        try fixture().dbQueue.write { db in
            _ = try ForecastPlanSeeder.apply(db: db)
            let reserve = try category(db, "Remaining for expenses")
            XCTAssertTrue(reserve.isReserved)
            let entry = try XCTUnwrap(entries(db, "Remaining for expenses").first)
            XCTAssertEqual(entry.amountMinorUnits, -200_000)
            XCTAssertEqual(entry.frequency, .monthly)
            XCTAssertEqual(entry.startDate, month(2026, 10))
            XCTAssertEqual(entry.status, .confirmed)
            XCTAssertEqual(try ForecastGroup.fetchOne(db, key: entry.groupId)?.name, "Reserved")
        }
    }

    func testCoveredCategoriesAreExcludedAndLoseTheirAutoEntries() throws {
        try fixture().dbQueue.write { db in
            _ = try ForecastPlanSeeder.apply(db: db)
            for name in ["Groceries", "Confirmed other expenses", "House Decor / Move Expenses", "Confirmed other SIGNIFICANT expenses"] {
                XCTAssertTrue(try category(db, name).excludeFromAutoForecast, name)
            }
            XCTAssertTrue(try entries(db, "Confirmed other expenses").isEmpty)
            XCTAssertTrue(try entries(db, "House Decor / Move Expenses").isEmpty)
        }
    }

    func testPlannedItemsAreAddedAndExcludedFromAutoForecast() throws {
        try fixture().dbQueue.write { db in
            _ = try ForecastPlanSeeder.apply(db: db)
            let expected: [(String, Int, ForecastFrequency, Int, Date)] = [
                ("Car Payments", -35_125, .monthly, 1, month(2026, 10)),
                ("Council Tax", -35_000, .monthly, 1, month(2026, 10)),
                ("Transfer: Lloyds Joint", -200_000, .monthly, 1, month(2026, 10)),
                ("UK Taxes", -320_000, .annually, 1, month(2026, 12)),
                ("Accountant", -72_000, .annually, 1, month(2026, 12)),
                ("Car Insurance", -120_000, .annually, 1, month(2027, 5)),
                ("Car Service", -100_000, .annually, 1, month(2027, 5)),
                ("Car MOT", -15_000, .annually, 1, month(2027, 8)),
                ("Car Tax", -19_500, .annually, 1, month(2027, 1))
            ]
            for (name, amount, frequency, interval, start) in expected {
                let all = try entries(db, name)
                XCTAssertEqual(all.count, 1, name)
                let entry = try XCTUnwrap(all.first)
                XCTAssertEqual(entry.amountMinorUnits, amount, name)
                XCTAssertEqual(entry.frequency, frequency, name)
                XCTAssertEqual(entry.interval, interval, name)
                XCTAssertEqual(entry.startDate, start, name)
                XCTAssertEqual(entry.status, .confirmed, name)
                XCTAssertEqual(entry.note, "From spreadsheet plan", name)
                XCTAssertEqual(try ForecastGroup.fetchOne(db, key: entry.groupId)?.name, "Spreadsheet plan", name)
                XCTAssertTrue(try category(db, name).excludeFromAutoForecast, name)
            }
        }
    }

    func testTaxesAndAccountantBecomeExpenses() throws {
        try fixture().dbQueue.write { db in
            _ = try ForecastPlanSeeder.apply(db: db)
            XCTAssertEqual(try category(db, "UK Taxes").type, .expense)
            XCTAssertEqual(try category(db, "Accountant").type, .expense)
            XCTAssertEqual(try category(db, "Transfer: Lloyds Joint").type, .transfer)
        }
    }

    func testCorrectionsUpdateTheAutoEntriesInPlaceAndMakeThemManual() throws {
        try fixture().dbQueue.write { db in
            _ = try ForecastPlanSeeder.apply(db: db)
            let expected: [(String, Int, ForecastFrequency, Int, Date)] = [
                ("Rent", -290_000, .monthly, 1, month(2026, 10)),
                ("TV License", -18_000, .annually, 1, month(2027, 5)),
                ("Thames Water", -35_000, .monthly, 6, month(2027, 3))
            ]
            for (name, amount, frequency, interval, start) in expected {
                let all = try entries(db, name)
                XCTAssertEqual(all.count, 1, name)
                let entry = try XCTUnwrap(all.first)
                XCTAssertEqual(entry.amountMinorUnits, amount, name)
                XCTAssertEqual(entry.frequency, frequency, name)
                XCTAssertEqual(entry.interval, interval, name)
                XCTAssertEqual(entry.startDate, start, name)
                XCTAssertEqual(entry.status, .manual, name)
                XCTAssertEqual(try ForecastGroup.fetchOne(db, key: entry.groupId)?.name, "Detected recurring", name)
            }
        }
    }

    func testACorrectionWithNoAutoEntryGoesToThePlanGroupAndIsExcludedFromAutoForecast() throws {
        let manager = try fixture()
        try manager.dbQueue.write { db in
            try ForecastEntry.filter(Column("categoryId") == category(db, "Rent").id!).deleteAll(db)
            _ = try ForecastPlanSeeder.apply(db: db)
            let all = try entries(db, "Rent")
            XCTAssertEqual(all.count, 1)
            XCTAssertEqual(try ForecastGroup.fetchOne(db, key: all[0].groupId)?.name, ForecastPlanSeeder.planGroupName)
            XCTAssertEqual(all[0].amountMinorUnits, -290_000)
            XCTAssertTrue(try category(db, "Rent").excludeFromAutoForecast)
        }
    }

    func testACorrectionReEnablesADisabledAutoEntry() throws {
        let manager = try fixture()
        try manager.dbQueue.write { db in
            try db.execute(sql: "UPDATE forecastEntry SET isEnabled = 0 WHERE categoryId = ?", arguments: [category(db, "TV License").id!])
            _ = try ForecastPlanSeeder.apply(db: db)
            let entry = try XCTUnwrap(entries(db, "TV License").first)
            XCTAssertTrue(entry.isEnabled)
            XCTAssertEqual(entry.amountMinorUnits, -18_000)
            XCTAssertEqual(entry.status, .manual)
        }
    }

    func testASecondRunChangesNothing() throws {
        try fixture().dbQueue.write { db in
            XCTAssertFalse(try ForecastPlanSeeder.apply(db: db).isEmpty)
            let entryCount = try ForecastEntry.fetchCount(db)
            XCTAssertEqual(try ForecastPlanSeeder.apply(db: db), [])
            XCTAssertEqual(try ForecastEntry.fetchCount(db), entryCount)
        }
    }

    func testAMissingCategoryAbortsWithoutWriting() throws {
        let manager = try fixture()
        try manager.dbQueue.write { db in
            try db.execute(sql: "DELETE FROM category WHERE name = 'Car MOT'")
        }
        try manager.dbQueue.write { db in
            XCTAssertThrowsError(try ForecastPlanSeeder.apply(db: db)) {
                XCTAssertEqual($0 as? ForecastPlanSeederError, .missingCategories(["Car MOT"]))
            }
            XCTAssertNil(try Category.filter(Column("name") == "Remaining for expenses").fetchOne(db))
            XCTAssertEqual(try category(db, "UK Taxes").type, .transfer)
        }
    }

    func testAnOrdinaryCategoryWithTheReserveNameAborts() throws {
        let manager = try fixture()
        try manager.dbQueue.write { db in
            var clash = Category(name: "Remaining for expenses", type: .expense)
            try clash.insert(db)
            XCTAssertThrowsError(try ForecastPlanSeeder.apply(db: db)) {
                XCTAssertEqual($0 as? ForecastPlanSeederError, .nameTakenByOrdinaryCategory("Remaining for expenses"))
            }
        }
    }
}
