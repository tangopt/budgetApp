# Import documents 4 — Every import button becomes a shortcut — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Every existing way of bringing a file into the app — Dashboard Import CSV…/PDF…, Accounts' import menu, Tenancies ▸ Import receipts…, the receipt panel's Add/Replace PDF, Add contract…, Utility invoices…, Documents ▸ Add documents… and its drop zone, source-folder scans, Tax year ▸ Income ▸ Import P60, P45 or P11D…, and the record-level Add document… / drop zones — becomes one consistent shortcut into the importer that only pre-sets the expected type or target; the old sheets and the old Import screen are retired.

**Architecture:** `ImportShortcut` (BudgetCore) is the single catalogue of shortcuts: each case yields the `ImportIntent` (expected kind, property/person/account/tax year, link target with role and documents it replaces) and the entry-point name recorded on the run. The App gets two design-system pieces — `ImportShortcutButton` and `.importDropTarget(_:)` — that call the importer from plan 1 through the `documentImport` environment value, so every screen looks and behaves the same. Source-folder scans hand their new and changed files to the importer with their folder metadata; applying records the documents on the scan records and acknowledges changes. Then the old flows are deleted.

**Tech Stack:** Swift 5.10, BudgetCore + GRDB, SwiftUI (macOS 26), xcodegen, XCTest, snapshot harness.

**Spec:** `docs/superpowers/specs/2026-10-20-document-import-design.md` ("Replace the existing import flows", Goal 1, Call 5). Builds on plans 1 and 2 (`docs/superpowers/plans/2026-10-20-import-1-core-and-review.md`, `…-import-2-statements.md`): `ImportIntent` / `ImportIntent.Target`, `ImportPipeline`, `ImportApplier`, `DocumentImportAction` (environment + focused value), `ImportCenterModel.start/pickFiles`, `StatementIssue.remap`, the review's mapping step. Independent of plan 3.

## Global Constraints

- Everything in plan 1's Global Constraints applies (scratch suffix `-imp4`).
- A shortcut only pre-sets: expected type, property, person, account, tax year, or a link target (entity, role, documents it replaces). It never skips the review: nothing is written before Confirm import, even for a single file attached to a record.
- A pre-set link target is a certain link with the reason `"You added it from <entry point>"`; a pre-set type that the file contradicts is a `kindMismatch` Needs-you item (plan 1 Task 5).
- One look everywhere: shortcut buttons keep their screen's current title and placement (copy below) and use `ImportShortcutButton`; drop zones use `.importDropTarget` (accent outline while targeted, same as today).
- Entry-point names (exact, recorded on the run and shown in Import history): `"Dashboard ▸ Import CSV…"`, `"Dashboard ▸ Import PDF…"`, `"Accounts ▸ Import CSV…"`, `"Accounts ▸ Import PDF…"`, `"Accounts ▸ Edit column mapping…"`, `"Tenancies ▸ Import receipts…"`, `"Receipt ▸ Add PDF…"`, `"Receipt ▸ Replace PDF…"`, `"Tenancy ▸ Add contract…"`, `"Utility invoices…"`, `"Documents ▸ Add documents…"`, `"Documents ▸ Drop"`, `"Source folder ▸ <folder name>"`, `"Income ▸ Import P60, P45 or P11D…"`, `"Property ▸ Add document…"`, `"Manual item ▸ Add document…"`, `"Missing evidence ▸ Add"`, `"Transaction ▸ Add document"`, `"Link document ▸ Add file…"`.
- Kept (not imports): Settings ▸ Evidence sources ▸ Add Folder… (registers a folder), "Reset column mapping…", "Reset PDF layout…", Recharges ▸ provider rules "Test with a file…", exports (evidence pack, PDFs), the receipt panel's "View receipt PDF".
- Core functions the retired sheets used stay (tools and tests use them); only App code is deleted.

## Review Focus

