# Import documents 2 — Bank statements through the importer — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Every supported bank statement — BBVA Portugal "EXTRATO GLOBAL" PDFs (current account, mortgage instalments split into interest and capital, fund subscriptions and value, balances chained) and UK CSV/PDF statements — imports through the one importer, with statement problems as Needs-you items (balance mismatch with import-anyway and a reason, possible duplicate rows keep/skip, unparsed lines, unknown layout opening the mapping step inside the review, unknown account chosen and learnt).

**Architecture:** BBVA logic now buried in the one-off `BBVAEarlierHistoryImport.apply` is split into reusable pure/`db` functions (`BBVAStatementLegs`) that both the old tool and a new `BBVAStatementReader` use. A statement becomes a parent `ImportItem` (effect `.bbvaStatement` or `.ukStatement`) with child items for its row-level questions; statements of one account are always re-proposed together so their balance checks chain. A first, generic learnt-rule store (`importRule`, kind `statementAccount`) remembers the account chosen for a file signature; plan 3 adds the other kinds. Saved category rules still categorise at import; everything else lands in Uncategorized.

**Tech Stack:** Swift 5.10, BudgetCore + GRDB, CoreGraphics PDF (`PDFGlyphTextExtractor`), SwiftUI (macOS 26), XCTest.

**Spec:** `docs/superpowers/specs/2026-10-20-document-import-design.md` (Goals 5 and 7, "Statements", Calls 3 and 6). Builds on `docs/superpowers/plans/2026-10-20-import-1-core-and-review.md` (read its Interfaces: `ImportItem`, `ImportIssueKind.statement(StatementIssue)`, `ImportResolution`, `ImportEffect`, `ImportEffects.perform`, `ImportApplier`, `ImportPipeline.resolve`, `UKStatementReader`, `ImportCenterModel`, `ImportIssueControls`).

## Global Constraints

- Everything in plan 1's Global Constraints applies (scratch suffix `-imp2`: `swift test --scratch-path <scratch>/build-imp2`, derived data `<scratch>/dd-imp2.noindex`, snapshots `<scratch>/snaps-imp2`).
- A statement only **adds** transactions. Categories at import: saved rules (`RuleMatcher`), transfer legs and manual-entry replacements only (`ImportCoordinator.Categorization.rulesOnly`); no history or model suggestions, no `RuleLearner` learning; everything else is saved uncategorised (`.pendingReview`) for the Uncategorized screen.
- Overlaps add only what is missing: a row whose fingerprint (with occurrence index, `TransactionFingerprint.computeAll`) is already saved on the account is a certain duplicate, skipped and counted.
- A "possible duplicate" row (exact definition, pinned): not a certain duplicate and not a manual-entry replacement, and the account has a saved non-manual row from **another** import batch with the same amount, dated within ±2 days, whose description differs, and that no other staged row of the batch already claims.
- Balance mismatch: import anyway only with a non-empty reason (trimmed); the reason is stored in `importRun.reasonsJSON` under the statement item's title, and the mismatch is recorded on the account as today (`StatementCheck.finish`, `addAdjustment: false`).
- Learnt account choices are written only at Confirm import, inside the run (so Undo removes them).
- BBVA account names stay those of the existing constants (`BBVAHistoryImport.accountName`, `BBVAFundMortgageImport.loanAccountName` / `.fundAccountName`, `.interestCategoryName`); they are fallbacks, never required.
- `BBVAEarlierHistoryImportTests`, `BBVAFundMortgageImportTests` and `BBVAHistoryImportTests` must pass unchanged after the refactor.

## Review Focus

1. **The same BBVA month dropped again after it was imported** — no new rows, no second interest row on the loan, no second market movement on the fund; the item is a Duplicate ("Already imported: 38 rows"). Pinned in Task 4 (`testReimportingSameMonthAddsNothing`).
2. **Two consecutive statements of one account in one batch, the first left out** — the second's balance check is recomputed without the first's rows (and fails), instead of keeping the check from when both were in. Pinned in Task 5 (`testLeavingOutEarlierStatementRechecksLaterOne`).
3. **Import anyway with a reason of only spaces** — refused; the item stays in Needs you. Pinned in Task 5 (`testImportAnywayNeedsANonBlankReason`).
4. **A UK CSV with no account number dropped twice from different downloads** — the account chosen the first time is used the second time, and the preview names the remembered choice. Pinned in Task 6 (`testChosenAccountIsRememberedForTheSameSignature`).
5. **A mortgage instalment whose debit is on the statement but whose COBRANÇAS EFECTUADAS receipt is missing (or the reverse)** — Needs you on the statement with that instalment named, never a silent transfer without interest. Pinned in Task 3 (`testInstalmentWithoutReceiptIsAnIssue`).

