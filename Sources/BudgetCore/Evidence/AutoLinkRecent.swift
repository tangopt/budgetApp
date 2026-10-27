import Foundation
import GRDB

/// A link the waiting-documents job made after a sync pull (step 9): no import summary shows it, so it is kept
/// here until the person sees it ("Linked automatically", with Undo, in Documents) and dismisses it, or undoes it.
/// Local to this device (`SyncSchema.localOnlyTables`), never a CloudKit record. No foreign keys: a row naming a
/// document or transaction gone since (or a link removed since) is simply not listed.
public struct AutoLinkRecent: Codable, Equatable, FetchableRecord, MutablePersistableRecord, Sendable {
    public var id: Int64?
    public var documentId: Int64
    public var transactionId: Int64
    public var linkedAt: Date

    public init(id: Int64? = nil, documentId: Int64, transactionId: Int64, linkedAt: Date) {
        self.id = id
        self.documentId = documentId
        self.transactionId = transactionId
        self.linkedAt = EvidenceLinks.wholeSeconds(linkedAt)
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    public static let databaseTableName = "autoLinkRecent"

    public var pair: WaitingDocuments.Pair { WaitingDocuments.Pair(documentId: documentId, transactionId: transactionId) }

    /// Keeps the pairs (again: the date moves to `at`).
    static func record(db: Database, _ pairs: [WaitingDocuments.Pair], at date: Date) throws {
        for pair in pairs {
            try db.execute(sql: """
                INSERT INTO autoLinkRecent (documentId, transactionId, linkedAt) VALUES (?, ?, ?)
                ON CONFLICT (documentId, transactionId) DO UPDATE SET linkedAt = excluded.linkedAt
                """, arguments: [pair.documentId, pair.transactionId, EvidenceLinks.wholeSeconds(date)])
        }
    }

    static func remove(db: Database, _ pairs: [WaitingDocuments.Pair]) throws {
        for pair in pairs {
            try db.execute(sql: "DELETE FROM autoLinkRecent WHERE documentId = ? AND transactionId = ?",
                           arguments: [pair.documentId, pair.transactionId])
        }
    }
}

extension WaitingDocuments {
    /// After a sync pull (the Mac's `SyncScheduler.afterPull`): the transactions the pull added
    /// (`SyncPulledRows.takeTransactions`; none: nothing runs) given to `run`, and the links it made kept for
    /// `recentAutoLinks`. Runs in the caller's write.
    @discardableResult
    public static func runAfterPull(db: Database, now: Date = Date()) throws -> Outcome {
        let pulled = try SyncPulledRows.takeTransactions(db: db)
        guard !pulled.isEmpty else { return Outcome() }
        let outcome = try run(db: db, newTransactions: pulled, now: now)
        try AutoLinkRecent.record(db: db, outcome.linked, at: now)
        return outcome
    }

    /// The links the job made after sync pulls that are still in place and not dismissed, newest first (then by
    /// document): what Documents shows as "Linked automatically", each with Undo (`undo`, which also drops it here)
    /// and dismissable (`dismissRecentAutoLinks`). Names: `describe`.
    public static func recentAutoLinks(db: Database) throws -> [AutoLinkRecent] {
        try AutoLinkRecent.fetchAll(db, sql: """
            SELECT r.* FROM autoLinkRecent r
            WHERE EXISTS (SELECT 1 FROM documentLink l WHERE l.documentId = r.documentId AND l.entityType = ? AND l.entityId = r.transactionId)
            ORDER BY r.linkedAt DESC, r.documentId, r.transactionId
            """, arguments: [EvidenceEntityType.transaction.rawValue])
    }

    /// The person has seen them: no longer listed (the links stay).
    public static func dismissRecentAutoLinks(db: Database, _ pairs: [Pair]) throws {
        try AutoLinkRecent.remove(db: db, pairs)
    }
}

/// Step 9: the links made after sync pulls, until seen. Local only; one row per pair.
func registerAutoLinkRecentMigration(_ migrator: inout DatabaseMigrator) {
    // Only adds a table.
    migrator.registerMigration("createAutoLinkRecent") { db in
        try db.create(table: "autoLinkRecent") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("documentId", .integer).notNull()
            t.column("transactionId", .integer).notNull()
            t.column("linkedAt", .datetime).notNull()
            t.uniqueKey(["documentId", "transactionId"])
        }
    }
}
