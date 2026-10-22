import GRDB
import Foundation

/// One confirmed run of the document importer: the unit the user can undo.
public struct ImportRun: Codable, Equatable, Identifiable, FetchableRecord, MutablePersistableRecord, Sendable {
    public var id: Int64?
    public var confirmedAt: Date
    public var entryPoint: String
    public var summary: String
    public var backupPath: String?
    /// JSON `[String: String]`: item id (UUID string) -> the user's reason (used by import-anyway).
    public var reasonsJSON: String?
    public var undoneAt: Date?
    public var undoSummary: String?
    /// Who confirmed the run; nil for the CLI tools and for runs before sign-in existed.
    public var appUserId: Int64?

    public init(id: Int64? = nil, confirmedAt: Date, entryPoint: String, summary: String,
                backupPath: String? = nil, reasonsJSON: String? = nil,
                undoneAt: Date? = nil, undoSummary: String? = nil, appUserId: Int64? = nil) {
        self.id = id
        self.confirmedAt = confirmedAt
        self.entryPoint = entryPoint
        self.summary = summary
        self.backupPath = backupPath
        self.reasonsJSON = reasonsJSON
        self.undoneAt = undoneAt
        self.undoSummary = undoSummary
        self.appUserId = appUserId
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }

    public static let databaseTableName = "importRun"
}

public enum ImportChangeOperation: String, Codable, Sendable {
    case insert, update, delete
}

/// One row-level change made by a run, kept so the run can be undone.
public struct ImportChange: Codable, Equatable, Identifiable, FetchableRecord, MutablePersistableRecord, Sendable {
    public var id: Int64?
    public var runId: Int64
    public var seq: Int
    public var tableName: String
    public var rowId: Int64
    public var operation: ImportChangeOperation
    public var beforeJSON: String?
    public var afterJSON: String?

    public init(id: Int64? = nil, runId: Int64, seq: Int, tableName: String, rowId: Int64,
                operation: ImportChangeOperation, beforeJSON: String? = nil, afterJSON: String? = nil) {
        self.id = id
        self.runId = runId
        self.seq = seq
        self.tableName = tableName
        self.rowId = rowId
        self.operation = operation
        self.beforeJSON = beforeJSON
        self.afterJSON = afterJSON
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }

    public static let databaseTableName = "importChange"
}

public enum ImportFileOutcome: String, Codable, CaseIterable, Sendable {
    case filed, linked, recorded, duplicate, leftOut, transactions
}

public struct ImportRunFile: Codable, Equatable, Identifiable, FetchableRecord, MutablePersistableRecord, Sendable {
    public var id: Int64?
    public var runId: Int64
    public var fileName: String
    public var sha256: String
    public var documentId: Int64?
    public var outcome: ImportFileOutcome
    public var detail: String

    public init(id: Int64? = nil, runId: Int64, fileName: String, sha256: String,
                documentId: Int64? = nil, outcome: ImportFileOutcome, detail: String) {
        self.id = id
        self.runId = runId
        self.fileName = fileName
        self.sha256 = sha256
        self.documentId = documentId
        self.outcome = outcome
        self.detail = detail
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }

    public static let databaseTableName = "importRunFile"
}

func registerImportRunMigration(_ migrator: inout DatabaseMigrator) {
    migrator.registerMigration("createImportRun") { db in
        try db.create(table: "importRun") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("confirmedAt", .datetime).notNull()
            t.column("entryPoint", .text).notNull()
            t.column("summary", .text).notNull()
            t.column("backupPath", .text)
            t.column("reasonsJSON", .text)
            t.column("undoneAt", .datetime)
            t.column("undoSummary", .text)
        }
        try db.create(table: "importChange") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("runId", .integer).notNull().references("importRun", onDelete: .cascade)
            t.column("seq", .integer).notNull()
            t.column("tableName", .text).notNull()
            t.column("rowId", .integer).notNull()
            t.column("operation", .text).notNull()
            t.column("beforeJSON", .text)
            t.column("afterJSON", .text)
        }
        try db.create(index: "importChange_on_table_row", on: "importChange", columns: ["tableName", "rowId"])
        try db.create(table: "importRunFile") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("runId", .integer).notNull().references("importRun", onDelete: .cascade)
            t.column("fileName", .text).notNull()
            t.column("sha256", .text).notNull()
            t.column("documentId", .integer)
            t.column("outcome", .text).notNull()
            t.column("detail", .text).notNull()
        }
        try db.alter(table: "importBatch") { t in
            t.add(column: "importRunId", .integer).references("importRun", onDelete: .setNull)
        }
    }
}
