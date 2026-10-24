import XCTest
import GRDB
@testable import BudgetCore
@testable import BudgetDemo

/// `DashboardInput.load`: the one read the Mac's dashboard and the phone's Home share.
final class DashboardInputLoadTests: XCTestCase {
    func testLoadReadsEverythingTheDashboardNeeds() throws {
        let (manager, evidence) = try PhoneDemoFixture.build()
        defer { try? FileManager.default.removeItem(at: evidence) }
        let today = PhoneDemoFixture.today
        // A manual close for October, the day before today: the calendar must honour it.
        try manager.dbQueue.write { db in
            var close = PayMonthClose(year: 2026, month: 10, closeDate: DemoDatabase.date(2026, 10, 14))
            try close.insert(db)
        }
        try manager.dbQueue.read { db in
            let input = try DashboardInput.load(db: db, today: today)
            XCTAssertEqual(input.today, today)
            XCTAssertEqual(input.accounts.count, try Account.fetchCount(db))
            XCTAssertEqual(input.snapshots.count, try BalanceSnapshot.fetchCount(db))
            XCTAssertEqual(input.transactions, try LocalActualsSource().transactions(db))
            XCTAssertEqual(input.categories.count, try Category.fetchCount(db))
            XCTAssertEqual(input.categoryGroups.count, try CategoryGroup.fetchCount(db))
            XCTAssertEqual(input.forecastEntries, try ForecastEntry.budget(db))
            XCTAssertEqual(input.forecastGroups.count, try ForecastGroup.fetchCount(db))
            XCTAssertEqual(input.exceptions.count, try PlannedOccurrenceException.fetchCount(db))
            XCTAssertEqual(input.importBatches.count, try ImportBatch.fetchCount(db))
            XCTAssertEqual(input.rate, try ExchangeRateSetting.currentOrDefault(db: db))
            XCTAssertEqual(input.payCalendar.closeSource(of: PayMonth(year: 2026, month: 10)), .manual)
            // Transfer links read: the incoming legs of linked transfers leave the budget's transactions.
            let links = try TransferLink.fetchAll(db)
            XCTAssertFalse(links.isEmpty)
            XCTAssertEqual(input.transferLinks, links)
            XCTAssertLessThan(input.budgetTransactions.count, input.transactions.count)
        }
    }
}
