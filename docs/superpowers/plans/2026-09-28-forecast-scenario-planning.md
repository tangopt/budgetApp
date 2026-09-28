# Forecast Scenario Planning & Management Panel Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the Forecast screen's bottom "Manage forecast" disclosure group with a right-side panel that supports multi-item scenarios (each item optionally end-dated), lets exactly one scenario preview at a time with its net-worth impact shown explicitly, confirms a scenario's entries all at once, and gives the Forecast grid the same category-group collapsing the Budget grid already has.

**Architecture:** A scenario is the existing `ForecastGroup` concept, unchanged in the database — no migration. `ForecastCalculator.previewTotal` gains a `selectedScenarioGroupId` parameter so exactly one scenario's hypothetical entries count toward the preview at a time, replacing today's "every enabled group blends together." `ForecastViewModel` gains scenario-level create/add-item/confirm methods (all still simple GRDB writes) and threads `endDate` through entry creation/editing. `ForecastView`'s body becomes an `HStack` (grid + a fixed-width right panel) instead of one scrolling `VStack`; the grid itself gains category-group rows mirroring `BudgetGridView`'s existing pattern.

**Tech Stack:** Swift, SwiftUI, GRDB (existing stack — no new dependencies).

**Spec:** `docs/superpowers/specs/2026-09-28-forecast-scenario-planning-design.md`

## Global Constraints

- No schema or migration changes — `ForecastEntry.endDate` and `ForecastGroup` already exist with everything this plan needs.
- "Confirmed" forecast still drives every grid cell's primary (bold) line and both net-worth headline stat blocks — a selected scenario's effect is additive (the existing amber preview line, plus one new impact figure), never a replacement.
- Exactly one scenario (or none) previews at a time. Selection is ephemeral `@Published` view-model state, not persisted.
- Confirming a scenario confirms every entry in it in one action; from then on it behaves like "Detected recurring" — always contributing, no longer selectable.
- Category groups in the grid reuse the existing `CategoryGroup`/`groupId` mechanism verbatim.
- `ForecastCalculator.confirmedTotal`'s public signature does not change.

---

### Task 1: `ForecastCalculator` — scenario-scoped preview

**Files:**
- Modify: `Sources/BudgetCore/Forecasting/ForecastCalculator.swift`
- Test: `Tests/BudgetCoreTests/ForecastCalculatorTests.swift`

**Interfaces:**
- Consumes: existing `FrequencyExpander.amount(for:in:)`, `Category`, `PayPeriod`, `ForecastEntry`, `ForecastGroup` (all existing models). `ForecastCalculator.confirmedTotal` (existing, unchanged signature).
- Produces: `ForecastCalculator.previewTotal(categoryId:period:entries:groups:selectedScenarioGroupId:) -> Int` (signature changed — new required `selectedScenarioGroupId: Int64?` parameter), `ForecastCalculator.previewNetWorthDelta(period:categories:entries:groups:selectedScenarioGroupId:) -> Int` (new). Both consumed by Task 2.

- [ ] **Step 1: Update the existing `previewTotal` test and write the new failing tests**

