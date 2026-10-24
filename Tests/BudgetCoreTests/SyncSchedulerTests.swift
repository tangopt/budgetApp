import XCTest
import GRDB
import os
@testable import BudgetCore

/// A `sleep` the test drives: every call is recorded and waits until the test fires its duration, or its task is
/// cancelled (then it throws `CancellationError`, as `Task.sleep` does).
final class ManualSleeper: Sendable {
    private struct State {
        var requested: [TimeInterval] = []
        var waiting: [UUID: (TimeInterval, CheckedContinuation<Void, Error>)] = [:]
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    /// Every duration asked for, in order (cancelled ones included).
    var requested: [TimeInterval] { state.withLock { $0.requested } }

    /// How many sleeps of `duration` are waiting now.
    func pending(_ duration: TimeInterval) -> Int {
        state.withLock { $0.waiting.values.filter { $0.0 == duration }.count }
    }

    func sleep(_ duration: TimeInterval) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let cancelled = Task.isCancelled
                state.withLock { state in
                    state.requested.append(duration)
                    if !cancelled { state.waiting[id] = (duration, continuation) }
                }
                if cancelled { continuation.resume(throwing: CancellationError()) }
            }
        } onCancel: {
            let waiter = state.withLock { $0.waiting.removeValue(forKey: id) }
            waiter?.1.resume(throwing: CancellationError())
        }
    }

    /// Wakes every sleep of `duration` waiting now.
    func fire(_ duration: TimeInterval) {
        let woken = state.withLock { state -> [CheckedContinuation<Void, Error>] in
            let ids = state.waiting.filter { $0.value.0 == duration }.map(\.key)
            return ids.compactMap { state.waiting.removeValue(forKey: $0)?.1 }
        }
        for continuation in woken { continuation.resume() }
    }
}

/// The scheduler's clock, moved by the test.
final class TestClock: Sendable {
    private let state: OSAllocatedUnfairLock<Date>
    init(_ start: Date) { state = OSAllocatedUnfairLock(initialState: start) }
    var now: Date { state.withLock { $0 } }
    func advance(_ seconds: TimeInterval) { state.withLock { $0 = $0.addingTimeInterval(seconds) } }
}

/// `FakeCloud` with scripted change-feed failures, and a change feed that can block until released or cancelled
/// (a slow network the app is backgrounded on).
actor ScriptedTransport: SyncTransport {
    let cloud: FakeCloud
    private var nextFailures: [SyncTransportError] = []
    private var alwaysFailing: SyncTransportError?
    private var blocking = false
    private var blocked: CheckedContinuation<Void, Error>?
    private(set) var changesCalls = 0
    private(set) var cancelledWhileBlocked = 0

    init(_ cloud: FakeCloud) { self.cloud = cloud }

    func failNextChanges(with error: SyncTransportError) { nextFailures.append(error) }
    func failChangesAlways(with error: SyncTransportError?) { alwaysFailing = error }
    func block() { blocking = true }
    func release() {
        blocking = false
        blocked?.resume()
        blocked = nil
    }
    var isBlocked: Bool { blocked != nil }

    private func cancelBlocked() {
        guard let blocked else { return }
        self.blocked = nil
        cancelledWhileBlocked += 1
        blocked.resume(throwing: CancellationError())
    }

    private func waitForRelease() async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    cancelledWhileBlocked += 1
                    continuation.resume(throwing: CancellationError())
                } else {
                    blocked = continuation
                }
            }
        } onCancel: {
            Task { await self.cancelBlocked() }
        }
    }

    func operationLimits() async -> SyncOperationLimits { await cloud.operationLimits() }
    func createZone(_ zone: String) async throws { try await cloud.createZone(zone) }
    func save(_ records: [SyncWireRecord], ifUnchanged: [String: Data], atomic: Bool) async throws -> [SaveResult] {
        try await cloud.save(records, ifUnchanged: ifUnchanged, atomic: atomic)
    }
    func changes(since token: Data?, zone: String) async throws -> SyncChanges {
        changesCalls += 1
        if !nextFailures.isEmpty { throw nextFailures.removeFirst() }
        if let alwaysFailing { throw alwaysFailing }
        if blocking { try await waitForRelease() }
        return try await cloud.changes(since: token, zone: zone)
    }
    func delete(_ recordNames: [String], zone: String) async throws { try await cloud.delete(recordNames, zone: zone) }
    func fetch(_ recordName: String, zone: String) async throws -> SyncServerRecord? { try await cloud.fetch(recordName, zone: zone) }
    func serverTime() async throws -> Date? { try await cloud.serverTime() }
}

