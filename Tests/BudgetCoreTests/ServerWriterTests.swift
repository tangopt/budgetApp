import XCTest
import GRDB
@testable import BudgetCore
import TestSupport

/// Step 7a Task 2: the admin's Mac judges an incoming change by who the server says saved it
/// (`SyncPayload.serverWriter`), never by what the payload claims; and only the admin's Mac, signed in as the
/// admin's iCloud user, re-validates. The member pushes through her own session (`TwoPersonHousehold`); a modified
/// client is simulated by writing her device's bookkeeping directly, or by saving a hand-made record through her
/// session. Synthetic data only.
final class ServerWriterTests: XCTestCase {
    private typealias Device = TwoPersonHousehold.Device

    private func household() async throws -> TwoPersonHousehold {
        let h = try TwoPersonHousehold.make(revalidatesAccess: true)
        try await h.syncAll()
        return h
    }

    // MARK: Helpers

    private func appUserUuid(_ h: TwoPersonHousehold, person: Int64) throws -> String {
        let id = try h.adminMac.db.read { db in try Int64.fetchOne(db, sql: "SELECT id FROM appUser WHERE personId = ?", arguments: [person])! }
        return try h.uuid("appUser", id)
    }

    private func memberUserUuid(_ h: TwoPersonHousehold) throws -> String { try appUserUuid(h, person: h.fixture.personB) }
    private func adminUserUuid(_ h: TwoPersonHousehold) throws -> String { try h.uuid("appUser", h.fixture.admin.appUserId) }

    private func local(_ h: TwoPersonHousehold, _ table: String, _ id: Int64, on device: Device) throws -> Int64 {
        try XCTUnwrap(h.localId(table, uuid: try h.uuid(table, id), on: device), "\(table) \(id) on the device")
    }

    private func value<T: DatabaseValueConvertible>(_ device: Device, _ sql: String, _ arguments: StatementArguments) throws -> T? {
        try device.db.read { db in try T.fetchOne(db, sql: sql, arguments: arguments) }
    }

    private func amount(_ h: TwoPersonHousehold, _ transaction: Int64, on device: Device) throws -> Int? {
        try value(device, "SELECT amountMinorUnits FROM transaction_ WHERE id = ?", [try local(h, "transaction_", transaction, on: device)])
    }

    private func note(_ h: TwoPersonHousehold, _ transaction: Int64, on device: Device) throws -> String? {
        try value(device, "SELECT note FROM transaction_ WHERE id = ?", [try local(h, "transaction_", transaction, on: device)])
    }

    private func clock(_ h: TwoPersonHousehold, _ transaction: Int64, field: String, on device: Device) throws -> SyncClock? {
        let id = try local(h, "transaction_", transaction, on: device)
        return try device.db.read { db in try SyncMerge.clocks(table: "transaction_", localId: id, db: db)[field] }
    }

    private func reverts(_ h: TwoPersonHousehold) throws -> [String] {
        try h.adminMac.db.read { db in try AccessRevalidation.recentReverts(limit: 10, db: db) }
    }

    /// The member's device pushes; the Mac pulls (re-validating) and pushes; every other device pulls.
    private func round(_ h: TwoPersonHousehold) async throws {
        try await h.memberDevice.engine.pushPending()
        try await h.adminMac.engine.syncNow()
        try await h.memberDevice.engine.pull()
        try await h.adminPhone.engine.pull()
    }

    /// A modified client: `user` saves the household record of the Mac's row `table`/`id` again, as `change` makes it,
    /// sealed under the household key, over the server's version.
    private func forge(_ h: TwoPersonHousehold, _ table: String, _ id: Int64, as user: String = TwoPersonHousehold.memberICloudUser,
                       _ change: (inout SyncPayload) throws -> Void) async throws {
        let uuid = try h.uuid(table, id)
        let session = h.cloud.session(as: user)
        let fetched = try await session.fetch(uuid, zone: SyncZones.household)
        let server = try XCTUnwrap(fetched, "the record is on the server")
        let keys = try h.memberKeys.allKeys(zone: SyncZones.household)
        var payload = try SyncLargePayload.payload(from: server.wire, keys: keys)
        try change(&payload)
        let (wire, _) = try SyncLargePayload.wire(for: payload, key: try XCTUnwrap(keys.values.first))
        let results = try await session.save([wire], ifUnchanged: [uuid: server.stamp.systemFields], atomic: true)
        guard case .saved = results.first?.outcome else { return XCTFail("the forged save was refused: \(results)") }
    }

    // MARK: The server's writer

