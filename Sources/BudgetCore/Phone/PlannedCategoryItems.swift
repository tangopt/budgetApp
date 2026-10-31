import Foundation
import GRDB

/// What the confirmed plan holds for one category in a pay month's plan period, one item per occurrence, with the
/// ones the month's transactions already cover marked done (the Month screen's category detail, "what's planned and
/// when"). The occurrences are `ForecastCalculator.confirmedOccurrences`, the same the row's plan figure sums, so
/// the items add up to `PayMonthReview.Row.planMinorUnits`.
public enum PlannedCategoryItems {
    public struct Item: Equatable, Identifiable, Sendable {
        public let entryId: Int64
        /// The occurrence's date, after any move.
        public let date: Date
        /// Signed like the plan (negative = money out).
        public let amountMinorUnits: Int
        /// The entry's note, when it has one.
        public let note: String?
        /// The transaction that covers it; nil while still planned.
        public let matchedTransactionId: Int64?
        public var isDone: Bool { matchedTransactionId != nil }
        public var id: String { "\(entryId)-\(date.timeIntervalSince1970)" }
    }

    /// An occurrence is covered by a transaction of the same direction whose amount is within this share of it
    /// (or `matchSlackMinorUnits`, whichever is more): bills rarely land to the penny.
    static let matchTolerance = 0.10
    static let matchSlackMinorUnits = 100

    /// The category's occurrences in `planPeriod`, by date, each matched to at most one of `transactions` (the
    /// category's confirmed transactions in the pay month, signed as stored, in GBP). Earlier occurrences choose
    /// first, each taking the unused transaction closest in amount (then earliest).
    public static func items(categoryId: Int64, planPeriod: PayPeriod, entries: [ForecastEntry], groups: [ForecastGroup],
                             exceptions: [PlannedOccurrenceException], transactions: [Transaction]) -> [Item] {
        let occurrences = ForecastCalculator.confirmedOccurrences(period: planPeriod, entries: entries, groups: groups,
                                                                  exceptions: exceptions, filter: nil)
            .filter { $0.categoryId == categoryId }
            .sorted { ($0.date, $0.entryId) < ($1.date, $1.entryId) }
        let notes = Dictionary(entries.compactMap { entry in entry.id.map { ($0, entry.note) } }, uniquingKeysWith: { first, _ in first })
        var unused = transactions.sorted { ($0.date, $0.id ?? 0) < ($1.date, $1.id ?? 0) }
        return occurrences.map { occurrence in
            let planned = occurrence.amountMinorUnits
            let allowed = max(Int(Double(abs(planned)) * matchTolerance), matchSlackMinorUnits)
            let best = unused.indices
                .filter { unused[$0].amountMinorUnits.signum() == planned.signum() && abs(unused[$0].amountMinorUnits - planned) <= allowed }
                .min { abs(unused[$0].amountMinorUnits - planned) < abs(unused[$1].amountMinorUnits - planned) }
            let matched = best.map { unused.remove(at: $0) }
            return Item(entryId: occurrence.entryId, date: occurrence.date, amountMinorUnits: planned,
                        note: notes[occurrence.entryId] ?? nil, matchedTransactionId: matched?.id)
        }
    }

    /// The same, read from the database for a row's pay month: `range` must carry its month (`DayRange.month`);
    /// without one there is no plan period and no items. Only the transactions `viewer` reads can cover an item
    /// (the other person's private accounts stay category totals); the plan itself is the household's.
    public static func read(db: Database, categoryId: Int64, range: PayMonthReview.DayRange, viewer: SharingViewer, today: Date) throws -> [Item] {
        guard let period = range.planPeriod else { return [] }
        let transactions = try PayMonthReview.transactions(db: db, categoryId: categoryId, range: range, viewer: viewer, today: today)
            .map(\.transaction)
        return items(categoryId: categoryId, planPeriod: period, entries: try ForecastEntry.budget(db),
                     groups: try ForecastGroup.fetchAll(db), exceptions: try PlannedOccurrenceException.fetchAll(db),
                     transactions: transactions)
    }
}