---

### Task 1: Learnt-rule store with the statement-account kind

**Files:**
- Create: `Sources/BudgetCore/DocumentImport/ImportRule.swift`
- Modify: `Sources/BudgetCore/Database/DatabaseManager.swift` (append `registerImportRuleMigration(&migrator)` last)
- Test: `Tests/BudgetCoreTests/ImportRuleStoreTests.swift`

**Interfaces:**
- Consumes: plan 1 `ImportChangeCapture` (table is tracked automatically).
- Produces:
  - `public enum ImportRuleKind: String, Codable, CaseIterable, Sendable { case statementAccount }` (plan 3 adds `documentKind`, `issuer`, `link`, `figurePosition`).
  - `public struct ImportRule: Codable, Equatable, Identifiable, FetchableRecord, MutablePersistableRecord, Sendable` — table `importRule`: `id: Int64?`, `kind: ImportRuleKind`, `matchKey: String`, `matchLabel: String` (shown: "CSV with columns Date, Description, Amount"), `actionJSON: String`, `actionLabel: String` (shown: "Account: Everyday Current"), `isEnabled: Bool` (default true), `createdAt: Date`, `lastUsedAt: Date?`, `useCount: Int`. Unique `(kind, matchKey)`.
  - `public enum ImportRuleStore { public static func rule(db: Database, kind: ImportRuleKind, key: String) throws -> ImportRule?` (enabled only)`; public static func learn(db: Database, kind: ImportRuleKind, key: String, matchLabel: String, action: some Encodable, actionLabel: String, now: Date) throws -> ImportRule` (upsert by kind+key, re-enables)`; public static func markUsed(db: Database, ids: [Int64], now: Date) throws; public static func all(db: Database) throws -> [ImportRule] }`
  - `public struct StatementAccountAction: Codable, Equatable, Sendable { public var accountId: Int64 }`
  - `public enum StatementSignature { public static func key(for file: ImportFile, kind: ImportKind) -> (key: String, label: String)? }` — CSV: `"csv:" + normalised header row (lowercased, trimmed cells joined by "|")`, label `"CSV with columns <cells joined by ", ">"`; PDF: `"pdf:" + first two non-empty lines with digits removed, normalised`, label `"PDF starting “<first line>”"`; BBVA: `"bbva:<current account digits>"`, label `"BBVA statement of account …<last 4 digits>"`.

- [ ] **Step 1: Write the failing tests**

```swift
func testLearnUpsertsByKindAndKey() throws { /* learn twice same key, other account → 1 row, action accountId == second */ }
func testDisabledRuleIsNotReturned() throws { }
func testCSVSignatureIgnoresRowsAndCase() { /* "Date,Description,Amount\n…" vs "DATE, description ,amount\n…other rows" → same key */ }
func testMarkUsedCountsAndStamps() throws { }
```

- [ ] **Step 2: Run** `swift test --scratch-path <scratch>/build-imp2 --filter ImportRuleStoreTests` — Expected: FAIL.
- [ ] **Step 3: Implement** the record, migration `"createImportRule"`, store and signature.
- [ ] **Step 4: Run** — Expected: PASS.
- [ ] **Step 5: Commit** `git commit -m "Import: learnt-rule store, statement-account kind"`

---

### Task 2: Shared BBVA legs (refactor of the earlier-history import)

**Files:**
- Create: `Sources/BudgetCore/Import/BBVAStatementLegs.swift`
- Modify: `Sources/BudgetCore/Import/BBVAEarlierHistoryImport.swift` (steps 6–7 of `apply` call the new functions)
- Test: `Tests/BudgetCoreTests/BBVAStatementLegsTests.swift`

