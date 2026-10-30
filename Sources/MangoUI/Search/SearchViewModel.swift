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
    /// Under a day's total when the day lists an incoming transfer leg that the total leaves out.
    public static let transferNote = "Transfers between your accounts aren't counted in the total"

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

    /// The day lists the incoming leg of a transfer between the household's accounts that its total leaves out (the
    /// transfer counts once, as sent).
    public var listsUncountedTransfer: Bool { totals.excludedTransferLegCount > 0 }

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
    /// Grouping stops at the first new day once `rowLimit` rows are listed: the rest is never grouped.
    public static func make(rows: [TransactionSearch.Row], eurToGbpRate: Double, countsTransfersOnce: Bool, rowLimit: Int) -> SearchResults {
        var days: [SearchDay] = []
        var shown = 0
        var openDay: Date?
        var openRows: [TransactionSearch.Row] = []
        func close() {
            guard let day = openDay else { return }
            days.append(SearchDay(day: day, rows: openRows,
                                  totals: TransactionSearch.totals(openRows, eurToGbpRate: eurToGbpRate, countsTransfersOnce: countsTransfersOnce)))
            shown += openRows.count
            openRows.removeAll(keepingCapacity: true)
        }
        for row in rows {
            let day = MonthRange.calendar.startOfDay(for: row.date)
            if day != openDay {
                close()
                if shown >= rowLimit {
                    openDay = nil
                    break
                }
                openDay = day
            }
            openRows.append(row)
        }
        close()
        return SearchResults(days: days, matchCount: rows.count)
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

/// Search's state (iPhone spec §3.4). One read per load builds `TransactionSearch.Index` (kept newest first, so a
/// search never sorts); typing and tokens only filter it (`TransactionSearch.rows`), off the main actor. Nothing here computes a figure:
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
    /// What `results` are for (they follow `criteria` a moment later, off the main actor).
    @Published public private(set) var resultsCriteria = TransactionSearch.Criteria()
    /// The transaction open in the detail sheet.
    @Published public var detail: TransactionSearch.Row?

    private let dbQueue: any DatabaseReader
    private let today: () -> Date
    private let queryDelay: Duration
    /// Waits out the typing pause (`Task.sleep`; tests pass a gate they open themselves).
    private let pause: @Sendable (Duration) async -> Void
    /// The query the results are for (`query` after the pause).
    private var appliedQuery: String
    private var queryTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var filterTask: Task<SearchResults?, Never>?
    private var refreshGeneration = 0
    private var data: SearchData?
    private var loadedKey: Date?
    private var generation = 0

    /// `queryDelay`: the pause in typing before the results follow the field (`.zero`: at once). `pause` waits it out.
    public init(dbQueue: any DatabaseReader, today: @escaping () -> Date, queryDelay: Duration = .milliseconds(150),
                pause: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }) {
        self.dbQueue = dbQueue
        self.today = today
        self.queryDelay = queryDelay
        self.pause = pause
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
        self.pause = { _ in }
        self.query = query
        self.appliedQuery = query
        self.tokens = tokens
        self.data = data
        self.state = data == nil ? .failed(Self.loadFailureMessage) : .loaded
        // The route's first frame needs its results: computed here, at once.
        let criteria = SearchQuery.criteria(text: query, tokens: tokens)
        if let data {
            results = Self.results(data, criteria: criteria, now: today())
            resultsCriteria = criteria
        }
    }

    /// What the results are for: the applied query and the tokens.
    public var criteria: TransactionSearch.Criteria {
        SearchQuery.criteria(text: appliedQuery, tokens: tokens)
    }

    /// The results shown are for nothing typed and no token: the list is the newest transactions.
    public var isBrowsing: Bool { resultsCriteria.isDefault }

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
        let tokens = accounts.sortedForDisplay().compactMap { account in
            account.id.map { SearchToken.account(id: $0, name: account.displayName) }
        }
        return SearchData(index: index, eurToGbpRate: rate, accountTokens: tokens,
                          rowsById: Dictionary(index.allRows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }))
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
        let pause = pause
        queryTask = Task { [weak self] in
            await pause(delay)
            guard !Task.isCancelled, let self, self.query == text else { return }
            self.appliedQuery = text
            self.refresh()
        }
    }

    /// The results for the applied query and the tokens, computed off the main actor; a later refresh wins.
    private func refresh() {
        refreshGeneration += 1
        let mine = refreshGeneration
        let criteria = criteria
        guard let data else {
            results = .empty
            resultsCriteria = criteria
            return
        }
        let now = today()
        // A newer search supersedes this one: a filter still waiting to start never runs.
        filterTask?.cancel()
        let filter = Task.detached(priority: .userInitiated) { () -> SearchResults? in
            guard !Task.isCancelled else { return nil }
            return SearchViewModel.results(data, criteria: criteria, now: now)
        }
        filterTask = filter
        refreshTask = Task { [weak self] in
            guard let computed = await filter.value else { return }
            guard let self, mine == self.refreshGeneration else { return }
            self.results = computed
            self.resultsCriteria = criteria
        }
    }

    /// Waits for a pending typing pause and refresh (tests; the view just watches `results`).
    public func settle() async {
        await queryTask?.value
        await refreshTask?.value
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
        // A first load that failed reads again on every sync's start and end (`SyncReloadTrigger`), data or not.
        if state != .idle, !state.isFailed {
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

extension SearchViewModel.State: ScreenLoadState {}
