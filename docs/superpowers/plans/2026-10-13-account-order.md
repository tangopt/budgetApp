# Account Order Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development.

**Spec:** `docs/superpowers/specs/2026-10-13-account-order-design.md`

## Global Constraints
- Tests: `swift test --scratch-path <scratchpad>/build-ao`. App: `xcodegen generate && xcodebuild -project Budget.xcodeproj -scheme Budget -destination 'platform=macOS' -derivedDataPath <scratchpad>/dd-ao build 2>&1 | grep -E "warning:|error:|BUILD" | grep -v appintents | sort -u`. Never both at once; no warnings.
- Migration appended last. Stage only App/Sources/Tests/docs; Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>. Never push; never touch ~/Library/Application Support/Budget; never drive the user's screen.

### Task 1: Account order (BudgetCore + Accounts screen + Budget panel/grid + pickers)
- [ ] Spec in full; TDD for AccountOrdering + migration. Full suite + app build; commit "Accounts: alphabetical by default, drag to reorder".
