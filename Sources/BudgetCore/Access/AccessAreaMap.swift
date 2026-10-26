import Foundation
import GRDB

/// What kind of change is being judged. An update carries the record as this device held it before, which
/// is what property money and a tax row's person are judged on (the after state grants nothing).
public enum AccessChange: Equatable, Sendable {
    case insert
    case update(before: [String: SyncValue])
    /// `row` is the record's last state.
    case delete
}

/// What a change needs from its writer.
public indirect enum AccessDecision: Equatable, Sendable {
    /// Edit in this area.
    case area(AccessArea)
    /// The writer must be this person (an account's owner, a person's own sharing); nil: nobody may.
    case ownerOnly(personId: Int64?)
    /// Every one of these.
    case allOf([AccessDecision])
    /// Nobody (a table no rule knows).
    case denied

    /// The areas whose Edit it needs.
    public var areas: [AccessArea] {
        switch self {
        case .area(let area): return [area]
        case .allOf(let parts): return parts.flatMap(\.areas)
        case .ownerOnly, .denied: return []
        }
    }

    /// One decision for all of `parts`: the single one when there is one, duplicates removed; denied when
    /// a part can be met by nobody.
    static func all(_ parts: [AccessDecision]) -> AccessDecision {
        var unique: [AccessDecision] = []
        for part in parts.flatMap({ part -> [AccessDecision] in if case .allOf(let inner) = part { return inner } else { return [part] } })
        where !unique.contains(part) {
            unique.append(part)
        }
        if unique.contains(where: \.containsNobody) { return .denied }
        return unique.count == 1 ? unique[0] : .allOf(unique)
    }
}

/// Which permission a change needs (sharing spec 2026-10-25 §10).
///
/// - An origin counts only on the tables that kind of write produces (an import's batch, statement and
///   document tables; matching's link tables; document links). Any other table under any origin is judged
///   by its table, so a self-declared origin grants nothing beyond what that write could have made.
/// - A transaction change touching only its category, note, status and how it was categorised is Property
///   when the transaction, as it was before the change, is property money (a property-linked account at
///   Everything, or a property category). Any other transaction change is Budget & accounts.
/// - A tax row needs Edit on the tax of every person it names, before and after the change; a row whose
///   transaction has no owner belongs to every owner of its property; a row naming no one is the admin's.
/// - An account's owner and level, its summaries, and a person's tax-and-income level are the owner's alone.
/// - A table no rule knows is denied.
///
/// `row` (and `before`) hold a record's synced columns. A reference may be this device's local id
/// (`.int`) or the referenced record's UUID (`.string`, as a payload carries it); both resolve here.
public enum AccessAreaMap {
    static let summaryTables: Set<String> = ["accountBalancePoint", "accountSummaryMonth"]
    /// `account` columns only the owner sets.
    static let ownerOnlyAccountFields: Set<String> = ["ownerPersonId", "sharingLevel"]
    /// `personSharing` columns only that person sets.
    static let ownerOnlyPersonSharingFields: Set<String> = ["taxIncomeLevel"]
    /// Transaction fields a member with Property may set on property money.
    static let propertyTransactionFields: Set<String> = ["categoryId", "note", "status", "categorizedBy"]
    /// `account` columns an import's statement check writes.
    static let statementCheckFields: Set<String> = [
        "statementMismatchMinorUnits", "statementMismatchDate", "statementMismatchClosingMinorUnits", "statementLastCheckedDate",
    ]

    /// The tables each origin's writes produce, where the origin decides the area.
    private static let originTables: [WriteOrigin: Set<String>] = [
        .import: ["importRun", "importBatch", "importChange", "importRunFile", "importProfile", "importWaitingFile",
                  "transaction_", "transferLink", "balanceSnapshot", "balanceSnapshotArchive", "document", "documentLink"],
        .propertyMatching: ["rechargePayment", "rechargeLine", "rentReceiptPayment", "utilityInvoice"],
        .documentLink: ["document", "documentLink"],
    ]
    private static let originAreas: [WriteOrigin: AccessArea] = [.import: .import, .propertyMatching: .property, .documentLink: .documents]

