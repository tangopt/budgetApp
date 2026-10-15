import Foundation
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

/// Which bank-detail fields an account uses (spec 2026-10-15 §2).
public enum BankRegion: String, Codable, CaseIterable, Sendable {
    case uk, us, europe, other

    public var title: String {
        switch self {
        case .uk: return "UK"
        case .us: return "US"
        case .europe: return "Europe"
        case .other: return "Other"
        }
    }

    /// The region-specific fields, in display order (bank name and BIC apply to every region).
    public var fields: [BankDetailField] {
        switch self {
        case .uk: return [.sortCode, .accountNumber, .iban]
        case .us: return [.routingNumber, .accountNumber]
        case .europe: return [.iban]
        case .other: return [.accountNumber]
        }
    }

    public static func forCurrency(_ currency: Currency) -> BankRegion {
        switch currency {
        case .gbp: return .uk
        case .eur: return .europe
        }
    }
}

public enum BankDetailField: String, CaseIterable, Hashable, Sendable {
    case bankName, sortCode, routingNumber, accountNumber, iban, bic
}

public struct Account: Codable, Equatable, Identifiable, FetchableRecord, MutablePersistableRecord, Sendable {
    public var id: Int64?
    public var name: String
    public var currency: Currency
    public var kind: AccountKind
    /// Legacy (spec 2026-10-14 §1): stored for compatibility, ignored by every calculation —
    /// every account's balance is its opening balance plus its transactions.
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
    /// The stored bank region; nil derives one (`effectiveBankRegion`).
    public var bankRegion: BankRegion?
    /// Optional, trimmed free text.
    public var bankName: String?
    /// US ABA routing number: 9 digits, no separators.
    public var routingNumber: String?
    /// BIC/SWIFT: uppercase, 8 or 11 characters.
    public var bic: String?
    /// The user's drag-and-drop position (`AccountOrdering`); nil until the first reorder.
    /// Ordered accounts list first, ascending; the rest follow alphabetically.
    public var sortOrder: Int?
    /// The last statement import's unresolved closing-balance difference (spec 2026-10-14 §2):
    /// statement − computed, signed like a transaction amount; nil when there's none.
    /// Set and cleared by `StatementCheck` (Finish import) and cleared by Update balance.
    public var statementMismatchMinorUnits: Int?
    /// The statement's closing date for `statementMismatchMinorUnits`.
    public var statementMismatchDate: Date?
    /// The statement's closing balance for that mismatch, so every later Finish import can
    /// re-check it (an import filling a gap before it clears it).
    public var statementMismatchClosingMinorUnits: Int?
    /// The closing date of the latest-dated statement checked: an earlier statement never
    /// overrides what a later one recorded.
    public var statementLastCheckedDate: Date?
    /// The latest day the user (Update balance, even with nothing to adjust) or the balance
    /// conversion confirmed the computed balance — counts as activity for staleness and "as of"
    /// (`BalanceStaleness.lastActivity`) though nothing else records it. Nil when never.
    public var balanceConfirmedAt: Date?
    /// The main account (spec 2026-10-15 account-forecast §1): planned items with no account of
    /// their own and no category history go to it. At most one account is main
    /// (`AccountEditing.setMain`, enforced by a partial unique index).
    public var isMain: Bool

    public init(id: Int64? = nil, name: String, currency: Currency, kind: AccountKind, trackingMode: AccountTrackingMode,
                alias: String? = nil, sortCode: String? = nil, accountNumber: String? = nil, iban: String? = nil, sortOrder: Int? = nil,
                statementMismatchMinorUnits: Int? = nil, statementMismatchDate: Date? = nil,
                statementMismatchClosingMinorUnits: Int? = nil, statementLastCheckedDate: Date? = nil, balanceConfirmedAt: Date? = nil,
                bankRegion: BankRegion? = nil, bankName: String? = nil, routingNumber: String? = nil, bic: String? = nil, isMain: Bool = false) {
        self.id = id
        self.name = name
        self.currency = currency
        self.kind = kind
        self.trackingMode = trackingMode
        self.alias = alias
        self.sortCode = sortCode
        self.accountNumber = accountNumber
        self.iban = iban
        self.sortOrder = sortOrder
        self.statementMismatchMinorUnits = statementMismatchMinorUnits
        self.statementMismatchDate = statementMismatchDate
        self.statementMismatchClosingMinorUnits = statementMismatchClosingMinorUnits
        self.statementLastCheckedDate = statementLastCheckedDate
        self.balanceConfirmedAt = balanceConfirmedAt
        self.bankRegion = bankRegion
        self.bankName = bankName
        self.routingNumber = routingNumber
        self.bic = bic
        self.isMain = isMain
    }

    /// The stored region; else derived from the details set (sort code → UK, IBAN → Europe,
    /// routing number → US), else from the currency.
    public var effectiveBankRegion: BankRegion {
        if let bankRegion { return bankRegion }
        if sortCode != nil { return .uk }
        if iban != nil { return .europe }
        if routingNumber != nil { return .us }
        return .forCurrency(currency)
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

func registerAccountSortOrderMigration(_ migrator: inout DatabaseMigrator) {
    migrator.registerMigration("addAccountSortOrder") { db in
        try db.alter(table: "account") { t in
            t.add(column: "sortOrder", .integer)
        }
    }
}

func registerAccountStatementMismatchMigration(_ migrator: inout DatabaseMigrator) {
    migrator.registerMigration("addAccountStatementMismatch") { db in
        try db.alter(table: "account") { t in
            t.add(column: "statementMismatchMinorUnits", .integer)
            t.add(column: "statementMismatchDate", .datetime)
            t.add(column: "statementMismatchClosingMinorUnits", .integer)
            t.add(column: "statementLastCheckedDate", .datetime)
        }
    }
}

func registerAccountBalanceConfirmedAtMigration(_ migrator: inout DatabaseMigrator) {
    migrator.registerMigration("addAccountBalanceConfirmedAt") { db in
        try db.alter(table: "account") { t in
            t.add(column: "balanceConfirmedAt", .datetime)
        }
    }
}

func registerAccountBankRegionMigration(_ migrator: inout DatabaseMigrator) {
    migrator.registerMigration("addAccountBankRegion") { db in
        try db.alter(table: "account") { t in
            t.add(column: "bankRegion", .text)
            t.add(column: "bankName", .text)
            t.add(column: "routingNumber", .text)
            t.add(column: "bic", .text)
        }
    }
}

func registerAccountIsMainMigration(_ migrator: inout DatabaseMigrator) {
    migrator.registerMigration("addAccountIsMain") { db in
        try db.alter(table: "account") { t in
            t.add(column: "isMain", .boolean).notNull().defaults(to: false)
        }
        try db.execute(sql: "CREATE UNIQUE INDEX account_single_main ON account(isMain) WHERE isMain = 1")
    }
}

extension Sequence where Element == Account {
    /// The main account's id (`Account.isMain`), nil when none is set.
    public var mainAccountId: Int64? {
        first(where: \.isMain)?.id
    }

    /// The accounts in `Account.displayNameOrder`.
    public func sortedByDisplayName() -> [Account] {
        sorted(by: Account.displayNameOrder)
    }

    /// The accounts in the order the UI lists them (`AccountOrdering`).
    public func sortedForDisplay() -> [Account] {
        AccountOrdering.sorted(Array(self))
    }
}
