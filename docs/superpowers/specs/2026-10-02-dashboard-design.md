# Dashboard Landing Page — Design Spec

## Overview

Add a **Dashboard** screen as the app's landing page: one glanceable view of net worth since 2020, how each year and month is tracking, what needs attention, and — front and centre — how fresh the imported data is, with import launchable from the same screen.

**Guiding principle: one timeline, actuals and confirmed forecast together.** In the original spreadsheet, budget (what happened) and confirmed forecast (what's expected) lived in the same place. The app split them across the Budget and Forecast screens. On the dashboard they are combined: everything with a time dimension shows actuals and the confirmed forecast on one axis, visually distinguished — **solid = actual, hatched/dashed = forecast, and the current month shows both**.

A visual mockup accompanies this spec in the session where it was produced. This document is the authority; where the two differ, this document wins.

## Current state (verified against the code and the live database)

- **Landing page is Import.** `ContentView` defaults `selection` to `.importReview`. `AppScreen` has 8 cases (Import, Uncategorized, Budget, Forecast, Net Worth, Rules, Categories, Accounts) in three sidebar sections.
- **Net worth history exists as data.** 444 balance snapshots (monthly, Jan 2020 – Feb 2026, across 6 accounts). `BudgetGridViewModel.netWorthTotal(year:month:)` produces a carried-forward month value; `netWorthChange(year)` is the Dec-to-Dec change (and is `nil` for 2020, which has no prior December). Nothing charts any of it — the app uses no `Charts` anywhere.
- **Forecast net worth is a formula in an App-target view model.** `ForecastViewModel.forecastNetWorth(atEndOf:)` = current net worth (latest snapshot per account, plus transactions after it for `.imported` accounts) + the sum of `ForecastCalculator.confirmedNetWorthImpact` for every month after `latestRealMonth` (month of the latest transaction) through December. Headlines today: Dec 2026 £209,832.70 (↑36.4% vs Dec 2025), Dec 2027 £271,292.60 (↑29.3%). Untested and private to that view model.
- **The Forecast grid already flips months to actuals** (`isActual`: month ≤ `latestRealMonth`), but only wholesale — a month is entirely actual or entirely forecast. There is no "this month so far, plus what's still expected" view anywhere.
- **The data is stale.** Latest transaction in the database is 14 Feb 2026; today is October 2026. The only `ImportBatch` is the original Numbers migration (23 Sep 2026). "Last import date" and "data is current through" are different facts and both matter.
- **Snapshots are start-of-month balances dated the 1st.** Month-over-month snapshot differences line up with the *following* month's transaction totals (e.g. Nov→Dec +£7.2k vs November transactions +£10.0k, but −£4.4k for December), so a snapshot dated `YYYY-MM-01` is the balance at the start of that month. All net worth figures on the dashboard use the app's existing convention unchanged (a month's value is the latest snapshot at or before that month's end).
- **Historical transactions are monthly per-category aggregates**, dated mid-month (e.g. 25 rows on 14 Feb 2026), imported from the spreadsheet. The CSV from the bank (`44116660_…csv`, Lloyds Classic: 16 Feb → 29 Sep 2026, 660 rows, with a running **Balance** column) is real per-transaction data from where the spreadsheet stopped.
- **Tracking mode today does two things.** (1) `ContentView.importableAccounts` lists only `.imported` accounts, so the Import screen's picker offers none of the six real accounts (all `manual`). (2) For `manual` accounts the balance is the latest snapshot only — transactions never move it; for `.imported` accounts it is the latest snapshot plus transactions dated after it. Budget/Forecast actuals read transactions from *all* accounts regardless of mode.
- **Import entry points live inside `ImportView`**: two buttons, two `fileImporter`s, the CSV mapping wizard sheet, the PDF layout sheet, and `handlePickedFile`/`handlePickedPDF`. `ImportViewModel` is already owned by `ContentView`, so staging state survives navigation.

## Goals

- A Dashboard screen that becomes the default landing page, first item in the **Overview** sidebar section.
- Show, in this order: data freshness + import; net worth evolution since 2020 with forecast; year-over-year net worth change since 2020; current month tracking; year at a glance (monthly income/expenses/net, actual + forecast); top categories this month; needs attention; upcoming bills; account balances.
- Import can be **started** from the dashboard (account picker, Import CSV…, Import PDF…); progress and review stay on the Import screen.
- Every figure that also appears on another screen (year-end forecast, current net worth, "expected" amounts, YoY change) comes from the same code path, so the screens can never disagree.
- Light and dark mode; no hardcoded colors outside chart series hues (which use system palette colors).

## Non-goals

- No change to forecast math, scenario behavior, or how `latestRealMonth` is defined. The dashboard always shows the **confirmed** forecast, never a selected scenario's preview.
- No widget customization, reordering, or hiding.
- No Budget-grid change. Hiding future months in the Budget grid is a separate pending sub-project; it will reuse the blend rule defined here (see "Actual + forecast") but the dashboard does not depend on it.
- No change to net worth semantics or the snapshot convention.
- No notifications, background refresh, or auto-import.

## Actual + forecast: one timeline

All time-based cards share a single month classification, computed once in BudgetCore (`MonthBlend`), so the cards cannot disagree.

Let **D** = the data-through date (latest transaction date, any account) and **T** = today (UTC calendar).

| Month M | Class | Values |
|---|---|---|
| M ≤ month(D) and M is **not** T's month | **actual** | transaction totals only (identical to the Forecast grid's `isActual` rule) |
| M = T's month and month(D) = M (some transactions already imported this month) | **blended** | actual so far **+ remaining expected**: confirmed-forecast occurrences dated *after* D through month end, per category |
| M = T's month and month(D) < M (nothing imported this month yet) | **forecast** | full-month confirmed forecast, shown with the note "No <month> transactions imported yet" |
| M > month(D), M ≠ T's month | **forecast** | full-month confirmed forecast |

