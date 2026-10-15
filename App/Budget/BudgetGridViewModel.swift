// App/Budget/BudgetGridViewModel.swift
import Foundation
import BudgetCore
import struct BudgetCore.Category
import GRDB

@MainActor
final class BudgetGridViewModel: ObservableObject {
    @Published var categories: [Category] = [] {
        didSet { itemAccountsCache = nil; clearPlanCaches(); clearNetWorthCaches() }
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
    /// `budgetTransactions` with All accounts (what `monthTotals` sums), so clearing the filter
    /// needs no recomputation.
    private var allAccountsBudgetTransactions: [Transaction] = []
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
    /// Whether the account panel is open beside the grid (kept for the session like the filter).
    @Published var isAccountPanelOpen = true
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
            clearNetWorthCaches()
            // A deleted account leaves the filter (none left = All accounts).
            let ids = Set(accounts.compactMap(\.id))
            if !accountFilter.isSubset(of: ids) { accountFilter.formIntersection(ids) }
        }
    }
    @Published var balanceSnapshots: [BalanceSnapshot] = [] {
        didSet { clearNetWorthCaches() }
    }
    @Published var exchangeRate: ExchangeRateSetting = ExchangeRateSetting(eurToGbpRate: 0.87, updatedAt: Date()) {
        didSet { clearNetWorthCaches() }
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

    init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
    }

    func load(horizon: Date) throws {
        lastHorizon = horizon
        manualCloses = try dbQueue.read { db in try PayMonthClose.fetchAll(db) }
        categories = try dbQueue.read { db in try Category.fetchAll(db) }
        categoryGroups = try dbQueue.read { db in try CategoryGroup.fetchAll(db) }
        (transferLinks, transferCounterparts) = try dbQueue.read { db in (try TransferLink.fetchAll(db), try TransferLinks.counterparts(db: db)) }
        transactions = try dbQueue.read { db in try Transaction.fetchAll(db) }
        forecastEntries = try dbQueue.read { db in try ForecastEntry.budget(db) }
        forecastGroups = try dbQueue.read { db in try ForecastGroup.fetchAll(db) }
        exceptions = try dbQueue.read { db in try PlannedOccurrenceException.fetchAll(db) }
        accounts = try dbQueue.read { db in try Account.fetchAll(db) }.sortedForDisplay()
        balanceSnapshots = try dbQueue.read { db in try BalanceSnapshot.fetchAll(db) }
        exchangeRate = try dbQueue.read { db in try ExchangeRateSetting.currentOrDefault(db: db) }
        selectDefaultYearIfNeeded()
    }

    /// Rebuilds everything derived from the pay calendar. `load()` sets `manualCloses` and
    /// `categories` before `transactions`, so this runs once per load with all inputs fresh.
    private func rebuildPayMonths() {
        payCalendar = PayCalendar(salaryDates: PaydaySource.paydayDates(transactions: transactions, categories: categories), manualCloses: manualCloses, today: Date())
        allAccountsBudgetTransactions = TransferLinks.budgetFacing(transactions, links: transferLinks)
        itemAccountsCache = nil
        monthTotals = PayMonthTotals.lookup(transactions: allAccountsBudgetTransactions, calendar: payCalendar)
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
        if accountFilter.isEmpty {
            budgetTransactions = allAccountsBudgetTransactions
            shownMonthTotals = monthTotals
        } else {
            budgetTransactions = TransferLinks.budgetFacing(transactions, links: transferLinks, accountIds: accountFilter)
            shownMonthTotals = PayMonthTotals.lookup(transactions: budgetTransactions, calendar: payCalendar)
        }
        noteMonths = PayMonthTotals.noteMonths(transactions: budgetTransactions, calendar: payCalendar)
        reserveRemainingCache = [:]
        cellCache = [:]
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
        case blank
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
