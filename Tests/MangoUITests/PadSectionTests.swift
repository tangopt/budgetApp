import XCTest
import BudgetCore
@testable import MangoUI

/// The iPad sidebar's section map, footer and collapsed state (step 10, Task 3).
final class PadSectionTests: XCTestCase {
    func testPropertyGroupOrderAndTitles() {
        let groups = PadSection.groups(hasProperty: true)
        XCTAssertEqual(groups.map(\.title), [nil, "Property", "Everything else"])
        XCTAssertEqual(groups[0].sections, [.home, .month, .accounts, .search])
        XCTAssertEqual(groups[1].sections.map(\.title),
                       ["This month", "Bills & recharges", "Tenancies", "Money", "Calendar", "Checks", "Profile"])
    }

    func testEvidenceSitsUnderEverythingElseNotProperty() {
        let groups = PadSection.groups(hasProperty: true)
        XCTAssertEqual(groups[2].sections, [.evidence, .documents])
        XCTAssertEqual(groups[2].sections.map(\.title), ["Evidence", "Documents"])
        XCTAssertFalse(groups[1].sections.contains(.evidence))
        XCTAssertFalse(PadSection.evidence.requiresProperty)
    }

    func testNoPropertyHidesPropertyGroup() {
        let groups = PadSection.groups(hasProperty: false)
        XCTAssertEqual(groups.map(\.title), [nil, "Everything else"])
        XCTAssertTrue(groups.flatMap(\.sections).allSatisfy { !$0.requiresProperty })
        XCTAssertEqual(PadSection.allCases.filter(\.requiresProperty).count, 7)
    }

    func testEverySectionHasTitleAndSymbol() {
        XCTAssertEqual(Set(PadSection.allCases.map(\.title)).count, PadSection.allCases.count)
        for section in PadSection.allCases {
            XCTAssertFalse(section.title.isEmpty)
            XCTAssertFalse(section.systemImage.isEmpty)
        }
        let listed = PadSection.groups(hasProperty: true).flatMap(\.sections)
        XCTAssertEqual(Set(listed), Set(PadSection.allCases))
    }

    func testFooterShowsNoAccessLevel() {
        let now = Date()
        let texts = SidebarFooter.texts(userName: "Alex Example", sync: .synced(now.addingTimeInterval(-120)), waitingChanges: 0, now: now)
        XCTAssertEqual(texts.count, 2)
        XCTAssertEqual(texts[0], "Alex Example")
        XCTAssertEqual(texts[1], "Synced 2 min ago")
        for text in texts {
            XCTAssertFalse(text.localizedCaseInsensitiveContains("admin"))
            XCTAssertFalse(text.localizedCaseInsensitiveContains("member"))
        }
        XCTAssertEqual(SidebarFooter.initials("Alex Example"), "AE")
        XCTAssertEqual(SidebarFooter.initials(""), "?")
    }

    func testSyncLineCopy() {
        let now = Date()
        XCTAssertEqual(SidebarFooter.syncLine(.synced(now), waitingChanges: 3, now: now), "3 changes waiting")
        XCTAssertEqual(SidebarFooter.syncLine(.synced(now), waitingChanges: 1, now: now), "1 change waiting")
        XCTAssertEqual(SidebarFooter.syncLine(.synced(now.addingTimeInterval(-120)), waitingChanges: 0, now: now), "Synced 2 min ago")
        XCTAssertEqual(SidebarFooter.syncLine(.synced(nil), waitingChanges: 0, now: now), "Not synced yet")
        XCTAssertEqual(SidebarFooter.syncLine(nil, waitingChanges: 0, now: now), "Sync is off")
    }

    func testCollapsedStateAndPortraitPanelRule() {
        var state = PadSidebarState()
        XCTAssertEqual(state.width, 264)
        state.toggle()
        XCTAssertTrue(state.isCollapsed)
        XCTAssertEqual(state.width, 72)
        // 11" portrait with a document panel open collapses by itself; landscape, 13" and no panel do not.
        let open = PadSidebarState()
        XCTAssertTrue(open.effective(width: 834, height: 1194, panelOpen: true).isCollapsed)
        XCTAssertFalse(open.effective(width: 834, height: 1194, panelOpen: false).isCollapsed)
        XCTAssertFalse(open.effective(width: 1194, height: 834, panelOpen: true).isCollapsed)
        XCTAssertFalse(open.effective(width: 1032, height: 1376, panelOpen: true).isCollapsed)
        XCTAssertTrue(state.effective(width: 1194, height: 834, panelOpen: false).isCollapsed)
    }
}
