# Sync, access control and security — design

Status: for the user's review (2026-10-22). Written with the user in a brainstorming session; the user's
answers are marked **(user, date)**, my calls **(my call)**. Companion specs:
`2026-10-22-companion-apps-overview.md` (feature × device matrix, name, distribution, build order),
`2026-10-22-iphone-app-design.md`, `2026-10-22-ipad-app-design.md`.

**Relationship to the authentication spec.** `2026-10-21-authentication-design.md` is the single source
of truth for identity, sign-in, lock and attribution. This spec does not redefine any of it. Where the
companion work needs something different, it is listed in §11 "Changes requested to the authentication
spec", with the reason, for the authentication spec's owner to fold in.

## 1. What the user decided

- **Who uses what (user, 2026-10-21):** one household Mac, used by the admin. The other person uses an
  iPhone and an iPad, each with her own Apple Account. **Revised (user, 2026-10-22):** because the
  mobile apps lack Mac features, the Mac app must support both people with private data; see §3.1. The
  admin also
  uses the iPhone and iPad apps.
- **Statement import is in scope on the iPad (user, 2026-10-21).** So the iPad is a second "heavy writer"
  next to the Mac.
- **iPhone: read plus quick edits (user, 2026-10-21):** categorise a transaction (also one-by-one "quick
  sort"), add a note, attach a receipt photo, accept a rent/recharge split, update a manual balance.
- **Granular access (user, 2026-10-22):** shared vs private per account, with levels down to aggregates
  only (e.g. net worth only); feature-level permissions per person; "the flat and taxes could be
  completely transparent, but individual transactions on my personal account might not".
- **Privacy belongs to the owner (user, 2026-10-22):** the admin cannot see the other person's private
  data. The admin controls permissions on shared data only.
- **Accounts shared at "Category totals" count in the budget and forecast (user, 2026-10-22).**
- **CloudKit, not Supabase (user, 2026-10-21, after comparing):** see §10.

## 2. Goals, non-goals, anti-goals

Goals
1. The Mac, both iPhones and both iPads see the same household data, offline-first, synced through
   CloudKit.
2. Each account and each per-person area has a sharing level set by its owner; private data never reaches
   the other person's devices.
3. Per-person permissions (None / View / Edit) per area, set by the admin.
4. All logic stays in BudgetCore; the apps only present.
5. The existing database migrates without changing a single existing value; the filed returns
   2020/21–2024/25 keep reproducing exactly.

Non-goals
- No server of ours. No web or Android client.
- No live bank feeds. Data still arrives only through imports.
- No database-file encryption beyond the platform's (FileVault, iOS Data Protection).

Anti-goals (a failure even if it "works")
- Data loss or silent overwrite from a sync conflict.
- Private data readable on the other person's devices, in iCloud by Apple, or in logs, widgets or
  notifications on a locked screen.
- A sync change that moves a filed tax figure.
- A raw SQLite file in iCloud Drive (it corrupts).

## 3. Architecture

```
 Mac (hub)                        Admin's iPhone / iPad          Member's iPhone / iPad
 ┌──────────────┐                 ┌──────────────┐               ┌──────────────┐
 │ App (SwiftUI)│                 │ App (SwiftUI)│               │ App (SwiftUI)│
 │ BudgetCore   │                 │ BudgetCore   │               │ BudgetCore   │
 │ GRDB SQLite  │                 │ GRDB SQLite  │               │ GRDB SQLite  │
 │ SyncEngine   │                 │ SyncEngine   │               │ SyncEngine   │
 └──────┬───────┘                 └──────┬───────┘               └──────┬───────┘
        │      admin's private database  │                              │ member's shared database
        ├──── zone "household" ──────────┼──── shared by CKShare ───────┤
        ├──── zone "private-<admin>" ────┘                              │
        │                                  member's private database    │
        │                                  zone "private-<member>" ─────┘
```

- **Every device keeps its own GRDB database.** BudgetCore runs unchanged on each; every screen reads
  local data, so everything works offline.
- **CloudKit is the transport.** One container (`iCloud.com.personal.budget`), `CKSyncEngine` on each
  device, record-level sync.
- **Zones (my call):**
  - `household`: in the admin's private database, shared with the member through a **zone-wide
    CKShare** (read-write). Holds everything at sharing level "Everything", plus the summaries of
    accounts shared at lower levels (§6).
  - `private-<person>`: in each person's own private database, never shared. Holds that person's
    accounts below "Everything" (transactions, documents, statements, their links) and their hidden
    per-person areas.
- **The Mac is the hub (my call).** It is the only device that runs background maintenance:
  - exchange-rate, HMRC-rate and Euribor fetches;
  - the auto-forecast refresh (`AutoForecastGenerator`);
  - the filed-year regression after sync (§5.4).

  Other devices still compute everything they display.

  On a Mac with two macOS users (§3.1), only the admin's runs the hub jobs; the other runs as an ordinary
  device. Settings ▸ Sync shows which one is the hub.

### 3.1 Two people on one Mac (user, 2026-10-22)

The iPad and iPhone don't have everything the Mac has: account set-up, new bank layouts, forecast and tax
are Mac-only. So a person with private accounts needs the full desktop app too. That means **multiple
accounts on the Mac** with real privacy, not just a lock screen.

**How: each person uses their own macOS user on the household Mac, signed in to their own Apple Account
(my call, forced by CloudKit).**
- **On macOS, CloudKit always acts as the iCloud account of the logged-in macOS user.** An app can't
  sign in to a second iCloud account. So an in-app "switch person" on the admin's macOS user could never
  fetch the member's private zone, which lives in *her* iCloud.
- **Separate macOS users give real separation for free:**
  - each has its own `~/Library/Application Support/Budget` database and evidence library;
  - macOS file permissions keep each user's files out of the other's reach;
  - FileVault covers both;
  - Fast User Switching lets both stay logged in.
- **The member's Budget on her macOS user** syncs `household` (through the share, like her iPad) plus her
  own private zone. It has every Mac feature for what she can see and edit: add accounts, map new bank
  layouts, import, and look at the forecast and her own tax years. Hidden tax years therefore become
  possible too (§6.1).
- **The admin's Budget** is unchanged: `household` plus the admin's private zone. It never receives the
  member's private data.
- **Imports from both macOS users are coordinated by the import lease** (§5.2), as with any two devices.
- **Desktop sign-in on each macOS user** is the authentication spec as written. Each app has one person:
  Touch ID or a password, and the same lock rules. The auth spec's in-app "Switch User" stays for a Mac
  where both people share one macOS user. In that case private data is simply not available for the
  person whose macOS user it isn't, and the app says so.

**iPad parity for routine private use (my call).** So that a private account doesn't force a trip to the
Mac, the iPad also gets:
- **adding and editing your own accounts:** name, currency, kind, bank details, sharing level. This is a
  form sheet with the Mac's fields and Save.
- New bank layout mapping stays on the Mac; she can do it on her macOS user.

## 4. Records and identity

### 4.1 Stable IDs without rewriting the schema (my call)
Every table uses auto-increment `Int64` keys (66 migrations, ~2,400 tests). Rewriting them to UUIDs would
touch every model and test. Instead:

```
syncRecord                          -- one row per synced local row (local only, never synced itself)
  tableName      TEXT NOT NULL
  localId        INTEGER NOT NULL
  uuid           TEXT NOT NULL UNIQUE      -- the CKRecord.ID recordName
  zone           TEXT NOT NULL             -- "household" | "private-<person uuid>"
  systemFields   BLOB                      -- CKRecord encodeSystemFields (change tag)
  modifiedBy     TEXT                      -- appUser uuid of the last writer
  modifiedAt     DATETIME
  PRIMARY KEY (tableName, localId)
```

- Local IDs stay local: two devices may both create row 812 in `transaction`; they are different
  records with different UUIDs.
- **Foreign keys** go out as the referenced row's UUID and come back translated to that device's local
  ID. A record whose parent hasn't arrived yet waits in a staging table until it does.
- **Record type = table name.** A per-table `SyncSchema` entry in BudgetCore lists:
  - which columns sync;
  - which are foreign keys (and to which table);
  - which stay local-only.

  Adding a column to a synced table means adding it to the schema entry; a test fails if a column is
  unlisted.

### 4.2 Field encryption
- **Every synced column except the UUID foreign keys goes in `encryptedValues`** (end-to-end, keys in
  iCloud Keychain, also inside the shared zone).
- **Foreign keys are encrypted UUID strings, not `CKRecord.Reference` (my call).** References can't be
  encrypted and would show Apple how records connect. The cost is no server-side cascade delete, which we
  don't use anyway.
- **Documents are encrypted by the app before upload** (§9.1). Each is a `CKAsset` holding ciphertext.
  The keys travel only in encrypted fields. Advanced Data Protection isn't available to UK accounts, so
  we don't rely on it (user, 2026-10-22).

### 4.3 Never synced (device-local)
`syncRecord`, the staging table, backups, source-folder paths and bookmarks, window/UI state, lock and
Touch ID enrolment, notification and widget settings, `localCredential` (§11.6).

## 5. Sync behaviour

### 5.1 Single-record edits
The phone's quick edits and most iPad edits (category, note, balance update, recharge status) merge
**field by field, last writer wins per field**. Two people changing different fields of one transaction
keep both changes. When both change the same field, the later one wins and the earlier is kept in a
per-record conflict log the Mac can show (Settings ▸ Sync ▸ Recent conflicts).

### 5.2 Imports are batches
- **Import lease (my call).** One import may be confirmed at a time per household.
  - The confirming device takes the lease: an `importLease` record in `household`, saved with
    `.ifServerRecordUnchanged` outside the sync engine, so it's a compare-and-set.
  - It holds the lease from Confirm until the batch is fully uploaded. The lease expires after 30 minutes
    without renewal.
  - Reading and review need no lease and work offline. Confirm needs a moment online.
  - Another device seeing the lease shows "Importing on <device>" (iPad mockup 6).
- **Atomic arrival.** A batch can be larger than one CloudKit operation.
  - Every record written by a batch carries its `importRun` UUID.
  - The `importRun` record carries a manifest (record count per type).
  - Receiving devices apply a batch's records only when the whole manifest has arrived, in one local
    transaction. Until then they sit in staging.
- **Follow-on matching** (rent receipts, recharges, transfer links, evidence links) runs on the device
  that confirmed, inside the batch, as today.
- **Undo** is a batch too: it needs the lease, and it uses the existing change log (which syncs with the
  `importRun`).

### 5.3 Deletions
Deletes are tombstones carried by CKSyncEngine. A delete always wins over an edit made while offline,
except for documents: the evidence library never deletes a file another record still links to
(existing rule).

### 5.4 Filed tax years
- The writer's filed-year guard already stops changes at the source (`FiledYearGuard`).
- As a second line, after each sync the Mac re-runs the filed-return regression for 2020/21–2024/25.
  If a figure would move, it shows a banner naming the records and who changed them. It never writes
  anything automatically.

### 5.5 Offline
Every device works offline on its local copy. Changes queue and upload when back online. The UI shows
"Offline · showing data from <time>" (iPhone mockup 9). Confirming an import and accepting the share are
the only things that need a connection.

### 5.6 Sync unavailable (no iCloud, or the developer membership lapsed)
- Treated like being offline, with a banner saying why. Local data is never deleted because sync stopped.
- On return, sync resumes from where it left off.
- Settings ▸ Export my data writes the person's own data (household and their private zone) to an
  encrypted file protected by a password they choose, so private data can't be stranded on devices that
  stop launching (overview §3.1).

### 5.7 First sync
- **Mac:** after the migration (§8) it uploads everything; this takes minutes for tens of thousands of
  records.
- **Member's iPhone:** after accepting the share it downloads records with a progress bar (iPhone
  mockup 9). Documents download when opened (iPhone), are kept after first open (iPad) and are always
  kept (Mac).

