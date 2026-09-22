import GRDB

public enum ImportFormat: String, Codable, CaseIterable {
    case csv
    case pdf
}

public struct ImportProfile: Codable, Equatable, Identifiable, FetchableRecord, MutablePersistableRecord {
    public var id: Int64?
    public var accountId: Int64
    public var format: ImportFormat
    public var csvDelimiter: String?
    public var csvDateColumnIndex: Int?
    public var csvDescriptionColumnIndex: Int?
    public var csvAmountColumnIndex: Int?
    public var csvDateFormat: String?
    public var pdfLayoutConfig: String?

    public init(id: Int64? = nil, accountId: Int64, format: ImportFormat, csvDelimiter: String? = nil, csvDateColumnIndex: Int? = nil, csvDescriptionColumnIndex: Int? = nil, csvAmountColumnIndex: Int? = nil, csvDateFormat: String? = nil, pdfLayoutConfig: String? = nil) {
        self.id = id
        self.accountId = accountId
        self.format = format
        self.csvDelimiter = csvDelimiter
        self.csvDateColumnIndex = csvDateColumnIndex
        self.csvDescriptionColumnIndex = csvDescriptionColumnIndex
        self.csvAmountColumnIndex = csvAmountColumnIndex
        self.csvDateFormat = csvDateFormat
        self.pdfLayoutConfig = pdfLayoutConfig
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    public static let databaseTableName = "importProfile"
}

func registerImportProfileMigration(_ migrator: inout DatabaseMigrator) {
    migrator.registerMigration("createImportProfile") { db in
        try db.create(table: "importProfile") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("accountId", .integer).notNull().references("account")
            t.column("format", .text).notNull()
            t.column("csvDelimiter", .text)
            t.column("csvDateColumnIndex", .integer)
            t.column("csvDescriptionColumnIndex", .integer)
            t.column("csvAmountColumnIndex", .integer)
            t.column("csvDateFormat", .text)
            t.column("pdfLayoutConfig", .text)
            t.uniqueKey(["accountId", "format"])
        }
    }
}
