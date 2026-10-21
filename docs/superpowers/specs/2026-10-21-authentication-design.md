# Authentication — design

Status: draft for the user's review (2026-10-21). Written while the user was away, at their request
("make the spec… I will leave you working by yourself"). A builder check against the code has been
applied. Every decision the user didn't make is marked **(my call)**. The two that most change what gets
built are at the top of §12 for the user to confirm.

## 1. Why

Budget has always been one person's app on one Mac: no sign-in, one database in
`~/Library/Application Support/Budget/`. Two things change that:

- **Two people, independent accounts.** The household is two people, the app's two existing `person`
  rows. Each should sign in as themselves and be recorded as the one who did something, such as
  confirming an import.
- **iPhone and iPad companions are coming** (separate spec). They need an identity that works across
  devices.

Authentication comes first, on the desktop, because the companions build on it. This spec is the whole
design across devices, and **implementation-ready for the Mac** (§§3–9). The cross-device part (§10) is
the contract the companion spec must honour, not a build plan.

## 2. Goals, non-goals, anti-goals

Goals
- Each person has their own app account, tied to their `person` row.
- Opening the app, and coming back after it locks, requires that person: Touch ID or their password.
- The app records who confirmed each import and who taught each learnt import rule.
- The design survives the move to sync and mobile without a redo (§10).

Non-goals (v1)
- **No per-person privacy.** Both people see and edit everything, as today. Private accounts and tax
  years are deferred to the sync work, where they become real: a per-person CloudKit zone. Inside one
  local database they would mean filtering about 90 query sites (net worth, budget grid, forecast, tax,
  search, transfer matching…) for a weak protection, since the file is readable by the Mac user anyway.
  **(my call, see §12.1)**
- No server, no email/password service, no third-party identity provider.
- No database encryption beyond FileVault (§8).
- No general "changed by" on every record. That comes with sync, which records who changed what.

Anti-goals
- Anything that can lock the household out of its own data. There is always a recovery path (§7), and
  nothing in recovery deletes data.
- Anything that puts the filed tax returns at risk. The migration only adds things.
- Friction in the everyday case: one Touch ID press, or none within the lock timeout.

## 3. Concepts

- **Person**: the existing table (the household's two members, as the tax and property model knows
  them). Unchanged.
- **App user** (new): an account that can sign in. At most one per person.
- **Mac enrolment** (new): this Mac remembers which app users have Touch ID turned on. Kept per Mac in the
  app's UserDefaults, never in the database (§8).
- **Session**: the signed-in app user of the running app, held in memory and shared by all windows,
  including the Settings window. It locks after inactivity and on screen lock or sleep.

## 4. Data model (BudgetCore, one migration appended last)

Migration `createAppUser`, registered through a `registerAppUserMigration` call appended at the end of
`DatabaseManager.registerMigrations`, like the existing ones.

```
appUser
  id               INTEGER PK
  personId         INTEGER NOT NULL UNIQUE REFERENCES person(id) ON DELETE RESTRICT
  displayName      TEXT NOT NULL               -- shown on the lock screen
  passwordHash     TEXT NOT NULL               -- "pbkdf2-sha256$<rounds>$<salt b64>$<hash b64>"
  recoveryKeyHash  TEXT NOT NULL               -- same format (§7)
  appleUserId      TEXT UNIQUE                 -- Sign in with Apple's stable id; NULL until linked (§10)
  isAdmin          BOOLEAN NOT NULL DEFAULT 0
  createdAt        DATETIME NOT NULL
  lastSignInAt     DATETIME

importRun.appUserId               INTEGER REFERENCES appUser(id) ON DELETE SET NULL
importRule.createdByAppUserId     INTEGER REFERENCES appUser(id) ON DELETE SET NULL  -- set on insert, kept on update
importRule.lastLearntByAppUserId  INTEGER REFERENCES appUser(id) ON DELETE SET NULL  -- set on insert and on every re-learn
```

Rules
- The migration only adds a table and nullable columns. No existing value changes. The filed-year
  regressions (`Sources/TaxRegression`, `SelfAssessmentRegressionTests`) must pass unchanged.
