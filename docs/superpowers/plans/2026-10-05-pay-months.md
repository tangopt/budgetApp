# Pay Months Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Every "month" of actual money flows becomes a pay month (day after the previous salary → the salary date, inclusive), months close on salary import or by hand, and a closed month releases its leftover reserve.

**Architecture:** One BudgetCore value, `PayCalendar`, owns month boundaries, closed/open state and month class. A pay-month totals lookup with the same shape as today's calendar lookup replaces it at every call site, so screens change mostly by swapping the lookup and the classifier. Forecast amounts keep using calendar months (`MonthRange`).

**Tech Stack:** Swift 6 / SwiftUI (macOS 26), GRDB 6.29, XCTest, XcodeGen.

**Spec:** `docs/superpowers/specs/2026-10-05-pay-months-design.md` — read it before starting any task.

## Global Constraints

- Pay month *M* = start of the day after close(*M−1*) … last moment of close(*M*)'s day, UTC. close(*M*) = manual close for *M*, else the imported salary dated in calendar month *M*, else projected (day-of-month of the latest salary on or before *M*, else the first salary's day, clamped to *M*'s length); no salaries at all → last day of calendar month *M*.
- Salary dates: `PaydaySource.paydayDates(transactions:categories:)` / `paydayDates(db:)`, collapsed with `PayPeriodDetector.paydayAnchors` (dates < 20 days apart collapse to the first). If two anchors still fall in one calendar month (e.g. the 1st and the 28th), the later one is that month's salary.
- Closed = manual close or imported salary. Month class: closed → `.actual`; open and start ≤ today → `.blended`; open and start > today → `.forecast`.
- Expected/forecast amounts for month *M* always use the **calendar** month `MonthRange.of(year:month:)`. Actual amounts always use the **pay** month.
- Reserves: closed → 0; open → `ReservedCategories.remainingAllowances` with that pay month's unforecast spend; forecast-class months have no actuals so the full allowance.
- Balances, net worth points, accounts, upcoming bills, freshness: unchanged (calendar dates).
- Money is signed `Int` minor units; Dashboard flow figures are positive magnitudes.
- Tests: XCTest in `Tests/BudgetCoreTests/`, in-memory DB `let m = try DatabaseManager(path: nil); try m.migrate()`. Use bare `Category` (add `import struct BudgetCore.Category` if ambiguous). Run outside iCloud: `swift test --scratch-path /private/tmp/claude-501/-Users-pablo-dimenza-Documents-Code-budget/5fac4f61-c0c9-436b-881b-aebe445aa967/scratchpad/build-pm` (`--filter X` while iterating). App build: `xcodegen generate && xcodebuild -project Budget.xcodeproj -scheme Budget -destination 'platform=macOS' -derivedDataPath /private/tmp/claude-501/-Users-pablo-dimenza-Documents-Code-budget/5fac4f61-c0c9-436b-881b-aebe445aa967/scratchpad/dd-pm build 2>&1 | tail -5` → `** BUILD SUCCEEDED **`. Never run both at once.
- New migrations are appended at the end of `DatabaseManager.registerMigrations`.
- Commit after every task; message ends with the author's Co-Authored-By line. Never push. Never touch `~/Library/Application Support/Budget`.
- `DashboardFixture` has no category named "Income", so it has no salaries: its pay months equal calendar months and existing dashboard tests keep their expectations.

---

### Task 1: `PayMonth`, `PayMonthClose`, `PayCalendar`, `PayMonthTotals`

**Files:**
- Create: `Sources/BudgetCore/PayPeriods/PayCalendar.swift`, `Sources/BudgetCore/Models/PayMonthClose.swift`
- Modify: `Sources/BudgetCore/Database/DatabaseManager.swift`
- Test: `Tests/BudgetCoreTests/PayCalendarTests.swift`

