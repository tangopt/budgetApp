import Foundation
import GRDB

/// The one-time "Who owns each account?" sheet (sharing spec 2026-10-25 §7): the admin gives every account
/// its owner (themselves or Joint) and starting level, once, on the Mac.
///
/// Its rule, which the area map applies too (`AccessAreaMap`): only the admin, only while ownership is
/// unconfirmed (no `personSharing.ownershipConfirmedAt` yet), only through `save`. Afterwards only an
/// account's owner changes its level (`SharingLevels.set`) and nobody changes an owner (a deliberate later
/// flow, not step 6).
public enum SharingSetup {
    public enum Owner: Equatable, Sendable {
        case person(Int64)
        case joint

        var personId: Int64? {
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

    /// Whether the ownership sheet has been saved.
    public static func isConfirmed(db: Database) throws -> Bool {
        try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM personSharing WHERE ownershipConfirmedAt IS NOT NULL)") ?? false
    }

    /// Every account in the usual order, owned by the admin at its default level (`SharingDefaults`).
    public static func proposal(admin: AccessActor, db: Database) throws -> [Row] {
        guard admin.isAdmin else { throw SharingError.notAdmin }
        return try AccountOrdering.sorted(try Account.fetchAll(db)).map { account in
            let linked = try SharingDefaults.isPropertyLinked(accountId: account.id!, db: db)
            return Row(id: account.id!, displayName: account.displayName, bankName: account.bankName, isPropertyLinked: linked,
                       owner: .person(admin.personId), level: SharingDefaults.level(ownerPersonId: admin.personId, isPropertyLinked: linked))
        }
    }

    /// Saves the sheet as the admin, in the caller's transaction: every account's owner and level, a
    /// `personSharing` row for every person (Everything; existing rows kept), `ownershipConfirmedAt = now`
    /// on the admin's row, and the default permissions of every member. Refused (nothing written) unless
    /// `admin` is the admin, ownership is unconfirmed, `rows` name every account exactly once, each owner is
    /// the admin or Joint, every joint row is at Everything and no Hidden row has blockers.
    public static func save(_ rows: [Row], admin: AccessActor, db: Database, now: Date) throws {
        guard admin.isAdmin else { throw SharingError.notAdmin }
        guard try !isConfirmed(db: db) else { throw SharingError.alreadyConfirmed }
        let accountIds = try Int64.fetchAll(db, sql: "SELECT id FROM account ORDER BY id")
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

        try ActorWrite.perform(admin, area: .householdSettings, db: db) {
            for row in rows {
                try db.execute(sql: "UPDATE account SET ownerPersonId = ?, sharingLevel = ? WHERE id = ?",
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
