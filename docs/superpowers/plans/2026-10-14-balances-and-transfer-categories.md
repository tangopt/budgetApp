# Balances + Transfer Categories Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development.

**Spec:** `docs/superpowers/specs/2026-10-14-balances-and-transfer-categories-design.md`

## Global Constraints
- Tests: `swift test --scratch-path /private/tmp/claude-501/-Users-pablo-dimenza-Documents-Code-budget/5fac4f61-c0c9-436b-881b-aebe445aa967/scratchpad/build-bt`. App: `xcodegen generate && xcodebuild -project Budget.xcodeproj -scheme Budget -destination 'platform=macOS' -derivedDataPath /private/tmp/claude-501/-Users-pablo-dimenza-Documents-Code-budget/5fac4f61-c0c9-436b-881b-aebe445aa967/scratchpad/dd-bt build 2>&1 | grep -E "warning:|error:|BUILD" | grep -v appintents | sort -u`. Never both at once; no warnings.
- Migrations appended last. Nothing written before Finish import / Save. SheetScaffold for sheets. Stage only App/Sources/Tests/docs; Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>. Never push; never touch ~/Library/Application Support/Budget; never drive the user's screen.

### Task 1: Balance model + built-in adjustment categories + Update balance (core + app)
### Task 2: Statement mismatch on import (core + review UI + account warning)
### Task 3: Conversion tool (BudgetCore function + scratch executable target excluded from the app) with verification
### Task 4: Transfer categories per account (core + Categories screen + apply on link)
### Task 5: Final review, merge (controller); then data conversion with user go-ahead
