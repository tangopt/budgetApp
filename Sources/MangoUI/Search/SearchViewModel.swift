import Foundation
import BudgetCore
import struct BudgetCore.Category
import struct BudgetCore.Transaction
import GRDB

/// The words Search uses.
public enum SearchCopy {
    public static let prompt = "Description, amount or category"
    public static let emptyTitle = "Nothing matches"
    public static let emptyMessage = "Try other words, an amount like 24.99 or >100, or fewer filters."
    public static let noTransactionsTitle = "No transactions yet"
    public static let noTransactionsMessage = "Transactions appear here once the household's data arrives."
    public static let recentTitle = "Recent"
    public static let detailFooter = "Edit on iPad or Mac"

    public static func matches(_ count: Int) -> String {
        count == 1 ? "1 match" : "\(count) matches"
    }

    /// Under the count when only the newest days are listed.
    public static func capped(shown: Int) -> String {
        "Showing the newest \(shown). Narrow the search to see the rest."
    }
}

/// One day of results: its rows (newest first) and `TransactionSearch.totals` over them.
public struct SearchDay: Equatable, Sendable, Identifiable {
    /// The day (UTC start of day, as transactions are stored).
    public let day: Date
    public let rows: [TransactionSearch.Row]
    public let totals: TransactionSearch.Totals
    public var id: Date { day }

    public init(day: Date, rows: [TransactionSearch.Row], totals: TransactionSearch.Totals) {
        self.day = day
        self.rows = rows
        self.totals = totals
    }
}

/// What the results list shows: the matches by day, newest first, whole days only, stopping once `rowLimit` rows are
/// listed (a phone list of thousands of rows helps no one; the count says how many matched).
public struct SearchResults: Equatable, Sendable {
    public var days: [SearchDay]
    /// Every match, listed or not.
    public let matchCount: Int

    public static let empty = SearchResults(days: [], matchCount: 0)

    public var shownCount: Int { days.reduce(0) { $0 + $1.rows.count } }
    public var isCapped: Bool { shownCount < matchCount }

    /// `rows` newest first (as `TransactionSearch.rows` returns them). Each day's total is `TransactionSearch.totals`
    /// over all of that day's rows, with `countsTransfersOnce` as the Mac's search uses it (no account filter).
    public static func make(rows: [TransactionSearch.Row], eurToGbpRate: Double, countsTransfersOnce: Bool, rowLimit: Int) -> SearchResults {
        var days: [SearchDay] = []
        var shown = 0
        for (day, dayRows) in group(rows) {
            if shown >= rowLimit { break }
            days.append(SearchDay(day: day, rows: dayRows,
                                  totals: TransactionSearch.totals(dayRows, eurToGbpRate: eurToGbpRate, countsTransfersOnce: countsTransfersOnce)))
            shown += dayRows.count
        }
        return SearchResults(days: days, matchCount: rows.count)
    }

    /// Consecutive rows on the same UTC day, in order.
    static func group(_ rows: [TransactionSearch.Row]) -> [(Date, [TransactionSearch.Row])] {
        var result: [(Date, [TransactionSearch.Row])] = []
        for row in rows {
            let day = MonthRange.calendar.startOfDay(for: row.date)
            if let last = result.indices.last, result[last].0 == day {
                result[last].1.append(row)
            } else {
                result.append((day, [row]))
            }
        }
        return result
    }
}

/// What Search loads once per read: `TransactionSearch.Index` over every transaction, the stored euro rate, the
/// account tokens and each row by id (to keep an open detail current after a sync).
public struct SearchData: Sendable {
    public let index: TransactionSearch.Index
    public let eurToGbpRate: Double
    public let accountTokens: [SearchToken]
    let rowsById: [Int64: TransactionSearch.Row]
}

