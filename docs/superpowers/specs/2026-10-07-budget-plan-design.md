# Budget as the Plan — Design Spec

## Overview

Project 1 of 2 (project 2 turns the Forecast screen into a scenario lab and builds on this). Today the Budget grid shows actuals only (plus reserve rows); planned amounts live on the Forecast screen. This makes the **budget the plan**: planned items appear in the Budget grid's open and future months as **unconfirmed** amounts next to actuals, until a real transaction covers them or the month closes. Planned items are one-off or recurring with any frequency, and each occurrence can be edited on its own or together with all following ones (like a meeting series in Outlook).

## Decisions (user, 2026-10-07)

- Open months show **actual + pending remainder**; the pending part is styled as unconfirmed and disappears once actuals cover it or the month closes.
- Cells with unconfirmed amounts carry an icon: **all expected** (no actual yet) vs **partly happened** (actual below expected).
- Editing an occurrence can change **amount, date, category, skip/remove**, and the **frequency** of all following unconfirmed occurrences; scope "only this occurrence" or "this and all following".
- Model: **series + exceptions** (approach A).
- Auto-detected items are added as ordinary unconfirmed planned items, as if added by hand.
- The Forecast screen's scenarios stay as they are until project 2.

## Current state (verified)

- `ForecastEntry` (groupId, categoryId, amount, frequency once/weekly/monthly/annually, interval, start, end, isEnabled, status auto/manual/hypothetical/confirmed, note) in `ForecastGroup`s: "Detected recurring" (system-managed, `.auto`), "Reserved", "Spreadsheet plan", "Planned", and scenario groups (`.hypothetical`, or `.confirmed` once confirmed).
- `ForecastCalculator.confirmedEntries` = enabled, not hypothetical, in an enabled group; `confirmedTotal(categoryId:period:entries:groups:)` sums `FrequencyExpander.amount`. All screens use it (Dashboard, both grids, reserves, net-worth projection via `confirmedNetWorthImpact`).
- `AutoForecastGenerator.regenerate` creates/updates/deletes `.auto` entries in "Detected recurring" after each import.
- Budget grid: pay-month actuals for every month; reserve rows from the plan; Forecast grid: blended open months (`MonthBlend.projectedTotal`); per pay month classes from `PayCalendar` (closed / open-started = blended / not started = forecast). Planned items belong to the **calendar** month named on them; actuals to the pay month (pay-months spec).
- "+ Add planned item" lives on the Forecast grid's section headers (`PlannedItems.add`).

## Terms

- **Planned item** = a non-hypothetical `ForecastEntry` in an enabled group (exactly `confirmedEntries`), i.e. the series.
- **Occurrence** = one scheduled instance, identified by `(entryId, originalDate)` — the date the series would produce before any edit.
- **Exception** = an edit to one occurrence.

## Model

New table `plannedOccurrenceException` (migration appended last):

| column | type | meaning |
|---|---|---|
| id | integer pk | |
| entryId | integer, references forecastEntry ON DELETE CASCADE | the series |
| originalDate | datetime | the occurrence it edits (unique with entryId) |
| isSkipped | bool | the occurrence is removed |
| amountMinorUnits | integer? | replacement amount (signed like the series) |
| date | datetime? | replacement date |
| categoryId | integer? references category | replacement category |

`Sources/BudgetCore/Forecasting/PlannedOccurrences.swift`:

```swift
public struct PlannedOccurrence: Equatable, Identifiable {
    public let entryId: Int64
    public let originalDate: Date
    public let date: Date            // after any move
    public let categoryId: Int64     // after any re-file
    public let amountMinorUnits: Int // after any override
    public let isException: Bool
    public var id: String { "\(entryId)-\(originalDate.timeIntervalSince1970)" }
}
public enum PlannedOccurrences {
    /// Occurrences whose (possibly moved) date falls in the period: the series' originals
    /// in the period that aren't skipped or moved out, plus exceptions moved into it.
    public static func occurrences(entries: [ForecastEntry], exceptions: [PlannedOccurrenceException], in period: PayPeriod) -> [PlannedOccurrence]
}
```

`ForecastCalculator.confirmedTotal`, `previewTotal`, `confirmedNetWorthImpact`, `previewNetWorthDelta` gain an `exceptions:` parameter and sum `PlannedOccurrences` instead of `FrequencyExpander.amount`, filtering by the occurrence's (possibly re-filed) `categoryId`. Every caller passes the exceptions it loaded (Dashboard input, Forecast/Budget view models, projector, reserves). Hypothetical scenario entries never have exceptions in project 1.

### Editing operations (`PlannedItemEditing`, BudgetCore, each in one transaction)

