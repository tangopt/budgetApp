import XCTest
import GRDB
import CryptoKit
@testable import BudgetCore

/// `--sync-demo-reset` and `--print-demo-key` (plan step 4 Task 13): the Mac's demo tools. The reset deletes the
/// demo zone, removes the key the earlier demo runs kept under the real key-store scope, and forgets the zone here
/// so the next `--sync-demo` uploads everything again under a demo-scope key. Synthetic data, `FakeCloud` and
/// in-memory key stores only.
final class SyncDemoResetTests: XCTestCase {
    private let zone = SyncRecordStore.householdZone

    /// A stand-in for the real scope's Keychain items: records what the reset removes.
    private final class RemovableKeys: @unchecked Sendable {
        let store = InMemorySyncKeyStore()
        private let lock = NSLock()
        private var _removed: [String] = []
        var removed: [String] { lock.withLock { _removed } }

        func remove(_ id: String) throws -> Bool {
            let held = try store.allKeys(zone: SyncRecordStore.householdZone)[id] != nil
            lock.withLock { _removed.append(id) }
            return held
        }
    }

    private func addAccount(_ device: SyncEngineTestDevice, _ name: String) throws {
        try device.write { db in
            var account = Account(name: name, currency: .gbp, kind: .cash, trackingMode: .imported)
            try account.insert(db)
        }
    }

    // MARK: Refusals

    func testExtraDemoArgumentsNeedTheSyncDemoLaunch() {
        let allowed = SyncActivation.Decision(allowed: true, reason: nil)
        XCTAssertNil(SyncDemoReset.refusal(arguments: ["Mango"], decision: allowed), "no demo argument: nothing to refuse")
        XCTAssertNil(SyncDemoReset.refusal(arguments: ["Mango", "--sync-demo", "--sync-demo-reset"], decision: allowed))
        XCTAssertNil(SyncDemoReset.refusal(arguments: ["Mango", "--sync-demo", "--print-demo-key"], decision: allowed))

        let alone = SyncDemoReset.refusal(arguments: ["Mango", "--sync-demo-reset"], decision: allowed)
        XCTAssertEqual(alone, "--sync-demo-reset works only together with --sync-demo, on the demo database.")
        XCTAssertNotNil(SyncDemoReset.refusal(arguments: ["Mango", "--print-demo-key"], decision: allowed))
        XCTAssertNotNil(SyncDemoReset.refusal(arguments: ["Mango", "--sync-demo-reset", "--print-demo-key", "--sync-demo"],
                                              decision: allowed), "reset and print are separate launches")

        let refused = SyncActivation.Decision(allowed: false, reason: "--sync-demo works only in a Debug build; this build syncs nothing.")
        XCTAssertEqual(SyncDemoReset.refusal(arguments: ["Mango", "--sync-demo", "--sync-demo-reset"], decision: refused), refused.reason)
        XCTAssertEqual(SyncDemoReset.refusal(arguments: ["Mango", "--sync-demo", "--print-demo-key"], decision: refused), refused.reason)
    }

    func testRealDatabaseLaunchRefusesTheReset() throws {
        // Nothing at BUDGET_DB_PATH, a non-demo file, a Release build: SyncActivation's refusals carry through.
        let arguments = ["Mango", "--sync-demo", "--sync-demo-reset"]
        let release = SyncActivation.decision(databasePath: "/nonexistent/demo.sqlite", arguments: arguments, isDebug: false,
                                              hasCloudKitEntitlement: true)
        XCTAssertNotNil(SyncDemoReset.refusal(arguments: arguments, decision: release))
        let noFile = SyncActivation.decision(databasePath: "/nonexistent/demo.sqlite", arguments: arguments, isDebug: true,
                                             hasCloudKitEntitlement: true)
        XCTAssertNotNil(SyncDemoReset.refusal(arguments: arguments, decision: noFile))
    }

    // MARK: Reset

