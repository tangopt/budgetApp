# Dashboard Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A Dashboard landing page that combines actuals and the confirmed forecast on one timeline — import launcher with data freshness, net worth line since 2020 with forecast, year-over-year change bars, current-month tracking, a year-at-a-glance (monthly actual + forecast), top categories, needs-attention, upcoming bills and accounts — plus a "catch-all" expense category that keeps the forecast realistic.

**Architecture:** All logic is pure `BudgetCore` code over a `DashboardInput` value (`MonthBlend`, `DashboardCalculator`, `ForecastProjector`, `CatchAllCategory`), built test-first. Existing view-model formulas (`netWorthTotal`, `realNetWorth`, the forecast month walk, the confirmed-entry filter) are extracted into shared BudgetCore functions so the dashboard and the Budget/Forecast screens cannot disagree. The App layer loads once into a `DashboardViewModel`, renders with Swift Charts, and reuses the import flow through an extracted `ImportFlowHost`.

**Tech Stack:** Swift 5.10 / SwiftUI + Swift Charts (system framework, macOS 26), GRDB 6.29, XCTest.

**Spec:** `docs/superpowers/specs/2026-10-02-dashboard-design.md` (companion: `2026-10-02-statement-balances-design.md`). **Prerequisite:** the statement-balances plan (`docs/superpowers/plans/2026-10-02-statement-balances.md`) is complete and merged on `main`.

## Global Constraints

- Money is `Int` minor units, signed (expenses negative). Dashboard cards display Income/Expenses as positive magnitudes and Net signed. All date logic uses the **UTC** gregorian calendar (`MonthRange.calendar`).
- **Month blend rule (binding):** for a month that is the current calendar month *and* has imported transactions, each non-transfer category's projected total is the larger spend/income of actual-so-far vs the full-month confirmed expectation (income: `max`; expense, signed: `min`). Months ≤ the data-through month (other than the current month) are actual; all other months are the confirmed forecast. The dashboard **always uses confirmed forecast entries, never a scenario preview**.
- **Byte-identical refactors:** the Forecast screen's Dec 2026 = **£209,832.70** and Dec 2027 = **£271,292.60** (headline values at spec time, on today's database) and the Budget grid's per-year net worth change must not change. Tasks 1–3 extract shared code; existing tests must stay green.
- Existing tests must stay green. New parameters on existing model initializers are added **with defaults**.
- Test files: never annotate with a bare `Category` type (ambiguous with an Objective-C typedef; `BudgetCore.Category` is also unusable because the module declares `enum BudgetCore`) — build values by calling `Category(...)`/passing array literals to typed parameters, and let types be inferred. App files that reference `Category` use `import struct BudgetCore.Category`.
- Work directly on `main` (no worktree). Commit messages end with a blank line then `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>`. **Do not push.**
- Build hygiene (repo lives under iCloud-synced `~/Documents`): never run `swift test` and `xcodebuild` at the same time; if "ambiguous for type lookup" errors mention GRDB files with " 2.swift" names, `rm -rf .build` and rebuild once in isolation. `xcodebuild` can exceed 2–5 minutes; let it finish.
- Test commands: `swift test --filter <ClassName>`, full: `swift test`. App build: `xcodegen generate && xcodebuild -project Budget.xcodeproj -scheme Budget -destination 'platform=macOS' build` (launch with `open "<DerivedData path from the build output>/Build/Products/Debug/Budget.app"` — never by bundle id; stale builds exist).
- **Never run, import into, or write to the real database** (`~/Library/Application Support/Budget/budget.sqlite`). Manual checks use a copy and the `BUDGET_DB_PATH` environment variable (added by the statement-balances plan).
- Swift Charts / SwiftUI snippets in Tasks 12–14 are written to compile against macOS 26 but exact modifier signatures may need small adjustments; keep the described behavior.

---

### Task 1: MonthRange + shared month-end net worth

**Files:**
- Create: `Sources/BudgetCore/Support/MonthRange.swift`
- Modify: `Sources/BudgetCore/NetWorth/NetWorthCalculator.swift`, `App/Budget/BudgetGridViewModel.swift`, `App/Forecast/ForecastViewModel.swift`
- Test: `Tests/BudgetCoreTests/NetWorthCalculatorTests.swift`

**Interfaces:**
- Produces: `MonthRange.calendar` (UTC gregorian), `MonthRange.of(year:month:) -> (start: Date, end: Date)` (`end` = last moment of the month), `MonthRange.components(of:) -> (year: Int, month: Int)`, `MonthRange.index(year:month:) -> Int` (`year*12 + month - 1`); `NetWorthCalculator.monthEndNetWorth(accounts:snapshots:transactions:rate:year:month:) -> Int?` (`nil` when no account has a snapshot at or before that month). Used by Tasks 3, 8, 9.

- [ ] **Step 1: Write the failing test** — add to `NetWorthCalculatorTests`:

```swift
    private func utc(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: DateComponents(year: y, month: m, day: d))!
    }

    // Must equal the sum of each account's monthlyBalance — the formula BudgetGridViewModel
    // and ForecastViewModel each used to carry their own copy of.
    func testMonthEndNetWorthSumsCarriedForwardAccountBalances() {
        let gbp = Account(id: 1, name: "Current", currency: .gbp, kind: .cash, trackingMode: .manual)
        let eur = Account(id: 2, name: "EUR", currency: .eur, kind: .cash, trackingMode: .imported)
        let snapshots = [
            BalanceSnapshot(id: 1, accountId: 1, date: utc(2026, 1, 1), balanceMinorUnits: 100_000, note: nil),
            BalanceSnapshot(id: 2, accountId: 1, date: utc(2026, 3, 1), balanceMinorUnits: 150_000, note: nil),
            BalanceSnapshot(id: 3, accountId: 2, date: utc(2026, 2, 1), balanceMinorUnits: 200_000, note: nil)
        ]
        let transactions = [
            Transaction(id: 1, importBatchId: 1, accountId: 2, date: utc(2026, 2, 10), rawDescription: "X", amountMinorUnits: -10_000, categoryId: nil, status: .confirmed, categorizedBy: .manual, fingerprint: "x")
        ]
        let rate = ExchangeRateSetting(eurToGbpRate: 0.5, updatedAt: utc(2026, 1, 1))

        // Feb 2026: GBP carried forward from Jan (100_000); EUR imported = 200_000 - 10_000 = 190_000 EUR → 95_000 GBP.
        XCTAssertEqual(NetWorthCalculator.monthEndNetWorth(accounts: [gbp, eur], snapshots: snapshots, transactions: transactions, rate: rate, year: 2026, month: 2), 195_000)
        // Mar 2026: GBP picks up its new snapshot (150_000); EUR carries 190_000 → 95_000.
        XCTAssertEqual(NetWorthCalculator.monthEndNetWorth(accounts: [gbp, eur], snapshots: snapshots, transactions: transactions, rate: rate, year: 2026, month: 3), 245_000)
    }

    func testMonthEndNetWorthIsNilBeforeAnyAccountHasData() {
        let gbp = Account(id: 1, name: "Current", currency: .gbp, kind: .cash, trackingMode: .manual)
        let snapshots = [BalanceSnapshot(id: 1, accountId: 1, date: utc(2026, 3, 1), balanceMinorUnits: 100_000, note: nil)]
        let rate = ExchangeRateSetting(eurToGbpRate: 0.87, updatedAt: utc(2026, 1, 1))
        XCTAssertNil(NetWorthCalculator.monthEndNetWorth(accounts: [gbp], snapshots: snapshots, transactions: [], rate: rate, year: 2026, month: 2))
    }
```

- [ ] **Step 2: Run to verify it fails** — `swift test --filter NetWorthCalculatorTests` → compile error "type 'NetWorthCalculator' has no member 'monthEndNetWorth'".

- [ ] **Step 3: Implement**

```swift
// Sources/BudgetCore/Support/MonthRange.swift
import Foundation

/// UTC calendar-month helpers shared by the dashboard and the grid/forecast view models,
/// so "the end of March" means the same instant everywhere.
public enum MonthRange {
    public static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    /// `start` is 00:00:00 UTC on the 1st; `end` is the LAST MOMENT of the month's last day
    /// (next month's start minus one second) — see `FrequencyExpander`'s inclusive
    /// occurrence check; midnight at the start of the last day would silently exclude a
    /// same-day-later occurrence.
    public static func of(year: Int, month: Int) -> (start: Date, end: Date) {
        let start = calendar.date(from: DateComponents(year: year, month: month, day: 1))!
        let end = calendar.date(byAdding: .month, value: 1, to: start)!.addingTimeInterval(-1)
        return (start, end)
    }

    public static func components(of date: Date) -> (year: Int, month: Int) {
        let parts = calendar.dateComponents([.year, .month], from: date)
        return (parts.year!, parts.month!)
    }

    /// Orderable month index: `year * 12 + (month - 1)`.
    public static func index(year: Int, month: Int) -> Int { year * 12 + (month - 1) }
}
```

Add to `NetWorthCalculator` (below `monthlyBalance`):

```swift
    /// Total GBP net worth as of the end of the given calendar month: the sum of every
    /// account's `monthlyBalance` (latest snapshot at or before the month end, plus
    /// transactions after it for `.imported` accounts). `nil` when no account has any data
    /// at or before that month — distinguishes "no data yet" from "genuinely zero".
    /// `BudgetGridViewModel.netWorthTotal` and `ForecastViewModel.realNetWorth` delegate here.
    public static func monthEndNetWorth(accounts: [Account], snapshots: [BalanceSnapshot], transactions: [Transaction], rate: ExchangeRateSetting, year: Int, month: Int) -> Int? {
        let range = MonthRange.of(year: year, month: month)
        var total = 0
        var hasData = false
        for account in accounts {
            if let balance = monthlyBalance(account: account, snapshots: snapshots, transactions: transactions, rate: rate, monthStart: range.start, monthEnd: range.end) {
                total += balance.gbpBalanceMinorUnits
                hasData = true
            }
        }
        return hasData ? total : nil
    }
```

In `App/Budget/BudgetGridViewModel.swift` replace `netWorthTotal` and `hasNetWorthData`:

```swift
    func netWorthTotal(year: Int, month: Int) -> Int {
        NetWorthCalculator.monthEndNetWorth(accounts: accounts, snapshots: balanceSnapshots, transactions: transactions, rate: exchangeRate, year: year, month: month) ?? 0
    }

    /// True when at least one account has data (a snapshot at or before this month) for
    /// `year`/`month` — distinguishes "no data yet" from "net worth was genuinely zero."
    private func hasNetWorthData(year: Int, month: Int) -> Bool {
        NetWorthCalculator.monthEndNetWorth(accounts: accounts, snapshots: balanceSnapshots, transactions: transactions, rate: exchangeRate, year: year, month: month) != nil
    }
```

In `App/Forecast/ForecastViewModel.swift` replace the body of `realNetWorth(atEndOf:)`:

```swift
    private func realNetWorth(atEndOf year: Int) -> Int {
        NetWorthCalculator.monthEndNetWorth(accounts: accounts, snapshots: balanceSnapshots, transactions: transactions, rate: exchangeRate, year: year, month: 12) ?? 0
    }
```

- [ ] **Step 4: Verify** — `swift test --filter NetWorthCalculatorTests` → PASS; `swift test` → all green; `xcodegen generate && xcodebuild -project Budget.xcodeproj -scheme Budget -destination 'platform=macOS' build 2>&1 | tail -5` → `** BUILD SUCCEEDED **` (run these sequentially, never concurrently).

- [ ] **Step 5: Commit**

```bash
git add Sources/BudgetCore/Support/MonthRange.swift Sources/BudgetCore/NetWorth/NetWorthCalculator.swift App/Budget/BudgetGridViewModel.swift App/Forecast/ForecastViewModel.swift Tests/BudgetCoreTests/NetWorthCalculatorTests.swift
git commit -m "Extract shared month-end net worth into NetWorthCalculator and add MonthRange

Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
```

---

### Task 2: ForecastCalculator.confirmedEntries

**Files:**
- Modify: `Sources/BudgetCore/Forecasting/ForecastCalculator.swift`
- Test: `Tests/BudgetCoreTests/ForecastCalculatorTests.swift`

**Interfaces:**
- Produces: `ForecastCalculator.confirmedEntries(entries:groups:) -> [ForecastEntry]` — enabled entries, status `.auto`/`.manual`/`.confirmed`, in an enabled group. Used by Tasks 7 and 9.

- [ ] **Step 1: Write the failing test** — add to `ForecastCalculatorTests`:

```swift
    func testConfirmedEntriesExcludesHypotheticalDisabledAndDisabledGroupEntries() {
        let groups = [
            ForecastGroup(id: 1, name: "On", note: nil, isEnabled: true, isSystemManaged: false),
            ForecastGroup(id: 2, name: "Off", note: nil, isEnabled: false, isSystemManaged: false)
        ]
        func entry(_ id: Int64, group: Int64, status: ForecastEntryStatus, enabled: Bool = true) -> ForecastEntry {
            ForecastEntry(id: id, groupId: group, categoryId: 10, amountMinorUnits: -100, frequency: .monthly, interval: 1, startDate: date(2026, 1, 1), endDate: nil, isEnabled: enabled, status: status, note: nil)
        }
        let entries = [
            entry(1, group: 1, status: .auto), entry(2, group: 1, status: .manual), entry(3, group: 1, status: .confirmed),
            entry(4, group: 1, status: .hypothetical), entry(5, group: 1, status: .auto, enabled: false), entry(6, group: 2, status: .auto)
        ]
        XCTAssertEqual(ForecastCalculator.confirmedEntries(entries: entries, groups: groups).map(\.id), [1, 2, 3])
    }
```

- [ ] **Step 2: Run to verify it fails** — `swift test --filter ForecastCalculatorTests` → "no member 'confirmedEntries'".

- [ ] **Step 3: Implement** — in `ForecastCalculator`, add before the private `total`:

```swift
    /// The entries that count toward the *confirmed* forecast: enabled, not hypothetical, and
    /// in an enabled group. Shared by `total` and by the dashboard's upcoming-bills list so
    /// the two can never apply different rules.
    public static func confirmedEntries(entries: [ForecastEntry], groups: [ForecastGroup]) -> [ForecastEntry] {
        let enabledGroupIds = Set(groups.filter(\.isEnabled).compactMap(\.id))
        return entries.filter { $0.isEnabled && $0.status != .hypothetical && enabledGroupIds.contains($0.groupId) }
    }
```

and replace the private `total(...)`:

```swift
    private static func total(categoryId: Int64, period: PayPeriod, entries: [ForecastEntry], groups: [ForecastGroup], selectedScenarioGroupId: Int64?, includeHypothetical: Bool) -> Int {
        let confirmed = confirmedEntries(entries: entries, groups: groups)
        let hypothetical = includeHypothetical
            ? entries.filter { $0.isEnabled && $0.status == .hypothetical && $0.groupId == selectedScenarioGroupId }
            : []
        return (confirmed + hypothetical)
            .filter { $0.categoryId == categoryId }
            .reduce(0) { $0 + FrequencyExpander.amount(for: $1, in: period) }
    }
```

- [ ] **Step 4: Verify** — `swift test --filter ForecastCalculatorTests` → PASS (all existing cases unchanged); `swift test` → green.

- [ ] **Step 5: Commit**

```bash
git add Sources/BudgetCore/Forecasting/ForecastCalculator.swift Tests/BudgetCoreTests/ForecastCalculatorTests.swift
git commit -m "Extract ForecastCalculator.confirmedEntries

Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
```

---

### Task 3: ForecastProjector (shared forecast net worth walk)

**Files:**
- Create: `Sources/BudgetCore/NetWorth/NetWorthPoint.swift`, `Sources/BudgetCore/Forecasting/ForecastProjector.swift`
- Modify: `App/Forecast/ForecastViewModel.swift`
- Test: `Tests/BudgetCoreTests/ForecastProjectorTests.swift`

**Interfaces:**
- Consumes: `MonthRange` (Task 1), `ForecastCalculator.confirmedNetWorthImpact`.
- Produces: `NetWorthPoint(year:month:valueMinorUnits:)` (`Equatable`, `Identifiable` with `id = MonthRange.index`); `ForecastProjector.monthlyProjection(startingNetWorth:latestRealMonth:throughYear:categories:entries:groups:) -> [NetWorthPoint]` (running net worth at the end of each month strictly after `latestRealMonth` through December of `throughYear`); `ForecastProjector.forecastNetWorth(startingNetWorth:latestRealMonth:atEndOf:categories:entries:groups:) -> Int` (the December value, or `startingNetWorth` when there are no months to walk). Used by Task 8.

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/BudgetCoreTests/ForecastProjectorTests.swift
import XCTest
@testable import BudgetCore

final class ForecastProjectorTests: XCTestCase {
    private func utc(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: DateComponents(year: y, month: m, day: d))!
    }

    // Salary +3,000 on the 25th, rent -1,000 on the 1st, a transfer that must NOT count: +2,000/month.
    // The arrays are built inline as call arguments (never named with a `[Category]` type —
    // a bare `Category` annotation is ambiguous in this test target).
    private func projection(start: Int, latest: (year: Int, month: Int), through year: Int) -> [NetWorthPoint] {
        ForecastProjector.monthlyProjection(
            startingNetWorth: start, latestRealMonth: latest, throughYear: year,
            categories: [Category(id: 1, name: "Salary", type: .income), Category(id: 2, name: "Rent", type: .expense), Category(id: 3, name: "Savings", type: .transfer)],
            entries: [
                ForecastEntry(id: 1, groupId: 1, categoryId: 1, amountMinorUnits: 300_000, frequency: .monthly, interval: 1, startDate: utc(2026, 1, 25), endDate: nil, isEnabled: true, status: .manual, note: nil),
                ForecastEntry(id: 2, groupId: 1, categoryId: 2, amountMinorUnits: -100_000, frequency: .monthly, interval: 1, startDate: utc(2026, 1, 1), endDate: nil, isEnabled: true, status: .manual, note: nil),
                ForecastEntry(id: 3, groupId: 1, categoryId: 3, amountMinorUnits: -50_000, frequency: .monthly, interval: 1, startDate: utc(2026, 1, 10), endDate: nil, isEnabled: true, status: .manual, note: nil)
            ],
            groups: [ForecastGroup(id: 1, name: "G", note: nil, isEnabled: true, isSystemManaged: false)]
        )
    }

    private func forecast(start: Int, latest: (year: Int, month: Int), atEndOf year: Int) -> Int {
        ForecastProjector.forecastNetWorth(
            startingNetWorth: start, latestRealMonth: latest, atEndOf: year,
            categories: [Category(id: 1, name: "Salary", type: .income), Category(id: 2, name: "Rent", type: .expense), Category(id: 3, name: "Savings", type: .transfer)],
            entries: [
                ForecastEntry(id: 1, groupId: 1, categoryId: 1, amountMinorUnits: 300_000, frequency: .monthly, interval: 1, startDate: utc(2026, 1, 25), endDate: nil, isEnabled: true, status: .manual, note: nil),
                ForecastEntry(id: 2, groupId: 1, categoryId: 2, amountMinorUnits: -100_000, frequency: .monthly, interval: 1, startDate: utc(2026, 1, 1), endDate: nil, isEnabled: true, status: .manual, note: nil),
                ForecastEntry(id: 3, groupId: 1, categoryId: 3, amountMinorUnits: -50_000, frequency: .monthly, interval: 1, startDate: utc(2026, 1, 10), endDate: nil, isEnabled: true, status: .manual, note: nil)
            ],
            groups: [ForecastGroup(id: 1, name: "G", note: nil, isEnabled: true, isSystemManaged: false)]
        )
    }

    func testProjectionAccumulatesMonthlyImpactAfterTheLatestRealMonth() {
        let points = projection(start: 1_000_000, latest: (2026, 2), through: 2026)
        XCTAssertEqual(points.count, 10) // March ... December
        XCTAssertEqual(points.first, NetWorthPoint(year: 2026, month: 3, valueMinorUnits: 1_200_000))
        XCTAssertEqual(points.last, NetWorthPoint(year: 2026, month: 12, valueMinorUnits: 3_000_000))
    }

    func testForecastNetWorthMatchesTheDecemberPointAcrossYears() {
        XCTAssertEqual(forecast(start: 1_000_000, latest: (2026, 2), atEndOf: 2026), 3_000_000)
        XCTAssertEqual(forecast(start: 1_000_000, latest: (2026, 2), atEndOf: 2027), 5_400_000)
    }

    func testNoMonthsToWalkReturnsTheStartingValue() {
        XCTAssertTrue(projection(start: 1_000_000, latest: (2026, 12), through: 2026).isEmpty)
        XCTAssertEqual(forecast(start: 1_000_000, latest: (2026, 12), atEndOf: 2026), 1_000_000)
    }

    func testProjectionRollsOverTheYearBoundary() {
        let points = projection(start: 0, latest: (2025, 11), through: 2026)
        // Dec 2025 has no entries yet (they start Jan 2026) → +0; then 12 months of +2,000.
        XCTAssertEqual(points.count, 13)
        XCTAssertEqual(points[0], NetWorthPoint(year: 2025, month: 12, valueMinorUnits: 0))
        XCTAssertEqual(points.last, NetWorthPoint(year: 2026, month: 12, valueMinorUnits: 2_400_000))
    }
}
```

- [ ] **Step 2: Run to verify it fails** — `swift test --filter ForecastProjectorTests` → "cannot find 'ForecastProjector' in scope".

- [ ] **Step 3: Implement**

```swift
// Sources/BudgetCore/NetWorth/NetWorthPoint.swift
import Foundation