/// Plan step 4 Task 1: the scheduler around `SyncEngineCore` (triggers, debounce, retry-after and backoff, waiting
/// for the household key, cancellation, the states the apps show). Synthetic data over `FakeCloud`, in-memory key
/// stores, a test clock and a sleep the test fires.
final class SyncSchedulerTests: XCTestCase {
    private let zone = SyncRecordStore.householdZone
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private var cloud: FakeCloud!
    private var keys: InMemorySyncKeyStore!
    private var clock: TestClock!
    private var sleeper: ManualSleeper!
    private var schedulers: [SyncScheduler] = []

    override func setUp() async throws {
        cloud = FakeCloud()
        keys = InMemorySyncKeyStore()
        clock = TestClock(start)
        sleeper = ManualSleeper()
    }

    override func tearDown() async throws {
        for scheduler in schedulers { await scheduler.stop() }
        schedulers = []
    }

    /// One device: its database, an engine over a scripted transport, and its scheduler (started).
    private struct Device {
        let manager: DatabaseManager
        let transport: ScriptedTransport
        let engine: SyncEngineCore
        let scheduler: SyncScheduler
        var queue: DatabaseQueue { manager.dbQueue }
    }

    private func device(_ user: String, keys: (any SyncKeyStore)? = nil) async throws -> Device {
        let manager = try DatabaseManager(path: nil)
        try manager.migrate()
        try await manager.dbQueue.write { db in try SyncChangeTracker.setWriter(user, db: db) }
        let transport = ScriptedTransport(cloud)
        let engine = SyncEngineCore(db: manager.dbQueue, transport: transport, device: SyncDevice(id: "device-\(user)", name: user),
                                    keyStore: keys ?? self.keys)
        let clock = self.clock!
        let sleeper = self.sleeper!
        let scheduler = SyncScheduler(engine: engine, db: manager.dbQueue, clock: { clock.now }, sleep: { try await sleeper.sleep($0) },
                                      pushDebounce: 5, periodic: 3600, keyWaitRetry: 300)
        schedulers.append(scheduler)
        await scheduler.start()
        return Device(manager: manager, transport: transport, engine: engine, scheduler: scheduler)
    }

    @discardableResult
    private func addAccount(_ queue: DatabaseQueue, _ name: String) throws -> Int64 {
        try queue.write { db in
            var account = Account(name: name, currency: .gbp, kind: .cash, trackingMode: .imported)
            try account.insert(db)
            return account.id!
        }
    }

    private func accounts(_ queue: DatabaseQueue) throws -> Int {
        try queue.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM account")! }
    }

    private func pending(_ queue: DatabaseQueue) throws -> [PendingChange] {
        try queue.read { db in try SyncChangeTracker.pending(db: db) }
    }

    private func token(_ queue: DatabaseQueue) throws -> Data? {
        try queue.read { db in try SyncEngineCore.token(zone: zone, db: db) }
    }

    /// Waits (in real time, briefly) until `condition` holds; fails instead of hanging.
    private func eventually(_ message: String, timeout: TimeInterval = 5, file: StaticString = #filePath, line: UInt = #line,
                            _ condition: () async throws -> Bool) async rethrows {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if try await condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("timed out: \(message)", file: file, line: line)
    }

    private func calls(since index: Int) async -> [FakeCloud.Call] {
        Array(await cloud.calls.dropFirst(index))
    }

    // MARK: Triggers

