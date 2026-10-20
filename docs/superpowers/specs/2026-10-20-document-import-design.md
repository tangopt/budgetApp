# Import documents — one smart import for the whole app

Status: design for approval (2026-10-20).

## Intent and why

Today every kind of document has its own way in: Dashboard ▸ Import CSV… / Import PDF… (UK bank statements), Tenancies ▸ Import receipts… (Portal das Finanças export), receipt "Add PDF…", Recharges ▸ Utility invoices…, Documents ▸ Add documents… / source-folder scans, Tax year ▸ Income ▸ Import P60, P45 or P11D…. And some inputs have **no** way in at all: BBVA "EXTRATO GLOBAL" statements (current account + mortgage + fund in one PDF) have only been imported by one-off command-line tools run by the developer.

The user wants **one** import function for **everything the app uses** — not just tax or the tenancy — that is as smart as possible: you hand it files, it works out what each one is, files it in the evidence library under its canonical name, links it to the right records and transactions, and refuses duplicates. Then preparing a tax year (or keeping the budget current) never depends on someone running tools.

## What the user decided

- **Scope:** every document and statement the app can use, for the whole app (banks, budget, accounts, property, recharges, tax, evidence).
- **How files arrive:** only when the user hands them over (a single file, several, or a folder; drag-and-drop or a file picker). Watching folders (e.g. Downloads) is **backlog**.
- **Originals:** left where they are; the app keeps its own copy in its evidence library. Tidying the user's folders into a structure is **backlog** (the folder structure can change).
- **Review before anything is saved:** a summary and preview of what was identified, with outliers that need manual handling settled before one confirm applies everything.
- **Review layout: option A** (mockup in `.superpowers/brainstorm/…/import-review.html`):
  - **Needs you** at the top — anything not fully confident, each with the reason;
  - **Ready**, grouped by kind with a one-line summary per group (e.g. "3 BBVA statements Jan–Mar 2026 → 142 transactions", "9 utility invoices → linked to their debits"), expandable per document;
  - **Duplicates skipped**, each with what it duplicates;
  - a **preview** panel beside the list for the selected document: the file, what it was recognised as and why, the figures read, where it will be filed (canonical name), and what it will link to;
  - **Confirm** is disabled while anything is in Needs you; it applies everything in one go.
- **Learning:** when the user corrects a document (its type, issuer, a figure, its link, its category), the app remembers and applies it next time ("as smart as possible"). The preview shows which learnt rule was used.
- **Statements:** a bank statement only **adds** its transactions (with balance checks and overlap handling as today); categorising happens afterwards in the existing **Uncategorized** screen, not in this review.
- **Replace the existing import flows:** every current import button becomes a **shortcut into this one function**, all consistent in look and behaviour across the app; a shortcut may only pre-set the expected type or target (e.g. Tenancies ▸ Import receipts… opens it expecting the portal export for that tenancy).
- **On-device AI:** yes — Apple's on-device model (macOS 26 Foundation Models) may be used to read and classify documents the built-in recognisers don't know. Nothing leaves the Mac.

## Goals

