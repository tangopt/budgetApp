import Foundation

public struct AccountBalance {
    public let account: Account
    public let nativeBalanceMinorUnits: Int
    public let gbpBalanceMinorUnits: Int
}

public struct MonthlyAccountBalance {
    public let account: Account
    public let nativeBalanceMinorUnits: Int
    public let gbpBalanceMinorUnits: Int
    /// True when nothing dated within the requested month determined this balance — no
    /// snapshot and no transaction — so the figure shown is carried forward unchanged from
    /// an earlier month.
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

    /// `snapshot + sum(transactions)`: every account, whatever its (legacy) tracking mode,
    /// counts the transactions after its latest snapshot.
    public static func runningBalance(latestSnapshot: BalanceSnapshot?, transactionsSinceSnapshot: [Transaction]) -> Int {
        (latestSnapshot?.balanceMinorUnits ?? 0) + transactionsSinceSnapshot.reduce(0) { $0 + $1.amountMinorUnits }
    }

    /// Newest-first order for picking an account's latest snapshot: by date, then by id
    /// (several snapshots can share a date — the most recently inserted one wins).
    public static func isNewer(_ lhs: BalanceSnapshot, _ rhs: BalanceSnapshot) -> Bool {
        lhs.date != rhs.date ? lhs.date > rhs.date : (lhs.id ?? 0) > (rhs.id ?? 0)
    }

    /// An account's signed native balance at `date` (nil = no upper bound) and the date of the
    /// latest thing that set it (spec 2026-10-14 §1). The balance rule, for every account: the
    /// latest snapshot at or before `date` (the opening balance; legacy data may hold later
    /// ones) plus every transaction — imported, manual or adjustment — dated after it up to
    /// `date`. An account with no snapshot at all starts from zero, so all its transactions
    /// up to `date` count. Nil when there's nothing to go on: `date` precedes the account's
    /// first snapshot, or it has no snapshot and no transaction up to `date`.
    public static func balance(accountId: Int64?, at date: Date?, snapshots: [BalanceSnapshot], transactions: [Transaction]) -> (native: Int, latestActivity: Date)? {
        let accountSnapshots = snapshots.filter { $0.accountId == accountId }
        let latestSnapshot = accountSnapshots.filter { date == nil || $0.date <= date! }.sorted(by: isNewer).first
        if latestSnapshot == nil && !accountSnapshots.isEmpty { return nil }
        let since = transactions.filter {
            $0.accountId == accountId && (latestSnapshot == nil || $0.date > latestSnapshot!.date) && (date == nil || $0.date <= date!)
        }
        guard let latestActivity = ([latestSnapshot?.date].compactMap { $0 } + since.map(\.date)).max() else { return nil }
        return (runningBalance(latestSnapshot: latestSnapshot, transactionsSinceSnapshot: since), latestActivity)
    }

    static func gbp(_ native: Int, currency: Currency, rate: ExchangeRateSetting) -> Int {
        gbp(native, currency: currency, eurToGbpRate: rate.eurToGbpRate)
    }

    /// The one native → GBP formula: balances here, budget figures through `CurrencyConversion`.
    static func gbp(_ native: Int, currency: Currency, eurToGbpRate: Double) -> Int {
        switch currency {
        case .gbp: return native
        case .eur: return Int((Double(native) * eurToGbpRate).rounded())
        }
    }

    /// Every account's balance now (`balance` with no upper bound; 0 for an account with nothing).
    public static func accountBalances(accounts: [Account], snapshots: [BalanceSnapshot], transactions: [Transaction], rate: ExchangeRateSetting) -> [AccountBalance] {
        accounts.map { account in
            let native = balance(accountId: account.id, at: nil, snapshots: snapshots, transactions: transactions)?.native ?? 0
            return AccountBalance(account: account, nativeBalanceMinorUnits: native, gbpBalanceMinorUnits: gbp(native, currency: account.currency, rate: rate))
        }
    }

    /// The account's balance as of `monthEnd` (`balance`), carried forward when nothing in
    /// the month set it. Nil when the account has no data at or before `monthEnd`.
    public static func monthlyBalance(account: Account, snapshots: [BalanceSnapshot], transactions: [Transaction], rate: ExchangeRateSetting, monthStart: Date, monthEnd: Date) -> MonthlyAccountBalance? {
        guard let result = balance(accountId: account.id, at: monthEnd, snapshots: snapshots, transactions: transactions) else { return nil }
        return MonthlyAccountBalance(account: account, nativeBalanceMinorUnits: result.native, gbpBalanceMinorUnits: gbp(result.native, currency: account.currency, rate: rate),
                                     isCarriedForward: result.latestActivity < monthStart)
    }

    /// Total GBP net worth as of the end of the given calendar month: the sum of every
    /// counted account's (`Account.includeInNetWorth`) `monthlyBalance` (latest snapshot at or
    /// before the month end, plus transactions after it). `nil` when no counted account has any
    /// data at or before that month — distinguishes "no data yet" from "genuinely zero".
    /// `BudgetGridViewModel.netWorthTotal` delegates here.
    public static func monthEndNetWorth(accounts: [Account], snapshots: [BalanceSnapshot], transactions: [Transaction], rate: ExchangeRateSetting, year: Int, month: Int) -> Int? {
        let range = MonthRange.of(year: year, month: month)
        var total = 0
        var hasData = false
        for account in accounts where account.includeInNetWorth {
            if let balance = monthlyBalance(account: account, snapshots: snapshots, transactions: transactions, rate: rate, monthStart: range.start, monthEnd: range.end) {
                total += balance.gbpBalanceMinorUnits
                hasData = true
            }
        }
        return hasData ? total : nil
    }

    /// Sum of the signed GBP balances of the accounts that count toward net worth
    /// (`Account.includeInNetWorth`). Credit accounts already carry a negative balance when
    /// money is owed (see the sign convention above), so they reduce net worth without any
    /// special-casing.
    public static func netWorth(balances: [AccountBalance]) -> Int {
        balances.reduce(0) { $1.account.includeInNetWorth ? $0 + $1.gbpBalanceMinorUnits : $0 }
    }
}
