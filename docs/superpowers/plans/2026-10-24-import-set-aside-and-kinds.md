# Import set-aside, new kinds and several documents per payment — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Files left out of an import can be kept for later (Mango's own copy, re-suggested when Mango learns more) or copied to a folder; users create custom document kinds while importing (stored, synced, renamable, mergeable, learnt); two new built-in kinds (Repair bill, Stamp duty); the "same document" alert fires only for identical files or true same-kind same-period duplicates; one document can evidence several transactions, with instalment and remainder suggestions.

**Architecture:** All rules live in BudgetCore: `ImportDuplicates` (alert rule and wording), `DocumentClassifier` + `EvidenceMatcher` (new kinds, instalments), a new `CustomDocumentKind` record with a `DocumentKindRef`/`DocumentKindCatalog` façade used wherever a kind is shown or compared, and a local-only `ImportWaitingList`. The App adds the *New kind…* control, a *Kinds…* sheet, a *Set aside* sheet and a *Waiting for later* panel. Custom kinds created in a review stay in the plan until Confirm.

**Tech Stack:** Swift 6, SwiftUI (macOS 26), BudgetCore SwiftPM package, GRDB, XCTest.

**Spec:** `docs/superpowers/specs/2026-10-24-import-set-aside-and-kinds-design.md` (read it with `docs/superpowers/specs/2026-10-20-document-import-design.md`).

## Global Constraints

- No personal data in the repo: synthetic fixtures and demo data only (invented names, NIFs, ATCUDs, amounts).
- Filed SA years 2020/21–2024/25 must never change: the filed-year tests (`FiledYearSyncCheckTests`, `SelfAssessmentTests`, the filed-year guard tests) pass unchanged after every task.
- Logic in BudgetCore; the App only presents and calls it.
- UI fits 1100×700 with no figure wrapping (Panel, DataTable, StatusPill, InlineBanner, MoneyText, DateText, `figureText`).
- Editors save only on Save (Kinds sheet, evidence rules sheet, inspector details). One-click actions (Keep for later, Copy, Discard after confirmation, Import) are their own save.
- Nothing is written before Confirm in a review: a kind created there is pending until Confirm.
- Migrations appended last in `DatabaseManager` (after `registerSyncMigration`), never editing applied ones. New synced tables/columns go into `SyncSchema.tables` (parents first), `uniqueKeys`, `jsonReferences`; `SyncSchema.version` 4 → 5 and the new `pinnedHash` in `SyncChangeTrackerTests`. Local-only tables go into `SyncSchema.localOnlyTables`.
- The real database is never written by development agents; the one-off tool of Task 3 defaults to a dry run and is run for real only with the user's go.
- Build the App target too before merging: `swift test` misses App compile errors.
- Commit messages end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

Commands used throughout:
- Core tests: `swift test --filter <TestClass>` (all: `swift test`).
- App build: `xcodegen generate && xcodebuild -project Mango.xcodeproj -scheme Mango -configuration Debug -destination 'platform=macOS,arch=arm64' build`.
- Snapshots: `scripts/render-snapshots.sh`.

## Review Focus

1. **A notice, a receipt and an invoice of one payment from the same issuer, same day, same amount** must import together with no alert — Task 1 `testNoticeReceiptAndInvoiceOfOnePaymentImportTogether`.
2. **A receipt that quotes its invoice's ATCUD** must not be skipped as a duplicate of the invoice — Task 1 `testReceiptQuotingItsInvoicesATCUDIsNotADuplicate`.
3. **A mortgage notice or BBVA advice that lists "Imposto do Selo"** must keep its kind, not become Stamp duty — Task 2 `testStampDutyLinesInLoanLettersAndAdvicesKeepTheirKinds`.
4. **Keeping a file whose original was moved or deleted after reading** must fail for that file with its name, keep the others, and never leave a row without a copy — Task 9 `testKeepWithAMissingOriginalSkipsThatFileOnly`.
5. **Merging a custom kind that a pending review, a learnt rule and an evidence rule all use** must leave no dangling id: the rule follows the target, the evidence rule accepts the target, and a review item still holding the old pending/saved id is re-read at Confirm, not filed under a deleted kind — Task 5 `testMergeRepointsDocumentsRulesAndRequirements`, Task 6 `testConfirmWithAKindMergedMeanwhileFailsAsOutOfDate`.

---

### Task 1: The duplicate alert — identical file or same kind and period, worded with what it compares

**Files:**
- Modify: `Sources/BudgetCore/DocumentImport/ImportDuplicates.swift`
- Modify: `Sources/BudgetCore/DocumentImport/ImportPipeline.swift:1500-1610` (issue-id helpers that list `possibleDuplicate`, `sharedTransaction.`, `transactionHasDocument.`)
- Modify: `Sources/BudgetCore/DocumentImport/ImportResolutions.swift:530-540` (transaction of a duplicate-pass issue: add `checkLink.`)
- Modify: `App/Snapshots/ImportReviewDemo.swift:204` (demo wording)
- Test: `Tests/BudgetCoreTests/ImportDuplicatesTests.swift`

**Interfaces:**
- Produces: `DocumentIdentity.Identity.kindToken: String?` replacing `kind: DocumentKind?` — `"<DocumentKind.rawValue>"` for built-ins, `"custom:<id>"`/`"pending:<uuid>"` added by Task 6; `static func kindToken(of kind: ImportKind) -> String?`.
- Produces: `ImportDuplicates.claimRole(token: String, text: String?) -> String` (the existing rule, on tokens: bank advice / transfer proof / mortgage notice / receipt keep theirs; a text that `IssuerKey.isBankMovementAdvice` → `"bankDebitAdvice"`; else the token).
- Produces: issue ids `possibleDuplicate` (kept), `sameKindOnTransaction.<transactionId>` (replaces `sharedTransaction.` and `transactionHasDocument.`), `checkLink.<transactionId>`; the sentence helpers below.