- App users are created by the setup flow (§6), never by the migration. A migrated database with no app
  users is valid and means "not set up yet".
- `ImportUndo` compares row JSON when it checks for conflicts. The implementer checks whether the new
  `importRule` columns need excluding there, and whether `markUsed` (or anything else that updates
  `importRule`) needs the attribution. Undoing a run that learnt a rule removes or reverts it as today.
- The categorisation `rule` table (RuleLearner) gets no attribution in v1.
- Swift: `AppUser` (GRDB record) in `Sources/BudgetCore/Auth/`.

## 5. What each person sees and can do

- **v1: everything shared, both can edit** (§2). The only difference between the two people is who is
  signed in: it shows in the UI and is written on import runs and learnt import rules.
- **Admin**: the first user set up, plus anyone they make admin. Admins can add or remove the other app
  user, reset their password and make them admin. There is always at least one admin, enforced in one
  place in the store.
- The future privacy model (per-person private accounts and tax years) is sketched in §10 so the sync
  design keeps room for it. Nothing about it is built now.

## 6. Desktop UX

**Backup before any migration (new, general).** `AppEnvironment.load()` migrates on every launch, before
any UI. A new step runs first:
- When the database exists and has pending migrations, copy it to
  `budget.sqlite.pre-migration-backup-<yyyyMMdd-HHmmss>`, next to the existing backups.
- Then migrate. Keep the newest 5 of these backups and delete older ones of the same pattern only.
- A failed backup stops the launch with an error in `LaunchView`. It never migrates without one.
- This protects this migration and every later one. `install-app.sh` doesn't change.

**First launch after the update (not set up yet).** `LaunchView` shows the setup flow instead of the
content:
1. "Set up Budget for your household". Pick which person you are from the existing person rows (the
   real database has exactly the two household members; the list shows every person without an app
   user). Choose a password: at least 10 characters, with a strength hint. Turn on Touch ID for this Mac
   if it has Touch ID; it's on by default.
2. Your recovery key appears once, with "Copy" and "I've saved it" (§7). You become admin.
3. Optional: "Add <other person>". They type their own password now, or choose "Later". The admin can
   add them from Settings ▸ Sign-in at any time.

**Lock screen.** An overlay over every window, the Settings window included, not a separate window:
- The app's icon and "Budget is locked".
- One avatar button per app user (initials in a circle, display name under it).
- Clicking an avatar enrolled for Touch ID on this Mac asks for Touch ID. "Use password" is always there.
- An app user not enrolled on this Mac signs in with their password, then is offered Touch ID here.
- Content underneath is hidden, not just blurred: the overlay is opaque.

**When it locks (my call)**
- After 15 minutes without input. Settings ▸ Sign-in offers 5, 15, 30 or 60 minutes, or Never.
- On screen lock and on sleep.
- On demand: Budget ▸ Lock (⌃⌘L), or the lock button in the sidebar footer next to the signed-in
  person's initials.

Locking keeps windows and open sheets in memory. An import that is reading or waiting in review keeps its
state. The confirming user is taken when Confirm import is pressed, not when the import started.

**Switching person**: Budget ▸ Switch User… locks and shows the avatars. One signed-in person per running
app.

**Settings ▸ Sign-in** (new tab; not "Accounts", which would clash with the bank Accounts screen):
- Everyone: your name, change password, Touch ID on this Mac (on/off), lock timeout, regenerate recovery
  key.
- Admins also get the household's app users: add, remove, reset password, make admin.

