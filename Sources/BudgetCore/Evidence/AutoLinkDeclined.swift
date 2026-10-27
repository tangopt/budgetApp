import Foundation
import GRDB

/// A document–transaction pair the user undid after the waiting-documents job linked it (step 9, plan
/// call 1): the job never makes it again, and it is no longer suggested. Local to this device
/// (`SyncSchema.localOnlyTables`), never a CloudKit record. No foreign keys: a document or transaction
/// deleted (here or by a sync) leaves a row that names nothing, which blocks nothing.
public struct AutoLinkDeclined: Codable, Equatable, FetchableRecord, MutablePersistableRecord, Sendable {
    public var id: Int64?
    public var documentId: Int64
    public var transactionId: Int64
    public var declinedAt: Date

    public init(id: Int64? = nil, documentId: Int64, transactionId: Int64, declinedAt: Date) {
        self.id = id
        self.documentId = documentId
        self.transactionId = transactionId
        self.declinedAt = EvidenceLinks.wholeSeconds(declinedAt)
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    public static let databaseTableName = "autoLinkDeclined"

    /// Records the pair as declined (again: its date moves to `at`).
    static func record(db: Database, documentId: Int64, transactionId: Int64, at date: Date) throws {
        try db.execute(sql: """
            INSERT INTO autoLinkDeclined (documentId, transactionId, declinedAt) VALUES (?, ?, ?)
            ON CONFLICT (documentId, transactionId) DO UPDATE SET declinedAt = excluded.declinedAt
            """, arguments: [documentId, transactionId, EvidenceLinks.wholeSeconds(date)])
    }

    /// The declined transactions of each document (documents without any are absent).
    static func byDocument(db: Database) throws -> [Int64: Set<Int64>] {
        var result: [Int64: Set<Int64>] = [:]
        for row in try Row.fetchAll(db, sql: "SELECT documentId, transactionId FROM autoLinkDeclined") {
            result[row[0] as Int64, default: []].insert(row[1] as Int64)
        }
        return result
    }

    /// The declined transactions of `documentId`.
    static func transactions(db: Database, documentId: Int64) throws -> Set<Int64> {
        Set(try Int64.fetchAll(db, sql: "SELECT transactionId FROM autoLinkDeclined WHERE documentId = ?", arguments: [documentId]))
    }
}

/// Step 9: the pairs undone after an automatic link. Local only; one row per pair.
func registerAutoLinkDeclinedMigration(_ migrator: inout DatabaseMigrator) {
    // Only adds a table.
    migrator.registerMigration("createAutoLinkDeclined") { db in
        try db.create(table: "autoLinkDeclined") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("documentId", .integer).notNull()
            t.column("transactionId", .integer).notNull()
            t.column("declinedAt", .datetime).notNull()
            t.uniqueKey(["documentId", "transactionId"])
        }
    }
}
