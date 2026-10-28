import XCTest
import GRDB
@testable import BudgetCore
@testable import MangoUI
import TestSupport

/// Step 11 Task 3: the iPad's Add account and Edit details forms. Both people's writers over the admin's database
/// (`TwoPersonHousehold` with `SharingFixture`). Synthetic data only.
@MainActor
final class PadAccountFormModelTests: XCTestCase {
    private var h: TwoPersonHousehold!
    private var queue: DatabaseQueue { h.adminMac.db }
    private var f: SharingFixture { h.fixture }

    override func setUpWithError() throws {
        h = try TwoPersonHousehold.make()
        let personB = f.personB
        try queue.write { db in
            let member = try Int64.fetchOne(db, sql: "SELECT id FROM appUser WHERE personId = ?", arguments: [personB])!
            try db.execute(sql: "DELETE FROM memberPermission WHERE appUserId = ? AND area = ?",
                           arguments: [member, AccessArea.budgetAndAccounts.storageKey])
            var row = MemberPermission(appUserId: member, area: AccessArea.budgetAndAccounts.storageKey, level: .edit)
            try row.insert(db)
        }
    }

    private func writer(_ recordName: String) -> DeviceWriter {
        DeviceWriter(db: queue, viewer: { .iCloudUser(recordName: recordName) }, afterWrite: {})
    }

    private func write(as recordName: String) async -> PadWriteModel {
        let model = PadWriteModel(writer: writer(recordName), area: .budgetAndAccounts)
        await model.refresh()
        return model
    }

    private func form(_ mode: PadAccountFormModel.Mode, as recordName: String) async -> PadAccountFormModel {
        let form = PadAccountFormModel(mode: mode, write: await write(as: recordName), dbQueue: queue)
        await form.load()
        return form
    }

    private func account(_ id: Int64) throws -> Account {
        try XCTUnwrap(try queue.read { db in try Account.fetchOne(db, key: id) })
    }

    private func accountCount() throws -> Int { try queue.read { db in try Account.fetchCount(db) } }

    private func memberAccount(name: String = "Test Current") async throws -> Int64 {
        try await PadAccountEdits.add(writer: writer(TwoPersonHousehold.memberICloudUser), name: name, currency: .gbp, kind: .cash,
                                      manual: true, openingBalanceEntered: nil, asOf: Date(), details: AccountDetails(),
                                      includeInNetWorth: true, joint: false)
    }

    private func snapshot(_ id: Int64) throws -> Account { try account(id) }

    func testCancelWritesNothing() async throws {
        let id = try await memberAccount()
        let before = try account(id)
        let count = try accountCount()
        let edit = await form(.edit(before), as: TwoPersonHousehold.memberICloudUser)
        edit.name = "Test Renamed"
        edit.setSharingJoint(false)
        edit.sharingLevel = .categoryTotals
        edit.includeInNetWorth = false
        let add = await form(.add, as: TwoPersonHousehold.memberICloudUser)
        add.name = "Test New"
        // No save(): the sheet is cancelled or dismissed.
        XCTAssertEqual(try account(id), before)
        XCTAssertEqual(try accountCount(), count)
    }

    func testInvalidBankDetailsBlockSave() async throws {
        let add = await form(.add, as: TwoPersonHousehold.memberICloudUser)
        add.name = "Test Current"
        XCTAssertTrue(add.canSave)
        add.details.sortCode = "12-34"
        XCTAssertFalse(add.canSave)
        XCTAssertEqual(add.detailError(.sortCode), AccountDetailsError.invalidSortCode.errorDescription)
        let count = try accountCount()
        let saved = await add.save()
        XCTAssertFalse(saved)
        XCTAssertEqual(try accountCount(), count)
        XCTAssertTrue(add.revealErrors)
        add.details.sortCode = "12-34-56"
        XCTAssertTrue(add.canSave)
    }

    func testCreditKindLockedWithHistory() async throws {
        let id = try await memberAccount()
        try await queue.write { db in
            try BalanceUpdates.upsertSnapshot(db: db, accountId: id, date: Date(), balanceMinorUnits: 100, note: nil)
        }
        let withHistory = await form(.edit(try account(id)), as: TwoPersonHousehold.memberICloudUser)
        XCTAssertEqual(withHistory.kindChoices, [.cash, .investment])
        let plain = try await memberAccount(name: "Test Empty")
        let fresh = await form(.edit(try account(plain)), as: TwoPersonHousehold.memberICloudUser)
        XCTAssertEqual(fresh.kindChoices, [.cash, .investment, .credit])
        let add = await form(.add, as: TwoPersonHousehold.memberICloudUser)
        XCTAssertEqual(add.kindChoices, [.cash, .investment, .credit])
    }

