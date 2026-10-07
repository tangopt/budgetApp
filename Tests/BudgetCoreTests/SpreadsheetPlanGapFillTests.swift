// Tests/BudgetCoreTests/SpreadsheetPlanGapFillTests.swift
import XCTest
import GRDB
@testable import BudgetCore
import struct BudgetCore.Category

final class SpreadsheetPlanGapFillTests: XCTestCase {
    private static let utc: Calendar = { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }()
    private func month(_ y: Int, _ m: Int) -> Date { Self.utc.date(from: DateComponents(year: y, month: m, day: 1))! }
    private func monthEnd(_ y: Int, _ m: Int) -> Date { MonthRange.of(year: y, month: m).end }

    /// Every category the gap fill maps to, with the situation the brief describes.
    private func fixture(omit: String? = nil) throws -> DatabaseManager {
        let manager = try DatabaseManager(path: nil)
        try manager.migrate()
        try manager.dbQueue.write { db in
            for name in SpreadsheetPlanGapFill.requiredCategoryNames where name != omit {
                if name == SpreadsheetPlanGapFill.reserveName {
                    _ = try ReservedCategories.create(db: db, name: name)
                    continue
                }
                let type: CategoryType = name == "Income" ? .income : (name.hasPrefix("Transfer") ? .transfer : .expense)
                var category = Category(name: name, type: type)
                try category.insert(db)
            }
            var planGroup = ForecastGroup(name: "Spreadsheet plan", note: nil, isEnabled: true, isSystemManaged: false)
            try planGroup.insert(db)
            let reserved = try ReservedCategories.ensureGroup(db: db)
            func add(_ name: String, _ amount: Int, _ start: Date, group: ForecastGroup) throws {
                guard let id = try Category.filter(Column("name") == name).fetchOne(db)?.id else { return }
                var entry = ForecastEntry(groupId: group.id!, categoryId: id, amountMinorUnits: amount, frequency: .monthly, interval: 1, startDate: start, endDate: nil, isEnabled: true, status: .confirmed, note: "From spreadsheet plan")
                try entry.insert(db)
            }
            try add("Rent", -290_000, month(2026, 10), group: planGroup)
            try add("Council Tax", -35_000, month(2026, 10), group: planGroup)
            try add("Gas/Electricity", -13_948, month(2026, 2), group: planGroup)
            try add(SpreadsheetPlanGapFill.reserveName, -200_000, month(2026, 10), group: reserved)
        }
        return manager
    }

    private func entries(_ db: Database, _ name: String) throws -> [ForecastEntry] {
        let id = try XCTUnwrap(Category.filter(Column("name") == name).fetchOne(db)?.id)
        return try ForecastEntry.filter(Column("categoryId") == id && Column("note") == SpreadsheetPlanGapFill.note)
            .order(Column("startDate")).fetchAll(db)
    }

    func testRentGetsTwoRunsWithEndDates() throws {
        try fixture().dbQueue.write { db in
            _ = try SpreadsheetPlanGapFill.apply(db: db, plan: try SpreadsheetPlanGapFill.plan(db: db))
            let rent = try entries(db, "Rent")
            let new = rent
            XCTAssertEqual(new.count, 2)  // the fixture's own entry has a different note
            XCTAssertEqual(new.map(\.amountMinorUnits), [-280_000, -290_000])
            XCTAssertEqual(new.map(\.startDate), [month(2026, 3), month(2026, 8)])
            XCTAssertEqual(new.map { $0.endDate }, [monthEnd(2026, 7), monthEnd(2026, 9)])
            XCTAssertTrue(new.allSatisfy { $0.frequency == .monthly && $0.interval == 1 && $0.status == .confirmed && $0.isEnabled })
        }
    }

    func testInternetIsOpenEndedFromMarch() throws {
        try fixture().dbQueue.write { db in
            _ = try SpreadsheetPlanGapFill.apply(db: db, plan: try SpreadsheetPlanGapFill.plan(db: db))
            let internet = try entries(db, "Internet")
            XCTAssertEqual(internet.count, 1)
            XCTAssertEqual(internet[0].amountMinorUnits, -4_500)
            XCTAssertEqual(internet[0].startDate, month(2026, 3))
            XCTAssertNil(internet[0].endDate)
            XCTAssertEqual(internet[0].frequency, .monthly)
            let group = try XCTUnwrap(ForecastGroup.fetchOne(db, key: internet[0].groupId))
            XCTAssertEqual(group.name, "Spreadsheet plan")
        }
    }

    func testIncomeIsPositive() throws {
        try fixture().dbQueue.write { db in
            _ = try SpreadsheetPlanGapFill.apply(db: db, plan: try SpreadsheetPlanGapFill.plan(db: db))
            XCTAssertEqual(try entries(db, "Income").first?.amountMinorUnits, 775_825)
        }
    }

    func testCouncilTaxGetsAprilOnceAndMaySeptemberRun() throws {
        try fixture().dbQueue.write { db in
            _ = try SpreadsheetPlanGapFill.apply(db: db, plan: try SpreadsheetPlanGapFill.plan(db: db))
            let new = try entries(db, "Council Tax").filter { $0.startDate < month(2026, 10) }
            XCTAssertEqual(new.count, 2)
            XCTAssertEqual(new[0].frequency, .once)
            XCTAssertEqual(new[0].amountMinorUnits, -36_000)
            XCTAssertEqual(new[0].startDate, month(2026, 4))
            XCTAssertEqual(new[1].frequency, .monthly)
            XCTAssertEqual(new[1].amountMinorUnits, -35_000)
            XCTAssertEqual(new[1].startDate, month(2026, 5))
            XCTAssertEqual(new[1].endDate, monthEnd(2026, 9))
        }
    }

