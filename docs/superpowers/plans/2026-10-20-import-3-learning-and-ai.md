# Import documents 3 — Learning from corrections and on-device AI — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The importer remembers what the user corrects — a document's type, its issuer, its link, and (with "remember for this issuer") where a figure sits on that issuer's layout — applies those learnt rules next time with the rule named in the preview, lists every learnt import rule on the Rules page beside the transaction rules (edit, disable, delete), and asks Apple's on-device model to propose what an unknown document is, without ever making it Ready on its own.

**Architecture:** The `importRule` store from plan 2 gains four kinds. An `IssuerKey` derived from the text ties rules to an issuer. Corrections made in the review become `ImportRuleDraft`s on the item and are written at Confirm import inside the run (so Undo forgets them). A learnt-rule recogniser runs after the built-in ones; learnt figure positions fill facts; learnt links turn an "amount only" candidate into a certain link when its description matches. For what nothing recognises, a `DocumentModelReading` (Foundation Models in the app, a stub in tests) proposes kind and figures as `.model` facts with a `confirmModelReading` issue; accepting it is a correction like any other. The Rules page gets an "Import rules" tab built like the transaction rules table.

**Tech Stack:** Swift 5.10, BudgetCore + GRDB, FoundationModels (macOS 26, `SystemLanguageModel`, `@Generable`), SwiftUI, XCTest.

