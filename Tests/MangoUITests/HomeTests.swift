import XCTest
import GRDB
@testable import BudgetCore
import BudgetDemo
@testable import MangoUI

/// Home's view model and the rules its cards draw by (iPhone spec §3.2; plan step 4, Task 7). Figures come from
/// `HomeSummary`; these tests pin what Home does with them.
@MainActor
final class HomeTests: XCTestCase {
    private static func day(_ year: Int, _ month: Int, _ day: Int) -> Date {
        MonthRange.calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }

    private func emptyDatabase() throws -> DatabaseQueue {
        let manager = try DatabaseManager(path: nil)
        try manager.migrate()
        return manager.dbQueue
    }

    private func demoDatabase() throws -> DatabaseQueue {
        let queue = try emptyDatabase()
        let evidence = FileManager.default.temporaryDirectory.appendingPathComponent("HomeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: evidence) }
        try DemoDatabase.build(dbQueue: queue, evidenceRoot: evidence)
        return queue
    }

    // MARK: View model

    func testAnEmptyDatabaseIsTheEmptyState() async throws {
        let model = HomeViewModel(dbQueue: try emptyDatabase(), today: { Self.day(2026, 10, 15) })
        XCTAssertEqual(model.state, .idle)
        await model.load()
        XCTAssertEqual(model.state, .empty)
    }

    /// The figure Home shows is the Accounts screen's net worth on the same day (plan Task 7 step 2).
    func testTheDemoNetWorthIsTheAccountsOverviewsNetWorth() async throws {
        let queue = try demoDatabase()
        let today = DemoDatabase.defaultAsOf
        let model = HomeViewModel(dbQueue: queue, today: { today })
        await model.load()
        guard case let .loaded(summary) = model.state else { return XCTFail("not loaded: \(model.state)") }
        let netWorthGBP = try await queue.read { db in
            AccountsOverview.make(accounts: try Account.fetchAll(db), snapshots: try BalanceSnapshot.fetchAll(db),
                                  transactions: try Transaction.fetchAll(db), rate: try ExchangeRateSetting.currentOrDefault(db: db), today: today).netWorthGBP
        }
        XCTAssertEqual(summary.netWorth.currentNetWorthMinorUnits, netWorthGBP)
        XCTAssertEqual(try HomeViewModel.netWorthCheck(dbQueue: queue, today: today, shown: summary).matches, true)
    }

    func testAFailedReadKeepsTheLastSummary() async throws {
        let queue = try demoDatabase()
        let model = HomeViewModel(dbQueue: queue, today: { DemoDatabase.defaultAsOf })
        await model.load()
        guard case .loaded = model.state else { return XCTFail("not loaded") }
        try await queue.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA foreign_keys = OFF")
            try db.execute(sql: "DROP TABLE account")
        }
        await model.load()
        guard case .loaded = model.state else { return XCTFail("the summary was dropped: \(model.state)") }
        // A fixed sentence, never the database's own message.
        XCTAssertEqual(model.errorMessage, HomeViewModel.loadFailureMessage)
        XCTAssertFalse(model.errorMessage!.contains("SQL"))
    }

