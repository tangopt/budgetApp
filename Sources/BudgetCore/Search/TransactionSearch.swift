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

        public init(count: Int, inMinorUnits: Int, outMinorUnits: Int) {
            self.count = count
            self.inMinorUnits = inMinorUnits
            self.outMinorUnits = outMinorUnits
        }
    }

    // MARK: Search

    /// The transactions matching `criteria`, as rows, newest first. `now` anchors the
    /// relative date filters.
    public static func rows(_ input: Input, criteria: Criteria, now: Date = Date()) -> [Row] {
        let categoryById = Dictionary(input.categories.compactMap { c in c.id.map { ($0, c) } }, uniquingKeysWith: { a, _ in a })
        let accountById = Dictionary(input.accounts.compactMap { a in a.id.map { ($0, a) } }, uniquingKeysWith: { a, _ in a })
        let linked = Set(input.links.filter { !$0.isDismissed }.flatMap { [$0.outTransactionId, $0.inTransactionId] })
        let range = dateRange(criteria.date, now: now)
        let words = criteria.text.split(whereSeparator: \.isWhitespace).map(String.init)
        let amountWords = words.map(amountToken)

        let rows: [Row] = input.transactions.compactMap { transaction in
            let isLinked = transaction.id.map(linked.contains) ?? false
            let category = transaction.categoryId.flatMap { categoryById[$0] }
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
                case .linkedTransfer: if !isLinked { return nil }
                case .hasNote: if (transaction.note ?? "").isEmpty { return nil }
                }
            }
            for (word, amount) in zip(words, amountWords) {
                let matchesText = transaction.rawDescription.localizedCaseInsensitiveContains(word)
                    || (transaction.note?.localizedCaseInsensitiveContains(word) ?? false)
                    || (category?.name.localizedCaseInsensitiveContains(word) ?? false)
                let matchesAmount = amount.map { $0 == Int(magnitude) } ?? false
                if !matchesText && !matchesAmount { return nil }
            }
            let account = accountById[transaction.accountId]
            return Row(transaction: transaction, category: category, categoryName: category?.name ?? "",
                       accountName: account?.displayName ?? "", currency: account?.currency ?? .gbp, isLinkedTransfer: isLinked)
        }
        return sorted(rows, by: .date, ascending: false)
    }

    /// A word read as an amount, in absolute minor units: "12.99", "£12.99", "-12.99",
    /// "-£12.99", "1,200". Nil when it isn't one.
    public static func amountToken(_ word: String) -> Int? {
        var cleaned = word.trimmingCharacters(in: .whitespaces)
        if cleaned.hasPrefix("-") || cleaned.hasPrefix("+") { cleaned.removeFirst() }
        guard cleaned.contains(where: \.isNumber), let value = Money.parseMinorUnits(cleaned) else { return nil }
        return abs(value)
    }

    /// The instants a date filter keeps; nil = all time.
    public static func dateRange(_ filter: DateFilter, now: Date) -> ClosedRange<Date>? {
        let calendar = MonthRange.calendar
        switch filter {
        case .allTime:
            return nil
        case .thisMonth:
            let (year, month) = MonthRange.components(of: now)
            let range = MonthRange.of(year: year, month: month)
            return range.start...range.end
        case .thisYear:
            let year = MonthRange.components(of: now).year
            return MonthRange.of(year: year, month: 1).start...MonthRange.of(year: year, month: 12).end
        case .last12Months:
            let today = calendar.startOfDay(for: now)
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

    /// Rows ordered by a column; ties (and the date column) newest first, then by id.
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
            if lhs.date != rhs.date { return lhs.date > rhs.date }
            return lhs.id > rhs.id
        }
    }

    private static func compare<T: Comparable>(_ lhs: T, _ rhs: T) -> ComparisonResult {
        lhs < rhs ? .orderedAscending : (lhs > rhs ? .orderedDescending : .orderedSame)
    }

    // MARK: Totals

    /// Count, money in, money out and net of `rows`, in sterling.
    public static func totals(_ rows: [Row], eurToGbpRate: Double) -> Totals {
        let rate = ExchangeRateSetting(eurToGbpRate: eurToGbpRate, updatedAt: Date(timeIntervalSince1970: 0))
        var inTotal = 0
        var outTotal = 0
        for row in rows {
            let gbp = NetWorthCalculator.gbp(row.amountMinorUnits, currency: row.currency, rate: rate)
            if gbp > 0 { inTotal += gbp } else { outTotal += gbp }
        }
        return Totals(count: rows.count, inMinorUnits: inTotal, outMinorUnits: outTotal)
    }
}
