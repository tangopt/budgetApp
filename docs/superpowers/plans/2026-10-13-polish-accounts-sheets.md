# Budget Polish, Account Details, Consistent Sheets Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Budget screen polish (no hint card/caption, uniform year cards with £ change, icon edit button, window-growth fix), account alias + bank details shown across the app, and one consistent sheet/dialog design across the app.

**Architecture:** BudgetCore: Account fields + migration + normalisation helpers (tested). App: Budget view tweaks; `Account.displayName` usage; new `SheetScaffold` in App/DesignSystem applied to every sheet.

**Tech Stack:** Swift 6 / SwiftUI (macOS 26), GRDB 6.29, XCTest, XcodeGen.

**Spec:** `docs/superpowers/specs/2026-10-13-polish-accounts-sheets-design.md` — read it before any task.

## Global Constraints

- Tests: `swift test --scratch-path <scratchpad>/build-ps`. App: `xcodegen generate && xcodebuild -project Budget.xcodeproj -scheme Budget -destination 'platform=macOS' -derivedDataPath <scratchpad>/dd-ps build 2>&1 | grep -E "warning:|error:|BUILD" | grep -v appintents | sort -u`. Never both at once. No compiler warnings in our code.
- Grid smooth scrolling: offset only via HorizontalOffsetFollower, widths only via BodyWidthFollower.
- `.superpowers/` gitignored: stage only App/Sources/Tests/docs; confirm `git log -1`. Commit with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`. Never push. Never touch `~/Library/Application Support/Budget`. Do not launch the app against the real database (use BUDGET_DB_PATH with a scratch DB if you must run it, and never drive the user's screen without asking).

---

### Task 1: Budget polish and window-growth fix
**Files:** `App/Budget/BudgetGridView.swift`, `BudgetGridViewModel.swift`, `AccountFilterPanel.swift`, `App/DesignSystem/TransactionsSidePanel.swift`, `App/ContentView.swift` (window sizing) as needed.
- [ ] Spec §1. Find the window-growth root cause first and describe it in the report. Full suite + app build; commit "Budget polish: uniform year cards with £ change, icon edit, no hint/caption, window keeps its size".

### Task 2: Account alias and details
**Files:** BudgetCore `Models/Account.swift` (+ migration, normalisation/validation helpers, `displayName`), tests; App: Accounts screen + account sheets; every UI site that names an account → `displayName`.
- [ ] Spec §2 (TDD for BudgetCore). List every display site changed in the report. Full suite + app build; commit "Accounts: alias, sort code, account number, IBAN; alias across the app".

### Task 3: Consistent sheets and dialogs
**Files:** new `App/DesignSystem/SheetScaffold.swift`; every file in spec §3's inventory.
- [ ] Spec §3. Report a table: sheet/dialog → what changed. Full suite + app build (zero warnings); commit "Consistent sheets, dialogs and popovers".

### Task 4: Final review, merge (controller)
- [ ] Final review, one fix wave, merge, xcodegen + build in main, push; DB migration on the user's DB happens on next launch (backup first if the controller runs it).
