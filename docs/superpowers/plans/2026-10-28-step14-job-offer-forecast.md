# Step 14: a job offer in the Forecast (Mac) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (chosen) to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** from the Mac salary simulator's "Offer" column, create a Forecast scenario that replaces the salary from a start month with the offer's net pay, changes the pension entry, adds one-offs, and can be reopened in the simulator.

**Architecture:**
- **Reuse the scenario lab:** an offer is an ordinary `Scenario` made by `Scenarios.create` plus edits, so Compare, Differences, Grid, Apply, delete and sync work unchanged. `OfferScenarioBuilder` (BudgetCore) does all of it in one savepoint.
- **Inputs travel with the scenario:** one new nullable column `scenario.offerInputs` (JSON of `OfferScenarioSpec`: the simulator `SalaryComparisonInputs`, the salary/pension entry ids and the sheet's choices). It is added to the synced field list of `scenario` (an optional field on an existing record type, no new record type).
- **Mac sheet only:** `TryInForecastSheet` and an "Edit offer…" action in the scenario lab; both thin over BudgetCore.

**Tech Stack:** Swift 6, SwiftUI, GRDB 6.29, XCTest, XcodeGen.

**Spec:** `docs/superpowers/specs/2026-10-28-step14-job-offer-forecast-design.md` (binding; *(my call)* items accepted). Depends on step 13: `docs/superpowers/plans/2026-10-28-step13-salary-simulator.md` (types `SalaryInputs`, `SalaryResult`, `SalaryComparisonInputs`-the pair `SalaryDraft`, `SalaryComparisonViewModel`, `SalaryCalculator`). If step 13 is dropped, drop this step.

## Global Constraints

- **Logic in BudgetCore** (`Sources/BudgetCore/Forecasting/OfferScenarioBuilder.swift`); **Mac only**; fits 1100×700; no figure wraps; names truncate in the middle.
- **Reuse scenarios** (`Scenarios`, `PlannedItems.add(…, scenarioId:)`, `PlannedItemEditing`), no new mechanism. The base forecast and actuals are never touched: every write carries the new `scenarioId`; deleting the scenario removes everything (existing cascade).
- **Save-only:** the sheet creates nothing until Save; Cancel and dismiss create nothing. "Edit offer…" saves only on Save.
- **Scenarios sync as today;** the one added column goes in `SyncSchema` `scenario.synced` (additive, nullable; older devices ignore it). No new CloudKit record type. Run the sync schema tests.
- **Writes** follow the existing Mac path and `scripts/check-actor-writes.sh` must print "actor writes OK". Filed SA years untouched (no tax figure changes here).
- **Scenario names unique** (`ScenarioError.duplicateName` surfaces inline in the sheet).
- **Nothing personal committed:** synthetic names and amounts in tests.
- **Tests never touch the real DB, Keychain, iCloud or `/Applications`;** use `TestDatabase`. No subagent runs `scripts/install-app.sh`.
- **Mac build with `xcodebuild` for any `App/` change; `scripts/build-core-ios.sh` stays green.**
- **Commands** (`S14=/tmp/mango-14-build`): targeted `swift test --scratch-path $S14 --filter '<Tests>'`; full suite once at the end of each task `swift test --scratch-path $S14 --parallel`; Mac build `xcodegen generate && xcodebuild -project Mango.xcodeproj -scheme Mango -configuration Debug -derivedDataPath $S14/dd CODE_SIGNING_ALLOWED=NO build`; `scripts/check-actor-writes.sh`. **At most 2 building agents at once.**
- **Model tags:** **[opus]** = sync schema and scenario write logic. **[sonnet]** = UI.
- **Dropping:** Task 2 is the user-facing part; if only Task 1 lands, nothing is visible (stop and report).

## Review Focus

1. **No salary entry to replace (the forecast has none, or it was deleted since the scenario was made).** Expect the sheet to say so and offer "Add as new income"; "Edit offer…" on a scenario whose entry is gone keeps working and adds. Task 1: `testMissingSalaryEntryAddsNewIncome`.
2. **Start month before the salary entry's start, or after its end.** Expect before-start: whole series replaced; after-end: refused with a plain message, nothing created. Task 1: `testStartBeforeEntryStart`, `testStartAfterEntryEndRefused`.
3. **Notice-period gap of N months.** Expect no salary for exactly N months from the start month, the offer salary after them, and the original entry ended the day before the start month. Task 1: `testNoticeGapMonths`.
4. **Re-saving "Edit offer…".** Expect the scenario rebuilt in place (same id and name), no duplicate scenario, no orphan entries, other manual edits to the scenario's other entries kept. Task 1: `testRebuildReplacesOnlyOfferEntries`.
5. **Pension entry absent, or a salary-sacrifice offer.** Expect no pension edit when none exists (and the sheet says "no pension entry in your forecast"); the amount applied is employee plus employer pension per month, never double-counting the sacrifice already out of net pay. Task 1: `testNoPensionEntryLeavesPensionAlone`, `testPensionAmountIsEmployeePlusEmployer`.

---

### Task 1 [opus]: Scenario builder, offer inputs stored with the scenario

**Files:**
- Create: `Sources/BudgetCore/Forecasting/OfferScenarioBuilder.swift`, `Sources/BudgetCore/Forecasting/OfferScenarioSpec.swift`
- Modify: `Sources/BudgetCore/Models/Scenario.swift` (add `public var offerInputs: String?`, init default nil), `Sources/BudgetCore/Database/DatabaseManager.swift` (next migration: `ALTER TABLE scenario ADD COLUMN offerInputs TEXT`; use the next free migration name after the last registered), `Sources/BudgetCore/Sync/SyncSchema.swift` (add `"offerInputs"` to `scenario.synced`)
- Test: `Tests/BudgetCoreTests/OfferScenarioBuilderTests.swift`; extend the existing sync schema coverage tests if they enumerate columns

**Interfaces:**
- Consumes: step 13 `SalaryInputs`, `SalaryResult` (`takeHomeMonthly`, `employeePension`, `employerPension`), `SalaryCalculator.calculate`; `Scenarios.create`, `PlannedItems.add`, `ForecastEntry`, `ForecastFrequency.once/.monthly`.
- Produces (`public`, `Codable, Equatable, Sendable`):
  - `struct OfferOneOff { var label: String; var amountMinorUnits: Int; var month: Date }` (signing bonus: positive; stored as a `once` income entry on the first day of `month`)
  - `struct OfferScenarioSpec { var current: SalaryInputs; var offer: SalaryInputs; var salaryEntryId: Int64?; var pensionEntryId: Int64?; var startMonth: Date; var noticeGapMonths: Int; var oneOffs: [OfferOneOff] }`
  - `enum OfferScenarioBuilder { static func create(db: Database, name: String, spec: OfferScenarioSpec, now: Date = Date()) throws -> Scenario; static func rebuild(db: Database, scenarioId: Int64, spec: OfferScenarioSpec) throws; static func spec(db: Database, scenarioId: Int64) throws -> OfferScenarioSpec?; static func salaryCandidates(db: Database) throws -> [ForecastEntry] /* enabled budget income entries, monthly, by most recent start */ }`
  - `enum OfferScenarioError: Error, Equatable { case startAfterSalaryEnds, noSalaryEntryOrNewIncomeCategory }` (with `LocalizedError` copy).

- [ ] **Step 1: Write failing tests** (all with `TestDatabase`, a synthetic budget: income category "Salary" £2,000.00 monthly from 2026-01-01 with no end, pension expense entry £150.00 monthly; offer net £2,600.00/month from `SalaryCalculator`, spec month 2026-04-01):
  - `testReplacesSalaryFromStartMonth`: scenario copy of the salary entry has `endDate` 2026-03-31, a new `added` entry in the same group/category starts 2026-04-01 monthly at `takeHomeMonthly`; base forecast entries and their count unchanged (`ForecastEntry.budget`).
  - `testStartBeforeEntryStart`, `testStartAfterEntryEndRefused` (throws `.startAfterSalaryEnds`, no scenario row), `testNoticeGapMonths` (gap 2 → new entry starts 2026-06-01), `testMissingSalaryEntryAddsNewIncome`.
  - `testPensionAmountIsEmployeePlusEmployer` (pension entry in the scenario is `changed`, from the start month, amount keeps its sign and equals ±(employee + employer)/12 rounded), `testNoPensionEntryLeavesPensionAlone`.
  - `testOneOffsAdded` (signing bonus £3,000.00 in 2026-04: one `once` entry, positive, in the scenario only).
  - `testInputsStoredAndRead`: `spec(db:scenarioId:)` returns the same spec; `scenario.offerInputs` is JSON.
  - `testRebuildReplacesOnlyOfferEntries` (add an unrelated manual scenario entry first; after `rebuild` with a new offer salary it remains, the offer entries are replaced, scenario id and name unchanged, no orphan entries), `testDeleteScenarioRemovesOfferEntries`, `testDuplicateNameThrowsScenarioError`.
  - `testMigrationAddsColumnAndOldRowsReadNil`; sync: `testScenarioOfferInputsIsSynced` in the existing sync schema tests style.
- [ ] **Step 2: Run to see them fail**, `swift test --scratch-path $S14 --filter 'OfferScenarioBuilder|SyncSchema'`.
- [ ] **Step 3: Add the column, migration and sync field;** `Scenario.offerInputs` (`Codable` picks it up; keep column order irrelevant).
- [ ] **Step 4: Implement the builder in one savepoint:** `Scenarios.create(db:name:now:)`, then in the copy: end the salary entry's scenario copy at the day before the start month and mark it `changed` (via `PlannedItemEditing`, as the lab does for an edited amount), `PlannedItems.add(db:…, scenarioId:)` for the new salary entry (status `.confirmed`, same `groupId`, `categoryId`, `accountId`), the pension edit, and the one-offs; record `OfferScenarioSpec` JSON (sorted keys, ISO dates) in `offerInputs`. Entry ids in the spec refer to **budget** entries; resolve the scenario's copy by `sourceEntryId`. `rebuild` deletes only scenario entries it created (identify them by a marker: note prefix `"Offer: "` on added entries and, for changed copies, re-derive from the budget source via `Scenarios.refresh`-style re-copy of just that entry), then re-applies.
- [ ] **Step 5: Run targeted tests, the sync tests, `scripts/check-actor-writes.sh`, `scripts/build-core-ios.sh`, then the full suite.** All PASS; "actor writes OK".
- [ ] **Step 6: Commit.** `git add Sources/BudgetCore Tests/BudgetCoreTests && git commit -m "Step 14 task 1: offer scenario builder"`.

### Task 2 [sonnet]: Mac "Try in Forecast…" sheet and "Edit offer…" round trip

**Files:**
- Create: `App/Salary/TryInForecastSheet.swift`, `App/Salary/TryInForecastViewModel.swift`
- Modify: `App/Salary/SalarySimulatorView.swift` (a "Try in Forecast…" button under the Offer column, disabled with a reason until the Offer has a gross > 0), `App/Forecast/ScenarioLabView.swift` and `ScenarioChips.swift` (an "Edit offer…" menu item on scenarios where `offerInputs != nil`, which switches to the Salary screen preloaded with the stored spec and opens the sheet in edit mode), `App/ContentView.swift` (navigation hand-off), `App/Salary` view model hook to load a stored `OfferScenarioSpec`
- Test: `Tests/BudgetCoreTests/OfferSheetModelTests.swift` for the sheet's pure state (placed in BudgetCore as `OfferSheetModel` so it is testable; the SwiftUI sheet only binds to it)

**Interfaces:**
- Consumes: Task 1 `OfferScenarioBuilder`, `OfferScenarioSpec`, `OfferOneOff`, `OfferScenarioError`; step 13 `SalaryComparisonViewModel`.
- Produces: `@MainActor @Observable final class OfferSheetModel { init(offer: SalaryInputs, current: SalaryInputs, candidates: [ForecastEntry], pensionCandidates: [ForecastEntry], editing: (scenarioId: Int64, spec: OfferScenarioSpec)?); var name: String; var salaryEntryId: Int64?; var startMonth: Date; var noticeGapMonths: Int; var signingBonus: Int?; var canSave: Bool; var preview: String /* "From Apr 2026: £2,600.00 a month net, was £2,000.00" */; func spec() -> OfferScenarioSpec }`. Default name "Offer: <employer or 'new job'> <Mon YYYY>" (employer is not in step 13 inputs, so "Job offer <Mon YYYY>").

- [ ] **Step 1: Write failing tests** in `OfferSheetModelTests`: `testPreselectsMostRecentSalaryEntry`, `testCannotSaveWithEmptyNameOrNoSalaryAndNoNewIncome` (`canSave` false), `testPreviewWording` (exact string above; negative change wording "less"), `testEditModeKeepsNameAndSpec`, `testSpecCarriesOneOffAndGap`.
- [ ] **Step 2: Run to see them fail.**
- [ ] **Step 3: Implement `OfferSheetModel`** in `Sources/BudgetCore/Forecasting/OfferSheetModel.swift` (new file; add it to the Files list above) and the SwiftUI sheet: salary entry picker (names truncate in the middle), start month picker, "Months without salary (notice gap)" stepper, signing bonus field, scenario name, inline refusal text for `OfferScenarioError` and `ScenarioError.duplicateName`, **Save** and Cancel only. On Save call `OfferScenarioBuilder.create` (or `rebuild` in edit mode) through the existing Mac write path, then select the new scenario in the Forecast screen's Compare tab.
- [ ] **Step 4: Wire the entry points** ("Try in Forecast…", "Edit offer…") and the navigation hand-off.
- [ ] **Step 5: Run tests, the Mac build, `scripts/check-actor-writes.sh`.** Check manually in a unit-level way only (no running of the app by subagents); render with the Mac snapshot script if it supports the sheet, else skip.
- [ ] **Step 6: Full suite; commit.** `git add Sources App Tests && git commit -m "Step 14 task 2: Try in Forecast sheet and Edit offer"`.

## Controller-only (after the last task, not subagents)

Merge to main, `xcodegen generate`, `scripts/install-app.sh`. Because `scenario` gained a synced field, note in the report that the iPhone/iPad builds must be updated before they will round-trip `offerInputs` (older builds ignore it).
