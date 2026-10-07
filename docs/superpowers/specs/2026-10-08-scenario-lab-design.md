# Scenario Lab — Design Spec

## Overview

Project 2 of 2 (project 1, "budget as the plan", is built: `2026-10-07-budget-plan-design.md`). The budget now holds the plan; the Forecast screen becomes the place where **scenarios** are played: each scenario starts as a copy of the current budget, you add, remove and change expenses, incomes and reserves, and you compare several scenarios — including their effect on net worth — before applying chosen changes to the budget, with undo.

## Decisions (user, 2026-10-07/08)

- A scenario is a **frozen copy** of the budget with a **Refresh from budget** action that re-copies today's budget and re-applies the scenario's own changes.
- Comparison shows **net worth lines**, a **summary table**, the **item differences**, and a **month-by-month grid**.
- A **horizon picker** per comparison: end of this year, 2, 5 or 10 years (default 2 years).
- **Apply to budget**: tick the differences to apply; they become ordinary unconfirmed planned items; **undo** is available.
- Built straight after project 1.

## Current state (verified)

- Planned items = `ForecastEntry` rows (non-hypothetical, enabled, in an enabled `ForecastGroup`) with per-occurrence `PlannedOccurrenceException`s; `ForecastCalculator.confirmedEntries` selects them; totals/projections are exception-aware (`PlannedOccurrences`). `ForecastEntry.anchorDay` keeps month-end anchors.
- Editing: `PlannedItemEditing.editOccurrence` / `editFollowing` (budget items only), `PlannedItems.add`, `ReservedCategories.addReserve`.
- Today's scenarios: a non-system `ForecastGroup` with `.hypothetical` entries; `ForecastCalculator.previewTotal` / `previewNetWorthDelta` add the selected scenario's entries on top of the plan; the Forecast screen has a scenario panel (pick, add item, confirm → entries become `.confirmed`). The user's database has **no** scenario groups.
- Comparison building blocks: `ForecastProjector.monthlyProjection` (net worth walk from the latest data's pay month), `DashboardCalculator.monthlyFlows`/`yearTotals` (per-month income/expenses with pay-month actuals and month classes).

## Model

Migration `createScenarios` (appended last):

- Table `scenario`: `id`, `name` (unique), `createdAt`, `refreshedAt`.
- `forecastEntry` gains `scenarioId INTEGER NULL REFERENCES scenario ON DELETE CASCADE`, `sourceEntryId INTEGER NULL` (the budget entry it was copied from; no FK — the source may be deleted later), `scenarioChange TEXT NULL` (`added`, `changed`, `removed`; NULL = unchanged copy).
- Table `scenarioApplication`: `id`, `scenarioId` (cascade), `appliedAt`, `undoneAt NULL`, `journal TEXT` (JSON: the operations applied and before-images, see Apply).

**Budget vs scenario entries.** Budget entries have `scenarioId IS NULL`. `ForecastCalculator.confirmedEntries` excludes scenario entries. Every place that loads entries for the budget uses one helper, `ForecastEntry.budget(db)` (`scenarioId IS NULL`); scenario screens use `ForecastEntry.inScenario(db, id)`. Exceptions belong to an entry, so a scenario's copied exceptions are just exceptions on its own entries.

**A scenario's effective plan** = its entries that are enabled and not `removed`, with their exceptions, evaluated with the same calculator (`ForecastCalculator.planEntries(entries:groups:)` = `confirmedEntries` without the scenario filter, applied to a scenario's entries). Scenario entries keep their source's `groupId` (so reserves stay in "Reserved").

