import Foundation

/// Transaction search (spec 2026-10-15): every transaction — not only budget-facing ones, so
/// linked incoming legs too — filtered by free text, date, amount, accounts, categories and
/// flags, then sorted, with the matches' totals. Pure: works on what the screen loaded.
public enum TransactionSearch {
    /// The Date filter. Calendar months and years in UTC, as transactions are stored.
    public enum DateFilter: Hashable, Sendable {
        case allTime
        case thisMonth
        case thisYear
        /// From today's date a year ago through today.
        case last12Months
        /// Stored (UTC) days, both included; given in either order.
        case custom(from: Date, to: Date)
    }

    public enum Direction: String, CaseIterable, Sendable {
        case any
        case moneyIn
        case moneyOut
    }

    public enum Flag: String, CaseIterable, Sendable {
        /// Still waiting for review (`pendingReview`).
        case unreviewed
        /// Added by hand.
        case manual
        /// Either leg of an active transfer link.
        case linkedTransfer
        case hasNote
    }

    public struct Criteria: Equatable, Sendable {
        /// Words that must each match the description, note or category name (any case); a
        /// word that reads as an amount ("12.99", "£12.99", "-12.99") also matches that
        /// absolute amount exactly.
        public var text: String
        public var date: DateFilter
        /// Bounds on the absolute amount, both included; nil = unbounded.
        public var minAmountMinorUnits: Int?
        public var maxAmountMinorUnits: Int?
        public var direction: Direction
        /// Empty = every account.
        public var accountIds: Set<Int64>
        /// With `includesUncategorised`, the categories kept; both empty/false = every category.
        public var categoryIds: Set<Int64>
        public var includesUncategorised: Bool
        /// Every flag given must hold.
        public var flags: Set<Flag>

        public init(text: String = "", date: DateFilter = .allTime, minAmountMinorUnits: Int? = nil, maxAmountMinorUnits: Int? = nil,
                    direction: Direction = .any, accountIds: Set<Int64> = [], categoryIds: Set<Int64> = [],
                    includesUncategorised: Bool = false, flags: Set<Flag> = []) {
            self.text = text
            self.date = date
            self.minAmountMinorUnits = minAmountMinorUnits
            self.maxAmountMinorUnits = maxAmountMinorUnits
            self.direction = direction
            self.accountIds = accountIds
            self.categoryIds = categoryIds
            self.includesUncategorised = includesUncategorised
            self.flags = flags
        }

        /// Nothing narrows the search (blank text, every filter at its default).
        public var isDefault: Bool {
            var blank = self
            blank.text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return blank == Criteria()
        }

        /// Whether the category filter is on.
        public var filtersCategories: Bool { !categoryIds.isEmpty || includesUncategorised }
    }

    /// What the search runs over: everything the screen loaded.
    public struct Input: Sendable {
        public var transactions: [Transaction]
        public var categories: [Category]
        public var accounts: [Account]
        public var links: [TransferLink]
        public var eurToGbpRate: Double

        public init(transactions: [Transaction], categories: [Category], accounts: [Account], links: [TransferLink], eurToGbpRate: Double) {
            self.transactions = transactions
            self.categories = categories
            self.accounts = accounts
            self.links = links
            self.eurToGbpRate = eurToGbpRate
        }
    }

    /// A result row: the transaction with what its columns show.
    public struct Row: Identifiable, Equatable, Sendable {
        public let transaction: Transaction
        public let category: Category?
        /// Empty when uncategorised.
        public let categoryName: String
        public let accountName: String
        public let currency: Currency
        public let isLinkedTransfer: Bool
        /// The outgoing leg's id when this is the incoming leg of an active transfer link:
        /// hidden from budget figures (`TransferLinks.budgetFacing`), the money counted as sent.
        public let outgoingTransactionId: Int64?

        public var isIncomingTransferLeg: Bool { outgoingTransactionId != nil }
        public var id: Int64 { transaction.id ?? -1 }
        public var date: Date { transaction.date }
        public var description: String { transaction.rawDescription }
        public var amountMinorUnits: Int { transaction.amountMinorUnits }
    }

    public enum SortKey: String, CaseIterable, Sendable {
        case date, description, category, account, amount
    }

    /// The summary bar: matches in sterling (euro amounts converted at the stored rate).
    public struct Totals: Equatable, Sendable {
        public let count: Int
        /// Money in (≥ 0).
        public let inMinorUnits: Int
        /// Money out (≤ 0).
        public let outMinorUnits: Int
        public var netMinorUnits: Int { inMinorUnits + outMinorUnits }
        /// Incoming legs of linked transfers left out of In and Out (counted once, as sent).
        public let excludedTransferLegCount: Int

