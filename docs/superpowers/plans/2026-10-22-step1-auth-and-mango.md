# Build step 1: desktop authentication + Mango — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** each person signs in to the Mac app as themselves (password or Touch ID, auto-lock, recovery), imports and learnt rules record who did them, and the app becomes Mango with its new icon.

**Architecture:**
- **BudgetCore (`Sources/BudgetCore/Auth/`):** the data model, password hashing, recovery keys and the user store.
- **App layer:** a `SessionModel` drives setup, the lock overlay and Settings ▸ Sign-in.
- **Secrets:** they live only in the local-only `localCredential` table.
- **Touch ID:** a biometry-bound data-protection Keychain item per app user on team-signed builds, with an `LAContext`-only fallback for unsigned builds.
- **Migrations:** a general pre-migration backup runs before any migration at launch.
- **The rename:** only copy, the product name and the icon change; no identifier or data path does.

**Tech Stack:** Swift 6 / SwiftUI on macOS 26, GRDB 6.29, XCTest, CommonCrypto (PBKDF2), LocalAuthentication, Security (Keychain), XcodeGen.

**Spec:**
- `docs/superpowers/specs/2026-10-21-authentication-design.md` (the authority for §§3–9).
- `docs/superpowers/specs/2026-10-22-companion-apps-overview.md` §2.4–§2.5 (name and icon).
- `docs/superpowers/specs/2026-10-22-sync-and-access-design.md` §11 (already folded into the auth spec).

## Global Constraints

- Migrations are appended last in `DatabaseManager.registerMigrations`. The new one is called `createAppUser`. It only adds tables and nullable columns; no existing value changes.
- Filed SA returns 2020/21–2024/25 must not change: `SelfAssessmentRegressionTests` and the `TaxRegression` tool must give identical output.
- `localCredential` (passwordHash, recoveryKeyHash) is local-only and never leaves the Mac. Nothing in this step syncs.
- Password hashes use exactly this format: `pbkdf2-sha256$<rounds>$<salt b64>$<hash b64>`, with 600 000 rounds and a 16-byte random salt, compared in constant time.
- Recovery keys are 24 characters from an unambiguous alphabet, shown as six groups of 4, and stored as a PBKDF2 hash in the same format.
- Passwords are at least 10 characters.
- The lock timeout options are 5, 15, 30 and 60 minutes, or Never. The default is 15.
- After 5 wrong attempts the delay grows 1 s, 2 s, 4 s… up to 60 s, held in memory.
- Pre-migration backups are named `budget.sqlite.pre-migration-backup-<yyyyMMdd-HHmmss>` (en_US_POSIX, Gregorian, local time). The newest 5 of that pattern are kept. A failed backup stops launch.
- Only the `SNAPSHOTS` build bypasses the lock. Debug builds and `BUDGET_DB_PATH` runs still require sign-in.
- Copy says "Mango" wherever it names the app, for example "Mango is locked", "Set up Mango", "Mango ▸ Lock (⌃⌘L)", "Mango ▸ Switch User…". "Budget" stays where it names the budget grid or plan. The Settings tab is called "Sign-in".
- These identifiers and paths do **not** change: the bundle id `ubberninja.mango`, the data folder `~/Library/Application Support/Budget/`, the `BudgetCore` module, the UTType id `com.personal.budget.account-reference`, and the log subsystem.
- The design system follows the ui-polish spec §1/§6. No figure wraps or truncates at 1100×700. Edits save only on Save.
- No personal data in tests or commits: synthetic names and numbers only, and no team IDs or emails.
- Never write `~/Library/Application Support/Budget/` (the database or Evidence). Rehearse on copies.
- `swift test` uses a scratch path outside `~/Documents` (iCloud xattrs break codesign). Every task also builds the app: `xcodegen generate && xcodebuild … -scheme Mango` (after Task 7; `Budget` before), and the build must succeed.

## Review Focus

