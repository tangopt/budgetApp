import Foundation

public struct AccountBalance {
    public let account: Account
    public let nativeBalanceMinorUnits: Int
    public let gbpBalanceMinorUnits: Int
    /// Non-nil only when a manually-entered "actual" balance has been checked
    /// against the computed running balance for an `.imported` account.
    public let reconciliationDriftMinorUnits: Int?
}

public enum NetWorthCalculator {
    public static func runningBalance(account: Account, latestSnapshot: BalanceSnapshot?, transactionsSinceSnapshot: [Transaction]) -> Int {
        let base = latestSnapshot?.balanceMinorUnits ?? 0
        switch account.trackingMode {
        case .manual:
            return base
        case .imported:
            return base + transactionsSinceSnapshot.reduce(0) { $0 + $1.amountMinorUnits }
        }
    }

    public static func accountBalances(accounts: [Account], snapshots: [BalanceSnapshot], transactions: [Transaction], rate: ExchangeRateSetting) -> [AccountBalance] {
        accounts.map { account in
            let accountSnapshots = snapshots.filter { $0.accountId == account.id }.sorted { $0.date > $1.date }
            let latestSnapshot = accountSnapshots.first
            let transactionsSince = transactions.filter { $0.accountId == account.id && (latestSnapshot == nil || $0.date > latestSnapshot!.date) }
            let native = runningBalance(account: account, latestSnapshot: latestSnapshot, transactionsSinceSnapshot: transactionsSince)
            let gbp: Int
            switch account.currency {
            case .gbp: gbp = native
            case .eur: gbp = Int((Double(native) * rate.eurToGbpRate).rounded())
            }
            return AccountBalance(account: account, nativeBalanceMinorUnits: native, gbpBalanceMinorUnits: gbp, reconciliationDriftMinorUnits: nil)
        }
    }

    /// Cash and investment balances count as assets; credit balances count as liabilities.
    public static func netWorth(balances: [AccountBalance]) -> Int {
        balances.reduce(0) { total, balance in
            switch balance.account.kind {
            case .cash, .investment: return total + balance.gbpBalanceMinorUnits
            case .credit: return total - balance.gbpBalanceMinorUnits
            }
        }
    }

    /// Compares a manually-entered actual balance against the computed running balance,
    /// surfacing drift instead of silently trusting either figure.
    public static func reconciliationDrift(computedNativeBalanceMinorUnits: Int, actualNativeBalanceMinorUnits: Int) -> Int {
        actualNativeBalanceMinorUnits - computedNativeBalanceMinorUnits
    }
}
