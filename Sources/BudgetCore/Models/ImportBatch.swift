import GRDB
import Foundation

public struct ImportBatch: Codable, Equatable, Identifiable, FetchableRecord, MutablePersistableRecord {
    public var id: Int64?
    public var accountId: Int64
    public var sourceFileName: String
    public var importedAt: Date

    public init(id: Int64? = nil, accountId: Int64, sourceFileName: String, importedAt: Date) {
        self.id = id
        self.accountId = accountId
        self.sourceFileName = sourceFileName
        self.importedAt = importedAt
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    public static let databaseTableName = "importBatch"
}

func registerImportBatchMigration(_ migrator: inout DatabaseMigrator) {
    migrator.registerMigration("createImportBatch") { db in
        try db.create(table: "importBatch") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("accountId", .integer).notNull().references("account")
            t.column("sourceFileName", .text).notNull()
            t.column("importedAt", .datetime).notNull()
        }
    }
}
