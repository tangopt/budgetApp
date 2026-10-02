# Statement Balances — Design Spec

## Overview

When a bank CSV has a running **Balance** column, importing it should also record the account's balance as `BalanceSnapshot`s, so net worth and the forecast follow the statement without anyone typing balances. In the original spreadsheet the monthly balance row did this job by hand; this makes the importer do it for the account being imported.

Companion to the Dashboard spec (`2026-10-02-dashboard-design.md`), which explains why it matters: without it, importing a statement into a `manual` account leaves net worth on the last typed balance and *lowers* the forecast (months now counted as actual, whose effect is in no balance). This spec is planned and built **before** the first real import.

## Current state (verified)

- `CSVStatementParser` ignores any Balance column; `ParsedTransaction` is `(date, rawDescription, amountMinorUnits)`.
- `ImportProfile` stores column indexes (date, description, amount, optional credit); `CSVMappingWizardView` defaults every picker to columns 0/1/2 regardless of the header, so for a typical bank export (e.g. Lloyds: `Transaction Date, Transaction Type, Sort Code, Account Number, Transaction Description, Debit Amount, Credit Amount, Balance`) every picker must be changed by hand.
- `BalanceSnapshot(accountId, date, balanceMinorUnits, note)` has no uniqueness on `(accountId, date)`. Balances are signed (credit accounts negative when owed). Typed snapshots from the Net Worth screen are stamped with `Date()`; snapshots from the spreadsheet migration are dated the 1st of each month.
- `NetWorthCalculator`: a `.manual` account's balance is its latest snapshot; an `.imported` account's is the latest snapshot **plus transactions dated strictly after it**. So a snapshot at date *d* must mean "balance at the **close** of day *d*" to be consistent with that rule.
- `ImportViewModel` commits in several partial steps (`confirmReady`, `confirmRow`, `saveRemainingAsUncategorized`); there is no single "import finished" moment.
- Real example verified: the Lloyds Classic CSV (660 rows, 16 Feb → 29 Sep 2026, newest first, 112 days with several rows). Re-sorted oldest-first with same-day order reversed, `balance[i] == balance[i-1] + amount[i]` holds for **all** rows; with the file's own order it breaks 656 times — so the row order inside a day must be resolved, not assumed.

## Goals

- Optional **Balance column** in the CSV mapping; recorded as snapshots on import.
- The wizard **suggests the column mapping from the header names** (so the Balance column gets mapped by default, and the other five pickers stop needing manual changes for a typical bank export).
- Balances are only recorded if the Balance column is **verified**: it must add up with the transaction amounts for every row.
- Works in either tracking mode; each snapshot is a plain fact from the bank.

## Non-goals

- PDF statements (no balance parsing), credit-card accounts (balance sign conventions vary between banks; the feature is switched off for `AccountKind.credit` accounts), multi-account statements, back-filling snapshots earlier than the file's first transaction.
- Changing how tracking modes compute balances, or the forecast anchor.
- Reconciliation UI beyond the existing drift warning.

## Design

### Data

- `ImportProfile.csvBalanceColumnIndex: Int?` (nil = no balance column), migration `addBalanceColumnIndexToImportProfile` (nullable column, like the credit-column migration). Existing profiles are unaffected.
- `ParsedTransaction.balanceAfterMinorUnits: Int?` (default nil). Filled by `CSVStatementParser` when the profile has a balance column; a blank or unparsable cell gives nil for that row and **never** fails the row.

### Snapshot points

A *point* is `(date, balanceMinorUnits)` meaning "balance at the close of `date`" (UTC midnight date). From one file's rows, `StatementBalanceExtractor` produces:

- one point for **each 1st of a month that falls between the file's first and last transaction date (inclusive)**: the balance after the chronologically last row dated on or before that 1st (so a month with no activity on the 1st carries the prior balance, and rent paid on the 1st is included); and
- a **closing point** at the last transaction date: the final row's balance.