Rules (spec §4b): a strong-identity match, a weak-key match and a transaction claim count only when both sides have the same `claimRole` **and** the same period (`identity.day` equal, or both have `periodStart/periodEnd` and they overlap — add `period: ClosedRange<String>?` to `Identity`, filled from `.periodStart`/`.periodEnd` facts and the library document's columns). The issuer weak key becomes `"ida:<role>:<issuer>:<day>:<signed>"`. A strong match across different roles adds the note `"Refers to <name>: same <ATCUD|invoice number|receipt number> <value>"` and nothing else. Two certain links of one role and different periods on one transaction: both links `.needsReview` with issue `checkLink.<id>` (`.chooseLink`, offers `[.fileWithoutLink]`), reason `"<a> and <b> — both <kind>, <period a> and <period b> — were matched to the same transaction"`; skipped when either link's reasons contain `"Chosen by you"`.

Sentences (exact):
- `"Identical file: already in the library as \(name)"`, `"Identical file: same as \(file) in this import"`
- `"Duplicate of \(name): the same \(kindLower), \(keyName) \(value)"` with keyName `ATCUD` / `invoice number` / `receipt number` / `form` (payroll)
- `"Possibly a duplicate of \(name): also \(article(kind)) from \(issuer) dated \(day) for \(amount)"`, without `" from \(issuer)"` when unknown; day as `PropertyDates.isoDay`, amount `Money.format`
- `"Possibly a duplicate: \(name) is also \(article(kind)) dated \(day) on this transaction"`

- [ ] **Step 1: Write the failing tests** (new, in `ImportDuplicatesTests`)

```swift
func testNoticeReceiptAndInvoiceOfOnePaymentImportTogether() throws {
    // Same issuer, day and amount; three kinds; all certain of one debit.
    let t = try transaction(-7995, "DEMO CANALIZACOES")
    let link = ProposedLink(entity: .transaction(t), label: "DEMO −€79.95", confidence: .certain, reasons: ["test"])
    let facts = [fact(.issuer, .text("Demo Canalizações")), fact(.docDate, .date(Self.date(2023, 3, 5))), fact(.amount, .money(7995, .eur))]
    let annotated = try annotate([item("notice.pdf", sha: "a1", kind: .evidence(.imiNotice), facts: facts, links: [link]),
                                  item("receipt.pdf", sha: "a2", kind: .evidence(.insuranceReceipt), facts: facts, links: [link]),
                                  item("invoice.pdf", sha: "a3", kind: .evidence(.legalInvoice), facts: facts, links: [link])])
    XCTAssertEqual(annotated.map(\.section), [.ready, .ready, .ready])
    XCTAssertTrue(annotated.allSatisfy { $0.issues.isEmpty && $0.duplicate == nil })
}

func testReceiptQuotingItsInvoicesATCUDIsNotADuplicate() throws {
    try libraryDocument(sha: "b0", name: "Invoice FT 1", kind: .legalInvoice, text: "ATCUD:ABCD1234-77")
    let annotated = try annotate([item("receipt.pdf", sha: "b1", kind: .evidence(.insuranceReceipt), text: "Recibo RC 9 ATCUD:ZZZZ9999-1 ref. ATCUD:ABCD1234-77")])
    XCTAssertNil(annotated[0].duplicate)
    XCTAssertEqual(annotated[0].notes, ["Refers to Invoice FT 1: same ATCUD ABCD1234-77"])
}

func testSameKindSameDayIsPossiblyADuplicateWordedWithWhatItCompares() throws {
    try libraryDocument(sha: "c0", name: "Insurance March", docDate: Self.date(2023, 3, 5), amount: 12000)
    let annotated = try annotate([item("insurance.pdf", sha: "c1", facts: [fact(.docDate, .date(Self.date(2023, 3, 5))), fact(.amount, .money(12000, .eur))])])
    XCTAssertEqual(annotated[0].needsYouReasons, ["Possibly a duplicate of Insurance March: also an insurance receipt dated 2023-03-05 for €120.00"])
}

func testSameKindOverlappingPeriodsOnOneTransactionIsPossiblyADuplicate() throws { /* two .utilityInvoice-kind items, periods Mar 1–31 and Mar 15–Apr 14, same certain link → both needsYou with "Possibly a duplicate: <other> is also a utility invoice dated … on this transaction" */ }

func testSameKindDifferentPeriodsAutoLinkedToOneTransactionAskToCheckTheLink() throws {
    // Jan and Feb invoices both matched (certain) to one debit: no duplicate wording; links needsReview; issue id "checkLink.<t>".
}

func testLinksChosenByYouNeverAlert() throws { /* same as above with reasons ["Chosen by you"] → .ready, no issues */ }

func testIdenticalFileWordings() throws {
    // library hash → "Identical file: already in the library as <name>"; second copy in the batch → "Identical file: same as a.pdf in this import"
}
```

- [ ] **Step 2: Update the existing tests to the new rule and wording** — `testATCUDInLibraryTextIsDocumentDuplicate` (`"Duplicate of Insurance receipt March: the same insurance receipt, ATCUD ABCD1234-77"`), `testSameHashAsLibraryDocumentIsFileDuplicate`, `testSameFileTwiceInOneBatchIsOneReadyOneDuplicate`, `testSameDocumentTwiceInOneBatchIsOneReadyOneDuplicate`, `testIssuerDateAmountMatchesLibraryDocument`, `testKindKeyMatchesWhicheverSideNamesNoIssuer`, `testStrongBatchMatchWinsOverWeakLibraryMatch`, `testTwoDocumentsClaimingTheSameTransactionBothNeedYou` (different days → now `checkLink`), `testTransactionWithADocumentOfTheSameKindInThisImportNeedsYou` / `…NeedsYou` (same day → `sameKindOnTransaction` wording; different day → no alert), `testTwoReceiptsOrTwoAdvicesOnOneDebitStillNeedYou`, `testTheSameAdviceFiledAgainUnderAnotherKindIsStillCaught` (same role kept). Keep every "is fine" test passing unchanged.

- [ ] **Step 3: Run to see them fail** — `swift test --filter ImportDuplicatesTests` → the new tests FAIL (old wording / alerts across kinds).

- [ ] **Step 4: Implement** in `ImportDuplicates.swift` as specified above (`kindToken`, `period`, role-scoped keys, sentences, `checkLink.`), then follow the renamed ids through `ImportPipeline` (the helpers listing duplicate-pass issue ids) and `ImportResolutions.transactionId(ofDuplicateIssue:)`.

- [ ] **Step 5: Run** `swift test --filter ImportDuplicatesTests`, then `swift test --filter Import` → PASS.

- [ ] **Step 6: Commit** — `git commit -m "Import duplicates: alert only for an identical file or the same kind and period, worded with what it compares"`

---

### Task 2: Built-in kinds Repair bill and Stamp duty

**Files:**
- Modify: `Sources/BudgetCore/Evidence/EvidenceDocument.swift` (cases `repairInvoice`, `stampDuty`; display names `"Repair bill"`, `"Stamp duty"`)
- Modify: `Sources/BudgetCore/DocumentImport/ImportNaming.swift:86` (`repairInvoice` → `"Property"`, `stampDuty` → `"Tax PT"`)
- Modify: `Sources/BudgetCore/Evidence/DocumentClassifier.swift` (rules + `public static let rulesVersion = 2`)
- Modify: `Sources/BudgetCore/Evidence/EvidenceMatcher.swift:60` (expectations)
- Modify: `Sources/BudgetCore/Evidence/EvidenceRequirementDefaults.swift:31` (repair → `[.repairInvoice, .other]`, usual source "Supplier"; new: name contains "selo" or "stamp duty" → `[.stampDuty]`, "Portal das Finanças", checked before the `pt tax`/IRS rule)
- Modify: `Sources/BudgetCore/Tax/TaxSettings.swift` `TaxExpenseTypeMap.suggestedType` (expense named "selo"/"stamp duty" → the user's answer to open question 2; default `.otherExpense`), before the `imposto` → `.foreignTax` line
- Modify: every exhaustive `switch` over `DocumentKind` the compiler flags (e.g. `ImportModelProposals`, model prompts)
- Test: `Tests/BudgetCoreTests/DocumentClassifierTests.swift`, `EvidenceMatcherTests.swift`, `ImportNamingTests.swift`, `EvidenceRequirementDefaultsTests` (in the file that tests `rule(forCategoryName:)`), `TaxExpenseTypeMap` tests

**Interfaces:**
- Produces: `DocumentKind.repairInvoice`, `DocumentKind.stampDuty`; `DocumentClassifier.rulesVersion: Int` (Task 9's signature reads it).

Rules (spec §3): Repair text rule after `.utilityInvoice`, before the generic `.bankTransferProof`: `hasSquashed("FATURA","FACTURA","RECIBO","INVOICE") && has(repair words) && !has("MANUTENCAO DE CONTA")`. Repair file-name rule after `.legalInvoice`: `REPARACAO|REPAIR|OBRAS|MANUTENCAO|CANALIZ`. Stamp duty text rule right after `.ptIRSDeclaration`: `has("IMPOSTO DO SELO","IMPOSTO SELO") && (isStatePayment || has("NOTA DE COBRANCA","DOCUMENTO DE COBRANCA","LIQUIDACAO")) && !has("EMPRESTIMO","PRESTACAO","CREDITO HABITACAO")`. Stamp duty file-name rule before the IRS/IMI file rules: word `SELO` or `STAMP DUTY`. Expectations: repair `.debit, -15...45, categoryHints ["repair","manuten","obras"]`; stamp duty `.debit, -1...60, anchor .docDate, categoryHints ["selo","stamp"], descriptionHints ["PAGEST","ESTADO","SELO"], accountHint bbva`.

- [ ] **Step 1: Write the failing tests** (synthetic text only)

```swift
func testRepairBills() {
    XCTAssertEqual(DocumentClassifier.classify(text: "Canalizações Exemplo Lda\nFATURA-RECIBO FR 2026/15\nReparação de autoclismo\nMão de obra 40,00\nTotal 79,95 EUR", fileName: "doc.pdf"), .repairInvoice)
    XCTAssertEqual(DocumentClassifier.classify(text: "Demo Handyman Ltd\nINVOICE 12\nBoiler repair and maintenance\nTotal £120.00", fileName: "x.pdf"), .repairInvoice)
    XCTAssertEqual(DocumentClassifier.classify(text: nil, fileName: "Fatura reparacao esquentador.pdf"), .repairInvoice)
}
func testRepairWordingInOtherIssuersKeepsTheirKinds() {
    // condomínio receipt for works, insurance receipt, bank fee "Manutenção de conta", utility invoice
    XCTAssertEqual(DocumentClassifier.classify(text: "Condomínio Rua Exemplo 1\nRecibo N 44\nQuota extra obras fachada", fileName: "a.pdf"), .condominioReceipt)
    XCTAssertEqual(DocumentClassifier.classify(text: "Extrato\nSaldo\nComissão manutenção de conta", fileName: "b.pdf"), .bankStatement)
}
func testStampDuty() {
    XCTAssertEqual(DocumentClassifier.classify(text: "Autoridade Tributária e Aduaneira\nDOCUMENTO DE COBRANÇA\nImposto do Selo\nVerba 2 Arrendamento\nValor a pagar 95,00 €", fileName: "d.pdf"), .stampDuty)
    XCTAssertEqual(DocumentClassifier.classify(text: "COMPROVATIVO DE PAGAMENTO\nPortal das Finanças\nImposto do Selo\nValor 95,00", fileName: "e.pdf"), .stampDuty)
    XCTAssertEqual(DocumentClassifier.classify(text: "Pagamentos ao Estado\nImposto do Selo\n95,00 EUR", fileName: "f.pdf"), .stampDuty)
    XCTAssertEqual(DocumentClassifier.classify(text: nil, fileName: "Imposto do Selo 2026.pdf"), .stampDuty)
}
func testStampDutyLinesInLoanLettersAndAdvicesKeepTheirKinds() {
    XCTAssertEqual(DocumentClassifier.classify(text: "Aviso débito prestação\nEmpréstimo 0001\nJuros 300,00\nImposto do Selo 12,00", fileName: "g.pdf"), .mortgageNotice)
    XCTAssertEqual(DocumentClassifier.classify(text: "Recibo de empréstimo 193/480\nImposto do Selo 12,00", fileName: "h.pdf"), .mortgageReceipt)
}
```
Plus: `ImportNamingTests` area `"Property"` / `"Tax PT"`; `EvidenceMatcherTests` a repair bill of €79.95 proposes a −€79.95 debit 10 days later; defaults `rule(forCategoryName: "Repairs").kinds == [.repairInvoice, .other]`, `rule(forCategoryName: "Imposto do Selo").kinds == [.stampDuty]`; `TaxExpenseTypeMap.suggestedType(forCategoryName: "Imposto do Selo", type: .expense) == .otherExpense` (or the user's answer).

- [ ] **Step 2: Run** `swift test --filter DocumentClassifierTests` → FAIL (no such cases).
- [ ] **Step 3: Implement** the cases, names, areas, rules, expectations, defaults, tax suggestion, `rulesVersion = 2`; fix every switch the compiler flags.
- [ ] **Step 4: Run** `swift test` → PASS, filed-year tests included.
- [ ] **Step 5: Commit** — `"Repair bill and Stamp duty document kinds: detection, matching, default evidence rules"`

---

### Task 3: One-off `ReclassifyNewKinds` (dry run by default)

**Files:**
- Create: `Sources/BudgetCore/Evidence/NewKindsReclassification.swift`
- Create: `Sources/ReclassifyNewKinds/main.swift`; Modify: `Package.swift` (executable target, like `ReclassifyMortgageReceipts`)
- Test: `Tests/BudgetCoreTests/NewKindsReclassificationTests.swift`

**Interfaces:**
- Consumes: Task 2 kinds; `ImportNaming`/`EvidenceNaming` for the new canonical names.
- Produces: `NewKindsReclassification.plan(db: Database, repairsRuleKinds: [DocumentKind]?) throws -> MortgageReceiptReclassification`-shaped `Plan` (own `DocumentChange` with `newKind`, `RequirementChange`), `apply(_ plan: Plan, db: Database) throws` (refuses with `.documentChanged(id)` if a document changed since planning).

Behaviour: library documents of kind `.other` whose text (else file name) `DocumentClassifier` now reads as `.repairInvoice` or `.stampDuty` get that kind and a canonical name with the new type part; evidence rules whose scope is a category named like "Repairs" and whose kinds are `[]` change to `repairsRuleKinds` when given (nil = rule untouched — the answer to open question 1). The tool prints the plan; `--apply` writes it after a timestamped backup (`MigrationBackup`), like `ReclassifyMortgageReceipts`.

- [ ] **Step 1: Failing tests** — `testOtherDocumentsReadAsRepairBillsAreReclassified`, `testDocumentsOfOtherKindsAreLeftAlone` (an `.insuranceReceipt` with repair words stays), `testRepairsRuleChangesOnlyWhenKindsAreGiven` (nil → no `RequirementChange`; `[.repairInvoice, .other]` → one change from `[]`), `testApplyRefusesADocumentChangedSincePlanning`.
- [ ] **Step 2: Run** `swift test --filter NewKindsReclassificationTests` → FAIL.
- [ ] **Step 3: Implement** the plan/apply and the tool (dry run unless `--apply`; `--repairs-kinds repairInvoice,other` sets the rule).
- [ ] **Step 4: Run** → PASS. Dry-run the tool on the demo database only: `swift run ReclassifyNewKinds --database <demo copy>`.
- [ ] **Step 5: Commit** — `"ReclassifyNewKinds: file existing documents under Repair bill and Stamp duty (dry run by default)"`. Do **not** run it on the real database; the controller asks the user.

---

### Task 4: Custom kinds — storage, sync and the kind façade

**Files:**
- Create: `Sources/BudgetCore/Evidence/CustomDocumentKind.swift` (record, `DocumentArea`, `DocumentKindRef`, `DocumentKindCatalog`, migration `createCustomDocumentKinds`)
- Modify: `Sources/BudgetCore/Evidence/EvidenceDocument.swift` (`customKindId: Int64?` on `EvidenceDocument` and `EvidenceDocumentSummary` + `CodingKeys`; `kindRef`)
- Modify: `Sources/BudgetCore/Evidence/EvidenceRequirement.swift` (`customKindIds: [Int64]`, `accepts(_ ref: DocumentKindRef)`)
- Modify: `Sources/BudgetCore/Database/DatabaseManager.swift` (register last)
- Modify: `Sources/BudgetCore/Sync/SyncSchema.swift`; `Tests/BudgetCoreTests/SyncChangeTrackerTests.swift` (version 5, new `pinnedHash`)
- Test: `Tests/BudgetCoreTests/CustomDocumentKindTests.swift`, `SyncSchemaTests`, `SyncReferenceClassificationTests`

**Interfaces:**
- Produces:
  - `public enum DocumentArea: String, Codable, CaseIterable, Sendable { case property, tax, bank, other; public var libraryArea: String }` → "Property", "Tax", "Bank", "Other".
  - `public struct CustomDocumentKind: Codable, Equatable, Identifiable, FetchableRecord, MutablePersistableRecord, Sendable { id: Int64?; name: String; area: DocumentArea; createdAt: Date }`, table `customDocumentKind`.
  - `public enum DocumentKindRef: Hashable, Codable, Sendable { case builtIn(DocumentKind); case custom(Int64) }`.
  - `public struct DocumentKindCatalog: Sendable { static func load(db: Database) throws -> Self; var all: [DocumentKindRef] /* built-ins then custom, each by name */; func displayName(_: DocumentKindRef) -> String; func libraryArea(_: DocumentKindRef) -> String; func custom(named: String) -> CustomDocumentKind? /* case- and accent-insensitive */ }`.
  - `EvidenceDocument.kindRef: DocumentKindRef` (`customKindId.map(.custom) ?? .builtIn(kind)`), same on the summary.
  - `EvidenceRequirement.customKindIds: [Int64]`; `accepts(_ ref: DocumentKindRef) -> Bool` (both lists empty = any); `accepts(_ kind: DocumentKind)` stays for built-ins.

Migration `createCustomDocumentKinds`: table `customDocumentKind` (`id`, `name TEXT NOT NULL COLLATE NOCASE UNIQUE`, `area TEXT NOT NULL`, `createdAt DATETIME NOT NULL`); `ALTER TABLE document ADD customKindId INTEGER REFERENCES customDocumentKind ON DELETE SET NULL` (+ index); `ALTER TABLE evidenceRequirement ADD customKindIds TEXT NOT NULL DEFAULT '[]'`. Sync: `SyncTableSchema("customDocumentKind", synced: ["name","area","createdAt"])` listed before `document`; `document` synced + `customKindId`, foreign key `"customKindId": "customDocumentKind"`; `evidenceRequirement` synced + `customKindIds`; `SyncUniqueKey("customDocumentKind", ["name"], .identity)`; `SyncJSONReference(table: "evidenceRequirement", column: "customKindIds", content: .rules([SyncJSONRule("[]", .row("customDocumentKind"))]), plainNumbers: [])`; `version = 5`.

- [ ] **Step 1: Failing tests** — `testCatalogListsBuiltInsThenCustomByName`, `testDocumentKindRefOfADocument`, `testRequirementAcceptsCustomKinds` (`kinds: [], customKindIds: [7]` accepts `.custom(7)` only; both empty accepts anything), `testNameIsUniqueIgnoringCase` (inserting "boiler service" after "Boiler service" throws), `testMergedOrDeletedKindLeavesDocumentsAsOther` (FK set null); and the sync guards: `SyncSchemaTests` (every column classified, parents first), `SyncReferenceClassificationTests` (unique key and JSON reference listed), `SyncChangeTrackerTests.testSchemaHashIsPinnedToItsVersion` with `XCTAssertEqual(SyncSchema.version, 5)`.
- [ ] **Step 2: Run** `swift test --filter "CustomDocumentKindTests|SyncSchemaTests|SyncReferenceClassificationTests|SyncChangeTrackerTests"` → FAIL.
- [ ] **Step 3: Implement**; compute the new hash with `SyncChangeTracker.schemaHash(SyncSchema.tables)` and pin it.
- [ ] **Step 4: Run** `swift test` → PASS.
- [ ] **Step 5: Commit** — `"Custom document kinds: table, document and evidence-rule columns, synced (schema version 5)"`

---

### Task 5: Custom kinds across the library — names, filters, matching, rename and merge

**Files:**
- Create: `Sources/BudgetCore/Evidence/CustomDocumentKinds.swift` (create/rename/merge)
- Modify: `Sources/BudgetCore/Evidence/EvidenceBrowsing.swift` (`Filter.kind: DocumentKindRef?`; present kinds as refs, line ~210)
- Modify: `Sources/BudgetCore/Evidence/MissingEvidence.swift`, `MissingEvidenceBrowsing.swift` (`requirement.accepts(document.kindRef)`)
- Modify: `Sources/BudgetCore/DocumentImport/ImportNaming.swift` (`area(of ref:catalog:)`)
- Modify: `Sources/BudgetCore/Evidence/EvidenceMatcher.swift` (custom kinds use the default `Expectation()`)
- Test: `Tests/BudgetCoreTests/CustomDocumentKindsTests.swift`, `EvidenceBrowsingTests`, `MissingEvidenceTests`

**Interfaces:**
- Consumes: Task 4.
- Produces:
  - `public enum CustomDocumentKinds { enum Failure: Error, Equatable { case emptyName; case nameTaken(String) /* a custom or built-in display name, ignoring case and accents */; case notFound(Int64); case mergeIntoItself } }`
  - `static func create(db: Database, name: String, area: DocumentArea, now: Date) throws -> CustomDocumentKind`
  - `public struct KindEdit: Equatable, Sendable { enum Change { case rename(name: String, area: DocumentArea); case merge(into: DocumentKindRef) }; var kindId: Int64; var change: Change }`
  - `static func save(db: Database, edits: [KindEdit]) throws -> KindSaveResult` (`documentsChanged`, `rulesChanged`, `requirementsChanged`), all in the caller's one write.

Rename: name/area; canonical names whose part `" - <oldArea> - <oldName>"` (or leading part after the date) is rewritten to the new; `importRule` `documentKind` rules naming the id get `actionLabel = "Kind: <new name>"`. Merge into a ref: documents' `kind`/`customKindId` set to the target with canonical names rewritten; `documentKind` rules' `actionJSON` re-pointed; requirements: id removed from `customKindIds`, target added to `kinds` or `customKindIds` (no duplicates); the custom kind deleted.

- [ ] **Step 1: Failing tests** — `testCreateRefusesBuiltInAndCustomNames` ("repair bill" → `.nameTaken("Repair bill")`), `testRenameRewritesCanonicalNamesAndRuleLabels`, `testMergeRepointsDocumentsRulesAndRequirements` (custom 1 used by a document, a learnt rule and a requirement `[customKindIds: [1]]` merged into `.builtIn(.repairInvoice)` → document `.repairInvoice`/nil, rule action `.repairInvoice`, requirement `kinds [.repairInvoice], customKindIds []`, kind gone), `testMergeIntoAnotherCustomKind`, `testLibraryFilterByCustomKind`, `testMissingEvidenceSatisfiedByACustomKind`.
- [ ] **Step 2: Run** `swift test --filter "CustomDocumentKindsTests|EvidenceBrowsingTests|MissingEvidenceTests"` → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** `swift test` → PASS.
- [ ] **Step 5: Commit** — `"Custom kinds in the library: filters, missing evidence, canonical names, rename and merge"`

---

### Task 6: Custom kinds in the import — New kind…, Confirm, learning

**Files:**
- Modify: `Sources/BudgetCore/DocumentImport/ImportModel.swift` (`ImportKind.customEvidence(CustomKindKey)`, `ImportPlan.pendingKinds`, resolutions)
- Modify: `Sources/BudgetCore/DocumentImport/ImportResolutions.swift`, `ImportPipeline.swift` (a custom kind is read like `.evidence(.other)` by the evidence reader, then named and filed as the custom kind)
- Modify: `Sources/BudgetCore/DocumentImport/ImportApplier.swift` (insert pending kinds first through `ImportChangeCapture`; file with `kind .other` + `customKindId`)
- Modify: `Sources/BudgetCore/DocumentImport/ImportRule.swift` (`DocumentKindAction.customKindId: Int64?`, decoded when absent), `ImportLearning.swift` (draft and recogniser), `ImportDuplicates.swift` (`kindToken` for custom: `"custom:<id>"`, `"pending:<uuid>"`)
- Modify: `Sources/BudgetCore/Sync/SyncSchema.swift` (`importRule.actionJSON` rule `SyncJSONRule("customKindId", .row("customDocumentKind"))` — no table change, so no version bump)
- Test: `Tests/BudgetCoreTests/ImportCustomKindTests.swift`, `ImportLearningTests`, `ImportApplierTests`, `ImportUndoTests`

**Interfaces:**
- Consumes: Tasks 1, 4, 5.
- Produces:
  - `public enum CustomKindKey: Hashable, Codable, Sendable { case saved(Int64); case pending(UUID) }`
  - `public struct PendingDocumentKind: Equatable, Sendable { id: UUID; name: String; area: DocumentArea }`; `ImportPlan.pendingKinds: [PendingDocumentKind]`
  - `ImportResolution.chooseCustomKind(CustomKindKey)` and `.createKind(name: String, area: DocumentArea)` (adds a pending kind, then acts as `.chooseCustomKind(.pending(id))`; refuses a name taken by a built-in, a saved custom kind or another pending one with `ImportResolutionError.kindNameTaken(String)`)
  - `ImportSession.kindChoices: [ImportKindChoice]` where `public struct ImportKindChoice: Hashable, Sendable { var kind: ImportKind; var label: String }` — built-ins, saved custom kinds, then the review's pending ones, by label.

Confirm: pending kinds are inserted before any document (changes captured, so undo deletes them when nothing else uses them; otherwise undo refuses as for any changed row). If a saved custom kind an item uses no longer exists at Confirm, apply throws `ImportApplyError.notConfirmable` and the review stays open (the plan is out of date: re-read). Learning: a `.chooseCustomKind` on an item with an `IssuerKey` drafts `DocumentKindAction(kind: .other, customKindId: id)` labelled `"Kind: <name>"`; a pending id is resolved to the inserted id at Confirm. The recogniser skips a rule whose custom kind is gone.

- [ ] **Step 1: Failing tests** — `testNewKindIsUsableForOtherItemsOfTheReview`, `testNewKindNameTakenIsRefused`, `testConfirmInsertsThePendingKindAndFilesUnderIt` (document `kind .other`, `customKindId` = new id; canonical name `"20230305 - Property - Boiler service - …"`), `testDiscardForgetsAPendingKind`, `testUndoRemovesAKindTheRunCreated`, `testCustomKindIsLearntForTheIssuerAndSuggestedNextTime` (second import of the issuer → `.customEvidence(.saved(id))`, `.needsReview` until Confirm per the existing learnt-kind rule), `testConfirmWithAKindMergedMeanwhileFailsAsOutOfDate`, `testTwoFilesOfOneCustomKindAndDayAreDuplicates` (Task 1 rule with custom tokens).
- [ ] **Step 2: Run** `swift test --filter "ImportCustomKindTests|ImportLearningTests"` → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** `swift test` → PASS.
- [ ] **Step 5: Commit** — `"Import: New kind… in the review, saved at Confirm, learnt per sender"`

---

### Task 7: App — kind chooser, Kinds sheet, filters and evidence rules

**Files:**
- Modify: `App/DocumentImport/ImportIssueControls.swift:417-447` (`ImportKindChooser` from `session.kindChoices`; last item *New kind…*)
- Create: `App/DocumentImport/NewKindPopover.swift` (name field + area segmented control; *Create* disabled while empty; shows the `kindNameTaken` message inline)
- Modify: `App/DocumentImport/ImportPreviewPanel.swift:215` (the "Recognised as" block offers the chooser on Ready items too, as today)
- Create: `App/Documents/DocumentKindsSheet.swift` (DataTable: name, area, documents; Rename / Merge into… staged; **Save** applies `CustomDocumentKinds.save`; Cancel discards)
- Modify: `App/Documents/DocumentsView.swift`, `DocumentsViewModel.swift` (kind filter over `DocumentKindRef`; toolbar *Kinds…*), `DocumentInspector.swift` (kind picker with custom kinds), `EvidenceRulesSheet.swift` (kinds multi-select includes custom kinds, saves `customKindIds`), `App/Rules/ImportRulesTab.swift` (labels from the catalog)
- Modify: `App/Snapshots/SnapshotCatalog.swift`, `ImportReviewDemo.swift` (routes `import-review-new-kind`, `documents-kinds`)

**Interfaces:**
- Consumes: `ImportSession.kindChoices`, `ImportResolution.chooseCustomKind/.createKind`, `DocumentKindCatalog`, `CustomDocumentKinds.save`.

- [ ] **Step 1: Implement** the views above; all BudgetCore calls off the main actor as the existing view models do.
- [ ] **Step 2: Build** the App (command above) → succeeds.
- [ ] **Step 3: Snapshots** `scripts/render-snapshots.sh` → the new routes render at 1100×700 with no wrapped figures and no clipped buttons; check the PNGs.
- [ ] **Step 4: Commit** — `"App: New kind… in the import review, Kinds sheet with rename and merge, custom kinds in filters and evidence rules"`

---

### Task 8: One document on several transactions — instalments and the remainder

**Files:**
- Modify: `Sources/BudgetCore/Evidence/EvidenceMatcher.swift` (instalment pairs; remainder suggestions)
- Modify: `Sources/BudgetCore/Evidence/EvidenceBrowsing.swift:313` (`documentSuggestions` adds remainder matches)
- Modify: `Sources/BudgetCore/DocumentImport/Readers/DocumentImportReaders.swift:660-690` (instalment proposal), `ImportResolutions.swift` (`.acknowledge` on `instalments` makes both links certain, reason "Checked by you")
- Modify: `App/Documents/LinkPickers.swift:145` (empty search lists unlinked **and** partly paid documents)
- Test: `Tests/BudgetCoreTests/EvidenceMatcherTests.swift`, `ImportMultiLinkTests.swift` (new), `MissingEvidenceTests`, `EvidenceBrowsingTests`

**Interfaces:**
- Produces:
  - `public struct InstalmentMatch: Equatable, Sendable { var transactionIds: [Int64]; var reasons: [String] }`
  - `EvidenceMatcher.instalments(document: EvidenceDocument, index: Index) -> [InstalmentMatch]` — pairs only: two debits (the kind's direction), both inside the kind's window plus `amountGraceDays`, same `MerchantKey.make(rawDescription)`, each smaller than the document's amount, summing exactly to it in the account's currency; reason `"Paid in 2 instalments: \(a) + \(b)"`; at most 3 matches, earliest first.
  - `EvidenceMatcher.remainder(document: EvidenceDocument, linkedAmounts: [Int], transaction: Transaction, currency: Currency) -> Suggestion?` — the transaction's amount equals the document's amount minus the linked debits' total (> 0); reason `"Pays the rest of \(name): \(remaining) after \(paid)"`; scores as an exact amount.
  - `EvidenceDocumentSearch.Entry.isPartlyPaid: Bool` (linked transaction debits sum below the document's amount); filter `LinkState.unlinkedOrPartlyPaid`.

Import: when no single confident match exists and `instalments` finds exactly one pair, the item gets both links `.needsReview` and issue `ImportIssue(id: "instalments", kind: .readerProblem(reason), reason: reason, offers: [.acknowledge, .fileWithoutLink])`; with several pairs, the existing "which one?" chooser lists the pairs' transactions.

- [ ] **Step 1: Failing tests** — `testTwoDebitsOfOneMerchantAddingUpToTheInvoiceAreInstalments` (€79.95 = −40.00 −39.95, 20 days apart → one match), `testDebitsOfAnotherMerchantOrNotAddingUpAreNot`, `testInstalmentsAreAskedNeverCertain` (import item in Needs you; `.acknowledge` → two certain links; Confirm writes two `documentLink` rows), `testOneDocumentLinkedToTwoDebitsSatisfiesBothInMissingEvidence`, `testRemainderSuggestedForTheSecondInstalment` (document linked to −40.00; −39.95 suggested with the reason), `testPartlyPaidDocumentsAreListedWithoutSearching`, `testStatementLinkedToThreeFeeDebitsSatisfiesThree` (a `.bankStatement` document linked to three debits under a `[.bankStatement]` rule → three satisfied).
- [ ] **Step 2: Run** `swift test --filter "EvidenceMatcherTests|ImportMultiLinkTests|MissingEvidenceTests|EvidenceBrowsingTests"` → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** `swift test` → PASS; build the App.
- [ ] **Step 5: Commit** — `"One document on several transactions: instalment pairs, the rest of a part-paid document"`

---

### Task 9: Waiting list and set-aside in BudgetCore

**Files:**
- Create: `Sources/BudgetCore/DocumentImport/ImportWaitingList.swift` (record, migration `createImportWaitingFile`, store)
- Create: `Sources/BudgetCore/DocumentImport/ImportSetAside.swift` (candidates, copy to a folder)
- Modify: `Sources/BudgetCore/DocumentImport/ImportApplier.swift` (`ImportRunSummary.setAside: [SetAsideFile]`; mark waiting rows imported in the apply transaction)
- Modify: `Sources/BudgetCore/DocumentImport/ImportSession.swift` (`setAsideCandidates() -> [SetAsideFile]` for an open review; `waiting: [ImportWaitingFile]`, `refreshWaiting()` re-checking off the main actor; `importWaiting(_ ids: [Int64])` starting a review with entry point "Waiting list")
- Modify: `Sources/BudgetCore/Database/DatabaseManager.swift` (register last), `Sources/BudgetCore/Sync/SyncSchema.swift` (`"importWaitingFile"` in `localOnlyTables`)
- Test: `Tests/BudgetCoreTests/ImportWaitingListTests.swift`, `ImportSetAsideTests.swift`, `ImportSessionTests`

**Interfaces:**
- Consumes: `DocumentClassifier.rulesVersion` (Task 2), custom kinds and `documentKind` rules (Tasks 4, 6), `ImportDetector`/`ImportLearning.recogniser` as the pipeline builds them.
- Produces:
  - `public struct SetAsideFile: Equatable, Sendable { var url: URL; var fileName: String; var sha256: String; var byteCount: Int64; var text: String?; var textStatus: DocumentTextStatus; var reason: String; var recognisedAs: String }`
  - `public struct ImportWaitingFile: Codable, Equatable, Identifiable, FetchableRecord, MutablePersistableRecord, Sendable { id; sha256 (unique); originalFileName; byteCount; storedRelativePath /* "<sha>/<originalFileName>" */; text: String?; textStatus; reason; recognisedAs; suggestion: String?; checkedSignature: String; keptAt: Date; importedRunId: Int64? }`, table `importWaitingFile` (`importedRunId` references `importRun` on delete set null).
  - `public struct ImportWaitingList { static var defaultRoot: URL /* Application Support/Budget/Waiting */; init(root: URL = defaultRoot, database: any DatabaseWriter); func keep(_ files: [SetAsideFile], now: Date) throws -> KeepResult /* kept, alreadyWaiting, failed: [(fileName: String, reason: String)] */; func waiting() throws -> [ImportWaitingFile] /* not imported, or imported by an undone run; newest first */; func fileURL(_ file: ImportWaitingFile) -> URL; func discard(_ ids: [Int64]) throws; func recheck(recognise: (ImportFile) -> ImportRecognition, signature: String) throws -> [Int64] /* ids newly suggested */; func purgeImported(now: Date, olderThanDays: Int = 30) throws -> Int; static func signature(db: Database) throws -> String; static func markImported(db: Database, runId: Int64, sha256s: Set<String>) throws }`
  - `public enum ImportSetAside { static func candidates(_ plan: ImportPlan, discarding: Bool) -> [SetAsideFile]; static func copy(_ files: [SetAsideFile], waitingCopy: (String) -> URL?, to folder: URL) -> CopyResult /* copied: [URL], failed: [(fileName: String, reason: String)] */ }`

Rules: candidates are top-level items (`parentId == nil`) that won't be imported — `isLeftOut` at Confirm, every item when `discarding` — except an `ImportDuplicate.Level.file` whose original is a library document; `reason` is the item's first Needs-you reason, else `"Left out by you"`, else `"Import discarded"`; `recognisedAs` the item's `recognition.kind.displayName`. `keep` copies first (to a temporary name, then moved into place), then inserts the row; a failed copy inserts nothing for that file. `signature` = SHA-256 of `rulesVersion`, the custom kinds (`id:name:area`, by id) and the enabled `documentKind`/`issuer` rules (`id:matchKey:actionJSON`, by id). `recheck` rebuilds an `ImportFile` from the row (url = the copy, stored text) for rows whose `checkedSignature` differs; a recognition other than `.unknown`/`.evidence(.other)` whose `displayName` differs from `recognisedAs` sets `suggestion = "Now recognised as <name>"`; the signature is stored either way. `copy` writes `name 2.ext`, `name 3.ext`… on a clash, never overwrites, copies the original when it exists, else the waiting copy. `markImported` (inside the apply) sets `importedRunId` for rows whose hash the run filed, linked or recorded.

- [ ] **Step 1: Failing tests**

```swift
func testKeepCopiesTheFileAndListsItAcrossReopen() throws // keep → copy exists under root/<sha>/<name>; new ImportWaitingList on the same DB lists it
func testKeepWithAMissingOriginalSkipsThatFileOnly() throws // two files, one url deleted → kept 1, failed ["gone.pdf"], one row, no orphan copy
func testKeepingTheSameFileTwiceIsAlreadyWaiting() throws
func testDiscardRemovesRowAndCopyButNeverTheOriginal() throws
func testSignatureChangesWithANewKindOrRule() throws // + a disabled rule doesn't change it
func testRecheckSuggestsFilesNowRecognised() throws // recognise closure returns .evidence(.repairInvoice) → suggestion "Now recognised as Repair bill"; unchanged signature → not re-read
func testImportedRowsLeaveTheListAndComeBackWhenTheRunIsUndone() throws
func testPurgeRemovesRowsOfStandingRunsAfter30Days() throws
func testCandidatesAtConfirmAreTheLeftOutFilesNotRowsNorIdenticalLibraryFiles() throws
func testCandidatesWhenDiscardingAreEveryFileButIdenticalLibraryFiles() throws
func testCopyToAFolderNumbersClashesAndNeverOverwrites() throws // existing "a.pdf" → "a 2.pdf"; original untouched (same bytes, same mtime)
func testCopyFallsBackToTheWaitingCopy() throws
func testWaitingTableIsLocalOnly() // SyncSchema.localOnlyTables.contains("importWaitingFile"); SyncSchemaTests stays green
```
- [ ] **Step 2: Run** `swift test --filter "ImportWaitingListTests|ImportSetAsideTests"` → FAIL.
- [ ] **Step 3: Implement** (file work through `FileManager`, temporary directories in tests).
- [ ] **Step 4: Run** `swift test` → PASS.
- [ ] **Step 5: Commit** — `"Import waiting list and set-aside: keep for later, copy to a folder, suggested again"`

---

### Task 10: App — Set aside sheet and the Waiting for later panel

**Files:**
- Create: `App/DocumentImport/SetAsideSheet.swift`
- Create: `App/DocumentImport/ImportWaitingPanel.swift`
- Modify: `App/DocumentImport/ImportCenterModel.swift` (publish `waiting`, `setAside`; `keepForLater(_:)`, `copyToFolder(_:)` with `NSOpenPanel` choosing a folder, `discardWaiting(_:)`, `importWaiting(_:)`; refresh/recheck on `loadRuns`, after Confirm and after a kind save)
- Modify: `App/DocumentImport/ImportReviewView.swift:57-60` (Discard dialog: *Set files aside…* opens the sheet, then discards on Done; *Discard* as today)
- Modify: `App/DocumentImport/ImportHistoryView.swift` (the panel above the history when the list isn't empty; a finished run with `setAside` opens the sheet once)
- Modify: `App/Snapshots/SnapshotCatalog.swift` (routes `imports-set-aside`, `imports-waiting`)

**Interfaces:**
- Consumes: Task 9 (`SetAsideFile`, `ImportWaitingList`, `ImportSetAside`, `ImportSession.setAsideCandidates/waiting/refreshWaiting/importWaiting`, `ImportRunSummary.setAside`).

UI copy: sheet title "Files not imported", subtitle "Mango can keep its own copy for later, or copy them to a folder. Your originals aren't touched."; row actions *Keep for later*, *Copy to a folder…* (a row done shows a StatusPill "Kept" / "Copied"); footer *Keep all for later*, *Copy all to a folder…*, *Done*. Panel title "Waiting for later" with subtitle "N files"; columns File, Kept (DateText), Why (StatusPill "Now recognised as …" when suggested, else the reason); row actions *Import*, *Copy to a folder…*, *Discard…* (confirmation "Mango deletes its copy. Your original, if you still have it, isn't touched."); header *Import suggested (N)* when N > 0 and *Import all*.

- [ ] **Step 1: Implement** the views and model actions (BudgetCore work off the main actor).
- [ ] **Step 2: Build** the App → succeeds.
- [ ] **Step 3: Snapshots** → both routes at 1100×700, no wrapped figures, long file names truncate in the middle.
- [ ] **Step 4: Commit** — `"App: set files aside after an import, Waiting for later in the import centre"`

---

### Task 11: Demo data, full verification, install

**Files:**
- Modify: `Sources/BudgetDemo/DemoImportSamples.swift` (synthetic: a repair bill + its receipt + a debit advice for one demo debit; a stamp-duty note; an invoice paid in two instalments; one unknown file to set aside)
- Modify: `Sources/BudgetDemo/DemoDatabase.swift` (one custom kind "Boiler service", one waiting file; demo "Repairs" rule accepting Repair bill and Other)

- [ ] **Step 1:** `swift test` → all PASS (filed-year tests included).
- [ ] **Step 2:** App build → succeeds; `scripts/render-snapshots.sh` → every route renders; review the new ones at 1100×700.
- [ ] **Step 3:** Run the app on the demo database: import the demo samples — the three documents of one debit import with no alert; the instalment pair is asked; leave the unknown file out → Set aside sheet → Keep for later; create "New kind…" for it in a new import → the waiting file is suggested again.
- [ ] **Step 4: Commit** — `"Demo: import samples for repair bills, stamp duty, instalments and set-aside"`
- [ ] **Step 5:** After merge to main: `xcodegen generate`, `scripts/install-app.sh`. The controller then asks the user for open questions 1–3 and for the go to run `ReclassifyNewKinds` on the real database.
