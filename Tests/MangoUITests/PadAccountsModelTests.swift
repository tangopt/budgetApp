import XCTest
import GRDB
@testable import BudgetCore
@testable import MangoUI
import TestSupport

/// Step 11 Task 2: which actions the iPad's Accounts screen offers on each account. Both people's writers over the
/// admin's database (`TwoPersonHousehold` with `SharingFixture`). Synthetic data only.
@MainActor
final class PadAccountsModelTests: XCTestCase {
    private var h: TwoPersonHousehold!
    private var queue: DatabaseQueue { h.adminMac.db }
    private var f: SharingFixture { h.fixture }

    override func setUpWithError() throws {
        h = try TwoPersonHousehold.make()
    }

    private func writer(_ recordName: String) -> DeviceWriter {
        DeviceWriter(db: queue, viewer: { .iCloudUser(recordName: recordName) }, afterWrite: {})
    }

    private func model(as recordName: String?, area: AccessArea = .budgetAndAccounts) -> PadAccountsModel {
        let viewer: PhoneViewer = recordName.map { .iCloudUser(recordName: $0) } ?? .demoAdmin
        let write = PadWriteModel(writer: recordName.map(writer), area: area)
        let accounts = AccountsViewModel(dbQueue: queue, today: { Date() }, viewer: viewer)
        return PadAccountsModel(accounts: accounts, write: write, dbQueue: queue)
    }

    private func setMemberLevel(_ level: PermissionLevel) throws {
        let personB = f.personB
        try queue.write { db in
            let member = try Int64.fetchOne(db, sql: "SELECT id FROM appUser WHERE personId = ?", arguments: [personB])!
            try db.execute(sql: "DELETE FROM memberPermission WHERE appUserId = ? AND area = ?",
                           arguments: [member, AccessArea.budgetAndAccounts.storageKey])
            var row = MemberPermission(appUserId: member, area: AccessArea.budgetAndAccounts.storageKey, level: level)
            try row.insert(db)
        }
    }

    private func hide(_ id: Int64) throws {
        try queue.write { db in try db.execute(sql: "UPDATE account SET sharingLevel = 'hidden' WHERE id = ?", arguments: [id]) }
    }

    private func makeManual(_ id: Int64) throws {
        try queue.write { db in try db.execute(sql: "UPDATE account SET trackingMode = 'manual' WHERE id = ?", arguments: [id]) }
    }

    private func memberAccount() async throws -> Int64 {
        let day = UKTaxYear.utcCalendar.date(from: DateComponents(year: 2026, month: 10, day: 1))!
        return try await PadAccountEdits.add(writer: writer(TwoPersonHousehold.memberICloudUser), name: "Test Current", currency: .gbp, kind: .cash,
                                             manual: true, openingBalanceEntered: nil, asOf: day, details: AccountDetails(),
                                             includeInNetWorth: true, joint: false)
    }

    func testOtherPersonsAccountOffersNoActions() async throws {
        try setMemberLevel(.edit)
        try makeManual(f.privateAccount)
        let member = model(as: TwoPersonHousehold.memberICloudUser)
        let balanceOnly = await member.actions(for: f.privateAccount)
        let totals = await member.actions(for: f.totals)
        XCTAssertTrue(balanceOnly.isEmpty, "the admin's Balance-only account")
        XCTAssertTrue(totals.isEmpty, "the admin's Category-totals account")
    }

    func testNoEditControlsWithoutEdit() async throws {
        try setMemberLevel(.edit)
        let own = try await memberAccount()
        try setMemberLevel(.view)
        for subject in [model(as: TwoPersonHousehold.memberICloudUser), model(as: nil)] {
            let actions = await subject.actions(for: own)
            XCTAssertTrue(actions.isDisjoint(with: [.addAccount, .editDetails, .setSharing, .updateBalance, .fetchStatement]))
            let canAdd = await subject.canAdd()
            XCTAssertFalse(canAdd)
        }
    }

    func testSharingOnlyOnOwnAccount() async throws {
        try setMemberLevel(.edit)
        let own = try await memberAccount()
        let member = model(as: TwoPersonHousehold.memberICloudUser)
        let ownActions = await member.actions(for: own)
        let jointActions = await member.actions(for: f.joint)
        let adminsActions = await member.actions(for: f.shared)
        XCTAssertTrue(ownActions.contains(.setSharing))
        XCTAssertFalse(jointActions.contains(.setSharing), "joint: nobody's to set")
        XCTAssertFalse(adminsActions.contains(.setSharing), "the admin's")
        XCTAssertTrue(jointActions.contains(.editDetails), "a joint account is seen in full")
    }