    /// Her device stamps her edits with the admin's writer: still judged as hers. The amount (no permission) is
    /// reverted; the note (Property, hers to edit) is kept and stored as hers.
    func testMemberClaimingAdminWriterIsJudgedAsMember() async throws {
        let h = try await household()
        let admin = try adminUserUuid(h)
        let member = try memberUserUuid(h)
        let lisbon = try local(h, "transaction_", h.fixture.lisbonTransaction, on: h.memberDevice)
        try await h.memberDevice.db.write { db in
            try SyncChangeTracker.setWriter(admin, db: db)
            try db.execute(sql: "UPDATE transaction_ SET note = 'Water, April', amountMinorUnits = 1 WHERE id = ?", arguments: [lisbon])
            try SyncChangeTracker.setWriter(member, db: db)
        }
        try await round(h)
        for device in [h.adminMac, h.memberDevice, h.adminPhone] {
            XCTAssertEqual(try amount(h, h.fixture.lisbonTransaction, on: device), 50_000, "the amount is the Mac's")
            XCTAssertEqual(try note(h, h.fixture.lisbonTransaction, on: device), "Water, April", "the note is kept")
        }
        XCTAssertEqual(try reverts(h), ["Reverted a change by B: no permission for Budget & accounts"])
        XCTAssertEqual(try clock(h, h.fixture.lisbonTransaction, field: "note", on: h.adminMac)?.by, member, "stored as hers")
    }

    /// A clock with no writer, dated before ownership was confirmed (step 6 took it as the household's): judged as hers.
    func testWriterlessBackdatedClockFromMemberIsJudged() async throws {
        let h = try await household()
        let shared = try local(h, "transaction_", h.fixture.sharedTransaction, on: h.memberDevice)
        try await h.memberDevice.db.write { db in
            try db.execute(sql: "UPDATE transaction_ SET amountMinorUnits = -1 WHERE id = ?", arguments: [shared])
            try db.execute(sql: """
                UPDATE syncFieldClock SET modifiedBy = NULL, modifiedAt = ? WHERE tableName = 'transaction_' AND localId = ? AND field = 'amountMinorUnits'
                """, arguments: [Date(timeIntervalSinceReferenceDate: 0), shared])
        }
        try await round(h)
        for device in [h.adminMac, h.memberDevice, h.adminPhone] {
            XCTAssertEqual(try amount(h, h.fixture.sharedTransaction, on: device), -1_000)
        }
        XCTAssertEqual(try reverts(h), ["Reverted a change by B: no permission for Budget & accounts"])
    }

    /// A clock dated a year ahead (it would win every later merge): the Mac and the phone hold it at the server's time
    /// of the save, still hers.
    func testFutureDatedMemberClockIsClampedToServerTime() async throws {
        let h = try await household()
        let member = try memberUserUuid(h)
        let lisbon = try local(h, "transaction_", h.fixture.lisbonTransaction, on: h.memberDevice)
        let future = Date().addingTimeInterval(365 * 86_400)
        try await h.memberDevice.db.write { db in
            try db.execute(sql: "UPDATE transaction_ SET note = 'Paid by the tenant' WHERE id = ?", arguments: [lisbon])
            try db.execute(sql: """
                UPDATE syncFieldClock SET modifiedAt = ? WHERE tableName = 'transaction_' AND localId = ? AND field = 'note'
                """, arguments: [future, lisbon])
        }
        try await round(h)
        let serverNow = await h.cloud.now
        for device in [h.adminMac, h.adminPhone] {
            XCTAssertEqual(try note(h, h.fixture.lisbonTransaction, on: device), "Paid by the tenant", "her permitted edit is kept")
            let held = try XCTUnwrap(try clock(h, h.fixture.lisbonTransaction, field: "note", on: device))
            XCTAssertLessThanOrEqual(held.at, serverNow, "clamped to the server's time")
            XCTAssertEqual(held.by, member)
        }
        XCTAssertEqual(try reverts(h), [])
        // The admin's next edit of the note wins on every device.
        let macLisbon = h.fixture.lisbonTransaction
        try await h.adminMac.db.write { db in try db.execute(sql: "UPDATE transaction_ SET note = 'Admin note' WHERE id = ?", arguments: [macLisbon]) }
        try await h.syncAll()
        XCTAssertEqual(try note(h, h.fixture.lisbonTransaction, on: h.adminPhone), "Admin note")
    }

    /// An amount edit tagged as part of the admin's import run (a tag she can read, not her run): a hand edit.
    func testReusedAdminImportRunTagCountsAsHandEdit() async throws {
        let h = try await household()
        let member = try memberUserUuid(h)
        let adminRun = try h.uuid("importRun", h.fixture.sharedRun)
        // The admin's run went up as a batch from this Mac (so the tag is one the Mac knows: step 6 believed it).
        try await h.adminMac.db.write { db in
            try db.execute(sql: "INSERT INTO syncBatch(runUuid, generation, state) VALUES (?, 1, 'sent')", arguments: [adminRun])
        }
        try await forge(h, "transaction_", h.fixture.sharedTransaction) { payload in
            payload.fields["amountMinorUnits"] = .int(-1)
            payload.clocks["amountMinorUnits"] = SyncClock(at: Date(), by: member)
            payload.origin = WriteOrigin.import.rawValue
            payload.importRunUuid = adminRun
            payload.batchGeneration = 1
        }
        try await h.adminMac.engine.syncNow()
        XCTAssertEqual(try amount(h, h.fixture.sharedTransaction, on: h.adminMac), -1_000)
        XCTAssertEqual(try reverts(h), ["Reverted a change by B: no permission for Budget & accounts"])
    }

