import XCTest
@testable import BudgetCore

final class DashboardCalculatorTests: XCTestCase {
    private typealias F = DashboardFixture
    private func date(_ y: Int, _ m: Int, _ d: Int) -> Date { F.date(y, m, d) }

    // MARK: freshness

    func testBehindWhenTheLatestTransactionIsMonthsOld() {
        let input = F.input(
            today: date(2026, 10, 2),
            transactions: [F.txn(1, date(2026, 2, 14), -1_000, category: F.rentId)],
            importBatches: [ImportBatch(id: 1, accountId: 1, sourceFileName: "Budget copy.numbers", importedAt: date(2026, 9, 23))]
        )
        let freshness = DashboardCalculator.dataFreshness(input)
        XCTAssertEqual(freshness.status, .behind(months: 7, days: 230))
        XCTAssertEqual(freshness.dataThrough, date(2026, 2, 14))
        XCTAssertEqual(freshness.lastImportAt, date(2026, 9, 23))
        XCTAssertEqual(freshness.lastImportFileName, "Budget copy.numbers")
    }

    func testThirtyOneDaysIsStillUpToDateAndThirtyTwoIsBehind() {
        let today = date(2026, 10, 2)
        XCTAssertEqual(DashboardCalculator.dataFreshness(F.input(today: today, transactions: [F.txn(1, date(2026, 9, 1), -1, category: nil)])).status, .upToDate)
        XCTAssertEqual(DashboardCalculator.dataFreshness(F.input(today: today, transactions: [F.txn(1, date(2026, 8, 31), -1, category: nil)])).status, .behind(months: 1, days: 32))
    }

    func testFreshnessThresholdIgnoresTheTimeOfDayOfToday() {
        let afternoon = date(2026, 10, 2).addingTimeInterval(14 * 3600) // what the view model passes: Date()
        // Exactly 31 days earlier (1 Sep) is still up to date even at 14:00.
        XCTAssertEqual(DashboardCalculator.dataFreshness(F.input(today: afternoon, transactions: [F.txn(1, date(2026, 9, 1), -1, category: nil)])).status, .upToDate)
        // 32 days earlier (31 Aug) is behind.
        XCTAssertEqual(DashboardCalculator.dataFreshness(F.input(today: afternoon, transactions: [F.txn(1, date(2026, 8, 31), -1, category: nil)])).status, .behind(months: 1, days: 32))
    }

    func testNoTransactionsMeansNoData() {
        XCTAssertEqual(DashboardCalculator.dataFreshness(F.input(today: date(2026, 10, 2))).status, .noData)
    }

    // MARK: attention

    func testUncategorizedCountIncludesNilCategoryAndPendingReview() {
        let input = F.input(today: date(2026, 10, 2), transactions: [
            F.txn(1, date(2026, 9, 1), -100, category: F.rentId),
            F.txn(2, date(2026, 9, 2), -100, category: nil, status: .pendingReview),
            F.txn(3, date(2026, 9, 3), -100, category: F.groceriesId, status: .pendingReview)
        ])
        XCTAssertEqual(DashboardCalculator.attentionItems(input).uncategorizedCount, 2)
    }

    func testStaleBalancesExcludeImportedAccountsAndUseA45DayThreshold() {
        let today = date(2026, 10, 2) // 45 days earlier = 2026-08-18
        let accounts = [
            Account(id: 1, name: "Old", currency: .gbp, kind: .cash, trackingMode: .manual),
            Account(id: 2, name: "Imported", currency: .gbp, kind: .cash, trackingMode: .imported),
            Account(id: 3, name: "Fresh", currency: .gbp, kind: .cash, trackingMode: .manual),
            Account(id: 4, name: "Never", currency: .gbp, kind: .cash, trackingMode: .manual),
            Account(id: 5, name: "Edge", currency: .gbp, kind: .cash, trackingMode: .manual)
        ]
        let snapshots = [
            F.snapshot(1, date(2026, 1, 1), 100), F.snapshot(2, date(2025, 1, 1), 100), F.snapshot(3, date(2026, 9, 20), 100),
            F.snapshot(5, date(2026, 8, 17), 100) // 46 days old → stale
        ]
        let items = DashboardCalculator.attentionItems(F.input(today: today, accounts: accounts, snapshots: snapshots))
        XCTAssertEqual(items.staleBalanceCount, 3) // Old, Never, Edge
        XCTAssertEqual(items.oldestStaleSnapshotDate, date(2026, 1, 1))

        let exactly45 = DashboardCalculator.attentionItems(F.input(today: today, accounts: [accounts[4]], snapshots: [F.snapshot(5, date(2026, 8, 18), 100)]))
        XCTAssertEqual(exactly45.staleBalanceCount, 0)
    }

