# Step 17: compare the budget with several scenarios at once — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (chosen) to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Forecast's Compare tab shows the budget, up to 4 ticked scenarios and a **Combined** line (all ticked scenarios applied together), with an impact table of each line's difference from the budget and a "Save combination as a scenario…" action.

**Architecture:**
- **What exists:** `ScenarioLabViewModel.compareSelection` already ticks any number of scenarios; `ScenarioComparison.netWorthSeries` / `yearSummaries` give each plan's line and per-year row (`PlanYearSummary.differenceVsBudget`); `CompareTab` draws `ScenarioNetWorthChart` and `SummaryTable`. A scenario is a full copy of the budget whose entries carry `scenarioChange` (`nil` unchanged, `.changed`, `.added`, `.removed` tombstone) and `sourceEntryId`.
- **What is new:** `ScenarioCombinator` (BudgetCore, pure) builds one `PlanInput` by applying the ticked scenarios' *changes only* onto the budget in list order and reports overlaps; `ScenarioImpact` (BudgetCore, pure) derives average monthly surplus and each line's difference. The view model feeds the combined `PlanInput` to the **same** `ScenarioComparison` functions (no second forecast engine). `CompareTab` gains the Combined toggle, the overlap notice, the impact figures and the save button.
- **Nothing saved by comparing**; only "Save combination as a scenario…" writes (a new scenario via `Scenarios`), never the budget or actuals.

**Tech Stack:** Swift 6, SwiftUI, Swift Charts, GRDB, XCTest, XcodeGen.

**Spec:** `docs/superpowers/specs/2026-10-28-step17-scenario-comparison-design.md` (binding; *(my call)* items accepted).

## Global Constraints

- **Logic in BudgetCore** (`Sources/BudgetCore/Forecasting/`), pure, no `Date()`; `scripts/build-core-ios.sh` stays green. No second forecast engine: lines and summaries come from `ScenarioComparison`.
- **Combining rules:** scenarios applied in their list order (`ScenarioLabViewModel.scenarios` order) onto the budget; when two scenarios change the same forecast entry, **the later one wins** and Compare says so: "Buy a car and Salary +10% both change 'Groceries'; the later one is used".
- **Up to 4 scenarios ticked at once.** The fifth tick is refused with an inline note, not silently.
- **Combined toggle** applies every ticked scenario together; with fewer than 2 ticked it is disabled ("Tick at least two scenarios").
- **Impact table:** one column per line (Budget, each ticked scenario, Combined): net worth at the end of each year shown, average monthly surplus, income and expenses per year, and the difference from the budget for each. The Combined column also shows each scenario's own difference and the "together" difference.
- **Fits 1100×700:** the table scrolls horizontally only inside its own box; no figure wraps (`.figureText()` / `MoneyText`); names truncate in the middle (`.lineLimit(1).truncationMode(.middle)`).
- **Nothing changes the budget or actuals; no filed-year effect.** No new table or CloudKit field. iPhone/iPad Forecast and probabilistic scenarios are out of scope.
- **Tests never touch the real DB, Keychain, iCloud or `/Applications`;** use `TestDatabase`. No subagent runs `scripts/install-app.sh`.
- **Build the App target with `xcodebuild`** for any task touching `App/`.
- **Commands** (`S17=/tmp/mango-17-build`):
  - targeted: `swift test --scratch-path $S17 --filter '<Tests>'`
  - full suite, once at the end of each task: `swift test --scratch-path $S17 --parallel`
  - Mac build: `xcodegen generate && xcodebuild -project Mango.xcodeproj -scheme Mango -configuration Debug -derivedDataPath $S17/dd CODE_SIGNING_ALLOWED=NO build`
  - **at most 2 building agents at once.**
- **Model tags:** **[opus]** = logic plus a spec+code review. **[sonnet]** = UI/plumbing: quick review.
- **Dropping tasks: drop from the end.** Task 3 (save combination) is the first to go; Tasks 1-2 are the whole comparison. The whole step is droppable second to last in the unattended run.

## Calls extending the spec

