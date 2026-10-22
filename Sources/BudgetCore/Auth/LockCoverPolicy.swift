import Foundation

/// What happens to the sheets, alerts and dialogs a lock covered when the cover lifts (auth spec §6):
/// the person they were open for gets them back as they were; anyone else never sees them, so they end.
public enum LockCoverPolicy {
    public enum Outcome: Equatable, Sendable {
        case restore
        case dismiss
    }

    /// `coveredFor`: who was signed in when the cover went up; `signedIn`: who is signed in now.
    public static func onUncover(coveredFor: Int64?, signedIn: Int64?) -> Outcome {
        guard let coveredFor, let signedIn, coveredFor == signedIn else { return .dismiss }
        return .restore
    }
}
