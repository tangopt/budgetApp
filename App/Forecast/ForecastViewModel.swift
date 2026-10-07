// App/Forecast/ForecastViewModel.swift
import Foundation
import BudgetCore
import struct BudgetCore.Category
import GRDB

@MainActor
final class ForecastViewModel: ObservableObject {
    @Published var groups: [ForecastGroup] = []

    /// Groups offered as what-if scenarios: not system-managed, and not the "Reserved" /
    /// "Spreadsheet plan" / "Planned" groups (those hold confirmed planning data).
    var scenarioGroups: [ForecastGroup] {
        let confirmedGroupNames: Set<String> = [ReservedCategories.groupName, ForecastPlanSeeder.planGroupName, PlannedItems.groupName]
        return groups.filter { !$0.isSystemManaged && !confirmedGroupNames.contains($0.name) }
    }
    @Published var entries: [ForecastEntry] = []
    @Published var exceptions: [PlannedOccurrenceException] = []
    @Published var categories: [Category] = []
    @Published var categoryGroups: [CategoryGroup] = []
    @Published var accounts: [Account] = []
    @Published var balanceSnapshots: [BalanceSnapshot] = []
    /// Set only by `load()`, which rebuilds `payCalendar`/`monthTotals` from it.
    @Published private(set) var transactions: [Transaction] = []
    @Published var exchangeRate: ExchangeRateSetting = ExchangeRateSetting(eurToGbpRate: 0.87, updatedAt: Date())
    @Published var errorMessage: String?
    /// The scenario (non-system-managed `ForecastGroup`) currently previewed in the grid
    /// and headline. `nil` means "None (confirmed only)" — the default. Ephemeral: reset
    /// to `nil` on every `load()`, never persisted. Changing it changes what
    /// `previewCategoryTotal`/`scenarioNetWorthImpact` compute, so it must trigger the
    /// same cache rebuild any other cache-affecting mutation does. The `oldValue` guard
    /// avoids a redundant recompute on a same-value assignment (e.g. re-selecting the
    /// scenario that's already selected) — `load()` no longer depends on this `didSet`
    /// firing to rebuild the caches (see its own trailing `recomputeForecastCaches()`
    /// call), but other call sites still rely on it for a plain selection change.
    @Published var selectedScenarioGroupId: Int64? {
        didSet {
            guard oldValue != selectedScenarioGroupId else { return }
            recomputeForecastCaches()
        }
    }
    /// The pay month containing the latest transaction date across everything `load()`
    /// fetched. `nil` before the first successful `load()`, or if there's no transaction
    /// data at all. Only the net-worth headline's walk starts from it; cell values follow
    /// `monthClass`.
    @Published private(set) var latestRealMonth: (year: Int, month: Int)?
    /// Month boundaries and classes (salary dates + manual closes), rebuilt by `load()`.
    @Published private(set) var payCalendar = PayCalendar(salaryDates: [], manualCloses: [], today: Date())

