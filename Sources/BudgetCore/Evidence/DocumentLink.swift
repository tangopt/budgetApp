import GRDB
import Foundation

/// The kinds of record a document can be evidence for (spec §2).
public enum EvidenceEntityType: String, Codable, CaseIterable, Sendable {
    case transaction
    case account
    case category
    case property
    case taxYear
    case person
    case other
    case tenancy
    case rentReceipt
    case taxManualItem
    case employment
    case employmentIncome
    case hmrcPayment
    case otherIncome
    case pensionContribution
    case taxPolicyReceipt
}

/// A record a document links to.
public struct EvidenceEntity: Codable, Hashable, Sendable {
    public var type: EvidenceEntityType
    public var id: Int64

    public init(type: EvidenceEntityType, id: Int64) {
        self.type = type
        self.id = id
    }

    public static func transaction(_ id: Int64) -> EvidenceEntity { EvidenceEntity(type: .transaction, id: id) }
    public static func account(_ id: Int64) -> EvidenceEntity { EvidenceEntity(type: .account, id: id) }
    public static func category(_ id: Int64) -> EvidenceEntity { EvidenceEntity(type: .category, id: id) }
}

/// A document is evidence for a record (spec §2): many-to-many — one IMI notice links to
/// three instalment payments, one transaction can have a notice and a receipt. At most one
/// link per (document, entity type, entity id).
public struct DocumentLink: Codable, Equatable, Identifiable, FetchableRecord, MutablePersistableRecord, Sendable {
    public var id: Int64?
    public var documentId: Int64
    public var entityType: EvidenceEntityType
    public var entityId: Int64
    /// What the document is for this record, free text (e.g. "notice", "payment proof").
    public var role: String?
    public var createdAt: Date

    public init(id: Int64? = nil, documentId: Int64, entity: EvidenceEntity, role: String?, createdAt: Date = Date()) {
        self.id = id
        self.documentId = documentId
        self.entityType = entity.type
        self.entityId = entity.id
        self.role = role
        self.createdAt = EvidenceLinks.wholeSeconds(createdAt)
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    public static let databaseTableName = "documentLink"

    public var entity: EvidenceEntity { EvidenceEntity(type: entityType, id: entityId) }

    static func filter(_ entity: EvidenceEntity) -> QueryInterfaceRequest<DocumentLink> {
        filter(Column("entityType") == entity.type.rawValue && Column("entityId") == entity.id)
    }
}

/// Reading and editing document links inside a caller's database transaction. Prefer the
/// `EvidenceLibrary` methods; these compose with other writes (add + link in one go).
public enum EvidenceLinks {
    /// Links `documentId` to `entity`, or updates the role of the existing link (a `nil` role
    /// keeps the current one; `setRole` clears it). A transaction, account or category must exist.
    @discardableResult
    public static func link(db: Database, documentId: Int64, to entity: EvidenceEntity, role: String? = nil) throws -> DocumentLink {
        guard try EvidenceDocument.exists(db, key: documentId) else { throw EvidenceLibraryError.documentNotFound }
        guard try entityExists(db: db, entity) else { throw EvidenceLibraryError.entityNotFound }
        let role = Transaction.normalizedNote(role)
        if var existing = try DocumentLink.filter(entity).filter(Column("documentId") == documentId).fetchOne(db) {
            if let role, role != existing.role {
                existing.role = role
                try existing.update(db)
            }
            return existing
        }
        var link = DocumentLink(documentId: documentId, entity: entity, role: role)
        try link.insert(db)
        return link
    }

    /// Sets (or, with `nil`, clears) the role of an existing link; `false` when there is none.
    @discardableResult
    public static func setRole(db: Database, _ role: String?, documentId: Int64, entity: EvidenceEntity) throws -> Bool {
        guard var link = try DocumentLink.filter(entity).filter(Column("documentId") == documentId).fetchOne(db) else { return false }
        link.role = Transaction.normalizedNote(role)
        try link.update(db)
        return true
    }