- `editOccurrence(db:entryId:originalDate:change:)` — upsert the exception (`change` = any of amount, date, category, skip).
- `editFollowing(db:entryId:originalDate:change:)` — split the series: the original ends the day before `originalDate` (or is deleted if `originalDate` is its first occurrence); a new entry (same group, status `.manual`, note kept) starts at `originalDate` with the changes applied (amount, category, frequency/interval, start date shifted by a date move, or no new entry for "remove all following"). Exceptions after `originalDate` move to the new entry (their original dates re-keyed only when the series isn't shifted; when a date move or frequency change shifts the schedule, later exceptions are dropped).
- `changeFrequency` is `editFollowing` with a frequency/interval change.
- Editing a `.auto` entry turns it `.manual`.
- **Only unconfirmed occurrences can be edited** (see below); the operations throw `PlannedItemEditError.occurrenceConfirmed` otherwise, and `.invalidDate` for a move into a closed month.

### Confirmation

An occurrence is **confirmed** when its pay month is closed, or when its category's actual for that pay month covers the category's planned total for that month (envelope: expense actual ≤ planned, i.e. spend ≥ plan; income actual ≥ plan; transfers by sign as `MonthBlend`). Otherwise unconfirmed. Per category per month:
- `pending = max(0, |planned| − |actual|)` in the plan's direction;
- state `.allExpected` when actual is 0 and pending > 0, `.partial` when 0 < |actual| < |planned|, `.covered` otherwise.

`Sources/BudgetCore/Budget/PlanStatus.swift` exposes `PlanStatus.cell(actual:planned:categoryType:monthClass:) -> (value: Int, pending: Int, state: PendingState)` used by the Budget grid (and available to the Dashboard).

## Detection

`AutoForecastGenerator` stops updating and deleting: after an import it only **adds** an entry for a category that has no planned item (any non-hypothetical entry) and isn't excluded/reserved, as status `.manual` in "Detected recurring" (the group keeps `isSystemManaged = true` only so it never appears as a scenario; its items are edited like any other). Migration step: existing `.auto` entries become `.manual` (generic, no personal data). The `.auto` status remains readable for old databases but is no longer produced.

## Budget grid

- Months: closed → actuals (as now). Open (started or not) → `PlanStatus.cell` value = actual + pending, pending styled unconfirmed (secondary colour, italic) with an icon: `circle.fill` for `.allExpected`, `circle.lefthalf.filled` for `.partial`; help text "£x actual + £y expected" / "£y expected".
- Reserves: as now (closed 0, open what's left), shown with the `.allExpected` icon while they count.
- Group and section rows sum their members' values; the icon shows when any member is pending (partial if any member is partial).
- Year total sums the displayed values; footnote "Includes £x not yet confirmed" when any pending.
- Years: the year picker always includes the current year.
- Clicking a cell opens the drill-down: actual transactions (as now) plus the **planned occurrences** for that category and month (date, amount, frequency, confirmed/unconfirmed). Unconfirmed occurrences have **Edit…** and **Remove…**.
- Section headers (Income, Expenses, Transfers) and the Reserved header get **"+ Add planned item"** (moved from the Forecast grid): category, amount (MoneyField), one-off or recurring (weekly / monthly / annually, every N), start, optional end. Reserves use their existing add-reserve flow.

### Edit occurrence sheet

Fields prefilled from the occurrence: amount (MoneyField), date, category (non-reserved categories of the same type, or reserves for a reserve), frequency + interval (series-level), "Remove". On Save, a choice: **Only this occurrence** / **This and all following**; a frequency change offers only "This and all following". Removing offers "Only this occurrence" / "This and all following" (ends the series). Errors inline; closed-month dates rejected.

## Forecast screen (unchanged in project 1)

Keeps working on the same entries: its grid and headline use the exception-aware totals. Its "+" header buttons are removed (the Budget grid owns adding planned items). Scenario creation/preview/confirm unchanged.

## Testing

- `PlannedOccurrences`: originals in period; skipped; amount override; moved within/into/out of a period; re-filed category counted under the new category; weekly/monthly/annual with interval.
- `ForecastCalculator` totals and net-worth impact with exceptions; existing tests unchanged without exceptions.
- `PlannedItemEditing`: occurrence upsert; following split (end date, new entry, moved exceptions, first-occurrence case deletes original); frequency change; remove following; confirmed occurrence rejected; `.auto` → `.manual`.
- `PlanStatus.cell`: all-expected, partial, covered, closed month, income and transfer directions.
- `AutoForecastGenerator`: adds only for categories without a plan; never updates/deletes; migration turns `.auto` into `.manual`.
- App: build; manual check on a database copy.
