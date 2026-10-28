# Step 18: widgets with charts — design

Status: 2026-10-28, written unattended; calls marked *(my call)*. Budget ~3%. User (2026-10-27): "the widgets are not
useful as they currently are, one could be a property month status in terms of recharges and another one could be
the spend expected to the current month… with graphics".

## Widgets (iPhone and iPad; WidgetKit, Widgets/ target)
1. **Property month** (small, medium): this pay month's recharge pipeline for the property — bills in / statement
   sent / paid by tenant as a 3-step progress with counts and the outstanding amount; medium adds a mini bar per
   utility (in/out). Label by **tenancy name**, never the tenant's personal name.
2. **Month spend** (small, medium, large): spent so far vs expected to date and vs the month's budget — a progress
   ring (small), a cumulative line of actual vs expected by day (medium), plus top 3 categories over budget (large).
- Keep the existing Net worth and Payday widgets *(my call)*; replace "Left this month" with Month spend *(my call)*.
- Lock-screen/redaction rules from the sync spec: figures redacted on the lock screen unless the per-device
  setting allows them; widgets keep the system font (step 16).
- Data comes from the shared WidgetEntry snapshot written by the app (no new DB access from the extension beyond
  today's); logic for the figures in BudgetCore with tests.

## Constraints
Swift Charts in widgets; no figure wraps in any family at default and large Dynamic Type; snapshot renders of each
family light/dark; tests for the figures (expected-to-date proration, pipeline counts).
