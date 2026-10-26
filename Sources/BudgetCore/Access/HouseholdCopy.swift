import Foundation

/// Every household string the Mac and iPhone show (step 7a): Settings ▸ Household, the invite's blockers, and the
/// member device's notices. Names come from the app's data, never from here.
public enum HouseholdCopy {
    // MARK: Settings ▸ Household

    public static let paneTitle = "Household"
    public static let addTitle = "Add someone to the household"
    public static let addField = "Name"
    public static let addButton = "Add"
    public static let inviteButton = "Invite…"

    public static func inviteExplainer(_ name: String) -> String {
        "Invite \(name) to Mango. They'll see what your sharing levels allow, and can't change anything yet."
    }

    public static func status(_ status: HouseholdInvite.Status) -> String {
        switch status {
        case .notInvited: return "Not invited yet"
        case .invited: return "Invited — waiting for them to accept"
        case .joined: return "Joined"
        }
    }

    public static let removeButton = "Remove from household…"

    public static func removeTitle(_ name: String) -> String { "Remove \(name) from the household?" }

    public static let removeMessage = "Their devices stop syncing and delete the household's data. Your data stays on this Mac."

    // MARK: Why the invite can't go yet

    public static func blocker(_ blocker: HouseholdInvite.Blocker) -> String {
        switch blocker {
        case .ownershipNotConfirmed:
            return "Confirm who owns each account first, in Settings ▸ Sharing."
        case .syncNotOn:
            return "Turn on iCloud sync first, in Settings ▸ Sync."
        case .noMember:
            return "Add the person you're inviting first."
        case .pendingUpload(let count):
            return "Mango still has \(count) \(count == 1 ? "change" : "changes") to upload. Sync now, then try again."
        case .misplaced(let count):
            return count == 1
                ? "1 record isn't in the right place yet. Sync now, then try again."
                : "\(count) records aren't in the right place yet. Sync now, then try again."
        case .householdAudit(let count):
            return "\(count) \(count == 1 ? "record" : "records") in the household shouldn't be there. Nothing was shared."
        case .offline:
            return "Mango couldn't check iCloud. Try again when you're online."
        }
    }

    // MARK: The member's device

    public static let removedNotice = "You're no longer in this household. Its data was removed from this device."
    public static let accountChangedNotice = "This device's iCloud account changed. Mango removed the previous person's private data."
}
