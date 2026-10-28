import Foundation
import GRDB
import os

private let inviteLog = Logger(subsystem: "com.personal.budget", category: "Household")

extension HouseholdInvite {
    /// What pressing "Invite…" on the Mac comes to (`press`): every outcome the pane shows, none silent.
    public enum PressOutcome<Sheet> {
        /// The invite can't go yet: one line each (`HouseholdCopy.blocker`), shown under "Not yet:".
        case blocked([String])
        /// The share is made (or was already): the system share sheet opens for `sheet`.
        case present(SyncZoneShare, sheet: Sheet)
        /// The share is made but the sheet couldn't be prepared for it (`HouseholdCopy.shareFailed`).
        case sheetUnavailable(SyncZoneShare)
        /// iCloud went `idleLimit` without answering: the gate gave up, nothing new was shared
        /// (`HouseholdCopy.inviteTimedOut`).
        case timedOut
    }

    /// How long "Invite…" waits for iCloud to answer before giving up. A long household read is fine: every page read
    /// counts as an answer (`InviteWatchdog`).
    public static let pressIdleLimit: Duration = .seconds(60)

    /// The Mac's "Invite…" (Settings ▸ Household): the local gate, then real sync must be running, then `invite` (the
    /// whole gate and the share), then `sheet` reads what the system share sheet needs (the `CKShare` and its container).
    /// `progress` hears each step (`Stage`); when iCloud goes `idleLimit` without answering, the press is `.timedOut`.
    /// Errors that aren't passing are thrown for the pane's error line.
    public static func press<Sheet>(running: Bool, transport: any SyncTransport & SyncShareTransport, keys: any SyncKeyStore,
                                    db: any DatabaseWriter, title: String, idleLimit: Duration = pressIdleLimit,
                                    progress: @escaping @Sendable (Stage) -> Void = { _ in },
                                    isolation: isolated (any Actor)? = #isolation,
                                    sheet: () async throws -> Sheet?) async throws -> PressOutcome<Sheet> {
        inviteLog.notice("Household invite: pressed")
        progress(.checkingThisMac)
        let local = try await db.read { db in try localBlockers(db: db) }
        guard local.isEmpty else {
            inviteLog.notice("Household invite: blocked on this Mac (\(local.count, privacy: .public) reason(s))")
            return .blocked(local.map { HouseholdCopy.blocker($0) })
        }
        guard running else {
            inviteLog.notice("Household invite: blocked, sync isn't running")
            return .blocked([HouseholdCopy.blocker(.syncNotOn)])
        }
        let gate: (existed: Bool, result: Result)
        do {
            gate = try await InviteWatchdog.run(idleLimit: idleLimit) { beat in
                let report: @Sendable (Stage) -> Void = { stage in
                    beat()
                    progress(stage)
                }
                inviteLog.notice("Household invite: reading the share")
                let existed = (try? await transport.zoneShare(SyncZones.household)) != nil
                beat()
                inviteLog.notice("Household invite: gate starts (share \(existed ? "exists" : "not made yet", privacy: .public))")
                return (existed, try await invite(transport: transport, keys: keys, db: db, title: title, progress: report))
            }
        } catch is InviteWatchdog.TimedOut {
            inviteLog.error("Household invite: iCloud didn't answer for \(idleLimit.components.seconds, privacy: .public) s; gave up")
            return .timedOut
        }
        switch gate.result {
        case .blocked(let found):
            inviteLog.notice("Household invite: blocked (\(found.count, privacy: .public) reason(s))")
            return .blocked(found.map { HouseholdCopy.blocker($0, alreadyShared: gate.existed) })
        case .share(let made):
            inviteLog.notice("Household invite: share ready, reading it for the sheet")
            progress(.preparingSheet)
            guard let ready = try await sheet() else { return .sheetUnavailable(made) }
            return .present(made, sheet: ready)
        }
    }
}

/// Runs work that reports progress, and gives up when it goes `idleLimit` without any: a CloudKit reply that never
/// comes (the operation's own timeout is days) ends the wait instead of leaving "Invite…" spinning. The work is
/// cancelled then (a CloudKit operation is cancelled with it), but the caller never waits for it to stop.
public enum InviteWatchdog {
    public struct TimedOut: Error, Equatable, Sendable {
        public init() {}
    }

    public static func run<T: Sendable>(idleLimit: Duration,
                                        _ work: @escaping @Sendable (_ beat: @escaping @Sendable () -> Void) async throws -> T)
        async throws -> T {
        let clock = ContinuousClock()
        let last = OSAllocatedUnfairLock(initialState: clock.now)
        let tasks = OSAllocatedUnfairLock<[Task<Void, Never>]>(initialState: [])
        let finished = OSAllocatedUnfairLock(initialState: false)
        let beat: @Sendable () -> Void = { last.withLock { $0 = clock.now } }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
                // The first to finish (the work, the watchdog, or a cancel) answers; the others are cancelled.
                let finish: @Sendable (Swift.Result<T, Error>) -> Void = { result in
                    let first = finished.withLock { done -> Bool in
                        if done { return false }
                        done = true
                        return true
                    }
                    guard first else { return }
                    continuation.resume(with: result)
                    for task in tasks.withLock({ $0 }) { task.cancel() }
                }
                let worker = Task {
                    do { finish(.success(try await work(beat))) } catch { finish(.failure(error)) }
                }
                let watcher = Task {
                    while !Task.isCancelled {
                        let idle = clock.now - last.withLock { $0 }
                        if idle >= idleLimit {
                            finish(.failure(TimedOut()))
                            return
                        }
                        try? await Task.sleep(for: idleLimit - idle)
                    }
                    // Cancelled: the work finished, or the caller was cancelled (`onCancel`).
                    finish(.failure(CancellationError()))
                }
                tasks.withLock { $0 = [worker, watcher] }
                if finished.withLock({ $0 }) {
                    worker.cancel()
                    watcher.cancel()
                }
            }
        } onCancel: {
            for task in tasks.withLock({ $0 }) { task.cancel() }
        }
    }
}