/// A net worth value (GBP minor units) at the end of a calendar month.
public struct NetWorthPoint: Equatable, Identifiable {
    public let year: Int
    public let month: Int
    public let valueMinorUnits: Int

    public init(year: Int, month: Int, valueMinorUnits: Int) {
        self.year = year
        self.month = month
        self.valueMinorUnits = valueMinorUnits
    }

    public var id: Int { MonthRange.index(year: year, month: month) }
}
```

```swift
// Sources/BudgetCore/Forecasting/ForecastProjector.swift
import Foundation

/// The month-by-month forecast net worth walk, shared by `ForecastViewModel` (year-end
/// headline figures) and the dashboard (the dashed forecast line) so they cannot diverge.
public enum ForecastProjector {
    /// Running confirmed net worth at the END of every month strictly after
    /// `latestRealMonth`, through December of `throughYear`: starting net worth plus the
    /// accumulated `confirmedNetWorthImpact` (transfers excluded). Empty when
    /// `latestRealMonth` is already at or past that December.
    public static func monthlyProjection(startingNetWorth: Int, latestRealMonth: (year: Int, month: Int), throughYear: Int, categories: [Category], entries: [ForecastEntry], groups: [ForecastGroup]) -> [NetWorthPoint] {
        var points: [NetWorthPoint] = []
        var running = startingNetWorth
        var cursor = (year: latestRealMonth.year, month: latestRealMonth.month + 1)
        if cursor.month > 12 { cursor = (cursor.year + 1, 1) }
        while cursor.year <= throughYear {
            let range = MonthRange.of(year: cursor.year, month: cursor.month)
            let period = PayPeriod(startDate: range.start, endDate: range.end, type: .projected)
            running += ForecastCalculator.confirmedNetWorthImpact(period: period, categories: categories, entries: entries, groups: groups)
            points.append(NetWorthPoint(year: cursor.year, month: cursor.month, valueMinorUnits: running))
            cursor.month += 1
            if cursor.month > 12 { cursor = (cursor.year + 1, 1) }
        }
        return points
    }

    /// Forecast net worth at the end of December `year`; equals `startingNetWorth` when
    /// there are no months between `latestRealMonth` and that December.
    public static func forecastNetWorth(startingNetWorth: Int, latestRealMonth: (year: Int, month: Int), atEndOf year: Int, categories: [Category], entries: [ForecastEntry], groups: [ForecastGroup]) -> Int {
        monthlyProjection(startingNetWorth: startingNetWorth, latestRealMonth: latestRealMonth, throughYear: year, categories: categories, entries: entries, groups: groups).last?.valueMinorUnits ?? startingNetWorth
    }
}
```

In `App/Forecast/ForecastViewModel.swift` replace `computeForecastNetWorth(atEndOf:)` (leave `sumOverForecastMonths`, which the scenario preview still uses):

```swift
    private func computeForecastNetWorth(atEndOf year: Int) -> Int? {
        guard let latestRealMonth else { return nil }
        return ForecastProjector.forecastNetWorth(startingNetWorth: currentNetWorthGBP, latestRealMonth: latestRealMonth, atEndOf: year, categories: categories, entries: entries, groups: groups)
    }
```

- [ ] **Step 4: Verify** — `swift test --filter ForecastProjectorTests` → PASS; `swift test` → green; then the app build (sequentially): `xcodegen generate && xcodebuild -project Budget.xcodeproj -scheme Budget -destination 'platform=macOS' build 2>&1 | tail -5` → `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add Sources/BudgetCore/NetWorth/NetWorthPoint.swift Sources/BudgetCore/Forecasting/ForecastProjector.swift App/Forecast/ForecastViewModel.swift Tests/BudgetCoreTests/ForecastProjectorTests.swift
git commit -m "Extract the forecast net worth walk into ForecastProjector

Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
```

---

### Task 4: Catch-all category (model, migration, designation, auto-forecast skip)

**Files:**
- Modify: `Sources/BudgetCore/Models/Category.swift`, `Sources/BudgetCore/Models/Category+Migration.swift`, `Sources/BudgetCore/Database/DatabaseManager.swift`, `Sources/BudgetCore/Forecasting/AutoForecastGenerator.swift`
- Create: `Sources/BudgetCore/Forecasting/CatchAllCategory.swift`
- Test: `Tests/BudgetCoreTests/CatchAllCategoryTests.swift`, `Tests/BudgetCoreTests/AutoForecastGeneratorTests.swift`

**Interfaces:**
- Produces: `Category.isCatchAll: Bool` (init parameter `isCatchAll: Bool = false`, last position); `CatchAllCategory.designate(db:categoryId:) throws`, `CatchAllCategory.clear(db:categoryId:) throws`, `CatchAllError.notAnExpenseCategory`. `AutoForecastGenerator.regenerate` never touches a catch-all category's entries. Used by Tasks 5, 7, 14.

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/BudgetCoreTests/CatchAllCategoryTests.swift
import XCTest
import GRDB
@testable import BudgetCore

final class CatchAllCategoryTests: XCTestCase {
    private func manager() throws -> DatabaseManager {
        let manager = try DatabaseManager(path: nil)
        try manager.migrate()
        return manager
    }

    func testNewCategoriesAreNotCatchAllByDefault() throws {
        let manager = try manager()
        try manager.dbQueue.write { db in
            var category = Category(name: "Bulk other", type: .expense)
            try category.insert(db)
            XCTAssertFalse(try XCTUnwrap(Category.fetchOne(db, key: category.id!)).isCatchAll)
        }
    }

    func testDesignatingClearsThePreviousCatchAllAndPromotesItsAutoEntry() throws {
        let manager = try manager()
        try manager.dbQueue.write { db in
            var first = Category(name: "Other A", type: .expense, isCatchAll: true)
            var second = Category(name: "Other B", type: .expense)
            try first.insert(db)
            try second.insert(db)
            var group = ForecastGroup(name: "Detected recurring", note: nil, isEnabled: true, isSystemManaged: true)
            try group.insert(db)
            var entry = ForecastEntry(groupId: group.id!, categoryId: second.id!, amountMinorUnits: -17_139, frequency: .monthly, interval: 1, startDate: Date(), endDate: nil, isEnabled: true, status: .auto, note: nil)
            try entry.insert(db)

            try CatchAllCategory.designate(db: db, categoryId: second.id!)

            XCTAssertFalse(try XCTUnwrap(Category.fetchOne(db, key: first.id!)).isCatchAll)
            XCTAssertTrue(try XCTUnwrap(Category.fetchOne(db, key: second.id!)).isCatchAll)
            XCTAssertEqual(try XCTUnwrap(ForecastEntry.fetchOne(db, key: entry.id!)).status, .manual)
        }
    }

    func testOnlyExpenseCategoriesCanBeCatchAll() throws {
        let manager = try manager()
        try manager.dbQueue.write { db in
            var income = Category(name: "Pay", type: .income)
            try income.insert(db)
            XCTAssertThrowsError(try CatchAllCategory.designate(db: db, categoryId: income.id!)) { error in
                XCTAssertEqual(error as? CatchAllError, .notAnExpenseCategory)
            }
        }
    }

    func testClearRemovesTheFlagOnly() throws {
        let manager = try manager()
        try manager.dbQueue.write { db in
            var category = Category(name: "Bulk other", type: .expense)
            try category.insert(db)
            try CatchAllCategory.designate(db: db, categoryId: category.id!)
            try CatchAllCategory.clear(db: db, categoryId: category.id!)
            XCTAssertFalse(try XCTUnwrap(Category.fetchOne(db, key: category.id!)).isCatchAll)
        }
    }
}
```

Add to `AutoForecastGeneratorTests`:

```swift
    // The user keeps a realistic bulk allowance in a catch-all category. After a real import
    // that category has no recent confirmed activity, so the generator would normally delete
    // its auto entry (see testStaleAutoEntryIsRemovedWhenPatternNoLongerHolds) — for a
    // catch-all it must leave the entry alone.
    func testRegenerateLeavesCatchAllCategoryEntriesUntouched() throws {
        let (manager, _, _, periods) = try seededManagerWithRentHistory()
        try manager.dbQueue.write { db in
            var bulk = Category(name: "Bulk other", type: .expense, isCatchAll: true)
            try bulk.insert(db)
            let group = try AutoForecastGenerator.ensureDetectedRecurringGroup(db: db)
            var entry = ForecastEntry(groupId: group.id!, categoryId: bulk.id!, amountMinorUnits: -17_139, frequency: .monthly, interval: 1, startDate: periods[0].startDate, endDate: nil, isEnabled: true, status: .auto, note: nil)
            try entry.insert(db)

            try AutoForecastGenerator.regenerate(db: db, actualPeriods: periods)

            let kept = try ForecastEntry.filter(Column("categoryId") == bulk.id!).fetchAll(db)
            XCTAssertEqual(kept.count, 1)
            XCTAssertEqual(kept[0].amountMinorUnits, -17_139)
            XCTAssertEqual(kept[0].status, .auto)
        }
    }
```

- [ ] **Step 2: Run to verify they fail** — `swift test --filter "CatchAllCategoryTests|AutoForecastGeneratorTests"` → compile error "extra argument 'isCatchAll' in call".

- [ ] **Step 3: Implement**

`Category.swift`: add the property and init parameter —

```swift
    /// The one expense category that stands in for unplanned, never-itemised spending: its
    /// monthly allowance stays in the forecast and the auto-forecast never changes it.
    public var isCatchAll: Bool
```
```swift
    public init(id: Int64? = nil, name: String, type: CategoryType, groupId: Int64? = nil, isCatchAll: Bool = false) {
        self.id = id
        self.name = name
        self.type = type
        self.groupId = groupId
        self.isCatchAll = isCatchAll
    }
```

`Category+Migration.swift`: append —

```swift
func registerCategoryCatchAllMigration(_ migrator: inout DatabaseMigrator) {
    migrator.registerMigration("addIsCatchAllToCategory") { db in
        try db.alter(table: "category") { t in
            t.add(column: "isCatchAll", .boolean).notNull().defaults(to: false)
        }
    }
}
```

`DatabaseManager.registerMigrations`: add `registerCategoryCatchAllMigration(&migrator)` immediately after `registerCategoryGroupIdMigration(&migrator)`.

`CatchAllCategory.swift`:

```swift
// Sources/BudgetCore/Forecasting/CatchAllCategory.swift
import GRDB

public enum CatchAllError: Error, Equatable {
    case notAnExpenseCategory
}

public enum CatchAllCategory {
    /// Marks `categoryId` as THE catch-all expense category: clears the flag on every
    /// other category and promotes this category's `.auto` forecast entries to `.manual`
    /// so the amount sticks (the auto-forecast also skips catch-all categories entirely).
    public static func designate(db: Database, categoryId: Int64) throws {
        guard let category = try Category.fetchOne(db, key: categoryId), category.type == .expense else {
            throw CatchAllError.notAnExpenseCategory
        }
        try db.execute(sql: "UPDATE category SET isCatchAll = 0 WHERE isCatchAll = 1 AND id != ?", arguments: [categoryId])
        try db.execute(sql: "UPDATE category SET isCatchAll = 1 WHERE id = ?", arguments: [categoryId])
        try db.execute(sql: "UPDATE forecastEntry SET status = 'manual' WHERE categoryId = ? AND status = 'auto'", arguments: [categoryId])
    }

    public static func clear(db: Database, categoryId: Int64) throws {
        try db.execute(sql: "UPDATE category SET isCatchAll = 0 WHERE id = ?", arguments: [categoryId])
    }
}
```

`AutoForecastGenerator.regenerate`: right after `guard let categoryId = category.id else { continue }` add:

```swift
            // A designated catch-all keeps whatever allowance the user maintains for it.
            if category.isCatchAll { continue }
```

- [ ] **Step 4: Verify** — `swift test --filter "CatchAllCategoryTests|AutoForecastGeneratorTests"` → PASS; `swift test` → green.

- [ ] **Step 5: Commit**

```bash
git add Sources/BudgetCore/Models/Category.swift Sources/BudgetCore/Models/Category+Migration.swift Sources/BudgetCore/Database/DatabaseManager.swift Sources/BudgetCore/Forecasting/CatchAllCategory.swift Sources/BudgetCore/Forecasting/AutoForecastGenerator.swift Tests/BudgetCoreTests/CatchAllCategoryTests.swift Tests/BudgetCoreTests/AutoForecastGeneratorTests.swift
git commit -m "Add a catch-all expense category that the auto-forecast never touches

Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
```

---

### Task 5: Categories screen — catch-all toggle

**Files:**
- Modify: `App/Categories/CategoriesView.swift`

**Interfaces:**
- Consumes: `CatchAllCategory.designate/clear` (Task 4).

- [ ] **Step 1: Add to `CategoriesViewModel`** (below `assignCategory`):

```swift
    /// Designates (or clears) the catch-all expense category. Designating promotes the
    /// category's auto forecast entry to manual and clears any previous catch-all.
    func setCatchAll(_ category: Category, enabled: Bool) throws {
        guard let id = category.id else { return }
        try dbQueue.write { db in
            if enabled {
                try CatchAllCategory.designate(db: db, categoryId: id)
            } else {
                try CatchAllCategory.clear(db: db, categoryId: id)
            }
        }
        try load()
    }
```

- [ ] **Step 2: In the `List` row, insert after `Spacer()` and before the group `Picker`:**

```swift
                    if category.type == .expense {
                        Toggle("Catch-all", isOn: Binding(
                            get: { category.isCatchAll },
                            set: { newValue in try? viewModel.setCatchAll(category, enabled: newValue) }
                        ))
                        .toggleStyle(.checkbox)
                        .help("Use as the catch-all for unplanned spending. Its monthly allowance stays in the forecast, and the auto-forecast never changes it.")
                    }
```

- [ ] **Step 3: Build** — `xcodebuild -project Budget.xcodeproj -scheme Budget -destination 'platform=macOS' build 2>&1 | tail -5` → `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
git add App/Categories/CategoriesView.swift
git commit -m "Add a catch-all toggle to the Categories screen

Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
```

---

### Task 6: MonthBlend

**Files:**
- Create: `Sources/BudgetCore/Dashboard/MonthBlend.swift`
- Test: `Tests/BudgetCoreTests/MonthBlendTests.swift`

**Interfaces:**
- Consumes: `MonthRange` (Task 1), `CategoryType`.
- Produces: `MonthClass` (`.actual`, `.blended`, `.forecast`); `MonthBlend.classify(year:month:dataThrough:today:) -> MonthClass`; `MonthBlend.projectedTotal(actual:expected:categoryType:monthClass:) -> Int` (signed). Used by Tasks 8, 9.

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/BudgetCoreTests/MonthBlendTests.swift
import XCTest
@testable import BudgetCore

final class MonthBlendTests: XCTestCase {
    private func utc(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: DateComponents(year: y, month: m, day: d))!
    }

    func testClassifiesActualBlendedAndForecastMonths() {
        let dataThrough = utc(2026, 10, 13), today = utc(2026, 10, 14)
        XCTAssertEqual(MonthBlend.classify(year: 2025, month: 12, dataThrough: dataThrough, today: today), .actual)
        XCTAssertEqual(MonthBlend.classify(year: 2026, month: 9, dataThrough: dataThrough, today: today), .actual)
        XCTAssertEqual(MonthBlend.classify(year: 2026, month: 10, dataThrough: dataThrough, today: today), .blended)
        XCTAssertEqual(MonthBlend.classify(year: 2026, month: 11, dataThrough: dataThrough, today: today), .forecast)
        XCTAssertEqual(MonthBlend.classify(year: 2027, month: 1, dataThrough: dataThrough, today: today), .forecast)
    }

    func testNothingImportedThisMonthMakesTheCurrentMonthForecast() {
        let dataThrough = utc(2026, 9, 29), today = utc(2026, 10, 2)
        XCTAssertEqual(MonthBlend.classify(year: 2026, month: 9, dataThrough: dataThrough, today: today), .actual)
        XCTAssertEqual(MonthBlend.classify(year: 2026, month: 10, dataThrough: dataThrough, today: today), .forecast)
    }

    func testStaleDataTreatsTheGapMonthsAsForecast() {
        let dataThrough = utc(2026, 2, 14), today = utc(2026, 10, 2)
        XCTAssertEqual(MonthBlend.classify(year: 2026, month: 2, dataThrough: dataThrough, today: today), .actual)
        XCTAssertEqual(MonthBlend.classify(year: 2026, month: 3, dataThrough: dataThrough, today: today), .forecast)
        XCTAssertEqual(MonthBlend.classify(year: 2026, month: 10, dataThrough: dataThrough, today: today), .forecast)
    }

    func testNoDataAtAllIsForecast() {
        XCTAssertEqual(MonthBlend.classify(year: 2026, month: 10, dataThrough: nil, today: utc(2026, 10, 2)), .forecast)
    }

    // A clock behind the data never makes a later data month "forecast".
    func testDataAfterTodayIsTreatedAsToday() {
        let dataThrough = utc(2026, 10, 20), today = utc(2026, 10, 5)
        XCTAssertEqual(MonthBlend.classify(year: 2026, month: 9, dataThrough: dataThrough, today: today), .actual)
        XCTAssertEqual(MonthBlend.classify(year: 2026, month: 10, dataThrough: dataThrough, today: today), .blended)
        XCTAssertEqual(MonthBlend.classify(year: 2026, month: 11, dataThrough: dataThrough, today: today), .forecast)
    }

    func testActualAndForecastMonthsPassTheirOwnValueThrough() {
        XCTAssertEqual(MonthBlend.projectedTotal(actual: -500, expected: -850, categoryType: .expense, monthClass: .actual), -500)
        XCTAssertEqual(MonthBlend.projectedTotal(actual: -500, expected: -850, categoryType: .expense, monthClass: .forecast), -850)
    }

    func testBlendedIncomeTakesTheLarger() {
        XCTAssertEqual(MonthBlend.projectedTotal(actual: 100, expected: 300, categoryType: .income, monthClass: .blended), 300)
        XCTAssertEqual(MonthBlend.projectedTotal(actual: 400, expected: 300, categoryType: .income, monthClass: .blended), 400)
        XCTAssertEqual(MonthBlend.projectedTotal(actual: 100, expected: 0, categoryType: .income, monthClass: .blended), 100)
    }

    func testBlendedExpenseTakesTheLargerSpend() {
        // Signed: spend is negative, so the larger spend is the smaller (more negative) number.
        XCTAssertEqual(MonthBlend.projectedTotal(actual: -500, expected: -850, categoryType: .expense, monthClass: .blended), -850)
        XCTAssertEqual(MonthBlend.projectedTotal(actual: -900, expected: -850, categoryType: .expense, monthClass: .blended), -900)
        XCTAssertEqual(MonthBlend.projectedTotal(actual: 50, expected: -850, categoryType: .expense, monthClass: .blended), -850) // a refund
        XCTAssertEqual(MonthBlend.projectedTotal(actual: -25, expected: 0, categoryType: .expense, monthClass: .blended), -25) // unplanned
    }
}
```

- [ ] **Step 2: Run to verify it fails** — `swift test --filter MonthBlendTests` → "cannot find 'MonthBlend' in scope".

- [ ] **Step 3: Implement**

```swift
// Sources/BudgetCore/Dashboard/MonthBlend.swift
import Foundation

