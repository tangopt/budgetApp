import Foundation
import GRDB

/// The zones records live in (sync spec §3, sharing spec 2026-10-25 §3): the household zone both people
/// fetch, and one private zone per person that only that person's devices fetch.
public enum SyncZones {
    public static let household = "household"
    private static let privatePrefix = "private-"

    /// The private zone of the person whose `person` record has this UUID.
    public static func privateZone(personUuid: String) -> String { privatePrefix + personUuid }

    /// The person UUID a private zone belongs to; nil for any other zone.
    public static func personUuid(ofPrivateZone zone: String) -> String? {
        guard zone.hasPrefix(privatePrefix), zone.count > privatePrefix.count else { return nil }
        return String(zone.dropFirst(privatePrefix.count))
    }

    static func isPrivate(_ zone: String) -> Bool { personUuid(ofPrivateZone: zone) != nil }

    /// Where a household record may name an account below Everything that isn't Hidden (`table.column` to
    /// the levels it may at): the summaries the level allows, its property-money transactions (§10), its
    /// transfer category, its property link and an evidence requirement's exclusion list. Any other
    /// reference to it is private content of the account.
    public static let stubReferences: [String: Set<SharingLevel>] = [
        "accountBalancePoint.accountId": [.balanceOnly, .categoryTotals],
        "accountSummaryMonth.accountId": [.categoryTotals],
        "transaction_.accountId": [.balanceOnly, .categoryTotals],
        "category.transferAccountId": [.balanceOnly, .categoryTotals],
        "propertyAccount.accountId": [.balanceOnly, .categoryTotals],
        "evidenceRequirement.excludedAccountIds": [.balanceOnly, .categoryTotals],
    ]
}

/// Where one record goes, and what it leaves behind.
public struct ZoneAssignment: Equatable, Sendable {
    /// A second record carrying what a household stub leaves out, in its owner's private zone.
    public struct Companion: Equatable, Sendable {
        /// "accountDetails".
        public var recordType: String
        public var zone: String
        public var fields: [String]

        public init(recordType: String, zone: String, fields: [String]) {
            self.recordType = recordType
            self.zone = zone
            self.fields = fields
        }
    }

    public var zone: String
    /// Synced columns the record doesn't carry in `zone`.
    public var omittedFields: [String]
    public var companion: Companion?

    public init(zone: String, omittedFields: [String] = [], companion: Companion? = nil) {
        self.zone = zone
        self.omittedFields = omittedFields
        self.companion = companion
    }

    public static let household = ZoneAssignment(zone: SyncZones.household)

    var isPrivate: Bool { SyncZones.isPrivate(zone) }
}

public enum SyncZoneRouterError: Error, Equatable {
    /// The admin hasn't confirmed who owns each account: nothing may be routed, so nothing uploads.
    case ownershipNotConfirmed
    /// A table no routing rule covers (or that doesn't sync).
    case unknownTable(String)
    case noSuchRow(table: String, localId: Int64)
    /// An account below Everything without an owner, so no private zone to put it in.
    case noOwner(accountId: Int64)
    /// The owner's `person` row has no sync identity, so its private zone has no name.
    case ownerHasNoIdentity(accountId: Int64)
    /// Records whose references lead back to themselves.
    case referenceCycle(table: String, localId: Int64)
    /// The record belongs to two people's private zones at once: it can be placed in neither, and never in
    /// `household`.
    case spansPrivateZones(table: String, localId: Int64)
    /// A record that can only go to the admin's private zone, and no admin (or their person's identity).
    case noAdmin
}