    func testLaunchPullsThenPushes() async throws {
        let phone = try await device("user-a")
        try addAccount(phone.queue, "Synthetic Launch")
        let status = await phone.scheduler.status
        XCTAssertEqual(status, .idle(lastSync: nil), "started, never synced")

        await phone.scheduler.requestSync(.launch)

        let calls = await cloud.calls
        let firstPull = try XCTUnwrap(calls.firstIndex { if case .changes = $0 { return true } else { return false } })
        let firstSave = try XCTUnwrap(calls.firstIndex { if case .save = $0 { return true } else { return false } })
        XCTAssertLessThan(firstPull, firstSave, "pull, then push")
        XCTAssertEqual(try pending(phone.queue), [])
        let after = await phone.scheduler.status
        XCTAssertEqual(after, .idle(lastSync: start))
    }

    func testLocalChangeIsDebouncedAndOnlyPushes() async throws {
        let mac = try await device("user-a")
        await mac.scheduler.requestSync(.launch)
        let mark = await cloud.calls.count

        try addAccount(mac.queue, "Synthetic One")
        await mac.scheduler.requestSync(.localChange)
        try addAccount(mac.queue, "Synthetic Two")
        await mac.scheduler.requestSync(.localChange)
        await mac.scheduler.requestSync(.localChange)

        // Each change restarts the debounce: three asked for, only the last one waits.
        try await eventually("three debounces, one waiting") {
            self.sleeper.requested.filter { $0 == 5 }.count == 3 && self.sleeper.pending(5) == 1
        }
        let early = await calls(since: mark)
        XCTAssertEqual(early, [], "nothing goes before the debounce")

        sleeper.fire(5)
        try await eventually("the debounced push") { try self.pending(mac.queue).isEmpty }
        let sent = await calls(since: mark)
        XCTAssertTrue(sent.contains { if case .save = $0 { return true } else { return false } })
        XCTAssertFalse(sent.contains { if case .changes = $0 { return true } else { return false } }, "a local change only pushes")
        try await eventually("idle again") { await mac.scheduler.status == .idle(lastSync: self.start) }
    }

    // MARK: Retry

    func testRetryAfterIsHonoured() async throws {
        let phone = try await device("user-a")
        await phone.transport.failNextChanges(with: .unavailable(retryAfter: 37))

        await phone.scheduler.requestSync(.launch)

        let status = await phone.scheduler.status
        XCTAssertEqual(status, .offline(since: start, retryAt: start.addingTimeInterval(37)))
        XCTAssertEqual(sleeper.pending(37), 1, "the next attempt at +37 s (more than the 30 s backoff)")
        // Nothing reaches the server before then: not a timer, not the app coming back, not a refresh.
        await phone.scheduler.requestSync(.periodic)
        await phone.scheduler.requestSync(.foreground)
        await phone.scheduler.requestSync(.userRefresh)
        await phone.scheduler.requestSync(.localChange)
        do {
            _ = try await phone.scheduler.syncNowAndWait()
            XCTFail("the server asked to wait")
        } catch SyncTransportError.unavailable {}
        let tried = await phone.transport.changesCalls
        XCTAssertEqual(tried, 1)
        XCTAssertEqual(sleeper.pending(5), 0, "no push queued behind the wait")

        clock.advance(37)
        sleeper.fire(37)
        try await eventually("the retry succeeds") { await phone.scheduler.status == .idle(lastSync: self.start.addingTimeInterval(37)) }
        let retried = await phone.transport.changesCalls
        XCTAssertEqual(retried, 2)
    }

    func testBackoffDoublesTo15Minutes() async throws {
        let phone = try await device("user-a")
        await phone.transport.failChangesAlways(with: .networkUnavailable)

        await phone.scheduler.requestSync(.launch)
        XCTAssertEqual(sleeper.pending(30), 1)
        var previous: TimeInterval = 30
        for next: TimeInterval in [60, 120, 240, 480, 900, 900] {
            sleeper.fire(previous)
            try await eventually("retry after \(next) s") { self.sleeper.pending(next) == 1 }
            previous = next
        }
        let status = await phone.scheduler.status
        XCTAssertEqual(status, .offline(since: start, retryAt: start.addingTimeInterval(900)), "offline since the first failure")
        XCTAssertEqual(sleeper.requested.filter { $0 != 3600 }, [30, 60, 120, 240, 480, 900, 900])

        // Back online: the backoff starts again from 30 s.
        await phone.transport.failChangesAlways(with: nil)
        sleeper.fire(900)
        try await eventually("back online") { await phone.scheduler.status == .idle(lastSync: self.start) }
        await phone.transport.failNextChanges(with: .networkUnavailable)
        await phone.scheduler.requestSync(.periodic)
        XCTAssertEqual(sleeper.pending(30), 1)
    }

