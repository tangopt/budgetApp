# Side Panels, Year Cards, Categories Screen Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Budget year cards with year-end net worth, a right side panel replacing the drill-down pop-up (with selected-cell outline, groups/sections), note indicators on cells, a reorganised Categories screen with its own transactions panel, and an Accounts chart hover readout.

**Architecture:** Small tested BudgetCore helpers (year-end net worth per year, category/group operations, monthly average); a reusable `TransactionsSidePanel` view in App/DesignSystem used by Budget and Categories.

**Tech Stack:** Swift 6 / SwiftUI + Swift Charts (macOS 26), GRDB 6.29, XCTest, XcodeGen.

**Spec:** `docs/superpowers/specs/2026-10-12-panels-and-categories-design.md` — read it before any task.

## Global Constraints

- Tests: `swift test --scratch-path /private/tmp/claude-501/-Users-pablo-dimenza-Documents-Code-budget/5fac4f61-c0c9-436b-881b-aebe445aa967/scratchpad/build-pc`. App: `xcodegen generate && xcodebuild -project Budget.xcodeproj -scheme Budget -destination 'platform=macOS' -derivedDataPath /private/tmp/claude-501/-Users-pablo-dimenza-Documents-Code-budget/5fac4f61-c0c9-436b-881b-aebe445aa967/scratchpad/dd-pc build 2>&1 | tail -5`. Never both at once.
- Grid smooth scrolling: scroll offset observed only by HorizontalOffsetFollower, widths only by BodyWidthFollower; sizes from GridMetrics.
- `.superpowers/` is gitignored: stage only App/Sources/Tests/docs; confirm `git log -1`.
- Commit per task with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`. Never push. Never touch `~/Library/Application Support/Budget`.

---

### Task 1: Budget year cards + Accounts chart readout

**Files:** `App/Budget/BudgetGridView.swift` (yearPicker), `BudgetGridViewModel.swift`, BudgetCore helper for year-end net worth if needed (+ tests); `App/Accounts/AccountsView.swift` (chart readout).

- [ ] Spec §1 and §5. Full suite + app build; commit "Budget year cards with year-end net worth; Accounts chart hover readout".

### Task 2: Budget side panel, selected cell, note indicators

**Files:** new `App/DesignSystem/TransactionsSidePanel.swift`; `App/Budget/BudgetGridView.swift`, `BudgetGridViewModel.swift`, `GridDrillDownSheet.swift` (replace/retire), `EditTransactionSheet.swift` (reuse).

- [ ] Spec §2 and §3 (panel for category/group/section/reserve/Year Total/year columns; outline; Escape/✕; notes shown; triangle indicator; empty open-month cells still add). Full suite + app build; commit "Budget: side panel for cell transactions, selected cell, note indicators".

### Task 3: Categories screen

**Files:** BudgetCore `Categories.swift` / new `CategoryGroups.swift` / `CategoryStats.swift` (+ tests); rewrite `App/Categories/CategoriesView.swift` (+ view model split if large).

- [ ] Spec §4 (sections by type, groups collapsible with counts, Ungrouped, Reserves read-only; search; + Group inline; group ⋯ menu; + Category; multi-select drag to group; right-click Move to / Rename / Exclude / Delete with readable refusal; 12-month average; transactions side panel with year filter, reusing TransactionsSidePanel + EditTransactionSheet). Full suite + app build; commit "Categories screen: organised by type and group, drag to move, transactions panel".

### Task 4: Final review, merge (controller) — runs after Task 5

- [ ] Final review, one fix wave, merge, `xcodegen generate` + build in main, push.

### Task 5 (added): Transfers between own accounts

**Files:** BudgetCore new `Models/TransferLink.swift` (+ migration), `Import/TransferMatcher.swift`, Transaction budget-facing helper; every transaction load site used for budget/plan/dashboard/history/uncategorized/scenarios/auto-forecast; ImportCoordinator (match after commit; review badge data); App launch hook; App panels / EditTransactionSheet (link display, Unlink, Link to transfer…); Review row badge.

- [ ] Spec §6. Tests first for the matcher (same currency, FX tolerance, ±3 days, closest date, ties unmatched, dismissed never relinked, one link per incoming transaction; historical spreadsheet rows: same pay month, single equal amount, smallest exact-sum set, ambiguous sets unmatched) and for budget-facing exclusion in at least BudgetGridCalculator, DashboardCalculator flows, PayMonthTotals, UncategorizedTransactions, HistoryCategorizer; balances unchanged. Full suite + app build; commit "Transfers between your accounts: auto-match, count once as sent".

### Task 6 (added): Budget account filter

**Files:** `App/Budget/BudgetGridView.swift`, `BudgetGridViewModel.swift`, new `App/Budget/AccountFilterPanel.swift`, BudgetCore helpers for per-account actuals if needed (+ tests), TransactionsSidePanel (account name).

- [ ] Spec §7 (and §6 transfer rule with a filter). Tests for the filtered actuals and transfer counting with filters. Full suite + app build; commit "Budget: account filter panel".