/// Decides each record's zone from the database's facts, at push time (sharing spec 2026-10-25 §3, §10;
/// sync spec §6.1). Pure: it only reads. When unsure it picks the most private answer, or refuses
/// (throws) when no private zone can be named, so nothing it can't place ever reaches `household`. P is the
/// private zone of the account's owner; "below Everything" includes Hidden.
///
/// 1. An **account** at Everything (or joint) is `household`. Below Everything and not Hidden: a `household`
///    stub without `privateAccountColumns`, which travel in an `accountDetails` companion in P. Hidden: P.
///    An unknown level counts as Hidden.
/// 2. **Records of an account** (`accountRecordTables`): Everything → `household`, else P. A shared
///    account's import batch whose run is private (rule 6) stays shared without `importRunId`.
/// 3. **Property money** (§10): a transaction of an account below Everything but not Hidden stays in
///    `household` when its category is a property category or a property/tax row names it (`pinningTables`).
///    It leaves out `importBatchId` (its batch is private).
/// 4. **Closure**, over every record: a record referencing (foreign key, logical, polymorphic or JSON
///    reference) a record placed in a private zone goes to that zone. A reference to a stub account counts
///    as private too, except where `SyncZones.stubReferences` allows it (the summaries its level allows, its
///    property-money transactions, its transfer category, its property link, an evidence exclusion list).
///    References into two people's private zones are refused (`spansPrivateZones`).
/// 5. A **document** takes the most private zone among its referrers (`documentReferrers`; a run file by its
///    run), `household` when none is private, the admin's private zone when only shared runs' files name it
///    (two people's zones: refused). Its `documentFile` follows the document.
/// 6. An **import run** that touched an account below Everything (a batch on it, or a change naming it,
///    its transactions or its batches) is P, summary and all; two owners: refused.
/// 7. An **import change** goes to P of the account its recorded row names (directly, or through a
///    transaction or batch), else to the admin's private zone when it names none, or one gone.
/// 8. An **import run file** follows its run; in a shared run it goes where its document goes (rule 5), and
///    to the admin's private zone without one.
/// 9. A learnt **merchant link rule** follows the account it was learnt from (`LinkAction.sourceAccountId`),
///    and goes to the admin's private zone when that is unknown.
/// 10. A **waiting file** (kept for later) is never shared: the private zone of whoever kept it
///    (`keptByAppUserId`), else the admin's.
/// 11. A record that would still be `household` but quotes an account's private details
///    (`SyncPrivateDetails`, as the guard checks) goes to that account's owner's private zone.
/// A table without a rule is refused (`unknownTable`); `SyncZoneRouterTests` lists every table's rule.
///
/// Valid only inside the database access it was made in; it memoises per record.
public final class SyncZoneRouter {
    /// Account columns a stub leaves out; its `accountDetails` companion carries them.
    public static let privateAccountColumns = ["sortCode", "accountNumber", "iban", "routingNumber", "bic",
                                               "statementMismatchMinorUnits", "statementMismatchDate",
                                               "statementMismatchClosingMinorUnits", "statementLastCheckedDate"]

    public static let companionRecordType = "accountDetails"

    /// What decides a table's zone before the closure (rule 4) is applied.
    enum Rule: Equatable, Sendable {
        /// Rule 1.
        case account
        /// Rule 2 (and 3 for `transaction_`), by the row's `accountId`.
        case accountRecord
        /// Rule 5.
        case document
        /// Rule 6.
        case importRun
        /// Rule 7.
        case importChange
        /// Rule 8.
        case importRunFile
        /// Rule 9.
        case importRule
        /// Rule 10.
        case importWaitingFile
        /// Shared by rule (summaries, sharing settings, property and tax records, tax and income).
        case shared
        /// Only the closure decides.
        case followsReferences
    }

    static let accountRecordTables: Set<String> = ["transaction_", "importBatch", "importProfile", "balanceSnapshot",
                                                   "balanceSnapshotArchive", "forecastEntry"]

    /// Tables whose rows name a transaction and keep it shared (§10).
    static let pinningTables = ["taxPolicyReceipt", "taxNotClaimed", "taxTransactionOwner", "rentReceiptPayment",
                                "rechargePayment", "rechargeLine", "utilityInvoice"]

    static let sharedTables: Set<String> = [
        "accountBalancePoint", "accountSummaryMonth", "personSharing", "memberPermission",
        "taxPolicyReceipt", "taxNotClaimed", "taxTransactionOwner", "rentReceiptPayment", "rechargePayment",
        "rechargeLine", "utilityInvoice",
        "employment", "employmentIncome", "benefitInKind", "otherIncome", "pensionContribution", "hmrcPayment",
        "hmrcRate", "taxYear", "taxFiledBox", "taxYearSplit", "taxAttributionRule", "taxExpenseTypeMap", "taxManualItem",
    ]

