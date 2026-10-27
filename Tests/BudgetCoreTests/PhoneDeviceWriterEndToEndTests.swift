import XCTest
import GRDB
@testable import BudgetCore
import TestSupport

/// Step 7b Task 3: the iPhone writes as the iPad does (`DeviceWriteMode` on both idioms), end to end. Two people over
/// one `FakeCloud` (`TwoPersonHousehold`, the Mac re-validating, the household share read-write), her iPhone
/// (`memberPhone`) and the admin's (`adminPhone`) in device mode with no document files, every edit through
/// `DeviceWriter.writeCheckingFiledYears` as the phone's screens make it. Every save is audited. Synthetic data only.
final class PhoneDeviceWriterEndToEndTests: XCTestCase {
    private typealias Device = TwoPersonHousehold.Device

    // MARK: Household

    /// The household with the share read-write, synced to every device, her iPhone included.
    private func household() async throws -> TwoPersonHousehold {
        let h = try TwoPersonHousehold.make(revalidatesAccess: true)
        _ = try await h.cloud.makeZoneShare(SyncZones.household, title: "Synthetic household")
        try await h.syncAll()
        try await h.memberPhone.engine.pull()
        XCTAssertEqual(try pendingCount(h.memberPhone), 0)
        XCTAssertEqual(try pendingCount(h.adminPhone), 0)
        assertAuditsClean(h)
        return h
    }

    // MARK: Helpers

    private func memberWriter(_ h: TwoPersonHousehold) -> DeviceWriter {
        DeviceWriter(db: h.memberPhone.db, viewer: { .iCloudUser(recordName: TwoPersonHousehold.memberICloudUser) }, afterWrite: {})
    }

    private func adminWriter(_ h: TwoPersonHousehold) -> DeviceWriter {
        DeviceWriter(db: h.adminPhone.db, viewer: { .iCloudUser(recordName: TwoPersonHousehold.adminICloudUser) }, afterWrite: {})
    }

    /// The local id on `device` of the Mac's row `table`/`id`.
    private func local(_ h: TwoPersonHousehold, _ table: String, _ id: Int64, on device: Device) throws -> Int64 {
        try XCTUnwrap(h.localId(table, uuid: try h.uuid(table, id), on: device), "\(table) \(id) on the device")
    }

    private func value<T: DatabaseValueConvertible>(_ device: Device, _ sql: String, _ arguments: StatementArguments = []) throws -> T? {
        try device.db.read { db in try T.fetchOne(db, sql: sql, arguments: arguments) }
    }

    private func pendingCount(_ device: Device) throws -> Int {
        try value(device, "SELECT COUNT(*) FROM syncPending")!
    }

    private func reverts(_ h: TwoPersonHousehold) throws -> [String] {
        try h.adminMac.db.read { db in try AccessRevalidation.recentReverts(limit: 10, db: db) }
    }

    private func assertAuditsClean(_ h: TwoPersonHousehold, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(h.audit.householdViolations(router: h.adminRouter()), [], "admin", file: file, line: line)
        XCTAssertEqual(h.memberAudit.householdViolations(router: TwoPersonHousehold.router(h.memberPhone.db)), [], "member",
                       file: file, line: line)
    }

    /// A note edit on `transaction` (the Mac's id) on `device`, as the phone's note sheet saves it.
    private func editNote(_ h: TwoPersonHousehold, _ writer: DeviceWriter, _ area: AccessArea, transaction: Int64, on device: Device,
                          note: String) async throws {
        let here = try local(h, "transaction_", transaction, on: device)
        try await writer.writeCheckingFiledYears(area, edit: "Edit note", scope: FiledYearEditCheck.Scope(transactionIds: [here])) { db in
            try db.execute(sql: "UPDATE transaction_ SET note = ? WHERE id = ?", arguments: [note, here])
        }
    }

    /// The saves `transport` has carried, per zone.
    private func saveCounts(_ transport: ZoneAuditingTransport) -> [String: Int] {
        transport.savesByZone.mapValues(\.count)
    }

    // MARK: Tests

    /// Her iPhone edits the note of the flat's rent (property money: her Edit area). It goes up, the Mac re-validates
    /// and keeps it, and every device has her note.
    func testMemberPhoneNoteEditReachesMac() async throws {
        let h = try await household()
        let f = h.fixture
        try await editNote(h, memberWriter(h), .property, transaction: f.lisbonTransaction, on: h.memberPhone, note: "Rent, October")
        XCTAssertGreaterThan(try pendingCount(h.memberPhone), 0, "queued on her iPhone")

        let pushed = try await h.memberPhone.engine.pushPending()
        XCTAssertGreaterThan(pushed.saved, 0)
        XCTAssertEqual(pushed.heldBack, 0)
        try await h.adminMac.engine.syncNow()
        try await h.memberPhone.engine.pull()
        try await h.adminPhone.engine.pull()

        XCTAssertEqual(try value(h.adminMac, "SELECT note FROM transaction_ WHERE id = ?", [f.lisbonTransaction]) as String?, "Rent, October",
                       "kept by the Mac")
        for device in [h.memberPhone, h.adminPhone] {
            let here = try local(h, "transaction_", f.lisbonTransaction, on: device)
            XCTAssertEqual(try value(device, "SELECT note FROM transaction_ WHERE id = ?", [here]) as String?, "Rent, October")
        }
        XCTAssertEqual(try reverts(h), [])
        XCTAssertEqual(try pendingCount(h.memberPhone), 0)
        assertAuditsClean(h)
    }

