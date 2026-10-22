import Foundation

/// The wait between sign-in attempts after repeated wrong passwords: none for the first 5 failures, then
/// 1 s, 2 s, 4 s… up to 60 s. Held in memory only; a restart resets it (auth spec §8).
public struct SignInThrottle: Sendable {
    public static let freeAttempts = 5
    public static let maximumDelay: TimeInterval = 60

    public private(set) var failures = 0
    private var lastFailureAt: Date?

    public init() {}

    public mutating func recordFailure(now: Date) {
        failures += 1
        lastFailureAt = now
    }

    /// Seconds still to wait before the next attempt (0 when one may be made now).
    public func delay(now: Date) -> TimeInterval {
        guard failures > Self.freeAttempts, let lastFailureAt else { return 0 }
        let exponent = min(failures - Self.freeAttempts - 1, 16)
        let required = min(pow(2, Double(exponent)), Self.maximumDelay)
        return max(0, required - now.timeIntervalSince(lastFailureAt))
    }

    public mutating func reset() {
        failures = 0
        lastFailureAt = nil
    }
}
