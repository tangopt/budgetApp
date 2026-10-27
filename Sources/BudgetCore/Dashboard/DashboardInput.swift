import Foundation

/// Everything the dashboard needs, loaded once. `today` is part of the input so tests never
/// depend on the clock.
public struct DashboardInput {
    public let today: Date
    public let accounts: [Account]
    public let snapshots: [BalanceSnapshot]
    /// Every transaction: balances, net worth and data freshness.
    public let transactions: [Transaction]
    /// `transactions` without transfers' incoming legs (`TransferLinks.budgetFacing`), in GBP
    /// (`conversion`): flows, month totals, unreviewed and uncategorised counts.
    public let budgetTransactions: [Transaction]
    /// Non-GBP accounts' transactions at `rate`, for the budget figures (`budgetTransactions`).
    let conversion: CurrencyConversion
    public let categories: [Category]
    public let categoryGroups: [CategoryGroup]
    public let forecastEntries: [ForecastEntry]
    /// `forecastEntries` as the net-worth forecast counts them (`ForecastCalculator.netWorthEntries`):
    /// without income and expense items on accounts left out of net worth.
    public let netWorthEntries: [ForecastEntry]
    public let forecastGroups: [ForecastGroup]
    public let exceptions: [PlannedOccurrenceException]
    public let importBatches: [ImportBatch]
    public let rate: ExchangeRateSetting
    /// Latest transaction date across all accounts ("D"); nil when there are no transactions.
    public let dataThrough: Date?
    /// Pay-month boundaries (salaries + manual closes), against `effectiveToday`.
    public let payCalendar: PayCalendar
    /// Confirmed pay-month totals per category, built once.
    let monthTotals: [Int64: [Int: [Int: Int]]]
    /// The transfer links `budgetTransactions` was built with (an account filter's actuals
    /// rebuild it for the selected accounts).
    let transferLinks: [TransferLink]
    /// The Budget account filter (spec 2026-10-15 §4): when set, the net-worth figures
    /// (`netWorthSeries`, `netWorthActuals`, `yearEndNetWorth`, `budgetNetWorthMonths`) cover
    /// only its accounts, projected with only their planned items. Flows are unaffected.
    public var accountFilter: PlanAccountFilter?

    /// The accounts the net-worth figures cover: `accountFilter`'s, else every account — only
    /// those that count toward net worth (`Account.includeInNetWorth`).
    var netWorthAccounts: [Account] {
        guard let filter = accountFilter else { return accounts.countedInNetWorth }
        return accounts.filter { $0.includeInNetWorth && ($0.id.map(filter.accountIds.contains) ?? false) }
    }

    /// `accountFilter` for the net-worth figures: its accounts that count toward net worth (an
    /// excluded account's planned legs then cross the selection's boundary). Nil = All accounts.
    var netWorthFilter: PlanAccountFilter? {
        guard let filter = accountFilter else { return nil }
        let excluded = accounts.excludedFromNetWorthIds
        guard !excluded.isDisjoint(with: filter.accountIds) else { return filter }
        return PlanAccountFilter(accountIds: filter.accountIds.subtracting(excluded), itemAccounts: filter.itemAccounts)
    }

    public init(today: Date, accounts: [Account], snapshots: [BalanceSnapshot], transactions: [Transaction], categories: [Category], categoryGroups: [CategoryGroup], forecastEntries: [ForecastEntry], forecastGroups: [ForecastGroup], exceptions: [PlannedOccurrenceException], importBatches: [ImportBatch], rate: ExchangeRateSetting, manualCloses: [PayMonthClose] = [], transferLinks: [TransferLink] = [], publishedCloses: [Date] = []) {
        let payCalendar = PayCalendar.forData(transactions: transactions, categories: categories, manualCloses: manualCloses, today: today,
                                              publishedCloses: publishedCloses)
        self.init(today: today, accounts: accounts, snapshots: snapshots, transactions: transactions, categories: categories, categoryGroups: categoryGroups, forecastEntries: forecastEntries, forecastGroups: forecastGroups, exceptions: exceptions, importBatches: importBatches, rate: rate, payCalendar: payCalendar, transferLinks: transferLinks)
    }

