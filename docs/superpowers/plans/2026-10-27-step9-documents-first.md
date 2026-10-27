# Step 9: documents first, statements later — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (chosen) to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** a bill, invoice or receipt filed before the bank statement that pays it waits quietly ("Waiting for its payment") and links itself when the statement import (or a sync from another device) brings the matching debit; weaker matches become one-click suggestions.

**Architecture:**
- **Derived, not stored.** "Waiting" is computed from the document (kind expects a debit, has an amount, no transaction link, younger than 90 days). No new CloudKit record type. One new **local-only** table (`autoLinkDeclined`) remembers pairs the user undid, so the job never re-makes them.
- **One matcher.** `EvidenceMatcher.suggestions` + `confidentMatch` decide; `EvidenceLinkGuard.checked` guards every automatic link (a refusal, i.e. a filed year, downgrades the pair to a suggestion). Same pattern as `BBVADebitAdvice.linkLibraryAdvices`.
- **Where it runs:** at the end of `ImportApplier.applyAll` (inside the run, so run-level Undo also takes the links back), after `ImportCoordinator.commit(accountId:…)` (CSV/PDF statements), and after each pull on the Mac (`SyncScheduler` post-pull hook). The iPad never runs it; it reads the state and accepts suggestions through `DeviceWriter`.

**Tech Stack:** Swift 6, SwiftUI, GRDB 6.29, XCTest, XcodeGen.

**Spec:** `docs/superpowers/specs/2026-10-27-step9-documents-first-design.md` (binding; calls marked *(my call)* there are adopted as written unless listed under "Plan calls" below).

## Global Constraints

- **Logic in BudgetCore** (`Sources/BudgetCore`); `App/` and `Sources/MangoUI/Pad` render and call it. `scripts/build-core-ios.sh` stays green.
- **No second matcher:** only `EvidenceMatcher` (`suggestions`, `confidentMatch`, `expectation(for:)`/`isPaidByDebits`, `Index`) decides a match.
- **Every automatic link goes through `EvidenceLinkGuard.checked`** (one savepoint per pair). Filed SA years 2020/21–2024/25 never change: a refused pair is never linked, it becomes a suggestion.
- **No new CloudKit record type.** The waiting state is derived. `autoLinkDeclined` is added to `SyncSchema.localOnlyTables`.
- **iPad writes** go through `DeviceWriter.writeCheckingFiledYears` (refusal inline via `PadRefusalBanner`/`DeviceWriteCopy`); controls hidden, not disabled, by `DeviceWriter.canEdit(.documents)`.
- **Mac fits 1100×700; no figure wraps; names truncate in the middle** (`.lineLimit(1).truncationMode(.middle)`). iPad fits 11"/13", portrait and landscape.
- **Nothing saves except explicit actions:** the automatic link is the import's (or the sync's) own reported action, with Undo.
- **Tenant's personal name only on Tenancies and in the recharge email;** elsewhere the tenancy's name.
- **Tests never touch the real DB (`~/Library/Application Support/Budget`), Keychain, iCloud or `/Applications`.** Use `TestDatabase`, BudgetDemo, `FakeCloud`, `TwoPersonHousehold`. No subagent runs `scripts/install-app.sh`.
- **Nothing personal committed** (public repo): synthetic names and amounts.
- **Build the App/Phone targets with `xcodebuild`** for any task touching `App/`, `Phone/`, `project.yml`.
- **Commands** (`S9=/tmp/mango-9-build`, outside `~/Documents` because of iCloud CodeSign issues):
  - targeted: `swift test --scratch-path $S9 --filter '<Tests>'`
  - full suite, once at the end of each task: `swift test --scratch-path $S9 --parallel`
  - Mac build: `xcodegen generate && xcodebuild -project Mango.xcodeproj -scheme Mango -configuration Debug -derivedDataPath $S9/dd CODE_SIGNING_ALLOWED=NO build`
  - phone/iPad build: `scripts/build-phone.sh`
  - `scripts/check-actor-writes.sh` → "actor writes OK" after any task adding a write path.
  - **at most 2 building agents at once.**
- **Model tags:** **[opus]** = sync, write path, filed year or import logic: most capable model plus spec+code review. **[sonnet]** = UI: quick review.
- **Dropping tasks: drop from the end.** Task 4 (iPad) is the most droppable: without it the iPad shows the document unlinked as today, and the Mac links for it anyway.

## Plan calls (extend or contradict the spec)

