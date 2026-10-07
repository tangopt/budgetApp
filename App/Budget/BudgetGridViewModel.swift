// App/Budget/BudgetGridViewModel.swift
import Foundation
import BudgetCore
import struct BudgetCore.Category
import GRDB

@MainActor
final class BudgetGridViewModel: ObservableObject {
    @Published var categories: [Category] = [] {
        didSet { reserveRemainingCache = [:]; cellCache = [:] }
    }
    @Published var categoryGroups: [CategoryGroup] = []
    @Published var transactions: [Transaction] = [] {
        didSet { rebuildPayMonths(); clearNetWorthCaches() }
    }
    @Published var forecastEntries: [ForecastEntry] = [] {
        didSet { reserveRemainingCache = [:]; plannedCache = [:]; cellCache = [:] }
    }
    @Published var forecastGroups: [ForecastGroup] = [] {
        didSet { reserveRemainingCache = [:]; plannedCache = [:]; cellCache = [:] }
    }
    @Published var exceptions: [PlannedOccurrenceException] = [] {
        didSet { reserveRemainingCache = [:]; plannedCache = [:]; cellCache = [:] }
    }
    @Published var accounts: [Account] = [] {
        didSet { clearNetWorthCaches() }
    }
    @Published var balanceSnapshots: [BalanceSnapshot] = [] {
        didSet { clearNetWorthCaches() }
    }
    @Published var exchangeRate: ExchangeRateSetting = ExchangeRateSetting(eurToGbpRate: 0.87, updatedAt: Date()) {
        didSet { clearNetWorthCaches() }
    }
    @Published var selectedYear: Int?
    @Published var errorMessage: String?
    @Published private(set) var availableYears: [Int] = []
    /// Pay-month boundaries (salaries + manual closes). Rebuilt with `monthTotals` whenever
    /// transactions change (a recategorize can add or remove a salary).
    @Published private(set) var payCalendar = PayCalendar(salaryDates: [], manualCloses: [], today: Date())

    private let dbQueue: DatabaseQueue
    private var manualCloses: [PayMonthClose] = []
    private var lastHorizon: Date?
    /// Confirmed totals per category per pay month (`PayMonthTotals.lookup`).
    private var monthTotals: [Int64: [Int: [Int: Int]]] = [:]
    /// Remaining allowance per reserve id, memoised per `MonthRange.index` — the grid asks
    /// for every reserve cell on every render, and each month's answer scans every
    /// category's forecast. Cleared whenever categories, transactions or forecasts change.
    private var reserveRemainingCache: [Int: [Int64: Int]] = [:]
    /// Planned (confirmed-forecast) total per category per calendar month, memoised per
    /// `MonthRange.index` for the same reason. Cleared whenever forecasts or exceptions change.
    private var plannedCache: [Int: [Int64: Int]] = [:]
    /// Each category's Budget cell, memoised per `MonthRange.index` then category id: group,
    /// section and Year Total rows (and the pending footnote) combine member cells on every
    /// render. Cleared with `plannedCache`, when
    /// categories change, and when the pay calendar is rebuilt.
    private var cellCache: [Int: [Int64: PlanCell]] = [:]
    /// `payCalendar.monthClass` per `MonthRange.index`; reset when the calendar is rebuilt.
    private var monthClassCache: [Int: MonthClass] = [:]
    /// Account balance cells per `MonthRange.index` then account id (`nil` = no data yet), and
    /// the Net Worth row / year-picker totals per `MonthRange.index` (`nil` = no data). Each
    /// look-up scans every snapshot and transaction, so they're memoised like the plan cells.
    /// Cleared whenever accounts, snapshots, transactions or the exchange rate change.
    private var accountBalanceCache: [Int: [Int64: MonthlyAccountBalance?]] = [:]
    private var netWorthCache: [Int: Int?] = [:]