    func testAFirstReadThatFailsShowsTheFixedSentence() async throws {
        let queue = try emptyDatabase()
        try await queue.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA foreign_keys = OFF")
            try db.execute(sql: "DROP TABLE account")
        }
        let model = HomeViewModel(dbQueue: queue, today: { Self.day(2026, 10, 15) })
        await model.load()
        XCTAssertEqual(model.state, .failed(HomeViewModel.loadFailureMessage))
    }

    // MARK: Reloading after a sync

    func testTheReloadKeyIsTheLastSyncTime() {
        let t = Self.day(2026, 10, 15)
        XCTAssertEqual(HomeViewModel.reloadKey(.idle(lastSync: t)), t)
        XCTAssertEqual(HomeViewModel.reloadKey(.needsAttention(held: 1, lastSync: t)), t)
        XCTAssertNil(HomeViewModel.reloadKey(.syncing(.pulling)))
        XCTAssertNil(HomeViewModel.reloadKey(.offline(since: t, retryAt: nil)))
        XCTAssertNil(HomeViewModel.reloadKey(.idle(lastSync: nil)))
    }

    /// A sync that brings the first records in (empty → data) reloads Home; a sync in progress or the same sync
    /// again doesn't.
    func testHomeReloadsWhenANewSyncHasLanded() async throws {
        let queue = try emptyDatabase()
        let model = HomeViewModel(dbQueue: queue, today: { DemoDatabase.defaultAsOf })
        await model.reload(for: nil)
        XCTAssertEqual(model.state, .empty)

        let evidence = FileManager.default.temporaryDirectory.appendingPathComponent("HomeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: evidence) }
        try DemoDatabase.build(dbQueue: queue, evidenceRoot: evidence)

        await model.reload(for: nil)  // syncing: keeps what is shown
        XCTAssertEqual(model.state, .empty)
        let synced = Self.day(2026, 10, 15)
        await model.reload(for: synced)
        guard case .loaded = model.state else { return XCTFail("not reloaded: \(model.state)") }
    }

    func testTheSameSyncDoesNotReloadAgain() async throws {
        let queue = try emptyDatabase()
        let model = HomeViewModel(dbQueue: queue, today: { DemoDatabase.defaultAsOf })
        let synced = Self.day(2026, 10, 15)
        await model.reload(for: synced)
        XCTAssertEqual(model.state, .empty)
        let evidence = FileManager.default.temporaryDirectory.appendingPathComponent("HomeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: evidence) }
        try DemoDatabase.build(dbQueue: queue, evidenceRoot: evidence)
        await model.reload(for: synced)
        XCTAssertEqual(model.state, .empty)
    }

    // MARK: Freshness

    func testFreshnessNamesTheLastDayAndTurnsAmberPastFourteenDays() async throws {
        let queue = try demoDatabase()
        let model = HomeViewModel(dbQueue: queue, today: { DemoDatabase.defaultAsOf })
        await model.load()
        guard case let .loaded(fresh) = model.state else { return XCTFail() }
        XCTAssertFalse(fresh.isFreshnessAmber)
        XCTAssertTrue(HomeCopy.freshness(fresh).hasPrefix("Data through "), HomeCopy.freshness(fresh))
        XCTAssertFalse(HomeCopy.freshness(fresh).contains("days old"))

        let later = HomeViewModel(dbQueue: queue, today: { HomeRoutes.staleToday(from: DemoDatabase.defaultAsOf) })
        await later.load()
        guard case let .loaded(stale) = later.state else { return XCTFail() }
        XCTAssertTrue(stale.isFreshnessAmber)
        XCTAssertTrue(HomeCopy.freshness(stale).contains("\(stale.dataAgeDays!) days old"), HomeCopy.freshness(stale))
    }

    // MARK: This pay month

    func testDaysToPaydayReadsAsWords() {
        XCTAssertEqual(HomeCopy.daysToPayday(0), "today")
        XCTAssertEqual(HomeCopy.daysToPayday(1), "in 1 day")
        XCTAssertEqual(HomeCopy.daysToPayday(12), "in 12 days")
    }

    func testTheBarSplitsPlannedIntoSpentAndStillExpected() {
        let bar = PayMonthBar(spentMinorUnits: 30_000, stillExpectedMinorUnits: 50_000, plannedMinorUnits: 100_000)
        XCTAssertEqual(bar.spent, 0.3, accuracy: 0.0001)
        XCTAssertEqual(bar.stillExpected, 0.5, accuracy: 0.0001)
        // Over plan: the bar is all spent, nothing still expected.
        let over = PayMonthBar(spentMinorUnits: 150_000, stillExpectedMinorUnits: 0, plannedMinorUnits: 100_000)
        XCTAssertEqual(over.spent, 1)
        XCTAssertEqual(over.stillExpected, 0)
        // Nothing planned: no division by zero.
        let none = PayMonthBar(spentMinorUnits: 0, stillExpectedMinorUnits: 0, plannedMinorUnits: 0)
        XCTAssertEqual(none.spent, 0)
        XCTAssertEqual(none.stillExpected, 0)
        // Never more than the whole bar between the two.
        let tight = PayMonthBar(spentMinorUnits: 80_000, stillExpectedMinorUnits: 50_000, plannedMinorUnits: 100_000)
        XCTAssertEqual(tight.spent + tight.stillExpected, 1, accuracy: 0.0001)
    }

    // MARK: Needs attention

    func testAttentionListsCountsAndSyncProblemsOnly() {
        let now = Self.day(2026, 10, 15)
        let items = AttentionItems(uncategorizedCount: 3, staleBalanceCount: 2, oldestStaleSnapshotDate: Self.day(2026, 8, 1),
                                   missingReserveAllowance: false)
        let quiet = AttentionLine.lines(items, syncStatus: .idle(lastSync: now), now: now)
        XCTAssertEqual(quiet.map(\.label), ["Uncategorised transactions", "Balances out of date"])
        XCTAssertEqual(quiet.map(\.count), [3, 2])
        XCTAssertEqual(quiet[1].detail, "Oldest from 1 Aug 2026")

        let none = AttentionItems(uncategorizedCount: 0, staleBalanceCount: 0, oldestStaleSnapshotDate: nil, missingReserveAllowance: false)
        XCTAssertTrue(AttentionLine.lines(none, syncStatus: .off, now: now).isEmpty)
        XCTAssertTrue(AttentionLine.lines(none, syncStatus: .syncing(.pulling), now: now).isEmpty)

        let waiting = AttentionLine.lines(none, syncStatus: .waitingForKey(since: now), now: now)
        XCTAssertEqual(waiting.map(\.label), ["Waiting for the household key from iCloud Keychain"])
        XCTAssertEqual(waiting.first?.tone, .neutral)
        XCTAssertNil(waiting.first?.count)

        let offline = AttentionLine.lines(none, syncStatus: .offline(since: now, retryAt: nil), now: now)
        XCTAssertEqual(offline.first?.tone, .amber)
    }

    // MARK: Upcoming

    func testUpcomingShowsTheNextFiveAndNamesEachSource() {
        let date = Self.day(2026, 10, 20)
        func item(_ id: String, _ source: HomeSummary.UpcomingItem.Source, estimate: Bool = false) -> HomeSummary.UpcomingItem {
            HomeSummary.UpcomingItem(id: id, date: date, title: "Insurance", amountMinorUnits: 1_000, currency: .gbp, source: source, isEstimate: estimate)
        }
        let items = (1...7).map { item("bill/\($0)", .bill) }
        XCTAssertEqual(HomeCopy.nextUpcoming(items).map(\.id), ["bill/1", "bill/2", "bill/3", "bill/4", "bill/5"])
        XCTAssertEqual(HomeCopy.upcomingSource(item("bill/1", .bill)), "20 Oct 2026 · Planned bill")
        XCTAssertEqual(HomeCopy.upcomingSource(item("property/1/x", .propertyObligation)), "20 Oct 2026 · Property cost")
        XCTAssertEqual(HomeCopy.upcomingSource(item("property/1/x", .propertyObligation, estimate: true)), "20 Oct 2026 · Property cost, estimated")
    }

    /// The demo has something coming up for the Upcoming card to show.
    func testTheDemoHasUpcomingItems() async throws {
        let model = HomeViewModel(dbQueue: try demoDatabase(), today: { DemoDatabase.defaultAsOf })
        await model.load()
        guard case let .loaded(summary) = model.state else { return XCTFail() }
        XCTAssertFalse(summary.upcoming.isEmpty)
    }

    // MARK: Expense colour

    /// Expense figures stay legible in light mode as income does: at least 4.5:1 on a card; dark unchanged.
    func testLightExpenseReachesFourPointFiveToOneOnACardAndDarkIsUnchanged() {
        for palette in ThemePalette.all {
            let light = PhoneTheme.expenseToken(palette, .light)
            let card = PhoneTheme.opaqueSurface(palette, .light)
            XCTAssertGreaterThanOrEqual(ColorMath.contrastRatio(light, card), 4.5, palette.id)
            XCTAssertEqual(PhoneTheme.expenseToken(palette, .dark), palette.dark.expense, palette.id)
        }
        XCTAssertNotEqual(PhoneTheme.expenseToken(ThemePalette.named("classic"), .light), ThemePalette.named("classic").light.expense)
    }
}
