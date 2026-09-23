# Budget Grid v2: Performance, Layout, and Category Groups — Design Spec

## Background

After using the app with real, full-scale data (1,634 transactions, 6 accounts, ~50 categories, 6+ years of history), several problems surfaced that weren't visible with the small datasets used during development:

1. **Performance.** The Calendar-mode grid re-scans the entire transaction list from scratch for every cell, every render. With real data volume this is now visibly slow.
2. **Visual polish.** Money figures render centered rather than aligned, with no visible cell borders — the grid doesn't read cleanly as a table.
3. **Navigation.** Scrolling the grid loses track of which category/month you're looking at, since neither the category column nor the month header freezes in place.
4. **Pay Period mode adds no value** in practice — the user only ever uses Calendar mode.
5. **No way to see category spending holistically.** The original spreadsheet listed related categories (e.g. all "Car" costs) consecutively; the app has no equivalent grouping, so seeing "how much did Car cost this year" means mentally summing several rows.

This spec covers all five. It's scoped to the Budget grid and a new Categories screen — it does not touch Import, Forecast, Net Worth, or Uncategorized.

## Global Constraints

- Numbers are right-aligned with tabular (monospaced) figures, matching the approved mockup.
- Category column and month-header row stay visible (frozen) while scrolling the grid in either direction.
- Pay Period mode is removed entirely — Calendar is the only Budget grid view.
- Category groups are a first-class, user-manageable concept — not a static label.
- An ungrouped category behaves exactly as every category does today — grouping is additive, never required.

## 1. Remove Pay Period mode

`BudgetGridView`'s segmented "Pay Period / Calendar" control, `GridGroupingMode` enum, and every `case .payPeriod` branch in `BudgetGridViewModel`/`BudgetGridView` are deleted. Calendar becomes the grid's only rendering path — no mode state, no toggle.

Consequence: the grid's drill-down sheet only ever needs `GridDrillDownTarget.transactions` now (`.forecastEntries`, which existed for tapping a *projected* pay-period cell, has no calendar-mode equivalent — projections remain visible only on the Forecast screen). `GridDrillDownTarget.forecastEntries` and its rendering branch in `GridDrillDownSheet` are removed as dead code.

Pay-period *detection* itself (`PayPeriodDetector`, `PayPeriodDetector.allPeriods`) is untouched — it still drives the Forecast screen's periods. Only the Budget grid's pay-period *view* goes away.

## 2. Performance: precomputed lookup

`BudgetGridCalculator.categoryTotalForCalendarMonth` currently does a full linear filter over every transaction, for every (category, year, month) triple requested — and it's requested roughly (categories × 12 × years) times per grid render, plus again for every year chip's total and YoY comparison. That's tens of thousands of full-array scans per render with real data.

Fix: `BudgetGridViewModel.load()` builds one lookup, once, after fetching transactions:

```swift
// keyed by [categoryId: [year: [month: Int]]]
private var calendarTotals: [Int64: [Int: [Int: Int]]] = [:]
```

built with a single pass over `transactions` (group by categoryId, then by year/month extracted once per transaction — not once per query). `calendarCategoryTotal(_:year:month:)` becomes an O(1) dictionary lookup (defaulting to 0 when absent). `yearlyTotal`/`yearOverYearChange` sum from the same structure instead of re-deriving through `categoryTotalForCalendarMonth`.

This is a pure internal change — every existing `BudgetGridCalculatorTests` case still describes the required behavior; the tests just need to also cover the new lookup-building function directly.

## 3. Grid visual redesign

Per the approved mockup:
- Money cells right-aligned, tabular figures (`.monospacedDigit()`, already used by `MoneyText`), so decimal points line up column-to-column.
- Visible borders between every row and column (currently the grid has none).
- Category column frozen on the left; month-header row frozen on top. Both remain visible while scrolling the other axis.

**Technical approach.** SwiftUI's `Grid`/`ScrollView` (the current implementation) has no built-in concept of a frozen row or column. The standard technique — and what this spec calls for — is two axes of synchronized scrolling: the frozen column and the scrollable body share vertical scroll position; the frozen header and the scrollable body share horizontal scroll position. This is the one piece of this spec with real implementation risk (exact SwiftUI mechanism for synchronizing two scroll views is worth confirming early, since API availability varies by OS version) — the implementation plan should front-load a small spike to settle the approach before building the full grid around it, rather than discovering a blocker midway.

Category-group header/child rows (section 4) reuse the same row rendering as regular category rows — a group row just also carries a disclosure toggle and bold/shaded styling to set it apart, matching the mockup.

## 4. Category groups

### Data model

```swift
public struct CategoryGroup: Codable, Equatable, Identifiable, FetchableRecord, MutablePersistableRecord {
    public var id: Int64?
    public var name: String
}
```

`Category` gains `public var groupId: Int64?` (nullable — ungrouped is the default and fully supported state). Migration adds the `categoryGroup` table and the nullable `groupId` column on `category`.

### Categories screen (new)

New sidebar entry, `AppScreen.categories`, positioned after Rules (mirroring how Uncategorized/Accounts were added in the last pass — see `App/ContentView.swift`'s `AppScreen` enum). Lists every category, each with a picker to assign it to an existing group or "None," plus a way to create a new group inline (a text field + "Add Group" affordance is enough — no separate group-management screen; a group with no members is harmless and just doesn't render in the grid). No category create/rename/delete here — the existing category list is otherwise unchanged; this screen only manages grouping.

### Grid integration

Within each type section (Income/Expenses/Transfers), categories sharing a non-nil `groupId` collapse into a single group row showing the sum of their monthly/yearly totals, with a disclosure control to expand/collapse (default collapsed, matching the mockup). Expanded, each member category renders as an indented child row beneath the group row, identical in every other respect to a standalone category row (same drill-down behavior, same cell rendering). Categories with `groupId == nil` render exactly as today, interleaved with group rows in the section's existing order.

### Seeding

A one-off script (same pattern as `MigrateAccountBalances`) creates an initial "Car" group and assigns the car-related categories (`Car Payments`, `Car Tax`, `Car MOT`, `Car Insurance`, `Car Service`, `Car Subscriptions`, `Car Fines`, `Car Maintenance/Accessories`, `Car Parking`, `Car Parking Permit`, `Car Tolls`, `Car Charge`, `Car Gas`) to it, and scans the remaining category names for other obvious clusters (e.g. subscription services) to group similarly. This is a starting point, editable from the new Categories screen — not a fixed taxonomy.

## Testing

- `BudgetGridCalculatorTests`: extend to cover the new lookup-building function directly (correct grouping by category/year/month, correct handling of categories/months with no transactions).
- New `CategoryGroupTests` (or extend `CategoryTests`): `Category.groupId` persists correctly; a group with no members doesn't error or appear in the grid.
- Grid-with-groups behavior (group row sums correctly, expand/collapse doesn't lose data) is App-target UI logic — per this codebase's established pattern (no App-target test suite exists), this is verified by manual walkthrough, not unit tests.

## Out of scope

- Full category CRUD (add/rename/delete a category) — the existing fixed category list is untouched beyond adding `groupId`.
- Group-level metadata beyond a name (icon, color, sort order) — not requested.
- Any change to Import, Forecast, Net Worth, Rules, or Uncategorized screens.
