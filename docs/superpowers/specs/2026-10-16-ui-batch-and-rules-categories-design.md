# UI Batch, Manual Rules, Categories Distribution — Design Spec

Requested 2026-10-16.

## A. UI tweaks
1. Sidebar: a Settings button (gear, "Settings") pinned at the bottom of the sidebar (safeAreaInset where the old appearance toggle was) opening the Settings window (`openSettings` environment action).
2. Budget: the account filter panel starts collapsed by default (persist the user's open/closed choice across launches via AppStorage; default collapsed).
3. Budget toolbar: the share/export control is a plain icon (no bordered button chrome): toolbar Menu showing only `square.and.arrow.up`, borderless, no menu indicator, help "Share or export".
4. Forecast › Compare: the summary table uses the full available width (columns flex; no fixed max width).
5. Accounts list: the "Imported up to" date goes on the same line as the existing secondary text (or right-aligned compact caption) — no extra row height; list column narrower (e.g. 260pt min, ~32% of width) and the detail panel gets the remaining space (flexible).

## B. Manual rules (Rules screen)
- Toolbar "+ Rule" opens a sheet (SheetScaffold): Pattern (text), Match type (Contains / Regular expression — regex validated inline), Category (CategoryPickerButton incl. New category…; built-in/reserve excluded), live preview "Matches N transactions (M uncategorised)" with the first few descriptions, checkbox "Also categorise the M uncategorised matches now" (default on). Save inserts the rule with the next priority (same ordering rules the learner uses) and, if ticked, applies it to matching uncategorised transactions (confirmed, categorizedBy .rule) in the same write. Edit existing rule from the list (double-click) with the same sheet.
- BudgetCore: tested `Rules.add/update(db:pattern:matchType:categoryId:applyToUncategorised:)` and `Rules.preview(...)` using the same matcher as imports (MerchantKey/contains/regex semantics as existing).

## C. Categories screen
- Move the global Expand all / Collapse all from the toolbar into the list (a small control row at the top of the list, above the first section).
- Right side panel when no category or group is selected: **Distribution** — year filter (same as the transactions panel: current year default, "All years"), two Swift Charts donuts: **Expenses** by group (slices = groups + Ungrouped; click a slice to show that group's categories in the donut, with a back control) and **Income** by category; each with a legend list (name, amount, %), totals at the centre, theme chart colours, hover readout. Uses budget-facing actuals (same as the Budget grid: transfers counted once, adjustments excluded). Selecting a category/group shows the existing transactions panel instead; deselecting returns to Distribution.
- BudgetCore: tested `CategoryDistribution.compute(year:...) -> (expensesByGroup, expensesByCategory, incomeByCategory)`.