**Interfaces — Produces:**
- `public struct PayMonth: Hashable, Comparable, Codable { year: Int; month: Int; init(year:month:); var previous: PayMonth; var next: PayMonth }`
- `public struct PayMonthClose: Codable, Equatable, Identifiable, FetchableRecord, MutablePersistableRecord { id: Int64?; year: Int; month: Int; closeDate: Date }` (table `payMonthClose`, unique `(year, month)`)
- `public enum PayCloseSource: Equatable { case manual, salary, projected }`
- `public enum PayCalendarError: Error, Equatable { case invalidCloseDate }`
- `public struct PayCalendar`:
  - `init(salaryDates: [Date], manualCloses: [PayMonthClose], today: Date)`
  - `static func load(db: Database, today: Date) throws -> PayCalendar`
  - `let today: Date`
  - `func closeDate(of: PayMonth) -> Date` (start of that day), `func closeSource(of: PayMonth) -> PayCloseSource`
  - `func range(of: PayMonth) -> (start: Date, end: Date)`
  - `func month(containing: Date) -> PayMonth`
  - `func isClosed(_: PayMonth) -> Bool`, `func monthClass(_: PayMonth) -> MonthClass`, `var current: PayMonth`
  - `func validateClose(_ month: PayMonth, on date: Date) throws`
  - `static func close(db: Database, month: PayMonth, on date: Date, today: Date) throws` (validates against `load(db:today:)`, then upserts), `static func reopen(db: Database, month: PayMonth) throws` (deletes the manual close)
- `public enum PayMonthTotals { static func lookup(transactions: [Transaction], calendar: PayCalendar) -> [Int64: [Int: [Int: Int]]] }` — confirmed, categorised only; keyed `[categoryId][year][month]` of `calendar.month(containing: date)`.

- [ ] **Step 1: Write the failing tests** (`PayCalendarTests.swift`). Helper `d(y,m,day)` = UTC start of day; `s(y,m,day)` = 12:00 that day. Cover:
  1. Salaries 15 Sep 2026, 15 Oct 2026: `range(of: Oct 2026)` = 16 Sep 00:00 … 15 Oct 23:59:59; `month(containing: s(2026,9,15)) == Sep`, `(2026,9,16) == Oct`, `(2026,10,15) == Oct`, `(2026,10,16) == Nov`.
  2. Projection: only salary 14 Feb 2026 → close(Mar 2026) = 14 Mar; salary on 31 Jan → close(Feb 2026) = 28 Feb, close(Feb 2028) = 29 Feb.
  3. Months before the first salary use the first salary's day; no salaries → `range(of: Mar 2026)` = 1 Mar … 31 Mar (calendar month).
  4. Manual close for a projected month: closes 10 Oct for Oct with no Oct salary → `isClosed(Oct)`, `closeSource == .manual`, Nov starts 11 Oct.
  5. Manual close overrides a salary in the same month (`closeSource == .manual`).
  6. `isClosed`: salary-closed true; projected false. `monthClass`: today 5 Oct 2026 with salaries Sep 15 → Sep `.actual`, Oct `.blended` (open, started 16 Sep), Nov `.forecast`; with salaries only up to Feb 2026 → Mar…Oct `.blended`, Nov `.forecast`; `current == Oct`.
  7. `validateClose`: a date before the month's start throws `.invalidCloseDate`; a date on/after close(*M+1*) when *M+1* is closed throws; a valid date passes.
  8. `close(db:…)` inserts, a second close for the same month replaces it (one row), `reopen` deletes it; `load(db:today:)` reads salaries (category "Income") and closes.
  9. `PayMonthTotals.lookup`: a payday-dated expense counts in the month its salary closes; the next day in the following month; unreviewed (`categoryId == nil` or `.pendingReview`) excluded.
  10. Two salary-sized credits 5 days apart in one month → one salary: the first (`PayPeriodDetector.paydayAnchors` collapses dates < 20 days apart and keeps the first).

- [ ] **Step 2: Run to verify they fail** — `swift test --scratch-path … --filter PayCalendarTests` → "cannot find 'PayCalendar'".

- [ ] **Step 3: Implement.** `PayMonthClose.swift` (model + `registerPayMonthCloseMigration` creating `payMonthClose` with `id`, `year`, `month`, `closeDate`, unique index on `(year, month)`; register last in `DatabaseManager`). `PayCalendar.swift`:

```swift
// Sources/BudgetCore/PayPeriods/PayCalendar.swift
import Foundation
import GRDB

/// A month as the spreadsheet meant it: from the day after the previous month's salary up
/// to and including this month's salary date (spec: 2026-10-05-pay-months-design.md).
public struct PayMonth: Hashable, Comparable, Codable {
    public let year: Int
    public let month: Int
    public init(year: Int, month: Int) { self.year = year; self.month = month }
    var index: Int { year * 12 + (month - 1) }
    init(index: Int) { self.init(year: Int((Double(index) / 12).rounded(.down)), month: ((index % 12) + 12) % 12 + 1) }
    public var previous: PayMonth { PayMonth(index: index - 1) }
    public var next: PayMonth { PayMonth(index: index + 1) }
    public static func < (a: PayMonth, b: PayMonth) -> Bool { a.index < b.index }
}

public enum PayCloseSource: Equatable { case manual, salary, projected }
public enum PayCalendarError: Error, Equatable { case invalidCloseDate }

public struct PayCalendar {
    public let today: Date
    private let salaryByMonth: [PayMonth: Date]   // start of day
    private let manualByMonth: [PayMonth: Date]   // start of day
    private let salaryMonthsSorted: [PayMonth]

    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    public init(salaryDates: [Date], manualCloses: [PayMonthClose], today: Date) {
        let cal = Self.calendar
        var salaries: [PayMonth: Date] = [:]
        for date in PayPeriodDetector.paydayAnchors(salaryDates) {
            let day = cal.startOfDay(for: date)
            let parts = cal.dateComponents([.year, .month], from: day)
            let month = PayMonth(year: parts.year!, month: parts.month!)
            salaries[month] = max(salaries[month] ?? day, day) // the later salary wins within a month
        }
        var manual: [PayMonth: Date] = [:]
        for close in manualCloses { manual[PayMonth(year: close.year, month: close.month)] = cal.startOfDay(for: close.closeDate) }
        self.salaryByMonth = salaries
        self.manualByMonth = manual
        self.salaryMonthsSorted = salaries.keys.sorted()
        self.today = today
    }

    public static func load(db: Database, today: Date) throws -> PayCalendar {
        PayCalendar(salaryDates: try PaydaySource.paydayDates(db: db), manualCloses: try PayMonthClose.fetchAll(db), today: today)
    }

    public func closeSource(of month: PayMonth) -> PayCloseSource {
        if manualByMonth[month] != nil { return .manual }
        if salaryByMonth[month] != nil { return .salary }
        return .projected
    }

    public func closeDate(of month: PayMonth) -> Date {
        if let manual = manualByMonth[month] { return manual }
        if let salary = salaryByMonth[month] { return salary }
        let cal = Self.calendar
        let first = cal.date(from: DateComponents(year: month.year, month: month.month, day: 1))!
        let length = cal.range(of: .day, in: .month, for: first)!.count
        guard let reference = salaryMonthsSorted.last(where: { $0 <= month }) ?? salaryMonthsSorted.first else {
            return cal.date(byAdding: .day, value: length - 1, to: first)!
        }
        let day = min(cal.component(.day, from: salaryByMonth[reference]!), length)
        return cal.date(byAdding: .day, value: day - 1, to: first)!
    }

    public func range(of month: PayMonth) -> (start: Date, end: Date) {
        let cal = Self.calendar
        let start = cal.date(byAdding: .day, value: 1, to: closeDate(of: month.previous))!
        let end = cal.date(byAdding: .day, value: 1, to: closeDate(of: month))!.addingTimeInterval(-1)
        return (start, end)
    }

    public func month(containing date: Date) -> PayMonth {
        let parts = Self.calendar.dateComponents([.year, .month], from: date)
        var month = PayMonth(year: parts.year!, month: parts.month!)
        while date > range(of: month).end { month = month.next }
        while date < range(of: month).start { month = month.previous }
        return month
    }

    public func isClosed(_ month: PayMonth) -> Bool { closeSource(of: month) != .projected }

    public func monthClass(_ month: PayMonth) -> MonthClass {
        if isClosed(month) { return .actual }
        return range(of: month).start <= today ? .blended : .forecast
    }

    public var current: PayMonth { month(containing: today) }

    public func validateClose(_ month: PayMonth, on date: Date) throws {
        let day = Self.calendar.startOfDay(for: date)
        guard day >= Self.calendar.startOfDay(for: range(of: month).start) else { throw PayCalendarError.invalidCloseDate }
        if isClosed(month.next), day >= closeDate(of: month.next) { throw PayCalendarError.invalidCloseDate }
    }

    public static func close(db: Database, month: PayMonth, on date: Date, today: Date) throws {
        try load(db: db, today: today).validateClose(month, on: date)
        try PayMonthClose.filter(Column("year") == month.year && Column("month") == month.month).deleteAll(db)
        var close = PayMonthClose(year: month.year, month: month.month, closeDate: calendar.startOfDay(for: date))
        try close.insert(db)
    }

    public static func reopen(db: Database, month: PayMonth) throws {
        try PayMonthClose.filter(Column("year") == month.year && Column("month") == month.month).deleteAll(db)
    }
}

public enum PayMonthTotals {
    /// Confirmed, categorised transactions summed per category per pay month — the same shape
    /// as the old calendar lookup, so every reader just swaps the builder.
    public static func lookup(transactions: [Transaction], calendar: PayCalendar) -> [Int64: [Int: [Int: Int]]] {
        var result: [Int64: [Int: [Int: Int]]] = [:]
        for transaction in transactions {
            guard transaction.status == .confirmed, let categoryId = transaction.categoryId else { continue }
            let month = calendar.month(containing: transaction.date)
            result[categoryId, default: [:]][month.year, default: [:]][month.month, default: 0] += transaction.amountMinorUnits
        }
        return result
    }
}
```

  Check `PaydaySource.paydayDates(db:)`'s real signature and `PayPeriodDetector.paydayAnchors` visibility before relying on them. Performance: `month(containing:)` is called once per transaction (1.6k+); `range(of:)` is cheap, but if the full suite or app load slows noticeably, memoise `closeDate(of:)` in a dictionary built lazily — note it in the report.

