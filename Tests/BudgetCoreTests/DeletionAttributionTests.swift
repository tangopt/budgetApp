import XCTest
import GRDB
@testable import BudgetCore
import TestSupport

/// Step 7a Task 3: a household delete travels as a deletion marker (`SyncPayload.deleted`), a save the server
/// attributes, so the admin's Mac judges it like any other change: one its writer had no permission for is undone,
/// and so is a bare hard deletion in the household it didn't make. Two simulated people (`TwoPersonHousehold`, the
/// Mac re-validating). Synthetic data only.
final class DeletionAttributionTests: XCTestCase {
    private typealias Device = TwoPersonHousehold.Device

    private func household() async throws -> TwoPersonHousehold {
        let h = try TwoPersonHousehold.make(revalidatesAccess: true)
        try await h.syncAll()
        return h
    }

    // MARK: Helpers

    private func local(_ h: TwoPersonHousehold, _ table: String, _ id: Int64, on device: Device) throws -> Int64 {
        try XCTUnwrap(h.localId(table, uuid: try h.uuid(table, id), on: device), "\(table) \(id) on the device")
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

    private func delete(_ table: String, _ id: Int64, on device: Device) throws {
        try device.db.write { db in
            try db.execute(sql: "DELETE FROM \(table) WHERE id = ?", arguments: [id])
        }
    }

    /// The household's server copy of a record, opened.
    private func serverPayload(_ h: TwoPersonHousehold, _ uuid: String) async throws -> SyncPayload? {
        guard let server = try await h.cloud.fetch(uuid, zone: SyncZones.household) else { return nil }
        return try SyncLargePayload.payload(from: server, keys: try h.adminKeys.allKeys(zone: SyncZones.household))
    }

    /// A document the Mac links to the shared transaction (both in the household), synced everywhere: the link's id.
    private func householdLink(_ h: TwoPersonHousehold) async throws -> Int64 {
        let link = try await h.adminMac.db.write { db -> Int64 in
            try db.execute(sql: """
                INSERT INTO document(sha256, storedRelativePath, originalFileName, byteCount, addedAt) VALUES (?, ?, 'synthetic.pdf', 1, ?)
                """, arguments: [String(repeating: "3", count: 64), "synthetic-3.pdf", Date()])
            try db.execute(sql: "INSERT INTO documentLink(documentId, entityType, entityId, createdAt) VALUES (?, 'transaction', ?, ?)",
                           arguments: [db.lastInsertedRowID, h.fixture.sharedTransaction, Date()])
            return db.lastInsertedRowID
        }
        try await h.syncAll()
        return link
    }

    // MARK: Judged

    /// She deletes a transaction (Budget & accounts: view only for her): the Mac keeps it, sends it again over her
    /// marker, and every device has it back.
    func testMemberDeleteWithoutPermissionIsUndone() async throws {
        let h = try await household()
        try delete("transaction_", try local(h, "transaction_", h.fixture.sharedTransaction, on: h.memberDevice), on: h.memberDevice)
        try await round(h)
        for device in [h.adminMac, h.memberDevice, h.adminPhone] {
            XCTAssertNotNil(try h.localId("transaction_", uuid: try h.uuid("transaction_", h.fixture.sharedTransaction), on: device))
        }
        XCTAssertEqual(try reverts(h), ["Reverted a delete by B: no permission for Budget & accounts"])
        let server = try await serverPayload(h, try h.uuid("transaction_", h.fixture.sharedTransaction))
        XCTAssertNil(server?.deleted, "the record is back on the server")
        XCTAssertEqual(server?.resent, true)
    }

    /// She deletes a document link (Documents: hers to edit): it goes everywhere.
    func testMemberDeleteWithPermissionApplies() async throws {
        let h = try await household()
        let link = try await householdLink(h)
        let uuid = try h.uuid("documentLink", link)
        try delete("documentLink", try local(h, "documentLink", link, on: h.memberDevice), on: h.memberDevice)
        try await round(h)
        for device in [h.adminMac, h.memberDevice, h.adminPhone] {
            XCTAssertNil(try h.localId("documentLink", uuid: uuid, on: device))
        }
        XCTAssertEqual(try reverts(h), [])
        let deletedBy: String? = try await h.adminMac.db.read { db in
            try String.fetchOne(db, sql: "SELECT deletedBy FROM syncTombstone WHERE uuid = ?", arguments: [uuid])
        }
        let memberUser = try await h.adminMac.db.read { db in
            try SyncRecordStore.uuid(for: "appUser", localId: try Int64.fetchOne(db, sql: "SELECT id FROM appUser WHERE personId = ?",
                                                                                  arguments: [h.fixture.personB])!, db: db)
        }
        XCTAssertEqual(deletedBy, memberUser, "the delete is stored as hers")
    }

    /// A hard deletion in the household (no writer: an older build, or a modified client): the Mac sends the record
    /// again, and logs it.
    func testBareHardDeleteFromAnotherDeviceIsUndone() async throws {
        let h = try await household()
        let uuid = try h.uuid("transaction_", h.fixture.sharedTransaction)
        // The Mac has pulled before (a first, full fetch lists no deletions: it would only send missing records again).
        try await h.adminMac.engine.pull()
        try await h.cloud.session(as: TwoPersonHousehold.memberICloudUser).delete([uuid], zone: SyncZones.household)
        try await h.adminMac.engine.syncNow()
        try await h.adminPhone.engine.pull()
        XCTAssertNotNil(try h.localId("transaction_", uuid: uuid, on: h.adminMac))
        XCTAssertNotNil(try h.localId("transaction_", uuid: uuid, on: h.adminPhone), "back on the phone")
        let server = try await serverPayload(h, uuid)
        XCTAssertEqual(server?.resent, true, "sent again")
        XCTAssertEqual(try reverts(h), ["Reverted a delete by someone not in this household: no permission for Budget & accounts"])
    }

    /// The Mac's own hard delete (sent by an older build) coming back on a pull: kept deleted, nothing sent, nothing logged.
    func testOwnHardDeleteSeenOnPullIsKept() async throws {
        let h = try await household()
        let uuid = try h.uuid("transaction_", h.fixture.sharedTransaction)
        try delete("transaction_", h.fixture.sharedTransaction, on: h.adminMac)
        try await h.adminMac.db.write { db in try db.execute(sql: "DELETE FROM syncPending WHERE uuid = ?", arguments: [uuid]) }
        try await h.cloud.delete([uuid], zone: SyncZones.household)
        try await h.adminMac.engine.syncNow()
        XCTAssertNil(try h.localId("transaction_", uuid: uuid, on: h.adminMac))
        let onServer = try await h.cloud.fetch(uuid, zone: SyncZones.household)
        XCTAssertNil(onServer, "not sent again")
        XCTAssertEqual(try reverts(h), [])
    }

    /// Review Focus 3: the admin's other Mac deletes in the household. Its marker is the admin's: never undone.
    func testSecondAdminMacDeleteIsNotUndone() async throws {
        let h = try await household()
        try await h.adminMac2.engine.pull()
        let uuid = try h.uuid("transaction_", h.fixture.sharedTransaction)
        try delete("transaction_", try local(h, "transaction_", h.fixture.sharedTransaction, on: h.adminMac2), on: h.adminMac2)
        try await h.adminMac2.engine.pushPending()
        try await h.adminMac.engine.syncNow()
        try await h.adminPhone.engine.pull()
        for device in [h.adminMac, h.adminMac2, h.adminPhone] {
            XCTAssertNil(try h.localId("transaction_", uuid: uuid, on: device))
        }
        XCTAssertEqual(try reverts(h), [])
        let server = try await serverPayload(h, uuid)
        XCTAssertEqual(server?.deleted, true, "the marker stands")
    }

    // MARK: The marker

    /// A household delete is a save of a marker: sealed like any record, no fields, never a hard delete.
    func testHouseholdDeleteTravelsAsSealedMarker() async throws {
        let h = try await household()
        let uuid = try h.uuid("transaction_", h.fixture.sharedTransaction)
        try delete("transaction_", h.fixture.sharedTransaction, on: h.adminMac)
        try await h.adminMac.engine.pushPending()
        let fetched = try await h.cloud.fetch(uuid, zone: SyncZones.household)
        let server = try XCTUnwrap(fetched, "a marker, not a hard delete")
        XCTAssertEqual(Set(server.wire.encryptedFields.keys), [FieldSealing.sealedField, FieldSealing.keyIdField])
        XCTAssertEqual(server.wire.unencryptedFields, [:])
        XCTAssertEqual(server.wire.assets, [:])
        XCTAssertEqual(server.lastModifiedBy, TwoPersonHousehold.adminICloudUser)
        let opened = try await serverPayload(h, uuid)
        let payload = try XCTUnwrap(opened)
        XCTAssertEqual(payload.deleted, true)
        XCTAssertEqual(payload.fields, [:])
        XCTAssertEqual(payload.clocks, [:])
        let calls = await h.cloud.calls
        XCTAssertFalse(calls.contains { if case .delete(let names) = $0 { return names.contains(uuid) } else { return false } })
        XCTAssertEqual(try h.audit.householdViolations(router: h.adminRouter()), [])
        let pending = try await h.adminMac.db.read { db in try SyncChangeTracker.pending(db: db) }
        XCTAssertEqual(pending, [], "the delete is done")
    }

    /// Her device (and the admin's phone) drop the row on the marker, and remember it.
    func testMemberDeviceDropsRowOnDeletionMarker() async throws {
        let h = try await household()
        let uuid = try h.uuid("transaction_", h.fixture.sharedTransaction)
        try delete("transaction_", h.fixture.sharedTransaction, on: h.adminMac)
        try await h.syncAll()
        for device in [h.memberDevice, h.adminPhone] {
            XCTAssertNil(try h.localId("transaction_", uuid: uuid, on: device))
            let tombstone = try await device.db.read { db in try SyncTombstoneRow.fetchOne(db, key: uuid) }
            XCTAssertNotNil(tombstone, "a later stale copy stays out")
        }
    }

    /// A build from before markers (it doesn't know `deleted`) takes the marker as a move out of view: it drops the row.
    func testOlderBuildDropsRowOnDeletionMarker() async throws {
        let h = try await household()
        let uuid = try h.uuid("transaction_", h.fixture.sharedTransaction)
        var marker = SyncPayload.deletionMarker(uuid: uuid, tableName: "transaction_", zone: SyncZones.household)
        marker.deleted = nil
        try await h.adminPhone.db.write { db in
            _ = try SyncChangeTracker.readOnlyApply(db: db) { try SyncTranslator.incoming(marker, db: db, deviceUser: nil) }
        }
        XCTAssertNil(try h.localId("transaction_", uuid: uuid, on: h.adminPhone), "no ghost row")
    }
}
