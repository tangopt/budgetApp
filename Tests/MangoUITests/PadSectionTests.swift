import XCTest
import GRDB
@testable import BudgetCore
@testable import MangoUI
import TestSupport

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
        XCTAssertEqual(groups[2].sections, [.salary, .evidence, .documents])
        XCTAssertEqual(groups[2].sections.map(\.title), ["Salary calculator", "Evidence", "Documents"])
        XCTAssertFalse(groups[1].sections.contains(.evidence))
        XCTAssertFalse(PadSection.evidence.requiresProperty)
    }

    func testSalaryIsInEverythingElseGroup() {
        for hasProperty in [true, false] {
            XCTAssertTrue(PadSection.groups(hasProperty: hasProperty).last?.sections.contains(.salary) ?? false)
        }
        XCTAssertEqual(PadSection.salary.systemImage, "percent")
    }

    func testSalaryNotAPropertySection() {
        XCTAssertFalse(PadSection.salary.requiresProperty)
    }

    func testNoPropertyHidesPropertyGroup() {
        let groups = PadSection.groups(hasProperty: false)
        XCTAssertEqual(groups.map(\.title), [nil, "Everything else"])
        XCTAssertTrue(groups.flatMap(\.sections).allSatisfy { !$0.requiresProperty })
        XCTAssertEqual(PadSection.allCases.filter(\.requiresProperty).count, 7)
    }

    /// A member with Property None sees no Property section (None hides the area), as before she is known; View shows them.
    @MainActor
    func testMemberWithoutPropertyViewHasNoPropertySections() async throws {
        let db = try TestDatabase.migrated()
        let user = try await db.write { db -> Int64 in
            var property = Property(name: "Synthetic flat", country: "PT", currency: .eur)
            try Properties.save(db: db, &property)
            var person = Person(name: "Person B", shortName: "B")
            try People.save(db: db, &person)
            var user = AppUser(personId: person.id!, displayName: "B", cloudKitUserRecordName: "_member", isAdmin: false, createdAt: Date())
            try user.insert(db)
            _ = try SyncRecordStore.uuid(for: "appUser", localId: user.id!, db: db)
            try MemberPermissions.ensureDefaults(appUserId: user.id!, db: db)
            return user.id!
        }
        func level(_ level: PermissionLevel) async throws {
            try await db.write { db in
                try db.execute(sql: "UPDATE memberPermission SET level = ? WHERE appUserId = ? AND area = ?",
                               arguments: [level.rawValue, user, AccessArea.property.storageKey])
            }
        }
        func tabs(_ viewer: PhoneViewer) async -> PhoneTabsModel {
            let writer = DeviceWriter(db: db, viewer: { viewer }, afterWrite: {})
            let tabs = PhoneTabsModel(dbQueue: db, today: { Date() }, hasProperty: true, viewer: viewer, writer: writer)
            await tabs.refreshPropertyAccess()
            return tabs
        }
        try await level(.none)
        let member = await tabs(.iCloudUser(recordName: "_member"))
        XCTAssertFalse(member.showsPropertySections)
        XCTAssertEqual(PadSection.groups(hasProperty: member.showsPropertySections).map(\.title), [nil, "Everything else"])
        let unknown = await tabs(.iCloudUser(recordName: nil))
        XCTAssertFalse(unknown.showsPropertySections)
        try await level(.view)
        let viewing = await tabs(.iCloudUser(recordName: "_member"))
        XCTAssertTrue(viewing.showsPropertySections)
        XCTAssertEqual(PadSection.groups(hasProperty: viewing.showsPropertySections).map(\.title), [nil, "Property", "Everything else"])
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
