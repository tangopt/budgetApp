import XCTest
import GRDB
@testable import BudgetCore

/// The phone's engine is read-only (plan step 4 Task 12 fix round 1, review M1): it pulls, and never writes to the
/// server: no zone creation, no saves, no deletes, no key marker, no lease. Synthetic data over `FakeCloud`.
final class ReadOnlySyncEngineTests: XCTestCase {
    private let zone = SyncRecordStore.householdZone

    private func database(_ user: String) async throws -> DatabaseQueue {
        let manager = try DatabaseManager(path: nil)
        try manager.migrate()
        try await manager.dbQueue.write { db in try SyncChangeTracker.setWriter(user, db: db) }
        return manager.dbQueue
    }

    private func addAccount(_ queue: DatabaseQueue, _ name: String) async throws {
        try await queue.write { db in
            var account = Account(name: name, currency: .gbp, kind: .cash, trackingMode: .imported)
            try account.insert(db)
        }
    }

    private static func writes(_ calls: [FakeCloud.Call]) -> [FakeCloud.Call] {
        calls.filter {
            switch $0 {
            case .createZone, .save, .delete: true
            case .changes, .fetch: false
            }
        }
    }

    /// Before the Mac has made the household zone: nothing is created, nothing is downloaded, no token is kept (the
    /// phone stays in its first download).
    func testAMissingZoneIsNotCreatedAndLeavesTheFirstDownloadPending() async throws {
        let cloud = FakeCloud(zones: [])
        let phone = try await database("user-b")
        let engine = SyncEngineCore(db: phone, transport: cloud, device: SyncDevice(id: "phone", name: "Phone"),
                                    keyStore: InMemorySyncKeyStore(), readOnly: true)

        let report = try await engine.syncNow()

        XCTAssertEqual(report.pull.received, 0)
        let calls = await cloud.calls
        XCTAssertEqual(Self.writes(calls), [], "no zone made, nothing sent")
        let pulled = try await phone.read { db in try SyncEngineCore.hasChangeToken(db: db) }
        XCTAssertFalse(pulled)
        // Asked again: still nothing written.
        _ = try await engine.syncNow()
        let again = await cloud.calls
        XCTAssertEqual(Self.writes(again), [])
    }

    /// With the household there: the phone pulls everything and sends nothing back, even a stray local edit; it
    /// makes no key of its own.
    func testItPullsAndNeverWrites() async throws {
        let cloud = FakeCloud()
        let keys = InMemorySyncKeyStore()
        let mac = try await database("user-a")
        try await addAccount(mac, "Synthetic Shared")
        _ = try await SyncEngineCore(db: mac, transport: cloud, device: SyncDevice(id: "mac", name: "Mac"), keyStore: keys).syncNow()
        let before = await cloud.calls.count

        let phone = try await database("user-b")
        try await addAccount(phone, "Synthetic Stray")  // never sent
        let phoneKeys = InMemorySyncKeyStore()
        try phoneKeys.store(try XCTUnwrap(keys.key(zone: zone)), zone: zone)
        let engine = SyncEngineCore(db: phone, transport: cloud, device: SyncDevice(id: "phone", name: "Phone"),
                                    keyStore: phoneKeys, readOnly: true)
        let report = try await engine.syncNow()

        XCTAssertGreaterThanOrEqual(report.pull.received, 1)
        XCTAssertEqual(report.push, SyncPushReport())
        let after = Array(await cloud.calls.dropFirst(before))
        XCTAssertEqual(Self.writes(after), [])
        let accounts = try await phone.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM account")! }
        XCTAssertEqual(accounts, 2)
        let pulled = try await phone.read { db in try SyncEngineCore.hasChangeToken(db: db) }
        XCTAssertTrue(pulled)
    }

    /// No household key yet: waiting, and no key is made here.
    func testWithoutTheKeyItWaitsAndMakesNoKey() async throws {
        let cloud = FakeCloud()
        let mac = try await database("user-a")
        try await addAccount(mac, "Synthetic Shared")
        _ = try await SyncEngineCore(db: mac, transport: cloud, device: SyncDevice(id: "mac", name: "Mac"),
                                     keyStore: InMemorySyncKeyStore()).syncNow()
        let phoneKeys = InMemorySyncKeyStore()
        let phone = try await database("user-b")
        let engine = SyncEngineCore(db: phone, transport: cloud, device: SyncDevice(id: "phone", name: "Phone"),
                                    keyStore: phoneKeys, readOnly: true)
        let report = try await engine.syncNow()
        XCTAssertGreaterThan(report.pull.waitingForKey, 0)
        XCTAssertEqual(try phoneKeys.allKeys(zone: zone).count, 0)
    }

    /// The import lease is never taken from a read-only engine.
    func testTheLeaseIsRefused() async throws {
        let engine = SyncEngineCore(db: try await database("user-b"), transport: FakeCloud(),
                                    device: SyncDevice(id: "phone", name: "Phone"), keyStore: InMemorySyncKeyStore(), readOnly: true)
        do {
            try await engine.acquireImportLease()
            XCTFail("a read-only engine took the lease")
        } catch {
            XCTAssertEqual(error as? SyncEngineCore.ReadOnlyError, .readOnly)
        }
    }
}