    private static let byTable: [String: AccessArea] = {
        var map: [String: AccessArea] = [:]
        for table in ["account", "transaction_", "transferLink", "balanceSnapshot", "balanceSnapshotArchive", "payPeriod", "payMonthClose"] {
            map[table] = .budgetAndAccounts
        }
        for table in ["category", "categoryGroup", "rule", "importRule", "taxExpenseTypeMap"] { map[table] = .rulesAndCategories }
        for table in ["forecastGroup", "forecastEntry", "plannedOccurrenceException", "scenario", "scenarioApplication"] { map[table] = .forecast }
        for table in ["mortgageRateOverride", "interestIndexValue", "propertyCheckDecision", "evidenceRequirement", "evidenceWaiver"] {
            map[table] = .property
        }
        for table in ["document", "documentLink", "customDocumentKind"] { map[table] = .documents }
        for table in ["importRun", "importBatch", "importChange", "importRunFile", "importProfile", "importWaitingFile"] { map[table] = .import }
        for table in ["hmrcRate", "taxAttributionRule", "rechargeNettingRule", "exchangeRateSetting", "person", "appUser",
                      "memberPermission", "personSharing"] {
            map[table] = .householdSettings
        }
        return map
    }()

    /// Property's records by prefix (`property*`, `tenancy*`, `rentReceipt*`, `utility*`, `recharge*`), after
    /// the explicit tables above (so `rechargeNettingRule` stays Household settings).
    private static let propertyPrefixes = ["property", "tenancy", "rentReceipt", "utility", "recharge"]

    /// Tax tables whose rows name their person in `personId`.
    private static let taxTablesWithPerson: Set<String> = [
        "employment", "otherIncome", "pensionContribution", "hmrcPayment", "taxYear", "taxFiledBox", "taxYearSplit",
        "taxManualItem", "taxTransactionOwner",
    ]
    /// Tax tables whose person is the owning record's.
    private static let taxTablesWithoutPerson: Set<String> = ["employmentIncome", "benefitInKind", "taxPolicyReceipt", "taxNotClaimed"]

    /// What a change to `table` needs. `changedFields` are the synced columns the change sets (every column
    /// for an insert); `row` is the record after the change (its last state for a delete).
    public static func area(table: String, origin: WriteOrigin?, change: AccessChange, changedFields: Set<String>,
                            row: [String: SyncValue], db: Database) throws -> AccessDecision {
        guard SyncSchema.table(table) != nil else { return .denied }
        let before: [String: SyncValue]? = if case .update(let before) = change { before } else { nil }
        let judged = change == .delete ? row : before

        if summaryTables.contains(table) {
            var accounts = [row["accountId"]]
            if let before { accounts.append(before["accountId"]) }
            return .all(try accounts.map { .ownerOnly(personId: try accountOwner($0, db: db)) })
        }
        if let origin, let tables = originTables[origin], tables.contains(table), let area = originAreas[origin],
           table != "account" {
            return .area(area)
        }
        if origin == .import, table == "account", !changedFields.isEmpty, changedFields.isSubset(of: statementCheckFields) {
            return .area(.import)
        }
        if taxTablesWithPerson.contains(table) || taxTablesWithoutPerson.contains(table) {
            var people = try taxPeople(table: table, row: row, db: db)
            if let before { people.formUnion(try taxPeople(table: table, row: before, db: db)) }
            return .all(try people.sorted().map { .area(.tax(personUuid: try SyncRecordStore.uuid(for: "person", localId: $0, db: db))) })
        }
        switch table {
        case "transaction_":
            if let judged, !changedFields.isEmpty, changedFields.isSubset(of: propertyTransactionFields),
               try isPropertyMoney(judged, db: db) {
                return .area(.property)
            }
            return .area(.budgetAndAccounts)
        case "account":
            return try accountDecision(change: change, changedFields: changedFields, row: row, db: db)
        case "personSharing":
            var parts: [AccessDecision] = []
            if !changedFields.subtracting(ownerOnlyPersonSharingFields).isEmpty || change == .delete { parts.append(.area(.householdSettings)) }
            let setsLevel: Bool
            switch change {
            case .insert: setsLevel = row["taxIncomeLevel"].map { $0 != .string(TaxIncomeLevel.everything.rawValue) } ?? false
            case .update: setsLevel = !changedFields.isDisjoint(with: ownerOnlyPersonSharingFields)
            case .delete: setsLevel = false
            }
            if setsLevel { parts.append(.ownerOnly(personId: try localId((judged ?? row)["personId"], table: "person", db: db))) }
            return parts.isEmpty ? .area(.householdSettings) : .all(parts)
        default:
            break
        }
        if let area = byTable[table] { return .area(area) }
        if propertyPrefixes.contains(where: { table.hasPrefix($0) }) { return .area(.property) }
        return .denied
    }

