# Faster Categorising Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Merchant-key learning and history suggestions in BudgetCore, a searchable category picker, and grouped/bulk categorising on the import Review and Uncategorized screens.

**Architecture:** Pure BudgetCore helpers (`MerchantKey`, `HistoryCategorizer`, `CategoryShortlist`) plus changes to `RuleLearner`, `CategorizationService` and `ImportCoordinator.commit`, all XCTest-covered; App gets a shared `CategoryPickerButton` and grouped list UIs.

**Tech Stack:** Swift 6 / SwiftUI (macOS 26), GRDB 6.29, XCTest, XcodeGen.

**Spec:** `docs/superpowers/specs/2026-10-08-faster-categorising-design.md` — read it before any task.

## Global Constraints

- Tests: XCTest, in-memory DB. `swift test --scratch-path /private/tmp/claude-501/-Users-pablo-dimenza-Documents-Code-budget/5fac4f61-c0c9-436b-881b-aebe445aa967/scratchpad/build-fc`. App: `xcodegen generate && xcodebuild -project Budget.xcodeproj -scheme Budget -destination 'platform=macOS' -derivedDataPath /private/tmp/claude-501/-Users-pablo-dimenza-Documents-Code-budget/5fac4f61-c0c9-436b-881b-aebe445aa967/scratchpad/dd-fc build 2>&1 | tail -5`. Never both at once.
- Reserves (`!isAssignable`) never offered or suggested. Existing rules and stored `categorizedBy` values keep working.
- Commit per task with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`. Never push. Never touch `~/Library/Application Support/Budget`.

---

### Task 1: BudgetCore — merchant key, learning, history, shortlist, commit flag

**Files:** create `Sources/BudgetCore/Categorization/MerchantKey.swift`, `HistoryCategorizer.swift`, `CategoryShortlist.swift`; modify `RuleLearner.swift`, `CategorizationService.swift`, `Sources/BudgetCore/Models/Transaction.swift` (`CategorizedBy.history`), `Sources/BudgetCore/Import/ImportCoordinator.swift` (history loaded once for staging; `ImportDecision.learnRule`); tests: new `MerchantKeyTests`, `HistoryCategorizerTests`, `CategoryShortlistTests`, additions to `CategorizationServiceTests` (or the existing service tests), `ImportCoordinatorTests`, rule learner tests.

**Produces:**
```swift
public enum MerchantKey { public static func make(_ description: String) -> String }
extension RuleLearner { public static func learn(description: String, categoryId: Int64, db: Database) throws }
public struct HistoryEntry: Sendable, Equatable { public let merchantKey: String; public let categoryId: Int64 }
public enum HistoryCategorizer {
    public static func load(db: Database) throws -> [HistoryEntry]   // confirmed, categorised transactions
    public static func suggest(merchantKey: String, history: [HistoryEntry]) -> (categoryId: Int64, count: Int, share: Double)?
}
public enum CategoryShortlist { public static func recent(db: Database, since: Date, limit: Int) throws -> [Int64] }
// CategorizedBy gains .history
// CategorizationService.categorizeBatch(descriptions:rules:categories:history: [HistoryEntry] = [])
// ImportDecision(stagedId:finalCategoryId:learnRule: Bool = true)
```
- [ ] Tests first (spec "Testing" list, examples verbatim from spec §1; history: 3×Groceries + 1×Eating Out for "TESCO STORES" → Groceries count 3 share 0.75; 1×Groceries + 1×Eating Out → nil; single transaction → nil; order: a rule beats history, history beats the model; commit with `learnRule: false` creates no rule, `true` creates a key rule).
- [ ] Implement; full suite + app build; commit "Categorising: merchant keys, history suggestions, recent categories".

### Task 2: Shared category picker

**Files:** create `App/DesignSystem/CategoryPickerButton.swift`; use it in `App/Import/ReviewView.swift` and `App/Uncategorized/UncategorizedView.swift` in place of the current `Picker` (no grouping yet).

- [ ] `CategoryPickerButton(selection: Binding<Int64?>, categories: [Category], groups: [CategoryGroup], suggestedId: Int64?, recentIds: [Int64], amountMinorUnits: Int?)` per spec §3 (search, Suggested / Recent / grouped sections, sign filter + "Show all categories", Uncategorized option, ↑/↓/Return/Escape).
- [ ] View models load `recentIds` via `CategoryShortlist.recent(since: 90 days ago, limit: 5)` and the category groups.
- [ ] Review rows with `.history` source show "Suggested from N past transactions" (N carried on the staged row; add what's needed) and the confidence dot treats `.history` like a rule-level suggestion.
- [ ] Full suite + app build; commit "Searchable category picker on Review and Uncategorized".

### Task 3: Review screen grouping, bulk and Remember

**Files:** `App/Import/ReviewView.swift`, `App/Import/ImportViewModel.swift` (split a `ReviewGrouping` helper if large).

- [ ] Group rows by `MerchantKey.make(rawDescription)` within "Needs your attention" and "Ready to confirm" per spec §4 (group row with × N, date range, total, group picker, disclosure; "Mixed" when rows differ; single rows unchanged).
- [ ] Multi-select (⌘/⇧-click) of rows and groups; **Set category…** applies to all selected rows; **Remember for <key>** toggle (default on for group/2+ rows, off for single rows) stored per row as `learnRule`, passed in `ImportDecision`.
- [ ] Confirm / Confirm N ready / Save remaining / Return-to-confirm keep working; confirming a group confirms its rows.
- [ ] Full suite + app build; commit "Import review: group similar transactions, bulk set category, remember".

### Task 4: Uncategorized screen grouping and bulk

**Files:** `App/Uncategorized/UncategorizedView.swift`, `UncategorizedViewModel.swift`.

- [ ] Same grouping by merchant key, multi-select, Set category…, picker, Remember toggle (spec §5); saving updates each transaction and learns a key rule (`RuleLearner.learn`) only when Remember is on.
- [ ] Full suite + app build; commit "Uncategorized: group, bulk set category, remember".

### Task 5: Final review, merge (controller)

- [ ] Final whole-branch review, one fix wave, merge to main, `xcodegen generate` + xcodebuild in the main checkout, push.
