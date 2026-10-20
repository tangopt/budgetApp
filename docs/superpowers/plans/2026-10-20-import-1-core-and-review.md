# Import documents 1 — Core pipeline and review — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** One import function in BudgetCore (detect → read → propose placement and links with explicit confidence and reasons → duplicate check at file, document and transaction level → plan) wrapping the existing readers, applied in one transaction as an undoable batch with a before/after change log and a filed-year guard, plus the review screen (option A), one global entry point and the batch history.

**Architecture:** A new `Sources/BudgetCore/DocumentImport/` module: `ImportFile` (bytes, hash, text) → `ImportDetector` (built-in recognisers in a fixed order) → one `ImportReader` per kind that turns its files into `ImportItem`s (facts, placement, links, an `ImportEffect`, issues) by calling the existing readers and planners → `ImportDuplicates` and `FiledYearGuard` annotate items → `ImportPlan` sorts them into Needs you / Ready / Duplicates skipped / Left out. `ImportApplier` performs the Ready items' effects through the existing guarded write paths inside one write transaction while `ImportChangeCapture` (temporary SQLite triggers) logs every row written into `importChange`; `ImportUndo` reverts a run from that log or refuses. The App only presents: an `ImportCenterModel` drives a new "Imports" sidebar screen (review or history), a File ▸ Import… command, a toolbar button and a window-wide drop target.

**Tech Stack:** Swift 5.10 package (BudgetCore, GRDB 6.29+), macOS 26 SwiftUI app generated with xcodegen, XCTest, PDFKit/Vision via the existing extractors.

