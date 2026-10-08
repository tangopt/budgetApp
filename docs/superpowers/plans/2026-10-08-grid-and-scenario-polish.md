# Grid and Scenario Polish Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Forecast-screen fixes (whole-cell differs shading, open new scenario's grid, chart tooltip inside the chart, vertical summary table), "ends after N occurrences" for recurring items, a pinned Year Total column in both grids, and multi-year selection with YoY Δ in the Budget grid.

**Architecture:** Two small pure helpers in BudgetCore (`RecurrenceEnd`, `YearOverYear`) with XCTest; everything else is SwiftUI in `App/`. No schema change.

**Tech Stack:** Swift 6 / SwiftUI + Swift Charts (macOS 26), GRDB 6.29, XCTest, XcodeGen.

**Spec:** `docs/superpowers/specs/2026-10-08-grid-and-scenario-polish-design.md` — read it before any task.

## Global Constraints

- Tests: XCTest, in-memory DB. `swift test --scratch-path /private/tmp/claude-501/-Users-pablo-dimenza-Documents-Code-budget/5fac4f61-c0c9-436b-881b-aebe445aa967/scratchpad/build-gp`. App: `xcodegen generate && xcodebuild -project Budget.xcodeproj -scheme Budget -destination 'platform=macOS' -derivedDataPath /private/tmp/claude-501/-Users-pablo-dimenza-Documents-Code-budget/5fac4f61-c0c9-436b-881b-aebe445aa967/scratchpad/dd-gp build 2>&1 | tail -5`. Never run both at once.
- Horizontal grid scrolling must stay smooth: the scroll offset is observed only by `HorizontalOffsetFollower` (`App/DesignSystem/FrozenHeaderScroll.swift`), never by the grid body.
- Pending styling: `Color.pending`, italic, icons `circle.fill` (all expected) / `circle.lefthalf.filled` (partial) via `PlanCellView`.
- Money inputs use `MoneyField`; dates in UTC calendar like `FrequencyExpander`.
- Commit per task with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`. Never push. Never touch `~/Library/Application Support/Budget`.

---

### Task 1: Forecast screen fixes

**Files:** `App/Forecast/ScenarioGridTab.swift`, `ScenarioListPanel.swift`, `ScenarioLabView.swift`, `ScenarioLabViewModel.swift`, `CompareTab.swift`.

- [ ] **Whole-cell shading:** in `ScenarioGridTab`, apply `Self.differsFill` as the background of the full cell frame (fixed cell width and the row's full height, no inner padding outside the fill) for every cell flagged as differing (month cells and the Year Total if flagged).
- [ ] **Open new scenario's grid:** move the selected tab into `ScenarioLabViewModel` (e.g. `@Published var tab: ScenarioLabView.Tab`) if it isn't there; after a successful create or duplicate, select the new scenario and set `tab = .grid`.
- [ ] **Tooltip:** in `CompareTab`'s readout annotation use `overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))` and give the chart enough top padding (`.chartPlotStyle`/`.padding(.top)`) that the "Today" label is not covered; verify the readout is fully visible when hovering the highest point at a 10-year horizon.
- [ ] **Vertical summary:** rewrite `SummaryTable` as one block per year (header `yearLabel(year)` with the accent background), then a column-header row (`Plan`, `Net worth`, `Δ vs Budget`, `Income`, `Expenses`, `Reserves (unspent)`), then one row per plan (same formatting rules as today: Budget's Δ is "—", positive Δ green with "+", expenses shown negative, reserves "—" when 0). Use a `Grid` per block with flexible columns; no `ScrollView(.horizontal)`.
- [ ] Full suite + app build; commit "Forecast: whole-cell differs shading, new scenario opens its grid, tooltip inside chart, vertical summary".

### Task 2: Ends after N occurrences

**Files:** create `Sources/BudgetCore/Forecasting/RecurrenceEnd.swift`, `Tests/BudgetCoreTests/RecurrenceEndTests.swift`; modify `App/Budget/PlannedItemSheets.swift` (add sheet and edit-occurrence sheet's series fields), plus any other add sheet with "Ends on a specific date" (`ReserveSheets.swift`, `ScenarioGridTab` uses the same sheets).

**Produces:** `RecurrenceEnd.endDate(start: Date, frequency: ForecastFrequency, interval: Int, anchorDay: Int?, occurrences: Int) -> Date` — the date of the Nth occurrence (N ≥ 1; N = 1 or `.once` → `start`), computed with `FrequencyExpander.occurrences` on a temporary unsaved `ForecastEntry` with no end date over a period from `start` long enough to contain N occurrences (take element N−1).

- [ ] **Tests first** (`RecurrenceEndTests`), dates built in UTC:
  - monthly, start 31 Jan 2026, anchorDay 31, N = 3 → 31 Mar 2026; N = 2 → 28 Feb 2026
  - weekly interval 2, start 1 Jan 2026, N = 3 → 29 Jan 2026
  - annually, start 15 Jun 2026, N = 2 → 15 Jun 2027
  - monthly interval 3, start 1 Jan 2026, N = 4 → 1 Oct 2026
  - N = 1 → start; `.once`, N = 5 → start
- [ ] Run, see them fail; implement; run, pass.
- [ ] **Sheets:** replace the "Ends on a specific date" toggle with a segmented `Picker("Ends")` of **Never / On a date / After** ; "After" shows an integer field with stepper (1…999, default 12) and "occurrences", and a live caption "Last: <d MMM yyyy>" from `RecurrenceEnd.endDate`. On save, "After N" passes that date as `endDate`. In the edit-occurrence sheet the count starts from the edited occurrence's date (that's the new series' start for "this and all following"); prefill: existing `endDate` → "On a date", none → "Never". A frequency/end change still only offers "This and all following".
- [ ] Full suite + app build; commit "Recurring items can end after N occurrences".

### Task 3: Pinned Year Total column (Budget and Forecast grids)

**Files:** `App/Budget/BudgetGridView.swift`, `App/Forecast/ScenarioGridTab.swift`, `App/DesignSystem/FrozenHeaderScroll.swift` if a shared piece helps.

- [ ] Restructure each grid so the layout is: pinned left category column | horizontally scrolling month columns | pinned right Year Total column. Header row (month names + "Year Total") stays aligned with the body using the existing follower technique; vertical scrolling moves all three together (single vertical `ScrollView` containing an `HStack` of left column, horizontal month scroller, right column — rows must share heights; use fixed row heights as the grid already does).
- [ ] Year Total keeps its current behaviours (pending styling, help text, click opens the year drill-down, balances show December value, differs shading in the scenario grid).
- [ ] Footnotes/legends unchanged. Check smooth scrolling is preserved (offset not read in the grid body).
- [ ] Full suite + app build; commit "Grids: Year Total column pinned on the right".

### Task 4: Budget grid multi-year selection with YoY

**Files:** create `Sources/BudgetCore/Budget/YearOverYear.swift`, `Tests/BudgetCoreTests/YearOverYearTests.swift`; modify `App/Budget/BudgetGridViewModel.swift`, `BudgetGridView.swift`.

**Produces:**
```swift
public enum YearOverYear {
    /// current − previous, and the change as a fraction of |previous| (nil when previous is 0).
    public static func delta(current: Int, previous: Int) -> (amount: Int, fraction: Double?)
    /// Whether the change is good for a line of this type: expenses (negative values) improve when
    /// less negative, income when higher; transfers/balances return nil (neutral).
    public static func isImprovement(amount: Int, categoryType: CategoryType?) -> Bool?
}
```
- [ ] **Tests first:** delta(1200, 1000) → (200, 0.2); delta(−900, −1000) → (100, 0.1) (fraction = amount / |previous|); delta(500, 0) → (500, nil); delta(0, 0) → (0, nil); isImprovement(100, .expense) → true; (−100, .expense) → false; (100, .income) → true; (100, .transfer) → nil; (0, .expense) → nil.
- [ ] Implement; pass.
- [ ] **View model:** `selectedYears: [Int]` (sorted, non-empty) replacing/backing `selectedYear` (`selectedYear` = the single year when count == 1, else nil, so existing month code paths stay); `toggleYear(_:)` for ⌘-click (never empties), `selectYear(_:)` for click. Per-line year totals reuse the existing Year Total computation for each selected year.
- [ ] **View:** year picker: click → `selectYear`, ⌘-click (`NSEvent.modifierFlags.contains(.command)` in the tap, or `.simultaneousGesture` with modifiers) → `toggleYear`; selected years highlighted. When several years are selected the grid's scrolling area shows, per selected year, a "<year>" total column and, for each year after the first, "Δ vs <prev>" (signed £, green/red by `isImprovement`, secondary when nil) and "%" (one decimal, "—" when nil). Section/group/category/reserve/total/balance rows all get them (balances use year-end values). Pending styling and click-to-drill-down on year totals as in the Year Total column. The pinned Year Total column from Task 3 is hidden in multi-year mode.
- [ ] Full suite + app build; commit "Budget grid: select several years with year-over-year change".

### Task 5: Check and merge (controller)

- [ ] On a DB copy: screenshots of the multi-year grid, pinned Year Total while scrolled, vertical summary, tooltip at top. Final review, one fix wave, merge to main, push.
