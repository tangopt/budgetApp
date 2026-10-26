import Foundation
import GRDB

/// An account's balance at the end of a pay month, or now (`payMonth == "current"`): what the household
/// zone holds for an account at Balance only or Category totals (sharing spec §3). Rebuilt by the owner's
/// devices; synced.
public struct AccountBalancePoint: Codable, Equatable, Identifiable, FetchableRecord, MutablePersistableRecord, Sendable {
    /// The `payMonth` of the latest balance.
    public static let currentPayMonth = "current"

    public var id: Int64?
    public var accountId: Int64
    /// "YYYY-MM", or `currentPayMonth`.
    public var payMonth: String
    public var date: Date
    public var balanceMinorUnits: Int

    public init(id: Int64? = nil, accountId: Int64, payMonth: String, date: Date, balanceMinorUnits: Int) {
        self.id = id
        self.accountId = accountId
        self.payMonth = payMonth
        self.date = date
        self.balanceMinorUnits = balanceMinorUnits
    }

    public static let databaseTableName = "accountBalancePoint"

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

/// An account's total and count of transactions in one category (nil: uncategorised) and pay month: what
/// the household zone holds for an account at Category totals (sharing spec §3). Rebuilt by the owner's
/// devices; synced.
public struct AccountSummaryMonth: Codable, Equatable, Identifiable, FetchableRecord, MutablePersistableRecord, Sendable {
    public var id: Int64?
    public var accountId: Int64
    /// "YYYY-MM".
    public var payMonth: String
    public var categoryId: Int64?
    /// In the account's currency.
    public var amountMinorUnits: Int
    /// The same total in GBP, the household's reporting currency: each transaction converted and rounded as the
    /// owner's budget converts it (`CurrencyConversion`), corrections in their own leg's currency. Equal to
    /// `amountMinorUnits` for a GBP account without corrections from other currencies.
    public var gbpAmountMinorUnits: Int
    public var transactionCount: Int

    public init(id: Int64? = nil, accountId: Int64, payMonth: String, categoryId: Int64?, amountMinorUnits: Int, gbpAmountMinorUnits: Int? = nil,
                transactionCount: Int) {
        self.id = id
        self.accountId = accountId
        self.payMonth = payMonth
        self.categoryId = categoryId
        self.amountMinorUnits = amountMinorUnits
        self.gbpAmountMinorUnits = gbpAmountMinorUnits ?? amountMinorUnits
        self.transactionCount = transactionCount
    }

    public static let databaseTableName = "accountSummaryMonth"

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
