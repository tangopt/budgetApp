import XCTest
import GRDB
@testable import BudgetCore
import struct BudgetCore.Category
import struct BudgetCore.Transaction
import BudgetDemo
@testable import MangoUI
import TestSupport

/// Search on the phone (iPhone spec §3.4; plan step 4, Task 11): what the field and the tokens turn into
/// (`SearchQuery`), and what the tab shows (`SearchViewModel`): `TransactionSearch`'s rows, grouped by day, each
/// day's total `TransactionSearch.totals`.
@MainActor
final class SearchTests: XCTestCase {
    private func emptyDatabase() throws -> DatabaseQueue {
        return try TestDatabase.migrated()
    }

    private static var cachedDemo: DatabaseQueue?

    /// The demo, built once for the class (read-only use only).
    private func demoDatabase() throws -> DatabaseQueue {
        if let queue = Self.cachedDemo { return queue }
        let queue = try emptyDatabase()
        let evidence = FileManager.default.temporaryDirectory.appendingPathComponent("SearchTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: evidence) }
        try TestDatabase.fillDemo(queue, evidenceRoot: evidence)
        Self.cachedDemo = queue
        return queue
    }

    private let today = DemoDatabase.defaultAsOf

    private func loadedModel(_ queue: DatabaseQueue) async throws -> SearchViewModel {
        let day = today
        let model = SearchViewModel(dbQueue: queue, today: { day }, queryDelay: .zero)
        await model.load()
        await model.settle()
        guard case .loaded = model.state else { throw XCTSkip("not loaded: \(model.state)") }
        return model
    }

    // MARK: The field

    func testPlainWordsStayText() {
        let criteria = SearchQuery.criteria(text: "  bean   coffee ", tokens: [])
        XCTAssertEqual(criteria.text, "bean coffee")
        XCTAssertNil(criteria.minAmountMinorUnits)
        XCTAssertNil(criteria.maxAmountMinorUnits)
        XCTAssertTrue(SearchQuery.criteria(text: "   ", tokens: []).isDefault)
    }

    /// "24.99" stays a word: `TransactionSearch` matches it as that exact amount (either sign) or as text.
    func testAnExactAmountStaysAWordForTransactionSearch() {
        let criteria = SearchQuery.criteria(text: "24.99", tokens: [])
        XCTAssertEqual(criteria.text, "24.99")
        XCTAssertNil(criteria.minAmountMinorUnits)
    }

    func testGreaterThanIsStrictlyMoreThanTheAmount() {
        XCTAssertEqual(SearchQuery.criteria(text: ">100", tokens: []).minAmountMinorUnits, 10_001)
        XCTAssertEqual(SearchQuery.criteria(text: ">£100", tokens: []).minAmountMinorUnits, 10_001)
        XCTAssertEqual(SearchQuery.criteria(text: "> 100", tokens: []).minAmountMinorUnits, 10_001)
        XCTAssertEqual(SearchQuery.criteria(text: ">100", tokens: []).text, "")
    }

    func testAtLeastAndLessThanAndAtMost() {
        XCTAssertEqual(SearchQuery.criteria(text: ">=100", tokens: []).minAmountMinorUnits, 10_000)
        XCTAssertEqual(SearchQuery.criteria(text: "≥100", tokens: []).minAmountMinorUnits, 10_000)
        XCTAssertEqual(SearchQuery.criteria(text: "<50", tokens: []).maxAmountMinorUnits, 4_999)
        XCTAssertEqual(SearchQuery.criteria(text: "<=50", tokens: []).maxAmountMinorUnits, 5_000)
        XCTAssertEqual(SearchQuery.criteria(text: "≤12.50", tokens: []).maxAmountMinorUnits, 1_250)
    }

    func testBoundsCombineWithWords() {
        let criteria = SearchQuery.criteria(text: "coffee >3 <4", tokens: [])
        XCTAssertEqual(criteria.text, "coffee")
        XCTAssertEqual(criteria.minAmountMinorUnits, 301)
        XCTAssertEqual(criteria.maxAmountMinorUnits, 399)
    }

    /// Two lower bounds keep the higher one; two upper bounds the lower one.
    func testRepeatedBoundsKeepTheNarrowest() {
        let criteria = SearchQuery.criteria(text: ">10 >20 <90 <80", tokens: [])
        XCTAssertEqual(criteria.minAmountMinorUnits, 2_001)
        XCTAssertEqual(criteria.maxAmountMinorUnits, 7_999)
    }

    /// A comparison without an amount is just a word; a lone ">" at the end is dropped.
    func testAComparisonWithoutAnAmountIsText() {
        let criteria = SearchQuery.criteria(text: ">abc", tokens: [])
        XCTAssertEqual(criteria.text, ">abc")
        XCTAssertNil(criteria.minAmountMinorUnits)
        let trailing = SearchQuery.criteria(text: "rent >", tokens: [])
        XCTAssertEqual(trailing.text, "rent")
        XCTAssertNil(trailing.minAmountMinorUnits)
    }

    /// "<0": nothing has an absolute amount below zero, so the range is empty and matches nothing.
    func testLessThanZeroMatchesNothing() async throws {
        let criteria = SearchQuery.criteria(text: "<0", tokens: [])
        XCTAssertEqual(criteria.maxAmountMinorUnits, 0)
        XCTAssertEqual(criteria.minAmountMinorUnits, 1)
        let model = try await loadedModel(try demoDatabase())
        model.query = "<0"
        await model.settle()
        XCTAssertFalse(model.isBrowsing)
        XCTAssertEqual(model.results.matchCount, 0)
    }

    // MARK: Tokens

    func testTokensBecomeFilters() {
        let criteria = SearchQuery.criteria(text: "", tokens: [.uncategorised, .account(id: 3, name: "A"), .account(id: 7, name: "B"),
                                                              .period(.thisYear)])
        XCTAssertTrue(criteria.includesUncategorised)
        XCTAssertTrue(criteria.categoryIds.isEmpty)
        XCTAssertEqual(criteria.accountIds, [3, 7])
        XCTAssertEqual(criteria.date, .thisYear)
    }

    func testThePeriodsAreTransactionSearchsDateFilters() {
        XCTAssertEqual(SearchPeriod.thisMonth.filter, .thisMonth)
        XCTAssertEqual(SearchPeriod.thisYear.filter, .thisYear)
        XCTAssertEqual(SearchPeriod.last12Months.filter, .last12Months)
        XCTAssertEqual(SearchPeriod.allCases.map(\.title), ["This month", "This year", "Last 12 months"])
    }

    /// Suggestions: Uncategorised, the periods, then each account, without what's already chosen; one period at most.
    func testSuggestionsLeaveOutWhatIsChosen() {
        let accounts: [SearchToken] = [.account(id: 1, name: "Everyday"), .account(id: 2, name: "Saver")]
        let all = SearchQuery.suggestions(accounts: accounts, chosen: [])
        XCTAssertEqual(all, [.uncategorised, .period(.thisMonth), .period(.thisYear), .period(.last12Months)] + accounts)
        let some = SearchQuery.suggestions(accounts: accounts, chosen: [.uncategorised, .period(.thisYear), .account(id: 2, name: "Saver")])
        XCTAssertEqual(some, [.account(id: 1, name: "Everyday")])
    }

    /// Typing reaches the results only once the pause is over (a gate the test opens, no wall clock); clearing at once.
    func testTypingAppliesAfterAPause() async throws {
        let day = today
        let gate = PauseGate()
        let model = SearchViewModel(dbQueue: try demoDatabase(), today: { day }, queryDelay: .milliseconds(150),
                                    pause: { _ in await gate.wait() })
        await model.load()
        await model.settle()
        model.query = "streamflix"
        await gate.waitUntilWaiting()
        XCTAssertTrue(model.isBrowsing, "applied before the pause ended")
        await gate.open()
        await model.settle()
        XCTAssertFalse(model.isBrowsing)
        XCTAssertTrue(model.results.days.flatMap(\.rows).allSatisfy { $0.description == "STREAMFLIX" })
        model.query = ""
        await model.settle()
        XCTAssertTrue(model.isBrowsing)
    }

    /// A day listing an incoming transfer leg that its total leaves out says so.
    func testADayWithAnUncountedTransferLegSaysSo() {
        let out = row(2, day(14), -5_000)
        let inLegTransaction = Transaction(id: 3, importBatchId: 1, accountId: 2, date: day(14), rawDescription: "IN", amountMinorUnits: 5_000,
                                           categoryId: nil, status: .confirmed, categorizedBy: .none, fingerprint: "f3")
        let inLeg = TransactionSearch.Row(transaction: inLegTransaction, category: nil, categoryName: "", accountName: "B", currency: .gbp,
                                          isLinkedTransfer: true, outgoingTransactionId: 2)
        let once = SearchResults.make(rows: [inLeg, out], eurToGbpRate: 1, countsTransfersOnce: true, rowLimit: 100)
        XCTAssertTrue(once.days[0].listsUncountedTransfer)
        XCTAssertEqual(once.days[0].totals.netMinorUnits, -5_000)
        let byAccount = SearchResults.make(rows: [inLeg, out], eurToGbpRate: 1, countsTransfersOnce: false, rowLimit: 100)
        XCTAssertFalse(byAccount.days[0].listsUncountedTransfer)
        XCTAssertFalse(SearchResults.make(rows: [out], eurToGbpRate: 1, countsTransfersOnce: true, rowLimit: 100).days[0].listsUncountedTransfer)
        XCTAssertEqual(SearchCopy.transferNote, "Transfers between your accounts aren't counted in the total")
    }

    func testTokenTitles() {
        XCTAssertEqual(SearchToken.uncategorised.title, "Uncategorised")
        XCTAssertEqual(SearchToken.account(id: 1, name: "Everyday Current").title, "Everyday Current")
        XCTAssertEqual(SearchToken.period(.last12Months).title, "Last 12 months")
    }

    // MARK: Grouping

    private func row(_ id: Int64, _ day: Date, _ amount: Int, account: Int64 = 1) -> TransactionSearch.Row {
        let transaction = Transaction(id: id, importBatchId: 1, accountId: account, date: day, rawDescription: "ROW \(id)",
                                      amountMinorUnits: amount, categoryId: nil, status: .confirmed, categorizedBy: .none,
                                      fingerprint: "f\(id)")
        return TransactionSearch.Row(transaction: transaction, category: nil, categoryName: "", accountName: "A", currency: .gbp,
                                     isLinkedTransfer: false, outgoingTransactionId: nil)
    }

    private func day(_ d: Int) -> Date {
        MonthRange.calendar.date(from: DateComponents(year: 2026, month: 10, day: d))!
    }

    func testRowsGroupByDayWithEachDaysTotal() {
        let rows = [row(5, day(14), -1_000), row(4, day(14), 300), row(3, day(12), -250), row(2, day(10), -100), row(1, day(10), -50)]
        let results = SearchResults.make(rows: rows, eurToGbpRate: 1.2, countsTransfersOnce: true, rowLimit: 100)
        XCTAssertEqual(results.days.map(\.day), [day(14), day(12), day(10)])
        XCTAssertEqual(results.days.map { $0.rows.map(\.id) }, [[5, 4], [3], [2, 1]])
        XCTAssertEqual(results.days.map(\.totals.netMinorUnits), [-700, -250, -150])
        XCTAssertEqual(results.days[0].totals, TransactionSearch.totals(Array(rows[0...1]), eurToGbpRate: 1.2, countsTransfersOnce: true))
        XCTAssertEqual(results.matchCount, 5)
        XCTAssertEqual(results.shownCount, 5)
        XCTAssertFalse(results.isCapped)
    }

    /// Over the limit: whole days only (a day's total is always over all of its rows), stopping once the limit is met.
    func testTheLimitKeepsWholeDays() {
        let rows = [row(5, day(14), -1_000), row(4, day(14), 300), row(3, day(12), -250), row(2, day(10), -100), row(1, day(10), -50)]
        let results = SearchResults.make(rows: rows, eurToGbpRate: 1, countsTransfersOnce: true, rowLimit: 3)
        XCTAssertEqual(results.days.map(\.day), [day(14), day(12)])
        XCTAssertEqual(results.shownCount, 3)
        XCTAssertEqual(results.matchCount, 5)
        XCTAssertTrue(results.isCapped)
        // A first day bigger than the limit still shows whole.
        let big = SearchResults.make(rows: rows, eurToGbpRate: 1, countsTransfersOnce: true, rowLimit: 1)
        XCTAssertEqual(big.days.map(\.day), [day(14)])
        XCTAssertEqual(big.shownCount, 2)
    }

    // MARK: The tab on the demo

    func testNothingTypedShowsTheRecentDays() async throws {
        let queue = try demoDatabase()
        let model = try await loadedModel(queue)
        XCTAssertTrue(model.isBrowsing)
        let results = model.results
        XCTAssertFalse(results.days.isEmpty)
        XCTAssertGreaterThanOrEqual(results.shownCount, SearchViewModel.recentRowLimit)
        let latest = try await queue.read { db in try Transaction.order(Column("date").desc).fetchOne(db)?.date }
        XCTAssertEqual(results.days.first?.day, latest.map { MonthRange.calendar.startOfDay(for: $0) })
        XCTAssertTrue(results.isCapped)
    }

    func testUncategorisedTokenListsTheDemosFiveWaitingRows() async throws {
        let model = try await loadedModel(try demoDatabase())
        model.tokens = [.uncategorised]
        await model.settle()
        XCTAssertFalse(model.isBrowsing)
        let rows = model.results.days.flatMap(\.rows)
        XCTAssertEqual(rows.count, 5)
        XCTAssertTrue(rows.allSatisfy { $0.category == nil })
        XCTAssertTrue(rows.allSatisfy { TransactionRowPresentation($0).isUncategorised })
        XCTAssertEqual(TransactionRowPresentation(rows[0]).secondary, "Everyday Current · Uncategorised")
    }

    func testAnAmountBoundKeepsOnlyLargerAmounts() async throws {
        let model = try await loadedModel(try demoDatabase())
        model.query = ">100"
        await model.settle()
        model.tokens = [.period(.thisMonth)]
        await model.settle()
        let rows = model.results.days.flatMap(\.rows)
        XCTAssertFalse(rows.isEmpty)
        XCTAssertTrue(rows.allSatisfy { $0.amountMinorUnits.magnitude > 10_000 })
        let october = TransactionSearch.dateRange(.thisMonth, now: today)!
        XCTAssertTrue(rows.allSatisfy { october.contains($0.date) })
    }

    /// The field matches a category's name ("coffee" finds Coffee rows whatever their description).
    func testTheFieldMatchesTheCategory() async throws {
        let model = try await loadedModel(try demoDatabase())
        model.query = "streaming"
        await model.settle()
        let rows = model.results.days.flatMap(\.rows)
        XCTAssertFalse(rows.isEmpty)
        XCTAssertTrue(rows.allSatisfy { $0.categoryName == "Streaming" })
        XCTAssertTrue(rows.contains { $0.description == "STREAMFLIX" })
    }

    func testAnExactAmountFindsThatAmount() async throws {
        let model = try await loadedModel(try demoDatabase())
        model.query = "10.99"
        await model.settle()
        let rows = model.results.days.flatMap(\.rows)
        XCTAssertFalse(rows.isEmpty)
        XCTAssertTrue(rows.allSatisfy { $0.amountMinorUnits.magnitude == 1_099 })
    }

    func testNothingMatches() async throws {
        let model = try await loadedModel(try demoDatabase())
        model.query = "zzqx"
        await model.settle()
        XCTAssertTrue(model.results.days.isEmpty)
        XCTAssertEqual(model.results.matchCount, 0)
        XCTAssertEqual(SearchCopy.emptyTitle, "Nothing matches")
    }

    /// The route assertion: every day's total is `TransactionSearch.totals` over that day's matches, read afresh.
    func testDayTotalsCheckHoldsAndCatchesADifference() async throws {
        let queue = try demoDatabase()
        let model = try await loadedModel(queue)
        model.tokens = [.period(.thisMonth)]
        await model.settle()
        let check = try SearchViewModel.dayTotalsCheck(dbQueue: queue, today: today, criteria: model.criteria, shown: model.results)
        XCTAssertTrue(check.matches, check.line)
        var wrong = model.results
        let first = wrong.days[0]
        wrong.days[0] = SearchDay(day: first.day, rows: first.rows,
                                  totals: TransactionSearch.Totals(count: first.totals.count, inMinorUnits: first.totals.inMinorUnits + 1,
                                                                   outMinorUnits: first.totals.outMinorUnits))
        XCTAssertFalse(try SearchViewModel.dayTotalsCheck(dbQueue: queue, today: today, criteria: model.criteria, shown: wrong).matches)
    }

    func testAnEmptyDatabaseLoadsWithNoResults() async throws {
        let model = try await loadedModel(try emptyDatabase())
        XCTAssertTrue(model.results.days.isEmpty)
        XCTAssertEqual(model.suggestedTokens.first, .uncategorised)
    }

    func testSuggestionsListTheDemosAccounts() async throws {
        let model = try await loadedModel(try demoDatabase())
        XCTAssertTrue(model.suggestedTokens.contains { $0.title == "Everyday Current" })
        model.tokens = [.period(.thisMonth)]
        await model.settle()
        XCTAssertFalse(model.suggestedTokens.contains(.period(.thisYear)))
    }

    /// A reload after a sync keeps the query and tokens, and a detail open on a row the sync removed closes.
    func testReloadKeepsTheSearchAndDropsAVanishedDetail() async throws {
        let queue = try DatabaseQueue()
        try demoDatabase().backup(to: queue)
        let model = try await loadedModel(queue)
        model.tokens = [.uncategorised]
        await model.settle()
        let shown = model.results.days.flatMap(\.rows)
        model.detail = shown[0]
        try await queue.write { db in _ = try Transaction.deleteOne(db, key: shown[0].id) }
        await model.reload(for: Date())
        await model.settle()
        XCTAssertEqual(model.tokens, [.uncategorised])
        XCTAssertEqual(model.results.days.flatMap(\.rows).count, 4)
        XCTAssertNil(model.detail)
    }

    func testAReloadForTheSameSyncDoesNotReadAgain() async throws {
        let queue = try DatabaseQueue()
        try demoDatabase().backup(to: queue)
        let model = try await loadedModel(queue)
        let key = Date()
        await model.reload(for: key)
        await model.settle()
        model.tokens = [.uncategorised]
        await model.settle()
        try await queue.write { db in _ = try Transaction.filter(Column("categoryId") == nil).deleteAll(db) }
        await model.reload(for: key)
        await model.settle()
        XCTAssertEqual(model.results.days.flatMap(\.rows).count, 5)
    }

    // MARK: Rows and the detail

    func testARowsAmountRoleFollowsItsCategory() async throws {
        let model = try await loadedModel(try demoDatabase())
        model.query = "salary"
        await model.settle()
        let salary = try XCTUnwrap(model.results.days.first?.rows.first)
        let shown = TransactionRowPresentation(salary)
        XCTAssertEqual(shown.amount.role, .income)
        XCTAssertEqual(shown.amount.minorUnits, salary.amountMinorUnits)
        XCTAssertGreaterThan(shown.amount.minorUnits, 0)
        XCTAssertEqual(shown.secondary, "Everyday Current · Income")
        model.query = "streamflix"
        await model.settle()
        let spend = try XCTUnwrap(model.results.days.first?.rows.first)
        XCTAssertLessThan(TransactionRowPresentation(spend).amount.minorUnits, 0)
    }

    func testTheDetailShowsTheTransactionsFields() async throws {
        let model = try await loadedModel(try demoDatabase())
        model.query = "boiler"
        await model.settle()
        let repair = try XCTUnwrap(model.results.days.first?.rows.first)
        let detail = TransactionDetailPresentation(repair)
        XCTAssertEqual(detail.description, "BOILER REPAIR LDA")
        XCTAssertEqual(detail.account, "Euro Current")
        XCTAssertEqual(detail.category, "Repairs")
        XCTAssertEqual(detail.note, "Boiler pressure valve replaced")
        XCTAssertEqual(detail.currency, .eur)
        XCTAssertEqual(detail.amount.minorUnits, -32_000)
    }

    // MARK: Tabs

    /// A lock closes the transaction sheet's state too (the cover window dismisses it in UIKit, bypassing the binding),
    /// so after unlocking nothing re-presents and a row opens again.
    func testDismissingSheetsClearsTheOpenTransaction() async throws {
        let day = today
        let model = PhoneTabsModel(dbQueue: try demoDatabase(), today: { day }, hasProperty: true)
        await model.search.load()
        await model.search.settle()
        model.search.detail = model.search.results.days.first?.rows.first
        XCTAssertNotNil(model.search.detail)
        model.dismissSheets()
        XCTAssertNil(model.search.detail)
    }

    func testThePropertyTabNeedsAPropertyRow() async throws {
        let demo = try demoDatabase()
        let empty = try emptyDatabase()
        let demoHas = await PhoneTabsModel.hasProperty(demo)
        let emptyHas = await PhoneTabsModel.hasProperty(empty)
        XCTAssertEqual(demoHas, true)
        XCTAssertEqual(emptyHas, false)
        let day = today
        let model = PhoneTabsModel(dbQueue: empty, today: { day }, hasProperty: true)
        model.selection = .property
        await model.reload(for: Date())
        XCTAssertFalse(model.hasProperty)
        XCTAssertEqual(model.selection, .home)
    }
}

/// A pause the test ends: `wait()` suspends until `open()`.
private actor PauseGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var arrivals: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        for arrival in arrivals { arrival.resume() }
        arrivals.removeAll()
        await withCheckedContinuation { waiters.append($0) }
    }

    /// Returns once someone is waiting at the gate.
    func waitUntilWaiting() async {
        if !waiters.isEmpty { return }
        await withCheckedContinuation { arrivals.append($0) }
    }

    func open() {
        isOpen = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }
}
