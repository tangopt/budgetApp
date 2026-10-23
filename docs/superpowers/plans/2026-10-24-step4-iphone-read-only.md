# Build step 4: the read-only iPhone app for the admin — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (chosen) to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** an iOS 26 app, `ubberninja.mango.ios`, that pulls the household zone from CloudKit in the sealed format, locks with Face ID or the passcode, and shows Home, Month, Accounts, Property and Search read-only, with every figure from BudgetCore; plus the sync scheduler both apps use, and the TestFlight packaging, prepared but not uploaded.

**Architecture:**
- **BudgetCore** gains the scheduler (`SyncScheduler`, around `SyncEngineCore`), the activation policy that keeps the real Mac database off sync, the mobile lock policy, and the three phone calculators (`HomeSummary`, `PayMonthReview`, `PropertySummary`) that package existing calculators' figures for small screens. Nothing in the App layers computes a total.
- **`MangoSync`** (new SwiftPM target, CloudKit + Security) holds what both apps share and BudgetCore may not import: `CloudKitTransport`, `KeychainSyncKeyStore` (moved from `App/Sync/`) and the iCloud account check.
- **`MangoUI`** (new SwiftPM target, SwiftUI) holds the iPhone's views, design-system pieces and view models, so the iPad (step 7) reuses them. **`Phone/`** is the XcodeGen target `MangoPhone`: entry point, environment, lock, sync controller, entitlements, snapshot harness.
- **Mac:** `SyncDemoMode` drives the scheduler instead of one `syncNow()`; Settings ▸ Sync shows status. The real database stays off: `SyncActivation` refuses it without the user's later go.
- **Demo data only:** the Mac uploads the demo database (`--sync-demo`, Development container); the simulator pulls it (`--sync-demo` on iOS, the demo key handed over by an environment variable, simulator builds only). Demo keys live under their own key-store scope, so they never seal real data.

**Tech Stack:** Swift 6, SwiftUI (iOS 26: `TabView` with `Tab(role: .search)`, `NavigationStack`, Charts), LocalAuthentication, CloudKit (`CKDatabase` operations, ruling R11), GRDB 6.29, XcodeGen 2.46, XCTest; `xcodebuild` against the iPhone 17 simulator (Xcode 27.1).

