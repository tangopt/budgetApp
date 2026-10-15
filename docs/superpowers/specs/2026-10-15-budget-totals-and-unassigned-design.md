# Budget: Total In/Out Rows and Assigning Unassigned Forecast Items — Design Spec

Approved in chat 2026-10-15 ("go").

## 1. Totals block
- New "Totals" section between Adjustments and Accounts in the Budget grid (collapsible like the others via GridOutline; when collapsed the **Net** row stays visible): rows **Total in**, **Total out**, **Net** (= in + out with out negative; shown signed).
- Total in: Income plus incoming external-transfer money (positive amounts in isExternalTransfer categories). Total out: Expenses + Reserved (reserve allowance cells as shown) + outgoing external transfers. Internal (own-account) transfers are excluded with All accounts; with an account filter, transfer money arriving in the selected accounts counts in and money leaving them counts out (unless both legs selected → once as sent → excluded since it nets to zero within the selection). Adjustments excluded.
- Cells reuse the plan cell semantics: actual + pending with italic/pending colour when any planned money is included; Show forecast off → actuals only; Year Total and multi-year columns (with Δ) like other aggregate rows; side panel on click lists the contributing transactions/planned items (reuse aggregate panel behaviour).
- Pure, tested BudgetCore helper for in/out per month (actual and planned parts) with and without account filter.

## 2. Assign unassigned forecast items
- Clicking a "Not assigned to an account" cell (month or Year Total) opens the side panel listing the planned occurrences with no effective account in that period (amount, category, date), each with Edit… and an **Assign to ▾** menu (accounts by displayName). Assigning sets the item's `accountId` for the series ("this and all following" — the whole series, since account is per series) via PlannedItems/OccurrenceChange.
- Panel header: **Assign all to ▾** applies to every unassigned item shown (one write).
- After assigning: caches invalidated, the row/account balances update, the panel refreshes; the row hides when the year has nothing unassigned.
- Tests: assigning moves the amount from unassigned to the account (sum still equals Net Worth); assign-all in one write.
