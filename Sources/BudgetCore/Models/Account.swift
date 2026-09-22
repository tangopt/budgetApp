import GRDB

public enum AccountKind: String, Codable, CaseIterable {
    case cash
    case credit
    case investment
}

public enum AccountTrackingMode: String, Codable, CaseIterable {
    case imported
    case manual
}

public struct Account: Codable, Equatable, Identifiable, FetchableRecord, MutablePersistableRecord {
    public var id: Int64?
    public var name: String
    public var currency: Currency
    public var kind: AccountKind
    public var trackingMode: AccountTrackingMode

    public init(id: Int64? = nil, name: String, currency: Currency, kind: AccountKind, trackingMode: AccountTrackingMode) {
        self.id = id
        self.name = name
        self.currency = currency
        self.kind = kind
        self.trackingMode = trackingMode
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    public static let databaseTableName = "account"
}

func registerAccountMigration(_ migrator: inout DatabaseMigrator) {
    migrator.registerMigration("createAccount") { db in
        try db.create(table: "account") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("name", .text).notNull().unique()
            t.column("currency", .text).notNull()
            t.column("kind", .text).notNull()
            t.column("trackingMode", .text).notNull()
        }
    }
}