- *(plan call)* Already there, so not rebuilt: ticking several scenarios and a line per scenario in Compare. This plan adds the Combined line/column, the per-scenario differences, the overlap notice, the cap of 4 and the save action.
- *(plan call)* "Average monthly surplus" = (income − expenses) summed over the shown months ÷ the number of months shown (12 per full year, the horizon's month in its last year, from `PlanYearSummary` and the horizon). A scenario's "own difference" in the Combined column is its year-end net worth minus the budget's (already `differenceVsBudget`); "together" is the Combined line's.
- *(plan call)* A `.removed` tombstone and a `.changed` entry both replace their source entry in the combination (a tombstone is a disabled entry, it counts for nothing). Two scenarios that both *add* entries never overlap. Edited occurrences on an unchanged copy (no `scenarioChange`) are ignored, consistent with `Scenarios.differences`.
- *(plan call)* Overlap is reported per source entry, naming the category; the later scenario's change is used.

## Review Focus

1. **One scenario ticked, or none.** Expect Combined disabled/hidden, no crash, chart and table as today. Task 2: `testCombinedUnavailableBelowTwoTicked`.
2. **Two scenarios change the same entry (salary +10% and a job offer).** Expect later wins, one overlap notice naming both scenarios and the category. Task 1: `testLaterScenarioWinsAndOverlapIsReported`.
3. **A scenario removes an entry another scenario changes.** Expect the later one's version, overlap reported. Task 1: `testRemovedThenChangedUsesTheLaterAndReportsOverlap`.
4. **A scenario's source entry has since left the budget (`Source no longer in the budget`).** Expect its change kept as an added entry, no crash, no duplicate. Task 1: `testChangeWhoseSourceIsGoneIsKeptAsAdded`.
5. **Ticking a fifth scenario; deleting a ticked scenario; a scenario refreshed from the budget while ticked.** Expect refusal with a note; selection pruned and Combined recomputed; refreshed scenario's changes re-read. Task 2: `testFifthTickIsRefused`, `testDeletingATickedScenarioRecomputesCombined`.

---

### Task 1 [opus]: `ScenarioCombinator` and `ScenarioImpact`

**Files:**
- Create: `Sources/BudgetCore/Forecasting/ScenarioCombinator.swift`, `Sources/BudgetCore/Forecasting/ScenarioImpact.swift`
- Test: `Tests/BudgetCoreTests/ScenarioCombinatorTests.swift`, `Tests/BudgetCoreTests/ScenarioImpactTests.swift` (reuse the fixture style of `ScenarioComparisonTests`: `entry(...)` helper, UTC dates, one group)

**Interfaces:**
- Consumes: `PlanInput { entries, exceptions, groups }`, `ForecastEntry` (`id`, `sourceEntryId`, `scenarioChange`, `categoryId`), `PlanYearSummary`, `ScenarioComparison.netWorthSeries(_:plan:)` and `yearSummaries(…)`.
- Produces (`public`, `Equatable, Sendable`):
  - `struct ScenarioPlan { let id: Int64; let name: String; let plan: PlanInput }`
  - `struct ScenarioOverlap { let sourceEntryId: Int64; let categoryId: Int64; let earlierScenarioId: Int64; let laterScenarioId: Int64 }`
  - `struct CombinedPlan { let plan: PlanInput; let overlaps: [ScenarioOverlap]; let contributions: [Int64: Int64] /* entry id in `plan` -> scenario id it came from; budget entries absent */ }`
  - `enum ScenarioCombinator { static func combine(budget: PlanInput, scenarios: [ScenarioPlan]) -> CombinedPlan; static func overlapNotice(_ overlap: ScenarioOverlap, scenarioNames: [Int64: String], categoryNames: [Int64: String]) -> String /* "Buy a car and Salary +10% both change 'Groceries'; the later one is used" */ }`
  - `enum ScenarioImpact { static func averageMonthlySurplus(_ years: [PlanYearSummary], horizon: (year: Int, month: Int)) -> Int /* pence, rounded half away from zero; 0 for no years */ ; static func difference(_ value: Int?, from budget: Int?) -> Int? }`

- [ ] **Step 1: Write the failing combinator tests** (`ScenarioCombinatorTests`, budget = salary 3 000 + rent −1 000 + groceries −400 monthly):
  - `testNoScenariosReturnsTheBudget`: `combine(budget:, scenarios: [])` → `plan == budget`, no overlaps, no contributions.
  - `testUnchangedCopiesContributeNothing`: a scenario with only `nil`-change copies → `plan.entries` equals the budget's entries; netWorth series identical to the budget's.
  - `testTwoDisjointScenariosApplyTogether`: salary +10% (`.changed` salary) and "car" (`.added` −300 monthly) → entries: budget's rent and groceries, scenario-1's changed salary, scenario-2's car; `contributions` maps those two entry ids to their scenario ids; no overlaps; the combined year-end net worth difference from the budget equals the sum of the two scenarios' own differences (disjoint, linear).
  - `testLaterScenarioWinsAndOverlapIsReported`: both change groceries (−500 then −600): the combined groceries entry is the second's (−600); one `ScenarioOverlap(sourceEntryId: groceries, categoryId: groceriesCat, earlierScenarioId: s1, laterScenarioId: s2)`.
  - `testOrderIsTheListOrder`: reversing the input array reverses which one wins.
  - `testRemovedThenChangedUsesTheLaterAndReportsOverlap`: s1 `.removed` tombstone of rent, s2 `.changed` rent → s2's rent is used and enabled; overlap reported. And the reverse order leaves the tombstone (rent counts for nothing).
  - `testChangeWhoseSourceIsGoneIsKeptAsAdded`: a `.changed` entry whose `sourceEntryId` is not in the budget is appended, no overlap, count of entries = budget + 1.
  - `testExceptionsFollowTheirEntries`: a skipped occurrence on a changed entry stays; the replaced budget entry's exceptions are dropped; exceptions of a budget entry kept stay.
  - `testGroupsAreUnionedById`: a scenario's added entry in a group that only the scenario knows keeps that group; the budget's groups are not duplicated.
  - `testOverlapNoticeWording`: `overlapNotice` returns exactly "Buy a car and Salary +10% both change 'Groceries'; the later one is used" for those names; a missing category name reads 'an item'.
- [ ] **Step 2: Write the failing impact tests** (`ScenarioImpactTests`): `testAverageMonthlySurplusFullYears` (two full years, income 36 000 and expenses 24 000 per year → 100 000 pence); `testAverageMonthlySurplusStopsAtHorizonMonth` (second year ends in June, so 18 months); `testAverageMonthlySurplusRoundsHalfAwayFromZero` (surplus −1 pence over 3 months → 0; −2 over 3 → −1); `testNoYearsIsZero`; `testDifferenceIsNilWhenEitherSideIsNil`.
- [ ] **Step 3: Run to see them fail.** `swift test --scratch-path $S17 --filter 'ScenarioCombinator|ScenarioImpact'` → FAIL (types missing).
- [ ] **Step 4: Implement `ScenarioCombinator.combine`.** Algorithm (the only part the signature does not determine): `result` = budget entries keyed by id in order; for each scenario in input order, for each of its entries with `scenarioChange != nil`: `.added` → append, `contributions[e.id] = scenario.id`; `.changed`/`.removed` with a `sourceEntryId` present in `result` (the current holder of that source, tracked in `holderOfSource: [Int64: Int64]` = source id → entry id now standing for it, plus `touchedBy: [Int64: Int64]` = source id → scenario id) → replace the holder with `e`, record an overlap if `touchedBy[source]` exists (earlier scenario, this scenario), update both maps; with a source not in the budget → append as added (Review Focus 4). Exceptions: keep a budget entry's exceptions while it stands; when replaced drop them; add the scenario's exceptions for each entry taken from it. Groups: budget groups plus scenario groups with unseen ids.
- [ ] **Step 5: Implement `overlapNotice` and `ScenarioImpact`.** `averageMonthlySurplus`: months = 12 per year except the last year = `horizon.month` when `years.last?.year == horizon.year`; surplus = Σ(income − expenses) (both positive magnitudes, as `DashboardCalculator.yearTotals` gives them), divided by months with half-away-from-zero rounding.
- [ ] **Step 6: Run targeted tests, then the full suite and `scripts/build-core-ios.sh`.** Expected PASS.
- [ ] **Step 7: Commit** `Step 17: scenario combinator and impact figures`.

---

### Task 2 [sonnet]: Combined line, impact table and overlap notice in Compare

**Files:**
- Modify: `App/Forecast/ScenarioLabViewModel.swift` (compare state and `computeComparison`), `App/Forecast/CompareTab.swift` (Combined toggle, notice, table, chart line), `App/Forecast/ScenarioChips.swift` only for the cap note
- Test: `Tests/BudgetCoreTests/ScenarioCombinedComparisonTests.swift` (the view-model derivation is extracted to a BudgetCore function so it is testable: see Interfaces)

**Interfaces:**
- Consumes: Task 1's `ScenarioCombinator.combine`, `CombinedPlan`, `ScenarioImpact`; `ScenarioComparison.netWorthSeries(_:plan:actuals:)`, `yearSummaries(…)`; view model's `scenarios`, `compareSelection`, `scenarioPlans`, `budgetPlan`.
- Produces:
  - BudgetCore: `struct ComparisonLine { let id: String /* "budget" | "scenario-<id>" | "combined" */; let name: String; let forecast: [NetWorthPoint]; let years: [PlanYearSummary]; let averageMonthlySurplus: Int }` and `enum CombinedComparison { static let maxTicked = 4; static func lines(_ data: ComparisonData, budget: PlanInput, scenarios: [ScenarioPlan] /* ticked, list order */, includeCombined: Bool) -> (actual: [NetWorthPoint], lines: [ComparisonLine], overlaps: [ScenarioOverlap]) }` in `Sources/BudgetCore/Forecasting/CombinedComparison.swift`.
  - View model: `@Published var showCombined = false`; `@Published private(set) var overlapNotices: [String]`; `var canCombine: Bool` (≥ 2 ticked); `var tickLimitNote: String?`; `SummaryRow` gains `averageMonthlySurplus: Int` and `contributions: [(name: String, difference: Int?)]` only for the combined row (optional, empty otherwise).

- [ ] **Step 1: Write the failing tests** (`ScenarioCombinedComparisonTests`, `ComparisonData` fixture as in `ScenarioComparisonTests`):
  - `testLinesAreBudgetThenScenariosThenCombined`: ids `["budget","scenario-7","scenario-8","combined"]` with `includeCombined: true`; without it, no combined line.
  - `testCombinedEqualsSumOfDifferencesWhenDisjoint`: combined year-end difference from the budget == sum of the two scenarios' differences; the budget line is identical to `ScenarioComparison.netWorthSeries(data, plan: budget)`.
  - `testOverlapsPassThrough`: two scenarios changing the same entry → `overlaps.count == 1`.
  - `testAverageMonthlySurplusMatchesImpact`: each line's `averageMonthlySurplus == ScenarioImpact.averageMonthlySurplus(years, horizon:)`.
  - `testCombinedUnavailableBelowTwoTicked`: one scenario with `includeCombined: true` → no combined line.
  - `testMaxTickedIsFour`: `CombinedComparison.maxTicked == 4`.
- [ ] **Step 2: Run to see them fail.** `swift test --scratch-path $S17 --filter ScenarioCombinedComparison` → FAIL.
- [ ] **Step 3: Implement `CombinedComparison.lines`** by composing the existing calls: actuals once, one series per plan (`computeComparison`'s loop moves here), combined plan from `ScenarioCombinator.combine`, rows from `yearSummaries(…budgetSeries:)`. `ScenarioLabViewModel.computeComparison` now calls it and maps `ComparisonLine` to the existing `PlanLine`/`SummaryRow`; behaviour with `showCombined == false` is byte-for-byte what it was (existing `ScenarioComparisonTests` stay green).
- [ ] **Step 4: View model.** `compareSelection.didSet` refuses a tick beyond 4 (restore the previous set, set `tickLimitNote = "Four scenarios at most: untick one first."`, clear it on the next change); `showCombined` change and `canCombine` false force `showCombined = false`; `overlapNotices` built with `ScenarioCombinator.overlapNotice` from scenario and category names; `showCombined` recomputes the comparison. Add tests in the same test file where BudgetCore-testable (`testFifthTickIsRefused` and `testDeletingATickedScenarioRecomputesCombined` assert the pure selection-pruning helper `CombinedComparison.pruned(selection:available:)` -> `Set<Int64>` that the view model calls, so that test needs no UI).
- [ ] **Step 5: `CompareTab` UI.** Under the chips a `Toggle("Combined", isOn: $viewModel.showCombined)` (disabled with help "Tick at least two scenarios" when `!canCombine`) and the limit note; overlap notices as `InlineBanner`-style lines (secondary text, `exclamationmark.triangle`, wrapping allowed: they are sentences, names inside truncate via the string already built). Chart: the combined line uses `theme.series(5)`-style distinct colour index and a dotted dash `[2, 3]`; hover read-out lists it. Table: `SummaryTable` gains a leading "Avg monthly surplus" column and, for the Combined row, a second line under "Δ vs Budget" listing each scenario's own difference ("Salary +10%: +£12,000") and "Together: +£9,500"; names `.lineLimit(1).truncationMode(.middle)`; all figures `MoneyText`/`.figureText()`; raise `SummaryTable.minimumWidth` by one column (the table already sits in a horizontal `ScrollView` with `wrapProbeScrollsHorizontally()`).
- [ ] **Step 6: Verify.** Targeted tests, full suite, Mac build. Then render at 1100×700 with the app's snapshot script (`scripts/render-snapshots.sh` if it has a Forecast route; otherwise state that the layout was checked by reading and ask the controller for a manual look) with 4 scenarios ticked and Combined on: no figure wraps.
- [ ] **Step 7: Commit** `Step 17: Combined line, impact table and overlap notices in Compare`.

---

### Task 3 [sonnet]: Save combination as a scenario (droppable)

**Files:**
- Modify: `Sources/BudgetCore/Forecasting/Scenarios.swift` (new `createCombined`), `App/Forecast/ScenarioLabViewModel.swift` (action), `App/Forecast/CompareTab.swift` (button), `App/Forecast/ScenarioChips.swift` (reuse the name prompt if it fits)
- Test: `Tests/BudgetCoreTests/ScenarioCombinedSaveTests.swift`

**Interfaces:**
- Consumes: `ScenarioCombinator.combine`, `Scenarios.create` (copies the budget as unchanged copies), the private `Scenarios.copy(db:_:scenarioId:sourceEntryId:change:)`, `ForecastEntry.inScenario(db, id:)`, `Scenarios.validatedName`.
- Produces: `Scenarios.createCombined(db: Database, name: String, from scenarioIds: [Int64], now: Date = Date()) throws -> Scenario` and `ScenarioLabViewModel.saveCombination(name: String) -> SaveOutcome`.

- [ ] **Step 1: Write the failing tests** with `TestDatabase` (a budget of 3 entries, two scenarios made with `Scenarios.create` and edited through `PlannedItemEditing`/`PlannedItems.add(…, scenarioId:)` as `ScenariosTests` does):
  - `testSavedCombinationHasTheSameNetWorthAsTheCombinedLine`: the new scenario's plan run through `ScenarioComparison.netWorthSeries` equals the combined plan's series.
  - `testSavedCombinationIsAnOrdinaryScenario`: it has one entry per budget entry (unchanged copies with `sourceEntryId`), `Scenarios.differences` lists exactly the union of the two scenarios' differences (later wins on overlaps), and "Apply to budget" is not run.
  - `testSavingDoesNotTouchTheBudgetOrTheSourceScenarios`: budget entries and both scenarios' entries unchanged afterwards.
  - `testDuplicateOrEmptyNameIsRefused`: `Scenarios.validatedName`'s existing errors surface; fewer than 2 ids throws `ScenarioError.notFound`-style error (use the existing case closest in meaning; add `ScenarioError.needsTwoScenarios` only if none fits).
- [ ] **Step 2: Run to see them fail.** `swift test --scratch-path $S17 --filter ScenarioCombinedSave` → FAIL.
- [ ] **Step 3: Implement `createCombined`** in one savepoint: `create(db:name:)`, then for each combined entry in `contributions`, delete the new scenario's unchanged copy of its source (for `.added`, none) and `copy(…, sourceEntryId: entry.sourceEntryId, change: entry.scenarioChange)` with its exceptions (as `duplicate` does). Order of scenarios = `scenarios` list order.
- [ ] **Step 4: View model and UI.** Button "Save combination as a scenario…" beside the Combined toggle, enabled when `showCombined && canCombine`; it opens the existing name prompt (default name "A + B"), calls `saveCombination`, then ticks only the new scenario via `showInCompare` and switches Combined off. Errors go to `errorMessage`.
- [ ] **Step 5: Run targeted tests, full suite, Mac build.** Expected PASS.
- [ ] **Step 6: Commit** `Step 17: save a combination as a scenario`.