public enum MonthClass: Equatable {
    /// Real transactions only.
    case actual
    /// The current calendar month, with some transactions already imported: per category,
    /// the larger of what has happened and what was expected for the whole month.
    case blended
    /// The confirmed forecast only.
    case forecast
}

/// One definition of "which months are real, which are forecast, and what is the current
/// month" for every card on the dashboard.
public enum MonthBlend {
    /// `dataThrough` is the latest transaction date (nil: no data). A clock behind the data
    /// is treated as "today = dataThrough". Months ≤ the data month are `.actual` (the same
    /// rule as the Forecast grid's `isActual`), except the current calendar month, which is
    /// `.blended` when it has data and `.forecast` when it doesn't.
    public static func classify(year: Int, month: Int, dataThrough: Date?, today: Date) -> MonthClass {
        guard let dataThrough else { return .forecast }
        let target = MonthRange.index(year: year, month: month)
        let dataMonth = index(of: dataThrough)
        let todayMonth = index(of: max(today, dataThrough))
        if target == todayMonth && dataMonth == target { return .blended }
        if target <= dataMonth && target != todayMonth { return .actual }
        return .forecast
    }

    /// The projected signed total for one category in a month. For a blended month the
    /// category is treated as an allowance (envelope): income takes the larger of actual
    /// and expected, expense (negative) the larger spend. Transfers are never blended.
    public static func projectedTotal(actual: Int, expected: Int, categoryType: CategoryType, monthClass: MonthClass) -> Int {
        switch monthClass {
        case .actual: return actual
        case .forecast: return expected
        case .blended:
            switch categoryType {
            case .income: return max(actual, expected)
            case .expense: return min(actual, expected)
            case .transfer: return actual
            }
        }
    }

    private static func index(of date: Date) -> Int {
        let parts = MonthRange.components(of: date)
        return MonthRange.index(year: parts.year, month: parts.month)
    }
}
```

- [ ] **Step 4: Verify** — `swift test --filter MonthBlendTests` → PASS (8 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/BudgetCore/Dashboard/MonthBlend.swift Tests/BudgetCoreTests/MonthBlendTests.swift
git commit -m "Add MonthBlend: one actual/blended/forecast month rule for the dashboard

Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
```

---

### Task 7: DashboardInput + freshness, attention, accounts, upcoming bills, catch-all allowance

**Files:**
- Create: `Sources/BudgetCore/Dashboard/DashboardInput.swift`, `Sources/BudgetCore/Dashboard/DashboardCalculator.swift`
- Test: `Tests/BudgetCoreTests/DashboardFixture.swift`, `Tests/BudgetCoreTests/DashboardCalculatorTests.swift`

**Interfaces:**
- Consumes: `ForecastCalculator.confirmedEntries/confirmedTotal` (Task 2), `MonthRange` (Task 1), `Category.isCatchAll` (Task 4), `FrequencyExpander`, `NetWorthCalculator.accountBalances`.
- Produces: `DashboardInput(today:accounts:snapshots:transactions:categories:categoryGroups:forecastEntries:forecastGroups:importBatches:rate:)` with `dataThrough: Date?`, `effectiveToday: Date`, internal `calendarTotals`; `DashboardCalculator.dataFreshness(_:) -> DataFreshness`, `.attentionItems(_:) -> AttentionItems`, `.accountSummaries(_:) -> [AccountSummary]`, `.upcomingBills(_:days:) -> [UpcomingBill]`, `.catchAllAllowance(_:) -> CatchAllAllowance?`. Types below. The test-only `DashboardFixture` is reused by Tasks 8–9.

- [ ] **Step 1: Write the fixture and failing tests**

```swift
// Tests/BudgetCoreTests/DashboardFixture.swift
import Foundation
@testable import BudgetCore

/// Builds `DashboardInput` values with a small fixed chart of accounts. Only returns
/// `DashboardInput` (never `[Category]`) because a bare `Category` annotation is ambiguous
/// in this test target.
enum DashboardFixture {
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()
    static func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d))!
    }

    static let salaryId: Int64 = 1, rentId: Int64 = 2, savingsId: Int64 = 3, groceriesId: Int64 = 4, diningId: Int64 = 5, bulkId: Int64 = 6

    private static func entry(_ id: Int64, _ category: Int64, _ amount: Int, start: Date, status: ForecastEntryStatus = .manual, enabled: Bool = true, end: Date? = nil) -> ForecastEntry {
        ForecastEntry(id: id, groupId: 1, categoryId: category, amountMinorUnits: amount, frequency: .monthly, interval: 1, startDate: start, endDate: end, isEnabled: enabled, status: status, note: nil)
    }

    /// +3,000 salary on the 25th, -1,000 rent on the 1st: +2,000/month.
    static var salaryAndRent: [ForecastEntry] {
        [entry(1, salaryId, 300_000, start: date(2026, 1, 25)), entry(2, rentId, -100_000, start: date(2026, 1, 1))]
    }
    /// `salaryAndRent` plus -400 dining on the 14th: +1,600/month.
    static var withDining: [ForecastEntry] {
        salaryAndRent + [entry(3, diningId, -40_000, start: date(2026, 1, 14))]
    }

    static func txn(_ id: Int64, _ day: Date, _ amount: Int, category: Int64?, status: TransactionStatus = .confirmed, account: Int64 = 1) -> Transaction {
        Transaction(id: id, importBatchId: 1, accountId: account, date: day, rawDescription: "T\(id)", amountMinorUnits: amount, categoryId: category, status: status, categorizedBy: .manual, fingerprint: "fp\(id)")
    }

    static func snapshot(_ account: Int64, _ day: Date, _ balance: Int) -> BalanceSnapshot {
        BalanceSnapshot(accountId: account, date: day, balanceMinorUnits: balance, note: nil)
    }

    static func input(
        today: Date,
        accounts: [Account]? = nil,
        snapshots: [BalanceSnapshot] = [],
        transactions: [Transaction] = [],
        importBatches: [ImportBatch] = [],
        entries: [ForecastEntry]? = nil,
        catchAllId: Int64? = nil
    ) -> DashboardInput {
        DashboardInput(
            today: today,
            accounts: accounts ?? [Account(id: 1, name: "Current", currency: .gbp, kind: .cash, trackingMode: .manual)],
            snapshots: snapshots,
            transactions: transactions,
            categories: [
                Category(id: salaryId, name: "Salary", type: .income, isCatchAll: false),
                Category(id: rentId, name: "Rent", type: .expense, isCatchAll: catchAllId == rentId),
                Category(id: savingsId, name: "Savings", type: .transfer, isCatchAll: false),
                Category(id: groceriesId, name: "Groceries", type: .expense, groupId: 1, isCatchAll: catchAllId == groceriesId),
                Category(id: diningId, name: "Dining", type: .expense, groupId: 1, isCatchAll: catchAllId == diningId),
                Category(id: bulkId, name: "Bulk other", type: .expense, isCatchAll: catchAllId == bulkId)
            ],
            categoryGroups: [CategoryGroup(id: 1, name: "Food")],
            forecastEntries: entries ?? withDining,
            forecastGroups: [ForecastGroup(id: 1, name: "Detected recurring", note: nil, isEnabled: true, isSystemManaged: true)],
            importBatches: importBatches,
            rate: ExchangeRateSetting(eurToGbpRate: 0.5, updatedAt: date(2026, 1, 1))
        )
    }
}
```

```swift
// Tests/BudgetCoreTests/DashboardCalculatorTests.swift
import XCTest
@testable import BudgetCore

final class DashboardCalculatorTests: XCTestCase {
    private typealias F = DashboardFixture
    private func date(_ y: Int, _ m: Int, _ d: Int) -> Date { F.date(y, m, d) }

    // MARK: freshness

    func testBehindWhenTheLatestTransactionIsMonthsOld() {
        let input = F.input(
            today: date(2026, 10, 2),
            transactions: [F.txn(1, date(2026, 2, 14), -1_000, category: F.rentId)],
            importBatches: [ImportBatch(id: 1, accountId: 1, sourceFileName: "Budget copy.numbers", importedAt: date(2026, 9, 23))]
        )
        let freshness = DashboardCalculator.dataFreshness(input)
        XCTAssertEqual(freshness.status, .behind(months: 7, days: 230))
        XCTAssertEqual(freshness.dataThrough, date(2026, 2, 14))
        XCTAssertEqual(freshness.lastImportAt, date(2026, 9, 23))
        XCTAssertEqual(freshness.lastImportFileName, "Budget copy.numbers")
    }

    func testThirtyOneDaysIsStillUpToDateAndThirtyTwoIsBehind() {
        let today = date(2026, 10, 2)
        XCTAssertEqual(DashboardCalculator.dataFreshness(F.input(today: today, transactions: [F.txn(1, date(2026, 9, 1), -1, category: nil)])).status, .upToDate)
        XCTAssertEqual(DashboardCalculator.dataFreshness(F.input(today: today, transactions: [F.txn(1, date(2026, 8, 31), -1, category: nil)])).status, .behind(months: 1, days: 32))
    }

    func testNoTransactionsMeansNoData() {
        XCTAssertEqual(DashboardCalculator.dataFreshness(F.input(today: date(2026, 10, 2))).status, .noData)
    }

    // MARK: attention

    func testUncategorizedCountIncludesNilCategoryAndPendingReview() {
        let input = F.input(today: date(2026, 10, 2), transactions: [
            F.txn(1, date(2026, 9, 1), -100, category: F.rentId),
            F.txn(2, date(2026, 9, 2), -100, category: nil, status: .pendingReview),
            F.txn(3, date(2026, 9, 3), -100, category: F.groceriesId, status: .pendingReview)
        ])
        XCTAssertEqual(DashboardCalculator.attentionItems(input).uncategorizedCount, 2)
    }

    func testStaleBalancesExcludeImportedAccountsAndUseA45DayThreshold() {
        let today = date(2026, 10, 2) // 45 days earlier = 2026-08-18
        let accounts = [
            Account(id: 1, name: "Old", currency: .gbp, kind: .cash, trackingMode: .manual),
            Account(id: 2, name: "Imported", currency: .gbp, kind: .cash, trackingMode: .imported),
            Account(id: 3, name: "Fresh", currency: .gbp, kind: .cash, trackingMode: .manual),
            Account(id: 4, name: "Never", currency: .gbp, kind: .cash, trackingMode: .manual),
            Account(id: 5, name: "Edge", currency: .gbp, kind: .cash, trackingMode: .manual)
        ]
        let snapshots = [
            F.snapshot(1, date(2026, 1, 1), 100), F.snapshot(2, date(2025, 1, 1), 100), F.snapshot(3, date(2026, 9, 20), 100),
            F.snapshot(5, date(2026, 8, 17), 100) // 46 days old → stale
        ]
        let items = DashboardCalculator.attentionItems(F.input(today: today, accounts: accounts, snapshots: snapshots))
        XCTAssertEqual(items.staleBalanceCount, 3) // Old, Never, Edge
        XCTAssertEqual(items.oldestStaleSnapshotDate, date(2026, 1, 1))

        let exactly45 = DashboardCalculator.attentionItems(F.input(today: today, accounts: [accounts[4]], snapshots: [F.snapshot(5, date(2026, 8, 18), 100)]))
        XCTAssertEqual(exactly45.staleBalanceCount, 0)
    }

    func testCatchAllIssueStates() {
        let today = date(2026, 10, 2)
        XCTAssertEqual(DashboardCalculator.attentionItems(F.input(today: today)).catchAllIssue, .notDesignated)
        // Designated, but only dining/rent/salary entries exist → no allowance for the bulk category.
        XCTAssertEqual(DashboardCalculator.attentionItems(F.input(today: today, catchAllId: F.bulkId)).catchAllIssue, .noAllowance)
        // Designated with an entry of its own → fine.
        let withBulk = F.withDining + [ForecastEntry(id: 9, groupId: 1, categoryId: F.bulkId, amountMinorUnits: -17_139, frequency: .monthly, interval: 1, startDate: date(2026, 1, 14), endDate: nil, isEnabled: true, status: .manual, note: nil)]
        XCTAssertNil(DashboardCalculator.attentionItems(F.input(today: today, entries: withBulk, catchAllId: F.bulkId)).catchAllIssue)
    }

    func testCatchAllAllowanceIsThePositiveMonthlyAmount() {
        let withBulk = F.withDining + [ForecastEntry(id: 9, groupId: 1, categoryId: F.bulkId, amountMinorUnits: -17_139, frequency: .monthly, interval: 1, startDate: date(2026, 1, 14), endDate: nil, isEnabled: true, status: .manual, note: nil)]
        let allowance = DashboardCalculator.catchAllAllowance(F.input(today: date(2026, 10, 2), entries: withBulk, catchAllId: F.bulkId))
        XCTAssertEqual(allowance, CatchAllAllowance(name: "Bulk other", monthlyMinorUnits: 17_139))
        XCTAssertNil(DashboardCalculator.catchAllAllowance(F.input(today: date(2026, 10, 2))))
    }

    // MARK: accounts

    func testAccountSummariesAreSortedLargestFirstWithGBPConversion() {
        let accounts = [
            Account(id: 1, name: "Current", currency: .gbp, kind: .cash, trackingMode: .manual),
            Account(id: 2, name: "Card", currency: .gbp, kind: .credit, trackingMode: .manual),
            Account(id: 3, name: "EUR", currency: .eur, kind: .cash, trackingMode: .manual)
        ]
        let snapshots = [F.snapshot(1, date(2026, 1, 1), 500_000), F.snapshot(2, date(2026, 1, 1), -200_000), F.snapshot(3, date(2026, 1, 1), 1_000_000)]
        let summaries = DashboardCalculator.accountSummaries(F.input(today: date(2026, 10, 2), accounts: accounts, snapshots: snapshots))
        XCTAssertEqual(summaries.map(\.name), ["EUR", "Current", "Card"])
        XCTAssertEqual(summaries.map(\.gbpBalanceMinorUnits), [500_000, 500_000, -200_000]) // 1_000_000 EUR × 0.5
        XCTAssertEqual(summaries[0].nativeBalanceMinorUnits, 1_000_000)
    }

    // MARK: upcoming bills

    func testUpcomingBillsWindowIncludesTodayAndDay30AndOnlyConfirmedExpenses() {
        let hypothetical = ForecastEntry(id: 7, groupId: 1, categoryId: F.groceriesId, amountMinorUnits: -9_999, frequency: .monthly, interval: 1, startDate: date(2026, 10, 10), endDate: nil, isEnabled: true, status: .hypothetical, note: nil)
        let ended = ForecastEntry(id: 8, groupId: 1, categoryId: F.groceriesId, amountMinorUnits: -5_000, frequency: .monthly, interval: 1, startDate: date(2026, 1, 3), endDate: date(2026, 9, 30), isEnabled: true, status: .manual, note: nil)
        let disabled = ForecastEntry(id: 9, groupId: 1, categoryId: F.groceriesId, amountMinorUnits: -1_000, frequency: .monthly, interval: 1, startDate: date(2026, 1, 5), endDate: nil, isEnabled: false, status: .manual, note: nil)
        let input = F.input(today: date(2026, 10, 2), entries: F.withDining + [hypothetical, ended, disabled])
        let bills = DashboardCalculator.upcomingBills(input, days: 30)
        // Rent falls on 1 Nov (day 30 → included); dining on 14 Oct; salary (income), the
        // hypothetical, ended and disabled entries are all excluded.
        XCTAssertEqual(bills.map(\.categoryName), ["Dining", "Rent"])
        XCTAssertEqual(bills.map(\.date), [date(2026, 10, 14), date(2026, 11, 1)])
        XCTAssertEqual(bills.map(\.amountMinorUnits), [-40_000, -100_000])
    }

    func testUpcomingBillsIncludeTodayAndExcludeDay31() {
        let bills = DashboardCalculator.upcomingBills(F.input(today: date(2026, 10, 1)), days: 30)
        // Rent on 1 Oct (today) is in; rent on 1 Nov is day 31 → out.
        XCTAssertEqual(bills.map(\.date), [date(2026, 10, 1), date(2026, 10, 14)])
    }
}
```

- [ ] **Step 2: Run to verify it fails** — `swift test --filter DashboardCalculatorTests` → "cannot find 'DashboardInput' in scope".

- [ ] **Step 3: Implement**

```swift
// Sources/BudgetCore/Dashboard/DashboardInput.swift
import Foundation

/// Everything the dashboard needs, loaded once. `today` is part of the input so tests never
/// depend on the clock.
public struct DashboardInput {
    public let today: Date
    public let accounts: [Account]
    public let snapshots: [BalanceSnapshot]
    public let transactions: [Transaction]
    public let categories: [Category]
    public let categoryGroups: [CategoryGroup]
    public let forecastEntries: [ForecastEntry]
    public let forecastGroups: [ForecastGroup]
    public let importBatches: [ImportBatch]
    public let rate: ExchangeRateSetting
    /// Latest transaction date across all accounts ("D"); nil when there are no transactions.
    public let dataThrough: Date?
    /// Confirmed calendar-month totals per category, built once.
    let calendarTotals: [Int64: [Int: [Int: Int]]]

    public init(today: Date, accounts: [Account], snapshots: [BalanceSnapshot], transactions: [Transaction], categories: [Category], categoryGroups: [CategoryGroup], forecastEntries: [ForecastEntry], forecastGroups: [ForecastGroup], importBatches: [ImportBatch], rate: ExchangeRateSetting) {
        self.today = today
        self.accounts = accounts
        self.snapshots = snapshots
        self.transactions = transactions
        self.categories = categories
        self.categoryGroups = categoryGroups
        self.forecastEntries = forecastEntries
        self.forecastGroups = forecastGroups
        self.importBatches = importBatches
        self.rate = rate
        self.dataThrough = transactions.map(\.date).max()
        self.calendarTotals = BudgetGridCalculator.calendarTotalsLookup(transactions: transactions)
    }

    /// `today`, but never earlier than the data (a clock behind the data counts as "today = D").
    var effectiveToday: Date { dataThrough.map { max(today, $0) } ?? today }
}

public struct DataFreshness: Equatable {
    public enum Status: Equatable {
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

public enum CatchAllIssue: Equatable {
    case notDesignated
    case noAllowance
}

public struct AttentionItems: Equatable {
    public let uncategorizedCount: Int
    public let staleBalanceCount: Int
    public let oldestStaleSnapshotDate: Date?
    public let catchAllIssue: CatchAllIssue?
}

public struct AccountSummary: Equatable, Identifiable {
    public let id: Int64
    public let name: String
    public let kind: AccountKind
    public let currency: Currency
    public let nativeBalanceMinorUnits: Int
    public let gbpBalanceMinorUnits: Int
}

public struct UpcomingBill: Equatable, Identifiable {
    public let date: Date
    public let categoryName: String
    /// Signed (negative = money out), per occurrence.
    public let amountMinorUnits: Int
    public var id: String { "\(categoryName)-\(date.timeIntervalSince1970)-\(amountMinorUnits)" }
}

public struct CatchAllAllowance: Equatable {
    public let name: String
    /// Positive magnitude of the confirmed monthly allowance (0 when none).
    public let monthlyMinorUnits: Int
}
```

