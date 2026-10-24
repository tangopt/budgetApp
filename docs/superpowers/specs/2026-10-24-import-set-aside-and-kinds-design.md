# Import centre: files set aside, new document kinds, several documents per payment

Status: requirements approved by the user 2026-10-24; design decisions below are marked **(user)** — taken
from the approved requirements — or **(controller)** — taken while writing this spec from the code, which
the user can overrule. Builds on `2026-10-20-document-import-design.md` (the import centre) and keeps all
of its rules (review before anything is saved, one Confirm, undo, filed-year guard, learning).

## 1. Files left out of an import

Today a file that isn't imported — left out in the review, or every file of a review that is discarded —
is simply forgotten: the run records `leftOut` with its name and hash only (`importRunFile`), and the user
has to find the original again.

- **Two actions, per file or all at once (user):** *Keep for later* and *Copy to a folder…*.
- **When they are offered (controller):** a *Set aside* sheet opens (a) after a Confirm that left files
  out and (b) from Discard ("Set files aside…" beside "Discard"). It lists each candidate with why it was
  left out ("Left out by you", "Not recognised", "Possibly a duplicate of …"), one *Keep for later* and one
  *Copy to a folder…* per row, *Keep all for later* / *Copy all to a folder…* and *Done*. Each button acts
  at once (it is the save); *Done* lets the rest go.
