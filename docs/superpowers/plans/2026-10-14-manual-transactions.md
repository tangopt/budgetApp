# Manual Transactions Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development.

**Spec:** `docs/superpowers/specs/2026-10-14-manual-transactions-design.md`

## Global Constraints
- Tests: `swift test --scratch-path /private/tmp/claude-501/-Users-pablo-dimenza-Documents-Code-budget/5fac4f61-c0c9-436b-881b-aebe445aa967/scratchpad/build-mt`. App: `xcodegen generate && xcodebuild -project Budget.xcodeproj -scheme Budget -destination 'platform=macOS' -derivedDataPath /private/tmp/claude-501/-Users-pablo-dimenza-Documents-Code-budget/5fac4f61-c0c9-436b-881b-aebe445aa967/scratchpad/dd-mt build 2>&1 | grep -E "warning:|error:|BUILD" | grep -v appintents | sort -u`. Never both at once; no warnings.
- Migration appended last. Nothing written before Finish import (except Categories.create). Sheets use SheetScaffold. Stage only App/Sources/Tests/docs; Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>. Never push; never touch ~/Library/Application Support/Budget; never drive the user's screen.

### Task 1: BudgetCore — manual transactions, other side, import replacement
- [ ] Spec §1 and §3 core (ManualTransactions add/update/delete/addOtherSide; staging annotation + commit replacement), TDD. Full suite; commit "Manual transactions: core".

### Task 2: App — Add transaction, Edit/Delete manual, Add the other side, review badge
- [ ] Spec §2 and §3 UI. Full suite + app build; commit "Manual transactions: add, edit, other side, import replacement".

### Task 3: Final review, merge (controller)