    private let dbQueue: DatabaseQueue
    /// Confirmed actuals per category per *pay* month (`PayMonthTotals.lookup`), rebuilt by
    /// `load()` with `payCalendar`.
    private var monthTotals: [Int64: [Int: [Int: Int]]] = [:]
    /// `payCalendar.monthClass` for every month of `thisYear`/`nextYear`, rebuilt by `load()`:
    /// the class is read for every cell on every scroll frame, and computing it walks the
    /// calendar's close dates.
    private var monthClassCache: [Int: [Int: MonthClass]] = [:]
    /// Precomputed confirmed/preview forecast totals for every (category, year, month)
    /// cell, covering `thisYear` and `nextYear` — rebuilt by `recomputeForecastCaches()`
    /// at the end of `load()`, after any mutation that changes `entries`/`groups`, and
    /// whenever `selectedScenarioGroupId` changes (the `preview` half of this cache is
    /// scenario-dependent). `ForecastView.body` re-evaluates on every horizontal-scroll-
    /// offset change (same frozen-header/frozen-column technique as the Budget grid),
    /// which would otherwise re-run `ForecastCalculator` for every visible cell on every
    /// scroll frame — measured at ~30ms per full-grid pass against the live database,
    /// well over a 60fps frame budget. Only consulted for open (blended/forecast) months;
    /// closed months already have an O(1) path via `monthTotals`. Keyed by
    /// categoryId → year → month.
    private var forecastTotalsCache: [Int64: [Int: [Int: (confirmed: Int, preview: Int)]]] = [:]
    /// Precomputed `forecastNetWorth`/`forecastNetWorthYoY`/`scenarioNetWorthImpact`
    /// results for `thisYear` and `nextYear` — the headline figures `ForecastView` shows.
    /// Rebuilt alongside `forecastTotalsCache` for the same reason. Keyed by year.
    private var netWorthHeadlineCache: [Int: (forecast: Int?, yoy: (changeGBP: Int, percent: Double?)?, scenarioImpact: Int?)] = [:]
    /// Each reserve's value (`ReservedCategories.monthAllowances`: 0 when closed, what's left
    /// after the pay month's unforecast spending when blended, the full allowance when
    /// forecast) for every month of `thisYear`/`nextYear`. Rebuilt with
    /// `forecastTotalsCache`. Keyed by year → month.
    private var reserveRemainingCache: [Int: [Int: (confirmed: [Int64: Int], preview: [Int64: Int])]] = [:]
    private static let calendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }()

    var thisYear: Int { Self.calendar.component(.year, from: Date()) }
    var nextYear: Int { thisYear + 1 }

    init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
    }

    func load() throws {
        groups = try dbQueue.read { db in try ForecastGroup.fetchAll(db) }
        entries = try dbQueue.read { db in try ForecastEntry.fetchAll(db) }
        exceptions = try dbQueue.read { db in try PlannedOccurrenceException.fetchAll(db) }
        categories = try dbQueue.read { db in try Category.fetchAll(db) }
        categoryGroups = try dbQueue.read { db in try CategoryGroup.fetchAll(db) }
        accounts = try dbQueue.read { db in try Account.fetchAll(db) }
        balanceSnapshots = try dbQueue.read { db in try BalanceSnapshot.fetchAll(db) }
        transactions = try dbQueue.read { db in try Transaction.fetchAll(db) }
        let manualCloses = try dbQueue.read { db in try PayMonthClose.fetchAll(db) }
        exchangeRate = try dbQueue.read { db in try ExchangeRateSetting.currentOrDefault(db: db) }
        // Everything derived from the pay calendar is rebuilt here, before the caches below:
        // its inputs (transactions, categories, manual closes) only change through `load()`.
        payCalendar = PayCalendar(salaryDates: PaydaySource.paydayDates(transactions: transactions, categories: categories), manualCloses: manualCloses, today: Date())
        monthTotals = PayMonthTotals.lookup(transactions: transactions, calendar: payCalendar)
        var classes: [Int: [Int: MonthClass]] = [:]
        for year in [thisYear, nextYear] {
            for month in 1...12 { classes[year, default: [:]][month] = payCalendar.monthClass(PayMonth(year: year, month: month)) }
        }
        monthClassCache = classes
        latestRealMonth = transactions.map(\.date).max().map { latest in
            let month = payCalendar.month(containing: latest)
            return (month.year, month.month)
        }
        selectedScenarioGroupId = nil
        // Rebuilt explicitly rather than relying on `selectedScenarioGroupId`'s `didSet`
        // firing: a same-value nil→nil assignment (e.g. reloading while nothing was ever
        // selected) wouldn't change `oldValue`, so the `didSet`'s own guard would skip the
        // rebuild — and every other property `load()` sets above (e.g. `latestRealMonth`)
        // must already be in place before this rebuild runs, which a direct call at the
        // very end guarantees regardless of what the property observer does.
        recomputeForecastCaches()
    }

    /// Rebuilds `forecastTotalsCache` and `netWorthHeadlineCache` from current state.
    /// Called explicitly at the end of `load()`, and after every mutation that changes
    /// `entries`/`groups`/`selectedScenarioGroupId`.
    private func recomputeForecastCaches() {
        var totals: [Int64: [Int: [Int: (confirmed: Int, preview: Int)]]] = [:]
        for category in categories {
            guard let categoryId = category.id else { continue }
            var byYear: [Int: [Int: (confirmed: Int, preview: Int)]] = [:]
            for year in [thisYear, nextYear] {
                var byMonth: [Int: (confirmed: Int, preview: Int)] = [:]
                for month in 1...12 {
                    let range = dateRange(forYear: year, month: month)
                    let period = PayPeriod(startDate: range.start, endDate: range.end, type: .projected)
                    byMonth[month] = (
                        ForecastCalculator.confirmedTotal(categoryId: categoryId, period: period, entries: entries, groups: groups, exceptions: exceptions),
                        ForecastCalculator.previewTotal(categoryId: categoryId, period: period, entries: entries, groups: groups, selectedScenarioGroupId: selectedScenarioGroupId, exceptions: exceptions)
                    )
                }
                byYear[year] = byMonth
            }
            totals[categoryId] = byYear
        }
        forecastTotalsCache = totals

        var remaining: [Int: [Int: (confirmed: [Int64: Int], preview: [Int64: Int])]] = [:]
        if !reserves.isEmpty {
            for year in [thisYear, nextYear] {
                for month in 1...12 {
                    remaining[year, default: [:]][month] = (computeRemainingReserves(year: year, month: month, preview: false), computeRemainingReserves(year: year, month: month, preview: true))
                }
            }
        }
        reserveRemainingCache = remaining

        var headline: [Int: (forecast: Int?, yoy: (changeGBP: Int, percent: Double?)?, scenarioImpact: Int?)] = [:]
        for year in [thisYear, nextYear] {
            headline[year] = (computeForecastNetWorth(atEndOf: year), computeForecastNetWorthYoY(atEndOf: year), computeScenarioNetWorthImpact(atEndOf: year))
        }
        netWorthHeadlineCache = headline
    }

    /// The month's class from `payCalendar` (closed → `.actual`; open and started →
    /// `.blended`; open and in the future → `.forecast`), from `monthClassCache` for
    /// `thisYear`/`nextYear`.
    ///
    /// `latestRealMonth` (and so the net-worth walk) comes from transaction dates only —
    /// deliberately NOT balance snapshot dates: a balance typed on the Accounts screen is
    /// dated by its as-of day (usually today) regardless of how stale the imported
    /// transactions are, and would skip forecast months that have no data.
    func monthClass(year: Int, month: Int) -> MonthClass {
        monthClassCache[year]?[month] ?? payCalendar.monthClass(PayMonth(year: year, month: month))
    }

    func dateRange(forYear year: Int, month: Int) -> (start: Date, end: Date) {
        var startComponents = DateComponents(); startComponents.year = year; startComponents.month = month; startComponents.day = 1
        let start = Self.calendar.date(from: startComponents)!
        // `end` is the LAST MOMENT of the month's last day, not midnight at its start —
        // see `FrequencyExpander`'s inclusive occurrence check; a `ForecastEntry.startDate`
        // can carry a real time-of-day and landing exactly at midnight would silently
        // exclude a same-day-later occurrence.
        let end = Self.calendar.date(byAdding: .month, value: 1, to: start)!.addingTimeInterval(-1)
        return (start, end)
    }

    /// The category's total for one month, by `monthClass`: a closed month shows the
    /// pay-month actuals; a blended month `MonthBlend.projectedTotal` of those actuals and
    /// the confirmed forecast for the calendar month; a forecast month the confirmed
    /// forecast (read from `forecastTotalsCache`, falling back to a direct calculation for
    /// a cache miss). Same rules as the Dashboard (`DashboardCalculator.categoryAmounts`).
    func categoryTotal(_ category: Category, year: Int, month: Int) -> Int {
        cellTotal(category, year: year, month: month, preview: false)
    }

    /// Like `categoryTotal`, with the selected scenario's `.hypothetical` entries added to
    /// the forecast part. A closed month always equals `categoryTotal` — a hypothetical
    /// can't retroactively change history; a blended month blends the actuals with the
    /// preview forecast.
    func previewCategoryTotal(_ category: Category, year: Int, month: Int) -> Int {
        cellTotal(category, year: year, month: month, preview: true)
    }

    private func cellTotal(_ category: Category, year: Int, month: Int, preview: Bool) -> Int {
        let kind = monthClass(year: year, month: month)
        if category.isReserved {
            // Reserves are forecast-only (`ReservedCategories.monthAllowances`): 0 in a
            // closed month, what's left after the pay month's unforecast spending in a
            // blended one, the full allowance in a forecast one.
            guard kind != .actual else { return 0 }
            return remainingReserveValue(category, year: year, month: month, preview: preview)
        }
        let actual = kind == .forecast ? 0 : (category.id.flatMap { monthTotals[$0]?[year]?[month] } ?? 0)
        guard kind != .actual else { return actual }
        return MonthBlend.projectedTotal(actual: actual, expected: forecastValue(category, year: year, month: month, preview: preview), categoryType: category.type, monthClass: kind)
    }

    /// The category's forecast total for one month — confirmed, or confirmed plus the
    /// selected scenario's hypotheticals when `preview` — read from
    /// `forecastTotalsCache`, falling back to a direct calculation for a cache miss.
    private func forecastValue(_ category: Category, year: Int, month: Int, preview: Bool) -> Int {
        guard let categoryId = category.id else { return 0 }
        if let cached = forecastTotalsCache[categoryId]?[year]?[month] { return preview ? cached.preview : cached.confirmed }
        let range = dateRange(forYear: year, month: month)
        let period = PayPeriod(startDate: range.start, endDate: range.end, type: .projected)
        return preview
            ? ForecastCalculator.previewTotal(categoryId: categoryId, period: period, entries: entries, groups: groups, selectedScenarioGroupId: selectedScenarioGroupId, exceptions: exceptions)
            : ForecastCalculator.confirmedTotal(categoryId: categoryId, period: period, entries: entries, groups: groups, exceptions: exceptions)
    }

    /// A reserve's remaining allowance for one month, from `reserveRemainingCache`, falling
    /// back to a direct calculation for a cache miss.
    private func remainingReserveValue(_ reserve: Category, year: Int, month: Int, preview: Bool) -> Int {
        guard let reserveId = reserve.id else { return 0 }
        if let cached = reserveRemainingCache[year]?[month] { return (preview ? cached.preview : cached.confirmed)[reserveId] ?? 0 }
        return computeRemainingReserves(year: year, month: month, preview: preview)[reserveId] ?? 0
    }

    /// Every reserve's month value (confirmed, or preview when `preview`) by the month's
    /// class (`ReservedCategories.monthAllowances`): the unforecast spend comes from the pay
    /// month's actuals and is absorbed in name order.
    private func computeRemainingReserves(year: Int, month: Int, preview: Bool) -> [Int64: Int] {
        let allowances: [(id: Int64, name: String, allowance: Int)] = reserves.compactMap { reserve in
            reserve.id.map { ($0, reserve.name, forecastValue(reserve, year: year, month: month, preview: preview)) }
        }
        return ReservedCategories.monthAllowances(allowances, monthClass: monthClass(year: year, month: month)) {
            ReservedCategories.unforecastSpend(year: year, month: month, categories: categories, monthTotals: monthTotals, entries: entries, groups: groups, exceptions: exceptions)
        }
    }

    private var currentNetWorthGBP: Int {
        NetWorthCalculator.netWorth(balances: NetWorthCalculator.accountBalances(accounts: accounts, snapshots: balanceSnapshots, transactions: transactions, rate: exchangeRate))
    }

    /// Total real net worth as of December of `year`, using only real balance snapshot
    /// data (no forecast) — the same calculation `BudgetGridViewModel.netWorthTotal` uses.
    private func realNetWorth(atEndOf year: Int) -> Int {
        NetWorthCalculator.monthEndNetWorth(accounts: accounts, snapshots: balanceSnapshots, transactions: transactions, rate: exchangeRate, year: year, month: 12) ?? 0
    }

    /// Forecast net worth at the end of `year` (December; `year` must be `thisYear` or
    /// `nextYear`): current net worth plus the confirmed forecast's accumulated net impact
    /// for every month strictly after `latestRealMonth` through that December. `nil` when
    /// there's no `latestRealMonth` yet. Reads from `netWorthHeadlineCache`, falling back
    /// to a direct calculation for a cache miss.
    func forecastNetWorth(atEndOf year: Int) -> Int? {
        netWorthHeadlineCache[year]?.forecast ?? computeForecastNetWorth(atEndOf: year)
    }

    private func computeForecastNetWorth(atEndOf year: Int) -> Int? {
        guard let latestRealMonth else { return nil }
        return ForecastProjector.forecastNetWorth(startingNetWorth: currentNetWorthGBP, latestRealMonth: latestRealMonth, atEndOf: year, categories: categories, entries: entries, groups: groups, exceptions: exceptions)
    }

    /// Walks month-by-month from the month after `latestRealMonth` through December of
    /// `year` (inclusive), summing whatever `perMonth(year, month)` returns for each
    /// month. `nil` when there's no `latestRealMonth` yet. Used by
    /// `computeScenarioNetWorthImpact`; the confirmed forecast walk lives in
    /// `ForecastProjector` (which mirrors this month-rollover arithmetic).
    private func sumOverForecastMonths(atEndOf year: Int, _ perMonth: (Int, Int) -> Int) -> Int? {
        guard let latestRealMonth else { return nil }
        var sum = 0
        var cursor = (year: latestRealMonth.year, month: latestRealMonth.month + 1)
        if cursor.month > 12 { cursor = (cursor.year + 1, 1) }
        while cursor.year < year || (cursor.year == year && cursor.month <= 12) {
            sum += perMonth(cursor.year, cursor.month)
            cursor.month += 1
            if cursor.month > 12 { cursor = (cursor.year + 1, 1) }
        }
        return sum
    }

    /// `forecastNetWorth(atEndOf: year)` compared to a baseline: last year's real
    /// year-end net worth when December of `year - 1` is closed in the pay calendar
    /// (`payCalendar.isClosed`), or last year's *forecast* year-end net
    /// worth otherwise — which is always the case when `year == nextYear` (no real data
    /// can exist for a future year's December), but can also happen when `year ==
    /// thisYear` if real data is stale enough that it doesn't reach last December (e.g.
    /// imports lapsed for over a year). Falling back to the forecast baseline in that
    /// case avoids presenting a stale, carried-forward balance as "vs Dec `year - 1`" —
    /// which would overstate how much of that figure is real. `percent` is `nil` when
    /// the baseline is zero. Reads from `netWorthHeadlineCache`, falling back to a direct
    /// calculation for a cache miss.
    func forecastNetWorthYoY(atEndOf year: Int) -> (changeGBP: Int, percent: Double?)? {
        netWorthHeadlineCache[year]?.yoy ?? computeForecastNetWorthYoY(atEndOf: year)
    }

    private func computeForecastNetWorthYoY(atEndOf year: Int) -> (changeGBP: Int, percent: Double?)? {
        guard let forecast = computeForecastNetWorth(atEndOf: year) else { return nil }
        let baseline = payCalendar.isClosed(PayMonth(year: year - 1, month: 12)) ? realNetWorth(atEndOf: year - 1) : (computeForecastNetWorth(atEndOf: year - 1) ?? 0)
        let change = forecast - baseline
        let percent: Double? = baseline != 0 ? Double(change) / Double(abs(baseline)) : nil
        return (change, percent)
    }

    /// `nil` when `selectedScenarioGroupId` is nil (no scenario selected) or there's no
    /// `latestRealMonth` yet. Otherwise, the selected scenario's cumulative preview delta
    /// (`ForecastCalculator.previewNetWorthDelta`) summed over the same months
    /// `forecastNetWorth` accumulates over — the change in year-end net worth this
    /// scenario would add on top of the confirmed forecast. Reads from
    /// `netWorthHeadlineCache`, falling back to a direct calculation for a cache miss.
    func scenarioNetWorthImpact(atEndOf year: Int) -> Int? {
        netWorthHeadlineCache[year]?.scenarioImpact ?? computeScenarioNetWorthImpact(atEndOf: year)
    }

    private func computeScenarioNetWorthImpact(atEndOf year: Int) -> Int? {
        guard let selectedScenarioGroupId else { return nil }
        return sumOverForecastMonths(atEndOf: year, { y, m in
            let range = dateRange(forYear: y, month: m)
            return ForecastCalculator.previewNetWorthDelta(period: PayPeriod(startDate: range.start, endDate: range.end, type: .projected), categories: categories, entries: entries, groups: groups, selectedScenarioGroupId: selectedScenarioGroupId, exceptions: exceptions)
        })
    }

    func toggleGroup(_ group: ForecastGroup) {
        guard let index = groups.firstIndex(where: { $0.id == group.id }) else { return }
        groups[index].isEnabled.toggle()
        try? dbQueue.write { db in try groups[index].update(db) }
        recomputeForecastCaches()
    }

    func toggleEntry(_ entry: ForecastEntry) {
        guard let index = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        entries[index].isEnabled.toggle()
        try? dbQueue.write { db in try entries[index].update(db) }
        recomputeForecastCaches()
    }

    /// Edits an entry's amount/frequency/interval/start-date/end-date. If it was auto-detected, this
    /// promotes it to `.manual` so a future `AutoForecastGenerator.refresh` won't silently
    /// overwrite the edit — mirrors the generator's own skip-on-manual-tuning behavior.
    ///
    /// The write happens against a locally-built copy first; `entries` is only mutated
    /// once that write has actually succeeded, mirroring `BudgetGridViewModel.recategorize`.
    ///
    /// A new start date, frequency or interval reschedules the series, so its per-occurrence
    /// exceptions (keyed by the old schedule's dates) are deleted in the same write.
    @discardableResult
    func updateEntry(_ entry: ForecastEntry, amountMinorUnits: Int, frequency: ForecastFrequency, interval: Int, startDate: Date, endDate: Date?) -> Bool {
        errorMessage = nil
        guard let index = entries.firstIndex(where: { $0.id == entry.id }) else { return false }
        var updated = entries[index]
        let reschedules = updated.startDate != startDate || updated.frequency != frequency || updated.interval != interval
        updated.amountMinorUnits = amountMinorUnits
        updated.frequency = frequency
        updated.interval = interval
        if updated.startDate != startDate { updated.anchorDay = nil } // a new start sets the day
        updated.startDate = startDate
        updated.endDate = endDate
        if updated.status == .auto {
            updated.status = .manual
        }
        do {
            try dbQueue.write { db in
                try updated.update(db)
                if reschedules, let id = updated.id {
                    _ = try PlannedOccurrenceException.filter(Column("entryId") == id).deleteAll(db)
                }
            }
        } catch {
            errorMessage = "Couldn't save the change: \(error.localizedDescription)"
            return false
        }
        if reschedules { exceptions.removeAll { $0.entryId == updated.id } }
        entries[index] = updated
        recomputeForecastCaches()
        return true
    }

    /// Moves a confirmed entry back to `.hypothetical` (preview-only). Write-first,
    /// mutate-on-success, like `updateEntry`.
    @discardableResult
    func unconfirm(_ entry: ForecastEntry) -> Bool {
        errorMessage = nil
        guard let index = entries.firstIndex(where: { $0.id == entry.id }) else { return false }
        var updated = entries[index]
        updated.status = .hypothetical
        do {
            try dbQueue.write { db in try updated.update(db) }
        } catch {
            errorMessage = "Couldn't un-confirm this entry: \(error.localizedDescription)"
            return false
        }
        entries[index] = updated
        recomputeForecastCaches()
        return true
    }

    /// One item in a scenario being created or added to — a plain value type, not
    /// persisted directly (see `createScenario`/`addItem`, which turn it into a
    /// `ForecastEntry`).
    struct ScenarioItem {
        let categoryId: Int64
        let amountMinorUnits: Int
        let frequency: ForecastFrequency
        let interval: Int
        let startDate: Date
        let endDate: Date?
    }

    /// Creates a new scenario (a non-system-managed `ForecastGroup`) with one or more
    /// hypothetical entries in a single write. `items` is expected non-empty — the current
    /// UI only ever calls this with exactly one item (from `ScenarioItemFormView`'s
    /// `.newScenario` mode); there is no item-count validation or Save-disabling anywhere
    /// in that flow, so this is a precondition on the call site, not a runtime error path.
    /// Write-first: `groups`/`entries` are only refetched (to pick up the new
    /// auto-generated ids) once the whole write has actually succeeded, mirroring
    /// `updateEntry`/`unconfirm`/`confirmScenario`'s do/catch → `errorMessage` pattern.
    /// Also selects the newly created scenario, so the user doesn't have to find and
    /// select it themselves right after creating it.
    func createScenario(name: String, items: [ScenarioItem]) {
        errorMessage = nil
        var newGroupId: Int64?
        do {
            try dbQueue.write { db in
                var group = ForecastGroup(name: name, note: nil, isEnabled: true, isSystemManaged: false)
                try group.insert(db)
                newGroupId = group.id
                for item in items {
                    var entry = ForecastEntry(groupId: group.id!, categoryId: item.categoryId, amountMinorUnits: item.amountMinorUnits, frequency: item.frequency, interval: item.interval, startDate: item.startDate, endDate: item.endDate, isEnabled: true, status: .hypothetical, note: nil)
                    try entry.insert(db)
                }
            }
        } catch {
            errorMessage = "Couldn't create this scenario: \(error.localizedDescription)"
            return
        }
        groups = (try? dbQueue.read { db in try ForecastGroup.fetchAll(db) }) ?? groups
        entries = (try? dbQueue.read { db in try ForecastEntry.fetchAll(db) }) ?? entries
        selectedScenarioGroupId = newGroupId
        recomputeForecastCaches()
    }

    /// Adds one more item to an existing scenario group. Write-first, mutate-on-success,
    /// like `createScenario`.
    func addItem(to group: ForecastGroup, _ item: ScenarioItem) {
        errorMessage = nil
        do {
            try dbQueue.write { db in
                var entry = ForecastEntry(groupId: group.id!, categoryId: item.categoryId, amountMinorUnits: item.amountMinorUnits, frequency: item.frequency, interval: item.interval, startDate: item.startDate, endDate: item.endDate, isEnabled: true, status: .hypothetical, note: nil)
                try entry.insert(db)
            }
        } catch {
            errorMessage = "Couldn't add this item to the scenario: \(error.localizedDescription)"
            return
        }
        entries = (try? dbQueue.read { db in try ForecastEntry.fetchAll(db) }) ?? entries
        recomputeForecastCaches()
    }

    /// Confirms every entry in `group` at once — a scenario is the unit the user thinks
    /// in, so confirming happens at that level, not per-entry. Also force-enables the
    /// group itself: old-UI data could have a scenario group that was toggled off (via
    /// the previous per-group toggle), and `ForecastCalculator` only counts confirmed
    /// entries from *enabled* groups — without this, confirming a disabled scenario would
    /// leave it showing as "confirmed" while silently contributing £0 to every total.
    /// Write-first: every entry and the group are updated in the same transaction, and
    /// `entries`/`groups` are only mutated once the whole write succeeds. Deselects the
    /// scenario afterward if it was selected, since a confirmed scenario is no longer a
    /// "preview" — it's already part of the confirmed forecast.
    @discardableResult
    func confirmScenario(_ group: ForecastGroup) -> Bool {
        errorMessage = nil
        let indices = entries.indices.filter { entries[$0].groupId == group.id }
        guard !indices.isEmpty else { return false }
        var updated = entries
        for i in indices { updated[i].status = .confirmed }
        var updatedGroup = group
        updatedGroup.isEnabled = true
        do {
            try dbQueue.write { db in
                for i in indices { try updated[i].update(db) }
                try updatedGroup.update(db)
            }
        } catch {
            errorMessage = "Couldn't confirm this scenario: \(error.localizedDescription)"
            return false
        }
        entries = updated
        if let groupIndex = groups.firstIndex(where: { $0.id == group.id }) {
            groups[groupIndex] = updatedGroup
        }
        if selectedScenarioGroupId == group.id { selectedScenarioGroupId = nil }
        recomputeForecastCaches()
        return true
    }

    /// Creates a new category — used by `ScenarioItemFormView`'s inline "+ New category…"
    /// flow, for a scenario item whose category doesn't exist yet. Write-first,
    /// mutate-on-success, like the other mutators in this file. Returns the created
    /// category (with its assigned id) on success, `nil` on failure (also sets
    /// `errorMessage`).
    func createCategory(name: String, type: CategoryType) -> Category? {
        errorMessage = nil
        var category = Category(name: name, type: type)
        do {
            try dbQueue.write { db in try category.insert(db) }
        } catch {
            errorMessage = "Couldn't create this category: \(error.localizedDescription)"
            return nil
        }
        categories.append(category)
        return category
    }

    // MARK: - Reserves

    /// Reserved (forecast-only) categories, sorted by name.
    var reserves: [Category] { categories.filter(\.isReserved).sorted { $0.name < $1.name } }

    /// The forecast entries (allowances) filed under `reserve`, oldest start first.
    func reserveEntries(_ reserve: Category) -> [ForecastEntry] {
        entries.filter { $0.categoryId == reserve.id }.sorted { $0.startDate < $1.startDate }
    }

    /// Sum of every reserve's month total (confirmed, or preview when `preview`) — each the
    /// remaining allowance after the month's unforecast spending.
    func reserveTotal(year: Int, month: Int, preview: Bool) -> Int {
        reserves.reduce(0) { $0 + (preview ? previewCategoryTotal($1, year: year, month: month) : categoryTotal($1, year: year, month: month)) }
    }

    /// Creates a reserve and its first confirmed allowance in one write. Write-first,
    /// reload on success, `errorMessage` on failure.
    @discardableResult
    func addReserve(name: String, amountMinorUnits: Int, frequency: ForecastFrequency, interval: Int, startDate: Date, endDate: Date?) -> Bool {
        errorMessage = nil
        do {
            try dbQueue.write { db in
                try ReservedCategories.addReserve(db: db, name: name, amountMinorUnits: amountMinorUnits, frequency: frequency, interval: interval, startDate: startDate, endDate: endDate)
            }
        } catch ReservedCategoryError.duplicateName {
            errorMessage = "A category with that name already exists."
            return false
        } catch ReservedCategoryError.emptyName {
            errorMessage = "Enter a name."
            return false
        } catch {
            errorMessage = "Couldn't add this reserve: \(error.localizedDescription)"
            return false
        }
        try? load()
        return true
    }

    /// Adds another confirmed allowance to an existing reserve.
    @discardableResult
    func addReserveAmount(to reserve: Category, amountMinorUnits: Int, frequency: ForecastFrequency, interval: Int, startDate: Date, endDate: Date?) -> Bool {
        errorMessage = nil
        guard let reserveId = reserve.id else { return false }
        do {
            try dbQueue.write { db in
                let group = try ReservedCategories.ensureGroup(db: db)
                var entry = ForecastEntry(groupId: group.id!, categoryId: reserveId, amountMinorUnits: -abs(amountMinorUnits), frequency: frequency, interval: interval, startDate: startDate, endDate: endDate, isEnabled: true, status: .confirmed, note: nil)
                try entry.insert(db)
            }
        } catch {
            errorMessage = "Couldn't add this amount: \(error.localizedDescription)"
            return false
        }
        try? load()
        return true
    }

    @discardableResult
    func renameReserve(_ reserve: Category, to name: String) -> Bool {
        errorMessage = nil
        guard let reserveId = reserve.id else { return false }
        do {
            try dbQueue.write { db in try ReservedCategories.rename(db: db, categoryId: reserveId, to: name) }
        } catch ReservedCategoryError.duplicateName {
            errorMessage = "A category with that name already exists."
            return false
        } catch ReservedCategoryError.emptyName {
            errorMessage = "Enter a name."
            return false
        } catch {
            errorMessage = "Couldn't rename this reserve: \(error.localizedDescription)"
            return false
        }
        try? load()
        return true
    }

    /// Deletes a reserve and its allowances (see `ReservedCategories.delete`).
    @discardableResult
    func deleteReserve(_ reserve: Category) -> Bool {
        errorMessage = nil
        guard let reserveId = reserve.id else { return false }
        do {
            try dbQueue.write { db in try ReservedCategories.delete(db: db, categoryId: reserveId) }
        } catch {
            errorMessage = "Couldn't delete this reserve: \(error.localizedDescription)"
            return false
        }
        try? load()
        return true
    }
}
