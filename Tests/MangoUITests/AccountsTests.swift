import XCTest
import GRDB
@testable import BudgetCore
import struct BudgetCore.Category
import BudgetDemo
@testable import MangoUI
import TestSupport

/// Accounts' view models and the words its rows use (iPhone spec §3.6; plan step 4, Task 9). Figures come from
/// `AccountsOverview`, `DashboardCalculator`, `AccountHistory` and `TransactionSearch`; these tests pin that the
/// phone shows exactly the Mac's.
@MainActor
final class AccountsTests: XCTestCase {
    nonisolated private static func day(_ year: Int, _ month: Int, _ day: Int) -> Date {
        MonthRange.calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }

    private func emptyDatabase() throws -> DatabaseQueue {
        return try TestDatabase.migrated()
    }

    private static var cachedDemo: DatabaseQueue?

    /// The demo, built once for the class (read-only use only).
    private func demoDatabase() throws -> DatabaseQueue {
        if let queue = Self.cachedDemo { return queue }
        let queue = try emptyDatabase()
        try buildDemo(into: queue)
        Self.cachedDemo = queue
        return queue
    }

    private func buildDemo(into queue: DatabaseQueue) throws {
        let evidence = FileManager.default.temporaryDirectory.appendingPathComponent("AccountsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: evidence) }
        try TestDatabase.fillDemo(queue, evidenceRoot: evidence)
    }

    /// The Mac's Accounts screen's read (`App/Accounts/AccountsViewModel.load`).
    private func macOverview(_ queue: DatabaseQueue, today: Date) throws -> AccountsOverview {
        try queue.read { db in
            AccountsOverview.make(accounts: try Account.fetchAll(db), snapshots: try BalanceSnapshot.fetchAll(db),
                                  transactions: try Transaction.fetchAll(db), rate: try ExchangeRateSetting.currentOrDefault(db: db),
                                  today: today)
        }
    }

    private func loadedPage(_ model: AccountsViewModel) throws -> AccountsPage {
        guard case let .loaded(page) = model.state else {
            XCTFail("not loaded: \(model.state)")
            throw CancellationError()
        }
        return page
    }

    // MARK: Loading

    func testTheDemoIsTheMacsOverview() async throws {
        let queue = try demoDatabase()
        let today = DemoDatabase.defaultAsOf
        let model = AccountsViewModel(dbQueue: queue, today: { today })
        XCTAssertEqual(model.state, .idle)
        await model.load()
        let page = try loadedPage(model)
        XCTAssertEqual(page.overview, try macOverview(queue, today: today))
        XCTAssertFalse(page.sections.isEmpty)
        XCTAssertTrue(try AccountsViewModel.figuresCheck(dbQueue: queue, today: today, shown: page).matches)
    }

    /// Cash, Credit, Investments (iPhone spec §3.6), each with its group's subtotal and rows in the Mac's order.
    func testSectionsAreCashCreditInvestmentsWithTheGroupsSubtotals() async throws {
        let queue = try demoDatabase()
        let today = DemoDatabase.defaultAsOf
        let page = try XCTUnwrap(AccountsViewModel.readNow(queue, today: today).page)
        XCTAssertEqual(page.sections.map(\.kind), [.cash, .credit, .investment])
        XCTAssertEqual(page.sections.map(\.title), ["Cash", "Credit", "Investments"])
        let overview = try macOverview(queue, today: today)
        for section in page.sections {
            let group = try XCTUnwrap(overview.groups.first { $0.kind == section.kind })
            XCTAssertEqual(section.subtotalGBP, group.subtotalGBP, "\(section.kind)")
            XCTAssertEqual(section.rows.map(\.id), group.rows.map(\.id))
        }
    }

    /// The header's change is today's net worth against last December's real month end.
    func testTheChangeIsSinceLastDecember() async throws {
        let queue = try demoDatabase()
        let today = DemoDatabase.defaultAsOf
        let page = try XCTUnwrap(AccountsViewModel.readNow(queue, today: today).page)
        let december = try await queue.read { db in
            DashboardCalculator.yearEndNetWorth(try DashboardInput.load(db: db, today: today), year: 2025, includeForecast: false)
        }
        let since = try XCTUnwrap(page.sinceYearEnd)
        XCTAssertEqual(since.year, 2025)
        XCTAssertEqual(since.yearEndMinorUnits, try XCTUnwrap(december).valueMinorUnits)
        XCTAssertEqual(since.changeMinorUnits, page.overview.netWorthGBP - since.yearEndMinorUnits)
        XCTAssertEqual(AccountsCopy.sinceLabel(since), "Since December 2025")
    }

    func testAnEmptyDatabaseIsTheEmptyState() async throws {
        let model = AccountsViewModel(dbQueue: try emptyDatabase(), today: { Self.day(2026, 10, 15) })
        await model.load()
        XCTAssertEqual(model.state, .empty)
    }

    func testAFailedReadKeepsThePageAndAFirstFailureShowsTheFixedSentence() async throws {
        let queue = try emptyDatabase()
        try buildDemo(into: queue)
        let model = AccountsViewModel(dbQueue: queue, today: { DemoDatabase.defaultAsOf })
        await model.load()
        guard case .loaded = model.state else { return XCTFail("not loaded") }
        try await queue.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA foreign_keys = OFF")
            try db.execute(sql: "DROP TABLE balanceSnapshot")
        }
        await model.load()
        guard case .loaded = model.state else { return XCTFail("the page was dropped: \(model.state)") }
        XCTAssertEqual(model.errorMessage, AccountsViewModel.loadFailureMessage)

        let fresh = AccountsViewModel(dbQueue: queue, today: { DemoDatabase.defaultAsOf })
        await fresh.load()
        XCTAssertEqual(fresh.state, .failed(AccountsViewModel.loadFailureMessage))
        XCTAssertFalse(AccountsViewModel.loadFailureMessage.contains("SQL"))
    }

