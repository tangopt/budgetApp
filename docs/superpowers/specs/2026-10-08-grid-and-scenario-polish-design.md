# Grid and Scenario Polish — Design Spec

## Overview

A batch of improvements to the Forecast screen (scenario lab) and the Budget grid, requested 2026-10-08 after using the scenario lab, plus a one-off regrouping of the user's categories.

## Forecast screen

1. **Differs-from-budget shading covers the whole cell.** In `ScenarioGridTab`, the highlight fill is applied to the full cell frame (same width/height as every other cell, edge to edge), not just behind the text. The legend swatch stays.
2. **New scenario opens its grid.** After "New scenario…" succeeds (and after "Duplicate…"), the new scenario becomes the selected scenario and the Grid tab is shown.
3. **Chart tooltip stays inside the chart.** The hover readout on the Compare chart is currently clipped at the top. It must always be fully visible: placed inside the plot area (overflow resolution fits it to the chart on both axes, falling back to below the cursor near the top). The "Today" label stays.
4. **Summary table is vertical.** One block per year, stacked top to bottom (year label as a block header, "to <month>" for a partial last year as now). In each block: rows = plans (Budget first, then each compared scenario, same names/colours as the chart), columns = Year-end net worth, Δ vs Budget ("—" for Budget, "+" in green when positive as now), Income, Expenses, Reserves (unspent). No horizontal scrolling at normal window widths.

## Budget grid and Forecast grid

5. **Recurring items end by date or after N occurrences.** The add sheet (`PlannedItemSheets` add flow, used by both grids and by reserve allowances) and the edit-occurrence sheet's series fields offer **Ends: Never / On a date / After N occurrences** (N ≥ 1, stepper/field). "After N occurrences" is stored as the `endDate` = the date of the Nth occurrence counted from the series' start (for "this and all following" edits, counted from the edited occurrence), computed with the same expansion the plan uses (frequency, interval, anchorDay). No schema change. The occurrence count is not stored: changing the frequency later keeps the end date. Item summaries show "until <Mon yyyy>" as now; the sheet shows the computed last date live under the N field ("Last: 12 Mar 2027"). A pure helper in BudgetCore, `RecurrenceEnd.endDate(start:frequency:interval:anchorDay:occurrences:) -> Date`, is unit-tested (monthly with month-end anchor, weekly, annual, interval > 1, N = 1, once = start).
6. **Year Total column always visible.** In both the Budget grid and the Forecast (scenario) grid, the Year Total column is pinned at the right edge (like the category column is pinned at the left) while the month columns scroll horizontally; the header row stays aligned. Uses the existing frozen-header technique (`FrozenHeaderScroll`, offset observed only by the follower) so scrolling stays smooth.

## Budget grid: multiple years

7. **Select several years.** The year picker supports multi-selection: click selects one year (as now), ⌘-click adds/removes a year (at least one stays selected). The selection is kept sorted.
   - **One year selected:** unchanged (twelve months + pinned Year Total).
   - **Several years selected:** the grid shows, per line (category, group, section, reserve, totals, balances as today's Year Total semantics — balances show year-end value), one column per selected year with that year's total, and after each year except the first two columns: **Δ £** (this year − previous selected year) and **Δ %** (Δ / |previous|, one decimal, "—" when the previous is 0). Δ is coloured by whether it is good for that line (expense less negative = green; income higher = green; transfers and balances neutral/secondary).
   - Year totals keep the pending (italic, `Color.pending`, icon) styling when they include unconfirmed amounts; clicking a year total opens that year's drill-down as the Year Total does now.
   - "Previous" means the previous **selected** year (e.g. 2024, 2026 compares 2026 with 2024); the Δ header says "vs 2024".
   - Computation reuses the existing per-year totals (`BudgetGridViewModel`); the Δ math is a small pure function (tested: positive/negative/zero previous, sign handling for expenses).

## Category groups (one-off data change, not code)

On the user's database (after they quit Budget, with a timestamped backup), via SQL in one transaction:
- New expense groups: **Home & Bills** (Rent, Council Tax, Gas/Electricity, Thames Water, Internet, TV License, House Decor / Move Expenses), **Food & Drink** (Groceries, Eating Out, Delivery), **Commute** (Commute / Public Transport, Meals/Drinks), **Leisure & Health** (Holidays / Travel / Events, Sport, Optician), **Admin & Taxes** (Accountant, UK Taxes), **Other** (Confirmed other expenses, Confirmed other SIGNIFICANT expenses).
- Existing: **Car** unchanged; **Subscriptions** gains HP Instant Ink; **Mobile Phones** unchanged.
- Income group **Earnings** (Income, Bonus); Other income/refunds stays ungrouped.
- Transfer groups **Own accounts** (Transfer: BBVA Portugal, Transfer: Lloyds International EUR, Transfer: Lloyds Joint, Transfer: Santander Patricia) and **Investing** (Investments (Stocks + Crypto), Transfer: Lloyds Investment ISA, Trading tools & training); Business Expenses / AMEX stays ungrouped.
- Remaining for expenses (reserve) stays ungrouped.

## Testing

BudgetCore XCTest: `RecurrenceEnd.endDate` cases; year-over-year Δ helper. App: build; full suite; screenshots of a DB copy where possible (multi-year Budget grid, pinned Year Total, vertical summary, tooltip near the top).
