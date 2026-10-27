import XCTest
import SwiftUI
@testable import BudgetCore
@testable import MangoUI

/// In-memory notification center: counts what the app asks of it, schedules nothing for real.
private actor FakeCenter: NotificationCenterClient {
    var status: NotificationAuthorization
    /// id → words (`PlannedNotification.content`).
    var pending: [String: String] = [:]
    private(set) var requests = 0
    private(set) var adds = 0
    /// When set, reading what is pending waits until `resume()` (a refresh suspended mid-way).
    var holds = false
    private var gate: CheckedContinuation<Void, Never>?

    init(status: NotificationAuthorization) { self.status = status }

    var isHeld: Bool { gate != nil }
    func hold() { holds = true }
    func resume() {
        holds = false
        gate?.resume()
        gate = nil
    }

    func authorizationStatus() async -> NotificationAuthorization { status }
    func requestAuthorization() async -> Bool {
        requests += 1
        status = .granted
        return true
    }
    func pendingContent() async -> [String: String] {
        if holds { await withCheckedContinuation { gate = $0 } }
        return pending
    }
    func add(_ notification: PlannedNotification) async throws {
        adds += 1
        pending[notification.id] = notification.content
    }
    func remove(ids: [String]) async { for id in ids { pending[id] = nil } }
}

/// Step 7b Task 9: reminders scheduled from the plan, asked for only in Settings ▸ Notifications.
@MainActor
final class NotificationsSettingsTests: XCTestCase {
    private func ledger() throws -> (LedgerStore, () -> Void) {
        let suite = "NotificationsSettingsTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        return (LedgerStore(defaults: defaults), { defaults.removePersistentDomain(forName: suite) })
    }

    private func note(_ id: String, kind: NotificationKind = .billDue, link: PhoneTabLink = .home, body: String = "B") -> PlannedNotification {
        PlannedNotification(id: id, kind: kind, fireDate: Date(timeIntervalSince1970: 1_800_000_000), title: "T", body: body, link: link)
    }

    func testNoPermissionPromptAtLaunchOrRefresh() async throws {
        let (ledger, cleanup) = try ledger()
        defer { cleanup() }
        let center = FakeCenter(status: .notDetermined)
        await NotificationScheduler.refresh(plan: [note("a")], client: center, ledger: ledger)
        let requests = await center.requests
        XCTAssertEqual(requests, 0)
    }

    func testRefreshDoesNothingUnlessAuthorised() async throws {
        let (ledger, cleanup) = try ledger()
        defer { cleanup() }
        for status in [NotificationAuthorization.denied, .notDetermined] {
            let center = FakeCenter(status: status)
            await NotificationScheduler.refresh(plan: [note("a")], client: center, ledger: ledger)
            let adds = await center.adds
            XCTAssertEqual(adds, 0)
        }
        XCTAssertTrue(ledger.ids.isEmpty)
    }

    func testRefreshSchedulesPlannedAndRemovesStale() async throws {
        let (ledger, cleanup) = try ledger()
        defer { cleanup() }
        let center = FakeCenter(status: .granted)
        await center.add(ids: ["stale"])
        await NotificationScheduler.refresh(plan: [note("a"), note("b")], client: center, ledger: ledger)
        let pending = await center.pending
        XCTAssertEqual(Set(pending.keys), ["a", "b"])
        XCTAssertEqual(ledger.ids, ["a", "b"])
    }

    func testRefreshTwiceSchedulesOnce() async throws {
        let (ledger, cleanup) = try ledger()
        defer { cleanup() }
        let center = FakeCenter(status: .granted)
        let plan = [note("a"), note("b")]
        await NotificationScheduler.refresh(plan: plan, client: center, ledger: ledger)
        await NotificationScheduler.refresh(plan: plan, client: center, ledger: ledger)
        let adds = await center.adds
        XCTAssertEqual(adds, 2)
        // One that already fired (no longer pending) is not sent again.
        await center.remove(ids: ["a"])
        await NotificationScheduler.refresh(plan: plan, client: center, ledger: ledger)
        let again = await center.adds
        XCTAssertEqual(again, 2)
    }

