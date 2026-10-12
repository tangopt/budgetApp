import GRDB
import Foundation

public enum TransactionStatus: String, Codable, CaseIterable, Sendable {
    case pendingReview
    case confirmed
}

public enum CategorizedBy: String, Codable, CaseIterable, Sendable {
    case rule
    case llm
    case history
    case manual
    case none
    /// Matched to the other leg of a transfer between the user's accounts (import review):
    /// the category is that leg's.
    case transfer
}

public struct Transaction: Codable, Equatable, Identifiable, FetchableRecord, MutablePersistableRecord, Sendable {
    public var id: Int64?
    public var importBatchId: Int64
    public var accountId: Int64
    public var date: Date
    public var rawDescription: String
    public var amountMinorUnits: Int
    public var categoryId: Int64?
    public var status: TransactionStatus
    public var categorizedBy: CategorizedBy
    public var fingerprint: String
    /// The user's own note, from Review or Edit transaction (spec §5); never blank.
    public var note: String?

    public init(id: Int64? = nil, importBatchId: Int64, accountId: Int64, date: Date, rawDescription: String, amountMinorUnits: Int, categoryId: Int64?, status: TransactionStatus, categorizedBy: CategorizedBy, fingerprint: String, note: String? = nil) {
        self.id = id
        self.importBatchId = importBatchId
        self.accountId = accountId
        self.date = date
        self.rawDescription = rawDescription
        self.amountMinorUnits = amountMinorUnits
        self.categoryId = categoryId
        self.status = status
        self.categorizedBy = categorizedBy
        self.fingerprint = fingerprint
        self.note = note
    }

    /// A note as saved: trimmed, and `nil` when blank.
    public static func normalizedNote(_ note: String?) -> String? {
        guard let trimmed = note?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    public static let databaseTableName = "transaction_"
}

func registerTransactionMigration(_ migrator: inout DatabaseMigrator) {
    migrator.registerMigration("createTransaction") { db in
        try db.create(table: "transaction_") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("importBatchId", .integer).notNull().references("importBatch")
            t.column("accountId", .integer).notNull().references("account")
            t.column("date", .datetime).notNull()
            t.column("rawDescription", .text).notNull()
            t.column("amountMinorUnits", .integer).notNull()
            t.column("categoryId", .integer).references("category")
            t.column("status", .text).notNull()
            t.column("categorizedBy", .text).notNull()
            t.column("fingerprint", .text).notNull()
            t.uniqueKey(["accountId", "fingerprint"])
        }
    }
}

func registerTransactionNoteMigration(_ migrator: inout DatabaseMigrator) {
    migrator.registerMigration("addTransactionNote") { db in
        try db.alter(table: "transaction_") { t in
            t.add(column: "note", .text)
        }
    }
}
