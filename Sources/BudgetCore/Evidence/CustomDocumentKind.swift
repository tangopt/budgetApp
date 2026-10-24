import GRDB
import Foundation

/// The library area a custom kind files under (spec 2026-10-24 §2): the `<Area>` of its
/// documents' canonical names.
public enum DocumentArea: String, Codable, CaseIterable, Sendable {
    case property
    case tax
    case bank
    case other

    /// The area as canonical names and the library show it.
    public var libraryArea: String {
        switch self {
        case .property: return "Property"
        case .tax: return "Tax"
        case .bank: return "Bank"
        case .other: return "Other"
        }
    }
}

/// A document kind the user made (spec 2026-10-24 §2), synced: its name is unique ignoring
/// case, so one name is the same kind on every device. A document of a custom kind keeps
/// `kind = .other` and names it in `customKindId`.
public struct CustomDocumentKind: Codable, Equatable, Identifiable, FetchableRecord, MutablePersistableRecord, Sendable {
    public var id: Int64?
    public var name: String
    public var area: DocumentArea
    public var createdAt: Date

    public init(id: Int64? = nil, name: String, area: DocumentArea, createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.area = area
        self.createdAt = EvidenceLinks.wholeSeconds(createdAt)
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    public static let databaseTableName = "customDocumentKind"
}

/// A document kind, built-in or custom: how code talks about kinds once custom ones exist.
public enum DocumentKindRef: Hashable, Codable, Sendable {
    case builtIn(DocumentKind)
    case custom(Int64)
}

/// Every kind with its name and library area, read once (spec 2026-10-24 §2).
public struct DocumentKindCatalog: Sendable {
    public let customKinds: [CustomDocumentKind]
    private let customById: [Int64: CustomDocumentKind]

    public init(customKinds: [CustomDocumentKind]) {
        self.customKinds = customKinds.sorted { Self.ordered($0.name, $1.name) }
        self.customById = Dictionary(customKinds.compactMap { kind in kind.id.map { ($0, kind) } }, uniquingKeysWith: { first, _ in first })
    }

    public static func load(db: Database) throws -> DocumentKindCatalog {
        DocumentKindCatalog(customKinds: try CustomDocumentKind.fetchAll(db))
    }

    /// The built-in kinds by name, then the custom kinds by name.
    public var all: [DocumentKindRef] {
        let builtIns = DocumentKind.allCases.sorted { Self.ordered($0.displayName, $1.displayName) }
        return builtIns.map(DocumentKindRef.builtIn) + customKinds.compactMap { $0.id.map(DocumentKindRef.custom) }
    }

    /// The kind's name; a custom kind that's gone reads as Other.
    public func displayName(_ ref: DocumentKindRef) -> String {
        switch ref {
        case .builtIn(let kind): return kind.displayName
        case .custom(let id): return customById[id]?.name ?? DocumentKind.other.displayName
        }
    }

    /// The `<Area>` of the kind's canonical names; a custom kind that's gone reads as Other.
    public func libraryArea(_ ref: DocumentKindRef) -> String {
        switch ref {
        case .builtIn(let kind): return ImportNaming.area(of: kind)
        case .custom(let id): return customById[id]?.area.libraryArea ?? ImportNaming.area(of: .other)
        }
    }

    /// The custom kind called `name`, ignoring case, accents and surrounding spaces.
    public func custom(named name: String) -> CustomDocumentKind? {
        let wanted = Self.key(name)
        return customKinds.first { Self.key($0.name) == wanted }
    }

    /// A custom kind by id.
    public func custom(id: Int64) -> CustomDocumentKind? {
        customById[id]
    }

    static func key(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    private static func ordered(_ a: String, _ b: String) -> Bool {
        a.localizedStandardCompare(b) == .orderedAscending
    }
}

func registerCustomDocumentKindMigration(_ migrator: inout DatabaseMigrator) {
    // Only adds: a table, a nullable column and a column with a default.
    migrator.registerMigration("createCustomDocumentKinds") { db in
        try db.create(table: "customDocumentKind") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("name", .text).notNull().collate(.nocase).unique()
            t.column("area", .text).notNull()
            t.column("createdAt", .datetime).notNull()
        }
        try db.alter(table: "document") { t in
            t.add(column: "customKindId", .integer).references("customDocumentKind", onDelete: .setNull)
        }
        try db.create(index: "document_customKindId", on: "document", columns: ["customKindId"])
        try db.alter(table: "evidenceRequirement") { t in
            t.add(column: "customKindIds", .text).notNull().defaults(to: "[]")
        }
    }
}
