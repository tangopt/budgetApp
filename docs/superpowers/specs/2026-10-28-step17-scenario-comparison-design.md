# Step 17: compare the budget with several scenarios at once (Mac Forecast) — design

Status: 2026-10-28. User (2026-10-27): "compare budget and a set of different scenarios instead of one against the
other: e.g. a scenario where my salary goes up 10% and another where I buy a car; compare the current budget with
both or only one of them, seeing the impact of each." Calls marked *(my call)*. Budget ~4%.

## Behaviour
- Forecast's scenario lab gains a **Compare** view. At the top: the budget (always on) and a checkbox per scenario
  (e.g. "Salary +10%", "Buy a car", a job offer from step 14), plus a **Combined** toggle that applies every ticked
  scenario together.
- **Chart:** net worth over the forecast horizon — budget line, one line per ticked scenario, and the combined line
  when on. Hover shows each line's value that month.
- **Impact table:** one column per line (Budget, each scenario, Combined): net worth at the end of each year shown,
  average monthly surplus, total income and spending per year, and the **difference from the budget** for each.
  The combined column also shows how much each scenario contributes *(my call: each scenario's own difference, and
  the "together" difference, so overlaps are visible)*.
- **Combining rules:** scenarios are applied in their list order onto the budget. When two scenarios change the same
  forecast entry, the later one wins and the Compare view says so ("Buy a car and Salary +10% both change
  'Groceries'; the later one is used") *(my call)*. Nothing is saved by comparing; the user can "Save combination as
  a scenario…" *(my call)*.
- Uses the existing scenario model and forecast calculator in BudgetCore (no second forecast engine).

## Constraints
Logic in BudgetCore (a combinator over scenarios + the existing forecast), tested; fits 1100×700 (table scrolls
horizontally only inside its own box if many scenarios — up to 4 ticked at once *(my call)*); no figure wraps; names
truncate in the middle; nothing changes the budget or actuals; no filed-year effect.

## Non-goals
iPhone/iPad Forecast; probabilistic scenarios.
