# Scenario Lab Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the Forecast screen's hypothetical-group scenarios with a scenario lab: scenarios as refreshable copies of the budget, edited with the project-1 editors, compared (net worth lines, yearly table, differences, grid) over a chosen horizon, and applied to the budget with undo.

**Architecture:** Scenario items are `ForecastEntry` rows tagged with `scenarioId` (budget rows have NULL), so every calculator works unchanged on a scenario's own entries; operations (`Scenarios`, `ScenarioApply`) and the pure `ScenarioComparison` live in BudgetCore with tests; the Forecast screen is rebuilt on top.

**Tech Stack:** Swift 6 / SwiftUI + Swift Charts (macOS 26), GRDB 6.29, XCTest, XcodeGen.

**Spec:** `docs/superpowers/specs/2026-10-08-scenario-lab-design.md` — read it before any task.

## Global Constraints

- Budget entries: `scenarioId IS NULL`; every budget load uses `ForecastEntry.budget(db)`; `ForecastCalculator.confirmedEntries` excludes scenario entries. A scenario's effective plan is its own entries (enabled, not `removed`) in enabled groups, evaluated with the same calculators.
- `scenarioChange`: NULL unchanged copy, `added`, `changed`, `removed` (tombstone, disabled).
- Forecast amounts belong to the calendar month named on them; actuals to pay months (`PayCalendar`, `PayMonthTotals`); month classes from `PayCalendar.monthClass`.
- Apply boundary: the current pay month (`payCalendar.current`); applied items are ordinary unconfirmed planned items; only the latest un-undone application per scenario can be undone.
- Horizon options: end of this year, 2, 5, 10 years (default 2).
- Money inputs use `MoneyField`; money signed minor units.
- Tests: XCTest, in-memory DB, bare `Category`. `swift test --scratch-path /private/tmp/claude-501/-Users-pablo-dimenza-Documents-Code-budget/5fac4f61-c0c9-436b-881b-aebe445aa967/scratchpad/build-sl`. App: `xcodegen generate && xcodebuild -project Budget.xcodeproj -scheme Budget -destination 'platform=macOS' -derivedDataPath /private/tmp/claude-501/-Users-pablo-dimenza-Documents-Code-budget/5fac4f61-c0c9-436b-881b-aebe445aa967/scratchpad/dd-sl build 2>&1 | tail -5`. Never both at once.
- Migrations appended last. Commit per task (author's Co-Authored-By). Never push. Never touch `~/Library/Application Support/Budget`.

---

### Task 1: Model, budget filter, legacy conversion, parked fix

**Files:** create `Sources/BudgetCore/Models/Scenario.swift` (Scenario + ScenarioApplication records, migration `createScenarios`); modify `ForecastEntry.swift` (columns + `budget(db)` / `inScenario(db:_:)` request helpers), `ForecastCalculator.swift` (`confirmedEntries` excludes `scenarioId != nil`; add `planEntries(entries:groups:)` for a scenario's effective plan; delete `previewTotal`/`previewNetWorthDelta` and `.hypothetical` selection only if Task 4 is the last user — instead keep them compiling until Task 4 deletes the old UI), every `ForecastEntry.fetchAll` that feeds the budget (Dashboard, Budget grid, Forecast VM, PlannedItemEditing loader, AutoForecastGenerator's "has a plan" SQL, ForecastPlanSeeder, PlannedItems, ReservedCategories) → `budget(db)` / `scenarioId IS NULL`; `PlannedItemEditing` parked fix (no `excludeFromAutoForecast` when removing a `.once` series).

**Produces:** `Scenario` (`id`, `name`, `createdAt`, `refreshedAt`), `ScenarioApplication` (`id`, `scenarioId`, `appliedAt`, `undoneAt`, `journal`), `ForecastEntry.scenarioId/sourceEntryId/scenarioChange` (`ScenarioChange` enum: added/changed/removed), `ForecastEntry.budget(_:)`, `ForecastEntry.inScenario(_:id:)`, `ForecastCalculator.planEntries`.

- [ ] Tests: migration (columns, scenario delete cascades its entries and their exceptions); legacy conversion SQL (a group with hypothetical entries → scenario with `added` manual entries); budget filter (a scenario entry never changes `confirmedTotal`, Dashboard current month, Budget grid plan, projection, upcoming bills, detection's "has a plan"); parked fix test. Then implement, full suite + app build, commit "Scenario model and budget filter".

### Task 2: Scenario operations

**Files:** create `Sources/BudgetCore/Forecasting/Scenarios.swift`; modify `PlannedItemEditing.swift`, `PlannedItems.swift` (scenario-aware: guard = enabled entry in enabled group with matching scope; change markers per spec; no confirmation restriction for future months in a scenario; tombstone on remove-at-first for copies); tests `ScenariosTests.swift`.

**Produces:** `Scenarios.create(db:name:) -> Scenario`, `duplicate(db:scenarioId:name:)`, `rename`, `delete`, `refresh(db:scenarioId:) -> RefreshReport { reapplied: [String]; couldNotReapply: [String] }`, `differences(db:scenarioId:) -> [ScenarioDifference]` (`id` = entry id, `kind`, `categoryName`, `summary`, `fieldChanges: [String]`), `PlannedItems.add(db:..., scenarioId: Int64?)`, editing entry points taking the scope implicitly from the entry.

- [ ] Tests per spec "Operations" and "Testing" (copy fidelity incl. exceptions and anchorDay; markers for each edit kind; refresh cases incl. missing source; differences text). Implement, verify, commit "Scenario operations".

### Task 3: Apply/undo and comparison

**Files:** create `Sources/BudgetCore/Forecasting/ScenarioApply.swift`, `ScenarioComparison.swift`; tests.

**Produces:** `ScenarioApply.apply(db:scenarioId:differenceIds:calendar:) -> ScenarioApplication`, `undoLast(db:scenarioId:) -> UndoReport { restored: [String]; warnings: [String] }`, `canUndo(db:scenarioId:) -> Bool`; `ScenarioComparison.netWorthSeries(...)`, `yearSummaries(...)`, `gridCells(...)` with inputs as in the spec (a `PlanInput` struct: entries, exceptions, groups for one plan).

- [ ] Tests per spec (apply effects incl. current-month boundary and anchor; undo exact restore + modified-after warning + only latest; comparison series/summary/grid diff on fixtures). Implement, verify, commit "Scenario apply/undo and comparison".

### Task 4: Forecast screen rebuilt as the scenario lab

**Files:** rewrite `App/Forecast/ForecastView.swift` / `ForecastViewModel.swift` (split into focused files under `App/Forecast/`: `ScenarioLabView`, `ScenarioListPanel`, `CompareTab`, `DifferencesTab`, `ScenarioGridTab`, `ScenarioLabViewModel`); reuse the Budget grid's planned-item sheets (`App/Budget/PlannedItemSheets.swift`) with a scenario scope; remove the old scenario panel, preview/confirm/un-confirm, `.hypothetical` handling, `previewTotal`/`previewNetWorthDelta` (and their tests) once unused; keep the frozen-header scroll technique from the grid-polish fix.

- [ ] Implement the screen per spec "Forecast screen"; verify (full suite, app build); commit "Forecast screen becomes the scenario lab".

### Task 5: Check and merge (controller)

- [ ] On a DB copy: create a scenario, change Rent, add a car, compare lines/table, apply one difference, undo; screenshots if possible. Final review, one fix wave, merge.