1. **The only admin forgets their password, with no Touch ID enrolled.** They expect the recovery key on the lock screen to let them set a new password, with no data touched. Test in Task 3 (`testRecoveryKeyResetsPasswordWithoutAnotherAdmin`) and a UI route in Task 6.
2. **The Mac's fingerprints change after enrolment.** They expect Touch ID to stop offering and the password to be asked once, then re-enrolment to be offered. Test in Task 5 (`testChangedBiometryDropsEnrolment`, with a fake keychain returning `errSecItemNotFound` / invalidated).
3. **Auto-lock fires while an import is in review, and someone else unlocks.** They expect the review intact and Confirm to record whoever is signed in at Confirm. Test in Task 4 (`testConfirmRecordsUserAtConfirmTime`, an applier-level test passing two different ids).
4. **The app runs on a copied database (`BUDGET_DB_PATH`) on a Mac with no enrolment for its users.** They expect the password to work and Touch ID not to be offered until it's enrolled. Test in Task 5 (`testEnrolmentIsPerMacNotInDatabase`).
5. **Launching with a pending migration and a backup that can't be written** (disk full, or the folder not writable). They expect launch to stop with a clear error and the database unmigrated. Test in Task 1 (`testFailedBackupStopsMigration`).

---

### Task 1: Pre-migration backup at launch

**Files:**
- Create: `Sources/BudgetCore/Database/MigrationBackup.swift`
- Modify: `Sources/BudgetCore/Database/DatabaseManager.swift` (add `hasPendingMigrations`), `App/AppEnvironment.swift` (`load()`: back up, then migrate), `App/LaunchView.swift` (the error text)
- Test: `Tests/BudgetCoreTests/MigrationBackupTests.swift`

**Interfaces:**
- Produces:
  - `DatabaseManager.hasPendingMigrations() throws -> Bool`
  - `MigrationBackup.backUpIfNeeded(manager: DatabaseManager, databasePath: String, now: Date, keep: Int = 5) throws -> URL?`: nil when nothing is pending or the file doesn't exist yet.
  - `MigrationBackup.fileNamePrefix = "budget.sqlite.pre-migration-backup-"`

- [ ] **Step 1: Write failing tests:**
  - `testBacksUpOnlyWhenMigrationsPending`: a DB at `migrate(upTo:)` an earlier migration gives a non-nil URL whose file opens and has the same row counts; a fully migrated DB gives nil.
  - `testKeepsNewestFive`: 7 pre-existing backups with stamps give the 5 newest of the pattern kept. Other files, such as `budget.sqlite.pre-simar-totals-backup-…`, are untouched.
  - `testFailedBackupStopsMigration`: the backup directory is made read-only, so it throws and the DB's applied migrations are unchanged.
  - `testNoBackupForNewDatabase`: a path that doesn't exist gives nil.
- [ ] **Step 2:** Run `swift test --scratch-path <scratch> --filter MigrationBackupTests` and expect FAIL.
- [ ] **Step 3: Implement.** Use the SQLite backup API through GRDB (`DatabaseQueue.backup(to:)`) from the existing queue, so the WAL is included. The timestamp formatter is en_US_POSIX and Gregorian. In `AppEnvironment.load()`, call `MigrationBackup.backUpIfNeeded` before `manager.migrate()`. A throw surfaces in `LaunchView` as "Mango couldn't back up your data before updating it, so it didn't update anything. <error>".
- [ ] **Step 4:** Run the tests and expect PASS. Then run the full suite, and the app build.
- [ ] **Step 5: Commit** "Back up the database before any migration at launch (keeps the newest 5)".

### Task 2: Auth data model, password hashing, recovery keys

**Files:**
- Create: `Sources/BudgetCore/Auth/AppUser.swift` (the `AppUser` and `LocalCredential` records), `Sources/BudgetCore/Auth/PasswordHasher.swift`, `Sources/BudgetCore/Auth/RecoveryKey.swift`
- Modify: `Sources/BudgetCore/Database/DatabaseManager.swift` (append `registerAppUserMigration(&migrator)` after `registerImportRuleMigration`)
- Test: `Tests/BudgetCoreTests/AuthModelTests.swift`

