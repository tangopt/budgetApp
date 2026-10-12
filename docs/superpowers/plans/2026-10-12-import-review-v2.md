# Import Review v2 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Trustworthy "Ready", complete groups, Remember on single rows, create categories from the picker, transaction notes + Edit transaction, conditional sidebar items, and a three-tab review.

**Architecture:** BudgetCore: partitioning change, `ReviewKey`, `Categories.create`, `TransactionEditing`, migration for notes (XCTest). App: picker/sheet additions, ReviewView tabs, sidebar visibility.

**Tech Stack:** Swift 6 / SwiftUI (macOS 26), GRDB 6.29, XCTest, XcodeGen.

**Spec:** `docs/superpowers/specs/2026-10-12-import-review-v2-design.md` — read it before any task.

## Global Constraints

- Tests: XCTest, in-memory DB. `swift test --scratch-path /private/tmp/claude-501/-Users-pablo-dimenza-Documents-Code-budget/5fac4f61-c0c9-436b-881b-aebe445aa967/scratchpad/build-rv`. App: `xcodegen generate && xcodebuild -project Budget.xcodeproj -scheme Budget -destination 'platform=macOS' -derivedDataPath /private/tmp/claude-501/-Users-pablo-dimenza-Documents-Code-budget/5fac4f61-c0c9-436b-881b-aebe445aa967/scratchpad/dd-rv build 2>&1 | tail -5`. Never both at once.
- Nothing is written to the database before Finish import (existing behaviour). Migrations appended last.
- `.superpowers/` is gitignored: stage only App/Sources/Tests/docs; confirm `git log -1`.
- Commit per task with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`. Never push. Never touch `~/Library/Application Support/Budget`.

---

### Task 1: BudgetCore — ready rules, review keys, categories, notes, transaction editing

**Files:** `Sources/BudgetCore/Import/ReviewPartitioning.swift`, new `Sources/BudgetCore/Categorization/ReviewKey.swift`, `ReviewGrouping.swift` (use review keys; processor-group Remember default off; single-row picked default on), new `Sources/BudgetCore/Models/Categories.swift` (or extend an existing category helper), new `Sources/BudgetCore/Import/TransactionEditing.swift`, `Transaction.swift` (+ migration `addTransactionNote`), `ImportCoordinator.swift` (ImportDecision.note), tests.

**Produces:** `ReviewKey.groupKeys(descriptions:) -> [String]`; `ReviewKey.isProcessorGroup(_ key: String) -> Bool`; partition that never readies `.llm` and partitions by group; `ReviewGrouping.remembers(choice:groupRowCount:isProcessorGroup:pickedByHand:)` (or equivalent extension of the existing function — document the final signature in the report); `Categories.create(db:name:type:groupId:) throws -> Category`; `Transaction.note`; `ImportDecision(stagedId:finalCategoryId:learnRule:note:)`; `TransactionEditing.update(db:id:categoryId:note:)`.

- [ ] Tests first for every spec §1–§5 BudgetCore rule (examples verbatim from spec §2 incl. the user's real keys).
- [ ] Implement; full suite + app build (fix any App compile breaks minimally); commit "Import review v2 core: ready rules, review keys, categories, notes".

### Task 2: Picker "New category…", notes UI, Edit transaction, single-row Remember

**Files:** `App/DesignSystem/CategoryPickerButton.swift` (+ new `NewCategorySheet.swift`), `App/Import/ReviewView.swift` / `ImportViewModel.swift` (note button, single-row Remember checkbox), `App/Uncategorized/*` (same), `App/Budget/GridDrillDownSheet.swift` (+ new `EditTransactionSheet.swift`, reloading the grid after save).

- [ ] Per spec §3–§5. Full suite + app build; commit "Review: new category from picker, notes, single-row Remember; Edit transaction".

### Task 3: Three-tab review

**Files:** `App/Import/ReviewView.swift`, `ImportViewModel.swift` (ReviewSections per tab).

- [ ] Per spec §7 (tabs with counts, separate lists and selections, Confirm all on Ready, Confirmed with Undo, auto-switch when a tab empties, pinned notices/caption/actions, Return and ⌘Return). Full suite + app build; commit "Review in three lists".

### Task 4: Sidebar shows Import and Uncategorized only when needed

**Files:** `App/ContentView.swift`, `App/Dashboard/FreshnessImportCard.swift` / `DashboardView.swift` (Edit column mapping…), `App/Import/ImportView.swift` / `ImportFlowHost.swift`, `App/Uncategorized/*`.

- [ ] Per spec §6 (visibility, auto-select on start, back to Dashboard on finish/cancel/last uncategorised assigned, count label, mapping edit on the Dashboard card, guard unchanged). Full suite + app build; commit "Sidebar: Import and Uncategorized only when there is something to do".

### Task 5: Final review, merge (controller)

- [ ] Final whole-branch review, one fix wave, merge, `xcodegen generate` + build in main, push.
