# Side Panels, Year Cards, Categories Screen — Design Spec

Requested 2026-10-12 (mockup approved in chat).

## 1. Budget: year selector cards

Each year in the Budget year selector is a card: the year (bold), the **year-end net worth** (31 Dec, or for the current year the forecast to December, captioned "forecast to Dec"; for past years with no data "—"), and the % change vs the previous year's year-end net worth (green ↑ / red ↓, one decimal). Selected cards are filled with the accent tint and outlined; ⌘-click still toggles multi-year compare; a dashed "Compare…" card at the end explains "⌘-click years" (non-interactive hint). Cards sit in one horizontally scrolling row. Year-end net worth comes from the same source the Dashboard/Accounts use (actual net worth at year end; forecast via the projection for the current year) — put the per-year value in a tested BudgetCore helper if it isn't already exposed.

## 2. Budget: side panel instead of the drill-down pop-up

- Clicking a non-empty cell (category, group row, section header, reserve, Year Total, multi-year year column) outlines that cell (2pt accent stroke + light accent fill) and opens a **right side panel** (slides in, ~320pt wide, resizable not required) instead of the sheet. Title: "<row name> — <Mon yyyy>" or "<row name> — <yyyy>".
- Panel content: transactions for that row and period (date, description, category name when the row is a group/section, amount, note icon), sorted by date desc, count and total; then the planned occurrences section (as in today's drill-down: expected amounts, Edit…/Remove… for unconfirmed). Each transaction has **Edit…** (existing EditTransactionSheet). Notes are shown under the description in the panel.
- Group rows and section headers aggregate their member categories; reserves show planned items only (as today).
- Clicking another cell updates the panel; ✕ or Escape closes it and clears the outline. The grid narrows while the panel is open; frozen header / pinned Year Total alignment and smooth horizontal scrolling must be preserved (scroll offset observed only by HorizontalOffsetFollower; widths by BodyWidthFollower).
- Empty open-month cells keep opening Add planned item (unchanged). The old GridDrillDownSheet is replaced by the panel (keep shared row/section views if useful).

## 3. Notes indicator on cells

A cell whose transactions include at least one with a note shows a small triangle in its top-right corner (accent/secondary colour, ~6pt). Same for group/section aggregate cells when any member transaction has a note. The panel shows the notes (§2). Computed per cell from the view model's transaction data (no extra DB reads per render).

## 4. Categories screen

- Sections **Expenses**, **Income**, **Transfers** (by category type), each listing its groups as collapsible rows "<Group> · N", then **Ungrouped · N**. Reserves (isReserved) are listed in a separate "Reserves" section, read-only here (managed on the Budget grid).
- Search field filters category and group names (case-insensitive).
- **+ Group**: creates a group and puts its name in inline edit. Group ⋯ menu: Rename (inline), Delete (confirmation; its categories become ungrouped), Add category here (New category sheet with the group preselected).
- **+ Category**: the existing New category sheet (NewCategorySheet).
- Categories: multi-select (⌘/⇧-click); drag one or several onto a group row or "Ungrouped" to move them (a group may hold categories of any type, as today); right-click menu: Move to group ▸ (list), Rename…, Exclude from auto-forecast (toggle; expenses only), Delete… (refused with a readable message when the category has transactions or planned items: "Rent has 73 transactions and 2 planned items — move or recategorise them first").
- Each category row: type icon, name, 12-month average monthly amount (actuals over the last 12 pay months; "—" when none).
- Selecting a category opens the same kind of **right side panel** with all its transactions: year filter (defaults to current year; "All years"), count and total, rows with date, description, amount, note; Edit… per transaction.
- BudgetCore (tested): `CategoryGroups.create/rename/delete(db:)` (delete ungroups members), `Categories.rename(db:id:name:)` (unique), `Categories.delete(db:id:)` (refused with a readable error when transactions or forecast entries reference it; otherwise deletes the category and the rules pointing at it), `Categories.move(db:ids:toGroupId:)`, `CategoryStats.monthlyAverage(...)`.

## 5. Accounts chart tooltip

The Accounts screen's chart shows a hover readout: a vertical rule at the hovered month and a box with the month and the value of each plotted series (same style as the Dashboard/Compare readouts), kept inside the plot area (overlay, clamped).

## Testing

BudgetCore XCTest for the new helpers (year-end net worth per year if added; category group CRUD; rename/delete/move rules; monthly average). App: build; full suite.
