import Foundation
import GRDB

/// An account's own Sharing section on the Mac (sync-ui, 2026-10-26: sharing lives in the account, not in a sheet or a
/// list in Settings): its owner (the signed-in person or Joint) and its level, what changing them would move, and Save.
///
/// Before ownership is confirmed the section shows what the confirmation would give the account (the admin's, at its
/// default level), and the admin's Save confirms every account with the defaults first (`SharingSetup.confirmDefaults`),
/// then this account's choice. Only the account's owner changes its level; only the admin moves it between theirs and
/// Joint (`SharingLevels.setOwner`).
public enum AccountSharing {
    public struct State: Equatable, Sendable {
        public var accountId: Int64
        public var owner: SharingSetup.Owner
        public var level: SharingLevel
        public var isPropertyLinked: Bool
        /// The owner picker's person: the signed-in person's display name.
        public var ownerName: String
        /// The other person, for the lowering warning.
        public var otherName: String
        /// The signed-in person (the owner picker's "mine").
        public var personId: Int64
        /// The signed-in person may switch the account between theirs and Joint.
        public var canChangeOwner: Bool
        /// The signed-in person may change the level (it is theirs, not joint).
        public var canChangeLevel: Bool
        /// Ownership is confirmed already (otherwise Save confirms the defaults first).
        public var isConfirmed: Bool

        public init(accountId: Int64, owner: SharingSetup.Owner, level: SharingLevel, isPropertyLinked: Bool, ownerName: String, otherName: String,
                    personId: Int64, canChangeOwner: Bool, canChangeLevel: Bool, isConfirmed: Bool) {
            self.accountId = accountId
            self.owner = owner
            self.level = level
            self.isPropertyLinked = isPropertyLinked
            self.ownerName = ownerName
            self.otherName = otherName
            self.personId = personId
            self.canChangeOwner = canChangeOwner
            self.canChangeLevel = canChangeLevel
            self.isConfirmed = isConfirmed
        }

        /// The owner and level the pickers move to when the owner is switched: Joint is Everything; back to the person,
        /// the account's default level (`SharingDefaults`).
        public func choosing(joint: Bool) -> (owner: SharingSetup.Owner, level: SharingLevel) {
            joint ? (.joint, .everything)
                  : (.person(personId), SharingDefaults.level(ownerPersonId: personId, isPropertyLinked: isPropertyLinked))
        }
    }

    /// The account's sharing as the actor sees it. Reads only.
    public static func load(accountId: Int64, actor: AccessActor, db: Database) throws -> State {
        guard let account = try Account.fetchOne(db, key: accountId) else { throw SharingError.accountNotFound }
        let confirmed = try SharingSetup.isConfirmed(db: db)
        let linked = try SharingDefaults.isPropertyLinked(accountId: accountId, db: db)
        let isHouseholdAdmin = actor.isAdmin && (try? AccessActor.admin(db: db).appUserId) == actor.appUserId
        let owner: SharingSetup.Owner
        let level: SharingLevel
        if confirmed || !isHouseholdAdmin {
            owner = account.ownerPersonId.map(SharingSetup.Owner.person) ?? .joint
            level = account.sharingLevel
        } else {
            // What confirming would give it (`SharingSetup.proposal`).
            owner = .person(actor.personId)
            level = SharingDefaults.level(ownerPersonId: actor.personId, isPropertyLinked: linked)
        }
        let canChangeOwner = isHouseholdAdmin && (owner == .joint || owner == .person(actor.personId))
        let ownerName = try String.fetchOne(db, sql: "SELECT displayName FROM appUser WHERE id = ?", arguments: [actor.appUserId]) ?? ""
        return State(accountId: accountId, owner: owner, level: level, isPropertyLinked: linked, ownerName: ownerName,
                     otherName: try SharingOverview.otherName(besides: actor.personId, db: db), personId: actor.personId,
                     canChangeOwner: canChangeOwner, canChangeLevel: owner == .person(actor.personId) && (confirmed || isHouseholdAdmin),
                     isConfirmed: confirmed)
    }

    /// What saving `owner` and `level` would do: the records it moves to another zone (0 before ownership is confirmed:
    /// nothing has been placed by owner yet), whether it lowers what the other person sees, what blocks it. Reads only.
    public struct Preview: Equatable, Sendable {
        public var affectedCount: Int
        public var isLowering: Bool
        public var blockers: [SharingLevels.Blocker]

        public init(affectedCount: Int, isLowering: Bool, blockers: [SharingLevels.Blocker]) {
            self.affectedCount = affectedCount
            self.isLowering = isLowering
            self.blockers = blockers
        }

        public var isBlocked: Bool { !blockers.isEmpty }
    }

    public static func preview(accountId: Int64, owner: SharingSetup.Owner, level: SharingLevel, db: Database) throws -> Preview {
        guard let account = try Account.fetchOne(db, key: accountId) else { throw SharingError.accountNotFound }
        let blockers = try SharingLevels.blockers(accountId: accountId, to: level, db: db)
        let confirmed = try SharingSetup.isConfirmed(db: db)
        let same = owner.personId == account.ownerPersonId && level == account.sharingLevel
        var count = 0
        if blockers.isEmpty, confirmed, !same {
            count = try SyncZoneMoves.placementChanges(from: [:], to: [accountId: .init(owner: owner.personId, level: level)], db: db)
                .filter(\.changesZone).count
        }
        return Preview(affectedCount: count, isLowering: level < account.sharingLevel, blockers: blockers)
    }

    /// Saves the section as `actor`, in the caller's transaction: before ownership is confirmed the admin confirms the
    /// defaults first; then the owner (`SharingLevels.setOwner`) or the level (`SharingLevels.set`). Nothing when
    /// nothing changes.
    public static func apply(owner: SharingSetup.Owner, level: SharingLevel, accountId: Int64, actor: AccessActor, db: Database, now: Date) throws {
        if try !SharingSetup.isConfirmed(db: db) {
            guard actor.isAdmin, try AccessActor.admin(db: db).appUserId == actor.appUserId else { throw SharingError.notAdmin }
            try SharingSetup.confirmDefaults(admin: actor, db: db, now: now)
        }
        guard let account = try Account.fetchOne(db, key: accountId) else { throw SharingError.accountNotFound }
        if owner.personId != account.ownerPersonId {
            try SharingLevels.setOwner(owner, level: level, accountId: accountId, actor: actor, db: db)
        } else if level != account.sharingLevel {
            try SharingLevels.set(level, accountId: accountId, actor: actor, db: db)
        }
    }
}
