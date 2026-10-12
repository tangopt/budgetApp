import XCTest
import GRDB
@testable import BudgetCore

/// A linked transfer counts once, as sent (spec §6): the incoming leg is left out of every
/// budget figure; balances keep both legs.
final class TransferBudgetFacingTests: XCTestCase {
    private let d = TransferFixture.date

    /// Classic sends £360 (Transfer: International) and International receives it, the
    /// incoming leg uncategorised; plus a £20 groceries spend and an uncategorised £5.
    private func linkedFixture() throws -> (f: TransferFixture, out: Int64, inLeg: Int64) {
        let f = try TransferFixture()
        let out = try f.add(f.classic, d(2026, 3, 9), -36_000, category: f.transferCategory)
        let inLeg = try f.add(f.international, d(2026, 3, 9), 36_000)
        try f.add(f.classic, d(2026, 3, 10), -2_000, category: f.groceries, description: "TESCO")
        try f.add(f.classic, d(2026, 3, 11), -500, description: "CORNER SHOP")
        XCTAssertEqual(try f.match(), 1)
        return (f, out, inLeg)
    }

    func testBudgetFacingRequestLeavesOutIncomingLegsOfActiveLinksOnly() throws {
        let (f, out, inLeg) = try linkedFixture()
        let ids = try f.manager.dbQueue.read { db in try Transaction.budgetFacing.fetchAll(db).compactMap(\.id) }
        XCTAssertTrue(ids.contains(out))
        XCTAssertFalse(ids.contains(inLeg))
        XCTAssertEqual(ids.count, 3)
        // A dismissed link counts both legs again.
        let link = try XCTUnwrap(f.links().first)
        try f.manager.dbQueue.write { db in try TransferLinks.unlink(db: db, linkId: link.id!) }
        XCTAssertEqual(try f.manager.dbQueue.read { db in try Transaction.budgetFacing.fetchCount(db) }, 4)
    }

    func testUncategorizedListAndCountSkipIncomingLegs() throws {
        let (f, _, _) = try linkedFixture()
        let (list, count) = try f.manager.dbQueue.read { db in
            (try UncategorizedTransactions.fetch(db: db), try UncategorizedTransactions.count(db: db))
        }
        XCTAssertEqual(list.map(\.rawDescription), ["CORNER SHOP"])
        XCTAssertEqual(count, 1)
    }

    func testHistoryAndRecentCategoriesSkipIncomingLegs() throws {
        let f = try TransferFixture()
        // Two linked transfers whose incoming legs were filed under Groceries: neither
        // teaches history nor counts as a recent use.
        for day in [9, 20] {
            try f.add(f.classic, d(2026, 3, day), -36_000, category: f.transferCategory)
            try f.add(f.international, d(2026, 3, day), 36_000, category: f.groceries)
        }
        try f.match()
        let (history, recent) = try f.manager.dbQueue.read { db in
            (try HistoryCategorizer.load(db: db), try CategoryShortlist.recent(db: db, since: d(2026, 1, 1), limit: 5))
        }
        XCTAssertEqual(history.map(\.categoryId), [f.transferCategory, f.transferCategory])
        XCTAssertEqual(recent, [f.transferCategory])
    }

    func testPayMonthTotalsAndBudgetGridCountTheTransferOnceAsSent() throws {
        let f = try TransferFixture()
        try f.add(f.classic, d(2026, 3, 9), -36_000, category: f.transferCategory)
        try f.add(f.international, d(2026, 3, 9), 36_000, category: f.transferCategory)
        try f.match()
        let (all, budget, calendar, category) = try f.manager.dbQueue.read { db in
            (try Transaction.fetchAll(db), try Transaction.budgetFacing.fetchAll(db),
             try PayCalendar.load(db: db, today: d(2026, 10, 12)), try Category.fetchOne(db, key: f.transferCategory)!)
        }
        // Without the link the two legs would cancel out to 0.
        XCTAssertEqual(PayMonthTotals.lookup(transactions: all, calendar: calendar)[f.transferCategory]?[2026]?[3], 0)
        XCTAssertEqual(PayMonthTotals.lookup(transactions: budget, calendar: calendar)[f.transferCategory]?[2026]?[3], -36_000)
        let march = PayPeriod(startDate: d(2026, 3, 1), endDate: d(2026, 3, 31), type: .actual)
        XCTAssertEqual(BudgetGridCalculator.categoryTotal(category: category, period: march, transactions: budget, forecastEntries: [], forecastGroups: [], exceptions: []), -36_000)
        // The in-memory twin agrees with the request.
        let links = try f.links()
        XCTAssertEqual(TransferLinks.budgetFacing(all, links: links).map(\.id), budget.map(\.id))
    }

