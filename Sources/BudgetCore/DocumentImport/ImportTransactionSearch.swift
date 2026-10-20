import Foundation
import GRDB

/// What the review's "Link to a transaction…" searches for: words (description, note or
/// category, or an amount — `TransactionSearch`), an exact amount (either sign), a date window
/// (both days included) and an account.
public struct ImportTransactionQuery: Equatable, Sendable {
    public var text: String
    /// Absolute minor units; nil = any amount.
    public var amountMinorUnits: Int?
    public var from: Date?
    public var to: Date?
    public var accountId: Int64?

    public init(text: String = "", amountMinorUnits: Int? = nil, from: Date? = nil, to: Date? = nil, accountId: Int64? = nil) {
        self.text = text
        self.amountMinorUnits = amountMinorUnits
        self.from = from
        self.to = to
        self.accountId = accountId
    }

    /// Nothing to search by (no words, amount or dates; an account alone isn't enough).
    public var isEmpty: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && amountMinorUnits == nil && from == nil && to == nil
    }

    /// The search a document starts from: its amount, and a month before to two months after
    /// its date (else its period's start), payments coming after a document as a rule.
    public static func suggested(for item: ImportItem) -> ImportTransactionQuery {
        var query = ImportTransactionQuery()
        for field in [ImportFigureField.amount, .pay] {
            if case .money(let amount, _)? = item.facts.first(where: { $0.field == field })?.value {
                query.amountMinorUnits = abs(amount)
                break
            }
        }
        for field in [ImportFigureField.docDate, .periodStart, .periodEnd] {
            if case .date(let date)? = item.facts.first(where: { $0.field == field })?.value {
                let calendar = MonthRange.calendar
                let day = calendar.startOfDay(for: date)
                query.from = calendar.date(byAdding: .month, value: -1, to: day)
                query.to = calendar.date(byAdding: .month, value: 2, to: day)
                break
            }
        }
        return query
    }
}

/// A transaction as the review's peek shows it: date, account, description, amount, category
/// and the documents already linked to it.
public struct ImportTransactionCandidate: Identifiable, Equatable, Sendable {
    public var id: Int64
    public var date: Date
    public var accountId: Int64
    public var accountName: String
    public var description: String
    public var amountMinorUnits: Int
    public var currency: Currency
    /// Empty when uncategorised.
    public var categoryName: String
    public var note: String?
    /// The library documents linked to it (their names).
    public var documentNames: [String]

    public var entity: EvidenceEntity { .transaction(id) }
}

/// The review's transaction search, over the planning copy (`ImportPipeline.searchTransactions`)
/// or any database: SQL narrows by account, amount and dates, `TransactionSearch` matches the
/// words; newest first, at most `limit`.
public enum ImportTransactionSearch {
    public static let limit = 50

    public static func search(db: Database, query: ImportTransactionQuery, limit: Int = Self.limit) throws -> [ImportTransactionCandidate] {
        // Never every transaction: an amount or a date window narrows the rows read in SQL;
        // words alone are matched over the account's (or every) rows — at least one is needed.
        guard !query.isEmpty else { return [] }
        var request = Transaction.all()
        if let accountId = query.accountId { request = request.filter(Column("accountId") == accountId) }
        if let amount = query.amountMinorUnits {
            request = request.filter([abs(amount), -abs(amount)].contains(Column("amountMinorUnits")))
        }
        // Stored (UTC) days, both included.
        let calendar = MonthRange.calendar
        if let from = query.from { request = request.filter(Column("date") >= calendar.startOfDay(for: from)) }
        if let to = query.to, let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: to)) {
            request = request.filter(Column("date") < end)
        }
        let transactions = try request.fetchAll(db)
        let text = query.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let input = TransactionSearch.Input(transactions: transactions, categories: try Category.fetchAll(db), accounts: try Account.fetchAll(db),
                                            links: [], eurToGbpRate: 1)
        let rows = TransactionSearch.rows(input, criteria: TransactionSearch.Criteria(text: text))
        return try candidates(db: db, rows: Array(rows.prefix(max(0, limit))))
    }

    /// The transactions `ids` (those that exist), in that order: the peek of an item's links.
    public static func candidates(db: Database, ids: [Int64]) throws -> [ImportTransactionCandidate] {
        let transactions = try Transaction.fetchAll(db, keys: ids)
        let input = TransactionSearch.Input(transactions: transactions, categories: try Category.fetchAll(db), accounts: try Account.fetchAll(db),
                                            links: [], eurToGbpRate: 1)
        let byId = Dictionary(TransactionSearch.rows(input, criteria: TransactionSearch.Criteria()).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return try candidates(db: db, rows: ids.compactMap { byId[$0] })
    }

    private static func candidates(db: Database, rows: [TransactionSearch.Row]) throws -> [ImportTransactionCandidate] {
        try rows.map { row in
            ImportTransactionCandidate(id: row.id, date: row.date, accountId: row.transaction.accountId, accountName: row.accountName,
                                       description: row.description, amountMinorUnits: row.amountMinorUnits, currency: row.currency,
                                       categoryName: row.categoryName, note: row.transaction.note,
                                       documentNames: try EvidenceLinks.documents(db: db, for: .transaction(row.id)).map(\.displayName))
        }
    }
}
