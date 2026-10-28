import XCTest
import GRDB
@testable import BudgetCore
import TestSupport

/// Step 11 Task 1: the iPad's account writes (`PadAccountEdits`) through `DeviceWriter.writeWithActor`. Both people's
/// writers over the admin's database (`TwoPersonHousehold`'s Mac, with `SharingFixture`: ownership confirmed, the admin's
/// accounts, a joint one and a property-linked one). Synthetic data only.
final class PadAccountEditsTests: XCTestCase {
    private var h: TwoPersonHousehold!
    private var queue: DatabaseQueue { h.adminMac.db }
    private var f: SharingFixture { h.fixture }

    private static func day(_ y: Int, _ m: Int, _ d: Int) -> Date {
        UKTaxYear.utcCalendar.date(from: DateComponents(year: y, month: m, day: d))!
    }

    override func setUpWithError() throws {
        h = try TwoPersonHousehold.make()
        try setMemberLevel(.edit)
    }

    // MARK: Helpers

    private var memberWriter: DeviceWriter {
        DeviceWriter(db: queue, viewer: { .iCloudUser(recordName: TwoPersonHousehold.memberICloudUser) }, afterWrite: {})
    }

    private var adminWriter: DeviceWriter {
        DeviceWriter(db: queue, viewer: { .iCloudUser(recordName: TwoPersonHousehold.adminICloudUser) }, afterWrite: {})
    }

    private func setMemberLevel(_ level: PermissionLevel) throws {
        let f = self.f
        try write { db in
            let member = try Int64.fetchOne(db, sql: "SELECT id FROM appUser WHERE personId = ?", arguments: [f.personB])!
            try db.execute(sql: "DELETE FROM memberPermission WHERE appUserId = ? AND area = ?",
                           arguments: [member, AccessArea.budgetAndAccounts.storageKey])
            var row = MemberPermission(appUserId: member, area: AccessArea.budgetAndAccounts.storageKey, level: level)
            try row.insert(db)
        }
    }

    /// Synchronous access (async tests would otherwise pick GRDB's async overloads).
    private func read<T>(_ body: (Database) throws -> T) throws -> T { try queue.read(body) }
    private func write<T>(_ body: (Database) throws -> T) throws -> T { try queue.write(body) }

    private func account(_ id: Int64) throws -> Account {
        try XCTUnwrap(try read { db in try Account.fetchOne(db, key: id) })
    }

    private func accountCount() throws -> Int {
        try read { db in try Account.fetchCount(db) }
    }

    private func thrown(_ body: () async throws -> Void) async -> Error? {
        do {
            try await body()
            return nil
        } catch {
            return error
        }
    }

    /// The member's own account, added on her iPad.
    private func memberAccount(_ name: String = "Test Current") async throws -> Int64 {
        try await PadAccountEdits.add(writer: memberWriter, name: name, currency: .gbp, kind: .cash, manual: true,
                                      openingBalanceEntered: 1_000_00, asOf: Self.day(2026, 10, 1), details: AccountDetails(),
                                      includeInNetWorth: true, joint: false)
    }

    // MARK: Add

    func testAddOwnAccountIsOwnedByWriterAtDefaultLevel() async throws {
        let id = try await memberAccount()
        let added = try account(id)
        XCTAssertEqual(added.name, "Test Current")
        XCTAssertEqual(added.currency, .gbp)
        XCTAssertEqual(added.trackingMode, .manual)
        XCTAssertEqual(added.ownerPersonId, f.personB)
        XCTAssertEqual(added.sharingLevel, SharingDefaults.level(ownerPersonId: f.personB, isPropertyLinked: false))
        let snapshots = try read { db in try BalanceSnapshot.filter(Column("accountId") == id).fetchAll(db) }
        XCTAssertEqual(snapshots.count, 1)
        XCTAssertEqual(snapshots.first?.balanceMinorUnits, 1_000_00)
    }

    func testMemberCannotAddJoint() async throws {
        let before = try accountCount()
        let error = await thrown {
            try await PadAccountEdits.add(writer: self.memberWriter, name: "Test Joint", currency: .gbp, kind: .cash, manual: false,
                                          openingBalanceEntered: nil, asOf: Self.day(2026, 10, 1), details: AccountDetails(),
                                          includeInNetWorth: true, joint: true)
        }
        XCTAssertEqual(error as? PadAccountError, .jointNeedsAdmin)
        XCTAssertEqual(PadAccountError.jointNeedsAdmin.errorDescription, "Only the household's admin adds a joint account.")
        XCTAssertEqual(try accountCount(), before, "no account row added")
    }

    func testAdminAddsJointAtEverything() async throws {
        let id = try await PadAccountEdits.add(writer: adminWriter, name: "Test Joint", currency: .eur, kind: .cash, manual: false,
                                               openingBalanceEntered: nil, asOf: Self.day(2026, 10, 1), details: AccountDetails(),
                                               includeInNetWorth: true, joint: true)
        let added = try account(id)
        XCTAssertNil(added.ownerPersonId)
        XCTAssertEqual(added.sharingLevel, .everything)
        XCTAssertEqual(added.trackingMode, .imported)
    }

