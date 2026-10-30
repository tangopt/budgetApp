import XCTest
import GRDB
@testable import BudgetCore
@testable import MangoUI

/// The phone's sync states (plan step 4 Task 12): what reloads a screen after a sync, the future-obligation money
/// role, Settings' copy and choices. Synthetic, in-memory databases only.
@MainActor
final class SyncStatesTests: XCTestCase {
    private let today = MonthRange.calendar.date(from: DateComponents(year: 2026, month: 10, day: 15))!
    private let synced = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: Reloading after a sync

    /// The trigger moves when a sync starts or ends, and with its last-sync time; it carries the reload key.
    func testTheReloadTriggerMovesWhenASyncStartsOrEnds() {
        let idle = SyncReloadTrigger(.idle(lastSync: synced))
        XCTAssertEqual(idle.key, synced)
        XCTAssertNotEqual(SyncReloadTrigger(.syncing(.pulling)), idle)
        XCTAssertNotEqual(SyncReloadTrigger(.syncing(.pulling)), SyncReloadTrigger(.offline(since: synced, retryAt: nil)))
        XCTAssertEqual(SyncReloadTrigger(.syncing(.pulling)), SyncReloadTrigger(.syncing(.pushing)))
        XCTAssertNil(SyncReloadTrigger(.waitingForKey(since: synced)).key)
    }

    /// An unmigrated database: every read fails until `migrate()`.
    private func brokenThenFixable() throws -> DatabaseManager {
        try DatabaseManager(path: nil)
    }

    /// A screen whose first load failed reads again on the next sync, even one that brings no new data in (offline,
    /// waiting for the key): a reload with a nil key retries it.
    func testAFailedFirstLoadRetriesOnTheNextSync() async throws {
        let manager = try brokenThenFixable()
        let home = HomeViewModel(dbQueue: manager.dbQueue, today: { self.today })
        let month = MonthViewModel(dbQueue: manager.dbQueue, today: { self.today })
        let accounts = AccountsViewModel(dbQueue: manager.dbQueue, today: { self.today })
        let property = PropertyViewModel(dbQueue: manager.dbQueue, today: { self.today })
        let search = SearchViewModel(dbQueue: manager.dbQueue, today: { self.today })

        await home.reload(for: nil)
        await month.reload(for: nil)
        await accounts.reload(for: nil)
        await property.reload(for: nil)
        await search.reload(for: nil)
        guard case .failed = home.state else { return XCTFail("home: \(home.state)") }
        guard case .failed = month.state else { return XCTFail("month: \(month.state)") }
        guard case .failed = accounts.state else { return XCTFail("accounts: \(accounts.state)") }
        guard case .failed = property.state else { return XCTFail("property: \(property.state)") }
        guard case .failed = search.state else { return XCTFail("search: \(search.state)") }

        try manager.migrate()
        await home.reload(for: nil)
        await month.reload(for: nil)
        await accounts.reload(for: nil)
        await property.reload(for: nil)
        await search.reload(for: nil)
        XCTAssertEqual(home.state, .empty)
        if case .failed = month.state { XCTFail("month not retried") }
        if case .failed = accounts.state { XCTFail("accounts not retried") }
        if case .failed = property.state { XCTFail("property not retried") }
        if case .failed = search.state { XCTFail("search not retried") }
    }

    /// One shared helper tells a failed state from the others, for every tab.
    func testIsFailedIsTheFailedCaseOnly() {
        XCTAssertTrue(HomeViewModel.State.failed("x").isFailed)
        XCTAssertFalse(HomeViewModel.State.idle.isFailed)
        XCTAssertFalse(HomeViewModel.State.empty.isFailed)
        XCTAssertTrue(MonthViewModel.State.failed("x").isFailed)
        XCTAssertFalse(MonthViewModel.State.idle.isFailed)
        XCTAssertTrue(AccountsViewModel.State.failed("x").isFailed)
        XCTAssertTrue(PropertyViewModel.State.failed("x").isFailed)
        XCTAssertTrue(SearchViewModel.State.failed("x").isFailed)
        XCTAssertFalse(SearchViewModel.State.idle.isFailed)
    }

    // MARK: Money due

    /// A future obligation (Upcoming, the next instalment, Coming up) is drawn as a cost and read as "due", never
    /// "spent".
    func testAnObligationIsDueNotSpent() {
        let due = MoneyPresentation(minorUnits: 70_000, currency: .eur, role: .due)
        XCTAssertEqual(due.text, "\u{2212}€700.00")
        XCTAssertEqual(due.tone, .expense)
        XCTAssertEqual(due.spoken, "due €700.00")
        let credit = MoneyPresentation(minorUnits: -1_500, currency: .gbp, role: .due)
        XCTAssertEqual(credit.tone, .income)
        XCTAssertEqual(credit.spoken, "due back £15.00")
    }

    // MARK: Settings

    func testICloudAccountLines() {
        XCTAssertEqual(SettingsCopy.iCloudAccount(.available), "Signed in")
        XCTAssertEqual(SettingsCopy.iCloudAccount(.noAccount), "Not signed in")
        XCTAssertEqual(SettingsCopy.iCloudAccount(.restricted), "Restricted on this iPhone")
        XCTAssertEqual(SettingsCopy.iCloudAccount(.couldNotDetermine), "Couldn't check just now")
        XCTAssertEqual(SettingsCopy.iCloudAccount(.unknown), "Not checked")
        XCTAssertTrue(ICloudAccountState.noAccount.isUnavailable)
        XCTAssertTrue(ICloudAccountState.restricted.isUnavailable)
        XCTAssertFalse(ICloudAccountState.couldNotDetermine.isUnavailable, "a passing doubt never blocks the data")
        XCTAssertFalse(ICloudAccountState.unknown.isUnavailable)
    }

    func testAppearanceChoices() {
        XCTAssertEqual(PhoneAppearance.allCases.map(\.title), ["System", "Light", "Dark"])
        XCTAssertNil(PhoneAppearance.system.colorScheme)
        XCTAssertEqual(PhoneAppearance.light.colorScheme, .light)
        XCTAssertEqual(PhoneAppearance.dark.colorScheme, .dark)
        XCTAssertEqual(PhoneAppearance(storedValue: "nonsense"), .system)
        XCTAssertEqual(PhoneTheme.named("nonsense").id, PhoneTheme.mango.id)
        XCTAssertEqual(PhoneTheme.named(PhoneTheme.all.last!.id).id, PhoneTheme.all.last!.id)
    }

    /// The version line reads "0.2.0 (1)".
    func testVersionLine() {
        XCTAssertEqual(SettingsCopy.version(marketing: "0.2.0", build: "1"), "0.2.0 (1)")
        XCTAssertEqual(SettingsCopy.version(marketing: nil, build: nil), "Unknown")
    }
}
