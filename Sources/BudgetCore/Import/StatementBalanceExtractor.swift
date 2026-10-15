import Foundation

/// The balance at the **close** of `date` (UTC midnight of that day). `isClosing` marks
/// the final point (the statement's last transaction date).
public struct StatementBalancePoint: Equatable {
    public let date: Date
    public let balanceMinorUnits: Int
    public let isClosing: Bool

    public init(date: Date, balanceMinorUnits: Int, isClosing: Bool) {
        self.date = date
        self.balanceMinorUnits = balanceMinorUnits
        self.isClosing = isClosing
    }
}

public enum StatementBalanceResult: Equatable {
    /// No row carries a balance (no Balance column mapped, or all cells blank).
    case notProvided
    /// Some rows lack a balance, or no row ordering makes the balances add up. Nothing is
    /// checked; the string explains why.
    case unverified(String)
    case available([StatementBalancePoint])
}

public enum StatementBalanceExtractor {
    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    /// Verifies a statement's Balance column and turns it into balance points: one for
    /// each 1st of a month between the first and last transaction date (inclusive), plus a
    /// closing point at the last transaction date.
    ///
    /// The order of rows *within a day* isn't knowable from dates alone and varies by bank
    /// (newest-first exports list a day's rows newest-first), and some banks list rows in an
    /// order that isn't their dates' at all (Revolut dates a row by when it started but lists
    /// and balances it by when it completed). Four candidate orders are tried — rows stably
    /// date-sorted as given, reversed-then-stably-sorted, the file order, and the file order
    /// reversed — and a candidate is accepted only if `balance[i-1] + amount[i] == balance[i]`
    /// holds for every consecutive pair. If none does, nothing is checked; nor if several do
    /// but start from different opening balances (e.g. +10 then −10 on one day reads either
    /// way round), since the closing balance would then be a guess.
    ///
    /// From the accepted order, the opening balance is the first row's balance less its amount,
    /// and each point is the opening balance plus every amount dated on or before it — so the
    /// closing point is the last row's balance (in file order when that's the order that adds up).
    public static func extract(from rows: [ParsedTransaction]) -> StatementBalanceResult {
        guard rows.contains(where: { $0.balanceAfterMinorUnits != nil }) else { return .notProvided }
        guard rows.allSatisfy({ $0.balanceAfterMinorUnits != nil }) else {
            return .unverified("Some rows have no readable balance, so the statement's balances can't be used.")
        }
        let candidates = [chronological(rows), chronological(Array(rows.reversed())), rows, Array(rows.reversed())]
        let consistent = candidates.filter(isConsistent)
        guard let ordered = consistent.first else {
            return .unverified("The Balance column doesn't add up with the transaction amounts, so it wasn't used.")
        }
        let opening = openingBalance(ordered)
        guard consistent.allSatisfy({ openingBalance($0) == opening }) else {
            return .unverified("The Balance column could be read in more than one order, each giving a different closing balance, so it wasn't used.")
        }

        func balance(atCloseOf date: Date) -> Int {
            opening + ordered.filter { $0.date <= date }.reduce(0) { $0 + $1.amountMinorUnits }
        }
        let firstDate = rows.map(\.date).min()!
        let lastDate = rows.map(\.date).max()!
        var points: [StatementBalancePoint] = []
        var cursor = firstOfMonth(onOrAfter: firstDate)
        while cursor <= lastDate {
            points.append(StatementBalancePoint(date: cursor, balanceMinorUnits: balance(atCloseOf: cursor), isClosing: cursor == lastDate))
            cursor = calendar.date(byAdding: .month, value: 1, to: cursor)!
        }
        if points.last?.date != lastDate {
            points.append(StatementBalancePoint(date: lastDate, balanceMinorUnits: balance(atCloseOf: lastDate), isClosing: true))
        }
        return .available(points)
    }

    /// Stable sort by date: rows with equal dates keep their incoming relative order.
    private static func chronological(_ rows: [ParsedTransaction]) -> [ParsedTransaction] {
        rows.enumerated()
            .sorted { lhs, rhs in
                lhs.element.date != rhs.element.date ? lhs.element.date < rhs.element.date : lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    /// The balance before the first row of `ordered`.
    private static func openingBalance(_ ordered: [ParsedTransaction]) -> Int {
        ordered.first!.balanceAfterMinorUnits! - ordered.first!.amountMinorUnits
    }

    private static func isConsistent(_ ordered: [ParsedTransaction]) -> Bool {
        zip(ordered, ordered.dropFirst()).allSatisfy { previous, next in
            previous.balanceAfterMinorUnits! + next.amountMinorUnits == next.balanceAfterMinorUnits!
        }
    }

    private static func firstOfMonth(onOrAfter date: Date) -> Date {
        let start = calendar.date(from: calendar.dateComponents([.year, .month], from: date))!
        return start >= date ? start : calendar.date(byAdding: .month, value: 1, to: start)!
    }
}
