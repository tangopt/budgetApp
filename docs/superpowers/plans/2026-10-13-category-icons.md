# Category Icons Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development.

**Spec:** `docs/superpowers/specs/2026-10-13-category-icons-design.md`

## Global Constraints
- Tests: `swift test --scratch-path <scratchpad>/build-ci`. App: `xcodegen generate && xcodebuild -project Budget.xcodeproj -scheme Budget -destination 'platform=macOS' -derivedDataPath <scratchpad>/dd-ci build 2>&1 | grep -E "warning:|error:|BUILD" | grep -v appintents | sort -u`. Never both at once; no warnings.
- Migration appended last (after the account-order migration if merged). Stage only App/Sources/Tests/docs; Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>. Never push; never touch ~/Library/Application Support/Budget; never drive the user's screen.

### Task 1: Category icons
- [ ] Spec in full; TDD for setIcon + migration. Full suite + app build; commit "Categories: own icon per category, clearer labels".
