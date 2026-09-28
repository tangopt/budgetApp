// App/Forecast/ForecastViewModel.swift
import Foundation
import BudgetCore
import struct BudgetCore.Category
import GRDB

@MainActor
final class ForecastViewModel: ObservableObject {
    @Published var groups: [ForecastGroup] = []
    @Published var entries: [ForecastEntry] = []
    @Published var categories: [Category] = []
    @Published var categoryGroups: [CategoryGroup] = []
    @Published var accounts: [Account] = []
    @Published var balanceSnapshots: [BalanceSnapshot] = []
    @Published var transactions: [Transaction] = [] {
        didSet { calendarTotals = BudgetGridCalculator.calendarTotalsLookup(transactions: transactions) }
    }
    @Published var exchangeRate: ExchangeRateSetting = ExchangeRateSetting(eurToGbpRate: 0.87, updatedAt: Date())
    @Published var errorMessage: String?
    /// The scenario (non-system-managed `ForecastGroup`) currently previewed in the grid
    /// and headline. `nil` means "None (confirmed only)" — the default. Ephemeral: reset
    /// to `nil` on every `load()`, never persisted. Changing it changes what
    /// `previewCategoryTotal`/`scenarioNetWorthImpact` compute, so it must trigger the
    /// same cache rebuild any other cache-affecting mutation does.
    @Published var selectedScenarioGroupId: Int64? {
        didSet { recomputeForecastCaches() }
    }
    /// (year, month) of the latest transaction date across everything `load()` fetched.
    /// `nil` before the first successful `load()`, or if there's no transaction data at
    /// all.
    @Published private(set) var latestRealMonth: (year: Int, month: Int)?