This reproduces the spreadsheet's monthly balance row (dated the 1st) for the months the statement covers, plus a current closing balance. The real file yields 8 points: 1 Mar £41,419.46; 1 Apr £38,183.15; 1 May £36,447.01; 1 Jun £35,836.84; 1 Jul £34,099.72; 1 Aug £31,522.99; 1 Sep £27,926.43; closing 29 Sep £27,596.28.

### Verification and ordering (`StatementBalanceExtractor`, pure)

Result is one of:

- `.notProvided` — no row has a balance (no balance column mapped, or it is empty): nothing is shown.
- `.unverified(reason)` — some rows lack a balance, or no ordering of the rows makes the balances add up. Nothing is recorded; the review screen explains why (orange note).
- `.available(points)` — verified.

Algorithm: take two candidate chronological orders — the rows stably sorted by date as given, and the rows reversed then stably sorted by date (this resolves same-day order for both newest-first and oldest-first exports). A candidate is **consistent** if every consecutive pair satisfies `balance[i-1] + amount[i] == balance[i]`. Use the first consistent candidate; if neither is consistent, `.unverified`. Points are then computed from that order. The check is strict by design: a missing row, a pending item or a mis-ordered file is reported instead of silently recording a wrong balance.

### Recording

- `ImportCoordinator.recordStatementBalances(accountId:sourceFileName:points:) -> StatementBalanceRecording(added:updated:)`: for each point, **upsert by `(accountId, date)`** — update balance and note if a snapshot already exists on exactly that date, otherwise insert. Note text: `Statement balance — <file name>`. Idempotent: re-importing the same file changes nothing.
- A snapshot that already exists on one of those exact dates (for example from an earlier statement of the same account) is replaced by the bank's figure; the review panel says so.
- Typed snapshots (stamped with a time of day) never collide with statement points (UTC midnight), so they are never overwritten.

### When it happens (review screen)

Staging attaches the verified result to `StagedImport.statementBalances` (computed from **all** parsed rows, including ones later skipped as duplicates). The review screen shows a **Statement balances** panel above the transaction list:

- *available*: "8 balances from the statement, closing £27,596.28 on 29 Sep 2026", a toggle **Record them when I confirm** (default on), a **Record now** button, and the caption "Snapshots on the same dates are replaced."
- *unverified*: an orange note with the reason; no controls.
- *recorded*: a green "Recorded 8 balance snapshots" line.

With the toggle on, the balances are recorded once, on the **first successful commit** of that import (`confirmReady`, `confirmRow` or `saveRemainingAsUncategorized`); cancelling the import before any commit records nothing. **Record now** exists for the all-duplicates case (nothing to commit) and for recording early. If recording fails after a commit succeeded, the transactions stay committed and the error says so.

Credit accounts, PDF imports, and files without a mapped Balance column never show the panel.

### Wizard suggestions (`CSVColumnSuggester`, pure)

`suggest(header:) -> CSVColumnSuggestion` matches header names case-insensitively, checking in this order so overlapping words resolve correctly:

1. contains "balance" → balance;
2. contains "credit", "paid in" or "money in" → credit;
3. contains "debit", "paid out", "money out" or "withdrawal" → debit (stored as the profile's amount column);
4. contains "amount" → amount;
5. date: first header containing "date", preferring one containing "transaction";
6. description: first match in priority order "description", "details", "narrative", "payee", "reference".

If both a debit and a credit header are found, the suggestion enables the separate debit/credit mode; a lone credit header is ignored. Unmatched fields fall back to today's defaults. For the real header this yields date 0, description 4, debit 5, credit 6, balance 7. The wizard pre-selects these and has a **Balance column** picker with a "None" choice.

### Safe live verification

`AppEnvironment` honours an optional `BUDGET_DB_PATH` environment variable (falls back to the Application Support path), so the importer can be exercised against a **copy** of the real database without touching it. Launch with `open --env BUDGET_DB_PATH=… <App>.app`.

## Effects by tracking mode

| | `manual` | `.imported` |
|---|---|---|
| Net worth after import | follows the latest recorded snapshot (the closing balance) | latest snapshot + later transactions; the closing snapshot realigns any drift |
| Monthly net worth line | month-start snapshots fill Mar–Sep instead of a flat carry-forward | same, plus intra-month transactions after each snapshot date |
| Forecast anchor | current net worth now includes the statement balance | same |

Other accounts without a statement (ISAs, joint, EUR) still need typed balances; the dashboard's stale-balances item covers them.

## Error handling

| Situation | Behavior |
|---|---|
| Balance column mapped but cell blank/unparsable on some rows | `.unverified` ("some rows have no readable balance") |
| Balances don't add up in either order | `.unverified` ("the Balance column doesn't add up with the amounts") |
| File has no rows | existing "No transactions were found" error, no panel |
| Recording throws | transactions stay committed; error banner "Transactions were confirmed, but the statement balances couldn't be saved: …" |
| Credit account / PDF | panel never shown |

## Testing

- **BudgetCore (XCTest):**
  - `CSVColumnSuggesterTests` — the real Lloyds header; single "Amount" header; "Paid in/Paid out/Balance" style; lone credit header ignored; no matches → nils; "Debit Amount" classified as debit not amount.
  - `CSVStatementParserTests` — balance column parsed incl. thousands separators and negative; blank/short row → nil balance without failing the row; profile without balance column unaffected.
  - `ImportProfileStoreTests` — `csvBalanceColumnIndex` round trip.
  - `StatementBalanceExtractorTests` — newest-first file with same-day ties (the real shape); oldest-first file; points land on 1sts with carry-forward over a quiet 1st; balance taken *after* a transaction dated on the 1st; closing point; last transaction on a 1st (single point, marked closing); single row; first transaction on a 1st; month boundaries across a year end; inconsistent chain → `.unverified`; one missing balance → `.unverified`; no balances → `.notProvided`.
  - `ImportCoordinatorTests` — `stageCSVImport` attaches `.available`; duplicates-only re-stage still carries balances; `recordStatementBalances` inserts, is idempotent, replaces a same-date snapshot, leaves a typed (time-of-day) snapshot alone.
  - `DatabaseManagerTests` — the `importProfile` table gains the `csvBalanceColumnIndex` column.
- **App layer:** clean `xcodebuild`; then against a **copy** of the live database (Lloyds Classic temporarily set to `imported` in the copy), import the real CSV: the wizard pre-selects the Lloyds columns, the panel shows 8 balances with closing £27,596.28, confirming records exactly the 8 values listed above, and Net Worth shows Lloyds Classic at £27,596.28.

## File summary

- New: `Sources/BudgetCore/Import/CSVColumnSuggester.swift`, `Sources/BudgetCore/Import/StatementBalanceExtractor.swift`; tests `CSVColumnSuggesterTests`, `StatementBalanceExtractorTests`.
- Modified: `Sources/BudgetCore/Models/ImportProfile.swift`, `Sources/BudgetCore/Database/DatabaseManager.swift`, `Sources/BudgetCore/Import/ParsedTransaction.swift`, `Sources/BudgetCore/Import/CSVStatementParser.swift`, `Sources/BudgetCore/Import/ImportCoordinator.swift`, `App/Import/CSVMappingWizardView.swift`, `App/Import/ImportViewModel.swift`, `App/Import/ReviewView.swift`, `App/AppEnvironment.swift`; existing tests for parser, store, coordinator, database.

## Follow-ups (not part of this spec)

1. PDF statements with a balance column; credit-card balance sign handling.
2. A pre-import preview of how many snapshots would be added vs replaced.
3. Offering to switch an account's tracking mode once its balance is statement-driven.