**Interfaces:**
- Consumes: `BBVAStatementParser.Statement/LoanReceipt/FundMovement`, `ManualTransactions.addOtherSide(db:transactionId:accountId:)`, `ManualTransactions.add(db:accountId:date:description:amountMinorUnits:categoryId:note:allowBuiltIn:)`, `BBVAFundMortgageImport.ResolvedInstalment/note(for:)/isSubscription/instalmentRulePattern`, `BuiltInCategories.category(db:role: .marketMovement)`.
- Produces (`public enum BBVAStatementLegs`):
  - `public struct InstalmentMatch: Equatable, Sendable { public let movementIndex: Int; public let receipt: BBVAStatementParser.LoanReceipt }` and `public static func matchInstalments(movements: [BBVAStatementParser.Movement], receipts: [BBVAStatementParser.LoanReceipt]) -> (matches: [InstalmentMatch], movementsWithoutReceipt: [Int], receiptsWithoutMovement: [BBVAStatementParser.LoanReceipt])` — a movement is an instalment when its description matches `instalmentRulePattern`; pairs by `operationDate == movement.date && -totalMinorUnits == amount`.
  - `public struct FundPair: Equatable, Sendable { public let movementIndex: Int; public let fundMovement: BBVAStatementParser.FundMovement }` and `public static func pairFundMovements(movements: [BBVAStatementParser.Movement], fund: BBVAStatementParser.Fund?, pairingDays: Int = BBVAEarlierHistoryImport.fundPairingDays) -> (pairs: [FundPair], unpairedSubscriptions: [Int], unpairedFundMovements: [BBVAStatementParser.FundMovement])` — closest date wins, as today.
  - `public static func charges(_ receipt: BBVAStatementParser.LoanReceipt) -> Int` (interest + fees + late interest + taxes).
  - `@discardableResult public static func addInstalment(db: Database, instalmentRowId: Int64, receipt: BBVAStatementParser.LoanReceipt, loanAccountId: Int64, interestCategoryId: Int64) throws -> (leg: Transaction, interest: Transaction?)` — the leg on the loan and the "Mortgage interest (instalment N)" row with the note `BBVAFundMortgageImport.note(for:)`.
  - `@discardableResult public static func addFundSubscription(db: Database, subscriptionRowId: Int64, fundAccountId: Int64) throws -> Transaction`
  - `public static func marketMovement(db: Database, fundAccountId: Int64, statement: BBVAStatementParser.Statement, since openingDay: Date?, openingMinorUnits: Int?) throws -> Transaction?` — the Market movement on `periodEnd` that makes the fund's balance equal the statement's value; nil when it already equals it, or when a Market movement already exists on that account and day.

- [ ] **Step 1: Write the failing tests** — pure matching (`matchInstalments` on synthetic movements and receipts: one paired, one movement without receipt, one receipt without movement), `pairFundMovements` (closest day of two candidates), and a db test that `addInstalment` writes the loan leg of +total (the other side of the −total debit) and an interest row of −charges in Mortgage interest, so the loan moves by +capital.
- [ ] **Step 2: Run** `--filter BBVAStatementLegsTests` — Expected: FAIL.
- [ ] **Step 3: Implement** `BBVAStatementLegs`, then make `BBVAEarlierHistoryImport.apply` call `matchInstalments` / `addInstalment` / `pairFundMovements` / `addFundSubscription` / `marketMovement` with the same error messages it throws today.
- [ ] **Step 4: Run** `--filter BBVA` — Expected: PASS, including the unchanged earlier-history, fund/mortgage and history tests.
- [ ] **Step 5: Commit** `git commit -m "BBVA: shared statement legs (instalments, fund, market movement)"`

---

### Task 3: BBVA EXTRATO GLOBAL reader

**Files:**
- Create: `Sources/BudgetCore/DocumentImport/Readers/BBVAStatementReader.swift`
- Modify: `Sources/BudgetCore/DocumentImport/ImportModel.swift` (new effect and issue cases)
- Modify: `Sources/BudgetCore/DocumentImport/ImportDetector.swift` (BBVA recogniser first)
- Modify: `Sources/BudgetCore/DocumentImport/ImportReader.swift` (`defaultReaders` gains `BBVAStatementReader()` before `UKStatementReader`)
- Test: `Tests/BudgetCoreTests/BBVAStatementReaderTests.swift`

