# Budget & Forecast Grids: Collapse Sections and Groups — Design Spec

Approved in chat 2026-10-15 ("go").

Applies identically to the Budget grid (App/Budget/BudgetGridView.swift) and the Forecast scenario grid (App/Forecast/ScenarioGridTab.swift).

- **Type sections** (Expenses, Income, Transfers, Adjustments, Accounts, and any other section header row): the header row gets the same small chevron as group rows; clicking the header's name area toggles the section. Collapsed: only the header row remains, still showing its monthly totals / Year Total (and whatever it shows today). Expanded: as today.
- **Expand all / Collapse all groups**: hovering a section header reveals two small borderless icon buttons at the right end of its name cell (SF Symbols e.g. `rectangle.expand.vertical` / `rectangle.compress.vertical`, `.help("Expand all groups")` / `.help("Collapse all groups")`, accessibility labels), acting on that section's groups only; hidden when not hovering. ⌥-click on any group chevron/name toggles all groups in that section to the clicked group's new state (Finder convention).
- **Group rows**: unchanged behaviour; the chevron gets a hover highlight.
- **Persistence**: collapsed section types and expanded group ids are remembered per screen (Budget vs Forecast; shared across scenarios) across launches (`@AppStorage`/UserDefaults, encoded as a comma-separated string or JSON). Unknown ids are ignored.
- **Grid constraints**: scroll offset observed only by HorizontalOffsetFollower, widths only by BodyWidthFollower; frozen header and pinned Year Total alignment unchanged; collapsing only removes rows. Selected-cell/side panel: if the selected row disappears due to collapse, close the panel/clear the selection.
- **Testing**: extract the row-building (which rows are shown for a given collapsed-sections / expanded-groups state) into a pure, tested helper if it isn't already (App-level helper is fine if BudgetCore isn't appropriate; if no app test target exists, put the pure logic in BudgetCore with tests). App build, full suite, no warnings.