    /// Every synced table's rule.
    static let rules: [String: Rule] = {
        var rules: [String: Rule] = [:]
        for table in SyncSchema.tables {
            switch table.name {
            case "account": rules[table.name] = .account
            case "document": rules[table.name] = .document
            case "importRun": rules[table.name] = .importRun
            case "importChange": rules[table.name] = .importChange
            case "importRunFile": rules[table.name] = .importRunFile
            case "importRule": rules[table.name] = .importRule
            case "importWaitingFile": rules[table.name] = .importWaitingFile
            case let name where accountRecordTables.contains(name): rules[name] = .accountRecord
            case let name where sharedTables.contains(name): rules[name] = .shared
            default: rules[table.name] = .followsReferences
            }
        }
        return rules
    }()

    /// Every (table, column) naming a document by its local id, from `SyncSchema`.
    static let documentReferrers: [(table: String, column: String)] = SyncSchema.tables.flatMap { table in
        table.foreignKeys.merging(SyncSchema.logicalReferences(of: table.name)) { first, _ in first }
            .filter { $0.value == "document" }.keys.sorted().map { (table.name, $0) }
    }

    private struct AccountFact {
        var owner: Int64?
        var level: SharingLevel
    }

    private enum Placement {
        case shared
        case stub(String)
        case hidden(String)

        var privateZone: String? {
            switch self {
            case .shared: return nil
            case .stub(let zone), .hidden(let zone): return zone
            }
        }
    }

    private struct Key: Hashable {
        var table: String
        var localId: Int64
        /// Tables whose references are ignored on this walk (the reverse rules' own tables, to break cycles).
        var ignoring: Set<String>
    }

    private let db: Database
    private let accounts: [Int64: AccountFact]
    private let personUuids: [Int64: String]
    private let adminPersonUuid: String?
    private let propertyCategoryIds: Set<Int64>
    private let pinnedTransactionIds: Set<Int64>
    private let details: SyncPrivateDetails
    private var memo: [Key: ZoneAssignment] = [:]
    private var inProgress: Set<Key> = []
    private var runZones: [Int64: String?] = [:]

    /// Loads the facts. Refuses (`ownershipNotConfirmed`) until the admin has confirmed who owns each account.
    public init(db: Database) throws {
        guard try SharingSetup.isConfirmed(db: db) else { throw SyncZoneRouterError.ownershipNotConfirmed }
        self.db = db
        var accounts: [Int64: AccountFact] = [:]
        for row in try Row.fetchAll(db, sql: "SELECT id, ownerPersonId, sharingLevel FROM account") {
            let raw: String? = row["sharingLevel"]
            // An unknown level is the most private one.
            accounts[row["id"]] = AccountFact(owner: row["ownerPersonId"], level: raw.flatMap(SharingLevel.init(rawValue:)) ?? .hidden)
        }
        self.accounts = accounts
        var people: [Int64: String] = [:]
        for row in try Row.fetchAll(db, sql: "SELECT localId, uuid FROM syncRecord WHERE tableName = 'person'") {
            people[row["localId"]] = row["uuid"]
        }
        personUuids = people
        adminPersonUuid = try Int64.fetchOne(db, sql: "SELECT personId FROM appUser WHERE isAdmin = 1 ORDER BY id LIMIT 1")
            .flatMap { people[$0] }
        propertyCategoryIds = Set(try Int64.fetchAll(db, sql: """
            SELECT id FROM category WHERE groupId IN (SELECT categoryGroupId FROM propertyCategoryGroup)
            """))
        details = try SyncPrivateDetails(db: db)
        pinnedTransactionIds = Set(try Int64.fetchAll(db, sql: Self.pinningTables
            .map { "SELECT transactionId FROM \(SyncChangeTracker.quoted($0)) WHERE transactionId IS NOT NULL" }
            .joined(separator: " UNION ")))
    }

