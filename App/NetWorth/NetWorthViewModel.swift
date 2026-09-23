// App/NetWorth/NetWorthViewModel.swift
import Foundation
import BudgetCore
import GRDB

@MainActor
final class NetWorthViewModel: ObservableObject {
    @Published var accounts: [Account] = []
    @Published var balances: [AccountBalance] = []
    @Published var netWorthGBP: Int = 0
    @Published var exchangeRate: ExchangeRateSetting = ExchangeRateSetting(eurToGbpRate: 0.87, updatedAt: Date())
    @Published var history: [(date: Date, netWorthGBP: Int)] = []

    private let dbQueue: DatabaseQueue

    init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
    }

    func load() throws {
        accounts = try dbQueue.read { db in try Account.fetchAll(db) }
        let snapshots = try dbQueue.read { db in try BalanceSnapshot.fetchAll(db) }
        let transactions = try dbQueue.read { db in try Transaction.fetchAll(db) }
        exchangeRate = try dbQueue.read { db in try ExchangeRateSetting.currentOrDefault(db: db) }
        balances = NetWorthCalculator.accountBalances(accounts: accounts, snapshots: snapshots, transactions: transactions, rate: exchangeRate)
        netWorthGBP = NetWorthCalculator.netWorth(balances: balances)
        history = computeHistory(snapshots: snapshots, transactions: transactions)
    }

    /// One net-worth data point per distinct snapshot date across all accounts,
    /// using each account's most recent snapshot at or before that date.
    private func computeHistory(snapshots: [BalanceSnapshot], transactions: [Transaction]) -> [(date: Date, netWorthGBP: Int)] {
        let distinctDates = Set(snapshots.map(\.date)).sorted()
        return distinctDates.map { asOfDate in
            let snapshotsAsOf = snapshots.filter { $0.date <= asOfDate }
            let balancesAsOf = NetWorthCalculator.accountBalances(accounts: accounts, snapshots: snapshotsAsOf, transactions: transactions.filter { $0.date <= asOfDate }, rate: exchangeRate)
            return (asOfDate, NetWorthCalculator.netWorth(balances: balancesAsOf))
        }
    }

    @Published var reconciliationWarning: String?
    @Published var errorMessage: String?

    /// `enteredMinorUnits` is the figure as the user typed it — for credit accounts
    /// that's the positive amount owed, which is converted to the signed internal
    /// representation (negative = owed) before reconciling or saving; see
    /// `NetWorthCalculator.signedSnapshotBalance`.
    ///
    /// For `.imported` accounts, compares the balance being entered against what the
    /// running balance (previous snapshot + transactions since) computes to, and
    /// surfaces a warning rather than silently accepting a figure that implies a
    /// missing or duplicate transaction. The snapshot is saved either way.
    func addSnapshot(accountId: Int64, enteredMinorUnits: Int, note: String?) throws {
        reconciliationWarning = nil
        errorMessage = nil
        guard let account = accounts.first(where: { $0.id == accountId }) else { return }
        let balanceMinorUnits = NetWorthCalculator.signedSnapshotBalance(enteredMinorUnits: enteredMinorUnits, accountKind: account.kind)
        if account.trackingMode == .imported {
            let previousSnapshot = try dbQueue.read { db in
                try BalanceSnapshot.filter(Column("accountId") == accountId).order(Column("date").desc).fetchOne(db)
            }
            let transactionsSince = try dbQueue.read { db -> [Transaction] in
                if let previousSnapshot {
                    return try Transaction.filter(Column("accountId") == accountId && Column("date") > previousSnapshot.date).fetchAll(db)
                } else {
                    return try Transaction.filter(Column("accountId") == accountId).fetchAll(db)
                }
            }
            let computed = NetWorthCalculator.runningBalance(account: account, latestSnapshot: previousSnapshot, transactionsSinceSnapshot: transactionsSince)
            let drift = NetWorthCalculator.reconciliationDrift(computedNativeBalanceMinorUnits: computed, actualNativeBalanceMinorUnits: balanceMinorUnits)
            if drift != 0 {
                reconciliationWarning = "\(account.name): entered balance differs from the computed running balance by \(Money.format(drift, currency: account.currency)) — check for a missing or duplicate transaction."
            }
        }
        var snapshot = BalanceSnapshot(accountId: accountId, date: Date(), balanceMinorUnits: balanceMinorUnits, note: note)
        try dbQueue.write { db in try snapshot.insert(db) }
        try load()
    }

    func updateExchangeRate(_ rate: Double) throws {
        var setting = ExchangeRateSetting(eurToGbpRate: rate, updatedAt: Date())
        try dbQueue.write { db in try setting.insert(db) }
        try load()
    }
}