**Interfaces:**
- Consumes: Tasks 1–2; plan 1 `ImportReader`, `ImportContext`, `ImportItem`, `ImportNaming.placement`; `BBVAStatementParser.parse`, `PDFGlyphTextExtractor.text(of:maxPages:)`, `TransactionFingerprint.computeAll`, `RuleMatcher.match`, `TransferCategories.category(db:forAccountId:)`, `Properties.accounts(db:propertyId:role:)`, `StatementCheck.compare`.
- Produces:
  - Recogniser: a PDF whose text contains `"EXTRATO"`, `"BBVA"` and `"PERÍODO DE"` (accent-insensitive) → `.bbvaStatement`, certain, reason `"BBVA extrato global <yyyy-MM>"`. The reader re-reads text with `PDFGlyphTextExtractor.text(of:maxPages: 50)`.
  - `public enum StatementAccountRole: String, Codable, Sendable { case current, mortgage, fund }`
  - `StatementIssue` gains: `case unknownLinkedAccount(StatementAccountRole)`, `case possibleDuplicate(existingTransactionId: Int64, existingLabel: String)`, `case instalmentMismatch(String)`, `case fundMismatch(String)`, `case remap(format: ImportFormat, accountId: Int64)` (used by plan 4's "Edit column mapping…").
  - `ImportResolution` gains: `case chooseAccount(StatementAccountRole, Int64)`, `case importAnyway(reason: String)`, `case keepRow`, `case skipRow`, `case saveProfile(ImportProfile)`.
  - `public struct BBVAStatementEffect: Equatable, Sendable { public var statement: BBVAStatementParser.Statement; public var currentAccountId: Int64; public var loanAccountId: Int64?; public var fundAccountId: Int64?; public var staged: [StagedTransaction]; public var instalments: [BBVAStatementLegs.InstalmentMatch]; public var fundPairs: [BBVAStatementLegs.FundPair]; public var closing: StatementClosing; public var sourceFileName: String; public var learnAccounts: [StatementAccountRole: Int64] }` and `ImportEffect.bbvaStatement(BBVAStatementEffect)` (`mayChangeTaxFigures` true).
  - `public struct BBVAStatementReader: ImportReader` — per statement:
    - accounts: current = learnt `statementAccount` rule for `"bbva:<digits>"`, else the account whose IBAN/account-number digits end with the statement's account digits, else the account named `BBVAHistoryImport.accountName`, else issue `unknownAccount`; mortgage = rule `"bbva-mortgage:<digits>"`, else the `.mortgage` account of the property whose `.current` account is the current one, else the account named `loanAccountName`, else `unknownLinkedAccount(.mortgage)` — only when the statement has loan receipts; fund likewise (`"bbva-fund:<fund.account>"`, `fundAccountName`) — only when it has a fund.
    - rows: every movement; certain duplicates removed (counted on a child duplicate item `"Already imported: <n> rows"`); when **all** rows are certain duplicates the statement itself is a Duplicate (`.transactions`, `"Already imported: <n> rows"`).
    - categories: instalment rows → the loan's transfer category; paired subscription rows → the fund's; others `RuleMatcher.match` or none (source `.rule` / `.none`).
    - legs: `matchInstalments` and `pairFundMovements` on the **new** rows only; any `movementsWithoutReceipt` / `receiptsWithoutMovement` → `instalmentMismatch("Instalment of <date> <amount> has no settled receipt on the statement")` / `("Receipt <n> (<date>) has no instalment debit")`; unpaired fund movements or subscriptions → `fundMismatch(…)`.
    - unread lines (`statement.unreadLines`) → `unparsedLines`.
    - title `"BBVA statement <yyyy-MM>"`; facts: period, opening, closing, rows (text layer); group summary `"<n> BBVA statement(s) <first month>–<last month> → <rows> transactions"`.
    - preview lines (item facts of `.text`): `"<k> instalment(s): interest <sum>, capital <sum>"`, `"Fund: +<subscriptions>, value <closing value>"`.

- [ ] **Step 1: Write the failing tests** (synthetic statement text as `BBVAStatementParserTests` builds it; db fixture with BBVA, BBVA mortgage, BBVA retirement fund accounts and their transfer categories)

```swift
func testStatementIsReadyWithRowsLegsAndClosing() throws { /* section .ready; effect staged.count == movements; instalments.count == 1; fundPairs.count == 1 */ }
func testRuleCategorisesAndOthersStayUncategorised() throws { }
func testInstalmentWithoutReceiptIsAnIssue() throws {
    // movement "COBR REC TOT …" −812.53 on 2026-02-05, no COBRANÇAS EFECTUADAS receipt
    // issue kind .statement(.instalmentMismatch("Instalment of 05/02/2026 −€812.53 has no settled receipt on the statement")); section .needsYou
}
func testAccountFoundByIBANDigits() throws { }
func testUnknownMortgageAccountAsksOnlyWhenThereAreReceipts() throws { }
```

- [ ] **Step 2: Run** `--filter BBVAStatementReaderTests` — Expected: FAIL.
- [ ] **Step 3: Implement** the cases, recogniser and reader.
- [ ] **Step 4: Run** — Expected: PASS; plan 1's `ImportDetectorTests` still pass (BBVA rule placed first).
- [ ] **Step 5: Commit** `git commit -m "Import: BBVA extrato global reader"`

---

### Task 4: Applying BBVA statements

**Files:**
- Modify: `Sources/BudgetCore/DocumentImport/ImportEffects.swift` (`.bbvaStatement`)
- Modify: `Sources/BudgetCore/DocumentImport/ImportApplier.swift` (statements of an account in date order; learnt accounts)
- Test: `Tests/BudgetCoreTests/BBVAStatementApplyTests.swift`

**Interfaces:**
- Consumes: Tasks 1–3; `ImportCoordinator.commit(db:accountId:sourceFileName:staged:decisions:statement:importRunId:)`, `StatementFinish(closing:addAdjustment: false)`, `BBVAStatementLegs.addInstalment/addFundSubscription/marketMovement`, `ImportRuleStore.learn`.
- Produces: `ImportEffects.perform(db:_:documentId:importRunId:)` for `.bbvaStatement`: commit the staged rows on the current account (source file name `"BBVA extrato <yyyy-MM>"`, decisions = suggestions, `learnRule: false`), find the saved rows by fingerprint, `addInstalment` per match, `addFundSubscription` per pair, then `marketMovement` for the fund; `StatementCheck.compare` on the loan (`-receipt.outstandingAfterMinorUnits` of the last receipt) — a difference throws `ImportApplyError.planOutdated("BBVA mortgage balance …")`. Each entry of `learnAccounts` is learnt with `ImportRuleStore.learn(kind: .statementAccount, …)`. Statement items of one account are applied in `periodStart` order.

- [ ] **Step 1: Write the failing tests**

```swift
func testApplyAddsRowsLegsInterestAndMarketMovement() throws {
    // after apply: BBVA rows = movements; loan has leg +total and interest −charges; fund balance at periodEnd == statement fund closing value
}
func testReimportingSameMonthAddsNothing() throws {
    // apply month; plan the same file again → item section .duplicates, of "Already imported: 3 rows"
    // and if forced through ImportEffects.perform with no new rows: no new loan or fund rows (market movement already exists)
}
func testOverlappingStatementAddsOnlyMissingRows() throws { /* statement covering 2 saved + 1 new row → 1 inserted */ }
func testUndoRemovesLegsAndInterestToo() throws { }
```

- [ ] **Step 2: Run** `--filter BBVAStatementApplyTests` — Expected: FAIL.
- [ ] **Step 3: Implement**.
- [ ] **Step 4: Run** — Expected: PASS.
- [ ] **Step 5: Commit** `git commit -m "Import: apply BBVA statements (rows, mortgage legs and interest, fund)"`

---

### Task 5: Statement checks and their resolutions (both banks)

**Files:**
- Create: `Sources/BudgetCore/DocumentImport/StatementChecks.swift`
- Modify: `Sources/BudgetCore/DocumentImport/Readers/UKStatementReader.swift`, `.../BBVAStatementReader.swift`
- Modify: `Sources/BudgetCore/DocumentImport/ImportPipeline.swift`, `ImportResolutions.swift`, `ImportApplier.swift`
- Test: `Tests/BudgetCoreTests/StatementChecksTests.swift`

**Interfaces:**
- Consumes: Tasks 1–4; plan 1 `ImportPipeline.resolve`, `ImportApplier.apply(_:entryPoint:reasons:now:)`.
- Produces:
  - `public enum StatementChecks { public static func recheck(_ items: [ImportItem], db: Database) throws -> [ImportItem] }` — for each account, its statement items not left out, in date order: closing via `StatementCheck.compare(db:accountId:closing:stagedRows: rows of this and earlier kept statements of the batch)`; `.mismatch` → issue `statement(.balanceMismatch)` (id `"balance-<account>-<date>"`), replaced (not duplicated) on every recheck; `.matches` removes it. Possible duplicates (Global Constraints definition) → one child item per row (`parentId` = statement, title `"<date> <description> <amount>"`, issue `statement(.possibleDuplicate(existingTransactionId:existingLabel:))`, reason `"Looks like “<existing description>” of <date> already saved"`).
  - `public enum ImportResolutionError: Error, Equatable { case reasonRequired }`.
  - `ImportResolution.importAnyway(reason:)` — trimmed reason empty → `ImportResolutionError.reasonRequired` (thrown by `ImportPipeline.resolve`); otherwise the issue is resolved and the reason kept on the item (`ImportItem.resolutionNote: String?`, new field) and passed by `ImportCenterModel.confirm` in `reasons`.
  - `.keepRow` / `.skipRow` on a child: keep → the row stays staged (forced with a free fingerprint via `ImportCoordinator.stageForcedDuplicates`); skip → removed from the parent's `staged`; both resolve the child; the parent's checks are rechecked.
  - Any resolution or Leave out touching a statement item re-runs `StatementChecks.recheck` for **all** statement items of that account.
  - A parent statement is Needs you while any of its children is.

- [ ] **Step 1: Write the failing tests**

```swift
func testMismatchedClosingIsNeedsYouAndImportAnywayWithReasonReadies() async throws { /* reasons passed to apply land in importRun.reasonsJSON */ }
func testImportAnywayNeedsANonBlankReason() async throws { /* resolve(.importAnyway(reason: "   ")) throws .reasonRequired; item still .needsYou */ }
func testPossibleDuplicateRowIsAChildNeedsYou() async throws { }
func testSkipRowDropsItAndRechecksBalance() async throws { }
func testLeavingOutEarlierStatementRechecksLaterOne() async throws {
    // Jan + Feb of one account, both matching; leave out Jan → Feb has .balanceMismatch
}
func testCertainDuplicatesAreNotPossibleDuplicates() async throws { }
```

- [ ] **Step 2: Run** `--filter StatementChecksTests` — Expected: FAIL.
- [ ] **Step 3: Implement**.
- [ ] **Step 4: Run** — Expected: PASS.
- [ ] **Step 5: Commit** `git commit -m "Import: statement balance checks, import anyway with reason, possible duplicate rows"`

---

### Task 6: Unknown account and unknown layout inside the review

**Files:**
- Modify: `Sources/BudgetCore/DocumentImport/Readers/UKStatementReader.swift`
- Modify: `Sources/BudgetCore/Import/ImportProfileStore.swift` (add `public static func save(db: Database, _ profile: ImportProfile) throws -> ImportProfile`; the instance method calls it)
- Modify: `Sources/BudgetCore/DocumentImport/ImportApplier.swift`
- Test: `Tests/BudgetCoreTests/StatementAccountLearningTests.swift`

**Interfaces:**
- Consumes: Tasks 1, 5; `StatementSignature.key`.
- Produces:
  - UK statements: account = intent, else learnt `statementAccount` rule for the file's signature (recognition reason `"Remembered: <matchLabel> → <account>"`, and the item lists the rule in its facts), else sort code/number match (plan 1), else `unknownAccount`. `.chooseAccount(.current, id)` re-proposes with that account and records `learnAccounts[.current] = id` on the effect (`UKStatementEffect.learnAccount: (key: String, label: String, accountId: Int64)?`, new field).
  - No profile → `noProfile(format:accountId:)`; `.saveProfile(profile)` re-proposes with that profile (not saved yet) and sets `UKStatementEffect.profileToSave: ImportProfile?` (new field); the applier saves it with `ImportProfileStore.save(db:)` before the rows.
  - Applier: learnt accounts and profiles are written inside the run (captured; undone by Undo).

- [ ] **Step 1: Write the failing tests**

```swift
func testChosenAccountIsRememberedForTheSameSignature() async throws {
    // file A (no account number) → .unknownAccount; resolve(.chooseAccount(.current, id)); apply
    // file B, same header, other rows → account id preselected; recognition.reason == "Remembered: CSV with columns Date, Description, Amount → Everyday Current"
}
func testSavedProfileIsWrittenOnlyAtConfirm() async throws { /* after .saveProfile: ImportProfile count unchanged; after apply: 1 */ }
func testUndoForgetsTheLearntAccount() async throws { }
```

- [ ] **Step 2: Run** `--filter StatementAccountLearningTests` — Expected: FAIL.
- [ ] **Step 3: Implement**.
- [ ] **Step 4: Run** — Expected: PASS.
- [ ] **Step 5: Commit** `git commit -m "Import: choose and remember a statement's account; mapping saved at confirm"`

---

### Task 7: App — statement items in the review (mapping step, account choice, rows, reasons)

**Files:**
- Modify: `App/DocumentImport/ImportIssueControls.swift`
- Modify: `App/DocumentImport/ImportPreviewPanel.swift`
- Modify: `App/DocumentImport/ImportReviewView.swift` (child rows indented under their statement)
- Modify: `App/DocumentImport/ImportCenterModel.swift` (reasons passed to `apply`)
- Modify: `App/Snapshots/SnapshotCatalog.swift`, `Sources/BudgetDemo/DemoImportSamples.swift`

**Interfaces:**
- Consumes: Tasks 3–6; existing `CSVMappingWizardView(account:csvText:existingProfile:onSave:)`, `PDFLayoutWizardView(account:sampleLines:onSave:)`.
- Produces:
  - Issue controls: `.balanceMismatch` — statement closing, computed balance and difference (`MoneyText`, `.figureText()`), a reason `TextField("Why import it anyway?")` and "Import anyway" (disabled while blank); `.possibleDuplicate` — "Keep" / "Skip" with the existing row's label; `.unparsedLines` — the lines (monospaced, scrolling, max 8 visible) and "Got it"; `.noProfile` / `.remap` — "Set up columns…" (CSV) or "Set up layout…" (PDF) opening the existing wizard as a sheet over the review, `onSave` → `resolve(.saveProfile(profile))`; `.unknownAccount` / `.unknownLinkedAccount` — account picker (accounts of the bank region first) with the caption "Remembered for files like this"; `.instalmentMismatch` / `.fundMismatch` — the message and Leave out only.
  - Preview for statements: period, opening → closing, rows new / already imported, legs lines, check result pill ("Balance matches" / "Balance differs").
  - Demo samples: add a synthetic BBVA-format statement for the demo's euro current account (one instalment, no fund) and a UK CSV for an account without a profile; routes `imports-review_statement` (BBVA statement selected) and `imports-review_mapping` (CSV without profile selected).

- [ ] **Step 1: Build** — Expected: FAIL until implemented.
- [ ] **Step 2: Implement** the controls, preview sections, child-row layout, samples and routes.
- [ ] **Step 3: Build** (no warnings), `swift test --filter DemoImportSamplesTests` (update its expected section counts), then `scripts/render-snapshots.sh <scratch>/snaps-imp2 --only imports-review_statement,imports-review_mapping --size 1100x700` — Expected: PNGs written, no wrap-probe findings for these routes.
- [ ] **Step 4: Commit** `git commit -m "Imports: statement items in the review (mapping, accounts, rows, import anyway)"`

---

### Task 8: Final verification, merge and install (controller)

- [ ] Full test suite; Debug and Release builds without warnings; `lsregister -u`.
- [ ] Dry run on a **copy** of the real database (never the original): plan one recent BBVA extrato from `~/Documents/Personal/Casa/Lisboa/BBVA/Extratos` and show the plan's sections (read-only; no apply) — report counts to the user.
- [ ] Whole-branch review; merge; `xcodegen generate`; `scripts/install-app.sh`; do not push.

## Self-review

- Spec coverage: BBVA in-app with current account, mortgage interest/capital legs, fund movements and value, chaining and overlap (Tasks 2–5); UK CSV/PDF (plan 1 Task 8 + Tasks 5–6); balance mismatch import-anyway with reason recorded (5); possible duplicates keep/skip (5); unparsed lines (plan 1 + 7); unknown layout → mapping step inside the review, reused next time (6–7); unknown account → choose, learnt (1, 6); saved rules still apply, rest Uncategorized (Global Constraints, 3, plan 1 Task 8).
- Types: `StatementIssue`, `ImportResolution`, `ImportEffect.bbvaStatement`, `ImportRuleStore` names match plans 1, 3 and 4.
- Review Focus lines pinned in Tasks 3, 4, 5, 6.
