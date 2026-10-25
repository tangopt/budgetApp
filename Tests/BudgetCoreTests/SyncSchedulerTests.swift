import XCTest
import GRDB
import os
@testable import BudgetCore
import TestSupport

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

/// A failure that is neither the transport's nor the key's (a database or file error, say).
struct BrokenDisk: LocalizedError {
    var errorDescription: String? { "the disk is unhappy" }
}

/// `FakeCloud` with scripted failures, and a change feed or saves that can block (after letting some through)
/// until released or cancelled (a slow network the app is backgrounded on).
actor ScriptedTransport: SyncTransport {
    let cloud: FakeCloud
    private var nextFailures: [any Error] = []
    private var alwaysFailing: (any Error)?
    private var nextFetchFailures: [SyncTransportError] = []
    /// Changes calls (or saves) still let through before the next one blocks; nil: none blocks.
    private var changesBeforeBlock: Int?
    private var savesBeforeBlock: Int?
    private var fetchesBeforeBlock: Int?
    private var blocked: CheckedContinuation<Void, Error>?
    private(set) var changesCalls = 0
    private(set) var saveCalls = 0
    private(set) var cancelledWhileBlocked = 0

    init(_ cloud: FakeCloud) { self.cloud = cloud }

    func failNextChanges(with error: any Error) { nextFailures.append(error) }
    func failChangesAlways(with error: (any Error)?) { alwaysFailing = error }
    func failNextFetch(with error: SyncTransportError) { nextFetchFailures.append(error) }
    func block() { changesBeforeBlock = 0 }
    func blockChanges(after count: Int) { changesBeforeBlock = count }
    func blockSaves(after count: Int) { savesBeforeBlock = count }
    func blockFetches(after count: Int) { fetchesBeforeBlock = count }
    func release() {
        changesBeforeBlock = nil
        savesBeforeBlock = nil
        fetchesBeforeBlock = nil
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
        saveCalls += 1
        if let left = savesBeforeBlock {
            if left == 0 { try await waitForRelease() } else { savesBeforeBlock = left - 1 }
        }
        return try await cloud.save(records, ifUnchanged: ifUnchanged, atomic: atomic)
    }
    func changes(since token: Data?, zone: String) async throws -> SyncChanges {
        changesCalls += 1
        if !nextFailures.isEmpty { throw nextFailures.removeFirst() }
        if let alwaysFailing { throw alwaysFailing }
        if let left = changesBeforeBlock {
            if left == 0 { try await waitForRelease() } else { changesBeforeBlock = left - 1 }
        }
        return try await cloud.changes(since: token, zone: zone)
    }
    func delete(_ recordNames: [String], zone: String) async throws { try await cloud.delete(recordNames, zone: zone) }
    func fetch(_ recordName: String, zone: String) async throws -> SyncServerRecord? {
        if !nextFetchFailures.isEmpty { throw nextFetchFailures.removeFirst() }
        if let left = fetchesBeforeBlock {
            if left == 0 { try await waitForRelease() } else { fetchesBeforeBlock = left - 1 }
        }
        return try await cloud.fetch(recordName, zone: zone)
    }
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

    private func device(_ user: String, keys: (any SyncKeyStore)? = nil, batchSize: Int = 200) async throws -> Device {
        let manager = try TestDatabase.migratedManager()
        try await manager.dbQueue.write { db in try SyncChangeTracker.setWriter(user, db: db) }
        let transport = ScriptedTransport(cloud)
        let engine = SyncEngineCore(db: manager.dbQueue, transport: transport, device: SyncDevice(id: "device-\(user)", name: user),
                                    keyStore: keys ?? self.keys, batchSize: batchSize)
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

    private func hasToken(_ queue: DatabaseQueue) throws -> Bool {
        try queue.read { db in try SyncEngineCore.hasChangeToken(db: db) }
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
        await eventually("three debounces, one waiting") {
            self.sleeper.requested.filter { $0 == 5 }.count == 3 && self.sleeper.pending(5) == 1
        }
        let early = await calls(since: mark)
        XCTAssertEqual(early, [], "nothing goes before the debounce")

        sleeper.fire(5)
        try await eventually("the debounced push") { try self.pending(mac.queue).isEmpty }
        let sent = await calls(since: mark)
        XCTAssertTrue(sent.contains { if case .save = $0 { return true } else { return false } })
        XCTAssertFalse(sent.contains { if case .changes = $0 { return true } else { return false } }, "a local change only pushes")
        await eventually("idle again") { await mac.scheduler.status == .idle(lastSync: self.start) }
    }

    // MARK: Retry

    func testRetryAfterIsHonoured() async throws {
        let phone = try await device("user-a")
        await phone.transport.failNextChanges(with: SyncTransportError.unavailable(retryAfter: 37))

        await phone.scheduler.requestSync(.launch)

        let status = await phone.scheduler.status
        XCTAssertEqual(status, .offline(since: start, retryAt: start.addingTimeInterval(37)))
        await eventually("the next attempt at +37 s (more than the 30 s backoff)") { self.sleeper.pending(37) == 1 }
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
        await eventually("the retry succeeds") { await phone.scheduler.status == .idle(lastSync: self.start.addingTimeInterval(37)) }
        let retried = await phone.transport.changesCalls
        XCTAssertEqual(retried, 2)
    }

    func testBackoffDoublesTo15Minutes() async throws {
        let phone = try await device("user-a")
        await phone.transport.failChangesAlways(with: SyncTransportError.networkUnavailable)

        await phone.scheduler.requestSync(.launch)
        await eventually("a 30 s timer armed") { self.sleeper.pending(30) == 1 }
        var previous: TimeInterval = 30
        for next: TimeInterval in [60, 120, 240, 480, 900, 900] {
            sleeper.fire(previous)
            await eventually("retry after \(next) s") { self.sleeper.pending(next) == 1 }
            previous = next
        }
        let status = await phone.scheduler.status
        XCTAssertEqual(status, .offline(since: start, retryAt: start.addingTimeInterval(900)), "offline since the first failure")
        XCTAssertEqual(sleeper.requested.filter { $0 != 3600 }, [30, 60, 120, 240, 480, 900, 900])

        // Back online: the backoff starts again from 30 s.
        await phone.transport.failChangesAlways(with: nil)
        sleeper.fire(900)
        await eventually("back online") { await phone.scheduler.status == .idle(lastSync: self.start) }
        await phone.transport.failNextChanges(with: SyncTransportError.networkUnavailable)
        await phone.scheduler.requestSync(.periodic)
        await eventually("a 30 s timer armed") { self.sleeper.pending(30) == 1 }
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
        await eventually("retried on the slow schedule") { self.sleeper.pending(300) == 1 }
        XCTAssertEqual(try bKeys.allKeys(zone: zone).count, 0, "no second key created")
        let markers = await cloud.storedRecords().filter { $0.recordType == SyncZoneKeys.recordType }
        XCTAssertEqual(markers.count, 1)
        XCTAssertEqual(try accounts(phone.queue), 0)

        // The slow retry: still waiting, the same since, one more timer (no storm).
        clock.advance(300)
        sleeper.fire(300)
        await eventually("the retry pulls again") { await phone.transport.changesCalls == 2 }
        await eventually("the next slow retry") { self.sleeper.pending(300) == 1 }
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
        await eventually("the pull is in flight") { await phone.transport.isBlocked }
        let syncing = await phone.scheduler.status
        XCTAssertEqual(syncing, .syncing(.pulling))
        let mark = await cloud.calls.count

        await phone.scheduler.cancel()
        await eventually("the cancellation reaches the transport", timeout: 2) { await phone.transport.cancelledWhileBlocked == 1 }
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
        await phone.transport.failNextChanges(with: SyncTransportError.notAuthenticated)

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
        await phone.transport.failNextChanges(with: SyncTransportError.quotaExceeded)
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

    // MARK: Fix round 1: re-arming, the person's triggers, the key fetch, failures

    func testStopThenStartWhileOfflineRearmsTheRemainingRetryAfter() async throws {
        let phone = try await device("user-a")
        await phone.transport.failNextChanges(with: SyncTransportError.unavailable(retryAfter: 37))
        await phone.scheduler.requestSync(.launch)
        await eventually("a 37 s timer armed") { self.sleeper.pending(37) == 1 }

        // Backgrounded (stopped), back 10 s later: the retry is armed again for what is left of the server's window.
        await phone.scheduler.stop()
        XCTAssertEqual(sleeper.pending(37), 0)
        clock.advance(10)
        await phone.scheduler.start()
        await eventually("re-armed for the remaining 27 s") { self.sleeper.pending(27) == 1 }
        let status = await phone.scheduler.status
        XCTAssertEqual(status, .offline(since: start, retryAt: start.addingTimeInterval(37)))

        clock.advance(27)
        sleeper.fire(27)
        await eventually("the re-armed retry succeeds") {
            await phone.scheduler.status == .idle(lastSync: self.start.addingTimeInterval(37))
        }
    }

    func testStopThenStartWhileWaitingForTheKeyRearmsTheSlowRetry() async throws {
        let mac = try await device("user-a")
        try addAccount(mac.queue, "Synthetic Shared")
        await mac.scheduler.requestSync(.launch)
        let phone = try await device("user-b", keys: InMemorySyncKeyStore())
        await phone.scheduler.requestSync(.launch)
        await eventually("a 300 s timer armed") { self.sleeper.pending(300) == 1 }

        await phone.scheduler.stop()
        XCTAssertEqual(sleeper.pending(300), 0)
        await phone.scheduler.start()
        await eventually("the key retry is armed again") { self.sleeper.pending(300) == 1 }
        let status = await phone.scheduler.status
        XCTAssertEqual(status, .waitingForKey(since: start))
    }

    func testAnOfflineStatusNeverShowsARetryTimeInThePast() async throws {
        let phone = try await device("user-a")
        await phone.transport.failNextChanges(with: SyncTransportError.networkUnavailable)
        await phone.scheduler.requestSync(.launch)
        await phone.scheduler.stop()
        clock.advance(120)
        await phone.scheduler.start()
        guard case .offline(let since, let retryAt) = await phone.scheduler.status else { return XCTFail("still offline") }
        XCTAssertEqual(since, start)
        if let retryAt { XCTAssertGreaterThanOrEqual(retryAt, clock.now) }
        await eventually("past due: armed to try again at once") { self.sleeper.pending(0) == 1 }
    }

    func testPullToRefreshSucceedsRightAfterANetworkFailure() async throws {
        let phone = try await device("user-a")
        await phone.transport.failNextChanges(with: SyncTransportError.networkUnavailable)
        await phone.scheduler.requestSync(.launch)
        let offline = await phone.scheduler.status
        XCTAssertEqual(offline, .offline(since: start, retryAt: start.addingTimeInterval(30)))

        // The backoff delays the automatic triggers only.
        await phone.scheduler.requestSync(.periodic)
        let tried = await phone.transport.changesCalls
        XCTAssertEqual(tried, 1)
        // The person's own refresh goes at once.
        let report = try await phone.scheduler.syncNowAndWait()
        XCTAssertEqual(report.pull.unreadable, 0)
        let back = await phone.scheduler.status
        XCTAssertEqual(back, .idle(lastSync: start))
        XCTAssertEqual(sleeper.pending(30), 0, "the backoff retry is dropped")

        // And coming back to the foreground, too.
        await phone.transport.failNextChanges(with: SyncTransportError.networkUnavailable)
        await phone.scheduler.requestSync(.periodic)
        await phone.scheduler.requestSync(.foreground)
        let calls = await phone.transport.changesCalls
        XCTAssertEqual(calls, 4)
        let again = await phone.scheduler.status
        XCTAssertEqual(again, .idle(lastSync: start))
    }

    func testAKeyFetchThatCantReachTheServerIsOfflineNotWaiting() async throws {
        let phone = try await device("user-a")
        try addAccount(phone.queue, "Synthetic Fetch")
        await phone.transport.failNextFetch(with: .unavailable(retryAfter: 40))

        await phone.scheduler.requestSync(.launch)

        let status = await phone.scheduler.status
        XCTAssertEqual(status, .offline(since: start, retryAt: start.addingTimeInterval(40)), "the server's retry-after, not the key wait")
        await eventually("a 40 s timer armed") { self.sleeper.pending(40) == 1 }
        XCTAssertEqual(sleeper.pending(300), 0)
        XCTAssertFalse(try pending(phone.queue).isEmpty, "nothing sent")
    }

    func testOtherFailuresStopSyncWithTheReasonRetryAndClearOnSuccess() async throws {
        let phone = try await device("user-a")
        await phone.transport.failNextChanges(with: BrokenDisk())

        await phone.scheduler.requestSync(.launch)
        let status = await phone.scheduler.status
        XCTAssertEqual(status, .failed(reason: "the disk is unhappy"))
        await eventually("retried with the backoff") { self.sleeper.pending(30) == 1 }

        sleeper.fire(30)
        await eventually("cleared by the next success") { await phone.scheduler.status == .idle(lastSync: self.start) }
    }

    // MARK: Fix round 1: cancellation at each boundary

    func testCancelBetweenPagesKeepsTheTokenAndAppliesNothing() async throws {
        let mac = try await device("user-a")
        await mac.scheduler.requestSync(.launch)
        let phone = try await device("user-b")
        await phone.scheduler.requestSync(.launch)
        let tokenBefore = try token(phone.queue)
        for name in ["Synthetic P1", "Synthetic P2", "Synthetic P3"] { try addAccount(mac.queue, name) }
        await mac.scheduler.requestSync(.userRefresh)
        await cloud.setPageSize(1)

        await phone.transport.blockChanges(after: 1)
        let scheduler = phone.scheduler
        let outcome = Task { () -> Error? in
            do { _ = try await scheduler.syncNowAndWait(); return nil } catch { return error }
        }
        await eventually("blocked on the second page") { await phone.transport.isBlocked }
        let mark = await cloud.calls.count
        await phone.scheduler.cancel()
        await eventually("cancelled", timeout: 2) { await phone.transport.cancelledWhileBlocked == 1 }
        await phone.transport.release()
        let error = await outcome.value
        XCTAssertTrue(error is CancellationError, "\(String(describing: error))")
        let after = await calls(since: mark)
        XCTAssertEqual(after, [])
        XCTAssertEqual(try token(phone.queue), tokenBefore, "the first page isn't applied, the token stays")
        XCTAssertEqual(try accounts(phone.queue), 0)

        _ = try await phone.scheduler.syncNowAndWait()
        XCTAssertEqual(try accounts(phone.queue), 3)
    }

    func testCancelBetweenPullAndPushRecordsThePullAndKeepsTheEditPending() async throws {
        let mac = try await device("user-a")
        let ids = try await mac.queue.write { db in try FiledYearSyncCheckTests.fixture(db) }
        await mac.scheduler.requestSync(.launch)
        let phone = try await device("user-b")
        await phone.scheduler.requestSync(.launch)
        try await mac.queue.write { db in
            try db.execute(sql: "UPDATE transaction_ SET amountMinorUnits = -20000 WHERE id = ?", arguments: [ids["plumber"]!])
        }
        await mac.scheduler.requestSync(.userRefresh)
        try addAccount(phone.queue, "Synthetic Edit")
        let editsBefore = try pending(phone.queue)

        clock.advance(60)
        await phone.transport.blockSaves(after: 0)
        let scheduler = phone.scheduler
        let outcome = Task { () -> Error? in
            do { _ = try await scheduler.syncNowAndWait(); return nil } catch { return error }
        }
        await eventually("the push is in flight") { await phone.transport.isBlocked }
        await phone.scheduler.cancel()
        await eventually("cancelled", timeout: 2) { await phone.transport.cancelledWhileBlocked == 1 }
        await phone.transport.release()
        let error = await outcome.value
        XCTAssertTrue(error is CancellationError, "\(String(describing: error))")

        XCTAssertEqual(try pending(phone.queue), editsBefore, "the edit waits for the next push")
        let status = await phone.scheduler.status
        XCTAssertEqual(status, .needsAttention(held: 1, lastSync: start.addingTimeInterval(60)), "the pull's results are kept")
    }

    func testCancelBetweenPushChunksKeepsWhatTheServerTook() async throws {
        let phone = try await device("user-a", batchSize: 1)
        try addAccount(phone.queue, "Synthetic C0")  // the first push publishes the key marker
        await phone.scheduler.requestSync(.launch)
        XCTAssertEqual(try pending(phone.queue), [])
        for name in ["Synthetic C1", "Synthetic C2", "Synthetic C3"] { try addAccount(phone.queue, name) }

        let savesBefore = await phone.transport.saveCalls
        await phone.transport.blockSaves(after: 1)
        let scheduler = phone.scheduler
        let outcome = Task { () -> Error? in
            do { _ = try await scheduler.syncNowAndWait(); return nil } catch { return error }
        }
        await eventually("blocked on the second chunk") { await phone.transport.isBlocked }
        await phone.scheduler.cancel()
        await eventually("cancelled", timeout: 2) { await phone.transport.cancelledWhileBlocked == 1 }
        await phone.transport.release()
        let error = await outcome.value
        XCTAssertTrue(error is CancellationError, "\(String(describing: error))")

        XCTAssertEqual(try pending(phone.queue).count, 2, "the first chunk stays acknowledged; the rest waits")
        let onServer = await cloud.storedRecords().filter { $0.recordType == "account" }.count
        XCTAssertEqual(onServer, 2)
        let saves = await phone.transport.saveCalls
        XCTAssertEqual(saves, savesBefore + 2, "nothing after the cancelled operation")

        _ = try await phone.scheduler.syncNowAndWait()
        XCTAssertEqual(try pending(phone.queue), [])
        let all = await cloud.storedRecords().filter { $0.recordType == "account" }.count
        XCTAssertEqual(all, 4)
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

    // MARK: Parked from Task 1's review (N1–N3), fixed in Task 12

    /// N1: a key fetch that keeps failing on the network is one offline spell: the backoff keeps doubling and "since"
    /// stays the first failure's (a pull that succeeded in between doesn't reset them).
    func testAKeyFetchThatKeepsFailingBacksOffFromTheFirstFailure() async throws {
        let phone = try await device("user-a")
        try addAccount(phone.queue, "Synthetic Fetch")
        await phone.transport.failNextFetch(with: .networkUnavailable)
        await phone.transport.failNextFetch(with: .networkUnavailable)

        await phone.scheduler.requestSync(.launch)
        let first = await phone.scheduler.status
        XCTAssertEqual(first, .offline(since: start, retryAt: start.addingTimeInterval(30)))

        clock.advance(30)
        sleeper.fire(30)
        await eventually("the backoff doubled") { self.sleeper.pending(60) == 1 }
        let second = await phone.scheduler.status
        XCTAssertEqual(second, .offline(since: start, retryAt: start.addingTimeInterval(90)), "offline since the first failure")
    }

    /// N2: a push that sent nothing because the household key hasn't arrived isn't a sync: the last sync's time stays.
    func testAPushThatWaitsForTheKeyDoesntMoveTheLastSync() async throws {
        let mac = try await device("user-a")
        try addAccount(mac.queue, "Synthetic Shared")
        await mac.scheduler.requestSync(.launch)
        let phone = try await device("user-b", keys: InMemorySyncKeyStore())
        await phone.scheduler.requestSync(.launch)
        let pulledAt = await phone.scheduler.lastSync
        XCTAssertEqual(pulledAt, start)

        try addAccount(phone.queue, "Synthetic Local")
        clock.advance(100)
        await phone.scheduler.requestSync(.localChange)
        await eventually("the debounce armed") { self.sleeper.pending(5) == 1 }
        sleeper.fire(5)
        await eventually("the push settled (the key retry armed again)") { self.sleeper.requested.filter { $0 == 300 }.count == 2 }
        let after = await phone.scheduler.lastSync
        XCTAssertEqual(after, start, "nothing was sent: the last sync stays the pull's")
        let status = await phone.scheduler.status
        XCTAssertEqual(status, .waitingForKey(since: start))
    }

    /// N3: a sync cancelled by `stop()` after its pull arms no timer while stopped, so `start()` arms the key retry.
    /// The phone holds the household key and has an edit to send; one record here waits for a key it doesn't hold
    /// (sealed by a device of another household, synthetic), so the pull leaves it waiting for the key.
    func testACancelAfterStopArmsNothingUntilStart() async throws {
        let mac = try await device("user-a")
        try addAccount(mac.queue, "Synthetic Shared")
        await mac.scheduler.requestSync(.launch)

        // A record sealed under a key this household's devices never held.
        let otherCloud = FakeCloud()
        let other = try TestDatabase.migratedManager()
        try await other.dbQueue.write { db in try SyncChangeTracker.setWriter("user-c", db: db) }
        try addAccount(other.dbQueue, "Synthetic Elsewhere")
        _ = try await SyncEngineCore(db: other.dbQueue, transport: otherCloud, device: SyncDevice(id: "device-c", name: "c"),
                                     keyStore: InMemorySyncKeyStore()).syncNow()
        let stored = await otherCloud.storedRecords()
        let foreignName = try XCTUnwrap(stored.first { $0.recordType == "account" }?.recordName)
        let found = await otherCloud.record(named: foreignName)
        let foreign = try XCTUnwrap(found)

        let phone = try await device("user-b")
        let now = start
        try await phone.queue.write { db in try SyncTranslator.stageWaitingForKey(foreign, db: db, now: now) }
        try addAccount(phone.queue, "Synthetic Local")

        await phone.transport.blockSaves(after: 0)
        let scheduler = phone.scheduler
        let outcome = Task { () -> Error? in
            do { _ = try await scheduler.syncNowAndWait(); return nil } catch { return error }
        }
        await eventually("the push is in flight") { await phone.transport.isBlocked }
        await phone.scheduler.stop()
        await eventually("cancelled", timeout: 2) { await phone.transport.cancelledWhileBlocked == 1 }
        await phone.transport.release()
        let error = await outcome.value
        XCTAssertTrue(error is CancellationError, "\(String(describing: error))")
        XCTAssertEqual(sleeper.pending(300), 0, "nothing armed while stopped")
        let stopped = await phone.scheduler.status
        XCTAssertEqual(stopped, .off)

        await phone.scheduler.start()
        await eventually("start arms the key retry") { self.sleeper.pending(300) == 1 }
        let status = await phone.scheduler.status
        XCTAssertEqual(status, .waitingForKey(since: start))
    }

    /// The records each pull received, added up while the scheduler lives (the phone's first-download count).
    func testReceivedRecordsAddUpEachPull() async throws {
        let mac = try await device("user-a")
        try addAccount(mac.queue, "Synthetic One")
        try addAccount(mac.queue, "Synthetic Two")
        await mac.scheduler.requestSync(.launch)
        let phone = try await device("user-b")
        let none = await phone.scheduler.receivedRecords
        XCTAssertEqual(none, 0)
        XCTAssertFalse(try hasToken(phone.queue))
        await phone.scheduler.requestSync(.launch)
        let received = await phone.scheduler.receivedRecords
        XCTAssertGreaterThanOrEqual(received, 2)
        XCTAssertTrue(try hasToken(phone.queue))
    }
}
