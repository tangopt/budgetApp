import Foundation
import GRDB

/// Why a sharing change was refused.
public enum SharingError: Error, Equatable {
    /// Only the admin sets up ownership.
    case notAdmin
    /// The ownership sheet has already been saved; it runs once.
    case alreadyConfirmed
    /// No level can be set before the ownership sheet is saved (sharing spec §7).
    case ownershipNotConfirmed
    /// The set-up rows don't name every account exactly once (one was added or removed meanwhile).
    case rowsDoNotMatchAccounts
    /// The ownership sheet sets owners only on accounts that have none yet.
    case accountAlreadyOwned
    /// The ownership sheet offers the admin or Joint only.
    case ownerMustBeAdminOrJoint
    /// Only the account's (or person's) owner changes its level.
    case notOwner
    /// A joint account is always shared in full.
    case jointMustBeEverything
    /// Hidden is refused while these still point at the account.
    case blocked([SharingLevels.Blocker])
    /// Tax years and income can't be hidden yet (sharing spec §10).
    case notAvailableYet
    case accountNotFound
}

/// The level an account starts at (sharing spec 2026-10-25 §2): joint and property-linked accounts at
/// Everything, a person's own accounts at Balance only. Tax years and income start at Everything for
/// every person.
public enum SharingDefaults {
    /// `ownerPersonId` nil is a joint account; `isPropertyLinked`: the account has a `propertyAccount` row.
    public static func level(ownerPersonId: Int64?, isPropertyLinked: Bool) -> SharingLevel {
        if ownerPersonId == nil || isPropertyLinked { return .everything }
        return .balanceOnly
    }

    public static let taxIncomeLevel: TaxIncomeLevel = .everything

    static func isPropertyLinked(accountId: Int64, db: Database) throws -> Bool {
        try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM propertyAccount WHERE accountId = ?)", arguments: [accountId]) ?? false
    }
}

/// Changing a level after set-up: only the account's owner, never a joint account, and Hidden only once
/// nothing shared still points at the account. Moving the account's records between zones is the push's
/// job; this writes the level only.
public enum SharingLevels {
    public struct Change: Equatable, Sendable {
        public var from: SharingLevel
        public var to: SharingLevel
        public var isLowering: Bool

        public init(from: SharingLevel, to: SharingLevel, isLowering: Bool) {
            self.from = from
            self.to = to
            self.isLowering = isLowering
        }
    }

    /// What keeps an account from going Hidden.
    public enum Blocker: Equatable, Sendable {
        /// The account is linked to a property.
        case propertyLink(propertyName: String)
        /// Property-category transactions of the account, and property or tax rows pointing at its
        /// transactions (sharing spec §10: these are always shared).
        case propertyOrTaxRows(count: Int)
        /// Rows of `table` (`importRule`, `evidenceRequirement`) naming the account.
        case referencedBy(table: String, count: Int)
    }

    /// Property and tax tables whose rows point at a transaction and travel shared (sharing spec §10).
    static let propertyAndTaxTransactionTables = [
        "rentReceiptPayment", "utilityInvoice", "rechargeLine", "rechargePayment", "taxPolicyReceipt", "taxNotClaimed", "taxTransactionOwner",
    ]

    /// Sets the account's level as its owner, in the caller's transaction. Returns the change (from = to
    /// when the level was already `level`; nothing is written then).
    @discardableResult
    public static func set(_ level: SharingLevel, accountId: Int64, actor: AccessActor, db: Database) throws -> Change {
        guard let account = try Account.fetchOne(db, key: accountId) else { throw SharingError.accountNotFound }
        guard try SharingSetup.isConfirmed(db: db) else { throw SharingError.ownershipNotConfirmed }
        guard let owner = account.ownerPersonId else {
            guard level == .everything else { throw SharingError.jointMustBeEverything }
            return Change(from: account.sharingLevel, to: level, isLowering: false)
        }
        guard owner == actor.personId else { throw SharingError.notOwner }
        let change = Change(from: account.sharingLevel, to: level, isLowering: level < account.sharingLevel)
        guard level != account.sharingLevel else { return change }
        let blockers = try blockers(accountId: accountId, to: level, db: db)
        guard blockers.isEmpty else { throw SharingError.blocked(blockers) }

        // The same rule the Mac re-validates an incoming level change with.
        let decision = try AccessAreaMap.area(table: "account", origin: .edit,
                                              change: .update(before: ["ownerPersonId": .int(owner), "sharingLevel": .string(account.sharingLevel.rawValue)]),
                                              changedFields: ["sharingLevel"],
                                              row: ["ownerPersonId": .int(owner), "sharingLevel": .string(level.rawValue)], db: db)
        guard try AccessPolicy.allows(actor, decision, db: db) else { throw SharingError.notOwner }
        try ActorWrite.stamped(actor, origin: .edit, db: db) {
            try db.execute(sql: "UPDATE account SET sharingLevel = ? WHERE id = ?", arguments: [level.rawValue, accountId])
        }
        return change
    }

