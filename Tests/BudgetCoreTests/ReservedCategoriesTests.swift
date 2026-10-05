// Tests/BudgetCoreTests/ReservedCategoriesTests.swift
import XCTest
import GRDB
@testable import BudgetCore

final class ReservedCategoriesTests: XCTestCase {
    private func manager() throws -> DatabaseManager {
        let manager = try DatabaseManager(path: nil)
        try manager.migrate()
        return manager
    }
    private func utc(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!
        return c.date(from: DateComponents(year: y, month: m, day: d))!
    }

    func testFlagsDefaultToFalse() throws {
        try manager().dbQueue.write { db in
            var category = Category(name: "Groceries", type: .expense)
            try category.insert(db)
            let fetched = try XCTUnwrap(Category.fetchOne(db, key: category.id!))
            XCTAssertFalse(fetched.isReserved)
            XCTAssertFalse(fetched.excludeFromAutoForecast)
            XCTAssertTrue(fetched.isAssignable)
        }
    }

    func testCreateMakesAReservedExpenseCategoryWithATrimmedUniqueName() throws {
        try manager().dbQueue.write { db in
            let reserve = try ReservedCategories.create(db: db, name: "  Remaining for expenses ")
            XCTAssertEqual(reserve.name, "Remaining for expenses")
            XCTAssertEqual(reserve.type, .expense)
            XCTAssertTrue(reserve.isReserved)
            XCTAssertFalse(reserve.isAssignable)
            XCTAssertThrowsError(try ReservedCategories.create(db: db, name: "Remaining for expenses")) {
                XCTAssertEqual($0 as? ReservedCategoryError, .duplicateName)
            }
            XCTAssertThrowsError(try ReservedCategories.create(db: db, name: "   ")) {
                XCTAssertEqual($0 as? ReservedCategoryError, .emptyName)
            }
        }
    }

    func testEnsureGroupIsIdempotentAndUserManaged() throws {
        try manager().dbQueue.write { db in
            let first = try ReservedCategories.ensureGroup(db: db)
            let second = try ReservedCategories.ensureGroup(db: db)
            XCTAssertEqual(first.id, second.id)
            XCTAssertEqual(first.name, "Reserved")
            XCTAssertTrue(first.isEnabled)
            XCTAssertFalse(first.isSystemManaged)
        }
    }

    func testDeleteRemovesTheReserveAndItsEntriesButRefusesOrdinaryCategories() throws {
        try manager().dbQueue.write { db in
            let reserve = try ReservedCategories.create(db: db, name: "Reserve")
            let group = try ReservedCategories.ensureGroup(db: db)
            var entry = ForecastEntry(groupId: group.id!, categoryId: reserve.id!, amountMinorUnits: -200_000, frequency: .monthly, interval: 1, startDate: utc(2026, 10, 1), endDate: nil, isEnabled: true, status: .confirmed, note: nil)
            try entry.insert(db)
            var ordinary = Category(name: "Groceries", type: .expense)
            try ordinary.insert(db)

            try ReservedCategories.delete(db: db, categoryId: reserve.id!)
            XCTAssertNil(try Category.fetchOne(db, key: reserve.id!))
            XCTAssertNil(try ForecastEntry.fetchOne(db, key: entry.id!))
            XCTAssertThrowsError(try ReservedCategories.delete(db: db, categoryId: ordinary.id!)) {
                XCTAssertEqual($0 as? ReservedCategoryError, .notReserved)
            }
        }
    }

    func testRenameChecksForDuplicates() throws {
        try manager().dbQueue.write { db in
            let reserve = try ReservedCategories.create(db: db, name: "Reserve")
            _ = try ReservedCategories.create(db: db, name: "Other reserve")
            try ReservedCategories.rename(db: db, categoryId: reserve.id!, to: "Day to day")
            XCTAssertEqual(try Category.fetchOne(db, key: reserve.id!)?.name, "Day to day")
            XCTAssertThrowsError(try ReservedCategories.rename(db: db, categoryId: reserve.id!, to: "Other reserve")) {
                XCTAssertEqual($0 as? ReservedCategoryError, .duplicateName)
            }
        }
    }

    func testExcludingDeletesOnlyAutoEntries() throws {
        try manager().dbQueue.write { db in
            var category = Category(name: "Confirmed other expenses", type: .expense)
            try category.insert(db)
            var group = ForecastGroup(name: "Detected recurring", note: nil, isEnabled: true, isSystemManaged: true)
            try group.insert(db)
            var auto = ForecastEntry(groupId: group.id!, categoryId: category.id!, amountMinorUnits: -17_139, frequency: .monthly, interval: 1, startDate: utc(2026, 2, 14), endDate: nil, isEnabled: true, status: .auto, note: nil)
            var manual = ForecastEntry(groupId: group.id!, categoryId: category.id!, amountMinorUnits: -5_000, frequency: .once, interval: 1, startDate: utc(2026, 11, 1), endDate: nil, isEnabled: true, status: .manual, note: nil)
            try auto.insert(db)
            try manual.insert(db)

            let deleted = try ReservedCategories.setExcludedFromAutoForecast(db: db, categoryId: category.id!, true)
            XCTAssertEqual(deleted, 1)
            XCTAssertTrue(try XCTUnwrap(Category.fetchOne(db, key: category.id!)).excludeFromAutoForecast)
            XCTAssertNil(try ForecastEntry.fetchOne(db, key: auto.id!))
            XCTAssertNotNil(try ForecastEntry.fetchOne(db, key: manual.id!))

            XCTAssertEqual(try ReservedCategories.setExcludedFromAutoForecast(db: db, categoryId: category.id!, false), 0)
            XCTAssertFalse(try XCTUnwrap(Category.fetchOne(db, key: category.id!)).excludeFromAutoForecast)
        }
    }