Notes:

- "Remaining expected" is built with `FrequencyExpander.amount(for:in:)` over a `PayPeriod` from the day after D to the month's last day; no new expansion logic. A bill already paid (occurrence date ≤ D) is therefore not double-counted; an expected bill that hasn't shown up simply drops out of the remainder once its date passes.
- Everything is per category and rolls up through `CategoryGroup` exactly like the Budget/Forecast grids; transfer categories are excluded from income/expense totals (as `confirmedNetWorthImpact` does).
- A month that is "actual" because it is the last data month is treated as complete even if the data stops mid-month — the same simplification the Forecast grid already makes. (Example: if only the 14 Feb aggregate exists, February reads as a full actual month.)
- Uncategorized transactions have no category type, so they cannot be placed under Income or Expenses; the cards that need a type carry a footnote when any are present in the period ("N uncategorized transactions aren't included").
- **Sign convention:** money is stored signed (expenses negative). Cards display Income and Expenses as positive magnitudes and Net as signed; internal over/under comparisons use magnitudes.

## Screen layout

`ScrollView` containing cards on an adaptive grid (cards reflow to a single column below ~900pt rather than truncating; minimum card width ~280pt). Wide-window arrangement, top to bottom:

1. **Data freshness & import** — full width.
2. **Net worth evolution** — full width (line chart; headline and year-end forecasts in its header).
3. **Year-over-year change** (½) + **Current month** (½).
4. **Year at a glance** — full width (monthly actual + forecast).
5. **Top categories this month** (½) + **Needs attention** (½).
6. **Upcoming bills** (½) + **Accounts** (½).

Window title is "Dashboard" via the existing `.navigationTitle(selection?.rawValue …)`. No toolbar items. Each card header carries a trailing link to its detail screen (`Net Worth ›`, `Forecast ›`, `Budget ›`) that sets the sidebar selection.

### 1. Data freshness & import

- **Facts shown:** last import (`max(importBatch.importedAt)` and its `sourceFileName`) and data-through date D.
- **State:** *Up to date* when D is ≤ 31 days before today (neutral card, green check). *Behind* when older (amber card, warning icon, "N months behind" using whole elapsed months via the UTC calendar; "N days behind" under a month). *No data* when there are no transactions or no import batches ("Nothing imported yet").
- **Import controls:** account picker (see "Import prerequisites"), **Import CSV…** and **Import PDF…**. Choosing a file runs the exact same flow as today (file picker → mapping wizard if the account has no profile → staging); when staging begins the app navigates to the Import screen. The account selection is shared with the Import screen's "Import into" picker.
- **Other states:** no accounts at all → "Add an account to import into" with an `Accounts ›` link. Staging in progress → "Import in progress…" + `View progress ›`. Awaiting review → "Import ready to review" + `Resume review ›`. Buttons are hidden while either applies (same rule as `ImportView`).