    /// Whether the record exists, for the types that have a table; others are trusted.
    static func entityExists(db: Database, _ entity: EvidenceEntity) throws -> Bool {
        switch entity.type {
        case .transaction: return try Transaction.exists(db, key: entity.id)
        case .account: return try Account.exists(db, key: entity.id)
        case .category: return try Category.exists(db, key: entity.id)
        case .property: return try Property.exists(db, key: entity.id)
        case .person: return try Person.exists(db, key: entity.id)
        case .tenancy: return try Tenancy.exists(db, key: entity.id)
        case .rentReceipt: return try RentReceipt.exists(db, key: entity.id)
        case .taxYear: return try TaxYear.exists(db, key: entity.id)
        case .taxManualItem: return try TaxManualItem.exists(db, key: entity.id)
        case .employment: return try Employment.exists(db, key: entity.id)
        case .employmentIncome: return try EmploymentIncome.exists(db, key: entity.id)
        case .hmrcPayment: return try HMRCPayment.exists(db, key: entity.id)
        case .otherIncome: return try OtherIncome.exists(db, key: entity.id)
        case .pensionContribution: return try PensionContribution.exists(db, key: entity.id)
        case .taxPolicyReceipt: return try TaxPolicyReceipt.exists(db, key: entity.id)
        case .other: return true
        }
    }

    /// Removes the link; `false` when there was none.
    @discardableResult
    public static func unlink(db: Database, documentId: Int64, from entity: EvidenceEntity) throws -> Bool {
        try DocumentLink.filter(entity).filter(Column("documentId") == documentId).deleteAll(db) > 0
    }

    /// The documents linked to `entity`, oldest document date first (undated last), then by id.
    public static func documents(db: Database, for entity: EvidenceEntity) throws -> [EvidenceDocument] {
        try EvidenceDocument.fetchAll(db, sql: """
            SELECT document.* FROM document JOIN documentLink ON documentLink.documentId = document.id
            WHERE documentLink.entityType = ? AND documentLink.entityId = ?
            ORDER BY document.docDate IS NULL, document.docDate, document.id
            """, arguments: [entity.type.rawValue, entity.id])
    }

    /// The links of `documentId`, in the order they were made.
    public static func links(db: Database, for documentId: Int64) throws -> [DocumentLink] {
        try DocumentLink.filter(Column("documentId") == documentId).order(Column("id")).fetchAll(db)
    }

    /// How many documents each record of `type` has (records without any are absent).
    public static func linkCounts(db: Database, _ type: EvidenceEntityType) throws -> [Int64: Int] {
        let rows = try Row.fetchAll(db, sql: "SELECT entityId, COUNT(*) FROM documentLink WHERE entityType = ? GROUP BY entityId",
                                    arguments: [type.rawValue])
        return Dictionary(uniqueKeysWithValues: rows.map { (row: Row) in (row[0] as Int64, row[1] as Int) })
    }

    /// The documents each record of `type` has, by document id (records without any are absent).
    public static func linkedDocumentIds(db: Database, _ type: EvidenceEntityType) throws -> [Int64: [Int64]] {
        let rows = try Row.fetchAll(db, sql: "SELECT entityId, documentId FROM documentLink WHERE entityType = ? ORDER BY entityId, documentId",
                                    arguments: [type.rawValue])
        return Dictionary(grouping: rows, by: { (row: Row) -> Int64 in row[0] }).mapValues { $0.map { (row: Row) -> Int64 in row[1] } }
    }

    /// Documents linked to nothing, newest added first.
    public static func unlinkedDocuments(db: Database) throws -> [EvidenceDocument] {
        try EvidenceDocument
            .filter(sql: "id NOT IN (SELECT documentId FROM documentLink)")
            .order(Column("addedAt").desc, Column("id").desc)
            .fetchAll(db)
    }

    /// Moves every link of `from` to `to` (a record replaced by another, e.g. a manual entry
    /// by its imported transaction). Where a document already links to `to`, that link wins.
    public static func repoint(db: Database, from: EvidenceEntity, to: EvidenceEntity) throws {
        guard from != to else { return }
        try db.execute(sql: """
            UPDATE OR IGNORE documentLink SET entityType = ?, entityId = ? WHERE entityType = ? AND entityId = ?
            """, arguments: [to.type.rawValue, to.id, from.type.rawValue, from.id])
        try DocumentLink.filter(from).deleteAll(db)
    }

    /// Timestamps are kept to the second, so a record reads back equal to what was written.
    static func wholeSeconds(_ date: Date) -> Date {
        Date(timeIntervalSinceReferenceDate: date.timeIntervalSinceReferenceDate.rounded(.down))
    }
}
