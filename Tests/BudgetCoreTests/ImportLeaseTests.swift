import XCTest
@testable import BudgetCore

/// The import lease (sync spec §5.2): one import (or Undo) confirmed at a time per household, by a
/// compare-and-set on one lease record, expiring 30 minutes after it was last taken or renewed.
final class ImportLeaseTests: XCTestCase {
    private let mac = SyncDevice(id: "device-mac", name: "Mac")
    private let ipad = SyncDevice(id: "device-ipad", name: "iPad")
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    func testLeaseCompareAndSet() async throws {
        let store = InMemoryLeaseStore()
        // Both devices read "no lease" before either writes: the Mac's write lands first, so the iPad's
        // write, made against what it read, is refused by the store, and the iPad sees the Mac's lease.
        let racing = StaleFirstRead(store, stale: nil)
        let lease = try await ImportLease.acquire(device: mac, now: start, transport: store)
        do {
            _ = try await ImportLease.acquire(device: ipad, now: start, transport: racing)
            XCTFail("both devices got the lease")
        } catch let error as ImportLeaseError {
            XCTAssertEqual(error, .heldBy(deviceName: "Mac", until: start.addingTimeInterval(30 * 60)))
        }
        let saves = await racing.refusedSaves
        XCTAssertEqual(saves, 1, "the iPad's write was a compare-and-set that failed")
        let held = try await ImportLease.holder(now: start, transport: store)
        XCTAssertEqual(held?.holderId, mac.id)
        XCTAssertEqual(held?.holderName, "Mac")

        // The store itself: a write against a stale tag is refused and changes nothing.
        do {
            _ = try await store.saveLease(ImportLeaseRecord(holderId: ipad.id, holderName: ipad.name, takenAt: start, expiresAt: start),
                                          ifTag: "stale")
            XCTFail("a stale write landed")
        } catch LeaseStoreError.changed {}
        let current = try await store.currentLease()
        XCTAssertEqual(current?.tag, lease.tag)
    }

    func testLeaseRefusedWhileHeld() async throws {
        let store = InMemoryLeaseStore()
        let lease = try await ImportLease.acquire(device: mac, now: start, transport: store)
        XCTAssertEqual(lease.record.expiresAt, start.addingTimeInterval(ImportLease.duration))
        do {
            _ = try await ImportLease.acquire(device: ipad, now: start.addingTimeInterval(29 * 60), transport: store)
            XCTFail("acquired while held")
        } catch let error as ImportLeaseError {
            XCTAssertEqual(error, .heldBy(deviceName: "Mac", until: lease.record.expiresAt))
            XCTAssertEqual(error.message, "Importing on Mac")
        }
        // Reading and review need no lease; the holder may take it again (after a relaunch, say).
        let again = try await ImportLease.acquire(device: mac, now: start.addingTimeInterval(60), transport: store)
        XCTAssertEqual(again.record.holderId, mac.id)

        // Released, it is free at once.
        try await ImportLease.release(again, transport: store)
        let held = try await ImportLease.holder(now: start.addingTimeInterval(61), transport: store)
        XCTAssertNil(held)
        let taken = try await ImportLease.acquire(device: ipad, now: start.addingTimeInterval(62), transport: store)
        XCTAssertEqual(taken.record.holderId, ipad.id)
    }

    func testLeaseExpires() async throws {
        let store = InMemoryLeaseStore()
        let lease = try await ImportLease.acquire(device: mac, now: start, transport: store)
        // Renewed at 20 minutes: held until 50.
        let renewed = try await ImportLease.renew(lease, now: start.addingTimeInterval(20 * 60), transport: store)
        XCTAssertEqual(renewed.record.expiresAt, start.addingTimeInterval(50 * 60))
        do {
            _ = try await ImportLease.acquire(device: ipad, now: start.addingTimeInterval(49 * 60), transport: store)
            XCTFail("acquired before expiry")
        } catch ImportLeaseError.heldBy {}

        // 30 minutes without renewal, plus the allowance for clocks a little apart: anyone may take it.
        let stillHeld = try await ImportLease.holder(now: start.addingTimeInterval(51 * 60), transport: store)
        XCTAssertEqual(stillHeld?.holderId, mac.id, "within the clock allowance")
        let expired = try await ImportLease.holder(now: start.addingTimeInterval(52 * 60), transport: store)
        XCTAssertNil(expired)
        let taken = try await ImportLease.acquire(device: ipad, now: start.addingTimeInterval(52 * 60), transport: store)
        XCTAssertEqual(taken.record.holderId, ipad.id)

        // The Mac's old lease is lost: renewing it fails, and releasing it leaves the iPad's alone.
        do {
            _ = try await ImportLease.renew(renewed, now: start.addingTimeInterval(53 * 60), transport: store)
            XCTFail("renewed a lease another device took")
        } catch let error as ImportLeaseError {
            XCTAssertEqual(error, .lost)
        }
        try await ImportLease.release(renewed, transport: store)
        let held = try await ImportLease.holder(now: start.addingTimeInterval(54 * 60), transport: store)
        XCTAssertEqual(held?.holderId, ipad.id)
    }

