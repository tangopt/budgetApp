# Show/Hide Forecast and Forecast per Account — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development.

**Spec:** `docs/superpowers/specs/2026-10-15-forecast-by-account-design.md` — read it before any task.

## Global Constraints
- Tests: `swift test --scratch-path /private/tmp/claude-501/-Users-pablo-dimenza-Documents-Code-budget/5fac4f61-c0c9-436b-881b-aebe445aa967/scratchpad/build-fa`. App: `xcodegen generate && xcodebuild -project Budget.xcodeproj -scheme Budget -destination 'platform=macOS' -derivedDataPath /private/tmp/claude-501/-Users-pablo-dimenza-Documents-Code-budget/5fac4f61-c0c9-436b-881b-aebe445aa967/scratchpad/dd-fa build 2>&1 | grep -E "warning:|error:|BUILD" | grep -v appintents | sort -u`. Never both at once; no warnings.
- Migrations appended last. TDD for BudgetCore. Grid smooth scroll: offset only via HorizontalOffsetFollower, widths only via BodyWidthFollower.
- Stage only App/Sources/Tests; commit trailer `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`; confirm `git log -1`. Never push; never touch `~/Library/Application Support/Budget`; never launch the app on the real DB; never drive the screen.

### Task 1: Planned item accounts (core)
- [ ] Spec §2 core: migration, `PlannedItemAccounts` inference + effective account, transfer-category split, scenario copies keep accountId; budget calculator per-account planned amounts; net-worth projection per account set (§4). Tests. Commit "Planned items: account, inferred from category history".

### Task 2: Budget UI
- [ ] Spec §1, §2 sheets, §3, §4: Show forecast toggle; Account picker in planned item sheets (and scenario entry editing); filtered grid with planned items; side panel account names; net-worth rows and year cards follow filter and toggle. Commit "Budget: show/hide forecast; forecast and net worth per account".

### Task 3: Final review, merge (controller)