    /// The record's zone, what it leaves out there, and its companion.
    public func assignment(table: String, localId: Int64) throws -> ZoneAssignment {
        guard let assignment = try assignmentIfPresent(table: table, localId: localId, ignoring: []) else {
            throw SyncZoneRouterError.noSuchRow(table: table, localId: localId)
        }
        return assignment
    }

    /// The private zone a reference from `table` (`column`) to the record makes its referrer go to (a stub
    /// account counts, outside `SyncZones.stubReferences`); for a row that is gone, its tombstone's zone when
    /// private (a household tombstone proves nothing, but names no zone either). Nil: nothing private.
    private func privateZone(ofReferenced target: String, localId: Int64, from table: String, column: String,
                             ignoring: Set<String>) throws -> String? {
        if target == "account", let fact = accounts[localId], fact.level != .everything {
            if fact.level != .hidden, SyncZones.stubReferences["\(table).\(column)"]?.contains(fact.level) == true { return nil }
            return try placement(account: localId).privateZone
        }
        if let assignment = try assignmentIfPresent(table: target, localId: localId, ignoring: ignoring) {
            return assignment.isPrivate ? assignment.zone : nil
        }
        let gone = try String.fetchOne(db.cachedStatement(sql: """
            SELECT zone FROM syncTombstone WHERE tableName = ? AND localId = ? ORDER BY deletedAt DESC LIMIT 1
            """), arguments: [target, localId])
        return gone.flatMap { SyncZones.isPrivate($0) ? $0 : nil }
    }

    private func assignmentIfPresent(table: String, localId: Int64, ignoring: Set<String>) throws -> ZoneAssignment? {
        let key = Key(table: table, localId: localId, ignoring: ignoring)
        if let known = memo[key] { return known }
        guard let rule = Self.rules[table], let schema = SyncSchema.table(table) else { throw SyncZoneRouterError.unknownTable(table) }
        guard let fields = try fields(schema, localId: localId) else { return nil }
        guard inProgress.insert(key).inserted else { throw SyncZoneRouterError.referenceCycle(table: table, localId: localId) }
        defer { inProgress.remove(key) }

        var base = ZoneAssignment.household
        switch rule {
        case .account:
            switch try placement(account: localId) {
            case .shared: break
            case .stub(let zone):
                base = ZoneAssignment(zone: SyncZones.household, omittedFields: Self.privateAccountColumns,
                                      companion: .init(recordType: Self.companionRecordType, zone: zone, fields: Self.privateAccountColumns))
            case .hidden(let zone): base = ZoneAssignment(zone: zone)
            }
        case .accountRecord:
            if case .int(let accountId) = fields["accountId"] ?? .null {
                switch try placement(account: accountId) {
                case .shared:
                    if table == "importBatch", case .int(let run) = fields["importRunId"] ?? .null, try runZone(run) != nil {
                        base = ZoneAssignment(zone: SyncZones.household, omittedFields: ["importRunId"])
                    }
                case .hidden(let zone): base = ZoneAssignment(zone: zone)
                case .stub(let zone):
                    if table == "transaction_", isPropertyMoney(localId, fields: fields) {
                        base = ZoneAssignment(zone: SyncZones.household, omittedFields: ["importBatchId"])
                    } else {
                        base = ZoneAssignment(zone: zone)
                    }
                }
            }
        case .document:
            base = try documentPlacement(localId, ignoring: ignoring)
        case .importRun:
            if let zone = try runZone(localId) { base = ZoneAssignment(zone: zone) }
        case .importChange:
            base = try changeZone(fields, table: table, localId: localId)
        case .importRunFile:
            base = try runFileZone(fields, ignoring: ignoring)
        case .importWaitingFile:
            base = try waitingFileZone(localId)
        case .importRule:
            base = try importRuleZone(fields)
        case .shared, .followsReferences:
            break
        }

        // Rule 4, also over a private record, to refuse one that spans two people's zones.
        var zones: Set<String> = base.isPrivate ? [base.zone] : []
        let omitted = Set(base.omittedFields)
        let carried = fields.filter { !omitted.contains($0.key) }
        for reference in try SyncRowReferences.list(table: table, fields: carried, form: .local) where !ignoring.contains(reference.table) {
            guard case .local(let id) = reference.key else { continue }
            if let zone = try privateZone(ofReferenced: reference.table, localId: id, from: table, column: reference.column, ignoring: ignoring) {
                zones.insert(zone)
            }
        }
        guard zones.count <= 1 else { throw SyncZoneRouterError.spansPrivateZones(table: table, localId: localId) }
        var result = base.isPrivate ? base : zones.first.map { ZoneAssignment(zone: $0) } ?? base
        // What `SyncZoneGuard` would refuse in household (an account's private details quoted), routing keeps private.
        let accounts = accounts
        if !result.isPrivate, let account = details.account(quotedIn: table, fields: carried, isShared: { value in
            if case .int(let id) = value { return accounts[id]?.level == .everything }
            return false
        }), let zone = try placement(account: account).privateZone {
            result = ZoneAssignment(zone: zone)
        }
        memo[key] = result
        return result
    }

