import XCTest
@testable import BudgetCore

final class AccountsOverviewTests: XCTestCase {
    private func day(_ y: Int, _ m: Int, _ d: Int, hour: Int = 12) -> Date {
        MonthRange.calendar.date(from: DateComponents(year: y, month: m, day: d, hour: hour))!
    }
    private let today = MonthRange.calendar.date(from: DateComponents(year: 2026, month: 10, day: 7, hour: 9))!
    private let rate = ExchangeRateSetting(eurToGbpRate: 0.5, updatedAt: Date())

    private func acct(_ id: Int64, _ name: String, _ currency: Currency = .gbp, _ kind: AccountKind = .cash, _ mode: AccountTrackingMode = .manual) -> Account {
        Account(id: id, name: name, currency: currency, kind: kind, trackingMode: mode)
    }
    private func snap(_ id: Int64, _ date: Date, _ amount: Int) -> BalanceSnapshot {
        BalanceSnapshot(accountId: id, date: date, balanceMinorUnits: amount, note: nil)
    }

    // MARK: staleness

    func testImportedIsNeverStale() {
        XCTAssertFalse(BalanceStaleness.isStale(account: acct(1, "A", .gbp, .cash, .imported), latestSnapshot: nil, today: today))
        XCTAssertFalse(BalanceStaleness.isStale(account: acct(1, "A", .gbp, .cash, .imported), latestSnapshot: day(2020, 1, 1), today: today))
    }

    func testManualWithNoSnapshotIsStale() {
        XCTAssertTrue(BalanceStaleness.isStale(account: acct(1, "A"), latestSnapshot: nil, today: today))
    }

    func testFortyFiveDaysNotStaleFortySixStale() {
        let a = acct(1, "A")
        let start = MonthRange.calendar.startOfDay(for: today)
        let d45 = MonthRange.calendar.date(byAdding: .day, value: -45, to: start)!.addingTimeInterval(12 * 3600)
        let d46 = MonthRange.calendar.date(byAdding: .day, value: -46, to: start)!.addingTimeInterval(12 * 3600)
        XCTAssertFalse(BalanceStaleness.isStale(account: a, latestSnapshot: d45, today: today))
        XCTAssertTrue(BalanceStaleness.isStale(account: a, latestSnapshot: d46, today: today))
    }

    // MARK: overview

    func testOverviewGroupsTotalsAndChange() {
        let accounts = [
            acct(1, "Current"), acct(2, "Euro", .eur), acct(3, "ISA", .gbp, .investment), acct(4, "Card", .gbp, .credit),
        ]
        let snapshots = [
            // previous month end (September)
            snap(1, day(2026, 9, 20), 11_000), snap(2, day(2026, 9, 20), 10_000), snap(3, day(2026, 9, 20), 20_000), snap(4, day(2026, 9, 20), -3_000),
            // this month
            snap(1, day(2026, 10, 1), 10_000), snap(2, day(2026, 10, 1), 10_000), snap(3, day(2026, 10, 1), 20_000), snap(4, day(2026, 10, 5), -3_000),
        ]
        let o = AccountsOverview.make(accounts: accounts, snapshots: snapshots, transactions: [], rate: rate, today: today)
        XCTAssertEqual(o.groups.map(\.kind), [.cash, .investment, .credit])
        XCTAssertEqual(o.groups.map(\.subtotalGBP), [15_000, 20_000, -3_000])
        XCTAssertEqual(o.netWorthGBP, 32_000)
        let cash = o.groups[0].rows
        XCTAssertEqual(cash.map(\.account.name), ["Current", "Euro"])
        XCTAssertEqual(cash[1].nativeBalanceMinorUnits, 10_000)
        XCTAssertEqual(cash[1].gbpBalanceMinorUnits, 5_000)
        XCTAssertEqual(o.changeVsPreviousMonthGBP, -1_000)
        XCTAssertEqual(o.asOf, day(2026, 10, 5))
        XCTAssertEqual(o.staleCount, 0)
        XCTAssertNil(o.oldestStaleDate)
    }

    func testStaleCountOldestAndImportedExemption() {
        let accounts = [acct(1, "Old"), acct(2, "Older"), acct(3, "Never"), acct(4, "Imp", .gbp, .cash, .imported), acct(5, "Fresh")]
        let snapshots = [
            snap(1, day(2026, 6, 1), 100), snap(2, day(2026, 5, 1), 100), snap(4, day(2026, 1, 1), 100), snap(5, day(2026, 10, 1), 100),
        ]
        let txn = Transaction(importBatchId: 1, accountId: 4, date: day(2026, 10, 3), rawDescription: "x", amountMinorUnits: -50, categoryId: nil, status: .confirmed, categorizedBy: .none, fingerprint: "f")
        let o = AccountsOverview.make(accounts: accounts, snapshots: snapshots, transactions: [txn], rate: rate, today: today)
        XCTAssertEqual(o.staleCount, 3)
        XCTAssertEqual(o.oldestStaleDate, day(2026, 5, 1))
        let imp = o.groups[0].rows.first { $0.account.name == "Imp" }!
        XCTAssertFalse(imp.isStale)
        XCTAssertEqual(imp.lastUpdated, day(2026, 10, 3))
        XCTAssertEqual(imp.nativeBalanceMinorUnits, 50)
    }

    func testChangeIsNilWithoutPreviousMonthData() {
        let o = AccountsOverview.make(accounts: [acct(1, "A")], snapshots: [snap(1, day(2026, 10, 1), 100)], transactions: [], rate: rate, today: today)
        XCTAssertNil(o.changeVsPreviousMonthGBP)
    }
}