```swift
// Sources/BudgetCore/Dashboard/DashboardCalculator.swift
import Foundation

public enum DashboardCalculator {
    static var calendar: Calendar { MonthRange.calendar }

    // MARK: Data freshness

    public static func dataFreshness(_ input: DashboardInput) -> DataFreshness {
        let lastBatch = input.importBatches.max { $0.importedAt < $1.importedAt }
        guard let dataThrough = input.dataThrough else {
            return DataFreshness(status: .noData, lastImportAt: lastBatch?.importedAt, lastImportFileName: lastBatch?.sourceFileName, dataThrough: nil)
        }
        let threshold = calendar.date(byAdding: .day, value: -31, to: input.today)!
        let status: DataFreshness.Status
        if dataThrough < threshold {
            let months = calendar.dateComponents([.month], from: dataThrough, to: input.today).month ?? 0
            let days = calendar.dateComponents([.day], from: dataThrough, to: input.today).day ?? 0
            status = .behind(months: months, days: days)
        } else {
            status = .upToDate
        }
        return DataFreshness(status: status, lastImportAt: lastBatch?.importedAt, lastImportFileName: lastBatch?.sourceFileName, dataThrough: dataThrough)
    }

    // MARK: Needs attention

    public static func attentionItems(_ input: DashboardInput) -> AttentionItems {
        let uncategorized = input.transactions.filter { $0.categoryId == nil || $0.status == .pendingReview }.count

        let threshold = calendar.date(byAdding: .day, value: -45, to: input.today)!
        var staleCount = 0
        var oldest: Date?
        for account in input.accounts where account.trackingMode != .imported {
            let latest = input.snapshots.filter { $0.accountId == account.id }.map(\.date).max()
            if let latest {
                if latest < threshold {
                    staleCount += 1
                    oldest = oldest.map { min($0, latest) } ?? latest
                }
            } else {
                staleCount += 1 // never had a balance recorded
            }
        }

        let issue: CatchAllIssue?
        if let catchAll = input.categories.first(where: { $0.isCatchAll }) {
            let hasAllowance = ForecastCalculator.confirmedEntries(entries: input.forecastEntries, groups: input.forecastGroups).contains { $0.categoryId == catchAll.id }
            issue = hasAllowance ? nil : .noAllowance
        } else {
            issue = .notDesignated
        }
        return AttentionItems(uncategorizedCount: uncategorized, staleBalanceCount: staleCount, oldestStaleSnapshotDate: oldest, catchAllIssue: issue)
    }

    public static func catchAllAllowance(_ input: DashboardInput) -> CatchAllAllowance? {
        guard let category = input.categories.first(where: { $0.isCatchAll }), let id = category.id else { return nil }
        let parts = MonthRange.components(of: input.effectiveToday)
        let range = MonthRange.of(year: parts.year, month: parts.month)
        let period = PayPeriod(startDate: range.start, endDate: range.end, type: .projected)
        let monthly = -ForecastCalculator.confirmedTotal(categoryId: id, period: period, entries: input.forecastEntries, groups: input.forecastGroups)
        return CatchAllAllowance(name: category.name, monthlyMinorUnits: monthly)
    }

    // MARK: Accounts

    /// Every account, largest GBP balance first (a credit account owed money sorts last).
    public static func accountSummaries(_ input: DashboardInput) -> [AccountSummary] {
        NetWorthCalculator.accountBalances(accounts: input.accounts, snapshots: input.snapshots, transactions: input.transactions, rate: input.rate)
            .compactMap { balance -> AccountSummary? in
                guard let id = balance.account.id else { return nil }
                return AccountSummary(id: id, name: balance.account.name, kind: balance.account.kind, currency: balance.account.currency, nativeBalanceMinorUnits: balance.nativeBalanceMinorUnits, gbpBalanceMinorUnits: balance.gbpBalanceMinorUnits)
            }
            .sorted { $0.gbpBalanceMinorUnits > $1.gbpBalanceMinorUnits }
    }

    // MARK: Upcoming bills

    /// Confirmed expense entries expanded over [start of today, end of day today + `days`],
    /// sorted by date. The caller shows the first few and "+ N more".
    public static func upcomingBills(_ input: DashboardInput, days: Int = 30) -> [UpcomingBill] {
        let startOfToday = calendar.startOfDay(for: input.today)
        let end = calendar.date(byAdding: .day, value: days + 1, to: startOfToday)!.addingTimeInterval(-1)
        let period = PayPeriod(startDate: startOfToday, endDate: end, type: .projected)
        let expenseCategories = Dictionary(uniqueKeysWithValues: input.categories.compactMap { category -> (Int64, String)? in
            guard category.type == .expense, let id = category.id else { return nil }
            return (id, category.name)
        })
        var bills: [UpcomingBill] = []
        for entry in ForecastCalculator.confirmedEntries(entries: input.forecastEntries, groups: input.forecastGroups) {
            guard let name = expenseCategories[entry.categoryId] else { continue }
            for occurrence in FrequencyExpander.occurrences(for: entry, in: period) {
                bills.append(UpcomingBill(date: occurrence, categoryName: name, amountMinorUnits: entry.amountMinorUnits))
            }
        }
        return bills.sorted { $0.date != $1.date ? $0.date < $1.date : $0.categoryName < $1.categoryName }
    }
}
```

- [ ] **Step 4: Verify** — `swift test --filter DashboardCalculatorTests` → PASS; `swift test` → green.

- [ ] **Step 5: Commit**

```bash
git add Sources/BudgetCore/Dashboard/DashboardInput.swift Sources/BudgetCore/Dashboard/DashboardCalculator.swift Tests/BudgetCoreTests/DashboardFixture.swift Tests/BudgetCoreTests/DashboardCalculatorTests.swift
git commit -m "Add DashboardInput and the freshness, attention, accounts and upcoming-bills calculations

Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
```

---

### Task 8: Net worth series and year-over-year

**Files:**
- Create: `Sources/BudgetCore/Dashboard/DashboardCalculator+NetWorth.swift`
- Test: `Tests/BudgetCoreTests/DashboardNetWorthTests.swift`

**Interfaces:**
- Consumes: `MonthRange`, `NetWorthCalculator.monthEndNetWorth/accountBalances/netWorth` (Task 1), `ForecastProjector` (Task 3), `NetWorthPoint`, `DashboardInput` (Task 7).
- Produces: `NetWorthSeries` (`actual`, `forecast`, `currentNetWorthMinorUnits`, `asOf`, `changeVsPreviousMonthMinorUnits`, `yearEnds: [YearEndForecast]`, `behindBalances: BehindBalances?`, static `empty`); `YearEndForecast(year:valueMinorUnits:changeMinorUnits:percent:)`; `BehindBalances(accountCount:oldestSnapshotDate:)`; `YearChange(year:realisedMinorUnits:forecastMinorUnits:percent:partialFromMonth:)` with `totalMinorUnits`; `DashboardCalculator.netWorthSeries(_:) -> NetWorthSeries`, `.yearOverYear(_:series:) -> [YearChange]`.

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/BudgetCoreTests/DashboardNetWorthTests.swift
import XCTest
@testable import BudgetCore

final class DashboardNetWorthTests: XCTestCase {
    private typealias F = DashboardFixture
    private func date(_ y: Int, _ m: Int, _ d: Int) -> Date { F.date(y, m, d) }

    private var series2026Input: DashboardInput {
        F.input(
            today: date(2026, 4, 15),
            snapshots: [F.snapshot(1, date(2025, 12, 1), 1_000_000), F.snapshot(1, date(2026, 1, 1), 1_100_000), F.snapshot(1, date(2026, 2, 1), 1_200_000)],
            transactions: [F.txn(1, date(2026, 2, 10), -1_000, category: F.rentId)],
            entries: F.salaryAndRent
        )
    }

    func testActualSeriesRunsFromTheFirstSnapshotMonthToTheDataMonth() {
        let series = DashboardCalculator.netWorthSeries(series2026Input)
        XCTAssertEqual(series.actual, [
            NetWorthPoint(year: 2025, month: 12, valueMinorUnits: 1_000_000),
            NetWorthPoint(year: 2026, month: 1, valueMinorUnits: 1_100_000),
            NetWorthPoint(year: 2026, month: 2, valueMinorUnits: 1_200_000)
        ])
        XCTAssertEqual(series.currentNetWorthMinorUnits, 1_200_000)
        XCTAssertEqual(series.changeVsPreviousMonthMinorUnits, 100_000)
        XCTAssertEqual(series.asOf, date(2026, 2, 1))
        XCTAssertNil(series.behindBalances)
    }

    func testForecastStartsAtTheDataMonthAndMatchesTheProjector() {
        let series = DashboardCalculator.netWorthSeries(series2026Input)
        XCTAssertEqual(series.forecast.first, NetWorthPoint(year: 2026, month: 2, valueMinorUnits: 1_200_000))
        XCTAssertEqual(series.forecast.count, 23) // Feb 2026 anchor + Mar 2026 ... Dec 2027
        XCTAssertEqual(series.forecast.last, NetWorthPoint(year: 2027, month: 12, valueMinorUnits: 5_600_000))
    }

    func testYearEndForecastsCompareAgainstTheRightBaseline() {
        let yearEnds = DashboardCalculator.netWorthSeries(series2026Input).yearEnds
        XCTAssertEqual(yearEnds.map(\.year), [2026, 2027])
        // Dec 2026 vs the REAL Dec 2025 (1_000_000); Dec 2027 vs the FORECAST Dec 2026.
        XCTAssertEqual(yearEnds[0].valueMinorUnits, 3_200_000)
        XCTAssertEqual(yearEnds[0].changeMinorUnits, 2_200_000)
        XCTAssertEqual(try XCTUnwrap(yearEnds[0].percent), 2.2, accuracy: 0.0001)
        XCTAssertEqual(yearEnds[1].valueMinorUnits, 5_600_000)
        XCTAssertEqual(yearEnds[1].changeMinorUnits, 2_400_000)
        XCTAssertEqual(try XCTUnwrap(yearEnds[1].percent), 0.75, accuracy: 0.0001)
    }

    // Importing through April while the balance was last recorded in February: the line runs
    // flat and the banner data is populated.
    func testBalancesOlderThanTheDataMonthAreFlagged() {
        let input = F.input(
            today: date(2026, 4, 15),
            snapshots: [F.snapshot(1, date(2026, 2, 1), 1_200_000)],
            transactions: [F.txn(1, date(2026, 4, 10), -1_000, category: F.rentId)],
            entries: F.salaryAndRent
        )
        let series = DashboardCalculator.netWorthSeries(input)
        XCTAssertEqual(series.actual.map(\.valueMinorUnits), [1_200_000, 1_200_000, 1_200_000]) // Feb, Mar, Apr
        XCTAssertEqual(series.behindBalances, BehindBalances(accountCount: 1, oldestSnapshotDate: date(2026, 2, 1)))
    }

    func testImportedAccountsAreNeverBehind() {
        let imported = Account(id: 1, name: "Imported", currency: .gbp, kind: .cash, trackingMode: .imported)
        let input = F.input(
            today: date(2026, 4, 15), accounts: [imported],
            snapshots: [F.snapshot(1, date(2026, 2, 1), 1_200_000)],
            transactions: [F.txn(1, date(2026, 4, 10), -1_000, category: F.rentId)]
        )
        XCTAssertNil(DashboardCalculator.netWorthSeries(input).behindBalances)
    }

    func testNoSnapshotsGivesAnEmptySeries() {
        let series = DashboardCalculator.netWorthSeries(F.input(today: date(2026, 4, 15)))
        XCTAssertEqual(series, NetWorthSeries.empty)
        XCTAssertTrue(series.actual.isEmpty)
        XCTAssertNil(series.currentNetWorthMinorUnits)
    }

    // MARK: year over year

    private var yoyInput: DashboardInput {
        F.input(
            today: date(2026, 10, 2),
            snapshots: [
                F.snapshot(1, date(2024, 1, 1), 1_000_000), F.snapshot(1, date(2024, 12, 1), 2_200_000),
                F.snapshot(1, date(2025, 12, 1), 3_000_000), F.snapshot(1, date(2026, 2, 1), 3_300_000)
            ],
            transactions: [F.txn(1, date(2026, 2, 14), -1_000, category: F.rentId)],
            entries: F.salaryAndRent
        )
    }

    func testYearOverYearSplitsRealisedAndForecastParts() {
        let input = yoyInput
        let changes = DashboardCalculator.yearOverYear(input, series: DashboardCalculator.netWorthSeries(input))
        XCTAssertEqual(changes.map(\.year), [2024, 2025, 2026, 2027])

        // First year: measured from the first available month (Jan 2024) to Dec 2024.
        XCTAssertEqual(changes[0].realisedMinorUnits, 1_200_000)
        XCTAssertEqual(changes[0].forecastMinorUnits, 0)
        XCTAssertEqual(changes[0].partialFromMonth, 1)
        XCTAssertEqual(try XCTUnwrap(changes[0].percent), 1.2, accuracy: 0.0001)

        // Completed year: Dec to Dec.
        XCTAssertEqual(changes[1].realisedMinorUnits, 800_000)
        XCTAssertNil(changes[1].partialFromMonth)
        XCTAssertEqual(try XCTUnwrap(changes[1].percent), 800.0 / 2200.0, accuracy: 0.0001)

        // Current year: realised = latest actual (Feb 2026: 3_300_000) - Dec 2025 (3_000_000); the rest is forecast.
        XCTAssertEqual(changes[2].realisedMinorUnits, 300_000)
        XCTAssertEqual(changes[2].forecastMinorUnits, 2_000_000)
        XCTAssertEqual(changes[2].totalMinorUnits, 2_300_000)

        // Next year: entirely forecast (Dec 2027 7_700_000 - Dec 2026 5_300_000).
        XCTAssertEqual(changes[3].realisedMinorUnits, 0)
        XCTAssertEqual(changes[3].forecastMinorUnits, 2_400_000)
    }

    // The 2026 bar must equal the year-end headline on the net worth card.
    func testYearOverYearAgreesWithTheYearEndForecast() {
        let input = yoyInput
        let series = DashboardCalculator.netWorthSeries(input)
        let changes = DashboardCalculator.yearOverYear(input, series: series)
        XCTAssertEqual(changes[2].totalMinorUnits, try XCTUnwrap(series.yearEnds.first { $0.year == 2026 }).changeMinorUnits)
        XCTAssertEqual(changes[3].totalMinorUnits, try XCTUnwrap(series.yearEnds.first { $0.year == 2027 }).changeMinorUnits)
    }

    func testNegativeYearsKeepTheirSign() {
        let input = F.input(
            today: date(2025, 12, 20),
            snapshots: [F.snapshot(1, date(2024, 1, 1), 1_000_000), F.snapshot(1, date(2024, 12, 1), 800_000), F.snapshot(1, date(2025, 12, 1), 700_000)],
            transactions: [F.txn(1, date(2025, 12, 15), -1_000, category: F.rentId)],
            entries: F.salaryAndRent
        )
        let changes = DashboardCalculator.yearOverYear(input, series: DashboardCalculator.netWorthSeries(input))
        XCTAssertEqual(changes[0].realisedMinorUnits, -200_000) // 2024: Jan → Dec
        XCTAssertEqual(changes[1].realisedMinorUnits, -100_000) // 2025: Dec → Dec
    }

    func testYearOverYearIsEmptyWithoutHistory() {
        let input = F.input(today: date(2026, 4, 15))
        XCTAssertTrue(DashboardCalculator.yearOverYear(input, series: DashboardCalculator.netWorthSeries(input)).isEmpty)
    }
}
```

- [ ] **Step 2: Run to verify it fails** — `swift test --filter DashboardNetWorthTests` → "no member 'netWorthSeries'".

- [ ] **Step 3: Implement**

```swift
// Sources/BudgetCore/Dashboard/DashboardCalculator+NetWorth.swift
import Foundation

public struct YearEndForecast: Equatable {
    public let year: Int
    public let valueMinorUnits: Int
    public let changeMinorUnits: Int
    public let percent: Double?
}

public struct BehindBalances: Equatable {
    /// Non-imported accounts whose latest snapshot is older than the data-through month.
    public let accountCount: Int
    public let oldestSnapshotDate: Date
}

public struct NetWorthSeries: Equatable {
    /// Month values from the first snapshot month through the data-through month.
    public let actual: [NetWorthPoint]
    /// Starts at the data-through month (anchored at the current net worth) and runs to
    /// December of next year — the same walk the Forecast screen's headlines use.
    public let forecast: [NetWorthPoint]
    public let currentNetWorthMinorUnits: Int?
    public let asOf: Date?
    public let changeVsPreviousMonthMinorUnits: Int?
    /// This year and next year, matching the Forecast screen's headline figures.
    public let yearEnds: [YearEndForecast]
    public let behindBalances: BehindBalances?

    public static let empty = NetWorthSeries(actual: [], forecast: [], currentNetWorthMinorUnits: nil, asOf: nil, changeVsPreviousMonthMinorUnits: nil, yearEnds: [], behindBalances: nil)
}

/// One bar of the year-over-year chart. Completed years are all `realised`; the current
/// year splits at the latest actual month; future years are all `forecast`.
public struct YearChange: Equatable, Identifiable {
    public let year: Int
    public let realisedMinorUnits: Int
    public let forecastMinorUnits: Int
    /// Total change as a fraction of the baseline's magnitude; nil when the baseline is 0.
    public let percent: Double?
    /// Set (to the baseline month) for the first data year, whose baseline is its first
    /// available month rather than the previous December.
    public let partialFromMonth: Int?
    public var id: Int { year }
    public var totalMinorUnits: Int { realisedMinorUnits + forecastMinorUnits }
}