    // MARK: Waiting for the household key

    func testKeyWaitBecomesWaitingStateAndRetriesOnTheSlowSchedule() async throws {
        let mac = try await device("user-a")
        try addAccount(mac.queue, "Synthetic Shared")
        await mac.scheduler.requestSync(.launch)

        // Device B: iCloud Keychain hasn't delivered the household key yet.
        let bKeys = InMemorySyncKeyStore()
        let phone = try await device("user-b", keys: bKeys)
        await phone.scheduler.requestSync(.launch)

        let status = await phone.scheduler.status
        XCTAssertEqual(status, .waitingForKey(since: start))
        XCTAssertEqual(sleeper.pending(300), 1, "retried on the slow schedule")
        XCTAssertEqual(try bKeys.allKeys(zone: zone).count, 0, "no second key created")
        let markers = await cloud.storedRecords().filter { $0.recordType == SyncZoneKeys.recordType }
        XCTAssertEqual(markers.count, 1)
        XCTAssertEqual(try accounts(phone.queue), 0)

        // The slow retry: still waiting, the same since, one more timer (no storm).
        clock.advance(300)
        sleeper.fire(300)
        try await eventually("the retry pulls again") { await phone.transport.changesCalls == 2 }
        try await eventually("the next slow retry") { self.sleeper.pending(300) == 1 }
        let still = await phone.scheduler.status
        XCTAssertEqual(still, .waitingForKey(since: start))
        XCTAssertEqual(sleeper.requested.filter { $0 == 300 }.count, 2)
        XCTAssertEqual(sleeper.requested.filter { $0 == 30 }.count, 0, "waiting isn't failing: no backoff")

        // The key arrives: synced at once.
        try bKeys.store(try XCTUnwrap(keys.key(zone: zone)), zone: zone)
        await phone.scheduler.requestSync(.keyMayHaveArrived)
        let synced = await phone.scheduler.status
        XCTAssertEqual(synced, .idle(lastSync: start.addingTimeInterval(300)))
        XCTAssertEqual(try accounts(phone.queue), 1)
        XCTAssertEqual(sleeper.pending(300), 0, "no more key retries")
    }

    // MARK: Cancellation

    func testCancelStopsBeforeTheNextOperation() async throws {
        let mac = try await device("user-a")
        try addAccount(mac.queue, "Synthetic First")
        await mac.scheduler.requestSync(.launch)
        let phone = try await device("user-b")
        await phone.scheduler.requestSync(.launch)
        XCTAssertEqual(try accounts(phone.queue), 1)
        try addAccount(mac.queue, "Synthetic Second")
        await mac.scheduler.requestSync(.userRefresh)

        let tokenBefore = try XCTUnwrap(try token(phone.queue))
        await phone.transport.block()
        let scheduler = phone.scheduler
        let outcome = Task { () -> Error? in
            do {
                _ = try await scheduler.syncNowAndWait()
                return nil
            } catch {
                return error
            }
        }
        try await eventually("the pull is in flight") { await phone.transport.isBlocked }
        let syncing = await phone.scheduler.status
        XCTAssertEqual(syncing, .syncing(.pulling))
        let mark = await cloud.calls.count

        await phone.scheduler.cancel()
        try await eventually("the cancellation reaches the transport", timeout: 2) { await phone.transport.cancelledWhileBlocked == 1 }
        await phone.transport.release()  // (only matters when the cancellation didn't reach it)

        let error = await outcome.value
        XCTAssertTrue(error is CancellationError, "\(String(describing: error))")
        let after = await calls(since: mark)
        XCTAssertEqual(after, [], "nothing after the cancelled operation")
        XCTAssertEqual(try token(phone.queue), tokenBefore, "the token is unchanged")
        XCTAssertEqual(try accounts(phone.queue), 1, "nothing applied")
        let status = await phone.scheduler.status
        XCTAssertEqual(status, .idle(lastSync: start))

        // The next sync takes it from the same token.
        _ = try await phone.scheduler.syncNowAndWait()
        XCTAssertEqual(try accounts(phone.queue), 2)
    }

