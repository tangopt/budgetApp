# Forecast Screen Rebuild Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rebuild the Forecast screen around the app's calendar-year model (matching the Budget grid) instead of the abandoned pay-period model, adding a net worth projection with year-over-year comparison.

**Architecture:** The forecast engine (`FrequencyExpander`, `ForecastCalculator`) is untouched — it already operates on generic `{startDate, endDate}` ranges. `ForecastViewModel` is rewritten to construct calendar-month `PayPeriod` values instead of pay-period ones, blend actual transaction totals with confirmed forecast per month, and project net worth forward from the latest real balance data. `ForecastComparisonView` is replaced by a new `ForecastView` that mirrors `BudgetGridView`'s frozen-header/frozen-column grid technique and visual language (right-aligned figures, colored section rails, zebra striping).

**Tech Stack:** Swift, SwiftUI, GRDB (existing stack — no new dependencies).

**Spec:** `docs/superpowers/specs/2026-09-28-forecast-rebuild-design.md`

## Global Constraints

- No changes to `FrequencyExpander`, `AutoForecastGenerator`, or `PayPeriodDetector`/`PaydaySource`.
- Every projected total flows through the existing `ForecastCalculator.confirmedTotal`/`previewTotal`, called with calendar-month-shaped `PayPeriod` values (`PayPeriod(startDate: monthStart, endDate: monthEnd, type: .projected)`).
- "Confirmed" forecast (`.auto`, `.manual`, `.confirmed` entries) drives every headline number. "Preview" (confirmed + enabled `.hypothetical`) is secondary.
- Transfer categories (`Category.type == .transfer`) are excluded from every net-worth-affecting calculation.
- The screen always covers exactly two calendar years — `thisYear` and `nextYear` (today's real year, and the year after) — never a rolling window.
- A month is "actual" when it's on or before `latestRealMonth` (the later of the latest transaction date's month or the latest balance snapshot date's month); "forecast" otherwise.
- No changes to the Budget grid or a Dashboard screen — those are separate, later plans.

---

### Task 1: `ForecastCalculator.confirmedNetWorthImpact`

**Files:**
- Modify: `Sources/BudgetCore/Forecasting/ForecastCalculator.swift`
- Test: `Tests/BudgetCoreTests/ForecastCalculatorTests.swift`

**Interfaces:**
- Consumes: existing `ForecastCalculator.confirmedTotal(categoryId:period:entries:groups:)` (unchanged), `Category`, `PayPeriod`, `ForecastEntry`, `ForecastGroup` (all existing models).
- Produces: `ForecastCalculator.confirmedNetWorthImpact(period:categories:entries:groups:) -> Int`, consumed by Task 2.

- [ ] **Step 1: Write the failing tests**

Add to `Tests/BudgetCoreTests/ForecastCalculatorTests.swift` (the file already has a `date(_:_:_:)` helper — reuse it, don't redefine):

```swift
func testConfirmedNetWorthImpactSumsIncomeMinusExpensesExcludingTransfers() {
    let period = PayPeriod(startDate: date(2026, 3, 1), endDate: date(2026, 3, 31), type: .projected)
    let income = Category(id: 1, name: "Income", type: .income)
    let rent = Category(id: 2, name: "Rent", type: .expense)
    let isaTransfer = Category(id: 3, name: "Transfer: ISA", type: .transfer)
    let group = ForecastGroup(id: 1, name: "Detected recurring", note: nil, isEnabled: true, isSystemManaged: true)
    let entries = [
        ForecastEntry(id: 1, groupId: 1, categoryId: 1, amountMinorUnits: 280000, frequency: .monthly, interval: 1, startDate: date(2026, 1, 26), endDate: nil, isEnabled: true, status: .auto, note: nil),
        ForecastEntry(id: 2, groupId: 1, categoryId: 2, amountMinorUnits: -180000, frequency: .monthly, interval: 1, startDate: date(2026, 1, 26), endDate: nil, isEnabled: true, status: .auto, note: nil),
        ForecastEntry(id: 3, groupId: 1, categoryId: 3, amountMinorUnits: -50000, frequency: .monthly, interval: 1, startDate: date(2026, 1, 26), endDate: nil, isEnabled: true, status: .auto, note: nil)
    ]
    let impact = ForecastCalculator.confirmedNetWorthImpact(period: period, categories: [income, rent, isaTransfer], entries: entries, groups: [group])
    XCTAssertEqual(impact, 280000 - 180000) // the -50000 transfer is excluded
}

func testConfirmedNetWorthImpactExcludesHypotheticalEntries() {
    let period = PayPeriod(startDate: date(2026, 3, 1), endDate: date(2026, 3, 31), type: .projected)
    let groceries = Category(id: 1, name: "Groceries", type: .expense)
    let group = ForecastGroup(id: 1, name: "Detected recurring", note: nil, isEnabled: true, isSystemManaged: true)
    let entries = [
        ForecastEntry(id: 1, groupId: 1, categoryId: 1, amountMinorUnits: -20000, frequency: .monthly, interval: 1, startDate: date(2026, 1, 1), endDate: nil, isEnabled: true, status: .auto, note: nil),
        ForecastEntry(id: 2, groupId: 1, categoryId: 1, amountMinorUnits: -5000, frequency: .monthly, interval: 1, startDate: date(2026, 1, 1), endDate: nil, isEnabled: true, status: .hypothetical, note: nil)
    ]
    let impact = ForecastCalculator.confirmedNetWorthImpact(period: period, categories: [groceries], entries: entries, groups: [group])
    XCTAssertEqual(impact, -20000)
}

func testConfirmedNetWorthImpactSkipsCategoriesWithNoId() {
    let period = PayPeriod(startDate: date(2026, 3, 1), endDate: date(2026, 3, 31), type: .projected)
    let unsaved = Category(id: nil, name: "Draft", type: .expense)
    let impact = ForecastCalculator.confirmedNetWorthImpact(period: period, categories: [unsaved], entries: [], groups: [])
    XCTAssertEqual(impact, 0)
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter ForecastCalculatorTests`
Expected: FAIL — `confirmedNetWorthImpact` doesn't exist yet.

- [ ] **Step 3: Implement**

In `Sources/BudgetCore/Forecasting/ForecastCalculator.swift`, add inside the existing `enum ForecastCalculator { ... }` (alongside `confirmedTotal`/`previewTotal`, not in a separate `extension`):

```swift
    /// The confirmed forecast's net effect on account balances for one period — income
    /// minus expenses, transfer categories excluded (moving money to the user's own
    /// savings/ISA doesn't change net worth). Signed: positive means net worth grows.
    public static func confirmedNetWorthImpact(period: PayPeriod, categories: [Category], entries: [ForecastEntry], groups: [ForecastGroup]) -> Int {
        categories.reduce(0) { sum, category in
            guard category.type != .transfer, let categoryId = category.id else { return sum }
            return sum + confirmedTotal(categoryId: categoryId, period: period, entries: entries, groups: groups)
        }
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter ForecastCalculatorTests`
Expected: PASS, all cases including the three new ones.

- [ ] **Step 5: Commit**

```bash
git add Sources/BudgetCore/Forecasting/ForecastCalculator.swift Tests/BudgetCoreTests/ForecastCalculatorTests.swift
git commit -m "Add ForecastCalculator.confirmedNetWorthImpact"
```

---

### Task 2: `ForecastViewModel` — calendar-year model

**Files:**
- Modify (full rewrite): `App/Forecast/ForecastViewModel.swift`

**Interfaces:**
- Consumes: `ForecastCalculator.confirmedNetWorthImpact` (Task 1), `ForecastCalculator.confirmedTotal`/`previewTotal` (existing), `BudgetGridCalculator.calendarTotalsLookup`/`categoryTotalForCalendarMonth` (existing, from `Sources/BudgetCore/Budget/BudgetGridCalculator.swift`), `NetWorthCalculator.accountBalances`/`netWorth`/`monthlyBalance` (existing, from `Sources/BudgetCore/NetWorth/NetWorthCalculator.swift` — `monthlyBalance` returns `MonthlyAccountBalance?` with a `.gbpBalanceMinorUnits` field), `Account`, `BalanceSnapshot`, `ExchangeRateSetting`, `Transaction`, `Category`, `ForecastGroup`, `ForecastEntry`, `PayPeriod` (all existing models).
- Produces (consumed by Task 3 and Task 4):
  - `@Published var groups: [ForecastGroup]`, `@Published var entries: [ForecastEntry]` (unchanged from today)
  - `@Published var categories: [Category]`
  - `@Published var errorMessage: String?` (unchanged from today)
  - `var thisYear: Int`, `var nextYear: Int`
  - `func load() throws`
  - `func isActual(year: Int, month: Int) -> Bool`
  - `func categoryTotal(_ category: Category, year: Int, month: Int) -> Int` (confirmed/actual blend)
  - `func previewCategoryTotal(_ category: Category, year: Int, month: Int) -> Int`
  - `func forecastNetWorth(atEndOf year: Int) -> Int?`
  - `func forecastNetWorthYoY(atEndOf year: Int) -> (changeGBP: Int, percent: Double?)?`
  - Existing management methods unchanged in signature: `toggleGroup(_:)`, `toggleEntry(_:)`, `confirm(_:)`, `unconfirm(_:) -> Bool`, `updateEntry(_:amountMinorUnits:frequency:interval:) -> Bool`, `addHypotheticalEntry(groupName:categoryId:amountMinorUnits:frequency:interval:startDate:)`
  - Removed: `periods`, `horizon`, `extendHorizonToNextYear()`, `confirmedTotal(categoryId:period:)`, `previewTotal(categoryId:period:)` (the old `PayPeriod`-taking wrappers — replaced by the calendar-month-taking `categoryTotal`/`previewCategoryTotal` above)

- [ ] **Step 1: Replace the file**

Replace the full contents of `App/Forecast/ForecastViewModel.swift` with:

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
    @Published var accounts: [Account] = []
    @Published var balanceSnapshots: [BalanceSnapshot] = []
    @Published var transactions: [Transaction] = [] {
        didSet { calendarTotals = BudgetGridCalculator.calendarTotalsLookup(transactions: transactions) }
    }
    @Published var exchangeRate: ExchangeRateSetting = ExchangeRateSetting(eurToGbpRate: 0.87, updatedAt: Date())
    @Published var errorMessage: String?
    /// (year, month) of the later of the latest transaction date or the latest balance
    /// snapshot date, across everything `load()` fetched. `nil` before the first successful
    /// `load()`, or if there's no transaction or balance data at all.
    @Published private(set) var latestRealMonth: (year: Int, month: Int)?

    private let dbQueue: DatabaseQueue
    private var calendarTotals: [Int64: [Int: [Int: Int]]] = [:]
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
        latestRealMonth = Self.computeLatestRealMonth(transactions: transactions, balanceSnapshots: balanceSnapshots, calendar: Self.calendar)
    }

    private static func computeLatestRealMonth(transactions: [Transaction], balanceSnapshots: [BalanceSnapshot], calendar: Calendar) -> (year: Int, month: Int)? {
        let allDates = transactions.map(\.date) + balanceSnapshots.map(\.date)
        guard let latest = allDates.max() else { return nil }
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
        let end = Self.calendar.date(byAdding: DateComponents(month: 1, day: -1), to: start)!
        return (start, end)
    }

    /// The category's total for one month: the actual transaction total when the month
    /// is real (`isActual`), the confirmed forecast otherwise.
    func categoryTotal(_ category: Category, year: Int, month: Int) -> Int {
        if isActual(year: year, month: month) {
            return BudgetGridCalculator.categoryTotalForCalendarMonth(category: category, year: year, month: month, calendarTotals: calendarTotals)
        }
        guard let categoryId = category.id else { return 0 }
        let range = dateRange(forYear: year, month: month)
        return ForecastCalculator.confirmedTotal(categoryId: categoryId, period: PayPeriod(startDate: range.start, endDate: range.end, type: .projected), entries: entries, groups: groups)
    }

    /// Confirmed total plus enabled `.hypothetical` entries. For an actual month this
    /// always equals `categoryTotal` — a hypothetical can't retroactively change history.
    func previewCategoryTotal(_ category: Category, year: Int, month: Int) -> Int {
        if isActual(year: year, month: month) {
            return categoryTotal(category, year: year, month: month)
        }
        guard let categoryId = category.id else { return 0 }
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
    /// there's no `latestRealMonth` yet (no data loaded at all).
    func forecastNetWorth(atEndOf year: Int) -> Int? {
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
    /// year-end net worth when `year == thisYear`, or last year's *forecast* year-end
    /// net worth when `year == nextYear`. `percent` is `nil` when the baseline is zero.
    func forecastNetWorthYoY(atEndOf year: Int) -> (changeGBP: Int, percent: Double?)? {
        guard let forecast = forecastNetWorth(atEndOf: year) else { return nil }
        let baseline = year == thisYear ? realNetWorth(atEndOf: year - 1) : (forecastNetWorth(atEndOf: year - 1) ?? 0)
        let change = forecast - baseline
        let percent: Double? = baseline != 0 ? Double(change) / Double(abs(baseline)) : nil
        return (change, percent)
    }

    func toggleGroup(_ group: ForecastGroup) {
        guard let index = groups.firstIndex(where: { $0.id == group.id }) else { return }
        groups[index].isEnabled.toggle()
        try? dbQueue.write { db in try groups[index].update(db) }
    }

    func toggleEntry(_ entry: ForecastEntry) {
        guard let index = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        entries[index].isEnabled.toggle()
        try? dbQueue.write { db in try entries[index].update(db) }
    }

    func confirm(_ entry: ForecastEntry) {
        guard let index = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        entries[index].status = .confirmed
        try? dbQueue.write { db in try entries[index].update(db) }
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
    }
}
```

Note: `latestRealMonth`'s type is `(year: Int, month: Int)?`, a tuple — `@Published` supports tuple-typed properties fine as long as nothing requires `Equatable` conformance on it (nothing here does).

- [ ] **Step 2: Build to verify it compiles**

The old `ForecastComparisonView.swift` still references removed members (`viewModel.horizon`, `viewModel.extendHorizonToNextYear()`, `viewModel.confirmedTotal(categoryId:period:)`, `viewModel.previewTotal(categoryId:period:)`, `viewModel.periods`) — this task's build WILL fail until Task 3 replaces that file. Confirm the *only* errors are in `ForecastComparisonView.swift` (not e.g. a typo in the new `ForecastViewModel.swift` itself):

Run: `xcodebuild -project Budget.xcodeproj -scheme Budget -configuration Debug build 2>&1 | grep -A3 "error:"`
Expected: every error's file path is `ForecastComparisonView.swift`, none in `ForecastViewModel.swift`.

- [ ] **Step 3: Commit**

```bash
git add App/Forecast/ForecastViewModel.swift
git commit -m "Rewrite ForecastViewModel around calendar years instead of pay periods"
```

(This commit leaves the build broken until Task 3 — that's expected for a subagent-driven-development task sequence; each task is reviewed on its own diff, and the next task's brief says so.)

---

### Task 3: `ForecastView` — grid and year picker

**Files:**
- Create: `App/Forecast/ForecastView.swift`
- Delete: `App/Forecast/ForecastComparisonView.swift` (its `NewForecastEntryView`/`EditForecastEntryView` structs move into the new file — see Task 4, which is where the "Manage forecast" section using them is assembled; for *this* task, temporarily leave `ForecastComparisonView.swift` in place with just its top-level `ForecastComparisonView` struct's body emptied to `EmptyView()` so the project still builds, OR delete the whole file now and accept the build stays red until Task 4 re-adds `NewForecastEntryView`/`EditForecastEntryView` — **do the latter**: delete the file now, Task 4 recreates those two structs in the new file. This task's own review is scoped to `ForecastView.swift`'s grid + year picker; the reviewer should expect other build errors for the still-missing management sheets and not treat them as this task's bug.)

**Interfaces:**
- Consumes: `ForecastViewModel` (Task 2) — `thisYear`, `nextYear`, `categories`, `categoryTotal(_:year:month:)`, `previewCategoryTotal(_:year:month:)`. `MoneyText` (existing, `App/DesignSystem/MoneyText.swift`, params `minorUnits:currency:font:colorOverride:alignment:` all defaulted except `minorUnits`).
- Produces: `struct ForecastView: View { @ObservedObject var viewModel: ForecastViewModel }` (no `categories:` parameter — the view model now loads its own). Task 4 adds the net worth headline and manage-forecast section as additional content in this same file, and wires it into `ContentView.swift`.

- [ ] **Step 1: Delete the old view file**

```bash
git rm App/Forecast/ForecastComparisonView.swift
```

- [ ] **Step 2: Create the new grid view**

Create `App/Forecast/ForecastView.swift`:

```swift
// App/Forecast/ForecastView.swift
import SwiftUI
import BudgetCore
import struct BudgetCore.Category

struct ForecastView: View {
    @ObservedObject var viewModel: ForecastViewModel
    @State private var selectedYear: Int
    @State private var horizontalOffset: CGFloat = 0

    // A plain memberwise init would make `selectedYear` a required call-site argument;
    // this way callers just pass `viewModel`, and the initial year comes from it.
    init(viewModel: ForecastViewModel) {
        self.viewModel = viewModel
        _selectedYear = State(initialValue: viewModel.thisYear)
    }

    private func categoriesByType(_ type: CategoryType) -> [Category] {
        viewModel.categories.filter { $0.type == type }
    }

    private enum ForecastRowKind: Identifiable {
        case sectionHeader(String)
        case category(Category)
        var id: String {
            switch self {
            case .sectionHeader(let title): return "header-\(title)"
            case .category(let category): return "cat-\(category.id ?? -1)"
            }
        }
    }

    private struct ForecastRow: Identifiable {
        let kind: ForecastRowKind
        let shaded: Bool
        var id: String { kind.id }
    }

    private func rowColor(for type: CategoryType) -> Color {
        switch type {
        case .income: return .green
        case .expense: return .red
        case .transfer: return .blue
        }
    }

    private var allRows: [ForecastRow] {
        func section(_ title: String, _ type: CategoryType) -> [ForecastRow] {
            var rows: [ForecastRow] = [ForecastRow(kind: .sectionHeader(title), shaded: false)]
            for (index, category) in categoriesByType(type).enumerated() {
                rows.append(ForecastRow(kind: .category(category), shaded: index % 2 == 1))
            }
            return rows
        }
        return section("Income", .income) + section("Expenses", .expense) + section("Transfers", .transfer)
    }

    /// A category renders as a two-line row (confirmed + preview) when any month in the
    /// selected year has a preview total that differs from confirmed.
    private func isTwoLine(_ category: Category, year: Int) -> Bool {
        (1...12).contains { month in
            viewModel.categoryTotal(category, year: year, month: month) != viewModel.previewCategoryTotal(category, year: year, month: month)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
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
                .onPreferenceChange(ForecastHorizontalOffsetKey.self) { horizontalOffset = $0 }
            }
        }
        .padding()
    }

    private var yearPicker: some View {
        HStack(spacing: 10) {
            ForEach([viewModel.thisYear, viewModel.nextYear], id: \.self) { year in
                Button {
                    selectedYear = year
                } label: {
                    Text(String(year)).font(.subheadline).bold()
                        .padding(8)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(selectedYear == year ? Color.accentColor.opacity(0.15) : Color.clear)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(selectedYear == year ? Color.accentColor : Color.clear, lineWidth: 2)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func rowLabel(_ row: ForecastRowKind, shaded: Bool) -> some View {
        switch row {
        case .sectionHeader(let title):
            Text(title)
                .font(.caption).bold()
                .tracking(0.6)
                .foregroundStyle(.secondary)
                .frame(width: 220, height: 24, alignment: .leading)
                .padding(.horizontal, 8)
                .background(Color.accentColor.opacity(0.08))
        case .category(let category):
            let twoLine = isTwoLine(category, year: selectedYear)
            Text(category.name)
                .frame(width: 220, height: twoLine ? 44 : 28, alignment: .leading)
                .padding(.horizontal, 8)
                .background(shaded ? Color.primary.opacity(0.07) : Color.clear)
                .overlay(Rectangle().frame(height: 1).foregroundStyle(.separator), alignment: .bottom)
                .overlay(Rectangle().frame(width: 3).foregroundStyle(rowColor(for: category.type)), alignment: .leading)
        }
    }

    @ViewBuilder
    private func rowCells(_ row: ForecastRowKind, shaded: Bool) -> some View {
        switch row {
        case .sectionHeader:
            HStack(spacing: 0) {
                ForEach(1...(12 + 1), id: \.self) { _ in
                    Color.clear.frame(width: 120, height: 24).padding(.horizontal, 8)
                }
            }
            .background(Color.accentColor.opacity(0.08))
        case .category(let category):
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
        }
    }

    private func forecastCell(confirmed: Int, preview: Int, twoLine: Bool, bold: Bool = false) -> some View {
        VStack(alignment: .trailing, spacing: 0) {
            Group {
                if confirmed == 0 {
                    Text("—").foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .trailing)
                } else {
                    MoneyText(minorUnits: confirmed, alignment: .trailing)
                }
            }
            .fontWeight(bold ? .bold : .regular)
            if twoLine {
                if preview != confirmed {
                    MoneyText(minorUnits: preview, font: .caption2.monospacedDigit(), alignment: .trailing)
                        .opacity(0.7)
                } else {
                    Color.clear.frame(height: 14)
                }
            }
        }
        .frame(width: 120)
        .padding(.horizontal, 8)
    }

    private static func monthLabel(_ month: Int) -> String {
        let formatter = DateFormatter()
        formatter.monthSymbols = Calendar(identifier: .gregorian).monthSymbols
        return formatter.monthSymbols[month - 1]
    }
}

/// The forecast grid body's horizontal scroll offset — same technique as
/// `BudgetGridView`'s `HorizontalOffsetKey`, a separate type because SwiftUI
/// `PreferenceKey`s are matched by type, and this view has its own frozen header.
private struct ForecastHorizontalOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value += nextValue() }
}
```

Note on `monthLabel`: unlike `BudgetGridView.monthYearLabel`, this only needs the month name (the year is already selected via the year picker, not per-column) — `DateFormatter().monthSymbols` gives `["January", "February", ...]` directly, no `Date` construction needed.

- [ ] **Step 3: Build**

Run: `xcodebuild -project Budget.xcodeproj -scheme Budget -configuration Debug build 2>&1 | grep -A3 "error:"`
Expected: errors only in `ContentView.swift` (still references the deleted `ForecastComparisonView` and the old `categories:` parameter) — that's Task 4's job. No errors in `ForecastView.swift`.

- [ ] **Step 4: Commit**

```bash
git add App/Forecast/ForecastView.swift
git rm App/Forecast/ForecastComparisonView.swift
git commit -m "Replace ForecastComparisonView with a calendar-year ForecastView grid"
```

---

### Task 4: Net worth headline, manage-forecast panel, and wiring

**Files:**
- Modify: `App/Forecast/ForecastView.swift`
- Modify: `App/ContentView.swift`

**Interfaces:**
- Consumes: `ForecastViewModel.forecastNetWorth(atEndOf:)`/`forecastNetWorthYoY(atEndOf:)` (Task 2), `ForecastView` (Task 3), `MoneyText`.
- Produces: the complete `ForecastView` screen; `ContentView.swift`'s `.forecast` case wired to it.

- [ ] **Step 1: Add the net worth headline and manage-forecast section to `ForecastView.swift`**

In `App/Forecast/ForecastView.swift`, add two new private computed views and wire them into `body`, and re-add the two entry-editing sheets (moved from the deleted `ForecastComparisonView.swift`, unchanged):

```swift
    @State private var showNewEntrySheet = false
    @State private var editingEntry: ForecastEntry?
    @State private var manageExpanded = false
```

(add these `@State` properties alongside the existing `selectedYear`/`horizontalOffset` at the top of `ForecastView`)

```swift
    private var netWorthHeadline: some View {
        HStack(spacing: 12) {
            netWorthStat(year: viewModel.thisYear, baselineLabel: "vs Dec \(viewModel.thisYear - 1)")
            netWorthStat(year: viewModel.nextYear, baselineLabel: "vs Dec \(viewModel.thisYear) forecast")
        }
    }

    private func netWorthStat(year: Int, baselineLabel: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Forecast net worth — Dec \(year)").font(.caption).foregroundStyle(.secondary)
            if let forecast = viewModel.forecastNetWorth(atEndOf: year) {
                MoneyText(minorUnits: forecast, font: .title2.bold())
            } else {
                Text("—").font(.title2.bold()).foregroundStyle(.secondary)
            }
            if let yoy = viewModel.forecastNetWorthYoY(atEndOf: year), let percent = yoy.percent {
                Text("\(percent >= 0 ? "↑" : "↓") \(String(format: "%.1f", abs(percent) * 100))% \(baselineLabel)")
                    .font(.caption2)
                    .foregroundStyle(percent >= 0 ? Color.green : Color.red)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
    }

    private var manageForecastSection: some View {
        DisclosureGroup("Manage forecast", isExpanded: $manageExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                if let error = viewModel.errorMessage {
                    Text(error).foregroundStyle(.red).font(.callout)
                }
                ForEach(viewModel.groups) { group in
                    HStack {
                        Toggle(group.name, isOn: Binding(
                            get: { group.isEnabled },
                            set: { _ in viewModel.toggleGroup(group) }
                        ))
                        if !group.isSystemManaged {
                            Text("custom").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    ForEach(viewModel.entries.filter { $0.groupId == group.id }) { entry in
                        HStack {
                            Toggle(viewModel.categories.first(where: { $0.id == entry.categoryId })?.name ?? "Unknown", isOn: Binding(
                                get: { entry.isEnabled },
                                set: { _ in viewModel.toggleEntry(entry) }
                            ))
                            .padding(.leading, 24)
                            Text(entry.status.rawValue).font(.caption).foregroundStyle(.secondary)
                            Button("Edit…") { editingEntry = entry }
                                .buttonStyle(.plain)
                                .font(.caption)
                            if entry.status == .hypothetical {
                                Button("Confirm") { viewModel.confirm(entry) }
                            } else if entry.status == .confirmed {
                                Button("Un-confirm") { viewModel.unconfirm(entry) }
                            }
                        }
                    }
                }
                Button("Add hypothetical forecast entry…") { showNewEntrySheet = true }
            }
            .padding(.top, 8)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
    }
```

Re-add these two structs at the bottom of `App/Forecast/ForecastView.swift` (moved from the deleted file, byte-for-byte unchanged):

```swift
struct NewForecastEntryView: View {
    let categories: [Category]
    let onSave: (String, Int64, Int, ForecastFrequency, Int, Date) -> Void

    @State private var groupName = "New scenario"
    @State private var categoryId: Int64?
    @State private var amountPounds = ""
    @State private var frequency: ForecastFrequency = .monthly
    @State private var interval = 1
    @State private var startDate = Date()

    var body: some View {
        Form {
            TextField("Group name", text: $groupName)
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
            Button("Save") {
                guard let categoryId, let pounds = Double(amountPounds) else { return }
                let category = categories.first { $0.id == categoryId }
                let signedMinorUnits = Int(pounds * 100) * (category?.type == .income ? 1 : -1)
                onSave(groupName, categoryId, signedMinorUnits, frequency, interval, startDate)
            }
        }
        .padding()
        .frame(width: 420)
    }
}

struct EditForecastEntryView: View {
    let entry: ForecastEntry
    let onSave: (Int, ForecastFrequency, Int) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var amountPounds: String
    @State private var frequency: ForecastFrequency
    @State private var interval: Int

    init(entry: ForecastEntry, onSave: @escaping (Int, ForecastFrequency, Int) -> Void) {
        self.entry = entry
        self.onSave = onSave
        _amountPounds = State(initialValue: String(format: "%.2f", Double(abs(entry.amountMinorUnits)) / 100))
        _frequency = State(initialValue: entry.frequency)
        _interval = State(initialValue: entry.interval)
    }

    /// Preserves the entry's existing sign (income positive, everything else negative) —
    /// the field only ever asks for a positive magnitude. nil if the field doesn't parse.
    private var signedAmount: Int? {
        guard let minorUnits = Money.parseMinorUnits(amountPounds) else { return nil }
        return entry.amountMinorUnits < 0 ? -abs(minorUnits) : abs(minorUnits)
    }

    /// Save is a no-op unless something actually changed: saving an untouched `.auto`
    /// entry would otherwise promote it to `.manual` (via `updateEntry`) and permanently
    /// opt that category out of `AutoForecastGenerator.refresh` for no reason.
    private var hasChanges: Bool {
        guard let signedAmount else { return false }
        return signedAmount != entry.amountMinorUnits || frequency != entry.frequency || interval != entry.interval
    }

    var body: some View {
        Form {
            TextField("Amount (£)", text: $amountPounds)
            Picker("Frequency", selection: $frequency) {
                ForEach(ForecastFrequency.allCases, id: \.self) { freq in Text(freq.rawValue).tag(freq) }
            }
            Stepper("Every \(interval) \(frequency.rawValue)", value: $interval, in: 1...12)
            HStack {
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save") {
                    guard hasChanges, let signedAmount else { return }
                    onSave(signedAmount, frequency, interval)
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

Update `body` to include the new sections and the two sheets — replace:

```swift
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            yearPicker
```

with:

```swift
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            netWorthHeadline
            yearPicker
```

and change the closing of `body` (the `.onPreferenceChange` line, then two closing braces, then `.padding()`, then the final closing brace) from:

```swift
                .onPreferenceChange(ForecastHorizontalOffsetKey.self) { horizontalOffset = $0 }
            }
        }
        .padding()
    }
```

to:

```swift
                .onPreferenceChange(ForecastHorizontalOffsetKey.self) { horizontalOffset = $0 }
            }
            manageForecastSection
        }
        .padding()
        .sheet(isPresented: $showNewEntrySheet) {
            NewForecastEntryView(categories: viewModel.categories) { newGroupName, categoryId, amountMinorUnits, frequency, interval, startDate in
                viewModel.addHypotheticalEntry(groupName: newGroupName, categoryId: categoryId, amountMinorUnits: amountMinorUnits, frequency: frequency, interval: interval, startDate: startDate)
                showNewEntrySheet = false
            }
        }
        .sheet(item: $editingEntry) { entry in
            EditForecastEntryView(entry: entry) { amountMinorUnits, frequency, interval in
                viewModel.updateEntry(entry, amountMinorUnits: amountMinorUnits, frequency: frequency, interval: interval)
                editingEntry = nil
            }
        }
    }
```

(Note the `VStack`'s closing `}` moves down one line to after `manageForecastSection` — the outer `VStack(alignment: .leading, spacing: 8) { netWorthHeadline; yearPicker; <existing grid VStack>; manageForecastSection }` now has four children instead of two.)

- [ ] **Step 2: Wire `ContentView.swift`**

In `App/ContentView.swift`, update the comment above `forecastHorizon` (it references the now-removed `ForecastViewModel.horizon`):

```swift
    /// How far ahead to project forecasted pay periods in the Budget grid (the Forecast
    /// screen manages its own horizon independently — see `ForecastViewModel.horizon` —
    /// since only that screen has an extend-to-next-year action).
```

becomes:

```swift
    /// How far ahead to project forecasted pay periods in the Budget grid (the Forecast
    /// screen computes its own thisYear/nextYear independently — see `ForecastViewModel`).
```

and replace:

```swift
                case .forecast:
                    ForecastComparisonView(viewModel: forecastViewModel, categories: categories)
                        .onAppear { try? forecastViewModel.load() }
```

with:

```swift
                case .forecast:
                    ForecastView(viewModel: forecastViewModel)
                        .onAppear { try? forecastViewModel.load() }
```

- [ ] **Step 3: Build**

Run: `xcodebuild -project Budget.xcodeproj -scheme Budget -configuration Debug build 2>&1 | tail -20`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Run the full test suite**

Run: `swift test 2>&1 | tail -10`
Expected: all tests pass (134 existing + 3 new from Task 1 = 137 — the exact prior count may have drifted since this plan was written; the point is 0 failures).

- [ ] **Step 5: Live walkthrough**

Launch the built app (kill any stale running instance first, launch the exact fresh DerivedData binary — `pgrep -fl "Budget.app/Contents/MacOS/Budget"` then `open <path>`). Navigate to Forecast and verify:
- Two net worth stat blocks render with real figures (not "—", given this database has real balance/transaction data through February 2026).
- The year picker shows exactly two chips (this year, next year); clicking each switches the grid.
- Scrolling the grid vertically keeps the header pinned; scrolling horizontally keeps the category column pinned (same frozen-pane behavior as the Budget grid).
- January/February (or whichever months are ≤ the latest real data) show actual transaction totals; later months show forecast figures — both render, neither errors.
- "Manage forecast" expands to show the existing groups/entries list; toggling a group/entry, editing an entry, and adding a hypothetical entry all still work and the hypothetical's effect appears as a second muted line on its category's row.

- [ ] **Step 6: Commit**

```bash
git add App/Forecast/ForecastView.swift App/ContentView.swift
git commit -m "Add net worth headline and manage-forecast panel to ForecastView"
```
