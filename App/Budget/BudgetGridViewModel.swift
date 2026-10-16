// App/Budget/BudgetGridViewModel.swift
import Foundation
import BudgetCore
import struct BudgetCore.Category
import GRDB

@MainActor
final class BudgetGridViewModel: ObservableObject {
    @Published var categories: [Category] = [] {
        didSet { itemAccountsCache = nil; netWorthCategoriesCache = nil; clearPlanCaches(); clearNetWorthCaches() }
    }
    @Published var categoryGroups: [CategoryGroup] = []
    /// Every transaction: balances and net worth. The plan's actuals use `budgetTransactions`.
    @Published var transactions: [Transaction] = [] {
        didSet { rebuildPayMonths(); clearNetWorthCaches() }
    }
    /// Transfer links between the user's accounts (spec §6); loaded before `transactions`.
    private(set) var transferLinks: [TransferLink] = []
    /// `transactions` counting each linked transfer once, as sent (`TransferLinks.budgetFacing`),
    /// limited to `accountFilter`'s accounts when set: cells, notes and the side panel. Rebuilt
    /// with the pay calendar and whenever the filter changes.
    private(set) var budgetTransactions: [Transaction] = []
    /// `budgetTransactions` with All accounts, so clearing the filter needs no recomputation.
    private var allAccountsBudgetTransactions: [Transaction] = []
    /// `allAccountsBudgetTransactions` in GBP (`conversion`): what `monthTotals` sums.
    private var allAccountsGBPTransactions: [Transaction] = []
    /// Non-GBP accounts at `exchangeRate` (`CurrencyConversion`): every actual the grid sums
    /// (`monthTotals`, `shownMonthTotals`, the Totals block's transfers) is in GBP, while
    /// `budgetTransactions` (the side panel's list) stays in each account's currency. Rebuilt
    /// with the pay calendar; a change of rate or account currency rebuilds it.
    private(set) var conversion = CurrencyConversion.none
    /// The account panel's selection (spec §7); empty = All accounts. Kept for the app session
    /// (this view model lives as long as the window). Changing it rebuilds the shown actuals once.
    @Published private(set) var accountFilter: Set<Int64> = [] {
        didSet { if accountFilter != oldValue { rebuildShownActuals(); clearPlanCaches(); clearFilteredNetWorthCaches() } }
    }
    /// The toolbar's Show forecast (spec 2026-10-15 §1), remembered across launches: off, cells
    /// show actuals only and net worth stops at today. The caches that depend on it (cells,
    /// the Net Worth row, the year cards) are kept per setting, so toggling clears nothing:
    /// toggling back is a cache hit, and the first switch reuses the planned totals, reserves,
    /// balances and `NetWorthActuals` (none of which depend on it).
    @Published var showForecast: Bool = UserDefaults.standard.object(forKey: BudgetGridViewModel.showForecastKey) as? Bool ?? true {
        didSet {
            guard showForecast != oldValue else { return }
            UserDefaults.standard.set(showForecast, forKey: Self.showForecastKey)
        }
    }
    private static let showForecastKey = "budgetGrid.showForecast"
    /// Whether the account panel is open beside the grid: collapsed until the user opens it,
    /// then remembered across launches (the same defaults store as `@AppStorage`).
    @Published var isAccountPanelOpen: Bool = UserDefaults.standard.object(forKey: BudgetGridViewModel.accountPanelOpenKey) as? Bool ?? false {
        didSet {
            guard isAccountPanelOpen != oldValue else { return }
            UserDefaults.standard.set(isAccountPanelOpen, forKey: Self.accountPanelOpenKey)
        }
    }
    private static let accountPanelOpenKey = "budgetGrid.accountPanelOpen"
    /// Every transaction's count per account id, for the account panel; rebuilt with the pay calendar.
    @Published private(set) var transactionCountByAccount: [Int64: Int] = [:]
    /// Linked transfers' other legs by transaction id, for the side panel and Edit transaction.
    @Published private(set) var transferCounterparts: [Int64: [TransferCounterpart]] = [:]
    @Published var forecastEntries: [ForecastEntry] = [] {
        didSet { clearPlanCaches(); clearNetWorthCaches() }
    }
    @Published var forecastGroups: [ForecastGroup] = [] {
        didSet { clearPlanCaches(); clearNetWorthCaches() }
    }
    @Published var exceptions: [PlannedOccurrenceException] = [] {
        didSet { clearPlanCaches(); clearNetWorthCaches() }
    }
    @Published var accounts: [Account] = [] {
        didSet {
            // The main account decides where items with no account go.
            if accounts.mainAccountId != oldValue.mainAccountId { itemAccountsCache = nil; clearPlanCaches() }
            // Count toward net worth decides which transfers the Totals block counts.
            if accounts.excludedFromNetWorthIds != oldValue.excludedFromNetWorthIds {
                netWorthCategoriesCache = nil
                clearPlanCaches()
                if !isLoading { rebuildShownActuals() }
            }
            clearNetWorthCaches()
            rebuildPayMonthsIfConversionChanged()
            // A deleted account leaves the filter (none left = All accounts).
            let ids = Set(accounts.compactMap(\.id))
            if !accountFilter.isSubset(of: ids) { accountFilter.formIntersection(ids) }
        }
    }
    @Published var balanceSnapshots: [BalanceSnapshot] = [] {
        didSet { clearNetWorthCaches() }
    }
    @Published var exchangeRate: ExchangeRateSetting = ExchangeRateSetting(eurToGbpRate: 0.87, updatedAt: Date()) {
        didSet { clearNetWorthCaches(); rebuildPayMonthsIfConversionChanged() }
    }
    /// The years shown, sorted, never empty once loaded: one year shows its twelve months,
    /// several show each year's total with the change from the previous selected year.
    @Published private(set) var selectedYears: [Int] = []
    /// The single selected year (the month view); nil when several are selected.
    var selectedYear: Int? { selectedYears.count == 1 ? selectedYears[0] : nil }
    @Published var errorMessage: String?
    @Published private(set) var availableYears: [Int] = []
    /// Pay-month boundaries (salaries + manual closes). Rebuilt with `monthTotals` whenever
    /// transactions change (an edited category can add or remove a salary).
    @Published private(set) var payCalendar = PayCalendar(salaryDates: [], manualCloses: [], today: Date())

    /// Runs after an Edit transaction save, so ContentView can refresh the sidebar's
    /// uncategorised count (an edit can add or clear one).
    var onTransactionEdited: (() -> Void)?

