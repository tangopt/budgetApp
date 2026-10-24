import Foundation

/// The words each sync status shows on the phone (and later the Mac's Settings ▸ Sync): the one place this copy
/// lives (plan step 4, Task 12's copy; brought forward by Task 7, whose Home shows the status line and lists sync
/// problems). One line each. Waiting for the household key is never worded as a failure and never amber (sync spec
/// §9 weakest points); no status says "error", "failed" or "failure".
public enum SyncStatusCopy {
    /// How the line is drawn: `.neutral` in the secondary colour; `.amber` (the theme's pending colour) for what
    /// limits the data. Never red.
    public enum Tone: Equatable, Sendable {
        case neutral, amber
    }

    public static func text(_ status: SyncStatus, now: Date) -> (text: String, tone: Tone) {
        switch status {
        case .off:
            return ("Sync is off", .neutral)
        case .idle(let lastSync):
            guard let lastSync else { return ("Not synced yet", .neutral) }
            return ("Up to date · \(relative(lastSync, now: now))", .neutral)
        case .syncing(.pulling):
            return ("Checking for changes…", .neutral)
        case .syncing(.pushing):
            return ("Sending changes…", .neutral)
        case .waitingForKey:
            return ("Waiting for the household key from iCloud Keychain", .neutral)
        case .offline(_, let retryAt):
            guard let retryAt else { return ("Offline", .amber) }
            // Already due (the scheduler hasn't moved on yet): never "trying again 5 seconds ago".
            guard retryAt > now else { return ("Offline · trying again shortly", .amber) }
            return ("Offline · trying again \(relative(retryAt, now: now))", .amber)
        case .needsAttention(let held, _):
            return (held == 1 ? "1 change needs attention on the Mac" : "\(held) changes need attention on the Mac", .amber)
        case .unavailable(.noICloudAccount):
            return ("Sign in to iCloud to sync", .amber)
        case .unavailable(.quotaExceeded):
            return ("iCloud storage is full", .amber)
        case .failed:
            // The reason may quote an error; it is only the details (`detail`), never the line.
            return ("Sync stopped — will try again", .amber)
        }
    }

    /// What a details view (Settings ▸ About) may add under the line: a failure's reason. Nil for every other status.
    public static func detail(_ status: SyncStatus) -> String? {
        if case .failed(let reason) = status { return reason }
        return nil
    }

    /// A status worth the person's attention (Home's Needs attention): everything but off, up to date and a sync
    /// in progress.
    public static func isProblem(_ status: SyncStatus) -> Bool {
        switch status {
        case .off, .idle, .syncing: false
        case .waitingForKey, .offline, .needsAttention, .unavailable, .failed: true
        }
    }

    /// "5 minutes ago", "in 37 seconds", "now" (English, whatever the device's locale, as the rest of the copy).
    static func relative(_ date: Date, now: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "en_GB")
        formatter.unitsStyle = .full
        formatter.dateTimeStyle = .named
        return formatter.localizedString(for: date, relativeTo: now)
    }
}
