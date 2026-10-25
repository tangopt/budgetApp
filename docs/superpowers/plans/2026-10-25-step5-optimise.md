# Step 5: Optimise the Codebase — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make everyday development fast — a fix round under 5 min, the full suite under 4 min, an everyday install under 2 min — and make the app's filed-year check fast, without changing any behaviour.

**Architecture:** Measure first (done: `2026-10-25-step5-measurements.md`), then change only what the measurements point at: shared template databases for tests, an incremental install, a cheaper snapshot loop, a faster `TaxFigures.snapshot`, the slowest tests, and the tool targets out of the default build. Test pruning only with the user's approval of the list.

**Tech Stack:** Swift 6 / SwiftPM, GRDB, XCTest, XcodeGen, xcodebuild, zsh scripts.

**Spec:** the agreed step 5 shape (memory `feedback-dev-speed.md`) and the measurements note `docs/superpowers/plans/2026-10-25-step5-measurements.md`.

## Global Constraints

- No behaviour change in the apps. Every figure the app shows stays identical; filed SA returns 2020/21–2024/25 must reproduce exactly.
- No sync schema change.
- Tests stay synthetic; no personal data in the repo.
- Never touch the real database, Keychain, iCloud or the installed app from a subagent; read-only copies of the real DB for timing/equality checks only, deleted afterwards.
- Build in worktrees outside iCloud-synced folders or pass `--scratch-path` (CodeSign fails on `.build` inside ~/Documents).
- Measure before and after each task and record the numbers in the task report.

## Review Focus

- A shared template database leaking state between tests (a test mutating the template, or parallel tests sharing one file).
- The incremental install shipping a stale or wrongly signed app (Developer ID signature, entitlements, iCloud container, Touch ID Keychain access group).
- `TaxFigures.snapshot` changes altering any figure, including brought-forward amounts, apportionment and currency conversion.
- Snapshot "changed routes only" mode silently skipping routes a change affects.
- Pruned or merged tests losing a behaviour no other test covers.

---

### Task 1: Tests use template databases

**Files:** Create `Tests/TestSupport/TestDatabase.swift` (or the existing shared test-support target if there is one); modify the test files with private `makeDB()` / `emptyDatabase()` / `demoDatabase()` / `migrated` / `makeManager` helpers.

- [ ] `TestDatabase.migrated() throws -> DatabaseQueue` (in-memory or temp-file copy of a database migrated once per process via `backup(to:)`), `TestDatabase.demo() throws -> DatabaseQueue` (copy of a demo database built once per process). Each call returns an independent database.
- [ ] Replace the private helpers; tests that need a file path get a temp-file copy.
- [ ] Test: two copies are independent (a write to one isn't seen by the other or by a later copy); migrations recorded equal a fresh migration's.
- [ ] Before/after: `swift test --parallel` and serial wall time. Target parallel ≤ 150 s.
- [ ] Commit: "Tests: copy one migrated and one demo database instead of building them per test"

### Task 2: Incremental install

**Files:** `scripts/install-app.sh`.

- [ ] Everyday path: arm64 Release `build` into the persistent cache (incremental), then Developer ID signing via `-exportArchive`-equivalent or `codesign` with the same identity, entitlements and provisioning as today's export; `--notarise` keeps today's universal archive path.
- [ ] Consider compiling packages without WMO for the local path (e.g. `SWIFT_COMPILATION_MODE=singlefile`) if it brings a BudgetCore change under 2 min; measure runtime impact on `TaxFigures.snapshot` and app launch.
- [ ] Verify the produced app: `codesign -dv --entitlements -`, team, iCloud container, keychain access groups, hardened runtime identical to today's export (diff them). Never install from a subagent — produce the .app in a scratch folder only.
- [ ] Before/after timings: no change, App-only change, BudgetCore change.
- [ ] Commit: "Install: build incrementally for this Mac; archive only when notarising"

### Task 3: Snapshot loop

**Files:** `scripts/render-snapshots.sh`, `App/Snapshots/*`.

- [ ] `--quick`: one look (light-classic) and an explicit route list or `--changed` (routes whose source files changed vs a base ref, with a fallback to all routes when unsure).
- [ ] Cache the import-review plan per process so imports routes don't re-run the import per look.
- [ ] Full run unchanged in output (same PNG set, 0 violations). Before/after timings.
- [ ] Commit: "Snapshots: a quick mode for fix rounds; imports routes reuse their plan"

### Task 4: Faster `TaxFigures.snapshot`

**Files:** `Sources/BudgetCore/Tax/*`, `Sources/BudgetCore/Property/RentalAccounts.swift`, `Recharges.swift`, date helpers.

- [ ] Batch `Recharges.received` (one query per snapshot, date filter in SQL); cache earlier years' brought-forward results within one snapshot call; read `linkedDocuments` once per snapshot; shared static date formatters.
- [ ] Equality proof: on a READ-ONLY copy of the real DB, every year's full snapshot before == after (all fields, all persons), printed as a pass/fail count only, plus the existing test suite. Synthetic regression test for the brought-forward chain.
- [ ] Before/after: Release timing for 1 year and 10 years. Target ≤ 0.15 s.
- [ ] Commit: "Tax: figures snapshot without repeated lookups and recomputation"

### Task 5: Slowest tests

- [ ] ImportRehearsal (56 s), ImportSession, DemoImportKinds, SyncRehearsal: reuse the Task 1 demo copy, shrink inputs where the assertion doesn't need the full set, split the 56 s test so parallel runs aren't floored by it. Same assertions.
- [ ] Before/after per class.
- [ ] Commit: "Tests: the slowest end-to-end tests share setup and split"

### Task 6: Tools out of the default build

- [ ] Move the one-off tool executables so a plain `swift build` / `swift test` doesn't relink them on every BudgetCore interface change (a separate `Tools/` package depending on the main package, or products built only on demand). Keep every tool runnable (`swift run --package-path Tools <Tool>`), update docs/scripts/memory that name `swift run <Tool>`.
- [ ] Before/after: BudgetCore interface edit → `swift build` time.
- [ ] Commit: "Build: tools live in their own package"

### Task 7: Prune and merge tests (needs the user's approval of the list)

- [ ] Only the items the user approved: remove plain insert-and-fetch tests covered by service tests; turn same-pattern tests into table-driven tests where the code under test is shared. Show before/after test counts and that coverage of each behaviour remains.
- [ ] Commit: "Tests: remove duplicates, table-driven where the code is shared"

### Task 8: Re-measure

- [ ] Repeat the measurements note's key numbers; record against the targets in the note.
