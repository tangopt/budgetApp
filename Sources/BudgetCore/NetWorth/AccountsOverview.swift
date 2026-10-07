import Foundation

/// The one stale-balance rule, shared by the Accounts screen and the Dashboard's
/// "needs attention" list. `.imported` accounts are never stale (transactions keep them
/// current); others are stale with no snapshot, or when the latest is more than
/// `thresholdDays` before the start of `today` (UTC).
public enum BalanceStaleness {
    public static let thresholdDays = 45

    public static func isStale(account: Account, latestSnapshot: Date?, today: Date) -> Bool {
        guard account.trackingMode != .imported else { return false }
        guard let latestSnapshot else { return true }
        let calendar = MonthRange.calendar
        let startOfToday = calendar.startOfDay(for: today)
        let threshold = calendar.date(byAdding: .day, value: -thresholdDays, to: startOfToday)!
        return latestSnapshot < threshold
    }
}

public struct AccountRow: Equatable, Identifiable {
    public let account: Account
    public let nativeBalanceMinorUnits: Int
    public let gbpBalanceMinorUnits: Int
    /// Latest snapshot; for `.imported` accounts, max(latest snapshot, latest transaction).
    public let lastUpdated: Date?
    public let isStale: Bool
    public var id: Int64 { account.id! }
}

public struct AccountGroup: Equatable, Identifiable {
    public let kind: AccountKind
    public let subtotalGBP: Int
    /// By GBP balance descending, then name.
    public let rows: [AccountRow]
    public var id: String { kind.rawValue }
}

public struct AccountsOverview: Equatable {
    public let netWorthGBP: Int
    public let asOf: Date?
    /// Net worth minus the previous calendar month's month-end net worth; nil if unknown.
    public let changeVsPreviousMonthGBP: Int?
    /// Cash, investment, credit; empty groups omitted.
    public let groups: [AccountGroup]
    public let staleCount: Int
    /// Oldest latest-snapshot among stale accounts that have one.
    public let oldestStaleDate: Date?

    public static func make(accounts: [Account], snapshots: [BalanceSnapshot], transactions: [Transaction], rate: ExchangeRateSetting, today: Date) -> AccountsOverview {
        let balances = NetWorthCalculator.accountBalances(accounts: accounts, snapshots: snapshots, transactions: transactions, rate: rate)
        var staleCount = 0
        var oldestStale: Date?
        var rowsByKind: [AccountKind: [AccountRow]] = [:]
        for balance in balances {
            let account = balance.account
            guard account.id != nil else { continue }
            let latestSnapshot = snapshots.filter { $0.accountId == account.id }.map(\.date).max()
            let stale = BalanceStaleness.isStale(account: account, latestSnapshot: latestSnapshot, today: today)
            if stale {
                staleCount += 1
                if let latestSnapshot { oldestStale = oldestStale.map { min($0, latestSnapshot) } ?? latestSnapshot }
            }
            var lastUpdated = latestSnapshot
            if account.trackingMode == .imported, let latestTransaction = transactions.filter({ $0.accountId == account.id }).map(\.date).max() {
                lastUpdated = lastUpdated.map { max($0, latestTransaction) } ?? latestTransaction
            }
            rowsByKind[account.kind, default: []].append(AccountRow(account: account, nativeBalanceMinorUnits: balance.nativeBalanceMinorUnits, gbpBalanceMinorUnits: balance.gbpBalanceMinorUnits, lastUpdated: lastUpdated, isStale: stale))
        }
        let groups: [AccountGroup] = [AccountKind.cash, .investment, .credit].compactMap { kind in
            guard let rows = rowsByKind[kind], !rows.isEmpty else { return nil }
            let sorted = rows.sorted {
                $0.gbpBalanceMinorUnits != $1.gbpBalanceMinorUnits ? $0.gbpBalanceMinorUnits > $1.gbpBalanceMinorUnits : $0.account.name < $1.account.name
            }
            return AccountGroup(kind: kind, subtotalGBP: sorted.reduce(0) { $0 + $1.gbpBalanceMinorUnits }, rows: sorted)
        }
        let netWorth = NetWorthCalculator.netWorth(balances: balances)

        let current = MonthRange.components(of: today)
        let previous = current.month == 1 ? (year: current.year - 1, month: 12) : (year: current.year, month: current.month - 1)
        let previousNetWorth = NetWorthCalculator.monthEndNetWorth(accounts: accounts, snapshots: snapshots, transactions: transactions, rate: rate, year: previous.year, month: previous.month)

        return AccountsOverview(
            netWorthGBP: netWorth,
            asOf: snapshots.map(\.date).max(),
            changeVsPreviousMonthGBP: previousNetWorth.map { netWorth - $0 },
            groups: groups,
            staleCount: staleCount,
            oldestStaleDate: oldestStale
        )
    }
}