        public init(count: Int, inMinorUnits: Int, outMinorUnits: Int, excludedTransferLegCount: Int = 0) {
            self.count = count
            self.inMinorUnits = inMinorUnits
            self.outMinorUnits = outMinorUnits
            self.excludedTransferLegCount = excludedTransferLegCount
        }
    }

    // MARK: Search

    /// `Input` prepared once per load: each transaction's row and its folded search text, newest
    /// first (ties: the later id first, `sorted(_:by: .date, ascending: false)`'s order), so typing
    /// only filters and never sorts.
    public struct Index: Sendable {
        fileprivate struct Entry: Sendable {
            let row: Row
            /// Description, note and category name, case- and diacritic-folded, separated so
            /// a word never spans two of them.
            let haystack: String
        }

        fileprivate let entries: [Entry]

        /// Every row, newest first.
        public var allRows: [Row] { entries.map(\.row) }

        public init(_ input: Input) {
            let categoryById = Dictionary(input.categories.compactMap { c in c.id.map { ($0, c) } }, uniquingKeysWith: { a, _ in a })
            let accountById = Dictionary(input.accounts.compactMap { a in a.id.map { ($0, a) } }, uniquingKeysWith: { a, _ in a })
            let active = input.links.filter { !$0.isDismissed }
            let linked = Set(active.flatMap { [$0.outTransactionId, $0.inTransactionId] })
            let outByIn = Dictionary(active.map { ($0.inTransactionId, $0.outTransactionId) }, uniquingKeysWith: { first, _ in first })
            let unsorted: [Entry] = input.transactions.map { transaction in
                let category = transaction.categoryId.flatMap { categoryById[$0] }
                let account = accountById[transaction.accountId]
                let row = Row(transaction: transaction, category: category, categoryName: category?.name ?? "",
                              accountName: account?.displayName ?? "", currency: account?.currency ?? .gbp,
                              isLinkedTransfer: transaction.id.map(linked.contains) ?? false,
                              outgoingTransactionId: transaction.id.flatMap { outByIn[$0] })
                let haystack = [transaction.rawDescription, transaction.note ?? "", category?.name ?? ""]
                    .map(TransactionSearch.fold).joined(separator: "\u{1}")
                return Entry(row: row, haystack: haystack)
            }
            entries = unsorted.sorted { lhs, rhs in
                lhs.row.date != rhs.row.date ? lhs.row.date > rhs.row.date : lhs.row.id > rhs.row.id
            }
        }
    }

    /// Case- and diacritic-insensitive form of `text`, for matching.
    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    /// The transactions matching `criteria`, as rows, newest first. `now` and `timeZone`
    /// (the user's "today") anchor the relative date filters.
    public static func rows(_ input: Input, criteria: Criteria, now: Date = Date(), timeZone: TimeZone = .current) -> [Row] {
        rows(Index(input), criteria: criteria, now: now, timeZone: timeZone)
    }

    public static func rows(_ index: Index, criteria: Criteria, now: Date = Date(), timeZone: TimeZone = .current) -> [Row] {
        let range = dateRange(criteria.date, now: now, timeZone: timeZone)
        let words = criteria.text.split(whereSeparator: \.isWhitespace).map(String.init)
        let terms = words.map { (folded: fold($0), amount: amountToken($0)) }

        let rows: [Row] = index.entries.compactMap { entry in
            let row = entry.row
            let transaction = row.transaction
            if let range, !range.contains(transaction.date) { return nil }
            let magnitude = transaction.amountMinorUnits.magnitude
            if let min = criteria.minAmountMinorUnits, magnitude < min.magnitude { return nil }
            if let max = criteria.maxAmountMinorUnits, magnitude > max.magnitude { return nil }
            switch criteria.direction {
            case .any: break
            case .moneyIn: if transaction.amountMinorUnits <= 0 { return nil }
            case .moneyOut: if transaction.amountMinorUnits >= 0 { return nil }
            }
            if !criteria.accountIds.isEmpty, !criteria.accountIds.contains(transaction.accountId) { return nil }
            if criteria.filtersCategories {
                if let id = transaction.categoryId {
                    if !criteria.categoryIds.contains(id) { return nil }
                } else if !criteria.includesUncategorised {
                    return nil
                }
            }
            for flag in criteria.flags {
                switch flag {
                case .unreviewed: if transaction.status != .pendingReview { return nil }
                case .manual: if !transaction.isManual { return nil }
                case .linkedTransfer: if !row.isLinkedTransfer { return nil }
                case .hasNote: if (transaction.note ?? "").isEmpty { return nil }
                }
            }
            for term in terms {
                let matchesAmount = term.amount.map { $0 == Int(magnitude) } ?? false
                if !matchesAmount && !entry.haystack.contains(term.folded) { return nil }
            }
            return row
        }
        // Already newest first: the Index is kept in that order.
        return rows
    }