extension DashboardCalculator {
    public static func netWorthSeries(_ input: DashboardInput) -> NetWorthSeries {
        guard let firstSnapshot = input.snapshots.map(\.date).min(), let lastSnapshot = input.snapshots.map(\.date).max() else {
            return .empty
        }
        let balances = NetWorthCalculator.accountBalances(accounts: input.accounts, snapshots: input.snapshots, transactions: input.transactions, rate: input.rate)
        let current = NetWorthCalculator.netWorth(balances: balances)

        let dataMonth = input.dataThrough.map { MonthRange.components(of: $0) }
        let lastActualMonth = dataMonth ?? MonthRange.components(of: lastSnapshot)

        // Actual: one point per month, snapshots carried forward (the same formula as the Budget grid).
        var actual: [NetWorthPoint] = []
        var cursor = MonthRange.components(of: firstSnapshot)
        let lastActualIndex = MonthRange.index(year: lastActualMonth.year, month: lastActualMonth.month)
        while MonthRange.index(year: cursor.year, month: cursor.month) <= lastActualIndex {
            if let value = monthEndNetWorth(input, year: cursor.year, month: cursor.month) {
                actual.append(NetWorthPoint(year: cursor.year, month: cursor.month, valueMinorUnits: value))
            }
            cursor = (cursor.month == 12) ? (cursor.year + 1, 1) : (cursor.year, cursor.month + 1)
        }

        // Forecast: anchored at the current net worth in the data month, then the shared month walk.
        let thisYear = MonthRange.components(of: input.today).year
        var forecast: [NetWorthPoint] = []
        var yearEnds: [YearEndForecast] = []
        if let dataMonth {
            let projection = ForecastProjector.monthlyProjection(startingNetWorth: current, latestRealMonth: dataMonth, throughYear: thisYear + 1, categories: input.categories, entries: input.forecastEntries, groups: input.forecastGroups)
            forecast = [NetWorthPoint(year: dataMonth.year, month: dataMonth.month, valueMinorUnits: current)] + projection

            let dataIndex = MonthRange.index(year: dataMonth.year, month: dataMonth.month)
            func forecastValue(atEndOf year: Int) -> Int {
                ForecastProjector.forecastNetWorth(startingNetWorth: current, latestRealMonth: dataMonth, atEndOf: year, categories: input.categories, entries: input.forecastEntries, groups: input.forecastGroups)
            }
            for year in [thisYear, thisYear + 1] {
                let value = forecastValue(atEndOf: year)
                // Baseline rule mirrors ForecastViewModel.forecastNetWorthYoY: last December's
                // REAL net worth when real data reaches it, else last December's forecast.
                let baseline: Int
                if MonthRange.index(year: year - 1, month: 12) <= dataIndex {
                    baseline = monthEndNetWorth(input, year: year - 1, month: 12) ?? 0
                } else {
                    baseline = forecastValue(atEndOf: year - 1)
                }
                let change = value - baseline
                yearEnds.append(YearEndForecast(year: year, valueMinorUnits: value, changeMinorUnits: change, percent: baseline != 0 ? Double(change) / Double(abs(baseline)) : nil))
            }
        }

        // "As of": the latest of the last snapshot and the latest transaction of imported accounts.
        let importedIds = Set(input.accounts.filter { $0.trackingMode == .imported }.compactMap(\.id))
        let importedLatest = input.transactions.filter { importedIds.contains($0.accountId) }.map(\.date).max()
        let asOf = [lastSnapshot, importedLatest].compactMap { $0 }.max()

        let changeVsPrevious: Int? = actual.count >= 2 ? actual[actual.count - 1].valueMinorUnits - actual[actual.count - 2].valueMinorUnits : nil

        // Behind: a non-imported account whose latest snapshot predates the data month.
        var behindDates: [Date] = []
        if let dataMonth {
            let dataIndex = MonthRange.index(year: dataMonth.year, month: dataMonth.month)
            for account in input.accounts where account.trackingMode != .imported {
                guard let latest = input.snapshots.filter({ $0.accountId == account.id }).map(\.date).max() else { continue }
                let parts = MonthRange.components(of: latest)
                if MonthRange.index(year: parts.year, month: parts.month) < dataIndex { behindDates.append(latest) }
            }
        }
        let behind = behindDates.min().map { BehindBalances(accountCount: behindDates.count, oldestSnapshotDate: $0) }

        return NetWorthSeries(actual: actual, forecast: forecast, currentNetWorthMinorUnits: current, asOf: asOf, changeVsPreviousMonthMinorUnits: changeVsPrevious, yearEnds: yearEnds, behindBalances: behind)
    }

    /// One entry per year from the first data year to next year. See `YearChange`.
    public static func yearOverYear(_ input: DashboardInput, series: NetWorthSeries) -> [YearChange] {
        guard let firstActual = series.actual.first, let lastActual = series.actual.last else { return [] }
        var valueByIndex: [Int: Int] = [:]
        for point in series.forecast { valueByIndex[point.id] = point.valueMinorUnits }
        for point in series.actual { valueByIndex[point.id] = point.valueMinorUnits } // actual wins at the junction

        let lastActualIndex = lastActual.id
        let firstYear = firstActual.year
        let lastYear = MonthRange.components(of: input.today).year + 1
        guard firstYear <= lastYear else { return [] }

        var result: [YearChange] = []
        for year in firstYear...lastYear {
            let decemberIndex = MonthRange.index(year: year, month: 12)
            guard let december = valueByIndex[decemberIndex] else { continue }
            let isFirstYear = year == firstYear
            let baselineIndex = isFirstYear ? firstActual.id : MonthRange.index(year: year - 1, month: 12)
            guard let baseline = valueByIndex[baselineIndex] else { continue }
            let total = december - baseline

            let realised: Int
            if decemberIndex <= lastActualIndex {
                realised = total
            } else if baselineIndex <= lastActualIndex {
                realised = lastActual.valueMinorUnits - baseline
            } else {
                realised = 0
            }
            result.append(YearChange(
                year: year, realisedMinorUnits: realised, forecastMinorUnits: total - realised,
                percent: baseline != 0 ? Double(total) / Double(abs(baseline)) : nil,
                partialFromMonth: isFirstYear ? firstActual.month : nil
            ))
        }
        return result
    }

    private static func monthEndNetWorth(_ input: DashboardInput, year: Int, month: Int) -> Int? {
        NetWorthCalculator.monthEndNetWorth(accounts: input.accounts, snapshots: input.snapshots, transactions: input.transactions, rate: input.rate, year: year, month: month)
    }
}
```

- [ ] **Step 4: Verify** — `swift test --filter DashboardNetWorthTests` → PASS; `swift test` → green.

- [ ] **Step 5: Commit**

```bash
git add Sources/BudgetCore/Dashboard/DashboardCalculator+NetWorth.swift Tests/BudgetCoreTests/DashboardNetWorthTests.swift
git commit -m "Add the dashboard net worth series and year-over-year calculations

Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
```

---

### Task 9: Current month, monthly flows, year totals, top categories

**Files:**
- Create: `Sources/BudgetCore/Dashboard/DashboardCalculator+Flows.swift`
- Test: `Tests/BudgetCoreTests/DashboardFlowTests.swift`

**Interfaces:**
- Consumes: `MonthBlend` (Task 6), `DashboardInput` (Task 7), `ForecastCalculator.confirmedTotal`, `MonthRange`.
- Produces: `FlowTotals(actual:expected:projected:)`; `CurrentMonthTracking` (`year`, `month`, `dayOfMonth`, `daysInMonth`, `monthClass`, `income`, `expenses`, `unreviewedCount`, `unreviewedOutflowMinorUnits`, computed `net: FlowTotals`); `MonthlyFlow` (`year`, `month`, `monthClass`, `incomeActual`, `incomeRemaining`, `expenseActual`, `expenseRemaining` + computed `incomeTotal`, `expenseTotal`, `net`, `netActual`); `YearTotals`; `CategorySpend` (`name`, `actual`, `expected`, `projected`, `isOver`, `isUnplanned`); `DashboardCalculator.currentMonth(_:)`, `.monthlyFlows(_:year:)`, `.yearTotals(_:)`, `.topCategories(_:limit:)`. All money values are positive magnitudes except `net`.

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/BudgetCoreTests/DashboardFlowTests.swift
import XCTest
@testable import BudgetCore

final class DashboardFlowTests: XCTestCase {
    private typealias F = DashboardFixture
    private func date(_ y: Int, _ m: Int, _ d: Int) -> Date { F.date(y, m, d) }

    /// Mid-October, data through 13 Oct: rent paid (matches its expectation), groceries
    /// unplanned, dining over its expectation, salary not yet in; two unreviewed outflows.
    private var blendedInput: DashboardInput {
        F.input(today: date(2026, 10, 14), transactions: [
            F.txn(1, date(2026, 1, 1), -100_000, category: F.rentId),
            F.txn(2, date(2026, 1, 25), 300_000, category: F.salaryId),
            F.txn(3, date(2026, 10, 1), -100_000, category: F.rentId),
            F.txn(4, date(2026, 10, 5), -25_000, category: F.groceriesId),
            F.txn(5, date(2026, 10, 13), -55_000, category: F.diningId),
            F.txn(6, date(2026, 10, 5), -3_000, category: nil, status: .pendingReview),
            F.txn(7, date(2026, 10, 6), -2_000, category: F.groceriesId, status: .pendingReview)
        ])
    }

    // MARK: current month

    func testBlendedCurrentMonthUsesTheLargerOfActualAndExpectedPerCategory() {
        let month = DashboardCalculator.currentMonth(blendedInput)
        XCTAssertEqual(month.monthClass, .blended)
        XCTAssertEqual(month.dayOfMonth, 14)
        XCTAssertEqual(month.daysInMonth, 31)
        XCTAssertEqual(month.income, FlowTotals(actual: 0, expected: 300_000, projected: 300_000))
        // Rent 100k (=expected), groceries 25k unplanned, dining 55k over its 40k expectation.
        XCTAssertEqual(month.expenses, FlowTotals(actual: 180_000, expected: 140_000, projected: 180_000))
        XCTAssertEqual(month.net, FlowTotals(actual: -180_000, expected: 160_000, projected: 120_000))
    }

    func testUnreviewedTransactionsAreCountedButNotInTheTotals() {
        let month = DashboardCalculator.currentMonth(blendedInput)
        XCTAssertEqual(month.unreviewedCount, 2)
        XCTAssertEqual(month.unreviewedOutflowMinorUnits, 5_000)
    }

    // The Forecast grid hides expected amounts once a month has transactions; the dashboard
    // must keep reading them from the forecast.
    func testExpectedStillComesFromTheForecastWhenTheMonthHasTransactions() {
        XCTAssertEqual(DashboardCalculator.currentMonth(blendedInput).expenses.expected, 140_000)
    }

    func testCurrentMonthWithNothingImportedYetIsForecastOnly() {
        let input = F.input(today: date(2026, 10, 2), transactions: [F.txn(1, date(2026, 2, 14), -55_000, category: F.diningId)])
        let month = DashboardCalculator.currentMonth(input)
        XCTAssertEqual(month.monthClass, .forecast)
        XCTAssertEqual(month.income, FlowTotals(actual: 0, expected: 300_000, projected: 300_000))
        XCTAssertEqual(month.expenses, FlowTotals(actual: 0, expected: 140_000, projected: 140_000))
    }

    func testBulkAllowanceCountsInFullEvenWithNoActuals() {
        let withBulk = F.withDining + [ForecastEntry(id: 9, groupId: 1, categoryId: F.bulkId, amountMinorUnits: -17_139, frequency: .monthly, interval: 1, startDate: date(2026, 1, 14), endDate: nil, isEnabled: true, status: .manual, note: nil)]
        let input = F.input(today: date(2026, 10, 14), transactions: [F.txn(1, date(2026, 10, 13), -55_000, category: F.diningId)], entries: withBulk, catchAllId: F.bulkId)
        // Expected 100k rent + 40k dining + 17,139 bulk; actual only dining (55k) → projected 100k + 55k + 17,139.
        XCTAssertEqual(DashboardCalculator.currentMonth(input).expenses.projected, 172_139)
    }

    // MARK: monthly flows

    func testMonthlyFlowsClassifyEachMonthOfTheYear() {
        let flows = DashboardCalculator.monthlyFlows(blendedInput, year: 2026)
        XCTAssertEqual(flows.count, 12)
        XCTAssertEqual(flows.prefix(9).map(\.monthClass), Array(repeating: .actual, count: 9))
        XCTAssertEqual(flows[9].monthClass, .blended)
        XCTAssertEqual(flows[10].monthClass, .forecast)
        XCTAssertEqual(flows[11].monthClass, .forecast)
    }

    func testActualBlendedAndForecastMonthShapes() {
        let flows = DashboardCalculator.monthlyFlows(blendedInput, year: 2026)
        // January: actual only.
        XCTAssertEqual([flows[0].incomeActual, flows[0].incomeRemaining, flows[0].expenseActual, flows[0].expenseRemaining], [300_000, 0, 100_000, 0])
        // October: salary still to come (remaining 300k); expenses already at their projection.
        XCTAssertEqual([flows[9].incomeActual, flows[9].incomeRemaining, flows[9].expenseActual, flows[9].expenseRemaining], [0, 300_000, 180_000, 0])
        // November: forecast only.
        XCTAssertEqual([flows[10].incomeActual, flows[10].incomeRemaining, flows[10].expenseActual, flows[10].expenseRemaining], [0, 300_000, 0, 140_000])
        XCTAssertEqual(flows[10].net, 160_000)
    }

    func testPastYearsAreAllActual() {
        let flows = DashboardCalculator.monthlyFlows(blendedInput, year: 2025)
        XCTAssertTrue(flows.allSatisfy { $0.monthClass == .actual })
        XCTAssertTrue(flows.allSatisfy { $0.incomeRemaining == 0 && $0.expenseRemaining == 0 })
    }

    func testNextYearIsAllForecast() {
        let flows = DashboardCalculator.monthlyFlows(blendedInput, year: 2027)
        XCTAssertTrue(flows.allSatisfy { $0.monthClass == .forecast })
        XCTAssertEqual(flows[0].incomeRemaining, 300_000)
    }

    func testYearTotalsSeparateProjectedFromActualToDate() {
        let totals = DashboardCalculator.yearTotals(DashboardCalculator.monthlyFlows(blendedInput, year: 2026))
        XCTAssertEqual(totals.incomeProjected, 1_200_000) // Jan 300k + Oct 300k + Nov 300k + Dec 300k
        XCTAssertEqual(totals.incomeActual, 300_000)
        XCTAssertEqual(totals.expenseProjected, 560_000) // 100k + 180k + 140k + 140k
        XCTAssertEqual(totals.expenseActual, 280_000) // 100k + 180k
        XCTAssertEqual(totals.netProjected, 640_000)
        XCTAssertEqual(totals.netActual, 20_000)
    }

    // MARK: top categories

    func testTopCategoriesRollUpByGroupAndFlagOverspend() {
        let top = DashboardCalculator.topCategories(blendedInput, limit: 5)
        XCTAssertEqual(top.map(\.name), ["Rent", "Food"])
        XCTAssertEqual(top[0].actual, 100_000)
        XCTAssertFalse(top[0].isOver)
        // Food = groceries (25k, unplanned) + dining (55k vs 40k expected).
        XCTAssertEqual(top[1].actual, 80_000)
        XCTAssertEqual(top[1].expected, 40_000)
        XCTAssertEqual(top[1].projected, 80_000)
        XCTAssertTrue(top[1].isOver)
    }

    func testTopCategoriesAreExpectedOnlyBeforeAnyActualsAndRespectTheLimit() {
        let input = F.input(today: date(2026, 10, 2), transactions: [F.txn(1, date(2026, 2, 14), -55_000, category: F.diningId)])
        let top = DashboardCalculator.topCategories(input, limit: 1)
        XCTAssertEqual(top.map(\.name), ["Rent"])
        XCTAssertEqual(top[0].actual, 0)
        XCTAssertEqual(top[0].projected, 100_000)
    }

    func testAnUnplannedCategoryIsFlagged() {
        let input = F.input(today: date(2026, 10, 14), transactions: [F.txn(1, date(2026, 10, 13), -25_000, category: F.bulkId)])
        let unplanned = DashboardCalculator.topCategories(input, limit: 5).first { $0.name == "Bulk other" }
        XCTAssertEqual(unplanned?.isUnplanned, true)
    }
}
```

- [ ] **Step 2: Run to verify it fails** — `swift test --filter DashboardFlowTests` → "no member 'currentMonth'".

- [ ] **Step 3: Implement**