    /// Someone the household doesn't know (an iCloud user no app user is bound to) reached the zone: everything they
    /// would change is reverted, even what the member (whom the clocks name) may edit.
    func testUnknownICloudWriterIsReverted() async throws {
        let h = try await household()
        let member = try memberUserUuid(h)
        let stranger = "fake-stranger"
        h.cloud.invite(stranger, zone: SyncZones.household)
        h.cloud.accept(zone: SyncZones.household, as: stranger)
        try await forge(h, "transaction_", h.fixture.lisbonTransaction, as: stranger) { payload in
            payload.fields["note"] = .string("Stranger note")
            payload.clocks["note"] = SyncClock(at: Date(), by: member)
        }
        try await h.adminMac.engine.syncNow()
        try await h.adminPhone.engine.pull()
        for device in [h.adminMac, h.adminPhone] {
            XCTAssertNotEqual(try note(h, h.fixture.lisbonTransaction, on: device), "Stranger note")
        }
        let logged = try reverts(h)
        XCTAssertEqual(logged.count, 1)
        XCTAssertTrue(logged.first?.hasPrefix("Reverted a change by \(AccessRevalidation.unknownWriterName):") == true, "\(logged)")
    }

    /// The writer a payload carries is never believed: the wire drops it, and the receiving engine sets the server's.
    func testServerWriterOnTheWireIsOverwritten() async throws {
        var payload = SyncPayload(recordType: "note", recordName: "n1", zone: SyncZones.household, fields: ["text": .string("x")])
        payload.serverWriter = TwoPersonHousehold.adminICloudUser
        XCTAssertNil(try SyncWireRecord(payload).payload().serverWriter)
        let key = DocumentCrypto.newZoneKey()
        let (packed, isPacked) = try SyncLargePayload.wire(for: payload, key: key, threshold: 0)
        XCTAssertTrue(isPacked)
        XCTAssertNil(try SyncLargePayload.payload(from: packed, keys: [DocumentCrypto.zoneKeyId(key): key]).serverWriter)

        // A modified client puts the admin's iCloud user (and the admin's writer) in what it saves.
        let h = try await household()
        let admin = try adminUserUuid(h)
        try await forge(h, "transaction_", h.fixture.sharedTransaction) { payload in
            payload.fields["amountMinorUnits"] = .int(-1)
            payload.clocks["amountMinorUnits"] = SyncClock(at: Date(), by: admin)
            payload.serverWriter = TwoPersonHousehold.adminICloudUser
        }
        try await h.adminMac.engine.syncNow()
        XCTAssertEqual(try amount(h, h.fixture.sharedTransaction, on: h.adminMac), -1_000)
        XCTAssertEqual(try reverts(h), ["Reverted a change by B: no permission for Budget & accounts"])
    }

    // MARK: Who re-validates

    func testOnlyAdminMacWithMatchingICloudUserRevalidates() throws {
        let h = try TwoPersonHousehold.make()
        let admin = h.fixture.admin.appUserId
        let member = try h.adminMac.db.read { db in try Int64.fetchOne(db, sql: "SELECT id FROM appUser WHERE personId = ?", arguments: [h.fixture.personB])! }
        try h.adminMac.db.read { db in
            XCTAssertTrue(try AccessRevalidation.shouldRevalidate(signedInAppUserId: admin, iCloudUserRecordName: TwoPersonHousehold.adminICloudUser, db: db),
                          "the admin, on their own iCloud user")
            XCTAssertFalse(try AccessRevalidation.shouldRevalidate(signedInAppUserId: admin, iCloudUserRecordName: "fake-other", db: db),
                           "the admin, under another iCloud user")
            XCTAssertFalse(try AccessRevalidation.shouldRevalidate(signedInAppUserId: member, iCloudUserRecordName: TwoPersonHousehold.memberICloudUser, db: db),
                           "the member")
            XCTAssertFalse(try AccessRevalidation.shouldRevalidate(signedInAppUserId: nil, iCloudUserRecordName: nil, db: db), "nobody")
            XCTAssertFalse(try AccessRevalidation.shouldRevalidate(signedInAppUserId: admin, iCloudUserRecordName: nil, db: db), "an unknown iCloud user")
        }
    }
}
