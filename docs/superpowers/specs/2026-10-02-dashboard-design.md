# Dashboard Landing Page — Design Spec

## Overview

Add a **Dashboard** screen as the app's landing page: one glanceable view of net worth history and forecast, how the current month is tracking, what needs attention, and — front and centre — how fresh the imported data is, with import launchable from the same screen. It aggregates data the app already has; it introduces no new stored data except where noted in Architecture.

A visual mockup (interactive: "today / stale" vs "after importing" states) accompanies this spec in the session where it was produced. This document is the authority; where the two differ, this document wins.

## Current state (verified against the code and the live database)

- **Landing page is Import.** `ContentView` defaults `selection` to `.importReview`. `AppScreen` has 8 cases (Import, Uncategorized, Budget, Forecast, Net Worth, Rules, Categories, Accounts) in three sidebar sections.
- **Net worth history exists as data.** 444 balance snapshots (monthly, Jan 2020 – Feb 2026, across 6 accounts). `NetWorthViewModel.history` produces one point per snapshot date; `BudgetGridViewModel.netWorthTotal(year:month:)` produces a carried-forward month-end total. Nothing charts it yet — the app uses no `Charts` anywhere.
- **Forecast net worth is a formula in an App-target view model.** `ForecastViewModel.forecastNetWorth(atEndOf:)` = current net worth (all snapshots, plus transactions for `.imported` accounts) + the sum of `ForecastCalculator.confirmedNetWorthImpact` for every month after `latestRealMonth` (month of the latest transaction) through December. Screen headlines today: Dec 2026 £209,832.70 (↑36.4% vs Dec 2025), Dec 2027 £271,292.60 (↑29.3%). It is untested and private to that view model.
- **The data is stale.** Latest transaction is 14 Feb 2026; today is October 2026. The only `ImportBatch` is the original Numbers migration (23 Sep 2026). "Last import date" and "data is current through" are different facts and both matter.
- **Every account is `manual` tracking**, so none is import-eligible, and the Accounts screen can create accounts but cannot change an existing account's tracking mode (see Follow-ups).
- **Import entry points live inside `ImportView`**: two buttons, two `fileImporter`s, the CSV mapping wizard sheet, the PDF layout sheet, and `handlePickedFile`/`handlePickedPDF`. `ImportViewModel` is already owned by `ContentView`, so staging state survives navigation.

## Goals

- A Dashboard screen that becomes the default landing page, first item in the **Overview** sidebar section.
- Show, in this order: data freshness + import; net worth history with forecast; year-end forecast; current-month tracking; top categories this month; needs-attention; upcoming bills; account balances.
- Import can be **started** from the dashboard (account picker, Import CSV…, Import PDF…); progress and review stay on the Import screen.
- Every figure that also appears on another screen (year-end forecast, current net worth, "expected" amounts) comes from the same code path, so the screens can never disagree.
- Both light and dark mode; no hardcoded colors outside chart series hues (which use the system palette).

## Non-goals

