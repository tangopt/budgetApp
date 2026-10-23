# Authentication — design

Status: agreed (2026-10-22). Drafted 2026-10-21 while the user was away, then checked against the code by
a builder. The user accepted the changes requested by the sync spec (`2026-10-22-sync-and-access-design.md`
§11, items 1–8), and they are folded in here. Decisions the user didn't make are marked **(my call)**.

The app is called **Mango** (overview §2.4–§2.5). Its identifiers are `ubberninja.mango` (Mac),
`ubberninja.mango.ios`, `iCloud.ubberninja.mango` and `group.ubberninja.mango`, set in build step 0.
The data folder stays `~/Library/Application Support/Budget/`.

## 1. Why

Mango has always been one person's app on one Mac: no sign-in, one database in
`~/Library/Application Support/Budget/`. Two things change that:

- **Two people, independent accounts.** The household is two people, the app's two existing `person`
  rows. Each should sign in as themselves and be recorded as the one who did something, such as
  confirming an import.
- **iPhone and iPad companions are coming** (overview, iPhone, iPad and sync specs). They need an identity
  that works across devices.

Authentication comes first, on the desktop, because the companions build on it (overview §4, build step 1).
This spec is the whole design across devices, and **implementation-ready for the Mac** (§§3–9). The
cross-device part (§10) is the contract the companion and sync specs build on.

## 2. Goals, non-goals, anti-goals

Goals
- Each person has their own app account, tied to their `person` row.
- Opening the app, and coming back after it locks, requires that person: Touch ID or their password.
- The app records who confirmed each import and who taught each learnt import rule.
- The design survives the move to sync and mobile without a redo (§10). In particular, secrets live in a
  table that never syncs (`localCredential`, §4) from the start.

Non-goals (desktop-only v1, build step 1)
- **No per-person privacy in v1.** Both people see and edit everything, as today. Privacy arrives with
  sync, where it is real: per-person private CloudKit zones, sharing levels set by the owner and
  permissions set by the admin (sync spec §6, build step 5). Inside one local database it would mean
  filtering about 90 query sites for a weak protection.
