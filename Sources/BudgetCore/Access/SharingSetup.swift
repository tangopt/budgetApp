import Foundation
import GRDB

/// Confirming who owns each account (sharing spec 2026-10-25 §7), once, on the Mac, as the admin: every account
/// without an owner gets one (the admin, or Joint) and its starting level. Since sync-ui (2026-10-26) there is no
/// sheet for it: the turn-on's start and an account's Sharing section confirm the defaults (`confirmDefaults`).
///
/// Its rule, which the area map applies too (`AccessAreaMap`): only the admin, only while ownership is
/// unconfirmed (no `personSharing.ownershipConfirmedAt` yet), only through `save`. Afterwards only an
/// account's owner changes its level (`SharingLevels.set`), and only the admin moves an account between
/// theirs and Joint (`SharingLevels.setOwner`).
public enum SharingSetup {
    public enum Owner: Equatable, Sendable {
        case person(Int64)
        case joint

        public var personId: Int64? {
            if case .person(let id) = self { return id }
            return nil
        }
    }

    /// One account on the sheet.
    public struct Row: Equatable, Identifiable, Sendable {
        /// The account's id.
        public var id: Int64
        public var displayName: String
        public var bankName: String?
        public var isPropertyLinked: Bool
        public var owner: Owner
        public var level: SharingLevel

        public init(id: Int64, displayName: String, bankName: String?, isPropertyLinked: Bool, owner: Owner, level: SharingLevel) {
            self.id = id
            self.displayName = displayName
            self.bankName = bankName
            self.isPropertyLinked = isPropertyLinked
            self.owner = owner
            self.level = level
        }
    }

    /// Whether the ownership sheet has been saved: the admin's `personSharing` row (the first admin app
    /// user's person) has `ownershipConfirmedAt`. Anyone else's row counts for nothing.
    public static func isConfirmed(db: Database) throws -> Bool {
        try Bool.fetchOne(db, sql: """
            SELECT EXISTS (SELECT 1 FROM personSharing
                           WHERE ownershipConfirmedAt IS NOT NULL
                             AND personId = (SELECT personId FROM appUser WHERE isAdmin = 1 ORDER BY id LIMIT 1))
            """) ?? false
    }

    /// Every account without an owner yet, in the usual order, owned by the admin at its default level
    /// (`SharingDefaults`). An account that already has an owner keeps it and isn't on the sheet.
    public static func proposal(admin: AccessActor, db: Database) throws -> [Row] {
        guard admin.isAdmin else { throw SharingError.notAdmin }
        return try AccountOrdering.sorted(try Account.filter(Column("ownerPersonId") == nil).fetchAll(db)).map { account in
            let linked = try SharingDefaults.isPropertyLinked(accountId: account.id!, db: db)
            return Row(id: account.id!, displayName: account.displayName, bankName: account.bankName, isPropertyLinked: linked,
                       owner: .person(admin.personId), level: SharingDefaults.level(ownerPersonId: admin.personId, isPropertyLinked: linked))
        }
    }

    /// Saves the sheet as the admin, in the caller's transaction and in one savepoint (a failure part-way
    /// leaves nothing behind, even when the caller catches it): every unowned account's owner and level, a
    /// `personSharing` row for every person (Everything; existing rows kept), `ownershipConfirmedAt = now`
    /// on the admin's row, and the default permissions of every member. Refused (nothing written) unless
    /// `admin` is the admin, ownership is unconfirmed, no row names an account that already has an owner
    /// (`accountAlreadyOwned`, as the area map's set-up rule), `rows` name every unowned account exactly once,
    /// each owner is the admin or Joint, every joint row is at Everything and no Hidden row has blockers.
    public static func save(_ rows: [Row], admin: AccessActor, db: Database, now: Date) throws {
        guard admin.isAdmin else { throw SharingError.notAdmin }
        guard try !isConfirmed(db: db) else { throw SharingError.alreadyConfirmed }
        let owned = Set(try Int64.fetchAll(db, sql: "SELECT id FROM account WHERE ownerPersonId IS NOT NULL"))
        guard rows.allSatisfy({ !owned.contains($0.id) }) else { throw SharingError.accountAlreadyOwned }
        let accountIds = try Int64.fetchAll(db, sql: "SELECT id FROM account WHERE ownerPersonId IS NULL ORDER BY id")
        guard rows.map(\.id).sorted() == accountIds else { throw SharingError.rowsDoNotMatchAccounts }
        for row in rows {
            switch row.owner {
            case .joint:
                guard row.level == .everything else { throw SharingError.jointMustBeEverything }
            case .person(let personId):
                guard personId == admin.personId else { throw SharingError.ownerMustBeAdminOrJoint }
                let blockers = try SharingLevels.blockers(accountId: row.id, to: row.level, db: db)
                guard blockers.isEmpty else { throw SharingError.blocked(blockers) }
            }
        }

        try db.inSavepoint {
            // Records were placed (if at all) with every account joint at Everything: the next push's reconcile moves
            // those the sheet makes private (`SyncZoneMoves.reconcile`).
            let before = try SyncZoneMoves.currentFacts(db: db)
            try write(rows, admin: admin, db: db, now: now)
            try SyncZoneMoves.storeFacts(before, db: db, now: now)
            return .commit
        }
    }

    /// Confirms ownership with the defaults, as the admin, when it isn't confirmed yet: every unowned account the
    /// admin's at its default level (`proposal`: property-linked at Everything, the rest at Balance only). Nothing
    /// when already confirmed (owners and levels set since are kept). The turn-on's start and an account's Sharing
    /// section use it, so no separate ownership step is needed; the admin changes owners and levels per account
    /// afterwards. Returns how many accounts it gave an owner.
    @discardableResult
    public static func confirmDefaults(admin: AccessActor, db: Database, now: Date) throws -> Int {
        guard admin.isAdmin else { throw SharingError.notAdmin }
        guard try !isConfirmed(db: db) else { return 0 }
        let rows = try proposal(admin: admin, db: db)
        try save(rows, admin: admin, db: db, now: now)
        return rows.count
    }

    private static func write(_ rows: [Row], admin: AccessActor, db: Database, now: Date) throws {
        try ActorWrite.perform(admin, area: .householdSettings, db: db) {
            for row in rows {
                try db.execute(sql: "UPDATE account SET ownerPersonId = ?, sharingLevel = ? WHERE id = ? AND ownerPersonId IS NULL",
                               arguments: [row.owner.personId, row.level.rawValue, row.id])
            }
            try db.execute(sql: """
                INSERT INTO personSharing(personId, taxIncomeLevel) SELECT id, ? FROM person WHERE true
                ON CONFLICT(personId) DO NOTHING
                """, arguments: [SharingDefaults.taxIncomeLevel.rawValue])
            try db.execute(sql: "UPDATE personSharing SET ownershipConfirmedAt = ? WHERE personId = ?", arguments: [now, admin.personId])
            for appUserId in try Int64.fetchAll(db, sql: "SELECT id FROM appUser WHERE isAdmin = 0 ORDER BY id") {
                try MemberPermissions.ensureDefaults(appUserId: appUserId, db: db)
            }
        }
    }
}