    // MARK: Reverse rules

    /// Rule 5: the most private zone among the document's referrers. An import run file counts by its run:
    /// private when the run is; a file of a shared run places nothing by itself, so a document known only
    /// from shared runs' files can't be told apart and goes to the admin's private zone. No referrer at all:
    /// `household`. Two people's zones: refused.
    private func documentPlacement(_ document: Int64, ignoring: Set<String>) throws -> ZoneAssignment {
        let inner = ignoring.union(["document"])
        var zones: Set<String> = []
        var placedShared = false
        var sharedRunFiles = false
        for referrer in Self.documentReferrers {
            for id in try ids(referrer.table, where: referrer.column, is: document) {
                if referrer.table == "importRunFile" {
                    guard let run = try Int64.fetchOne(db.cachedStatement(sql: "SELECT runId FROM importRunFile WHERE id = ?"),
                                                       arguments: [id]) else { continue }
                    if let zone = try runZone(run) { zones.insert(zone) } else { sharedRunFiles = true }
                    continue
                }
                guard let assignment = try assignmentIfPresent(table: referrer.table, localId: id, ignoring: inner) else { continue }
                if assignment.isPrivate { zones.insert(assignment.zone) } else { placedShared = true }
            }
        }
        guard zones.count <= 1 else { throw SyncZoneRouterError.spansPrivateZones(table: "document", localId: document) }
        if let zone = zones.first { return ZoneAssignment(zone: zone) }
        if sharedRunFiles, !placedShared { return ZoneAssignment(zone: try adminZone()) }
        return .household
    }

    /// Rule 6: the private zone of the accounts below Everything the run touched, nil when none.
    private func runZone(_ runId: Int64) throws -> String? {
        if let known = runZones[runId] { return known }
        var touched = Set(try Int64.fetchAll(db.cachedStatement(sql: "SELECT accountId FROM importBatch WHERE importRunId = ?"),
                                             arguments: [runId]))
        for change in try Row.fetchAll(db.cachedStatement(sql: """
            SELECT tableName, rowId, beforeJSON, afterJSON FROM importChange WHERE runId = ?
            """), arguments: [runId]) {
            touched.formUnion(try accountsNamed(byChange: changeFields(change)))
        }
        var zones: Set<String> = []
        for account in touched where accounts[account] != nil {
            if let zone = try placement(account: account).privateZone { zones.insert(zone) }
        }
        guard zones.count <= 1 else { throw SyncZoneRouterError.spansPrivateZones(table: "importRun", localId: runId) }
        runZones[runId] = zones.first
        return zones.first
    }

    /// Rule 7.
    private func changeZone(_ fields: [String: SyncValue], table: String, localId: Int64) throws -> ZoneAssignment {
        let named = try accountsNamed(byChange: fields)
        guard !named.isEmpty, named.allSatisfy({ accounts[$0] != nil }) else { return ZoneAssignment(zone: try adminZone()) }
        let zones = Set(try named.compactMap { try placement(account: $0).privateZone })
        guard zones.count <= 1 else { throw SyncZoneRouterError.spansPrivateZones(table: table, localId: localId) }
        return zones.first.map { ZoneAssignment(zone: $0) } ?? .household
    }

