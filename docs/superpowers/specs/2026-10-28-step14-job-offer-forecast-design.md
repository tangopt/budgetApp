# Step 14: a job offer in the Forecast (Mac) — design

Status: written 2026-10-28 for an unattended run; calls marked *(my call)* for the user's review. Budget ~3%.
Depends on step 13 (salary simulator in BudgetCore). Related future step 17 (compare several scenarios at once).

## 1. Intent

The user (2026-10-26): "use a salary simulation on the forecast to simulate a potential job offer (Mac only)". See
what the offer does to the months ahead — net worth, savings, the budget — before deciding.

## 2. Behaviour

- From the Mac salary simulator's "Offer" column: **"Try in Forecast…"** opens a sheet: which salary income it
  replaces (the person's current salary forecast entry, preselected), the start month, and optionally a one-off
  (signing bonus, notice-period gap: months with no salary). Save creates a **scenario** in the existing scenario lab
  (memory: budget plan + scenario lab, 2026-10-08) *(my call: reuse scenarios, not a new mechanism)*.
- The scenario replaces the salary entry's amount from the start month with the simulator's net monthly pay, and
  changes pension contributions to the offer's employee/employer pension if a pension forecast entry exists
  *(my call)*; adds the one-offs.
- Forecast shows it like any scenario: compare against the base forecast (net worth line, monthly surplus, year
  totals). The simulator inputs are stored with the scenario so it can be re-opened and edited in the simulator
  ("Edit offer…") *(my call)*.
- Nothing changes the base forecast or actuals; deleting the scenario removes everything.

## 3. Constraints

Logic in BudgetCore (scenario builder from a simulator result); Mac only; fits 1100×700; no figure wraps; Save-only;
scenarios sync as today (they're the user's own, private as the forecast already is); no filed-year effect.

## 4. Non-goals

Comparing several scenarios together (step 17); iPhone/iPad forecast.
