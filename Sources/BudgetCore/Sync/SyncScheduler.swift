import Foundation
import GRDB
import os

/// What asked for a sync.
public enum SyncTrigger: Equatable, Sendable {
    /// The app started.
    case launch
    /// The app came back to the foreground (also ends waiting for the person: no iCloud account, iCloud full).
    case foreground
    /// The person asked (pull to refresh, a Sync button).
    case userRefresh
    /// Something changed here: debounced, and only pushes.
    case localChange
    /// The periodic timer.
    case periodic
    /// iCloud Keychain may have delivered the household key.
    case keyMayHaveArrived

    /// Started by the person (or the app coming to them), not by a timer.
    var isPersonal: Bool { self == .launch || self == .foreground || self == .userRefresh }
}

/// When `SyncEngineCore` runs, around it (plan step 4 Task 1; sync spec §5.5–§5.7, §9 "waiting isn't failing"):
/// - **One sync at a time.** A request while one runs queues one more after it (requests while that one waits join
///   it); `localChange` is debounced by `pushDebounce` and only pushes; every other trigger pulls, then pushes.
/// - **Offline** (`networkUnavailable`, `unavailable(retryAfter:)`, also when they keep the push from fetching the key
///   marker): `.offline`, tried again at `max(retryAfter, backoff)`, the backoff doubling from 30 s to 15 min. The
///   server's retry-after holds every trigger back (a refresh throws `unavailable` with the time left); the backoff
///   only holds back the automatic ones (`periodic`, `localChange`, `keyMayHaveArrived`): the person's own
///   refresh, the app's launch and its return to the foreground go at once.
/// - **Other failures** (a database error, a non-passing transport error): `.failed(reason:)`, tried again with the
///   same capped backoff, cleared by the next success.
/// - **The household key hasn't arrived** (a push's `keyWait`, a pull's `waitingForKey`, or records still waiting
///   for it here): `.waitingForKey`, tried again every `keyWaitRetry` and on `.keyMayHaveArrived`; no backoff, no
///   second key.
/// - **No iCloud account, iCloud full**: `.unavailable`, nothing tried again until the app comes back to the
///   foreground (or the person refreshes, or the app starts).
/// - Records held by the filed-year check (sync spec §5.4): `.needsAttention` while any is held here.
/// - `cancel()` stops the running sync at its next operation (the engine's `serialized` passes it on, so the
///   transport sees it); the change token and stamps stay as they were. A pull that finished before the cancel is
///   recorded (its time, what it held). A retry or key-wait timer is armed again after a cancel and on `start()`
///   (for what is left of the wait). A cancel inside one push chunk that took several save operations drops the
///   results of the operations already taken: those records stay pending and go again, coming back `changed` and
///   merged (as after a lost reply); nothing is lost or corrupted.
///
/// The database is only read here (the last sync's time, what waits in staging).
public actor SyncScheduler {
    enum Kind: Int, Comparable {
        case push
        case full

        static func < (lhs: Kind, rhs: Kind) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// Why sync is held back, other than waiting for the person or the key.
    private enum Problem: Equatable {
        case offline
        case failed(String)
    }

    /// The first retry after a failure, doubling up to `maxBackoff`.
    static let firstBackoff: TimeInterval = 30
    static let maxBackoff: TimeInterval = 15 * 60

    private static let log = Logger(subsystem: "com.personal.budget", category: "Sync")

    let engine: SyncEngineCore
    let db: any DatabaseWriter
    let clock: @Sendable () -> Date
    let sleep: @Sendable (TimeInterval) async throws -> Void
    let pushDebounce: TimeInterval
    let periodic: TimeInterval
    let keyWaitRetry: TimeInterval

    public private(set) var status: SyncStatus = .off {
        didSet {
            guard status != oldValue else { return }
            for continuation in continuations.values { continuation.yield(status) }
        }
    }

    private var started = false
    private var lastSync: Date?
    private var lastSyncLoaded = false
    /// Consecutive failures (the backoff's exponent).
    private var failures = 0
    private var problem: Problem?
    private var problemSince: Date?
    /// The next attempt after a failure: automatic triggers wait for it.
    private var retryAt: Date?
    /// Until when the server asked to wait (`retryAfter`): every trigger waits for it.
    private var serverRetryAt: Date?
    private var waitingSince: Date?
    private var held = 0
    private var unavailable: SyncUnavailableReason?

    private var runningTask: Task<SyncReport, Error>?
    private var runningId: Int?
    private var waitingTask: Task<SyncReport, Error>?
    private var waitingId: Int?
    private var waitingKind: Kind = .push
    private var nextId = 0

    private var retryTask: Task<Void, Never>?
    private var retryGeneration = 0
    private var debounceTask: Task<Void, Never>?
    private var periodicTask: Task<Void, Never>?
    private var continuations: [UUID: AsyncStream<SyncStatus>.Continuation] = [:]

    public init(engine: SyncEngineCore, db: any DatabaseWriter, clock: @escaping @Sendable () -> Date = { Date() },
                sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) },
                pushDebounce: TimeInterval = 5, periodic: TimeInterval = 900, keyWaitRetry: TimeInterval = 300) {
        self.engine = engine
        self.db = db
        self.clock = clock
        self.sleep = sleep
        self.pushDebounce = pushDebounce
        self.periodic = periodic
        self.keyWaitRetry = keyWaitRetry
    }

    // MARK: Lifecycle

    /// Starts the periodic timer, and a retry that was pending when it stopped; the status leaves `.off`. Syncs
    /// nothing else by itself (the app sends `.launch`).
    public func start() {
        guard !started else { return }
        started = true
        if !lastSyncLoaded {
            lastSyncLoaded = true
            lastSync = readLastSync()
        }
        rearmRetry(afterCancel: false)
        status = restingStatus()
        let sleep = self.sleep
        let periodic = self.periodic
        periodicTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await sleep(periodic) } catch { return }
                guard let self else { return }
                await self.requestSync(.periodic)
            }
        }
    }

    /// Stops: the running sync is cancelled, the timers too; the status is `.off`. What it was waiting for is kept,
    /// and `start()` arms it again.
    public func stop() {
        guard started else { return }
        started = false
        cancel()
        cancelRetry()
        periodicTask?.cancel()
        periodicTask = nil
        status = .off
    }

    /// Cancels the running sync (it stops at its next operation, the token and stamps as they were) and whatever
    /// waits for it, and a pending debounced push. Timers stay.
    public func cancel() {
        runningTask?.cancel()
        waitingTask?.cancel()
        waitingTask = nil
        waitingId = nil
        waitingKind = .push
        debounceTask?.cancel()
        debounceTask = nil
    }

    // MARK: Requests

    public func requestSync(_ trigger: SyncTrigger) async {
        guard admits(trigger) else { return }
        if trigger.isPersonal { unavailable = nil }
        if trigger == .localChange {
            scheduleDebouncedPush()
            return
        }
        _ = try? await enqueue(.full).value
    }

    /// Pulls, then pushes, and returns the report (pull to refresh awaits it). Throws `unavailable` with the time
    /// left while the server asked to wait, `CancellationError` when stopped or cancelled, and the sync's error.
    public func syncNowAndWait() async throws -> SyncReport {
        guard started else { throw CancellationError() }
        let now = clock()
        if let serverRetryAt, now < serverRetryAt {
            throw SyncTransportError.unavailable(retryAfter: serverRetryAt.timeIntervalSince(now))
        }
        unavailable = nil
        return try await enqueue(.full).value
    }

    /// The status now, then every change.
    public func statusStream() -> AsyncStream<SyncStatus> {
        let (stream, continuation) = AsyncStream.makeStream(of: SyncStatus.self, bufferingPolicy: .bufferingNewest(32))
        let id = UUID()
        continuations[id] = continuation
        continuation.yield(status)
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeContinuation(id) }
        }
        return stream
    }

    private func removeContinuation(_ id: UUID) { continuations[id] = nil }

    /// Whether `trigger` may start a sync now.
    private func admits(_ trigger: SyncTrigger) -> Bool {
        guard started else { return false }
        if unavailable != nil { return trigger.isPersonal }
        let now = clock()
        // The server asked to wait: nothing goes before then (the scheduled retry is the next attempt).
        if let serverRetryAt, now < serverRetryAt { return false }
        // The backoff holds back only what no one asked for.
        if !trigger.isPersonal, let retryAt, now < retryAt { return false }
        return true
    }

    // MARK: Running, one at a time

    /// The sync that runs after the current one (joined by every request made while it waits).
    private func enqueue(_ kind: Kind) -> Task<SyncReport, Error> {
        waitingKind = max(waitingKind, kind)
        if let waitingTask { return waitingTask }
        nextId += 1
        let id = nextId
        let previous = runningTask
        let task = Task {
            _ = await previous?.result
            return try await self.perform(id)
        }
        waitingTask = task
        waitingId = id
        return task
    }

    private func perform(_ id: Int) async throws -> SyncReport {
        // Cancelled (and dropped) while it waited.
        guard waitingId == id else { throw CancellationError() }
        let kind = waitingKind
        runningTask = waitingTask
        runningId = id
        waitingTask = nil
        waitingId = nil
        waitingKind = .push
        defer {
            if runningId == id {
                runningTask = nil
                runningId = nil
            }
        }
        guard started, !Task.isCancelled else { throw CancellationError() }
        status = .syncing(kind == .full ? .pulling : .pushing)
        var report = SyncReport(pull: SyncPullReport(), push: SyncPushReport())
        var pulled = false
        do {
            if kind == .full {
                report.pull = try await engine.pull()
                pulled = true
                try Task.checkCancellation()
                status = .syncing(.pushing)
            }
            report.push = try await engine.pushPending()
            settle(report)
            return report
        } catch {
            if error is CancellationError || Task.isCancelled {
                // A pull that finished is kept: its time, what it held, what waits for the key.
                if pulled { settle(report) }
                rearmRetry(afterCancel: true)
                status = restingStatus()
                throw CancellationError()
            }
            settle(error)
            throw error
        }
    }

    // MARK: Outcomes

    private func settle(_ report: SyncReport) {
        let now = clock()
        lastSync = now
        failures = 0
        problem = nil
        problemSince = nil
        retryAt = nil
        serverRetryAt = nil
        unavailable = nil
        do {
            let (waitingRows, heldRows) = try db.read { db in
                (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM syncStaging WHERE reason = ?",
                                  arguments: [SyncTranslator.waitingForHouseholdKey]) ?? 0,
                 try FiledYearSyncCheck.held(db: db).count)
            }
            held = max(report.pull.held + report.push.held, heldRows)
            if held == 0, report.pull.filedYearAlert != nil || report.push.filedYearAlert != nil { held = 1 }
            if report.push.keyWaitCause == nil, report.push.keyWait != nil || report.pull.waitingForKey > 0 || waitingRows > 0 {
                waitingSince = waitingSince ?? now
            } else if report.push.keyWaitCause == nil {
                waitingSince = nil
            }
        } catch {
            // What is held or waits stays as last known (only this sync's report is added), never silently cleared.
            Self.log.error("Sync status couldn't read staging (\(String(describing: type(of: error)), privacy: .public))")
            held = max(held, report.pull.held + report.push.held)
            if report.push.keyWait != nil && report.push.keyWaitCause == nil || report.pull.waitingForKey > 0 {
                waitingSince = waitingSince ?? now
            }
        }
        if let cause = report.push.keyWaitCause {
            // The key marker couldn't be fetched or published because the service wasn't reachable: offline.
            settle(cause)
            return
        }
        if waitingSince != nil {
            scheduleRetry(after: keyWaitRetry)
        } else {
            cancelRetry()
        }
        status = restingStatus()
    }

    private func settle(_ error: Error) {
        let transport = error as? SyncTransportError
        switch transport {
        case .notAuthenticated?:
            waitForPerson(.noICloudAccount)
        case .quotaExceeded?:
            waitForPerson(.quotaExceeded)
        default:
            let passing = transport?.isPassing ?? false
            let reason = Self.reason(error)
            Self.log.error("Sync \(passing ? "offline" : "failed", privacy: .public); tried again later (\(reason, privacy: .public))")
            failures += 1
            let backoff = min(Self.firstBackoff * pow(2, Double(failures - 1)), Self.maxBackoff)
            let serverWait = transport?.retryAfter
            let delay = max(serverWait ?? 0, backoff)
            let now = clock()
            let next: Problem = passing ? .offline : .failed(reason)
            // Since the first failure of this kind (offline, or stopped for this reason).
            if problem != next { problemSince = now }
            problem = next
            retryAt = now.addingTimeInterval(delay)
            serverRetryAt = serverWait.map { now.addingTimeInterval($0) }
            scheduleRetry(after: delay)
        }
        status = restingStatus()
    }

    /// The failure's kind for the details under "Sync stopped — will try again" (`SyncStatusCopy.detail`), never a value from the data.
    static func reason(_ error: Error) -> String {
        if let database = error as? DatabaseError { return "the database reported an error (\(database.resultCode))" }
        if let transport = error as? SyncTransportError { return "iCloud refused the operation (\(transport))" }
        if let described = (error as? LocalizedError)?.errorDescription { return described }
        return "an unexpected error (\(String(describing: type(of: error))))"
    }

    private func waitForPerson(_ reason: SyncUnavailableReason) {
        unavailable = reason
        failures = 0
        problem = nil
        problemSince = nil
        retryAt = nil
        serverRetryAt = nil
        cancelRetry()
    }

    /// The status outside a sync.
    private func restingStatus() -> SyncStatus {
        guard started else { return .off }
        if let unavailable { return .unavailable(unavailable) }
        switch problem {
        case .offline?:
            // Never "trying again at" a time already past.
            let next = retryAt.flatMap { $0 >= clock() ? $0 : nil }
            return .offline(since: problemSince ?? clock(), retryAt: next)
        case .failed(let reason)?:
            return .failed(reason: reason)
        case nil:
            break
        }
        if held > 0 { return .needsAttention(held: held, lastSync: lastSync) }
        if let waitingSince { return .waitingForKey(since: waitingSince) }
        return .idle(lastSync: lastSync)
    }

    /// When this database last pulled (its change token's last write), before this run of the app.
    private func readLastSync() -> Date? {
        do {
            return try db.read { db in
                try Date.fetchOne(db, sql: "SELECT updatedAt FROM syncState WHERE key = ?",
                                  arguments: [SyncEngineCore.tokenKey(SyncRecordStore.householdZone)])
            }
        } catch {
            Self.log.error("Sync status couldn't read the last sync time (\(String(describing: type(of: error)), privacy: .public))")
            return nil
        }
    }

    // MARK: Timers

    /// Arms again the retry a stop or a cancel dropped: what is left of a failure's wait (at once when it is past,
    /// unless a cancel stopped that very retry: then after the current backoff), or the key-wait retry.
    private func rearmRetry(afterCancel: Bool) {
        guard started, retryTask == nil, unavailable == nil else { return }
        let now = clock()
        if problem != nil, let retryAt {
            var remaining = max(0, retryAt.timeIntervalSince(now))
            if afterCancel, remaining == 0 {
                // The cancelled run was this retry (the app went to the background): not again at once.
                remaining = min(Self.firstBackoff * pow(2, Double(max(failures, 1) - 1)), Self.maxBackoff)
                self.retryAt = now.addingTimeInterval(remaining)
            }
            scheduleRetry(after: remaining)
        } else if waitingSince != nil {
            scheduleRetry(after: keyWaitRetry)
        }
    }

    private func scheduleRetry(after delay: TimeInterval) {
        retryTask?.cancel()
        retryGeneration += 1
        let generation = retryGeneration
        let sleep = self.sleep
        retryTask = Task { [weak self] in
            do { try await sleep(delay) } catch { return }
            await self?.retryFired(generation)
        }
    }

    private func cancelRetry() {
        retryTask?.cancel()
        retryTask = nil
        retryGeneration += 1
    }

    private func retryFired(_ generation: Int) async {
        guard generation == retryGeneration, started else { return }
        retryTask = nil
        _ = try? await enqueue(.full).value
    }

    private func scheduleDebouncedPush() {
        debounceTask?.cancel()
        let sleep = self.sleep
        let delay = pushDebounce
        debounceTask = Task { [weak self] in
            do { try await sleep(delay) } catch { return }
            await self?.debounceFired()
        }
    }

    private func debounceFired() async {
        guard admits(.localChange) else { return }
        _ = try? await enqueue(.push).value
    }
}
