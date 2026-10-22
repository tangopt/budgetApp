# Build step 2: BudgetCore on iOS — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** make BudgetCore build for iOS/iPadOS 26 and move the import centre's decision logic and the "where actuals come from" seam into BudgetCore, so the iPhone and iPad apps can reuse them unchanged. The Mac app behaves exactly as before.

**Architecture:**
- **Platform:** `Package.swift` gains `.iOS("26.0")`. The few macOS-only APIs in BudgetCore are fenced or moved out.
- **Import logic:** what `App/DocumentImport/ImportCenterModel.swift` decides (phases, answers, confirm, undo, rule fits) moves into a BudgetCore `ImportSession`. `ImportCenterModel` keeps only the main-actor publishing and the AppKit plumbing.
- **Actuals seam:** a BudgetCore `ActualsSource` becomes the one place screens get the transactions their calculators use. For now it returns local transactions only; it gains summary records with sharing levels in build step 5.

**Tech Stack:** Swift 6, SwiftPM, GRDB 6.29, XCTest; `xcodebuild -scheme BudgetCore -destination 'generic/platform=iOS'` for the iOS build check.

**Spec:**
- `docs/superpowers/specs/2026-10-22-companion-apps-overview.md` §4, build step 2.
- `docs/superpowers/specs/2026-10-22-sync-and-access-design.md` §7 (BudgetCore on iOS, `ActualsSource`).

## Global Constraints

- The Mac app's behaviour doesn't change: the full suite passes, the app builds (`Mango.xcodeproj`, scheme `Mango`), and snapshot routes render with 0 wrap violations.
- BudgetCore builds for iOS with no errors: `xcodebuild -scheme BudgetCore -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build`. Tests still run on macOS only.
- No AppKit or UIKit in BudgetCore. Anything that touches the Mac's file system or other apps (home directory, NSWorkspace, running apps) stays in the App or CLI targets, or sits behind `#if os(macOS)`.
- No database schema change in this step.
- Filed SA returns are unchanged: `SelfAssessmentRegressionTests` passes.
- No personal data in tests or commits.
- `swift test` uses a scratch path outside `~/Documents`.

## Review Focus

1. **An import confirmed or undone through the new `ImportSession` must give byte-identical results to before.** Test in Task 3: replay the existing ImportCenter-level flows (plan → answer → confirm → undo) through `ImportSession`, then compare the database with `ImportChangeCapture.trackedTables`.
2. **Cancelling a read mid-way, then starting another, must leave no stale results.** Test in Task 3 (`testCancelThenRestartShowsOnlyTheNewPlan`).
3. **The Dashboard, Budget grid and Forecast must show identical figures via `ActualsSource`.** Test in Task 2: same calculator outputs from the demo database through old and new loading.
4. **A BudgetCore API used only on macOS must not silently disappear on iOS where the iPad needs it** (for example source-folder scanning). Task 1 lists every `#if os(macOS)` and says what iOS gets instead.
5. **The iOS build check must be repeatable and must fail loudly.** Task 1 adds `scripts/build-core-ios.sh`, which exits non-zero on any error.

---

### Task 1: BudgetCore builds for iOS

**Files:**
- Modify:
  - `Package.swift`: platforms become `[.macOS("26.0"), .iOS("26.0")]`.
  - `Sources/BudgetCore/Tax/TaxRegression.swift`: the `homeDirectoryForCurrentUser` use (line ~440) moves behind `#if os(macOS)`, or its caller (the CLI) passes the path in.
  - Any other iOS build errors that appear.
- Create: `scripts/build-core-ios.sh`, which runs the iOS build of BudgetCore and exits non-zero on error.
- Report: every `#if os(macOS)` in BudgetCore, for example `SourceFolderScanner`, with what iOS does instead.

**Interfaces:**
- Produces: a BudgetCore that builds for iOS. The script prints `iOS build OK` on success.

- [ ] **Step 1:** Add the platform. Run `scripts/build-core-ios.sh` and expect FAIL listing the errors (at least `homeDirectoryForCurrentUser` in TaxRegression).
- [ ] **Step 2:** Fix each error with the smallest change. Prefer moving Mac-only behaviour to the caller over `#if`.
- [ ] **Step 3:** Run the script and expect `iOS build OK`. Then the full suite, the Mango app build, and one snapshot route; expect all green.
- [ ] **Step 4: Commit** "BudgetCore builds for iOS 26; build check script".

### Task 2: ActualsSource seam

**Files:**
- Create: `Sources/BudgetCore/Budget/ActualsSource.swift`
- Modify: the App loaders that fetch transactions for the Dashboard, Budget grid and Forecast (find the `Transaction.fetchAll` / `DashboardInput(...)` / `BudgetGridCalculator` call sites in `App/Dashboard`, `App/Budget*` and `App/Forecast`). They get their transactions from `ActualsSource`.
- Test: `Tests/BudgetCoreTests/ActualsSourceTests.swift`

**Interfaces:**
- Produces:
  - `public protocol ActualsSource { func transactions(_ db: Database) throws -> [Transaction] }`
  - `public struct LocalActualsSource: ActualsSource` (all local transactions, the same set the loaders read today).
  - `public static let local = LocalActualsSource()` on `ActualsSource where Self == LocalActualsSource`.
- Doc comment: in build step 5, private accounts below "Everything" contribute summary rows here (sync spec §6.1).

