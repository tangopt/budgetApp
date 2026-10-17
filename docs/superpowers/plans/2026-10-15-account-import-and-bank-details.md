# Import From Accounts, Regional Bank Details, CSV Account Check — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development. Steps use checkbox (`- [ ]`) syntax.

**Spec:** `docs/superpowers/specs/2026-10-15-account-import-and-bank-details-design.md` — read it before any task.

## Global Constraints
- Tests: `swift test --scratch-path <scratchpad>/build-aib`. App: `xcodegen generate && xcodebuild -project Budget.xcodeproj -scheme Budget -destination 'platform=macOS' -derivedDataPath <scratchpad>/dd-aib build 2>&1 | grep -E "warning:|error:|BUILD" | grep -v appintents | sort -u`. Never both at once. No warnings in our code.
- Migrations appended last. TDD for BudgetCore. Use the shared SheetScaffold for sheets.
- `.superpowers/` gitignored: stage only App/Sources/Tests/docs; confirm `git log -1`. Commit trailer `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`. Never push. Never touch `~/Library/Application Support/Budget`; never launch the app on the real DB; never drive the user's screen.

### Task 1: Regional bank details + detail panel section
- [ ] Spec §2, §3. Commit "Accounts: bank details for UK, US, Europe and other regions".

### Task 2: Import from Accounts, reset mapping, CSV account check
- [ ] Spec §1, §4, §5. Commit "Import from Accounts; reset mapping; CSV sort code/account check".

### Task 3: Final review, merge (controller)