    func testAReloadWaitsForANewSync() async throws {
        let queue = try emptyDatabase()
        let model = AccountsViewModel(dbQueue: queue, today: { DemoDatabase.defaultAsOf })
        await model.reload(for: nil)
        XCTAssertEqual(model.state, .empty)
        try buildDemo(into: queue)
        await model.reload(for: nil)  // a sync running: keeps what is shown
        XCTAssertEqual(model.state, .empty)
        await model.reload(for: Self.day(2026, 10, 15))
        guard case .loaded = model.state else { return XCTFail("not loaded: \(model.state)") }
        await model.reload(for: Self.day(2026, 10, 15))  // the same sync: no second read
        XCTAssertEqual(AccountsViewModel.reloadKey(.idle(lastSync: Self.day(2026, 10, 15))), Self.day(2026, 10, 15))
        XCTAssertNil(AccountsViewModel.reloadKey(.syncing(.pulling)))
    }

    // MARK: Rows

    private func account(_ kind: AccountKind = .cash, currency: Currency = .gbp, mode: AccountTrackingMode = .manual,
                         inNetWorth: Bool = true) -> Account {
        Account(id: 7, name: "Saver", currency: currency, kind: kind, trackingMode: mode, includeInNetWorth: inNetWorth)
    }

    private func row(_ account: Account, native: Int = 120_000, gbp: Int = 120_000, lastUpdated: Date? = nil,
                     stale: Bool = false) -> AccountRow {
        AccountRow(account: account, nativeBalanceMinorUnits: native, gbpBalanceMinorUnits: gbp, lastUpdated: lastUpdated, isStale: stale)
    }

    func testAnImportedAccountSaysHowFarItsImportsReach() {
        let shown = AccountRowPresentation(row(account(mode: .imported), lastUpdated: Self.day(2026, 10, 14)),
                                           importedThrough: Self.day(2026, 10, 12), today: Self.day(2026, 10, 15))
        XCTAssertEqual(shown.caption, "Imported · through 12 Oct 2026")
        XCTAssertFalse(shown.needsUpdate)
    }

    func testAManualAccountSaysWhenItWasLastChecked() {
        let today = Self.day(2026, 10, 15)
        func caption(_ last: Date?) -> String {
            AccountRowPresentation(row(account(), lastUpdated: last), importedThrough: nil, today: today).caption
        }
        XCTAssertEqual(caption(Self.day(2026, 10, 15)), "Checked today")
        XCTAssertEqual(caption(Self.day(2026, 10, 14)), "Checked 1 day ago")
        XCTAssertEqual(caption(Self.day(2026, 9, 15)), "Checked 30 days ago")
        XCTAssertEqual(caption(Self.day(2026, 6, 1)), "Checked 4 months ago")
        XCTAssertEqual(caption(nil), "No balance recorded yet")
    }

    /// The Mac's staleness rule (`BalanceStaleness`, through `AccountRow.isStale`): amber "Needs an update".
    func testAStaleAccountNeedsAnUpdate() {
        let shown = AccountRowPresentation(row(account(.investment), lastUpdated: Self.day(2026, 7, 1), stale: true),
                                           importedThrough: nil, today: Self.day(2026, 10, 15))
        XCTAssertTrue(shown.needsUpdate)
        XCTAssertEqual(AccountsCopy.needsUpdate, "Needs an update")
        XCTAssertTrue(shown.spoken.contains("Needs an update"))
    }

