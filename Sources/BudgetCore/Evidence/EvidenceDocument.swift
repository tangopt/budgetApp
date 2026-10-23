import GRDB
import Foundation

/// What a document is (spec 2026-10-16 §3, §7). Classification rules (`Task 2`) and
/// missing-evidence rules refer to these; `other` is anything not yet classified.
public enum DocumentKind: String, Codable, CaseIterable, Sendable {
    // Property: mortgage, insurance, local taxes, building, tenancy
    /// The bank's notice of an instalment, before its debit (issued mid-month, the breakdown).
    case mortgageNotice
    /// The bank's receipt of an instalment, after its debit ("Recibo de empréstimo" n/total):
    /// evidence of the same debit as its notice, dated on the debit's day.
    case mortgageReceipt
    case mortgageInterestStatement
    case mortgageContract
    case insuranceReceipt
    case insurancePolicy
    case imiNotice
    case imiPayment
    case condominioReceipt
    case rentReceipt
    case rentContract
    /// An addendum to a tenancy's contract ("Aditamento" / "Adenda" ao contrato de
    /// arrendamento): a new rent or term. Filed on the contract's tenancy beside it; never
    /// the contract the tenancy asks for, nor evidence of a transaction.
    case tenancyAddendum
    case utilityInvoice
    case accountantInvoice
    case legalInvoice
    /// A court fee (Portuguese DUC to IGFEJ, "taxa de justiça").
    case courtFee
    /// A letting agent's fee invoice (mediação imobiliária).
    case lettingAgentFee
    case propertyDeed
    case certificate
    // UK employment and tax
    case p60
    case p45
    case p11d
    case taxCodeNotice
    case hmrcPaymentProof
    case sa302
    case taxReturn
    // Portuguese IRS
    case ptIRSDeclaration
    case ptIRSAssessment
    case ptIRSPaymentNote
    case ptIRSPaymentProof
    // Banking
    case bankTransferProof
    /// A bank's advice of a debit from the account (BBVA "Pagamentos – Serviços/Compras",
    /// "Débito Direto"): proof of a payment, never the payee's invoice.
    case bankDebitAdvice
    case bankStatement
    case other
}

extension DocumentKind {
    /// The kind's name everywhere it's shown — lists, pickers, search, checklist exports
    /// ("Mortgage notice", "P60"). The single source of kind labels.
    public var displayName: String {
        switch self {
        case .mortgageNotice: return "Mortgage notice"
        case .mortgageReceipt: return "Mortgage receipt"
        case .mortgageInterestStatement: return "Mortgage interest statement"
        case .mortgageContract: return "Mortgage contract"
        case .insuranceReceipt: return "Insurance receipt"
        case .insurancePolicy: return "Insurance policy"
        case .imiNotice: return "IMI notice"
        case .imiPayment: return "IMI payment"
        case .condominioReceipt: return "Condomínio receipt"
        case .rentReceipt: return "Rent receipt"
        case .rentContract: return "Rent contract"
        case .tenancyAddendum: return "Tenancy addendum"
        case .utilityInvoice: return "Utility invoice"
        case .accountantInvoice: return "Accountant invoice"
        case .legalInvoice: return "Legal invoice"
        case .courtFee: return "Court fee"
        case .lettingAgentFee: return "Letting agent fee"
        case .propertyDeed: return "Property deed"
        case .certificate: return "Certificate"
        case .p60: return "P60"
        case .p45: return "P45"
        case .p11d: return "P11D"
        case .taxCodeNotice: return "Tax code notice"
        case .hmrcPaymentProof: return "HMRC payment proof"
        case .sa302: return "SA302"
        case .taxReturn: return "Tax return"
        case .ptIRSDeclaration: return "PT IRS declaration"
        case .ptIRSAssessment: return "PT IRS assessment"
        case .ptIRSPaymentNote: return "PT IRS payment note"
        case .ptIRSPaymentProof: return "PT IRS payment proof"
        case .bankTransferProof: return "Bank transfer proof"
        case .bankDebitAdvice: return "Bank debit advice"
        case .bankStatement: return "Bank statement"
        case .other: return "Other"
        }
    }
}

