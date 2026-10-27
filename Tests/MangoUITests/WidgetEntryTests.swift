import XCTest
@testable import MangoUI
import BudgetCore
import TestSupport

/// Step 7b Task 7: the widgets' words and redaction rule. Synthetic figures only.
final class WidgetEntryTests: XCTestCase {
    private static func day(_ y: Int, _ m: Int, _ d: Int) -> Date {
        MonthRange.calendar.date(from: DateComponents(year: y, month: m, day: d))!
    }

    private func sample(net: Int? = 1_234_500, lockScreen: Bool = false) -> WidgetSnapshot {
        WidgetSnapshot(generatedAt: Self.day(2026, 10, 15), netWorthMinorUnits: net, leftToSpendMinorUnits: 45_600,
                       paydayDate: Self.day(2026, 10, 24), showFiguresOnLockScreen: lockScreen)
    }

    func testNetWorthTextMatchesHomeFormat() {
        let s = sample()
        XCTAssertEqual(WidgetPresentation.netWorthText(s), Money.format(1_234_500, currency: .gbp))
        XCTAssertEqual(WidgetPresentation.netWorthText(s), "£12,345.00")
        XCTAssertEqual(WidgetPresentation.leftText(s), "£456.00")
        XCTAssertEqual(WidgetPresentation.netWorthText(sample(net: nil)), "—")
    }

    func testPaydayTextSingularToday() {
        let s = sample()
        XCTAssertEqual(WidgetPresentation.paydayText(s, on: Self.day(2026, 10, 12)), "12 days")
        XCTAssertEqual(WidgetPresentation.paydayText(s, on: Self.day(2026, 10, 23)), "1 day")
        XCTAssertEqual(WidgetPresentation.paydayText(s, on: Self.day(2026, 10, 24)), "Today")
        XCTAssertEqual(WidgetPresentation.paydayText(s, on: Self.day(2026, 10, 28)), "Today")
    }

    func testRedactedByDefaultOnLockScreen() {
        let s = sample()
        XCTAssertTrue(WidgetPresentation.isRedacted(s, isLockScreen: true))
        XCTAssertTrue(WidgetPresentation.isRedacted(s, isLockScreen: false))
    }

    func testSettingOnLiftsRedaction() {
        let s = sample(lockScreen: true)
        XCTAssertFalse(WidgetPresentation.isRedacted(s, isLockScreen: true))
        XCTAssertTrue(WidgetPresentation.isRedacted(s, isLockScreen: false), "home screen widgets stay sensitive")
    }

    func testNoSnapshotShowsEmptyText() {
        XCTAssertEqual(WidgetPresentation.emptyText, "Open Mango to set up")
        XCTAssertEqual(WidgetPresentation.text(nil, WidgetPresentation.netWorthText), "Open Mango to set up")
        XCTAssertEqual(WidgetPresentation.text(sample(), WidgetPresentation.leftText), "£456.00")
    }

    func testNegativeNetWorthFormats() {
        let text = WidgetPresentation.netWorthText(sample(net: -1_234_500))
        XCTAssertEqual(text, "-£12,345.00")
        XCTAssertFalse(text.contains(" "))
    }

    // MARK: Widget links (iPad)

    func testLinkMapsToPadSection() {
        XCTAssertEqual(PadSection(link: .home), .home)
        XCTAssertEqual(PadSection(link: .month), .month)
    }

    @MainActor
    func testAQuickEditRefreshesTheOutputsOnceTheScreensReadAgain() async throws {
        let tabs = PhoneTabsModel(dbQueue: try TestDatabase.migrated(), today: { Date() }, hasProperty: false, viewer: .iCloudUser(recordName: nil))
        var refreshed = 0
        tabs.afterEdit = { refreshed += 1 }
        await tabs.quickEdit.onChange?()
        XCTAssertEqual(refreshed, 1)
    }

    @MainActor
    func testOpeningALinkSelectsTheTabAndLeavesAPendingLinkForTheSidebar() throws {
        let tabs = PhoneTabsModel(dbQueue: try TestDatabase.migrated(), today: { Date() }, hasProperty: false, viewer: .iCloudUser(recordName: nil))
        XCTAssertNil(tabs.pendingLink)
        tabs.open(.month)
        XCTAssertEqual(tabs.selection, .month)
        XCTAssertEqual(tabs.pendingLink, .month)
        tabs.consumePendingLink()
        XCTAssertNil(tabs.pendingLink)
        tabs.open(.home)
        XCTAssertEqual(tabs.selection, .home)
    }
}