1. **Replace PDF… on a receipt whose new PDF turns out to be a different receipt** — the old PDF stays linked; the item is Needs you (receipt mismatch), and Leave out changes nothing. Pinned in Task 2 (`testReplaceWithWrongReceiptKeepsOldLink`).
2. **A source-folder scan whose changed file is the same document as before (re-saved, new bytes)** — a Duplicate (document), and on Confirm the change is still acknowledged so the folder stops reporting it. Pinned in Task 3 (`testChangedFileThatIsSameDocumentIsAcknowledged`).
3. **Dropping a P60 on the Tenancies tab's receipt drop zone (wrong type for the shortcut)** — a `kindMismatch` Needs-you item ("Expected a Rent receipt, this looks like a P60"), never filed as a rent receipt. Pinned in Task 1 (`testShortcutKindContradictedByFileIsNeedsYou`).
4. **Starting a shortcut while another review is open** — the files join the open review, each keeping its own shortcut's intent (not the first one's). Pinned in Task 1 (`testAddingFilesKeepsEachIntent`).
5. **Import P60… pressed on a filed year** — the filed-year guard still blocks a changing P60 even though the shortcut pre-set that year. Pinned in Task 1 (`testPresetTaxYearDoesNotBypassFiledGuard`).

---

### Task 1: The shortcut catalogue (Core) and per-file intents

**Files:**
- Create: `Sources/BudgetCore/DocumentImport/ImportShortcut.swift`
- Modify: `Sources/BudgetCore/DocumentImport/ImportModel.swift` (`ImportItem.intent: ImportIntent`; `ImportIntent.remapStatement: Bool`)
- Modify: `Sources/BudgetCore/DocumentImport/ImportPipeline.swift`, `Readers/UKStatementReader.swift`
- Test: `Tests/BudgetCoreTests/ImportShortcutTests.swift`

**Interfaces:**
- Consumes: plan 1 `ImportIntent`, `ImportIntent.Target`, `ImportKind`, `ImportPipeline.plan(_:intent:progress:)`, `plan(adding:to:intent:progress:)`; plan 2 `StatementIssue.remap`.
- Produces:
  - `public enum ImportShortcut: Equatable, Sendable { case statement(accountId: Int64, format: ImportFormat, from: StatementOrigin); case editColumnMapping(accountId: Int64); case rentReceiptsExport(propertyId: Int64); case receiptPDF(receiptId: Int64, replacing: [Int64]); case tenancyContract(tenancyId: Int64); case utilityInvoices(propertyId: Int64); case documents(dropped: Bool); case sourceFolder(folderId: Int64, name: String); case payrollForms(personId: Int64?, taxYear: Int?); case attach(EvidenceEntity, role: String?, from: AttachOrigin); public var intent: ImportIntent; public var entryPoint: String; public var allowedContentTypes: [String] /* UTType identifiers for the open panel */; public var allowsMultiple: Bool }`
  - `public enum StatementOrigin: String, Sendable { case dashboard, accounts }`; `public enum AttachOrigin: String, Sendable { case property, manualItem, missingEvidence, transaction, linkPicker }`.
  - Intents (exact): statement → `expected: .bankStatementCSV`/`.bankStatementPDF`, `accountId`; editColumnMapping → `expected: .bankStatementCSV`, `accountId`, `remapStatement: true`; rentReceiptsExport → `expected: .rentReceiptsExport`, `propertyId`; receiptPDF → `expected: .rentReceiptPDF`, `target: (.rentReceipt(id), role "Receipt", replacing)`; tenancyContract → `expected: .evidence(.rentContract)`, `target: (.tenancy(id), role "Contract", [])`; utilityInvoices → `expected: .utilityInvoice`, `propertyId`; documents → no preset; sourceFolder → no preset (files carry folder metadata, Task 3); payrollForms → `expected: .payrollForm(.p60)` (any payroll form matches), `personId`, `taxYear`; attach → `target: (entity, role, [])`.
  - Pipeline: intents are per file — `ImportItem.intent` is set from the call that brought the file; `plan(adding:to:intent:)` keeps each item's own intent; readers read `item.intent`/the file's intent instead of a plan-wide one.
  - `UKStatementReader`: `remapStatement` → issue `statement(.remap(format:accountId:))` prefilled from the saved profile (resolution `.saveProfile`).

- [ ] **Step 1: Write the failing tests**