In `Tests/BudgetCoreTests/ForecastCalculatorTests.swift`, replace `testPreviewTotalAddsEnabledHypotheticals` (it currently calls `previewTotal` without the new parameter, so it won't compile once Step 3 lands — update it now to pass `selectedScenarioGroupId: 1`, matching the group id its hypothetical entry belongs to, so its assertion still holds under the new scoping):

```swift
    func testPreviewTotalAddsSelectedScenarioHypotheticals() {
        let period = PayPeriod(startDate: date(2026, 8, 26), endDate: date(2026, 9, 25), type: .projected)
        let groups = [ForecastGroup(id: 1, name: "Detected recurring", note: nil, isEnabled: true, isSystemManaged: true)]
        let entries = [
            ForecastEntry(id: 1, groupId: 1, categoryId: 10, amountMinorUnits: -280000, frequency: .monthly, interval: 1, startDate: date(2026, 6, 26), endDate: nil, isEnabled: true, status: .auto, note: nil),
            ForecastEntry(id: 2, groupId: 1, categoryId: 10, amountMinorUnits: -5000, frequency: .monthly, interval: 1, startDate: date(2026, 6, 26), endDate: nil, isEnabled: true, status: .hypothetical, note: nil)
        ]
        let preview = ForecastCalculator.previewTotal(categoryId: 10, period: period, entries: entries, groups: groups, selectedScenarioGroupId: 1)
        XCTAssertEqual(preview, -285000)
    }

    func testPreviewTotalExcludesHypotheticalsFromUnselectedScenario() {
        let period = PayPeriod(startDate: date(2026, 8, 26), endDate: date(2026, 9, 25), type: .projected)
        let groups = [
            ForecastGroup(id: 1, name: "Detected recurring", note: nil, isEnabled: true, isSystemManaged: true),
            ForecastGroup(id: 2, name: "New car", note: nil, isEnabled: true, isSystemManaged: false)
        ]
        let entries = [
            ForecastEntry(id: 1, groupId: 1, categoryId: 10, amountMinorUnits: -280000, frequency: .monthly, interval: 1, startDate: date(2026, 6, 26), endDate: nil, isEnabled: true, status: .auto, note: nil),
            // This scenario's group (id 2) is enabled, but it isn't the *selected* one (id 1 is selected below) — its hypothetical must not count.
            ForecastEntry(id: 2, groupId: 2, categoryId: 10, amountMinorUnits: -35000, frequency: .monthly, interval: 1, startDate: date(2026, 6, 26), endDate: nil, isEnabled: true, status: .hypothetical, note: nil)
        ]
        let preview = ForecastCalculator.previewTotal(categoryId: 10, period: period, entries: entries, groups: groups, selectedScenarioGroupId: 1)
        XCTAssertEqual(preview, -280000) // only the auto entry — group 2's hypothetical is excluded
    }

    func testPreviewTotalWithNoSelectionExcludesAllHypotheticals() {
        let period = PayPeriod(startDate: date(2026, 8, 26), endDate: date(2026, 9, 25), type: .projected)
        let groups = [ForecastGroup(id: 1, name: "Detected recurring", note: nil, isEnabled: true, isSystemManaged: true)]
        let entries = [
            ForecastEntry(id: 1, groupId: 1, categoryId: 10, amountMinorUnits: -280000, frequency: .monthly, interval: 1, startDate: date(2026, 6, 26), endDate: nil, isEnabled: true, status: .auto, note: nil),
            ForecastEntry(id: 2, groupId: 1, categoryId: 10, amountMinorUnits: -5000, frequency: .monthly, interval: 1, startDate: date(2026, 6, 26), endDate: nil, isEnabled: true, status: .hypothetical, note: nil)
        ]
        let preview = ForecastCalculator.previewTotal(categoryId: 10, period: period, entries: entries, groups: groups, selectedScenarioGroupId: nil)
        XCTAssertEqual(preview, -280000)
    }

    func testPreviewNetWorthDeltaSumsSelectedScenarioIncomeMinusExpensesExcludingTransfers() {
        let period = PayPeriod(startDate: date(2026, 3, 1), endDate: date(2026, 3, 31), type: .projected)
        let salary = Category(id: 1, name: "Bonus", type: .income)
        let carPayment = Category(id: 2, name: "Car Payments", type: .expense)
        let transfer = Category(id: 3, name: "Transfer: ISA", type: .transfer)
        let groups = [ForecastGroup(id: 2, name: "New car", note: nil, isEnabled: true, isSystemManaged: false)]
        let entries = [
            ForecastEntry(id: 1, groupId: 2, categoryId: 1, amountMinorUnits: 100000, frequency: .monthly, interval: 1, startDate: date(2026, 1, 1), endDate: nil, isEnabled: true, status: .hypothetical, note: nil),
            ForecastEntry(id: 2, groupId: 2, categoryId: 2, amountMinorUnits: -35000, frequency: .monthly, interval: 1, startDate: date(2026, 1, 1), endDate: nil, isEnabled: true, status: .hypothetical, note: nil),
            ForecastEntry(id: 3, groupId: 2, categoryId: 3, amountMinorUnits: -20000, frequency: .monthly, interval: 1, startDate: date(2026, 1, 1), endDate: nil, isEnabled: true, status: .hypothetical, note: nil)
        ]
        let delta = ForecastCalculator.previewNetWorthDelta(period: period, categories: [salary, carPayment, transfer], entries: entries, groups: groups, selectedScenarioGroupId: 2)
        XCTAssertEqual(delta, 100000 - 35000) // transfer excluded; delta is preview minus confirmed (0, nothing confirmed here)
    }

    func testPreviewNetWorthDeltaIsZeroWithNoSelection() {
        let period = PayPeriod(startDate: date(2026, 3, 1), endDate: date(2026, 3, 31), type: .projected)
        let carPayment = Category(id: 2, name: "Car Payments", type: .expense)
        let groups = [ForecastGroup(id: 2, name: "New car", note: nil, isEnabled: true, isSystemManaged: false)]
        let entries = [
            ForecastEntry(id: 2, groupId: 2, categoryId: 2, amountMinorUnits: -35000, frequency: .monthly, interval: 1, startDate: date(2026, 1, 1), endDate: nil, isEnabled: true, status: .hypothetical, note: nil)
        ]
        let delta = ForecastCalculator.previewNetWorthDelta(period: period, categories: [carPayment], entries: entries, groups: groups, selectedScenarioGroupId: nil)
        XCTAssertEqual(delta, 0)
    }
```

Delete the old `testPreviewTotalAddsEnabledHypotheticals` test (replaced by `testPreviewTotalAddsSelectedScenarioHypotheticals` above — same assertion, updated call).

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter ForecastCalculatorTests`
Expected: FAIL to compile — `previewTotal` doesn't have a `selectedScenarioGroupId` parameter yet, and `previewNetWorthDelta` doesn't exist.

- [ ] **Step 3: Implement**

Replace the full contents of `Sources/BudgetCore/Forecasting/ForecastCalculator.swift`:

```swift
import Foundation

public enum ForecastCalculator {
    public static func confirmedTotal(categoryId: Int64, period: PayPeriod, entries: [ForecastEntry], groups: [ForecastGroup]) -> Int {
        total(categoryId: categoryId, period: period, entries: entries, groups: groups, selectedScenarioGroupId: nil, includeHypothetical: false)
    }

    /// `selectedScenarioGroupId` scopes which scenario's hypothetical entries count —
    /// only entries belonging to that specific group are included, not "any enabled
    /// group" (unlike confirmed/auto/manual entries, which are still gated by their own
    /// group's `isEnabled`, unrelated to selection). `nil` means no scenario is selected,
    /// so no hypothetical entries count at all — `previewTotal` then equals `confirmedTotal`.
    public static func previewTotal(categoryId: Int64, period: PayPeriod, entries: [ForecastEntry], groups: [ForecastGroup], selectedScenarioGroupId: Int64?) -> Int {
        total(categoryId: categoryId, period: period, entries: entries, groups: groups, selectedScenarioGroupId: selectedScenarioGroupId, includeHypothetical: true)
    }

    /// The confirmed forecast's net effect on account balances for one period — income
    /// minus expenses, transfer categories excluded (moving money to the user's own
    /// savings/ISA doesn't change net worth). Signed: positive means net worth grows.
    public static func confirmedNetWorthImpact(period: PayPeriod, categories: [Category], entries: [ForecastEntry], groups: [ForecastGroup]) -> Int {
        categories.reduce(0) { sum, category in
            guard category.type != .transfer, let categoryId = category.id else { return sum }
            return sum + confirmedTotal(categoryId: categoryId, period: period, entries: entries, groups: groups)
        }
    }

    /// The selected scenario's preview net effect on account balances for one period —
    /// `previewTotal` minus `confirmedTotal`, summed across non-transfer categories. This
    /// is the *delta* a scenario would add on top of the confirmed forecast, not a full
    /// preview total by itself. `nil` selection (or a scenario with no entries in a given
    /// category) contributes 0. Signed the same way as `confirmedNetWorthImpact`.
    public static func previewNetWorthDelta(period: PayPeriod, categories: [Category], entries: [ForecastEntry], groups: [ForecastGroup], selectedScenarioGroupId: Int64?) -> Int {
        categories.reduce(0) { sum, category in
            guard category.type != .transfer, let categoryId = category.id else { return sum }
            let confirmed = confirmedTotal(categoryId: categoryId, period: period, entries: entries, groups: groups)
            let preview = previewTotal(categoryId: categoryId, period: period, entries: entries, groups: groups, selectedScenarioGroupId: selectedScenarioGroupId)
            return sum + (preview - confirmed)
        }
    }

    private static func total(categoryId: Int64, period: PayPeriod, entries: [ForecastEntry], groups: [ForecastGroup], selectedScenarioGroupId: Int64?, includeHypothetical: Bool) -> Int {
        let enabledGroupIds = Set(groups.filter(\.isEnabled).compactMap(\.id))
        return entries
            .filter { $0.categoryId == categoryId }
            .filter { $0.isEnabled }
            .filter { entry in
                switch entry.status {
                case .auto, .manual, .confirmed:
                    return enabledGroupIds.contains(entry.groupId)
                case .hypothetical:
                    return includeHypothetical && entry.groupId == selectedScenarioGroupId
                }
            }
            .reduce(0) { $0 + FrequencyExpander.amount(for: $1, in: period) }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter ForecastCalculatorTests`
Expected: PASS, all cases.

- [ ] **Step 5: Commit**

```bash
git add Sources/BudgetCore/Forecasting/ForecastCalculator.swift Tests/BudgetCoreTests/ForecastCalculatorTests.swift
git commit -m "Scope forecast preview to a single selected scenario; add previewNetWorthDelta"
```

---

### Task 2: `ForecastViewModel` — scenario selection, multi-item methods, end-dates

**Files:**
- Modify: `App/Forecast/ForecastViewModel.swift`

**Interfaces:**
- Consumes: `ForecastCalculator.previewTotal(...selectedScenarioGroupId:)`, `ForecastCalculator.previewNetWorthDelta` (Task 1). `CategoryGroup` (existing model, `Sources/BudgetCore/Models/CategoryGroup.swift`). Everything else already in `ForecastViewModel` (unchanged from the previous plan).
- Produces (consumed by Tasks 3-5):
  - `@Published var selectedScenarioGroupId: Int64?` (with a `didSet` that calls `recomputeForecastCaches()`)
  - `@Published var categoryGroups: [CategoryGroup]`
  - `struct ScenarioItem { let categoryId: Int64; let amountMinorUnits: Int; let frequency: ForecastFrequency; let interval: Int; let startDate: Date; let endDate: Date? }`
  - `func createScenario(name: String, items: [ScenarioItem])`
  - `func addItem(to group: ForecastGroup, _ item: ScenarioItem)`
  - `func confirmScenario(_ group: ForecastGroup) -> Bool`
  - `func scenarioNetWorthImpact(atEndOf year: Int) -> Int?`
  - `func updateEntry(_ entry: ForecastEntry, amountMinorUnits: Int, frequency: ForecastFrequency, interval: Int, endDate: Date?) -> Bool` (signature changed — new `endDate` parameter)
  - Removed: `addHypotheticalEntry(groupName:categoryId:amountMinorUnits:frequency:interval:startDate:)`
  - Unchanged in signature: `thisYear`, `nextYear`, `load() throws`, `isActual`, `dateRange`, `categoryTotal`, `previewCategoryTotal`, `forecastNetWorth`, `forecastNetWorthYoY`, `toggleGroup`, `toggleEntry`, `confirm`, `unconfirm`

- [ ] **Step 1: Replace the file**

Replace the full contents of `App/Forecast/ForecastViewModel.swift`:

```swift
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
```

Note: `selectedScenarioGroupId`'s `didSet` calls `recomputeForecastCaches()`, and `confirmScenario` both mutates `entries` directly AND may set `selectedScenarioGroupId = nil` — when that assignment happens, its own `didSet` fires a second `recomputeForecastCaches()` call. That's a harmless redundant recompute (correctness-safe, just a few extra milliseconds), not worth special-casing.

- [ ] **Step 2: Build to verify it compiles**

`ForecastView.swift` still calls the old `updateEntry(...)` (3 args, no `endDate`) and the now-removed `addHypotheticalEntry(...)` — this task's build WILL fail there; that's expected and Task 4's job. Confirm the *only* errors are in `ForecastView.swift`:

Run: `xcodegen generate && xcodebuild -project Budget.xcodeproj -scheme Budget -configuration Debug build 2>&1 | grep -A3 "error:"`
Expected: every error's file path is `ForecastView.swift`, none in `ForecastViewModel.swift`.

- [ ] **Step 3: Commit**

```bash
git add App/Forecast/ForecastViewModel.swift
git commit -m "Add scenario selection, multi-item creation, and end-date support to ForecastViewModel"
```

---

### Task 3: `ScenarioItemFormView` and `EditForecastEntryView` end-date field

**Files:**
- Modify: `App/Forecast/ForecastView.swift` (only the two bottom struct definitions — `NewForecastEntryView` and `EditForecastEntryView` — not `ForecastView` itself, not touched in this task)

**Interfaces:**
- Consumes: `ForecastViewModel.ScenarioItem` (Task 2), `Money.parseMinorUnits` (existing, `Sources/BudgetCore/Models/Money.swift` or wherever `Money` lives — already used by the current `EditForecastEntryView`), `Category`, `ForecastFrequency`, `ForecastEntry`.
- Produces (consumed by Task 4):
  - `struct ScenarioItemFormView: View` with `enum Mode { case newScenario; case addItem(to: ForecastGroup) }`, `init(mode: Mode, categories: [Category], onSave: (String?, ForecastViewModel.ScenarioItem) -> Void)`
  - `struct EditForecastEntryView: View` with `init(entry: ForecastEntry, onSave: @escaping (Int, ForecastFrequency, Int, Date?) -> Void)` (signature changed — `onSave` closure gains a fourth `Date?` parameter for the end-date)

- [ ] **Step 1: Replace `NewForecastEntryView` with `ScenarioItemFormView`**

In `App/Forecast/ForecastView.swift`, replace the entire `NewForecastEntryView` struct (currently the second-to-last struct in the file) with:

```swift
struct ScenarioItemFormView: View {
    enum Mode {
        case newScenario
        case addItem(to: ForecastGroup)
    }
    let mode: Mode
    let categories: [Category]
    let onSave: (String?, ForecastViewModel.ScenarioItem) -> Void // scenario name only non-nil for .newScenario

    @State private var scenarioName = "New scenario"
    @State private var categoryId: Int64?
    @State private var amountPounds = ""
    @State private var frequency: ForecastFrequency = .monthly
    @State private var interval = 1
    @State private var startDate = Date()
    @State private var hasEndDate = false
    @State private var endDate = Date()

    var body: some View {
        Form {
            if case .newScenario = mode {
                TextField("Scenario name", text: $scenarioName)
            }
            Picker("Category", selection: $categoryId) {
                Text("Select…").tag(Int64?.none)
                ForEach(categories) { category in Text(category.name).tag(Int64?.some(category.id!)) }
            }
            TextField("Amount (£, positive number)", text: $amountPounds)
            Picker("Frequency", selection: $frequency) {
                ForEach(ForecastFrequency.allCases, id: \.self) { freq in Text(freq.rawValue).tag(freq) }
            }
            Stepper("Every \(interval) \(frequency.rawValue)", value: $interval, in: 1...12)
            DatePicker("Starting", selection: $startDate, displayedComponents: .date)
            Toggle("Ends on a specific date", isOn: $hasEndDate)
            if hasEndDate {
                DatePicker("Ends", selection: $endDate, displayedComponents: .date)
            }
            Button("Save") {
                guard let categoryId, let minorUnits = Money.parseMinorUnits(amountPounds) else { return }
                let category = categories.first { $0.id == categoryId }
                let signedMinorUnits = category?.type == .income ? abs(minorUnits) : -abs(minorUnits)
                let item = ForecastViewModel.ScenarioItem(categoryId: categoryId, amountMinorUnits: signedMinorUnits, frequency: frequency, interval: interval, startDate: startDate, endDate: hasEndDate ? endDate : nil)
                let name: String? = { if case .newScenario = mode { return scenarioName }; return nil }()
                onSave(name, item)
            }
        }
        .padding()
        .frame(width: 420)
    }
}
```

- [ ] **Step 2: Add the end-date field to `EditForecastEntryView`**

Replace the entire `EditForecastEntryView` struct (currently the last struct in the file) with:

```swift
struct EditForecastEntryView: View {
    let entry: ForecastEntry
    let onSave: (Int, ForecastFrequency, Int, Date?) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var amountPounds: String
    @State private var frequency: ForecastFrequency
    @State private var interval: Int
    @State private var hasEndDate: Bool
    @State private var endDate: Date

    init(entry: ForecastEntry, onSave: @escaping (Int, ForecastFrequency, Int, Date?) -> Void) {
        self.entry = entry
        self.onSave = onSave
        _amountPounds = State(initialValue: String(format: "%.2f", Double(abs(entry.amountMinorUnits)) / 100))
        _frequency = State(initialValue: entry.frequency)
        _interval = State(initialValue: entry.interval)
        _hasEndDate = State(initialValue: entry.endDate != nil)
        _endDate = State(initialValue: entry.endDate ?? Date())
    }

    /// Preserves the entry's existing sign (income positive, everything else negative) —
    /// the field only ever asks for a positive magnitude. nil if the field doesn't parse.
    private var signedAmount: Int? {
        guard let minorUnits = Money.parseMinorUnits(amountPounds) else { return nil }
        return entry.amountMinorUnits < 0 ? -abs(minorUnits) : abs(minorUnits)
    }

    private var resolvedEndDate: Date? { hasEndDate ? endDate : nil }

    /// Save is a no-op unless something actually changed: saving an untouched `.auto`
    /// entry would otherwise promote it to `.manual` (via `updateEntry`) and permanently
    /// opt that category out of `AutoForecastGenerator.refresh` for no reason.
    private var hasChanges: Bool {
        guard let signedAmount else { return false }
        return signedAmount != entry.amountMinorUnits || frequency != entry.frequency || interval != entry.interval || resolvedEndDate != entry.endDate
    }

    var body: some View {
        Form {
            TextField("Amount (£)", text: $amountPounds)
            Picker("Frequency", selection: $frequency) {
                ForEach(ForecastFrequency.allCases, id: \.self) { freq in Text(freq.rawValue).tag(freq) }
            }
            Stepper("Every \(interval) \(frequency.rawValue)", value: $interval, in: 1...12)
            Toggle("Ends on a specific date", isOn: $hasEndDate)
            if hasEndDate {
                DatePicker("Ends", selection: $endDate, displayedComponents: .date)
            }
            HStack {
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save") {
                    guard hasChanges, let signedAmount else { return }
                    onSave(signedAmount, frequency, interval, resolvedEndDate)
                }
                .disabled(!hasChanges)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 360)
    }
}
```

- [ ] **Step 3: Build**

Run: `xcodegen generate && xcodebuild -project Budget.xcodeproj -scheme Budget -configuration Debug build 2>&1 | grep -A3 "error:"`
Expected: errors in `ForecastView.swift` at the OLD `.sheet` call sites inside `ForecastView.body` and `manageForecastSection` — they still reference `NewForecastEntryView` (now deleted) and the old 3-argument `EditForecastEntryView`/`updateEntry` closures. That's expected — Task 4 rewrites those call sites. Confirm no error is inside the `ScenarioItemFormView`/`EditForecastEntryView` struct bodies themselves (i.e. every error line points at code above the `ScenarioItemFormView` struct in the file, in `ForecastView`'s own body/`manageForecastSection`).

- [ ] **Step 4: Commit**

```bash
git add App/Forecast/ForecastView.swift
git commit -m "Replace NewForecastEntryView with ScenarioItemFormView; add end-date to EditForecastEntryView"
```

---

### Task 4: `ForecastView` — right panel, scenario picker, sheet wiring

**Files:**
- Modify: `App/Forecast/ForecastView.swift` (the `ForecastView` struct itself — `body`, its `@State`, and everything above `ScenarioItemFormView`)

**Interfaces:**
- Consumes: `ForecastViewModel.selectedScenarioGroupId`, `.groups`, `.entries`, `.categories`, `.scenarioNetWorthImpact(atEndOf:)`, `.confirmScenario(_:)`, `.createScenario(name:items:)`, `.addItem(to:_:)`, `.updateEntry(_:amountMinorUnits:frequency:interval:endDate:)`, `.toggleGroup(_:)` (Task 2). `ScenarioItemFormView`, `EditForecastEntryView` (Task 3).
- Produces: the complete, buildable `ForecastView` screen — this task closes the build.

- [ ] **Step 1: Replace `ForecastView`'s `@State` and `body`**

In `App/Forecast/ForecastView.swift`, replace the `@State` declarations at the top of `ForecastView` (currently `selectedYear`, `horizontalOffset`, `showNewEntrySheet`, `editingEntry`, `manageExpanded`) with:

```swift
struct ForecastView: View {
    @ObservedObject var viewModel: ForecastViewModel
    @State private var selectedYear: Int
    @State private var horizontalOffset: CGFloat = 0
    @State private var expandedGroupIds: Set<Int64> = []
    @State private var showNewScenarioSheet = false
    @State private var addingItemTo: ForecastGroup?
    @State private var editingEntry: ForecastEntry?

    init(viewModel: ForecastViewModel) {
        self.viewModel = viewModel
        _selectedYear = State(initialValue: viewModel.thisYear)
    }
```

(`expandedGroupIds` is added here even though category-group rows arrive in Task 5 — it's simplest to declare it alongside the other `@State` now and have Task 5 be purely additive to `rowLabel`/`rowCells`/`allRows`, rather than Task 5 needing to also touch this task's `@State` block.)

Replace `body` in full:

```swift
    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 8) {
                    netWorthHeadline
                    yearPicker

                    VStack(alignment: .leading, spacing: 0) {
                        HStack(spacing: 0) {
                            Text("Category").font(.headline).frame(width: 220, alignment: .leading)
                                .padding(.horizontal, 8).padding(.vertical, 6)
                                .overlay(Rectangle().frame(width: 1).foregroundStyle(.separator), alignment: .trailing)
                            HStack(spacing: 0) {
                                ForEach(1...12, id: \.self) { month in
                                    Text(Self.monthLabel(month))
                                        .frame(width: 120, alignment: .trailing)
                                        .padding(.horizontal, 8).padding(.vertical, 6)
                                        .overlay(Rectangle().frame(width: 1).foregroundStyle(.separator), alignment: .trailing)
                                }
                                Text("Year Total").bold()
                                    .frame(width: 120, alignment: .trailing)
                                    .padding(.horizontal, 8).padding(.vertical, 6)
                            }
                            .offset(x: horizontalOffset)
                            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                            .clipped()
                        }
                        .font(.headline)
                        .background(Color(nsColor: .controlBackgroundColor))
                        .overlay(Rectangle().frame(height: 1.5).foregroundStyle(Color.primary.opacity(0.18)), alignment: .bottom)
                        .shadow(color: .black.opacity(0.08), radius: 3, y: 2)

                        ScrollView(.vertical) {
                            HStack(alignment: .top, spacing: 0) {
                                VStack(spacing: 0) {
                                    ForEach(allRows) { entry in
                                        rowLabel(entry.kind, shaded: entry.shaded)
                                    }
                                }
                                .frame(width: 236, alignment: .leading)
                                .overlay(Rectangle().frame(width: 1).foregroundStyle(.separator), alignment: .trailing)

                                ScrollView(.horizontal) {
                                    VStack(alignment: .leading, spacing: 0) {
                                        ForEach(allRows) { entry in
                                            rowCells(entry.kind, shaded: entry.shaded)
                                        }
                                    }
                                    .background(GeometryReader { geo in
                                        Color.clear.preference(key: ForecastHorizontalOffsetKey.self, value: geo.frame(in: .named("forecastHScroll")).minX)
                                    })
                                }
                                .coordinateSpace(.named("forecastHScroll"))
                            }
                        }
                        .frame(height: 480)
                        .onPreferenceChange(ForecastHorizontalOffsetKey.self) { horizontalOffset = $0 }
                    }
                }
                .padding()
            }
            Divider()
            scenarioPanel
                .frame(width: 280)
        }
        .sheet(isPresented: $showNewScenarioSheet) {
            ScenarioItemFormView(mode: .newScenario, categories: viewModel.categories) { name, item in
                viewModel.createScenario(name: name ?? "New scenario", items: [item])
                showNewScenarioSheet = false
            }
        }
        .sheet(item: $addingItemTo) { group in
            ScenarioItemFormView(mode: .addItem(to: group), categories: viewModel.categories) { _, item in
                viewModel.addItem(to: group, item)
                addingItemTo = nil
            }
        }
        .sheet(item: $editingEntry) { entry in
            EditForecastEntryView(entry: entry) { amountMinorUnits, frequency, interval, endDate in
                viewModel.updateEntry(entry, amountMinorUnits: amountMinorUnits, frequency: frequency, interval: interval, endDate: endDate)
                editingEntry = nil
            }
        }
    }
