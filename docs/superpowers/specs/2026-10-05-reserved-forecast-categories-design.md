# Reserved Forecast Categories — Design Spec

## Overview

The original spreadsheet kept the forecast realistic with one hand-typed row, **"Remaining for expenses"**: a flat **£2,000/month** (Mar–Dec 2026) standing in for all the day-to-day spending that was never planned line by line — groceries, eating out, transport, holidays, "other". None of those categories had future amounts of their own. The app never imported that row, so its forecast has no equivalent, and forecast expenses (~£2.6k/month) sit far below actuals (~£5.2k in Jan 2026).

This spec adds **reserved categories**: forecast-only expense buckets that hold an allowance for expected-but-uncategorised spending, shown **separately** from ordinary categories in the Forecast grid, the Budget grid and the Dashboard. It replaces the single catch-all category added with the Dashboard (`2026-10-02-dashboard-design.md`, "Catch-all category"), and a one-off tool seeds the reserve and the spreadsheet's other planned amounts that the app's forecast is missing.

## Current state (verified 2026-10-05)

- `Category.isCatchAll` (migration `addIsCatchAllToCategory`): at most one expense category; designating it promotes its `.auto` entries to `.manual`; `AutoForecastGenerator` skips it; `DashboardCalculator.catchAllAllowance` and the "forecast realism" attention item read it; Categories screen has the toggle. **No category is currently designated.**
- `ForecastCalculator.confirmedEntries`: enabled, not `.hypothetical`, in an enabled group. `confirmedNetWorthImpact` **excludes transfer categories**.
- `AutoForecastGenerator` owns the system-managed "Detected recurring" group and skips entries whose status is not `.auto`.
- Category pickers: `ReviewView`, `UncategorizedView`/`UncategorizedViewModel`, `RulesView`/`RulesViewModel`, `GridDrillDownSheet`, `ScenarioItemFormView` (Forecast).
- One-off executables already exist for data work on the real database: `MigrateHistory`, `MigrateAccountBalances`, `SeedCategoryGroups`.
- Real database: "Confirmed other expenses" (74 transactions, −£14.3k) and "Confirmed other SIGNIFICANT expenses" (37, −£13.0k) hold spreadsheet history. Enabled expense forecast entries are all `.auto` in "Detected recurring", including "Confirmed other expenses" −£171.39/mo and "House Decor / Move Expenses" −£60.25 every 2 months.

### Spreadsheet vs app forecast (`Budget.numbers`, main table, 2026)

| Item | Spreadsheet | App forecast today |
|---|---|---|
| Remaining for expenses | £2,000/mo Mar–Dec (Feb: residual formula) | — |
| Rent | £2,800/mo, £2,900 from Aug | −£2,171.08/mo (auto) |
| Car Payments | £351.25/mo | — |
| Council Tax | £350/mo from Apr | — |
| Transfer: Lloyds Joint | £2,000/mo | — |
| UK Taxes | £3,200 Dec (2025: £1,032 Dec) | — |
| Accountant | £720 Dec (2025: £720 Nov) | — |
| Car Insurance | £1,200 May (2025: £1,066 May) | — |
| Car Service | £1,000 May | — |
| Car MOT | £150 Aug (2025: £51 Jul) | — |
| Car Tax | £195 Jan (2025: £453 Jan) | — |
| TV License | £180 May | −£174.50 annually (auto) |
| Thames Water | £350 Mar and Sep | −£324.41 every 6 months (auto) |
| Car Subscriptions | £119 Feb | −£119 annually (auto) — matches |

## Goals

- Any number of **reserved categories**: forecast-only expense buckets, each with one or more allowance entries (monthly, annual, one-off; confirmed or hypothetical).
- Shown as a separate **Reserved** block, with its own subtotal, in the Forecast grid, the Budget grid and the Dashboard.
- Ordinary categories whose spending a reserve covers can be marked **excluded from the auto-forecast**, so nothing is counted twice.
- Seed the real database from the spreadsheet: the £2,000/month reserve and the missing planned amounts.

## Non-goals

- Sinking funds / reserved balances that accumulate and are drawn down; "available vs reserved" net worth.
- Linking a reserve to the categories it covers or showing "used £X of £Y".
- Counting unreviewed transactions anywhere (they stay excluded, as today).
- The Import / Net Worth tab clean-up (separate follow-up, see end).

## Data model

Schema migration `replaceCatchAllWithReserved` (generic — no personal data):