```swift
// Sources/BudgetCore/Dashboard/DashboardCalculator+Flows.swift
import Foundation

/// Magnitudes (income and expenses are both positive).
public struct FlowTotals: Equatable {
    public var actual: Int
    public var expected: Int
    public var projected: Int

    public init(actual: Int, expected: Int, projected: Int) {
        self.actual = actual
        self.expected = expected
        self.projected = projected
    }
}

public struct CurrentMonthTracking: Equatable {
    public let year: Int
    public let month: Int
    public let dayOfMonth: Int
    public let daysInMonth: Int
    public let monthClass: MonthClass
    public let income: FlowTotals
    public let expenses: FlowTotals
    /// Transactions dated this month with no category or still pending review — not in the
    /// totals (like the Budget grid), shown as a footnote.
    public let unreviewedCount: Int
    public let unreviewedOutflowMinorUnits: Int

    /// Signed: income minus expenses, for each of actual / expected / projected.
    public var net: FlowTotals {
        FlowTotals(actual: income.actual - expenses.actual, expected: income.expected - expenses.expected, projected: income.projected - expenses.projected)
    }
}

/// One month of the year-at-a-glance chart. `*Remaining` is the part of the month's
/// projection that hasn't happened yet (hatched in the chart); it is 0 for actual months
/// and equals the whole forecast for forecast months. All values are positive magnitudes.
public struct MonthlyFlow: Equatable, Identifiable {
    public let year: Int
    public let month: Int
    public let monthClass: MonthClass
    public let incomeActual: Int
    public let incomeRemaining: Int
    public let expenseActual: Int
    public let expenseRemaining: Int

    public var id: Int { month }
    public var incomeTotal: Int { incomeActual + incomeRemaining }
    public var expenseTotal: Int { expenseActual + expenseRemaining }
    public var net: Int { incomeTotal - expenseTotal }
    public var netActual: Int { incomeActual - expenseActual }
}

public struct YearTotals: Equatable {
    public let incomeProjected: Int
    public let incomeActual: Int
    public let expenseProjected: Int
    public let expenseActual: Int
    public var netProjected: Int { incomeProjected - expenseProjected }
    public var netActual: Int { incomeActual - expenseActual }
    /// True when part of the year is still forecast (so "of which actual" is worth showing).
    public var hasForecast: Bool { incomeProjected != incomeActual || expenseProjected != expenseActual }
}

public struct CategorySpend: Equatable, Identifiable {
    public let name: String
    public let actual: Int
    public let expected: Int
    public let projected: Int
    public var id: String { name }
    public var isOver: Bool { expected > 0 && actual > expected }
    public var isUnplanned: Bool { expected == 0 && actual > 0 }
}

extension DashboardCalculator {
    // MARK: Shared per-month computation

    private struct MonthTotals {
        var income = FlowTotals(actual: 0, expected: 0, projected: 0)
        var expenses = FlowTotals(actual: 0, expected: 0, projected: 0)
    }

    /// Per non-transfer category: actual (confirmed transactions), expected (confirmed
    /// forecast for the whole calendar month — independent of whether the month "is actual"),
    /// and the projected value under `MonthBlend`. Expected is skipped for actual months
    /// unless `includeExpected` (the current-month card always wants it).
    private static func categoryAmounts(_ input: DashboardInput, year: Int, month: Int, monthClass: MonthClass, includeExpected: Bool, visit: (Category, _ actual: Int, _ expected: Int, _ projected: Int) -> Void) {
        let range = MonthRange.of(year: year, month: month)
        let period = PayPeriod(startDate: range.start, endDate: range.end, type: .projected)
        for category in input.categories {
            guard let categoryId = category.id, category.type != .transfer else { continue }
            let actual = monthClass == .forecast ? 0 : (input.calendarTotals[categoryId]?[year]?[month] ?? 0)
            let expected = (monthClass != .actual || includeExpected)
                ? ForecastCalculator.confirmedTotal(categoryId: categoryId, period: period, entries: input.forecastEntries, groups: input.forecastGroups)
                : 0
            let projected = MonthBlend.projectedTotal(actual: actual, expected: expected, categoryType: category.type, monthClass: monthClass)
            visit(category, actual, expected, projected)
        }
    }

    private static func monthTotals(_ input: DashboardInput, year: Int, month: Int, monthClass: MonthClass, includeExpected: Bool) -> MonthTotals {
        var totals = MonthTotals()
        categoryAmounts(input, year: year, month: month, monthClass: monthClass, includeExpected: includeExpected) { category, actual, expected, projected in
            switch category.type {
            case .income:
                totals.income.actual += actual; totals.income.expected += expected; totals.income.projected += projected
            case .expense:
                // Signed outflows → positive magnitudes.
                totals.expenses.actual -= actual; totals.expenses.expected -= expected; totals.expenses.projected -= projected
            case .transfer:
                break
            }
        }
        return totals
    }

    // MARK: Current month

    public static func currentMonth(_ input: DashboardInput) -> CurrentMonthTracking {
        let today = input.effectiveToday
        let parts = MonthRange.components(of: today)
        let monthClass = MonthBlend.classify(year: parts.year, month: parts.month, dataThrough: input.dataThrough, today: input.today)
        let totals = monthTotals(input, year: parts.year, month: parts.month, monthClass: monthClass, includeExpected: true)

        let range = MonthRange.of(year: parts.year, month: parts.month)
        let unreviewed = input.transactions.filter { $0.date >= range.start && $0.date <= range.end && ($0.categoryId == nil || $0.status == .pendingReview) }
        let outflow = -unreviewed.map(\.amountMinorUnits).filter { $0 < 0 }.reduce(0, +)

        return CurrentMonthTracking(
            year: parts.year, month: parts.month,
            dayOfMonth: calendar.component(.day, from: today),
            daysInMonth: calendar.range(of: .day, in: .month, for: today)!.count,
            monthClass: monthClass, income: totals.income, expenses: totals.expenses,
            unreviewedCount: unreviewed.count, unreviewedOutflowMinorUnits: outflow
        )
    }

    // MARK: Year at a glance

    public static func monthlyFlows(_ input: DashboardInput, year: Int) -> [MonthlyFlow] {
        (1...12).map { month in
            let monthClass = MonthBlend.classify(year: year, month: month, dataThrough: input.dataThrough, today: input.today)
            let totals = monthTotals(input, year: year, month: month, monthClass: monthClass, includeExpected: false)
            return MonthlyFlow(
                year: year, month: month, monthClass: monthClass,
                incomeActual: totals.income.actual, incomeRemaining: max(totals.income.projected - totals.income.actual, 0),
                expenseActual: totals.expenses.actual, expenseRemaining: max(totals.expenses.projected - totals.expenses.actual, 0)
            )
        }
    }

    public static func yearTotals(_ flows: [MonthlyFlow]) -> YearTotals {
        YearTotals(
            incomeProjected: flows.map(\.incomeTotal).reduce(0, +), incomeActual: flows.map(\.incomeActual).reduce(0, +),
            expenseProjected: flows.map(\.expenseTotal).reduce(0, +), expenseActual: flows.map(\.expenseActual).reduce(0, +)
        )
    }

    // MARK: Top categories

    /// Expense categories for the current month, rolled up by `CategoryGroup` exactly like
    /// the grids (a group is the sum of its members; ungrouped categories stand alone),
    /// ranked by projected month-end spend.
    public static func topCategories(_ input: DashboardInput, limit: Int = 5) -> [CategorySpend] {
        let parts = MonthRange.components(of: input.effectiveToday)
        let monthClass = MonthBlend.classify(year: parts.year, month: parts.month, dataThrough: input.dataThrough, today: input.today)
        let groupNames = Dictionary(uniqueKeysWithValues: input.categoryGroups.compactMap { group -> (Int64, String)? in group.id.map { ($0, group.name) } })

        var rolled: [String: (actual: Int, expected: Int, projected: Int)] = [:]
        categoryAmounts(input, year: parts.year, month: parts.month, monthClass: monthClass, includeExpected: true) { category, actual, expected, projected in
            guard category.type == .expense else { return }
            let key = category.groupId.flatMap { groupNames[$0] } ?? category.name
            var entry = rolled[key] ?? (0, 0, 0)
            entry.actual -= actual; entry.expected -= expected; entry.projected -= projected
            rolled[key] = entry
        }
        return rolled
            .map { CategorySpend(name: $0.key, actual: $0.value.actual, expected: $0.value.expected, projected: $0.value.projected) }
            .filter { $0.actual != 0 || $0.expected != 0 || $0.projected != 0 }
            .sorted { $0.projected != $1.projected ? $0.projected > $1.projected : $0.name < $1.name }
            .prefix(limit)
            .map { $0 }
    }
}
```

- [ ] **Step 4: Verify** — `swift test --filter DashboardFlowTests` → PASS (13 tests); `swift test` → all green.

- [ ] **Step 5: Commit**

```bash
git add Sources/BudgetCore/Dashboard/DashboardCalculator+Flows.swift Tests/BudgetCoreTests/DashboardFlowTests.swift
git commit -m "Add dashboard current-month, year-at-a-glance and top-category calculations

Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
```

---

### Task 10: AppScreen.dashboard, default selection, import picker lists all accounts

**Files:**
- Modify: `App/ContentView.swift`

**Interfaces:**
- Produces: `AppScreen.dashboard` (rawValue "Dashboard"); `ContentView` default selection `.dashboard`; the Import screen lists **all** accounts and remembers the last-used one (`@AppStorage("lastImportAccountId")`). The `.dashboard` detail case is added in Task 14 (until then, the switch needs a placeholder so the file compiles).

- [ ] **Step 1: Edit `AppScreen`**

```swift
enum AppScreen: String, CaseIterable, Identifiable {
    case importReview = "Import"
    case dashboard = "Dashboard"
    case budgetGrid = "Budget"
    // ... unchanged ...
```

`systemImage`: add `case .dashboard: return "square.grid.2x2"`. `sidebarSection`: `case .dashboard, .budgetGrid, .forecast, .netWorth: return "Overview"`.

- [ ] **Step 2: Edit `ContentView`**

1. `@State private var selection: AppScreen? = .dashboard`
2. Add below the other `@State` properties: `@AppStorage("lastImportAccountId") private var lastImportAccountId = 0`
3. In the detail `switch`, add a temporary case (replaced in Task 14):

```swift
                case .dashboard:
                    Text("Dashboard") // replaced by DashboardView in Task 14
```
4. In the `.importReview` case replace `importableAccounts` with `accounts` (all of them) and the empty-state text with: `"Add an account under Accounts, then pick it here to import a statement."`. The Picker becomes:

```swift
                            Picker("Import into", selection: $selectedImportAccountId) {
                                ForEach(accounts) { account in
                                    Text("\(account.name) (\(account.currency.rawValue.uppercased()))").tag(Int64?.some(account.id!))
                                }
                            }
```
5. Delete the `importableAccounts` computed property and its doc comment; `selectedImportAccount` becomes `accounts.first { $0.id == selectedImportAccountId }`.
6. In `refreshSharedState()` replace the final block with:

```swift
        // Keep the user's choice across navigation; otherwise default to the last-used
        // account (remembered across launches), then the first account.
        if selectedImportAccount == nil {
            selectedImportAccountId = accounts.first { Int($0.id ?? -1) == lastImportAccountId }?.id ?? accounts.first?.id
        }
```
7. Add to the `body` modifiers (next to the other `.onChange`):

```swift
        .onChange(of: selectedImportAccountId) { _ in
            if let id = selectedImportAccountId { lastImportAccountId = Int(id) }
        }
```

- [ ] **Step 3: Build** — `xcodegen generate && xcodebuild -project Budget.xcodeproj -scheme Budget -destination 'platform=macOS' build 2>&1 | tail -5` → `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
git add App/ContentView.swift
git commit -m "Add the Dashboard screen entry and let every account be an import target

Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
```

---

### Task 11: Extract ImportFlowHost from ImportView

**Files:**
- Create: `App/Import/ImportFlowHost.swift`
- Modify: `App/Import/ImportView.swift`

**Interfaces:**
- Produces: `ImportFlowActions(startCSV:startPDF:)`; `ImportFlowHost(viewModel:account:profileStore:onStarted:content:)` — wraps `content` with the CSV/PDF file pickers and the two mapping wizards; `onStarted` fires at the moment staging begins (after picking a CSV with a saved profile, after the mapping wizard saves, after picking a PDF with a saved layout, or after the PDF wizard saves — never on cancel). Behavior of the Import screen is unchanged.

- [ ] **Step 1: Create the host** — move the state, `fileImporter`s, wizard sheets and `handlePickedFile`/`handlePickedPDF` out of `ImportView` verbatim, with staging launches routed through `onStarted`:

```swift
// App/Import/ImportFlowHost.swift
import SwiftUI
import BudgetCore
import UniformTypeIdentifiers

struct ImportFlowActions {
    let startCSV: () -> Void
    let startPDF: () -> Void
}

/// Owns everything needed to START an import — the two file pickers, the column-mapping and
/// PDF-layout wizards, and the "which file did the user pick" state — so the Import screen
/// and the Dashboard's import card start one in exactly the same way. Progress and review
/// stay on the Import screen (`ImportView`).
struct ImportFlowHost<Content: View>: View {
    @ObservedObject var viewModel: ImportViewModel
    let account: Account
    let profileStore: ImportProfileStore
    /// Called when staging actually begins (not when the user cancels a picker or wizard).
    let onStarted: () -> Void
    @ViewBuilder let content: (ImportFlowActions) -> Content

    @State private var showFilePicker = false
    @State private var pendingHeaderRowForWizard: [String]?
    @State private var pendingFileURL: URL?
    @State private var showPDFPicker = false
    @State private var pendingPDFLines: [String]?
    @State private var pendingPDFFileName = "statement.pdf"

    var body: some View {
        content(ImportFlowActions(startCSV: { showFilePicker = true }, startPDF: { showPDFPicker = true }))
            .fileImporter(isPresented: $showFilePicker, allowedContentTypes: [.commaSeparatedText]) { result in
                switch result {
                case .success(let url): handlePickedFile(url)
                case .failure(let error): viewModel.fail("Couldn't open the file: \(error.localizedDescription)")
                }
            }
            .fileImporter(isPresented: $showPDFPicker, allowedContentTypes: [.pdf]) { result in
                switch result {
                case .success(let url): handlePickedPDF(url)
                case .failure(let error): viewModel.fail("Couldn't open the file: \(error.localizedDescription)")
                }
            }
            .sheet(item: Binding(get: { pendingHeaderRowForWizard.map { Wrapped(value: $0) } }, set: { _ in pendingHeaderRowForWizard = nil })) { wrapped in
                CSVMappingWizardView(account: account, sampleHeaderRow: wrapped.value) { profile in
                    pendingHeaderRowForWizard = nil
                    do {
                        try profileStore.save(profile)
                    } catch {
                        viewModel.fail("Couldn't save the column mapping: \(error.localizedDescription)")
                        return
                    }
                    if let url = pendingFileURL { startCSVStaging(url) }
                }
            }
            .sheet(item: Binding(get: { pendingPDFLines.map { Wrapped(value: $0) } }, set: { _ in pendingPDFLines = nil })) { wrapped in
                PDFLayoutWizardView(account: account, sampleLines: wrapped.value) { profile in
                    pendingPDFLines = nil
                    do {
                        try profileStore.save(profile)
                        guard let configJSON = profile.pdfLayoutConfig else {
                            viewModel.fail("The PDF layout couldn't be saved.")
                            return
                        }
                        let config = try PDFLayoutConfig.decode(configJSON)
                        startPDFStaging(lines: wrapped.value, config: config, fileName: pendingPDFFileName)
                    } catch {
                        viewModel.fail("Couldn't save the PDF layout: \(error.localizedDescription)")
                    }
                }
            }
    }

    private func startCSVStaging(_ url: URL) {
        onStarted()
        Task { await viewModel.stageCSV(fileURL: url, account: account) }
    }

    private func startPDFStaging(lines: [String], config: PDFLayoutConfig, fileName: String) {
        onStarted()
        Task { await viewModel.stagePDF(lines: lines, config: config, account: account, sourceFileName: fileName) }
    }

    private func handlePickedFile(_ url: URL) {
        viewModel.errorMessage = nil
        pendingFileURL = url
        guard let accountId = account.id else {
            viewModel.fail("This account hasn't been saved yet.")
            return
        }
        let text: String
        do {
            text = try ImportViewModel.readText(at: url)
        } catch {
            viewModel.fail("Couldn't read \(url.lastPathComponent) as UTF-8 text: \(error.localizedDescription)")
            return
        }
        // CSVStatementParser.splitLines handles LF, CRLF and CR line endings alike.
        guard let firstLine = CSVStatementParser.splitLines(text).first else {
            viewModel.fail("\(url.lastPathComponent) is empty.")
            return
        }
        do {
            if try profileStore.find(accountId: accountId, format: .csv) != nil {
                startCSVStaging(url)
            } else {
                pendingHeaderRowForWizard = CSVRowSplitter.split(line: firstLine, delimiter: ",")
            }
        } catch {
            viewModel.fail("Couldn't load this account's import settings: \(error.localizedDescription)")
        }
    }

    private func handlePickedPDF(_ url: URL) {
        viewModel.errorMessage = nil
        guard let accountId = account.id else {
            viewModel.fail("This account hasn't been saved yet.")
            return
        }
        let lines: [String]
        do {
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            lines = try PDFTextExtractor.extractLines(from: url)
        } catch {
            viewModel.fail("Couldn't read text from \(url.lastPathComponent). Is it a scanned (image-only) PDF?")
            return
        }
        guard !lines.isEmpty else {
            viewModel.fail("No text could be extracted from \(url.lastPathComponent).")
            return
        }
        pendingPDFFileName = url.lastPathComponent
        do {
            if let existingProfile = try profileStore.find(accountId: accountId, format: .pdf),
               let configJSON = existingProfile.pdfLayoutConfig {
                let config = try PDFLayoutConfig.decode(configJSON)
                startPDFStaging(lines: lines, config: config, fileName: url.lastPathComponent)
            } else {
                pendingPDFLines = lines
            }
        } catch {
            viewModel.fail("Couldn't load this account's PDF layout: \(error.localizedDescription)")
        }
    }
}

private struct Wrapped: Identifiable {
    let value: [String]
    var id: String { value.joined() }
}
```

- [ ] **Step 2: Slim down `ImportView`** — keep the error/status banners, `ReviewView`, `stagingProgressView`; delete the moved `@State`s, the two `fileImporter`s, the two `.sheet`s, `handlePickedFile`, `handlePickedPDF` and the private `Wrapped` struct. The body becomes:

```swift
    var body: some View {
        ImportFlowHost(viewModel: viewModel, account: account, profileStore: profileStore, onStarted: {}) { actions in
            VStack(alignment: .leading, spacing: 12) {
                // While reviewing, ReviewView shows this same errorMessage locally, right next
                // to the button that caused it — skip the banner here to avoid showing the
                // same error twice (e.g. a failed "Confirm N ready" leaves isReviewing true).
                if let error = viewModel.errorMessage, !viewModel.isReviewing {
                    HStack(alignment: .top) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                        Text(error).foregroundStyle(.red)
                        Spacer()
                        Button("Dismiss") { viewModel.errorMessage = nil }
                            .buttonStyle(.borderless)
                    }
                    .font(.callout)
                }
                if let status = viewModel.statusMessage, !viewModel.isReviewing {
                    Text(status).foregroundStyle(.secondary).font(.callout)
                }

                if viewModel.isReviewing {
                    ReviewView(viewModel: viewModel, categories: categories) {}
                } else if viewModel.isStaging {
                    stagingProgressView
                } else {
                    Button("Import CSV statement…") { actions.startCSV() }
                    Button("Import PDF statement…") { actions.startPDF() }
                }
                Spacer(minLength: 0)
            }
            .padding()
        }
    }
```

Remove the now-unused `import UniformTypeIdentifiers` from `ImportView.swift`.

- [ ] **Step 3: Build** — `xcodegen generate && xcodebuild -project Budget.xcodeproj -scheme Budget -destination 'platform=macOS' build 2>&1 | tail -5` → `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
git add App/Import/ImportFlowHost.swift App/Import/ImportView.swift
git commit -m "Extract ImportFlowHost so the dashboard can start an import

Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
```

---

### Task 12: DashboardViewModel

**Files:**
- Create: `App/Dashboard/DashboardViewModel.swift`

**Interfaces:**
- Consumes: `DashboardInput` and every `DashboardCalculator` function (Tasks 7–9).
- Produces: `DashboardContent` (all display models), `DashboardViewModel` (`content`, `flows`, `selectedYear`, `errorMessage`, `load()`, `selectYear(_:)`, `yearRange`). Used by Tasks 13–14.

- [ ] **Step 1: Write the view model**

```swift
// App/Dashboard/DashboardViewModel.swift
import Foundation
import BudgetCore
import struct BudgetCore.Category
import GRDB

/// Everything the dashboard renders, computed once per load. Views are pure functions of
/// this — no calculation happens in a view body (the Forecast screen's per-scroll-frame
/// recompute is the cautionary precedent).
struct DashboardContent {
    let today: Date
    let freshness: DataFreshness
    let netWorth: NetWorthSeries
    let yearChanges: [YearChange]
    let currentMonth: CurrentMonthTracking
    let topCategories: [CategorySpend]
    let attention: AttentionItems
    let bills: [UpcomingBill]
    let accounts: [AccountSummary]
    let catchAll: CatchAllAllowance?
    /// Selectable years for the year-at-a-glance chart: first data year ... next year.
    let yearRange: ClosedRange<Int>
}

@MainActor
final class DashboardViewModel: ObservableObject {
    @Published private(set) var content: DashboardContent?
    @Published private(set) var flows: [MonthlyFlow] = []
    @Published private(set) var selectedYear: Int
    @Published private(set) var errorMessage: String?

    private let dbQueue: DatabaseQueue
    private let todayProvider: () -> Date
    private var input: DashboardInput?

    init(dbQueue: DatabaseQueue, today: @escaping () -> Date = { Date() }) {
        self.dbQueue = dbQueue
        self.todayProvider = today
        self.selectedYear = MonthRange.components(of: today()).year
    }

    /// One batched read, then every display model computed once. Stale content stays in
    /// place if the read fails.
    func load() {
        do {
            let today = todayProvider()
            let loaded = try dbQueue.read { db -> DashboardInput in
                DashboardInput(
                    today: today,
                    accounts: try Account.fetchAll(db),
                    snapshots: try BalanceSnapshot.fetchAll(db),
                    transactions: try Transaction.fetchAll(db),
                    categories: try Category.fetchAll(db),
                    categoryGroups: try CategoryGroup.fetchAll(db),
                    forecastEntries: try ForecastEntry.fetchAll(db),
                    forecastGroups: try ForecastGroup.fetchAll(db),
                    importBatches: try ImportBatch.fetchAll(db),
                    rate: try ExchangeRateSetting.currentOrDefault(db: db)
                )
            }
            let netWorth = DashboardCalculator.netWorthSeries(loaded)
            let thisYear = MonthRange.components(of: today).year
            let firstYear = netWorth.actual.first?.year ?? thisYear
            let range = min(firstYear, thisYear)...(thisYear + 1)

            input = loaded
            content = DashboardContent(
                today: today,
                freshness: DashboardCalculator.dataFreshness(loaded),
                netWorth: netWorth,
                yearChanges: DashboardCalculator.yearOverYear(loaded, series: netWorth),
                currentMonth: DashboardCalculator.currentMonth(loaded),
                topCategories: DashboardCalculator.topCategories(loaded),
                attention: DashboardCalculator.attentionItems(loaded),
                bills: DashboardCalculator.upcomingBills(loaded),
                accounts: DashboardCalculator.accountSummaries(loaded),
                catchAll: DashboardCalculator.catchAllAllowance(loaded),
                yearRange: range
            )
            if !range.contains(selectedYear) { selectedYear = thisYear }
            flows = DashboardCalculator.monthlyFlows(loaded, year: selectedYear)
            errorMessage = nil
        } catch {
            errorMessage = "Couldn't load the dashboard: \(error.localizedDescription)"
        }
    }

    /// Recomputes only the year-at-a-glance months, from the already-loaded data.
    func selectYear(_ year: Int) {
        guard let input, content?.yearRange.contains(year) == true else { return }
        selectedYear = year
        flows = DashboardCalculator.monthlyFlows(input, year: year)
    }
}
```