```swift
func testEveryShortcutHasItsEntryPointAndIntent() { /* table: each case → entryPoint string from Global Constraints and the intent fields above */ }
func testShortcutKindContradictedByFileIsNeedsYou() async throws {
    // .receiptPDF(receiptId:) shortcut with a synthetic P60 → issue .kindMismatch(expected: .rentReceiptPDF, found: .payrollForm(.p60)),
    // reason "Expected a Rent receipt, this looks like a P60"; no link to the receipt proposed
}
func testAddingFilesKeepsEachIntent() async throws { /* plan(receipt via .receiptPDF) + adding(invoice via .utilityInvoices) → each item.intent as given */ }
func testPresetTaxYearDoesNotBypassFiledGuard() async throws { /* .payrollForms(personId: a, taxYear: 2024) with a changing P60 on a filed year → .filedYear issue */ }
func testEditColumnMappingAsksToRemap() async throws { }
```

- [ ] **Step 2: Run** `swift test --scratch-path <scratch>/build-imp4 --filter ImportShortcutTests` — Expected: FAIL.
- [ ] **Step 3: Implement**.
- [ ] **Step 4: Run** — Expected: PASS; plan 1–2 suites still pass.
- [ ] **Step 5: Commit** `git commit -m "Import: shortcut catalogue and per-file intents"`

---

### Task 2: Attach targets — linking, replacing, roles

**Files:**
- Modify: `Sources/BudgetCore/DocumentImport/Readers/*.swift` (target link applied by every reader), `ImportApplier.swift`
- Test: `Tests/BudgetCoreTests/ImportAttachTargetTests.swift`

**Interfaces:**
- Consumes: Task 1; plan 1 `ProposedLink`, `ImportApplier` (`replacing` unlink step).
- Produces:
  - Every reader adds the intent target's link (certain, reason `"You added it from <entryPoint>"`, `madeByEffect: false`) unless the reader's own link to the same entity exists; for `.rentReceiptPDF` the receipt matcher must agree (contract and receipt number) — disagreement keeps plan 1's mismatch issue and no target link.
  - Applier: `replacing` documents are unlinked from the target only when the new document was linked to it in this run (never for a left-out or failed item).

- [ ] **Step 1: Write the failing tests**

```swift
func testAttachToTransactionLinksWithReason() async throws { }
func testReplacePDFUnlinksOldAndLinksNew() async throws { /* role "Receipt"; old document still in the library */ }
func testReplaceWithWrongReceiptKeepsOldLink() async throws { /* new PDF of another receipt → .needsYou; leave out + apply other items → old link intact */ }
func testTenancyContractGetsRoleContract() async throws { }
```

- [ ] **Step 2: Run** `--filter ImportAttachTargetTests` — Expected: FAIL.
- [ ] **Step 3: Implement**.
- [ ] **Step 4: Run** — Expected: PASS.
- [ ] **Step 5: Commit** `git commit -m "Import: attach targets with roles and replacing"`

---

### Task 3: Source-folder scans feed the importer

**Files:**
- Create: `Sources/BudgetCore/DocumentImport/SourceFolderImport.swift`
- Modify: `Sources/BudgetCore/Evidence/SourceFolderScanner.swift` (add `public static func acknowledgeChange(db: Database, folderId: Int64, relativePath: String) throws -> Bool`; the instance method calls it)
- Modify: `Sources/BudgetCore/DocumentImport/ImportPipeline.swift`, `ImportApplier.swift`
- Test: `Tests/BudgetCoreTests/SourceFolderImportTests.swift`

**Interfaces:**
- Consumes: `SourceFolderScanner.scan`, `ScanResult.new/changed`, `ScannedFile`, `withResolvedFolder` (security scope), plan 1 `ImportFile.sourceFolderId/sourceRelativePath/sourceModifiedAt`.
- Produces:
  - `public enum SourceFolderImport { public static func inputs(from result: SourceFolderScanner.ScanResult) -> [SourceFolderImport.Input] }` with `public struct Input: Equatable, Sendable { url: URL; folderId: Int64; relativePath: String; modifiedAt: Date; isChange: Bool }` — new and changed files only; missing/ignored/not-downloaded/unreadable are reported by the scan as today.
  - `ImportPipeline.plan(folder: SourceFolder, scanner: SourceFolderScanner, inputs: [SourceFolderImport.Input], progress:) async throws -> ImportPlan` — reads inside the folder's security scope; files carry their folder metadata (placement metadata gets `sourceFolderId`, `sourceRelativePath`, `sourceModifiedAt`).
  - Applier: for a file from a folder, sets `sourceFile.documentId` (filed or matched duplicate document) and, when `isChange`, `acknowledgeChange(db:folderId:relativePath:)` — also for duplicates and left-out changed files (the user has seen the change). Scan state (`lastScanAt`, new/changed/missing) is otherwise unchanged.