    init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
    }

    func load(horizon: Date) throws {
        lastHorizon = horizon
        manualCloses = try dbQueue.read { db in try PayMonthClose.fetchAll(db) }
        categories = try dbQueue.read { db in try Category.fetchAll(db) }
        categoryGroups = try dbQueue.read { db in try CategoryGroup.fetchAll(db) }
        transactions = try dbQueue.read { db in try Transaction.fetchAll(db) }
        forecastEntries = try dbQueue.read { db in try ForecastEntry.budget(db) }
        forecastGroups = try dbQueue.read { db in try ForecastGroup.fetchAll(db) }
        exceptions = try dbQueue.read { db in try PlannedOccurrenceException.fetchAll(db) }
        accounts = try dbQueue.read { db in try Account.fetchAll(db) }
        balanceSnapshots = try dbQueue.read { db in try BalanceSnapshot.fetchAll(db) }
        exchangeRate = try dbQueue.read { db in try ExchangeRateSetting.currentOrDefault(db: db) }
        selectDefaultYearIfNeeded()
    }

    /// Rebuilds everything derived from the pay calendar. `load()` sets `manualCloses` and
    /// `categories` before `transactions`, so this runs once per load with all inputs fresh.
    private func rebuildPayMonths() {
        payCalendar = PayCalendar(salaryDates: PaydaySource.paydayDates(transactions: transactions, categories: categories), manualCloses: manualCloses, today: Date())
        monthTotals = PayMonthTotals.lookup(transactions: transactions, calendar: payCalendar)
        reserveRemainingCache = [:]
        cellCache = [:]
        monthClassCache = [:]
        // The current year is always offered (calendar and pay-month year, which differ late in
        // December), so the plan for it shows even before any transaction lands in it.
        let currentYears = [MonthRange.components(of: Date()).year, payCalendar.current.year]
        availableYears = Array(Set(BudgetGridCalculator.yearsWithData(transactions: transactions, calendar: payCalendar) + currentYears)).sorted()
    }

    /// The grid's actuals as CSV: one column per pay month of the grid's years that has
    /// started, the same totals the cells show. Reserves are forecast-only, so left out.
    func exportCSV() -> String {
        BudgetGridExporter.export(categories: categories.filter { !$0.isReserved }, years: availableYears, calendar: payCalendar, monthTotals: monthTotals)
    }

    func payMonthCategoryTotal(_ category: Category, year: Int, month: Int) -> Int {
        category.id.flatMap { monthTotals[$0]?[year]?[month] } ?? 0
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

    /// `NetWorthCalculator.monthEndNetWorth`, memoised (`nil` = no account has data yet).
    private func monthEndNetWorth(year: Int, month: Int) -> Int? {
        let key = MonthRange.index(year: year, month: month)
        if let cached = netWorthCache[key] { return cached }
        let total = NetWorthCalculator.monthEndNetWorth(accounts: accounts, snapshots: balanceSnapshots, transactions: transactions, rate: exchangeRate, year: year, month: month)
        netWorthCache[key] = .some(total)
        return total
    }

    private func clearNetWorthCaches() {
        accountBalanceCache = [:]
        netWorthCache = [:]
    }

    /// Sum of every account's GBP-converted balance for `month`; accounts with no data yet
    /// that month contribute 0, matching how a not-yet-open account has no effect on net worth.
    func netWorthTotal(year: Int, month: Int) -> Int {
        monthEndNetWorth(year: year, month: month) ?? 0
    }

    /// True when at least one account has data (a snapshot at or before this month) for
    /// `year`/`month` — distinguishes "no data yet" from "net worth was genuinely zero."
    private func hasNetWorthData(year: Int, month: Int) -> Bool {
        monthEndNetWorth(year: year, month: month) != nil
    }

    /// Change in total GBP net worth from the end of the previous year to the end of
    /// `year` (both measured at December). `nil` when the previous year-end has no data
    /// at all (e.g. before any account's first snapshot) — a change needs a baseline.
    func netWorthChange(_ year: Int) -> Int? {
        guard hasNetWorthData(year: year - 1, month: 12) else { return nil }
        return netWorthTotal(year: year, month: 12) - netWorthTotal(year: year - 1, month: 12)
    }

    /// `netWorthChange` as a fraction of the previous year-end's net worth. `nil` when
    /// there's no change to show, or the previous year-end was exactly zero (the
    /// percentage would be meaningless/infinite).
    func netWorthChangePercent(_ year: Int) -> Double? {
        guard let change = netWorthChange(year) else { return nil }
        let previousYearEnd = netWorthTotal(year: year - 1, month: 12)
        guard previousYearEnd != 0 else { return nil }
        return Double(change) / Double(abs(previousYearEnd))
    }

    /// Falls back to the most recent year with data whenever the current selection is
    /// unset or no longer has data (e.g. right after `load()`).
    private func selectDefaultYearIfNeeded() {
        if selectedYear == nil || !availableYears.contains(selectedYear!) {
            selectedYear = availableYears.last
        }
    }

    func transactions(forCategoryId categoryId: Int64, from startDate: Date, to endDate: Date) -> [Transaction] {
        transactions.filter { $0.categoryId == categoryId && $0.status == .confirmed && $0.date >= startDate && $0.date <= endDate }
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
        let range = MonthRange.of(year: year, month: month)
        let period = PayPeriod(startDate: range.start, endDate: range.end, type: .projected)
        let allowances: [(id: Int64, name: String, allowance: Int)] = reserves.compactMap { reserve in
            reserve.id.map { ($0, reserve.name, ForecastCalculator.confirmedTotal(categoryId: $0, period: period, entries: forecastEntries, groups: forecastGroups, exceptions: exceptions)) }
        }
        let remaining = ReservedCategories.monthAllowances(allowances, monthClass: monthClass(year: year, month: month)) {
            ReservedCategories.unforecastSpend(year: year, month: month, categories: categories, monthTotals: monthTotals, entries: forecastEntries, groups: forecastGroups, exceptions: exceptions)
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

    /// The planned total for `category` in the calendar month named `year`/`month`.
    private func plannedTotal(_ categoryId: Int64, year: Int, month: Int) -> Int {
        let key = MonthRange.index(year: year, month: month)
        if let cached = plannedCache[key] { return cached[categoryId] ?? 0 }
        let range = MonthRange.of(year: year, month: month)
        let totals = ForecastCalculator.confirmedTotalsByCategory(period: PayPeriod(startDate: range.start, endDate: range.end, type: .projected),
                                                                  entries: forecastEntries, groups: forecastGroups, exceptions: exceptions)
        plannedCache[key] = totals
        return totals[categoryId] ?? 0
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
    /// still expects (`PlanStatus.cell`); closed months show the actual alone. Memoised.
    func cell(_ category: Category, year: Int, month: Int) -> PlanCell {
        guard let id = category.id else { return (0, 0, .none) }
        let key = MonthRange.index(year: year, month: month)
        if let cached = cellCache[key]?[id] { return cached }
        let cell = PlanStatus.cell(actual: payMonthCategoryTotal(category, year: year, month: month),
                                   planned: plannedTotal(id, year: year, month: month),
                                   categoryType: category.type,
                                   monthClass: monthClass(year: year, month: month))
        cellCache[key, default: [:]][id] = cell
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

    /// A reserve's month as a cell: what's left of its allowance counts as expected while the
    /// month is open (reserves never hold transactions).
    func reserveCell(_ reserves: [Category], year: Int, month: Int) -> PlanCell {
        let value = reserves.reduce(0) { $0 + reserveTotal($1, year: year, month: month) }
        return (value, value, value == 0 ? .none : .allExpected)
    }

    /// Every planned item (`ForecastCalculator.confirmedEntries`): the add sheet's "Already
    /// planned" lines and the drill-down's occurrences.
    var plannedEntries: [ForecastEntry] {
        ForecastCalculator.confirmedEntries(entries: forecastEntries, groups: forecastGroups)
    }

    /// The planned occurrences filed under `category` (after any re-file) whose date falls in
    /// the calendar month `year`/`month`, each with whether it's confirmed and its series.
    func occurrences(category: Category, year: Int, month: Int) -> [PlannedRow] {
        guard let id = category.id else { return [] }
        return PlannedRow.rows(categoryId: id, year: year, month: month, plan: plannedEntries, exceptions: exceptions) { entry, occurrence in
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
    func addPlannedItem(categoryId: Int64, amountMinorUnits: Int, frequency: ForecastFrequency, interval: Int, startDate: Date, endDate: Date?) -> SaveOutcome {
        perform { db in
            _ = try PlannedItems.add(db: db, categoryId: categoryId, amountMinorUnits: amountMinorUnits, frequency: frequency, interval: interval, startDate: startDate, endDate: endDate)
        }
    }

    /// A new planned item for a category created with it ("+ New category…"), in one write so
    /// a failed save leaves no orphaned category (`PlannedItems.add(db:newCategoryName:…)`).
    func addPlannedItem(newCategoryName: String, type: CategoryType, amountMinorUnits: Int, frequency: ForecastFrequency, interval: Int, startDate: Date, endDate: Date?) -> SaveOutcome {
        perform { db in
            _ = try PlannedItems.add(db: db, newCategoryName: newCategoryName, type: type, amountMinorUnits: amountMinorUnits, frequency: frequency, interval: interval, startDate: startDate, endDate: endDate)
        }
    }

    /// A new reserve with its first allowance, from the Reserved header
    /// (`ReservedCategories.addReserve`).
    func addReserve(name: String, amountMinorUnits: Int, frequency: ForecastFrequency, interval: Int, startDate: Date, endDate: Date?) -> SaveOutcome {
        perform { db in
            _ = try ReservedCategories.addReserve(db: db, name: name, amountMinorUnits: amountMinorUnits, frequency: frequency, interval: interval, startDate: startDate, endDate: endDate)
        }
    }

    /// Another allowance for an existing reserve, in the "Reserved" group (a reserve's row menu).
    func addReserveAmount(to reserve: Category, amountMinorUnits: Int, frequency: ForecastFrequency, interval: Int, startDate: Date, endDate: Date?) -> SaveOutcome {
        guard let reserveId = reserve.id else { return .failed("This reserve no longer exists.") }
        return perform { db in
            let group = try ReservedCategories.ensureGroup(db: db)
            var entry = ForecastEntry(groupId: group.id!, categoryId: reserveId, amountMinorUnits: -abs(amountMinorUnits), frequency: frequency, interval: interval, startDate: startDate, endDate: endDate, isEnabled: true, status: .confirmed, note: nil)
            try entry.insert(db)
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

    /// Re-categorizes a single already-confirmed transaction (from a drill-down sheet).
    ///
    /// The write happens against a locally-built copy first; `self.transactions` is only
    /// mutated once that write has actually succeeded, mirroring
    /// `UncategorizedViewModel.assignCategory`. Mutating the in-memory array before the
    /// write (as an earlier version of this method did) would leave the grid cell showing
    /// the new category even when the DB write failed, silently diverging from the
    /// persisted row until the next launch reverted it.
    @discardableResult
    func recategorize(_ transaction: Transaction, to categoryId: Int64) -> Bool {
        errorMessage = nil
        guard let index = transactions.firstIndex(where: { $0.id == transaction.id }) else { return false }
        var updated = transactions[index]
        updated.categoryId = categoryId
        do {
            try dbQueue.write { db in try updated.update(db) }
        } catch {
            errorMessage = "Couldn't recategorize this transaction: \(error.localizedDescription)"
            return false
        }
        transactions[index] = updated
        return true
    }
}