    private let dbQueue: DatabaseQueue
    /// Inside `load()`: an account or rate change waits for the `transactions` rebuild.
    private var isLoading = false
    private var manualCloses: [PayMonthClose] = []
    private var lastHorizon: Date?
    /// Confirmed totals per category per pay month (`PayMonthTotals.lookup`) over every account:
    /// the plan's own figures (reserves' unforecast spend, locked occurrences) and the CSV export.
    private var monthTotals: [Int64: [Int: [Int: Int]]] = [:]
    /// The cells' actuals: `monthTotals` again with All accounts, else over `budgetTransactions`
    /// (the selected accounts only).
    private var shownMonthTotals: [Int64: [Int: [Int: Int]]] = [:]
    /// The pay months each category has a transaction with a note in (`PayMonthTotals.noteMonths`),
    /// for the cells' note markers; over `budgetTransactions`, rebuilt with `shownMonthTotals`.
    private var noteMonths: [Int64: Set<PayMonth>] = [:]
    /// Remaining allowance per reserve id, memoised per `MonthRange.index` — the grid asks
    /// for every reserve cell on every render, and each month's answer scans every
    /// category's forecast. Cleared whenever categories, transactions or forecasts change.
    private var reserveRemainingCache: [Int: [Int64: Int]] = [:]
    /// Planned (confirmed-forecast) total per category per calendar month, memoised per
    /// `MonthRange.index` for the same reason. Cleared whenever forecasts or exceptions change.
    private var plannedCache: [Int: [Int64: Int]] = [:]
    /// Each category's Budget cell, memoised per Show forecast, then `MonthRange.index`, then
    /// category id: group, section and Year Total rows (and the pending footnote) combine member
    /// cells on every render. Cleared with `plannedCache`, when categories change, and when the
    /// pay calendar is rebuilt.
    private var cellCache: [Bool: [Int: [Int64: PlanCell]]] = [:]
    /// Each transaction's linked other legs' accounts (`BudgetTotals.counterpartAccounts`),
    /// rebuilt with the pay calendar: which transfers cross the account filter.
    private var counterpartAccounts: [Int64: Set<Int64>] = [:]
    /// The shown transfers whose money counts in the Totals block (`BudgetTotals.countedTransfers`)
    /// and their flows per category per pay month; rebuilt with `shownMonthTotals`.
    private var countedTransferIds: Set<Int64> = []
    private var transferFlows: [Int64: [Int: [Int: BudgetTotals.Flow]]] = [:]
    /// The Totals block's month (Total in, Total out) per Show forecast, then `MonthRange.index`.
    /// Cleared with the plan caches and whenever the shown actuals are rebuilt.
    private var totalsCache: [Bool: [Int: (totalIn: PlanCell, totalOut: PlanCell)]] = [:]
    /// The plan's transfers for the Totals block (`BudgetTotals.plannedTransfers`) per
    /// `MonthRange.index`, for the filter's accounts; cleared with `plannedCache`.
    private var plannedTransfersCache: [Int: (byCategory: [Int64: BudgetTotals.Flow], incomingElsewhere: Int)] = [:]
    /// `unassignedRows` per year * 100 + month (0 = the whole year); cleared with the plan caches.
    private var unassignedRowsCache: [Int: [PlannedRow]] = [:]
    /// `payCalendar.monthClass` per `MonthRange.index`; reset when the calendar is rebuilt.
    private var monthClassCache: [Int: MonthClass] = [:]
    /// Account balance cells per `MonthRange.index` then account id (`nil` = no data yet). Each
    /// look-up scans every snapshot and transaction, so they're memoised like the plan cells.
    /// Cleared whenever accounts, snapshots, transactions or the exchange rate change.
    private var accountBalanceCache: [Int: [Int64: MonthlyAccountBalance?]] = [:]
    /// Year-end net worth per Show forecast, then year, for the year cards
    /// (`DashboardCalculator.yearEndNetWorth`, nil = none); cleared with the net worth caches,
    /// whenever categories, forecasts or the filter change.
    private var yearEndCache: [Bool: [Int: YearEndNetWorth?]] = [:]
    /// The Net Worth row per Show forecast, then year (`DashboardCalculator.budgetNetWorthMonths`),
    /// cleared like `yearEndCache`.
    private var netWorthRowCache: [Bool: [Int: [Int?]]] = [:]
    /// `DashboardCalculator.netWorthActuals(netWorthInput)` (every month-end since the first
    /// data: the costly part of the net-worth figures), worked out once per input and shared by
    /// every year's row and card in both Show forecast states. Cleared like `yearEndCache`.
    private var netWorthActualsCache: NetWorthActuals??
    /// The net-worth figures' input (filter and plan included), built once per change.
    private var netWorthInputCache: DashboardInput?
    /// `categories` marked for the accounts left out of net worth
    /// (`markingNetWorthExclusions`), for the Totals block; rebuilt lazily when either changes.
    private var netWorthCategoriesCache: [Category]?
    /// Planned items' accounts (`PlannedItemAccounts`), rebuilt lazily when categories,
    /// transactions or the main account change.
    private var itemAccountsCache: PlannedItemAccounts?
    /// The account rows' forecast months per Show forecast, then year
    /// (`DashboardCalculator.budgetAccountForecast`, always over All accounts, so the filter
    /// keeps it). Cleared with the net worth caches.
    private var accountForecastCache: [Bool: [Int: BudgetAccountForecast]] = [:]
    /// `netWorthInput` and its `NetWorthActuals` for All accounts, whatever the filter (the
    /// account rows); the same as `netWorthInput` with no filter.
    private var allAccountsInputCache: DashboardInput?
    private var allAccountsActualsCache: NetWorthActuals??
    /// Each account's native balance today (`NetWorthCalculator.balance` with no end date), for
    /// the Year Total with Show forecast off. Cleared with the net worth caches.
    private var todayBalanceCache: [Int64: Int] = [:]

