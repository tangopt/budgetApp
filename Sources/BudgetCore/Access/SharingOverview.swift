import Foundation
import GRDB

/// What Settings ▸ Sharing shows the person signed in (sharing spec 2026-10-25 §3 goal 6, §7): before the ownership
/// sheet, whether they can open it (the admin only); afterwards their own accounts with each level, the joint
/// accounts, and their "tax years and income" level. Read in one go, off the main thread.
public struct SharingOverview: Equatable, Sendable {
    public struct AccountRow: Equatable, Identifiable, Sendable {
        /// The account's id.
        public var id: Int64
        public var displayName: String
        public var bankName: String?
        public var level: SharingLevel

        public init(id: Int64, displayName: String, bankName: String?, level: SharingLevel) {
            self.id = id
            self.displayName = displayName
            self.bankName = bankName
            self.level = level
        }
    }

    /// The ownership sheet has been saved.
    public var isConfirmed: Bool
    /// The person signed in is the admin: only they open the ownership sheet, once.
    public var isAdmin: Bool
    /// Their own accounts, in the usual order (after the sheet; none before).
    public var own: [AccountRow]
    /// The joint accounts, always at Everything (after the sheet; none before).
    public var joint: [AccountRow]
    public var taxIncomeLevel: TaxIncomeLevel
    /// The other person's name, for the level-change warning ("… may already have a copy …").
    public var otherName: String

    public init(isConfirmed: Bool, isAdmin: Bool, own: [AccountRow], joint: [AccountRow], taxIncomeLevel: TaxIncomeLevel, otherName: String) {
        self.isConfirmed = isConfirmed
        self.isAdmin = isAdmin
        self.own = own
        self.joint = joint
        self.taxIncomeLevel = taxIncomeLevel
        self.otherName = otherName
    }

    /// The admin, before the sheet has been saved.
    public var canSetOwners: Bool { isAdmin && !isConfirmed }

    public static func load(actor: AccessActor, db: Database) throws -> SharingOverview {
        let confirmed = try SharingSetup.isConfirmed(db: db)
        var own: [AccountRow] = [], joint: [AccountRow] = []
        if confirmed {
            for account in try AccountOrdering.sorted(try Account.fetchAll(db)) {
                guard let id = account.id else { continue }
                let row = AccountRow(id: id, displayName: account.displayName, bankName: account.bankName, level: account.sharingLevel)
                if account.ownerPersonId == nil { joint.append(row) } else if account.ownerPersonId == actor.personId { own.append(row) }
            }
        }
        let taxIncome = try PersonSharing.filter(Column("personId") == actor.personId).fetchOne(db)?.taxIncomeLevel ?? SharingDefaults.taxIncomeLevel
        return SharingOverview(isConfirmed: confirmed, isAdmin: actor.isAdmin, own: own, joint: joint, taxIncomeLevel: taxIncome,
                               otherName: try otherName(besides: actor.personId, db: db))
    }

    /// The other person as the app shows them: their app user's display name, else their name; "The other person"
    /// when there's nobody else yet.
    static func otherName(besides personId: Int64, db: Database) throws -> String {
        if let user = try AppUser.filter(Column("personId") != personId).order(Column("isAdmin").desc, Column("id")).fetchOne(db) {
            return user.displayName
        }
        return try String.fetchOne(db, sql: "SELECT name FROM person WHERE id != ? ORDER BY id LIMIT 1", arguments: [personId])
            ?? SharingCopy.otherPersonFallback
    }

    /// What changing one of the actor's accounts to `level` would do, for the confirmation (`SharingCopy.moves`):
    /// the records it moves, and what blocks it (Hidden only). Reads only.
    public struct LevelChangePreview: Equatable, Sendable {
        public var accountId: Int64
        public var from: SharingLevel
        public var to: SharingLevel
        public var affectedCount: Int
        public var blockers: [SharingLevels.Blocker]

        public init(accountId: Int64, from: SharingLevel, to: SharingLevel, affectedCount: Int, blockers: [SharingLevels.Blocker]) {
            self.accountId = accountId
            self.from = from
            self.to = to
            self.affectedCount = affectedCount
            self.blockers = blockers
        }

        public var isLowering: Bool { to < from }
        public var isBlocked: Bool { !blockers.isEmpty }
    }

    public static func preview(accountId: Int64, to level: SharingLevel, db: Database) throws -> LevelChangePreview {
        guard let account = try Account.fetchOne(db, key: accountId) else { throw SharingError.accountNotFound }
        let blockers = try SharingLevels.blockers(accountId: accountId, to: level, db: db)
        return LevelChangePreview(accountId: accountId, from: account.sharingLevel, to: level,
                                  affectedCount: blockers.isEmpty ? try SharingLevels.affectedCount(accountId: accountId, to: level, db: db) : 0,
                                  blockers: blockers)
    }
}