- [ ] **Step 4: Verify** — `--filter PayCalendarTests` PASS; full suite green; app build succeeds.
- [ ] **Step 5: Commit** — "Add PayCalendar: pay months, manual closes and pay-month totals".

---

### Task 2: Dashboard on pay months

**Files:** `Sources/BudgetCore/Dashboard/DashboardInput.swift`, `DashboardCalculator.swift`, `DashboardCalculator+Flows.swift`, `DashboardCalculator+NetWorth.swift`, `MonthBlend.swift`; `Sources/BudgetCore/Forecasting/ReservedCategories.swift`; `App/Dashboard/DashboardViewModel.swift`, `App/Dashboard/CurrentMonthCard.swift`; tests `DashboardFixture.swift`, `DashboardFlowTests.swift`, `DashboardCalculatorTests.swift`, `MonthBlendTests.swift`.

**Interfaces:**
- Consumes (Task 1): `PayCalendar`, `PayMonth`, `PayMonthTotals.lookup`, `PayMonthClose`.
- Produces:
  - `DashboardInput.init(... , rate:, manualCloses: [PayMonthClose] = [])`; `public let payCalendar: PayCalendar` built from `PaydaySource.paydayDates(transactions:categories:)`, `manualCloses`, `effectiveToday`; internal `monthTotals` (renamed from `calendarTotals`) = `PayMonthTotals.lookup`.
  - `CurrentMonthTracking` gains `start: Date`, `end: Date`, `hasTransactions: Bool`; `dayOfMonth`/`daysInMonth` become day-of-pay-month / pay-month length.
  - `ReservedCategories.unforecastSpend(year:month:categories:monthTotals:entries:groups:)` — parameter renamed from `calendarTotals`; reads pay-month actuals; the "nothing forecast" test still uses the **calendar** month `MonthRange.of(year:month:)`.
  - `MonthBlend.classify` is deleted (with its tests); `MonthBlend.projectedTotal` stays.

