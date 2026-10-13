import GRDB

public enum AccountKind: String, Codable, CaseIterable, Sendable {
    case cash
    case credit
    case investment
}

public enum AccountTrackingMode: String, Codable, CaseIterable, Sendable {
    case imported
    case manual
}

public struct Account: Codable, Equatable, Identifiable, FetchableRecord, MutablePersistableRecord, Sendable {
    public var id: Int64?
    public var name: String
    public var currency: Currency
    public var kind: AccountKind
    public var trackingMode: AccountTrackingMode
    /// Short name shown instead of `name` across the app (`displayName`). Normalised on save
    /// (`AccountDetailsFormat`): trimmed, empty → nil.
    public var alias: String?
    /// 6 digits, no separators (shown "30-00-00").
    public var sortCode: String?
    /// Digits only, 6–8 of them.
    public var accountNumber: String?
    /// Uppercase, no spaces (shown in groups of 4).
    public var iban: String?

    public init(id: Int64? = nil, name: String, currency: Currency, kind: AccountKind, trackingMode: AccountTrackingMode,
                alias: String? = nil, sortCode: String? = nil, accountNumber: String? = nil, iban: String? = nil) {
        self.id = id
        self.name = name
        self.currency = currency
        self.kind = kind
        self.trackingMode = trackingMode
        self.alias = alias
        self.sortCode = sortCode
        self.accountNumber = accountNumber
        self.iban = iban
    }

    /// What the UI calls the account: the alias when set, otherwise the full name. `name`
    /// stays the identity (uniqueness).
    public var displayName: String {
        AccountDetailsFormat.normalizedAlias(alias ?? "") ?? name
    }

    /// Orders accounts as the UI lists them: by `displayName`, case-insensitively and with
    /// numbers compared numerically ("Card 9" before "Card 10"); `name` breaks ties.
    public static func displayNameOrder(_ lhs: Account, _ rhs: Account) -> Bool {
        switch lhs.displayName.localizedStandardCompare(rhs.displayName) {
        case .orderedAscending: return true
        case .orderedDescending: return false
        case .orderedSame: return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
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

func registerAccountDetailsMigration(_ migrator: inout DatabaseMigrator) {
    migrator.registerMigration("addAccountAliasAndDetails") { db in
        try db.alter(table: "account") { t in
            t.add(column: "alias", .text)
            t.add(column: "sortCode", .text)
            t.add(column: "accountNumber", .text)
            t.add(column: "iban", .text)
        }
    }
}

extension Sequence where Element == Account {
    /// The accounts in `Account.displayNameOrder`.
    public func sortedByDisplayName() -> [Account] {
        sorted(by: Account.displayNameOrder)
    }
}