    /// Rule 8: a file of a private run is private; a file of a shared run goes where its document goes
    /// (rule 5), and to the admin's private zone without one.
    private func runFileZone(_ fields: [String: SyncValue], ignoring: Set<String>) throws -> ZoneAssignment {
        guard case .int(let run) = fields["runId"] ?? .null else { return ZoneAssignment(zone: try adminZone()) }
        if let zone = try runZone(run) { return ZoneAssignment(zone: zone) }
        if case .int(let document) = fields["documentId"] ?? .null { return try documentPlacement(document, ignoring: ignoring) }
        return ZoneAssignment(zone: try adminZone())
    }

    /// Rule 10: the private zone of the person who kept the file (`keptByAppUserId`), else the admin's.
    private func waitingFileZone(_ localId: Int64) throws -> ZoneAssignment {
        let keeper = try String.fetchOne(db.cachedStatement(sql: """
            SELECT person.uuid FROM importWaitingFile kept
            JOIN appUser ON appUser.id = kept.keptByAppUserId
            JOIN syncRecord person ON person.tableName = 'person' AND person.localId = appUser.personId
            WHERE kept.id = ?
            """), arguments: [localId])
        return ZoneAssignment(zone: try keeper.map(SyncZones.privateZone(personUuid:)) ?? adminZone())
    }

    /// Rule 9.
    private func importRuleZone(_ fields: [String: SyncValue]) throws -> ZoneAssignment {
        guard fields["kind"] == .string(ImportRuleKind.link.rawValue), case .string(let json) = fields["actionJSON"] ?? .null,
              let action = ImportLearning.decode(LinkAction.self, json), action.entity == nil else { return .household }
        guard let source = action.sourceAccountId, accounts[source] != nil else { return ZoneAssignment(zone: try adminZone()) }
        return try placement(account: source).privateZone.map { ZoneAssignment(zone: $0) } ?? .household
    }

    /// The accounts a recorded change names: its row (an account, or a transaction's or batch's account) and
    /// every account, transaction or batch its before and after rows reference.
    private func accountsNamed(byChange fields: [String: SyncValue]) throws -> Set<Int64> {
        var named: Set<Int64> = []
        for reference in try SyncRowReferences.list(table: "importChange", fields: fields, form: .local) {
            guard case .local(let id) = reference.key else { continue }
            switch reference.table {
            case "account": named.insert(id)
            case "transaction_", "importBatch":
                if let account = try Int64.fetchOne(db.cachedStatement(sql: """
                    SELECT accountId FROM \(SyncChangeTracker.quoted(reference.table)) WHERE id = ?
                    """), arguments: [id]) {
                    named.insert(account)
                }
            default: break
            }
        }
        return named
    }

    private func changeFields(_ row: Row) -> [String: SyncValue] {
        var fields: [String: SyncValue] = [:]
        for column in ["tableName", "rowId", "beforeJSON", "afterJSON"] {
            fields[column] = SyncValue(row[column] as DatabaseValue, declaredType: "")
        }
        return fields
    }

    private func adminZone() throws -> String {
        guard let uuid = adminPersonUuid else { throw SyncZoneRouterError.noAdmin }
        return SyncZones.privateZone(personUuid: uuid)
    }

    private func ids(_ table: String, where column: String, is value: Int64) throws -> [Int64] {
        try Int64.fetchAll(db.cachedStatement(sql: """
            SELECT id FROM \(SyncChangeTracker.quoted(table)) WHERE \(SyncChangeTracker.quoted(column)) = ?
            """), arguments: [value])
    }

    private func placement(account id: Int64) throws -> Placement {
        guard let fact = accounts[id] else { throw SyncZoneRouterError.noSuchRow(table: "account", localId: id) }
        if fact.level == .everything { return .shared }
        guard let owner = fact.owner else { throw SyncZoneRouterError.noOwner(accountId: id) }
        guard let uuid = personUuids[owner] else { throw SyncZoneRouterError.ownerHasNoIdentity(accountId: id) }
        let zone = SyncZones.privateZone(personUuid: uuid)
        return fact.level == .hidden ? .hidden(zone) : .stub(zone)
    }

