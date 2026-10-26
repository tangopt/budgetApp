import Combine
import XCTest
import GRDB
@testable import BudgetCore
@testable import MangoUI
import TestSupport

/// The admin's own iPhone after its first sync (TestFlight build 751: Settings ▸ Sharing kept saying "Mango doesn't
/// know whose iPhone this is yet"). The app launches locked, and the lock keeps the content out of the view tree, so
/// this iPhone's iCloud user's record name, read while locked, was already there when the content appeared: a view's
/// `onChange` never saw it change and the tabs kept the unnamed viewer. The tabs model (above the lock) follows the
/// name itself, the value already read included.
@MainActor
final class PhoneViewerTests: XCTestCase {
    /// The admin's iPhone: the household pulled with its engine's first viewer (`.none`, household only).
    private func adminPhoneAfterHouseholdPull() async throws -> TwoPersonHousehold {
        let h = try TwoPersonHousehold.make()
        let engine = SyncEngineCore(db: h.adminPhone.db, transport: h.audit, device: SyncDevice(id: "admin-iphone", name: "iPhone"),
                                    keyStore: h.adminKeys, readOnly: true, viewer: .none)
        try await h.adminMac.engine.pushPending()
        _ = try await engine.pull()
        return h
    }

    func testTheHouseholdPullNamesTheAdminsICloudUser() async throws {
        let h = try await adminPhoneAfterHouseholdPull()
        let recordName = TwoPersonHousehold.adminICloudUser
        try await h.adminPhone.db.read { db in
            XCTAssertEqual(try SharingViewer.forCloudKitUser(recordName: recordName, db: db).personId, h.fixture.personA)
            XCTAssertEqual(try SyncViewer.forCloudKitUser(recordName: recordName, db: db), SyncViewer(personUuid: h.fixture.personAUuid))
            guard case .loaded(let overview) = try SharingSectionState.read(db, viewer: .iCloudUser(recordName: recordName)) else {
                return XCTFail("named once the household is here")
            }
            XCTAssertTrue(overview.isAdmin)
            XCTAssertTrue(overview.isConfirmed)
            XCTAssertFalse(overview.own.isEmpty)
        }
    }

    /// The record name was read before the tabs follow it (while the app was locked): it still applies.
    func testANameReadBeforeFollowingApplies() async throws {
        let h = try await adminPhoneAfterHouseholdPull()
        let db = h.adminPhone.db
        let tabs = PhoneTabsModel(dbQueue: db, today: { Date() }, hasProperty: true, viewer: .iCloudUser(recordName: nil))
        let unnamed = tabs.viewer
        let before = try await db.read { db in try SharingSectionState.read(db, viewer: unnamed) }
        XCTAssertEqual(before, .notNamed)

        let names = CurrentValueSubject<String?, Never>(TwoPersonHousehold.adminICloudUser)
        tabs.follow(recordNames: names)
        XCTAssertEqual(tabs.viewer, .iCloudUser(recordName: TwoPersonHousehold.adminICloudUser))
        XCTAssertEqual(tabs.home.viewer, tabs.viewer)
        XCTAssertEqual(tabs.month.viewer, tabs.viewer)
        XCTAssertEqual(tabs.accounts.viewer, tabs.viewer)
        let named = tabs.viewer
        guard case .loaded(let overview) = try await db.read({ db in try SharingSectionState.read(db, viewer: named) }) else {
            return XCTFail("Settings ▸ Sharing shows the admin's accounts")
        }
        XCTAssertTrue(overview.isAdmin)

        // A later change (another iCloud user) is followed too.
        names.send(nil)
        XCTAssertEqual(tabs.viewer, .iCloudUser(recordName: nil))
        names.send(TwoPersonHousehold.adminICloudUser)
        XCTAssertEqual(tabs.viewer, .iCloudUser(recordName: TwoPersonHousehold.adminICloudUser))
    }
}
