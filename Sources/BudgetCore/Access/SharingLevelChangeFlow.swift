import Foundation

/// The steps of changing one of your accounts' levels in Settings ▸ Sharing (sharing spec §3 goal 4), as a value the
/// Mac's settings model drives: a level picked opens one confirmation, its records are counted off the main thread
/// (`SharingOverview.preview`), and Change runs only once they are, never when Hidden is blocked and never twice.
/// A count or a result that comes back for a confirmation no longer open is dropped. Nothing is written by picking.
public struct SharingLevelChangeFlow: Equatable, Sendable {
    /// The confirmation open now.
    public struct Pending: Equatable, Identifiable, Sendable {
        public let account: SharingOverview.AccountRow
        public let to: SharingLevel
        /// nil while the records to move are counted.
        public var preview: SharingOverview.LevelChangePreview?
        public var isChanging = false
        public var error: String?
        /// Tells apart two confirmations of the same account and level opened one after the other.
        public let serial: Int

        public init(account: SharingOverview.AccountRow, to: SharingLevel, preview: SharingOverview.LevelChangePreview? = nil, serial: Int = 0) {
            self.account = account
            self.to = to
            self.preview = preview
            self.serial = serial
        }

        public var id: String { "\(account.id)-\(to.rawValue)-\(serial)" }
        /// Change can be pressed: counted, not blocked, not already running.
        public var canChange: Bool { preview.map { !$0.isBlocked } == true && !isChanging }
    }

    public private(set) var pending: Pending?
    private var serial = 0

    public init(pending: Pending? = nil) {
        self.pending = pending
    }

    /// Opens the confirmation for `level` on `account`; returns its id, which the count and the result come back
    /// with. nil (nothing opens) for the level the account has, or while another confirmation is open.
    public mutating func request(_ level: SharingLevel, for account: SharingOverview.AccountRow) -> String? {
        guard level != account.level, pending == nil else { return nil }
        serial += 1
        let change = Pending(account: account, to: level, serial: serial)
        pending = change
        return change.id
    }

    /// The records counted for confirmation `id`; dropped when it is no longer the one open.
    public mutating func counted(_ preview: SharingOverview.LevelChangePreview, for id: String) {
        guard pending?.id == id else { return }
        pending?.preview = preview
    }

    /// The count or the change for `id` failed.
    public mutating func failed(_ message: String, for id: String) {
        guard pending?.id == id else { return }
        pending?.isChanging = false
        pending?.error = message
    }

    /// Change pressed: the account and level to set, or nil when Change isn't possible now.
    public mutating func beginChange() -> (id: String, accountId: Int64, level: SharingLevel)? {
        guard let change = pending, change.canChange else { return nil }
        pending?.isChanging = true
        pending?.error = nil
        return (change.id, change.account.id, change.to)
    }

    /// The level was set: the confirmation closes.
    public mutating func changed(_ id: String) {
        guard pending?.id == id else { return }
        pending = nil
    }

    /// Cancel (or the sheet dismissed): closes the confirmation, except while the change is running.
    public mutating func cancel() {
        guard pending?.isChanging != true else { return }
        pending = nil
    }
}

extension SharingSetup.Row {
    /// The ownership sheet's owner picker: Joint locks the level to Everything; back to the admin, the account
    /// takes its default level again (`SharingDefaults`).
    public mutating func setJoint(_ joint: Bool, adminPersonId: Int64) {
        guard joint != (owner == .joint) else { return }
        if joint {
            owner = .joint
            level = .everything
        } else {
            owner = .person(adminPersonId)
            level = SharingDefaults.level(ownerPersonId: adminPersonId, isPropertyLinked: isPropertyLinked)
        }
    }
}
