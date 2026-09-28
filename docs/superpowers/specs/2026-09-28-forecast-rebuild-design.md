# Forecast Screen Rebuild — Design Spec

## Background

The Forecast screen (`ForecastComparisonView`/`ForecastViewModel`) was built around `PayPeriod`-based pay-period comparisons, back when the Budget grid also had a Pay Period display mode. The 2026-09-23 Grid v2 pass removed Pay Period mode from the Budget grid entirely — including all forecast integration (`GridDrillDownTarget.forecastEntries` and its rendering were deleted, since calendar-mode cells have no pay-period-projection equivalent). The Forecast screen itself was never updated to match: it still lists pay periods (e.g. "26 Aug – 25 Sep"), which no longer correspond to anything else in the app, defaults to a horizon that stops at the end of the current year, and shows no net worth information at all. This is what "Forecast is not working" refers to — not a crash, but a screen stuck in a display paradigm the rest of the app abandoned.

Investigation found the underlying engine is **not** actually pay-period-specific: `FrequencyExpander.occurrences(for:in:)` and `ForecastCalculator.confirmedTotal`/`previewTotal` operate on `PayPeriod`, but that struct is structurally just `{startDate, endDate, type}` — a generic date range plus an actual/projected marker. Nothing in `FrequencyExpander`'s occurrence-counting logic depends on periods being pay-period-shaped. This spec reframes the *screen* around calendar months without touching the engine.

Separately, investigation surfaced that the app's latest real balance snapshot and transaction data both currently stop at February 2026, while the current date is well past that. This spec's net-worth projection is defined to start from the latest real data point (not from "today"), so it stays correct regardless of how stale the most recent import happens to be — see "Net worth forecast" below.

`AutoForecastGenerator.refresh`/`.regenerate` (which *detect* recurring patterns from real transaction history) are unaffected by this spec — they already derive their own pay-period buckets internally from salary cadence, which is a reasonable detection window independent of how projections are later displayed. Only the *projection/display* layer changes.

## Global Constraints

