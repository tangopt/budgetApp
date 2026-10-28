# Mac Dashboard: resizable layout, saved — design

Status: 2026-10-28. User: "On the mac dashboard allow to resize rows and columns. Save the layout." Calls marked
*(my call)*.

## Behaviour
- Each dashboard section (Money, Property, Tax & documents) is a grid of tiles. The user can **resize a tile** to
  span 1–3 columns and 1–2 rows by dragging its bottom-right corner (snaps to the grid), and **drag tiles to
  reorder** within a section *(my call: not across sections)*.
- **Column count** per section: Auto (by window width, today's behaviour) or 2 / 3 / 4, from a small menu on the
  section header *(my call)*. **Row height** per section: Compact / Regular / Tall from the same menu.
- An **Edit layout** button in the toolbar turns on resize handles and drag; **Done** saves; **Reset layout**
  restores the default. Outside edit mode nothing moves by accident.
- The layout is **saved** per user on this Mac (local settings, not synced *(my call)*), and survives relaunch.
  Hidden-card settings keep working; a hidden tile's slot closes up.
- Charts redraw to their tile size; no figure wraps or truncates at any span (tiles too small for a figure fall back
  to the figure without the chart).

## Constraints
Layout model (spans, order, columns, row height, persistence, reset, packing) in BudgetCore/App model with tests;
fits 1100×700 by default; works with window resize.

## Revision 2026-10-28 (user): fluid, not a static grid
User: "I would want a more fluid adjustment of the rows and columns with content within the affected tiles to
adjust. You made it so I can change the layout but still works as a static grid."
- Each section is laid out as **rows of tiles**. Between two tiles in a row there is a **draggable divider**: dragging
  it moves the boundary continuously (any width, not snapped spans), the neighbouring tiles shrink/grow live.
  Between rows a **horizontal divider** changes that row's height continuously. Dividers are always available on
  hover (thin handle, resize cursor) — no separate edit mode needed for sizing; a menu keeps Reset layout and
  moving tiles between rows/reordering *(my call)*.
- **Content adapts live to the tile's size**, not just clipped: charts fill the space (more axis labels/points as
  they grow); lists show more rows as the tile gets taller (top 2 → 3 → 5 categories, bills, accounts); secondary
  lines appear/disappear by available height; the big figure stays and never wraps or truncates; below a minimum
  size the chart drops before the figure. Minimum tile width/height so nothing breaks.
- Proportions are saved (fractions of the row width, row heights), per Mac, and reapply when the window resizes
  (tiles scale proportionally with the window). Reset layout restores the default.
