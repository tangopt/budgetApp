import Foundation
import GRDB

/// The one door for password and recovery-key sign-in: both share one `SignInThrottle`, and only one
/// check runs at a time (a second attempt while one is being checked is refused, not queued), so
/// concurrent attempts can't all slip past the delay.
@MainActor
public final class SignInGate {
    public enum Outcome: Equatable, Sendable {
        case accepted
        case rejected
        /// Too many wrong attempts: try again after this many seconds.
        case throttled(TimeInterval)
        /// Another attempt is being checked.
        case busy
    }

    private let dbQueue: DatabaseQueue
    private var throttle = SignInThrottle()
    private var inFlight = false

    public init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
    }

    public var failures: Int { throttle.failures }

    /// PBKDF2 runs on the database queue, off the main thread. A write, because a right password made with
    /// fewer rounds is rehashed.
    public func password(appUserId: Int64, password: String, now: Date) async -> Outcome {
        await attempt(now: now) { [dbQueue] in
            (try? await dbQueue.write { try AppUserStore.verifyPassword($0, appUserId: appUserId, password: password) }) ?? false
        }
    }

    public func recoveryKey(appUserId: Int64, key: String, now: Date) async -> Outcome {
        await attempt(now: now) { [dbQueue] in
            (try? await dbQueue.read { try AppUserStore.verifyRecoveryKey($0, appUserId: appUserId, key: key) }) ?? false
        }
    }

    /// `now` is the time of the attempt (the throttle's clock); the failure is recorded at it too.
    func attempt(now: Date, _ check: () async -> Bool) async -> Outcome {
        guard !inFlight else { return .busy }
        let wait = throttle.delay(now: now)
        guard wait <= 0 else { return .throttled(wait) }
        inFlight = true
        defer { inFlight = false }
        guard await check() else {
            throttle.recordFailure(now: now)
            let wait = throttle.delay(now: now)
            return wait > 0 ? .throttled(wait) : .rejected
        }
        throttle.reset()
        return .accepted
    }
}