    func testTVLicenceOnceInMay() throws {
        try fixture().dbQueue.write { db in
            _ = try SpreadsheetPlanGapFill.apply(db: db, plan: try SpreadsheetPlanGapFill.plan(db: db))
            let tv = try entries(db, "TV License")
            XCTAssertEqual(tv.count, 1)
            XCTAssertEqual(tv[0].frequency, .once)
            XCTAssertEqual(tv[0].amountMinorUnits, -18_000)
            XCTAssertEqual(tv[0].startDate, month(2026, 5))
        }
    }

    func testThamesWaterOnceInMarchAndSeptember() throws {
        try fixture().dbQueue.write { db in
            _ = try SpreadsheetPlanGapFill.apply(db: db, plan: try SpreadsheetPlanGapFill.plan(db: db))
            let water = try entries(db, "Thames Water")
            XCTAssertEqual(water.map(\.startDate), [month(2026, 3), month(2026, 9)])
            XCTAssertTrue(water.allSatisfy { $0.frequency == .once && $0.amountMinorUnits == -35_000 })
        }
    }

    func testDecemberOneOffsStayOnce() throws {
        try fixture().dbQueue.write { db in
            _ = try SpreadsheetPlanGapFill.apply(db: db, plan: try SpreadsheetPlanGapFill.plan(db: db))
            for name in ["UK Taxes", "Accountant"] {
                let list = try entries(db, name)
                XCTAssertEqual(list.count, 1)
                XCTAssertEqual(list[0].frequency, .once)
                XCTAssertEqual(list[0].startDate, month(2026, 12))
            }
        }
    }

    func testGasIsOnlyReported() throws {
        try fixture().dbQueue.write { db in
            let plan = try SpreadsheetPlanGapFill.plan(db: db)
            XCTAssertTrue(plan.mismatches.contains("Gas/Electricity: plan -£139.48 vs spreadsheet -£100.00 (2026-03…2026-12) — not changed"), "\(plan.mismatches)")
            let before = try ForecastEntry.fetchCount(db)
            _ = try SpreadsheetPlanGapFill.apply(db: db, plan: plan)
            XCTAssertEqual(try entries(db, "Gas/Electricity").count, 0)  // nothing added; the fixture's entry has another note
            XCTAssertGreaterThan(try ForecastEntry.fetchCount(db), before)
        }
    }

    func testReserveFilledMarchToSeptemberInReservedGroup() throws {
        try fixture().dbQueue.write { db in
            _ = try SpreadsheetPlanGapFill.apply(db: db, plan: try SpreadsheetPlanGapFill.plan(db: db))
            let new = try entries(db, SpreadsheetPlanGapFill.reserveName).filter { $0.startDate < month(2026, 10) }
            XCTAssertEqual(new.count, 1)
            XCTAssertEqual(new[0].amountMinorUnits, -200_000)
            XCTAssertEqual(new[0].startDate, month(2026, 3))
            XCTAssertEqual(new[0].endDate, monthEnd(2026, 9))
            XCTAssertEqual(try ForecastGroup.fetchOne(db, key: new[0].groupId)?.name, "Reserved")
        }
    }

    func testLogLines() throws {
        try fixture().dbQueue.write { db in
            let log = try SpreadsheetPlanGapFill.apply(db: db, plan: try SpreadsheetPlanGapFill.plan(db: db))
            XCTAssertTrue(log.contains("Internet: -£45.00 monthly from 2026-03 (continues)"), "\(log)")
            XCTAssertTrue(log.contains("Rent: -£2,800.00 monthly 2026-03…2026-07"), "\(log)")
            XCTAssertTrue(log.contains("TV License: -£180.00 once 2026-05"), "\(log)")
        }
    }

    func testSecondRunFindsNothing() throws {
        try fixture().dbQueue.write { db in
            _ = try SpreadsheetPlanGapFill.apply(db: db, plan: try SpreadsheetPlanGapFill.plan(db: db))
            let again = try SpreadsheetPlanGapFill.plan(db: db)
            XCTAssertTrue(again.runs.isEmpty, "\(again.runs)")
            let count = try ForecastEntry.fetchCount(db)
            XCTAssertTrue(try SpreadsheetPlanGapFill.apply(db: db, plan: again).isEmpty)
            XCTAssertEqual(try ForecastEntry.fetchCount(db), count)
        }
    }

    func testMissingCategoryAbortsWithoutWrites() throws {
        let manager = try fixture(omit: "NOW")
        try manager.dbQueue.write { db in
            let before = try ForecastEntry.fetchCount(db)
            XCTAssertThrowsError(try SpreadsheetPlanGapFill.plan(db: db)) {
                XCTAssertEqual($0 as? SpreadsheetPlanGapFillError, .missingCategories(["NOW"]))
            }
            XCTAssertEqual(try ForecastEntry.fetchCount(db), before)
        }
    }
}