    // MARK: States that wait for the person

    func testNotAuthenticatedWaitsForForeground() async throws {
        let phone = try await device("user-a")
        await phone.transport.failNextChanges(with: .notAuthenticated)

        await phone.scheduler.requestSync(.launch)
        let status = await phone.scheduler.status
        XCTAssertEqual(status, .unavailable(.noICloudAccount))
        XCTAssertEqual(sleeper.requested.filter { $0 != 3600 }, [], "no retry timer")

        await phone.scheduler.requestSync(.periodic)
        await phone.scheduler.requestSync(.localChange)
        await phone.scheduler.requestSync(.keyMayHaveArrived)
        let tried = await phone.transport.changesCalls
        XCTAssertEqual(tried, 1, "nothing tried until the app comes back")
        XCTAssertEqual(sleeper.requested.filter { $0 != 3600 }, [])

        await phone.scheduler.requestSync(.foreground)
        let back = await phone.scheduler.status
        XCTAssertEqual(back, .idle(lastSync: start))

        // A full iCloud storage waits the same way.
        await phone.transport.failNextChanges(with: .quotaExceeded)
        await phone.scheduler.requestSync(.periodic)
        let full = await phone.scheduler.status
        XCTAssertEqual(full, .unavailable(.quotaExceeded))
        await phone.scheduler.requestSync(.periodic)
        let calls = await phone.transport.changesCalls
        XCTAssertEqual(calls, 3)
    }

    func testHeldRecordsAreNeedsAttention() async throws {
        let mac = try await device("user-a")
        let ids = try await mac.queue.write { db in try FiledYearSyncCheckTests.fixture(db) }
        await mac.scheduler.requestSync(.launch)
        let phone = try await device("user-b")
        await phone.scheduler.requestSync(.launch)
        let synced = await phone.scheduler.status
        XCTAssertEqual(synced, .idle(lastSync: start))

        // A change that would move the filed 2024/25 return arrives: held.
        try await mac.queue.write { db in
            try db.execute(sql: "UPDATE transaction_ SET amountMinorUnits = -20000 WHERE id = ?", arguments: [ids["plumber"]!])
        }
        await mac.scheduler.requestSync(.userRefresh)
        clock.advance(60)
        await phone.scheduler.requestSync(.periodic)
        let held = await phone.scheduler.status
        XCTAssertEqual(held, .needsAttention(held: 1, lastSync: start.addingTimeInterval(60)))

        // Still held on the next sync, though that pull brings nothing new.
        clock.advance(60)
        await phone.scheduler.requestSync(.periodic)
        let still = await phone.scheduler.status
        XCTAssertEqual(still, .needsAttention(held: 1, lastSync: start.addingTimeInterval(120)))
    }

    // MARK: Status stream

    func testStatusStreamStartsWithTheCurrentStatusAndYieldsEachChange() async throws {
        let phone = try await device("user-a")
        var iterator = await phone.scheduler.statusStream().makeAsyncIterator()
        let first = await iterator.next()
        XCTAssertEqual(first, .idle(lastSync: nil))
        await phone.scheduler.requestSync(.launch)
        var seen: [SyncStatus] = []
        for _ in 0..<3 { if let next = await iterator.next() { seen.append(next) } }
        XCTAssertEqual(seen, [.syncing(.pulling), .syncing(.pushing), .idle(lastSync: start)])
        await phone.scheduler.stop()
        let off = await iterator.next()
        XCTAssertEqual(off, .off)
    }
}