    // MARK: Edit

    func testUpdateNameKindDetailsSavedTogetherWithLevel() async throws {
        let id = try await memberAccount()
        var details = AccountDetails(region: .uk)
        details.bankName = "Test Bank"
        try await PadAccountEdits.update(writer: memberWriter, accountId: id, name: "Test Savings", kind: .investment, details: details,
                                         includeInNetWorth: true, sharing: (.person(f.personB), .categoryTotals))
        let saved = try account(id)
        XCTAssertEqual(saved.name, "Test Savings")
        XCTAssertEqual(saved.kind, .investment)
        XCTAssertEqual(saved.bankName, "Test Bank")
        XCTAssertEqual(saved.sharingLevel, .categoryTotals)

        // A level change the owner rule refuses takes the name with it: both or neither.
        let error = await thrown {
            try await PadAccountEdits.update(writer: self.adminWriter, accountId: id, name: "Test Renamed", kind: .investment,
                                             details: details, includeInNetWorth: true, sharing: (.person(self.f.personB), .everything))
        }
        XCTAssertEqual(error as? SharingError, .notOwner)
        XCTAssertEqual(try account(id).name, "Test Savings")
        XCTAssertEqual(try account(id).sharingLevel, .categoryTotals)
    }

    func testSetLevelOnOthersAccountRefused() async throws {
        let before = try account(f.shared)
        let error = await thrown {
            try await PadAccountEdits.update(writer: self.memberWriter, accountId: self.f.shared, name: "Test Renamed", kind: before.kind,
                                             details: AccountDetails(), includeInNetWorth: before.includeInNetWorth,
                                             sharing: (.person(self.f.personA), .balanceOnly))
        }
        XCTAssertEqual(error as? SharingError, .notOwner)
        let after = try account(f.shared)
        XCTAssertEqual(after.name, before.name)
        XCTAssertEqual(after.sharingLevel, before.sharingLevel)
    }

    func testPropertyLinkedEditOnFiledYearRefused() async throws {
        let f = self.f
        // A kind or Count toward net worth change on a property-linked account reaches every filed year; anything
        // else on any account reaches none.
        try read { db in
            XCTAssertEqual(try PadAccountEdits.updateScope(accountId: f.lisbon, kind: .investment, includeInNetWorth: true, db: db), .everyYear)
            XCTAssertEqual(try PadAccountEdits.updateScope(accountId: f.lisbon, kind: .cash, includeInNetWorth: false, db: db), .everyYear)
            XCTAssertEqual(try PadAccountEdits.updateScope(accountId: f.lisbon, kind: .cash, includeInNetWorth: true, db: db),
                           FiledYearEditCheck.Scope())
            XCTAssertEqual(try PadAccountEdits.updateScope(accountId: f.shared, kind: .investment, includeInNetWorth: false, db: db),
                           FiledYearEditCheck.Scope())
        }
        // A filed 2022/23 return: an account edit saved with a repair the return would count is refused, nothing saved.
        let (repair, repairs) = try write { db -> (Int64, Int64) in
            try db.execute(sql: "UPDATE property SET currency = 'gbp' WHERE id = ?", arguments: [f.propertyId])
            _ = try Properties.setOwners(db: db, propertyId: f.propertyId, [
                PropertyOwner(propertyId: f.propertyId, personId: f.personA, shareBasisPoints: 10_000)
            ])
            var filed = TaxYear(startYear: 2022, personId: f.personA, status: .filed)
            try filed.insert(db)
            let group = try Int64.fetchOne(db, sql: "SELECT categoryGroupId FROM propertyCategoryGroup WHERE propertyId = ?",
                                           arguments: [f.propertyId])
            var repairs = Category(name: "Test repairs", type: .expense, groupId: group)
            try repairs.insert(db)
            try TaxExpenseTypeMap.seed(db: db, propertyId: f.propertyId)
            try TaxExpenseTypeMap.set(db: db, categoryId: repairs.id!, expenseType: .repairs)
            let batch = try Int64.fetchOne(db, sql: "SELECT id FROM importBatch WHERE accountId = ?", arguments: [f.lisbon])!
            var repair = Transaction(importBatchId: batch, accountId: f.lisbon, date: Self.day(2022, 11, 1), rawDescription: "PLUMBER",
                                     amountMinorUnits: -40_000, categoryId: nil, status: .pendingReview, categorizedBy: .none,
                                     fingerprint: "test-repair")
            try repair.insert(db)
            return (repair.id!, repairs.id!)
        }
        let before = try account(f.lisbon)
        let scope = try read { db in
            try PadAccountEdits.updateScope(accountId: f.lisbon, kind: .investment, includeInNetWorth: true, db: db)
        }
        let lisbon = f.lisbon
        let error = await thrown {
            try await self.adminWriter.writeWithActor(.budgetAndAccounts, edit: "Edit account", scope: scope) { db, _ in
                try AccountEditing.update(db: db, accountId: lisbon, name: "Test Flat", kind: .investment, includeInNetWorth: true)
                try db.execute(sql: "UPDATE transaction_ SET categoryId = ? WHERE id = ?", arguments: [repairs, repair])
            }
        }
        guard case .filedYear(let question)? = error as? DeviceWriteRefusal else {
            return XCTFail("expected a filed-year refusal, got \(String(describing: error))")
        }
        XCTAssertEqual(question.years.first?.label, "2022/23")
        XCTAssertEqual(try account(f.lisbon), before, "nothing saved")
        XCTAssertNil(try read { db in try Int64.fetchOne(db, sql: "SELECT categoryId FROM transaction_ WHERE id = ?", arguments: [repair]) })
        // The same kind change on its own moves no filed figure (no tax figure reads an account's kind): it saves.
        try await PadAccountEdits.update(writer: adminWriter, accountId: f.lisbon, name: before.name, kind: .investment, details: AccountDetails(before),
                                         includeInNetWorth: before.includeInNetWorth, sharing: nil)
        XCTAssertEqual(try account(f.lisbon).kind, .investment)
    }

