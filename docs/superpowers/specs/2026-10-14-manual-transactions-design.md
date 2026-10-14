# Manual Transactions — Design Spec

Requested 2026-10-14 (approved in chat). Case: a transfer from Lloyds Club Joint to the Lloyds Investment ISA was imported in the Joint account; the ISA side can't be created because transactions only come from imports.

## 1. Model
- Migration (appended last): `transaction_.isManual BOOLEAN NOT NULL DEFAULT 0`. Manual transactions live in a per-account import batch with `sourceFileName = "Manual entries"` (created on first use, reused after). Fingerprint: `manual-<uuid>` (never collides with bank fingerprints, never treated as an import duplicate).
- BudgetCore `ManualTransactions` (tested):
  - `add(db:accountId:date:description:amountMinorUnits:categoryId:note:) -> Transaction` — status confirmed when categorised, else pendingReview; categorizedBy manual; isManual true; rejects reserves (readable error), zero amount, empty description.
  - `update(db:id:date:description:amountMinorUnits:accountId:categoryId:note:)` — manual transactions only (readable error otherwise); moving to another account moves it to that account's Manual entries batch; existing transfer links are kept unless the change breaks the link's sign/account rules (then the link is removed).
  - `delete(db:id:)` — manual only; links cascade.
  - `addOtherSide(db:transactionId:accountId:) -> Transaction` — for a transaction with no active link: creates the opposite-sign manual transaction in the chosen account (different from the source's), same date, amount converted with the stored exchange rate when currencies differ, same category, description "Transfer from <source account displayName>" / "Transfer to …", then creates a manual TransferLink (out = the negative leg, in = the positive leg). Refuses when the source's category is an external-transfer category (readable error) or when the source is already linked.
- Budget-facing rules unchanged: a linked pair counts once as sent; manual transactions count like any other; balances include them.

## 2. UI
- **Add transaction…**: on the Accounts screen (per account row/menu) and in the Budget side panel header (account preselected from the panel's filter when exactly one account is selected, else the first account). Sheet (SheetScaffold): account, date, description, Money in / Money out segmented, amount (MoneyField, account currency), category (CategoryPickerButton incl. New category…), note. Save adds; the grid/panels/categories/uncategorised count refresh.
- Manual transactions show a small secondary "Manual" tag in side panels and transaction lists. Edit transaction for a manual one: date, description, amount (with in/out), account editable, plus **Delete…** (destructive, confirmation). Imported ones stay as today (category, note, links).
- Edit transaction for an unlinked transaction (manual or imported) whose category isn't an external-transfer category: **Add the other side…** → choose the account (all other accounts) → creates and links; the sheet then shows the link line.

## 3. Imports replacing manual entries
- During staging, a staged row that matches a manual transaction in the same account (same amount and sign; date within ±3 days; that manual transaction not already replaced) is marked "Replaces your manual entry (<date>)" in the review; its category and note pre-fill from the manual entry; it's Ready.
- On Finish import (same write as the commit), for each such row: the imported transaction takes over — the manual transaction's transfer links are repointed to the imported one, then the manual transaction is deleted. If the row is left out or the import cancelled, nothing changes.
- Tested in BudgetCore (staging annotation + commit replacement, links repointed, balances).

## Testing
BudgetCore XCTest for every operation and rule above. App: build; full suite; no warnings.
