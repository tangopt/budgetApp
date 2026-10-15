# Forecast Grid Parity with the Budget Grid — Design Spec

Requested 2026-10-15: "add all the features we added to the budget grid to the forecast grid (category icons, expand/collapse functionalities, total rows, cell selection and detail pane)".

Scope: the Forecast scenario grid (App/Forecast/ScenarioGridTab.swift and its view model) gets, with the same look and behaviour as the Budget grid (App/Budget/*):
1. Category icons on category rows (same CategoryIcon view as Budget).
2. Expand/collapse: section headers collapsible with chevrons, hover Expand all / Collapse all per section, ⌥-click on group chevrons, persisted per screen (already partly there via GridOutline — verify parity incl. Net Worth/Reserved totals kept when collapsed).
3. Totals block (Total in, Total out, Net) between Adjustments and Accounts, teal-tinted (0.17 / 0.28 Net), collapsible keeping Net, computed for the scenario's plan with the same BudgetTotals helper (scenario entries instead of budget entries; actuals the same).
4. Cell selection and detail pane: clicking a cell outlines it (2pt accent) and opens the right SidePanelHost panel (like BudgetCellPanel) listing actual transactions and the scenario's planned occurrences for that row/period with Edit…/Remove… for scenario items (reusing the existing scenario edit sheets), replacing the current drill-down sheet; Escape/✕ closes; empty open-month cells keep "add" behaviour.
Constraints: smooth-scroll rules (offset only via HorizontalOffsetFollower, widths only via BodyWidthFollower; `.clipped().contentShape(Rectangle())`), caches so Show forecast / scenario switches stay instant, row ids unique. Prefer extracting shared components from Budget (row/cell views, panel) over duplicating.