/// Whether a document's text can be read (spec §3), set by text extraction.
public enum DocumentTextStatus: String, Codable, CaseIterable, Sendable {
    /// Not analysed yet.
    case unknown
    /// A normal text layer.
    case text
    /// A text layer of obfuscated glyph names that decodes (BBVA PDFs).
    case glyph
    /// Image-only (scans, photos): no text layer.
    case image
    /// Analysed and no text found, or a format without text (spreadsheets, archives).
    case noText = "none"
}

/// A file in the evidence library: a copy of something the user added or that a link needed,
/// stored by content hash under `EvidenceLibrary.root` (spec §3). Documents link to
/// transactions and other records through `DocumentLink`.
public struct EvidenceDocument: Codable, Equatable, Identifiable, FetchableRecord, MutablePersistableRecord, Sendable {
    public var id: Int64?
    /// Lowercase hex SHA-256 of the file's bytes; unique in the library.
    public var sha256: String
    /// Where the copy lives, relative to the library root: `<sha[0..2]>/<sha>.<ext>`.
    public var storedRelativePath: String
    /// The file's name when it was added.
    public var originalFileName: String
    public var byteCount: Int64
    /// `YYYYMMDD - <Area> - <Type> - <Detail>[ - period][ - amount]` (`EvidenceNaming`).
    public var canonicalName: String?
    public var kind: DocumentKind
    /// The document's own date (issue, payment, receipt date).
    public var docDate: Date?
    /// The period the document covers (rent month, insurance cover, tax year).
    public var periodStart: Date?
    public var periodEnd: Date?
    /// The document's headline amount, in `currency`; sign-free (what the document states).
    public var amountMinorUnits: Int?
    public var currency: Currency?
    /// Who the document concerns (e.g. the taxpayers), by name.
    public var persons: [String]
    public var textStatus: DocumentTextStatus
    /// The text read from the document, for search and matching (`textStatus` text/glyph).
    public var extractedText: String?
    /// The registered source folder the file came from, and where in it.
    public var sourceFolderId: Int64?
    public var sourceRelativePath: String?
    /// The source file's modification date when it was last read, to spot changes on a scan.
    public var sourceModifiedAt: Date?
    public var addedAt: Date
    public var note: String?

    public init(id: Int64? = nil, sha256: String, storedRelativePath: String, originalFileName: String, byteCount: Int64,
                canonicalName: String? = nil, kind: DocumentKind = .other, docDate: Date? = nil, periodStart: Date? = nil,
                periodEnd: Date? = nil, amountMinorUnits: Int? = nil, currency: Currency? = nil, persons: [String] = [],
                textStatus: DocumentTextStatus = .unknown, extractedText: String? = nil, sourceFolderId: Int64? = nil,
                sourceRelativePath: String? = nil, sourceModifiedAt: Date? = nil, addedAt: Date, note: String? = nil) {
        self.id = id
        self.sha256 = sha256
        self.storedRelativePath = storedRelativePath
        self.originalFileName = originalFileName
        self.byteCount = byteCount
        self.canonicalName = canonicalName
        self.kind = kind
        self.docDate = docDate
        self.periodStart = periodStart
        self.periodEnd = periodEnd
        self.amountMinorUnits = amountMinorUnits
        self.currency = currency
        self.persons = persons
        self.textStatus = textStatus
        self.extractedText = extractedText
        self.sourceFolderId = sourceFolderId
        self.sourceRelativePath = sourceRelativePath
        self.sourceModifiedAt = sourceModifiedAt
        self.addedAt = addedAt
        self.note = note
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    public static let databaseTableName = "document"

    /// The name to show: the canonical name, else the original file name.
    public var displayName: String {
        if let canonicalName, !canonicalName.isEmpty { return canonicalName }
        return originalFileName
    }

    /// The stored file's extension (lowercase), or "" when it has none.
    public var fileExtension: String {
        (storedRelativePath as NSString).pathExtension
    }
}

/// A document without its extracted text, for lists (the text can be large).
public struct EvidenceDocumentSummary: Codable, Equatable, Identifiable, FetchableRecord, TableRecord, Sendable {
    public var id: Int64
    public var sha256: String
    public var storedRelativePath: String
    public var originalFileName: String
    public var byteCount: Int64
    public var canonicalName: String?
    public var kind: DocumentKind
    public var docDate: Date?
    public var periodStart: Date?
    public var periodEnd: Date?
    public var amountMinorUnits: Int?
    public var currency: Currency?
    public var persons: [String]
    public var textStatus: DocumentTextStatus
    public var sourceFolderId: Int64?
    public var sourceRelativePath: String?
    public var sourceModifiedAt: Date?
    public var addedAt: Date
    public var note: String?