- No server, no email/password service, no third-party identity provider (identity across devices is the
  person's iCloud account, §10).
- No database encryption beyond FileVault (§8).
- No general "changed by" on every record. That comes with sync (`syncRecord.modifiedBy`, §10).

Anti-goals
- Anything that can lock the household out of its own data. There is always a recovery path (§7), and
  nothing in recovery deletes data.
- Anything that puts the filed tax returns at risk. The migration only adds things.
- Friction in the everyday case: one Touch ID press, or none within the lock timeout.

## 3. Concepts

- **Person**: the existing table (the household's two members, as the tax and property model knows
  them). Unchanged.
- **App user** (new): an account that can sign in. At most one per person. It will sync with the
  household (sync spec §4) once sync exists.
- **Local credential** (new): an app user's password and recovery-key hashes on this Mac. **It never
  syncs and never leaves the Mac** (sync spec §11.6).
- **Mac enrolment** (new): this Mac remembers which app users have Touch ID turned on (§8). It is
  device-local.
- **macOS users** (sync spec §3.1): normally each person uses Mango on their own macOS user, so each
  Mango on the Mac holds one app user. Two app users in one Mango happen only when both people share a
  macOS user. That's supported, without private data once privacy exists.
- **Session**: the signed-in app user of the running app, held in memory and shared by all windows,
  including the Settings window. It locks after inactivity and on screen lock or sleep.

## 4. Data model (BudgetCore, one migration appended last)

Migration `createAppUser`, registered through a `registerAppUserMigration` call appended at the end of
`DatabaseManager.registerMigrations`, like the existing ones.

```
appUser                                        -- will sync (household zone) once sync exists
  id                      INTEGER PK
  personId                INTEGER NOT NULL UNIQUE REFERENCES person(id) ON DELETE RESTRICT
  displayName             TEXT NOT NULL               -- shown on the lock screen
  cloudKitUserRecordName  TEXT UNIQUE                 -- CKContainer.userRecordID(); NULL until iCloud sync is on (§10)
  isAdmin                 BOOLEAN NOT NULL DEFAULT 0
  createdAt               DATETIME NOT NULL
  lastSignInAt            DATETIME                    -- device-local meaning; excluded from sync

localCredential                                -- NEVER synced, never leaves the Mac (sync spec §11.6)
  appUserId        INTEGER PRIMARY KEY REFERENCES appUser(id) ON DELETE CASCADE
  passwordHash     TEXT NOT NULL               -- "pbkdf2-sha256$<rounds>$<salt b64>$<hash b64>"
  recoveryKeyHash  TEXT NOT NULL               -- same format (§7)

importRun.appUserId               INTEGER REFERENCES appUser(id) ON DELETE SET NULL
importRule.createdByAppUserId     INTEGER REFERENCES appUser(id) ON DELETE SET NULL  -- set on insert, kept on update
importRule.lastLearntByAppUserId  INTEGER REFERENCES appUser(id) ON DELETE SET NULL  -- set on insert and on every re-learn
```

Rules
- The migration only adds tables and nullable columns. No existing value changes. The filed-year
  regressions (`Sources/TaxRegression`, `SelfAssessmentRegressionTests`) must pass unchanged.
- App users and their local credentials are created together by the setup flow (§6), never by the
  migration. A migrated database with no app users is valid and means "not set up yet".
- An app user with no `localCredential` on this Mac exists once sync is on: it is the other person,
  synced from another device. It can't sign in here until that person sets a password on this Mac (§6).
- `memberPermission` (sync spec §6.2) is **not** part of build step 1. It comes with the household work
  (build step 6). `isAdmin` and the "at least one admin" invariant stay as they are.
- `ImportUndo` compares row JSON when it checks for conflicts. The implementer checks whether the new
  `importRule` columns need excluding there, and whether `markUsed` (or anything else that updates
  `importRule`) needs the attribution. Undoing a run that learnt a rule removes or reverts it as today.
- The categorisation `rule` table (RuleLearner) gets no attribution in v1.
- Swift: `AppUser` and `LocalCredential` (GRDB records) in `Sources/BudgetCore/Auth/`.

## 5. What each person sees and can do

- **v1: everything shared, both can edit** (§2). The only difference between the two people is who is
  signed in: it shows in the UI and is written on import runs and learnt import rules.
- **Admin**: the first user set up, plus anyone they make admin. Admins can add or remove the other app
  user, reset their password on this Mac and make them admin. There is always at least one admin,
  enforced in one place in the store.
- **With sync** (not in v1), sharing levels (owner-set) and per-area permissions (admin-set) arrive as in
  sync spec §6. The admin's permissions apply to shared data only; nobody can set the level of someone
  else's account.

## 6. Desktop UX

All app-name copy says **Mango** (sync spec §11.8). "Budget" stays only where it names the budget grid or
plan.

**Backup before any migration (new, general).** `AppEnvironment.load()` migrates on every launch, before
any UI. A new step runs first:
- When the database exists and has pending migrations, copy it to
  `budget.sqlite.pre-migration-backup-<yyyyMMdd-HHmmss>`, next to the existing backups.
- Then migrate. Keep the newest 5 of these backups and delete older ones of the same pattern only.
- A failed backup stops the launch with an error in `LaunchView`. It never migrates without one.
- This protects this migration and every later one. `install-app.sh` doesn't change for this.

**First launch after the update (not set up yet).** `LaunchView` shows the setup flow instead of the
content:
1. "Set up Mango". Pick which person you are from the existing person rows (the list shows every person
   without an app user). Choose a password: at least 10 characters, with a strength hint. Turn on Touch ID
   for this Mac if it has Touch ID; it's on by default.
2. Your recovery key appears once, with "Copy" and "I've saved it" (§7). You become admin.
3. Optional, only for a shared macOS user: "Add <other person>". They type their own password now, or
   choose "Later". Normally the other person uses their own macOS user and sets up there (sync spec §3.1),
   so the default answer is "Later".

**The other person's own macOS user** (sync spec §3.1, §11.5). Their Mango has its own database, so it
runs the same setup on first launch. Once sync exists, their app user is created when they accept the
household share, on their iPhone or their macOS user, whichever comes first. The admin confirms which
`person` they are, and setup on their macOS user then only asks for their own password and Touch ID.

**Lock screen.** An overlay over every window, the Settings window included, not a separate window:
- The app's icon and "Mango is locked".
- One avatar button per app user with a local credential on this Mac (initials in a circle, display name
  under it). On a per-person macOS user that is normally one avatar.
- Clicking an avatar enrolled for Touch ID on this Mac asks for Touch ID. "Use password" is always there.
- An app user not enrolled on this Mac signs in with their password, then is offered Touch ID here.
- Content underneath is hidden, not just blurred: the overlay is opaque.

**When it locks (my call)**
- After 15 minutes without input. Settings ▸ Sign-in offers 5, 15, 30 or 60 minutes, or Never.
- On screen lock and on sleep.
- On demand: Mango ▸ Lock (⌃⌘L), or the lock button in the sidebar footer next to the signed-in person's
  initials.

Locking keeps windows and open sheets in memory. An import that is reading or waiting in review keeps its
state. The confirming user is taken when Confirm import is pressed, not when the import started.

**Switching person**: Mango ▸ Switch User… locks and shows the avatars. It appears only when this Mac
has more than one app user with a local credential, which means a shared macOS user.

**Settings ▸ Sign-in** (new tab; not "Accounts", which would clash with the bank Accounts screen):
- Everyone: your name, change password, Touch ID on this Mac (on/off), lock timeout, regenerate recovery
  key.
- Admins also get the household's app users on this Mac: add, remove, reset password, make admin.

**Attribution in the UI**
- Import runs (the Imports screen's run list and undo) show "Confirmed by <name>". Runs from before
  sign-in show nothing.
- Learnt import rules (Rules ▸ Import rules) show "Learnt from <name>'s correction". When the latest
  learning came from the other person, the line also says "updated by <name>".

Copy and layout follow the design system (ui-polish spec §1/§6). The setup, lock screen and Settings tab
fit 1100×700 and the smallest window size.

## 7. Recovery **(my call)**

- **Forgotten password, another admin with a local credential on this Mac:** they reset it from
  Settings ▸ Sign-in.
- **Forgotten password, Touch ID on this Mac:** Touch ID signs you in, and you change the password
  without the old one. Touch ID counts as the proof.
- **Last resort:** the recovery key. It is 24 characters from an unambiguous alphabet, shown in groups
  of 4, and stored only as a hash (`localCredential.recoveryKeyHash`, same PBKDF2 format as passwords).
  Entering it on the lock screen ("Forgot password?") lets you set a new password. Regenerating it
  invalidates the old one.
- **Nothing in recovery deletes or re-encrypts data.**

## 8. Security model

What it protects
- Casual use of the app on an unattended or shared Mac.
- Attribution of imports and learnt import rules.

What it doesn't protect
- The database file from anyone with the macOS user's file access. FileVault and the macOS login do that,
  and separate macOS users (sync spec §3.1) keep each person's files apart.
- Encrypting the database (SQLCipher) would need a key in the Keychain, migrating the file and the
  evidence library, and complicates CloudKit. It is not worth it for v1.

Passwords and recovery keys
- PBKDF2-HMAC-SHA256 via CommonCrypto, 600 000 rounds, 16-byte random salt, constant-time compare.
- `needsRehash` raises the rounds later. Never logged.
- Stored only in `localCredential`, which never syncs (§4).
- After 5 wrong attempts, an increasing delay (1 s, 2 s, 4 s… up to 60 s), held in memory. A restart
  resets it, which is acceptable given the threat model.

Touch ID
- **Team-signed builds (the normal case since build step 0).** Each enrolled app user gets an item in the
  data-protection Keychain, under the keychain access group in `App/Mango.entitlements`. Its access
  control is `.biometryCurrentSet`, and it holds a random 32-byte device secret. Unlocking as that user
  means reading their item with Touch ID. So a fingerprint unlocks only the app users enrolled with it on
  this Mac, and a copied database can't be unlocked elsewhere. When the Mac's fingerprints change, the
  item becomes unreadable: enrolment is dropped and the password is asked once.
  Who is enrolled is read from a separate, non-secret index (`auth.keychainEnrolledAccounts` in this
  Mac's preferences, written on enrol and dropped on remove or a not-found read), never by querying the
  access-controlled items: a listing of them without interaction can come back empty or refused on a team
  build, and the lock screen then never offered Touch ID (fixed 2026-10-23).
- **Unsigned local builds (no `Config/Signing.local.xcconfig`; the membership lapsed, overview §3.1).**
  The data-protection Keychain isn't available without a team (errSecMissingEntitlement), so the
  fallback is `LAContext.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics)` alone. Enrolment is
  then a per-Mac list of app user ids in UserDefaults, stored with
  `LAContext.evaluatedPolicyDomainState`. A Touch ID check unlocks any app user enrolled on that Mac. On
  a per-person macOS user that is only its owner.
- The app is not sandboxed. Nothing here needs it to be.

Bypasses
- Only the snapshot build (`SNAPSHOTS`) skips the lock, signed in as a demo user.
- Plain Debug builds and Release builds with `BUDGET_DB_PATH` (manual testing on a copy) require sign-in
  like any other run. A copy of a set-up database carries its app users and local credentials.
- The CLI tools (ImportRehearsal, ImportDryRun, …) don't sign in. They pass `appUserId: nil`. Their
  "quit the app first" check looks for both bundle ids (`AppIdentity.macBundleIdentifiers`).

## 9. Desktop implementation outline

BudgetCore (`Sources/BudgetCore/Auth/`)
- `AppUser` and `LocalCredential` records, and the `createAppUser` migration (§4).
- `DatabaseManager`: `hasPendingMigrations` and the pre-migration backup with retention (§6).
- `PasswordHasher`: hash, verify, needsRehash.
- `RecoveryKey`: generate, format, normalise input.
- `AppUserStore`:
  - `isSetUp`, `appUsers`, `signInCandidates` (app users with a local credential);
  - `create(personId:displayName:password:isAdmin:)`, which writes the app user and its credential in
    one transaction;
  - `verifyPassword`, `verifyRecoveryKey`, `changePassword`, `resetPassword(of:by:)`;
  - `remove(_:by:)`, `setAdmin`, `regenerateRecoveryKey`, `recordSignIn`;
  - the "at least one admin" invariant.
- Attribution:
  - `ImportApplier.apply(…, confirmedBy: Int64?)` writes `importRun.appUserId`. It goes on `apply`, not
    the initialiser, because one applier serves the app and the user can switch.
  - `ImportRuleStore.learn(…, by: Int64?)` sets `createdByAppUserId` on insert and
    `lastLearntByAppUserId` on insert and update. The `learn` call sites (ImportApplier, ImportEffects)
    pass it through.
  - ImportRehearsal, ImportDryRun and the tests pass `nil`.

App
- `SessionModel` (@MainActor, ObservableObject):
  - states `.notSetUp`, `.locked`, `.signedIn(AppUser)`;
  - idle timer (event monitor);
  - `NSWorkspace` screen-lock and sleep notifications;
  - Touch ID through `BiometricUnlock`: the Keychain-bound item when the build has a team, otherwise the
    `LAContext`-only fallback (§8).
- `AppEnvironment` owns the session (also reachable from the Settings scene through the existing
  `AppEnvironment.Current.shared`).
- `LaunchView` routes `.notSetUp` to setup. A root modifier puts the lock overlay over the main windows
  and the Settings window.
- Settings ▸ Sign-in tab; menu items Mango ▸ Lock (⌃⌘L) and Mango ▸ Switch User…; sidebar footer with
  initials and lock button.
- `ImportCenterModel` passes the signed-in app user at Confirm.
- Attribution lines on the Imports run list and on Rules ▸ Import rules.

Tests
- BudgetCore:
  - hashing (known PBKDF2 vectors, rehash) and recovery keys;
  - the store's invariants (unique person, at least one admin, reset by admin only, credential written
    with its user, no sign-in without a credential);
  - attribution on import runs and on learnt rules, insert and update;
  - undo of a run that learnt a rule still works;
  - the pre-migration backup (made only when migrations are pending, retention of 5, failure stops launch).
- Migration test: build a pre-auth database with the test-only `migrate(upTo:)` and fill it with
  synthetic rows. After migrating, every existing row is unchanged and the filed-year regressions pass.
- App: snapshot routes (demo DB only) for setup, the lock screen (one and two users) and Settings ▸
  Sign-in. No figure wraps at 1100×700.
- Rehearsal: migrate a copy of the real database (read-only source) and compare tax figures and row
  counts. The real database migrates on the first launch after install, behind the automatic backup.

## 10. Across devices (contract for the companion apps and sync)

These replace the 2026-10-21 draft's Sign in with Apple and privacy sketch (sync spec §11).

- **Identity across devices = the person's iCloud account** (§11.1).
  - `appUser.cloudKitUserRecordName` comes from `CKContainer.userRecordID()` on the person's own device.
    For the member it is matched through the share participant's `userIdentity`.
  - On the Mac, Settings ▸ Sign-in offers "Turn on iCloud sync", which records it.
  - Sign in with Apple isn't used: CloudKit already authenticates each person.
- **No app password on iPhone and iPad** (§11.2). Unlock is `LAContext.deviceOwnerAuthentication`: Face
  ID or Touch ID, with the device passcode as fallback. The mobile lock happens:
  - on launch;
  - after 5 minutes in the background;
  - before confirming an import, Undo or a sharing-level change.
- **Privacy comes with sync** (§11.3): sharing levels per account set by the owner, in per-person
  private zones, plus admin-set permissions (sync spec §6).
- **Permissions** (§11.4): `memberPermission` (sync spec §6.2) is added with the household work. `isAdmin`
  and the "at least one admin" invariant stay.
- **One macOS user each** (§11.5, sync spec §3.1): see §3 and §6. "Add <other person>" and "Switch User"
  remain for a shared macOS user, without private data.
- **Secrets never sync** (§11.6): `localCredential` (§4), built in step 1.
- **Attribution** (§11.7): `syncRecord.modifiedBy` records the last writer of every synced record.
  `importRun.appUserId` and `importRule.*ByAppUserId` stay, because they say who confirmed or taught.
- **Name** (§11.8): all copy says Mango. No identifier changes because of the rename. The bundle id
  (`ubberninja.mango`), the data folder and the Keychain service stay.

## 11. Rollout

1. Build on a branch (subagent-driven, as usual), together with the Mango rename and icon (overview §2.5).
   Rehearse the migration on a copy.
2. Merge (when the user says so) and install. On the next launch the automatic backup is taken, the
   migration runs, and setup appears. The user does the setup themselves.
3. The other person sets up on their own macOS user when convenient.
4. iCloud identity (`cloudKitUserRecordName`) waits for the sync work (build step 3).

## 12. Decisions

Settled by the user (2026-10-22, sync spec §11):
- Privacy with sync, not in v1; one macOS user each; iCloud identity; no mobile password;
  `localCredential` now; `memberPermission` later; the Mango name.

Made without the user **(my calls, unchallenged so far)**:
1. Lock after 15 minutes idle, on screen lock and sleep, and on demand; configurable (§6).
2. Recovery: another admin, Touch ID, or a one-time recovery key. Nothing ever deletes data (§7).
3. No database encryption beyond FileVault (§8).
4. The first user is admin, and there is always at least one admin (§5).
5. Attribution only for import runs and learnt import rules, until sync (§4).
6. A general pre-migration backup on launch, keeping the newest 5 (§6).
7. Touch ID is Keychain-bound per app user on team-signed builds, with the `LAContext`-only fallback for
   unsigned builds (§8). This follows from build step 0.
