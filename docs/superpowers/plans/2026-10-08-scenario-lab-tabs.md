# Scenario Lab Tabs Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the Forecast left panel with per-tab scenario chip rows, make Differences a multi-scenario side-by-side table with Edit…/Revert, and let an empty grid cell add a planned item (Budget grid and scenario grid).

**Architecture:** BudgetCore gains `Scenarios.revert` and a pure `DifferenceMatrix` builder (XCTest); the rest is SwiftUI in `App/Forecast` and `App/Budget`, reusing existing sheets and operations.

**Tech Stack:** Swift 6 / SwiftUI (macOS 26), GRDB 6.29, XCTest, XcodeGen.

**Spec:** `docs/superpowers/specs/2026-10-08-scenario-lab-tabs-design.md` — read it before any task.

## Global Constraints

- Tests: XCTest, in-memory DB. `swift test --scratch-path /private/tmp/claude-501/-Users-pablo-dimenza-Documents-Code-budget/5fac4f61-c0c9-436b-881b-aebe445aa967/scratchpad/build-lt`. App: `xcodegen generate && xcodebuild -project Budget.xcodeproj -scheme Budget -destination 'platform=macOS' -derivedDataPath /private/tmp/claude-501/-Users-pablo-dimenza-Documents-Code-budget/5fac4f61-c0c9-436b-881b-aebe445aa967/scratchpad/dd-lt build 2>&1 | tail -5`. Never both at once.
- Budget entries have `scenarioId IS NULL` and load via `ForecastEntry.budget(db)`; scenario entries via `ForecastEntry.inScenario`. Scenario copies: `sourceEntryId` set, `scenarioChange` NULL; markers added/changed/removed.
- Plan colours: `PlanPalette.color(index)`, Budget = index 0; scenarios keep their current colour assignment.
- Horizontal grid scrolling must stay smooth: the scroll offset is observed only by `HorizontalOffsetFollower`, widths only by `BodyWidthFollower`; shared sizes in `GridMetrics` (App/DesignSystem/FrozenHeaderScroll.swift).
- Money inputs `MoneyField`; pending styling via `PlanCellView`.
- Commit per task with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`. Never push. Never touch `~/Library/Application Support/Budget`.

---

### Task 1: BudgetCore — revert and difference matrix

**Files:** modify `Sources/BudgetCore/Forecasting/Scenarios.swift` (revert; `ScenarioDifference` gains `sourceEntryId: Int64?` and `sourceSummary: String?`, filled by `differences`), create `Sources/BudgetCore/Forecasting/DifferenceMatrix.swift`; tests in `Tests/BudgetCoreTests/ScenariosTests.swift` and new `DifferenceMatrixTests.swift`.

**Produces:**
```swift
extension Scenarios {
    /// Puts one scenario item back to the budget's version (see spec "Editing and reverting").
    public static func revert(db: Database, scenarioId: Int64, entryId: Int64) throws
}
public struct DifferenceMatrix {
    public struct Row: Identifiable, Equatable {
        public var id: String              // "source-<budgetEntryId>" or "added-<scenarioId>-<entryId>"
        public var categoryName: String
        public var isAdded: Bool
        public var budgetSummary: String?  // nil for added rows
        public var cells: [Int64: ScenarioDifference] // scenarioId → that scenario's difference
    }
    /// `differences` in the scenarios' display order. Rows: one per budget source id (changed/removed
    /// across scenarios merged), one per added entry; sorted by categoryName, then id.
    public static func rows(differences: [(scenarioId: Int64, differences: [ScenarioDifference])]) -> [Row]
}
```
- [ ] Tests first: revert added → entry gone, others untouched; revert changed (with an exception on the source) → scenario has a fresh unchanged copy (`scenarioChange == nil`, `sourceEntryId` = source, same fields and exceptions as the budget entry); revert removed tombstone → copy back, enabled; revert when source deleted → scenario entry just deleted; revert only touches the given scenario. Matrix: two scenarios changing the same budget item → one row with two cells and `budgetSummary` = source summary; an added entry → own row, only its scenario's cell; sort by category name; `sourceEntryId`/`sourceSummary` populated by `differences` for changed/removed, nil for added.
- [ ] Implement (revert in one transaction; reuse the copy helper used by create/refresh); full suite + app build; commit "Scenario revert and difference matrix".

### Task 2: Forecast layout — chip rows, per-tab selection, Compare and Grid tabs

**Files:** create `App/Forecast/ScenarioChips.swift`; modify `ScenarioLabView.swift`, `ScenarioLabViewModel.swift`, `CompareTab.swift`, `ScenarioGridTab.swift`; delete `ScenarioListPanel.swift` (move its name sheet / delete alert / refresh report into `ScenarioChips.swift` or a small `ScenarioManagement.swift`).

- [ ] `ScenarioChips(mode:)` with modes `.multi(selected: Binding<Set<Int64>>)` (Budget chip shown selected, not toggleable) and `.single(selected: Binding<Int64?>)` (nil = Budget). Chip: colour dot + name, selected style filled with a tint of the plan colour + border. Right-click menu on scenario chips: Rename…, Duplicate…, Refresh from budget (report alert), Delete… (confirm). Trailing "+ New scenario" chip. Horizontal scroll if they overflow.
- [ ] View model: `compareSelection: Set<Int64>`, `differencesSelection: Set<Int64>`, `gridSelection: Int64?` (replace the old single selection + compare flags); create/duplicate inserts the new id into both sets, sets `gridSelection`, `tab = .grid`; delete removes it everywhere. Comparison inputs use `compareSelection`; grid uses `gridSelection`.
- [ ] Layout: no left panel; tab picker + horizon picker in the top bar; each tab shows its chip row under it.
- [ ] Grid tab: header bar in the selected plan's colour ("Editing **<name>**" / "Budget — read-only, edit it in the Budget grid"); differs shading uses the selected scenario's colour (light tint) and the legend swatch follows.
- [ ] Full suite + app build; commit "Forecast: per-tab scenario chips replace the left panel".

### Task 3: Differences tab — side-by-side, Edit…, Revert

**Files:** rewrite `App/Forecast/DifferencesTab.swift`; modify `ScenarioLabViewModel.swift` (matrix load, ticks, apply grouped, undo per scenario, edit target, revert).

**Consumes:** `DifferenceMatrix.rows`, `Scenarios.revert`, `ScenarioApply.apply/undoLast/canUndo/appliedDifferenceIds`, existing edit-occurrence sheet (`App/Budget/PlannedItemSheets.swift`) used by the scenario grid.

- [ ] Table: Category column + Budget column + one column per `differencesSelection` scenario (header colour dot + name, tinted). Cells per spec (summary, field changes for changed, "Removed", "—"; differing cells lightly tinted in the scenario colour; "Applied" badge where applied).
- [ ] Differing, not-applied cells: tick box (ticking unticks the row's other cells), Edit… (added/changed only, when the entry has an occurrence in an open pay month: opens the edit-occurrence sheet on that first open occurrence with scope fixed to "This and all following"), Revert (confirmation text from the spec → `Scenarios.revert`).
- [ ] "Apply to budget…" confirmation lists ticked cells grouped by scenario; applies all in one write transaction (call `ScenarioApply.apply` per scenario inside one `write`); "Undo last apply" menu lists ticked scenarios where `canUndo`.
- [ ] Reload differences, comparison and grid after edit/revert/apply/undo. Full suite + app build; commit "Differences: side-by-side scenarios with edit and revert".

### Task 4: Click an empty cell to add

**Files:** `App/Budget/BudgetGridView.swift`, `App/Forecast/ScenarioGridTab.swift`, `App/Budget/PlannedItemSheets.swift` / `ReserveSheets.swift` (optional initial category and date).

- [ ] Add-sheet inputs: optional initial category id and initial date (defaults unchanged).
- [ ] Empty category cell (no actual, nothing planned) in an open or future pay month → Add planned item, category preselected, one-off, date = today if that month is the current month else the 1st. Empty reserve cell in an open/future month → reserve Add amount for that reserve, that month's date. Closed months, section/group/total/balance rows: no action. Non-empty cells unchanged (drill-down).
- [ ] Scenario grid: same, only when a scenario is selected (adds to the scenario); Budget selection read-only.
- [ ] Full suite + app build; commit "Click an empty cell to add a planned item".

### Task 5: Final review, merge (controller)

- [ ] Final whole-branch review, one fix wave, merge to main, `xcodegen generate` + xcodebuild in the main checkout, push.