1. One entry point, consistent everywhere; existing import screens/sheets retired in favour of shortcuts into it.
2. Automatic detection of document type for every known kind (see "Document kinds"), with a stated reason.
3. Archival into the evidence library (content-addressed copy, canonical name, metadata, persons, period, amounts).
4. Linkage to the right records: transactions (the debit/credit it evidences), rent receipts, utility invoices / recharge statements, insurance & condomínio itemised receipts, tax-year records (employment, P11D benefits, HMRC payments, foreign tax), property/tenancy (contracts), mortgage terms/notices.
5. Duplicate detection at three levels: same file (hash), same document in a different file (invoice number, ATCUD, receipt number, payment reference, or issuer + date + amount), and same transactions (statement overlaps add only what's missing, balances checked).
6. Learning from corrections.
7. Bank statements of every supported bank, including BBVA EXTRATO GLOBAL (current account, mortgage instalments split into interest/capital, fund movements, balances chained), imported through this function.

## Non-goals

- Categorising imported transactions inside the review (that's the Uncategorized screen).
- Watching folders / automatic background import (backlog).
- Moving, renaming or tidying the user's original files (backlog).
- Sending anything off the Mac (no cloud OCR/AI).
- Filing tax returns.

## Anti-goals (would make it a failure even if it "works")

- **Filing something wrong silently.** Every placement and link must have a visible reason; anything below full confidence goes to Needs you, never to Ready.
- **Creating duplicates** — of files, documents, transactions or links.
- Changing a **filed or paid tax year**'s figures (existing guard: filed SA returns 2020/21–2024/25 must keep reproducing exactly; an import that would move one must stop and explain).
- Writing anything before the user confirms.

## Document kinds (initial set; the classifier must be extensible)

Banks & accounts: BBVA EXTRATO GLOBAL PDF; BBVA received-transfer advices ("TRANSFERÊNCIA RECEBIDA"); UK bank CSV and PDF statements (existing import profiles: Lloyds, Santander, …); balance confirmations.
Property & tenancy: Portal das Finanças receipts export (ListaRecibos .xlsx); individual rent receipt PDFs; tenancy contracts; utility invoices and credit notes (EDP, SIMAR, Lisboagás/CUR and future providers); condomínio receipts/statements (itemised quotas and extras); insurance receipts/policies; IMI notices and payment proofs; mortgage notices / instalment receipts / interest statements; deeds and certificates.
Tax: P60, P45, P11D; HMRC payment proofs and SA302/statements; Portuguese IRS declarations, liquidação notes and payment notices (Pagamentos ao Estado); accountant invoices (PT and UK); filed-return approval packs (archive only).
Other: anything else → archived with a user-chosen kind (and learnt).

## How detection should work (decided at the level of behaviour; mechanics left to the builder)

- Text from the document's text layer, else on-device OCR (Vision), else the on-device model for structure.
- Built-in recognisers first (existing ones: DocumentClassifier, BBVA glyph decoding, PayrollFormReader, UtilityInvoiceRules incl. provider presets, rent-receipt PDF reader, RentCreditEvidence advice reader, RentReceiptImport, CSV profiles), then learnt rules, then the on-device model for unknowns; the model's answer is never "Ready" on its own — it proposes, and the item stays in Needs you until the user confirms (and that confirmation becomes a learnt rule).
- Confidence is explicit per item (recognised type, each figure, each link). Figures read by OCR, single-candidate links matched on amount only, and multiple candidates are always Needs you.

## Applying a batch

- One confirm applies the whole batch in a single transaction, after a timestamped backup when the change is large (statements), using the existing guarded write paths (evidence library add, rent matching, recharge matching, utility intake, payroll import, statement import with balance checks, filed-year guard).
- Each confirmed import is recorded as a **batch** the user can open later (what was added, filed, linked, skipped) and **undo** (removes what the batch added and its links; never deletes documents or transactions that existed before). *My call:* undo is in scope for v1 because it directly protects against the "filed wrong silently" anti-goal.
- After a statement import, the follow-on steps the app already does run automatically: rent receipt matching (incl. date fallback), recharge payment matching, transfer linking, evidence links from advices.

## Calls made after the builder check (my calls — the user can overrule)

1. **Undo reverts everything the batch did, or refuses.** Every write a batch makes (rows added, fields changed on existing records — employment figures, receipt/recharge matches, transfer links, evidence links — and documents filed) is recorded in a per-batch change log with before/after values. Undo puts all of it back. If anything the batch touched has been changed since (a transaction categorised or split, a link edited, a later batch building on it), undo refuses and lists what changed; no cascading. The existing `importBatch` table is extended (new migration) to hold this.
2. **Filed or paid tax years.** An item whose effect would change any figure on a filed return is held in Needs you with the before/after figures and **cannot be confirmed**; the rest of the batch can still be confirmed. Figures that are information only (not on the return, e.g. the not-deductible line) may change and are listed in the item's preview. There is no in-app "accept a change to a filed figure" — consistent with the user's rule that filed returns cannot change. (Older statements that need filed-year set-up first are handled by setting the year up, then importing.)
3. **Statement decisions from today's review move into Needs you, per statement:**
   - a failed balance check is a Needs-you item; the user may import anyway only by giving a reason (recorded with the batch), as today's force option;
   - possible duplicate transactions appear as row-level Needs-you items under their statement (keep / skip each);
   - unparsed lines are listed under the statement as a Needs-you item;
   - saved category rules keep applying at import as today (auto-categorised rows still land as they do now; everything else is left for the Uncategorized screen);
   - a statement from a bank/layout with no saved profile becomes a Needs-you item that opens the existing CSV/PDF mapping step inside the review; once saved, the profile is reused next time.
4. **A corrected figure** fixes that document; the user can tick "remember for this issuer", which stores a label/position rule for that issuer's layout (like the provider reading rules already used for utility invoices). Fixed values are not learnt.
5. **Source-folder scan** becomes a shortcut that sends the folder's new or changed files into the importer; the folder's new/changed/missing state is kept.
6. **Account for a statement** that can't be detected (e.g. UK CSVs without an account number) is a Needs-you item to choose the account; the choice is learnt for files like it.

## Constraints

- macOS 26 SwiftUI app + BudgetCore Swift package (GRDB). All detection, matching and planning logic in **BudgetCore** (future iOS/iPadOS clients); the App only presents.
- Migrations appended last; never edit applied migrations.
- Follow the design system (docs/superpowers/specs/2026-10-18-ui-polish.md §1 and §6): Panel, DataTable, StatusPill, InlineBanner, MoneyText, DateText, figureText (no figure ever wraps), side panels docked beside tables, theme tokens; fits the 1100×700 minimum window.
- Personal data never in commits (tests synthetic only).
- The real database is never written by development agents; verification uses the demo database and the snapshot harness (`scripts/render-snapshots.sh`), and data-heavy paths are dry-run on a copy.
- Performance: a batch of ~50 PDFs including OCR should be identified within a reasonable time with visible progress; the review must stay responsive (lessons from the receipt-panel lag: no per-render recomputation, background work off the main actor).

## Left to the builder

- How to structure the recogniser pipeline, the rules store, confidence scoring and the on-device model prompts/schemas.
- Exact canonical-name formats per kind (existing evidence library conventions apply).
- How statement imports of different banks plug in (the BBVA EXTRATO GLOBAL reader from the 2022 import tool should become an in-app importer).
- The order in which existing import screens are retired and replaced by shortcuts.
- How to phase the work into plans (likely: core pipeline + review screen + the kinds that already have readers; then BBVA statements in-app; then learning + on-device model; then shortcuts everywhere and retiring old flows).

## Backlog (explicitly not now)

- Watching folders (Downloads, registered source folders) and offering imports.
- Tidying originals into the user's folder structure.