    /// What stops the account going to `level`: only Hidden has blockers.
    public static func blockers(accountId: Int64, to level: SharingLevel, db: Database) throws -> [Blocker] {
        guard level == .hidden else { return [] }
        var blockers: [Blocker] = try String.fetchAll(db, sql: """
            SELECT property.name FROM propertyAccount JOIN property ON property.id = propertyAccount.propertyId
            WHERE propertyAccount.accountId = ? ORDER BY property.name, property.id
            """, arguments: [accountId]).map { .propertyLink(propertyName: $0) }

        // Each transaction once, however many of these point at it.
        let pointing = propertyAndTaxTransactionTables.map { "SELECT transactionId FROM \($0)" }.joined(separator: " UNION ")
        let propertyOrTax = try Int.fetchOne(db, sql: """
            SELECT COUNT(*) FROM transaction_
            WHERE transaction_.accountId = ?
              AND (transaction_.categoryId IN (SELECT category.id FROM category
                                               JOIN propertyCategoryGroup ON propertyCategoryGroup.categoryGroupId = category.groupId)
                   OR transaction_.id IN (\(pointing)))
            """, arguments: [accountId]) ?? 0
        if propertyOrTax > 0 { blockers.append(.propertyOrTaxRows(count: propertyOrTax)) }

        let rules = try ImportRule.fetchAll(db).filter { rulePossiblyNames($0, accountId: accountId) }.count
        if rules > 0 { blockers.append(.referencedBy(table: ImportRule.databaseTableName, count: rules)) }

        let requirements = try EvidenceRequirement.fetchAll(db).filter { requirement in
            if requirement.excludedAccountIds.contains(accountId) { return true }
            switch requirement.scope {
            case .transactionsMatching(_, let accountIds, _): return accountIds.contains(accountId)
            case .periodic(let entity, _), .single(let entity): return entity == .account(accountId)
            case .transactionsInCategory, .transactionsInCategoryGroup, .recordsOfProperty, .personalIncomeRecords: return false
            }
        }.count
        if requirements > 0 { blockers.append(.referencedBy(table: EvidenceRequirement.databaseTableName, count: requirements)) }
        return blockers
    }

    /// Sets a person's "tax years and income" level, as that person. Only Everything is available: Hidden
    /// throws `notAvailableYet` (the code that would move the records is deferred, sharing spec §10).
    public static func setTaxIncomeLevel(_ level: TaxIncomeLevel, personId: Int64, actor: AccessActor, db: Database) throws {
        guard actor.personId == personId else { throw SharingError.notOwner }
        guard level == .everything else { throw SharingError.notAvailableYet }
        try ActorWrite.stamped(actor, origin: .edit, db: db) {
            try db.execute(sql: """
                INSERT INTO personSharing(personId, taxIncomeLevel) VALUES (?, ?)
                ON CONFLICT(personId) DO UPDATE SET taxIncomeLevel = excluded.taxIncomeLevel
                WHERE taxIncomeLevel != excluded.taxIncomeLevel
                """, arguments: [personId, level.rawValue])
        }
    }

    /// Whether an import rule names the account. Only statement-account and link rules can; one of those
    /// whose action can't be read might, so it counts (Hidden fails closed).
    private static func rulePossiblyNames(_ rule: ImportRule, accountId: Int64) -> Bool {
        switch rule.kind {
        case .statementAccount:
            guard let action = ImportLearning.decode(StatementAccountAction.self, rule.actionJSON) else { return true }
            return action.accountId == accountId
        case .link:
            guard let action = ImportLearning.decode(LinkAction.self, rule.actionJSON) else { return true }
            return action.entity == .account(accountId)
        case .documentKind, .issuer, .figurePosition:
            return false
        }
    }
}