**Spec:**
- `docs/superpowers/specs/2026-10-22-iphone-app-design.md` (§§2–5; the read parts of §3, §3.1 lock, §3.9 states, §4 design rules, §6 test plan's harness).
- `docs/superpowers/specs/2026-10-22-companion-apps-overview.md` §3 (TestFlight), §4 step 4.
- `docs/superpowers/specs/2026-10-22-sync-and-access-design.md` §3 (R11), §4.2 and §9.1 (R15: sealed records, key in iCloud Keychain, bootstrap and waiting), §5.5–§5.7 (offline, unavailable, first sync), §9 "Weakest points" (waiting isn't failing; the iOS keychain access group).
- `docs/superpowers/specs/2026-10-21-authentication-design.md` §10 (mobile lock: `LAContext.deviceOwnerAuthentication`; on launch, after 5 minutes in the background, on demand).
- Follow-ups owed to this step: `2026-10-23-step3-sync-foundation.md` (cancellation through `serialized`; tools' `recursive_triggers`), `2026-10-23-field-sealing.md` (waiting rows worded as waiting; the keychain access group).

## Global Constraints

- **Logic in BudgetCore.** `MangoUI` and `Phone/` never compute a figure; they call `HomeSummary`, `PayMonthReview`, `PropertySummary`, `AccountsOverview`, `DashboardCalculator`, `TransactionSearch`, `AccountHistory`. No AppKit or UIKit in BudgetCore (`scripts/build-core-ios.sh`, `scripts/test-core-ios.sh` stay green).
- **Identifiers:** bundle id `ubberninja.mango.ios`, product name `Mango`, deployment target iOS 26.0, iCloud container `iCloud.ubberninja.mango`, keychain access group `$(AppIdentifierPrefix)ubberninja.mango` (the Mac's; without it the synchronizable key items are invisible, sync spec §9), `com.apple.developer.icloud-container-environment` = `$(CLOUDKIT_ENVIRONMENT)` (Debug Development, Release Production). No App Group, widgets, share extension or push in this step (step 6).
- **Read-only:** the iPhone writes nothing a sync could carry. No edit control exists (not hidden: absent). The phone's `SyncChangeTracker.pending` is empty at all times; a test pins it.
- **No local writers on the phone:** no `CategorySeeder`, `TransferCategories.ensure`, `TransferMatcher`, `AutoForecastGenerator`, exchange-rate, HMRC or Euribor fetches. The Mac is the hub (sync spec §3).
- **The real Mac database never syncs in this step.** `SyncActivation.decision(databasePath:, arguments:, isDebug:)` allows sync only for a `--sync-demo` DEBUG launch on a `DemoMarker` database outside the app's data folder (today's `SyncDemoMode.refusal` rules). Settings ▸ Sync on the Mac shows "Off" with no switch; the switch comes with the user's go.
- **Demo keys are not real keys.** `--sync-demo` (Mac and iOS) uses `KeychainSyncKeyStore(container: CloudKitTransport.containerIdentifier + "/demo")`, never the plain scope the real data will use.
- **Waiting isn't failing.** `SyncStatus.waitingForKey` is shown as "Waiting for the household key from iCloud Keychain", in the secondary colour, never red, never with "error" or "failed" (sync spec §9 weakest points; field-sealing follow-up finding 4 and 6).
- **Lock:** `LAContext.deviceOwnerAuthentication` (Face ID, Touch ID or passcode). Locks on launch, after 300 s in the background, and from the Settings sheet. Content under the lock is not rendered; the app-switcher snapshot is blurred (`.privacySensitive()` or a cover view on `scenePhase` changes). Snapshot builds (`SNAPSHOTS`) skip the lock.
- **Design:** every figure is one line: `MoneyText`/`figureText` with `minimumScaleFactor(0.7)` where the width is fixed, natural width otherwise; at accessibility Dynamic Type sizes rows stack the amount under the label. Touch targets ≥ 44 pt. SF Symbols. Copy says "Mango". Money roles and signs as the ui-polish spec §1.4; theme tokens from `ThemeCatalog`.
- **Snapshot harness:** `scripts/render-phone-snapshots.sh` renders every route from the demo database, light and dark, at default and `xxxLarge` Dynamic Type, on the iPhone 17 simulator; `wrap-report.txt` must list zero violations.
- **On-device storage:** the database at `Application Support/Mango/budget.sqlite` in the app sandbox, file protection `completeUntilFirstUserAuthentication`, excluded from iCloud backup (sync spec §9 "On devices"). Documents are not downloaded on the phone in this step (`documents: nil`).
- **No personal data** in the repo, tests, snapshots or logs (no amounts or names in `Logger` lines). Tests use `FakeCloud` and `InMemorySyncKeyStore`, never the Keychain or CloudKit.
- **TestFlight is prepared, not done.** The archive/export script runs to an `.ipa`; `--upload` exists but the plan's final task does not run it. Nothing is installed on the user's phone.
- Build the Mac app too before merging (`xcodebuild -project Mango.xcodeproj -scheme Mango`); run `xcodegen generate` in the main checkout after the merge.

## Review Focus

1. **A fresh iPhone database before its first pull.** Expect no row of any synced table and nothing pending: a seeded category or a matched transfer would collide with the household's records on arrival. Task 4: `testFreshPhoneDatabaseHasNoSyncedRowsAndNothingPending`.
2. **The key hasn't arrived from iCloud Keychain** (pull reports `waitingForKey > 0`, push reports `keyWait`). Expect the status "Waiting for the household key…", Home's empty state saying the same, no red, no retry storm. Task 1: `testKeyWaitBecomesWaitingStateAndRetriesOnTheSlowSchedule`; Task 12: snapshot route `home-waiting_for_key`.
3. **CloudKit says come back later** (`SyncTransportError.unavailable(retryAfter: 37)`), or the app is backgrounded mid-sync. Expect the next attempt not before 37 s, and a cancelled sync that stops at the next operation and leaves the token and stamps consistent. Task 1: `testRetryAfterIsHonoured`, `testCancelStopsBeforeTheNextOperation`.
4. **No device passcode.** `LAContext.canEvaluatePolicy` fails with `passcodeNotSet`. Expect the lock screen to say "Mango needs a device passcode" with "Open Settings", and the content to stay hidden. Task 5: `testNoPasscodeStaysLockedWithExplanation`.
5. **A launch that could reach the real database with sync.** `--sync-demo` with `BUDGET_DB_PATH` on the app's data folder, a non-demo file, a Release build, or no argument at all. Expect `SyncActivation` to refuse, with the reason, before anything opens. Task 1: `testActivationRefusesEverythingButADemoDatabaseInDebug`.

---

### Task 1: SyncScheduler, SyncStatus and SyncActivation (BudgetCore)

**Files:**
- Create: `Sources/BudgetCore/Sync/SyncScheduler.swift`, `Sources/BudgetCore/Sync/SyncStatus.swift`, `Sources/BudgetCore/Sync/SyncActivation.swift`
- Modify: `Sources/BudgetCore/Sync/SyncEngineCore.swift` (`serialized`, lines ~190–197): the inner `Task` is cancelled when the caller's task is (`withTaskCancellationHandler`), so cancellation reaches the transport (step 3 follow-up).
- Test: `Tests/BudgetCoreTests/SyncSchedulerTests.swift`, `Tests/BudgetCoreTests/SyncActivationTests.swift`

**Interfaces:**
- Consumes: `SyncEngineCore` (`syncNow`, `pull`, `pushPending`, reports), `SyncTransportError`, `SyncKeyError`, `SyncChangeTracker.pending`.
- Produces:
  - `public enum SyncStatus: Equatable, Sendable { case off; case idle(lastSync: Date?); case syncing(SyncPhase); case waitingForKey(since: Date); case offline(since: Date, retryAt: Date?); case needsAttention(held: Int, lastSync: Date?); case unavailable(SyncUnavailableReason) }` with `public enum SyncPhase { case pulling, pushing }` and `public enum SyncUnavailableReason: Equatable, Sendable { case noICloudAccount, quotaExceeded }`.
  - `public actor SyncScheduler` with `init(engine: SyncEngineCore, db: any DatabaseWriter, clock: @Sendable () -> Date = { Date() }, sleep: @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }, pushDebounce: TimeInterval = 5, periodic: TimeInterval = 900, keyWaitRetry: TimeInterval = 300)`;
    `func start()`, `func stop()` (cancels the running sync and the timers), `func requestSync(_ trigger: SyncTrigger) async` with `public enum SyncTrigger { case launch, foreground, userRefresh, localChange, periodic, keyMayHaveArrived }`, `func cancel()`, `var status: SyncStatus { get }`, `func statusStream() -> AsyncStream<SyncStatus>`, `func syncNowAndWait() async throws -> SyncReport` (pull-to-refresh awaits it).
  - Rules: one sync at a time; `localChange` is debounced by `pushDebounce` and only pushes; `userRefresh` and `launch` do pull then push; `.unavailable(retryAfter:)` and `.networkUnavailable` go to `.offline(retryAt:)` with retry at `max(retryAfter, backoff)` where the backoff doubles from 30 s to 15 min; a `keyWait` report or `waitingForKey > 0` goes to `.waitingForKey` and retries every `keyWaitRetry`, also on `.keyMayHaveArrived`; `.notAuthenticated` → `.unavailable(.noICloudAccount)`, `.quotaExceeded` → `.unavailable(.quotaExceeded)`, no retry until `foreground`; a report with `held > 0` or a `filedYearAlert` → `.needsAttention`.
  - `public enum SyncActivation { public struct Decision: Equatable { public let allowed: Bool; public let reason: String? }; public static func decision(databasePath: String?, arguments: [String], isDebug: Bool, hasCloudKitEntitlement: Bool, fileManager: FileManager = .default) -> Decision }`, moving the rules of `SyncDemoMode.refusal` (absent argument, relative path, missing file, `TaxRegression.isAppData`, `DemoMarker.isDemoDatabase`, entitlement) into BudgetCore; `SyncDemoMode` calls it.

- [ ] **Step 1: Write the failing tests** (`FakeCloud`, `InMemorySyncKeyStore`, a fake clock and a recording `sleep`): `testLaunchPullsThenPushes`, `testLocalChangeIsDebouncedAndOnlyPushes`, `testRetryAfterIsHonoured` (transport throws `unavailable(retryAfter: 37)`; next attempt at +37 s, status `.offline(retryAt:)`), `testBackoffDoublesTo15Minutes`, `testKeyWaitBecomesWaitingStateAndRetriesOnTheSlowSchedule` (device B without the key: status `.waitingForKey`, retry at +300 s, no second key created), `testCancelStopsBeforeTheNextOperation` (a transport that blocks on a continuation; `cancel()` makes the sync throw `CancellationError` and the token in `syncState` is unchanged), `testNotAuthenticatedWaitsForForeground`, `testHeldRecordsAreNeedsAttention`, and `testActivationRefusesEverythingButADemoDatabaseInDebug` (five refusals with their reasons; one acceptance).
- [ ] **Step 2: Run them**: `swift test --filter 'SyncSchedulerTests|SyncActivationTests'`. Expected: FAIL, types not found.
- [ ] **Step 3: Implement** the three files and the `serialized` change. The status stream yields on every change, starting with the current status.
- [ ] **Step 4: Run** the filter, then the full suite (`SyncEngineCoreTests` must still pass with the `serialized` change) and `scripts/test-core-ios.sh`. Expected: all pass.
- [ ] **Step 5: Commit** "Sync scheduler: triggers, retry-after, key wait, cancellation; activation policy in BudgetCore".

### Task 2: Phone calculators (BudgetCore)

**Files:**
- Create: `Sources/BudgetCore/Phone/HomeSummary.swift`, `Sources/BudgetCore/Phone/PayMonthReview.swift`, `Sources/BudgetCore/Phone/PropertySummary.swift`
- Test: `Tests/BudgetCoreTests/HomeSummaryTests.swift`, `Tests/BudgetCoreTests/PayMonthReviewTests.swift`, `Tests/BudgetCoreTests/PropertySummaryTests.swift` (the demo database through `DemoDatabase.build(dbQueue:evidenceRoot:)`, `asOf` 2026-10-15)

**Interfaces:**
- Consumes: `DashboardInput`, `DashboardCalculator` (`dataFreshness`, `attentionItems`, `netWorthSeries`, `currentMonth`, `monthlyFlows`, `upcomingBills`), `MonthBlend`, `PayCalendar`, `BudgetGridCalculator.categoryTotal/periodSummary`, `PropertyCalendar.obligations`, `PropertyPage`, `MortgageHistory.estimate/progress`, `PropertyMonthBreakdown.monthBreakdown`, `AccountsOverview`.
- Produces:
  - `public struct HomeSummary: Equatable { freshness: DataFreshness; netWorth: NetWorthSeries; month: CurrentMonthTracking; leftToSpendMinorUnits: Int; plannedSpendingMinorUnits: Int; daysToPayday: Int; attention: AttentionItems; upcoming: [UpcomingItem] }` with `public struct UpcomingItem: Equatable, Identifiable { id: String; date: Date; title: String; amountMinorUnits: Int?; currency: Currency; source: Source }`, `Source` one of `bill, propertyObligation`; `public static func make(_ input: DashboardInput, db: Database, today: Date) throws -> HomeSummary`. "Left to spend" and the hatched "still expected" use `MonthBlend.projectedTotal` exactly as the Mac's `CurrentMonthCard`. Property obligations come from every property's `PropertyCalendar.obligations(from: today, to: today + 60 days)`. Ruling: the freshness line says "Data through <date> · last import <when>"; "imported on <device>" waits for `syncRecord.modifiedBy` naming devices (step 6).
  - `public struct PayMonthReview: Equatable { month: PayMonth; range: (start: Date, end: Date); incomeMinorUnits, spentMinorUnits, stillExpectedMinorUnits, leftToSpendMinorUnits: Int; rows: [Row] }`, `public struct Row: Equatable, Identifiable { id: Int64 (category id); category: Category; actualMinorUnits: Int; planMinorUnits: Int; isOverPlan: Bool }`, grouped by `CategoryType` through `rows(of: CategoryType)`; `public static func make(month: PayMonth, input: DashboardInput, calendar: PayCalendar) -> PayMonthReview`.
  - `public struct PropertySummary: Equatable { property: Property; letSince: Date?; contractTo: Date?; rent: RentStatus; receipt: ReceiptStatus; lastRecharge: RechargeStatus?; mortgage: Mortgage?; comingUp: [PropertyObligation] }` with the enums `RentStatus { received(Date), expected(Date), late(since: Date), none }`, `ReceiptStatus { issued, pending, none }`, `RechargeStatus { paid, sent, readyToSend, none }`, `Mortgage { nextInstalmentMinorUnits: Int?; nextInstalmentDate: Date?; outstandingMinorUnits: Int; progress: MortgageHistory.Progress?; ratePercent: Double?; nextReview: Date? }`; `public static func make(db: Database, propertyId: Int64, today: Date) throws -> PropertySummary` and `public static func all(db: Database, today: Date) throws -> [PropertySummary]`.

- [ ] **Step 1: Write the failing tests**: `testHomeLeftToSpendEqualsTheMacDashboard` (equals the figures `DashboardCalculator.currentMonth` and `MonthBlend` give for the same input), `testUpcomingMergesBillsAndObligationsByDate`, `testFreshnessIsAmberAfter14Days`; `testReviewRowsEqualTheBudgetGrid` (each row's actual equals `BudgetGridCalculator.categoryTotal` for the month's `PayPeriod`), `testOverPlanRowsFlagged`, `testEmptyMonthHasNoRows`; `testPropertySummaryOnTheDemo` (rent received this month, mortgage outstanding equals `MortgageHistory.estimate`, coming up sorted by date), `testPropertyWithoutMortgageHasNilMortgage`.
- [ ] **Step 2: Run**: `swift test --filter 'HomeSummaryTests|PayMonthReviewTests|PropertySummaryTests'`. Expected: FAIL.
- [ ] **Step 3: Implement** the three files, calling existing calculators only.
- [ ] **Step 4: Run** the filter and `scripts/test-core-ios.sh`. Expected: pass.
- [ ] **Step 5: Commit** "Phone calculators: HomeSummary, PayMonthReview, PropertySummary".

### Task 3: MangoSync package target (shared CloudKit transport and key store)

**Files:**
- Create: `Sources/MangoSync/CloudKitTransport.swift` (moved from `App/Sync/`), `Sources/MangoSync/KeychainSyncKeyStore.swift` (moved; `init(container:)` already takes the scope), `Sources/MangoSync/CloudKitAccountStatus.swift`
- Modify: `Package.swift` (target `MangoSync`, dependencies `BudgetCore`; product `.library(name: "MangoSync", targets: ["MangoSync"])`), `project.yml` (the Mac target depends on `MangoSync`), `App/Sync/SyncDemoMode.swift` (imports `MangoSync`), `Tests/BudgetCoreTests/CloudKitRecordMappingTests.swift` if it referenced the App copy.
- Delete: `App/Sync/CloudKitTransport.swift`, `App/Sync/KeychainSyncKeyStore.swift`.

**Interfaces:**
- Produces: `public final class CloudKitTransport` and `public final class KeychainSyncKeyStore` (unchanged API, now public), `public static let demoKeyScope = CloudKitTransport.containerIdentifier + "/demo"`, and `public enum CloudKitAccountStatus { public static func current(container: String = CloudKitTransport.containerIdentifier) async -> Status }` with `public enum Status { case available, noAccount, restricted, couldNotDetermine }` (wraps `CKContainer.accountStatus`).
- Note: `CKRecord` mapping stays in BudgetCore (`CloudKitRecordMapping`), as today.

- [ ] **Step 1:** Move the files, make the types public, add the target and the dependency.
- [ ] **Step 2: Verify**: `swift build --target MangoSync`; `scripts/build-core-ios.sh` extended to build the `MangoSync` scheme for iOS as well (same workspace, `CODE_SIGNING_ALLOWED=NO`); `xcodegen generate && xcodebuild -project Mango.xcodeproj -scheme Mango -configuration Debug CODE_SIGNING_ALLOWED=NO build`; full `swift test`. Expected: all green.
- [ ] **Step 3: Commit** "MangoSync: the CloudKit transport and key store shared by the Mac and iOS apps".

### Task 4: The iOS target, its environment and database

**Files:**
- Create: `Sources/BudgetCore/Database/PhoneDatabasePolicy.swift`, `Phone/MangoPhoneApp.swift` (`@main`; `SNAPSHOTS` runs the harness only, as `BudgetMain` does), `Phone/PhoneEnvironment.swift`, `Phone/PhoneDatabase.swift`, `Phone/Info.plist`, `Phone/Mango.entitlements`, `Phone/Assets.xcassets` (AppIcon from `docs/design/mango-icon.svg` via `scripts/generate-app-icon.swift`, iOS sizes incl. 1024 marketing), `Phone/PrivacyInfo.xcprivacy` (required-reason APIs: UserDefaults `CA92.1`, file timestamps `C617.1`; no tracking), `Config/SigningPhone.xcconfig` (`#include? "Signing.local.xcconfig"` then `CODE_SIGN_ENTITLEMENTS = Phone/Mango.entitlements` and `ENABLE_HARDENED_RUNTIME = NO`, because `Signing.local.xcconfig.example` sets the Mac's entitlements path), `scripts/build-phone.sh` (unsigned simulator build; prints `Phone build OK`, exits non-zero on error), `Sources/MangoUI/MangoUI.swift` (empty module with the `MangoUI` target in `Package.swift`, depends on `BudgetCore`).
- Modify: `project.yml` (target `MangoPhone`: `platform: iOS`, `deploymentTarget: "26.0"`, `sources: [Phone]`, dependencies `BudgetCore`, `MangoSync`, `MangoUI`, `configFiles` `Config/SigningPhone.xcconfig`, settings `PRODUCT_BUNDLE_IDENTIFIER: ubberninja.mango.ios`, `PRODUCT_NAME: Mango`, `MARKETING_VERSION: "0.2.0"`, `CURRENT_PROJECT_VERSION: "1"`, `TARGETED_DEVICE_FAMILY: "1"`, `INFOPLIST_KEY_UISupportedInterfaceOrientations: UIInterfaceOrientationPortrait`, the `CLOUDKIT_ENVIRONMENT` configs as the Mac's; `Config/Signing.local.xcconfig.example` gains a comment that both targets include it).
- Test: `Tests/BudgetCoreTests/PhoneDatabaseTests.swift` for the BudgetCore part (`PhoneDatabasePolicy`).

**Interfaces:**
- Produces:
  - `Phone/Mango.entitlements`: `com.apple.developer.icloud-container-identifiers` [`iCloud.ubberninja.mango`], `com.apple.developer.icloud-services` [`CloudKit`], `com.apple.developer.icloud-container-environment` `$(CLOUDKIT_ENVIRONMENT)`, `keychain-access-groups` [`$(AppIdentifierPrefix)ubberninja.mango`]. Nothing else.
  - `Sources/BudgetCore/Database/PhoneDatabasePolicy.swift`: `public enum PhoneDatabasePolicy { public static func open(at path: String) throws -> DatabaseManager }` — migrates and **does not seed, match transfers or create anything**; `public static func syncedRowCount(db: Database) throws -> Int` (sum over `SyncSchema.tables` of `SELECT COUNT(*)`); the file protection and backup exclusion are applied by the caller (`Phone/PhoneDatabase.swift`, UIKit-free Foundation attributes: `FileProtectionType.completeUntilFirstUserAuthentication`, `URLResourceValues.isExcludedFromBackup = true`).
  - `@MainActor final class PhoneEnvironment: ObservableObject { let dbQueue: DatabaseQueue; let databasePath: String; let today: () -> Date; static func load() async throws -> PhoneEnvironment }`, mirroring `AppEnvironment.load` minus every writer and every hub job.
  - `Phone/Info.plist`: `NSFaceIDUsageDescription` "Mango unlocks with Face ID so only you see the household's figures."; `UILaunchScreen` {}; `UIApplicationSceneManifest` single scene.

- [ ] **Step 1: Write the failing test** `testFreshPhoneDatabaseHasNoSyncedRowsAndNothingPending`: open a temp path through `PhoneDatabasePolicy.open`, expect `syncedRowCount == 0` and `SyncChangeTracker.pending(db:).isEmpty`; and `testPhoneOpenMigratesToTheLatest` (`hasPendingMigrations == false`).
- [ ] **Step 2: Run** `swift test --filter PhoneDatabaseTests`. Expected: FAIL.
- [ ] **Step 3: Implement** the policy, then the target files. The app's root for now: `Text("Mango")` behind the lock to come.
- [ ] **Step 4: Verify**: the filter passes; `xcodegen generate`; `scripts/build-phone.sh` prints `Phone build OK`; `xcrun simctl boot "iPhone 17"` then `xcrun simctl install booted <Mango.app>` and `xcrun simctl launch booted ubberninja.mango.ios` prints a PID; the Mac scheme still builds.
- [ ] **Step 5: Commit** "MangoPhone target: iOS 26 app shell, entitlements, read-only database policy".

### Task 5: App lock on iPhone

**Files:**
- Create: `Sources/BudgetCore/Auth/MobileLockPolicy.swift`, `Phone/Lock/PhoneLockModel.swift`, `Sources/MangoUI/Lock/LockScreen.swift`, `Phone/Lock/LockCover.swift`
- Test: `Tests/BudgetCoreTests/MobileLockPolicyTests.swift`

**Interfaces:**
- Produces:
  - `public enum MobileLockPolicy { public static let backgroundGrace: TimeInterval = 300; public enum Availability: Equatable, Sendable { case biometrics(BiometryKind), passcodeOnly, noPasscode, unavailable }; public enum BiometryKind: Sendable { case faceID, touchID }; public static func shouldLock(backgroundedAt: Date?, now: Date) -> Bool; public static func lockScreenCopy(_ availability: Availability) -> (title: String, body: String, primary: String?, secondary: String?) }` — copy: title "Mango is locked"; body "Your household's figures are hidden until you unlock."; primary "Unlock with Face ID" / "Unlock with Touch ID" / "Unlock with passcode"; secondary "Use passcode" when biometrics; for `.noPasscode` title "Mango needs a device passcode", body "Set a passcode in Settings to protect the household's figures.", primary "Open Settings", no secondary.
  - `@MainActor final class PhoneLockModel: ObservableObject { enum State { case locked(MobileLockPolicy.Availability), unlocking, unlocked }; @Published private(set) var state; func unlock(allowPasscodeOnly: Bool) async; func lock(); func sceneDidEnterBackground(now:); func sceneWillEnterForeground(now:) }`, over `LAContext` (`deviceOwnerAuthentication`; `deviceOwnerAuthenticationWithBiometrics` first when the primary button is tapped). `SNAPSHOTS` and a `MANGO_UNLOCKED=1` environment variable in **simulator DEBUG builds only** (`#if DEBUG && targetEnvironment(simulator)`) start unlocked, for the harness and the attended checks.
  - `LockScreen(availability:, onPrimary:, onSecondary:)` in MangoUI: icon, the copy above, two buttons (≥ 44 pt), fits the iPhone SE width class (375 pt) and 17 Pro Max.
  - `LockCover` (Phone): a root modifier that renders `LockScreen` instead of the content while locked (not over it), and an opaque cover with the app icon while `scenePhase != .active`.

- [ ] **Step 1: Write the failing tests**: `testLocksAfterFiveMinutesInBackground` (299 s no, 300 s yes, nil backgroundedAt no), `testNoPasscodeStaysLockedWithExplanation` (copy for `.noPasscode`; `shouldLock` irrelevant), `testCopyPerAvailability`.
- [ ] **Step 2: Run** `swift test --filter MobileLockPolicyTests`. Expected: FAIL.
- [ ] **Step 3: Implement** the policy, the model, the screen and the cover; wire the root in `MangoPhoneApp`.
- [ ] **Step 4: Verify**: filter passes; `scripts/build-phone.sh`; launched on the simulator with no passcode set, the lock screen shows the no-passcode copy (`xcrun simctl io booted screenshot`); with `MANGO_UNLOCKED=1` (`SIMCTL_CHILD_MANGO_UNLOCKED=1 xcrun simctl launch …`) the content shows.
- [ ] **Step 5: Commit** "iPhone lock: Face ID or passcode, 5-minute background grace, no-passcode state".

### Task 6: MangoUI design system and the iOS snapshot harness

**Files:**
- Create: `Sources/MangoUI/DesignSystem/MoneyText.swift`, `FigureText.swift`, `DateText.swift`, `Card.swift`, `EmptyState.swift`, `InlineBanner.swift`, `AmountRow.swift` (label + amount; stacks at accessibility sizes via `@Environment(\.dynamicTypeSize).isAccessibilitySize`), `PhoneTheme.swift` (`ThemeCatalog` tokens → `Color`; the Classic theme maps to system colours), `Sources/MangoUI/DesignSystem/WrapProbe.swift` (port of `App/Snapshots/WrapProbe.swift`: a preference-key probe active only when `WrapProbeRegistry.shared.isActive`), `Sources/MangoUI/Demo/DemoRoutes.swift` (the route catalogue: name, view builder, Dynamic Type sizes), `Phone/Snapshots/PhoneSnapshotRunner.swift` (`SNAPSHOTS` only: builds the demo database in-process with `BudgetDemo`, renders each route in a `UIWindow` at 393×852 (iPhone 17) light and dark, `.large` and `.xxxLarge`, writes PNGs and `wrap-report.txt` to `Documents/snapshots/`, exits), `scripts/render-phone-snapshots.sh` (builds `MangoPhone` with `SWIFT_ACTIVE_COMPILATION_CONDITIONS='$(inherited) SNAPSHOTS'` and `BudgetDemo` linked, boots the simulator, installs, launches with `--render-snapshots`, waits for exit, copies `xcrun simctl get_app_container booted ubberninja.mango.ios data`/Documents/snapshots to `<outDir>`, prints the wrap report's first two lines).
- Modify: `project.yml`: `MangoPhone` depends on `BudgetDemo` too. Ruling: XcodeGen can't vary dependencies per build setting, so `BudgetDemo` is linked always and imported only under `#if SNAPSHOTS` (`PhoneSnapshotRunner`); the release build carries an unused library and never calls it. Record the ruling in the runner's header.
- Test: route `gallery` (every design-system piece with long figures: "£1,234,567.89", "−€12,345.67", "1,234 days").

**Interfaces:**
- Produces: `MoneyText(minorUnits:, currency:, role: MoneyRole, fit: FigureFit = .natural)`, `public enum MoneyRole { income, expense, transfer, neutral, balance }`, `Text.figureText(_:)`, `Card(title:) { }`, `EmptyState(symbol:, title:, message:, action:)`, `InlineBanner(tone: .amber|.neutral, text:)`, `AmountRow(label:, secondary:, amount: MoneyText)`; `DemoRoutes.all: [DemoRoute]` with `struct DemoRoute { name: String; sizes: [DynamicTypeSize]; make: (PhoneDemoContext) -> AnyView }`; `PhoneDemoContext { dbQueue, today, syncStatus }`.
- Later tasks add their routes to `DemoRoutes.all`.

- [ ] **Step 1:** Build the pieces and the `gallery` route; port the probe.
- [ ] **Step 2: Verify**: `scripts/render-phone-snapshots.sh /tmp/phone-snaps --only gallery` writes 4 PNGs and `wrap-report.txt` with `0 violations`; make one figure deliberately wrap (a temporary `lineLimit(nil)`) and confirm the report names it, then revert.
- [ ] **Step 3: Commit** "MangoUI design system (money, figures, cards, banners) and the iOS snapshot harness with the wrap probe".

### Task 7: Home

**Files:**
- Create: `Sources/MangoUI/Home/HomeView.swift`, `HomeViewModel.swift` (`@MainActor`, loads `DashboardInput` the way `DashboardViewModel.load` does, then `HomeSummary.make`), `NetWorthCard.swift` (Charts: actual line, confirmed forecast dashed, year-end figure), `PayMonthCard.swift` (bar with hatched still-expected; left to spend; days to payday), `AttentionCard.swift` (uncategorised count, stale balances, sync problems — each a line, no actions in this step), `UpcomingCard.swift` (next 5 `UpcomingItem`s), `FreshnessLine.swift` (amber over 14 days).
- Routes: `home`, `home-empty` (an empty database: "Nothing here yet" with the sync status line), `home-stale_data`.

**Interfaces:**
- Consumes: `HomeSummary`, `SyncStatus` (shown in the Attention card when not `.idle`/`.off`), `MoneyText`, `Card`.
- Produces: `HomeView(model: HomeViewModel, syncStatus: SyncStatus, onRefresh: () async -> Void, onSettings: () -> Void)`; the avatar button top right opens the Settings sheet (Task 12). Pull to refresh calls `onRefresh`.

- [ ] **Step 1:** Build the view and the routes.
- [ ] **Step 2: Verify**: `scripts/render-phone-snapshots.sh /tmp/phone-snaps --only home,home-empty,home-stale_data`: 0 violations at both sizes; the net worth figure in the demo equals `AccountsOverview.netWorthGBP` for 2026-10-15 (checked by the route's assertion, printed in the report).
- [ ] **Step 3: Commit** "iPhone Home: freshness, net worth, this pay month, needs attention, upcoming".

### Task 8: Month

**Files:**
- Create: `Sources/MangoUI/Month/MonthView.swift` (header with ‹ › over `PayCalendar` months, date range, summary grid, segments Spending | Income | Transfers, rows), `MonthViewModel.swift`, `CategoryRow.swift` (badge from `CategoryIcons`, name, "actual / plan", progress bar, "£x left" or "£x over plan" in the expense colour), `MonthTransactionsView.swift` (a row's transactions, read-only list grouped by day).
- Routes: `month`, `month-income`, `month-empty` (a projected month with no rows: "No transactions in this month yet").

**Interfaces:**
- Consumes: `PayMonthReview`, `PayCalendar.load(db:today:)`, `TransactionSearch` for the row's transactions (criteria: category and date range).
- Produces: `MonthView(model: MonthViewModel)`.

- [ ] **Step 1:** Build; the ‹ › range is the calendar's months from `DemoDatabase.historyStart` to the current month.
- [ ] **Step 2: Verify**: routes render with 0 violations; the route asserts the summary grid's four figures equal `PayMonthReview.make` for the same month.
- [ ] **Step 3: Commit** "iPhone Month: pay month summary, category rows, transactions per row".

### Task 9: Accounts

**Files:**
- Create: `Sources/MangoUI/Accounts/AccountsView.swift` (header: net worth and change on last December via `DashboardCalculator.yearEndNetWorth(year − 1, includeForecast: false)`; sections Cash / Credit / Investments with subtotals), `AccountsViewModel.swift`, `AccountRowView.swift` (two lines: name over "Imported · through <date>" or "Checked <n> days ago"; amber "needs an update" for a manual account over 30 days old — the "tap to update" action is step 6; non-GBP shows the native figure with GBP beneath), `AccountDetailView.swift` (balance chart from `AccountHistory.make`, then recent transactions).
- Routes: `accounts`, `account-detail`, `accounts-empty`.

**Interfaces:**
- Consumes: `AccountsOverview.make`, `AccountHistory.make`, `BalanceStaleness`, `TransactionSearch`.
- Produces: `AccountsView(model: AccountsViewModel)` with `NavigationStack` to `AccountDetailView(accountId:)`.

- [ ] **Step 1:** Build.
- [ ] **Step 2: Verify**: routes, 0 violations; the route asserts the subtotals equal `AccountGroup.subtotalGBP`.
- [ ] **Step 3: Commit** "iPhone Accounts: groups, staleness, detail with balance chart".

### Task 10: Property

**Files:**
- Create: `Sources/MangoUI/Property/PropertyView.swift` (one property: shown directly; several: a list → detail), `PropertyViewModel.swift`, `ThisMonthCard.swift` (rent status, receipt status, last recharge status — words from `PropertySummary` enums), `MortgageCard.swift` (next instalment, outstanding, repaid bar, rate, next review), `ComingUpList.swift` (`PropertyObligation`s with dates and expected amounts; estimates marked "est.").
- Routes: `property`, `property-no_mortgage`, `property-empty` ("No property set up").

**Interfaces:**
- Consumes: `PropertySummary.all/make`.
- Produces: `PropertyView(model: PropertyViewModel)`. No "Split it" in this step (step 6).

- [ ] **Step 1:** Build.
- [ ] **Step 2: Verify**: routes, 0 violations.
- [ ] **Step 3: Commit** "iPhone Property: this month, mortgage, coming up".

### Task 11: Search tab and the tab bar

**Files:**
- Create: `Sources/MangoUI/Search/SearchView.swift` (`Tab(role: .search)`: the field matches description, amount tokens "24.99" and ">100", category; token filters Uncategorised · account · period; results grouped by day with the day's total; uncategorised rows carry the amber "?" badge), `SearchViewModel.swift` (builds a `TransactionSearch.Index` once per load; `Criteria` from the field and tokens), `TransactionRow.swift` (badge, description, "account · category", amount), `TransactionDetailSheet.swift` (read-only: amount, description, account, date, category, note; footer "Edit on iPad or Mac"), `Sources/MangoUI/Root/PhoneTabs.swift` (`TabView`: Home · Month · Accounts · Property · Search; Property absent when there is no property — spec §3.9 permission None analogue — ruling: absent in step 4 only when the database has no property row).
- Routes: `search`, `search-results`, `search-empty` ("Nothing matches"), `transaction-detail`.

**Interfaces:**
- Consumes: `TransactionSearch.rows/totals/amountToken/dateRange`, `CategoryIcons`.
- Produces: `PhoneTabs(environment:, lock:, sync:)` is the unlocked root.

- [ ] **Step 1:** Build; wire `PhoneTabs` as the root under the lock cover.
- [ ] **Step 2: Verify**: routes, 0 violations; the full harness run (`scripts/render-phone-snapshots.sh /tmp/phone-snaps`) reports 0 violations across every route; the day totals in `search-results` equal `TransactionSearch.totals` (route assertion).
- [ ] **Step 3: Commit** "iPhone Search tab, transaction detail, tab bar".

### Task 12: Sync on the phone: controller, status, states, demo mode

**Files:**
- Create: `Phone/Sync/PhoneSyncController.swift` (`@MainActor ObservableObject`: owns `SyncEngineCore(db:, transport: CloudKitTransport(), device: SyncDevice(id: <UUID kept in localSetting "phone.deviceId">, name: UIDevice.current.name), keyStore: KeychainSyncKeyStore(container: scope), documents: nil)` and a `SyncScheduler`; publishes `status`, `isFirstDownload` (no token in `syncState` yet) and `downloadedRecords` (from `SyncPullReport.received`); maps `scenePhase` → `.foreground`, launch → `.launch`, pull-to-refresh → `syncNowAndWait`; `CloudKitAccountStatus.current()` on launch and foreground; the scope is `demoKeyScope` under `--sync-demo`, else the plain container), `Phone/Sync/PhoneSyncDemoMode.swift` (`#if DEBUG`: `--sync-demo` on the phone means "pull the Development container's demo zone"; `#if targetEnvironment(simulator)`: if `MANGO_DEMO_HOUSEHOLD_KEY` (64 hex chars) is set, `store` it in the demo-scope key store once at launch — the simulator has no iCloud Keychain; a malformed value is refused with a log line and nothing stored), `Sources/MangoUI/Sync/SyncStatusLine.swift` (the one place status copy lives: `SyncStatusCopy.text(_ status: SyncStatus, now:) -> (text: String, tone: Tone)` in **BudgetCore** `Sources/BudgetCore/Sync/SyncStatusCopy.swift`, so it's tested), `Sources/MangoUI/Sync/OfflineBanner.swift` ("Offline · showing data from <time>." — no "N changes" on a read-only phone), `Sources/MangoUI/Sync/ICloudUnavailableView.swift` (full screen: "Sign in to iCloud to see the household's data" / "Open Settings"; local data stays readable: the button "Show what's here" goes to the tabs), `Sources/MangoUI/Sync/FirstDownloadView.swift` ("Downloading the household's records… <n> so far"), `Sources/MangoUI/Settings/SettingsSheet.swift` (Lock now; Appearance (system/light/dark) and theme picker from `ThemeCatalog.all`; Security status: iCloud account, "Records sealed with the household key" / "Waiting for the household key from iCloud Keychain"; About: version, build, `SyncStatusLine`, "Sync now").
- Test: `Tests/BudgetCoreTests/SyncStatusCopyTests.swift`.

**Interfaces:**
- Consumes: Tasks 1, 3, 4, 5; `HomeView.onSettings`.
- Produces: `SyncStatusCopy` — exact copy: `.off` "Sync is off"; `.idle(last)` "Up to date · <relative time>" or "Not synced yet"; `.syncing(.pulling)` "Checking for changes…"; `.syncing(.pushing)` "Sending changes…"; `.waitingForKey` "Waiting for the household key from iCloud Keychain" (tone `.neutral`); `.offline(retryAt)` "Offline · trying again <relative>" (tone `.amber`); `.needsAttention(held)` "<n> changes need attention on the Mac" (tone `.amber`); `.unavailable(.noICloudAccount)` "Sign in to iCloud to sync"; `.unavailable(.quotaExceeded)` "iCloud storage is full". No status text contains "error", "failed" or "failure".

- [ ] **Step 1: Write the failing tests**: `testEveryStatusHasCopy` (over every case), `testWaitingForKeyIsNeutralAndNeverAnError` (tone neutral; text contains none of "error", "failed", "failure").
- [ ] **Step 2: Run** `swift test --filter SyncStatusCopyTests`. Expected: FAIL.
- [ ] **Step 3: Implement** the copy, the controller, the views and the sheet; add routes `home-waiting_for_key` (status injected), `home-offline`, `icloud-unavailable`, `first-download`, `settings`.
- [ ] **Step 4: Verify**: filter passes; full harness 0 violations; `scripts/build-phone.sh`; on the simulator a plain launch (no iCloud account) shows `ICloudUnavailableView` and "Show what's here" reaches the tabs' empty states.
- [ ] **Step 5: Commit** "iPhone sync: scheduler-driven CloudKit pull, status copy, offline and iCloud states, Settings sheet, simulator demo mode".

### Task 13: The Mac uses the scheduler; Settings ▸ Sync; demo key scope and reset

**Files:**
- Modify: `App/Sync/SyncDemoMode.swift` (`refusal` delegates to `SyncActivation.decision`; `start` makes `SyncEngineCore` with `KeychainSyncKeyStore(container: CloudKitTransport.demoKeyScope)` and a `SyncScheduler`, `start()`s it and logs each status change; new DEBUG arguments: `--print-demo-key` writes the demo-scope household key as 64 hex to stderr after the first successful push — demo scope only, refused otherwise; `--sync-demo-reset` reads the Development zone's marker `keyId`, deletes the zone (`CKModifyRecordZonesOperation`), deletes the plain-scope Keychain item `iCloud.ubberninja.mango/household/<keyId>` if it exists (the key the earlier demo runs stored under the real scope), clears `syncState` rows for the zone, and exits), `App/Settings/SettingsView.swift` (new tab Sync), `App/AppEnvironment.swift` (`syncStatus: SyncStatus` published; `.off` unless demo mode).
- Create: `App/Settings/SyncSettings.swift` (status line through `SyncStatusCopy`; text "Sync for your data turns on in a later step." when `.off`; in demo mode the live status, last report counts and "Sync now"), `Sources/MangoSync/KeychainSyncKeyStore+Removal.swift` (`func remove(keyId:zone:) throws`, used by the reset only).
- Modify: `Sources/BudgetCore/Database/DatabaseManager.swift` or the tools' shared open path: every one-off tool in `Sources/` that opens a database sets `PRAGMA recursive_triggers = ON` (step 3 follow-up); a test opens through the tools' path and asserts the pragma.
- Snapshot route (Mac): `settings-sync` at 1100×700, 0 wrap violations.

**Interfaces:**
- Consumes: Task 1, Task 3.
- Produces: the Mac shows `SyncStatus` and stays `.off` for the real database.

- [ ] **Step 1:** Write the failing test `testToolOpenPathSetsRecursiveTriggers` and run it (FAIL).
- [ ] **Step 2:** Implement all of the above.
- [ ] **Step 3: Verify**: full `swift test`; Mac Debug build; `scripts/render-snapshots.sh /tmp/mac-snaps --only settings-sync --size 1100x700` 0 violations; without `--sync-demo` the app logs no sync activity and Settings ▸ Sync says Off.
- [ ] **Step 4: Commit** "Mac: sync scheduler in demo mode, Settings ▸ Sync (off for real data), demo key scope, --sync-demo-reset, tools set recursive_triggers".

### Task 14: TestFlight packaging, prepared

**Files:**
- Create: `Config/ExportOptions-TestFlight.plist` (`method` `app-store-connect`, `signingStyle` `automatic`, `uploadSymbols` true, `destination` `export`; `teamID` filled by the script from `Config/Signing.local.xcconfig`), `scripts/archive-phone.sh` (`xcodegen generate`; `xcodebuild archive -scheme MangoPhone -configuration Release -destination 'generic/platform=iOS' -archivePath <scratch>/Mango.xcarchive`; `xcodebuild -exportArchive … -exportOptionsPlist` → `<scratch>/export/Mango.ipa`; prints the `.ipa` path and size; `--upload` runs `xcrun altool --upload-app -t ios -f <ipa> --apiKey <id> --apiIssuer <issuer>` and is **refused unless `MANGO_ASC_KEY_ID` and `MANGO_ASC_ISSUER` are set**; without a team in `Signing.local.xcconfig` it stops with "TestFlight needs the team-signed configuration").
- Modify: `docs/superpowers/plans/2026-10-22-step0-developer-setup.md` gets a pointer to this script. Ruling: the build number is `CURRENT_PROJECT_VERSION=$(git rev-list --count HEAD)`, passed by the script on the `xcodebuild archive` command line, so every upload's build number increases and nothing is committed for it.

**Interfaces:**
- Produces: a reproducible `.ipa` for App Store Connect record "Mango Household Budget" (bundle `ubberninja.mango.ios`). Upload and install are the user's.

- [ ] **Step 1:** Write the plist and the script.
- [ ] **Step 2: Verify**: `scripts/archive-phone.sh` on this Mac (team present) ends with an `.ipa`, `codesign -d --entitlements - <app in the archive>` lists the iCloud container, the Production environment and the keychain group; `--upload` without the two variables is refused.
- [ ] **Step 3: Commit** "TestFlight packaging for MangoPhone: archive and export script (upload guarded)".

### Task 15: Final verification on the simulator with the demo synced from the Development container

Controller-run, attended where marked. Nothing here touches the real database or the Production environment.

- [ ] **Step 1:** Full checks: `swift test`, `scripts/build-core-ios.sh`, `scripts/test-core-ios.sh`, `scripts/build-phone.sh`, Mac Debug build, `scripts/render-snapshots.sh /tmp/mac-snaps --only settings-sync,dashboard --size 1100x700`, `scripts/render-phone-snapshots.sh /tmp/phone-snaps` (0 violations in both reports; keep both `wrap-report.txt` and all PNGs for the review).
- [ ] **Step 2 (attended: the user confirms the Development zone may be reset):** Mac team-signed Debug build with `BUDGET_DB_PATH=<fresh demo from MakeDemoDatabase> --sync-demo-reset`, then `--sync-demo --print-demo-key`. Expected: log "saved <n>", the demo key printed once, the CloudKit Console (Development) shows records with only `keyId` and `sealed`.
- [ ] **Step 3 (attended: the user signs the simulator in to iCloud in Settings and sets a device passcode; Features ▸ Face ID ▸ Enrolled):** team-signed Debug build of `MangoPhone` on "iPhone 17"; `SIMCTL_CHILD_MANGO_DEMO_HOUSEHOLD_KEY=<key> xcrun simctl launch booted ubberninja.mango.ios --sync-demo`. Expected in order, each screenshotted with `xcrun simctl io booted screenshot`: the lock screen; unlock (Features ▸ Face ID ▸ Matching Face, and once with the passcode); "Downloading the household's records…"; Home with the demo's figures (net worth equal to the Mac's Dashboard on the same demo, 2026-10-15 as-of is not forced here, so compare the "Data through" date and the account balances instead); Month; Accounts; Property; Search with ">100"; the Settings sheet with "Up to date".
- [ ] **Step 4:** Launch again **without** the key variable on a freshly erased simulator (`xcrun simctl erase`, sign in again). Expected: Home's empty state and the Settings sheet say "Waiting for the household key from iCloud Keychain", nothing red, and the log shows retries 300 s apart, not more often. Screenshot.
- [ ] **Step 5:** Background the app for 5 minutes (`xcrun simctl` has no clock; set `MobileLockPolicy.backgroundGrace` through a DEBUG-simulator env var `MANGO_LOCK_GRACE=5` for the check) and return: the lock screen. Screenshot.
- [ ] **Step 6:** Record in this plan's **Result** section: record counts, the time of the first download, the screenshots' folder, both wrap reports, and anything the user must still do (TestFlight upload, Keychain cleanup).

## Rulings made in this plan (binding unless the user objects)

1. Demo keys live under the key-store scope `iCloud.ubberninja.mango/demo`; the key the two earlier demo runs stored under the real scope is removed by `--sync-demo-reset` (Task 13), because a Production bootstrap would otherwise reuse it (`refreshHouseholdKey` adopts the newest local key when the server has no marker).
2. The simulator receives the demo key by `MANGO_DEMO_HOUSEHOLD_KEY`, simulator DEBUG builds only; a real iPhone receives it from iCloud Keychain and never reads the variable.
3. `MangoUI` and `MangoSync` are SwiftPM targets in the existing package, not a second package: one `Package.swift`, one workspace, the iOS scripts unchanged.
4. The phone passes `documents: nil`: no evidence files are downloaded in step 4 (no viewer yet).
5. Home's freshness line omits "imported on <device>" until step 6.
6. The Property tab is absent when the database has no property; otherwise one property shows directly.
7. No XCUITest in this step: the lock, the states and every screen are covered by the harness and the attended Task 15; UI tests arrive with the first edits (step 6).

## Result

(Filled by Task 15.)