    func testTogglingAKindOffRemovesItsPending() async throws {
        let (ledger, cleanup) = try ledger()
        defer { cleanup() }
        let center = FakeCenter(status: .granted)
        let plan = [note("bill", kind: .billDue), note("tax", kind: .taxDue)]
        await NotificationScheduler.refresh(plan: plan, client: center, ledger: ledger)
        var settings = PhoneOutputSettings()
        settings.notifications.remove(.billDue)
        // The planner leaves the kind out once its setting is off; the scheduler then removes what was pending.
        await NotificationScheduler.refresh(plan: plan.filter { settings.notifications.contains($0.kind) }, client: center, ledger: ledger)
        let pending = await center.pending
        XCTAssertEqual(Set(pending.keys), ["tax"])
    }

    func testFiguresTurnedOffReplacesPendingWithWordsWithoutTheAmount() async throws {
        let (ledger, cleanup) = try ledger()
        defer { cleanup() }
        let center = FakeCenter(status: .granted)
        await NotificationScheduler.refresh(plan: [note("bill", body: "Gas is due on 12 Nov 2026. £5.00")], client: center, ledger: ledger)
        // "Show figures on the lock screen" off: the planner's words drop the amount; the pending one is replaced.
        await NotificationScheduler.refresh(plan: [note("bill", body: "Gas is due on 12 Nov 2026.")], client: center, ledger: ledger)
        let pending = await center.pending
        XCTAssertEqual(pending, ["bill": "T\nGas is due on 12 Nov 2026."])
        let adds = await center.adds
        XCTAssertEqual(adds, 2)
    }

    func testClearIsNotUndoneByARefreshInFlight() async throws {
        let (ledger, cleanup) = try ledger()
        defer { cleanup() }
        let center = FakeCenter(status: .granted)
        let operations = NotificationOperations()
        var generation = 1
        let current = generation
        await center.hold()
        operations.enqueue {
            await NotificationScheduler.refresh(plan: [self.note("a")], client: center, ledger: ledger,
                                                isCurrent: { @MainActor in current == generation })
        }
        while await !center.isHeld { await Task.yield() }
        // Signed out while the refresh waits.
        generation += 1
        let cleared = operations.enqueue { await NotificationScheduler.clear(client: center) }
        await center.resume()
        await cleared.value
        let pending = await center.pending
        let adds = await center.adds
        XCTAssertTrue(pending.isEmpty)
        XCTAssertEqual(adds, 0)
    }

    func testAdminOnlyToggleHiddenForMember() {
        XCTAssertEqual(NotificationsSection.kinds(isAdmin: true), [.rentLate, .billDue, .taxDue, .noImport])
        XCTAssertEqual(NotificationsSection.kinds(isAdmin: false), [.rentLate, .billDue, .taxDue])
        XCTAssertEqual(NotificationsCopy.title(.noImport), "No statement imported")
        XCTAssertEqual(NotificationsCopy.title(.rentLate), "Rent not seen")
        XCTAssertEqual(NotificationsCopy.title(.billDue), "Bill due in 3 days")
        XCTAssertEqual(NotificationsCopy.title(.taxDue), "Tax payment due in 7 days")
    }

    func testSectionStatesFollowTheSystemSetting() {
        func section(_ access: NotificationAuthorization) -> NotificationsSection {
            NotificationsSection(settings: .constant(PhoneOutputSettings()), authorization: access, isAdmin: true, onAllow: {})
        }
        XCTAssertTrue(section(.notDetermined).showsAllowRow)
        XCTAssertFalse(section(.granted).showsAllowRow)
        XCTAssertTrue(section(.denied).showsDeniedNote)
        XCTAssertEqual(NotificationsCopy.denied, "Notifications are off for Mango in Settings.")
    }

    func testTapOpensMatchingTab() {
        for link in PhoneTabLink.allCases {
            XCTAssertEqual(NotificationScheduler.link(fromUserInfo: NotificationScheduler.userInfo(for: link)), link)
        }
        XCTAssertNil(NotificationScheduler.link(fromUserInfo: [:]))
        XCTAssertNil(NotificationScheduler.link(fromUserInfo: [NotificationScheduler.linkKey: "https://example.com"]))
    }
}

private extension FakeCenter {
    func add(ids: [String]) { for id in ids { pending[id] = "T\nB" } }
}