    func testViewOnlyWriterRefused() async throws {
        try setMemberLevel(.view)
        let before = try accountCount()
        let shared = try account(f.shared)
        let addError = await thrown { _ = try await self.memberAccount() }
        XCTAssertEqual(addError as? AccessDenied, AccessDenied(area: .budgetAndAccounts))
        let updateError = await thrown {
            try await PadAccountEdits.update(writer: self.memberWriter, accountId: self.f.shared, name: "Test Renamed", kind: shared.kind,
                                             details: AccountDetails(), includeInNetWorth: false, sharing: nil)
        }
        XCTAssertEqual(updateError as? AccessDenied, AccessDenied(area: .budgetAndAccounts))
        XCTAssertEqual(try accountCount(), before)
        XCTAssertEqual(try account(f.shared), shared)
    }

    func testIncludeInNetWorthToggleSaved() async throws {
        let id = try await memberAccount()
        try await PadAccountEdits.update(writer: memberWriter, accountId: id, name: "Test Current", kind: .cash, details: AccountDetails(),
                                         includeInNetWorth: false, sharing: nil)
        XCTAssertFalse(try account(id).includeInNetWorth)
        try await PadAccountEdits.update(writer: memberWriter, accountId: id, name: "Test Current", kind: .cash, details: AccountDetails(),
                                         includeInNetWorth: true, sharing: nil)
        XCTAssertTrue(try account(id).includeInNetWorth)
    }

    // MARK: Sharing

    func testCanSetSharingOnlyForOwnAccount() async throws {
        let own = try await memberAccount()
        let memberCanOwn = try await PadAccountEdits.canSetSharing(accountId: own, writer: memberWriter, dbReader: queue)
        let memberCanShared = try await PadAccountEdits.canSetSharing(accountId: f.shared, writer: memberWriter, dbReader: queue)
        let memberCanJoint = try await PadAccountEdits.canSetSharing(accountId: f.joint, writer: memberWriter, dbReader: queue)
        let adminCanShared = try await PadAccountEdits.canSetSharing(accountId: f.shared, writer: adminWriter, dbReader: queue)
        let adminCanMemberOwn = try await PadAccountEdits.canSetSharing(accountId: own, writer: adminWriter, dbReader: queue)
        XCTAssertTrue(memberCanOwn)
        XCTAssertFalse(memberCanShared, "the admin's")
        XCTAssertFalse(memberCanJoint, "joint: nobody's to set")
        XCTAssertTrue(adminCanShared)
        XCTAssertFalse(adminCanMemberOwn, "the admin is no exception")

        let state = try await PadAccountEdits.sharingState(writer: memberWriter, dbReader: queue, accountId: own)
        XCTAssertEqual(state?.owner, .person(f.personB))
        // View only: no sharing controls, even on her own.
        try setMemberLevel(.view)
        let viewOnly = try await PadAccountEdits.canSetSharing(accountId: own, writer: memberWriter, dbReader: queue)
        XCTAssertFalse(viewOnly)
        // No actor: no state.
        let stranger = DeviceWriter(db: queue, viewer: { .iCloudUser(recordName: "test-nobody") }, afterWrite: {})
        let none = try await PadAccountEdits.sharingState(writer: stranger, dbReader: queue, accountId: own)
        XCTAssertNil(none)
        let strangerCan = try await PadAccountEdits.canSetSharing(accountId: own, writer: stranger, dbReader: queue)
        XCTAssertFalse(strangerCan)
    }
}