- [ ] **Step 2: Build** — `xcodegen generate && xcodebuild -project Budget.xcodeproj -scheme Budget -destination 'platform=macOS' build 2>&1 | tail -5` → `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git add App/Dashboard/DashboardViewModel.swift
git commit -m "Add DashboardViewModel

Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
```

---

### Task 13: Charts and formatting helpers

**Files:**
- Create: `App/Dashboard/DashboardFormat.swift`, `App/Dashboard/HatchPattern.swift`, `App/Dashboard/NetWorthLineChart.swift`, `App/Dashboard/YearOverYearChart.swift`, `App/Dashboard/YearAtAGlanceChart.swift`

**Interfaces:**
- Consumes: `NetWorthPoint`, `YearChange`, `MonthlyFlow`, `MonthRange`, `MonthClass` (BudgetCore).
- Produces: `DashboardFormat.pounds(_:)`, `.day(_:)`, `.monthYear(_:)`, `.percent(_:)`; `HatchPattern.style(_:)`; `NetWorthLineChart(actual:forecast:today:)`, `YearOverYearChart(changes:)`, `YearAtAGlanceChart(flows:)`.

- [ ] **Step 1: Formatting helpers**

```swift
// App/Dashboard/DashboardFormat.swift
import Foundation

enum DashboardFormat {
    private static let wholePounds: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "GBP"
        formatter.locale = Locale(identifier: "en_GB")
        formatter.maximumFractionDigits = 0
        formatter.minimumFractionDigits = 0
        return formatter
    }()

    private static func utcFormatter(_ pattern: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_GB")
        formatter.dateFormat = pattern
        return formatter
    }
    private static let dayFormatter = utcFormatter("d MMM yyyy")
    private static let monthYearFormatter = utcFormatter("MMMM yyyy")

    /// "£161,340" — whole pounds, signed.
    static func pounds(_ minorUnits: Int) -> String {
        wholePounds.string(from: NSNumber(value: Double(minorUnits) / 100)) ?? "—"
    }

    static func day(_ date: Date) -> String { dayFormatter.string(from: date) }
    static func monthYear(_ date: Date) -> String { monthYearFormatter.string(from: date) }

    /// "+36.4%" / "-4.0%"; "—" when unknown.
    static func percent(_ fraction: Double?) -> String {
        guard let fraction else { return "—" }
        return String(format: "%+.1f%%", fraction * 100)
    }

    /// "£12.4k"-style label for chart annotations; sign kept.
    static func compactPounds(_ minorUnits: Int) -> String {
        let thousands = Double(minorUnits) / 100_000
        return String(format: "%@£%.1fk", thousands < 0 ? "-" : "+", abs(thousands))
    }
}
```

- [ ] **Step 2: Hatch fill**

```swift
// App/Dashboard/HatchPattern.swift
import SwiftUI

/// A tiled diagonal-hatch fill: solid = actual, hatched = forecast, everywhere on the
/// dashboard. If the image can't be rendered, falls back to a 30%-opacity fill of the same
/// color (the accepted fallback in the spec).
@MainActor
enum HatchPattern {
    static func style(_ color: Color) -> AnyShapeStyle {
        let tile = Canvas { context, size in
            var path = Path()
            path.move(to: CGPoint(x: 0, y: size.height)); path.addLine(to: CGPoint(x: size.width, y: 0))
            path.move(to: CGPoint(x: -2, y: 2)); path.addLine(to: CGPoint(x: 2, y: -2))
            path.move(to: CGPoint(x: size.width - 2, y: size.height + 2)); path.addLine(to: CGPoint(x: size.width + 2, y: size.height - 2))
            context.stroke(path, with: .color(color), lineWidth: 1.5)
        }
        .frame(width: 6, height: 6)
        let renderer = ImageRenderer(content: tile)
        renderer.scale = 2
        guard let image = renderer.cgImage else { return AnyShapeStyle(color.opacity(0.3)) }
        return AnyShapeStyle(ImagePaint(image: Image(decorative: image, scale: 2), scale: 1))
    }
}
```

- [ ] **Step 3: Net worth line chart**

```swift
// App/Dashboard/NetWorthLineChart.swift
import SwiftUI
import Charts
import BudgetCore

/// Net worth by month: solid actual line (light area beneath), dashed forecast line, a
/// "Today" rule, dots on the forecast year-ends, and a hover read-out.
struct NetWorthLineChart: View {
    let actual: [NetWorthPoint]
    let forecast: [NetWorthPoint]
    let today: Date

    @State private var selectedDate: Date?

    private struct Plotted: Identifiable {
        let id: Int
        let date: Date
        let month: Int
        let pounds: Double
    }

    private func plot(_ points: [NetWorthPoint]) -> [Plotted] {
        points.map { Plotted(id: $0.id, date: MonthRange.of(year: $0.year, month: $0.month).start, month: $0.month, pounds: Double($0.valueMinorUnits) / 100) }
    }

    private var selected: Plotted? {
        guard let selectedDate else { return nil }
        return (plot(actual) + plot(forecast)).min { abs($0.date.timeIntervalSince(selectedDate)) < abs($1.date.timeIntervalSince(selectedDate)) }
    }

    var body: some View {
        let actualPlotted = plot(actual)
        let forecastPlotted = plot(forecast)
        Chart {
            ForEach(actualPlotted) { point in
                AreaMark(x: .value("Month", point.date), y: .value("Net worth", point.pounds), series: .value("Series", "Actual area"))
                    .foregroundStyle(Color.blue.opacity(0.12))
                LineMark(x: .value("Month", point.date), y: .value("Net worth", point.pounds), series: .value("Series", "Actual"))
                    .foregroundStyle(Color.blue)
                    .lineStyle(StrokeStyle(lineWidth: 2))
            }
            ForEach(forecastPlotted) { point in
                LineMark(x: .value("Month", point.date), y: .value("Net worth", point.pounds), series: .value("Series", "Forecast"))
                    .foregroundStyle(Color.blue)
                    .lineStyle(StrokeStyle(lineWidth: 2, dash: [5, 4]))
            }
            ForEach(forecastPlotted.filter { $0.month == 12 }) { point in
                PointMark(x: .value("Month", point.date), y: .value("Net worth", point.pounds))
                    .foregroundStyle(Color.blue)
                    .symbolSize(40)
            }
            RuleMark(x: .value("Today", today))
                .foregroundStyle(Color.secondary)
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                .annotation(position: .top, alignment: .leading, spacing: 2) {
                    Text("Today").font(.caption2).foregroundStyle(.secondary)
                }
            if let selected {
                RuleMark(x: .value("Selected", selected.date))
                    .foregroundStyle(Color.secondary.opacity(0.5))
                    .annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        VStack(spacing: 0) {
                            Text(DashboardFormat.monthYear(selected.date)).font(.caption2).foregroundStyle(.secondary)
                            Text(DashboardFormat.pounds(Int(selected.pounds * 100))).font(.caption.bold())
                        }
                        .padding(4)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .windowBackgroundColor)))
                    }
            }
        }
        .chartXSelection(value: $selectedDate)
        .chartXAxis {
            AxisMarks(values: .stride(by: .year)) { _ in
                AxisGridLine()
                AxisValueLabel(format: .dateTime.year(), centered: false)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let pounds = value.as(Double.self) { Text("£\(Int(pounds / 1000))k") }
                }
            }
        }
        .frame(height: 230)
        .accessibilityLabel("Net worth by month since \(actual.first.map { String($0.year) } ?? "the start"), actual and forecast")
    }
}
```

- [ ] **Step 4: Year-over-year chart**

```swift
// App/Dashboard/YearOverYearChart.swift
import SwiftUI
import Charts
import BudgetCore

/// Net worth change per year: solid = realised, hatched = forecast, negative below the axis.
struct YearOverYearChart: View {
    let changes: [YearChange]

    private func label(_ change: YearChange) -> String {
        change.partialFromMonth != nil ? "\(change.year)*" : String(change.year)
    }
    private func pounds(_ minorUnits: Int) -> Double { Double(minorUnits) / 100 }
    private func color(_ change: YearChange) -> Color { change.totalMinorUnits < 0 ? .red : .green }

    var body: some View {
        Chart {
            ForEach(changes) { change in
                if change.realisedMinorUnits != 0 || change.forecastMinorUnits == 0 {
                    BarMark(x: .value("Year", label(change)), y: .value("Realised", pounds(change.realisedMinorUnits)))
                        .foregroundStyle(color(change))
                        .annotation(position: change.totalMinorUnits < 0 ? .bottom : .top) {
                            if change.forecastMinorUnits == 0 { totalLabel(change) }
                        }
                }
                if change.forecastMinorUnits != 0 {
                    BarMark(x: .value("Year", label(change)), y: .value("Forecast", pounds(change.forecastMinorUnits)))
                        .foregroundStyle(HatchPattern.style(color(change)))
                        .annotation(position: change.totalMinorUnits < 0 ? .bottom : .top) { totalLabel(change) }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let pounds = value.as(Double.self) { Text("£\(Int(pounds / 1000))k") }
                }
            }
        }
        .frame(height: 200)
        .accessibilityLabel("Net worth change per year")
    }

    private func totalLabel(_ change: YearChange) -> some View {
        Text(DashboardFormat.compactPounds(change.totalMinorUnits))
            .font(.caption2)
            .foregroundStyle(.secondary)
    }
}
```

- [ ] **Step 5: Year-at-a-glance chart**

```swift
// App/Dashboard/YearAtAGlanceChart.swift
import SwiftUI
import Charts
import BudgetCore

/// Twelve months of income and expenses side by side (each a solid "actual" part plus a
/// hatched "still expected" part) with the net as a line. Solid = actual, hatched = forecast.
struct YearAtAGlanceChart: View {
    let flows: [MonthlyFlow]

    private static let monthNames = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
    private func name(_ flow: MonthlyFlow) -> String { Self.monthNames[flow.month - 1] }
    private func pounds(_ minorUnits: Int) -> Double { Double(minorUnits) / 100 }

    var body: some View {
        Chart {
            ForEach(flows) { flow in
                BarMark(x: .value("Month", name(flow)), y: .value("Income", pounds(flow.incomeActual)))
                    .position(by: .value("Type", "Income"))
                    .foregroundStyle(Color.green)
                if flow.incomeRemaining > 0 {
                    BarMark(x: .value("Month", name(flow)), y: .value("Income", pounds(flow.incomeRemaining)))
                        .position(by: .value("Type", "Income"))
                        .foregroundStyle(HatchPattern.style(.green))
                }
                BarMark(x: .value("Month", name(flow)), y: .value("Expenses", pounds(flow.expenseActual)))
                    .position(by: .value("Type", "Expenses"))
                    .foregroundStyle(Color.orange)
                if flow.expenseRemaining > 0 {
                    BarMark(x: .value("Month", name(flow)), y: .value("Expenses", pounds(flow.expenseRemaining)))
                        .position(by: .value("Type", "Expenses"))
                        .foregroundStyle(HatchPattern.style(.orange))
                }
            }
            ForEach(flows) { flow in
                LineMark(x: .value("Month", name(flow)), y: .value("Net", pounds(flow.net)), series: .value("Series", "Net"))
                    .foregroundStyle(Color.blue)
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
                PointMark(x: .value("Month", name(flow)), y: .value("Net", pounds(flow.net)))
                    .foregroundStyle(Color.blue)
                    .symbolSize(flow.monthClass == .forecast ? 24 : 40)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let pounds = value.as(Double.self) { Text("£\(Int(pounds / 1000))k") }
                }
            }
        }
        .frame(height: 220)
        .accessibilityLabel("Monthly income, expenses and net for the selected year, actual and forecast")
    }
}
```