    private let dbQueue: DatabaseQueue
    private var calendarTotals: [Int64: [Int: [Int: Int]]] = [:]
    /// Precomputed confirmed/preview forecast totals for every (category, year, month)
    /// cell, covering `thisYear` and `nextYear` — rebuilt by `recomputeForecastCaches()`
    /// at the end of `load()`, after any mutation that changes `entries`/`groups`, and
    /// whenever `selectedScenarioGroupId` changes (the `preview` half of this cache is
    /// scenario-dependent). `ForecastView.body` re-evaluates on every horizontal-scroll-
    /// offset change (same frozen-header/frozen-column technique as the Budget grid),
    /// which would otherwise re-run `ForecastCalculator` for every visible cell on every
    /// scroll frame — measured at ~30ms per full-grid pass against the live database,
    /// well over a 60fps frame budget. Only consulted for *forecast* (non-actual) months;
    /// actual months already have an O(1) path via `calendarTotals`. Keyed by
    /// categoryId → year → month.
    private var forecastTotalsCache: [Int64: [Int: [Int: (confirmed: Int, preview: Int)]]] = [:]
    /// Precomputed `forecastNetWorth`/`forecastNetWorthYoY`/`scenarioNetWorthImpact`
    /// results for `thisYear` and `nextYear` — the headline figures `ForecastView` shows.
    /// Rebuilt alongside `forecastTotalsCache` for the same reason. Keyed by year.
    private var netWorthHeadlineCache: [Int: (forecast: Int?, yoy: (changeGBP: Int, percent: Double?)?, scenarioImpact: Int?)] = [:]
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
        categories = try dbQueue.read { db in try Category.fetchAll(db) }
        categoryGroups = try dbQueue.read { db in try CategoryGroup.fetchAll(db) }
        accounts = try dbQueue.read { db in try Account.fetchAll(db) }
        balanceSnapshots = try dbQueue.read { db in try BalanceSnapshot.fetchAll(db) }
        transactions = try dbQueue.read { db in try Transaction.fetchAll(db) }
        exchangeRate = try dbQueue.read { db in try ExchangeRateSetting.currentOrDefault(db: db) }
        latestRealMonth = Self.computeLatestRealMonth(transactions: transactions, calendar: Self.calendar)
        selectedScenarioGroupId = nil // resets caches via its own didSet, so no separate recomputeForecastCaches() call needed here
    }

    /// Rebuilds `forecastTotalsCache` and `netWorthHeadlineCache` from current state.
    /// Called once at the end of `load()` (indirectly, via `selectedScenarioGroupId`'s
    /// `didSet` — several other properties `load()` sets, e.g. `latestRealMonth`, are only
    /// valid once everything else is already in place, so resetting `selectedScenarioGroupId`
    /// last and letting its `didSet` fire the rebuild avoids rebuilding with a partially-
    /// updated, stale mix of state) and after every mutation that changes `entries`/
    /// `groups`/`selectedScenarioGroupId`.
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
                        ForecastCalculator.confirmedTotal(categoryId: categoryId, period: period, entries: entries, groups: groups),
                        ForecastCalculator.previewTotal(categoryId: categoryId, period: period, entries: entries, groups: groups, selectedScenarioGroupId: selectedScenarioGroupId)
                    )
                }
                byYear[year] = byMonth
            }
            totals[categoryId] = byYear
        }
        forecastTotalsCache = totals

        var headline: [Int: (forecast: Int?, yoy: (changeGBP: Int, percent: Double?)?, scenarioImpact: Int?)] = [:]
        for year in [thisYear, nextYear] {
            headline[year] = (computeForecastNetWorth(atEndOf: year), computeForecastNetWorthYoY(atEndOf: year), computeScenarioNetWorthImpact(atEndOf: year))
        }
        netWorthHeadlineCache = headline
    }

    /// Transaction dates only — deliberately NOT balance snapshot dates. A balance
    /// snapshot recorded via the Net Worth screen's "Update a balance…" flow is stamped
    /// with `Date()` (today), regardless of how stale the imported transaction data is.
    /// If snapshot dates fed into this cutoff, recording any balance update would jump
    /// `latestRealMonth` straight to today's month, retroactively flipping every
    /// in-between month from "forecast" to "actual" in the grid — and since there's no
    /// transaction data for those months, every category cell in them would render blank
    /// ("—"), and the net-worth projection would silently skip their forecasted
    /// contribution. `realNetWorth`/`currentNetWorthGBP` still use `balanceSnapshots` as
    /// before — that's a separate concern (actual account balances), not this actual/
    /// forecast month cutoff.
    private static func computeLatestRealMonth(transactions: [Transaction], calendar: Calendar) -> (year: Int, month: Int)? {
        guard let latest = transactions.map(\.date).max() else { return nil }
        let components = calendar.dateComponents([.year, .month], from: latest)
        guard let year = components.year, let month = components.month else { return nil }
        return (year, month)
    }

    /// True when `(year, month)` is on or before `latestRealMonth` — `categoryTotal`
    /// returns the actual transaction total for it rather than the confirmed forecast.
    func isActual(year: Int, month: Int) -> Bool {
        guard let latestRealMonth else { return false }
        if year != latestRealMonth.year { return year < latestRealMonth.year }
        return month <= latestRealMonth.month
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

    /// The category's total for one month: the actual transaction total when the month
    /// is real (`isActual`), the confirmed forecast otherwise (read from
    /// `forecastTotalsCache`, falling back to a direct calculation for a cache miss).
    func categoryTotal(_ category: Category, year: Int, month: Int) -> Int {
        if isActual(year: year, month: month) {
            return BudgetGridCalculator.categoryTotalForCalendarMonth(category: category, year: year, month: month, calendarTotals: calendarTotals)
        }
        guard let categoryId = category.id else { return 0 }
        if let cached = forecastTotalsCache[categoryId]?[year]?[month] { return cached.confirmed }
        let range = dateRange(forYear: year, month: month)
        return ForecastCalculator.confirmedTotal(categoryId: categoryId, period: PayPeriod(startDate: range.start, endDate: range.end, type: .projected), entries: entries, groups: groups)
    }

    /// Confirmed total plus the selected scenario's `.hypothetical` entries, if any. For
    /// an actual month this always equals `categoryTotal` — a hypothetical can't
    /// retroactively change history. Reads from `forecastTotalsCache` for a forecast
    /// month, same fallback as `categoryTotal`.
    func previewCategoryTotal(_ category: Category, year: Int, month: Int) -> Int {
        if isActual(year: year, month: month) {
            return categoryTotal(category, year: year, month: month)
        }
        guard let categoryId = category.id else { return 0 }
        if let cached = forecastTotalsCache[categoryId]?[year]?[month] { return cached.preview }
        let range = dateRange(forYear: year, month: month)
        return ForecastCalculator.previewTotal(categoryId: categoryId, period: PayPeriod(startDate: range.start, endDate: range.end, type: .projected), entries: entries, groups: groups, selectedScenarioGroupId: selectedScenarioGroupId)
    }

    private var currentNetWorthGBP: Int {
        NetWorthCalculator.netWorth(balances: NetWorthCalculator.accountBalances(accounts: accounts, snapshots: balanceSnapshots, transactions: transactions, rate: exchangeRate))
    }

    /// Total real net worth as of December of `year`, using only real balance snapshot
    /// data (no forecast) — the same calculation `BudgetGridViewModel.netWorthTotal` uses.
    private func realNetWorth(atEndOf year: Int) -> Int {
        let range = dateRange(forYear: year, month: 12)
        return accounts.reduce(0) { sum, account in
            sum + (NetWorthCalculator.monthlyBalance(account: account, snapshots: balanceSnapshots, transactions: transactions, rate: exchangeRate, monthStart: range.start, monthEnd: range.end)?.gbpBalanceMinorUnits ?? 0)
        }
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
        var netChange = 0
        var cursor = (year: latestRealMonth.year, month: latestRealMonth.month + 1)
        if cursor.month > 12 { cursor = (cursor.year + 1, 1) }
        while cursor.year < year || (cursor.year == year && cursor.month <= 12) {
            let range = dateRange(forYear: cursor.year, month: cursor.month)
            netChange += ForecastCalculator.confirmedNetWorthImpact(period: PayPeriod(startDate: range.start, endDate: range.end, type: .projected), categories: categories, entries: entries, groups: groups)
            cursor.month += 1
            if cursor.month > 12 { cursor = (cursor.year + 1, 1) }
        }
        return currentNetWorthGBP + netChange
    }

    /// `forecastNetWorth(atEndOf: year)` compared to a baseline: last year's real
    /// year-end net worth when December of `year - 1` is actually covered by real data,
    /// or last year's *forecast* year-end net worth otherwise. `percent` is `nil` when the
    /// baseline is zero. Reads from `netWorthHeadlineCache`, falling back to a direct
    /// calculation for a cache miss.
    func forecastNetWorthYoY(atEndOf year: Int) -> (changeGBP: Int, percent: Double?)? {
        netWorthHeadlineCache[year]?.yoy ?? computeForecastNetWorthYoY(atEndOf: year)
    }

    private func computeForecastNetWorthYoY(atEndOf year: Int) -> (changeGBP: Int, percent: Double?)? {
        guard let forecast = computeForecastNetWorth(atEndOf: year) else { return nil }
        let baseline = isActual(year: year - 1, month: 12) ? realNetWorth(atEndOf: year - 1) : (computeForecastNetWorth(atEndOf: year - 1) ?? 0)
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
        guard let selectedScenarioGroupId, let latestRealMonth else { return nil }
        var delta = 0
        var cursor = (year: latestRealMonth.year, month: latestRealMonth.month + 1)
        if cursor.month > 12 { cursor = (cursor.year + 1, 1) }
        while cursor.year < year || (cursor.year == year && cursor.month <= 12) {
            let range = dateRange(forYear: cursor.year, month: cursor.month)
            delta += ForecastCalculator.previewNetWorthDelta(period: PayPeriod(startDate: range.start, endDate: range.end, type: .projected), categories: categories, entries: entries, groups: groups, selectedScenarioGroupId: selectedScenarioGroupId)
            cursor.month += 1
            if cursor.month > 12 { cursor = (cursor.year + 1, 1) }
        }
        return delta
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

    func confirm(_ entry: ForecastEntry) {
        guard let index = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        entries[index].status = .confirmed
        try? dbQueue.write { db in try entries[index].update(db) }
        recomputeForecastCaches()
    }

    /// Edits an entry's amount/frequency/interval/end-date. If it was auto-detected, this
    /// promotes it to `.manual` so a future `AutoForecastGenerator.refresh` won't silently
    /// overwrite the edit — mirrors the generator's own skip-on-manual-tuning behavior.
    ///
    /// The write happens against a locally-built copy first; `entries` is only mutated
    /// once that write has actually succeeded, mirroring `BudgetGridViewModel.recategorize`.
    @discardableResult
    func updateEntry(_ entry: ForecastEntry, amountMinorUnits: Int, frequency: ForecastFrequency, interval: Int, endDate: Date?) -> Bool {
        errorMessage = nil
        guard let index = entries.firstIndex(where: { $0.id == entry.id }) else { return false }
        var updated = entries[index]
        updated.amountMinorUnits = amountMinorUnits
        updated.frequency = frequency
        updated.interval = interval
        updated.endDate = endDate
        if updated.status == .auto {
            updated.status = .manual
        }
        do {
            try dbQueue.write { db in try updated.update(db) }
        } catch {
            errorMessage = "Couldn't save the change: \(error.localizedDescription)"
            return false
        }
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
    /// hypothetical entries in a single write. `items` is expected non-empty — the UI
    /// disables Save with zero items, so this is a precondition, not a runtime error path.
    func createScenario(name: String, items: [ScenarioItem]) {
        try? dbQueue.write { db in
            var group = ForecastGroup(name: name, note: nil, isEnabled: true, isSystemManaged: false)
            try group.insert(db)
            for item in items {
                var entry = ForecastEntry(groupId: group.id!, categoryId: item.categoryId, amountMinorUnits: item.amountMinorUnits, frequency: item.frequency, interval: item.interval, startDate: item.startDate, endDate: item.endDate, isEnabled: true, status: .hypothetical, note: nil)
                try entry.insert(db)
            }
        }
        groups = (try? dbQueue.read { db in try ForecastGroup.fetchAll(db) }) ?? groups
        entries = (try? dbQueue.read { db in try ForecastEntry.fetchAll(db) }) ?? entries
        recomputeForecastCaches()
    }

    /// Adds one more item to an existing scenario group.
    func addItem(to group: ForecastGroup, _ item: ScenarioItem) {
        try? dbQueue.write { db in
            var entry = ForecastEntry(groupId: group.id!, categoryId: item.categoryId, amountMinorUnits: item.amountMinorUnits, frequency: item.frequency, interval: item.interval, startDate: item.startDate, endDate: item.endDate, isEnabled: true, status: .hypothetical, note: nil)
            try entry.insert(db)
        }
        entries = (try? dbQueue.read { db in try ForecastEntry.fetchAll(db) }) ?? entries
        recomputeForecastCaches()
    }

    /// Confirms every entry in `group` at once — a scenario is the unit the user thinks
    /// in, so confirming happens at that level, not per-entry. Write-first: every entry is
    /// updated in the same transaction, and `entries` is only mutated once the whole write
    /// succeeds. Deselects the scenario afterward if it was selected, since a confirmed
    /// scenario is no longer a "preview" — it's already part of the confirmed forecast.
    @discardableResult
    func confirmScenario(_ group: ForecastGroup) -> Bool {
        errorMessage = nil
        let indices = entries.indices.filter { entries[$0].groupId == group.id }
        guard !indices.isEmpty else { return false }
        var updated = entries
        for i in indices { updated[i].status = .confirmed }
        do {
            try dbQueue.write { db in
                for i in indices { try updated[i].update(db) }
            }
        } catch {
            errorMessage = "Couldn't confirm this scenario: \(error.localizedDescription)"
            return false
        }
        entries = updated
        if selectedScenarioGroupId == group.id { selectedScenarioGroupId = nil }
        recomputeForecastCaches()
        return true
    }
}
