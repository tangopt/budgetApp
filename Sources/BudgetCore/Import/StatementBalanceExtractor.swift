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
    /// recorded; the string explains why.
    case unverified(String)
    case available([StatementBalancePoint])
}

public enum StatementBalanceExtractor {
    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    /// Verifies a statement's Balance column and turns it into snapshot points: one for
    /// each 1st of a month between the first and last transaction date (inclusive), plus a
    /// closing point at the last transaction date.
    ///
    /// The order of rows *within a day* isn't knowable from dates alone and varies by bank
    /// (newest-first exports list a day's rows newest-first). Two candidate chronological
    /// orders are tried — rows stably date-sorted as given, and reversed-then-stably-sorted
    /// — and a candidate is accepted only if `balance[i-1] + amount[i] == balance[i]`
    /// holds for every consecutive pair. If neither does, nothing is recorded.
    public static func extract(from rows: [ParsedTransaction]) -> StatementBalanceResult {
        guard rows.contains(where: { $0.balanceAfterMinorUnits != nil }) else { return .notProvided }
        guard rows.allSatisfy({ $0.balanceAfterMinorUnits != nil }) else {
            return .unverified("Some rows have no readable balance, so the statement's balances can't be used.")
        }
        let candidates = [chronological(rows), chronological(Array(rows.reversed()))]
        guard let ordered = candidates.first(where: isConsistent) else {
            return .unverified("The Balance column doesn't add up with the transaction amounts, so it wasn't used.")
        }

        let firstDate = ordered.first!.date
        let lastDate = ordered.last!.date
        var points: [StatementBalancePoint] = []
        var cursor = firstOfMonth(onOrAfter: firstDate)
        while cursor <= lastDate {
            if let row = ordered.last(where: { $0.date <= cursor }) {
                points.append(StatementBalancePoint(date: cursor, balanceMinorUnits: row.balanceAfterMinorUnits!, isClosing: cursor == lastDate))
            }
            cursor = calendar.date(byAdding: .month, value: 1, to: cursor)!
        }
        if points.last?.date != lastDate {
            points.append(StatementBalancePoint(date: lastDate, balanceMinorUnits: ordered.last!.balanceAfterMinorUnits!, isClosing: true))
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
