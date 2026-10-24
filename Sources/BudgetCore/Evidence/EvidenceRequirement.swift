import GRDB
import Foundation

/// How often a periodic requirement expects a document (spec 2026-10-16 §7).
public enum EvidencePeriodicity: String, Codable, CaseIterable, Sendable {
    case month
    case quarter
    case year

    var months: Int {
        switch self {
        case .month: return 1
        case .quarter: return 3
        case .year: return 12
        }
    }
}

/// Which transactions a transaction-scoped requirement covers, by sign.
public enum EvidenceTransactionDirection: String, Codable, CaseIterable, Sendable {
    /// Debits only (expenses, instalments paid): refunds don't need evidence.
    case outflows
    /// Credits only (rent received).
    case inflows
    case any
}

/// What a requirement expects evidence for (spec §7). Stored as JSON in
/// `evidenceRequirement.scope`; the case and label names are part of the stored format.
public enum EvidenceRequirementScope: Codable, Equatable, Hashable, Sendable {
    /// Every transaction in the category needs a linked document.
    case transactionsInCategory(categoryId: Int64)
    /// Every transaction in any category of the group (categories added to it later too).
    case transactionsInCategoryGroup(groupId: Int64)
    /// Every transaction matching all the given criteria (an empty list or `nil` doesn't
    /// restrict); at least one criterion must be set. The description match is case-insensitive.
    case transactionsMatching(categoryIds: [Int64], accountIds: [Int64], descriptionContains: String?)
    /// One document per slot (month, quarter, year) linked to the record, dated or covering
    /// that slot (rent receipt per rent month, condomínio receipt per quarter).
    case periodic(entity: EvidenceEntity, every: EvidencePeriodicity)
    /// One document linked to the record, whatever its date (deed, P60 for a tax-year record).
    case single(entity: EvidenceEntity)
    /// One document for each record of `recordType` of the property — each issued rent receipt
    /// (its PDF) whose rent period meets the checklist's period, each tenancy (its contract)
    /// running in it (`PropertyEvidence`). New records are covered as they arrive.
    case recordsOfProperty(propertyId: Int64, recordType: EvidenceEntityType)
    /// One document per personal-income record of every person (`PersonalIncomeEvidence`):
    /// the P60 of each employment held to the year's end, the P45 of each that ended, the
    /// P11D of each with benefits, the proof of each HMRC payment.
    case personalIncomeRecords(record: PersonalIncomeRecordKind)

    /// Whether the scope targets transactions (one item per transaction).
    public var isTransactionScope: Bool {
        switch self {
        case .transactionsInCategory, .transactionsInCategoryGroup, .transactionsMatching: return true
        case .periodic, .single, .recordsOfProperty, .personalIncomeRecords: return false
        }
    }
}

public enum EvidenceRequirementError: Error, Equatable {
    case blankName
    /// A `transactionsMatching` scope with no criterion would match every transaction.
    case noMatchingCriteria
    /// `activeFrom` isn't before `activeTo`.
    case invalidActiveRange
    case requirementNotFound
    /// `recordsOfProperty` supports tenancies and rent receipts only.
    case unsupportedRecordType
}

/// A rule for what evidence the records need (spec §7), stored as data so new years
/// generate their checklist automatically. A requirement is met by a linked document of
/// any of `kinds` or `customKindIds` (both empty accepts any document).
public struct EvidenceRequirement: Codable, Equatable, Identifiable, FetchableRecord, MutablePersistableRecord, Sendable {
    public var id: Int64?
    public var name: String
    public var scope: EvidenceRequirementScope
    /// The document kinds that satisfy it, any of; empty = any document.
    public var kinds: [DocumentKind]
    /// The custom document kinds that satisfy it too, any of (`customDocumentKind` ids).
    public var customKindIds: [Int64]
    /// For transaction scopes: which signs count. Ignored by periodic and single scopes.
    public var direction: EvidenceTransactionDirection
    /// For transaction scopes: accounts whose transactions are left out (e.g. the mortgage
    /// account's interest rows, when the instalment rule already asks for the notice).
    public var excludedAccountIds: [Int64]
    /// Where the document usually comes from ("BBVA app", "Portal das Finanças"); the
    /// checklist groups by it.
    public var usualSource: String?
    /// When the rule applies: `activeFrom` inclusive, `activeTo` exclusive; `nil` is open.
    public var activeFrom: Date?
    public var activeTo: Date?
    public var notes: String?
    public var createdAt: Date