    /// The area a table's rows belong to when neither an origin nor a special rule decides: what a reverted change
    /// is logged under when the part it failed names no area (an owner's say, a table nobody may write). Nil for a
    /// tax table (each row is a person's) and a table no rule knows.
    static func tableArea(_ table: String) -> AccessArea? {
        if summaryTables.contains(table) { return .budgetAndAccounts }
        if let area = byTable[table] { return area }
        if taxTablesWithPerson.contains(table) || taxTablesWithoutPerson.contains(table) { return nil }
        if propertyPrefixes.contains(where: { table.hasPrefix($0) }) { return .property }
        return nil
    }

    /// Whether a change to these fields of `table` includes a part only an owner may make: any write to a
    /// summary table, an account's owner or level, a person's tax-and-income level.
    public static func isOwnerOnly(table: String, fields: Set<String>) -> Bool {
        if summaryTables.contains(table) { return true }
        if table == "account" { return !fields.isDisjoint(with: ownerOnlyAccountFields) }
        if table == "personSharing" { return !fields.isDisjoint(with: ownerOnlyPersonSharingFields) }
        return false
    }

    // MARK: Accounts

    /// Budget & accounts, plus the owner's say for a level change. A new account names its owner (who must
    /// be the writer) unless it is joint at Everything; a level change is judged on the owner before it; a
    /// joint account's level is nobody's to change, and after set-up nobody changes an owner. The one
    /// exception is the ownership sheet: while ownership is unconfirmed, the admin (with Household settings)
    /// sets the owner and level of an account that has no owner yet.
    private static func accountDecision(change: AccessChange, changedFields: Set<String>, row: [String: SyncValue],
                                        db: Database) throws -> AccessDecision {
        var parts: [AccessDecision] = []
        let others = changedFields.subtracting(ownerOnlyAccountFields)
        switch change {
        case .insert:
            parts.append(.area(.budgetAndAccounts))
            let owner = try localId(row["ownerPersonId"], table: "person", db: db)
            let level = row["sharingLevel"]
            if owner != nil {
                parts.append(.ownerOnly(personId: owner))
            } else if let level, level != .string(SharingLevel.everything.rawValue), level != .null {
                parts.append(.denied)
            }
        case .update(let before):
            if !others.isEmpty { parts.append(.area(.budgetAndAccounts)) }
            if !changedFields.isDisjoint(with: ownerOnlyAccountFields) {
                let owner = try localId(before["ownerPersonId"], table: "person", db: db)
                if owner == nil, try !SharingSetup.isConfirmed(db: db) {
                    // The ownership sheet (`SharingSetup`): the admin, once, on accounts with no owner yet.
                    parts.append(.area(.householdSettings))
                    parts.append(.ownerOnly(personId: try Int64.fetchOne(db, sql: "SELECT personId FROM appUser WHERE isAdmin = 1 ORDER BY id LIMIT 1")))
                } else if changedFields.contains("ownerPersonId") {
                    // After set-up nobody changes an owner (a deliberate later flow, not step 6).
                    parts.append(.denied)
                } else {
                    parts.append(.ownerOnly(personId: owner))
                }
            }
        case .delete:
            parts.append(.area(.budgetAndAccounts))
            if let owner = try localId(row["ownerPersonId"], table: "person", db: db) { parts.append(.ownerOnly(personId: owner)) }
        }
        return .all(parts.isEmpty ? [.area(.budgetAndAccounts)] : parts)
    }

    private static func accountOwner(_ value: SyncValue?, db: Database) throws -> Int64? {
        guard let accountId = try localId(value, table: "account", db: db) else { return nil }
        return try Int64.fetchOne(db, sql: "SELECT ownerPersonId FROM account WHERE id = ?", arguments: [accountId])
    }

    // MARK: Transactions

    /// Property money: a transaction of a property-linked account at Everything, or one in a property's category.
    private static func isPropertyMoney(_ row: [String: SyncValue], db: Database) throws -> Bool {
        if let accountId = try localId(row["accountId"], table: "account", db: db),
           try Bool.fetchOne(db, sql: """
               SELECT EXISTS (SELECT 1 FROM account JOIN propertyAccount ON propertyAccount.accountId = account.id
                              WHERE account.id = ? AND account.sharingLevel = ?)
               """, arguments: [accountId, SharingLevel.everything.rawValue]) == true {
            return true
        }
        if let categoryId = try localId(row["categoryId"], table: "category", db: db),
           try Bool.fetchOne(db, sql: """
               SELECT EXISTS (SELECT 1 FROM category JOIN propertyCategoryGroup ON propertyCategoryGroup.categoryGroupId = category.groupId
                              WHERE category.id = ?)
               """, arguments: [categoryId]) == true {
            return true
        }
        return false
    }

    // MARK: Tax

