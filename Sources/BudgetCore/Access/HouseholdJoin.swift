import Foundation

/// What a member's device shows while it joins the household (step 7a): accepting the share, the key exchange's code,
/// the first pull, and the ways it can stop. Pure: the phone's controller feeds it what the key exchange and the sync
/// report; the screen and its snapshot routes only draw it. The admin's phone never has one (`Plan.ownZones`).
public enum HouseholdJoinState: Equatable, Sendable {
    /// Why joining is taking long (shown under "Still joining…", with Retry).
    public enum Reason: Equatable, Sendable {
        /// The invitation couldn't be accepted in iCloud (offline, iCloud busy).
        case acceptFailed
        case offline
        /// The pull ran and found no household in the shared database yet.
        case notShownYet
        /// Sync stopped for a reason of its own (`SyncStatus.failed`).
        case syncStopped(String)
        case noAccount
    }

    /// The invitation is being accepted in iCloud.
    case accepting
    /// The key request is posted; the Mac hasn't answered.
    case waitingForKey
    /// The 6-digit code to check against the Mac's.
    case showCode(String)
    /// The key arrived; the first household pull is under way.
    case pulling
    /// The grant didn't open: nothing was stored.
    case refused
    /// The request ran out, or another of her devices replaced it.
    case expired
    /// Accepted (or tried), but the household hasn't reached this device.
    case stillJoining(Reason)
    /// The invitation can't be used on this device.
    case cannotJoin(String)
    /// Removed from the household (`HouseholdCopy.removedNotice`).
    case removed

    /// What the key exchange reported. `.received` is "pulling": the first pull follows.
    public init(requester status: SyncKeyExchange.Requester.Status) {
        switch status {
        case .waitingForMac: self = .waitingForKey
        case .showCode(let code): self = .showCode(code)
        case .received: self = .pulling
        case .refused: self = .refused
        case .expired: self = .expired
        }
    }

    /// After the key: what the sync's status says of the first household pull. `joined`: a household pull through the
    /// shared database has succeeded (`SyncHouseholdMembership.hasJoined`): then there is nothing to show (nil).
    public static func afterPull(status: SyncStatus, joined: Bool) -> HouseholdJoinState? {
        if joined { return nil }
        switch status {
        case .syncing, .off, .idle(lastSync: nil): return .pulling
        case .idle, .needsAttention: return .stillJoining(.notShownYet)
        case .waitingForKey: return .waitingForKey
        case .offline: return .stillJoining(.offline)
        case .unavailable: return .stillJoining(.noAccount)
        case .failed(let reason): return .stillJoining(.syncStopped(reason))
        }
    }

    /// Whether the screen offers "Start again" (a new key request).
    public var offersStartAgain: Bool {
        switch self {
        case .refused, .expired: return true
        default: return false
        }
    }

    /// Whether the screen offers "Retry".
    public var offersRetry: Bool {
        if case .stillJoining = self { return true }
        return false
    }

    /// What this device does at a start, from its membership and whether it holds the household key.
    public enum Plan: Equatable, Sendable {
        /// No membership: the admin's phone (or one that never joined). Its own zones, exactly as before.
        case ownZones
        /// A member without the household key: no sync, the key exchange.
        case exchangeKey
        /// A member with the key: the household through the shared database.
        case pullHousehold
    }

    public static func plan(owner: String?, keyHeld: Bool) -> Plan {
        guard owner != nil else { return .ownZones }
        return keyHeld ? .pullHousehold : .exchangeKey
    }
}

extension HouseholdCopy {
    // MARK: Joining (the member's device)

    public static let joiningTitle = "Joining the household…"
    public static let joiningDetail = "Accepting the invitation in iCloud."
    public static let checkCodeTitle = "Check this code matches the one on the Mac"
    public static let checkCodeDetail = "Waiting for the household key. Nothing is shared until the code is confirmed on the Mac."
    public static let pullingTitle = "Getting the household's records…"
    public static let stillJoiningTitle = "Still joining…"
    public static let retryButton = "Retry"
    public static let startAgainButton = "Start again"
    public static let okButton = "OK"
    public static let keyRefused = "The household key didn't arrive safely, so nothing was stored on this device."
    public static let keyExpired = "The request ran out of time, or another device of yours replaced it."
    public static let wrongHousehold = "This invitation isn't for this app, or isn't a household invitation."
    public static let alreadyMember = "This device already belongs to a household. Leave it before joining another."
    public static let syncOff = "Sync is off in this build of Mango, so it can't join the household."
    public static let hasOwnData = "This device already holds a household's data, so it can't join another."

    public static func stillJoiningReason(_ reason: HouseholdJoinState.Reason) -> String {
        switch reason {
        case .acceptFailed: return "iCloud couldn't accept the invitation yet."
        case .offline: return "This device can't reach iCloud right now."
        case .notShownYet: return "iCloud hasn't shown the household to this device yet. That can take a few minutes."
        case .syncStopped(let why): return "Sync stopped: \(why)."
        case .noAccount: return "Sign in to iCloud to join."
        }
    }
}
