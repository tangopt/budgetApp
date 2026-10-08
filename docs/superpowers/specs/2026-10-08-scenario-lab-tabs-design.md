# Scenario Lab Tabs, Editable Differences, Click-to-Add — Design Spec

## Overview

Follow-up to the scenario lab (`2026-10-08-scenario-lab-design.md`) and grid polish (`2026-10-08-grid-and-scenario-polish-design.md`), requested 2026-10-08. The Forecast screen loses its left panel; each tab gets its own scenario chip row with behaviour suited to the tab. Differences become a side-by-side comparison of several scenarios and the budget, and can be edited or reverted. Clicking an empty cell in the Budget grid or a scenario grid adds a planned item there.

## Forecast screen layout

- The left scenario panel is removed. Under the tab bar (Compare / Differences / Grid; the horizon picker stays top right) each tab shows a **chip row**: **Budget** first (palette colour index 0, blue), then each scenario (its `PlanPalette` colour, as today), then a **"+ New scenario"** chip (name sheet; copies the budget).
- Each scenario chip: colour dot + name. Right-click menu: Rename…, Duplicate…, Refresh from budget (shows the report as today), Delete… (confirm). These reuse the existing sheets/alerts from `ScenarioListPanel`, which is deleted.
- Each tab keeps its own selection (in `ScenarioLabViewModel`), so switching tabs doesn't reset another tab's choice. A newly created or duplicated scenario is ticked in Compare and Differences, selected in Grid, and the Grid tab is shown (as today). A deleted scenario is removed from every tab's selection.

### Compare tab
Chips are toggles (multi-select). Budget is always on (its chip is shown selected and not toggleable — Δ is measured against it). Ticked scenarios drive the chart lines and the summary blocks' rows (same as today's "compare" checkboxes).

### Differences tab
Chips are toggles (multi-select; Budget always shown as the first column, not toggleable). Content is a side-by-side table:
- **Rows** = items that differ in at least one ticked scenario. A budget-backed item (a `changed` or `removed` scenario entry) is keyed by its budget source entry id, so the same budget item changed in two scenarios is one row; each `added` scenario entry is its own row. Row label = category name (plus "new" badge for added rows). Rows sorted by category name, then by first date.
- **Columns** = Budget, then each ticked scenario (header: colour dot + name, tinted background).
- **Cells:** that plan's series summary (e.g. "−£2,900 monthly from Nov 2026"), "Removed" for a removed tombstone, "—" when the plan doesn't have the item, and for `changed` the field changes under the summary (as today). Budget cell = source summary ("—" for added rows). A scenario cell that differs from the budget has a light tint of the scenario's colour.
- A differing scenario cell has: a **tick box** (apply), **Edit…** and **Revert** (context buttons, see below). Already-applied differences show the "Applied" badge as today and no tick box.
- **One tick per row:** ticking a cell unticks the same row's other scenario cells (two versions of one budget item never go to the budget together).
- **Apply to budget…**: confirmation lists ticked cells grouped by scenario; applies each scenario's ticked ids with the existing `ScenarioApply.apply`, all in one database write transaction.
- **Undo last apply** becomes a menu listing each ticked scenario that `canUndo`; choosing one undoes that scenario's latest application (existing `undoLast`, report shown as today).

### Editing and reverting a difference
- **Edit…** (added / changed cells): opens the existing edit-occurrence sheet for the scenario entry's first occurrence in an open (not closed) pay month, with the scope fixed to "This and all following". Hidden when the entry has no occurrence in an open month, and for removed cells.
- **Revert** (all differing cells, confirmation "Revert <category> in <scenario> to the budget? Your edits to this item in the scenario are lost."): new `Scenarios.revert(db:scenarioId:entryId:)`, one transaction:
  - `added` → delete the scenario entry (exceptions cascade).
  - `changed` / `removed` → delete the scenario entry; if its `sourceEntryId` budget entry still exists, insert a fresh unchanged copy of it (and its exceptions) into the scenario, exactly as `create`/`refresh` copy (sourceEntryId set, scenarioChange NULL). If the source no longer exists, nothing is re-copied.
  - A "this and all following" split shows as two differences (the ended original `changed` and the new `added`); each is reverted on its own.
- After any edit/revert/apply the differences, comparison and grid reload.

### Grid tab
Chips are single-select (Budget or one scenario). A header bar under the chips in the selected plan's colour: "Editing **<name>**" for a scenario; "Budget — read-only, edit it in the Budget grid" for Budget. Cells that differ from the budget are shaded with the scenario's colour (light tint, whole cell) instead of the generic highlight; the legend swatch follows.

## Click an empty cell to add (Budget grid and scenario grid)

- Clicking an **empty** category cell (no actual, nothing planned) in an **open or future** pay month opens "Add planned item" with that category preselected (category picker still editable), one-off, date = today if the cell's month is the current month, else the 1st of that month.
- Clicking an empty **reserve** cell in an open/future month opens the reserve "Add amount" sheet for that reserve with that month's date.
- Closed months, section/group/total rows and balances do nothing on an empty cell. Non-empty cells keep opening their drill-down.
- In the Forecast grid this applies only when a scenario is selected (items go to that scenario, as the section "+ Add item" does); Budget stays read-only.
- The add sheets gain an optional initial category and initial date (no other behaviour change).

## Testing

BudgetCore XCTest: `Scenarios.revert` (added deleted; changed → fresh unchanged copy with exceptions; removed tombstone → copy back; missing source → just deleted; other scenarios untouched); the differences matrix builder (pure: rows keyed by source id / added entry id, cells per scenario, budget cell, sorting; one budget item changed in two scenarios = one row). App: build; full suite.
