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
    @Published var accounts: [Account] = []
    @Published var balanceSnapshots: [BalanceSnapshot] = []
    @Published var transactions: [Transaction] = [] {
        didSet { calendarTotals = BudgetGridCalculator.calendarTotalsLookup(transactions: transactions) }
    }
    @Published var exchangeRate: ExchangeRateSetting = ExchangeRateSetting(eurToGbpRate: 0.87, updatedAt: Date())
    @Published var errorMessage: String?
    /// (year, month) of the latest transaction date across everything `load()` fetched.
    /// `nil` before the first successful `load()`, or if there's no transaction data at
    /// all.
    @Published private(set) var latestRealMonth: (year: Int, month: Int)?

    private let dbQueue: DatabaseQueue
    private var calendarTotals: [Int64: [Int: [Int: Int]]] = [:]
    /// Precomputed confirmed/preview forecast totals for every (category, year, month)
    /// cell, covering `thisYear` and `nextYear` — rebuilt by `recomputeForecastCaches()`
    /// at the end of `load()` and after any mutation that changes `entries`/`groups`
    /// (toggling, editing, confirming, adding a hypothetical). `ForecastView.body`
    /// re-evaluates on every horizontal-scroll-offset change (same frozen-header/frozen-
    /// column technique as the Budget grid), which would otherwise re-run
    /// `ForecastCalculator` (`FrequencyExpander` occurrence-counting plus `Calendar` date
    /// arithmetic) for every visible cell on every scroll frame — measured at ~30ms per
    /// full-grid pass against the live database (56 categories, 12 forecast entries),
    /// well over a 60fps frame budget, which would cause visible stutter. Only consulted
    /// for *forecast* (non-actual) months; actual months already have an O(1) path via
    /// `calendarTotals`. Keyed by categoryId → year → month.
    private var forecastTotalsCache: [Int64: [Int: [Int: (confirmed: Int, preview: Int)]]] = [:]
    /// Precomputed `forecastNetWorth`/`forecastNetWorthYoY` results for `thisYear` and
    /// `nextYear` — the four net-worth headline figures `ForecastView` shows. Rebuilt
    /// alongside `forecastTotalsCache` for the same reason: both underlying functions sum
    /// `ForecastCalculator.confirmedNetWorthImpact` across every category for every month
    /// since `latestRealMonth`, so recomputing them on every scroll frame is the same cost
    /// problem. Keyed by year.
    private var netWorthHeadlineCache: [Int: (forecast: Int?, yoy: (changeGBP: Int, percent: Double?)?)] = [:]
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
        accounts = try dbQueue.read { db in try Account.fetchAll(db) }
        balanceSnapshots = try dbQueue.read { db in try BalanceSnapshot.fetchAll(db) }
        transactions = try dbQueue.read { db in try Transaction.fetchAll(db) }
        exchangeRate = try dbQueue.read { db in try ExchangeRateSetting.currentOrDefault(db: db) }
        latestRealMonth = Self.computeLatestRealMonth(transactions: transactions, calendar: Self.calendar)
        recomputeForecastCaches()
    }

    /// Rebuilds `forecastTotalsCache` and `netWorthHeadlineCache` from the current
    /// `categories`/`entries`/`groups`/`accounts`/`balanceSnapshots`/`transactions`/
    /// `latestRealMonth`. Called once at the end of `load()` (not via a `didSet` on each
    /// contributing property — several of them, e.g. `latestRealMonth`, are only valid
    /// once everything else `load()` fetches is already in place, so a single explicit
    /// call after `load()` finishes avoids rebuilding with a partially-updated, stale
    /// mix of state) and again after every mutation that changes `entries`/`groups`.
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
                        ForecastCalculator.previewTotal(categoryId: categoryId, period: period, entries: entries, groups: groups)
                    )
                }
                byYear[year] = byMonth
            }
            totals[categoryId] = byYear
        }
        forecastTotalsCache = totals

        var headline: [Int: (forecast: Int?, yoy: (changeGBP: Int, percent: Double?)?)] = [:]
        for year in [thisYear, nextYear] {
            headline[year] = (computeForecastNetWorth(atEndOf: year), computeForecastNetWorthYoY(atEndOf: year))
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
        // `end` is the LAST MOMENT of the month's last day, not midnight at its start.
        // `FrequencyExpander` checks occurrences inclusively against `end`, and a
        // `ForecastEntry.startDate` can carry a real time-of-day (e.g. `Date()`, the
        // default in `NewForecastEntryView`) — midnight on the last day would silently
        // exclude any occurrence later that same day. "One second before next month
        // starts" is unambiguously the last day's last second regardless of month length
        // or leap years.
        let end = Self.calendar.date(byAdding: .month, value: 1, to: start)!.addingTimeInterval(-1)
        return (start, end)
    }

    /// The category's total for one month: the actual transaction total when the month
    /// is real (`isActual`), the confirmed forecast otherwise (read from
    /// `forecastTotalsCache`, falling back to a direct calculation for a cache miss —
    /// e.g. a year outside `thisYear`/`nextYear`, or before the first `load()`).
    func categoryTotal(_ category: Category, year: Int, month: Int) -> Int {
        if isActual(year: year, month: month) {
            return BudgetGridCalculator.categoryTotalForCalendarMonth(category: category, year: year, month: month, calendarTotals: calendarTotals)
        }
        guard let categoryId = category.id else { return 0 }
        if let cached = forecastTotalsCache[categoryId]?[year]?[month] { return cached.confirmed }
        let range = dateRange(forYear: year, month: month)
        return ForecastCalculator.confirmedTotal(categoryId: categoryId, period: PayPeriod(startDate: range.start, endDate: range.end, type: .projected), entries: entries, groups: groups)
    }

    /// Confirmed total plus enabled `.hypothetical` entries. For an actual month this
    /// always equals `categoryTotal` — a hypothetical can't retroactively change history.
    /// Reads from `forecastTotalsCache` for a forecast month, same fallback as
    /// `categoryTotal`.
    func previewCategoryTotal(_ category: Category, year: Int, month: Int) -> Int {
        if isActual(year: year, month: month) {
            return categoryTotal(category, year: year, month: month)
        }
        guard let categoryId = category.id else { return 0 }
        if let cached = forecastTotalsCache[categoryId]?[year]?[month] { return cached.preview }
        let range = dateRange(forYear: year, month: month)
        return ForecastCalculator.previewTotal(categoryId: categoryId, period: PayPeriod(startDate: range.start, endDate: range.end, type: .projected), entries: entries, groups: groups)
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
    /// there's no `latestRealMonth` yet (no data loaded at all). Reads from
    /// `netWorthHeadlineCache`, falling back to a direct calculation for a cache miss.
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
    /// year-end net worth when December of `year - 1` is actually covered by real data
    /// (`isActual(year: year - 1, month: 12)`), or last year's *forecast* year-end net
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
        let baseline = isActual(year: year - 1, month: 12) ? realNetWorth(atEndOf: year - 1) : (computeForecastNetWorth(atEndOf: year - 1) ?? 0)
        let change = forecast - baseline
        let percent: Double? = baseline != 0 ? Double(change) / Double(abs(baseline)) : nil
        return (change, percent)
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

    /// Edits an entry's amount/frequency/interval. If it was auto-detected, this promotes
    /// it to `.manual` so a future `AutoForecastGenerator.refresh` won't silently
    /// overwrite the edit — mirrors the generator's own skip-on-manual-tuning behavior.
    ///
    /// The write happens against a locally-built copy first; `entries` is only mutated
    /// once that write has actually succeeded, mirroring `BudgetGridViewModel.recategorize`.
    @discardableResult
    func updateEntry(_ entry: ForecastEntry, amountMinorUnits: Int, frequency: ForecastFrequency, interval: Int) -> Bool {
        errorMessage = nil
        guard let index = entries.firstIndex(where: { $0.id == entry.id }) else { return false }
        var updated = entries[index]
        updated.amountMinorUnits = amountMinorUnits
        updated.frequency = frequency
        updated.interval = interval
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

    func addHypotheticalEntry(groupName: String, categoryId: Int64, amountMinorUnits: Int, frequency: ForecastFrequency, interval: Int, startDate: Date) {
        try? dbQueue.write { db in
            let group: ForecastGroup
            if let existing = try ForecastGroup.filter(Column("name") == groupName).fetchOne(db) {
                group = existing
            } else {
                var newGroup = ForecastGroup(name: groupName, note: nil, isEnabled: true, isSystemManaged: false)
                try newGroup.insert(db)
                group = newGroup
            }
            var entry = ForecastEntry(groupId: group.id!, categoryId: categoryId, amountMinorUnits: amountMinorUnits, frequency: frequency, interval: interval, startDate: startDate, endDate: nil, isEnabled: true, status: .hypothetical, note: nil)
            try entry.insert(db)
        }
        groups = (try? dbQueue.read { db in try ForecastGroup.fetchAll(db) }) ?? groups
        entries = (try? dbQueue.read { db in try ForecastEntry.fetchAll(db) }) ?? entries
        recomputeForecastCaches()
    }
}