- [ ] **Step 1: Failing tests** (DashboardFlowTests, using a fixture extension `F.input(..., categoriesExtra:)` or a local input that adds an "Income" category with salaries): (a) salaries 15 Sep and the 15th of earlier months, today 5 Oct → `currentMonth` is October, `start` 16 Sep, `end` 15 Oct 23:59:59, `dayOfMonth` 20, `daysInMonth` 30; a groceries txn on 15 Sep counts in September's flow, one on 16 Sep in October's; (b) reserve released: a −£2,000 reserve, salaries through Sep → September (closed) `reservedRemaining == 0` and not counted in `expenseRemaining`; October (open, current) reserve = what's left; November = 200_000; (c) open past month (salaries only up to Feb, today Oct): March is `.blended` and keeps its reserve; (d) a manual close for October passed via `manualCloses` closes it (October `.actual`, reserve 0). Existing tests (no salaries → calendar months) must pass unchanged except `MonthBlendTests.classify` cases, which are deleted.
- [ ] **Step 2: Run** → fail.
- [ ] **Step 3: Implement.**
  - `categoryAmounts`/`monthTotals`/`monthlyFlows`/`topCategories`/`currentMonth`: month class = `input.payCalendar.monthClass(PayMonth(year:month:))`; actuals from `input.monthTotals`; expected from the calendar month (unchanged); reserves: closed → none counted (`.actual` already skips them), else `remainingReserves` with `unforecastSpend(… monthTotals: input.monthTotals …)`.
  - `currentMonth`: `let month = input.payCalendar.current`, range from `range(of:)`, `dayOfMonth` = whole days from `start` to `effectiveToday` + 1, `daysInMonth` = days in range, `hasTransactions` = any confirmed or unreviewed transaction in range; unreviewed footnote uses the pay range. `topCategories` uses `current` too. `unreviewed(_:year:)` covers the pay year (Jan pay month start … Dec pay month end). `attentionItems`' reserve check uses the calendar month named by `current`.
  - `netWorthSeries`: the forecast walk starts after `payCalendar.month(containing: dataThrough)` instead of the calendar data month; actual points unchanged.
  - `DashboardViewModel.load()`: read `PayMonthClose.fetchAll(db)` and pass `manualCloses:`.
  - `CurrentMonthCard`: header `"\(monthName) · \(DashboardFormat.day(start))–\(DashboardFormat.day(end)) · day \(dayOfMonth) of \(daysInMonth)"`; `hasActuals` = `month.hasTransactions` (was `monthClass == .blended`). (The Close button comes in Task 4.)
- [ ] **Step 4: Verify** — dashboard tests + full suite green; app build.
- [ ] **Step 5: Commit** — "Dashboard: pay months, month classes from PayCalendar".

---

### Task 3: Forecast grid on pay months

**Files:** `App/Forecast/ForecastViewModel.swift`, `App/Forecast/ForecastView.swift`.

**Interfaces — Consumes:** `PayCalendar`, `PayMonthTotals.lookup`, `ReservedCategories.unforecastSpend(... monthTotals: ...)`, `MonthBlend.projectedTotal`.

- [ ] **Step 1: Implement.**
  - `load()`: build `payCalendar = PayCalendar(salaryDates: PaydaySource.paydayDates(transactions:categories:), manualCloses: PayMonthClose.fetchAll(db), today: Date())`; `monthTotals = PayMonthTotals.lookup(...)` (replacing `calendarTotals`; rebuild in the same places).
  - `latestRealMonth` = `payCalendar.month(containing: latestTransactionDate)`.
  - Replace `isActual(year:month:)` with `monthClass(year:month:) -> MonthClass` from the calendar. Keep an `isActual` helper (`== .actual`) only if callers still need it (net-worth baseline: use `payCalendar.isClosed(December of year-1)`).
  - `categoryTotal`: `.actual` → pay-month actual; `.blended` → `MonthBlend.projectedTotal(actual: payActual, expected: forecastValue(preview: false), categoryType:, monthClass: .blended)`; `.forecast` → `forecastValue(preview: false)`. `previewCategoryTotal`: same with `preview: true` (and `.actual` → actual).
  - Reserves: closed → 0; otherwise remaining via `computeRemainingReserves` using `monthTotals`. Remove every `ReservedCategories.countsAllowance` call.
  - `ForecastView` month column headers: `.help("\(day(start)) – \(day(end))")` from `viewModel.payCalendar.range(of:)`.