    func testTransactionsAndRulesCannotUseAReserve() throws {
        try manager().dbQueue.write { db in
            let reserve = try ReservedCategories.create(db: db, name: "Reserve")
            var ordinary = Category(name: "Groceries", type: .expense)
            try ordinary.insert(db)
            var account = Account(name: "Current", currency: .gbp, kind: .cash, trackingMode: .manual)
            try account.insert(db)
            var batch = ImportBatch(accountId: account.id!, sourceFileName: "x.csv", importedAt: utc(2026, 10, 1))
            try batch.insert(db)

            var txn = Transaction(importBatchId: batch.id!, accountId: account.id!, date: utc(2026, 10, 1), rawDescription: "Shop", amountMinorUnits: -1_000, categoryId: reserve.id!, status: .confirmed, categorizedBy: .manual, fingerprint: "fp1")
            XCTAssertThrowsError(try txn.insert(db)) { error in
                XCTAssertTrue("\(error)".contains("Reserved categories can't hold transactions."))
            }
            txn.categoryId = ordinary.id!
            try txn.insert(db)
            txn.categoryId = reserve.id!
            XCTAssertThrowsError(try txn.update(db))

            var rule = Rule(matchPattern: "SHOP", matchType: .contains, categoryId: reserve.id!, priority: 0)
            XCTAssertThrowsError(try rule.insert(db))
            rule.categoryId = ordinary.id!
            try rule.insert(db)
            rule.categoryId = reserve.id!
            XCTAssertThrowsError(try rule.update(db))
        }
    }

    func testReserveAllowancesLowerTheNetWorthProjection() {
        let reserve = Category(id: 1, name: "Remaining for expenses", type: .expense, isReserved: true)
        let group = ForecastGroup(id: 1, name: "Reserved", note: nil, isEnabled: true, isSystemManaged: false)
        let entry = ForecastEntry(id: 1, groupId: 1, categoryId: 1, amountMinorUnits: -200_000, frequency: .monthly, interval: 1, startDate: utc(2026, 10, 1), endDate: nil, isEnabled: true, status: .confirmed, note: nil)
        let november = PayPeriod(startDate: utc(2026, 11, 1), endDate: utc(2026, 11, 30), type: .projected)
        XCTAssertEqual(ForecastCalculator.confirmedNetWorthImpact(period: november, categories: [reserve], entries: [entry], groups: [group]), -200_000)
    }

    func testCountsAllowanceFromTheCurrentCalendarMonthOn() {
        let today = utc(2026, 10, 5)
        XCTAssertFalse(ReservedCategories.countsAllowance(year: 2026, month: 9, today: today))
        XCTAssertTrue(ReservedCategories.countsAllowance(year: 2026, month: 10, today: today))
        XCTAssertTrue(ReservedCategories.countsAllowance(year: 2027, month: 1, today: today))
        XCTAssertFalse(ReservedCategories.countsAllowance(year: 2025, month: 12, today: today))
    }

    // MARK: Remaining allowance after unforecast spending

    func testRemainingAllowanceIsReducedByUnforecastSpend() {
        let result = ReservedCategories.remainingAllowances([(id: 1, name: "Remaining", allowance: -200_000)], unforecastSpend: 60_000)
        XCTAssertEqual(result, [1: -140_000])
    }

    func testRemainingAllowanceNeverGoesBeyondZero() {
        let result = ReservedCategories.remainingAllowances([(id: 1, name: "Remaining", allowance: -200_000)], unforecastSpend: 230_000)
        XCTAssertEqual(result, [1: 0])
    }

    func testZeroSpendLeavesTheFullAllowance() {
        let result = ReservedCategories.remainingAllowances([(id: 1, name: "Remaining", allowance: -200_000), (id: 2, name: "Gifts", allowance: -5_000)], unforecastSpend: 0)
        XCTAssertEqual(result, [1: -200_000, 2: -5_000])
    }

