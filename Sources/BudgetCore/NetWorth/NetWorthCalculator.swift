import Foundation

public struct AccountBalance {
    public let account: Account
    public let nativeBalanceMinorUnits: Int
    public let gbpBalanceMinorUnits: Int
    /// Non-nil only when a manually-entered "actual" balance has been checked
    /// against the computed running balance for an `.imported` account.
    public let reconciliationDriftMinorUnits: Int?
}

/// Sign convention: every balance is signed exactly like `Transaction.amountMinorUnits`
/// (negative = money you don't have). A credit account's balance is therefore NEGATIVE
/// when money is owed on it — "I owe £300 on my AMEX" is stored as -30000. That makes
/// `runningBalance = snapshot + sum(transactions)` correct for every account kind: a
/// £50 card charge (-5000) takes £300 owed (-30000) to £350 owed (-35000), and a
/// repayment (+) reduces what's owed. Net worth is then a plain sum of balances.
public enum NetWorthCalculator {
    /// Converts what the user types when recording a balance into the signed stored
    /// value. For credit accounts the UI asks for the (positive) "amount owed", which
    /// is negated here; typing a negative amount owed records a credit in your favour.
    public static func signedSnapshotBalance(enteredMinorUnits: Int, accountKind: AccountKind) -> Int {
        switch accountKind {
        case .credit: return -enteredMinorUnits
        case .cash, .investment: return enteredMinorUnits
        }
    }

    /// Inverse of `signedSnapshotBalance`, for showing a balance in the same terms the
    /// user enters it (amount owed for credit accounts).
    public static func enteredBalance(signedMinorUnits: Int, accountKind: AccountKind) -> Int {
        signedSnapshotBalance(enteredMinorUnits: signedMinorUnits, accountKind: accountKind)
    }

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

    /// Sum of all signed GBP balances. Credit accounts already carry a negative balance
    /// when money is owed (see the sign convention above), so they reduce net worth
    /// without any special-casing.
    public static func netWorth(balances: [AccountBalance]) -> Int {
        balances.reduce(0) { $0 + $1.gbpBalanceMinorUnits }
    }

    /// Compares a manually-entered actual balance against the computed running balance,
    /// surfacing drift instead of silently trusting either figure.
    public static func reconciliationDrift(computedNativeBalanceMinorUnits: Int, actualNativeBalanceMinorUnits: Int) -> Int {
        actualNativeBalanceMinorUnits - computedNativeBalanceMinorUnits
    }
}