```

- [ ] **Step 2: Replace `manageForecastSection` with `scenarioPanel`**

Delete the entire `manageForecastSection` computed property and replace it with:

```swift
    private var scenarioPanel: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 16) {
                if let error = viewModel.errorMessage {
                    Text(error).foregroundStyle(.red).font(.callout)
                }
                scenarioPicker
                if let selectedGroup = viewModel.groups.first(where: { $0.id == viewModel.selectedScenarioGroupId }) {
                    selectedScenarioSection(selectedGroup)
                }
                detectedRecurringSection
            }
            .padding()
        }
    }

    private var scenarioPicker: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Scenario").font(.caption).foregroundStyle(.secondary)
            scenarioRow(name: "None (confirmed only)", isSelected: viewModel.selectedScenarioGroupId == nil, badge: nil) {
                viewModel.selectedScenarioGroupId = nil
            }
            ForEach(viewModel.groups.filter { !$0.isSystemManaged }) { group in
                let isConfirmed = viewModel.entries.contains { $0.groupId == group.id && $0.status == .confirmed }
                scenarioRow(name: group.name, isSelected: viewModel.selectedScenarioGroupId == group.id, badge: isConfirmed ? "confirmed" : nil) {
                    guard !isConfirmed else { return }
                    viewModel.selectedScenarioGroupId = group.id
                }
            }
            Button("+ New scenario…") { showNewScenarioSheet = true }
                .buttonStyle(.plain).font(.caption).padding(.top, 4)
        }
    }

    private func scenarioRow(name: String, isSelected: Bool, badge: String?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(name).font(.callout)
                Spacer()
                if let badge {
                    Text(badge).font(.caption2).foregroundStyle(.secondary)
                }
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 8).fill(isSelected ? Color.accentColor.opacity(0.15) : Color.clear))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 2))
        }
        .buttonStyle(.plain)
    }

    private func selectedScenarioSection(_ group: ForecastGroup) -> some View {
        let isConfirmed = viewModel.entries.contains { $0.groupId == group.id && $0.status == .confirmed }
        return VStack(alignment: .leading, spacing: 6) {
            Text("\(group.name) — items").font(.caption).foregroundStyle(.secondary)
            ForEach(viewModel.entries.filter { $0.groupId == group.id }) { entry in
                scenarioItemRow(entry)
            }
            if !isConfirmed {
                Button("+ Add item…") { addingItemTo = group }
                    .buttonStyle(.plain).font(.caption)
                Button("Confirm scenario") { viewModel.confirmScenario(group) }
                    .font(.caption)
                if let impact = viewModel.scenarioNetWorthImpact(atEndOf: selectedYear), impact != 0 {
                    HStack(spacing: 4) {
                        Text("With this scenario:").font(.caption).foregroundStyle(.secondary)
                        MoneyText(minorUnits: impact, font: .caption.bold(), tint: .orange)
                        Text("by Dec \(String(selectedYear))").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func scenarioItemRow(_ entry: ForecastEntry) -> some View {
        HStack {
            Text(viewModel.categories.first(where: { $0.id == entry.categoryId })?.name ?? "Unknown").font(.caption)
            Spacer()
            MoneyText(minorUnits: entry.amountMinorUnits, font: .caption)
            if let endDate = entry.endDate {
                Text("ends \(Self.monthYearLabel(endDate))").font(.caption2).foregroundStyle(.secondary)
            }
            Button("Edit…") { editingEntry = entry }
                .buttonStyle(.plain).font(.caption)
        }
    }

    private var detectedRecurringSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let detectedRecurring = viewModel.groups.first(where: { $0.isSystemManaged }) {
                Toggle(detectedRecurring.name, isOn: Binding(
                    get: { detectedRecurring.isEnabled },
                    set: { _ in viewModel.toggleGroup(detectedRecurring) }
                )).font(.caption)
                ForEach(viewModel.entries.filter { $0.groupId == detectedRecurring.id }) { entry in
                    HStack {
                        Text(viewModel.categories.first(where: { $0.id == entry.categoryId })?.name ?? "Unknown").font(.caption)
                        Text(entry.status.rawValue).font(.caption2).foregroundStyle(.secondary)
                        if let endDate = entry.endDate {
                            Text("ends \(Self.monthYearLabel(endDate))").font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Edit…") { editingEntry = entry }
                            .buttonStyle(.plain).font(.caption)
                    }
                }
            }
        }
    }
```

Add a small date-formatting helper next to the existing `monthLabel(_:)` static function (same file, same style — used by the two end-date displays above):

```swift
    private static func monthYearLabel(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM yyyy"
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: date)
    }
```

- [ ] **Step 3: Build**

Run: `xcodegen generate && xcodebuild -project Budget.xcodeproj -scheme Budget -configuration Debug build 2>&1 | tail -20`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Run the full test suite**

Run: `swift test 2>&1 | tail -10`
Expected: all tests passing (134 before this plan + 5 new from Task 1 = 139 — the exact prior count may have drifted; the point is 0 failures).

- [ ] **Step 5: Live walkthrough**

Launch the built app (kill any stale running instance first — `pgrep -fl "Budget.app/Contents/MacOS/Budget"` — then launch the exact fresh DerivedData binary). Navigate to Forecast and verify:
- The right panel renders alongside a narrower grid; "Manage forecast" (the old bottom disclosure) is gone.
- The scenario picker shows "None (confirmed only)" (selected by default) plus one row per existing custom scenario group (if any exist in the live database from the previous plan's testing — there may not be any; that's fine, an empty scenario list is a valid state).
- "+ New scenario…" opens `ScenarioItemFormView`; create a scenario with a category, amount, frequency, and an end-date set via the "Ends on a specific date" toggle. Confirm it appears in the picker and, once selected, its item appears in "items" with the end-date shown, and the grid's amber preview line reflects it for months before the end-date but not after.
- "Confirm scenario" moves it out of the selectable list (shows a "confirmed" badge instead) and its numbers become part of the confirmed (bold) grid figures.
- "Detected recurring" still lists its entries with Edit working, and adding an end-date there via Edit… causes that entry to stop contributing to months after it.

- [ ] **Step 6: Commit**

```bash
git add App/Forecast/ForecastView.swift
git commit -m "Replace Manage-forecast disclosure group with a right-side scenario panel"
```

---

### Task 5: Category groups in the Forecast grid

**Files:**
- Modify: `App/Forecast/ForecastView.swift` (only `ForecastRowKind`, `ForecastRow`, `allRows`, `rowLabel`, `rowCells` — not `body`, not the panel, not the two sheet structs)

**Interfaces:**
- Consumes: `viewModel.categoryGroups: [CategoryGroup]` (Task 2), `CategoryGroup` (existing model), the `expandedGroupIds` `@State` (declared in Task 4).
- Produces: the finished screen for this plan.

- [ ] **Step 1: Extend `ForecastRowKind` and `allRows`**

Replace the `ForecastRowKind` enum:

```swift
    private enum ForecastRowKind: Identifiable {
        case sectionHeader(String)
        case category(Category)
        case groupHeader(CategoryGroup, categories: [Category])
        case groupChild(Category)
        var id: String {
            switch self {
            case .sectionHeader(let title): return "header-\(title)"
            case .category(let category): return "cat-\(category.id ?? -1)"
            case .groupHeader(let group, let categories): return "group-\(group.id ?? -1)-\(categories.first?.type.rawValue ?? "")"
            case .groupChild(let category): return "groupchild-\(category.id ?? -1)"
            }
        }
    }
```

Add a `rowKinds(for:)` helper and rewrite `allRows` to enumerate it — the same two-step split `BudgetGridView` already uses (`rowKinds(for:)` builds the flat, unshaded row list; `allRows` enumerates it so the shading index counts *rendered rows*, not raw categories — a collapsed group is one row regardless of how many categories it has):

```swift
    /// Categories sharing a `groupId` collapse into one `.groupHeader` row (first-seen
    /// order wins for where the group appears), expanding to a `.groupChild` row per
    /// member only when its id is in `expandedGroupIds`. Ungrouped categories render
    /// exactly as `.category`, interleaved in the section's existing order. Identical
    /// logic to `BudgetGridView.rowKinds(for:)`.
    private func rowKinds(for type: CategoryType) -> [ForecastRowKind] {
        let cats = categoriesByType(type)
        var rows: [ForecastRowKind] = []
        var seenGroupIds: Set<Int64> = []
        for category in cats {
            if let groupId = category.groupId {
                guard !seenGroupIds.contains(groupId) else { continue }
                seenGroupIds.insert(groupId)
                guard let group = viewModel.categoryGroups.first(where: { $0.id == groupId }) else { continue }
                let members = cats.filter { $0.groupId == groupId }
                rows.append(.groupHeader(group, categories: members))
                if expandedGroupIds.contains(groupId) {
                    rows += members.map { .groupChild($0) }
                }
            } else {
                rows.append(.category(category))
            }
        }
        return rows
    }

    private var allRows: [ForecastRow] {
        func section(_ title: String, _ type: CategoryType) -> [ForecastRow] {
            var rows: [ForecastRow] = [ForecastRow(kind: .sectionHeader(title), shaded: false)]
            for (index, kind) in rowKinds(for: type).enumerated() {
                rows.append(ForecastRow(kind: kind, shaded: index % 2 == 1))
            }
            return rows
        }
        return section("Income", .income) + section("Expenses", .expense) + section("Transfers", .transfer)
    }
```

(This replaces the previous version's simpler `for (index, category) in categoriesByType(type).enumerated()` loop — the index used for zebra shading now increments once per *rendered row*, not once per category, since a collapsed group renders fewer rows than it has member categories.)

`isTwoLine(_:year:)` also needs a group-aware counterpart for the header row (does ANY member category have a preview difference somewhere in the year):

```swift
    private func isTwoLineGroup(_ categories: [Category], year: Int) -> Bool {
        categories.contains { isTwoLine($0, year: year) }
    }
```

- [ ] **Step 2: Add `.groupHeader`/`.groupChild` cases to `rowLabel`**

Add these two cases to the `rowLabel` switch (alongside the existing `.sectionHeader`/`.category` cases):

```swift
        case .groupHeader(let group, let categories):
            let twoLine = isTwoLineGroup(categories, year: selectedYear)
            Button {
                if let id = group.id {
                    if expandedGroupIds.contains(id) { expandedGroupIds.remove(id) } else { expandedGroupIds.insert(id) }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: (group.id.map { expandedGroupIds.contains($0) } ?? false) ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                    Text(group.name).bold()
                }
            }
            .buttonStyle(.plain)
            .frame(width: 220, height: twoLine ? 44 : 28, alignment: .leading)
            .padding(.horizontal, 8)
            .background(Color.orange.opacity(0.10))
            .overlay(Rectangle().frame(height: 1).foregroundStyle(.separator), alignment: .bottom)
            .overlay(Rectangle().frame(width: 3).foregroundStyle(categories.first.map { rowColor(for: $0.type) } ?? .clear), alignment: .leading)
        case .groupChild(let category):
            let twoLine = isTwoLine(category, year: selectedYear)
            Text(category.name).foregroundStyle(.secondary)
                .frame(width: 200, height: twoLine ? 44 : 28, alignment: .leading)
                .padding(.leading, 28).padding(.trailing, 8)
                .background(shaded ? Color.primary.opacity(0.07) : Color.clear)
                .overlay(Rectangle().frame(height: 1).foregroundStyle(.separator), alignment: .bottom)
                .overlay(Rectangle().frame(width: 3).foregroundStyle(rowColor(for: category.type)), alignment: .leading)
```

- [ ] **Step 3: Add `.groupHeader`/`.groupChild` cases to `rowCells`**

Add these two cases to the `rowCells` switch:

```swift
        case .groupHeader(_, let categories):
            let year = selectedYear
            let twoLine = isTwoLineGroup(categories, year: year)
            HStack(spacing: 0) {
                ForEach(1...12, id: \.self) { month in
                    let confirmed = categories.reduce(0) { $0 + viewModel.categoryTotal($1, year: year, month: month) }
                    let preview = categories.reduce(0) { $0 + viewModel.previewCategoryTotal($1, year: year, month: month) }
                    forecastCell(confirmed: confirmed, preview: preview, twoLine: twoLine, bold: true)
                        .frame(height: twoLine ? 44 : 28)
                        .overlay(Rectangle().frame(height: 1).foregroundStyle(.separator), alignment: .bottom)
                        .overlay(Rectangle().frame(width: 1).foregroundStyle(.separator), alignment: .trailing)
                }
                let confirmedYearTotal = (1...12).reduce(0) { sum, month in sum + categories.reduce(0) { $0 + viewModel.categoryTotal($1, year: year, month: month) } }
                let previewYearTotal = (1...12).reduce(0) { sum, month in sum + categories.reduce(0) { $0 + viewModel.previewCategoryTotal($1, year: year, month: month) } }
                forecastCell(confirmed: confirmedYearTotal, preview: previewYearTotal, twoLine: twoLine, bold: true)
                    .frame(height: twoLine ? 44 : 28)
                    .overlay(Rectangle().frame(height: 1).foregroundStyle(.separator), alignment: .bottom)
            }
            .background(Color.orange.opacity(0.10))
        case .groupChild(let category):
            // Identical cell behavior to `.category` — a `@ViewBuilder` function returning
            // `some View` can't call itself recursively, so this repeats the `.category`
            // branch's body rather than calling `rowCells(.category(...))`.
            let year = selectedYear
            let twoLine = isTwoLine(category, year: year)
            HStack(spacing: 0) {
                ForEach(1...12, id: \.self) { month in
                    let confirmed = viewModel.categoryTotal(category, year: year, month: month)
                    let preview = viewModel.previewCategoryTotal(category, year: year, month: month)
                    forecastCell(confirmed: confirmed, preview: preview, twoLine: twoLine)
                        .frame(height: twoLine ? 44 : 28)
                        .background(shaded ? Color.primary.opacity(0.07) : Color.clear)
                        .overlay(Rectangle().frame(height: 1).foregroundStyle(.separator), alignment: .bottom)
                        .overlay(Rectangle().frame(width: 1).foregroundStyle(.separator), alignment: .trailing)
                }
                let confirmedYearTotal = (1...12).reduce(0) { $0 + viewModel.categoryTotal(category, year: year, month: $1) }
                let previewYearTotal = (1...12).reduce(0) { $0 + viewModel.previewCategoryTotal(category, year: year, month: $1) }
                forecastCell(confirmed: confirmedYearTotal, preview: previewYearTotal, twoLine: twoLine, bold: true)
                    .frame(height: twoLine ? 44 : 28)
                    .background(shaded ? Color.primary.opacity(0.07) : Color.clear)
                    .overlay(Rectangle().frame(height: 1).foregroundStyle(.separator), alignment: .bottom)
            }
```

- [ ] **Step 4: Build**

Run: `xcodegen generate && xcodebuild -project Budget.xcodeproj -scheme Budget -configuration Debug build 2>&1 | tail -20`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 5: Run the full test suite**

Run: `swift test 2>&1 | tail -10`
Expected: all tests still passing, 0 failures (this task touches no `Sources/BudgetCore` code).

- [ ] **Step 6: Live walkthrough**

Launch the app, navigate to Forecast. Confirm: categories belonging to a `CategoryGroup` (e.g. "Car," seeded earlier in this project) now render as a collapsible bold group row summing their members' confirmed/preview totals correctly, expand/collapse works, and ungrouped categories render exactly as before, interleaved in the section's existing order.

- [ ] **Step 7: Commit**

```bash
git add App/Forecast/ForecastView.swift
git commit -m "Add category-group collapsing to the Forecast grid"
```