- [ ] **Step 1: Write the failing tests**

```swift
func testNewAndChangedFilesBecomeInputs() throws { }
func testFiledFileIsRecordedOnItsScanRecord() async throws { /* sourceFile.documentId == new document id; document.sourceFolderId == folder id */ }
func testChangedFileThatIsSameDocumentIsAcknowledged() async throws { /* changed bytes, same ATCUD → .duplicates; after apply, pendingChanges(inFolder:) is empty */ }
```

- [ ] **Step 2: Run** `--filter SourceFolderImportTests` — Expected: FAIL.
- [ ] **Step 3: Implement**.
- [ ] **Step 4: Run** — Expected: PASS.
- [ ] **Step 5: Commit** `git commit -m "Import: source-folder scans feed the importer"`

---

### Task 4: Design-system shortcut button and drop target

**Files:**
- Create: `App/DesignSystem/ImportShortcutButton.swift`
- Modify: `App/DocumentImport/ImportCenterModel.swift` (`pickFiles(for shortcut: ImportShortcut)`, `start(_ urls: [URL], shortcut: ImportShortcut)`), `App/DocumentImport/ImportCommands.swift` (environment entry)
- Modify: `App/Snapshots/ComponentGallery.swift` (gallery row)

**Interfaces:**
- Consumes: Task 1 `ImportShortcut`; plan 1 `DocumentImportAction` environment value.
- Produces:
  - `struct ImportShortcutButton: View { init(_ title: String, systemImage: String? = nil, shortcut: ImportShortcut, prominent: Bool = false) }` — opens the open panel with `shortcut.allowedContentTypes` / `allowsMultiple`, then `start`; the importer screen is shown (`onShow`).
  - `extension View { func importDropTarget(_ shortcut: ImportShortcut, isEnabled: Bool = true) -> some View }` — `.dropDestination(for: URL.self)` with the accent outline while targeted; returns true when any URL was taken.
  - Gallery: both pieces at rest and targeted.

- [ ] **Step 1: Build** — Expected: FAIL until implemented.
- [ ] **Step 2: Implement**.
- [ ] **Step 3: Build** (no warnings); `scripts/render-snapshots.sh <scratch>/snaps-imp4 --only gallery-controls --size 1100x700`.
- [ ] **Step 4: Commit** `git commit -m "Design system: import shortcut button and drop target"`

---

### Task 5: Statements — Dashboard and Accounts become shortcuts; old Import screen retired