1. **`autoLinkDeclined` local-only table** (documentId, transactionId, declinedAt). Extends the spec's "no new stored state": without it Undo would be re-linked by the next job. Local to a Mac (not synced, not a record type); a second Mac that never saw the undo could re-link it, accepted and noted.
2. **Per-pair Undo = unlink + decline**, through `EvidenceLinkGuard.checked`; run-level Undo of the import still reverts the whole run's links (they are captured by `ImportChangeCapture`).
3. **"Due/issue date" is `docDate ?? periodEnd ?? addedAt`** — documents have no due-date field. The 90-day expiry counts from it (clock injected).
4. **Waiting kinds = `EvidenceMatcher.isPaidByDebits(kind)` and an amount stated.** Credits (rent receipts, advices) and custom kinds are never waiting. A utility invoice document counts when its bills-tracker invoice has no payment; `Recharges.matchPayments` still runs first (inside `followOns`) and keeps the bills-tracker stage.
5. **Confident = `EvidenceMatcher.confidentMatch`** (≥140, exact amount, date in window or reference, strictly ahead). A transaction already linked to another document of the same kind is not auto-linked (suggestion instead), as `linkLibraryAdvices` does.
6. **Suggestions are computed, not stored** (on open of the document / panel), so no new state; the job only returns their counts.
7. **Sync hook is a new optional `afterPull` closure on `SyncScheduler`** (set by the Mac's `RealSync` only); iPad passes nil.

## Review Focus

1. **Two equal-amount bills (e.g. two €60 utility bills, one month apart) and one debit.** Expect no automatic link when scores tie; both show a suggestion; nothing linked. Task 1: `testTwoEqualBillsOneDebitIsASuggestion`.
2. **The same statement imported twice, or a sync that re-delivers the same debit.** Expect nothing new linked and no duplicate link or summary line. Task 1: `testRunTwiceLinksOnce`; Task 2: `testReimportedStatementLinksNothingNew`.
3. **A user who undid an automatic link.** Expect it never re-made by later imports or syncs, and the document back to waiting (or lapsed). Task 1: `testUndoneLinkIsNotRemade`.
4. **A debit that belongs to a filed year (2020/21–2024/25).** Expect a suggestion, no link, no change to the filed return. Task 1: `testFiledYearLinkBecomesSuggestion`.
5. **A document with no amount, a credit-kind document, or a document older than 90 days.** Expect never waiting and never auto-linked (an old one is an ordinary unlinked document, still suggestible by hand). Task 1: `testWaitingRules`, `testLapsesAfterNinetyDays`.

---

### Task 1 [opus]: The waiting state, matcher reuse, auto-link with filed-year guard and 90-day expiry

**Files:**
- Create: `Sources/BudgetCore/Evidence/WaitingDocuments.swift` (state, job, undo), `Sources/BudgetCore/Evidence/AutoLinkDeclined.swift` (record + migration `createAutoLinkDeclined`)
- Modify: `Sources/BudgetCore/Sync/SyncSchema.swift:273` (add `"autoLinkDeclined"` to `localOnlyTables`), the migrator registration list that already calls `registerSavedSiteMigration` or its siblings (grep `createSavedSite` callers) to register the new migration
- Test: `Tests/BudgetCoreTests/WaitingDocumentsTests.swift`

**Interfaces — Produces:**
```swift
public enum WaitingDocuments {
    public static let expiryDays = 90
    public enum State: Equatable, Sendable { case waiting, lapsed, notApplicable }   // lapsed: expired, now an ordinary unlinked document
    public struct Pair: Equatable, Identifiable, Sendable { public var documentId: Int64; public var transactionId: Int64; public var id: String { "\(documentId)-\(transactionId)" } }
    public struct Outcome: Equatable, Sendable { public var linked: [Pair]; public var suggested: [Int64: Int] /* documentId → candidate count */ }
    public static func state(db: Database, documentId: Int64, now: Date) throws -> State
    public static func states(db: Database, now: Date) throws -> [Int64: State]        // only waiting/lapsed present; one query pass
    @discardableResult public static func run(db: Database, now: Date = Date()) throws -> Outcome
    public static func suggestions(db: Database, documentId: Int64, limit: Int = 8) throws -> [EvidenceMatcher.Suggestion]  // declined pairs and already-linked excluded
    public static func undo(db: Database, _ pair: Pair, now: Date) throws                // EvidenceLinkGuard.checked unlink + decline row
}
```

- [ ] **Step 1: Write the failing tests** in `WaitingDocumentsTests` (all on `TestDatabase`, injected `now`, synthetic data, a BBVA-like debit account):
  - `testWaitingRules`: a utility invoice doc with amount and no link is `.waiting`; same doc with no amount, a rent receipt (credit kind), a custom-kind doc, and a doc linked to a transaction are `.notApplicable`.
  - `testLapsesAfterNinetyDays`: doc dated day 0 is `.waiting` at day 90, `.lapsed` at day 91; `run` at day 91 links nothing.
  - `testOneConfidentMatchLinks`: exact amount, date inside the kind's window → `run` returns one `Pair`, the `documentLink` row exists, state becomes `.notApplicable`.
  - `testTwoEqualBillsOneDebitIsASuggestion`: two docs, same amount, one debit → `linked` empty, `suggested` has both ids with count 1.
  - `testWeakMatchIsASuggestion`: amount matches, date outside the window → not linked; `suggestions(...)` returns it.
  - `testFiledYearLinkBecomesSuggestion`: debit dated in 2023/24 where linking would move a filed return (build as `EvidenceLinkGuardTests` does) → no link row, `suggested[doc] == 1`.
  - `testUndoneLinkIsNotRemade`: `run`, `undo(pair)`, `run` again → `linked` empty; `suggestions` no longer lists that transaction; state back to `.waiting`.
  - `testRunTwiceLinksOnce`: second `run` returns empty `linked`.
  - `testTakenDebitIsNotAutoLinked`: the debit already linked to another document of the same kind → suggestion only.
  - `testUtilityInvoiceKeepsBillsTrackerStage`: utility doc whose invoice `Recharges.matchPayments` paid is not waiting and gains its document link without moving the invoice's stage backwards.
- [ ] **Step 2: Run to verify they fail:** `swift test --scratch-path $S9 --filter WaitingDocumentsTests` → FAIL (type not defined).
- [ ] **Step 3: Implement** `AutoLinkDeclined` (`documentId`, `transactionId`, `declinedAt`, unique on the pair, FK-less so a deleted row cannot block sync) and its migration; add to `localOnlyTables`.
- [ ] **Step 4: Implement `WaitingDocuments`** in `Sources/BudgetCore/Evidence/WaitingDocuments.swift`: candidates = documents with `EvidenceMatcher.isPaidByDebits(ref)`, `amountMinorUnits != nil`, no `transaction` link (use the `NOT EXISTS (documentLink …)` shape of `BBVADebitAdvice.linkLibraryAdvices`); anchor `docDate ?? periodEnd ?? addedAt`; `lapsed` when `days(anchor, now) > 90`. `run`: build one `EvidenceMatcher.Index` from transactions dated ≥ (earliest waiting anchor − `EvidenceMatcher.amountGraceDays`), call `suggestions` per waiting document, drop declined pairs, take `confidentMatch`; for each confident pair not "taken" (call 5) link inside `EvidenceLinkGuard.checked`, catching `EvidenceLinkGuard.Failure` to count it as a suggestion; documents with other candidates count in `suggested`. Linking uses `EvidenceLinks.link` (no role). `undo` unlinks inside `checked` and inserts the decline row. Order by document id for determinism.
- [ ] **Step 5: Run targeted tests** → all PASS. Then `swift test --scratch-path $S9 --parallel`, `scripts/check-actor-writes.sh`, `scripts/build-core-ios.sh`.
- [ ] **Step 6: Commit**
  ```bash
  git add Sources/BudgetCore/Evidence Sources/BudgetCore/Sync/SyncSchema.swift Tests/BudgetCoreTests/WaitingDocumentsTests.swift
  git commit -m "Waiting documents: derived state, auto-link on a confident match, filed-year guard, 90-day expiry"
  ```

### Task 2 [opus]: Run it after imports and sync merges; "N documents linked" + Undo

**Files:**
- Modify: `Sources/BudgetCore/DocumentImport/ImportApplier.swift` (after `followOns` at the `try ImportEffects.followOns(db: db, propertyIds: touched)` line, before the filed-year backstop; `ImportRunSummary` gains `paymentLinks: [WaitingDocuments.Pair]` and `text` adds "N documents linked to their payments" — singular "1 document linked to its payment"), `Sources/BudgetCore/Import/ImportCoordinator.swift` (the non-db `commit(accountId:…)` runs it after the write; the `db:` variants do not, the applier does), `Sources/BudgetCore/Sync/SyncScheduler.swift` (optional `afterPull: (@Sendable () async -> Void)?` init parameter, awaited in `perform` right after `engine.pull()` when `pulled`), `App/Sync/RealSync.swift` (sets `afterPull` to run `WaitingDocuments.run` through `ActorWrite.perform(orAdmin:…, area: .documents, origin: .edit)` on `dbQueue`), `App/DocumentImport/ImportHistoryView.swift` (the success banner at the line using `summary.text` lists each pair, Undo per pair)
- Create: `Sources/BudgetCore/Evidence/WaitingDocumentsNames.swift` (pair → "invoice name  ↔  transaction title" strings via `EvidenceLinkTitles`)
- Test: `Tests/BudgetCoreTests/WaitingDocumentsImportTests.swift`

**Interfaces — Consumes:** Task 1's `WaitingDocuments.run/undo/Pair`. **Produces:** `ImportRunSummary.paymentLinks`; `SyncScheduler.init(…, afterPull:)`; `WaitingDocuments.describe(db: Database, _ pair: Pair) throws -> (document: String, payment: String)`.

- [ ] **Step 1: Write the failing tests:**
  - `testStatementImportLinksWaitingBill`: file a utility bill (no link), apply a statement plan containing its debit through `ImportApplier` → `summary.paymentLinks.count == 1`, `summary.text` contains "1 document linked to its payment", link row exists.
  - `testRunUndoRevertsAutoLinks`: `ImportUndo.undo` of that run removes the link too (no conflicts raised by it).
  - `testFiledYearDebitDoesNotFailTheImport`: a debit that would link into a filed year → import succeeds, no link, `summary.paymentLinks` empty.
  - `testReimportedStatementLinksNothingNew`: duplicates add no pair.
  - `testCSVCommitRunsIt`: `ImportCoordinator.commit(accountId:…)` with a matching row links the waiting bill.
  - `testSchedulerRunsAfterPullOnly`: `SyncScheduler` with `FakeCloud` and a counting `afterPull`: called once per full sync, not for a push-only sync, not when the pull throws.
  - `testSyncMergeLinksWaitingBill` (`Tests/MangoSyncTests` using `TwoPersonHousehold`): device B imports the debit, device A (hook = `WaitingDocuments.run`) pulls → bill linked on A, and the link syncs back as an ordinary document link.
  - `testPairUndoFromSummary`: `WaitingDocuments.undo` for a pair from `summary.paymentLinks` unlinks it and the next `run` leaves it.
- [ ] **Step 2: Run to verify they fail:** `swift test --scratch-path $S9 --filter 'WaitingDocumentsImportTests|SyncSchedulerTests'` → FAIL.
- [ ] **Step 3: Implement** the applier call (inside the existing write, so `ImportChangeCapture` records the links; per-pair `checked` savepoints nest inside it), the summary field and text, the coordinator call, the scheduler hook and the `RealSync` wiring. The hook swallows and logs its own errors (never fails a sync). Skip the job in the applier/coordinator when the batch added no transactions.
- [ ] **Step 4: ImportHistoryView:** under the success banner, one row per pair (`describe`), each with an "Undo" button calling `WaitingDocuments.undo` through the environment's `write(.documents)`, row removed on success; refusal shown inline. Names `.lineLimit(1).truncationMode(.middle)`, fits 1100×700.
- [ ] **Step 5: Run** targeted tests → PASS; full suite; `scripts/check-actor-writes.sh`; Mac build command (App touched).
- [ ] **Step 6: Commit**
  ```bash
  git add Sources App Tests
  git commit -m "Waiting documents link after imports and sync merges; import summary lists them with Undo"
  ```

### Task 3 [sonnet]: Mac UI — Documents filter, state on the document, suggestions

**Files:**
- Modify: `Sources/BudgetCore/Evidence/EvidenceBrowsing.swift` (`LinkState` gains `.waiting`; `EvidenceDocumentSearch.Filter`/`Entry` carry the state from `WaitingDocuments.states`, so the filter stays a pure function of the index), `App/Documents/DocumentsView.swift` (the "Linked or not" chip at ~line 389 shows "Waiting for its payment"; the overview's recent-unlinked list leaves waiting documents out), `App/Documents/DocumentInspector.swift` (state line + the suggestions list, one-click "Link"), `App/Documents/DocumentsViewModel.swift` (`refreshSuggestions` at ~line 260 uses `WaitingDocuments.suggestions` for waiting documents), `Sources/BudgetCore/Evidence/MissingEvidence.swift`/`MissingEvidenceBrowsing.swift` only if an unlinked-document list is found there that must skip `.waiting` documents (grep first; if none, no change)
- Test: `Tests/BudgetCoreTests/EvidenceBrowsingTests.swift` (additions)

**Interfaces — Consumes:** `WaitingDocuments.states(db:now:)`, `.suggestions`, `.State`. **Produces:** `EvidenceDocumentSearch.LinkState.waiting`; `EvidenceDocumentSearch.Entry.waitingState: WaitingDocuments.State`.

- [ ] **Step 1: Write the failing tests** in `EvidenceBrowsingTests`: `testWaitingFilterShowsOnlyWaiting`; `testLapsedIsOrdinaryUnlinked` (shown by `.unlinked`, not by `.waiting`); `testWaitingDocumentIsNotInRecentUnlinked`; `testAnyAndLinkedFiltersUnchanged`.
- [ ] **Step 2: Run to verify they fail:** `swift test --scratch-path $S9 --filter EvidenceBrowsingTests` → FAIL.
- [ ] **Step 3: Implement** the filter case and entry state; the `.waiting` filter hides the Linked/Unlinked notion (`unlinkedOrPartlyPaid` unchanged so the Link-document picker is untouched).
- [ ] **Step 4: Inspector:** a quiet line "Waiting for its payment — Mango links it when the statement arrives" (secondary text, no warning styling) for `.waiting`; for `.lapsed` nothing special. When suggestions exist, a "Possible payments" list (amount, date, account; one "Link" button each) using the existing guarded link path (`DocumentsViewModel` link action, which already shows a filed-year refusal and its confirm warning). Accessibility labels on both.
- [ ] **Step 5: Snapshots/verify:** Mac build command green; render the Documents routes at 1100×700 if `scripts/render-snapshots.sh` exists (report 0 wrap violations), else state that visual check is left to the user.
- [ ] **Step 6: Run** targeted tests, full suite. **Commit**
  ```bash
  git add Sources App Tests
  git commit -m "Documents: filter Waiting for its payment, state and suggestions on the document"
  ```

### Task 4 [sonnet]: iPad — state in the document panel, accept a suggestion via DeviceWriter (most droppable)

**Files:**
- Modify: `Sources/MangoUI/Pad/Shared/DocumentPanelModel.swift` (`DocumentPanelDetails` gains `waiting: Bool`; `load` reads `WaitingDocuments.state`), `Sources/MangoUI/Pad/Shared/DocumentPanel.swift` (the quiet line, same copy as the Mac; hidden when not waiting), `Sources/MangoUI/Pad/Documents/PadDocumentActions.swift` (`linkChoices(for:)` uses `WaitingDocuments.suggestions`; the existing `link(documentId:transactionId:)` already goes through `write.perform` with `FiledYearEditCheck.Scope` — reuse it, no new write path), `Sources/MangoUI/Pad/Documents/PadDocumentsModel.swift` (the Unlinked filter excludes waiting documents; add a "Waiting" filter chip with the Mac's wording)
- Test: `Tests/MangoUITests/DocumentPanelModelTests.swift`, `Tests/MangoUITests/PadDocumentsModelTests.swift` (additions)

**Interfaces — Consumes:** `WaitingDocuments.state/suggestions`. **Produces:** `DocumentPanelDetails.waiting: Bool`.

- [ ] **Step 1: Write the failing tests:** `testPanelShowsWaitingForABillWithNoPayment`; `testPanelNotWaitingOnceLinked`; `testWaitingChipListsOnlyWaiting`; `testAcceptSuggestionLinks` (via `PadDocumentActions.link`, `FakeWriter` as `PadDocumentActionsTests` does); `testAcceptIntoFiledYearIsRefusedInline` (no link, refusal copy from `DeviceWriteCopy`); `testViewerWithoutDocumentsEditSeesNoLinkButton` (`canEdit(.documents)` false → choices empty/hidden).
- [ ] **Step 2: Run to verify they fail:** `swift test --scratch-path $S9 --filter 'DocumentPanelModelTests|PadDocumentsModelTests'` → FAIL.
- [ ] **Step 3: Implement** as listed; no layout beyond one line and a chip. Names truncate in the middle.
- [ ] **Step 4: Verify:** `scripts/build-phone.sh`; `scripts/render-phone-snapshots.sh $S9/snaps --device ipad --only documents` at the four sizes, 0 wrap violations.
- [ ] **Step 5: Run** targeted tests, full suite. **Commit**
  ```bash
  git add Sources Tests
  git commit -m "iPad: Waiting for its payment in the document panel; accept a suggested payment"
  ```