    public init(id: Int64? = nil, name: String, scope: EvidenceRequirementScope, kinds: [DocumentKind], customKindIds: [Int64] = [],
                direction: EvidenceTransactionDirection = .outflows, excludedAccountIds: [Int64] = [], usualSource: String? = nil,
                activeFrom: Date? = nil, activeTo: Date? = nil, notes: String? = nil, createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.scope = scope
        self.kinds = kinds
        self.customKindIds = customKindIds
        self.direction = direction
        self.excludedAccountIds = excludedAccountIds
        self.usualSource = usualSource
        self.activeFrom = activeFrom
        self.activeTo = activeTo
        self.notes = notes
        self.createdAt = EvidenceLinks.wholeSeconds(createdAt)
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    public static let databaseTableName = "evidenceRequirement"

    /// Whether a document of the built-in `kind` satisfies the rule.
    public func accepts(_ kind: DocumentKind) -> Bool {
        accepts(.builtIn(kind))
    }

    /// Whether a document of `ref` satisfies the rule: any document when both lists are empty.
    public func accepts(_ ref: DocumentKindRef) -> Bool {
        if kinds.isEmpty && customKindIds.isEmpty { return true }
        switch ref {
        case .builtIn(let kind): return kinds.contains(kind)
        case .custom(let id): return customKindIds.contains(id)
        }
    }

    /// The part of `period` the rule is active in (half-open), or `nil` when none.
    func activeWindow(in period: DateInterval) -> (start: Date, end: Date)? {
        let start = max(period.start, activeFrom ?? period.start)
        let end = min(period.end, activeTo ?? period.end)
        return start < end ? (start, end) : nil
    }
}

/// Why a requirement's target is waived (spec §7: an item can be marked "not available").
public enum EvidenceWaiverReason: String, Codable, CaseIterable, Sendable {
    case notAvailable
    case other
}

/// A target of a requirement that won't get a document: counts as done in the checklist.
/// For transaction scopes the entity is the transaction and `slotStart` is `nil`; for
/// periodic scopes `slotStart` is the start of the slot waived.
public struct EvidenceWaiver: Codable, Equatable, Identifiable, FetchableRecord, MutablePersistableRecord, Sendable {
    public var id: Int64?
    public var requirementId: Int64
    public var entityType: EvidenceEntityType
    public var entityId: Int64
    public var slotStart: Date?
    public var reason: EvidenceWaiverReason
    public var note: String?
    public var createdAt: Date

    public init(id: Int64? = nil, requirementId: Int64, entity: EvidenceEntity, slotStart: Date? = nil,
                reason: EvidenceWaiverReason, note: String? = nil, createdAt: Date = Date()) {
        self.id = id
        self.requirementId = requirementId
        self.entityType = entity.type
        self.entityId = entity.id
        self.slotStart = slotStart
        self.reason = reason
        self.note = note
        self.createdAt = EvidenceLinks.wholeSeconds(createdAt)
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    public static let databaseTableName = "evidenceWaiver"

    public var entity: EvidenceEntity { EvidenceEntity(type: entityType, id: entityId) }
}

/// Reading and editing requirements and waivers inside a caller's database transaction.
public enum EvidenceRequirements {
    /// Inserts or updates `requirement` after validating it (trimmed name, criteria, range).
    public static func save(db: Database, _ requirement: inout EvidenceRequirement) throws {
        requirement.name = requirement.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !requirement.name.isEmpty else { throw EvidenceRequirementError.blankName }
        if case let .transactionsMatching(categoryIds, accountIds, text) = requirement.scope {
            let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines)
            let blankText = trimmed?.isEmpty ?? true
            guard !categoryIds.isEmpty || !accountIds.isEmpty || !blankText else { throw EvidenceRequirementError.noMatchingCriteria }
            requirement.scope = .transactionsMatching(categoryIds: categoryIds, accountIds: accountIds, descriptionContains: blankText ? nil : trimmed)
        }
        if case let .recordsOfProperty(_, recordType) = requirement.scope, !PropertyEvidence.recordTypes.contains(recordType) {
            throw EvidenceRequirementError.unsupportedRecordType
        }
        if let from = requirement.activeFrom, let to = requirement.activeTo, from >= to { throw EvidenceRequirementError.invalidActiveRange }
        requirement.usualSource = Transaction.normalizedNote(requirement.usualSource)
        requirement.notes = Transaction.normalizedNote(requirement.notes)
        requirement.excludedAccountIds = requirement.excludedAccountIds.reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
        requirement.kinds = requirement.kinds.reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
        try requirement.save(db)
    }