- [ ] **Step 2: Verify** — app build; full suite green. Report what October 2026 and March 2026 cells now show for a category with a forecast and actuals, reasoning from the code.
- [ ] **Step 3: Commit** — "Forecast grid: pay-month actuals and blended open months".

---

### Task 4: Budget grid on pay months; close/reopen UI; cleanup

**Files:** `App/Budget/BudgetGridViewModel.swift`, `App/Budget/BudgetGridView.swift`, `App/Dashboard/CurrentMonthCard.swift`, `App/Dashboard/DashboardView.swift`, new `App/Shared/CloseMonthView.swift`; `Sources/BudgetCore/Budget/BudgetGridCalculator.swift`, `Sources/BudgetCore/Forecasting/ReservedCategories.swift`; tests touching removed APIs.

**Interfaces — Consumes:** `PayCalendar.close(db:month:on:today:)`, `reopen(db:month:)`, `closeSource(of:)`, `range(of:)`, `isClosed`.

- [ ] **Step 1: Budget grid VM.** Build `payCalendar` in `load()` (as Task 3); `monthTotals` replaces `calendarTotals`; `calendarCategoryTotal` → `payMonthCategoryTotal` (rename call sites); `dateRange(forYear:month:)` → `payCalendar.range(of:)` (drill-down then lists the pay month's transactions); `availableYears` = years of `payCalendar.month(containing:)` over transactions; `reserveTotal`: closed → 0, else remaining using `monthTotals`. Add `func closeMonth(_ month: PayMonth, on date: Date) -> Bool` and `func reopenMonth(_ month: PayMonth) -> Bool` (write via `PayCalendar.close`/`reopen`, then reload; map `PayCalendarError.invalidCloseDate` to "Pick a date inside <Month> (from <start>)." in `errorMessage`).
- [ ] **Step 2: Budget grid view.** Month column header: `.help("<start> – <end>")`, plus a context menu: open month → "Close month…" (opens `CloseMonthView`); `.manual` → "Reopen"; `.salary` → a disabled "Closed by salary on <date>".
- [ ] **Step 3: `CloseMonthView`** (shared): title "Close <Month Year>", the current range, a `DatePicker` (default: `min(today, projected close)` for open months), caption "Spending after this date counts in <next month>.", inline error text, Cancel / Close month. Calls a closure returning `Bool`; dismisses on success.
- [ ] **Step 4: Dashboard.** `CurrentMonthCard` gets a "Close month…" button opening `CloseMonthView` for `currentMonth`; `DashboardViewModel` gains `closeMonth(_:on:) -> Bool` (write, reload) and passes errors inline.
- [ ] **Step 5: Cleanup.** Delete `ReservedCategories.countsAllowance` (and its test), `BudgetGridCalculator.calendarTotalsLookup` / `categoryTotalForCalendarMonth` if no callers remain (grep). `grep -rn "countsAllowance\|calendarTotals\|MonthBlend.classify" Sources App Tests` → no hits.
- [ ] **Step 6: Verify** — full suite green; app build.
- [ ] **Step 7: Commit** — "Budget grid on pay months; close and reopen months".

---

### Task 5: Real-data check (controller)

- [ ] Copy the real DB to the scratchpad; with a small `swift` script or `sqlite3`, confirm every historical calendar month's transactions lie inside the same-named pay month (all dated on that month's salary date) → per-month totals unchanged.
- [ ] Launch the built app on the copy (`open -n --env BUDGET_DB_PATH=<copy> <app>`); check Dashboard current month = October (16 Sep–15 Oct), reserve, Budget grid headers/tooltips/close menu, Forecast grid. Screenshots if the screen is unlocked.
- [ ] Final whole-branch review, fixes, merge to local `main`.