    /// The admin's iPhone edits a transaction of his private account: it goes to his private zone, and nothing of his
    /// phone's reaches any zone but the household and his own.
    func testAdminPhoneEditOfPrivateAccountGoesToHisPrivateZone() async throws {
        let h = try await household()
        let f = h.fixture
        let before = saveCounts(h.audit)
        try await editNote(h, adminWriter(h), .budgetAndAccounts, transaction: f.privateTransaction, on: h.adminPhone, note: "Mine only")

        let pushed = try await h.adminPhone.engine.pushPending()
        XCTAssertGreaterThan(pushed.saved, 0)
        XCTAssertEqual(pushed.heldBack, 0)
        let after = saveCounts(h.audit)
        let reached = Set(after.keys.filter { after[$0, default: 0] > before[$0, default: 0] })
        XCTAssertEqual(reached, [f.privateZone], "his own zone only")
        XCTAssertTrue(reached.isSubset(of: [SyncZones.household, f.privateZone]))
        let uuid = try h.uuid("transaction_", f.privateTransaction)
        let inPrivate = try await h.cloud.fetch(uuid, zone: f.privateZone)
        XCTAssertNotNil(inPrivate, "saved in A's zone")
        let inHousehold = try await h.cloud.fetch(uuid, zone: SyncZones.household)
        XCTAssertNil(inHousehold, "never in the household")

        try await h.adminMac.engine.syncNow()
        XCTAssertEqual(try value(h.adminMac, "SELECT note FROM transaction_ WHERE id = ?", [f.privateTransaction]) as String?, "Mine only")
        try await h.memberPhone.engine.pull()
        XCTAssertNil(try h.localId("transaction_", uuid: uuid, on: h.memberPhone), "never on her iPhone")
        assertAuditsClean(h)
    }

    /// The iPhone keeps no document files (`documents: nil`): a transaction edit still goes up whole, nothing held back.
    func testPhoneWithoutDocumentFilesPushesTransactionEdit() async throws {
        let h = try await household()
        let f = h.fixture
        let memberFiles = await h.memberPhone.engine.documents
        let adminFiles = await h.adminPhone.engine.documents
        XCTAssertNil(memberFiles, "no document files on her iPhone")
        XCTAssertNil(adminFiles, "nor on his")
        try await editNote(h, memberWriter(h), .property, transaction: f.lisbonTransaction, on: h.memberPhone, note: "Paid late")

        let pushed = try await h.memberPhone.engine.pushPending()
        XCTAssertGreaterThan(pushed.saved, 0)
        XCTAssertEqual(pushed.heldBack, 0)
        XCTAssertEqual(try pendingCount(h.memberPhone), 0)
        try await h.adminMac.engine.syncNow()
        XCTAssertEqual(try value(h.adminMac, "SELECT note FROM transaction_ WHERE id = ?", [f.lisbonTransaction]) as String?, "Paid late")
        assertAuditsClean(h)
    }

    /// A modified iPhone writes past `DeviceWriter` (stamped as her, as every write on her phone is): a household
    /// transaction's category, outside her Edit areas. The Mac reverts it, and her iPhone converges on the original.
    func testMemberPhoneBudgetEditRevertedByMac() async throws {
        let h = try await household()
        let f = h.fixture
        let shared = try local(h, "transaction_", f.sharedTransaction, on: h.memberPhone)
        let propertyCategory = try local(h, "category", f.propertyCategory, on: h.memberPhone)
        try await h.memberPhone.db.write { db in
            try db.execute(sql: "UPDATE transaction_ SET categoryId = ? WHERE id = ?", arguments: [propertyCategory, shared])
        }
        let pushed = try await h.memberPhone.engine.pushPending()
        XCTAssertEqual(pushed.heldBack, 0)
        try await h.adminMac.engine.syncNow()
        try await h.memberPhone.engine.pull()
        try await h.adminPhone.engine.pull()

        XCTAssertEqual(try value(h.adminMac, "SELECT categoryId FROM transaction_ WHERE id = ?", [f.sharedTransaction]) as Int64?, f.plainCategory)
        for device in [h.memberPhone, h.adminPhone] {
            let here = try local(h, "transaction_", f.sharedTransaction, on: device)
            let plain = try local(h, "category", f.plainCategory, on: device)
            XCTAssertEqual(try value(device, "SELECT categoryId FROM transaction_ WHERE id = ?", [here]) as Int64?, plain, "converged")
        }
        XCTAssertEqual(try reverts(h), ["Reverted a change by B: no permission for Budget & accounts"])
        XCTAssertEqual(try pendingCount(h.memberPhone), 0)
        assertAuditsClean(h)
    }
}