/// Search's state (iPhone spec §3.4). One read per load builds `TransactionSearch.Index`; typing and tokens only
/// filter it (`TransactionSearch.rows`), on the main actor, as the Mac's search does. Nothing here computes a figure:
/// the day totals are `TransactionSearch.totals`.
///
/// The pattern of the other tabs: `load()` reads off the main actor; `.task(id: reloadKey)` reloads after a sync; the
/// snapshot routes use `readNow`. The model sits above the lock cover, so a relock keeps the query, the tokens and an
/// open transaction (`detail`).
@MainActor
public final class SearchViewModel: ObservableObject {
    public enum State: Equatable, Sendable {
        case idle
        case loaded
        case failed(String)
    }

    public static let loadFailureMessage = "Mango couldn't read the transactions. Pull down to try again."
    /// Nothing typed: the newest days, about this many rows.
    public static let recentRowLimit = 20
    /// A search: the newest days of its matches, about this many rows.
    public static let resultRowLimit = 150

    @Published public private(set) var state: State
    @Published public private(set) var errorMessage: String?
    /// What the field holds. Typing reaches the results after a short pause (`queryDelay`), as on the Mac, so a
    /// keystroke never waits for the list to redraw; clearing applies at once.
    @Published public var query: String {
        didSet { if query != oldValue { scheduleQuery() } }
    }
    @Published public var tokens: [SearchToken] {
        didSet { if tokens != oldValue { refresh() } }
    }
    @Published public private(set) var results: SearchResults = .empty
    /// The transaction open in the detail sheet.
    @Published public var detail: TransactionSearch.Row?

    private let dbQueue: any DatabaseReader
    private let today: () -> Date
    private let queryDelay: Duration
    /// The query the results are for (`query` after the pause).
    private var appliedQuery: String
    private var queryTask: Task<Void, Never>?
    private var data: SearchData?
    private var loadedKey: Date?
    private var generation = 0

    /// `queryDelay`: the pause in typing before the results follow the field (`.zero`: at once, for tests).
    public init(dbQueue: any DatabaseReader, today: @escaping () -> Date, queryDelay: Duration = .milliseconds(150)) {
        self.dbQueue = dbQueue
        self.today = today
        self.queryDelay = queryDelay
        self.query = ""
        self.appliedQuery = ""
        self.tokens = []
        self.state = .idle
    }

    /// Already loaded (the snapshot harness): `data` from `readNow`, nil when that read failed.
    public init(dbQueue: any DatabaseReader, today: @escaping () -> Date, query: String = "", tokens: [SearchToken] = [],
                preloaded data: SearchData?) {
        self.dbQueue = dbQueue
        self.today = today
        self.queryDelay = .zero
        self.query = query
        self.appliedQuery = query
        self.tokens = tokens
        self.data = data
        self.state = data == nil ? .failed(Self.loadFailureMessage) : .loaded
        refresh()
    }

    /// What the results are for: the applied query and the tokens.
    public var criteria: TransactionSearch.Criteria {
        SearchQuery.criteria(text: appliedQuery, tokens: tokens)
    }

    /// Nothing typed and no token: the list is the newest transactions.
    public var isBrowsing: Bool { criteria.isDefault }

    public var suggestedTokens: [SearchToken] {
        SearchQuery.suggestions(accounts: data?.accountTokens ?? [], chosen: tokens)
    }

    /// Reads off the main actor. A failed read keeps what was shown (and says so).
    public func load() async {
        generation += 1
        let mine = generation
        do {
            let loaded = try await dbQueue.read { db in try Self.read(db) }
            guard mine == generation else { return }
            data = loaded
            state = .loaded
            errorMessage = nil
            refresh()
            if let open = detail { detail = loaded.rowsById[open.id] }
        } catch {
            guard mine == generation else { return }
            if state == .loaded { errorMessage = Self.loadFailureMessage } else { state = .failed(Self.loadFailureMessage) }
        }
    }

    /// The same read, now (the snapshot routes); nil when it fails.
    public nonisolated static func readNow(_ dbQueue: any DatabaseReader) -> SearchData? {
        try? dbQueue.read { db in try read(db) }
    }

