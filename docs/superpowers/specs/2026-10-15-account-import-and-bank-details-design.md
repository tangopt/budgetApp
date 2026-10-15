# Import From Accounts, Regional Bank Details, CSV Account Check — Design Spec

Requested and approved in chat 2026-10-15 ("looks right, keep Other, go" plus the mapping/validation additions).

## 1. Import statement from the Accounts screen
- The Accounts detail panel's button row gets an **Import statement ▾** menu: **CSV…**, **PDF…**, **Edit column mapping…** (only when the account has a CSV profile), **Reset column mapping…** (see §4). It reuses `ImportFlowHost` with the selected account; staging opens the Import screen as from the Dashboard (ContentView already selects it when staging starts).
- The account list row's context menu also has **Import statement** ▸ CSV… / PDF….
- While an import is staging or in review the menu is disabled and a "Resume review ›" link (navigates to the Import screen) is shown.

## 2. Regional bank details
- Migration (appended last): `account.bankRegion TEXT NULL` (`uk`, `us`, `europe`, `other`), `account.bankName TEXT NULL`, `account.routingNumber TEXT NULL`, `account.bic TEXT NULL`. Existing columns kept: `sortCode`, `accountNumber`, `iban`.
- `Account.effectiveBankRegion`: stored region if set; else sort code set → uk; else IBAN set → europe; else routing number set → us; else by currency (GBP → uk, USD → us, EUR → europe, otherwise other). The migration does not need to backfill (derived at read time); saving an account stores the region shown.
- Fields and validation per region (normalised on save: trim; empty → nil; inline errors):
  - UK: sort code (6 digits, shown 30-00-00), account number (8 digits — relax to 6–8 as today if shorter numbers already stored, show as stored), optional IBAN.
  - US: routing number (9 digits, ABA checksum 3·(d1+d4+d7) + 7·(d2+d5+d8) + (d3+d6+d9) ≡ 0 mod 10), account number (4–17 digits).
  - Europe: IBAN (15–34 alphanumerics, 2 letters + 2 digits, **mod-97 checksum** enforced), shown in groups of 4.
  - Other: account number (free text, trimmed, ≤ 34 chars).
  - All regions: bank name (optional, free text), BIC/SWIFT (optional; uppercase, 8 or 11 alphanumerics: 4 letters bank, 2 letters country, 2 alnum location, optional 3 alnum branch).
  - Fields not belonging to the chosen region are kept in the DB but hidden (switching region back shows them again); validation applies only to visible fields. Existing IBANs failing the new checksum keep loading; the error shows only when the user edits that field.
- Edit/Add account sheets: Region picker at the top of a "Bank details" section, showing only that region's fields plus bank name and BIC.

## 3. Detail panel "Bank details" section
- Titled section: bank name, then the region's fields formatted locally (sort code 30-00-00, routing number 9 digits, IBAN in groups of 4, BIC), each with a copy button (unformatted value); **Copy all** puts a plain-text block on the clipboard, e.g. "Lloyds Bank\nName: Lloyds Classic\nSort code: 30-00-00\nAccount number: 12345678\nBIC: LOYDGB2L" (only set lines; account full name line uses `account.name`).
- No details: an "Add bank details…" link opening the Edit sheet.
- Tested BudgetCore helper `BankDetailsFormat.lines(for:) -> [(label, shown, copied)]` and `copyAllText(for:)`.

## 4. Redo the import mapping
- **Reset column mapping…** (Accounts menu §1 and the Dashboard import card's CSV menu): confirmation "Reset the column mapping for <account>? The next CSV import asks you to map its columns again." → deletes the account's CSV `ImportProfile` (BudgetCore `ImportProfileStore.delete(accountId:format:)`). **Edit column mapping…** stays as today (reopens the sheet with the last file or asks for one).
- Same for PDF layouts if a PDF profile exists: "Reset PDF layout…".

## 5. CSV account columns: validate or fill
- New CSV roles `sortCode` and `accountNumber` (`CSVColumnRole`, `ImportProfile.csvSortCodeColumnIndex`, `csvAccountNumberColumnIndex` — migration appended last). The suggester detects headers "Sort Code"/"Sort code"/"Sortcode" and "Account Number"/"Account No"/"Account" (exact-ish, case-insensitive; not "Account Name"). For a saved profile without these roles, staging still detects them by header name (no profile change needed).
- Values normalised: strip quotes/apostrophes (Lloyds exports `'30-94-57`), spaces and dashes; sort code → 6 digits; account number → digits.
- Before staging (`StatementAccountCheck`, pure, tested): collect distinct (sortCode, accountNumber) pairs from the rows.
  - Account has sort code and/or account number set and the file's values differ (or the file has more than one distinct pair): **block** with an alert: "This file is for sort code 30-94-57, account 12345678 — <displayName> is 30-00-00, 87654321." Buttons: **Cancel** (default) and **Import anyway**.
  - Account fields empty (and the file has one distinct pair): stage normally; on **Finish import** (commit) fill the empty fields (only the empty ones) and set `bankRegion = uk` if no region stored; the import's finish message mentions "Saved sort code and account number to <account>". Cancelled imports fill nothing.
  - Only one of the two present in file or account: compare what both have.
- PDF imports unchanged.

## Testing
BudgetCore XCTest: region derivation; UK/US/Europe/Other normalisation and validation incl. ABA and IBAN mod-97 and BIC; migration; BankDetailsFormat lines and copy-all text; ImportProfileStore.delete; CSV role suggestion for the account headers and Lloyds-style apostrophe values; StatementAccountCheck (match, mismatch, multiple pairs, empty account → fill plan); commit fills empty fields only. App: build, full suite, no warnings.
