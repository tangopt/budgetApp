import Foundation

/// The Accounts screen's balance history for one account (spec 2026-10-14 §1/§3): computed
/// month-end balances for the chart, and a list of what set the balance — the opening balance,
/// any later recorded balance (legacy data, before the conversion) and every adjustment
/// (a transaction in a built-in category).
public struct AccountHistory: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case opening
        /// A recorded balance after the opening one (legacy, until converted).
        case recordedBalance
        /// An adjustment transaction filed under the built-in category `categoryName`.
        case adjustment(categoryName: String)
    }

    public struct Entry: Equatable, Identifiable, Sendable {
        /// "s<id>" for a snapshot, "t<id>" for a transaction.
        public let id: String
        public let date: Date
        public let kind: Kind
        /// The balance (opening / recorded) or the adjustment's signed amount.
        public let amountMinorUnits: Int
        public let note: String?
    }

    public struct Point: Equatable, Sendable {
        public let date: Date
        public let balanceMinorUnits: Int
    }

    /// Newest first.
    public let entries: [Entry]
    /// Oldest first: the balance at the end of the opening day (or the first transaction's day
    /// when there's no opening balance), each month end after it before today, then the end of today.
    public let points: [Point]

    public static let empty = AccountHistory(entries: [], points: [])

    /// `adjustmentCategoryNames`: the built-in categories' names by id.
    public static func make(accountId: Int64, snapshots: [BalanceSnapshot], transactions: [Transaction],
                            adjustmentCategoryNames: [Int64: String], today: Date) -> AccountHistory {
        let snapshots = snapshots.filter { $0.accountId == accountId }
        let transactions = transactions.filter { $0.accountId == accountId }
        let ordered = snapshots.sorted { NetWorthCalculator.isNewer($1, $0) }
        var entries: [(order: Int, entry: Entry)] = ordered.enumerated().map { index, snapshot in
            (0, Entry(id: "s\(snapshot.id ?? 0)", date: snapshot.date, kind: index == 0 ? .opening : .recordedBalance,
                      amountMinorUnits: snapshot.balanceMinorUnits, note: snapshot.note))
        }
        for transaction in transactions {
            guard let categoryId = transaction.categoryId, let name = adjustmentCategoryNames[categoryId] else { continue }
            entries.append((1, Entry(id: "t\(transaction.id ?? 0)", date: transaction.date, kind: .adjustment(categoryName: name),
                                     amountMinorUnits: transaction.amountMinorUnits, note: transaction.note)))
        }
        entries.sort { $0.entry.date != $1.entry.date ? $0.entry.date > $1.entry.date : $0.order > $1.order }

        var points: [Point] = []
        let calendar = MonthRange.calendar
        if let start = ordered.first?.date ?? transactions.map(\.date).min() {
            let end = BalanceUpdates.endOfDay(today)
            func add(_ date: Date) {
                if let balance = NetWorthCalculator.balance(accountId: accountId, at: date, snapshots: snapshots, transactions: transactions)?.native {
                    points.append(Point(date: date, balanceMinorUnits: balance))
                }
            }
            let startEnd = BalanceUpdates.endOfDay(start)
            add(startEnd)
            var month = MonthRange.components(of: start)
            while true {
                let monthEnd = MonthRange.of(year: month.year, month: month.month).end
                if monthEnd >= end { break }
                if monthEnd > startEnd { add(monthEnd) }
                let next = calendar.date(byAdding: .month, value: 1, to: MonthRange.of(year: month.year, month: month.month).start)!
                month = MonthRange.components(of: next)
            }
            if end > startEnd { add(end) }
        }
        return AccountHistory(entries: entries.map(\.entry), points: points)
    }
}
