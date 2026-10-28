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
