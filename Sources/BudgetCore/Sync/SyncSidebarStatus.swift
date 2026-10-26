import Foundation

/// The small sync row at the foot of the Mac's sidebar (sync-ui, 2026-10-26), from the real sync's published status
/// and first-upload progress: shown only while real sync is on (or turned on but stopped for a reason), never while
/// it is off.
public enum SyncSidebarStatus: Equatable, Sendable {
    /// Pulling or pushing; during the first upload, how far (`sent` of `total`).
    case syncing(sent: Int?, total: Int?)
    /// Up to date as of the date (nil: not synced yet).
    case synced(Date?)
    /// Offline, or waiting for the household key: it carries on by itself.
    case paused
    /// Something the person has to look at (Settings ▸ Sync says what).
    case attention

    /// The row for the real sync's state; nil hides it.
    public static func make(isRunning: Bool, status: SyncStatus, progress: SyncTurnOn.Progress?, refusal: String?) -> SyncSidebarStatus? {
        // Turned on, but this launch can't sync: waiting for iCloud to say who is signed in (offline at launch, retried by
        // itself) is a pause; anything else (another iCloud user, a build that can't sync) needs the person.
        if let refusal { return refusal == SyncTurnOnFlow.iCloudUserUnknown ? .paused : .attention }
        guard isRunning else { return nil }
        let upload = progress.flatMap { $0.stage == .uploading && $0.total > 0 ? $0 : nil }
        switch status {
        case .off:
            return nil
        case .syncing:
            return .syncing(sent: upload?.sent, total: upload?.total)
        case .idle(let lastSync):
            // Between the first upload's pushes it is still under way.
            if let upload { return .syncing(sent: upload.sent, total: upload.total) }
            return .synced(lastSync)
        case .offline, .waitingForKey:
            return .paused
        case .needsAttention, .unavailable, .failed:
            return .attention
        }
    }

    public func text(now: Date) -> String {
        switch self {
        case .syncing: return "Syncing…"
        case .synced(let date?): return "Synced \(Self.shortRelative(date, now: now))"
        case .synced(nil): return "Not synced yet"
        case .paused: return "Sync paused"
        case .attention: return "Sync needs attention"
        }
    }

    /// "2 min ago", "yesterday": the sidebar is narrow.
    static func shortRelative(_ date: Date, now: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "en_GB")
        formatter.unitsStyle = .short
        formatter.dateTimeStyle = .named
        return formatter.localizedString(for: date, relativeTo: now)
    }

    /// "1,248 of 3,006" during the first upload.
    public var detail: String? {
        guard case .syncing(let sent?, let total?) = self else { return nil }
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = Locale(identifier: "en_GB")
        func number(_ value: Int) -> String { formatter.string(from: NSNumber(value: value)) ?? String(value) }
        return "\(number(sent)) of \(number(total))"
    }

    /// How far the first upload is, 0…1 (nil outside it).
    public var fraction: Double? {
        guard case .syncing(let sent?, let total?) = self, total > 0 else { return nil }
        return min(1, Double(sent) / Double(total))
    }

    /// Clicking the row opens Settings ▸ Sync.
    public var opensSettings: Bool { self == .attention }
}