**Legacy scenarios.** The same migration converts existing scenario groups (any group holding `.hypothetical` entries; none in the user's DB) with plain SQL: one `scenario` row per group (its name), and its `.hypothetical` entries get that `scenarioId`, `scenarioChange = 'added'` and status `manual`. No budget copy is made — Refresh brings the budget in. `.hypothetical` is no longer produced; `previewTotal`/`previewNetWorthDelta`/the scenario panel are removed.

## Operations (`Sources/BudgetCore/Forecasting/Scenarios.swift`, each in one transaction)

- `create(db:name:)` — new scenario; copies every budget entry (all groups, including disabled ones, preserving `isEnabled`) with `sourceEntryId`, and each entry's exceptions.
- `duplicate(db:scenarioId:name:)` — copies a scenario's entries (including change markers) and exceptions.
- `rename`, `delete` (cascade).
- Editing inside a scenario reuses the project-1 operations, scenario-aware: `PlannedItemEditing.editOccurrence` / `editFollowing` and `PlannedItems.add` accept scenario entries (the "planned item" guard becomes "enabled entry in an enabled group, any scenario"); there is no confirmation restriction for future months; past months follow the same closed-month rule. Any edit of an unchanged copy marks it `changed`; a split's new entry is `added` and its original `changed`; `add` creates an `added` entry; "remove this and all following" on an unchanged/changed copy at its first occurrence marks it `removed` (kept as a tombstone, disabled) instead of deleting.
- `refresh(db:scenarioId:) -> RefreshReport` — deletes the scenario's unchanged copies; re-copies today's budget entries and exceptions; then re-applies: a `changed` or `removed` entry whose `sourceEntryId` still exists in the budget replaces/removes that fresh copy; one whose source no longer exists is kept as `added` (changed) or dropped (removed) and listed in the report as "couldn't reapply: source no longer in the budget". `added` entries are kept. Updates `refreshedAt`.
- `differences(db:scenarioId:) -> [ScenarioDifference]` — `added` (series summary), `removed` (source summary), `changed` (field-by-field: amount, frequency/interval, start/end, category; plus "N occurrences edited" when exceptions differ from the source's).

## Apply to budget, with undo (`ScenarioApply.swift`)

`apply(db:scenarioId:differences:[ids], today:) -> ScenarioApplication`, one transaction:
- `added` → a new budget entry (copy of the scenario entry; group "Planned", or "Reserved" for reserves) plus its exceptions.
- `removed` → the source budget entry's `endDate` = end of the month before the current pay month (or before the source's start if it hasn't started: the entry is disabled).
- `changed` → like `editFollowing` from the current pay month: the source ends before it; a new budget entry with the scenario values starts at the first occurrence on/after the current month (anchorDay kept); scenario exceptions dated on/after the current month are copied.
- The journal stores, per operation: created entry ids, and the before-image (`endDate`, `isEnabled`) of modified entries plus an after-image fingerprint.

`undoLast(db:scenarioId:) -> UndoReport` — for the scenario's most recent un-undone application: deletes the created entries (exceptions cascade) and restores the before-images; if a modified entry's current state differs from its after-image, it is still restored but reported ("Rent was edited after applying; restored to before the apply"). Sets `undoneAt`. Only the latest application per scenario can be undone.

## Comparison (`ScenarioComparison.swift`, pure)

Input: categories, transactions, snapshots, accounts, rate, pay calendar, budget entries/exceptions/groups, each selected scenario's entries/exceptions, horizon (end month), today.
- **Net worth series** per plan (budget + each scenario): actual net worth points (shared) + `ForecastProjector.monthlyProjection` with that plan's entries to the horizon.
- **Summary per year** (each year from the current one to the horizon's year): year-end net worth; difference vs budget; income, expenses and reserves totals for the year (as `DashboardCalculator.monthlyFlows`/`yearTotals` with that plan's entries — closed months are actuals, open/future months follow the plan).
- **Grid cells** for one scenario: per category per month the scenario's planned value (open/future) or actual (closed), and a flag where it differs from the budget's value.

## Forecast screen (rebuilt)

- **Left panel:** "Budget" (always first) and the scenarios, each with a checkbox "compare" and a selection highlight. Buttons: New scenario… (name; copies the budget), and per scenario a menu: Rename…, Duplicate…, Refresh from budget (shows the report), Delete… (confirm).
- **Top bar:** horizon picker (End of this year / 2 years / 5 years / 10 years, default 2 years).
- **Tabs:**
  - **Compare** — Swift Charts net-worth lines for Budget and each checked scenario (distinct colours, legend, hover shows each line's value for the month); below, the summary table (rows = plans, column groups per year: year-end net worth, Δ vs Budget, income, expenses, reserves).
  - **Differences** — for the selected scenario: the list of differences (added / removed / changed with field changes) each with a checkbox; **Apply to budget…** (confirmation listing the ticked items) and **Undo last apply** (enabled when an un-undone application exists; shows the undo report).
  - **Grid** — the month-by-month grid (categories × months for the horizon's years, with the year picker limited to the horizon) for the selected scenario; cells that differ from the Budget are highlighted; clicking a cell opens the planned occurrences for that month with Edit…/Remove… (scenario-scoped, same sheets as the Budget grid), and section headers have "+ Add item" (scenario-scoped). Selecting "Budget" shows the budget read-only with a hint to edit it in the Budget grid.
- The old scenario panel (preview, confirm, un-confirm) and the "Planned"/"Spreadsheet plan"/"Reserved" group handling on this screen are removed.

## Also in this project

- Fix (parked from project 1): removing a **one-off** via "this and all following" must not set `excludeFromAutoForecast`.

## Testing

BudgetCore (XCTest): migration (columns, cascade, legacy conversion); budget filter (scenario entries never affect Dashboard/Budget/projection); create/duplicate copy entries + exceptions; scenario edits set change markers (occurrence, following split, add, remove-at-first → tombstone); refresh (unchanged re-copied; changed/removed re-applied; missing source reported); differences; apply (added/removed/changed effects on the budget, current-month boundary, anchor kept) and undo (exact restore; modified-after-apply reported; only latest undoable); comparison (net worth series per plan, yearly summary, grid diff flags) on fixtures. App: build; manual check on a database copy.
