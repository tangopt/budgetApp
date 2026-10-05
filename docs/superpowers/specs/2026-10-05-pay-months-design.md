# Pay Months — Design Spec

## Overview

In the original spreadsheet every "month" ran **payday to payday**: a month's column holds that month's salary and the spending since the previous salary. The app instead buckets actual transactions by **calendar month** everywhere (Budget grid, Forecast grid actual months, Dashboard). This spec makes the pay month the app-wide definition of a month for actual money flows, and adds closing a month — automatically when its salary is imported, or by hand on a chosen date — which also releases any leftover reserve (`2026-10-05-reserved-forecast-categories-design.md`).

This reverses the grid-v2 decision to drop pay periods (`2026-09-23-grid-v2-design.md`, "Pay Period mode adds no value"): that mode showed raw date-range columns; here the columns keep their month names and only the boundaries move.

## Decisions (from the user, 2026-10-05)

- **A pay month ends with its salary.** Pay month *M* runs from the day **after** the previous month's salary date up to and **including** *M*'s salary date. Example: salary 15 Sep and 15 Oct → "October" = 16 Sep – 15 Oct. Today (5 Oct 2026) is in October.
- **Payday transactions stay with that salary's month.** Every transaction dated on a salary date belongs to the month that salary closes (bank exports give no reliable order within a day, so the date alone decides).
- **Forecast items belong to the calendar month named on the item.** A forecast entry is "for that month"; its real transaction may land a few days either side and is counted in whichever pay month its date falls in (e.g. the mobile bill: standard monthly cost in the forecast, varying actual dates).
- **A month closes when its salary is imported**, or when the user closes it by hand, choosing a closing date (also retrospectively). A closed month releases its leftover reserve.

## Current state (verified)

- `MonthRange` (calendar months, UTC) and `BudgetGridCalculator.calendarTotalsLookup` (`[categoryId: [year: [month: minorUnits]]]` by calendar month) feed: `BudgetGridViewModel.calendarCategoryTotal`, `ForecastViewModel.categoryTotal` (actual months), `DashboardInput.calendarTotals` (current month, year at a glance, top categories), `ReservedCategories.unforecastSpend`.
- `MonthBlend.classify` decides actual / blended / forecast per calendar month from the latest transaction date and today. `ForecastViewModel.isActual` uses `latestRealMonth` (calendar month of the latest transaction). `ReservedCategories.countsAllowance` releases reserves before the current calendar month.
- `PaydaySource.paydayDates(db:)` / `paydayDates(transactions:categories:)` returns salary dates (category "Income", amounts ≥ half the median); `PayPeriodDetector.paydayAnchors` collapses dates < 20 days apart. Used by the auto-forecast.
- Real data: 1,634 transactions, all from the spreadsheet migration, each month's rows dated on that month's payday (14th–16th; latest 14 Feb 2026). So every historical row stays in its current month under the new rule.

## Goals

- One definition of "month" for actual flows, used by every screen.
- Months close automatically on salary import; manual close/reopen with a closing date.
- Reserves: leftover released when a month closes; open months keep "what's left".
- No change to forecast amounts, balances, net worth points, or historical monthly totals.

## Non-goals

- Changing how balances / net worth are dated (they stay point-in-time calendar dates: month-end balances in the Budget grid, the net worth line and the year-change bars are unchanged).
- Weekly or irregular pay; more than one salary per month (a second salary-sized credit within 20 days is collapsed as today).
- Re-dating or editing historical transactions.

## Model

### `PayMonthClose` (new table `payMonthClose`)

`id`, `year INTEGER`, `month INTEGER` (unique together), `closeDate DATETIME` — the last day of that pay month (inclusive), chosen by the user. Migration `createPayMonthClose`, appended last.

### `PayCalendar` (new, `Sources/BudgetCore/PayPeriods/PayCalendar.swift`)

A value built from salary dates, manual closes and today; the single source of month boundaries.

```swift
public struct PayMonth: Hashable, Comparable { public let year: Int; public let month: Int }

public struct PayCalendar {
    public init(salaryDates: [Date], manualCloses: [PayMonthClose], today: Date)
    public static func load(db: Database, today: Date) throws -> PayCalendar   // PaydaySource + payMonthClose
    public func closeDate(of month: PayMonth) -> Date        // start of day of the last day
    public func range(of month: PayMonth) -> (start: Date, end: Date)  // day after previous close … end of close day
    public func month(containing date: Date) -> PayMonth
    public func isClosed(_ month: PayMonth) -> Bool
    public func monthClass(_ month: PayMonth) -> MonthClass  // .actual / .blended / .forecast
    public var current: PayMonth { get }                     // month(containing: today)
    public func closeSource(of month: PayMonth) -> CloseSource  // .salary / .manual / .projected
}
```

