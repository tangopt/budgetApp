# Phase 1 — Evidence Library, Links, Source Folders, Missing Evidence — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development.

**Spec:** `docs/superpowers/specs/2026-10-16-property-and-uk-tax-design.md` (§0, §2, §3, §7) — read it first.

## Global Constraints
- Tests: `swift test --scratch-path <scratchpad>/build-ev`. App: `xcodegen generate && xcodebuild -project Budget.xcodeproj -scheme Budget -destination 'platform=macOS' -derivedDataPath <scratchpad>/dd-ev.noindex build` and a Release build; then `lsregister -u` both built apps. Never tests and builds at once; no warnings.
- Migrations appended last. TDD for BudgetCore; all logic in BudgetCore (future iOS). Theme tokens for colours; SheetScaffold for sheets.
- Evidence files are personal: never commit real documents or their contents; tests use synthetic PDFs generated in tests.
- Never write `~/Library/Application Support/Budget` from tests or tools without the controller's go; never launch the app; never drive the screen; never push. Stage only App/Sources/Tests/project.yml/Package.swift; trailer `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

### Task 1: Evidence model and library (BudgetCore)
Tables (migration): `document` (sha256 unique, storedRelativePath, originalFileName, canonicalName, kind, docDate, periodStart, periodEnd, amountMinorUnits, currency, persons, textStatus [text/glyph/image/none], sourceFolderId, sourceRelativePath, sourceModifiedAt, addedAt, note), `documentLink` (documentId, entityType [transaction, account, category, property, taxYear, person, other], entityId, role, createdAt; unique per triple), `sourceFolder` (path, bookmark blob, name, lastScanAt). `EvidenceLibrary` API: root URL (Application Support/Budget/Evidence; injectable for tests), `add(fileURL, metadata) -> Document` (hash, copy into `<sha[0..2]>/<sha>.<ext>`, dedupe by hash), `link/unlink`, `documents(for:)`, `entities(for:)`, `remove` (refuse when linked unless forced), canonical naming helper `YYYYMMDD - <Area> - <Type> - <Detail>[ - period][ - amount]`. Commit "Evidence library: documents, links, source folders".

### Task 2: Text extraction, classification, matching (BudgetCore)
PDF text via PDFKit; port the BBVA glyph-name decoding (`/UNIC00xx`, `/LExxxxxx` → characters) used in the scratch scripts; detect image-only; extract dates and amounts (PT/UK formats); classify kind with rules (mortgage notice, insurance receipt, IMI notice/payment, condomínio receipt, rent receipt, accountant invoice, utility invoice, P60, P11D, PT IRS declaração/liquidação/nota/pagamento, bank transfer proof, other). `EvidenceMatcher.suggestions(document, transactions)` → ranked candidate transactions (amount equality incl. currency, date window by kind, account/category hints). Tests with synthetic PDFs (incl. a glyph-obfuscated one). Commit "Evidence: text extraction, classification and transaction matching".

### Task 3: Source folders and scanning (BudgetCore + App)
Register folders (security-scoped bookmarks), scan → new / changed / missing / already-in-library (by hash), propose classification + transaction links for review; nothing in the user's folders is modified. App: Settings ▸ Evidence sources (add/remove folder, scan now, last scan). Commit "Evidence: source folders and scanning".

### Task 4: Documents UI and links on transactions (App)
Sidebar "Documents": library list (search, kind/year/account filters, unlinked filter), detail with PDF/image preview (PDFKit/QuickLook), metadata edit, links list; "Add documents…" and drag & drop; scan review sheet (accept/reject suggested links in bulk). Transactions: side panels, Search results and Edit transaction show a paperclip with count and a "Documents" section (open, unlink, "Link document…" picker with suggestions, drop a file to add+link). Commit "Documents screen; link documents to transactions".

### Task 5: Missing-evidence machinery (BudgetCore + App)
`EvidenceRequirement` rules stored as data (e.g. "each transaction in category X needs a document of kind Y"; "each period P needs one document of kind Y for entity E"; "not available" waivers with reason). `MissingEvidence.items(for period/taxYear, …)` → items with what/expected date/amount/period/usual source + target entity. Phase-1 default rules: every transaction in Lisbon expense categories, Transfer: BBVA mortgage instalments (notice), PT tax payments, PT accountant, Legal fees needs a linked document. App: "Missing evidence" view (tax-year/period picker, grouped by source, % done, drop target per item, mark not available, export Markdown). Commit "Missing evidence checklist".

### Task 6: Initial evidence import (data step, controller-gated)
One-off tool `ImportExistingEvidence <db> --library <dir> [--dry-run]` using the move maps in `~/Documents/Personal/Documentos/Tax/_app-import/` and the scanners: register source folders (Lisboa, Tax, Downloads/IRS UK), add documents relevant to linked records (BBVA 2023-01…2026-09 transactions: mortgage notices, insurance, IMI, condomínio, accountant, legal, PT IRS docs; rent receipts later in phase 2), link with high-confidence matches, leave the rest as suggestions. Dry run on a copy (library to a scratch dir) → report counts/links/unmatched; real run only after backup + user "go".

### Task 7: Final review, merge, install (controller)
