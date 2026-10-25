import GRDB
import Foundation

/// One document shown on a transaction (the budget's paperclip popover, Search, Edit transaction).
public struct TransactionDocument: Equatable, Identifiable, Sendable {
    /// The document's id.
    public var id: Int64
    /// The kind's name, a custom kind's included (`DocumentKindCatalog`).
    public var kindLabel: String
    public var displayName: String
    public var docDate: Date?
    public var amountMinorUnits: Int?
    public var currency: Currency?
    public var storedRelativePath: String
    public var fileExtension: String
    /// What the document is for this transaction (the link's role), when it has one.
    public var role: String?
    /// How many other transactions the same document is evidence for.
    public var otherTransactionCount: Int

    public init(id: Int64, kindLabel: String, displayName: String, docDate: Date?, amountMinorUnits: Int?, currency: Currency?,
                storedRelativePath: String, fileExtension: String, role: String?, otherTransactionCount: Int) {
        self.id = id
        self.kindLabel = kindLabel
        self.displayName = displayName
        self.docDate = docDate
        self.amountMinorUnits = amountMinorUnits
        self.currency = currency
        self.storedRelativePath = storedRelativePath
        self.fileExtension = fileExtension
        self.role = role
        self.otherTransactionCount = otherTransactionCount
    }
}

/// A transaction's documents: the ones linked to it, plus the document of a recorded utility
/// invoice whose `transactionId` is it (once, even when also linked).
public enum TransactionDocuments {
    /// SQL: the (transaction, document) pairs, a linked document and a recorded invoice's counted once.
    private static let pairs = """
        SELECT entityId AS tx, documentId FROM documentLink WHERE entityType = 'transaction'
        UNION
        SELECT transactionId AS tx, documentId FROM utilityInvoice WHERE transactionId IS NOT NULL AND documentId IS NOT NULL
        """

    /// The documents of the transaction, oldest document date first (undated last), then by id.
    public static func documents(db: Database, transactionId: Int64, catalog: DocumentKindCatalog) throws -> [TransactionDocument] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT document.*,
                   (SELECT documentLink.role FROM documentLink
                    WHERE documentLink.documentId = document.id AND documentLink.entityType = 'transaction'
                      AND documentLink.entityId = :t) AS linkRole,
                   (SELECT COUNT(*) FROM (\(pairs)) AS p WHERE p.documentId = document.id AND p.tx != :t) AS otherCount
            FROM document
            WHERE document.id IN (SELECT documentId FROM (\(pairs)) WHERE tx = :t)
            ORDER BY document.docDate IS NULL, document.docDate, document.id
            """, arguments: ["t": transactionId])
        return try rows.map { row in
            let document = try EvidenceDocument(row: row)
            return TransactionDocument(
                id: document.id ?? -1, kindLabel: catalog.displayName(of: document), displayName: document.displayName,
                docDate: document.docDate, amountMinorUnits: document.amountMinorUnits, currency: document.currency,
                storedRelativePath: document.storedRelativePath, fileExtension: document.fileExtension,
                role: row["linkRole"], otherTransactionCount: row["otherCount"])
        }
    }

    /// How many documents each of `transactionIds` has (those without any are absent), in one read
    /// per 500 ids.
    public static func counts(db: Database, transactionIds: [Int64]) throws -> [Int64: Int] {
        var result: [Int64: Int] = [:]
        for start in stride(from: 0, to: transactionIds.count, by: 500) {
            let chunk = Array(transactionIds[start..<min(start + 500, transactionIds.count)])
            let marks = databaseQuestionMarks(count: chunk.count)
            let rows = try Row.fetchAll(db, sql: """
                SELECT tx, COUNT(*) FROM (\(pairs)) WHERE tx IN (\(marks)) GROUP BY tx
                """, arguments: StatementArguments(chunk))
            for row in rows { result[row[0]] = row[1] }
        }
        return result
    }

    /// How many documents every transaction that has some has (what the paperclips observe).
    public static func allCounts(db: Database) throws -> [Int64: Int] {
        let rows = try Row.fetchAll(db, sql: "SELECT tx, COUNT(*) FROM (\(pairs)) GROUP BY tx")
        return Dictionary(uniqueKeysWithValues: rows.map { (row: Row) in (row[0] as Int64, row[1] as Int) })
    }
}

extension EvidenceLibrary {
    /// The library file of a stored path.
    public func fileURL(storedRelativePath: String) -> URL {
        root.appendingPathComponent(storedRelativePath)
    }

    /// Whether the file is in this Mac's library (a document synced from another device may not have arrived).
    public func isOnThisDevice(storedRelativePath: String) -> Bool {
        FileManager.default.fileExists(atPath: fileURL(storedRelativePath: storedRelativePath).path)
    }
}