    init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
    }

    func load(horizon: Date) throws {
        lastHorizon = horizon
        // Setting `transactions` rebuilds everything once with the fresh accounts and rate.
        isLoading = true
        defer { isLoading = false }
        manualCloses = try dbQueue.read { db in try PayMonthClose.fetchAll(db) }
        categories = try dbQueue.read { db in try Category.fetchAll(db) }
        categoryGroups = try dbQueue.read { db in try CategoryGroup.fetchAll(db) }
        (transferLinks, transferCounterparts) = try dbQueue.read { db in (try TransferLink.fetchAll(db), try TransferLinks.counterparts(db: db)) }
        // Accounts and the rate before `transactions`: the actuals are converted to GBP with them.
        accounts = try dbQueue.read { db in try Account.fetchAll(db) }.sortedForDisplay()
        exchangeRate = try dbQueue.read { db in try ExchangeRateSetting.currentOrDefault(db: db) }
        transactions = try dbQueue.read { db in try Transaction.fetchAll(db) }
        forecastEntries = try dbQueue.read { db in try ForecastEntry.budget(db) }
        forecastGroups = try dbQueue.read { db in try ForecastGroup.fetchAll(db) }
        exceptions = try dbQueue.read { db in try PlannedOccurrenceException.fetchAll(db) }
        balanceSnapshots = try dbQueue.read { db in try BalanceSnapshot.fetchAll(db) }
        selectDefaultYearIfNeeded()
    }

    /// A new rate or account currency outside `load()` changes every converted actual (a load
    /// rebuilds once, when it sets `transactions`).
    private func rebuildPayMonthsIfConversionChanged() {
        guard !isLoading else { return }
        if CurrencyConversion(accounts: accounts, rate: exchangeRate) != conversion { rebuildPayMonths() }
    }

    /// Rebuilds everything derived from the pay calendar. `load()` sets `manualCloses`,
    /// `categories`, the accounts and the rate before `transactions`, so this runs once per
    /// load with all inputs fresh.
    private func rebuildPayMonths() {
        conversion = CurrencyConversion(accounts: accounts, rate: exchangeRate)
        payCalendar = PayCalendar(salaryDates: PaydaySource.paydayDates(transactions: transactions, categories: categories), manualCloses: manualCloses, today: Date())
        allAccountsBudgetTransactions = TransferLinks.budgetFacing(transactions, links: transferLinks)
        itemAccountsCache = nil
        allAccountsGBPTransactions = conversion.toGBP(allAccountsBudgetTransactions)
        monthTotals = PayMonthTotals.lookup(transactions: allAccountsGBPTransactions, calendar: payCalendar)
        counterpartAccounts = BudgetTotals.counterpartAccounts(transactions: transactions, links: transferLinks)
        transactionCountByAccount = transactions.reduce(into: [:]) { counts, transaction in counts[transaction.accountId, default: 0] += 1 }
        monthClassCache = [:]
        rebuildShownActuals()
        // The current year is always offered (calendar and pay-month year, which differ late in
        // December), so the plan for it shows even before any transaction lands in it.
        let currentYears = [MonthRange.components(of: Date()).year, payCalendar.current.year]
        availableYears = Array(Set(BudgetGridCalculator.yearsWithData(transactions: transactions, calendar: payCalendar) + currentYears)).sorted()
    }

    /// What the cells, note markers and side panel read (`budgetTransactions`,
    /// `shownMonthTotals`, `noteMonths`), for the account filter. Runs once per filter change
    /// or load, never per render; the transfer rule with a filter is `TransferLinks.budgetFacing`'s.
    private func rebuildShownActuals() {
        let shownGBP: [Transaction]
        if accountFilter.isEmpty {
            budgetTransactions = allAccountsBudgetTransactions
            shownGBP = allAccountsGBPTransactions
            shownMonthTotals = monthTotals
        } else {
            budgetTransactions = TransferLinks.budgetFacing(transactions, links: transferLinks, accountIds: accountFilter)
            shownGBP = conversion.toGBP(budgetTransactions)
            shownMonthTotals = PayMonthTotals.lookup(transactions: shownGBP, calendar: payCalendar)
        }
        noteMonths = PayMonthTotals.noteMonths(transactions: budgetTransactions, calendar: payCalendar)
        let counted = BudgetTotals.countedTransfers(shownGBP, categories: netWorthCategories, accountIds: totalsAccountIds, counterpartAccounts: counterpartAccounts)
        countedTransferIds = Set(counted.compactMap(\.id))
        transferFlows = BudgetTotals.transferActuals(counted, calendar: payCalendar)
        reserveRemainingCache = [:]
        cellCache = [:]
        totalsCache = [:]
        unassignedRowsCache = [:]
    }

    // MARK: Account filter

    /// A filter is on: cells show the selected accounts' actuals and the planned items whose
    /// effective account is selected (spec 2026-10-15 §3).
    var isAccountFiltered: Bool { !accountFilter.isEmpty }

    /// Which account each planned item belongs to (explicit, else inferred from its
    /// category's history over every account).
    var itemAccounts: PlannedItemAccounts {
        if let cached = itemAccountsCache { return cached }
        let built = PlannedItemAccounts(categories: categories, budgetTransactions: allAccountsBudgetTransactions, calendar: payCalendar, mainAccountId: accounts.mainAccountId)
        itemAccountsCache = built
        return built
    }

    /// The account filter applied to the plan; nil = All accounts.
    var planFilter: PlanAccountFilter? {
        accountFilter.isEmpty ? nil : PlanAccountFilter(accountIds: accountFilter, itemAccounts: itemAccounts)
    }

    /// The planned item sheets' Account picker.
    var planAccountOptions: PlanAccountOptions {
        PlanAccountOptions(accounts: accounts, itemAccounts: itemAccounts)
    }

    /// The accounts the Accounts rows show: the filter's, else every account.
    var shownAccounts: [Account] {
        accountFilter.isEmpty ? accounts : accounts.filter { $0.id.map(accountFilter.contains) ?? false }
    }

    /// Add planned item's prefilled account: the filter's account when exactly one is ticked.
    var singleFilteredAccountId: Int64? { accountFilter.count == 1 ? accountFilter.first : nil }

    /// Ticks or unticks an account in the panel.
    func toggleAccountFilter(_ accountId: Int64) {
        if accountFilter.contains(accountId) { accountFilter.remove(accountId) } else { accountFilter.insert(accountId) }
    }

    /// "All accounts": clears the selection.
    func showAllAccounts() {
        accountFilter = []
    }

    /// Drag and drop in the account panel: `ids` are the accounts in panel order, moved as
    /// SwiftUI's `onMove` describes. Saves the shared order (`AccountOrdering`) and re-reads
    /// the accounts; on failure sets `errorMessage`.
    func moveAccounts(fromOffsets: IndexSet, toOffset: Int) {
        let ids = accounts.compactMap(\.id)
        do {
            try dbQueue.write { db in try AccountOrdering.move(db: db, ids: ids, fromOffsets: fromOffsets, toOffset: toOffset) }
            accounts = try dbQueue.read { db in try Account.fetchAll(db) }.sortedForDisplay()
        } catch {
            errorMessage = "Couldn't reorder accounts: \(error.localizedDescription)"
        }
    }

    /// Account names by id, for the side panel's per-transaction account.
    var accountNameById: [Int64: String] {
        Dictionary(accounts.compactMap { account in account.id.map { ($0, account.displayName) } }, uniquingKeysWith: { a, _ in a })
    }

    /// The grid's actuals as CSV: one column per pay month of the grid's years that has
    /// started, the same totals the cells show. Reserves are forecast-only, so left out.
    func exportCSV() -> String {
        BudgetGridExporter.export(categories: categories.filter { !$0.isReserved }, years: availableYears, calendar: payCalendar, monthTotals: monthTotals)
    }

    /// The cell's actual: the selected accounts' (all accounts' without a filter) total.
    func payMonthCategoryTotal(_ category: Category, year: Int, month: Int) -> Int {
        category.id.flatMap { shownMonthTotals[$0]?[year]?[month] } ?? 0
    }

    /// The account's balance as of the end of `month`, carried forward from its latest
    /// prior snapshot when there's nothing recorded that exact month. `nil` when the
    /// account has no snapshot at or before that month at all. Uses `MonthRange` (end = the
    /// month's last moment) — the same window `NetWorthCalculator.monthEndNetWorth` sums over,
    /// so the per-account cells always add up to the Net Worth total row even for a snapshot
    /// stamped later than midnight on the month's last day.
    func accountBalance(_ account: Account, year: Int, month: Int) -> MonthlyAccountBalance? {
        let range = MonthRange.of(year: year, month: month)
        guard let id = account.id else {
            return NetWorthCalculator.monthlyBalance(account: account, snapshots: balanceSnapshots, transactions: transactions, rate: exchangeRate, monthStart: range.start, monthEnd: range.end)
        }
        let key = MonthRange.index(year: year, month: month)
        if let cached = accountBalanceCache[key]?[id] { return cached }
        let balance = NetWorthCalculator.monthlyBalance(account: account, snapshots: balanceSnapshots, transactions: transactions, rate: exchangeRate, monthStart: range.start, monthEnd: range.end)
        accountBalanceCache[key, default: [:]][id] = .some(balance)
        return balance
    }

    private func clearNetWorthCaches() {
        accountBalanceCache = [:]
        accountForecastCache = [:]
        todayBalanceCache = [:]
        allAccountsInputCache = nil
        allAccountsActualsCache = nil
        clearFilteredNetWorthCaches()
    }

    /// The net-worth figures that follow the account filter.
    private func clearFilteredNetWorthCaches() {
        yearEndCache = [:]
        netWorthRowCache = [:]
        netWorthInputCache = nil
        netWorthActualsCache = nil
    }

    /// The plan's caches: planned totals, cells and reserves.
    private func clearPlanCaches() {
        reserveRemainingCache = [:]
        plannedCache = [:]
        cellCache = [:]
        totalsCache = [:]
        plannedTransfersCache = [:]
        unassignedRowsCache = [:]
    }

    /// The net-worth figures' input: every account and transaction, the budget's plan, and
    /// the account filter (spec 2026-10-15 §4).
    private var netWorthInput: DashboardInput {
        if let cached = netWorthInputCache { return cached }
        var input = DashboardInput(today: Date(), accounts: accounts, snapshots: balanceSnapshots, transactions: transactions, categories: categories, categoryGroups: categoryGroups,
                                   forecastEntries: forecastEntries, forecastGroups: forecastGroups, exceptions: exceptions, importBatches: [], rate: exchangeRate, payCalendar: payCalendar,
                                   transferLinks: transferLinks)
        input.accountFilter = planFilter
        netWorthInputCache = input
        return input
    }

    /// `netWorthInput` with All accounts (the account rows).
    private var allAccountsInput: DashboardInput {
        if accountFilter.isEmpty { return netWorthInput }
        if let cached = allAccountsInputCache { return cached }
        var input = netWorthInput
        input.accountFilter = nil
        allAccountsInputCache = input
        return input
    }

    /// `allAccountsInput`'s `NetWorthActuals`, memoised (shared with the Net Worth row with no filter).
    private var allAccountsActuals: NetWorthActuals? {
        if accountFilter.isEmpty { return netWorthActuals }
        if let cached = allAccountsActualsCache { return cached }
        let actuals = DashboardCalculator.netWorthActuals(allAccountsInput)
        allAccountsActualsCache = .some(actuals)
        return actuals
    }

    /// The account rows' forecast months for `year` (`DashboardCalculator.budgetAccountForecast`),
    /// memoised per Show forecast and year.
    private func accountForecast(year: Int) -> BudgetAccountForecast {
        if let cached = accountForecastCache[showForecast]?[year] { return cached }
        let forecast = DashboardCalculator.budgetAccountForecast(allAccountsInput, actuals: allAccountsActuals, itemAccounts: itemAccounts, year: year, includeForecast: showForecast)
        accountForecastCache[showForecast, default: [:]][year] = forecast
        return forecast
    }

    /// An account row's month (account-forecast spec §2): the actual month-end balance to
    /// today; with Show forecast the walk-start month and later months forecast (today's
    /// balance plus the account's planned legs), else "—" after today.
    enum AccountCell {
        case actual(MonthlyAccountBalance?)
        case forecast(AccountForecastBalance, currency: Currency)
        /// Today's actual balance (the current year's Year Total with Show forecast off).
        case today(nativeMinorUnits: Int, currency: Currency)
        case blank
    }

    /// An account row's Year Total, like the Net Worth row's (`yearEndNetWorth`): December's
    /// cell, except this year with Show forecast off, which is today's actual balance.
    func accountYearEnd(_ account: Account, year: Int) -> AccountCell {
        guard !showForecast, year == MonthRange.components(of: Date()).year, let id = account.id else { return accountCell(account, year: year, month: 12) }
        if let cached = todayBalanceCache[id] { return .today(nativeMinorUnits: cached, currency: account.currency) }
        guard let native = NetWorthCalculator.balance(accountId: id, at: nil, snapshots: balanceSnapshots, transactions: transactions)?.native else { return .actual(nil) }
        todayBalanceCache[id] = native
        return .today(nativeMinorUnits: native, currency: account.currency)
    }

    func accountCell(_ account: Account, year: Int, month: Int) -> AccountCell {
        let forecast = accountForecast(year: year)
        if let id = account.id, let balance = forecast.balance(accountId: id, month: month) { return .forecast(balance, currency: account.currency) }
        if forecast.blankMonths.contains(month) || forecast.isForecast(month: month) { return .blank }
        return .actual(accountBalance(account, year: year, month: month))
    }

    /// The "Not assigned to an account" row's month: planned items with no effective account,
    /// accumulated over the forecast months (GBP); nil elsewhere.
    func unassignedForecast(year: Int, month: Int) -> Int? {
        accountForecast(year: year).unassigned[month]
    }

    /// Whether the "Not assigned to an account" row shows: All accounts, and something
    /// unassigned in one of the shown years.
    var showsUnassignedRow: Bool {
        accountFilter.isEmpty && selectedYears.contains { accountForecast(year: $0).hasUnassigned }
    }

    /// `netWorthInput`'s `NetWorthActuals` (nil = no balance data yet), memoised.
    private var netWorthActuals: NetWorthActuals? {
        if let cached = netWorthActualsCache { return cached }
        let actuals = DashboardCalculator.netWorthActuals(netWorthInput)
        netWorthActualsCache = .some(actuals)
        return actuals
    }

    /// The Net Worth row's month (`DashboardCalculator.budgetNetWorthMonths`, net-worth-forecast-fix
    /// §3): the actual month-end net worth to today, then with Show forecast this month's
    /// remaining plan and the projection, else nil ("—"). The filter's accounts only. Memoised per year.
    func netWorthTotal(year: Int, month: Int) -> Int? {
        if netWorthRowCache[showForecast]?[year] == nil {
            netWorthRowCache[showForecast, default: [:]][year] = DashboardCalculator.budgetNetWorthMonths(netWorthInput, actuals: netWorthActuals, year: year, includeForecast: showForecast)
        }
        return netWorthRowCache[showForecast]?[year]?[month - 1] ?? nil
    }

    /// Net worth at the end of `year` for the year cards: real for past years, the Dashboard's
    /// forecast to December for this year — or, with Show forecast off, today's actual net
    /// worth (`DashboardCalculator.yearEndNetWorth`). The filter's accounts only.
    func yearEndNetWorth(_ year: Int) -> YearEndNetWorth? {
        if let cached = yearEndCache[showForecast]?[year] { return cached }
        let value = DashboardCalculator.yearEndNetWorth(netWorthInput, actuals: netWorthActuals, year: year, includeForecast: showForecast)
        yearEndCache[showForecast, default: [:]][year] = .some(value)
        return value
    }

    /// `year`'s year-end net worth less the previous year's, in minor units (the year card's
    /// "↑ £24,953"). Nil when either is missing.
    func yearEndChange(_ year: Int) -> Int? {
        guard let value = yearEndNetWorth(year), let previous = yearEndNetWorth(year - 1) else { return nil }
        return value.valueMinorUnits - previous.valueMinorUnits
    }

    /// `year`'s year-end net worth against the previous year's, as a fraction of the previous
    /// one's magnitude. Nil when either is missing or the previous is zero.
    func yearEndChangePercent(_ year: Int) -> Double? {
        guard let value = yearEndNetWorth(year), let previous = yearEndNetWorth(year - 1), previous.valueMinorUnits != 0 else { return nil }
        return Double(value.valueMinorUnits - previous.valueMinorUnits) / Double(abs(previous.valueMinorUnits))
    }

    /// Drops selected years that no longer have data, falling back to the most recent year
    /// with data whenever nothing is left (e.g. right after the first `load()`).
    private func selectDefaultYearIfNeeded() {
        let kept = selectedYears.filter(availableYears.contains)
        if !kept.isEmpty {
            if kept != selectedYears { selectedYears = kept }
        } else if let latest = availableYears.last {
            selectedYears = [latest]
        }
    }

    // MARK: Show in Budget

    /// A category's pay-month cell whose side panel the grid opens when it next shows (or
    /// right away when on screen): Search's Show in Budget.
    struct RevealRequest: Equatable {
        let categoryId: Int64
        let year: Int
        let month: Int
    }

    @Published var revealRequest: RevealRequest?

    /// Show in Budget: selects the pay year `date` falls in and asks the grid to open the
    /// category's cell for its pay month. An account filter that hides `accountId` is
    /// cleared, so the panel lists the transaction. Call after `load` (the pay calendar).
    func reveal(categoryId: Int64, date: Date, accountId: Int64) {
        let payMonth = payCalendar.month(containing: date)
        if !accountFilter.isEmpty, !accountFilter.contains(accountId) { accountFilter = [] }
        if selectedYears != [payMonth.year] { selectedYears = [payMonth.year] }
        revealRequest = RevealRequest(categoryId: categoryId, year: payMonth.year, month: payMonth.month)
    }

    /// A plain click on a year: show just that year.
    func selectYear(_ year: Int) {
        selectedYears = [year]
    }

    /// A ⌘-click on a year: add it to, or remove it from, the selection (the last selected
    /// year stays selected).
    func toggleYear(_ year: Int) {
        if let index = selectedYears.firstIndex(of: year) {
            guard selectedYears.count > 1 else { return }
            selectedYears.remove(at: index)
        } else {
            selectedYears = (selectedYears + [year]).sorted()
        }
    }

    /// The confirmed, budget-facing transactions of any of `categoryIds` in `start...end` (a
    /// cell's side panel: one category, or a group's or section's members) — what the cell sums.
    func transactions(forCategoryIds categoryIds: Set<Int64>, from startDate: Date, to endDate: Date) -> [Transaction] {
        budgetTransactions.filter { $0.categoryId.map(categoryIds.contains) == true && $0.status == .confirmed && $0.date >= startDate && $0.date <= endDate }
    }

    /// Whether any of `categories` has a transaction with a note in the pay month (a cell's
    /// note marker; groups and sections pass their members).
    func hasNote(_ categories: [Category], year: Int, month: Int) -> Bool {
        let payMonth = PayMonth(year: year, month: month)
        return categories.contains { category in category.id.map { noteMonths[$0]?.contains(payMonth) == true } ?? false }
    }

    /// Whether any of `categories` has a transaction with a note in any of the year's pay
    /// months (a Year Total cell's marker).
    func hasNote(_ categories: [Category], year: Int) -> Bool {
        (1...12).contains { hasNote(categories, year: year, month: $0) }
    }

    /// Category names by id, for the side panel's per-transaction category.
    var categoryNameById: [Int64: String] {
        Dictionary(categories.compactMap { category in category.id.map { ($0, category.name) } }, uniquingKeysWith: { a, _ in a })
    }

    /// Categories by id, for the side panel's per-transaction category badge and name.
    var categoryById: [Int64: Category] {
        Dictionary(categories.compactMap { category in category.id.map { ($0, category) } }, uniquingKeysWith: { a, _ in a })
    }

    var reserves: [Category] { categories.filter(\.isReserved).sorted { $0.name < $1.name } }

    /// Reserves are forecast-only (`ReservedCategories.monthAllowances`): 0 in a closed pay
    /// month (its leftover is released), what's left after the pay month's unforecast spend
    /// in an open month that has started, the full allowance in a future month. Allowances
    /// are the confirmed forecast for the calendar month of that name.
    func reserveTotal(_ reserve: Category, year: Int, month: Int) -> Int {
        guard let id = reserve.id else { return 0 }
        let key = MonthRange.index(year: year, month: month)
        if let cached = reserveRemainingCache[key] { return cached[id] ?? 0 }
        // The filter's planned totals and actuals (all accounts' without one).
        let planned = plannedTotals(year: year, month: month)
        let allowances: [(id: Int64, name: String, allowance: Int)] = reserves.compactMap { reserve in
            reserve.id.map { ($0, reserve.name, planned[$0] ?? 0) }
        }
        let remaining = ReservedCategories.monthAllowances(allowances, monthClass: monthClass(year: year, month: month)) {
            ReservedCategories.unforecastSpend(year: year, month: month, categories: categories, monthTotals: shownMonthTotals, plannedTotals: planned)
        }
        reserveRemainingCache[key] = remaining
        return remaining[id] ?? 0
    }

    /// The pay month's range (start of its first day ... last moment of its close day).
    func dateRange(forYear year: Int, month: Int) -> (start: Date, end: Date) {
        payCalendar.range(of: PayMonth(year: year, month: month))
    }

    /// January's pay month start ... December's pay month end, matching the Year Total column.
    func dateRange(forYear year: Int) -> (start: Date, end: Date) {
        (payCalendar.range(of: PayMonth(year: year, month: 1)).start, payCalendar.range(of: PayMonth(year: year, month: 12)).end)
    }

    // MARK: Closing months

    /// Closes `month` on the picked day (`date` is already 00:00 UTC on that day — see
    /// `PayCalendar.utcDay`), then reloads. On failure sets `errorMessage` and returns false.
    @discardableResult
    func closeMonth(_ month: PayMonth, on date: Date) -> Bool {
        errorMessage = nil
        do {
            try dbQueue.write { db in try PayCalendar.close(db: db, month: month, on: date, today: Date()) }
        } catch PayCalendarError.invalidCloseDate {
            errorMessage = PayMonthFormat.invalidCloseDateMessage(month, calendar: payCalendar)
            return false
        } catch {
            errorMessage = "Couldn't close \(PayMonthFormat.name(month)): \(error.localizedDescription)"
            return false
        }
        return reload()
    }

    /// Removes `month`'s manual close, then reloads. On failure sets `errorMessage`.
    @discardableResult
    func reopenMonth(_ month: PayMonth) -> Bool {
        errorMessage = nil
        do {
            try dbQueue.write { db in try PayCalendar.reopen(db: db, month: month) }
        } catch {
            errorMessage = "Couldn't reopen \(PayMonthFormat.name(month)): \(error.localizedDescription)"
            return false
        }
        return reload()
    }

    /// Re-reads after a close/reopen. The write already succeeded, so a failed re-read only
    /// leaves the grid stale: say so (returning false keeps the sheet up to show it).
    private func reload() -> Bool {
        do {
            try load(horizon: lastHorizon ?? Date())
            return true
        } catch {
            errorMessage = "Saved, but couldn't reload the grid: \(error.localizedDescription)"
            return false
        }
    }

    // MARK: The plan

    typealias PlanCell = (value: Int, pending: Int, state: PendingState)

    /// The planned totals per category in the calendar month named `year`/`month`, for the
    /// filter's accounts (`ForecastCalculator.confirmedTotalsByCategory(…filter:)`). Memoised.
    private func plannedTotals(year: Int, month: Int) -> [Int64: Int] {
        let key = MonthRange.index(year: year, month: month)
        if let cached = plannedCache[key] { return cached }
        let range = MonthRange.of(year: year, month: month)
        let totals = ForecastCalculator.confirmedTotalsByCategory(period: PayPeriod(startDate: range.start, endDate: range.end, type: .projected),
                                                                  entries: forecastEntries, groups: forecastGroups, exceptions: exceptions, filter: planFilter)
        plannedCache[key] = totals
        return totals
    }

    /// The pay month's class (`payCalendar.monthClass`), cached until the calendar is rebuilt.
    private func monthClass(year: Int, month: Int) -> MonthClass {
        let key = MonthRange.index(year: year, month: month)
        if let cached = monthClassCache[key] { return cached }
        let monthClass = payCalendar.monthClass(PayMonth(year: year, month: month))
        monthClassCache[key] = monthClass
        return monthClass
    }

    /// A category's Budget cell: the pay month's actual plus whatever the calendar month's plan
    /// still expects (`PlanStatus.cell`), both for the filter's accounts; closed months show the
    /// actual alone, as does every month with Show forecast off. Memoised.
    func cell(_ category: Category, year: Int, month: Int) -> PlanCell {
        guard let id = category.id else { return (0, 0, .none) }
        let key = MonthRange.index(year: year, month: month)
        if let cached = cellCache[showForecast]?[key]?[id] { return cached }
        let actual = payMonthCategoryTotal(category, year: year, month: month)
        let cell: PlanCell = !showForecast ? (actual, 0, .none)
            : PlanStatus.cell(actual: actual,
                              planned: plannedTotals(year: year, month: month)[id] ?? 0,
                              categoryType: category.type,
                              monthClass: monthClass(year: year, month: month))
        cellCache[showForecast, default: [:]][key, default: [:]][id] = cell
        return cell
    }

    /// A group or section row: its members' cells combined (`PlanStatus.combine`).
    func cell(_ categories: [Category], year: Int, month: Int) -> PlanCell {
        PlanStatus.combine(categories.map { cell($0, year: year, month: month) })
    }

    /// The Year Total cell: the twelve displayed values summed, pending summed (for the
    /// "Includes £x not yet confirmed" footnote), state combined.
    func yearCell(_ categories: [Category], year: Int) -> PlanCell {
        PlanStatus.combine((1...12).map { cell(categories, year: year, month: $0) })
    }

    /// A reserve row's (or the Total reserved row's) Year Total: its twelve month cells combined.
    func reserveYearCell(_ reserves: [Category], year: Int) -> PlanCell {
        PlanStatus.combine((1...12).map { reserveCell(reserves, year: year, month: $0) })
    }

    /// A reserve's month as a cell: what's left of its allowance counts as expected while the
    /// month is open (reserves never hold transactions). Empty with Show forecast off: a
    /// reserve is planned money only.
    func reserveCell(_ reserves: [Category], year: Int, month: Int) -> PlanCell {
        guard showForecast else { return (0, 0, .none) }
        let value = reserves.reduce(0) { $0 + reserveTotal($1, year: year, month: month) }
        return (value, value, value == 0 ? .none : .allExpected)
    }

    // MARK: Totals (budget-totals spec §1)

    /// `categories` as the Totals block reads them: transfers to and from accounts left out
    /// of net worth count (`Category.isTiedToAccountOutsideNetWorth`).
    private var netWorthCategories: [Category] {
        if let cached = netWorthCategoriesCache { return cached }
        let marked = categories.markingNetWorthExclusions(accounts: accounts)
        netWorthCategoriesCache = marked
        return marked
    }

    /// The account filter as the Totals block takes it (nil = All accounts).
    private var totalsAccountIds: Set<Int64>? { accountFilter.isEmpty ? nil : accountFilter }

    /// The month's Total in and Total out (`BudgetTotals.month`) over the cells' own figures:
    /// the shown actuals, the filter's planned totals and the Total reserved cell. Memoised per
    /// Show forecast and month.
    private func totals(year: Int, month: Int) -> (totalIn: PlanCell, totalOut: PlanCell) {
        let key = MonthRange.index(year: year, month: month)
        if let cached = totalsCache[showForecast]?[key] { return cached }
        var actuals: [Int64: Int] = [:]
        var flows: [Int64: BudgetTotals.Flow] = [:]
        for category in categories {
            guard let id = category.id else { continue }
            if let actual = shownMonthTotals[id]?[year]?[month] { actuals[id] = actual }
            if let flow = transferFlows[id]?[year]?[month] { flows[id] = flow }
        }
        let plannedTransfers = showForecast ? self.plannedTransfers(year: year, month: month) : (byCategory: [:], incomingElsewhere: 0)
        let result = BudgetTotals.month(categories: netWorthCategories, actuals: actuals, transferActuals: flows,
                                        planned: showForecast ? plannedTotals(year: year, month: month) : [:],
                                        plannedTransfers: plannedTransfers.byCategory, plannedIncomingElsewhere: plannedTransfers.incomingElsewhere,
                                        reserves: reserveCell(reserves, year: year, month: month),
                                        monthClass: monthClass(year: year, month: month), includeForecast: showForecast, accountIds: totalsAccountIds)
        totalsCache[showForecast, default: [:]][key] = result
        return result
    }

    /// The calendar month's planned transfer money for the filter's accounts, memoised.
    private func plannedTransfers(year: Int, month: Int) -> (byCategory: [Int64: BudgetTotals.Flow], incomingElsewhere: Int) {
        let key = MonthRange.index(year: year, month: month)
        if let cached = plannedTransfersCache[key] { return cached }
        let range = MonthRange.of(year: year, month: month)
        let result = BudgetTotals.plannedTransfers(period: PayPeriod(startDate: range.start, endDate: range.end, type: .projected), categories: netWorthCategories,
                                                   entries: forecastEntries, groups: forecastGroups, exceptions: exceptions, filter: planFilter)
        plannedTransfersCache[key] = result
        return result
    }

    /// A Totals row's month cell.
    func totalsCell(_ row: BudgetTotals.Row, year: Int, month: Int) -> PlanCell {
        let month = totals(year: year, month: month)
        return BudgetTotals.cell(row, totalIn: month.totalIn, totalOut: month.totalOut)
    }

    /// A Totals row's Year Total: its twelve month cells combined.
    func totalsYearCell(_ row: BudgetTotals.Row, year: Int) -> PlanCell {
        PlanStatus.combine((1...12).map { totalsCell(row, year: year, month: $0) })
    }

    /// The shown transactions in `start...end` a Totals row sums (its side panel).
    func totalsTransactions(_ row: BudgetTotals.Row, from startDate: Date, to endDate: Date) -> [Transaction] {
        let byId = categoryById
        return budgetTransactions.filter { transaction in
            guard transaction.status == .confirmed, transaction.date >= startDate, transaction.date <= endDate,
                  let category = transaction.categoryId.flatMap({ byId[$0] }) else { return false }
            return row.includes(category, amount: transaction.amountMinorUnits, countedTransfer: transaction.id.map(countedTransferIds.contains) ?? false)
        }
    }

    /// The planned occurrences in the calendar month a Totals row includes (as the filter's
    /// accounts see them), by date. Reserves are left out: their cells show what's left of the
    /// allowance, which the panel shows as one line (`totalsReserved`).
    func totalsOccurrences(_ row: BudgetTotals.Row, year: Int, month: Int) -> [PlannedRow] {
        netWorthCategories.filter { $0.type != .adjustment && !$0.isReserved }
            .flatMap { category in
                let counted = BudgetTotals.countsPlannedTransfer(category, accountIds: totalsAccountIds)
                return occurrences(category: category, year: year, month: month).filter {
                    // An incoming leg filed under a category that doesn't count still arrives
                    // from outside the selection (`BudgetTotals.plannedTransfers`).
                    row.includes(category, amount: $0.occurrence.amountMinorUnits, countedTransfer: counted || $0.source != nil)
                }
            }
            .sorted { $0.occurrence.date < $1.occurrence.date }
    }

    /// The Total reserved cell's month as a Totals panel line (what's left of the allowances;
    /// 0 for none, and for Total in).
    func totalsReserved(_ row: BudgetTotals.Row, year: Int, month: Int) -> Int {
        row == .totalIn ? 0 : reserveCell(reserves, year: year, month: month).value
    }

    // MARK: Unassigned planned items (budget-totals spec §2)

    /// The planned occurrences with no effective account (`ForecastCalculator.unassignedOccurrences`)
    /// in the calendar month `year`/`month`, or the whole calendar year when `month` is nil.
    func unassignedRows(year: Int, month: Int?) -> [PlannedRow] {
        let key = year * 100 + (month ?? 0)
        if let cached = unassignedRowsCache[key] { return cached }
        let rows = buildUnassignedRows(year: year, month: month)
        unassignedRowsCache[key] = rows
        return rows
    }

    private func buildUnassignedRows(year: Int, month: Int?) -> [PlannedRow] {
        let start = MonthRange.of(year: year, month: month ?? 1).start
        let end = MonthRange.of(year: year, month: month ?? 12).end
        let plan = plannedEntries
        let byId = Dictionary(plan.compactMap { e in e.id.map { ($0, e) } }, uniquingKeysWith: { a, _ in a })
        return ForecastCalculator.unassignedOccurrences(period: PayPeriod(startDate: start, endDate: end, type: .projected), categories: categories,
                                                        entries: forecastEntries, groups: forecastGroups, exceptions: exceptions, itemAccounts: itemAccounts)
            .compactMap { occurrence in
                guard let entry = byId[occurrence.entryId] else { return nil }
                let locked = PlannedItemEditing.isLocked(entry: entry, occurrence: occurrence, calendar: payCalendar, monthTotals: monthTotals,
                                                         entries: forecastEntries, groups: forecastGroups, exceptions: exceptions, categories: categories)
                return PlannedRow(occurrence: occurrence, isConfirmed: locked, entry: entry, accountLabel: nil)
            }
    }

    /// Whether Assign to ▾ offers `accountId` for `row`: not a transfer into that same account
    /// (`PlannedItemAccounts.canAssign`).
    func canAssign(_ row: PlannedRow, to accountId: Int64) -> Bool {
        itemAccounts.canAssign(categoryId: row.occurrence.categoryId, to: accountId)
    }

    /// Assign to ▾ / Assign all to ▾: every series behind `rows` gets `accountId`, in one write
    /// (`PlannedItems.assignAccount`), then the grid reloads. Rows that can't take the account
    /// (`canAssign`) are skipped; the caller says how many.
    func assignAccount(_ rows: [PlannedRow], to accountId: Int64) -> SaveOutcome {
        let entryIds = rows.filter { canAssign($0, to: accountId) }.compactMap(\.entry.id)
        guard !entryIds.isEmpty else { return .saved }
        return perform { db in try PlannedItems.assignAccount(db: db, entryIds: entryIds, accountId: accountId) }
    }

    /// Every planned item (`ForecastCalculator.confirmedEntries`): the add sheet's "Already
    /// planned" lines and the drill-down's occurrences.
    var plannedEntries: [ForecastEntry] {
        ForecastCalculator.confirmedEntries(entries: forecastEntries, groups: forecastGroups)
    }

    /// The planned occurrences filed under `category` (after any re-file) whose date falls in
    /// the calendar month `year`/`month` as the filter's accounts see them, each with whether
    /// it's confirmed, its series and its account.
    func occurrences(category: Category, year: Int, month: Int) -> [PlannedRow] {
        guard let id = category.id else { return [] }
        return PlannedRow.rows(categoryId: id, year: year, month: month, plan: plannedEntries, exceptions: exceptions,
                               filter: planFilter, accounts: accounts.isEmpty ? nil : planAccountOptions) { entry, occurrence in
            PlannedItemEditing.isLocked(entry: entry, occurrence: occurrence, calendar: payCalendar, monthTotals: monthTotals,
                                        entries: forecastEntries, groups: forecastGroups, exceptions: exceptions, categories: categories)
        }
    }

    /// `editOccurrence` / `editFollowing`, for the drill-down's shared Edit… / Remove….
    var planEditActions: PlanEditActions {
        PlanEditActions(editOccurrence: { [unowned self] in editOccurrence($0, change: $1) },
                        editFollowing: { [unowned self] in editFollowing($0, change: $1) })
    }

    // MARK: Editing the plan

    /// Only this occurrence (`PlannedItemEditing.editOccurrence`).
    func editOccurrence(_ occurrence: PlannedOccurrence, change: OccurrenceChange) -> SaveOutcome {
        perform { [payCalendar] db in
            try PlannedItemEditing.editOccurrence(db: db, entryId: occurrence.entryId, originalDate: occurrence.originalDate, change: change, calendar: payCalendar)
        }
    }

    /// This and all following (`PlannedItemEditing.editFollowing`).
    func editFollowing(_ occurrence: PlannedOccurrence, change: OccurrenceChange) -> SaveOutcome {
        perform { [payCalendar] db in
            try PlannedItemEditing.editFollowing(db: db, entryId: occurrence.entryId, originalDate: occurrence.originalDate, change: change, calendar: payCalendar)
        }
    }

    /// A new planned item from a section header (`PlannedItems.add`).
    func addPlannedItem(categoryId: Int64, amountMinorUnits: Int, frequency: ForecastFrequency, interval: Int, startDate: Date, endDate: Date?, accountId: Int64?) -> SaveOutcome {
        perform { db in
            _ = try PlannedItems.add(db: db, categoryId: categoryId, amountMinorUnits: amountMinorUnits, frequency: frequency, interval: interval, startDate: startDate, endDate: endDate, accountId: accountId)
        }
    }

    /// A new planned item for a category created with it ("+ New category…"), in one write so
    /// a failed save leaves no orphaned category (`PlannedItems.add(db:newCategoryName:…)`).
    func addPlannedItem(newCategoryName: String, type: CategoryType, amountMinorUnits: Int, frequency: ForecastFrequency, interval: Int, startDate: Date, endDate: Date?, accountId: Int64?) -> SaveOutcome {
        perform { db in
            _ = try PlannedItems.add(db: db, newCategoryName: newCategoryName, type: type, amountMinorUnits: amountMinorUnits, frequency: frequency, interval: interval, startDate: startDate, endDate: endDate, accountId: accountId)
        }
    }

    /// A new reserve with its first allowance, from the Reserved header
    /// (`ReservedCategories.addReserve`).
    func addReserve(name: String, amountMinorUnits: Int, frequency: ForecastFrequency, interval: Int, startDate: Date, endDate: Date?) -> SaveOutcome {
        perform { db in
            _ = try ReservedCategories.addReserve(db: db, name: name, amountMinorUnits: amountMinorUnits, frequency: frequency, interval: interval, startDate: startDate, endDate: endDate)
        }
    }

    /// Another allowance for an existing reserve (`ReservedCategories.addAllowance`; a reserve's row menu).
    func addReserveAmount(to reserve: Category, amountMinorUnits: Int, frequency: ForecastFrequency, interval: Int, startDate: Date, endDate: Date?) -> SaveOutcome {
        guard let reserveId = reserve.id else { return .failed("This reserve no longer exists.") }
        return perform { db in
            _ = try ReservedCategories.addAllowance(db: db, reserveId: reserveId, amountMinorUnits: amountMinorUnits, frequency: frequency, interval: interval, startDate: startDate, endDate: endDate)
        }
    }

    func renameReserve(_ reserve: Category, to name: String) -> SaveOutcome {
        guard let reserveId = reserve.id else { return .failed("This reserve no longer exists.") }
        return perform { db in try ReservedCategories.rename(db: db, categoryId: reserveId, to: name) }
    }

    /// Deletes a reserve and its allowances (`ReservedCategories.delete`).
    func deleteReserve(_ reserve: Category) -> SaveOutcome {
        guard let reserveId = reserve.id else { return .failed("This reserve no longer exists.") }
        return perform { db in try ReservedCategories.delete(db: db, categoryId: reserveId) }
    }

    /// Write first, then reload (exceptions are only read in `load`). A failed write returns
    /// `.failed` with a message for the sheet; a failed reload after a successful write
    /// returns `.savedButReloadFailed` with a "Saved, but …" banner, so the sheet closes
    /// instead of inviting a retry that would save twice.
    private func perform(_ write: (Database) throws -> Void) -> SaveOutcome {
        do {
            try dbQueue.write { db in try write(db) }
        } catch {
            return .failed(PlanFormat.errorMessage(for: error))
        }
        return reload() ? .saved : .savedButReloadFailed
    }

    /// The Edit transaction sheet's Save (spec §5): category and note (or a manual
    /// transaction's fields) and the pending transfer change, in one write via
    /// `TransactionEditing.save` (no rule learned); then the grid reloads and
    /// `onTransactionEdited` runs. A refusal writes nothing.
    func saveTransactionEdit(id: Int64, changes: TransactionEditChanges) -> SaveOutcome {
        manualWrite { db in try TransactionEditing.save(db: db, id: id, changes: changes) }
    }

    /// Add transaction… (spec 2026-10-14 §2, `ManualTransactions.add`): the grid reloads and
    /// `onTransactionEdited` runs.
    func addTransaction(_ input: ManualTransactionInput) -> SaveOutcome {
        manualWrite { db in
            _ = try ManualTransactions.add(db: db, accountId: input.accountId, date: input.date, description: input.description,
                                           amountMinorUnits: input.amountMinorUnits, categoryId: input.categoryId, note: input.note)
        }
    }

    /// Edit transaction's Delete… for a transaction added by hand (`ManualTransactions.delete`).
    var manualActions: ManualTransactionActions {
        ManualTransactionActions(
            accounts: accounts,
            delete: { [unowned self] id in manualWrite { db in try ManualTransactions.delete(db: db, id: id) } }
        )
    }

    /// A transaction write: readable refusals, then the reload and `onTransactionEdited`.
    private func manualWrite(_ write: (Database) throws -> Void) -> SaveOutcome {
        do {
            try dbQueue.write { db in try write(db) }
        } catch {
            return .failed(ManualFormat.errorMessage(for: error))
        }
        let reloaded = reload()
        onTransactionEdited?()
        return reloaded ? .saved : .savedButReloadFailed
    }

    /// Edit transaction's transfer row: linked legs, Link to transfer…'s candidates and Add
    /// the other side…'s accounts (the changes are written by Save).
    var transferActions: TransferLinkActions {
        TransferLinkActions.make(dbQueue: dbQueue, accounts: accounts, counterparts: { [unowned self] in transferCounterparts[$0] ?? [] })
    }

    /// The picker's "New category…" (spec §4): creates the category and adds it to the list.
    func createCategory(name: String, type: CategoryType, groupId: Int64?) throws -> Category {
        let category = try dbQueue.write { db in try Categories.create(db: db, name: name, type: type, groupId: groupId) }
        // Re-read rather than append, so the list keeps `load()`'s order; a failed re-read
        // falls back to appending (the category was created either way).
        if let reloaded = try? dbQueue.read({ db in try Category.fetchAll(db) }) {
            categories = reloaded
        } else {
            categories.append(category)
        }
        return category
    }

    /// The Edit transaction picker's Recent section: the last 90 days' most used
    /// categories. A failed read only costs the section.
    func recentCategoryIds() -> [Int64] {
        let since = Calendar.current.date(byAdding: .day, value: -90, to: Date()) ?? Date()
        return (try? dbQueue.read { db in try CategoryShortlist.recent(db: db, since: since, limit: 5) }) ?? []
    }
}