- No change to forecast math, scenario behavior, or how `latestRealMonth` is defined. The dashboard always shows the **confirmed** forecast, never a selected scenario's preview.
- No widget customization, reordering, or hiding.
- No Budget-grid change (hiding future months / current-month blending is a separate pending sub-project; the dashboard's current-month card shares its definitions but does not depend on it).
- No change to Accounts (see Follow-ups for the tracking-mode gap).
- No notifications, background refresh, or auto-import.

## Screen layout

`ScrollView` containing cards on an adaptive grid (cards reflow to fewer columns below ~900pt rather than truncating; minimum card width ~280pt). Wide-window arrangement, top to bottom:

1. **Data freshness & import** — full width.
2. **Net worth** (≈2/3) + **Year-end forecast** (≈1/3).
3. **Current month** (½) + **Top categories this month** (½).
4. **Needs attention** (⅓) + **Upcoming bills** (⅓) + **Accounts** (⅓).

Window title is "Dashboard" via the existing `.navigationTitle(selection?.rawValue …)`. No toolbar items. Each card header carries a trailing link to its detail screen (`Budget ›`, `Forecast ›`, `Net Worth ›`) which sets the sidebar selection.

### 1. Data freshness & import

- **Facts shown:** last import (`max(importBatch.importedAt)` and its `sourceFileName`) and data-through date (`max(transaction.date)`).
- **State:** *Up to date* when the latest transaction is ≤ 31 days before today (neutral card, green check). *Behind* when older (amber card, warning icon, "N months behind" using whole elapsed months via the UTC calendar; "N days behind" when under a month). *No data* when there are no transactions or no import batches ("Nothing imported yet").
- **Import controls:** account picker listing `.imported` accounts only (selection shared with the Import screen's "Import into" picker), **Import CSV…** and **Import PDF…**. Choosing a file runs the exact same flow as today (file picker → mapping wizard if the account has no profile → staging); when staging begins the app navigates to the Import screen.
- **Other states:** no `.imported` accounts → "No account is set to imported tracking" with an `Accounts ›` link and no buttons. Staging in progress → "Import in progress…" + `View progress ›`. Awaiting review → "Import ready to review" + `Resume review ›`. Buttons are hidden while either applies (same rule as `ImportView`).

### 2. Net worth + forecast chart

- **Headline:** current net worth (GBP), "as of" date = latest of (last snapshot date, latest transaction date of `.imported` accounts), and change vs the previous month-end.
- **Chart (Swift Charts):** solid **actual** line from the first month with data to the last month with data; **dashed forecast** line continuing to December of next year; a dot on the two year-end forecast points; a labelled vertical "Today" rule. Range control: 1Y / 3Y / 5Y / All (forecast always shown to its end). Single y-axis. Hover shows month and value. Light area fill under the actual line only. Dash style (not just color) distinguishes forecast from actual.
- **Series definitions:** *actual* = month-end net worth per month using the same formula as `BudgetGridViewModel.netWorthTotal`. *forecast* = starts at the current net worth at `latestRealMonth` and adds `confirmedNetWorthImpact` month by month; its December points **must equal** the Forecast screen's headline figures exactly.
- The forecast line starts at `latestRealMonth`, not at today. The "Today" rule marks the real current date, so while data is stale the rule sits inside the dashed region (e.g. actual ends Feb 2026, rule at Oct 2026) — this is deliberate: it shows how far behind the data is.
- Net worth is snapshot-based for manual accounts, so the actual line ends at the last snapshot month even if transactions were imported later — expected, and the reason for the balances nudge below.

### 3. Year-end forecast

Two stat blocks — Dec *thisYear* and Dec *nextYear* — each with the value and "↑/↓ x% vs Dec <previous year>", identical to the Forecast screen headlines (same YoY baseline rule: real prior December when covered by real data, otherwise the forecast one). Link: `Forecast ›`.

### 4. Current month

- **Month** = calendar month of today (UTC calendar, like the rest of the app). Header: "October 2026 · day 2 of 31".
- **Sign convention:** money is stored signed (expenses negative). The card displays Income and Expenses as positive magnitudes and Net as signed (income + expenses); internal comparisons ("over expected") use magnitudes.
- **Rows:** Income, Expenses, Net. Each shows *actual so far* vs *expected for the full month*, a progress meter, and a marker at the fraction of the month elapsed. Expenses over expected turn red.
- **Actual** = confirmed transactions dated in the month, summed by category type (income / expense; transfers excluded), via `BudgetGridCalculator.calendarTotalsLookup` / `categoryTotalForCalendarMonth`.
- **Expected** = `ForecastCalculator.confirmedTotal` summed over categories of that type for the month's period — **always from the forecast, independent of `isActual`**. (The Forecast grid switches a month to actuals-only once it has transactions; the dashboard must keep both, so it cannot read the grid's per-cell totals.)
- **No actuals yet** → expected only with the note "No <month> transactions imported yet."
- **Uncategorized in the month** → a footnote "N uncategorized transactions this month aren't included", because they have no category type.

### 5. Top categories this month

Expense categories **rolled up by `CategoryGroup` exactly as the Budget/Forecast grids do** (a group's row is the sum of its members). Top 5 by `max(actual, expected)`. Each row: name, actual / expected, mini-meter; actual > expected shows red with "+£overage". Expected-only months (no actuals) show "expected £x" without a meter. A category with actual spend but no expected amount shows the actual with an "unplanned" label.

### 6. Needs attention

Up to two items, each with a link; both clear states shown as a green check:

- **Uncategorized transactions** — count of transactions with `categoryId == nil` or status `.pendingReview` (the same predicate as `UncategorizedTransactions.fetch`) → `Uncategorized`.
- **Stale balances** — `.manual` accounts whose latest snapshot is more than 45 days old: "N balances not updated since <oldest date>" → `Net Worth`.

### 7. Upcoming bills

Next 30 days from today. Source: the **confirmed** forecast entries — the same filter `ForecastCalculator.confirmedTotal` applies (entry enabled; status `.auto`/`.manual`/`.confirmed` in an enabled group; `.hypothetical` excluded), extracted into a shared `ForecastCalculator.confirmedEntries(entries:groups:)` so the dashboard cannot drift from it — whose category type is `.expense` (income and transfers are not bills), expanded with `FrequencyExpander.occurrences(for:in:)` over `[today, today + 30 days]`. Sorted by date; first 5 listed as `date · category · amount`, then "+ N more ›" → Forecast.

### 8. Accounts

Per-account GBP balance from `NetWorthCalculator.accountBalances`, largest first, top 4 then "+ N more ›" → Net Worth. Credit accounts display as "<amount> owed", colored by their stored (negative) sign so debt reads red, exactly as the Net Worth screen does. Balances are shown in the account's native currency with the GBP equivalent for non-GBP accounts.

## Architecture

New logic is pure and lives in `BudgetCore` (unit-tested); the App layer only loads and renders.

### New in BudgetCore (`Sources/BudgetCore/Dashboard/`)

- `DashboardCalculator` (pure static functions): `dataFreshness(batches:transactions:today:)`, `currentMonth(...)`, `topCategories(...)`, `upcomingBills(...)`, `attentionItems(...)`. Each returns a small value type (`DataFreshness`, `CurrentMonthTracking`, `CategorySpend`, `UpcomingBill`, `AttentionItems`). All take `today: Date` as a parameter so tests never depend on the clock.

### Shared computation extracted (so dashboard and existing screens cannot diverge)

- `ForecastProjector.monthlyProjection(...)` in `BudgetCore/Forecasting` — the month-by-month walk currently private to `ForecastViewModel.sumOverForecastMonths`/`computeForecastNetWorth`, returning the running net worth for each month after `latestRealMonth` through a target December. `ForecastViewModel.forecastNetWorth(atEndOf:)` is changed to read the December point from it.
- `ForecastCalculator.confirmedEntries(entries:groups:)` — the entry filter currently inline in the private `total(...)`; `total` is changed to use it (no behavior change).
- `NetWorthCalculator.monthEndNetWorth(accounts:snapshots:transactions:rate:year:month:)` — the formula `BudgetGridViewModel.netWorthTotal` and `ForecastViewModel.realNetWorth` each implement today. Both delegate to it.
- **Hard requirement:** these two refactors must leave existing numbers byte-identical. Acceptance check on the live database before and after: Forecast screen Dec 2026 = £209,832.70, Dec 2027 = £271,292.60, and the Budget grid's per-year net worth change unchanged. Characterization tests pin these on a fixture before the extraction is made.

### New in App (`App/Dashboard/`)

- `DashboardViewModel` (`@MainActor ObservableObject`): one `load()` doing a single batched `dbQueue.read` (accounts, snapshots, transactions, categories, category groups, forecast groups/entries, import batches, exchange rate), then computing every display model once and publishing them. Views are pure functions of those models — no calculation in `body` (the Forecast scroll-frame recompute bug is the cautionary precedent). `load()` runs on appear; returning from Import after a commit therefore refreshes it.
- `DashboardView` and one small view per card, in separate files (each card independently previewable).
- `DashboardViewModel` takes `today` as an injectable value (defaults to `Date()`).

### Changes to existing files

- `ContentView.swift`: add `case dashboard = "Dashboard"` to `AppScreen` immediately after `.importReview` (so Overview's first member is Dashboard and the Overview section keeps its position), `systemImage` `square.grid.2x2`, `sidebarSection` "Overview"; default `selection = .dashboard`; own a `@StateObject DashboardViewModel`; pass a `navigate: (AppScreen) -> Void` closure and the shared `ImportViewModel`/import-account binding into `DashboardView`.
- **Import flow extraction:** move the pickers, wizard sheets and `handlePicked*` logic out of `ImportView` into a reusable `ImportFlowHost` that exposes "start CSV" and "start PDF" actions to its content and calls an `onStarted` closure at the moment staging begins (after picking a file whose profile exists, or after the mapping/layout wizard saves — not on cancel). `ImportView` and the dashboard's import card both use it; behavior of the Import screen is unchanged.
- `ForecastViewModel.swift` / `BudgetGridViewModel.swift`: delegate to the extracted shared functions above; no behavior change.
- `project.yml`/Package: no new dependency (`Charts` is a system framework).

## Error and empty states

| Situation | Behavior |
|---|---|
| Fresh install / no transactions | Freshness card "Nothing imported yet"; chart shows "No history yet"; other cards show a one-line empty message |
| No forecast entries | Year-end cards show current net worth with "No forecast yet"; upcoming bills "None in the next 30 days" |
| No `latestRealMonth` | Forecast projection omitted (chart shows actual only), year-end stats show "—" |
| `load()` throws | Inline error banner at the top (same pattern as other screens); stale content left in place |
| No `.imported` accounts | Import card empty state with `Accounts ›` link |

## Testing

- **BudgetCore (XCTest):** `DashboardCalculator` — freshness thresholds (31-day boundary, months vs days wording, no data); current-month actual vs expected including the case where the month has transactions yet expected must still come from the forecast; expenses-over-expected and uncategorized footnote; top-categories group roll-up, ordering, over-expected and unplanned cases; upcoming-bills window edges (today, day 30, entry ending inside the window, hypothetical excluded, income excluded); attention items (45-day boundary, imported accounts excluded from stale-balance). `ForecastProjector` — December points equal the pre-extraction `forecastNetWorth` on a fixture; `monthEndNetWorth` equals the old `netWorthTotal` on a fixture.
- **App layer:** clean `xcodebuild`, then a live walkthrough against the real database in both states — today's stale state, and after staging the real CSV into a throwaway imported account (cancelled, not committed, test account removed afterward) — confirming import-from-dashboard hands off to the Import screen with progress, and that light and dark mode render correctly.

## File summary

- New: `Sources/BudgetCore/Dashboard/DashboardCalculator.swift` (+ value types), `Sources/BudgetCore/Forecasting/ForecastProjector.swift`, `App/Dashboard/DashboardViewModel.swift`, `App/Dashboard/DashboardView.swift`, per-card views under `App/Dashboard/`, `App/Import/ImportFlowHost.swift`.
- Modified: `App/ContentView.swift`, `App/Import/ImportView.swift`, `App/Forecast/ForecastViewModel.swift`, `App/Budget/BudgetGridViewModel.swift`, `Sources/BudgetCore/NetWorth/NetWorthCalculator.swift`, `Sources/BudgetCore/Forecasting/ForecastCalculator.swift` (extract `confirmedEntries`; existing `ForecastCalculatorTests` must pass unchanged).
- New tests: `DashboardCalculatorTests`, `ForecastProjectorTests`, plus a `monthEndNetWorth` test in the existing NetWorth calculator tests.

## Follow-ups (not part of this spec, flagged because they affect real use)

1. **No way to switch an account to `imported` tracking.** All six real accounts are `manual`, so the dashboard's import card will show its empty state until one is changed; Import itself is in the same position today. A small tracking-mode control on the Accounts screen is the fix and should land before or alongside this work to make the import card usable.
2. **Manual accounts and the forecast.** Importing transactions does not move a `manual` account's balance, and the forecast is anchored to *current net worth* plus impacts after the latest transaction month — so after an import without a balance update the forecast understates. The dashboard makes this visible (stale-balances item) but does not change the model; revisiting that anchoring is its own piece of work.
3. **Sidebar section ordering** is still derived from enum declaration order (a deferred minor from the HIG pass); inserting `.dashboard` is safe as specified, but an explicit `SidebarSection` enum would remove the fragility.
