import GRDB
import Foundation

/// A folder of the user's the app remembers and scans for new or changed evidence (spec §3):
/// Lisboa, Tax, IRS UK. Nothing in it is moved or changed without the user's approval.
public struct SourceFolder: Codable, Equatable, Identifiable, FetchableRecord, MutablePersistableRecord, Sendable {
    public var id: Int64?
    /// The folder's path when registered (display and matching; the bookmark is authoritative).
    public var path: String
    /// A security-scoped bookmark to reopen the folder across launches (sandbox, iOS).
    public var bookmark: Data?
    public var name: String
    public var lastScanAt: Date?

    public init(id: Int64? = nil, path: String, bookmark: Data?, name: String, lastScanAt: Date? = nil) {
        self.id = id
        self.path = path
        self.bookmark = bookmark
        self.name = name
        self.lastScanAt = lastScanAt
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    public static let databaseTableName = "sourceFolder"
}

/// A file seen in a source folder by a scan (spec §3): its size, modification date and hash
/// when last read — so a rescan only rehashes files whose size or date changed — and the
/// library document with that content, if any. A change of content is kept pending (the earlier
/// hash and document, and when it was noticed) until `SourceFolderScanner.acknowledgeChange`.
/// Rows stay after the file disappears (reported as missing); removing the folder removes them.
public struct SourceFile: Codable, Equatable, Identifiable, FetchableRecord, MutablePersistableRecord, Sendable {
    public var id: Int64?
    public var folderId: Int64
    /// Path inside the folder, `/`-separated.
    public var relativePath: String
    public var size: Int64
    public var modifiedAt: Date
    /// Lowercase hex SHA-256 of the content when last read.
    public var sha256: String
    /// The library document with this content (set when it's in the library).
    public var documentId: Int64?
    /// The last scan that found the file in the folder.
    public var lastSeenAt: Date
    /// A pending change: the content (and its library document) before the change, and the
    /// scan that noticed it. All `nil` when there is none.
    public var previousSha256: String?
    public var previousDocumentId: Int64?
    public var changeDetectedAt: Date?

    public var hasPendingChange: Bool { changeDetectedAt != nil }

    public init(id: Int64? = nil, folderId: Int64, relativePath: String, size: Int64, modifiedAt: Date, sha256: String,
                documentId: Int64? = nil, lastSeenAt: Date, previousSha256: String? = nil, previousDocumentId: Int64? = nil,
                changeDetectedAt: Date? = nil) {
        self.id = id
        self.folderId = folderId
        self.relativePath = relativePath
        self.size = size
        self.modifiedAt = modifiedAt
        self.sha256 = sha256
        self.documentId = documentId
        self.lastSeenAt = lastSeenAt
        self.previousSha256 = previousSha256
        self.previousDocumentId = previousDocumentId
        self.changeDetectedAt = changeDetectedAt
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    public static let databaseTableName = "sourceFile"
}

func registerEvidenceSourceFilesMigration(_ migrator: inout DatabaseMigrator) {
    migrator.registerMigration("createEvidenceSourceFiles") { db in
        try db.create(table: "sourceFile") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("folderId", .integer).notNull().references("sourceFolder", onDelete: .cascade)
            t.column("relativePath", .text).notNull()
            t.column("size", .integer).notNull()
            t.column("modifiedAt", .datetime).notNull()
            t.column("sha256", .text).notNull()
            t.column("documentId", .integer).indexed().references("document", onDelete: .setNull)
            t.column("lastSeenAt", .datetime).notNull()
            t.column("previousSha256", .text)
            t.column("previousDocumentId", .integer).indexed().references("document", onDelete: .setNull)
            t.column("changeDetectedAt", .datetime)
            t.uniqueKey(["folderId", "relativePath"])
        }
    }
}