    func testAFastClockCannotTakeALeaseEarly() async throws {
        // The server's clock is the truth; the iPad's runs 10 minutes fast.
        let server = Clock(start)
        let store = InMemoryLeaseStore(clock: { server.now })
        _ = try await ImportLease.acquire(device: mac, now: server.now, transport: store)
        server.advance(25 * 60)
        let fast = server.now.addingTimeInterval(10 * 60)
        do {
            _ = try await ImportLease.acquire(device: ipad, now: fast, transport: store)
            XCTFail("a fast clock took the lease 5 minutes early")
        } catch ImportLeaseError.heldBy {}
        server.advance(5 * 60 + 1)
        let taken = try await ImportLease.acquire(device: ipad, now: server.now.addingTimeInterval(10 * 60), transport: store)
        XCTAssertEqual(taken.record.holderId, ipad.id, "expired by the server's clock")

        // Without the server's clock, a clock a minute fast is covered by the allowance.
        let plain = InMemoryLeaseStore()
        let lease = try await ImportLease.acquire(device: mac, now: start, transport: plain)
        do {
            _ = try await ImportLease.acquire(device: ipad, now: lease.record.expiresAt.addingTimeInterval(60), transport: plain)
            XCTFail("taken within the allowance")
        } catch ImportLeaseError.heldBy {}
    }

    func testAcquireDecidesOnceMoreAfterLosingEveryRace() async throws {
        // The Mac's own expired lease, and every compare-and-set of the retries lost to churn: the last read
        // still shows a lease the Mac may take, so it takes it rather than reporting itself as the holder.
        let store = InMemoryLeaseStore()
        _ = try await ImportLease.acquire(device: mac, now: start, transport: store)
        let churning = LosesSaves(store, losses: 5)
        let lease = try await ImportLease.acquire(device: mac, now: start.addingTimeInterval(40 * 60), transport: churning)
        XCTAssertEqual(lease.record.holderId, mac.id)
        XCTAssertEqual(lease.record.expiresAt, start.addingTimeInterval(70 * 60))
    }

    func testAnExpiredLeaseNobodyTookCanStillBeRenewed() async throws {
        let store = InMemoryLeaseStore()
        let lease = try await ImportLease.acquire(device: mac, now: start, transport: store)
        let renewed = try await ImportLease.renew(lease, now: start.addingTimeInterval(45 * 60), transport: store)
        XCTAssertEqual(renewed.record.expiresAt, start.addingTimeInterval(75 * 60))
    }
}

/// A store whose first read returns what another device read before a write landed: the next write
/// is then made against a stale state, as when two devices race.
private actor StaleFirstRead: LeaseStore {
    private let store: InMemoryLeaseStore
    private var stale: StoredLease??
    private(set) var refusedSaves = 0

    init(_ store: InMemoryLeaseStore, stale: StoredLease?) {
        self.store = store
        self.stale = .some(stale)
    }

    func currentLease() async throws -> StoredLease? {
        if let first = stale {
            stale = nil
            return first
        }
        return try await store.currentLease()
    }

    func saveLease(_ record: ImportLeaseRecord, ifTag tag: String?) async throws -> StoredLease {
        do {
            return try await store.saveLease(record, ifTag: tag)
        } catch {
            refusedSaves += 1
            throw error
        }
    }

    func deleteLease(ifTag tag: String) async throws {
        try await store.deleteLease(ifTag: tag)
    }
}

/// The server's clock in a test.
private final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    init(_ start: Date) { current = start }
    var now: Date { lock.withLock { current } }
    func advance(_ seconds: TimeInterval) { lock.withLock { current = current.addingTimeInterval(seconds) } }
}

/// A store whose first `losses` writes lose a race (another write landed first).
private actor LosesSaves: LeaseStore {
    private let store: InMemoryLeaseStore
    private var losses: Int

    init(_ store: InMemoryLeaseStore, losses: Int) {
        self.store = store
        self.losses = losses
    }

    func currentLease() async throws -> StoredLease? { try await store.currentLease() }

    func saveLease(_ record: ImportLeaseRecord, ifTag tag: String?) async throws -> StoredLease {
        if losses > 0 {
            losses -= 1
            throw LeaseStoreError.changed
        }
        return try await store.saveLease(record, ifTag: tag)
    }

    func deleteLease(ifTag tag: String) async throws { try await store.deleteLease(ifTag: tag) }
}