**Close date of month *M*** (first match wins):
1. a manual close for *M* → its `closeDate`;
2. an imported salary dated in calendar month *M* (after `paydayAnchors` collapsing) → that date;
3. projected → day-of-month of the most recent imported salary on or before *M* (the first salary's day for earlier months), clamped to *M*'s length. No salaries at all → the last day of calendar month *M* (pay months then equal calendar months).

**Range:** `start` = start of the day after close(*M−1*); `end` = last moment of close(*M*)'s day. All UTC.

**Closed:** *M* is closed when it has a manual close or an imported salary (sources 1–2).

**Month class** (replaces `MonthBlend.classify` and `ForecastViewModel.isActual` for flows):
- closed → `.actual` (actuals only);
- open and `start ≤ today` → `.blended` (actuals so far plus what's still expected; reserve = what's left);
- open and `start > today` → `.forecast`.

`MonthBlend.projectedTotal` (the envelope rule per category) is unchanged.

**Consistency rules:** a manual close date must be ≥ `start` of *M* and < close(*M+1*) when *M+1* is closed; otherwise `PayCalendarError.invalidCloseDate`. A manual close overrides an imported salary for the same month (explicit user intent).

### Totals by pay month

`PayMonthTotals.lookup(transactions:calendar:) -> [Int64: [Int: [Int: Int]]]` — same shape as `calendarTotalsLookup`, keyed by `calendar.month(containing: date)`; confirmed, categorised transactions only (unreviewed excluded, as now). Every reader of `calendarTotalsLookup` switches to it; `calendarTotalsLookup` is removed. Expected amounts keep using `ForecastCalculator.confirmedTotal` over the **calendar** month named *M* (`MonthRange.of(year:month:)`).

## Behaviour by screen

**Budget grid** — columns are pay months (labels unchanged); cells = pay-month actuals. Column header tooltip shows the range ("16 Sep – 15 Oct"). Header context menu: **Close month…** (open months) / **Reopen** (manually closed months; disabled with explanation when closed by an imported salary). Account balance rows unchanged (calendar month-end).

**Forecast grid** — per month by class: `.actual` → actuals; `.blended` → `MonthBlend.projectedTotal(actual, expected)` per category; `.forecast` → confirmed forecast. (Today the grid switches abruptly from actuals to forecast at the latest data month.) The net-worth headline keeps its walk from the month after the latest transaction's pay month.

**Dashboard**
- Current month card = `calendar.current`: header "October · 16 Sep – 15 Oct · day 20 of 30"; totals via the class rules; **Close month…** button.
- Year at a glance, year totals, top categories, unreviewed footnotes → pay months.
- Net worth line, year-change bars, accounts, upcoming bills → unchanged (dates).
- Freshness card unchanged.

**Reserves** — `ReservedCategories.countsAllowance` is replaced by `!calendar.isClosed(M)`: closed months count £0 (leftover released); open months count what's left (`remainingAllowances` with that pay month's `unforecastSpend`); forecast months the full allowance. Applies in both grids and the Dashboard.

**Close month sheet** (shared view): month name, current range, date picker (default: today for the current month, the projected close date for earlier months), note "Spending after this date counts in <next month>." Save → insert/replace `payMonthClose`; errors inline. Reopen → delete the row.

## Data

No data migration: historical rows are dated on their month's payday, which is that month's close date, so every month's totals are unchanged. Verify by comparing per-month category totals before/after on a copy of the real database (must be identical for all 74 months up to Feb 2026).

## Testing

- `PayCalendar`: ranges for consecutive salaries (payday inclusive, day after starts next month); projection from the latest salary's day and clamping (31st → Feb 28/29); manual close overriding a salary; manual close for a projected month; invalid close dates; `isClosed`; `monthClass` for closed / open-past / current / future; no salaries → calendar months.
- `PayMonthTotals`: payday rows in the closing month; the day after in the next month; unreviewed excluded.
- Dashboard: current month = pay month containing today; reserve released for a closed month, "what's left" for an open past month, full in future months.
- Forecast/Budget grids via their BudgetCore helpers: blended month values; reserve rows.
- Migration `createPayMonthClose`.
- Real-data check: per-month totals identical before/after on a DB copy.