**Attribution in the UI**
- Import runs (the Imports screen's run list and undo) show "Confirmed by <name>". Runs from before
  sign-in show nothing.
- Learnt import rules (Rules ▸ Import rules) show "Learnt from <name>'s correction". When the latest
  learning came from the other person, the line also says "updated by <name>".

Copy and layout follow the design system (ui-polish spec §1/§6). The setup, lock screen and Settings tab
fit 1100×700 and the smallest window size.

## 7. Recovery **(my call)**

- **Forgotten password, another admin exists:** they reset it from Settings ▸ Sign-in.
- **Forgotten password, Touch ID on this Mac:** Touch ID signs you in, and you change the password
  without the old one. Touch ID counts as the proof.
- **Last resort:** the recovery key. It is 24 characters from an unambiguous alphabet, shown in groups
  of 4, and stored only as a hash (`recoveryKeyHash`, same PBKDF2 format as passwords). Entering it on
  the lock screen ("Forgot password?") lets you set a new password. Regenerating it invalidates the old
  one.
- **Nothing in recovery deletes or re-encrypts data.**

## 8. Security model

What it protects
- Casual use of the app on an unattended or shared Mac.
- Attribution of imports and learnt import rules.

What it doesn't protect
- The database file from anyone with the Mac user's file access. FileVault and the macOS login do that.
- Encrypting the database (SQLCipher) would need a key in the Keychain, migrating the file and the
  evidence library, and complicates CloudKit. It is not worth it for v1.

Passwords and recovery keys
- PBKDF2-HMAC-SHA256 via CommonCrypto, 600 000 rounds, 16-byte random salt, constant-time compare.
- `needsRehash` raises the rounds later. Never logged.
- After 5 wrong attempts, an increasing delay (1 s, 2 s, 4 s… up to 60 s), held in memory. A restart
  resets it, which is acceptable given the threat model.

Touch ID (my call, fits how the app is signed today)
- The installed app is ad-hoc signed, with no team and no entitlements. That rules out the
  data-protection Keychain and biometry-bound Keychain items (they fail with errSecMissingEntitlement).
  The legacy Keychain's ACLs would also break on every `install-app.sh` rebuild.
- So v1 uses `LAContext.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics)` alone. A successful
  Touch ID check by the Mac's enrolled fingerprints unlocks as the chosen enrolled app user.
- Enrolment is a per-Mac list of app user ids in UserDefaults, written only after a password sign-in.
  Alongside it is the `LAContext.evaluatedPolicyDomainState`: when the Mac's fingerprints change, it no
  longer matches, enrolment is dropped and the password is asked once.
- Consequence, stated plainly: anyone whose fingerprint is enrolled on that Mac can unlock as any app user
  enrolled on that Mac. On a personal Mac that is exactly the household. When the app gets a team
  signature (needed anyway for the companions and CloudKit, §10), enrolment moves to a biometry-bound
  data-protection Keychain item per app user.
- The app is not sandboxed. Nothing here needs it to be.

Bypasses
- Only the snapshot build (`SNAPSHOTS`) skips the lock, signed in as a demo user.
- Plain Debug builds and Release builds with `BUDGET_DB_PATH` (manual testing on a copy) require sign-in
  like any other run. A copy of a set-up database carries its app users.
- The CLI tools (ImportRehearsal, ImportDryRun, …) don't sign in. They pass `appUserId: nil`.

## 9. Desktop implementation outline

BudgetCore (`Sources/BudgetCore/Auth/`)
- `AppUser` record and the `createAppUser` migration (§4).
- `DatabaseManager`: `hasPendingMigrations` and the pre-migration backup with retention (§6).
- `PasswordHasher`: hash, verify, needsRehash.
- `RecoveryKey`: generate, format, normalise input.
- `AppUserStore`:
  - `isSetUp`, `appUsers`, `create(personId:displayName:password:isAdmin:)`;
  - `verifyPassword`, `verifyRecoveryKey`, `changePassword`, `resetPassword(of:by:)`;
  - `remove(_:by:)`, `setAdmin`, `regenerateRecoveryKey`, `recordSignIn`;
  - the "at least one admin" invariant.
- Attribution:
  - `ImportApplier.apply(…, confirmedBy: Int64?)` writes `importRun.appUserId`. It goes on `apply`, not
    the initialiser, because one applier serves the app and the user can switch.
  - `ImportRuleStore.learn(…, by: Int64?)` sets `createdByAppUserId` on insert and
    `lastLearntByAppUserId` on insert and update. The `learn` call sites (ImportApplier, ImportEffects) pass
    it through.
  - ImportRehearsal, ImportDryRun and the tests pass `nil`.

App
- `SessionModel` (@MainActor, ObservableObject):
  - states `.notSetUp`, `.locked`, `.signedIn(AppUser)`;
  - idle timer (event monitor);
  - `NSWorkspace` screen-lock and sleep notifications;
  - Touch ID through `LAContext`;
  - `MacEnrolment` in UserDefaults.
- `AppEnvironment` owns the session (also reachable from the Settings scene through the existing
  `AppEnvironment.Current.shared`).
- `LaunchView` routes `.notSetUp` to setup. A root modifier puts the lock overlay over the main windows
  and the Settings window.
- Settings ▸ Sign-in tab; menu items Budget ▸ Lock (⌃⌘L) and Budget ▸ Switch User…; sidebar footer with
  initials and lock button.
- `ImportCenterModel` passes the signed-in app user at Confirm.
- Attribution lines on the Imports run list and on Rules ▸ Import rules.

Tests
- BudgetCore:
  - hashing (known PBKDF2 vectors, rehash) and recovery keys;
  - the store's invariants (unique person, at least one admin, reset by admin only);
  - attribution on import runs and on learnt rules, insert and update;
  - undo of a run that learnt a rule still works;
  - the pre-migration backup (made only when migrations are pending, retention of 5, failure stops launch).
- Migration test: build a pre-auth database with the test-only `migrate(upTo:)` and fill it with
  synthetic rows. After migrating, every existing row is unchanged and the filed-year regressions pass.
- App: snapshot routes (demo DB only) for setup, lock screen (one and two users) and Settings ▸ Sign-in.
  No figure wraps at 1100×700.
- Rehearsal: migrate a copy of the real database (read-only source) and compare tax figures and row
  counts. The real database migrates on the first launch after install, behind the automatic backup.

## 10. Across devices (contract for the companion apps)

- **Identity across devices = Sign in with Apple, linked to the app user.**
  - On iPhone and iPad, the first sign-in uses Sign in with Apple; the app user is found by `appleUserId`.
  - On the Mac, Settings ▸ Sign-in offers "Link your Apple Account" once the app has a team signature.
  - The password stays as the Mac's offline fallback.
- **Data across devices = CloudKit** (decided in the companion/sync spec). The household's data lives in
  the admin's private database, shared with the other person's Apple Account through a CKShare.
- **Privacy, when it comes**: private accounts and tax years would live in a per-person zone that isn't
  shared, so they're unreadable on the other person's devices. That is when "owner" and "private"
  columns and the query filtering are worth building, as part of the sync work.
- **Unlock on mobile**: Face ID or Touch ID with a biometry-bound Keychain item, using the same lock rules
  as §6. The iPhone app locks after 5 minutes in the background.
- **Prerequisite**: a paid Apple Developer team, for Sign in with Apple, CloudKit, Keychain entitlements
  and device distribution. With it, the Mac app gets a team signature too and Touch ID moves to the
  Keychain (§8).

## 11. Rollout

1. Build on a branch (subagent-driven, as usual). Rehearse the migration on a copy.
2. Merge and install. On the next launch the automatic backup is taken, the migration runs, and setup
   appears. The user does the setup themselves.
3. The second person is added when convenient.
4. Apple Account linking waits for the companion and sync work.

## 12. Decisions made without the user **(check these)**

1. **No per-person privacy in v1** (§2, §5): both see and edit everything; privacy arrives with sync,
   where it can be real. Alternative: build owner/private accounts and tax years now, a project roughly
   4× larger (about 90 query sites) that only hides things inside the app.
2. **Touch ID without a developer team** (§8): a Touch ID check on this Mac unlocks any app user enrolled
   on it. It upgrades to per-user Keychain-bound unlock once the app has a team signature. Alternative:
   get the paid Apple Developer team first, which the companions need anyway.
3. Lock after 15 minutes idle, on screen lock and sleep, and on demand; configurable (§6).
4. Recovery: another admin, Touch ID, or a one-time recovery key. Nothing ever deletes data (§7).
5. No database encryption beyond FileVault (§8).
6. The first user is admin, and there is always at least one admin (§5).
7. Attribution only for import runs and learnt import rules (§4).
8. A general pre-migration backup on launch, keeping the newest 5 (§6). It protects every future
   migration, not just this one.
