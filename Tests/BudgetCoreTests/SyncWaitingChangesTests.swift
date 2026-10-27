import XCTest
import GRDB
@testable import BudgetCore
import TestSupport

/// Step 10 Task 5: the sidebar's "N changes waiting" counts this device's unsent changes in the zones it pushes to.
final class SyncWaitingChangesTests: XCTestCase {
    private func count(_ db: DatabaseQueue, _ mode: SyncWriteMode) throws -> Int {
        try db.read { db in try SyncWaitingChanges.count(db: db, mode: mode) }
    }

    private func edit(_ db: DatabaseQueue, transaction id: Int64) throws {
        try db.write { db in try db.execute(sql: "UPDATE transaction_ SET note = 'iPad' WHERE id = ?", arguments: [id]) }
    }

    func testCountsOnlyTheDevicesPushZones() async throws {
        let h = try TwoPersonHousehold.make()
        try await h.syncAll()
        try await h.adminTablet.engine.pull()
        let household = SyncWriteMode.device(zones: [SyncZones.household])
        let privateOnly = SyncWriteMode.device(zones: [h.fixture.privateZone])
        let tablet = h.adminTablet.db
        XCTAssertEqual(try count(tablet, household), 0, "all synced")

        let uuid = try h.uuid("transaction_", h.fixture.sharedTransaction)
        try edit(tablet, transaction: try XCTUnwrap(h.localId("transaction_", uuid: uuid, on: h.adminTablet)))

        XCTAssertEqual(try count(tablet, household), 1, "one household edit waits")
        XCTAssertEqual(try count(tablet, privateOnly), 0, "not in a zone it pushes to")
        XCTAssertEqual(try count(tablet, .readOnly), 0)

        _ = try await h.adminTablet.engine.pushPending()
        XCTAssertEqual(try count(tablet, household), 0, "taken")
    }
}
