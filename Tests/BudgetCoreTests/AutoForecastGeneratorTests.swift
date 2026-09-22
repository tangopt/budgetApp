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
}