**Interfaces:**
- Produces:
  - `struct AppUser: Codable, FetchableRecord, MutablePersistableRecord`, with `id: Int64?`, `personId: Int64`, `displayName: String`, `cloudKitUserRecordName: String?`, `isAdmin: Bool`, `createdAt: Date` and `lastSignInAt: Date?`. The table is `appUser`.
  - `struct LocalCredential: Codable, FetchableRecord, PersistableRecord`, with `appUserId: Int64`, `passwordHash: String` and `recoveryKeyHash: String`. The table is `localCredential`, and `appUserId` is its primary key, with ON DELETE CASCADE.
  - `ImportRun.appUserId: Int64?`, and `ImportRule.createdByAppUserId: Int64?` and `ImportRule.lastLearntByAppUserId: Int64?`. These are new columns, each `REFERENCES appUser(id) ON DELETE SET NULL`.
  - `PasswordHasher.hash(_ password: String, rounds: Int = 600_000) -> String`, `PasswordHasher.verify(_ password: String, against encoded: String) -> Bool`, and `PasswordHasher.needsRehash(_ encoded: String) -> Bool`.
  - `RecoveryKey.generate() -> String` (24 characters from `ABCDEFGHJKLMNPQRSTUVWXYZ23456789`), `RecoveryKey.formatted(_:) -> String` ("XXXX-XXXX-…"), and `RecoveryKey.normalised(_ input: String) -> String` (uppercase; strips spaces and hyphens; maps O→0 and I/L→1 only if those characters can't appear, otherwise rejects them).

- [ ] **Step 1: Write failing tests:**
  - `testPBKDF2KnownVector`: the RFC 6070-style PBKDF2-HMAC-SHA256 vector ("password", "salt", 1 round) gives the known hex `120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b`.
  - `testHashRoundTripAndFormat`: the hash starts with `pbkdf2-sha256$600000$`, `verify` is true for the right password and false for a wrong one, and two hashes of the same password differ (the salts differ).
  - `testNeedsRehashBelowCurrentRounds`.
  - `testRecoveryKeyShapeAndNormalise`: it has 24 characters, all in the alphabet; `normalised` of the formatted key in lowercase with spaces equals the key; `normalised("O000…")` (outside the alphabet) is nil.
  - `testMigrationAddsTablesAndLeavesRowsUnchanged`: `migrate(upTo: "createImportRule")`, insert synthetic rows into `importRun`, `importRule` and `person`, then `migrate()`. The old rows are byte-identical in their old columns, the new columns are NULL, and the `appUser` and `localCredential` tables exist and are empty.
  - `testPersonDeleteRestrictedWhileAppUserExists`.
- [ ] **Step 2:** Run the tests and expect FAIL.
- [ ] **Step 3: Implement.** PBKDF2 is `CCKeyDerivationPBKDF` with a 32-byte output. Comparison is constant-time: XOR-accumulate over equal-length byte arrays.
- [ ] **Step 4:** Run the full suite and expect PASS. Also run `SelfAssessmentRegressionTests` (part of the suite) and expect PASS. Then the app build.
- [ ] **Step 5: Commit** "Auth model: appUser, local-only localCredential, attribution columns; PBKDF2 hashing; recovery keys".

### Task 3: AppUserStore

**Files:**
- Create: `Sources/BudgetCore/Auth/AppUserStore.swift`
- Test: `Tests/BudgetCoreTests/AppUserStoreTests.swift`

**Interfaces:**
- Consumes: Task 2's types.
- Produces (all `static`, taking `db: Database`):
  - `isSetUp(db) -> Bool`: any app user with a local credential.
  - `appUsers(db) -> [AppUser]`.
  - `signInCandidates(db) -> [AppUser]`: those with a local credential, ordered admin first, then by name.
  - `unclaimedPeople(db) -> [Person]`: people without an app user.
  - `create(db, personId:, displayName:, password:, isAdmin:, now:) throws -> (AppUser, recoveryKey: String)`: writes the user and its credential in one transaction.
  - `verifyPassword(db, appUserId:, password:) -> Bool`: also rehashes when `needsRehash`.
  - `verifyRecoveryKey(db, appUserId:, key:) -> Bool`.
  - `changePassword(db, appUserId:, newPassword:) throws`. The caller has already proved who they are.
  - `resetPassword(db, of:, by:, newPassword:) throws`: throws `.notAdmin` unless `by` is an admin.
  - `remove(db, _ appUserId:, by:) throws`: admin only. Throws `.lastAdmin` if it would leave no admin with a credential, and `.cannotRemoveSelf`.
  - `setAdmin(db, _ appUserId:, _ isAdmin: Bool, by:) throws`: admin only, keeps at least one admin.
  - `regenerateRecoveryKey(db, appUserId:) throws -> String`.
  - `recordSignIn(db, appUserId:, now:) throws`.
- Errors: `AppUserStoreError`, with `notAdmin`, `lastAdmin`, `cannotRemoveSelf`, `passwordTooShort` (fewer than 10 characters), `personAlreadyHasUser` and `noCredential`.

- [ ] **Step 1: Write failing tests:**
  - `testCreateWritesUserAndCredentialTogether` (a failure mid-write leaves neither row);
  - `testShortPasswordRejected`;
  - `testOnePersonOneUser`;
  - `testUserWithoutCredentialCannotSignIn` (insert an `appUser` row directly: not a candidate, and `verifyPassword` is false);
  - `testResetNeedsAdmin`;
  - `testCannotRemoveLastAdmin`;
  - `testCannotDemoteLastAdmin`;
  - `testRecoveryKeyResetsPasswordWithoutAnotherAdmin` (a single admin: `verifyRecoveryKey`, `changePassword`, and the new password verifies);
  - `testRegenerateInvalidatesOldKey`;
  - `testRehashOnVerifyWhenRoundsLow` (store a 1000-round hash: verify succeeds, and the stored hash now has 600000 rounds).
- [ ] **Step 2:** Run the tests and expect FAIL.
- [ ] **Step 3: Implement** in one place, enforcing the "at least one admin with a credential" invariant.
- [ ] **Step 4:** Run the tests and expect PASS. Then the full suite and the app build.
- [ ] **Step 5: Commit** "AppUserStore: create, verify, recover, reset, admin invariants".

### Task 4: Attribution of imports and learnt rules

**Files:**
- Modify:
  - `Sources/BudgetCore/DocumentImport/ImportApplier.swift`: `apply(_:entryPoint:reasons:now:)` becomes `apply(_:entryPoint:reasons:confirmedBy: Int64? = nil, now:)`, and writes `importRun.appUserId`.
  - `Sources/BudgetCore/DocumentImport/ImportRule.swift`: both `ImportRuleStore.learn` overloads gain `by appUserId: Int64? = nil`. On insert they set `createdByAppUserId` and `lastLearntByAppUserId`; on update only `lastLearntByAppUserId`.
  - The call sites that pass the confirming user: `ImportApplier` (line 292 area) and `ImportEffects` (200/266 area).
  - `App/DocumentImport/ImportCenterModel.swift`, which passes the signed-in user at Confirm. This needs a `currentAppUserId: () -> Int64?` closure injected at init.
  - `App/DocumentImport/ImportHistoryView.swift`: "Confirmed by <name>".
  - `App/Rules/ImportRulesTab.swift`: "Learnt from <name>'s correction", plus " · updated by <name>" when the two ids differ.
- Check: `ImportUndo` row comparison and `markUsed`. Exclude the attribution columns from the conflict comparison only if needed, so an Undo after a re-learn by the same run still works.
- Test: `Tests/BudgetCoreTests/ImportAttributionTests.swift`

**Interfaces:**
- Consumes: Task 2's columns.
- Produces: `ImportApplier.apply(..., confirmedBy:)` and `ImportRuleStore.learn(..., by:)`. The CLI tools and existing tests keep compiling through the defaults (nil).

- [ ] **Step 1: Write failing tests:**
  - `testRunRecordsConfirmingUser`;
  - `testConfirmRecordsUserAtConfirmTime` (plan once, apply with id A on one copy and id B on another: each run stores its own id);
  - `testRuleCreatedAndRelearntBy` (learn with A gives created A and last A; re-learn with B keeps created A and sets last B);
  - `testUndoOfRunThatLearntRuleStillWorks`;
  - `testNilAttributionForTools`.
- [ ] **Step 2:** Run the tests and expect FAIL.
- [ ] **Step 3: Implement** as above. The names in the UI come from `appUser.displayName`. A nil or deleted user shows nothing.
- [ ] **Step 4:** Run the full suite (including the import suites) and expect PASS. Then the app build.
- [ ] **Step 5: Commit** "Imports and learnt import rules record who confirmed and who taught them".

### Task 5: Session, Touch ID and locking (App layer, with BudgetCore seams)

**Files:**
- Create:
  - `Sources/BudgetCore/Auth/SignInThrottle.swift`: the 5-attempt delay schedule (pure, testable).
  - `Sources/BudgetCore/Auth/BiometricEnrolment.swift`: the protocol plus the pure enrolment logic.
  - `App/Auth/SessionModel.swift`
  - `App/Auth/BiometricUnlock.swift`: `KeychainBiometricUnlock` and `LAContextBiometricUnlock`.
  - `App/Auth/IdleMonitor.swift`
- Modify: `App/AppEnvironment.swift`, which owns `session: SessionModel`, reachable from the Settings scene through `AppEnvironment.Current.shared`.
- Test: `Tests/BudgetCoreTests/SignInThrottleTests.swift` and `Tests/BudgetCoreTests/BiometricEnrolmentTests.swift`, using a fake store.

**Interfaces:**
- `SignInThrottle`, with `mutating func recordFailure(now:)`, `func delay(now:) -> TimeInterval` (0 for the first 5 failures, then 1, 2, 4 … capped at 60) and `mutating func reset()`.
- `protocol BiometricUnlocker`, with:
  - `var isAvailable: Bool`;
  - `func enrol(appUserId: Int64) async throws`;
  - `func unlock(appUserId: Int64, reason: String) async throws -> Bool`;
  - `func remove(appUserId: Int64)`;
  - `func enrolledIds() -> Set<Int64>`.
- `KeychainBiometricUnlock`:
  - It stores a 32-byte random secret per app user in the data-protection Keychain (`kSecUseDataProtectionKeychain: true`).
  - Service `ubberninja.mango.unlock`, account `"<appUserId>"`, and the access group from the entitlements.
  - The access control is `SecAccessControlCreateWithFlags(.., kSecAttrAccessibleWhenUnlockedThisDeviceOnly, .biometryCurrentSet)`.
  - `unlock` reads the item with an `LAContext`. `errSecItemNotFound` after a biometry change counts as "not enrolled".
- `LAContextBiometricUnlock`:
  - It is the fallback: enrolment is in UserDefaults key `auth.enrolledAppUserIds`, with `auth.biometryDomainState` holding the `evaluatedPolicyDomainState` data.
  - A changed domain state clears enrolment.
- Selection: `BiometricUnlock.make()` probes once by adding and deleting a throwaway item. On `errSecMissingEntitlement` (-34018) it uses the fallback.
- `SessionModel` (@MainActor, ObservableObject):
  - `@Published state: .notSetUp | .locked | .signedIn(AppUser)`, plus `func signIn(appUserId:password:) async -> SignInResult`, `func signInWithBiometrics(appUserId:) async`, `func lock()`, `var lockTimeout: LockTimeout` (UserDefaults `auth.lockTimeout`; `.minutes(5/15/30/60)` or `.never`; default 15) and `var currentAppUserId: Int64?`.
  - It locks on: idle (`NSEvent` local and global monitors reset a timer), `NSWorkspace.screensDidSleepNotification`, `willSleepNotification`, and the `com.apple.screenIsLocked` distributed notification.
  - Under `SNAPSHOTS` it starts `.signedIn` as a demo user, through the existing `SnapshotMode`.

- [ ] **Step 1: Write failing tests:**
  - `testThrottleSchedule` (0 ×5, then 1, 2, 4, 8, 16, 32, 60, 60);
  - `testChangedBiometryDropsEnrolment` (a fake domain-state store: enrol, change the state, and `enrolledIds` is empty);
  - `testEnrolmentIsPerMacNotInDatabase` (enrolment lives only in the injected defaults or keychain fake; a new DB with the same user ids has no enrolment);
  - `testRemoveClearsEnrolment`.
- [ ] **Step 2:** Run the tests and expect FAIL.
- [ ] **Step 3: Implement.** Keep the Keychain and LAContext code thin. Put the decisions in `BiometricEnrolment` so they're testable with fakes.
- [ ] **Step 4:** Run the tests, the full suite and the app build, and expect PASS.
- [ ] **Step 5: Commit** "Session: sign-in, throttle, Touch ID (Keychain-bound on team builds, LAContext fallback), auto-lock".

### Task 6: Setup, lock overlay, Settings ▸ Sign-in, menus, sidebar footer

**Files:**
- Create: `App/Auth/SetupFlowView.swift`, `App/Auth/LockOverlay.swift`, `App/Auth/RecoveryKeySheet.swift`, `App/Settings/SignInSettings.swift`
- Modify:
  - `App/LaunchView.swift`: `.notSetUp` goes to setup.
  - `App/BudgetApp.swift`: the root modifier `.lockOverlay(session)` on the `WindowGroup` and the `Settings` scenes, and commands for Lock (⌃⌘L) and Switch User… in the app menu (shown only when `signInCandidates.count > 1`).
  - `App/Settings/SettingsView.swift`: a "Sign-in" tab (`systemImage: "person.badge.key"`).
  - `App/ContentView.swift`: the sidebar footer with the initials and a lock button.
  - `App/Snapshots/SnapshotCatalog.swift`: the routes `auth-setup`, `auth-recovery-key`, `auth-locked-one`, `auth-locked-two`, `auth-forgot-password` and `settings-sign-in`.
- Copy (exact):
  - "Set up Mango"
  - "Who are you?"
  - "Choose a password"
  - "At least 10 characters"
  - "Use Touch ID on this Mac"
  - "Your recovery key"
  - "If you forget your password, this key lets you set a new one. Save it in your password manager: it's shown only once."
  - "Copy"
  - "I've saved it"
  - "Add <name> now?" with "Add" and "Later"
  - "Mango is locked"
  - "Use password"
  - "Forgot password?"
  - "Enter your recovery key"
  - "Lock"
  - "Switch User…"
  - "Lock after" with "5 minutes", "15 minutes", "30 minutes", "1 hour" and "Never"
  - "Change password…"
  - "Regenerate recovery key…"
  - "Household"
  - "Make admin"
  - "Reset password…"
  - "Remove…"
  - "Confirmed by <name>"
  - "Learnt from <name>'s correction"
- Rules:
  - The overlay is opaque and covers every window, the Settings window included.
  - The setup's "Add <other person>" defaults to Later.
  - Edits in Settings save only on Save.
  - Wrong passwords show the throttle delay as "Try again in N s".

- [ ] **Step 1:** Add the snapshot routes, rendering from the demo DB with synthetic users. Run `scripts/render-snapshots.sh <out> --only auth-setup,auth-recovery-key,auth-locked-one,auth-locked-two,auth-forgot-password,settings-sign-in` and expect no figure wrapping at 1100×700, in both appearances.
- [ ] **Step 2: Build the views and wiring.** The app build must succeed. Run the full suite.
- [ ] **Step 3: Commit** "Setup, lock screen, Settings ▸ Sign-in, Lock and Switch User".

### Task 7: The rename to Mango

**Files:**
- Modify:
  - `project.yml`: `name: Mango`; target `Mango` (`PRODUCT_NAME: Mango`); `CURRENT_PROJECT_VERSION` bumped by 1; `UTTypeDescription: Mango account reference`. Keep `PRODUCT_BUNDLE_IDENTIFIER: ubberninja.mango` and the UTType id unchanged.
  - App-name copy in `App/` (`LaunchView` title, menu items, messages that name the app such as "Mango deletes its copy…" and "Mango stops scanning it…", the window title fallback). Find it with `grep -rn '"Budget' App` and judge each hit: the budget grid and plan keep "Budget".
  - `scripts/install-app.sh`:
    - quit check `pgrep -x Mango || pgrep -x Budget`;
    - build and install `Mango.app`;
    - once, if `/Applications/Budget.app` exists, unregister it from LaunchServices and remove it.
  - `scripts/render-snapshots.sh`: the app path.
  - `.claude/skills/install/SKILL.md`: the text.
  - The CLI "quit first" messages: "Mango is running: quit it…". The checks stay bundle-id based, with `AppIdentity.macBundleIdentifiers`.
- Test: a source-scan test, `testNoAppNameBudgetInUserCopy`. It greps `App/**/*.swift` string literals for `"Budget is`, `"Budget ▸`, `"Budget deletes`, `"Budget stops` and `"Set up Budget`, and expects none.

- [ ] **Step 1:** Write the scan test and expect FAIL.
- [ ] **Step 2:** Rename. Run `xcodegen generate` and the app build: scheme `Mango` must give BUILD SUCCEEDED.
- [ ] **Step 3:** Run the scan test, the full suite and the snapshot render for 3 routes, and expect PASS.
- [ ] **Step 4: Commit** "Rename the app to Mango (product name, copy, install script); identifiers and data folder unchanged".

### Task 8: The Mango icon

**Files:**
- Create:
  - `docs/design/mango-icon-layers/` (one SVG per top-level group of `docs/design/mango-icon.svg`, produced by a script).
  - `scripts/split-icon-layers.swift`.
- Modify: `scripts/generate-app-icon.swift`, which rasterises `docs/design/mango-icon.svg` with NSImage (macOS 26 renders SVG) into every `AppIcon.appiconset` size. Below 32 px it uses the simplified drawing: the gloss, shading, shadow and leaf-vein groups are hidden.
- Optional, a user step: an Icon Composer document `App/Mango.icon`. If it is present, `project.yml` uses it, with `ASSETCATALOG_COMPILER_APPICON_NAME: Mango`, instead of the appiconset.

- [ ] **Step 1:** Run `swift scripts/split-icon-layers.swift` and expect 8 layer SVGs, each a valid standalone SVG with the shared `<defs>`.
- [ ] **Step 2:** Run `swift scripts/generate-app-icon.swift` and expect all sizes written. Visually check the 1024 and 16 px PNGs (Read the image files).
- [ ] **Step 3:** Run the app build and expect BUILD SUCCEEDED.
- [ ] **Step 4: Commit** "Mango icon: layers for Icon Composer, rasterised AppIcon from the master SVG".
- [ ] **Step 5 (user, optional):** in Icon Composer, File ▸ New, then drag in the layers from `docs/design/mango-icon-layers/` in order. Set the dark, tinted and clear appearances per overview §2.4 and save as `App/Mango.icon`. The controller wires it in and rebuilds.

### Task 9: Rehearsal on a copy, then the hand-over

- [ ] **Step 1:** Copy the real database (`sqlite3 .backup`) into the scratchpad. Run the app binary from the branch build with `BUDGET_DB_PATH=<copy>`, or a small test harness calling `AppEnvironment.load`'s steps. Expect a `pre-migration-backup` beside the copy, the migration applied, and the setup flow shown.
- [ ] **Step 2:** On the migrated copy, compare every table's row count and contents with the original, excluding the new tables and columns. Expect identical.
- [ ] **Step 3:** Run `TaxRegression --no-apply` and `SelfAssessmentRegression` on the original copy and on the migrated copy. Expect the outputs identical apart from the path header line.
- [ ] **Step 4: Final whole-branch review**, then hand over. Merge only when the user says so. After merging: xcodegen, a signed install (which installs `Mango.app` and removes `Budget.app`), and the user does the setup on their real data. The automatic backup runs first.