### 2. Net worth evolution (line chart, since 2020)

- **Headline:** current net worth (GBP), "as of" date = latest of (last snapshot date, latest transaction date of `.imported` accounts), and change vs the previous month. Alongside it, two forecast stat blocks — Dec <thisYear> and Dec <nextYear> — each with the value and "↑/↓ x% vs Dec <previous year>", identical to the Forecast screen headlines (same YoY baseline rule: the real prior December when covered by real data, otherwise the forecast one). Link: `Forecast ›`.
- **Chart (Swift Charts):** the full history — **every month from January 2020** — as a solid **actual** line, continuing as a **dashed forecast** line to December of next year; year gridlines on the x axis labelled 2020…2027; a dot on the two year-end forecast points; a labelled vertical "Today" rule. No range picker: the point of this card is the whole 2020→now→forecast shape. Hover shows month and value. Light area fill under the actual line only. Dash style (not just color) distinguishes forecast from actual.
- **Series definitions:** *actual* = month value per month using the same formula as `BudgetGridViewModel.netWorthTotal`. *forecast* = starts at the current net worth at `latestRealMonth` and adds `confirmedNetWorthImpact` month by month; its December points **must equal** the Forecast screen's headline figures exactly.
- The forecast line starts at `latestRealMonth`, not at today. The "Today" rule marks the real current date, so while data is stale the rule sits inside the dashed region — deliberate: it shows how far behind the data is.
- Net worth for `manual` accounts is snapshot-based, so after a later import the actual line runs flat from the last snapshot to the data-through month (carry-forward). When the latest snapshot is older than the data-through month, the card shows an amber banner: "Balances were last updated <date>, so the forecast restarts from them. Update balances to correct it." (see "Import prerequisites").

### 3. Year-over-year change (bar chart, since 2020)

- One bar per year from **2020** to next year: the change in net worth over the year, in £ (value label on each bar; hover also shows % of the previous year-end).
- **Definition:** Dec-to-Dec, using the same function as the Budget grid (`netWorthChange`) for 2021 onward. **2020 has no prior December** (the first snapshot is Jan 2020), so its bar is measured from the first available month to Dec 2020 and is marked with an asterisk and the footnote "2020 measured from Jan 2020 (first data)".
- **Actual vs forecast, same visual language as the line:** completed years are solid bars. The current year is a **two-tone stacked bar** — the part already realised (latest actual net worth minus the prior December) solid, the remainder to the forecast December hatched. Next year is fully hatched. Negative years draw below the axis in the system red; positive in the accent/green used elsewhere.
- Link: `Net Worth ›`.

### 4. Current month