## 6. Access control

Two layers, because data that reaches a device can always be read there.

### 6.1 Layer 1: sharing levels (real privacy, set by the owner)

| Level | Lives in | The other person gets |
|---|---|---|
| **Everything** (default) | `household` | All transactions, documents, statements, balances |
| **Category totals** | owner's `private` zone | Per pay month: totals per category, plus balances |
| **Balance only** | owner's `private` zone | Balance over time; counts in net worth |
| **Hidden** | owner's `private` zone | Nothing |

- **Applies to:** each account; each per-person area (that person's tax years, employment and payroll
  documents); and documents not linked to a shared record. A document follows the record it is linked to.
- **Summaries.** For an account below "Everything", the owner's devices publish summary records into
  `household`:

  ```
  accountSummaryMonth  (accountUuid, payMonth, categoryUuid, amount, transactionCount)  -- Category totals
  accountBalancePoint  (accountUuid, date, balance)                                    -- both levels
  ```

  They are rebuilt by the owner's devices whenever that account's transactions, the categories or the pay
  calendar change. They are deterministic, so two owner devices produce the same records.
- **How totals count (user, 2026-10-22):**
  - **Budget grid and dashboard:** actuals = shared transactions + `accountSummaryMonth` amounts.
    Drilling into a cell lists the shared transactions, then one line per private account: "Personal
    current account (<owner>) · 7 transactions · details private".
  - **Forecast:** the auto-forecast reads the same monthly actuals, so totals feed it. On the hub
    (the admin's Mac) the admin's own private accounts count in full, because they're on that Mac. The
    member's are totals.
  - **Net worth:** every level except Hidden counts, through `accountBalancePoint`.
  - **Hidden:** not in the other person's household figures at all. Each person's net worth view says
    "Includes everything you can see".
- **Imports of private accounts happen on the owner's devices** (my call, forced by design). That
  means her iPad, or her own macOS user on the Mac (§3.1). The admin's Mac never receives them.
- **Changing a level:**
  - Lowering it (Everything → Category totals) moves the records from `household` to the owner's private
    zone and deletes them from `household`. The other person's devices delete their copies when that
    sync arrives.
  - Raising it moves them back.
  - The app warns that a copy may already exist on the other person's devices or in their backups from
    before; lowering can't recall data already shared.
- **A tax year at "Hidden"** is prepared by its owner on their own macOS user (§3.1), since tax is
  Mac-only. Today's answer is the user's: taxes transparent.

### 6.2 Layer 2: permissions (set by the admin, on shared data)

```
memberPermission (appUserUuid, area, level)      -- level: none | view | edit; synced in household
```

- **Areas:** Budget & accounts, Property, Forecast, Tax (one entry per person's tax years), Documents,
  Import, Rules & categories, Household settings.
- **Defaults:**
  - admin: Edit everywhere;
  - member: Edit everywhere except Household settings, which is View. This matches today's "both edit
    everything".
- **Enforcement:**
  - `AccessPolicy` in BudgetCore: `can(_ user: AppUser, _ action: .view | .edit, _ area:)`.
  - Every write path takes the actor and checks it. The apps hide or disable what's not allowed.
  - The Mac re-validates incoming changes: a change by someone without Edit on that area is reverted to
    the server's previous value and logged ("Reverted a change by <name>: no permission for Property").
  - **Honest limit:** None/View on shared data is enforced by our app, not by cryptography. Real secrecy
    is Layer 1.
- **Owner rule:** the admin's permissions apply to shared data only. Nobody, the admin included, can set
  a level on someone else's account (user, 2026-10-22).

### 6.3 UI
- **Settings ▸ Sharing (every device):** "My accounts", a list of your accounts with a level picker each;
  "My tax years and income", one level picker.
- **Settings ▸ Household (admin):** the members, and the permissions grid (areas × None/View/Edit) per
  member.
- **Badges:** an account below Everything shows a small lock badge for its owner ("Shared as category
  totals"). For the other person it appears as a summary row.

## 7. BudgetCore on iOS

- `Package.swift`: add `.iOS("26.0")` next to `.macOS("26.0")`.
- **Builds unchanged on iOS 26:** GRDB, PDFKit (`PDFTextExtractor`, `PDFGlyphTextExtractor`,
  `BBVAStatementReader`), Vision (`EvidenceOCR`), Foundation Models (`OnDeviceCategorizer`,
  `DocumentModelReader`), `PayrollFormReader`.
  - The two `#if os(macOS)` spots in BudgetCore are reviewed when porting.
  - CI builds BudgetCore for both platforms and runs its tests on macOS.
- **macOS-only today, in the App layer; iOS equivalents needed:**
  - `NSSharingService` (recharge email) → `MFMailComposeViewController`;
  - `NSWorkspace` (opening files, sleep and lock notifications) → Quick Look and scene phases;
  - the AppKit key-window and sheet plumbing;
  - the snapshot harness (`App/Snapshots`), which gets an iOS twin that renders the same demo database.
- **New in BudgetCore** (`Sources/BudgetCore/Sync/`, `Sources/BudgetCore/Access/`):
  - `SyncSchema`, `SyncRecordStore`, the outgoing/incoming translators, the batch stager, `ImportLease`;
  - `DocumentCrypto` (zone keys, data keys, seal/open, re-wrap; §9.1);
  - `AccessPolicy`, `SharingLevel`, the summary builders, `ActualsSource` (transactions + summaries),
    used by `BudgetGridCalculator`, `DashboardCalculator` and `ForecastCalculator`.
- **Only the CKSyncEngine wrapper lives in the apps**, because it needs entitlements; it calls into
  BudgetCore for everything else.

## 8. Migration of today's database (Mac, once)

Builds on the authentication spec's pre-migration backup (its §6).
1. **Rehearsal on a copy:**
   - run the migration on a copy of the real database (the source is opened read-only);
   - compare every table's row count and contents before and after;
   - run `TaxRegression` and `SelfAssessmentRegression` (2020/21–2024/25 must be unchanged);
   - do a dry-run upload to a **development** CloudKit container.
2. **Real migration, behind the automatic timestamped backup:**
   - append migrations for `syncRecord`, staging, `memberPermission`, summaries and `importLease`;
   - give every existing row a UUID in `syncRecord`, all in zone `household` (everything is
     "Everything" today);
   - no existing value changes.
3. **First upload** to the production container. The Mac shows progress and stays usable.
4. **The admin sets levels** for any account that should be private. Records move to the private zone.
5. **Invite:** Settings ▸ Household ▸ Invite… creates the zone-wide share. The member accepts on her
   iPhone, and the app asks the admin (on next sync) which person she is. That links her app user to her
   `person` row.
6. **Rollback:** sync can be turned off. The local database keeps working, and the backup from step 2
   restores the pre-sync state exactly.

## 9. Security model

**In iCloud**
- Field values are end-to-end encrypted (`encryptedValues`). Apple sees record types, counts, sizes and
  timestamps, never amounts, names, descriptions or identifiers.
- **Documents** are encrypted on the device before upload (§9.1). Apple stores ciphertext whose keys it
  doesn't have, with or without Advanced Data Protection.
- **Advanced Data Protection isn't available in the UK** (user, 2026-10-22). It hasn't been offered to UK
  accounts since 2025, so the design doesn't depend on it. If it ever becomes available, it adds nothing
  this design needs.
- **To verify at build step 0:** that CloudKit encrypted fields are end-to-end for UK accounts without
  ADP. Their keys live in iCloud Keychain, which stays end-to-end for everyone. Check this against Apple's
  current Platform Security guide. If it ever stops being true, the zone keys of §9.1 move to a keychain
  item, and the rest of the design is unchanged.
- Private zones are never shared, so the other person's devices never receive their contents.

### 9.1 Document encryption (my call, because ADP isn't available)
- **Zone keys.** Each zone has a 256-bit **zone key**, held in a `zoneKey` record in that zone, in an
  encrypted field:
  - the household zone's key is readable by both people;
  - a private zone's key only by its owner.
- **Per-document keys.** Each document gets a random **data key**. The file is sealed with AES-GCM
  (CryptoKit) under the data key. The data key, wrapped with the zone key, is stored in an encrypted
  field of the document's record. The `CKAsset` holds only the ciphertext.
- **The evidence hash stays the SHA-256 of the plaintext**, so duplicate detection and canonical naming
  are unchanged. The hash is stored in an encrypted field.
- **Rotation.** Removing a member, or moving a document between zones (a sharing-level change):
  - a new zone key is made, and every document's data key is re-wrapped. That's cheap: no file is
    re-uploaded.
  - Copies the removed person already downloaded can't be recalled. The app says so.
- **Cost:** about 5% more CPU on upload and download, and nothing else visible.
- **Tests:**
  - seal and open;
  - a wrong key fails;
  - re-wrap on rotation;
  - the hash is unchanged;
  - an uploaded asset never contains plaintext (checked against the CloudKit fake).

**On devices**
- **iOS:** the database and documents use file protection `completeUntilFirstUserAuthentication`, so
  background sync and widgets keep working while locked. They are excluded from iCloud device backup,
  since they are already in CloudKit.
- **Mac:** FileVault, plus the authentication spec's lock.
- **The app lock is a privacy screen, not encryption** (as the authentication spec says).

**Leaks**
- Widgets and notifications are redacted on the lock screen by default; figures show only after unlock.
  There is a per-device setting to allow figures.
- The app switcher snapshot is blurred.
- Logs never carry amounts or names.

**Weakest points**
- Each Apple Account (two-factor required). Use a strong, unique password; Apple can reset the account, which is why documents carry our own encryption.
- The member has Edit on shared data by design.

## 10. Alternatives considered

- **Supabase / own server.**
  - Data would be readable by the provider unless we built client-side encryption, which removes
    server-side queries, the main reason to use Postgres.
  - It's a public API whose row-level policies are the only barrier.
  - It isn't offline-first without another sync layer (PowerSync / ElectricSQL).
  - It needs paid tiers for backups, and we'd be maintaining it ourselves.
  - It would only win with non-Apple clients or server-side jobs, and neither is needed.
- **Core Data + NSPersistentCloudKitContainer.** Would mean leaving GRDB and rewriting every query and
  test. It also can't do our batch atomicity, import lease or per-zone privacy cleanly.
- **SQLite file in iCloud Drive.** Rejected by the user and unsafe: corruption and whole-file conflicts.
- **Per-record CKShare instead of a zone-wide share.** Too many shares to manage; a zone-wide share plus
  private zones gives the same privacy more simply.

## 11. Changes requested to the authentication spec

**All seven accepted by the user (2026-10-22).** They are for the authentication spec's owner to fold
in.

1. **Mobile identity from the iCloud account, not Sign in with Apple.**
   - Replace `appUser.appleUserId` with `appUser.cloudKitUserRecordName` (from
     `CKContainer.userRecordID()` on the person's own device; for the member, matched through the share
     participant's `userIdentity`).
   - Reason: CloudKit already authenticates each person, and it's required anyway. Sign in with Apple
     would add a sign-in screen and an entitlement without adding security, and it would need its user ID
     matched to the CloudKit identity anyway.
   - On the Mac, "Link your Apple Account" becomes "Turn on iCloud sync", which records the record name.
2. **No app password on iPhone and iPad.** Unlock with `LAContext.deviceOwnerAuthentication`: Face ID or
   Touch ID, with the device passcode as fallback.
   - Reason: a separate password adds something to forget and protects nothing the device passcode
     doesn't.
   - The mobile lock follows the auth spec's §10: on launch, after 5 minutes in the background, and
     before confirming an import, Undo or a level change.
3. **Per-person privacy is in scope with sync**, as §6 here.
   - The authentication spec's §2 non-goal stands for the desktop-only v1.
   - Its §10 privacy sketch is replaced by §6: per-person private zones, owner-controlled, plus admin-set
     permissions.
4. **Permissions beyond admin.** Keep `isAdmin`; add `memberPermission` (§6.2). The "at least one admin"
   invariant is unchanged.
5. **Each person has their own macOS user (user, 2026-10-22, superseding 2026-10-21's "rarely or
   never on the Mac").**
   - The Mac app normally holds one app user per macOS user (§3.1).
   - Her app user is created when she accepts the share, on her iPhone or her macOS user, whichever comes
     first. The admin confirms which `person` she is.
   - On her macOS user, setup asks her for her own Mac password and Touch ID, as the auth spec's §6
     setup does.
   - "Add <other person>" and "Switch User" stay for a shared macOS user, without private data (§3.1).
6. **Secrets must not sync.** `appUser` syncs (in `household`), but `passwordHash` and
   `recoveryKeyHash` must never leave the Mac.
   - Request: move them into a local-only `localCredential(appUserId, passwordHash, recoveryKeyHash)`
     table now, before anything syncs. Moving them later means a migration that touches secrets.
7. **Attribution generalises with sync.** `syncRecord.modifiedBy` records the last writer of every
   synced record. The auth spec's `importRun.appUserId` and `importRule.*ByAppUserId` stay as they are,
   because they say who *confirmed* or *taught*, not just who wrote last.

## 12. Test plan (sync and access)

BudgetCore unit tests, using synthetic data and an in-memory CloudKit fake:
- **Schema:**
  - every synced table's columns are listed in `SyncSchema`;
  - local-only tables never produce records.
- **IDs:** the same local ID on two devices produces distinct UUIDs; foreign keys translate both ways;
  orphans wait in staging.
- **Conflicts:** field-level merge; same-field last-writer-wins plus a conflict-log entry; delete vs
  offline edit.
- **Batches:**
  - a partial manifest is never applied;
  - a complete one applies in one transaction;
  - the lease's compare-and-set works, expires, and is refused when held by another device.
- **Access:**
  - `AccessPolicy` for every area × level;
  - the Mac reverts an unauthorised change;
  - summaries are deterministic, and the budget grid's totals with summaries equal the totals with full
    data;
  - lowering and raising a level moves records and deletes the shared copies;
  - Hidden accounts are absent from the other person's net worth.
- **Filed years:** an incoming change that would move a 2020/21–2024/25 figure raises the banner and
  writes nothing.
- **Migration:** a pre-sync database (built with `migrate(upTo:)`) migrates with all values unchanged and
  the regressions passing.

Integration, with two simulators and a development container:
- a member edit appears on the Mac;
- an iPad import is blocked while the Mac holds the lease;
- the member's private account never reaches the admin's devices (checked by querying the admin's
  zones).

## 13. Alternative without a developer membership: the Mac as the hub server

Asked by the user (2026-10-22), who may not renew the Apple Developer Program every year.
**Decision (user, 2026-10-22): CloudKit for now.**
- This section stays as the documented fallback.
- The transport is still built swappable (§13.2) at build step 3, so the switch stays cheap if the
  membership lapses later.

### 13.1 What a membership is needed for, and what isn't
- **CloudKit and push notifications** need a paid team. Without one there's no iCloud sync at all: free
  teams can't use iCloud, CloudKit or iCloud Drive containers.
- **Installing a native app on an iPhone or iPad** needs a signature. A free Apple Account signs for
  7 days, for up to 3 apps per device. **SideStore** (or AltStore) re-signs automatically: its helper
  runs on the Mac, re-signs over home Wi-Fi before the 7 days run out, and doesn't need a cable after the
  first pairing.
- **Face ID, Vision, PDFKit, Foundation Models and local notifications** all work with a free
  signature.
- **Widgets and the share extension** need App Groups, which free signing may not provide. Treat them as
  "may not be available" on this path.

### 13.2 Design: sync through the household Mac instead of iCloud
**The transport becomes swappable (my call; build it this way whichever path is chosen).**
- Everything in §4–§6 stays: `syncRecord` UUIDs, zones, batches, the import lease, sharing levels,
  permissions.
- Only the transport changes. A `SyncTransport` protocol in BudgetCore has two implementations:
  `CloudKitTransport` (§3) and `HubTransport` (below).

**The hub.**
- The admin's Mac runs **Budget Hub**: a small login-item helper bundled with the Mac app. It keeps
  running when the app is closed.
- It stores every zone's records and documents in its own folder. It serves them over HTTPS on the home
  network (found with Bonjour) and, away from home, over **Tailscale**. Tailscale's free personal plan
  creates a private network between your devices, with no ports opened on the router.
- **The hub only ever sees ciphertext.** Every record's synced fields and every document are encrypted on
  the device with the zone's key (§9.1, generalised from documents to all fields).
  - The household key is held by both people's devices.
  - Each private zone's key is held only by its owner's devices.
  - So the member's private data sits on the admin's Mac as unreadable blobs, and owner privacy (§6.1)
    holds. The hub stores and forwards, nothing more.

**Pairing replaces iCloud identity.**
- A new device shows a QR code. The admin scans it on the Mac and picks which person the device belongs
  to.
- The devices exchange public keys (Curve25519, CryptoKit). Each device signs its requests with its
  key.
- The zone keys are sent to the new device encrypted to its public key:
  - the household key is sent to any device of either person;
  - a private zone's key goes only to that owner's own devices, approved on one of them.
- `appUser.cloudKitUserRecordName` (§11.1) becomes optional. A `pairedDevice(appUserId, publicKey, name,
  pairedAt)` table links devices to people.

**Behaviour.**
- **While the Mac is reachable:** devices sync in the background when the app is open or iOS gives it
  background time. Without push, nothing wakes the app instantly; the app syncs on open and on
  background refresh.
- **While the Mac is asleep or off:** devices work offline, as in §5.5. The Mac's Energy settings should
  allow "Wake for network access".
- **The import lease, batches and filed-year checks** work as in §5. The hub enforces the lease's
  compare-and-set.
- **Backups:** Time Machine covers the hub folder (ciphertext) as well as the Mac's own database.
- **The member's macOS user** on the same Mac is just another client of the hub, over `localhost`.

### 13.3 Comparison

| | CloudKit (§3) | Mac hub + SideStore |
|---|---|---|
| Membership | Needed every year for the mobile apps | Not needed |
| Installing on phones and iPads | TestFlight, automatic updates, 90-day builds | SideStore: refreshes every 7 days over home Wi-Fi. If it isn't refreshed in time the app won't open until it is; data is safe |
| Sync away from home | Anywhere | Through Tailscale, only while the Mac is awake |
| Who stores the data | Apple (encrypted fields; documents encrypted by us) | Your Mac only (everything encrypted by us) |
| Instant updates (push) | Yes | No: sync on open and in the background |
| Widgets, share extension | Yes | Possibly not (App Groups) |
| Extra to build | CloudKit wrapper | Hub server, pairing, field encryption, transport |
| Risk if the Mac dies | None for sync; restore the Mac from iCloud | Phones and iPads keep their copies; restore the hub from Time Machine |

### 13.4 Recommendation
- **Build the swappable transport whichever path is chosen.** It's cheap at build step 3 and keeps the
  choice open.
- **If you'll keep renewing:** CloudKit. It's simpler to live with: no Mac uptime, push, widgets,
  TestFlight.
- **If you won't, or want the data never to leave home:** the Mac hub with SideStore. While you do have
  a membership, the hub path can still use TestFlight for installs; it just doesn't need it.
- **Not recommended:**
  - a web app served by the Mac (no install problem, but not native, which you asked for);
  - a third-party backend (§10).