    func testSeveralReservesAbsorbSpendInNameOrder() {
        // "Gifts" sorts before "Remaining": it absorbs first until it reaches 0.
        let reserves: [(id: Int64, name: String, allowance: Int)] = [(id: 1, name: "Remaining", allowance: -200_000), (id: 2, name: "Gifts", allowance: -5_000)]
        XCTAssertEqual(ReservedCategories.remainingAllowances(reserves, unforecastSpend: 3_000), [1: -200_000, 2: -2_000])
        XCTAssertEqual(ReservedCategories.remainingAllowances(reserves, unforecastSpend: 65_000), [1: -140_000, 2: 0])
        XCTAssertEqual(ReservedCategories.remainingAllowances(reserves, unforecastSpend: 500_000), [1: 0, 2: 0])
    }

    func testUnforecastSpendCountsOnlyExpenseCategoriesWithNothingForecast() {
        let groceries = Category(id: 1, name: "Groceries", type: .expense)
        let dining = Category(id: 2, name: "Dining", type: .expense)          // forecast in October
        let reserve = Category(id: 3, name: "Remaining", type: .expense, isReserved: true)
        let salary = Category(id: 4, name: "Salary", type: .income)
        let savings = Category(id: 5, name: "Savings", type: .transfer)
        let group = ForecastGroup(id: 1, name: "Planned", note: nil, isEnabled: true, isSystemManaged: false)
        let diningEntry = ForecastEntry(id: 1, groupId: 1, categoryId: 2, amountMinorUnits: -40_000, frequency: .monthly, interval: 1, startDate: utc(2026, 1, 14), endDate: nil, isEnabled: true, status: .confirmed, note: nil)
        let reserveEntry = ForecastEntry(id: 2, groupId: 1, categoryId: 3, amountMinorUnits: -200_000, frequency: .monthly, interval: 1, startDate: utc(2026, 1, 1), endDate: nil, isEnabled: true, status: .confirmed, note: nil)
        func txn(_ id: Int64, _ day: Date, _ amount: Int, _ category: Int64?, _ status: TransactionStatus = .confirmed) -> Transaction {
            Transaction(id: id, importBatchId: 1, accountId: 1, date: day, rawDescription: "T\(id)", amountMinorUnits: amount, categoryId: category, status: status, categorizedBy: .manual, fingerprint: "fp\(id)")
        }
        let transactions = [
            txn(1, utc(2026, 10, 3), -25_000, 1),              // groceries: counts
            txn(2, utc(2026, 10, 9), 5_000, 1),                // groceries refund: nets
            txn(3, utc(2026, 10, 4), -55_000, 2),              // dining: forecast, ignored
            txn(4, utc(2026, 10, 25), 300_000, 4),             // income, ignored
            txn(5, utc(2026, 10, 26), -50_000, 5),             // transfer, ignored
            txn(6, utc(2026, 10, 5), -3_000, nil, .pendingReview),  // unreviewed, ignored
            txn(7, utc(2026, 10, 6), -2_000, 1, .pendingReview),    // unreviewed, ignored
            txn(8, utc(2026, 9, 6), -9_000, 1)                 // another month, ignored
        ]
        let totals = BudgetGridCalculator.calendarTotalsLookup(transactions: transactions)
        let spend = ReservedCategories.unforecastSpend(year: 2026, month: 10, categories: [groceries, dining, reserve, salary, savings], calendarTotals: totals, entries: [diningEntry, reserveEntry], groups: [group])
        XCTAssertEqual(spend, 20_000)
    }

    func testUnforecastSpendIsNeverNegative() {
        let groceries = Category(id: 1, name: "Groceries", type: .expense)
        let refund = Transaction(id: 1, importBatchId: 1, accountId: 1, date: utc(2026, 10, 3), rawDescription: "Refund", amountMinorUnits: 7_000, categoryId: 1, status: .confirmed, categorizedBy: .manual, fingerprint: "fp1")
        let totals = BudgetGridCalculator.calendarTotalsLookup(transactions: [refund])
        XCTAssertEqual(ReservedCategories.unforecastSpend(year: 2026, month: 10, categories: [groceries], calendarTotals: totals, entries: [], groups: []), 0)
    }

    func testCatchAllMigrationCarriesTheFlagOverAndDropsTheColumn() throws {
        let manager = try DatabaseManager(path: nil)
        // Migrate up to (but not including) dropCatchAll, insert a catch-all row, then finish.
        try manager.migrate(upTo: "addReservedCategoryFlags")
        try manager.dbQueue.write { db in
            try db.execute(sql: "INSERT INTO category (name, type, isCatchAll) VALUES ('Bulk other', 'expense', 1), ('Rent', 'expense', 0)")
        }
        try manager.migrate()
        try manager.dbQueue.read { db in
            let columns = try db.columns(in: "category").map(\.name)
            XCTAssertFalse(columns.contains("isCatchAll"))
            let bulk = try XCTUnwrap(Category.filter(Column("name") == "Bulk other").fetchOne(db))
            let rent = try XCTUnwrap(Category.filter(Column("name") == "Rent").fetchOne(db))
            XCTAssertTrue(bulk.excludeFromAutoForecast)
            XCTAssertFalse(rent.excludeFromAutoForecast)
        }
    }
}