    /// A word read as an amount, in absolute minor units: "12.99", "£12.99", "-12.99",
    /// "-£12.99", "1,200". Nil when it isn't one.
    public static func amountToken(_ word: String) -> Int? {
        var cleaned = word.trimmingCharacters(in: .whitespaces)
        if cleaned.hasPrefix("-") || cleaned.hasPrefix("+") { cleaned.removeFirst() }
        guard cleaned.contains(where: \.isNumber), let value = Money.parseMinorUnits(cleaned) else { return nil }
        return abs(value)
    }

    /// The instants a date filter keeps; nil = all time. "This" month or year and the last
    /// 12 months follow today's date in `timeZone` (the user's); transactions are stored as
    /// UTC days, so the ranges are UTC.
    public static func dateRange(_ filter: DateFilter, now: Date, timeZone: TimeZone = .current) -> ClosedRange<Date>? {
        let calendar = MonthRange.calendar
        let today = PayCalendar.utcDay(sameDayAs: now, in: timeZone)
        switch filter {
        case .allTime:
            return nil
        case .thisMonth:
            let (year, month) = MonthRange.components(of: today)
            let range = MonthRange.of(year: year, month: month)
            return range.start...range.end
        case .thisYear:
            let year = MonthRange.components(of: today).year
            return MonthRange.of(year: year, month: 1).start...MonthRange.of(year: year, month: 12).end
        case .last12Months:
            let start = calendar.date(byAdding: .year, value: -1, to: today)!
            return start...endOfDay(today)
        case .custom(let from, let to):
            let first = calendar.startOfDay(for: min(from, to))
            let last = calendar.startOfDay(for: max(from, to))
            return first...endOfDay(last)
        }
    }

    private static func endOfDay(_ day: Date) -> Date {
        MonthRange.calendar.date(byAdding: .day, value: 1, to: day)!.addingTimeInterval(-1)
    }

    /// A category group's members: what picking the group in the Categories filter selects.
    public static func memberIds(ofGroupId groupId: Int64, categories: [Category]) -> Set<Int64> {
        Set(categories.filter { $0.groupId == groupId }.compactMap(\.id))
    }

    // MARK: Sorting

    /// Rows ordered by a column. Ties are newest first (then the later id), except on the
    /// date column ascending, where they go oldest first (then the earlier id).
    public static func sorted(_ rows: [Row], by key: SortKey, ascending: Bool) -> [Row] {
        rows.sorted { lhs, rhs in
            let order: ComparisonResult
            switch key {
            case .date: order = compare(lhs.date, rhs.date)
            case .description: order = lhs.description.localizedStandardCompare(rhs.description)
            case .category: order = lhs.categoryName.localizedStandardCompare(rhs.categoryName)
            case .account: order = lhs.accountName.localizedStandardCompare(rhs.accountName)
            case .amount: order = compare(lhs.amountMinorUnits, rhs.amountMinorUnits)
            }
            if order != .orderedSame { return ascending ? order == .orderedAscending : order == .orderedDescending }
            if key == .date && ascending { return lhs.id < rhs.id }
            if lhs.date != rhs.date { return lhs.date > rhs.date }
            return lhs.id > rhs.id
        }
    }

    private static func compare<T: Comparable>(_ lhs: T, _ rhs: T) -> ComparisonResult {
        lhs < rhs ? .orderedAscending : (lhs > rhs ? .orderedDescending : .orderedSame)
    }

    // MARK: Totals

    /// Count, money in, money out and net of `rows`, in sterling. With `countsTransfersOnce`
    /// (no account filter, as the Budget grid without one) an active link's incoming leg is
    /// left out of In and Out — the transfer counts once, as sent; it still counts as a row.
    public static func totals(_ rows: [Row], eurToGbpRate: Double, countsTransfersOnce: Bool = false) -> Totals {
        let rate = ExchangeRateSetting(eurToGbpRate: eurToGbpRate, updatedAt: Date(timeIntervalSince1970: 0))
        var inTotal = 0
        var outTotal = 0
        var excluded = 0
        for row in rows {
            if countsTransfersOnce && row.isIncomingTransferLeg {
                excluded += 1
                continue
            }
            let gbp = NetWorthCalculator.gbp(row.amountMinorUnits, currency: row.currency, rate: rate)
            if gbp > 0 { inTotal += gbp } else { outTotal += gbp }
        }
        return Totals(count: rows.count, inMinorUnits: inTotal, outMinorUnits: outTotal, excludedTransferLegCount: excluded)
    }
}
