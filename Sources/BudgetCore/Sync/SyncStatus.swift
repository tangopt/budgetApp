import Foundation

/// What a running sync is doing now.
public enum SyncPhase: Equatable, Sendable {
    case pulling
    case pushing
}

/// Why sync waits for the person rather than for time (sync spec §5.6): nothing is retried until the app comes
/// back to the foreground (or the person refreshes).
public enum SyncUnavailableReason: Equatable, Sendable {
    /// No iCloud account is signed in on this device.
    case noICloudAccount
    /// The iCloud storage is full.
    case quotaExceeded
}

/// The sync state the apps show (Settings ▸ Sync on the Mac, the iPhone's status line), as `SyncScheduler` keeps it.
public enum SyncStatus: Equatable, Sendable {
    /// Sync isn't running here (the scheduler is stopped, or this database never syncs).
    case off
    /// Up to date as of `lastSync` (nil: never synced here).
    case idle(lastSync: Date?)
    case syncing(SyncPhase)
    /// Records (or this device's own edits) wait for the household key from iCloud Keychain (ruling R15). Waiting
    /// isn't failing: shown in the secondary colour, retried on a slow schedule.
    case waitingForKey(since: Date)
    /// The service couldn't be reached (no network, busy, rate limited) since `since`; tried again at `retryAt`.
    case offline(since: Date, retryAt: Date?)
    /// Records held because they would change a filed tax year (sync spec §5.4).
    case needsAttention(held: Int, lastSync: Date?)
    /// Waits for the person (no iCloud account, iCloud full).
    case unavailable(SyncUnavailableReason)
}
