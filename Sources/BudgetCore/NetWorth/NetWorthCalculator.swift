import Foundation

public struct AccountBalance {
    public let account: Account
    public let nativeBalanceMinorUnits: Int
    public let gbpBalanceMinorUnits: Int
    /// Non-nil only when a manually-entered "actual" balance has been checked
    /// against the computed running balance for an `.imported` account.
    public let reconciliationDriftMinorUnits: Int?
}

public struct MonthlyAccountBalance {
    public let account: Account
    public let nativeBalanceMinorUnits: Int
    public let gbpBalanceMinorUnits: Int
    /// True when nothing dated within the requested month determined this balance — no
    /// snapshot, and (for `.imported` accounts) no transaction either — so the figure shown
    /// is carried forward unchanged from an earlier month.
    public let isCarriedForward: Bool
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

    /// Newest-first order for picking an account's latest snapshot: by date, then by id
    /// (several snapshots can share a date — the most recently inserted one wins).
    public static func isNewer(_ lhs: BalanceSnapshot, _ rhs: BalanceSnapshot) -> Bool {
        lhs.date != rhs.date ? lhs.date > rhs.date : (lhs.id ?? 0) > (rhs.id ?? 0)
    }

    public static func accountBalances(accounts: [Account], snapshots: [BalanceSnapshot], transactions: [Transaction], rate: ExchangeRateSetting) -> [AccountBalance] {
        accounts.map { account in
            let accountSnapshots = snapshots.filter { $0.accountId == account.id }.sorted(by: isNewer)
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

    /// The account's balance as of `monthEnd`: the latest snapshot at or before it (plus,
    /// for `.imported` accounts, transactions between that snapshot and `monthEnd`), the same
    /// carry-forward `runningBalance` already does for "now" — just parameterized to an
    /// arbitrary month instead of hardcoded to the latest snapshot overall. Returns `nil` when
    /// there's no snapshot at or before `monthEnd` at all (the account has no data yet).
    public static func monthlyBalance(account: Account, snapshots: [BalanceSnapshot], transactions: [Transaction], rate: ExchangeRateSetting, monthStart: Date, monthEnd: Date) -> MonthlyAccountBalance? {
        let accountSnapshots = snapshots.filter { $0.accountId == account.id && $0.date <= monthEnd }.sorted(by: isNewer)
        guard let latestSnapshot = accountSnapshots.first else { return nil }
        let transactionsSince = transactions.filter { $0.accountId == account.id && $0.date > latestSnapshot.date && $0.date <= monthEnd }
        let native = runningBalance(account: account, latestSnapshot: latestSnapshot, transactionsSinceSnapshot: transactionsSince)
        let gbp: Int
        switch account.currency {
        case .gbp: gbp = native
        case .eur: gbp = Int((Double(native) * rate.eurToGbpRate).rounded())
        }
        let latestActivityDate = transactionsSince.map(\.date).max() ?? latestSnapshot.date
        let isCarriedForward = latestActivityDate < monthStart
        return MonthlyAccountBalance(account: account, nativeBalanceMinorUnits: native, gbpBalanceMinorUnits: gbp, isCarriedForward: isCarriedForward)
    }

    /// Total GBP net worth as of the end of the given calendar month: the sum of every
    /// account's `monthlyBalance` (latest snapshot at or before the month end, plus
    /// transactions after it for `.imported` accounts). `nil` when no account has any data
    /// at or before that month — distinguishes "no data yet" from "genuinely zero".
    /// `BudgetGridViewModel.netWorthTotal` and `ForecastViewModel.realNetWorth` delegate here.
    public static func monthEndNetWorth(accounts: [Account], snapshots: [BalanceSnapshot], transactions: [Transaction], rate: ExchangeRateSetting, year: Int, month: Int) -> Int? {
        let range = MonthRange.of(year: year, month: month)
        var total = 0
        var hasData = false
        for account in accounts {
            if let balance = monthlyBalance(account: account, snapshots: snapshots, transactions: transactions, rate: rate, monthStart: range.start, monthEnd: range.end) {
                total += balance.gbpBalanceMinorUnits
                hasData = true
            }
        }
        return hasData ? total : nil
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
