# iPhone import: statements and documents from Files — design

Status: 2026-10-31, design only (not built, not committed). User: "I want you to design importing statements and
documents on iPhone. You can assume I downloaded them first and I can pick them from Files." Calls marked
*(my call)*. Mockups: design canvas page "iPhone import" (Import-1 to Import-6, 390x844).

## Principle
The iPhone is a new front door to engines that already exist. Picking a file runs the same read, classify, check and
link that the iPad's Check & link sheet runs on a downloaded file; statements go through `PadStatementImport` (the
household import lease, `ImportPipeline`, `ImportApplier`, `ImportUndo`). No second import engine, no iPhone-only
parsing. Only the screens, the file intake and the routing are new.

## Entry points
1. **Accounts: "Import" button** in the page header (secondary, tray-arrow icon, 44 pt). Opens the Files picker.
2. **An account's page: "Import"** in its header. Same picker, but the account is preset: a statement that detects as
   another account says so and asks (never silently re-targets).
3. **Property > this month, a bill, a receipt: "Add document"** (paperclip). Picker opens with PDF and images only;
   everything is treated as a document and the link target is preset to that bill or receipt (still shown, still
   changeable).
4. **Share sheet "Open in Mango"** from Files, Mail and Safari *(my call: include)*. Mango declares PDF, CSV, OFX and
   image document types; `onOpenURL` copies the file into the app's inbox and opens the same review as if it had been
   picked, with no preset account or link. Needs Info.plist types and one inbox copy step; no share extension target.
   If Mango is locked, the file waits behind the lock screen and opens after unlock.
5. A "Pick from Files" row in the empty state of Month > Sort and in Home > Needs you when data is stale
   *(my call: Home only, small: "Import statement" action replacing "Update" when the stale item is a bank account)*.

## The Files picker
System `fileImporter` (UIDocumentPicker) with `allowsMultipleSelection`, types PDF, CSV, OFX/QFX, and images
(JPEG, HEIC, PNG). Mockup 2 draws the native sheet. Files are copied into a temporary inbox first (security-scoped URL
released immediately), so nothing depends on the original file staying put. Over ~20 files at once: the first 20, with
"20 of 27 added, import the rest next". Unsupported types (.docx, .zip) are not selectable; if one arrives via the
share sheet it gets the "Can't read this file" card (mockup 6) and the batch continues.

## What happens per file
Classification runs on the phone through `ImportDetector`/the Check & link engine, off the main thread, with a
reading state ("Reading 3 files", per file ticks), no spinner blocking the screen.

| File | Detected as | Goes to |
|---|---|---|
| Bank PDF/CSV/OFX whose issuer and account number match a Mango account | Statement | Statement review (account auto-detected, confirmable) |
| Statement format known, account not matched | Statement | Statement review with Account empty: pick one from a list; "Detected" pill only when matched |
| Invoice, receipt, utility bill, tenancy paper, tax paper (PDF or photo) | Document kind | Document check & link |
| Unreadable or unknown | Unsupported | "Can't read this file" card; stays out of the batch |

Photos go through the existing document reader (text recognition on device); a photo of a statement is not treated as
a statement *(my call: statements must be PDF/CSV/OFX, so the numbers can be trusted)*.

## Review: one file at a time
Batch = the files chosen. The review is a full-height sheet with page dots (1 of 3) and a swipe or "Next file" line;
Cancel leaves the whole batch (confirm if anything was already saved). Each file has its own primary action; the
screen never shows two primaries.

**Statement screen** (mockup 3): file name and "Statement" pill; Account (Detected pill, tap to change); Period; two
count tiles "14 new rows" and "3 already in Mango"; money in and money out with row counts; balance check against the
statement's closing balance; warnings in an amber card (rows outside the period, a gap since the last import,
a row that looks like a duplicate of an older one). Primary: "Import 14 rows". The rows themselves are one tap away
("See the 14 rows", a list with the duplicate ones greyed), not shown by default.

**Document screen** (mockup 4): thumbnail of page 1, file name, pages and size, "Open full view"; form rows Kind,
From, Amount, Date, each carrying a "Read" pill when taken from the PDF (amber "To check" when low confidence);
Linked to: the suggested payment or bill ("Suggested - same amount, 2 days apart") with "Choose another" and "No
link". Edits are held until **Save and link**; Cancel discards (edits save only on Save). Kind change re-runs the
suggestion. A document that is not a payment evidence (a contract) just files under its kind.

Navigation rule: Statement files can be imported in any order; the primary on each screen acts on that file only, and
after it the sheet advances. Skipping a file ("Not now") leaves it in the batch summary as "Not imported".