**Spec:** `docs/superpowers/specs/2026-10-20-document-import-design.md` (read it whole, including "Calls made after the builder check" and the user's additions of 2026-10-20).

## Order of the four plans and their dependencies

1. **Plan 1 (this) — core and review.** Depends on nothing new. Ships the importer for documents and for UK statements of accounts that already have a saved profile; old import screens stay working beside it.
2. **Plan 2 — statements** (`2026-10-20-import-2-statements.md`). Depends on plan 1 (`ImportReader`, `ImportItem`, `ImportIssue`, `ImportApplier`, review screen). Adds BBVA EXTRATO GLOBAL, the statement Needs-you items, the mapping step inside the review, and creates the `importRule` store with its first kind (statement account).
3. **Plan 3 — learning and on-device AI** (`2026-10-20-import-3-learning-and-ai.md`). Depends on plans 1 and 2 (extends the `importRule` store plan 2 creates). Adds the other learnt kinds, "remember for this issuer", the Rules page section and the Foundation Models reader.
4. **Plan 4 — shortcuts** (`2026-10-20-import-4-shortcuts.md`). Depends on plans 1 and 2 (statement shortcuts need plan 2's statement handling; everything else needs only plan 1). Independent of plan 3. Replaces every import button with an `ImportIntent` shortcut and retires the old sheets and the old Import screen.

Execute in the order 1 → 2 → 3 → 4, each on its own branch, merged (and the app installed with `scripts/install-app.sh`) before the next starts.

## Global Constraints

- All detection, matching, planning, applying and undo logic lives in BudgetCore (future iOS/iPadOS clients); the App only presents and calls it.
- New migrations are appended last in `DatabaseManager.registerMigrations`; never edit an applied migration.
- Tests: XCTest in `Tests/BudgetCoreTests`, synthetic data only (no personal names, NIFs, account numbers or real documents; PDFs generated in tests with `EvidenceTestPDFs` / `PayrollFormTestPDFs`). Run `swift test --scratch-path <scratch>/build-imp1 [--filter <TestClass>]`.
- App build: `xcodegen generate && xcodebuild -project Budget.xcodeproj -scheme Budget -destination 'platform=macOS' -derivedDataPath <scratch>/dd-imp1.noindex build`; then `lsregister -u` the built app. Never run tests and builds at once; no warnings.
- UI is verified only through `scripts/render-snapshots.sh <scratch>/snaps-imp1 --only <routes> --size 1100x700` (demo database); agents never launch the app, never drive the screen.
- Never write `~/Library/Application Support/Budget` (tests, tools, snapshots); never push. Stage only `App/ Sources/ Tests/ project.yml Package.swift docs/`; commit trailer `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- Design system (spec 2026-10-18 UI polish §1, §6): `Panel`, `DataTable`, `StatusPill`, `InlineBanner`, `MoneyText`, `DateText`, `.figureText()` on every figure (no figure ever wraps), side panels docked beside lists, theme tokens only, fits the 1100×700 minimum window.
- Nothing is written before the user presses Confirm import. Anything below full confidence is Needs you, never Ready. Every placement and link carries a visible reason.
- Filed or paid tax years: an item that would change a figure on a filed return is held in Needs you and cannot be confirmed (its only resolution is Leave out); the whole batch is re-checked at apply and rolled back if any filed return figure moves.
- Performance: file reading runs off the main actor, at most 4 files at once, with progress; the review never recomputes the plan per render (the plan is a value held by the model, changed only by explicit resolutions).
- Copy (exact): section titles "Needs you", "Ready", "Duplicates skipped", "Left out"; button "Confirm import"; disabled help "Settle everything in Needs you first"; resolution "Leave out of this import"; menu item "Import…" (⇧⌘I); sidebar screen "Imports"; history title "Import history"; undo button "Undo import…".

## Review Focus

1. **A file dropped twice, or the same document saved as two files, in one batch** — the second is a Duplicate of the first (not two Ready items), even though neither is in the library yet. Pinned in Task 9 (`testSameDocumentTwiceInOneBatchIsOneReadyOneDuplicate`).
2. **Undo after the user has categorised one of the imported transactions** — undo refuses, names that transaction and writes nothing. Pinned in Task 3 (`testUndoRefusesWhenImportedTransactionWasCategorisedSince`).
3. **The apply transaction fails half-way (a guarded write throws)** — no rows, no run record, and no stored files left in the library for documents whose rows rolled back. Pinned in Task 13 (`testFailedApplyLeavesNoRowsAndNoOrphanFiles`).
4. **A scanned (image-only) receipt whose amount OCR misreads** — it is Needs you with "Read by text recognition" on the amount, never Ready, even when the misread amount happens to match a debit. Pinned in Task 7 (`testOCRAmountIsNeedsYouEvenWithConfidentMatch`).
5. **A folder dropped with hidden files, `.DS_Store`, Office lock files and nested folders** — only real files are read, recursively; ignored ones are counted, not imported. Pinned in Task 4 (`testCollectExpandsFoldersAndSkipsSystemFiles`).

---

### Task 1: Import runs, change log and file outcomes (migration)

**Files:**
- Create: `Sources/BudgetCore/DocumentImport/ImportRun.swift`
- Modify: `Sources/BudgetCore/Models/ImportBatch.swift` (add `importRunId`)
- Modify: `Sources/BudgetCore/Database/DatabaseManager.swift` (append `registerImportRunMigration(&migrator)` last)
- Test: `Tests/BudgetCoreTests/ImportRunTests.swift`

**Interfaces:**
- Consumes: nothing new.
- Produces:
  - `public struct ImportRun: Codable, Equatable, Identifiable, FetchableRecord, MutablePersistableRecord, Sendable` — table `importRun`: `id: Int64?`, `confirmedAt: Date`, `entryPoint: String`, `summary: String`, `backupPath: String?`, `reasonsJSON: String?` (JSON `[String: String]`, item title → user's reason, used by plan 2's import-anyway), `undoneAt: Date?`, `undoSummary: String?`.
  - `public enum ImportChangeOperation: String, Codable, Sendable { case insert, update, delete }`
  - `public struct ImportChange: Codable, Equatable, Identifiable, FetchableRecord, MutablePersistableRecord, Sendable` — table `importChange`: `id: Int64?`, `runId: Int64`, `seq: Int`, `tableName: String`, `rowId: Int64`, `operation: ImportChangeOperation`, `beforeJSON: String?`, `afterJSON: String?`. Index on `(tableName, rowId)`.
  - `public enum ImportFileOutcome: String, Codable, CaseIterable, Sendable { case filed, linked, recorded, duplicate, leftOut, transactions }`
  - `public struct ImportRunFile: Codable, Equatable, Identifiable, FetchableRecord, MutablePersistableRecord, Sendable` — table `importRunFile`: `id: Int64?`, `runId: Int64`, `fileName: String`, `sha256: String`, `documentId: Int64?`, `outcome: ImportFileOutcome`, `detail: String`.
  - `ImportBatch.importRunId: Int64?` (nullable column `importRunId` referencing `importRun`, `onDelete: .setNull`).
  - `func registerImportRunMigration(_ migrator: inout DatabaseMigrator)` — migration id `"createImportRun"`.

- [ ] **Step 1: Write the failing test**

```swift
final class ImportRunTests: XCTestCase {
    func testMigrationCreatesRunTablesAndBatchColumn() throws {
        let m = try DatabaseManager(path: nil); try m.migrate()
        try m.dbQueue.read { db in
            XCTAssertTrue(try db.tableExists("importRun"))
            XCTAssertTrue(try db.tableExists("importChange"))
            XCTAssertTrue(try db.tableExists("importRunFile"))
            XCTAssertTrue(try db.columns(in: "importBatch").contains { $0.name == "importRunId" })
        }
    }
    func testRunFileAndChangeRoundTrip() throws {
        // insert ImportRun(confirmedAt:, entryPoint: "Import…", summary: "1 document filed")
        // insert ImportRunFile(runId:, fileName: "a.pdf", sha256: "ab", documentId: nil, outcome: .filed, detail: "Filed as …")
        // insert ImportChange(runId:, seq: 1, tableName: "document", rowId: 7, operation: .insert, beforeJSON: nil, afterJSON: "{}")
        // XCTAssertEqual(fetched run.entryPoint, "Import…"); XCTAssertEqual(fetched change.operation, .insert)
    }
    func testExistingBatchesKeepNilRunId() throws {
        // migrate(upTo: last migration before createImportRun), insert an ImportBatch, migrate(); XCTAssertNil(batch.importRunId)
    }
}
```

- [ ] **Step 2: Run** `swift test --scratch-path <scratch>/build-imp1 --filter ImportRunTests` — Expected: FAIL (types not defined).
- [ ] **Step 3: Implement** the records and `registerImportRunMigration` in `ImportRun.swift`; add `importRunId` to `ImportBatch` (init parameter defaulting to `nil`).
- [ ] **Step 4: Run** the filter, then the whole suite — Expected: PASS (existing `ImportBatch(…)` call sites compile unchanged).
- [ ] **Step 5: Commit** `git commit -m "Import: runs, change log and file outcomes (migration)"`

---

### Task 2: Change capture with temporary triggers

**Files:**
- Create: `Sources/BudgetCore/DocumentImport/ImportChangeCapture.swift`
- Test: `Tests/BudgetCoreTests/ImportChangeCaptureTests.swift`

**Interfaces:**
- Consumes: `ImportChange`, `ImportChangeOperation` (Task 1).
- Produces:
  - `public enum ImportChangeCapture`
  - `static let untrackedTables: Set<String> = ["importRun", "importChange", "importRunFile", "forecastEntry", "forecastGroup", "grdb_migrations"]` (plus every `sqlite_%` table). Forecast tables are regenerated by `AutoForecastGenerator.refresh`, which only inserts.
  - `public static func begin(db: Database) throws` — creates `temp.importCapture(seq INTEGER PRIMARY KEY AUTOINCREMENT, tableName, rowId, op, beforeJSON, afterJSON)` and, for every tracked table, three `TEMP` triggers `importCapture_<table>_{ins,upd,del}` (AFTER INSERT/UPDATE/DELETE on `main.<table>`) inserting `json_object(...)` of every column (`NEW.`/`OLD.`; BLOB columns as `hex(col)`).
  - `public static func finish(db: Database, runId: Int64) throws -> [ImportChange]` — copies the captured rows into `importChange` (seq preserved) for `runId`, drops the triggers and the temp table, returns what it wrote.
  - `public static func cancel(db: Database) throws` — drops triggers and temp table without writing.
  - `public static func rowJSON(db: Database, table: String, rowId: Int64) throws -> String?` — the current row in the same JSON shape (for undo's comparisons).
  - `static func blobColumns(db: Database, table: String) throws -> Set<String>` (declared type `BLOB`).

- [ ] **Step 1: Write the failing tests**

```swift
func testCapturesInsertUpdateDeleteWithBeforeAndAfter() throws {
    // begin; insert a Category "Cap"; update its name to "Cap 2"; delete an existing rule; finish(runId:)
    // XCTAssertEqual(changes.map(\.operation), [.insert, .update, .delete])
    // insert: beforeJSON nil, afterJSON contains "\"name\":\"Cap\""
    // update: beforeJSON name "Cap", afterJSON name "Cap 2"
    // delete: beforeJSON has the rule's matchPattern, afterJSON nil
}
func testUntrackedTablesAreNotCaptured() throws {
    // begin; AutoForecastGenerator.refresh(db:) on a db with transactions; finish
    // XCTAssertTrue(changes.allSatisfy { !["forecastEntry", "forecastGroup"].contains($0.tableName) })
}
func testBlobColumnsAreHexEncoded() throws {
    // begin; insert SourceFolder(path: "/x", bookmark: Data([0xde, 0xad]), name: "x"); finish
    // XCTAssertTrue(change.afterJSON!.contains("\"bookmark\":\"DEAD\""))
}
func testFinishRemovesTriggersAndLaterWritesAreNotCaptured() throws {
    // begin; finish; insert another category
    // XCTAssertEqual(try ImportChange.fetchCount(db), changesBefore); XCTAssertEqual(temp triggers named importCapture_% count, 0)
}
```

- [ ] **Step 2: Run** `--filter ImportChangeCaptureTests` — Expected: FAIL.
- [ ] **Step 3: Implement** `ImportChangeCapture` (tables from `sqlite_master WHERE type = 'table'`, columns from `db.columns(in:)`).
- [ ] **Step 4: Run** — Expected: PASS.
- [ ] **Step 5: Commit** `git commit -m "Import: change capture with temporary triggers"`

---

### Task 3: Undo a run, or refuse

**Files:**
- Create: `Sources/BudgetCore/DocumentImport/ImportUndo.swift`
- Test: `Tests/BudgetCoreTests/ImportUndoTests.swift`

**Interfaces:**
- Consumes: `ImportChange`, `ImportRun`, `ImportChangeCapture.rowJSON` (Tasks 1–2); `EvidenceLibrary.fileURL(for:)`; `TaxFigures.snapshot/changes/isFiled`.
- Produces:
  - `public enum ImportUndoConflict: Equatable, Sendable { case changedSince(table: String, rowId: Int64, columns: [String]); case removedSince(table: String, rowId: Int64); case recreatedSince(table: String, rowId: Int64); case laterImport(runId: Int64, table: String, rowId: Int64); case dependsOnIt(table: String, rowId: Int64, dependent: String); case filedYear(FiledYearImpact) }` with `public var message: String` (e.g. `"Transaction 12 was changed since (category)"`; rows are described with `ImportUndo.describe(db:table:rowId:)` — a transaction as `"<date> <description> <amount>"`, a document by its canonical name or file name).
  - `public enum ImportUndoError: Error, Equatable { case refused([ImportUndoConflict]); case alreadyUndone; case runNotFound }`
  - `public struct ImportUndoResult: Equatable, Sendable { public var rowsRemoved: Int; public var rowsRestored: Int; public var filesRemoved: Int }`
  - `public static func conflicts(db: Database, runId: Int64) throws -> [ImportUndoConflict]`
  - `public static func undo(dbQueue: DatabaseQueue, library: EvidenceLibrary, runId: Int64, now: Date = Date()) throws -> ImportUndoResult` — one write; throws `.refused` with nothing written.
  - `static func netChanges(_ changes: [ImportChange]) -> [ImportChange]` — per (table,rowId): first `beforeJSON`, last `afterJSON`; insert…delete collapses to nothing; insert…update to insert; update…update to update.

Algorithm (fixed):
1. Net the run's changes. 2. Conflicts: an insert whose row is gone → `removedSince`; whose current JSON differs from `afterJSON` → `changedSince(columns)`. An update: row gone → `removedSince`; any column that differs between before and after and whose current value ≠ after → `changedSince`. A delete whose rowid exists again → `recreatedSince`. Any of these rows touched by a later, not-undone run → `laterImport` instead. A row outside this run's net inserts that references an inserted row — by a declared foreign key (`PRAGMA foreign_key_list` of every tracked table) or a `documentLink` whose `(entityType, entityId)` is an inserted row (entity type → table as in `EvidenceLinks.entityExists`) → `dependsOnIt`. Then, in a savepoint that is rolled back, revert and compare `TaxFigures.snapshot` before/after: any change of a field starting with `"SA "` in a year `TaxFigures.isFiled(_, includePaid: true)` → `filedYear`. 3. No conflicts: `PRAGMA defer_foreign_keys = ON`; walk net changes in descending seq: delete inserted rows, restore updated columns to `before`, re-insert deleted rows with their rowid. 4. Set `undoneAt`, `undoSummary` ("Removed 142 rows, restored 3"). 5. After commit, remove the stored file of every `document` row the undo deleted when no `document` row has that sha256 any more.

- [ ] **Step 1: Write the failing tests** (each builds a run by `ImportChangeCapture.begin` → writes → `finish`)

```swift
func testUndoRemovesInsertedRowsAndRestoresUpdatedOnes() throws {
    // run: insert a transaction + a documentLink to it; update an account's note
    // let result = try ImportUndo.undo(dbQueue:, library:, runId:)
    // XCTAssertEqual(result.rowsRemoved, 2); XCTAssertEqual(result.rowsRestored, 1)
    // transaction gone, link gone, account note back to before; run.undoneAt != nil
}
func testUndoRefusesWhenImportedTransactionWasCategorisedSince() throws {
    // run inserts a transaction (categoryId nil); afterwards set categoryId = groceries
    // XCTAssertThrowsError(try ImportUndo.undo(...)) { XCTAssertEqual($0 as? ImportUndoError,
    //     .refused([.changedSince(table: "transaction_", rowId: id, columns: ["categoryId", "categorizedBy", "status"])])) }
    // transaction still there (nothing written)
}
func testUndoRefusesWhenALaterRunTouchedTheSameRow() throws { /* second run updates the row → .laterImport(runId: 2, …) */ }
func testUndoRefusesWhenAnUnloggedRowDependsOnAnInsertedOne() throws { /* a documentLink to the inserted transaction added outside any run → .dependsOnIt(table: "transaction_", …, dependent: "documentLink …") */ }
func testUndoRemovesStoredFileOfDocumentItAdded() throws {
    // run: library.add(db:) a synthetic PDF; undo; XCTAssertFalse(FileManager.default.fileExists(atPath: stored.path))
}
func testUndoTwiceThrowsAlreadyUndone() throws { /* XCTAssertEqual(error, .alreadyUndone) */ }
func testNetChangesCollapseInsertThenDelete() { /* netChanges([insert r1, delete r1]) == [] */ }
```

- [ ] **Step 2: Run** `--filter ImportUndoTests` — Expected: FAIL.
- [ ] **Step 3: Implement** `ImportUndo` per the algorithm above.
- [ ] **Step 4: Run** — Expected: PASS.
- [ ] **Step 5: Commit** `git commit -m "Import: undo a run from its change log, or refuse"`

---

### Task 4: Import model types, file loading and folder collection

**Files:**
- Create: `Sources/BudgetCore/DocumentImport/ImportModel.swift` (types below)
- Create: `Sources/BudgetCore/DocumentImport/ImportFile.swift`
- Modify: `Sources/BudgetCore/Evidence/SourceFolderScanner.swift` (extract `static func ignoreReason(name: String, values: URLResourceValues) -> IgnoredFile.Reason?` from `list`, used by both)
- Test: `Tests/BudgetCoreTests/ImportModelTests.swift`

**Interfaces:**
- Consumes: `DocumentKind`, `DocumentTextStatus`, `EvidenceEntity`, `EvidenceTextExtractor`, `EvidenceOCR`, `EvidenceLibrary.sha256(of:)`.
- Produces:
  - `public struct ImportFile: Equatable, Sendable { url: URL; fileName: String; sha256: String; byteCount: Int64; fileExtension: String; text: String?; textStatus: DocumentTextStatus; usedOCR: Bool; sourceFolderId: Int64?; sourceRelativePath: String?; sourceModifiedAt: Date? }` and `public static func load(_ url: URL, ocr: Bool = true) throws -> ImportFile` (PDF/images: `UtilityInvoiceIntake.text(of:ocr:)`; `.csv`/`.txt`: UTF-8 else ISO Latin 1; `.xlsx` and others: no text, `.noText`).
  - `public enum ImportFileCollector { public static func collect(_ urls: [URL]) -> (files: [URL], ignored: [String]) }` — folders recursively, natural name order, ignoring what `SourceFolderScanner.ignoreReason` ignores.
  - `public enum ImportKind: Hashable, Codable, Sendable { case rentReceiptsExport, rentReceiptPDF, transferAdvice, utilityInvoice, payrollForm(PayrollFormKind), bankStatementCSV, bankStatementPDF, bbvaStatement, evidence(DocumentKind), unknown }` with `displayName` ("Rent receipts export", "Rent receipt", "Transfer advice", "Utility invoice", "P60"/"P45"/"P11D", "Bank statement (CSV)", "Bank statement (PDF)", "BBVA statement", the kind's `displayName`, "Unknown").
  - `public enum ImportConfidence: String, Codable, Sendable { case certain, needsReview }`
  - `public enum ImportFactSource: String, Codable, Sendable { case textLayer, ocr, fileName, intent, learntRule, model, user }` — `.ocr`, `.fileName`, `.model` are always `.needsReview`.
  - `public enum ImportFigureField: String, Codable, CaseIterable, Sendable { case docDate, amount, currency, periodStart, periodEnd, invoiceNumber, receiptNumber, reference, issuer, person, taxYear, pay, taxDeducted }`
  - `public enum ImportFactValue: Equatable, Codable, Sendable { case date(Date), money(Int, Currency), text(String), year(Int) }`
  - `public struct ImportFact: Equatable, Sendable { field; value: ImportFactValue; source: ImportFactSource; confidence: ImportConfidence; reason: String }`
  - `public struct ImportRecognition: Equatable, Sendable { kind: ImportKind; confidence: ImportConfidence; reason: String }`
  - `public struct ImportPlacement: Equatable, Sendable { metadata: EvidenceMetadata; canonicalName: String }`
  - `public struct ProposedLink: Equatable, Sendable { entity: EvidenceEntity; role: String?; label: String; confidence: ImportConfidence; reasons: [String]; madeByEffect: Bool }`
  - `public enum ImportTargetKind: String, Sendable { case property, person, account, tenancy }`
  - `public struct ImportIntent: Equatable, Sendable { expected: ImportKind?; propertyId: Int64?; personId: Int64?; accountId: Int64?; taxYear: Int?; target: ImportIntent.Target?; public static let none }` and `public struct Target: Equatable, Sendable { entity: EvidenceEntity; role: String?; replacing: [Int64] }` (plan 4 fills these).
  - `public enum ImportSection: String, CaseIterable, Sendable { case needsYou, ready, duplicates, leftOut }`
  - `public struct ImportDuplicate: Equatable, Sendable { public enum Level: String, Sendable { case file, document, transactions }; level; of: String /* what it duplicates, shown */ ; existingDocumentId: Int64? }`
  - `public struct ImportIssue: Equatable, Identifiable, Sendable { id: String; kind: ImportIssueKind; reason: String }`
  - `public enum ImportIssueKind: Equatable, Sendable { case unknownKind(proposed: DocumentKind?); case kindMismatch(expected: ImportKind, found: ImportKind); case confirmFigure(ImportFigureField); case missingFigure(ImportFigureField); case chooseLink([LinkCandidate]); case chooseTarget(ImportTargetKind, options: [Int64]); case readerProblem(String); case filedYear(FiledYearImpact); case statement(StatementIssue) }`
  - `public struct LinkCandidate: Equatable, Sendable { entity: EvidenceEntity; label: String; reasons: [String] }`
  - `public enum StatementIssue: Equatable, Sendable { case unknownAccount; case noProfile(format: ImportFormat, accountId: Int64); case balanceMismatch(StatementMismatch); case unparsedLines([String]) }` (plan 2 adds cases).
  - `public enum ImportResolution: Equatable, Sendable { case leaveOut; case chooseKind(DocumentKind); case chooseLink(EvidenceEntity); case fileWithoutLink; case confirmFigure(ImportFigureField, ImportFactValue); case chooseTarget(ImportTargetKind, Int64); case acknowledge }` (plan 2/3 add cases).
  - `public enum ImportEffect: Equatable, Sendable { case file; case rentReceiptsExport(propertyId: Int64, rows: [RentReceiptsExport.Row]); case rentReceiptPDF(RentReceiptPDFs.Item); case transferAdvice(RentCreditEvidence.AdvicePlanItem); case utilityInvoice(UtilityInvoice); case payrollForm(PayrollFormImport.Confirmed); case ukStatement(UKStatementEffect); case none }` and `public var mayChangeTaxFigures: Bool` (true for `rentReceiptsExport`, `utilityInvoice`, `payrollForm`, `ukStatement`).
  - `public struct ImportItem: Equatable, Identifiable, Sendable { id: UUID; file: ImportFile; recognition; title: String; facts: [ImportFact]; placement: ImportPlacement?; links: [ProposedLink]; effect: ImportEffect; issues: [ImportIssue]; duplicate: ImportDuplicate?; informationChanges: [FiledYearImpact]; parentId: UUID?; isLeftOut: Bool; groupKey: String; public var section: ImportSection; public var needsYouReasons: [String] }` — `section`: left out → `.leftOut`; duplicate → `.duplicates`; any issue, or recognition / fact / link `.needsReview` → `.needsYou`; else `.ready`.
  - `public struct FiledYearImpact: Equatable, Sendable { startYear: Int; person: String; isPaid: Bool; returnChanges: [Line]; informationChanges: [Line]; taxDifferenceMinorUnits: Int; causes: [String]; public struct Line: Equatable, Sendable { label: String; before: String; after: String } }` (declared here; Task 11 computes it and adds `headline` / `explanation`).
  - `public struct ImportReadyGroup: Equatable, Identifiable, Sendable { id: String /* groupKey */; title: String; summary: String; itemIds: [UUID] }`
  - `public struct ImportPlan: Equatable, Sendable { items: [ImportItem]; ignoredFiles: [String]; public func items(in: ImportSection) -> [ImportItem]; public var readyGroups: [ImportReadyGroup]; public var canConfirm: Bool /* needsYou empty and ready non-empty */ }`

- [ ] **Step 1: Write the failing tests**

```swift
func testOCRFactPutsItemInNeedsYou() {
    // item with a fact (.amount, source: .ocr, confidence: .needsReview) and no issues
    // XCTAssertEqual(item.section, .needsYou); XCTAssertEqual(item.needsYouReasons, ["Amount read by text recognition: check it"])
}
func testDuplicateWinsOverIssuesAndLeftOutWinsOverAll() { /* duplicate + issue → .duplicates; isLeftOut → .leftOut */ }
func testCanConfirmOnlyWithEmptyNeedsYouAndSomethingReady() {
    // [ready] → true; [ready, needsYou] → false; [duplicate] → false; [ready, leftOut] → true
}
func testCollectExpandsFoldersAndSkipsSystemFiles() throws {
    // temp dir: a.pdf, .hidden.pdf, .DS_Store, ~$lock.xlsx, sub/b.pdf, sub/c 10.pdf, sub/c 2.pdf
    // XCTAssertEqual(collect([dir]).files.map(\.lastPathComponent), ["a.pdf", "b.pdf", "c 2.pdf", "c 10.pdf"])
    // XCTAssertEqual(collect([dir]).ignored.count, 3)
}
func testLoadReadsTextLayerAndHash() throws {
    // EvidenceTestPDFs.textPDF(["FACTURA 123"]) → file.textStatus == .text, file.usedOCR == false, file.sha256 == EvidenceLibrary.sha256(of:)
}
```

- [ ] **Step 2: Run** `--filter ImportModelTests` — Expected: FAIL.
- [ ] **Step 3: Implement** the types (`UKStatementEffect` is declared in Task 8; until then declare it in `ImportModel.swift` as an empty `public struct UKStatementEffect: Equatable, Sendable {}` that Task 8 fills) and `ImportFile.load` / `ImportFileCollector.collect`.
- [ ] **Step 4: Run** — Expected: PASS; `SourceFolderScannerTests` still pass.
- [ ] **Step 5: Commit** `git commit -m "Import: model types, file loading and folder collection"`

---

### Task 5: Detection with stated reasons

**Files:**
- Create: `Sources/BudgetCore/DocumentImport/ImportDetector.swift`
- Test: `Tests/BudgetCoreTests/ImportDetectorTests.swift`

**Interfaces:**
- Consumes: `ImportFile`, `ImportKind`, `ImportRecognition`, `ImportIntent` (Task 4); `RentReceiptsExport.parse(xlsx:)`, `RentReceiptPDFs.parse`, `RentCreditEvidence.parseAdvice`, `UtilityInvoiceIntake.isUtilityInvoice(text:fileName:kind:providers:)`, `DocumentClassifier.classify(text:fileName:)`, `PayrollFormKind`.
- Produces:
  - `public struct ImportDetector: Sendable { public init(providers: [UtilityProvider]); public func detect(_ file: ImportFile) -> ImportRecognition }`
  - `public typealias ImportRecogniser = @Sendable (ImportFile) -> ImportRecognition?` and `public var recognisers: [ImportRecogniser]` — fixed order (first hit wins), extensible (plan 2 inserts BBVA first; plan 3 appends learnt rules then the model before the fallback):
    1. `.xlsx` that `RentReceiptsExport.parse` reads with ≥ 1 row → `.rentReceiptsExport`, certain, "Portal das Finanças receipts export (N rows)".
    2. `RentReceiptPDFs.parse(text)` non-nil → `.rentReceiptPDF`, certain, "Rent receipt nº <receipt> of contract <contract>".
    3. `RentCreditEvidence.parseAdvice(text)` non-nil → `.transferAdvice`, certain, "BBVA received-transfer advice of <date>".
    4. classifier `.p60/.p45/.p11d` → `.payrollForm(kind)`, certain, "P60 wording".
    5. `isUtilityInvoice` → `.utilityInvoice`, certain, "Invoice of <provider name>".
    6. `.csv` → `.bankStatementCSV`, certain, "CSV file"; classifier `.bankStatement` on a PDF → `.bankStatementPDF`, certain, "Bank statement wording".
    7. classifier kind ≠ `.other` from text → `.evidence(kind)`, certain, "<Kind> wording"; from the file name only → `.evidence(kind)`, needsReview, "Recognised from the file name only".
    8. otherwise `.unknown`, needsReview, "Not recognised".
  - `public static func intentIssue(_ recognition: ImportRecognition, intent: ImportIntent) -> ImportIssue?` — `kindMismatch` when `intent.expected` is set and differs (`.payrollForm` of any form matches an expected `.payrollForm`), reason `"Expected a <expected>, this looks like a <found>"`.

- [ ] **Step 1: Write the failing tests** — one per rule above with synthetic PDFs/xlsx (`XLSXWriter` writes the export fixture), asserting `kind`, `confidence` and the exact `reason`; plus `testFileNameOnlyIsNeedsReview` and `testIntentMismatchIssue` (`expected: .rentReceiptsExport`, found `.utilityInvoice` → reason `"Expected a Rent receipts export, this looks like a Utility invoice"`).
- [ ] **Step 2: Run** `--filter ImportDetectorTests` — Expected: FAIL.
- [ ] **Step 3: Implement** `ImportDetector`.
- [ ] **Step 4: Run** — Expected: PASS.
- [ ] **Step 5: Commit** `git commit -m "Import: detection with stated reasons"`

---

### Task 6: Readers for rent receipts (export, PDFs) and transfer advices

**Files:**
- Create: `Sources/BudgetCore/DocumentImport/ImportReader.swift` (protocol + context)
- Create: `Sources/BudgetCore/DocumentImport/Readers/RentImportReaders.swift`
- Test: `Tests/BudgetCoreTests/RentImportReadersTests.swift`

**Interfaces:**
- Consumes: Task 4–5 types; `RentReceiptsExport`, `RentReceiptImport.preview(db:propertyId:rows:)`, `RentReceiptPDFs.Input/plan(db:inputs:)/canonicalName`, `RentCreditEvidence.AdviceInput/planAdvices(db:propertyId:inputs:)`, `Tenancies.tenancy(db:propertyId:contractNumber:)`.
- Produces:
  - `public struct ImportContext: Sendable { intent: ImportIntent; properties: [Property]; people: [Person]; accounts: [Account]; providers: [UtilityProvider]; now: Date; public static func load(db: Database, intent: ImportIntent, now: Date) throws -> ImportContext }`
  - `public protocol ImportReader: Sendable { func handles(_ kind: ImportKind) -> Bool; func propose(_ files: [(file: ImportFile, recognition: ImportRecognition)], context: ImportContext, db: Database) throws -> [ImportItem] }` — a reader gets all its files at once (batch-level planners).
  - `public struct RentReceiptsExportReader: ImportReader` — property: the intent's, else the property of a tenancy with the export's contract number, else the only property, else issue `chooseTarget(.property, options:)`. Item effect `.rentReceiptsExport`, placement kind `.other` canonical name per Task 10, link `.property(id)` (certain, "Export for <property>"), facts: rows count and period span (textLayer). Summary title `"Receipts export: 3 tenancies, 48 receipts (12 new, 2 cancelled)"` from `RentReceiptImport.preview`.
  - `public struct RentReceiptPDFReader: ImportReader` — maps `RentReceiptPDFs.plan` outcomes: `.link` → Ready, link `.rentReceipt(id)` role `"Receipt"` certain with reason "Contract <c>, receipt nº <n>, amounts agree"; `.alreadyLinked` → duplicate `.document` of "<receipt> already has this PDF"; `.duplicate(of:)` → duplicate `.file`; `.mismatch` → issue `readerProblem("<field>: PDF <pdf>, stored <stored>")` per mismatch; `.noReceipt` → issue `readerProblem("No receipt nº <n> for contract <c>: import the portal export first")`; `.ambiguousContract` → `chooseTarget(.tenancy, options:)`; `.unreadable` → `unknownKind`. Facts from `usedOCR` are `.ocr`.
  - `public struct TransferAdviceReader: ImportReader` — per property, `planAdvices`; `.link` with a credit whose reference matched → Ready link `.transaction(id)` (certain); `.ambiguous` → `chooseLink`; `.noCredit` → issue `readerProblem("No credit of <amount> around <date> yet")` with `fileWithoutLink` offered; `.alreadyLinked`/`.copyOfLinked` → duplicate `.document`; `.notRent`, `.unconfirmed`, `.conflict` → `readerProblem` with the outcome's explanation.

- [ ] **Step 1: Write the failing tests** — synthetic property/tenancy/receipts (as `RentReceiptPDFsTests` builds them):

```swift
func testReceiptPDFMatchingStoredReceiptIsReadyWithReceiptLink() { /* section .ready; links == [.rentReceipt(id) role "Receipt", .certain] */ }
func testReceiptPDFWithDifferentAmountIsNeedsYouWithMismatch() { /* issue reason "Amount: PDF €650.00, stored €600.00" */ }
func testReceiptPDFWithoutStoredReceiptExplainsImportExportFirst() { }
func testExportWithUnknownContractAndTwoPropertiesAsksForProperty() { /* issue .chooseTarget(.property, options: [p1, p2]) */ }
func testAdviceMatchingOneCreditIsReady() { }
func testAdviceWithNoCreditOffersFileWithoutLink() { }
```

- [ ] **Step 2: Run** `--filter RentImportReadersTests` — Expected: FAIL.
- [ ] **Step 3: Implement** the protocol, context and three readers (read-only: they only call `plan`/`preview` functions).
- [ ] **Step 4: Run** — Expected: PASS.
- [ ] **Step 5: Commit** `git commit -m "Import: rent receipt and transfer advice readers"`

---

### Task 7: Readers for utility invoices, payroll forms and other evidence documents

**Files:**
- Create: `Sources/BudgetCore/DocumentImport/Readers/DocumentImportReaders.swift`
- Test: `Tests/BudgetCoreTests/DocumentImportReadersTests.swift`

**Interfaces:**
- Consumes: Task 4–6; `UtilityInvoiceIntake.propose(db:propertyId:documentId:text:fileName:…)` (+ `warnings`, `duplicateOf`, `missing`), `PayrollFormReader.read(_:kind:)`, `PayrollFormImport.Confirmed(_:kind:personId:)`, `.problems`, `.suggestedPersonId(db:nationalInsuranceNumber:)`, `EvidenceAnalyzer.analyze(text:textStatus:fileName:)`, `EvidenceMatcher.Index/suggestions(document:index:)/confidentMatch`.
- Produces:
  - `public struct UtilityInvoiceImportReader: ImportReader` — property from intent, else the provider's property. Missing provider/date/amount → `missingFigure`; each `warning` → `readerProblem(warning)`; `duplicateOf` → duplicate `.document` "Invoice <no> of <provider> already recorded"; payment: proposal's `transactionId` is a certain link only when `bestPayment` found the exact amount on the due/issue window; otherwise `chooseLink` with `paymentCandidates`. Effect `.utilityInvoice(invoice)`; the link is `madeByEffect` (the invoice row holds `transactionId`).
  - `public struct PayrollFormImportReader: ImportReader` — person: intent, else `suggestedPersonId` by NI number, else `chooseTarget(.person, options:)`; each `PayrollFormImport.Problem` → `missingFigure`/`readerProblem`; `entryMethod == .ocr` makes every figure fact `.ocr` (Needs you); effect `.payrollForm(confirmed)`; link `.employment` is `madeByEffect`.
  - `public struct EvidenceDocumentReader: ImportReader` — handles `.evidence(_)` and `.unknown`. Unknown → `unknownKind(proposed: nil)`. Facts from `EvidenceAnalyzer` (source `.ocr` when the file used OCR). Link rules (fixed): intent target → certain link with reason "You added it to <label>"; `confidentMatch` non-nil → certain link with the suggestion's reasons; exactly one suggestion with `amountMatched` but neither `dateInWindow` nor `referenceMatched` → `chooseLink([it])` ("Matched on amount only"); two or more suggestions within 20 points of the best → `chooseLink(top 5)`; none → Ready unlinked with the visible line "Not linked: no matching transaction yet".
  - `public static func defaultReaders(providers: [UtilityProvider]) -> [any ImportReader]` in `ImportReader.swift` (order: rent export, rent PDF, advice, utility, payroll, UK statement (Task 8), evidence).

- [ ] **Step 1: Write the failing tests**

```swift
func testInvoiceWithExactDebitIsReadyAndLinked() { }
func testInvoiceAlreadyRecordedIsDuplicate() { /* duplicate.level == .document, of == "Invoice FT 1/23 of Demo Power already recorded" */ }
func testP60WithKnownNINumberIsReadyForThatPerson() { }
func testScannedP60IsNeedsYou() { /* PayrollFormTestPDFs.scannedPDF → every money fact .ocr; section .needsYou */ }
func testAmountOnlySingleCandidateIsNeedsYou() { }
func testTwoEqualCandidatesAskToChoose() { /* issue .chooseLink with 2 candidates */ }
func testOCRAmountIsNeedsYouEvenWithConfidentMatch() {
    // EvidenceTestPDFs.imagePDF stand-in: ImportFile with usedOCR = true, text "SEGURO … TOTAL 120,00 €", a debit −120.00 on the day
    // XCTAssertEqual(item.section, .needsYou); XCTAssertTrue(item.needsYouReasons.contains("Amount read by text recognition: check it"))
}
func testUnknownDocumentAsksForKind() { }
```

- [ ] **Step 2: Run** `--filter DocumentImportReadersTests` — Expected: FAIL.
- [ ] **Step 3: Implement** the three readers and `defaultReaders`.
- [ ] **Step 4: Run** — Expected: PASS.
- [ ] **Step 5: Commit** `git commit -m "Import: utility invoice, payroll form and evidence readers"`

---

### Task 8: UK bank statements through saved profiles

**Files:**
- Create: `Sources/BudgetCore/DocumentImport/Readers/UKStatementReader.swift`
- Modify: `Sources/BudgetCore/Import/ImportCoordinator.swift` (rules-only categorisation; `importRunId` on commit)
- Test: `Tests/BudgetCoreTests/UKStatementReaderTests.swift`

**Interfaces:**
- Consumes: `ImportProfileStore.find(accountId:format:)`, `CSVStatementParser.parse`, `PDFLineParser.parse`, `PDFLayoutConfig.decode`, `StatementAccountCheck.fileValues/evaluate`, `StatementBalanceExtractor.extract`, `StatementCheck.compare(db:accountId:closing:…)`, `TransactionFingerprint.computeAll`, `ManualTransactions.stagedReplacements`, `TransferMatcher.stagedMatches`, `RuleMatcher.match`.
- Produces:
  - `ImportCoordinator.Categorization` — `public enum Categorization: Sendable { case full, rulesOnly }`; `stageCSVImport(…, categorization: Categorization = .full)` and `stagePDFImport(…, categorization: Categorization = .full)`. `.rulesOnly`: `RuleMatcher.match` → source `.rule`, confidence 1; no match → `nil`, `.none`. Transfers and manual replacements apply as today.
  - `public static func commit(db: Database, accountId: Int64, sourceFileName: String, staged: [StagedTransaction], decisions: [ImportDecision], statement: StatementFinish? = nil, importRunId: Int64? = nil) throws -> StatementFinishOutcome?` (the batch row gets `importRunId`).
  - `public struct UKStatementEffect: Equatable, Sendable { accountId: Int64; sourceFileName: String; staged: [StagedTransaction]; statement: StatementFinish?; accountFill: StatementAccountFill? }` (replaces Task 4's placeholder). Every `ImportDecision` is the suggestion with `learnRule: false`.
  - `public struct UKStatementReader: ImportReader` — handles `.bankStatementCSV`, `.bankStatementPDF`; its `propose` only resolves the account and profile (below). Staging is async, so the pipeline (Task 12) stages each resolved statement with `ImportCoordinator.stageCSVImport/stagePDFImport(…, categorization: .rulesOnly)` and then calls `public static func items(file: ImportFile, recognition: ImportRecognition, accountId: Int64, profile: ImportProfile, staged: StagedImport, context: ImportContext, db: Database) throws -> [ImportItem]`.
    - Account: `intent.accountId`, else the one account with a saved profile of the format whose sort code/account number `StatementAccountCheck.evaluate` says `.matches`, else issue `statement(.unknownAccount)` (only Leave out in this plan). No saved profile → `statement(.noProfile(format:accountId:))` (only Leave out here; plan 2 opens the mapping step).
    - Fingerprint duplicates → one child item per statement (`parentId`), `duplicate(.transactions, of: "<n> rows already imported")`. Unparsed lines → `statement(.unparsedLines)` resolved by `acknowledge`. A closing balance check (`StatementCheck.compare`) that is `.mismatch` → `statement(.balanceMismatch)` (Leave out only here; import anyway is plan 2).
    - Title `"<account> statement <first day>–<last day>"`; group summary `"<n> statement(s) → <rows> transactions"`.

- [ ] **Step 1: Write the failing tests**

```swift
func testRulesOnlyLeavesUnmatchedRowsUncategorised() async throws {
    // a rule "TESCO" → Groceries; CSV rows TESCO and NEWSHOP; coordinator with a categorizer that would suggest something
    // XCTAssertEqual(staged.first { TESCO }?.source, .rule); XCTAssertNil(staged.first { NEWSHOP }?.suggestedCategoryId)
}
func testCSVForAccountWithProfileIsReadyWithRowCount() async throws { /* group summary "1 statement(s) → 3 transactions" */ }
func testAlreadyImportedRowsBecomeADuplicateChild() async throws { }
func testCSVWithoutProfileIsNeedsYouNoProfile() async throws { }
func testAccountFoundBySortCodeWhenNoIntent() async throws { }
```

- [ ] **Step 2: Run** `--filter UKStatementReaderTests` and `--filter ImportCoordinator` — Expected: new tests FAIL, existing pass.
- [ ] **Step 3: Implement** the coordinator options and `UKStatementReader` (tests call `items(…)` with a `StagedImport` from the coordinator).
- [ ] **Step 4: Run** — Expected: PASS; all `ImportCoordinator*Tests` still pass.
- [ ] **Step 5: Commit** `git commit -m "Import: UK statements through saved profiles, rules-only categorisation"`

---

### Task 9: Duplicate check at file and document level

**Files:**
- Create: `Sources/BudgetCore/DocumentImport/ImportDuplicates.swift`
- Test: `Tests/BudgetCoreTests/ImportDuplicatesTests.swift`

**Interfaces:**
- Consumes: `ImportItem`, `ImportDuplicate`; `EvidenceDocument`, `EvidenceMatcher.paymentReferences(in:)`, `UtilityInvoice`, `RentReceipt` + `documentLink`.
- Produces:
  - `public enum DocumentIdentity { public static func keys(kind: ImportKind, text: String?, facts: [ImportFact], providerId: Int64?) -> Set<String> }` — keys: `"atcud:<code>"` (ATCUD `[A-Z0-9]{8,}-\d+` after "ATCUD"), `"invoice:<providerId>:<number>"`, `"receipt:<contract>:<number>"`, `"ref:<payment reference>"` (≥ 9 digits), `"ida:<kind raw>:<yyyyMMdd>:<amount minor>"` (issuer + date + amount: kind stands for issuer unless an issuer fact exists, then `"ida:<issuer normalised>:…"`).
  - `public struct DocumentIdentityIndex { public static func load(db: Database) throws -> DocumentIdentityIndex; public func match(_ keys: Set<String>) -> (documentId: Int64, label: String)? }` — built once per plan from library documents (their `extractedText`, kind, docDate, amount) and recorded invoices/receipts.
  - `public static func annotate(_ items: [ImportItem], db: Database) throws -> [ImportItem]` — in order: same sha256 as a library document → `.file` "Already in the library as <name>"; same sha256 as an earlier item of the batch → `.file` "Same file as <earlier file name>"; identity key in the library → `.document` "Same document as <name>"; identity key of an earlier item in the batch → `.document` "Same document as <earlier file name>". The first of a pair stays as it was.

- [ ] **Step 1: Write the failing tests**

```swift
func testSameHashAsLibraryDocumentIsFileDuplicate() { }
func testSameDocumentTwiceInOneBatchIsOneReadyOneDuplicate() {
    // two different PDFs (different bytes) of the same invoice: ATCUD "ABCD1234-77"
    // XCTAssertEqual(annotated.map(\.section), [.ready, .duplicates]); XCTAssertEqual(annotated[1].duplicate?.of, "Same document as invoice-a.pdf")
}
func testInvoiceNumberPerProviderMatchesRecordedInvoice() { }
func testIssuerDateAmountMatchesLibraryDocument() { }
func testSameAmountDifferentDateIsNotADuplicate() { }
```

- [ ] **Step 2: Run** `--filter ImportDuplicatesTests` — Expected: FAIL.
- [ ] **Step 3: Implement** `DocumentIdentity`, `DocumentIdentityIndex`, `ImportDuplicates.annotate`.
- [ ] **Step 4: Run** — Expected: PASS.
- [ ] **Step 5: Commit** `git commit -m "Import: duplicates by file and by document identity"`

---

### Task 10: Placement — canonical names and library metadata

**Files:**
- Create: `Sources/BudgetCore/DocumentImport/ImportNaming.swift`
- Test: `Tests/BudgetCoreTests/ImportNamingTests.swift`

**Interfaces:**
- Consumes: `EvidenceNaming.canonicalName(date:precision:area:type:detail:period:amountMinorUnits:currency:)`, `RentReceiptPDFs.canonicalName`, `ImportFact`.
- Produces: `public enum ImportNaming { public static func placement(kind: ImportKind, facts: [ImportFact], file: ImportFile, persons: [String]) -> ImportPlacement }` — area / type / detail per kind (exact):

| Kind | area | type | detail |
|---|---|---|---|
| rentReceiptPDF | (delegates to `RentReceiptPDFs.canonicalName`) | | |
| rentReceiptsExport | `Rent` | `Receipts export` | property name |
| transferAdvice | `Bank` | `Transfer received` | — (amount appended) |
| utilityInvoice | `Utilities` | `Invoice` (`Credit note` when negative) | provider name |
| payrollForm | `Tax` | `P60` / `P45` / `P11D` | employer, tax year `"2024/25"`, precision `.year` |
| evidence(k) | `DocumentKind` group: property kinds → `Property`; UK tax kinds → `Tax UK`; PT IRS kinds → `Tax PT`; banking → `Bank`; other → `Other` | `k.displayName` | issuer fact when present |
| bankStatementCSV/PDF, bbvaStatement | `Bank` | `Statement` | account name, period, precision `.month` |

Date: the docDate fact, else period start, else the file's modification day. Metadata carries kind, dates, period, amount, currency, persons, text status and text, and the source folder fields from `ImportFile`.

- [ ] **Step 1: Write the failing test** — table-driven: e.g. utility invoice of "Demo Power", 2026-09-14, €42.10 → `"20260914 - Utilities - Invoice - Demo Power - €42.10"`; P60 2024/25 employer "Acme Ltd" → `"2025 - Tax - P60 - Acme Ltd 2024/25"`.
- [ ] **Step 2: Run** `--filter ImportNamingTests` — Expected: FAIL.
- [ ] **Step 3: Implement** `ImportNaming.placement`; readers (Tasks 6–8) call it.
- [ ] **Step 4: Run** — Expected: PASS.
- [ ] **Step 5: Commit** `git commit -m "Import: canonical names and library placement"`

---

### Task 11: Filed-year guard with an explained impact

**Files:**
- Create: `Sources/BudgetCore/DocumentImport/FiledYearGuard.swift`
- Create: `Sources/BudgetCore/DocumentImport/ImportEffects.swift` (performs one effect in the caller's transaction; shared with Task 13)
- Test: `Tests/BudgetCoreTests/FiledYearGuardTests.swift`

**Interfaces:**
- Consumes: `TaxFigures.snapshot(db:years:)`, `.changes(from:to:)`, `.isFiled(_:startYear:includePaid:)`, `UKTaxYear`, Task 4 effects.
- Produces:
  - `public enum ImportEffects { public static func perform(db: Database, _ effect: ImportEffect, documentId: Int64?, importRunId: Int64?) throws }` — `.rentReceiptsExport` → `RentReceiptImport.run`; `.rentReceiptPDF` → `RentReceiptMatching`-free link (`EvidenceLinks.link(.rentReceipt, role "Receipt")`); `.transferAdvice` → `EvidenceLinks.link` to each credit (role as `RentCreditEvidence.applyAdvices` uses); `.utilityInvoice` → `UtilityInvoiceIntake.record` with `documentId`; `.payrollForm` → `PayrollFormImport.apply(db:_:documentId:)`; `.ukStatement` → `StatementAccountCheck.fill` then `ImportCoordinator.commit(db:…importRunId:)`; `.file`, `.none` → nothing.
  - `extension FiledYearImpact { public var headline: String; public var explanation: [String] }` (the struct is declared in Task 4)
    - `headline`: `"Would change the filed 2024/25 return of Person A"` (`"paid"` when the year is paid).
    - `returnChanges`: fields starting `"SA "`, label = field without `"SA "` (e.g. `"SA102 Employment box 1 Pay from this employment"`), values as pounds (`£40,000.00`).
    - `taxDifferenceMinorUnits`: after − before of `"SA calculation · SA liability"`; explanation line `"Tax: £230.00 more to pay"` / `"Tax: £230.00 less to pay"` / `"Tax: no change"`.
    - `informationChanges`: other changed fields of that year/person (information only, may change).
    - `causes`: the item title and its money/date facts (`"P60 2024/25 Acme Ltd: pay £41,000.00"`), plus each affected transaction `"<date> <description> <amount>"` for statements.
  - `public enum FiledYearGuard { public static func filedYears(db: Database) throws -> Set<Int>; public static func impacts(db: Database, item: ImportItem, filedYears: Set<Int>) throws -> [FiledYearImpact]; public static func annotate(_ items: [ImportItem], db: Database) throws -> [ImportItem] }` — only items with `effect.mayChangeTaxFigures` whose dates fall in a filed/paid UK tax year are evaluated: snapshot, perform the effect in a `SAVEPOINT` with `documentId: nil`, snapshot, `ROLLBACK TO`. Any `returnChanges` → issue `.filedYear(impact)` (id `"filed-<year>-<person>"`), whose only resolution is `.leaveOut`. Information-only changes are kept on the item for the preview (`ImportItem.informationChanges`).

- [ ] **Step 1: Write the failing tests** (a fixture with person A, a filed 2024 tax year and an employment, like `SelfAssessmentTests`)

```swift
func testP60ChangingAFiledYearIsBlockedWithExplainedImpact() throws {
    // P60 2024/25 with pay +£1,000 over the stored figure
    // let impact = item.issues.compactMap { if case .filedYear(let i) = $0.kind { i } else { nil } }.first!
    // XCTAssertEqual(impact.headline, "Would change the filed 2024/25 return of Person A")
    // XCTAssertTrue(impact.returnChanges.contains { $0.label.hasPrefix("SA102") && $0.before == "£40,000.00" && $0.after == "£41,000.00" })
    // XCTAssertEqual(impact.explanation.first { $0.hasPrefix("Tax:") }, "Tax: £400.00 more to pay")
    // XCTAssertEqual(item.section, .needsYou); database unchanged (savepoint rolled back)
}
func testOpenYearIsNotGuarded() throws { }
func testInformationOnlyChangeDoesNotBlock() throws { /* e.g. a cost marked not claimed → item ready, informationChanges non-empty */ }
func testItemsWithoutTaxEffectAreNotEvaluated() throws { /* .file effect: impacts == [] without taking snapshots (count snapshot calls via a test hook) */ }
```

- [ ] **Step 2: Run** `--filter FiledYearGuardTests` — Expected: FAIL.
- [ ] **Step 3: Implement** `ImportEffects.perform` and `FiledYearGuard`.
- [ ] **Step 4: Run** — Expected: PASS.
- [ ] **Step 5: Commit** `git commit -m "Import: filed-year guard with explained impact"`

---

### Task 12: The pipeline — plan, add files, resolve

**Files:**
- Create: `Sources/BudgetCore/DocumentImport/ImportPipeline.swift`
- Create: `Sources/BudgetCore/DocumentImport/ImportResolutions.swift`
- Test: `Tests/BudgetCoreTests/ImportPipelineTests.swift`

**Interfaces:**
- Consumes: everything from Tasks 4–11.
- Produces:
  - `public struct ImportProgress: Equatable, Sendable { public var completed: Int; public var total: Int; public var currentFile: String? }`
  - `public struct ImportPipeline: Sendable { public init(dbQueue: DatabaseQueue, library: EvidenceLibrary, categorizationService: CategorizationService, readers: [any ImportReader]? = nil, detector: ImportDetector? = nil) }`
  - `public func plan(_ urls: [URL], intent: ImportIntent = .none, progress: @Sendable (ImportProgress) -> Void = { _ in }) async throws -> ImportPlan` — collect → load files (TaskGroup, ≤ 4 at once, progress after each) → detect → stage UK statements → readers (one `dbQueue.read`) → intent issues → `ImportDuplicates.annotate` → `FiledYearGuard.annotate` → plan. Honors task cancellation (`CancellationError`).
  - `public func plan(adding urls: [URL], to plan: ImportPlan, intent: ImportIntent, progress: …) async throws -> ImportPlan` — re-runs duplicates over old + new items so cross-call duplicates are found.
  - `public func resolve(_ plan: ImportPlan, itemId: UUID, _ resolution: ImportResolution) async throws -> ImportPlan` — `.leaveOut` → `isLeftOut = true`; `.acknowledge` / `.fileWithoutLink` / `.chooseLink` / `.confirmFigure` change the item in place (the fact/link becomes `.user`, `.certain`) and drop the issue; `.chooseKind` / `.chooseTarget` re-run detection override + that item's reader + duplicates + filed-year guard for the item only. Resolving `.leaveOut` again on a left-out item puts it back (`isLeftOut = false`).
  - `ImportPlan.readyGroups` summaries (exact): rent receipts `"<n> rent receipt(s) → linked to their receipts"`; utility invoices `"<n> utility invoice(s) → linked to their debits"` (`"…→ <k> linked, <m> filed unlinked"` when mixed); payroll `"<n> P60/P45/P11D → employment <year>"`; statements as Task 8; evidence `"<n> <kind> document(s) → filed"`.

- [ ] **Step 1: Write the failing tests**

```swift
func testPlanSortsFilesIntoSections() async throws {
    // folder: matching receipt PDF (ready), unknown letter (needsYou), copy of a library file (duplicate)
    // XCTAssertEqual(plan.items(in: .ready).count, 1); .needsYou 1; .duplicates 1; XCTAssertFalse(plan.canConfirm)
}
func testProgressReportsEveryFile() async throws { /* 3 files → progress.completed sequence ends at 3 of 3 */ }
func testAddingTheSameFileLaterIsADuplicate() async throws { }
func testLeaveOutEnablesConfirm() async throws { /* resolve(.leaveOut) on the needsYou item → canConfirm true */ }
func testChooseKindReproposesItem() async throws { /* unknown → .chooseKind(.insuranceReceipt) → recognition kind .evidence(.insuranceReceipt), source .user */ }
func testCancellationStopsReading() async throws { }
func testPlanWritesNothing() async throws { /* table row counts identical before/after plan */ }
```

- [ ] **Step 2: Run** `--filter ImportPipelineTests` — Expected: FAIL.
- [ ] **Step 3: Implement** `ImportPipeline` and `ImportResolutions` (pure item edits in `ImportResolutions.apply(_:to:) -> ImportItem?`, `nil` meaning "re-propose").
- [ ] **Step 4: Run** — Expected: PASS.
- [ ] **Step 5: Commit** `git commit -m "Import: pipeline, adding files and resolutions"`

---

### Task 13: Apply a plan as one undoable run

**Files:**
- Create: `Sources/BudgetCore/DocumentImport/ImportApplier.swift`
- Create: `Sources/BudgetCore/DocumentImport/ImportBackup.swift`
- Modify: `Sources/BudgetCore/Evidence/EvidenceLibrary.swift` (add `public func removeOrphanedFiles(sha256s: [String]) throws -> Int`)
- Test: `Tests/BudgetCoreTests/ImportApplierTests.swift`

**Interfaces:**
- Consumes: Tasks 1–12; `EvidenceLibrary.add(db:_:metadata:analysis:now:)`, `EvidenceLinks.link/unlink`, `TransferMatcher.match(db:)`, `RentReceiptMatching.match(db:propertyId:)`, `Recharges.matchPayments(db:propertyId:)`, `RentCreditEvidence.linkReceiptDocuments(db:)`, `RentCreditEvidence.libraryAdvices/planAdvices/applyAdvices`, `AutoForecastGenerator.refresh(db:)`, `SourceFile` (`documentId` update).
- Produces:
  - `public struct ImportRunSummary: Equatable, Sendable { runId: Int64; filed: Int; linked: Int; recorded: Int; transactions: Int; duplicates: Int; leftOut: Int; backupPath: String?; public var text: String /* "3 documents filed, 2 linked, 142 transactions" */ }`
  - `public enum ImportApplyError: Error, Equatable { case notConfirmable; case filedYearChanged([FiledYearImpact]); case planOutdated(String) }`
  - `public struct ImportApplier: Sendable { public init(dbQueue: DatabaseQueue, databasePath: String?, library: EvidenceLibrary); public func apply(_ plan: ImportPlan, entryPoint: String, reasons: [String: String] = [:], now: Date = Date()) throws -> ImportRunSummary }`
    1. `plan.canConfirm` else `.notConfirmable`.
    2. `ImportBackup.backupIfNeeded` before the write.
    3. One `dbQueue.write`: insert `ImportRun`; `ImportChangeCapture.begin`; snapshot filed figures; for each Ready item (statement parents before their children; documents before links): add the file (`library.add(db:)`, remembering placed files), `ImportEffects.perform`, `EvidenceLinks.link` for links not `madeByEffect`, intent `replacing` documents unlinked from the target, the source file's `documentId` set; follow-ons in this order: `TransferMatcher.match`, for each property touched (all when a statement was applied) `RentReceiptMatching.match` then `Recharges.matchPayments`, `RentCreditEvidence.linkReceiptDocuments(db:)`, library advices planned and applied for `.link` outcomes, `AutoForecastGenerator.refresh`; snapshot again — any filed/paid `"SA "` change throws `.filedYearChanged` (rollback); `ImportRunFile` per file (duplicates and left-out too); `ImportChangeCapture.finish(db:runId:)`; summary saved on the run.
    4. On any throw: `ImportChangeCapture` is dropped with the rollback; placed files removed via `library.removeOrphanedFiles`.
  - `public enum ImportBackup { public static func backupIfNeeded(dbQueue: DatabaseQueue, databasePath: String?, plan: ImportPlan, now: Date) throws -> String?; static let keep = 10 }` — needed when any Ready item is a statement or ≥ 25 items are Ready; file `"<db>.pre-import-backup-yyyyMMdd-HHmmss"` via `dbQueue.backup(to:)`; in-memory databases → nil; older `pre-import-backup-` files beyond the newest 10 are removed.

- [ ] **Step 1: Write the failing tests**

```swift
func testApplyFilesLinksAndRecordsRun() throws {
    // plan with one ready receipt PDF and one ready insurance receipt linked to a debit
    // summary.filed == 2, summary.linked == 2; ImportRunFile outcomes [.linked, .linked]; ImportChange rows > 0
}
func testApplyRefusesPlanWithNeedsYou() throws { /* .notConfirmable, nothing written */ }
func testFailedApplyLeavesNoRowsAndNoOrphanFiles() throws {
    // second item's effect throws (a utility invoice with a providerId that no longer exists)
    // XCTAssertThrowsError; document count unchanged; library root contains no new stored files; ImportRun count 0
}
func testBatchLevelFiledYearChangeRollsBack() throws {
    // two items each harmless alone but together moving a filed figure (FiledYearGuard skipped them: simulate by
    // building the plan with guard annotations stripped) → .filedYearChanged
}
func testUndoAfterApplyRestoresTheDatabase() throws {
    // apply → ImportUndo.undo → row counts of every tracked table equal the pre-apply counts
}
func testStatementPlanWritesBackupNextToDatabase() throws { /* temp file db; backupPath has prefix "<db>.pre-import-backup-" */ }
func testApplyRunsFollowOnRentMatching() throws { /* statement with a rent credit + stored unmatched receipt → rentReceiptPayment row exists after apply */ }
```

- [ ] **Step 2: Run** `--filter ImportApplierTests` — Expected: FAIL.
- [ ] **Step 3: Implement** `ImportApplier`, `ImportBackup`, `removeOrphanedFiles`.
- [ ] **Step 4: Run** the filter, then the full suite — Expected: PASS.
- [ ] **Step 5: Commit** `git commit -m "Import: apply a plan as one undoable run, backups, follow-on matching"`

---

### Task 14: App — import center, global entry points and the Imports screen

**Files:**
- Create: `App/DocumentImport/ImportCenterModel.swift`
- Create: `App/DocumentImport/ImportCommands.swift`
- Create: `App/DocumentImport/ImportsScreen.swift` (progress, review or history)
- Modify: `App/AppEnvironment.swift` (`let databasePath: String?`, `lazy var importCenter: ImportCenterModel`)
- Modify: `App/ContentView.swift` (`AppScreen.imports = "Imports"`, systemImage `"tray.and.arrow.down"`, section `"Workflow"`; toolbar button; window drop target; publishes `focusedSceneValue(\.documentImport, …)`)
- Modify: `App/BudgetApp.swift` (`.commands { SearchCommands(); ImportCommands() }`)

**Interfaces:**
- Consumes: `ImportPipeline`, `ImportApplier`, `ImportUndo`, `ImportPlan`, `ImportResolution`, `ImportIntent`.
- Produces:
  - `@MainActor final class ImportCenterModel: ObservableObject` — `enum Phase: Equatable { case idle, reading(ImportProgress), review, applying, finished(ImportRunSummary), failed(String) }`; `@Published private(set) var phase`; `@Published private(set) var plan: ImportPlan?`; `@Published var selectedItemId: UUID?`; `@Published private(set) var runs: [ImportRun]`; `var onShow: (() -> Void)?` (ContentView selects Imports); `func start(_ urls: [URL], intent: ImportIntent = .none, entryPoint: String)` (adds to an open review via `plan(adding:)`); `func resolve(_ itemId: UUID, _ resolution: ImportResolution)`; `func confirm()`; `func discard()`; `func loadRuns()`; `func undo(_ runId: Int64) -> [ImportUndoConflict]` (empty: done). All Core calls run in `Task.detached`; the plan is replaced only on completion.
  - `struct DocumentImportAction { let start: (_ urls: [URL], _ intent: ImportIntent, _ entryPoint: String) -> Void; let pickFiles: (_ intent: ImportIntent, _ entryPoint: String) -> Void }` and `@Entry var documentImport: DocumentImportAction?` (FocusedValues) plus the same as an `EnvironmentValues` entry for plan 4's shortcuts.
  - `struct ImportCommands: Commands` — File menu, after `.newItem`: "Import…" ⇧⌘I opens a multi-select open panel (files and folders, any type).
  - Toolbar: `Button { pickFiles(.none, "Toolbar") } label: { Label("Import…", systemImage: "square.and.arrow.down.on.square") }`.
  - Window drop: `.dropDestination(for: URL.self)` on the detail column → `start(urls, .none, "Drop")`, with an accent outline while targeted.

- [ ] **Step 1: Build check** — `xcodegen generate && xcodebuild … build` — Expected: FAIL until the files exist (no unit tests for views; logic is covered in Core).
- [ ] **Step 2: Implement** the model, commands, screen shell (progress view: "Reading 3 of 12 — <file>" with a `ProgressView(value:)` and Cancel), sidebar case and entry points.
- [ ] **Step 3: Build** — Expected: BUILD SUCCEEDED, no warnings.
- [ ] **Step 4: Commit** `git commit -m "Imports screen, File ▸ Import…, toolbar button and window drop"`

---

### Task 15: App — the review (option A) with the docked preview

**Files:**
- Create: `App/DocumentImport/ImportReviewView.swift`
- Create: `App/DocumentImport/ImportPreviewPanel.swift`
- Create: `App/DocumentImport/ImportIssueControls.swift`

**Interfaces:**
- Consumes: `ImportCenterModel` (Task 14); `ImportPlan.items(in:)`, `readyGroups`, `ImportItem.needsYouReasons`, `ImportIssueKind`, `FiledYearImpact.headline/explanation`; design system `Panel`, `StatusPill`, `InlineBanner`, `MoneyText`, `DateText`, `.figureText()`, `DocumentThumbnail(url:height:)`.
- Produces:
  - `struct ImportReviewView: View` — left list, min width 520: **Needs you** (each row: StatusPill `.warning` "Needs you", title, first reason, figure); **Ready** grouped by `readyGroups` (DisclosureGroup, collapsed, row = group summary; expanded rows per document); **Duplicates skipped** (row: file name, "Duplicate of …"); **Left out** (with "Put back"). Footer: counts `"4 ready · 2 need you · 1 duplicate"` and `Button("Confirm import")` `.borderedProminent`, disabled with `.help("Settle everything in Needs you first")` while `!plan.canConfirm`; Discard.
  - `struct ImportPreviewPanel: View` (docked right, width 360, scrolls): file thumbnail (original URL); "Recognised as <kind>" + reason; figures table (label, value `.figureText()`, source pill "Text" / "OCR" / "File name" / "You"); "Filed as" canonical name; "Links to" with reasons; information-only tax changes (Task 11) as a caption list; issues with `ImportIssueControls`.
  - `struct ImportIssueControls: View` — per `ImportIssueKind`: kind picker (`DocumentKind.allCases` by `displayName`), candidate radio list + "File without a link", figure field editor (date/money/text), target picker (property/person/account/tenancy names), "Got it" for acknowledge, filed-year `InlineBanner(.warning)` showing headline + explanation lines with only "Leave out of this import"; every issue also offers "Leave out of this import".

- [ ] **Step 1: Build** — Expected: FAIL until implemented.
- [ ] **Step 2: Implement** the views (no plan recomputation in `body`: rows read `model.plan` values only).
- [ ] **Step 3: Build** — Expected: BUILD SUCCEEDED, no warnings.
- [ ] **Step 4: Commit** `git commit -m "Imports: review with Needs you, Ready groups, duplicates and docked preview"`

---

### Task 16: App — import history and undo; demo samples and snapshot routes

**Files:**
- Create: `App/DocumentImport/ImportHistoryView.swift`
- Create: `Sources/BudgetDemo/DemoImportSamples.swift`
- Modify: `Sources/MakeDemoDatabase/main.swift` (write samples to `ImportSamples/` beside the database)
- Modify: `App/Snapshots/SnapshotCatalog.swift` (`importRoutes`, appended last to `routes`)
- Test: `Tests/BudgetCoreTests/DemoImportSamplesTests.swift`

**Interfaces:**
- Consumes: `ImportCenterModel.runs/undo`, `ImportRunFile`, `ImportUndoConflict.message`, `DemoPDF`, `DemoDatabase`.
- Produces:
  - `struct ImportHistoryView: View` — title "Import history"; `DataTable` of runs (Date `DateText`, Entry point, Summary, `StatusPill("Undone")` when undone); docked detail: files with outcome pills and details, backup path, "Undo import…" → confirmation `"Undo this import? It removes what it added and puts back what it changed."` → on refusal an `InlineBanner(.warning)` titled `"Can't undo: <n> thing(s) changed since"` listing each conflict message.
  - `public enum DemoImportSamples { public static func write(into folder: URL, dbQueue: DatabaseQueue) throws -> [URL] }` — six synthetic files, derived from the demo database at write time: (1) the PDF of Tenancy 2's latest receipt (contract CT-0002) → Ready; (2) an insurance receipt equal to a demo Lisbon expense debit (date and amount) → Ready linked; (3) a copy of an existing demo evidence PDF → Duplicate (file); (4) a utility invoice re-issued with a recorded invoice's number → Duplicate (document); (5) a P60 2024/25 for Person A with pay £1,000 above the stored figure → Needs you (filed year); (6) `Letter.pdf` with no recognisable wording → Needs you (unknown kind).
  - Snapshot routes (in `SnapshotCatalog.importRoutes`): `imports-review` (plan of the samples, first Needs-you item selected), `imports-review_filed` (the P60 selected), `imports-review_ready` (Ready group expanded, receipt selected), `imports-history` (applies a plan of the samples with Needs-you items left out, then shows history with that run selected — last route, since it writes to the demo copy).

- [ ] **Step 1: Write the failing test**

```swift
func testDemoSamplesProduceEachSection() async throws {
    // DemoDatabase.build in a temp dir; DemoImportSamples.write; ImportPipeline.plan(samples)
    // XCTAssertEqual(plan.items(in: .ready).count, 2); XCTAssertEqual(plan.items(in: .duplicates).count, 2)
    // XCTAssertEqual(plan.items(in: .needsYou).count, 2)
    // XCTAssertTrue(plan.items(in: .needsYou).contains { $0.issues.contains { if case .filedYear = $0.kind { true } else { false } } })
}
```

- [ ] **Step 2: Run** `--filter DemoImportSamplesTests` — Expected: FAIL.
- [ ] **Step 3: Implement** the samples, the tool change, `ImportHistoryView`, the routes.
- [ ] **Step 4: Run** the test (PASS), the build (no warnings), then `scripts/render-snapshots.sh <scratch>/snaps-imp1 --only imports-review,imports-review_filed,imports-review_ready,imports-history --size 1100x700` — Expected: four PNGs per look; `wrap-report.txt` lists no import route.
- [ ] **Step 5: Commit** `git commit -m "Imports: history with undo, demo samples and snapshot routes"`

---

### Task 17: Final verification, merge and install (controller)

- [ ] Full `swift test --scratch-path <scratch>/build-imp1` — all pass; app Debug and Release builds without warnings; `lsregister -u` both.
- [ ] Full snapshot run at 1100×700 and 1440×900: no new wrap-probe findings on any route.
- [ ] Whole-branch review (subagent-driven-development's final review) against the spec sections "Goals" 1–5, "Anti-goals", "Calls" 1–2.
- [ ] Merge to main, `xcodegen generate` in the main checkout, `scripts/install-app.sh`; do not push.

## Self-review

- Spec coverage: one entry point (Task 14, shortcuts in plan 4); detection with reasons (5); archival with canonical names (10, 13); linkage to transactions, rent receipts, utility invoices, employment (6–8, 13); duplicates at three levels (8, 9); undo with change log and refusal (1–3, 13, 16); filed-year guard with impact explanation (11, 13); review option A with Confirm disabled while Needs you (15); single-transaction apply with backup (13); follow-on matching (13); batch history (16). Learning (plan 3), BBVA statements and statement Needs-you resolutions (plan 2), shortcuts and retiring old flows (plan 4).
- Types: `ImportIntent.Target`, `ImportEffect`, `UKStatementEffect`, `FiledYearImpact`, `ImportUndoConflict` are named identically in every task and in plans 2–4.
- Review Focus lines each have a named test in their owning task (Tasks 3, 4, 7, 9, 13).