- **Candidates (controller):** top-level items only (never a statement's rows) that are not imported,
  except a file identical (same hash) to a library document — Mango already holds those bytes.
- **Keep for later (user):** Mango copies the file into its own waiting folder (`Application Support/Budget/
  Waiting/<sha256>/<original name>`), so the original may move or go. The waiting list is a table
  (`importWaitingFile`) with the name, hash, size, the text already read (no second OCR), why it was set
  aside, what it was recognised as, and when. Shown in the import centre as a *Waiting for later* panel
  across restarts, each file with *Import*, *Copy to a folder…* and *Discard…* (confirmed; removes Mango's
  copy only — the user's original is never touched).
- **Suggested again (user):** when a new kind or a learnt rule appears, Mango re-reads waiting files and
  suggests the ones it now recognises ("Now recognised as Repair bill"), with *Import suggested (N)*.
  *(controller)* A signature of the recognisers — the built-in classifier's rules version, the custom kinds
  and the enabled `documentKind`/`issuer` learnt rules — is stored per waiting file; a file is re-read
  (from its stored text and name, off the main actor) whenever the signature differs, on opening the
  Imports screen, after a Confirm and after a kind is created, renamed or merged.
- **Importing waiting files (controller):** they go through the normal import (entry point "Waiting
  list"); on Confirm, a waiting file that the run filed, linked or recorded is marked imported by that run
  and leaves the list; if the run is undone it comes back. Marked rows and their copies are purged 30 days
  after their run (when the run still stands).
- **Copy to a folder… (user):** copies to a chosen folder; originals untouched; a name already there gets
  " 2", " 3"… (never overwrites); the original is copied when it still exists, else Mango's waiting copy.
- **Not synced (controller):** the waiting list is a Mac import-centre concern and its files are not in the
  synced library, so `importWaitingFile` is a local-only table (like `sourceFile`).

## 2. New document kinds while importing (custom kinds)

- **(user)** The review's kind chooser gets *New kind…*: a name and an area (Property, Tax, Bank, Other).
  The kind is usable at once — for that item and any other item of the same review.
- **Stored and synced (user):** table `customDocumentKind` (`name` unique ignoring case, `area`,
  `createdAt`), synced, unique name = the same kind on every device (identity). Built-in kinds are
  unchanged and stay the Swift enum `DocumentKind`.
- **How a document holds one (controller):** `document.kind` stays `other` and a new
  `document.customKindId` (foreign key, synced) names the custom kind. Code talks about kinds through
  `DocumentKindRef` (`.builtIn(DocumentKind)` / `.custom(Int64)`) and reads names and areas from a
  `DocumentKindCatalog` loaded once.
- **Saved at Confirm (controller):** a kind created in the review is part of the plan (*pending*) until
  Confirm, which inserts it first in the same transaction (and undo removes it with the run). Discarding
  the review forgets it. This keeps "nothing is written before Confirm".
- **Usable everywhere a kind is (user):** evidence rules (`evidenceRequirement.customKindIds`, a JSON list
  of ids beside `kinds`; both empty = any document), the Documents screen's kind filter, the document
  inspector's kind picker, missing-evidence matching and canonical names (`<date> - <Area> - <Name> - …`,
  area Property / Tax / Bank / Other).
- **Rename and merge (user):** a *Kinds…* sheet on the Documents screen lists custom kinds with their
  document counts. Rename (name, area) and *Merge into…* (another custom kind or a built-in) are staged and
  applied together on **Save** (one write). *(controller)* Renaming or merging also rewrites the
  `<Area> - <Name>` part of those documents' canonical names, re-points learnt rules (and their labels) and
  evidence rules; a merged kind is then deleted. Built-ins can't be renamed or merged.
- **Learning (user):** choosing a custom kind for a file with a recognisable sender (`IssuerKey`) learns a
  `documentKind` rule exactly like a built-in choice (`DocumentKindAction` gains an optional
  `customKindId`); next time the file is recognised as that kind, needs-review like any learnt kind until
  Confirm. A rule whose custom kind is gone is ignored.
- **Duplicates (controller):** a custom kind is a kind like any other for the duplicate rules of §4.

## 3. New built-in kinds (tax)

- **Repair bill (`repairInvoice`, area Property) (user):** an invoice or receipt for repairs or maintenance
  of the property ("fatura"/"fatura-recibo" of a tradesperson or shop). Text rule: an invoice word
  (FATURA, FACTURA, FATURA-RECIBO, RECIBO, INVOICE) and a repair word (REPARACAO, MANUTENCAO, CANALIZ…,
  ELETRICIST…/ELECTRICIST…, PINTURA, OBRAS, MAO DE OBRA, SUBSTITUICAO, DESENTUPIMENTO, ASSISTENCIA TECNICA,
  CALDEIRA, ESQUENTADOR, REPAIR, MAINTENANCE, PLUMB…), never "MANUTENCAO DE CONTA" (a bank fee); placed
  after the issuer rules (condomínio, insurance, accountant, legal, utilities keep their kinds). File-name
  rule for REPARACAO / REPAIR / OBRAS / MANUTENCAO / CANALIZ.
- **Stamp duty (`stampDuty`, area Tax PT) (user):** the Portuguese Imposto do Selo — note of payment
  (documento/nota de cobrança, liquidação), the tax authority's payment receipt, or the bank's "Pagamentos
  ao Estado" advice for it. Text rule: "IMPOSTO DO SELO" together with a charge or state-payment wording,
  and never a loan letter (EMPRESTIMO, PRESTACAO, CREDITO HABITACAO — mortgage notices list stamp duty on
  interest) or a bank statement; placed with the Portuguese tax rules, before IMI and IRS. File-name rule
  for SELO / STAMP DUTY.
- Detection is tested with **synthetic fixtures** only, including the negatives above (a mortgage notice and
  a bank advice that mention stamp duty keep their kinds; a condomínio receipt for works stays condomínio).
- **Matching (controller):** repair bills: debits from 15 days before to 45 after, category hints repair /
  manutenção / obras; stamp duty: debits from the day before to 60 after, hints PAGEST / ESTADO / SELO.
- **Evidence rules (user):** the default rule for a *Repairs* category accepts Repair bill (and Other, so
  documents filed before this kind existed still count) **(controller)**; a category named stamp duty /
  selo asks for Stamp duty, usual source Portal das Finanças. The user's existing "Lisbon: Repairs" rule
  (today: any document) and already-filed `other` documents that now read as repair bills or stamp duty are
  changed only by a one-off tool, dry-run by default, run on the real database with the user's go
  (precedent: `ReclassifyMortgageReceipts`).
- **Tax (controller, see open question 2):** kinds never change tax figures. A category named
  "Imposto do Selo" is today suggested as *Foreign tax* (it matches "imposto"); the suggestion is made
  explicit for stamp duty. Filed SA years 2020/21–2024/25 must reproduce exactly; any change that moves one
  stops.
- The classifier's rules version is bumped, so waiting files are re-read (§1).

## 4. Several documents on one payment, one document on several payments

### 4a. What the "same document" alert does today and why it confuses

The import's duplicate pass (`ImportDuplicates.annotate`) raises, for a document:

1. **"Same document as <name>"** — the item is skipped as a duplicate — when it shares a *strong identity*
   with a library document or an earlier file: any ATCUD printed anywhere in its text, a provider's invoice
   number, a contract's receipt number, or a payroll form key, and the money figures both hold agree. The
   kinds are not compared, so a receipt that quotes its invoice's ATCUD is skipped as "the same document".
2. **"Possibly the same document as <name>"** (Needs you) when it shares a *weak key*: issuer + day +
   amount (**kind not compared**), or kind + day + amount when one side names no issuer, or a payment
   reference with the same kind, day and amount. A notice, a receipt and an invoice of one payment from the
   same issuer on the same day for the same amount — exactly the documents of one transaction — trip it.
3. **"N documents in this import claim the same transaction"** and **"That transaction already has <a kind>
   (<name>)"** whenever two documents of the same role (`claimRole`) are linked to one transaction — e.g.
   an invoice and a receipt both unrecognised (`other`): "That transaction already has an other (…)".

Why it confuses: it says "same document" while comparing issuer, day and amount (or one printed code),
never says what it compared or which kinds, and treats the normal set of documents of one payment
(notice + receipt + invoice) as a suspected copy.

### 4b. The rule from now on (user)

- An alert fires only for a **genuinely identical file** (same hash) or a **true duplicate: same kind and
  same period**. "Same kind" is the same built-in or custom kind, by its role (the bank's own advice filed
  under another kind still counts as an advice — existing `claimRole`). "Same period" is the same day, or
  overlapping periods when both state one.
- **Wording names what it compares (controller):**
  - "Identical file: already in the library as <name>" / "Identical file: same as <file> in this import";
  - "Duplicate of <name>: the same <kind>, <ATCUD|invoice number|receipt number> <value>";
  - "Possibly a duplicate of <name>: also a <kind> from <issuer> dated <day> for <amount>" (issuer left
    out when unknown) — Needs you, keep or leave out;
  - on a transaction: "Possibly a duplicate: <name> is also a <kind> dated <day> on this transaction".
- Different kinds never alert: a shared code or key between them is a note only ("Refers to <name>:
  same ATCUD …").
- **Two automatic links of one kind and different periods on one transaction (controller):** not a
  duplicate; the links become *Check the link* questions ("<a> and <b> — both <kind>, <period a> and
  <period b> — were matched to the same transaction"). Links chosen by the user never raise either.
- Two files attaching to the same recorded utility invoice keep being one copy of the other, worded
  "Duplicate of <file>: the same utility invoice, invoice number <n>".

### 4c. One document on several transactions

The data model allows it (`documentLink` is many-to-many), the review can link one document to several
transactions, the Documents inspector links one at a time and stays open, and missing evidence counts the
document for every transaction it is linked to. Gaps found and fixed:

- **No proposal for instalments (controller):** the matcher only proposes a transaction of the document's
  exact amount. New: two debits of the same merchant inside the kind's window whose amounts add up exactly
  to the document's amount are proposed together ("Paid in 2 instalments: €40.00 + €39.95"), always as a
  question in Needs you (*Keep both links* / *File without a link*), never certain on its own.
- **The second instalment can't find its invoice (controller):** Edit transaction ▸ Link document… lists
  only unlinked documents until you type, and the matcher scores on the exact amount. New: a document
  already linked to other debits whose amounts fall short of its amount is suggested for a debit of the
  remainder ("Pays the rest of <name>: €39.95 after €40.00 on 3 Mar"), in the Documents inspector, Link
  document… and missing evidence.
- A utility invoice still records its debit only when exactly one is linked (unchanged).

## Constraints (all user)

- No personal data in the repo: synthetic fixtures and demo data only.
- Filed SA years 2020/21–2024/25 must never change.
- Logic in BudgetCore (future iPhone/iPad clients); the App presents.
- UI fits the 1100×700 minimum window with no figure wrapping (design system: Panel, DataTable,
  StatusPill, figureText).
- Editors save only on Save (the Kinds sheet, the evidence rules sheet, the document inspector's details).
- Append-only migrations; new synced tables and columns are added to `SyncSchema` with a version bump and
  the new pinned hash (`SyncChangeTrackerTests`), local-only ones to `localOnlyTables`.

## Open questions for the user

1. **"Lisbon: Repairs" rule:** keep it accepting any document, or narrow it to *Repair bill + Other*
   (the controller's default for the one-off tool; a bank advice alone would then no longer satisfy it)?
2. **Stamp duty on the return:** which UK line should a stamp-duty category suggest — *Any other expense*
   (controller's default), *Legal fees*, or *Not deductible*? Saved category mappings and filed years are
   not touched either way.
3. **Waiting list on other devices:** local to this Mac (controller's default) or synced with its files?
