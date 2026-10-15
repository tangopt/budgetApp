# Budget: Show/Hide Forecast and Forecast per Account — Design Spec

Requested 2026-10-15; option A chosen in chat ("A").

## 1. Show forecast toggle
- Budget toolbar toggle **Show forecast** (on by default; remembered across launches). Off: cells show actuals only (no pending/expected amounts, no pending icons, no forecast-derived Year Total parts, current/future months show actuals only); Add planned item on empty cells stays available. The forecast also drives net worth: with the toggle **on**, net-worth rows and the year cards project future months/year-ends with the forecast (as today); with it **off**, net-worth rows show actual balances up to today only (future months blank, "—") and the current year's card shows the actual net worth today instead of the year-end forecast (caption "today" instead of " forecast"); past years are unchanged.

## 2. Planned items have an account
- Migration (appended last): `forecastEntry.accountId INTEGER NULL REFERENCES account(id) ON DELETE SET NULL`. Applies to base planned items and scenario entries alike (scenario copies keep it).
- **Effective account** (BudgetCore, pure, tested `PlannedItemAccounts`): explicit `accountId` if set; else the **inferred** account for the entry's category = the account holding the largest number of that category's budget-facing transactions over the last 12 pay months (ties → most recent transaction's account; none in 12 months → over all history; none at all → nil). Reserves (isReserved categories) use the same rule; usually nil.
- **Transfer categories tied to an account** (`category.transferAccountId`): a planned item in "Transfer: Joint" moves money from its effective account (the paying account) to the tied account (Joint). With a filter: the paying account shows the outgoing amount; the tied account shows the incoming amount (sign flipped) under the paying account's transfer category ("Transfer: Current") — the same rule as actual linked transfers. With "All accounts": counted once as sent (unchanged).
- **Planned item sheets** (add/edit occurrence, App/Budget/PlannedItemSheets.swift; Forecast scenario entry editing where entries are edited): an **Account** picker — "Automatic (<inferred account name or "none">)" plus accounts by displayName. Saving stores nil for Automatic.

## 3. Budget with an account filter
- With a filter, the grid shows actuals of the selected accounts (as today) **plus** planned/expected amounts of planned items whose effective account is selected (and incoming planned transfers into a selected account per §2). Items with no effective account are hidden while filtered. Pending icons and amounts behave as they do unfiltered, limited to those items. Add planned item on an empty cell is available when exactly one account is selected (prefills that account) and with "All accounts".
- Auto-forecast / detected expected amounts (whatever produces "expected" values that aren't planned items): attribute by the same category-inference rule.
- The side panel's planned occurrences section lists only the filtered items, each showing its account name.
- Remove the "planned items have no account" special-casing introduced for the account filter (pending hidden while filtered).

## Testing
BudgetCore XCTest: migration; inference (majority, ties, 12-month window fallback, none); explicit wins; transfer-category planned item split per account; budget calculator with filter (single account, two accounts incl. both transfer legs selected → once as sent, unfiltered unchanged); show-forecast off yields actuals only. App: build, full suite, no warnings.
