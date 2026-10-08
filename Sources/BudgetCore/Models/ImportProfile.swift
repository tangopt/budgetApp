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
    /// When set, the statement splits amounts into two columns instead of one signed
    /// column: `csvAmountColumnIndex` holds the debit (money out) column and this holds
    /// the credit (money in) column. Exactly one of the two is expected to have a value
    /// per row — see `CSVStatementParser` for how a row is resolved (or rejected as
    /// unparsable) from the two columns. `nil` (the default) means the existing
    /// single-signed-amount-column behavior, unchanged for every profile saved before
    /// this field existed.
    public var csvCreditAmountColumnIndex: Int?
    /// Optional column holding the statement's running balance *after* each row. When set,
    /// `CSVStatementParser` fills `ParsedTransaction.balanceAfterMinorUnits` and the importer
    /// can record the account's balance from the statement (see `StatementBalanceExtractor`).
    /// `nil` (the default) means no balance column — unchanged for every existing profile.
    public var csvBalanceColumnIndex: Int?
    public var csvDateFormat: String?
    public var pdfLayoutConfig: String?
    /// Flips the sign of a single signed amount column (statements that list spending as
    /// positive). Ignored for split debit/credit columns. Default false.
    public var csvNegateAmounts: Bool

    public init(id: Int64? = nil, accountId: Int64, format: ImportFormat, csvDelimiter: String? = nil, csvDateColumnIndex: Int? = nil, csvDescriptionColumnIndex: Int? = nil, csvAmountColumnIndex: Int? = nil, csvCreditAmountColumnIndex: Int? = nil, csvBalanceColumnIndex: Int? = nil, csvDateFormat: String? = nil, pdfLayoutConfig: String? = nil, csvNegateAmounts: Bool = false) {
        self.id = id
        self.accountId = accountId
        self.format = format
        self.csvDelimiter = csvDelimiter
        self.csvDateColumnIndex = csvDateColumnIndex
        self.csvDescriptionColumnIndex = csvDescriptionColumnIndex
        self.csvAmountColumnIndex = csvAmountColumnIndex
        self.csvCreditAmountColumnIndex = csvCreditAmountColumnIndex
        self.csvBalanceColumnIndex = csvBalanceColumnIndex
        self.csvDateFormat = csvDateFormat
        self.pdfLayoutConfig = pdfLayoutConfig
        self.csvNegateAmounts = csvNegateAmounts
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

/// See `registerCategoryGroupIdMigration` for why this is a plain nullable column added
/// via `alter(table:)` rather than inside the original `create(table:)` block.
func registerImportProfileCreditColumnMigration(_ migrator: inout DatabaseMigrator) {
    migrator.registerMigration("addCreditAmountColumnIndexToImportProfile") { db in
        try db.alter(table: "importProfile") { t in
            t.add(column: "csvCreditAmountColumnIndex", .integer)
        }
    }
}

/// Plain nullable column added via `alter(table:)`, same approach as the credit-column migration.
func registerImportProfileBalanceColumnMigration(_ migrator: inout DatabaseMigrator) {
    migrator.registerMigration("addBalanceColumnIndexToImportProfile") { db in
        try db.alter(table: "importProfile") { t in
            t.add(column: "csvBalanceColumnIndex", .integer)
        }
    }
}

/// NOT NULL with a default so every profile saved before this existed keeps the old behavior.
func registerImportProfileNegateAmountsMigration(_ migrator: inout DatabaseMigrator) {
    migrator.registerMigration("addCSVNegateAmounts") { db in
        try db.alter(table: "importProfile") { t in
            t.add(column: "csvNegateAmounts", .boolean).notNull().defaults(to: false)
        }
    }
}