    func testUpdateBalanceOnlyOnManualAccount() async throws {
        try setMemberLevel(.edit)
        let own = try await memberAccount()
        try makeManual(f.joint)
        let member = model(as: TwoPersonHousehold.memberICloudUser)
        for id in [own, f.joint, f.shared] {
            let offered = await member.actions(for: id).contains(.updateBalance)
            let expected = await PhoneQuickEdits.canUpdateBalance(accountId: id, writer: writer(TwoPersonHousehold.memberICloudUser), dbReader: queue)
            XCTAssertEqual(offered, expected)
        }
        let ownOffered = await member.actions(for: own).contains(.updateBalance)
        let sharedOffered = await member.actions(for: f.shared).contains(.updateBalance)
        XCTAssertTrue(ownOffered)
        XCTAssertFalse(sharedOffered, "updated from statements")
    }

    func testFetchStatementNeedsTheBrowser() async throws {
        try setMemberLevel(.edit)
        let own = try await memberAccount()
        let member = model(as: TwoPersonHousehold.memberICloudUser)
        let withBrowser = await member.actions(for: own).contains(.fetchStatement)
        member.offersBrowser = false
        let without = await member.actions(for: own).contains(.fetchStatement)
        XCTAssertTrue(withBrowser)
        XCTAssertFalse(without)
    }

    func testListHidesWhatViewerCannotSee() async throws {
        try hide(f.privateAccount)
        let member = model(as: TwoPersonHousehold.memberICloudUser)
        await member.accounts.load()
        let ids = Set((member.accounts.state.page?.sections ?? []).flatMap(\.rows).map(\.id))
        XCTAssertFalse(ids.contains(f.privateAccount))
        XCTAssertTrue(ids.contains(f.shared))
    }

    func testDetailsHiddenForAccountNotSeenInFull() async throws {
        try setMemberLevel(.edit)
        let own = try await memberAccount()
        let (privateId, totalsId) = (f.privateAccount, f.totals)
        try await queue.write { db in
            try db.execute(sql: "UPDATE account SET bankName = 'Example Bank', accountNumber = '12345678' WHERE id IN (?, ?)",
                           arguments: [privateId, totalsId])
        }
        let member = model(as: TwoPersonHousehold.memberICloudUser)
        let ownShown = await member.showsDetails(for: own)
        let jointShown = await member.showsDetails(for: f.joint)
        let balanceOnlyShown = await member.showsDetails(for: f.privateAccount)
        let totalsShown = await member.showsDetails(for: f.totals)
        XCTAssertTrue(ownShown)
        XCTAssertTrue(jointShown)
        XCTAssertFalse(balanceOnlyShown, "the admin's Balance-only account: no bank or number")
        XCTAssertFalse(totalsShown, "the admin's Category-totals account: no bank or number")
        // A device whose user isn't named yet: no details on any account, joint ones included.
        let stranger = model(as: "test-nobody")
        for id in [own, f.joint, f.shared, f.privateAccount] {
            let shown = await stranger.showsDetails(for: id)
            XCTAssertFalse(shown)
        }
        // Demo data (its admin): her own accounts in full.
        let demo = model(as: nil)
        let demoShown = await demo.showsDetails(for: f.privateAccount)
        XCTAssertTrue(demoShown)
    }

    func testBankSiteMatchesTheBanksHost() {
        func site(_ name: String, _ host: String) -> SavedSite { SavedSite(name: name, url: URL(string: "https://\(host)")!, kind: .bank, sortOrder: 0) }
        let sites = [site("Example Water", "water.example.test"), site("Example Bank", "bank.example.test")]
        XCTAssertEqual(PadAccountsModel.bankSite(in: sites, bankName: "Example Bank")?.name, "Example Bank")
        XCTAssertEqual(PadAccountsModel.bankSite(in: sites, bankName: "bank")?.name, "Example Bank")
        XCTAssertNil(PadAccountsModel.bankSite(in: sites, bankName: "Other Bank"))
        XCTAssertNil(PadAccountsModel.bankSite(in: sites, bankName: nil))
    }
}