## Duplicates
Same engine as the Mac (`ImportDuplicates`): a duplicate row is never written; it is counted ("3 already in
Mango"). The same file twice, or a CSV that overlaps a PDF already imported, shows "All 17 rows are already in Mango"
with the primary replaced by "Done with this file" (no Import button when 0 new). A document whose hash already exists
says "Already saved as <name>" with "Open it" and "Save anyway" (text link, not a button pair).

## Lease, offline and member states (same words as the iPad)
Statements only; documents never need the lease. Route comes from `PadImportRoute`, shown in mockup 6:
- **Free or ours:** normal Import. The lease is taken on tap, renewed while importing, released after.
- **Held by another device:** "The Mac is importing (started 10:42). Try again when it finishes." Import is visible and
  disabled; "Finish on the Mac" is not offered on the phone *(my call: the file stays in the batch)*.
- **Offline:** "Connect to the internet to import". Documents can still be checked and saved locally, they sync later.
- **No import access for this account:** "This statement is imported on the Mac. Send it to the Mac to import it
  there." with **Send to the Mac** as the only action.
- **Member (Patricia) while `membersImport` is off:** no Import button, note "Statements are imported on the Mac or
  on the owner's iPad." Documents she adds still check and save if her area allows. Her name never appears except on
  Tenancies.
- **Still syncing / found changes:** the iPad's messages, unchanged ("Mango is still syncing - try again in a moment",
  "Mango found changes - check the statement again", which re-reads the file).
- **Filed tax years:** writes go through `DeviceWriter.writeCheckingFiledYears`; a refusal shows inline on the
  statement screen as a problem card and nothing is written.

## After the last file: summary (mockup 5)
"Everything is in": 28 new rows, 5 already in Mango, 1 document linked. "Where it landed" rows link to each account
(opens the account page scrolled to the new rows), the document (opens its detail), and a "Review 4 uncategorised"
shortcut into Month > Sort when new rows are uncategorised. Primary: **Done**. Below it a destructive text button
**Undo import** with the note "Undo removes the 28 rows. Linked documents stay saved." *(my call: Undo removes statement
rows only, as the Mac does; documents are removed from their own page.)*

Undo uses `ImportUndo`; conflicts (rows edited since, later import, filed year) show the Mac's wording in one sheet
with Cancel as the default. The Undo button stays on the Accounts page, under the account's last import, for the same
window as on the iPad, so closing the summary does not lose it.

## Where results show afterwards
- Accounts: "Imported - through <date>" pill disappears (stale pill clears); balances update at once.
- Month: new rows land in their month and in Sort if uncategorised; waiting documents auto-link to the new
  transactions (new rows only, step 9 rules) and Home > Needs you drops the matching item.
- Property > this month: a saved bill ticks its checklist step; an unlinked one stays as "Missing" until linked.
- Documents library (Mac/iPad) receive saved documents through sync; they appear with the device name.
- Mac import history shows "Imported on Pablo's iPhone" with Undo available from either device.

## Accessibility
- Every control 44 pt minimum; the primary 50 pt; one primary per screen; pills always carry a word.
- Dynamic Type to .xxxLarge: count tiles stack one per row, form rows wrap label above value, figures never wrap
  (wrap probe), file names truncate in the middle.
- VoiceOver: page dots read "File 2 of 3"; each count tile reads as one element; "Read" pill reads "Read from the
  file"; warnings are announced when the screen appears; swiping between files announces the new file name.
- Reduce Motion: no slide between files, a cross-fade. Dark mode via PhoneTheme roles (mockups are light only).
- Photos use the document's alt: kind, amount and date.

## Reuse vs new
**Reused (BudgetCore, unchanged):** `ImportPipeline`, `ImportDetector`, `ImportReader`/`Readers`, `ImportDuplicates`,
`ImportApplier`, `ImportUndo`, `PadStatementImport` (route, lease, copy), `DeviceWriter` and `SyncImportGate`, the
Check & link engine behind `CheckAndLinkModel` (propose, choosePayment, chooseKind, save).
**New in BudgetCore (small):** `ImportInbox` (copies picked or shared files to a temp folder, returns `TrayItem`-like
handles, 20-file cap); `ImportBatch` model (ordered files, per-file result, totals, Not-imported list) with tests.
Rename nothing; `PadStatementImport` is used as is even though the name says Pad *(my call: rename to
`StatementImport` in a later cleanup, not in this work)*.
**New in MangoUI/Phone:** `PhoneImportEntry` (button, fileImporter, onOpenURL), `PhoneImportReviewSheet` (paging),
`PhoneStatementReviewView`, `PhoneDocumentCheckView`, `PhoneImportSummaryView`, state cards. Shared small components
only: `StatusPill`, form row, primary button from the design system.
**Not in scope:** new bank formats, a share *extension* target, camera scanning, background import, members' import
(stays off), editing rows before import, importing from the built-in browser on iPhone.

## Tests
Batch ordering and totals; duplicate-only file gives no Import; lease held, offline, member and no-access routes map
to the right card; inbox copy is released on cancel; share-sheet file opens the review; Undo covers only that batch's
run; snapshot tests for the six mockup states at default and .xxxLarge (quick snapshots).

## Effort
**M, about 5% of weekly usage** (about 3% per M, plus ~1% for the share sheet and ~1% for batch/inbox and snapshot
tests). Largest parts: paged review sheet with the statement and document screens (reuse of the engines keeps it
M rather than L). Dropping the share sheet takes it to about 4%. Done in one stop at a clean point after the
Accounts entry works.