- `category.isReserved BOOLEAN NOT NULL DEFAULT 0` — the category is a forecast-only reserve. Only `expense` categories may be reserved.
- `category.excludeFromAutoForecast BOOLEAN NOT NULL DEFAULT 0` — the auto-forecast never creates, updates or deletes entries for this category.
- Data step: any category with `isCatchAll = 1` gets `excludeFromAutoForecast = 1` (it keeps its manual entries); then `isCatchAll` is dropped.
- `Category` gains `isReserved` and `excludeFromAutoForecast`; `isCatchAll` is removed. `CatchAllCategory`/`CatchAllError` are deleted.

**Reserved forecast group:** a `ForecastGroup` named "Reserved" (`isSystemManaged = false`, enabled), created on demand by `ReservedCategories.ensureGroup(db:)`. Reserve allowances live there by convention so they read as one block; correctness never depends on which group an entry is in.

`BudgetCore/Forecasting/ReservedCategories.swift` (replaces `CatchAllCategory.swift`):

- `create(db:name:) throws -> Category` — inserts an expense category with `isReserved = true`, no group. Name must be non-empty and unique across categories (`ReservedCategoryError.duplicateName`).
- `ensureGroup(db:) throws -> ForecastGroup`.
- `delete(db:categoryId:)` — deletes the reserve and its forecast entries (allowed because a reserve never has transactions or rules).
- `setExcludedFromAutoForecast(db:categoryId:_:)` — sets the flag; when turning it on, deletes the category's `.auto` entries (manual/confirmed/hypothetical entries are kept).

## Rules

**Never holds transactions.**
- `Transaction` and `Rule` writes go through a database trigger pair (`BEFORE INSERT/UPDATE OF categoryId` on `transaction_` and `rule`) that raises if the target category is reserved; Swift callers surface it as `ReservedCategoryError.cannotAssignTransactions`.
- Every category picker filters out reserves: Review, Uncategorized, Rules, Budget-grid drill-down, and the scenario item form's category list (scenario items for reserves are added from the Reserved section instead, see UI).
- `CategorizationService.categorize`/`categorizeBatch` drop reserves from the `categories` they are given before building the model's candidate names, so the on-device model can never suggest one. `RuleLearner` only learns from confirmed transactions, which can never be in a reserve.

**Month treatment** (applies to the Forecast grid, Budget grid and Dashboard):

| Month class (`MonthBlend`) | Reserve contributes |
|---|---|
| actual (past) | £0, shown as "—" |
| blended (current) | the full confirmed allowance (actual is always 0, so "larger of actual and expected" = allowance) |
| forecast (future) | the full confirmed allowance |

Reserves are expense-typed, so they count in `confirmedNetWorthImpact` and the net-worth projection with no change to that function.

**Auto-forecast:** `AutoForecastGenerator` skips categories where `isReserved || excludeFromAutoForecast` (replaces the `isCatchAll` skip).

## Seeding the real database — `Sources/SeedForecastPlan`

A one-off executable target (same pattern as `SeedCategoryGroups`), run once against the real database after the app migration has run. Usage: `swift run SeedForecastPlan <path-to-budget.sqlite> [--dry-run]`. It is rehearsed on a copy first (`BUDGET_DB_PATH`), prints every change, runs in one transaction, and is idempotent (a second run reports "no changes"). It matches categories by exact name and aborts without writing if any name is missing.

All amounts are signed as the app stores them (expenses/transfers out negative). "From Oct 2026" means `startDate` 2026-10-01; annual entries are dated the 1st of their month, `frequency = annually`, `interval = 1`; new entries are `status = .confirmed`, `isEnabled = true`, `note = "From spreadsheet plan"`.

1. **Reserve:** create reserved category "Remaining for expenses" with a monthly −£2,000.00 entry from Oct 2026 in the "Reserved" group.
2. **Covered by the reserve** — set `excludeFromAutoForecast` (which deletes their `.auto` entries, including −£171.39 and −£60.25): Groceries; Eating Out; Delivery; Meals/Drinks; Commute / Public Transport; Car Parking Permit; Car Parking; Car Tolls; Car Charge; Car Gas; Car Fines; Car Maintenance/Accessories; Sport; Holidays / Travel / Events; House Decor / Move Expenses; Optician; Confirmed other expenses; Confirmed other SIGNIFICANT expenses.
3. **Missing planned items**, in a new manual group "Spreadsheet plan" (`isSystemManaged = false`):
   - Monthly from Oct 2026: Car Payments −£351.25; Council Tax −£350.00; Transfer: Lloyds Joint −£2,000.00.
   - Annual: UK Taxes −£3,200.00 (Dec 2026); Accountant −£720.00 (Dec 2026); Car Insurance −£1,200.00 (May 2027); Car Service −£1,000.00 (May 2027); Car MOT −£150.00 (Aug 2027); Car Tax −£195.00 (Jan 2027).