- [ ] **Step 6: Build** — `xcodegen generate && xcodebuild -project Budget.xcodeproj -scheme Budget -destination 'platform=macOS' build 2>&1 | tail -20` → `** BUILD SUCCEEDED **`. (If a Charts modifier doesn't compile against the installed SDK, adjust the call while keeping the behavior; if `ImagePaint` renders blank in the later visual check, switch `HatchPattern.style` to return `AnyShapeStyle(color.opacity(0.3))`.)

- [ ] **Step 7: Commit**

```bash
git add App/Dashboard
git commit -m "Add dashboard formatting helpers and Swift Charts views

Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
```

---

### Task 14: Cards, DashboardView and wiring

**Files:**
- Create: `App/Dashboard/DashboardCard.swift`, `App/Dashboard/FreshnessImportCard.swift`, `App/Dashboard/NetWorthCard.swift`, `App/Dashboard/YearChangeCard.swift`, `App/Dashboard/CurrentMonthCard.swift`, `App/Dashboard/YearAtAGlanceCard.swift`, `App/Dashboard/SmallCards.swift`, `App/Dashboard/DashboardView.swift`
- Modify: `App/ContentView.swift`

**Interfaces:**
- Consumes: `DashboardViewModel`/`DashboardContent` (Task 12), the three charts and `DashboardFormat` (Task 13), `ImportFlowHost` (Task 11), `ImportViewModel`, `AppScreen`.
- Produces: `DashboardView(viewModel:importViewModel:accounts:selectedImportAccountId:profileStore:navigate:)`.

- [ ] **Step 1: Card container and meter**

```swift
// App/Dashboard/DashboardCard.swift
import SwiftUI

struct DashboardCard<Content: View>: View {
    let title: String
    var linkTitle: String? = nil
    var onLink: (() -> Void)? = nil
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.headline)
                Spacer()
                if let linkTitle, let onLink {
                    Button("\(linkTitle) ›", action: onLink)
                        .buttonStyle(.link)
                        .font(.caption)
                }
            }
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color(nsColor: .separatorColor)))
    }
}

/// A thin progress meter with a marker at "how far through the month we are".
struct PaceMeter: View {
    let fraction: Double
    let pace: Double
    let tint: Color

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color(nsColor: .separatorColor).opacity(0.5))
                Capsule().fill(tint).frame(width: proxy.size.width * min(max(fraction, 0), 1))
                Rectangle().fill(Color.primary.opacity(0.6)).frame(width: 2)
                    .offset(x: proxy.size.width * min(max(pace, 0), 1) - 1)
            }
        }
        .frame(height: 6)
    }
}
```

- [ ] **Step 2: Freshness + import card**

```swift
// App/Dashboard/FreshnessImportCard.swift
import SwiftUI
import BudgetCore

struct FreshnessImportCard: View {
    let freshness: DataFreshness
    @ObservedObject var importViewModel: ImportViewModel
    let accounts: [Account]
    @Binding var selectedAccountId: Int64?
    let profileStore: ImportProfileStore
    let navigate: (AppScreen) -> Void

    private var tint: Color {
        switch freshness.status {
        case .behind: return .orange
        case .upToDate: return .green
        case .noData: return .gray
        }
    }

    private var title: String {
        switch freshness.status {
        case .noData: return "Nothing imported yet"
        case .upToDate: return "Up to date"
        case .behind(let months, let days):
            return months >= 1 ? "Data is \(months) month\(months == 1 ? "" : "s") behind" : "Data is \(days) days behind"
        }
    }

    private var detail: String {
        var parts: [String] = []
        if let at = freshness.lastImportAt {
            let file = freshness.lastImportFileName.map { " (\($0))" } ?? ""
            parts.append("Last import \(DashboardFormat.day(at))\(file)")
        }
        if let through = freshness.dataThrough { parts.append("transactions through \(DashboardFormat.day(through))") }
        return parts.joined(separator: " · ")
    }

    private var selectedAccount: Account? { accounts.first { $0.id == selectedAccountId } }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Label(title, systemImage: freshness.status == .upToDate ? "checkmark.circle.fill" : (freshness.status == .noData ? "tray" : "exclamationmark.triangle.fill"))
                    .font(.headline)
                    .foregroundStyle(tint)
                if !detail.isEmpty { Text(detail).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer()
            importControls
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(tint.opacity(0.1)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(tint.opacity(0.35)))
    }

    @ViewBuilder
    private var importControls: some View {
        if importViewModel.isStaging {
            HStack {
                ProgressView().controlSize(.small)
                Text("Import in progress…").font(.callout)
                Button("View progress ›") { navigate(.importReview) }.buttonStyle(.link)
            }
        } else if importViewModel.isReviewing {
            HStack {
                Text("Import ready to review").font(.callout)
                Button("Resume review ›") { navigate(.importReview) }.buttonStyle(.link)
            }
        } else if accounts.isEmpty {
            HStack {
                Text("Add an account to import into").font(.callout).foregroundStyle(.secondary)
                Button("Accounts ›") { navigate(.accounts) }.buttonStyle(.link)
            }
        } else {
            HStack {
                Picker("Import into", selection: $selectedAccountId) {
                    ForEach(accounts) { account in
                        Text(account.name).tag(Int64?.some(account.id!))
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 220)
                if let account = selectedAccount {
                    ImportFlowHost(viewModel: importViewModel, account: account, profileStore: profileStore, onStarted: { navigate(.importReview) }) { actions in
                        HStack {
                            Button("Import CSV…") { actions.startCSV() }
                            Button("Import PDF…") { actions.startPDF() }
                        }
                    }
                }
            }
        }
    }
}
```

- [ ] **Step 3: Net worth card**

```swift
// App/Dashboard/NetWorthCard.swift
import SwiftUI
import BudgetCore

struct NetWorthCard: View {
    let content: DashboardContent
    let navigate: (AppScreen) -> Void

    private var series: NetWorthSeries { content.netWorth }

    var body: some View {
        DashboardCard(title: "Net worth since \(series.actual.first.map { String($0.year) } ?? "2020")", linkTitle: "Net Worth", onLink: { navigate(.netWorth) }) {
            if series.actual.isEmpty {
                Text("No history yet — record a balance on the Net Worth screen.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                if let behind = series.behindBalances {
                    Label("\(behind.accountCount) balance\(behind.accountCount == 1 ? " was" : "s were") last updated \(DashboardFormat.day(behind.oldestSnapshotDate)), so the forecast restarts from \(behind.accountCount == 1 ? "it" : "them"). Update balances to correct it.", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                HStack(alignment: .top, spacing: 12) {
                    statBlock(
                        title: series.asOf.map { "Net worth as of \(DashboardFormat.day($0))" } ?? "Net worth",
                        value: series.currentNetWorthMinorUnits.map(DashboardFormat.pounds) ?? "—",
                        detail: series.changeVsPreviousMonthMinorUnits.map { "\($0 >= 0 ? "↑" : "↓") \(DashboardFormat.pounds(abs($0))) vs previous month" },
                        large: true
                    )
                    ForEach(series.yearEnds, id: \.year) { yearEnd in
                        statBlock(
                            title: "Forecast Dec \(yearEnd.year)",
                            value: DashboardFormat.pounds(yearEnd.valueMinorUnits),
                            detail: "\(yearEnd.changeMinorUnits >= 0 ? "↑" : "↓") \(DashboardFormat.percent(yearEnd.percent.map(abs))) vs Dec \(yearEnd.year - 1)",
                            large: false
                        )
                    }
                }
                NetWorthLineChart(actual: series.actual, forecast: series.forecast, today: content.today)
                HStack(spacing: 14) {
                    legend(solid: true, "Actual")
                    legend(solid: false, "Confirmed forecast")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    private func statBlock(title: String, value: String, detail: String?, large: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(large ? .title2.bold() : .headline).monospacedDigit()
            if let detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .windowBackgroundColor)))
    }

    private func legend(solid: Bool, _ text: String) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 1)
                .fill(solid ? Color.blue : Color.blue.opacity(0.45))
                .frame(width: 14, height: 3)
            Text(text)
        }
    }
}
```

- [ ] **Step 4: Year-over-year and current-month cards**

```swift
// App/Dashboard/YearChangeCard.swift
import SwiftUI
import BudgetCore

struct YearChangeCard: View {
    let changes: [YearChange]
    let navigate: (AppScreen) -> Void

    var body: some View {
        DashboardCard(title: "Net worth change per year", linkTitle: "Net Worth", onLink: { navigate(.netWorth) }) {
            if changes.isEmpty {
                Text("Needs at least a year of balance history.").font(.callout).foregroundStyle(.secondary)
            } else {
                YearOverYearChart(changes: changes)
                HStack(spacing: 14) {
                    Label("Realised", systemImage: "square.fill").foregroundStyle(.green)
                    Label("Forecast", systemImage: "square.dashed").foregroundStyle(.green.opacity(0.7))
                }
                .font(.caption)
                .labelStyle(.titleAndIcon)
                if let first = changes.first, let month = first.partialFromMonth {
                    Text("* \(first.year) measured from \(DateFormatter().shortMonthSymbols[month - 1]) \(first.year) (first data)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
```

```swift
// App/Dashboard/CurrentMonthCard.swift
import SwiftUI
import BudgetCore

struct CurrentMonthCard: View {
    let month: CurrentMonthTracking
    let catchAll: CatchAllAllowance?
    let navigate: (AppScreen) -> Void

    private var monthName: String {
        DashboardFormat.monthYear(MonthRange.of(year: month.year, month: month.month).start)
    }
    private var pace: Double { Double(month.dayOfMonth) / Double(month.daysInMonth) }
    private var hasActuals: Bool { month.monthClass == .blended }

    var body: some View {
        DashboardCard(title: "\(monthName) · day \(month.dayOfMonth) of \(month.daysInMonth)", linkTitle: "Budget", onLink: { navigate(.budgetGrid) }) {
            if !hasActuals {
                Text("No \(monthName) transactions imported yet. Showing expected only.")
                    .font(.caption)
                    .padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.orange.opacity(0.15)))
            }
            row("Income", month.income, tint: .green)
            row("Expenses", month.expenses, tint: month.expenses.actual > month.expenses.expected ? .red : .orange)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("Net").font(.callout.bold())
                    Spacer()
                    Text("Projected month-end \(DashboardFormat.pounds(month.net.projected))").font(.callout).monospacedDigit()
                }
                if hasActuals {
                    Text("So far \(DashboardFormat.pounds(month.net.actual)) · expected \(DashboardFormat.pounds(month.net.expected))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if month.unreviewedCount > 0 {
                Text(unreviewedFootnote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func row(_ title: String, _ totals: FlowTotals, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title).font(.callout.bold())
                Spacer()
                if hasActuals {
                    Text("\(DashboardFormat.pounds(totals.actual)) of \(DashboardFormat.pounds(totals.expected))").font(.callout).monospacedDigit()
                } else {
                    Text("expected \(DashboardFormat.pounds(totals.expected))").font(.callout).monospacedDigit()
                }
            }
            if hasActuals {
                PaceMeter(fraction: totals.expected > 0 ? Double(totals.actual) / Double(totals.expected) : (totals.actual > 0 ? 1 : 0), pace: pace, tint: tint)
            }
            Text("Projected month-end \(DashboardFormat.pounds(totals.projected))")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var unreviewedFootnote: String {
        var text = "\(month.unreviewedCount) unreviewed transaction\(month.unreviewedCount == 1 ? "" : "s") (\(DashboardFormat.pounds(month.unreviewedOutflowMinorUnits)) out) aren't included."
        if let catchAll, catchAll.monthlyMinorUnits > 0 {
            text += " Your catch-all (\(catchAll.name), \(DashboardFormat.pounds(catchAll.monthlyMinorUnits))/month) stands in for typical unreviewed spending."
        }
        return text
    }
}
```

- [ ] **Step 5: Year-at-a-glance card**

```swift
// App/Dashboard/YearAtAGlanceCard.swift
import SwiftUI
import BudgetCore

struct YearAtAGlanceCard: View {
    @ObservedObject var viewModel: DashboardViewModel
    let content: DashboardContent
    let navigate: (AppScreen) -> Void

    private var totals: YearTotals { DashboardCalculator.yearTotals(viewModel.flows) }
    private var isFuture: Bool { viewModel.flows.contains { $0.monthClass != .actual } }

    var body: some View {
        DashboardCard(title: "Year at a glance — actual + forecast", linkTitle: isFuture ? "Forecast" : "Budget", onLink: { navigate(isFuture ? .forecast : .budgetGrid) }) {
            HStack {
                Spacer()
                Button { viewModel.selectYear(viewModel.selectedYear - 1) } label: { Image(systemName: "chevron.left") }
                    .disabled(viewModel.selectedYear <= content.yearRange.lowerBound)
                Text(String(viewModel.selectedYear)).font(.headline).frame(minWidth: 48)
                Button { viewModel.selectYear(viewModel.selectedYear + 1) } label: { Image(systemName: "chevron.right") }
                    .disabled(viewModel.selectedYear >= content.yearRange.upperBound)
            }
            YearAtAGlanceChart(flows: viewModel.flows)
            HStack(spacing: 14) {
                Label("Income", systemImage: "square.fill").foregroundStyle(.green)
                Label("Expenses", systemImage: "square.fill").foregroundStyle(.orange)
                Label("Net", systemImage: "circle.fill").foregroundStyle(.blue)
                Text("Solid = actual · hatched = forecast or still expected").foregroundStyle(.secondary)
            }
            .font(.caption)
            HStack(spacing: 10) {
                total("Income", projected: totals.incomeProjected, actual: totals.incomeActual)
                total("Expenses", projected: totals.expenseProjected, actual: totals.expenseActual)
                total("Net saved", projected: totals.netProjected, actual: totals.netActual)
            }
            Text(footnote).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func total(_ title: String, projected: Int, actual: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(totals.hasForecast ? "\(title) · projected" : title).font(.caption).foregroundStyle(.secondary)
            Text(DashboardFormat.pounds(projected)).font(.headline).monospacedDigit()
            if totals.hasForecast {
                Text("of which actual \(DashboardFormat.pounds(actual))").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .windowBackgroundColor)))
    }

    private var footnote: String {
        isFuture
            ? "Forecast months use confirmed entries only. Unreviewed transactions aren't included."
            : "Completed year — same totals as the Budget grid."
    }
}
```

- [ ] **Step 6: Small cards**

```swift
// App/Dashboard/SmallCards.swift
import SwiftUI
import BudgetCore

struct TopCategoriesCard: View {
    let categories: [CategorySpend]
    let hasActuals: Bool
    let navigate: (AppScreen) -> Void

    var body: some View {
        DashboardCard(title: "Top categories this month", linkTitle: "Forecast", onLink: { navigate(.forecast) }) {
            if categories.isEmpty {
                Text("Nothing planned or spent yet this month.").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(categories) { category in
                HStack {
                    Text(category.name)
                    Spacer()
                    if category.isUnplanned {
                        Text("\(DashboardFormat.pounds(category.actual)) · unplanned").foregroundStyle(.orange)
                    } else if hasActuals {
                        Text("\(DashboardFormat.pounds(category.actual)) of \(DashboardFormat.pounds(category.expected))")
                            .foregroundStyle(category.isOver ? Color.red : Color.primary)
                        if category.isOver { Text("+\(DashboardFormat.pounds(category.actual - category.expected))").foregroundStyle(.red) }
                    } else {
                        Text("expected \(DashboardFormat.pounds(category.expected))").foregroundStyle(.secondary)
                    }
                }
                .font(.callout)
                .monospacedDigit()
                Divider()
            }
        }
    }
}

struct AttentionCard: View {
    let items: AttentionItems
    let navigate: (AppScreen) -> Void

    var body: some View {
        DashboardCard(title: "Needs attention") {
            if items.uncategorizedCount > 0 {
                row(warning: true, "\(items.uncategorizedCount) transaction\(items.uncategorizedCount == 1 ? "" : "s") need a category", link: "Review") { navigate(.uncategorized) }
            } else {
                row(warning: false, "Nothing uncategorized", link: nil) {}
            }
            if items.staleBalanceCount > 0 {
                let since = items.oldestStaleSnapshotDate.map { " since \(DashboardFormat.day($0))" } ?? ""
                row(warning: true, "\(items.staleBalanceCount) balance\(items.staleBalanceCount == 1 ? "" : "s") not updated\(since)", link: "Update balances") { navigate(.netWorth) }
            } else {
                row(warning: false, "All balances up to date", link: nil) {}
            }
            switch items.catchAllIssue {
            case .notDesignated:
                row(warning: true, "No catch-all allowance in the forecast — unplanned spending isn't being projected", link: "Categories") { navigate(.categories) }
            case .noAllowance:
                row(warning: true, "The catch-all category has no monthly allowance in the forecast", link: "Forecast") { navigate(.forecast) }
            case nil:
                EmptyView()
            }
        }
    }

    private func row(warning: Bool, _ text: String, link: String?, action: @escaping () -> Void) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Image(systemName: warning ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                .foregroundStyle(warning ? Color.orange : Color.green)
            Text(text).font(.callout)
            Spacer()
            if let link { Button("\(link) ›", action: action).buttonStyle(.link).font(.caption) }
        }
    }
}

struct UpcomingBillsCard: View {
    let bills: [UpcomingBill]
    let navigate: (AppScreen) -> Void
    private let shown = 5

    var body: some View {
        DashboardCard(title: "Upcoming bills · 30 days", linkTitle: "Forecast", onLink: { navigate(.forecast) }) {
            if bills.isEmpty {
                Text("None in the next 30 days.").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(bills.prefix(shown)) { bill in
                HStack {
                    Text("\(DashboardFormat.day(bill.date)) · \(bill.categoryName)")
                    Spacer()
                    Text(DashboardFormat.pounds(abs(bill.amountMinorUnits))).monospacedDigit()
                }
                .font(.callout)
                Divider()
            }
            if bills.count > shown {
                Button("+ \(bills.count - shown) more ›") { navigate(.forecast) }.buttonStyle(.link).font(.caption)
            }
        }
    }
}

struct AccountsCard: View {
    let accounts: [AccountSummary]
    let navigate: (AppScreen) -> Void
    private let shown = 4

    var body: some View {
        DashboardCard(title: "Accounts", linkTitle: "Net Worth", onLink: { navigate(.netWorth) }) {
            ForEach(accounts.prefix(shown)) { account in
                HStack {
                    Text(account.name)
                    Spacer()
                    if account.kind == .credit {
                        Text("\(DashboardFormat.pounds(abs(account.gbpBalanceMinorUnits))) owed")
                            .foregroundStyle(account.gbpBalanceMinorUnits < 0 ? Color.red : Color.primary)
                    } else {
                        Text(DashboardFormat.pounds(account.gbpBalanceMinorUnits))
                    }
                }
                .font(.callout)
                .monospacedDigit()
                Divider()
            }
            if accounts.count > shown {
                Button("+ \(accounts.count - shown) more ›") { navigate(.netWorth) }.buttonStyle(.link).font(.caption)
            }
        }
    }
}
```

- [ ] **Step 7: Dashboard view**

```swift
// App/Dashboard/DashboardView.swift
import SwiftUI
import BudgetCore

struct DashboardView: View {
    @ObservedObject var viewModel: DashboardViewModel
    @ObservedObject var importViewModel: ImportViewModel
    let accounts: [Account]
    @Binding var selectedImportAccountId: Int64?
    let profileStore: ImportProfileStore
    let navigate: (AppScreen) -> Void

    // Cards reflow to a single column on narrow windows rather than truncating.
    private let columns = [GridItem(.adaptive(minimum: 340), spacing: 12, alignment: .top)]

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                if let error = viewModel.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if let content = viewModel.content {
                    FreshnessImportCard(freshness: content.freshness, importViewModel: importViewModel, accounts: accounts, selectedAccountId: $selectedImportAccountId, profileStore: profileStore, navigate: navigate)
                    NetWorthCard(content: content, navigate: navigate)
                    LazyVGrid(columns: columns, spacing: 12) {
                        YearChangeCard(changes: content.yearChanges, navigate: navigate)
                        CurrentMonthCard(month: content.currentMonth, catchAll: content.catchAll, navigate: navigate)
                    }
                    YearAtAGlanceCard(viewModel: viewModel, content: content, navigate: navigate)
                    LazyVGrid(columns: columns, spacing: 12) {
                        TopCategoriesCard(categories: content.topCategories, hasActuals: content.currentMonth.monthClass == .blended, navigate: navigate)
                        AttentionCard(items: content.attention, navigate: navigate)
                    }
                    LazyVGrid(columns: columns, spacing: 12) {
                        UpcomingBillsCard(bills: content.bills, navigate: navigate)
                        AccountsCard(accounts: content.accounts, navigate: navigate)
                    }
                } else if viewModel.errorMessage == nil {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 200)
                }
            }
            .padding(16)
        }
    }
}
```

- [ ] **Step 8: Wire into `ContentView`**

Add the view model next to the others:

```swift
    @StateObject private var dashboardViewModel: DashboardViewModel
```
and in `init`:
```swift
        _dashboardViewModel = StateObject(wrappedValue: DashboardViewModel(dbQueue: environment.dbQueue))
```
Replace the temporary `.dashboard` case from Task 10:

```swift
                case .dashboard:
                    DashboardView(
                        viewModel: dashboardViewModel, importViewModel: importViewModel,
                        accounts: accounts, selectedImportAccountId: $selectedImportAccountId,
                        profileStore: profileStore, navigate: { selection = $0 }
                    )
                    .onAppear { dashboardViewModel.load() }
```

- [ ] **Step 9: Build** — `xcodegen generate && xcodebuild -project Budget.xcodeproj -scheme Budget -destination 'platform=macOS' build 2>&1 | tail -20` → `** BUILD SUCCEEDED **`. Fix any SwiftUI/Charts signature mismatches while keeping the behavior described in the spec.

- [ ] **Step 10: Commit**

```bash
git add App/Dashboard App/ContentView.swift
git commit -m "Build the Dashboard screen and make it the landing page

Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
```

---

### Task 15: Verification on a copy of the live database

**Files:** none (verification only; fix and commit any defects found, each with its own test where the defect is in BudgetCore logic).

- [ ] **Step 1: Full test suite** — `swift test` → all green (previous 158 plus the new tests).

- [ ] **Step 2: Prepare a copy and launch**

```bash
SCRATCH="$(mktemp -d)"   # use your session scratchpad directory if one is provided
sqlite3 -readonly "$HOME/Library/Application Support/Budget/budget.sqlite" ".backup '$SCRATCH/budget-copy.sqlite'"
BUDGET_DB_PATH="$SCRATCH/budget-copy.sqlite" "<DerivedData path>/Build/Products/Debug/Budget.app/Contents/MacOS/Budget" &
```

(Quit any running Budget app first. If the app is showing the real database, stop.)

- [ ] **Step 3: Existing screens are unchanged (byte-identical refactors)** — open **Forecast**: Dec 2026 headline = **£209,832.70**, Dec 2027 = **£271,292.60** (↑36.4% / ↑29.3%). Open **Budget** and **Net Worth**: spot-check that the per-year net worth change row and totals look as before. Any difference is a defect in Tasks 1–3: fix with a failing test first.

- [ ] **Step 4: Dashboard — today's stale state** — the app opens on **Dashboard**. Check, against the copy of today's data:
  - Freshness card is amber: "Data is 7 months behind", "Last import 23 Sep 2026 (Budget copy.numbers) · transactions through 14 Feb 2026".
  - Net worth card: line chart from **2020** to **Dec 2027** (solid then dashed, "Today" rule at Oct 2026 inside the dashed region); headline £161,340 "as of 1 Feb 2026"; Dec 2026 **£209,833 ↑36.4%**, Dec 2027 **£271,293 ↑29.3%** — identical to the Forecast screen; no "behind" banner.
  - Year-over-year card: bars 2020* … 2027; 2026 two-tone (small realised part, large hatched part); 2027 fully hatched; footnote about 2020.
  - Current month: "October 2026 · day 2 of 31", orange "No October transactions imported yet" note, expected-only rows.
  - Year at a glance: 2026 shows Jan–Feb solid, Mar–Dec hatched; ◀ ▶ step through 2020–2027; a past year is all solid with no "of which actual" lines.
  - Needs attention: stale balances for the accounts, no uncategorized, plus "No catch-all allowance in the forecast…" (nothing designated yet).
  - Upcoming bills and Accounts populated; light **and** dark mode both legible (System Settings → Appearance); resize the window narrow and confirm cards reflow to one column.

- [ ] **Step 5: Catch-all** — Categories → tick **Catch-all** on "Confirmed other expenses": the Needs-attention catch-all item disappears; Forecast still shows its −£171.39/month entry (now **manual**). Untick/tick another expense category to confirm only one can be the catch-all.

- [ ] **Step 6: Import from the dashboard (uses the statement-balances work)** — on the copy, from the dashboard pick **Lloyds Classic** in the account picker (it is `manual`; it must be listed) → **Import CSV…** → `~/Downloads/44116660_20264430_1009.csv`. Expected: the column wizard pre-selects the Lloyds columns; after saving the mapping the app navigates to the **Import** screen with the progress bar; the review screen shows the **Statement balances** panel (8 balances, closing £27,596.28 on 29 Sep 2026). Confirm. Return to **Dashboard** (it reloads on appear):
  - Freshness card: "Up to date", transactions through 29 Sep 2026, last import today.
  - Net worth card: amber banner for the 5 accounts whose balances are older (the statement balance moved Lloyds Classic only); the actual line now runs through Sep 2026; Dec 2026 forecast changed accordingly (this is the documented bookkeeping effect, now flagged rather than silent).
  - Current month: October still "nothing imported yet" (the file ends 29 Sep); Year at a glance 2026 now has Jan–Sep solid, Oct–Dec hatched.
  - Needs attention lists the uncategorized transactions from the import (if any were left uncategorized).
  - The catch-all entry (−£171.39) is still present on the Forecast screen — the import's auto-forecast refresh did not delete it.

- [ ] **Step 7: Clean up** — quit the app, `rm -rf "$SCRATCH"`, then run `swift test` one final time → all green. Report any defect found with its fix commit; if everything passed, no commit is needed for this task.
