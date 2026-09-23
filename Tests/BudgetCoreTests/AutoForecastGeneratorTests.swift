// Tests/BudgetCoreTests/AutoForecastGeneratorTests.swift
import XCTest
import GRDB
@testable import BudgetCore

final class AutoForecastGeneratorTests: XCTestCase {
    func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var c = DateComponents(); c.year = y; c.month = m; c.day = d
        return Calendar(identifier: .gregorian).date(from: c)!
    }

    // NOTE: returns the Rent category's id (Int64) rather than the Category value itself.
    // On this toolchain, a bare `Category` type annotation in this test target is ambiguous
    // between BudgetCore.Category and the `Category` typedef from objc/runtime.h (pulled in
    // transitively via XCTest/Foundation), and that ambiguity can't be resolved by writing
    // `BudgetCore.Category` here because this module also declares `public enum BudgetCore`
    // (Sources/BudgetCore/BudgetCore.swift), which shadows the module name for qualified
    // lookup. Returning the id sidesteps the ambiguity; `Category.filter(...)` calls below
    // are unaffected since static-member/initializer calls disambiguate via overload
    // resolution regardless.
    func seededManagerWithRentHistory() throws -> (DatabaseManager, Int64, Account, [PayPeriod]) {
        let manager = try DatabaseManager(path: nil)
        try manager.migrate()
        try manager.dbQueue.write { db in try CategorySeeder.seedDefaults(db) }
        let rent = try manager.dbQueue.read { db in try Category.filter(Column("name") == "Rent").fetchOne(db)! }
        var account = Account(name: "Lloyds Classic", currency: .gbp, kind: .cash, trackingMode: .imported)
        try manager.dbQueue.write { db in try account.insert(db) }

        let periods = [
            PayPeriod(startDate: date(2026, 4, 26), endDate: date(2026, 5, 25), type: .actual),
            PayPeriod(startDate: date(2026, 5, 26), endDate: date(2026, 6, 25), type: .actual),
            PayPeriod(startDate: date(2026, 6, 26), endDate: date(2026, 7, 25), type: .actual)
        ]
        try manager.dbQueue.write { db in
            var batch = ImportBatch(accountId: account.id!, sourceFileName: "x.csv", importedAt: Date())
            try batch.insert(db)
            for (i, rentDate) in [date(2026, 4, 28), date(2026, 5, 28), date(2026, 6, 28)].enumerated() {
                var t = Transaction(importBatchId: batch.id!, accountId: account.id!, date: rentDate, rawDescription: "RENT", amountMinorUnits: -280000, categoryId: rent.id!, status: .confirmed, categorizedBy: .manual, fingerprint: "rent-\(i)")
                try t.insert(db)
            }
        }
        return (manager, rent.id!, account, periods)
    }

    func testFixedCategoryForecastsLastActualAmount() throws {
        let (manager, rentId, _, periods) = try seededManagerWithRentHistory()
        try manager.dbQueue.write { db in
            try AutoForecastGenerator.regenerate(db: db, actualPeriods: periods)
        }
        let entries = try manager.dbQueue.read { db in try ForecastEntry.filter(Column("categoryId") == rentId).fetchAll(db) }
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].amountMinorUnits, -280000)
        XCTAssertEqual(entries[0].status, .auto)
        XCTAssertEqual(entries[0].frequency, .monthly)
    }

    func testRegenerateDoesNotOverwriteManuallyTunedEntry() throws {
        let (manager, rentId, _, periods) = try seededManagerWithRentHistory()
        try manager.dbQueue.write { db in try AutoForecastGenerator.regenerate(db: db, actualPeriods: periods) }
        try manager.dbQueue.write { db in
            var entry = try ForecastEntry.filter(Column("categoryId") == rentId).fetchOne(db)!
            entry.amountMinorUnits = 300000
            entry.status = .manual
            try entry.update(db)
        }
        try manager.dbQueue.write { db in try AutoForecastGenerator.regenerate(db: db, actualPeriods: periods) }
        let entry = try manager.dbQueue.read { db in try ForecastEntry.filter(Column("categoryId") == rentId).fetchOne(db)! }
        XCTAssertEqual(entry.amountMinorUnits, 300000)
    }

    // MARK: - I3 / I1

    func utcDate(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal.date(from: DateComponents(year: y, month: m, day: d))!
    }

    /// `count` consecutive monthly actual periods starting 26 Jan 2025 (UTC).
    func monthlyPeriods(count: Int) -> [PayPeriod] {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let anchor = utcDate(2025, 1, 26)
        return (0..<count).map { i in
            let start = cal.date(byAdding: .month, value: i, to: anchor)!
            let end = cal.date(byAdding: .day, value: -1, to: cal.date(byAdding: .month, value: i + 1, to: anchor)!)!
            return PayPeriod(startDate: start, endDate: end, type: .actual)
        }
    }

    func makeManager() throws -> (DatabaseManager, Int64) {
        let manager = try DatabaseManager(path: nil)
        try manager.migrate()
        try manager.dbQueue.write { db in try CategorySeeder.seedDefaults(db) }
        var account = Account(name: "Lloyds Classic", currency: .gbp, kind: .cash, trackingMode: .imported)
        try manager.dbQueue.write { db in try account.insert(db) }
        return (manager, account.id!)
    }

    func categoryId(_ name: String, _ manager: DatabaseManager) throws -> Int64 {
        try manager.dbQueue.read { db in try Category.filter(Column("name") == name).fetchOne(db)!.id! }
    }

    func insert(_ manager: DatabaseManager, accountId: Int64, categoryId: Int64, _ items: [(Date, Int)]) throws {
        try manager.dbQueue.write { db in
            var batch = ImportBatch(accountId: accountId, sourceFileName: "x.csv", importedAt: Date())
            try batch.insert(db)
            for (date, amount) in items {
                var t = Transaction(importBatchId: batch.id!, accountId: accountId, date: date, rawDescription: "T", amountMinorUnits: amount, categoryId: categoryId, status: .confirmed, categorizedBy: .manual, fingerprint: UUID().uuidString)
                try t.insert(db)
            }
        }
    }

    func autoEntry(_ categoryId: Int64, _ manager: DatabaseManager) throws -> ForecastEntry? {
        try manager.dbQueue.read { db in try ForecastEntry.filter(Column("categoryId") == categoryId).fetchOne(db) }
    }

    // I3 probe: an annual bill (TV licence) must not be forecast as monthly.
    func testAnnualBillIsForecastAnnuallyOnItsDate() throws {
        let (manager, accountId) = try makeManager()
        let tvLicence = try categoryId("TV License", manager)
        let periods = monthlyPeriods(count: 14) // 26 Jan 2025 … 25 Mar 2026
        try insert(manager, accountId: accountId, categoryId: tvLicence, [(utcDate(2025, 2, 3), -16950), (utcDate(2026, 2, 2), -17450)])
        try manager.dbQueue.write { db in try AutoForecastGenerator.regenerate(db: db, actualPeriods: periods) }

        let entry = try XCTUnwrap(try autoEntry(tvLicence, manager))
        XCTAssertEqual(entry.frequency, .annually)
        XCTAssertEqual(entry.amountMinorUnits, -17450)
        XCTAssertEqual(entry.startDate, utcDate(2026, 2, 2))

        // Projected: fires in the period containing 2 Feb 2027 and in no other.
        let group = try manager.dbQueue.read { db in try ForecastGroup.fetchAll(db) }
        let projected = PayPeriodDetector.generateProjectedPeriods(cadence: PayCadence(averageIntervalDays: 30, lastPayDate: periods.last!.startDate), horizon: utcDate(2027, 3, 1))
        let totals = projected.map { ForecastCalculator.confirmedTotal(categoryId: tvLicence, period: $0, entries: [entry], groups: group) }
        XCTAssertEqual(totals.filter { $0 != 0 }, [-17450])
    }

    // I3: a category seen only once, or irregularly, gets no auto-forecast at all
    // (previously: monthly at the mean of its non-zero periods).
    func testSparseIrregularCategoryIsNotForecast() throws {
        let (manager, accountId) = try makeManager()
        let optician = try categoryId("Optician", manager)
        let carService = try categoryId("Car Service", manager)
        let periods = monthlyPeriods(count: 8)
        try insert(manager, accountId: accountId, categoryId: optician, [(utcDate(2025, 3, 1), -12000)])
        try insert(manager, accountId: accountId, categoryId: carService, [(utcDate(2025, 2, 1), -30000), (utcDate(2025, 3, 1), -5000), (utcDate(2025, 8, 1), -40000)])
        try manager.dbQueue.write { db in try AutoForecastGenerator.regenerate(db: db, actualPeriods: periods) }
        XCTAssertNil(try autoEntry(optician, manager))
        XCTAssertNil(try autoEntry(carService, manager))
    }

    func testQuarterlyCategoryIsForecastEveryThreeMonths() throws {
        let (manager, accountId) = try makeManager()
        let water = try categoryId("Thames Water", manager)
        let periods = monthlyPeriods(count: 9)
        try insert(manager, accountId: accountId, categoryId: water, [(utcDate(2025, 2, 10), -9000), (utcDate(2025, 5, 10), -9000), (utcDate(2025, 8, 10), -9500)])
        try manager.dbQueue.write { db in try AutoForecastGenerator.regenerate(db: db, actualPeriods: periods) }
        let entry = try XCTUnwrap(try autoEntry(water, manager))
        XCTAssertEqual(entry.frequency, .monthly)
        XCTAssertEqual(entry.interval, 3)
        XCTAssertEqual(entry.amountMinorUnits, -9500)
        XCTAssertEqual(entry.startDate, utcDate(2025, 8, 10))
    }

    // I3: zero periods are no longer silently skipped — a variable monthly category
    // missing the (still-open) latest period is still monthly, averaged over the
    // periods it actually occurred in.
    func testVariableMonthlyCategoryToleratesOneMissingPeriod() throws {
        let (manager, accountId) = try makeManager()
        let groceries = try categoryId("Groceries", manager)
        let periods = monthlyPeriods(count: 4)
        try insert(manager, accountId: accountId, categoryId: groceries, [(utcDate(2025, 2, 1), -30000), (utcDate(2025, 3, 1), -40000), (utcDate(2025, 4, 1), -50000)])
        try manager.dbQueue.write { db in try AutoForecastGenerator.regenerate(db: db, actualPeriods: periods) }
        let entry = try XCTUnwrap(try autoEntry(groceries, manager))
        XCTAssertEqual(entry.frequency, .monthly)
        XCTAssertEqual(entry.amountMinorUnits, -40000)
        XCTAssertEqual(entry.startDate, periods.last!.startDate)
    }

    // I1: the forecast keeps the sign of the actuals — an inbound transfer category
    // forecasts money in, not money out (the old code abs()'d then negated by type).
    func testInboundTransferCategoryForecastsPositiveAmount() throws {
        let (manager, accountId) = try makeManager()
        let joint = try categoryId("Transfer: Lloyds Joint", manager)
        let periods = monthlyPeriods(count: 3)
        try insert(manager, accountId: accountId, categoryId: joint, [(utcDate(2025, 1, 28), 50000), (utcDate(2025, 2, 28), 50000), (utcDate(2025, 3, 28), 50000)])
        try manager.dbQueue.write { db in try AutoForecastGenerator.regenerate(db: db, actualPeriods: periods) }
        XCTAssertEqual(try autoEntry(joint, manager)?.amountMinorUnits, 50000)
    }

    func testStaleAutoEntryIsRemovedWhenPatternNoLongerHolds() throws {
        let (manager, accountId) = try makeManager()
        let sport = try categoryId("Sport", manager)
        try insert(manager, accountId: accountId, categoryId: sport, [(utcDate(2025, 1, 28), -4000), (utcDate(2025, 2, 28), -4000)])
        try manager.dbQueue.write { db in try AutoForecastGenerator.regenerate(db: db, actualPeriods: self.monthlyPeriods(count: 2)) }
        XCTAssertNotNil(try autoEntry(sport, manager))
        // Four more months with no gym payments: no longer monthly.
        try manager.dbQueue.write { db in try AutoForecastGenerator.regenerate(db: db, actualPeriods: self.monthlyPeriods(count: 6)) }
        XCTAssertNil(try autoEntry(sport, manager))
    }

    func testDetectRecurrenceClassification() {
        XCTAssertEqual(AutoForecastGenerator.detectRecurrence(perPeriodSums: [-100, -100, -100])?.frequency, .monthly)
        XCTAssertNil(AutoForecastGenerator.detectRecurrence(perPeriodSums: [0, 0, -100, 0, 0, 0]))
        XCTAssertNil(AutoForecastGenerator.detectRecurrence(perPeriodSums: [-100, 0, 0, 0, -100, 0, 0, 0, 0, 0]))
        XCTAssertNil(AutoForecastGenerator.detectRecurrence(perPeriodSums: [-100, 100, 0]))
        let annual = AutoForecastGenerator.detectRecurrence(perPeriodSums: [-100] + Array(repeating: 0, count: 11) + [-120, 0])
        XCTAssertEqual(annual?.frequency, .annually)
        XCTAssertEqual(annual?.amountMinorUnits, -120)
    }

    // C5 building block: refresh(db:) derives periods from salary paydays itself.
    func testRefreshDerivesPeriodsFromSalaryAndForecastsRent() throws {
        let (manager, accountId) = try makeManager()
        let income = try categoryId("Income", manager)
        let bonus = try categoryId("Bonus", manager)
        let rent = try categoryId("Rent", manager)
        try insert(manager, accountId: accountId, categoryId: income, [(utcDate(2026, 4, 26), 280000), (utcDate(2026, 5, 26), 280000), (utcDate(2026, 6, 26), 280000)])
        try insert(manager, accountId: accountId, categoryId: bonus, [(utcDate(2026, 5, 12), 90000)])
        try insert(manager, accountId: accountId, categoryId: rent, [(utcDate(2026, 4, 28), -180000), (utcDate(2026, 5, 28), -180000), (utcDate(2026, 6, 28), -180000)])
        try manager.dbQueue.write { db in try AutoForecastGenerator.refresh(db: db) }
        let rentEntry = try XCTUnwrap(try autoEntry(rent, manager))
        XCTAssertEqual(rentEntry.amountMinorUnits, -180000)
        XCTAssertEqual(rentEntry.startDate, utcDate(2026, 6, 26))
        XCTAssertEqual(try autoEntry(income, manager)?.amountMinorUnits, 280000)
        XCTAssertNil(try autoEntry(bonus, manager)) // one-off, not recurring
    }
}