    func testAccountFilterCountsEachSelectedAccountsOwnLegs() throws {
        let (f, out, inLeg) = try linkedFixture()
        let (all, links) = try f.manager.dbQueue.read { db in (try Transaction.fetchAll(db), try TransferLink.fetchAll(db)) }
        let ids = { (accounts: Set<Int64>?) in Set(TransferLinks.budgetFacing(all, links: links, accountIds: accounts).compactMap(\.id)) }
        // Only International: the money arriving counts.
        XCTAssertEqual(ids([f.international]), [inLeg])
        // Both accounts: once, as sent.
        XCTAssertTrue(ids([f.classic, f.international]).contains(out))
        XCTAssertFalse(ids([f.classic, f.international]).contains(inLeg))
        XCTAssertFalse(ids([f.classic]).contains(inLeg))
        XCTAssertEqual(ids(nil), ids([f.classic, f.international, f.euro]))
    }

    // MARK: Dashboard

    private typealias F = DashboardFixture

    /// Account 1 sends £500 to account 2 in March (pay months = calendar months, closed
    /// through September); account 2 files its incoming leg as Salary, and an uncategorised
    /// incoming leg arrives too.
    private func dashboardInput(linked: Bool) -> DashboardInput {
        let transactions = [
            F.txn(1, F.date(2026, 3, 5), -50_000, category: F.savingsId, account: 1),
            F.txn(2, F.date(2026, 3, 5), 50_000, category: F.salaryId, account: 2),
            F.txn(3, F.date(2026, 3, 6), -1_000, category: F.savingsId, account: 1),
            F.txn(4, F.date(2026, 3, 6), 1_000, category: nil, status: .pendingReview, account: 2)
        ]
        let closes = (1...9).map { month in
            PayMonthClose(year: 2026, month: month, closeDate: F.date(2026, month + 1, 1).addingTimeInterval(-86_400))
        }
        let accounts = [Account(id: 1, name: "Classic", currency: .gbp, kind: .cash, trackingMode: .imported),
                        Account(id: 2, name: "International", currency: .gbp, kind: .cash, trackingMode: .imported)]
        let snapshots = [F.snapshot(1, F.date(2026, 1, 1), 100_000), F.snapshot(2, F.date(2026, 1, 1), 0)]
        let links = linked ? [TransferLink(id: 1, outTransactionId: 1, inTransactionId: 2, origin: .auto),
                              TransferLink(id: 2, outTransactionId: 3, inTransactionId: 4, origin: .manual)] : []
        return F.input(today: F.date(2026, 10, 14), accounts: accounts, snapshots: snapshots, transactions: transactions,
                       entries: [], manualCloses: closes, transferLinks: links)
    }

    func testDashboardFlowsAndCountsLeaveOutIncomingLegs() {
        let unlinked = dashboardInput(linked: false)
        let linked = dashboardInput(linked: true)
        XCTAssertEqual(DashboardCalculator.monthlyFlows(unlinked, year: 2026)[2].incomeActual, 50_000)
        XCTAssertEqual(DashboardCalculator.monthlyFlows(linked, year: 2026)[2].incomeActual, 0)
        XCTAssertEqual(DashboardCalculator.unreviewed(unlinked, year: 2026).count, 1)
        XCTAssertEqual(DashboardCalculator.unreviewed(linked, year: 2026).count, 0)
        XCTAssertEqual(DashboardCalculator.attentionItems(linked).uncategorizedCount, 0)
    }

    func testBalancesAndNetWorthKeepBothLegs() {
        let unlinked = dashboardInput(linked: false)
        let linked = dashboardInput(linked: true)
        XCTAssertEqual(DashboardCalculator.accountSummaries(linked), DashboardCalculator.accountSummaries(unlinked))
        XCTAssertEqual(DashboardCalculator.accountSummaries(linked).first { $0.id == 2 }?.nativeBalanceMinorUnits, 51_000)
        XCTAssertEqual(DashboardCalculator.netWorthSeries(linked), DashboardCalculator.netWorthSeries(unlinked))
    }
}