    private func isPropertyMoney(_ transactionId: Int64, fields: [String: SyncValue]) -> Bool {
        if pinnedTransactionIds.contains(transactionId) { return true }
        if case .int(let category) = fields["categoryId"] ?? .null { return propertyCategoryIds.contains(category) }
        return false
    }

    /// The row's synced columns, nil when there is no such row.
    private func fields(_ schema: SyncTableSchema, localId: Int64) throws -> [String: SyncValue]? {
        guard let row = try Row.fetchOne(db.cachedStatement(sql: """
            SELECT * FROM \(SyncChangeTracker.quoted(schema.name)) WHERE \(SyncChangeTracker.quoted(schema.localIdColumn)) = ?
            """), arguments: [localId]) else { return nil }
        var fields: [String: SyncValue] = [:]
        for column in schema.syncedColumns where row.hasColumn(column) {
            fields[column] = SyncValue(row[column] as DatabaseValue, declaredType: "")
        }
        return fields
    }
}

// MARK: References a record makes

/// One reference a record makes, by column (the JSON or polymorphic column for those).
struct SyncRowReference: Hashable {
    enum Key: Hashable {
        /// A row's local id (a row read here).
        case local(Int64)
        /// A record's UUID (a payload).
        case uuid(String)
    }

    var column: String
    var table: String
    var key: Key
}

/// Every reference a record's fields make: declared and logical foreign keys, polymorphic references and the
/// ids inside JSON columns (`SyncSchema`), read either from a local row (local ids) or from a payload (UUIDs).
enum SyncRowReferences {
    enum Form {
        case local
        case uuid
    }

    static func list(table: String, fields: [String: SyncValue], form: Form) throws -> [SyncRowReference] {
        guard let schema = SyncSchema.table(table) else { throw SyncZoneRouterError.unknownTable(table) }
        let direct = schema.foreignKeys.merging(SyncSchema.logicalReferences(of: table)) { first, _ in first }
        let polymorphic = SyncSchema.polymorphicReferences(of: table)
        let json = SyncSchema.jsonReferences(of: table)
        var references: [SyncRowReference] = []
        for column in schema.syncedColumns.sorted() {
            guard let value = fields[column] else { continue }
            if let target = direct[column] {
                if let key = key(value, form) { references.append(.init(column: column, table: target, key: key)) }
            } else if let reference = polymorphic.first(where: { $0.idColumn == column }) {
                guard case .string(let type) = fields[reference.typeColumn] ?? .null else { continue }
                if let target = reference.targets[type] {
                    if let key = key(value, form) { references.append(.init(column: column, table: target, key: key)) }
                } else if case .passThrough(let types) = reference.unlisted, !types.contains(type) {
                    throw SyncReferenceError.unclassifiedType(table: table, column: reference.typeColumn, type: type)
                }
            } else if let reference = json.first(where: { $0.column == column }), case .string(let text) = value {
                switch reference.content {
                case .rules(let rules):
                    references += try inJSON(text, rules: rules, table: table, column: column, form: form)
                case .rowOfTable(let typeColumn):
                    guard case .string(let inner) = fields[typeColumn] ?? .null else { continue }
                    references += try inRecordedRow(text, table: inner, changeTable: table, column: column, form: form)
                }
            }
        }
        return references
    }

    private static func key(_ value: SyncValue, _ form: Form) -> SyncRowReference.Key? {
        switch (form, value) {
        case (.local, .int(let id)) where id != 0: return .local(id)
        case (.uuid, .string(let uuid)): return .uuid(uuid)
        default: return nil
        }
    }

    private static func key(_ node: SyncJSONNode, bytes: [UInt8], _ form: Form) -> SyncRowReference.Key? {
        switch (form, node.kind) {
        case (.local, .number):
            guard let id = Int64(String(decoding: bytes[node.range], as: UTF8.self)), id != 0 else { return nil }
            return .local(id)
        case (.uuid, .string(let uuid)):
            return .uuid(uuid)
        default:
            return nil
        }
    }

