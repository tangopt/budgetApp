import Foundation

/// The one stale-balance rule, shared by the Accounts screen and the Dashboard's
/// "needs attention" list. Balances come from transactions (spec 2026-10-14 §1), so an
/// account fed by statement imports stays current through them (the import freshness card
/// covers it) — except an investment account, whose value moves without transactions.
/// Investment accounts and accounts never imported into are stale with no activity at all,
/// or when their last activity (latest snapshot or transaction, adjustments included) is more
/// than `thresholdDays` before the start of `today` (UTC).
public enum BalanceStaleness {
    public static let thresholdDays = 45

    /// Whether the rule applies to the account: investments, and accounts with no imported
    /// (non-manual) transaction. Another person's account read through its summaries
    /// (`SharedActuals.isSummary` rows or snapshots) counts as imported: its owner keeps it.
    public static func needsUpdates(account: Account, transactions: [Transaction], snapshots: [BalanceSnapshot] = []) -> Bool {
        account.kind == .investment
            || !(transactions.contains { $0.accountId == account.id && (!$0.isManual || SharedActuals.isSummary($0)) }
                 || snapshots.contains { $0.accountId == account.id && SharedActuals.isSummary($0) })
    }

    /// The account's last activity: its latest snapshot, transaction dated up to `today`'s day,
    /// or balance confirmation (`Account.balanceConfirmedAt`, passed as `confirmedAt`).
    public static func lastActivity(accountId: Int64?, snapshots: [BalanceSnapshot], transactions: [Transaction], today: Date, confirmedAt: Date? = nil) -> Date? {
        let calendar = MonthRange.calendar
        let endOfToday = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: today))!
        let snapshot = snapshots.lazy.filter { $0.accountId == accountId }.map(\.date).max()
        let transaction = transactions.lazy.filter { $0.accountId == accountId && $0.date < endOfToday }.map(\.date).max()
        return [snapshot, transaction, confirmedAt].compactMap { $0 }.max()
    }

    /// `lastActivity` for `account`, its `balanceConfirmedAt` included.
    public static func lastActivity(account: Account, snapshots: [BalanceSnapshot], transactions: [Transaction], today: Date) -> Date? {
        lastActivity(accountId: account.id, snapshots: snapshots, transactions: transactions, today: today, confirmedAt: account.balanceConfirmedAt)
    }

    public static func isStale(account: Account, snapshots: [BalanceSnapshot], transactions: [Transaction], today: Date) -> Bool {
        guard needsUpdates(account: account, transactions: transactions, snapshots: snapshots) else { return false }
        guard let last = lastActivity(account: account, snapshots: snapshots, transactions: transactions, today: today) else { return true }
        let calendar = MonthRange.calendar
        let threshold = calendar.date(byAdding: .day, value: -thresholdDays, to: calendar.startOfDay(for: today))!
        return last < threshold
    }
}

public struct AccountRow: Equatable, Identifiable, Sendable {
    public let account: Account
    public let nativeBalanceMinorUnits: Int
    public let gbpBalanceMinorUnits: Int
    /// The account's last activity (`BalanceStaleness.lastActivity`): latest snapshot or transaction.
    public let lastUpdated: Date?
    public let isStale: Bool
    public var id: Int64 { account.id! }
}

public struct AccountGroup: Equatable, Identifiable, Sendable {
    public let kind: AccountKind
    /// The rows that count toward net worth (`Account.includeInNetWorth`), summed.
    public let subtotalGBP: Int
    /// In `AccountOrdering` order.
    public let rows: [AccountRow]
    public var id: String { kind.rawValue }
}

public struct AccountsOverview: Equatable, Sendable {
    /// The accounts that count toward net worth (`Account.includeInNetWorth`); the groups still
    /// list the others, their balances left out of the subtotals.
    public let netWorthGBP: Int
    public let asOf: Date?
    /// Net worth minus the previous calendar month's month-end net worth; nil if unknown.
    public let changeVsPreviousMonthGBP: Int?
    /// Cash, investment, credit; empty groups omitted.
    public let groups: [AccountGroup]
    public let staleCount: Int
    /// Oldest last activity among stale accounts that have one.
    public let oldestStaleDate: Date?

    public static func make(accounts: [Account], snapshots: [BalanceSnapshot], transactions: [Transaction], rate: ExchangeRateSetting, today: Date) -> AccountsOverview {
        let balances = NetWorthCalculator.accountBalances(accounts: accounts, snapshots: snapshots, transactions: transactions, rate: rate)
        var staleCount = 0
        var oldestStale: Date?
        var rowsByKind: [AccountKind: [AccountRow]] = [:]
        for balance in balances {
            let account = balance.account
            guard account.id != nil else { continue }
            let lastUpdated = BalanceStaleness.lastActivity(account: account, snapshots: snapshots, transactions: transactions, today: today)
            // An account left out of net worth is never flagged stale.
            let stale = account.includeInNetWorth && BalanceStaleness.isStale(account: account, snapshots: snapshots, transactions: transactions, today: today)
            if stale {
                staleCount += 1
                if let lastUpdated { oldestStale = oldestStale.map { min($0, lastUpdated) } ?? lastUpdated }
            }
            rowsByKind[account.kind, default: []].append(AccountRow(account: account, nativeBalanceMinorUnits: balance.nativeBalanceMinorUnits, gbpBalanceMinorUnits: balance.gbpBalanceMinorUnits, lastUpdated: lastUpdated, isStale: stale))
        }
        let groups: [AccountGroup] = [AccountKind.cash, .investment, .credit].compactMap { kind in
            guard let rows = rowsByKind[kind], !rows.isEmpty else { return nil }
            let sorted = rows.sorted { AccountOrdering.areInOrder($0.account, $1.account) }
            return AccountGroup(kind: kind, subtotalGBP: sorted.reduce(0) { $1.account.includeInNetWorth ? $0 + $1.gbpBalanceMinorUnits : $0 }, rows: sorted)
        }
        let netWorth = NetWorthCalculator.netWorth(balances: balances)

        let current = MonthRange.components(of: today)
        let previous = current.month == 1 ? (year: current.year - 1, month: 12) : (year: current.year, month: current.month - 1)
        let previousNetWorth = NetWorthCalculator.monthEndNetWorth(accounts: accounts, snapshots: snapshots, transactions: transactions, rate: rate, year: previous.year, month: previous.month)

        return AccountsOverview(
            netWorthGBP: netWorth,
            asOf: groups.flatMap(\.rows).filter(\.account.includeInNetWorth).compactMap(\.lastUpdated).max(),
            changeVsPreviousMonthGBP: previousNetWorth.map { netWorth - $0 },
            groups: groups,
            staleCount: staleCount,
            oldestStaleDate: oldestStale
        )
    }
}