- [ ] **Step 1:** Write the failing test `testLocalSourceMatchesTodaysLoad`: on the demo database, `LocalActualsSource().transactions(db)` equals the set the existing loaders read, and the Dashboard and Budget-grid calculator outputs built from each are equal.
- [ ] **Step 2:** Implement, then switch the three loaders to it.
- [ ] **Step 3:** Run the full suite, the app build and the snapshots for `dashboard`, `budget` and `forecast` routes (0 violations, unchanged figures), and the iOS build script. Expect all green.
- [ ] **Step 4: Commit** "ActualsSource: one place the screens' actuals come from".

### Task 3: Import centre decision logic into BudgetCore

**Files:**
- Create: `Sources/BudgetCore/DocumentImport/ImportSession.swift` (and split files if it passes ~600 lines).
- Modify: `App/DocumentImport/ImportCenterModel.swift`, which becomes a thin `@MainActor ObservableObject` that owns an `ImportSession`, republishes its state, and keeps only AppKit or UI concerns: open panels, `onShow`, `NSSound`/notifications, focus.
- Test: `Tests/BudgetCoreTests/ImportSessionTests.swift`

**Interfaces:**
- Produces `ImportSession`, an `actor` or a `final class` confined to one executor; the implementer decides, and the decision is recorded. It has:
  - `phase` (`idle`, `reading(ImportProgress)`, `review`, `applying`, `finished(ImportRunSummary)`, `failed(String)`). Move the existing `ImportCenterModel.Phase` and keep the case names.
  - `plan`, `ruleFits` and `libraryCounts`.
  - Methods with the existing names and semantics from `ImportCenterModel`:
    - `start(inputs)`, `start(folder:inputs:)`, `startFromLibrary(_:)`;
    - `cancelReading()`;
    - `resolve(_:issueId:resolution:)` and its siblings;
    - `applyRule(...)` and the undo of rule changes;
    - `confirm(confirmedBy: Int64?)`;
    - `undo(run:)`, `loadRuns()`.
  - A change stream for the UI: `AsyncStream<ImportSession.Snapshot>`, or a callback. The implementer decides and records it.
- `ImportCenterModel` keeps its public API, so the views don't change apart from the `Phase` type's new module.

- [ ] **Step 1:** Write failing `ImportSessionTests` from the existing ImportCenterModel behaviours, using synthetic files from the demo samples:
  - `testPlanAnswerConfirmUndoRoundTrip` (Review Focus 1: the database after undo equals the database before);
  - `testCancelThenRestartShowsOnlyTheNewPlan` (Review Focus 2);
  - `testConfirmUsesTheGivenUser`;
  - `testRuleFitsAppliedAndUndone`;
  - `testStagesReportedInOrder`.
- [ ] **Step 2:** Move the logic, method by method, keeping the names. `ImportCenterModel` delegates.
- [ ] **Step 3:** Run the full suite (including all existing import tests), the app build, the import snapshot routes (`imports-*`, 0 violations; `imports-history_confirmed_by` still OK) and the iOS build script. Expect all green.
- [ ] **Step 4: Commit** "Import centre decision logic moves into BudgetCore (ImportSession); the Mac model is a thin wrapper".

## Deferred (ruling)

- **The iOS snapshot harness** (overview §4 lists it in step 2) moves to build step 4, together with the first iOS app target. A harness needs an app to host it, and this Mac's simulator runtime is out of date ("CoreSimulator is out of date"), so it can't run yet. Cost: none until step 4.

### Task 4: The shared test suite runs on the iOS simulator (added 2026-10-23)

Why: the user asked whether tests differ per platform. Building for iOS proves the code compiles there, not that it behaves the same. The shared logic's tests should pass on iOS as well as on the Mac.

**Files:**
- Create: `.swiftpm/xcode/xcshareddata/xcschemes/BudgetCoreTests.xcscheme`, a shared test scheme. The controller has drafted it; force-add it, because `.swiftpm/` is git-ignored, or add a `.gitignore` exception for `xcshareddata`.
- Create: `scripts/test-core-ios.sh`, which runs `xcodebuild test -scheme BudgetCoreTests -destination 'platform=iOS Simulator,name=iPhone 17'` and exits non-zero on any failure.
- Modify: `Tests/BudgetCoreTests/CategoryIconsTests.swift`, which imports AppKit. Fence the Mac-only part with `#if canImport(AppKit)`, or test the platform-neutral part on both platforms.
- Modify: other tests or code as the run shows.

- [ ] **Step 1:** Run the script and expect FAIL: the first failure is the AppKit import.
- [ ] **Step 2:** Make the suite compile on iOS. Then classify every runtime failure:
  - (a) a real behaviour difference in BudgetCore on iOS. Fix the code so both platforms agree, and add a test that pins it.
  - (b) a test that assumes the Mac, such as an absolute path, the home directory or a fixture location. Fix the test so it is platform-neutral.
  - (c) behaviour that legitimately differs by platform. Fence it explicitly and document why.

  List each failure with its class in the report. Never skip or delete a test to get green.
- [ ] **Step 3:** Run `scripts/test-core-ios.sh` (all pass), the Mac suite, the Mango app build and `scripts/build-core-ios.sh`, and expect all green.
- [ ] **Step 4: Commit** "Shared tests run on the iOS simulator too".