    func testANonPoundAccountShowsItsPoundsBeneath() {
        let euro = AccountRowPresentation(row(account(currency: .eur), native: 100_000, gbp: 87_000), importedThrough: nil,
                                          today: Self.day(2026, 10, 15))
        XCTAssertEqual(euro.currency, .eur)
        XCTAssertEqual(euro.nativeMinorUnits, 100_000)
        XCTAssertEqual(euro.gbpMinorUnits, 87_000)
        let pounds = AccountRowPresentation(row(account()), importedThrough: nil, today: Self.day(2026, 10, 15))
        XCTAssertNil(pounds.gbpMinorUnits)
    }

    func testAnAccountOutsideNetWorthSaysSo() {
        let shown = AccountRowPresentation(row(account(inNetWorth: false)), importedThrough: nil, today: Self.day(2026, 10, 15))
        XCTAssertFalse(shown.isInNetWorth)
        XCTAssertTrue(shown.spoken.contains(AccountsCopy.notInNetWorth))
    }

    func testARowReadsItsBalanceToVoiceOver() {
        let shown = AccountRowPresentation(row(account(.credit), native: -32_000, gbp: -32_000, lastUpdated: Self.day(2026, 10, 15)),
                                           importedThrough: nil, today: Self.day(2026, 10, 15))
        XCTAssertEqual(shown.name, "Saver")
        XCTAssertTrue(shown.spoken.hasPrefix("owed £320.00"), shown.spoken)
    }

    // MARK: Detail

    /// The chart is `AccountHistory.make` over everything (as the Mac makes it), though the phone reads only the
    /// account's rows; the list is `TransactionSearch`'s newest, limited.
    func testTheDetailIsTheMacsHistoryAndTheNewestTransactions() async throws {
        let queue = try demoDatabase()
        let today = DemoDatabase.defaultAsOf
        let page = try XCTUnwrap(AccountsViewModel.readNow(queue, today: today).page)
        let row = try XCTUnwrap(page.sections.first?.rows.first)
        let model = AccountsViewModel(dbQueue: queue, today: { today }, preloaded: .loaded(page))
        let detail = model.detailModel(for: AccountDestination(accountId: row.id))
        XCTAssertEqual(detail.state, .idle)
        await detail.load()
        guard case let .loaded(shown) = detail.state else { return XCTFail("not loaded: \(detail.state)") }

        let (history, search) = try await queue.read { db in
            let builtIns = try Category.filter(Column("builtInRole") != nil).fetchAll(db)
            let names = Dictionary(uniqueKeysWithValues: builtIns.map { ($0.id!, $0.name) })
            let history = AccountHistory.make(accountId: row.id, snapshots: try BalanceSnapshot.fetchAll(db),
                                              transactions: try Transaction.fetchAll(db), adjustmentCategoryNames: names, today: today)
            let input = TransactionSearch.Input(transactions: try Transaction.fetchAll(db), categories: try Category.fetchAll(db),
                                                accounts: try Account.fetchAll(db), links: try TransferLink.fetchAll(db),
                                                eurToGbpRate: try ExchangeRateSetting.currentOrDefault(db: db).eurToGbpRate)
            return (history, TransactionSearch.rows(input, criteria: .init(accountIds: [row.id]), now: today))
        }
        XCTAssertEqual(shown.history, history)
        XCTAssertGreaterThan(shown.history.points.count, 1)
        XCTAssertEqual(shown.recent, Array(search.prefix(AccountDetailModel.recentLimit)))
        XCTAssertEqual(shown.recent.count, AccountDetailModel.recentLimit)
        XCTAssertEqual(shown.account.id, row.id)
    }

    func testASyncRefreshesAPushedDetailInPlace() async throws {
        let queue = try demoDatabase()
        let today = DemoDatabase.defaultAsOf
        let model = AccountsViewModel(dbQueue: queue, today: { today })
        await model.reload(for: Self.day(2026, 10, 1))
        let page = try loadedPage(model)
        let row = try XCTUnwrap(page.sections.first?.rows.first)
        let destination = AccountDestination(accountId: row.id)
        let detail = model.detailModel(for: destination)
        await detail.load()
        await model.reload(for: Self.day(2026, 10, 2))
        XCTAssertTrue(model.detailModel(for: destination) === detail)
        guard case .loaded = detail.state else { return XCTFail("the detail was reset: \(detail.state)") }
        XCTAssertEqual(detail.row, row)
    }

    func testATransactionsAmountTakesItsCategorysRole() {
        let groceries = Category(id: 1, name: "Groceries", type: .expense)
        XCTAssertEqual(AccountDetailModel.amount(-2_499, category: groceries).role, .expense)
        XCTAssertEqual(AccountDetailModel.amount(-2_499, category: groceries).minorUnits, 2_499)
        let uncategorised = AccountDetailModel.amount(-2_499, category: nil)
        XCTAssertEqual(uncategorised.minorUnits, -2_499)
        XCTAssertEqual(uncategorised.role, .income)
    }
}