    /// The people whose tax the row is: its `personId`, else the owning record's people, else the admin.
    private static func taxPeople(table: String, row: [String: SyncValue], db: Database) throws -> Set<Int64> {
        let people = try namedTaxPeople(table: table, row: row, db: db)
        if !people.isEmpty { return people }
        guard let admin = try Int64.fetchOne(db, sql: "SELECT personId FROM appUser WHERE isAdmin = 1 ORDER BY id LIMIT 1") else {
            throw AccessAreaMapError.noPersonForTaxRow(table: table)
        }
        return [admin]
    }

    private static func namedTaxPeople(table: String, row: [String: SyncValue], db: Database) throws -> Set<Int64> {
        if let personId = try localId(row["personId"], table: "person", db: db) { return [personId] }
        switch table {
        case "employmentIncome", "benefitInKind":
            guard let employmentId = try localId(row["employmentId"], table: "employment", db: db) else { return [] }
            return Set(try Int64.fetchAll(db, sql: "SELECT personId FROM employment WHERE id = ?", arguments: [employmentId]))
        case "taxNotClaimed":
            if let itemId = try localId(row["manualItemId"], table: "taxManualItem", db: db) {
                return Set(try Int64.fetchAll(db, sql: "SELECT personId FROM taxManualItem WHERE id = ?", arguments: [itemId]))
            }
            if let transactionId = try localId(row["transactionId"], table: "transaction_", db: db) {
                return try transactionPeople(transactionId, propertyId: nil, db: db)
            }
            if let receiptId = try localId(row["policyReceiptId"], table: "taxPolicyReceipt", db: db),
               let receipt = try Row.fetchOne(db, sql: "SELECT transactionId, propertyId FROM taxPolicyReceipt WHERE id = ?", arguments: [receiptId]) {
                return try receiptPeople(transactionId: receipt["transactionId"], propertyId: receipt["propertyId"], db: db)
            }
            return []
        case "taxPolicyReceipt":
            return try receiptPeople(transactionId: try localId(row["transactionId"], table: "transaction_", db: db),
                                     propertyId: try localId(row["propertyId"], table: "property", db: db), db: db)
        default:
            return []
        }
    }

    private static func receiptPeople(transactionId: Int64?, propertyId: Int64?, db: Database) throws -> Set<Int64> {
        if let transactionId { return try transactionPeople(transactionId, propertyId: propertyId, db: db) }
        guard let propertyId else { return [] }
        return try propertyOwners([propertyId], db: db)
    }

    /// The transaction's tax owner; without one, every owner of its property (the one given, else the
    /// properties its category belongs to): a split transaction is each owner's tax.
    private static func transactionPeople(_ transactionId: Int64, propertyId: Int64?, db: Database) throws -> Set<Int64> {
        let owners = Set(try Int64.fetchAll(db, sql: "SELECT personId FROM taxTransactionOwner WHERE transactionId = ?", arguments: [transactionId]))
        if !owners.isEmpty { return owners }
        let properties = try propertyId.map { [$0] } ?? Int64.fetchAll(db, sql: """
            SELECT DISTINCT propertyCategoryGroup.propertyId FROM transaction_
            JOIN category ON category.id = transaction_.categoryId
            JOIN propertyCategoryGroup ON propertyCategoryGroup.categoryGroupId = category.groupId
            WHERE transaction_.id = ?
            """, arguments: [transactionId])
        return try propertyOwners(properties, db: db)
    }

    private static func propertyOwners(_ propertyIds: [Int64], db: Database) throws -> Set<Int64> {
        guard !propertyIds.isEmpty else { return [] }
        return Set(try Int64.fetchAll(db, sql: """
            SELECT DISTINCT personId FROM propertyOwner WHERE propertyId IN (\(propertyIds.map(String.init).joined(separator: ",")))
            """))
    }

    // MARK: References

    /// A reference's local id: an `.int` is one already (0 names no row); a `.string` is a record UUID.
    private static func localId(_ value: SyncValue?, table: String, db: Database) throws -> Int64? {
        switch value {
        case .int(let id)?: return id > 0 ? id : nil
        case .string(let uuid)?: return try SyncRecordStore.localId(table: table, uuid: uuid, db: db)
        default: return nil
        }
    }
}

public enum AccessAreaMapError: Error, Equatable {
    /// A tax row names no person and the household has no admin whose tax it would be.
    case noPersonForTaxRow(table: String)
}

extension AccessDecision {
    /// Whether some part can be met by nobody (an owner rule with no owner).
    var containsNobody: Bool {
        switch self {
        case .ownerOnly(let personId): return personId == nil
        case .allOf(let parts): return parts.contains { $0.containsNobody }
        case .area: return false
        case .denied: return true
        }
    }
}