**Files:**
- Modify: `App/Dashboard/FreshnessImportCard.swift` (Import CSV…/Import PDF… → `ImportShortcutButton` with `.statement(accountId:format:from: .dashboard)`; keep the account picker and `NonGBPImportCaption`)
- Modify: `App/Accounts/AccountsView.swift` (import menu CSV…/PDF… → `.statement(…, from: .accounts)`; "Edit column mapping…" → `.editColumnMapping(accountId:)`; keep Reset column mapping…/Reset PDF layout… using `ImportProfileStore.delete`)
- Modify: `App/ContentView.swift` (remove `AppScreen.importReview`, the unsaved-import alert and its state; Import progress lives on Imports)
- Delete: `App/Import/ImportFlowHost.swift`, `App/Import/ImportView.swift`, `App/Import/ImportViewModel.swift`, `App/Import/ReviewView.swift`
- Modify: `App/Snapshots/SnapshotCatalog.swift` (remove `import-review`; add `imports-review_dashboard_csv`: the Dashboard shortcut's intent with the demo CSV sample)

**Interfaces:**
- Consumes: Tasks 1, 4; plan 2 statement items and mapping step.
- Produces: no new types. The Dashboard freshness card's "Import in progress…" reads `ImportCenterModel.phase` instead of `ImportViewModel`.

- [ ] **Step 1: Build** after the edits — Expected: BUILD SUCCEEDED, no warnings, no reference left to the deleted types (`grep -rn "ImportViewModel\|ImportFlowHost\|ReviewView\|importReview" App` → nothing).
- [ ] **Step 2: Run** the full `swift test` (Core unaffected) — PASS.
- [ ] **Step 3: Snapshots** `--only dashboard-main,accounts-main,accounts-euro_current,imports-review_dashboard_csv --size 1100x700` — no wrap-probe findings.
- [ ] **Step 4: Commit** `git commit -m "Statements: Dashboard and Accounts import through the importer; old Import screen retired"`

---

### Task 6: Property — receipts, contracts, utility invoices

**Files:**
- Modify: `App/Property/PropertyTenanciesTab.swift` (Import receipts… → `.rentReceiptsExport(propertyId:)`; Add contract… → `.tenancyContract(tenancyId:)`; Utility invoices… → `.utilityInvoices(propertyId:)`; remove `.fileImporter` and the two sheets)
- Modify: `App/Property/RentReceiptPanel.swift` (Add the receipt PDF… / Add another PDF… → `.receiptPDF(receiptId:replacing: [])`; Replace PDF… → `.receiptPDF(receiptId:replacing: <current ids>)`; drop zone on the PDF section → `.importDropTarget(.receiptPDF(…))`)
- Modify: `App/Property/PropertyRechargesTab.swift` (both Utility invoices… → `.utilityInvoices(propertyId:)`)
- Modify: `App/Property/PropertyProfileTab.swift` (Add document… → `.attach(.property(id), role: nil, from: .property)`)
- Modify: `App/Property/PropertyViewModel.swift` (remove `addDocuments(_:to:role:replacing:)` once unused)
- Delete: `App/Property/UtilityInvoiceIntakeSheet.swift`; `ImportReceiptsSheet` from `App/Property/PropertySheets.swift`
- Modify: `App/Snapshots/SnapshotCatalog.swift` (remove `import_receipts`, `import_receipts_preview`, `invoice_intake`, `invoice_intake_lines`, `invoice_intake_problems`; add `imports-review_receipts` (Tenancies shortcut with the demo receipt PDF) and `imports-review_invoices` (Utility invoices shortcut with the demo invoice samples))

**Interfaces:**
- Consumes: Tasks 1, 2, 4.
- Produces: nothing new; copy unchanged on every button.

- [ ] **Step 1: Build** — BUILD SUCCEEDED, no warnings; `grep -rn "UtilityInvoiceIntakeSheet\|ImportReceiptsSheet\|fileImporter" App/Property` → only `RechargeSheets.swift` (provider rules test, kept).
- [ ] **Step 2: Snapshots** `--only property-tenancies,property-recharges,property-profile,imports-review_receipts,imports-review_invoices --size 1100x700` — no wrap-probe findings.
- [ ] **Step 3: Commit** `git commit -m "Property: receipts, contracts and utility invoices through the importer"`

---

### Task 7: Documents, source folders, missing evidence, links and record attachments

**Files:**
- Modify: `App/Documents/DocumentsView.swift` (Add documents… ×3 → `.documents(dropped: false)`; drop → `.importDropTarget(.documents(dropped: true))`; folder scan review → importer)
- Modify: `App/Settings/EvidenceSourcesSettings.swift` (Scan Now → scan, then `ImportCenterModel.start(folder:inputs:)` with `.sourceFolder(folderId:name:)`; keep Add Folder… and the per-folder new/changed/missing summary)
- Delete: `App/Documents/FolderReviewSheet.swift`
- Modify: `App/Documents/MissingEvidenceView.swift` (per-item add and drop → `.attach(<item's entity>, role: <item's role>, from: .missingEvidence)`)
- Modify: `App/Documents/LinkPickers.swift` (Add file… → `.attach(<picker's entity>, role: nil, from: .linkPicker)`)
- Modify: `App/Documents/TransactionDocumentsSection.swift` (drop → `.attach(.transaction(id), role: nil, from: .transaction)`)
- Modify: `App/Tax/TaxManualItemsTab.swift` (Add document… and drop → `.attach(EvidenceEntity(type: .taxManualItem, id:), role: nil, from: .manualItem)`)
- Modify: the view models whose `addFiles`/`add(_:to:)` become unused (`DocumentsViewModel`, `MissingEvidenceViewModel`, link picker model, `TransactionDocumentsModel`, manual item documents model) — remove those methods.
- Modify: `App/Snapshots/SnapshotCatalog.swift` (remove `folder_review`; add `imports-review_folder` using a temporary demo source folder with the samples)

**Interfaces:**
- Consumes: Tasks 1–4; plan 1 `ImportCenterModel`.
- Produces: `ImportCenterModel.start(folder: SourceFolder, inputs: [SourceFolderImport.Input])`.

- [ ] **Step 1: Build** — BUILD SUCCEEDED, no warnings; `grep -rn "fileImporter\|dropDestination(for: URL" App` → only `EvidenceSourcesSettings.swift` (folder chooser), `RechargeSheets.swift` (provider test) and `ImportShortcutButton.swift` / `ContentView.swift` (the importer's own).
- [ ] **Step 2: Snapshots** `--only documents-main,documents-selected,missing_evidence-main,imports-review_folder,settings-main --size 1100x700` — no wrap-probe findings.
- [ ] **Step 3: Commit** `git commit -m "Documents, folders, missing evidence and attachments through the importer"`

---

### Task 8: Tax — Income ▸ Import P60, P45 or P11D…

**Files:**
- Modify: `App/Tax/TaxIncomeTab.swift` (button → `.payrollForms(personId: <page person>, taxYear: <page year>)`; remove `.fileImporter`, `PayrollFormConfirmSheet` and its state)
- Modify: `App/Tax/TaxYearsViewModel.swift` (remove the payroll-import methods once unused)
- Modify: `App/Snapshots/SnapshotCatalog.swift` (remove `payroll_confirm`, `payroll_confirm_p11d`; add `imports-review_p60` with the Income shortcut and the demo P60 sample — the filed-year item selected)

**Interfaces:**
- Consumes: Tasks 1, 4.
- Produces: nothing new.

- [ ] **Step 1: Build** — no warnings; `grep -rn "PayrollFormConfirmSheet" App` → nothing.
- [ ] **Step 2: Snapshots** `--only tax_years-income,imports-review_p60 --size 1100x700` (use the tax-income route name in `SnapshotCatalog.taxTabs`) — no wrap-probe findings.
- [ ] **Step 3: Commit** `git commit -m "Tax: P60, P45 and P11D through the importer"`

---

### Task 9: Final verification, merge and install (controller)

- [ ] `grep -rn "fileImporter\|NSOpenPanel\|dropDestination(for: URL" App` — every remaining hit is in the Kept list (Global Constraints) or the importer itself.
- [ ] Full test suite; Debug and Release builds without warnings; `lsregister -u`.
- [ ] Full snapshot run at 1100×700 and 1440×900 — no wrap-probe findings; every `imports-review_*` route shows its shortcut's entry point in the review header.
- [ ] Whole-branch review against "Replace the existing import flows" and Call 5.
- [ ] Merge; `xcodegen generate`; `scripts/install-app.sh`; do not push.

## Self-review

- Spec coverage — every button the spec lists, plus the others found: Dashboard Import CSV/PDF (5), Accounts import menu and Edit column mapping (5), Tenancies Import receipts and Add contract (6), receipt Add/Replace PDF (6), Recharges and Tenancies Utility invoices (6), Property Add document (6), Documents Add documents + drop (7), source-folder scan with new/changed/missing state kept (3, 7), Missing evidence add/drop, Link document Add file, transaction drop, manual-item Add document/drop (7), Tax Income Import P60/P45/P11D (8). Old sheets and the old Import screen retired (5–8). Consistent look (4).
- Types: `ImportShortcut`, `ImportIntent.Target`, `ImportItem.intent`, `SourceFolderImport.Input`, `StatementIssue.remap` match plans 1–2.
- Review Focus lines pinned in Tasks 1, 2, 3.