    func testResetDeletesTheZoneRemovesTheRealScopeKeyAndUploadsAgainUnderADemoKey() async throws {
        let cloud = FakeCloud()
        // The earlier demo runs: the household key kept under the real scope.
        let realScope = RemovableKeys()
        let mac = try SyncEngineTestDevice("user-a", name: "Demo Mac", cloud: cloud, keys: realScope.store)
        try addAccount(mac, "Synthetic Account Kappa")
        try addAccount(mac, "Synthetic Account Lambda")
        try await mac.engine.syncNow()
        let oldRecord = await cloud.record(named: SyncZoneKeys.recordName(zone: zone))
        let oldMarker = try XCTUnwrap(oldRecord)
        let oldKeyId = try SyncZoneKeys.marker(from: oldMarker.wire).keyId

        let outcome = try await SyncDemoReset.run(
            transport: cloud,
            deleteZone: { zone in await cloud.deleteZone(zone) },
            removeRealScopeKey: { id in try realScope.remove(id) },
            db: mac.queue, now: Date())

        XCTAssertEqual(outcome.keyIds, [oldKeyId])
        XCTAssertEqual(outcome.removedRealScopeKeys, [oldKeyId])
        XCTAssertEqual(realScope.removed, [oldKeyId])
        let left = await cloud.storedRecords()
        XCTAssertTrue(left.isEmpty, "the zone and everything in it is gone")
        try mac.read { db in
            XCTAssertNil(try SyncZoneKeys.local(zone: zone, db: db), "the old marker is forgotten here")
            XCTAssertNil(try SyncEngineCore.token(zone: zone, db: db))
            XCTAssertFalse(try SyncEngineCore.zoneReady(zone, db: db))
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM syncRecord WHERE zone = ? AND systemFields IS NOT NULL",
                                            arguments: [zone]), 0)
            let pendingAccounts = try SyncChangeTracker.pending(db: db).filter { $0.table == "account" }
            XCTAssertEqual(pendingAccounts.count, 2, "every record goes up again")
        }

        // The next --sync-demo: a demo-scope key store, empty.
        let demoScope = InMemorySyncKeyStore()
        let again = SyncEngineCore(db: mac.queue, transport: cloud, device: mac.device, keyStore: demoScope)
        try await again.syncNow()
        let newRecord = await cloud.record(named: SyncZoneKeys.recordName(zone: zone))
        let newMarker = try XCTUnwrap(newRecord)
        let newKeyId = try SyncZoneKeys.marker(from: newMarker.wire).keyId
        XCTAssertNotEqual(newKeyId, oldKeyId, "the demo never reuses the real-scope key")
        XCTAssertNotNil(try demoScope.allKeys(zone: zone)[newKeyId])
        let accounts = await cloud.storedRecords().filter { $0.recordType == "account" }
        XCTAssertEqual(accounts.count, 2)
        XCTAssertEqual(Set(accounts.compactMap { FieldSealing.keyId(of: $0) }), [newKeyId])
    }

    func testResetOfAZoneThatIsAlreadyGoneStillForgetsItHereAndRemovesTheLocalMarkersKey() async throws {
        let cloud = FakeCloud()
        let realScope = RemovableKeys()
        let mac = try SyncEngineTestDevice("user-a", name: "Demo Mac", cloud: cloud, keys: realScope.store)
        try addAccount(mac, "Synthetic Account Mu")
        try await mac.engine.syncNow()
        let keyId = try XCTUnwrap(try mac.read { db in try SyncZoneKeys.local(zone: zone, db: db) }?.marker.keyId)
        await cloud.deleteZone(zone)

        let outcome = try await SyncDemoReset.run(
            transport: cloud,
            deleteZone: { _ in throw SyncTransportError.zoneNotFound("household") },
            removeRealScopeKey: { id in try realScope.remove(id) },
            db: mac.queue, now: Date())

        XCTAssertEqual(outcome.keyIds, [keyId])
        XCTAssertFalse(outcome.zoneDeleted)
        XCTAssertEqual(realScope.removed, [keyId])
        XCTAssertNil(try mac.read { db in try SyncZoneKeys.local(zone: zone, db: db) })
    }

    func testAFailedZoneDeletionChangesNothingElse() async throws {
        let cloud = FakeCloud()
        let realScope = RemovableKeys()
        let mac = try SyncEngineTestDevice("user-a", name: "Demo Mac", cloud: cloud, keys: realScope.store)
        try addAccount(mac, "Synthetic Account Nu")
        try await mac.engine.syncNow()

        do {
            _ = try await SyncDemoReset.run(
                transport: cloud,
                deleteZone: { _ in throw SyncTransportError.networkUnavailable },
                removeRealScopeKey: { id in try realScope.remove(id) },
                db: mac.queue, now: Date())
            XCTFail("expected the deletion's error")
        } catch SyncTransportError.networkUnavailable {}
        XCTAssertEqual(realScope.removed, [])
        XCTAssertNotNil(try mac.read { db in try SyncZoneKeys.local(zone: zone, db: db) })
        XCTAssertNotNil(try mac.read { db in try SyncEngineCore.token(zone: zone, db: db) })
    }

    // MARK: Printing the demo key

    func testDemoKeyIsPrintedOnlyOnceTheMarkerIsOnTheServer() async throws {
        let cloud = FakeCloud()
        let demoScope = InMemorySyncKeyStore()
        let mac = try SyncEngineTestDevice("user-a", name: "Demo Mac", cloud: cloud, keys: demoScope)
        XCTAssertNil(try DemoHouseholdKey.confirmedKeyHex(db: mac.queue, keyStore: demoScope), "nothing pushed yet")

        try addAccount(mac, "Synthetic Account Xi")
        try await mac.engine.syncNow()
        let hex = try XCTUnwrap(try DemoHouseholdKey.confirmedKeyHex(db: mac.queue, keyStore: demoScope))
        XCTAssertEqual(hex.count, 64)
        XCTAssertTrue(hex.allSatisfy { $0.isHexDigit && !$0.isUppercase })
        let parsed = try XCTUnwrap(DemoHouseholdKey.parse(hex))
        let keyId = try XCTUnwrap(try mac.read { db in try SyncZoneKeys.local(zone: zone, db: db) }?.marker.keyId)
        XCTAssertEqual(DocumentCrypto.zoneKeyId(parsed), keyId, "the key the marker names, round-tripping through parse")

        // A store that doesn't hold the marker's key (another scope) prints nothing.
        XCTAssertNil(try DemoHouseholdKey.confirmedKeyHex(db: mac.queue, keyStore: InMemorySyncKeyStore()))
    }

    func testHexRoundTrips() throws {
        let key = SymmetricKey(size: .bits256)
        let hex = DemoHouseholdKey.hex(key)
        let back = try XCTUnwrap(DemoHouseholdKey.parse(hex))
        XCTAssertEqual(back.withUnsafeBytes { Data($0) }, key.withUnsafeBytes { Data($0) })
    }
}
