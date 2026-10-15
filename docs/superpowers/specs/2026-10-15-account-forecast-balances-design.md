# Budget: Forecast Account Balances and a Main Account — Design Spec

Approved in chat 2026-10-15.

## 1. Main account
- Migration (appended last): `account.isMain BOOLEAN NOT NULL DEFAULT 0`; at most one account is main (partial unique index on isMain = 1, or enforced in the setter). BudgetCore `AccountEditing.setMain(db:accountId:)` (clears the others; nil clears all), tested.
- Accounts screen: account edit sheet gets a "Main account" toggle with help "Planned items with no account of their own go to this account"; the detail panel shows a small "Main account" badge; the account row context menu gets "Set as main account" / "Unset main account".
- Effective account of a planned item (`PlannedItemAccounts`): explicit → inferred from category history → **main account** → nil. The picker's Automatic label reflects it ("Automatic (Current — main account)" when it falls back to main).

## 2. Account rows follow the forecast (Budget)
- Each account row's months use the same rule as the Net Worth row (`budgetNetWorthMonths`): actual month-end through the past; current month = today's balance + that account's remaining planned legs (pending logic, counted once); later months add that account's planned legs month by month. Show forecast off → future months "—".
- Legs: an item's amount goes to its effective account; tied (internal) transfers move money out of the payer and into the tied account (net worth unchanged); external transfers lower the payer; income/expense on the effective account. Non-GBP accounts convert planned GBP amounts to native at the stored exchange rate (shown native as today, GBP-converted for totals).
- Items with no effective account (no main account set, no history): a "Not assigned to an account" row at the bottom of Accounts so rows always sum to Net Worth; hidden when zero for the year.
- Forecast-derived balances render italic in the pending colour (like other forecast amounts); actual balances unchanged.
- Account filter: only selected accounts' rows (as today); the unassigned row only with All accounts.
- Year Total / multi-year columns for account rows: the year-end balance (Dec) consistent with the year card logic.
- Tests: per-account projection sums to the net-worth projection for all accounts (property test across months, both toggle states); internal transfer moves between accounts; external lowers payer; main-account fallback; EUR conversion; unassigned row.
