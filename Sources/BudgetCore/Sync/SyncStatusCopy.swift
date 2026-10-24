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

    /// The amber banner at the top of every tab while offline (iPhone spec §3.9): "Offline · showing data from
    /// 14:05." (the time today, the day and time before, with the year when it isn't this one). No "N changes will
    /// sync": the phone has none.
    public static func offlineBanner(lastSync: Date?, now: Date, calendar: Calendar = .current) -> String {
        guard let lastSync else { return "Offline · showing what's on this iPhone." }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        if calendar.isDate(lastSync, inSameDayAs: now) {
            formatter.dateFormat = "HH:mm"
        } else if calendar.component(.year, from: lastSync) == calendar.component(.year, from: now) {
            formatter.dateFormat = "d MMM, HH:mm"
        } else {
            formatter.dateFormat = "d MMM yyyy, HH:mm"
        }
        return "Offline · showing data from \(formatter.string(from: lastSync))."
    }

    /// The first download's line (before this iPhone has pulled once): what has arrived so far.
    public static func firstDownload(received: Int) -> String {
        let base = "Downloading the household's records…"
        guard received > 0 else { return base }
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_GB")
        formatter.numberStyle = .decimal
        return "\(base) \(formatter.string(from: NSNumber(value: received)) ?? String(received)) so far"
    }

    /// Settings' security line: whether this device holds the household key (nil: sync is off here). Waiting is
    /// worded as the waiting status is, never as a failure.
    public static func householdKey(held: Bool?) -> String {
        switch held {
        case true?: "Records sealed with the household key"
        case false?: "Waiting for the household key from iCloud Keychain"
        case nil: "Sync is off"
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