    nonisolated static func read(_ db: Database) throws -> SearchData {
        let transactions = try Transaction.fetchAll(db)
        let categories = try Category.fetchAll(db)
        let accounts = try Account.fetchAll(db)
        let links = try TransferLink.fetchAll(db)
        let rate = try ExchangeRateSetting.currentOrDefault(db: db).eurToGbpRate
        let index = TransactionSearch.Index(TransactionSearch.Input(transactions: transactions, categories: categories, accounts: accounts,
                                                                    links: links, eurToGbpRate: rate))
        let all = TransactionSearch.rows(index, criteria: TransactionSearch.Criteria())
        let tokens = accounts.sortedForDisplay().compactMap { account in
            account.id.map { SearchToken.account(id: $0, name: account.displayName) }
        }
        return SearchData(index: index, eurToGbpRate: rate, accountTokens: tokens,
                          rowsById: Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }))
    }

    private func scheduleQuery() {
        queryTask?.cancel()
        let text = query
        guard !text.isEmpty, queryDelay > .zero else {
            appliedQuery = text
            refresh()
            return
        }
        let delay = queryDelay
        queryTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, self.query == text else { return }
            self.appliedQuery = text
            self.refresh()
        }
    }

    /// The results for the applied query and the tokens.
    private func refresh() {
        guard let data else {
            results = .empty
            return
        }
        results = Self.results(data, criteria: criteria, now: today())
    }

    nonisolated static func results(_ data: SearchData, criteria: TransactionSearch.Criteria, now: Date) -> SearchResults {
        let rows = TransactionSearch.rows(data.index, criteria: criteria, now: now)
        return SearchResults.make(rows: rows, eurToGbpRate: data.eurToGbpRate, countsTransfersOnce: criteria.accountIds.isEmpty,
                                  rowLimit: criteria.isDefault ? recentRowLimit : resultRowLimit)
    }

    // MARK: Reloading after a sync

    public nonisolated static func reloadKey(_ status: SyncStatus) -> Date? {
        HomeViewModel.reloadKey(status)
    }

    /// Loads the first time, then again only when a new sync has landed.
    public func reload(for key: Date?) async {
        if state != .idle {
            guard let key, key != loadedKey else { return }
        }
        loadedKey = key
        await load()
    }

    // MARK: The route's check

    /// The snapshot route's assertion (plan Task 11 step 2): each day shown lists exactly that day's matches, with
    /// `TransactionSearch.totals` over them, read afresh; and the count is every match's.
    public nonisolated static func dayTotalsCheck(dbQueue: any DatabaseReader, today: Date, criteria: TransactionSearch.Criteria,
                                                  shown: SearchResults) throws -> (matches: Bool, line: String) {
        let fresh = try dbQueue.read { db in try read(db) }
        let rows = TransactionSearch.rows(fresh.index, criteria: criteria, now: today)
        let byDay = Dictionary(grouping: rows) { MonthRange.calendar.startOfDay(for: $0.date) }
        var different: [String] = []
        for day in shown.days {
            let dayRows = (byDay[day.day] ?? []).sorted { $0.date != $1.date ? $0.date > $1.date : $0.id > $1.id }
            let expected = TransactionSearch.totals(dayRows, eurToGbpRate: fresh.eurToGbpRate,
                                                    countsTransfersOnce: criteria.accountIds.isEmpty)
            if day.totals != expected || day.rows.map(\.id) != dayRows.map(\.id) {
                different.append("\(PhoneDateFormat.day(day.day)) shown \(Money.format(day.totals.netMinorUnits, currency: .gbp))"
                                 + " (TransactionSearch.totals \(Money.format(expected.netMinorUnits, currency: .gbp)))")
            }
        }
        if shown.matchCount != rows.count {
            different.append("\(shown.matchCount) matches shown, \(rows.count) found")
        }
        let matches = different.isEmpty && !shown.days.isEmpty
        let line = "\(shown.days.count) days, \(shown.shownCount) of \(rows.count) matches: "
            + (matches ? "each day's total equal to TransactionSearch.totals" : "DIFFERENT " + (different.isEmpty ? "(no days)" : different.joined(separator: "; ")))
        return (matches, line)
    }
}