    private static func token(_ token: String, _ form: Form) -> SyncRowReference.Key? {
        switch form {
        case .local:
            guard let id = Int64(token), id != 0 else { return nil }
            return .local(id)
        case .uuid:
            return Int64(token) == nil ? .uuid(token) : nil
        }
    }

    /// The ids at the rules' places.
    private static func inJSON(_ text: String, rules: [SyncJSONRule], table: String, column: String,
                               form: Form) throws -> [SyncRowReference] {
        guard let root = SyncJSONNode.parse(text) else { return [] }
        let bytes = Array(text.utf8)
        let byPath = Dictionary(rules.map { ($0.path, $0.target) }, uniquingKeysWith: { first, _ in first })
        var found: [SyncRowReference] = []
        func visit(_ node: SyncJSONNode, _ path: String) throws {
            if let target = byPath[path] {
                switch target {
                case .row(let referenced):
                    if let key = key(node, bytes: bytes, form) { found.append(.init(column: column, table: referenced, key: key)) }
                case .evidenceEntity:
                    guard case .object(let members) = node.kind,
                          case .string(let type)? = members.first(where: { $0.key == "type" })?.value.kind,
                          let idNode = members.first(where: { $0.key == "id" })?.value else { return }
                    if let referenced = SyncSchema.evidenceEntityTables[type] {
                        if let key = key(idNode, bytes: bytes, form) { found.append(.init(column: column, table: referenced, key: key)) }
                    } else if !SyncSchema.evidenceEntityPassThrough.contains(type) {
                        throw SyncReferenceError.unclassifiedType(table: table, column: column, type: type)
                    }
                case .forecastFingerprint:
                    guard case .string(let raw) = node.kind else { return }
                    for (referenced, value) in SyncJSONTranslator.fingerprintTokens(raw) {
                        if let key = token(value, form) { found.append(.init(column: column, table: referenced, key: key)) }
                    }
                }
                return
            }
            switch node.kind {
            case .object(let members):
                for member in members { try visit(member.value, path.isEmpty ? member.key : path + "." + member.key) }
            case .array(let elements):
                for element in elements { try visit(element, path + "[]") }
            default:
                break
            }
        }
        try visit(root, "")
        return found
    }

    /// The ids in a row of `table` as `ImportChangeCapture` records it (its own id included).
    private static func inRecordedRow(_ text: String, table: String, changeTable: String, column: String,
                                      form: Form) throws -> [SyncRowReference] {
        guard let schema = SyncSchema.table(table), let root = SyncJSONNode.parse(text),
              case .object(let members) = root.kind else { return [] }
        let bytes = Array(text.utf8)
        var direct = schema.foreignKeys.merging(SyncSchema.logicalReferences(of: table)) { first, _ in first }
        direct[schema.localIdColumn] = direct[schema.localIdColumn] ?? table
        let polymorphic = SyncSchema.polymorphicReferences(of: table)
        let json = Dictionary(SyncSchema.jsonReferences(of: table).map { ($0.column, $0) }, uniquingKeysWith: { first, _ in first })
        var found: [SyncRowReference] = []
        for member in members {
            if let target = direct[member.key] {
                if let key = key(member.value, bytes: bytes, form) { found.append(.init(column: column, table: target, key: key)) }
            } else if let reference = polymorphic.first(where: { $0.idColumn == member.key }) {
                guard case .string(let type)? = members.first(where: { $0.key == reference.typeColumn })?.value.kind else { continue }
                if let target = reference.targets[type] {
                    if let key = key(member.value, bytes: bytes, form) { found.append(.init(column: column, table: target, key: key)) }
                } else if case .passThrough(let types) = reference.unlisted, !types.contains(type) {
                    throw SyncReferenceError.unclassifiedType(table: changeTable, column: column, type: type)
                }
            } else if let nested = json[member.key], case .rules(let rules) = nested.content, case .string(let inner) = member.value.kind {
                found += try inJSON(inner, rules: rules, table: table, column: column, form: form)
            }
        }
        return found
    }
}