    /// With a pay calendar the caller already built (the scenario comparison reuses the
    /// dashboard's calculators with each plan's entries over one shared calendar).
    /// `itemAccounts`: the planned items' accounts when the caller already has them (built here
    /// otherwise, only when an account is left out of net worth: `netWorthEntries`).
    public init(today: Date, accounts: [Account], snapshots: [BalanceSnapshot], transactions: [Transaction], categories: [Category], categoryGroups: [CategoryGroup], forecastEntries: [ForecastEntry], forecastGroups: [ForecastGroup], exceptions: [PlannedOccurrenceException], importBatches: [ImportBatch], rate: ExchangeRateSetting, payCalendar: PayCalendar, transferLinks: [TransferLink] = [], itemAccounts: PlannedItemAccounts? = nil) {
        self.today = today
        self.accounts = accounts
        self.snapshots = snapshots
        self.transactions = transactions
        let conversion = CurrencyConversion(accounts: accounts, rate: rate)
        self.conversion = conversion
        let nativeBudgetTransactions = TransferLinks.budgetFacing(transactions, links: transferLinks)
        let budgetTransactions = conversion.toGBP(nativeBudgetTransactions)
        self.budgetTransactions = budgetTransactions
        self.categories = categories.markingNetWorthExclusions(accounts: accounts)
        self.categoryGroups = categoryGroups
        self.forecastEntries = forecastEntries
        let excluded = accounts.excludedFromNetWorthIds
        if excluded.isEmpty {
            self.netWorthEntries = forecastEntries
        } else {
            let items = itemAccounts ?? PlannedItemAccounts(categories: categories, budgetTransactions: nativeBudgetTransactions, calendar: payCalendar, mainAccountId: accounts.mainAccountId)
            self.netWorthEntries = ForecastCalculator.netWorthEntries(forecastEntries, categories: categories, excludedAccountIds: excluded, itemAccounts: items)
        }
        self.forecastGroups = forecastGroups
        self.exceptions = exceptions
        self.importBatches = importBatches
        self.rate = rate
        self.dataThrough = Transaction.importedDataThrough(transactions)
        self.payCalendar = payCalendar
        self.monthTotals = PayMonthTotals.lookup(transactions: budgetTransactions, calendar: payCalendar)
        self.transferLinks = transferLinks
    }

    /// `today`, but never earlier than the data (a clock behind the data counts as "today = D").
    var effectiveToday: Date { dataThrough.map { max(today, $0) } ?? today }
}

public struct DataFreshness: Equatable, Sendable {
    public enum Status: Equatable, Sendable {
        case noData
        case upToDate
        /// More than 31 days between the latest transaction and today. `months` is whole
        /// elapsed calendar months (0 when under a month — show `days` then).
        case behind(months: Int, days: Int)
    }
    public let status: Status
    public let lastImportAt: Date?
    public let lastImportFileName: String?
    public let dataThrough: Date?
}

public struct AttentionItems: Equatable, Sendable {
    public let uncategorizedCount: Int
    public let staleBalanceCount: Int
    public let oldestStaleSnapshotDate: Date?
    /// No reserved category has a confirmed allowance for the current month, so unplanned
    /// spending isn't being projected.
    public let missingReserveAllowance: Bool
}

public struct AccountSummary: Equatable, Identifiable {
    public let id: Int64
    /// The account's `displayName` (alias, else name).
    public let name: String
    public let kind: AccountKind
    public let currency: Currency
    public let nativeBalanceMinorUnits: Int
    public let gbpBalanceMinorUnits: Int
}

public struct UpcomingBill: Equatable, Identifiable, Sendable {
    /// The planned occurrence it is (`PlannedOccurrence.id`): unique even when two bills share
    /// category, day and amount.
    public let occurrenceId: String
    public let date: Date
    public let categoryName: String
    /// Signed (negative = money out), per occurrence.
    public let amountMinorUnits: Int
    public var id: String { "\(categoryName)-\(date.timeIntervalSince1970)-\(amountMinorUnits)" }
}

extension DashboardInput {
    /// Nothing synced yet: no account and no transaction. Home shows its empty state then, and the widget gets no snapshot.
    public var isEmpty: Bool { accounts.isEmpty && transactions.isEmpty }
}