**Spec:** `docs/superpowers/specs/2026-10-20-document-import-design.md` ("Learning", "On-device AI", "How detection should work", Call 4 with the user's addition on the Rules page). Builds on plans 1 and 2 (`docs/superpowers/plans/2026-10-20-import-1-core-and-review.md`, `…-import-2-statements.md`): uses `ImportRule`, `ImportRuleKind`, `ImportRuleStore`, `ImportDetector.recognisers`, `ImportItem`, `ImportFact`, `ImportIssueKind`, `ImportResolution`, `ImportPipeline`, `ImportApplier`, `ImportPreviewPanel`, `ImportIssueControls`, `RulesView`.

## Global Constraints

- Everything in plan 1's Global Constraints applies (scratch suffix `-imp3`).
- The model's answer is never Ready on its own: every item with a `.model` fact or recognition is Needs you until the user accepts or corrects it; accepting creates learnt rules.
- Nothing leaves the Mac: only `FoundationModels` on-device sessions; no network.
- Fixed values are not learnt (spec Call 4): a corrected figure fixes that document; only "remember for this issuer" stores a label/position rule, never the value.
- Learnt rules are written only at Confirm import, inside the run; Undo of the run deletes the rules it created and restores the ones it changed.
- Learnt rules never override a certain built-in recognition (built-ins first, then learnt rules, then the model) and never make an OCR-read figure certain.
- Model calls: at most 2 at once, text cut to the first 6,000 characters, 20-second timeout per document; unavailable model → the item says why (exact copy below) and stays Needs you with the kind picker.
- Rules page copy: tabs "Transaction rules" / "Import rules"; columns "Kind", "When", "Then", "Used", "On"; empty state "Nothing learnt yet: corrections you make while importing appear here."

## Review Focus

1. **Two issuers whose first line is the same generic header ("FATURA" / "INVOICE")** — a rule learnt for one never applies to the other; the issuer key prefers a tax/VAT/company number and only falls back to the first line when it has a distinctive name. Pinned in Task 1 (`testGenericFirstLineIsNotAnIssuerKey`).
2. **A learnt figure label that no longer appears on a new layout of the same issuer** — the figure falls back to the built-in reading and the item says "Learnt position not found", rather than reading the wrong number. Pinned in Task 3 (`testMissingLabelFallsBackAndSaysSo`).
3. **The model returns a kind that is not in the app's list, or a malformed date/amount** — ignored field by field; the item is still Needs you with whatever was valid. Pinned in Task 5 (`testMalformedModelAnswerKeepsOnlyValidFields`).
4. **A disabled rule** — not applied, not shown in the preview, still listed (off) on the Rules page; re-enabling applies it again. Pinned in Task 2 (`testDisabledRuleIsNotApplied`).
5. **A rule pointing at a deleted account or property** — not applied; the Rules page shows it as "Target missing". Pinned in Task 6 (`testRuleWithMissingTargetIsSkippedAndFlagged`).

---

### Task 1: Issuer key and the new rule kinds

**Files:**
- Create: `Sources/BudgetCore/DocumentImport/IssuerKey.swift`
- Modify: `Sources/BudgetCore/DocumentImport/ImportRule.swift`
- Test: `Tests/BudgetCoreTests/IssuerKeyTests.swift`

**Interfaces:**
- Consumes: plan 2 `ImportRuleKind`, `ImportRuleStore`; `RentReceiptPDFs.isValidNIF`, `EvidenceText.normalized`, `Person.ptNif`.
- Produces:
  - `public struct IssuerKey: Hashable, Codable, Sendable { public let key: String; public let label: String; public static func derive(text: String?, fileName: String, ownNIFs: Set<String>) -> IssuerKey? }` — first match wins: a valid PT NIF/NIPC (9 digits passing `isValidNIF`) within 30 characters after `NIF`, `NIPC`, `CONTRIBUINTE` or `N.º CONTRIBUINTE`, not in `ownNIFs` → `"nif:<digits>"`; a UK VAT number `GB ?\d{3} ?\d{4} ?\d{2}` → `"vat:<9 digits>"`; a company number after `COMPANY (REGISTRATION )?(NO|NUMBER)` → `"crn:<8 chars>"`; else the first non-empty normalised line with ≥ 4 letters, digits removed, that is not in `IssuerKey.genericLines` (`"FATURA"`, `"FACTURA"`, `"FATURA RECIBO"`, `"RECIBO"`, `"INVOICE"`, `"RECEIPT"`, `"STATEMENT"`, `"EXTRATO"`, `"NOTA DE CREDITO"`, `"CREDIT NOTE"`, `"PAGE"`, `"PAGINA"`) → `"line:<line>"`; else nil. `label`: the line nearest the key, title-cased, ≤ 40 characters.
  - `ImportRuleKind` gains `documentKind`, `issuer`, `link`, `figurePosition`.
  - Actions: `public struct DocumentKindAction: Codable, Equatable, Sendable { kind: DocumentKind }`; `public struct IssuerAction: Codable, Equatable, Sendable { name: String }`; `public struct LinkAction: Codable, Equatable, Sendable { entity: EvidenceEntity?; role: String?; descriptionKey: String? }` (link to a fixed record, or to the transaction whose `MerchantKey.make(description)` equals `descriptionKey`); `public struct FigurePositionAction: Codable, Equatable, Sendable { field: ImportFigureField; label: String; occurrence: Int }`.
  - Keys: `documentKind`/`issuer`/`link` → `issuerKey.key`; `figurePosition` → `"<issuerKey.key>#<field>"`.

- [ ] **Step 1: Write the failing tests**

```swift
func testNIFAfterLabelIsTheKeyUnlessItIsOurs() { /* "NIF: 503 504 564" → "nif:503504564"; with ownNIFs containing it → falls through */ }
func testUKVATNumber() { /* "VAT Reg No GB 123 4567 89" → "vat:123456789" */ }
func testGenericFirstLineIsNotAnIssuerKey() { /* "FATURA\nDemo Power, S.A.\n…" → "line:DEMO POWER, S.A." */ }
func testNoTextNoKey() { /* derive(text: nil, …) == nil */ }
```

- [ ] **Step 2: Run** `swift test --scratch-path <scratch>/build-imp3 --filter IssuerKeyTests` — Expected: FAIL.
- [ ] **Step 3: Implement** `IssuerKey` and the kind/action types.
- [ ] **Step 4: Run** — Expected: PASS.
- [ ] **Step 5: Commit** `git commit -m "Import: issuer key and learnt rule kinds"`

---

### Task 2: Corrections become rules at confirm; learnt type, issuer and links are applied

**Files:**
- Create: `Sources/BudgetCore/DocumentImport/ImportLearning.swift`
- Modify: `Sources/BudgetCore/DocumentImport/ImportModel.swift` (`ImportItem.appliedRules`, `ImportItem.ruleDrafts`, new resolution cases)
- Modify: `Sources/BudgetCore/DocumentImport/ImportResolutions.swift`, `ImportPipeline.swift`, `ImportApplier.swift`, `ImportDetector.swift`, `Readers/DocumentImportReaders.swift`
- Test: `Tests/BudgetCoreTests/ImportLearningTests.swift`

**Interfaces:**
- Consumes: Task 1; plan 1 `ImportResolution.chooseKind/chooseLink`, `ImportDetector.recognisers`, `EvidenceDocumentReader`.
- Produces:
  - `public struct ImportRuleUse: Equatable, Sendable { ruleId: Int64; kind: ImportRuleKind; label: String /* "Learnt: Demo Power → Utility invoice" */ }` and `ImportItem.appliedRules: [ImportRuleUse]`.
  - `public struct ImportRuleDraft: Equatable, Sendable { kind: ImportRuleKind; key: String; matchLabel: String; actionJSON: String; actionLabel: String }` and `ImportItem.ruleDrafts: [ImportRuleDraft]`.
  - `ImportResolution` gains `case setIssuer(String)`.
  - `public enum ImportLearning { public static func drafts(for item: ImportItem, resolution: ImportResolution, issuer: IssuerKey?) -> [ImportRuleDraft]; public static func recogniser(rules: [ImportRule], ownNIFs: Set<String>) -> ImportRecogniser; public static func applyLinkRules(_ item: ImportItem, rules: [ImportRule], db: Database) throws -> ImportItem }`
    - `drafts`: `.chooseKind(k)` → documentKind; `.setIssuer(name)` → issuer; `.chooseLink(entity)` → link (`entity` for non-transaction targets; `descriptionKey` = `MerchantKey.make` of the chosen transaction's description for transactions). No issuer key → no drafts (the correction still fixes this document).
    - `recogniser`: enabled `documentKind` rule for the file's issuer key → `.evidence(kind)` (or the matching `ImportKind`), `.certain`, reason `"Learnt: <issuer label> → <kind>"`; inserted in `ImportDetector.recognisers` after the built-ins and before the file-name fallback.
    - `applyLinkRules`: a `link` rule with an entity → certain link `"Learnt: <issuer> documents go to <label>"`; with a `descriptionKey` → a `chooseLink` candidate whose transaction's merchant key equals it and whose amount matched becomes the certain link (`dateInWindow` not required), reason `"Learnt: <issuer> is paid by “<description>”"`; an issuer rule names the issuer fact (`source: .learntRule`).
  - `ImportApplier`: after the effects, `ImportRuleStore.learn` for each draft of each applied item, and `markUsed` for each `appliedRules` id.

- [ ] **Step 1: Write the failing tests**

```swift
func testChoosingKindForUnknownDocumentLearnsAndAppliesNextTime() async throws {
    // letter from "Example Seguros, S.A." → .unknown; resolve(.chooseKind(.insuranceReceipt)); apply
    // second letter of the same issuer → recognition .evidence(.insuranceReceipt), .certain, reason "Learnt: Example Seguros, S.A. → Insurance receipt"; appliedRules.count == 1
}
func testChosenTransactionLinkIsLearntByMerchant() async throws { /* next month's amount-only candidate with the same merchant → Ready, linked */ }
func testDisabledRuleIsNotApplied() async throws { }
func testUndoRemovesRulesTheRunLearnt() async throws { }
func testBuiltInRecognitionWinsOverLearntRule() async throws { /* a P60 with a documentKind rule saying .other → still .payrollForm(.p60) */ }
```

- [ ] **Step 2: Run** `--filter ImportLearningTests` — Expected: FAIL.
- [ ] **Step 3: Implement**.
- [ ] **Step 4: Run** — Expected: PASS; plan 1 and 2 suites still pass.
- [ ] **Step 5: Commit** `git commit -m "Import: learn type, issuer and links from corrections"`

---

### Task 3: "Remember for this issuer" — learnt figure positions

**Files:**
- Create: `Sources/BudgetCore/DocumentImport/LearntFigures.swift`
- Modify: `Sources/BudgetCore/DocumentImport/ImportModel.swift` (resolution case), `ImportLearning.swift`, `Readers/DocumentImportReaders.swift`, `Readers/RentImportReaders.swift`
- Test: `Tests/BudgetCoreTests/LearntFiguresTests.swift`

**Interfaces:**
- Consumes: Tasks 1–2; `EvidenceAmountParser.amounts(in:)`, `EvidenceDateParser.dates(in:)`, `EvidenceText.normalized`, `EvidenceAnalyzer.occurrences(of:in:)`.
- Produces:
  - `ImportResolution` gains `case confirmFigureRemembering(ImportFigureField, ImportFactValue)`.
  - `public enum LearntFigures`:
    - `public static func label(for value: ImportFactValue, field: ImportFigureField, in text: String) -> (label: String, occurrence: Int)?` — algorithm: render the value in the forms the parsers read (money: `1.234,56`, `1234,56`, `1,234.56`, `1234.56`; date: `dd/MM/yyyy`, `dd-MM-yyyy`, `yyyy-MM-dd`, `dd.MM.yyyy`); find the first occurrence in the normalised text; take the text before it back to the previous line break (max 60 characters), keep its last 1–4 words containing letters (trailing `:` and spaces trimmed) as the label; `occurrence` = how many times that label appears before this one (0-based). Nil when the value isn't in the text or the label has no letters.
    - `public static func read(_ action: FigurePositionAction, field: ImportFigureField, in text: String) -> ImportFactValue?` — the `occurrence`-th match of the label, then the first value of the field's type within 120 characters after it.
  - Reader integration: for each enabled `figurePosition` rule of the item's issuer, `read` overrides the built-in fact with source `.learntRule`, `.certain` (`.needsReview` when the file used OCR) and reason `"Learnt position: after “<label>”"`; when the label isn't found the built-in fact stays and a fact note `"Learnt position not found (after “<label>”)"` is shown and the fact is `.needsReview`.
  - Drafts: `.confirmFigureRemembering(field, value)` fixes the fact (as `.confirmFigure`) and, when `label(for:)` finds a label and the item has an issuer key, adds a `figurePosition` draft; when no label is found the preview says "Couldn't find where this figure sits: it is fixed for this document only".

- [ ] **Step 1: Write the failing tests**

```swift
func testLabelBeforeAmount() { /* "Valor a pagar: 42,10 €" , money(4210, .eur) → ("Valor a pagar", 0) */ }
func testSecondOccurrence() { /* two "Total:" lines, value after the second → occurrence 1 */ }
func testReadUsesLearntPositionOverBuiltIn() async throws { }
func testMissingLabelFallsBackAndSaysSo() async throws { }
func testValueIsNeverLearnt() async throws { /* the stored action JSON contains no "4210" */ }
```

- [ ] **Step 2: Run** `--filter LearntFiguresTests` — Expected: FAIL.
- [ ] **Step 3: Implement**.
- [ ] **Step 4: Run** — Expected: PASS.
- [ ] **Step 5: Commit** `git commit -m "Import: remember where a figure sits for an issuer"`

---

### Task 4: On-device model reader (protocol, Foundation Models session, availability)

**Files:**
- Create: `Sources/BudgetCore/DocumentImport/DocumentModelReader.swift`
- Test: `Tests/BudgetCoreTests/DocumentModelReaderTests.swift`

**Interfaces:**
- Consumes: `FoundationModels` (`LanguageModelSession`, `SystemLanguageModel.default.availability`, `@Generable`, `@Guide`), pattern of `OnDeviceCategorizer`.
- Produces:
  - `public struct DocumentModelGuess: Equatable, Sendable { kind: DocumentKind?; issuer: String?; docDate: Date?; amountMinorUnits: Int?; currency: Currency?; reference: String? }`
  - `public protocol DocumentModelReading: Sendable { func availability() -> DocumentModelAvailability; func read(text: String, fileName: String, kinds: [DocumentKind]) async throws -> DocumentModelGuess? }`
  - `public enum DocumentModelAvailability: Equatable, Sendable { case available; case unavailable(String) }` — messages (exact): Apple Intelligence off → `"On-device model unavailable: Apple Intelligence is turned off"`; device not eligible → `"On-device model unavailable on this Mac"`; model not ready → `"On-device model is still downloading"`; other → `"On-device model unavailable"`.
  - `@Generable struct DocumentGuessSchema { kind: String /* one of the given kind names, or "other" */; issuer: String; documentDate: String /* yyyy-MM-dd or empty */; amount: String /* "1234.56" or empty */; currency: String /* EUR, GBP or empty */; reference: String }` (internal).
  - `public final class FoundationModelsDocumentReader: DocumentModelReading` — one `LanguageModelSession` per call; prompt lists `kinds.map(\.displayName)`; text cut to 6,000 characters; converts the schema to `DocumentModelGuess` field by field (unknown kind name, unparseable date/amount/currency → nil for that field).
  - `public static func guess(from schema: DocumentGuessSchema, kinds: [DocumentKind]) -> DocumentModelGuess` (internal, unit-tested).

- [ ] **Step 1: Write the failing tests** — `guess(from:)` conversions: `"Insurance receipt"` → `.insuranceReceipt`; `"Holiday photo"` → nil kind; `"2026-02-30"` → nil date; `"1.234,56"` and `"1234.56"` → 123456; `"USD"` → nil currency. (The real session is not called in tests.)
- [ ] **Step 2: Run** `--filter DocumentModelReaderTests` — Expected: FAIL.
- [ ] **Step 3: Implement**.
- [ ] **Step 4: Run** — Expected: PASS.
- [ ] **Step 5: Commit** `git commit -m "Import: on-device model reader with availability"`

---

### Task 5: The model in the pipeline — propose only, never Ready

**Files:**
- Modify: `Sources/BudgetCore/DocumentImport/ImportPipeline.swift` (`modelReader: (any DocumentModelReading)?` in `init`)
- Modify: `Sources/BudgetCore/DocumentImport/ImportModel.swift` (`ImportIssueKind.confirmModelReading`, `ImportResolution.acceptModelReading`)
- Modify: `Sources/BudgetCore/DocumentImport/ImportResolutions.swift`, `ImportLearning.swift`
- Test: `Tests/BudgetCoreTests/ImportModelProposalTests.swift`

**Interfaces:**
- Consumes: Tasks 2–4.
- Produces:
  - After detection and learnt rules, items still `.unknown` or `.evidence(.other)` with non-empty text go to the model (≤ 2 concurrent, 20 s timeout → treated as no answer). A guess sets `recognition` (`.needsReview`, reason `"Proposed by the on-device model"`), facts with source `.model`, and issue `confirmModelReading` (reason `"Check what the on-device model read"`). Unavailable → issue `unknownKind` with the availability message as reason.
  - `.acceptModelReading` → every `.model` fact and the recognition become `.user`/`.certain`, the issue resolves, and drafts for `documentKind` and `issuer` are added (Task 2). Correcting any field instead (`.chooseKind`, `.confirmFigure…`, `.setIssuer`) also resolves it field by field; the item leaves Needs you only when no `.model` fact remains.
  - Progress shows `"Asking the on-device model about <file>"` as `currentFile`.

- [ ] **Step 1: Write the failing tests** (stub `DocumentModelReading`)

```swift
func testModelGuessIsNeedsYouNeverReady() async throws { /* stub returns a full guess → section .needsYou, issue .confirmModelReading */ }
func testAcceptingModelReadingReadiesAndLearns() async throws { /* after accept + apply: documentKind and issuer rules exist */ }
func testMalformedModelAnswerKeepsOnlyValidFields() async throws { /* stub schema with bad date and unknown kind → facts only amount; recognition still .unknown */ }
func testUnavailableModelSaysWhy() async throws { /* availability .unavailable("On-device model unavailable: Apple Intelligence is turned off") → issue reason equal */ }
func testRecognisedDocumentsNeverReachTheModel() async throws { /* stub counts calls; P60 + receipt → 0 calls */ }
```

- [ ] **Step 2: Run** `--filter ImportModelProposalTests` — Expected: FAIL.
- [ ] **Step 3: Implement**.
- [ ] **Step 4: Run** — Expected: PASS.
- [ ] **Step 5: Commit** `git commit -m "Import: on-device model proposals for unknown documents"`

---

### Task 6: Learnt rules on the Rules page

**Files:**
- Create: `Sources/BudgetCore/DocumentImport/ImportRuleEditing.swift`
- Create: `App/Rules/ImportRulesTab.swift`
- Modify: `App/Rules/RulesView.swift` (ScreenTabs "Transaction rules" / "Import rules"), `App/Rules/RulesViewModel.swift`
- Modify: `App/Snapshots/SnapshotCatalog.swift`, `Sources/BudgetDemo/DemoDatabase.swift` (three demo import rules)
- Test: `Tests/BudgetCoreTests/ImportRuleEditingTests.swift`

**Interfaces:**
- Consumes: Tasks 1–3; plan 2 `ImportRuleStore`; `ScreenTabs(_:selection:tabs:label:)`.
- Produces:
  - `public struct ImportRuleRow: Equatable, Identifiable, Sendable { id: Int64; kind: ImportRuleKind; kindLabel: String /* "Document type", "Issuer name", "Link", "Figure position", "Statement account" */; when: String; then: String; useCount: Int; lastUsedAt: Date?; isEnabled: Bool; targetMissing: Bool }`
  - `public enum ImportRuleEditing { public static func rows(db: Database) throws -> [ImportRuleRow]; public static func setEnabled(db: Database, id: Int64, _ enabled: Bool) throws; public static func delete(db: Database, id: Int64) throws; public static func update(db: Database, id: Int64, actionJSON: String, actionLabel: String) throws }` — `targetMissing` when an action's account, property, tenancy or other entity no longer exists; such rules are skipped by every applier (Tasks 2–3, plan 2's account rule).
  - `ImportRulesTab`: a `Table` with the same column look as transaction rules ("Kind", "When", "Then", "Used" (`"12 × · 3 Oct"` with `.figureText()`), "On" toggle); context menu "Edit Rule…" (sheet with a picker suited to the kind: document kind, issuer name text, link target picker, figure label text, account picker) and "Delete"; `StatusPill("Target missing", tone: .warning)` in "Then" when `targetMissing`; empty state copy from Global Constraints. Search filters "When" and "Then".
  - Snapshot route `rules-import` (Rules page, Import rules tab, demo rules: a document type, a link, a statement account).

- [ ] **Step 1: Write the failing tests**

```swift
func testRowsDescribeEachKind() throws { /* kindLabel/when/then strings for each of the five kinds */ }
func testRuleWithMissingTargetIsSkippedAndFlagged() throws { /* statementAccount rule to a deleted account → targetMissing true; ImportRuleStore-based applier ignores it */ }
func testDeleteAndDisable() throws { }
```

- [ ] **Step 2: Run** `--filter ImportRuleEditingTests` — Expected: FAIL.
- [ ] **Step 3: Implement** Core, then the tab, view-model methods (`importRules`, `setEnabled`, `delete`, `update`) and the route.
- [ ] **Step 4: Run** tests (PASS), build (no warnings), `scripts/render-snapshots.sh <scratch>/snaps-imp3 --only rules-main,rules-import --size 1100x700` — no wrap-probe findings.
- [ ] **Step 5: Commit** `git commit -m "Rules page: learnt import rules (edit, disable, delete)"`

---

### Task 7: App — learnt rules and model readings in the review

**Files:**
- Modify: `App/DocumentImport/ImportPreviewPanel.swift`, `App/DocumentImport/ImportIssueControls.swift`, `App/AppEnvironment.swift` (pipeline gets `FoundationModelsDocumentReader()`; snapshot mode passes `nil`)
- Modify: `App/Snapshots/SnapshotCatalog.swift`

**Interfaces:**
- Consumes: Tasks 2–6.
- Produces:
  - Preview: a "Learnt rules used" list (`ImportRuleUse.label`, each with "Show on Rules page" navigating to Rules ▸ Import rules); a figure's source pill "Learnt" / "Model"; "Will remember: …" lines for the item's `ruleDrafts`.
  - Figure editor: a "Remember for this issuer" checkbox (resolves with `.confirmFigureRemembering`), shown only when the item has an issuer key.
  - Issuer field: editable name (`.setIssuer`).
  - `confirmModelReading`: the model's fields in a small table with "Use these" (`.acceptModelReading`) and per-field edit; the availability message as `InlineBanner(.info)` when the model is unavailable.
  - Snapshot route `imports-review_model` uses a stub reader returning a fixed guess for `Letter.pdf` (snapshot mode only).

- [ ] **Step 1: Build** — Expected: FAIL until implemented.
- [ ] **Step 2: Implement**.
- [ ] **Step 3: Build** (no warnings); `scripts/render-snapshots.sh <scratch>/snaps-imp3 --only imports-review_model --size 1100x700` — PNGs written, no wrap findings.
- [ ] **Step 4: Commit** `git commit -m "Imports: learnt rules and model readings in the review"`

---

### Task 8: Final verification, merge and install (controller)

- [ ] Full test suite; Debug and Release builds without warnings; `lsregister -u`.
- [ ] Whole-branch review against "Learning", "On-device AI" and Call 4.
- [ ] Merge; `xcodegen generate`; `scripts/install-app.sh`; do not push.

## Self-review

- Spec coverage: learning type, issuer, links, accounts (plan 2), figure positions with "remember for this issuer" (Tasks 1–3); the preview shows the rule used (7); all learnt rules on the Rules page, consistent look, edit/disable/delete (6); on-device model for unknowns, propose only, confirmation becomes a rule, availability fallback (4–5, 7). "Its category" in the spec's list of corrections is the document's kind for documents (Task 2); transaction categories stay with the Uncategorized screen and its existing rules.
- Types: `ImportRuleKind`, `ImportRuleStore`, `ImportResolution` additions and `ImportItem.appliedRules/ruleDrafts` are used with these names in plan 4 (none needed there).
- Review Focus lines pinned in Tasks 1, 2, 3, 5, 6.