- No changes to `FrequencyExpander`, `AutoForecastGenerator`, or the pattern-detection side of `ForecastCalculator` — this spec is additive at the calculator layer (one new function) and a rewrite at the screen/ViewModel layer.
- Every projected total continues to flow through the existing `ForecastCalculator.confirmedTotal`/`previewTotal`, called with calendar-month-shaped `PayPeriod` values (`PayPeriod(startDate: monthStart, endDate: monthEnd, type: .projected)`) — this spec does not introduce a parallel calculation path.
- "Confirmed" forecast (entries with status `.auto`, `.manual`, or `.confirmed`) is the figure used for every headline number (grid cells' primary line, net worth projection). "Preview" (confirmed + enabled `.hypothetical` entries) is secondary/supplementary, matching the existing confirmed-vs-preview distinction — never the other way around.
- Transfers (`Category.type == .transfer`) are excluded from every net-worth-affecting calculation — money moving between the user's own accounts doesn't change net worth. This matches the fix already shipped to the Budget grid's year-picker YoY figure.
- This spec does not touch the Budget grid or add a Dashboard screen — those are separate specs (Budget grid month-hiding depends on this one; Dashboard depends on both).

## 1. Horizon: data-anchored, not date-anchored

The forecast horizon is every calendar month **after the latest month with real data** (the later of: the latest transaction date, or the latest balance snapshot date, across all accounts), through **December of next year** (next year relative to today's real calendar date, not relative to the data).

Concretely: if the latest real data is February 2026 and today is September 2026, the horizon is March 2026 through December 2027 — the gap months (March–September 2026) are included as forecast, not skipped, so the year-end projection is complete. Once real data catches up to the present (the common case going forward, as the user keeps importing), this horizon naturally becomes "just the genuinely future months."

`ForecastViewModel` computes this horizon once per `load()`:

```swift
/// Every (year, month) from the month after the latest real data through December of
/// next year (relative to today). Drives both the grid's columns and the net worth
/// projection's accumulation range.
private(set) var horizonMonths: [(year: Int, month: Int)] = []
```

## 2. `ForecastViewModel` gains account/balance data

To compute a net worth projection, `ForecastViewModel` needs the same account data `BudgetGridViewModel` already loads:

```swift
@Published var accounts: [Account] = []
@Published var balanceSnapshots: [BalanceSnapshot] = []
@Published var exchangeRate: ExchangeRateSetting = ExchangeRateSetting(eurToGbpRate: 0.87, updatedAt: Date())
```

`load()` fetches these the same way `BudgetGridViewModel.load()` does (`Account.fetchAll`, `BalanceSnapshot.fetchAll`, `ExchangeRateSetting.currentOrDefault`).

The "latest real data" date used to anchor the horizon (section 1) is `max(latest transaction date, latest balance snapshot date)` across everything loaded — computed once in `load()`.

## 3. New calculator function: `confirmedNetWorthImpact`

A new function on `ForecastCalculator`, mirroring `confirmedTotal`'s signature but summing across every non-transfer category for one period:

```swift
extension ForecastCalculator {
    /// The confirmed forecast's net effect on account balances for one period — income
    /// minus expenses, transfer categories excluded (moving money to the user's own
    /// savings/ISA doesn't change net worth). Signed: positive means net worth grows.
    public static func confirmedNetWorthImpact(period: PayPeriod, categories: [Category], entries: [ForecastEntry], groups: [ForecastGroup]) -> Int {
        categories.reduce(0) { sum, category in
            guard category.type != .transfer, let categoryId = category.id else { return sum }
            return sum + confirmedTotal(categoryId: categoryId, period: period, entries: entries, groups: groups)
        }
    }
}
```

`confirmedTotal` already returns a signed amount (income positive, expense negative), so summing across non-transfer categories directly gives the net change — no separate income/expense bucketing needed.

## 4. Net worth projection

`ForecastViewModel` adds:

```swift
/// Total net worth right now, using every account's latest real balance (same
/// calculation the Net Worth screen's headline uses).
private var currentNetWorthGBP: Int {
    NetWorthCalculator.netWorth(balances: NetWorthCalculator.accountBalances(accounts: accounts, snapshots: balanceSnapshots, transactions: transactions, rate: exchangeRate))
}

/// Forecast net worth at the end of `year` (December): current net worth plus the
/// confirmed forecast's accumulated net impact for every horizon month up to and
/// including that December. `nil` if `year`'s December isn't within the horizon (e.g.
/// real data already reaches that December, so there's nothing left to forecast).
func forecastNetWorth(atEndOf year: Int) -> Int? {
    guard horizonMonths.contains(where: { $0.year == year && $0.month == 12 }) else { return nil }
    let monthsThroughYear = horizonMonths.filter { $0.year < year || ($0.year == year && $0.month <= 12) }
    let netChange = monthsThroughYear.reduce(0) { sum, month in
        let range = dateRange(forYear: month.year, month: month.month)
        return sum + ForecastCalculator.confirmedNetWorthImpact(period: PayPeriod(startDate: range.start, endDate: range.end, type: .projected), categories: categories, entries: entries, groups: groups)
    }
    return currentNetWorthGBP + netChange
}
```

(`transactions` and `categories` are fetched in `load()` alongside the existing groups/entries — `transactions` for the "latest real data" date and for `NetWorthCalculator.accountBalances`' `.imported`-account handling; `categories` for `confirmedNetWorthImpact`. `dateRange(forYear:month:)` is a small private helper identical to `BudgetGridViewModel`'s.)

Year-over-year comparison reuses this directly:

```swift
/// Change from last year's real year-end net worth (Net Worth screen's own historical
/// data) to `forecastNetWorth(atEndOf: year)`. `nil` when either side is unavailable.
func forecastNetWorthYoY(atEndOf year: Int) -> (changeGBP: Int, percent: Double?)?
```

This screen shows two such headline pairs: this year's December (forecast vs. last real December) and next year's December (forecast vs. this year's forecast December) — both computed via the same two functions, just called with adjacent years.

## 5. Screen layout

`ForecastComparisonView.swift` is renamed `ForecastView.swift` (matching `BudgetGridView`/`NetWorthView` naming — the screen's shape changes enough that "Comparison" no longer describes it). Three sections, top to bottom:

**a. Net worth forecast headline.** Two stat blocks side by side (styled like the Budget grid's year-picker chips): "Dec `year`" with the forecast figure and YoY arrow/percent, for this year and next year.

**b. Category × month grid.** Same visual language as the Budget grid (right-aligned figures, colored type rail, section headers, zebra striping) — a new, separate view (not shared code with `BudgetGridView`, which stays untouched; sharing would couple two screens with different data sources for no benefit). Rows are categories grouped into Income/Expenses/Transfers sections exactly like the Budget grid (no category-group collapsing here — that's a grid-specific affordance tied to `CategoryGroup`, and forecast rows are sparser). Columns are `horizonMonths`, plus this-year and next-year total columns (July-next-year is far enough out that a running total column disambiguates without needing to scroll).

**c. Manage forecast.** A collapsible section (disclosure group, default collapsed) containing the existing groups/entries management UI (`groupsSection` today) — toggle group/entry enabled, edit an entry, confirm/un-confirm, add a hypothetical entry. Functionally unchanged from today; the "Add hypothetical forecast entry…" button and the two sheets (`NewForecastEntryView`, `EditForecastEntryView`) move here as-is.

## 6. Grid cell rendering

Per category row, per month column:

- **Default (no active hypothetical affecting this category):** single line — `MoneyText` showing the confirmed total, "—" when zero. Same row height as a normal Budget-grid row.
- **Category has at least one enabled `.hypothetical` entry whose effect is visible somewhere in the horizon:** the *entire row* renders at two-line height for every column — confirmed on top (normal weight), preview below in smaller muted text, colored amber only where the preview total actually differs from confirmed for that specific month; where they're equal for a given month, the bottom line is left blank (not repeated) so the eye isn't drawn to non-differences.

Row height is therefore per-category, not per-cell — every cell in a two-line row reserves the same height, even in months where that category's preview happens to match confirmed.

## Testing

- New `ForecastCalculatorTests` case(s) for `confirmedNetWorthImpact`: sums income and expenses correctly, excludes transfer categories, signed correctly (net worth grows on a net-positive month).
- `forecastNetWorth(atEndOf:)`/YoY logic lives in `ForecastViewModel` (App target) — per this codebase's established pattern (no App-target test suite), this is verified by manual walkthrough with real data, not unit tests, mirroring how `BudgetGridViewModel.netWorthChange` was verified.
- Grid cell two-line/one-line row logic and the manage-forecast panel are App-target UI — manual walkthrough.

## Out of scope

- Any change to `FrequencyExpander`, `AutoForecastGenerator`'s detection logic, or `PayPeriodDetector`/`PaydaySource` (still used by `AutoForecastGenerator.refresh` internally).
- The Budget grid's month-hiding and blended current-month cell — separate spec, depends on this one.
- The Dashboard screen — separate spec, depends on this one and the Budget grid spec.
- Sidebar navigation polish (icons, sections, dynamic window title) — folded into the Dashboard spec per the user's request, not here.
- Editing which months are forecast vs. real (e.g. manually marking a gap month as "actually zero spend") — the horizon is always data-anchored, not user-adjustable, in this pass.
