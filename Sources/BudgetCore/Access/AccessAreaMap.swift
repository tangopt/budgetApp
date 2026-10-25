import Foundation
import GRDB

public enum AccessAreaMapError: Error, Equatable {
    /// A tax row names no person and the household has no admin whose tax it would be.
    case noPersonForTaxRow(table: String)
}

/// Which permission a change needs (sharing spec 2026-10-25 §10): by origin first (an import's rows are
/// Import, matching is Property, document links are Documents), then by table. A transaction change
/// touching only its category, note, status and how it was categorised is Property when the transaction
/// is property money; any other transaction change is Budget & accounts. Summaries and an account's owner
/// and level are the owner's alone (`isOwnerOnly`, judged by `AccessPolicy.canSetLevel`).
///
/// `row` (and `before`) hold a record's synced columns. A reference may be this device's local id
/// (`.int`) or the referenced record's UUID (`.string`, as a payload carries it); both resolve here.
public enum AccessAreaMap {
    /// Tables whose every write is the account owner's (summaries the owner's devices rebuild).
    static let ownerOnlyTables: Set<String> = ["accountBalancePoint", "accountSummaryMonth"]
    /// `account` columns only the owner sets.
    static let ownerOnlyAccountFields: Set<String> = ["ownerPersonId", "sharingLevel"]
    /// Transaction fields a member with Property may set on property money.
    static let propertyTransactionFields: Set<String> = ["categoryId", "note", "status", "categorizedBy"]

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

    /// The area a change to `table` needs, or nil for an owner-only table or a table this map doesn't know.
    /// `changedFields` are the synced columns the change sets (every column for an insert); `before`, when
    /// given, is the record as this device holds it before the change.
    public static func area(table: String, origin: WriteOrigin?, changedFields: Set<String>, row: [String: SyncValue],
                            before: [String: SyncValue]? = nil, db: Database) throws -> AccessArea? {
        if ownerOnlyTables.contains(table) { return nil }
        switch origin {
        case .import?: return .import
        case .propertyMatching?: return .property
        case .documentLink?: return .documents
        case .edit?, .system?, nil: break
        }
        if taxTablesWithPerson.contains(table) || taxTablesWithoutPerson.contains(table) {
            return .tax(personUuid: try taxPersonUuid(table: table, row: row, db: db))
        }
        if table == "transaction_" {
            if !changedFields.isEmpty, changedFields.isSubset(of: propertyTransactionFields),
               try isPropertyMoney(row: row, before: before, db: db) {
                return .property
            }
            return .budgetAndAccounts
        }
        if let area = byTable[table] { return area }
        if propertyPrefixes.contains(where: { table.hasPrefix($0) }) { return .property }
        return nil
    }

    /// Whether a change to these fields of `table` is the account owner's alone: any write to a summary
    /// table, and an `account` change that sets its owner or level.
    public static func isOwnerOnly(table: String, fields: Set<String>) -> Bool {
        if ownerOnlyTables.contains(table) { return true }
        return table == "account" && !fields.isDisjoint(with: ownerOnlyAccountFields)
    }

    // MARK: Transactions

    /// Property money: a transaction of a property-linked account at Everything, or one whose category
    /// (before or after the change) is a property's.
    private static func isPropertyMoney(row: [String: SyncValue], before: [String: SyncValue]?, db: Database) throws -> Bool {
        for accountValue in [row["accountId"], before?["accountId"]] {
            guard let accountId = try localId(accountValue, table: "account", db: db) else { continue }
            if try Bool.fetchOne(db, sql: """
                SELECT EXISTS (SELECT 1 FROM account JOIN propertyAccount ON propertyAccount.accountId = account.id
                               WHERE account.id = ? AND account.sharingLevel = ?)
                """, arguments: [accountId, SharingLevel.everything.rawValue]) == true {
                return true
            }
        }
        for categoryValue in [row["categoryId"], before?["categoryId"]] {
            guard let categoryId = try localId(categoryValue, table: "category", db: db) else { continue }
            if try Bool.fetchOne(db, sql: """
                SELECT EXISTS (SELECT 1 FROM category JOIN propertyCategoryGroup ON propertyCategoryGroup.categoryGroupId = category.groupId
                               WHERE category.id = ?)
                """, arguments: [categoryId]) == true {
                return true
            }
        }
        return false
    }

    // MARK: Tax

    /// The UUID of the person whose tax the row is: its `personId`, else the owning record's person (an
    /// employment's, a manual item's, the transaction owner's), else the admin's.
    private static func taxPersonUuid(table: String, row: [String: SyncValue], db: Database) throws -> String {
        let personId = try taxPersonId(table: table, row: row, db: db) ?? adminPersonId(db: db)
        guard let personId else { throw AccessAreaMapError.noPersonForTaxRow(table: table) }
        return try SyncRecordStore.existingUUID(table: "person", localId: personId, db: db)
            ?? SyncRecordStore.uuid(for: "person", localId: personId, db: db)
    }

    private static func taxPersonId(table: String, row: [String: SyncValue], db: Database) throws -> Int64? {
        if let personId = try localId(row["personId"], table: "person", db: db) { return personId }
        switch table {
        case "employmentIncome", "benefitInKind":
            guard let employmentId = try localId(row["employmentId"], table: "employment", db: db) else { return nil }
            return try Int64.fetchOne(db, sql: "SELECT personId FROM employment WHERE id = ?", arguments: [employmentId])
        case "taxNotClaimed":
            if let itemId = try localId(row["manualItemId"], table: "taxManualItem", db: db),
               let personId = try Int64.fetchOne(db, sql: "SELECT personId FROM taxManualItem WHERE id = ?", arguments: [itemId]) {
                return personId
            }
            if let transactionId = try localId(row["transactionId"], table: "transaction_", db: db) {
                return try transactionOwner(transactionId, db: db)
            }
            if let receiptId = try localId(row["policyReceiptId"], table: "taxPolicyReceipt", db: db),
               let transactionId = try Int64.fetchOne(db, sql: "SELECT transactionId FROM taxPolicyReceipt WHERE id = ?", arguments: [receiptId]) {
                return try transactionOwner(transactionId, db: db)
            }
            return nil
        case "taxPolicyReceipt":
            guard let transactionId = try localId(row["transactionId"], table: "transaction_", db: db) else { return nil }
            return try transactionOwner(transactionId, db: db)
        default:
            return nil
        }
    }

    private static func transactionOwner(_ transactionId: Int64, db: Database) throws -> Int64? {
        try Int64.fetchOne(db, sql: "SELECT personId FROM taxTransactionOwner WHERE transactionId = ? ORDER BY id LIMIT 1",
                           arguments: [transactionId])
    }

    private static func adminPersonId(db: Database) throws -> Int64? {
        try Int64.fetchOne(db, sql: "SELECT personId FROM appUser WHERE isAdmin = 1 ORDER BY id LIMIT 1")
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
