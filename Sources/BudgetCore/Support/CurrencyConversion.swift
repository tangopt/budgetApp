import Foundation
import GRDB

/// Turns transactions in non-GBP accounts into their GBP equivalent at the stored rate
/// (`ExchangeRateSetting`), for every figure that sums transactions across accounts: the
/// Budget grid's actuals and totals, Dashboard flows, Categories' averages and distribution,
/// scenario actuals and plan status. Applied once where those inputs are loaded, so the
/// calculators stay currency-agnostic. Balances and net worth keep native transactions
/// (`NetWorthCalculator` converts the balance), and transaction lists show native amounts.
public struct CurrencyConversion: Equatable, Sendable {
    /// The non-GBP accounts' currencies by id; an account not listed is GBP.
    public let currencyByAccount: [Int64: Currency]
    public let eurToGbpRate: Double

    public init(accounts: [Account], rate: ExchangeRateSetting) {
        self.currencyByAccount = Dictionary(accounts.compactMap { account in
            account.id.flatMap { account.currency == .gbp ? nil : ($0, account.currency) }
        }, uniquingKeysWith: { first, _ in first })
        self.eurToGbpRate = rate.eurToGbpRate
    }

    /// No conversion: every account counts as GBP.
    public static let none = CurrencyConversion(currencyByAccount: [:], eurToGbpRate: 1)

    private init(currencyByAccount: [Int64: Currency], eurToGbpRate: Double) {
        self.currencyByAccount = currencyByAccount
        self.eurToGbpRate = eurToGbpRate
    }

    /// The accounts and the stored rate, read from the database.
    public static func current(db: Database) throws -> CurrencyConversion {
        CurrencyConversion(accounts: try Account.fetchAll(db), rate: try ExchangeRateSetting.currentOrDefault(db: db))
    }

    /// The currency of the account `accountId` (GBP when unknown).
    public func currency(ofAccount accountId: Int64) -> Currency {
        currencyByAccount[accountId] ?? .gbp
    }

    /// `amountMinorUnits` of a transaction in `accountId`, in GBP minor units.
    public func gbp(_ amountMinorUnits: Int, accountId: Int64) -> Int {
        switch currency(ofAccount: accountId) {
        case .gbp: return amountMinorUnits
        case .eur: return Int((Double(amountMinorUnits) * eurToGbpRate).rounded())
        }
    }

    /// The transaction's amount in GBP minor units.
    public func gbp(_ transaction: Transaction) -> Int {
        gbp(transaction.amountMinorUnits, accountId: transaction.accountId)
    }

    /// `transactions` with each non-GBP one's amount replaced by its GBP equivalent (everything
    /// else, id included, unchanged). Returns the input as is when no account is non-GBP.
    public func toGBP(_ transactions: [Transaction]) -> [Transaction] {
        guard !currencyByAccount.isEmpty else { return transactions }
        return transactions.map { transaction in
            guard currencyByAccount[transaction.accountId] != nil else { return transaction }
            var converted = transaction
            converted.amountMinorUnits = gbp(transaction)
            return converted
        }
    }
}