    public static let databaseTableName = EvidenceDocument.databaseTableName

    enum CodingKeys: String, CodingKey, CaseIterable {
        case id, sha256, storedRelativePath, originalFileName, byteCount, canonicalName, kind, docDate, periodStart, periodEnd,
             amountMinorUnits, currency, persons, textStatus, sourceFolderId, sourceRelativePath, sourceModifiedAt, addedAt, note
    }

    public static var databaseSelection: [any SQLSelectable] { CodingKeys.allCases.map { Column($0.rawValue) } }

    /// Every document, newest added first.
    public static var newestFirst: QueryInterfaceRequest<EvidenceDocumentSummary> {
        order(Column("addedAt").desc, Column("id").desc)
    }

    public var displayName: String {
        if let canonicalName, !canonicalName.isEmpty { return canonicalName }
        return originalFileName
    }
}

func registerEvidenceLibraryMigration(_ migrator: inout DatabaseMigrator) {
    migrator.registerMigration("createEvidenceLibrary") { db in
        try db.create(table: "sourceFolder") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("path", .text).notNull().unique()
            t.column("bookmark", .blob)
            t.column("name", .text).notNull()
            t.column("lastScanAt", .datetime)
        }
        try db.create(table: "document") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("sha256", .text).notNull().unique()
            t.column("storedRelativePath", .text).notNull()
            t.column("originalFileName", .text).notNull()
            t.column("byteCount", .integer).notNull()
            t.column("canonicalName", .text)
            t.column("kind", .text).notNull().defaults(to: DocumentKind.other.rawValue)
            t.column("docDate", .datetime)
            t.column("periodStart", .datetime)
            t.column("periodEnd", .datetime)
            t.column("amountMinorUnits", .integer)
            t.column("currency", .text)
            t.column("persons", .text).notNull().defaults(to: "[]")
            t.column("textStatus", .text).notNull().defaults(to: DocumentTextStatus.unknown.rawValue)
            t.column("extractedText", .text)
            t.column("sourceFolderId", .integer).indexed().references("sourceFolder", onDelete: .setNull)
            t.column("sourceRelativePath", .text)
            t.column("sourceModifiedAt", .datetime)
            t.column("addedAt", .datetime).notNull()
            t.column("note", .text)
        }
        try db.create(table: "documentLink") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("documentId", .integer).notNull().references("document", onDelete: .cascade)
            t.column("entityType", .text).notNull()
            t.column("entityId", .integer).notNull()
            t.column("role", .text)
            t.column("createdAt", .datetime).notNull()
            t.uniqueKey(["documentId", "entityType", "entityId"])
        }
        try db.create(index: "documentLink_entity", on: "documentLink", columns: ["entityType", "entityId"])
        // Links point at records by type and id (no foreign key), so deleting a record drops
        // its links here. Tables added later (property, tax year…) add their own trigger.
        for (table, type) in [("transaction_", EvidenceEntityType.transaction), ("account", .account), ("category", .category)] {
            try db.execute(sql: """
                CREATE TRIGGER documentLink_delete_\(type.rawValue) AFTER DELETE ON \(table)
                BEGIN DELETE FROM documentLink WHERE entityType = '\(type.rawValue)' AND entityId = OLD.id; END
                """)
        }
    }
}
