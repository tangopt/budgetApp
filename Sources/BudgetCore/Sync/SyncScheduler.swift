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
}

/// When `SyncEngineCore` runs, around it (plan step 4 Task 1; sync spec §5.5–§5.7, §9 "waiting isn't failing"):
/// - **One sync at a time.** A request while one runs queues one more after it (requests while that one waits join
///   it); `localChange` is debounced by `pushDebounce` and only pushes; every other trigger pulls, then pushes.
/// - **Offline** (`networkUnavailable`, `unavailable(retryAfter:)`, any other failure): `.offline`, tried again at
///   `max(retryAfter, backoff)`, the backoff doubling from 30 s to 15 min; until then no trigger reaches the
///   server (a refresh throws `unavailable` with the time left).
/// - **The household key hasn't arrived** (a push's `keyWait`, a pull's `waitingForKey`, or records still waiting
///   for it here): `.waitingForKey`, tried again every `keyWaitRetry` and on `.keyMayHaveArrived`; no backoff, no
///   second key.
/// - **No iCloud account, iCloud full**: `.unavailable`, nothing tried again until the app comes back to the
///   foreground (or the person refreshes, or the app starts).
/// - Records held by the filed-year check (sync spec §5.4): `.needsAttention` while any is held here.
/// - `cancel()` stops the running sync at its next operation (the engine's `serialized` passes it on, so the
///   transport sees it); the change token and stamps stay as they were.
///
/// The database is only read here (the last sync's time, what waits in staging).
public actor SyncScheduler {
    enum Kind: Int, Comparable {
        case push
        case full

        static func < (lhs: Kind, rhs: Kind) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// The first offline retry, doubling up to `maxBackoff`.
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
    /// Consecutive offline failures (the backoff's exponent).
    private var failures = 0
    private var offlineSince: Date?
    private var retryAt: Date?
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

    /// Starts the periodic timer; the status leaves `.off`. Syncs nothing by itself (the app sends `.launch`).
    public func start() {
        guard !started else { return }
        started = true
        if !lastSyncLoaded {
            lastSyncLoaded = true
            lastSync = readLastSync()
        }
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

    /// Stops: the running sync is cancelled, the timers too; the status is `.off`.
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
        if trigger == .foreground || trigger == .userRefresh || trigger == .launch { unavailable = nil }
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
        if unavailable == nil, let retryAt, now < retryAt {
            throw SyncTransportError.unavailable(retryAfter: retryAt.timeIntervalSince(now))
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
        if unavailable != nil { return trigger == .foreground || trigger == .userRefresh || trigger == .launch }
        // The server asked to wait (or the backoff runs): the scheduled retry is the next attempt.
        if let retryAt, clock() < retryAt { return false }
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
        do {
            var report = SyncReport(pull: SyncPullReport(), push: SyncPushReport())
            if kind == .full {
                report.pull = try await engine.pull()
                try Task.checkCancellation()
                status = .syncing(.pushing)
            }
            report.push = try await engine.pushPending()
            settle(report)
            return report
        } catch {
            if error is CancellationError || Task.isCancelled {
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
        offlineSince = nil
        retryAt = nil
        unavailable = nil
        let (waitingRows, heldRows) = (try? db.read { db in
            (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM syncStaging WHERE reason = ?", arguments: [SyncTranslator.waitingForHouseholdKey]) ?? 0,
             try FiledYearSyncCheck.held(db: db).count)
        }) ?? (0, 0)
        held = max(report.pull.held + report.push.held, heldRows)
        if held == 0, report.pull.filedYearAlert != nil || report.push.filedYearAlert != nil { held = 1 }
        let waiting = report.push.keyWait != nil || report.pull.waitingForKey > 0 || waitingRows > 0
        if waiting {
            waitingSince = waitingSince ?? now
            scheduleRetry(after: keyWaitRetry)
        } else {
            waitingSince = nil
            cancelRetry()
        }
        status = restingStatus()
    }

    private func settle(_ error: Error) {
        switch error as? SyncTransportError {
        case .notAuthenticated?:
            waitForPerson(.noICloudAccount)
        case .quotaExceeded?:
            waitForPerson(.quotaExceeded)
        default:
            Self.log.error("Sync failed; tried again later (\(String(describing: type(of: error)), privacy: .public))")
            failures += 1
            let backoff = min(Self.firstBackoff * pow(2, Double(failures - 1)), Self.maxBackoff)
            let delay = max((error as? SyncTransportError)?.retryAfter ?? 0, backoff)
            let now = clock()
            offlineSince = offlineSince ?? now
            retryAt = now.addingTimeInterval(delay)
            scheduleRetry(after: delay)
        }
        status = restingStatus()
    }

    private func waitForPerson(_ reason: SyncUnavailableReason) {
        unavailable = reason
        failures = 0
        offlineSince = nil
        retryAt = nil
        cancelRetry()
    }

    /// The status outside a sync.
    private func restingStatus() -> SyncStatus {
        guard started else { return .off }
        if let unavailable { return .unavailable(unavailable) }
        if let offlineSince { return .offline(since: offlineSince, retryAt: retryAt) }
        if held > 0 { return .needsAttention(held: held, lastSync: lastSync) }
        if let waitingSince { return .waitingForKey(since: waitingSince) }
        return .idle(lastSync: lastSync)
    }

    /// When this database last pulled (its change token's last write), before this run of the app.
    private func readLastSync() -> Date? {
        try? db.read { db in
            try Date.fetchOne(db, sql: "SELECT updatedAt FROM syncState WHERE key = ?",
                              arguments: [SyncEngineCore.tokenKey(SyncRecordStore.householdZone)])
        }
    }

    // MARK: Timers

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