    func testDuplicateNameRefused() async throws {
        let count = try accountCount()
        let add = await form(.add, as: TwoPersonHousehold.memberICloudUser)
        add.name = "  synthetic SHARED "
        XCTAssertEqual(add.nameError, "An account with that name already exists.")
        XCTAssertFalse(add.canSave)
        let saved = await add.save()
        XCTAssertFalse(saved)
        XCTAssertEqual(try accountCount(), count)

        // A stale list: the writer refuses it too, whole, with the form's copy.
        let stale = PadAccountFormModel(mode: .add, write: await write(as: TwoPersonHousehold.memberICloudUser), dbQueue: queue)
        stale.name = "Synthetic shared"
        let staleSaved = await stale.save()
        XCTAssertFalse(staleSaved)
        XCTAssertEqual(stale.write.message(for: PadAccountFormModel.rowId), "An account with that name already exists.")
        XCTAssertEqual(try accountCount(), count)
    }

    func testJointToggleHiddenForMember() async throws {
        let add = await form(.add, as: TwoPersonHousehold.memberICloudUser)
        XCTAssertFalse(add.showsJointToggle)
        add.name = "Test Joint"
        add.joint = true
        let saved = await add.save()
        XCTAssertTrue(saved)
        let id = try XCTUnwrap(add.addedId)
        XCTAssertEqual(try account(id).ownerPersonId, f.personB, "a member's toggle never makes it joint")
    }

    func testJointToggleShownForAdmin() async throws {
        let add = await form(.add, as: TwoPersonHousehold.adminICloudUser)
        XCTAssertTrue(add.showsJointToggle)
        add.name = "Test Joint"
        add.joint = true
        let saved = await add.save()
        XCTAssertTrue(saved)
        XCTAssertNil(try account(try XCTUnwrap(add.addedId)).ownerPersonId)
    }

    func testLoweringShowsPreviewBeforeSave() async throws {
        let id = try await memberAccount()
        let edit = await form(.edit(try account(id)), as: TwoPersonHousehold.memberICloudUser)
        XCTAssertTrue(edit.showsSharing)
        XCTAssertTrue(edit.showsLevelPicker)
        XCTAssertFalse(edit.showsOwnerPicker, "only the admin moves an account to Joint")
        edit.sharingLevel = .everything
        await edit.refreshPreview()
        XCTAssertFalse(edit.isLowering)
        XCTAssertNil(edit.loweringWarning())
        edit.sharingLevel = .hidden
        await edit.refreshPreview()
        XCTAssertTrue(edit.isLowering)
        let personB = f.personB
        let expected = try await queue.read { db in
            try AccountSharing.preview(accountId: id, owner: .person(personB), level: .hidden, db: db)
        }
        XCTAssertEqual(edit.preview, expected)
        XCTAssertEqual(edit.loweringWarning(), SharingCopy.lowerWarning(otherName: edit.context.sharing?.otherName ?? ""))
        XCTAssertEqual(try account(id).sharingLevel, .balanceOnly, "nothing saved by previewing")
    }

    func testSharingOnlyForTheOwner() async throws {
        let others = await form(.edit(try account(f.shared)), as: TwoPersonHousehold.memberICloudUser)
        XCTAssertFalse(others.showsSharing)
        let joint = await form(.edit(try account(f.joint)), as: TwoPersonHousehold.memberICloudUser)
        XCTAssertFalse(joint.showsSharing)
        let adminJoint = await form(.edit(try account(f.joint)), as: TwoPersonHousehold.adminICloudUser)
        XCTAssertTrue(adminJoint.showsOwnerPicker)
        XCTAssertFalse(adminJoint.showsLevelPicker, "joint is always Everything")
    }

    func testSaveCallsOneTransaction() async throws {
        let id = try await memberAccount()
        let edit = await form(.edit(try account(id)), as: TwoPersonHousehold.memberICloudUser)
        edit.name = "Test Renamed"
        edit.sharingLevel = .categoryTotals
        let saved = await edit.save()
        XCTAssertTrue(saved)
        let after = try account(id)
        XCTAssertEqual(after.name, "Test Renamed")
        XCTAssertEqual(after.sharingLevel, .categoryTotals)

        // Both or neither: a refused name leaves the level where it was.
        let again = await form(.edit(after), as: TwoPersonHousehold.memberICloudUser)
        again.name = "Synthetic shared"
        again.sharingLevel = .everything
        let refused = await again.save()
        XCTAssertFalse(refused)
        XCTAssertEqual(try account(id).sharingLevel, .categoryTotals)
        XCTAssertEqual(try account(id).name, "Test Renamed")
    }

    func testEditOfAccountNotSeenInFullIsRefused() async throws {
        let before = try account(f.totals)
        let edit = PadAccountFormModel(mode: .edit(before), write: await write(as: TwoPersonHousehold.memberICloudUser), dbQueue: queue)
        edit.name = "Test Renamed"
        let saved = await edit.save()
        XCTAssertFalse(saved)
        XCTAssertNotNil(edit.write.message(for: PadAccountFormModel.rowId))
        XCTAssertEqual(try account(f.totals).name, before.name)
    }
}