- **Month** = calendar month of today (UTC). Header: "October 2026 · day 2 of 31".
- **Rows:** Income, Expenses, Net. Each shows *actual so far*, *expected for the full month* (a progress meter with a marker at the fraction of the month elapsed), and **projected month-end** (= actual + remaining expected, per the blend rule). Expenses over expected turn red.
- **Actual** = confirmed transactions dated in the month, by category type (income / expense; transfers excluded), via `BudgetGridCalculator.calendarTotalsLookup` / `categoryTotalForCalendarMonth`.
- **Expected** = `ForecastCalculator.confirmedTotal` summed over categories of that type for the whole calendar month — **always from the forecast, independent of `isActual`**. (The Forecast grid hides expected amounts once a month has transactions, so the dashboard cannot read the grid's per-cell totals.)
- **No actuals yet this month** → projected = expected, with the note "No <month> transactions imported yet."
- Uncategorized footnote per the common rule.

### 5. Year at a glance (the spreadsheet view: actual + forecast in one row of months)

- **Chart:** 12 monthly clusters for the selected year — **Income** and **Expenses** bars with the **Net** value as a marker line — with ◀ ▶ to step through years (2020 … next year; default = current year, disabled at the ends).
- **Month classes** per the blend table: actual months solid; the current month a two-tone bar (actual solid + remaining expected hatched); future months hatched. Past years are entirely solid (they are the Budget grid's totals); the next year is entirely hatched.
- **Totals strip under the chart:** the selected year's **Income / Expenses / Net saved**, each as *projected full-year* with "of which actual to date £x" beneath it — the number the spreadsheet's year column gave. For past years the two numbers are identical and the "of which" line is omitted.
- Footnotes: uncategorized excluded; "Forecast months use confirmed entries only."
- Link: `Budget ›` for actual years, `Forecast ›` for the current/next year.

### 6. Top categories this month

Expense categories **rolled up by `CategoryGroup` exactly as the Budget/Forecast grids do**. Top 5 by **projected** month-end spend (actual + remaining expected). Each row: name, *actual of expected*, mini-meter, and the over-flag (actual > expected → red with "+£overage"). No actuals yet → "expected £x" without a meter. A category with actual spend but no expected amount shows the actual with an "unplanned" label. Link: `Forecast ›`.

### 7. Needs attention

Up to two items, each with a link; clear states show a green check:

- **Uncategorized transactions** — count of transactions with `categoryId == nil` or status `.pendingReview` (same predicate as `UncategorizedTransactions.fetch`) → `Uncategorized`.
- **Stale balances** — accounts whose latest snapshot is more than 45 days old, **excluding `.imported` accounts** (their balance already includes later transactions): "N balances not updated since <oldest date>" → `Net Worth`.

### 8. Upcoming bills

Next 30 days from today. Source: the **confirmed** forecast entries — the same filter `ForecastCalculator.confirmedTotal` applies (entry enabled; status `.auto`/`.manual`/`.confirmed` in an enabled group; `.hypothetical` excluded), extracted into a shared `ForecastCalculator.confirmedEntries(entries:groups:)` so the dashboard cannot drift from it — whose category type is `.expense` (income and transfers are not bills), expanded with `FrequencyExpander.occurrences(for:in:)` over `[today, today + 30 days]`. Sorted by date; first 5 listed as `date · category · amount`, then "+ N more ›" → Forecast.

### 9. Accounts

Per-account GBP balance from `NetWorthCalculator.accountBalances`, largest first, top 4 then "+ N more ›" → Net Worth. Credit accounts display as "<amount> owed", colored by their stored (negative) sign so debt reads red, exactly as the Net Worth screen does. Non-GBP accounts show their native amount with the GBP equivalent.

## Import prerequisites (what "manual" means for the dashboard)

The six real accounts are `manual`, and that is the right mode for them: it matches the spreadsheet (balances are entered periodically; transactions feed Budget/Forecast actuals; nothing double-counts). It becomes a problem in exactly two ways, both small:

1. **The picker excludes them.** `ContentView.importableAccounts` lists only `.imported` accounts, so you cannot import the Lloyds Classic CSV into Lloyds Classic. **In scope for this spec:** the import account picker (Import screen and dashboard card) lists **all accounts**, ordered with the last-used account first. Tracking mode keeps its single meaning — whether transactions move the account's balance — and nothing else.
2. **Importing does not advance net worth for a `manual` account — and it moves the forecast.** After importing the Feb → Sep CSV, the Budget grid and current-month card update, but net worth stays on the last typed balance (1 Feb 2026) until a new balance is entered. Worse, the forecast is "current net worth + impacts of months after the latest transaction month", so importing through September makes March–September count as actual months while their effect is in no balance: Dec 2026 would fall from £209.8k to roughly £176k (about 3 forecast months, ≈£4.8k each, added to the unchanged £161.3k) purely as bookkeeping. The mockup's "After importing the CSV" state shows this, with a warning banner on the net worth card. Flipping Lloyds Classic to `imported` would not fix this cleanly either: its Feb 2026 snapshot (£33,321.04) plus the spreadsheet's mid-Feb aggregate (+£2,402.16) plus the CSV's net flow would land about £1.6k away from the bank's own figure (£27,596.28 on 29 Sep), because the spreadsheet's early-February totals don't match the bank. The CSV's **Balance** column is the clean fix.

**Recommended follow-up sub-project (separate spec, not part of this one — needs your yes):** *statement balances*. The CSV wizard maps the optional Balance column; on commit, the import records `BalanceSnapshot`s from it — one per month start covered by the statement (the balance after the last transaction before the 1st) plus a closing snapshot at the last transaction date. That reproduces what the spreadsheet's monthly balance row did, automatically, for the account being imported, in either tracking mode. The other five accounts (ISAs, joint, EUR) have no statement and keep being updated by typing balances; the dashboard's stale-balances item reminds you.

Because of the forecast effect above, I recommend landing *statement balances* **before** the first real import (build order: dashboard and statement balances can be planned together; the dashboard does not depend on it technically). Until it lands, the dashboard degrades honestly — the net worth card shows a warning banner whenever the latest snapshot is older than the data-through month, the net worth line runs flat at the last snapshot (carry-forward), the freshness card shows data-through D, and the stale-balances item names the accounts to update.

## Architecture

New logic is pure and lives in `BudgetCore` (unit-tested); the App layer only loads and renders.

### New in BudgetCore (`Sources/BudgetCore/Dashboard/`)

- `MonthBlend` — classifies months (actual / blended / forecast) for `(D, T)` per the table above and returns per-category blended values for a month.
- `DashboardCalculator` (pure static functions): `dataFreshness(batches:transactions:today:)`, `currentMonth(...)`, `yearAtAGlance(year:...)`, `netWorthYoY(...)`, `topCategories(...)`, `upcomingBills(...)`, `attentionItems(...)`. Each returns a small value type (`DataFreshness`, `CurrentMonthTracking`, `MonthlyFlow`, `YearChange`, `CategorySpend`, `UpcomingBill`, `AttentionItems`). All take `today: Date` as a parameter so tests never depend on the clock.

### Shared computation extracted (so dashboard and existing screens cannot diverge)

- `ForecastProjector.monthlyProjection(...)` in `BudgetCore/Forecasting` — the month-by-month walk currently private to `ForecastViewModel`, returning the running net worth for each month after `latestRealMonth` through a target December. `ForecastViewModel.forecastNetWorth(atEndOf:)` reads the December point from it.
- `ForecastCalculator.confirmedEntries(entries:groups:)` — the entry filter currently inline in the private `total(...)`; `total` uses it (no behavior change).
- `NetWorthCalculator.monthEndNetWorth(accounts:snapshots:transactions:rate:year:month:)` — the formula `BudgetGridViewModel.netWorthTotal` and `ForecastViewModel.realNetWorth` each implement today. Both delegate to it. `BudgetGridViewModel.netWorthChange` keeps its behavior; the 2020 first-data baseline lives in `DashboardCalculator.netWorthYoY`, not in the grid.
- **Hard requirement:** these refactors must leave existing numbers byte-identical. Acceptance check on the live database before and after: Forecast screen Dec 2026 = £209,832.70, Dec 2027 = £271,292.60, and the Budget grid's per-year net worth change unchanged. Characterization tests pin these on a fixture before the extraction.

### New in App (`App/Dashboard/`)

- `DashboardViewModel` (`@MainActor ObservableObject`): one `load()` doing a single batched `dbQueue.read` (accounts, snapshots, transactions, categories, category groups, forecast groups/entries, import batches, exchange rate), then computing every display model once and publishing them. Views are pure functions of those models — no calculation in `body` (the Forecast scroll-frame recompute bug is the cautionary precedent). Year-at-a-glance for the selected year is computed from the already-loaded data when the year changes (cheap, no re-read). `load()` runs on appear, so returning from Import after a commit refreshes it.
- `DashboardView` and one small view per card, in separate files (each independently previewable). The two charts (`NetWorthLineChart`, `YearOverYearChart`) and `YearAtAGlanceChart` are Swift Charts views taking plain value arrays.
- `DashboardViewModel` takes `today` as an injectable value (defaults to `Date()`).

### Changes to existing files

- `ContentView.swift`: add `case dashboard = "Dashboard"` to `AppScreen` immediately after `.importReview` (so Overview's first member is Dashboard and the Overview section keeps its position), `systemImage` `square.grid.2x2`, `sidebarSection` "Overview"; default `selection = .dashboard`; own a `@StateObject DashboardViewModel`; pass a `navigate: (AppScreen) -> Void` closure and the shared `ImportViewModel`/import-account binding into `DashboardView`; `importableAccounts` becomes all accounts (see Import prerequisites).
- **Import flow extraction:** move the pickers, wizard sheets and `handlePicked*` logic out of `ImportView` into a reusable `ImportFlowHost` that exposes "start CSV" and "start PDF" actions to its content and calls an `onStarted` closure at the moment staging begins (after picking a file whose profile exists, or after the mapping/layout wizard saves — not on cancel). `ImportView` and the dashboard's import card both use it; the Import screen's behavior is otherwise unchanged.
- `ForecastViewModel.swift` / `BudgetGridViewModel.swift`: delegate to the extracted shared functions above; no behavior change.
- `project.yml`/Package: no new dependency (`Charts` is a system framework).

## Error and empty states

| Situation | Behavior |
|---|---|
| Fresh install / no transactions | Freshness card "Nothing imported yet"; charts show "No history yet"; other cards show a one-line empty message |
| Fewer than two years of snapshots | YoY chart shows the bars it can; line chart unaffected |
| No forecast entries | Net worth card shows the actual line only with "No forecast yet"; year-at-a-glance forecast months are empty; upcoming bills "None in the next 30 days" |
| No `latestRealMonth` | Forecast projection omitted (line shows actual only), year-end stats show "—" |
| `load()` throws | Inline error banner at the top (same pattern as other screens); stale content left in place |
| No accounts | Import card empty state with `Accounts ›` link |

## Testing

- **BudgetCore (XCTest):**
  - `MonthBlend` — all four table rows; D on the last day of the month; D on the 1st; no transactions this month; a bill paid before D is not counted in the remainder; a category with actual but no expected; D in a prior year.
  - `DashboardCalculator` — freshness thresholds (31-day boundary, months vs days wording, no data); current-month actual/expected/projected including the case where the month has transactions yet expected must still come from the forecast; top-categories group roll-up, ordering by projected, over-expected and unplanned; year-at-a-glance for a past year (all actual), the current year (actual + blended + forecast), and next year (all forecast), with totals "of which actual"; YoY including the 2020 first-data baseline and a negative year; upcoming-bills window edges (today, day 30, entry ending inside the window, hypothetical excluded, income/transfers excluded); attention items (45-day boundary, imported accounts excluded from stale-balances).
  - `ForecastProjector` — December points equal the pre-extraction `forecastNetWorth` on a fixture; `monthEndNetWorth` equals the old `netWorthTotal` on a fixture; `confirmedEntries` leaves existing `ForecastCalculatorTests` green unchanged.
- **App layer:** clean `xcodebuild`, then a live walkthrough against the real database in both states — today's stale state, and after importing the real CSV into Lloyds Classic on a **copy** of the database (or a throwaway account, removed afterward) — confirming import-from-dashboard hands off to the Import screen with progress, that the current month turns blended, and that light and dark mode render correctly.

## File summary

- New: `Sources/BudgetCore/Dashboard/MonthBlend.swift`, `Sources/BudgetCore/Dashboard/DashboardCalculator.swift` (+ value types), `Sources/BudgetCore/Forecasting/ForecastProjector.swift`, `App/Dashboard/DashboardViewModel.swift`, `App/Dashboard/DashboardView.swift`, per-card and per-chart views under `App/Dashboard/`, `App/Import/ImportFlowHost.swift`.
- Modified: `App/ContentView.swift`, `App/Import/ImportView.swift`, `App/Forecast/ForecastViewModel.swift`, `App/Budget/BudgetGridViewModel.swift`, `Sources/BudgetCore/NetWorth/NetWorthCalculator.swift`, `Sources/BudgetCore/Forecasting/ForecastCalculator.swift` (extract `confirmedEntries`; existing `ForecastCalculatorTests` must pass unchanged).
- New tests: `MonthBlendTests`, `DashboardCalculatorTests`, `ForecastProjectorTests`, plus a `monthEndNetWorth` test in the existing NetWorth calculator tests.

## Follow-ups (not part of this spec)

1. **Statement balances** (described under Import prerequisites): CSV Balance column → balance snapshots. Recommended next; without it, importing leaves net worth on the last typed balance.
2. **Budget grid month-hiding** (the other pending part of the original request): hide future months and show the blended current month, reusing `MonthBlend`.
3. **Sidebar section ordering** is still derived from enum declaration order (a deferred minor from the HIG pass); inserting `.dashboard` is safe as specified, but an explicit `SidebarSection` enum would remove the fragility.
4. **CSV mapping wizard has no Cancel button** (pre-existing); relevant because the dashboard adds a second entry point into it.
