import XCTest
import GRDB
@testable import BudgetCore
@testable import BudgetDemo

/// The seam the Dashboard, Budget grid and Forecast read their actuals through: the local
/// source gives exactly the set they read before, so the figures are identical.
final class ActualsSourceTests: XCTestCase {
    func testLocalSourceMatchesTodaysLoad() throws {
        let manager = try DatabaseManager(path: nil)
        try manager.migrate()
        let evidence = FileManager.default.temporaryDirectory.appendingPathComponent("ActualsEvidence-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: evidence) }
        try DemoDatabase.build(dbQueue: manager.dbQueue, evidenceRoot: evidence)

        let source: any ActualsSource = .local
        let today = Date()
        try manager.dbQueue.read { db in
            let old = try Transaction.fetchAll(db)
            let new = try source.transactions(db)
            XCTAssertFalse(old.isEmpty)
            XCTAssertEqual(new, old)

            func input(_ transactions: [Transaction]) throws -> DashboardInput {
                DashboardInput(today: today, accounts: try Account.fetchAll(db), snapshots: try BalanceSnapshot.fetchAll(db), transactions: transactions,
                               categories: try Category.fetchAll(db), categoryGroups: try CategoryGroup.fetchAll(db), forecastEntries: try ForecastEntry.budget(db),
                               forecastGroups: try ForecastGroup.fetchAll(db), exceptions: try PlannedOccurrenceException.fetchAll(db),
                               importBatches: try ImportBatch.fetchAll(db), rate: try ExchangeRateSetting.currentOrDefault(db: db),
                               manualCloses: try PayMonthClose.fetchAll(db), transferLinks: try TransferLink.fetchAll(db))
            }
            let oldInput = try input(old), newInput = try input(new)
            XCTAssertEqual(DashboardCalculator.accountSummaries(newInput), DashboardCalculator.accountSummaries(oldInput))
            XCTAssertEqual(DashboardCalculator.dataFreshness(newInput), DashboardCalculator.dataFreshness(oldInput))

            // The Budget grid's calculators, from each set.
            let categories = try Category.fetchAll(db)
            let closes = try PayMonthClose.fetchAll(db)
            let oldCalendar = PayCalendar.forData(transactions: old, categories: categories, manualCloses: closes, today: today)
            let newCalendar = PayCalendar.forData(transactions: new, categories: categories, manualCloses: closes, today: today)
            XCTAssertEqual(PayMonthTotals.lookup(transactions: new, calendar: newCalendar), PayMonthTotals.lookup(transactions: old, calendar: oldCalendar))
            XCTAssertEqual(BudgetGridCalculator.yearsWithData(transactions: new, calendar: newCalendar), BudgetGridCalculator.yearsWithData(transactions: old, calendar: oldCalendar))
        }
    }
}
