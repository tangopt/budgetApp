import XCTest
@testable import BudgetCore
import struct BudgetCore.Transaction

/// Manual entries never make the imported data look fresh or move the pay calendar's "today".
final class ManualFreshnessTests: XCTestCase {
    private typealias F = DashboardFixture
    private func date(_ y: Int, _ m: Int, _ d: Int) -> Date { F.date(y, m, d) }

    private func manual(_ id: Int64, _ day: Date, _ amount: Int, account: Int64 = 1) -> Transaction {
        var t = F.txn(id, day, amount, category: nil, account: account)
        t.isManual = true
        return t
    }

    func testFreshnessIgnoresManualEntriesAndTheirBatch() {
        let input = F.input(
            today: date(2026, 10, 2),
            transactions: [F.txn(1, date(2026, 2, 14), -1_000, category: F.rentId), manual(2, date(2026, 12, 25), -500)],
            importBatches: [ImportBatch(id: 1, accountId: 1, sourceFileName: "feb.csv", importedAt: date(2026, 3, 1)),
                            ImportBatch(id: 2, accountId: 1, sourceFileName: ManualTransactions.batchSourceFileName, importedAt: date(2026, 10, 1))]
        )
        XCTAssertEqual(input.dataThrough, date(2026, 2, 14))
        let freshness = DashboardCalculator.dataFreshness(input)
        XCTAssertEqual(freshness.status, .behind(months: 7, days: 230))
        XCTAssertEqual(freshness.dataThrough, date(2026, 2, 14))
        XCTAssertEqual(freshness.lastImportFileName, "feb.csv")
        XCTAssertEqual(freshness.lastImportAt, date(2026, 3, 1))
    }

    func testOnlyManualEntriesMeansNoData() {
        let input = F.input(today: date(2026, 10, 2), transactions: [manual(1, date(2026, 10, 1), -500)],
                            importBatches: [ImportBatch(id: 1, accountId: 1, sourceFileName: ManualTransactions.batchSourceFileName, importedAt: date(2026, 10, 1))])
        let freshness = DashboardCalculator.dataFreshness(input)
        XCTAssertEqual(freshness.status, .noData)
        XCTAssertNil(freshness.lastImportAt)
        XCTAssertNil(freshness.lastImportFileName)
    }

    func testPayCalendarTodayIgnoresAFutureManualEntry() {
        let today = date(2026, 10, 2)
        let calendar = PayCalendar.forData(transactions: [F.txn(1, date(2026, 9, 1), -1, category: nil), manual(2, date(2027, 1, 15), -500)],
                                           categories: [], manualCloses: [], today: today)
        XCTAssertEqual(calendar.today, today)
        let imported = PayCalendar.forData(transactions: [F.txn(1, date(2026, 11, 1), -1, category: nil)], categories: [], manualCloses: [], today: today)
        XCTAssertEqual(imported.today, date(2026, 11, 1))
    }

    // An account's last update counts manual entries (an Update balance adjustment is one)
    // up to today, never a future-dated one; the import freshness above still ignores them.
    func testAccountsOverviewLastUpdatedCountsManualEntriesUpToToday() {
        let account = Account(id: 1, name: "Joint", currency: .gbp, kind: .cash, trackingMode: .imported)
        let overview = AccountsOverview.make(accounts: [account], snapshots: [],
                                             transactions: [F.txn(1, date(2026, 9, 1), -100, category: nil), manual(2, date(2026, 9, 20), -50), manual(3, date(2026, 12, 25), -25)],
                                             rate: ExchangeRateSetting(eurToGbpRate: 0.85, updatedAt: date(2026, 1, 1)), today: date(2026, 10, 2))
        let row = overview.groups.flatMap(\.rows).first
        XCTAssertEqual(row?.lastUpdated, date(2026, 9, 20))
        XCTAssertEqual(row?.nativeBalanceMinorUnits, -175)
    }
}