    /// Every requirement, by name then id.
    public static func all(db: Database) throws -> [EvidenceRequirement] {
        try EvidenceRequirement.order(Column("name").collating(.localizedCaseInsensitiveCompare), Column("id")).fetchAll(db)
    }

    /// Deletes the requirement and its waivers; `false` when there was none.
    @discardableResult
    public static func delete(db: Database, id: Int64) throws -> Bool {
        try EvidenceRequirement.deleteOne(db, key: id)
    }

    /// Marks a target as not getting a document (or updates the reason of an existing waiver).
    @discardableResult
    public static func waive(db: Database, requirementId: Int64, target: MissingEvidence.Target,
                             reason: EvidenceWaiverReason = .notAvailable, note: String? = nil) throws -> EvidenceWaiver {
        guard try EvidenceRequirement.exists(db, key: requirementId) else { throw EvidenceRequirementError.requirementNotFound }
        let note = Transaction.normalizedNote(note)
        if var existing = try waiverRequest(requirementId: requirementId, target: target).fetchOne(db) {
            existing.reason = reason
            existing.note = note
            try existing.update(db)
            return existing
        }
        var waiver = EvidenceWaiver(requirementId: requirementId, entity: target.entity, slotStart: target.slot?.start,
                                    reason: reason, note: note)
        try waiver.insert(db)
        return waiver
    }

    /// Removes the waiver of a target; `false` when there was none.
    @discardableResult
    public static func removeWaiver(db: Database, requirementId: Int64, target: MissingEvidence.Target) throws -> Bool {
        try waiverRequest(requirementId: requirementId, target: target).deleteAll(db) > 0
    }

    /// The waivers of a requirement, oldest first.
    public static func waivers(db: Database, requirementId: Int64) throws -> [EvidenceWaiver] {
        try EvidenceWaiver.filter(Column("requirementId") == requirementId).order(Column("id")).fetchAll(db)
    }

    private static func waiverRequest(requirementId: Int64, target: MissingEvidence.Target) -> QueryInterfaceRequest<EvidenceWaiver> {
        let base = EvidenceWaiver.filter(Column("requirementId") == requirementId
                                         && Column("entityType") == target.entity.type.rawValue
                                         && Column("entityId") == target.entity.id)
        if let start = target.slot?.start { return base.filter(Column("slotStart") == start) }
        return base.filter(Column("slotStart") == nil)
    }
}

func registerEvidenceRequirementMigration(_ migrator: inout DatabaseMigrator) {
    migrator.registerMigration("createEvidenceRequirements") { db in
        try db.create(table: "evidenceRequirement") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("name", .text).notNull()
            t.column("scope", .text).notNull()
            t.column("kinds", .text).notNull().defaults(to: "[]")
            t.column("direction", .text).notNull().defaults(to: EvidenceTransactionDirection.outflows.rawValue)
            t.column("excludedAccountIds", .text).notNull().defaults(to: "[]")
            t.column("usualSource", .text)
            t.column("activeFrom", .datetime)
            t.column("activeTo", .datetime)
            t.column("notes", .text)
            t.column("createdAt", .datetime).notNull()
        }
        try db.create(table: "evidenceWaiver") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("requirementId", .integer).notNull().indexed().references("evidenceRequirement", onDelete: .cascade)
            t.column("entityType", .text).notNull()
            t.column("entityId", .integer).notNull()
            t.column("slotStart", .datetime)
            t.column("reason", .text).notNull()
            t.column("note", .text)
            t.column("createdAt", .datetime).notNull()
        }
        // One waiver per target; a NULL slot (transactions, single) is one target too.
        try db.execute(sql: """
            CREATE UNIQUE INDEX evidenceWaiver_target ON evidenceWaiver(requirementId, entityType, entityId, IFNULL(slotStart, ''))
            """)
        // A deleted record no longer needs evidence: drop its waivers (like its links).
        for (table, type) in [("transaction_", EvidenceEntityType.transaction), ("account", .account), ("category", .category)] {
            try db.execute(sql: """
                CREATE TRIGGER evidenceWaiver_delete_\(type.rawValue) AFTER DELETE ON \(table)
                BEGIN DELETE FROM evidenceWaiver WHERE entityType = '\(type.rawValue)' AND entityId = OLD.id; END
                """)
        }
    }
}