4. **Corrections to auto entries** — the existing `.auto` entry is updated in place and set to `.manual` (so the auto-forecast keeps it):
   - Rent → −£2,900.00 monthly from Oct 2026.
   - TV License → −£180.00 annually from May 2027.
   - Thames Water → −£350.00 every 6 months from Mar 2027 (Mar and Sep).

**Open question for review — UK Taxes and Accountant are `transfer` categories.** `confirmedNetWorthImpact` ignores transfers, so seeding them as-is shows them in the Forecast grid but does **not** lower the projected net worth by £3,920 in December. Recommendation: the seed tool changes both categories to `expense` (they are money leaving, not moving between own accounts); their history then appears under expenses in the Budget grid and Dashboard. Transfer: Lloyds Joint correctly stays a transfer (own account).

## UI

**Forecast screen**
- A **Reserved** section after the expense groups: one row per reserve plus a "Total reserved" subtotal row, included in the expense and net totals, the year total and the net-worth stat. Past months show "—".
- Section header has **Add reserve…** (name + monthly amount + start month → `create` + a monthly entry in the Reserved group). Each reserve row's context menu: Edit allowance (existing `EditForecastEntryView`), Add one-off amount, Rename, Delete reserve (confirmation).
- A scenario can include a reserve change: the scenario item form lists reserves under a "Reserved" heading in its category picker (the one picker that may show them, since it creates forecast entries, not transactions).

**Budget grid** — the same Reserved section and subtotal, read-only; past months "—"; drill-down disabled for reserve rows.

**Categories screen** — the catch-all toggle becomes **"Exclude from auto-forecast"** (expense categories), with help text "Covered by a reserve — the forecast won't detect a recurring amount for it." Reserves are not listed here.

**Dashboard**
- Current month: a separate "Reserved" line (allowance) after the category lines, included in projected spend.
- Year at a glance: reserves are their own segment in the expense bars and their own line in the hover breakdown.
- Top categories: excludes reserves.
- Attention "Forecast realism": shown when no reserved category has an enabled confirmed allowance covering the current month → "No reserve for unplanned spending in the forecast" → `Forecast`. (Replaces the catch-all variant; `catchAllAllowance` is removed.)

## Error handling

- Assigning a transaction or rule to a reserve: blocked in pickers; if attempted anyway, the trigger error is shown as "Reserved categories can't hold transactions."
- Duplicate reserve name: inline "A category with that name already exists."
- Seed tool: missing category name or unexpected existing data → abort with the list, no writes.

## Testing

BudgetCore (Swift Testing, in-memory `DatabaseManager`):
- Migration: `isCatchAll` → `excludeFromAutoForecast`; column dropped; defaults false.
- `ReservedCategories`: create (expense, reserved, unique name), delete (entries removed), exclude flag deletes only `.auto` entries.
- Triggers: inserting/updating a transaction or rule onto a reserve throws; ordinary categories unaffected.
- `AutoForecastGenerator`: skips reserved and excluded categories (no create/update/delete).
- Month treatment: reserve contributes 0 in actual months, allowance in blended and future months — in `BudgetGridCalculator`, the Forecast totals and `DashboardCalculator` current month / year at a glance; Top categories excludes reserves; attention item rules.
- Net-worth projection includes reserve allowances.
- `SeedForecastPlan`: logic lives in a `BudgetCore` function (`ForecastPlanSeeder.apply(db:dryRun:)`) tested on a fixture database with the real category names: expected entries, flags and corrections; second run is a no-op; a missing category aborts with no writes.

Manual: run the seed tool against a copy, open the app with `BUDGET_DB_PATH` on that copy, check the Reserved sections, the Dashboard and the Dec 2026 forecast net worth; then run it on the real database.

## Follow-up (separate, not in this spec)

Import tab: keep the review screen but drop it from the sidebar (show "Review import" only while an import is staging or awaiting review). Net Worth tab: still required (balance entry, full account list, history; five Dashboard links) — consider folding it into Accounts.