    func testStaleThresholdIgnoresTheTimeOfDayOfToday() {
        let afternoon = date(2026, 10, 2).addingTimeInterval(14 * 3600)
        let account = Account(id: 5, name: "Edge", currency: .gbp, kind: .cash, trackingMode: .manual)
        // Exactly 45 days earlier (18 Aug) is still fresh at 14:00.
        let fresh = DashboardCalculator.attentionItems(F.input(today: afternoon, accounts: [account], snapshots: [F.snapshot(5, date(2026, 8, 18), 100)]))
        XCTAssertEqual(fresh.staleBalanceCount, 0)
        XCTAssertNil(fresh.oldestStaleSnapshotDate)
        // 46 days earlier (17 Aug) is stale.
        let stale = DashboardCalculator.attentionItems(F.input(today: afternoon, accounts: [account], snapshots: [F.snapshot(5, date(2026, 8, 17), 100)]))
        XCTAssertEqual(stale.staleBalanceCount, 1)
        XCTAssertEqual(stale.oldestStaleSnapshotDate, date(2026, 8, 17))
    }

    func testMissingReserveAllowance() {
        let today = date(2026, 10, 2)
        let bulk = ForecastEntry(id: 9, groupId: 1, categoryId: F.bulkId, amountMinorUnits: -200_000, frequency: .monthly, interval: 1, startDate: date(2026, 10, 1), endDate: nil, isEnabled: true, status: .confirmed, note: nil)
        // No reserve at all.
        XCTAssertTrue(DashboardCalculator.attentionItems(F.input(today: today)).missingReserveAllowance)
        // A reserve with no allowance.
        XCTAssertTrue(DashboardCalculator.attentionItems(F.input(today: today, reservedId: F.bulkId)).missingReserveAllowance)
        // A reserve whose allowance covers this month.
        XCTAssertFalse(DashboardCalculator.attentionItems(F.input(today: today, entries: F.withDining + [bulk], reservedId: F.bulkId)).missingReserveAllowance)
        // An allowance that ended before this month doesn't count.
        var ended = bulk; ended.startDate = date(2026, 1, 1); ended.endDate = date(2026, 3, 31)
        XCTAssertTrue(DashboardCalculator.attentionItems(F.input(today: today, entries: F.withDining + [ended], reservedId: F.bulkId)).missingReserveAllowance)
    }

    // MARK: accounts

    func testAccountSummariesAreSortedLargestFirstWithGBPConversion() {
        let accounts = [
            Account(id: 1, name: "Current", currency: .gbp, kind: .cash, trackingMode: .manual),
            Account(id: 2, name: "Card", currency: .gbp, kind: .credit, trackingMode: .manual),
            Account(id: 3, name: "EUR", currency: .eur, kind: .cash, trackingMode: .manual)
        ]
        // 1_200_000 EUR × 0.5 = 600_000 GBP, strictly above Current's 500_000 so the order is unambiguous.
        let snapshots = [F.snapshot(1, date(2026, 1, 1), 500_000), F.snapshot(2, date(2026, 1, 1), -200_000), F.snapshot(3, date(2026, 1, 1), 1_200_000)]
        let summaries = DashboardCalculator.accountSummaries(F.input(today: date(2026, 10, 2), accounts: accounts, snapshots: snapshots))
        XCTAssertEqual(summaries.map(\.name), ["EUR", "Current", "Card"])
        XCTAssertEqual(summaries.map(\.gbpBalanceMinorUnits), [600_000, 500_000, -200_000])
        XCTAssertEqual(summaries[0].nativeBalanceMinorUnits, 1_200_000)
    }

    // MARK: upcoming bills

    func testUpcomingBillsWindowIncludesTodayAndDay30AndOnlyConfirmedExpenses() {
        let hypothetical = ForecastEntry(id: 7, groupId: 1, categoryId: F.groceriesId, amountMinorUnits: -9_999, frequency: .monthly, interval: 1, startDate: date(2026, 10, 10), endDate: nil, isEnabled: true, status: .hypothetical, note: nil)
        let ended = ForecastEntry(id: 8, groupId: 1, categoryId: F.groceriesId, amountMinorUnits: -5_000, frequency: .monthly, interval: 1, startDate: date(2026, 1, 3), endDate: date(2026, 9, 30), isEnabled: true, status: .manual, note: nil)
        let disabled = ForecastEntry(id: 9, groupId: 1, categoryId: F.groceriesId, amountMinorUnits: -1_000, frequency: .monthly, interval: 1, startDate: date(2026, 1, 5), endDate: nil, isEnabled: false, status: .manual, note: nil)
        let input = F.input(today: date(2026, 10, 2), entries: F.withDining + [hypothetical, ended, disabled])
        let bills = DashboardCalculator.upcomingBills(input, days: 30)
        // Rent falls on 1 Nov (day 30 → included); dining on 14 Oct; salary (income), the
        // hypothetical, ended and disabled entries are all excluded.
        XCTAssertEqual(bills.map(\.categoryName), ["Dining", "Rent"])
        XCTAssertEqual(bills.map(\.date), [date(2026, 10, 14), date(2026, 11, 1)])
        XCTAssertEqual(bills.map(\.amountMinorUnits), [-40_000, -100_000])
    }

    func testUpcomingBillsIncludeTodayAndExcludeDay31() {
        let bills = DashboardCalculator.upcomingBills(F.input(today: date(2026, 10, 1)), days: 30)
        // Rent on 1 Oct (today) is in; rent on 1 Nov is day 31 → out.
        XCTAssertEqual(bills.map(\.date), [date(2026, 10, 1), date(2026, 10, 14)])
    }
}
