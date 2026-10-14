# Balances From Transactions + Transfer Categories Per Account — Design Spec

Requested 2026-10-14 (approved in chat; Adjustments section in the Budget per recommendation unless the user objects).

## 1. Balance model
- An account has an **opening balance** (amount + date), entered when the account is created. It is the only typed balance.
- Balance at any date = opening balance + all transactions (any source, incl. manual and adjustments) dated after the opening date up to that date. The `trackingMode` distinction is removed from calculations (column kept for compatibility, ignored).
- **Update balance…** (Accounts screen, bulk update sheet) no longer writes a snapshot: the user enters the actual balance on a date; the app creates a manual transaction for the difference (actual − computed at that date) in a built-in category:
  - investment accounts → **Market movement**;
  - other accounts → **Balance adjustment** (sheet shows a caution: "Adjusting a cash account's balance is unusual — check for missing or duplicate transactions first").
  - Zero difference → nothing created ("Balance already matches").
- Built-in categories: new `category.builtInRole TEXT NULL` (`balanceAdjustment`, `marketMovement`); created by migration if missing; cannot be renamed/deleted/moved (Categories screen shows them read-only under a new **Adjustments** type section); type = new `CategoryType.adjustment`.
- Budget: a new **Adjustments** section (below Transfers) shows these categories' actuals; excluded from income/expense/transfer totals and plan; included in net worth (balances).
- Net worth / Accounts / Dashboard use the new balance rule.

## 2. Statement imports
- Statement balance points are no longer stored as snapshots. After staging, the app computes the account balance at the statement's closing date including the staged rows that will be saved (confirmed or not-yet-decided rows assumed included; rows left out at Finish are excluded at that point — recompute in the finish dialog).
- If |statement closing − computed| > 0: the review shows a red error banner with both figures, the difference and the date, and suggestions (check missing/duplicate transactions, import the missing period). An option "Add a balance adjustment of £X" exists, **unticked**; if ticked, Finish import adds it (Balance adjustment / Market movement by account kind) in the same write.
- Finishing with a mismatch is allowed; the account then shows a warning badge on the Accounts screen ("Statement mismatch on <date>: £X") until a later import or an adjustment resolves it (store `account.statementMismatchMinorUnits` + date, cleared when a later statement matches).

## 3. Data conversion (one-off tool, controller-run with backup and a before/after check)
- Per account: opening balance = earliest snapshot (amount, date). For each later snapshot in date order: adjustment amount = snapshot − (balance computed at that date from the opening + transactions + previous adjustments); if non-zero, insert a manual transaction on that date in Balance adjustment (or Market movement for investment accounts), description "Balance adjustment (converted)". Then delete the snapshots (or keep them in an archive table `balanceSnapshotArchive`).
- Verification: every account's month-end balance for every month from 2020 to today is identical before and after (tool prints any differences and aborts with rollback on mismatch).

## 4. Transfer categories per account
- `category.transferAccountId INTEGER NULL` (FK account, SET NULL). Each account gets a transfer category "Transfer: <displayName>" (auto-created for accounts without one; renamed when the alias/name changes). Existing transfer categories are tied by exact name match "Transfer: <account name or alias>"; others get a **Linked account** picker on the Categories screen (transfer categories only; external-transfer categories can't have one).
- When a pair is linked (auto match, Link to transfer…, Add the other side…): the out leg's category = the in-account's transfer category; the in leg's category = the out-account's transfer category. Unlinking leaves categories as they are.
- Budget counting unchanged (once as sent; per-account filter shows own legs).

## Testing
BudgetCore XCTest for: balance rule; Update balance → adjustment (both kinds, zero difference); built-in categories (creation, protection, Budget exclusion from totals, net worth inclusion); statement mismatch computation + optional adjustment at Finish + account warning; conversion function (opening + adjustments reproduce every month-end exactly on fixtures incl. the user's shapes: spreadsheet monthly snapshots + transactions, statement snapshots); transfer category tie/auto-create/rename/apply on link. App: build; full suite; no warnings.
