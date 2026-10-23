# Build step 3: Sync foundation on the Mac — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** everything sync needs underneath, in BudgetCore and proven against an in-memory CloudKit fake:
- stable record identities;
- the schema of what syncs;
- translation to and from records, with field-level merge and a conflict log;
- import batches with an import lease;
- document encryption;
- the post-sync filed-year check;
- a swappable transport;
- the one-time migration, rehearsed on a copy of the real database.

Nothing is sent to iCloud in this step.

**Architecture:**
- **Pure logic and the fake:** everything is in `Sources/BudgetCore/Sync/`, written against a `SyncTransport` protocol. The in-memory `FakeCloud` transport models zones, change tags, compare-and-set and tombstones, so two simulated devices can sync in tests.
- **The real transport:** the CloudKit transport (`CKSyncEngine` wrapper) lives in the Mac app target, because it needs entitlements. It is built and unit-tested where possible, but it is **not switched on**. The first real upload, to the development container with demo data, is a user-attended step at the start of build step 4.
- **Access control is step 5.** In this step every row goes to zone `household`, except tables marked local-only.

**Tech Stack:** Swift 6, GRDB 6.29 (TransactionObserver for change tracking), CryptoKit (AES-GCM), CloudKit / CKSyncEngine (App target only), XCTest.

**Spec:** `docs/superpowers/specs/2026-10-22-sync-and-access-design.md`: §3 architecture, §4 records and identity, §5 sync behaviour, §8 migration, §9.1 document encryption, §12 test plan (the BudgetCore unit tests, except Access, which is step 5). Also the overview §4, build step 3.

## Global Constraints

- **Nothing leaves the Mac.** There are no iCloud calls in tests or in the app's default behaviour. The CloudKit transport exists but is unreachable from the UI. A debug flag enabling it is allowed only in DEBUG builds and only with `BUDGET_DB_PATH` pointing at a demo database.
- **Migrations append only.** One migration, `createSync`, adds `syncRecord`, `syncStaging`, `syncConflict`, `syncTombstone` and `syncState`. **No existing value changes.** Filed SA returns are unchanged.
- **IDs:** a UUID per synced row, in `syncRecord(tableName, localId, uuid, zone, systemFields, modifiedBy, modifiedAt)`, exactly as sync spec §4.1. The zone is `"household"` for every row in this step.
- **Local-only, never synced** (sync spec §4.3 and §11.6):
  - `syncRecord`, `syncStaging`, `syncConflict`, `syncTombstone`, `syncState`, `localCredential`, `localSetting`;
  - backups and `grdb_migrations`;
  - `sourceFolder` and `sourceFile` (paths and bookmarks);
  - UI and window state;
  - `importRunFile`, if it holds local paths (check; record the ruling).
- **Encryption:** every synced column except foreign-key UUIDs goes in the record's `encryptedFields`. Foreign keys are UUID strings in `encryptedFields` too, never `CKRecord.Reference` (sync spec §4.2).
- **Documents** are sealed with AES-GCM under a random per-document data key. The data key is wrapped with the zone key. The evidence hash stays the SHA-256 of the plaintext (sync spec §9.1).
- **Merge:** field-level, last writer wins per field, and the losing value goes to `syncConflict`. A delete wins over an offline edit, except that a document linked by another record is never deleted (§5.1, §5.3).
- **Batches:**
  - Records written by an import carry their `importRun` UUID.
  - The `importRun` record carries a manifest of counts per record type.
  - Incoming records wait in `syncStaging` until the manifest is complete, then apply in one transaction (§5.2).
- **Import lease:** compare-and-set (`ifServerRecordUnchanged`), with a 30-minute expiry and renewal (§5.2).
- **Filed years:** after applying incoming changes, re-run the 2020/21–2024/25 figures. If any would move, raise a `FiledYearSyncAlert` naming the records and their writer, and write nothing more (§5.4).
- **The usual rules:**
  - BudgetCore has no AppKit or UIKit. `scripts/build-core-ios.sh` and `scripts/test-core-ios.sh` stay green.
  - Synthetic data only in tests.
  - Never write the real database. The rehearsal works on copies.
  - Logs never carry amounts or names (§9).

## Review Focus

1. **A synced table gains a column later and nobody lists it in `SyncSchema`.** Expect a test failure naming the column. Task 1: `testEveryColumnIsClassified`, driven from `PRAGMA table_info`.
2. **Two devices create row 812 in the same table offline, then sync.** Expect two distinct records, each translated to a different local id on the other device, and no overwrite. Task 3: `testSameLocalIdOnTwoDevicesStaysDistinct`.
3. **A child record arrives before its parent** (a transaction before its account, or an evidence link before its document). Expect it to wait in staging and apply when the parent arrives. Task 3: `testOrphanWaitsThenApplies`.
4. **A batch is interrupted halfway, by a network drop or the app quitting.** Expect nothing of the batch applied on the receiver, and a resume that completes it. Task 4: `testPartialManifestNeverApplies` and `testResumeAfterQuitCompletesBatch`.
5. **An incoming edit changes a transaction in a filed year** (category or amount). Expect the alert, no further writes, and the filed figures unchanged. Task 6: `testIncomingChangeToFiledYearRaisesAlertAndWritesNothing`.

---

### Task 1: Sync schema and the createSync migration

**Files:**
- Create: `Sources/BudgetCore/Sync/SyncSchema.swift`, `Sources/BudgetCore/Sync/SyncTables.swift` (the records for the five new tables).
- Modify: `DatabaseManager.registerMigrations`, appending `registerSyncMigration`.
- Test: `Tests/BudgetCoreTests/SyncSchemaTests.swift`

**Interfaces:**
- Produces:
  - `struct SyncSchema`, with `static let tables: [SyncTableSchema]`, `static func table(_ name: String) -> SyncTableSchema?` and `static let localOnlyTables: Set<String>`.
  - `struct SyncTableSchema`, with `name`, `syncedColumns: [String]`, `foreignKeys: [String: String]` (column to referenced table), `localOnlyColumns: [String]` (e.g. `appUser.lastSignInAt`, `account.statementLastCheckedDate` if device-local; record each ruling) and `batchKey: String?`.
  - The records `SyncRecordRow`, `SyncStagingRow`, `SyncConflictRow`, `SyncTombstoneRow` and `SyncStateRow`, with columns per sync spec §4.1. Staging holds the payload JSON and a reason; conflicts hold the table, uuid, field, losing value JSON, both writers and the time.
- Tests:
  - `testEveryColumnIsClassified` covers every table and every column from `sqlite_master` and `PRAGMA table_info`.
  - `testLocalOnlyTablesNeverListed`.
  - `testForeignKeysMatchTheDatabase`, against `PRAGMA foreign_key_list`.
  - `testMigrationOnlyAdds`: build the DB to the previous migration, fill it with synthetic rows, migrate, and expect old rows byte-identical.

### Task 2: Record identity and change tracking

**Files:** create `Sources/BudgetCore/Sync/SyncRecordStore.swift` and `Sources/BudgetCore/Sync/SyncChangeTracker.swift`.

**Interfaces:**
- `SyncRecordStore`:
  - `uuid(for table: String, localId: Int64, db:) throws -> String`, which creates one on first use with zone `"household"`;
  - `localId(table:uuid:db:) -> Int64?`;
  - `backfill(db:) throws -> Int`, which assigns UUIDs to every existing synced row and returns how many.
- `SyncChangeTracker`, a GRDB `TransactionObserver` that records pending changes (table, localId, kind insert/update/delete) for synced tables only. It survives relaunch through `syncState` or a `syncPending` list stored in `syncState`.
- `SyncChangeTracker.pending(db) -> [PendingChange]` and `acknowledge(_:)`.
- Tests:
  - `testBackfillGivesEveryRowOneStableUUID`, which is idempotent;
  - `testLocalOnlyWritesAreNotTracked`;
  - `testDeleteLeavesATombstone`;
  - `testTrackerSurvivesReopen`.

### Task 3: Translators, merge and staging

**Files:** create `Sources/BudgetCore/Sync/SyncPayload.swift`, `Sources/BudgetCore/Sync/SyncTranslator.swift` and `Sources/BudgetCore/Sync/SyncMerge.swift`.

**Interfaces:**
- `struct SyncPayload: Codable, Equatable`, with `recordType` (the table name), `recordName` (the uuid), `zone`, `fields: [String: SyncValue]` (every synced column, foreign keys as UUID strings), `modifiedBy` and `modifiedAt`.
- `enum SyncValue`, with `int`, `double`, `string`, `data`, `date`, `bool` and `null`, exactly round-tripping GRDB `DatabaseValue`.
- `SyncTranslator.outgoing(_ change: PendingChange, db:) throws -> SyncPayload?`.
- `SyncTranslator.incoming(_ payload:, db:, deviceUser:) throws -> IncomingResult`, one of `applied`, `staged(reason)` or `conflicted(fields)`. Foreign keys translate to local ids; a missing parent stages the payload. The merge is per field, comparing each field's `modifiedAt`, with the earlier value written to `syncConflict`.
- Tests:
  - Review Focus 2 and 3;
  - `testFieldLevelMergeKeepsBothDifferentFields`;
  - `testSameFieldLastWriterWinsAndLogsConflict`;
  - `testDeleteBeatsOfflineEdit`;
  - `testLinkedDocumentIsNotDeleted`;
  - `testEveryColumnRoundTrips`, using the demo database: export every row to payloads, import them into an empty database, and expect identical rows apart from local ids.

### Task 4: Import batches and the import lease

**Files:** create `Sources/BudgetCore/Sync/SyncBatch.swift` and `Sources/BudgetCore/Sync/ImportLease.swift`.

**Interfaces:**
- Outgoing records written by a confirmed import get `importRunUuid`.
- `ImportRun`'s payload carries a `manifest: [String: Int]`.
- `SyncBatch.applyIfComplete(runUuid:, db:) throws -> Bool` applies the staged payloads in one transaction only when every count is met.
- `ImportLease.acquire(device:, now:, transport:) async throws -> Lease`; `renew`; `release`. It expires after 30 minutes. It is refused while another device holds an unexpired lease.
- Tests:
  - Review Focus 4;
  - `testLeaseCompareAndSet`;
  - `testLeaseExpires`;
  - `testLeaseRefusedWhileHeld`;
  - `testUndoIsABatchToo`.

### Task 5: SyncTransport, FakeCloud and the engine core

**Files:** create `Sources/BudgetCore/Sync/SyncTransport.swift`, `Sources/BudgetCore/Sync/FakeCloud.swift` (in BudgetCore so the App's debug harness and tests can share it) and `Sources/BudgetCore/Sync/SyncEngineCore.swift`.

**Interfaces:**
- `protocol SyncTransport: Sendable`, with:
  - `func save(_ payloads: [SyncPayload], ifUnchanged: [String: String]) async throws -> [SaveResult]` (change tags);
  - `func changes(since token: Data?, zone: String) async throws -> (payloads: [SyncPayload], deletions: [String], token: Data)`;
  - `func delete(_ recordNames: [String], zone:) async throws`;
  - `func saveAsset(_ ciphertext: Data, for recordName: String) async throws` and `func asset(for recordName: String) async throws -> Data`.
- `actor FakeCloud: SyncTransport`, holding zones, change tags, tokens, assets and a call log for assertions.
- `SyncEngineCore(db:, transport:, device:)`, with `pushPending()`, `pull()` and `syncNow()`. It uses Tasks 2–4. The state token goes in `syncState`.
- Tests: two `SyncEngineCore` instances on two in-memory databases sharing one `FakeCloud`:
  - `testEditOnOneDeviceArrivesOnTheOther`;
  - `testBothOfflineThenSyncConverges`;
  - `testImportBatchArrivesAtomically`;
  - `testUploadedPayloadsContainNoPlaintextAmountsOutsideEncryptedFields`: the fake asserts that its non-encrypted field set is empty.

### Task 6: Post-sync filed-year check

**Files:** create `Sources/BudgetCore/Sync/FiledYearSyncCheck.swift`, reusing `TaxFigures` and `FiledYearGuard`'s snapshot machinery.

**Interfaces:**
- `FiledYearSyncCheck.baseline(db) throws -> FiledYearBaseline`.
- `FiledYearSyncCheck.after(apply: () throws -> Void, db:) throws -> FiledYearSyncAlert?`. It runs the apply in a savepoint, compares, and on any change rolls back and returns the alert.
- `SyncEngineCore.pull` uses it.
- Tests: Review Focus 5, and `testNonFiledChangeAppliesNormally`.

### Task 7: Document encryption

**Files:** create `Sources/BudgetCore/Sync/DocumentCrypto.swift`.

**Interfaces:**
- `DocumentCrypto.newZoneKey() -> SymmetricKey`.
- `seal(_ plaintext: Data, zoneKey:) throws -> (ciphertext: Data, wrappedKey: Data)`.
- `open(_ ciphertext: Data, wrappedKey: Data, zoneKey:) throws -> Data`.
- `rewrap(_ wrappedKey: Data, from old: SymmetricKey, to new: SymmetricKey) throws -> Data`.
- `SyncEngineCore` uploads evidence files through `saveAsset` as ciphertext only. The zone key is held in a `zoneKey` record in the zone, in an encrypted field.
- Tests (§9.1):
  - seal and open;
  - a wrong key fails;
  - rewrap on rotation;
  - the hash is unchanged;
  - the uploaded asset never contains the plaintext (FakeCloud asset inspection).
- **Limits recorded (Task 7 review):**
  - Rotation protects only files sealed after it. A removed member who kept the old zone key can still open the files sealed before the rotation, because rotation re-wraps data keys and doesn't re-seal files. Sync spec §9.1 accepts this ("copies the removed person already downloaded can't be recalled").
  - The zone keyring is kept in the local database (`syncState`) until it moves to the Keychain in step 5 or 6. Until then, local database backups contain it. That is the same exposure as the plaintext evidence library on the same disk.

### Task 8: CloudKit transport (App target, off) and the migration rehearsal

**Files:**
- Create: `App/Sync/CloudKitTransport.swift` (`CKSyncEngine` and `CKDatabase` implementing `SyncTransport`; `encryptedValues` for every field; the container `iCloud.ubberninja.mango`).
- Not wired to any UI. A DEBUG-only launch argument `--sync-demo` enables it only when `BUDGET_DB_PATH` names a file whose `DemoMarker` says it is the demo database.
- The rehearsal is controller-run: copy the real database, migrate (`createSync`) and `backfill`, then compare every existing table (identical) and run the Tax and SA regressions (identical). Generate the full outgoing payload set offline and report record counts per type and the total size. Check no plaintext field is outside `encryptedFields`.

**Steps:**
- [ ] Build the transport; the app builds. A unit test runs the transport's payload↔`CKRecord` mapping without the network: `CKRecord` objects can be created offline.
- [ ] The controller runs the rehearsal and records the numbers in the plan's Result section.
- [ ] **User-attended, step 4 kick-off (not in this step):** one launch with the demo database and `--sync-demo` against the **development** container. Check that a record round-trips and that the CloudKit console shows only encrypted fields.
  - Needs a **team-signed Debug build** (Config/Signing.local.xcconfig with the team, so the iCloud entitlement is present). `CKContainer(identifier:)` traps in a build without the entitlement; `--sync-demo` checks for it up front and refuses with a message instead, as it does for a non-demo `BUDGET_DB_PATH`.

## Result

Rehearsal on a copy of the real DB, 2026-10-23: PASSED — 67/67 existing tables identical; tax figures for every stored year 2015–2024 and 2020/21–2024/25 unchanged; 7,595 records, 229.77 MB (fields 4.33 MB; 625 sealed documents 225.44 MB; largest record 3.9 MB); no value outside encrypted fields; checked apply into an empty DB 3.58 s, 0 staged/held; SelfAssessmentRegression (2020–2025 settings) identical on the original and migrated copies.

Rulings that refine the spec (recorded there too):
- **R11** (§3): the CloudKit transport uses `CKDatabase` operations, not `CKSyncEngine`.
- **R12** (§5.4, §5.7): after a full refetch, local synced rows missing from the server are re-uploaded and logged needs-attention, never deleted.
- **R13** (§5.4): the protected years are 2020/21–2024/25 ∪ every year stored filed or paid; a change moving a (year, person) out of filed/paid is held like a figure move. The check holds only the offending records (and their batch) and applies the rest, instead of "writing nothing more".
- **R14** (§4.2, §9.1): a sealed file travels as its own `documentFile` record (asset = ciphertext only); the wrapped data key and the file record's name stay in the document record's encrypted fields.

## Prerequisite recorded for later steps (ruling R10, 2026-10-23)

Transaction fingerprints embed the importing device's local account id, so the same statement imported on two devices isn't recognised as the same rows. Before any second device can import statements (the member's Mac in step 6, the iPad in step 8), add a **portable fingerprint**:
- a new column computed from the account's UUID;
- existing rows backfilled by re-deriving each row's occurrence number against its stored local fingerprint, with no existing value changed;
- used by sync identity and by every importer's duplicate check.

## Follow-ups recorded by the final review (2026-10-23)
- **Tools opening the real database (step 4+, before sync is on):** the one-off tools in `Sources/` open the database with their own `DatabaseQueue` and skip `PRAGMA recursive_triggers = ON`, which `DatabaseManager` sets. Their writes are still tracked (ordinary AFTER triggers fire), but a REPLACE-style delete there would leave no tombstone. None does a REPLACE today; when sync turns on, give the tools' shared open path the same pragma (or open through `DatabaseManager`).
- **Cancellation (step 4 scheduler):** `SyncEngineCore.serialized` runs each entry point in its own unstructured `Task`, so cancelling the caller doesn't cancel the sync or reach the transport. The CloudKit transport now checks cancellation before adding an operation and cancels a running one; the scheduler should keep the entry point's task (or pass cancellation through) if a sync must be stoppable.

- **Unreadable zone key (step 4–6):** after an unreadable `zoneKey` record is staged, the local keyring keeps its `systemFields`, so the push path doesn't recheck the server. If that version was a key rotation by a newer build, this device keeps sealing new documents under the retired key until a device holding the new key rewraps them. No data loss and no filed-year impact. Fix: clear the keyring's `systemFields` when staging an unreadable `zoneKey`, so push rechecks the server and defers documents.

## Step-6 follow-up recorded by Task 6 (2026-10-23)
- Records held by the post-sync filed-year check (`FiledYearSyncCheck.held`, reasons "needs attention: … filed tax year") stay in `syncStaging` and are never retried. A held import batch stays held whole (`SyncBatch` skips a run with a held record), and its local edits wait (push holds back staged UUIDs). Step 6 needs a "release held" action (after a person confirms) that re-feeds the held payloads — the rows keep the full payloads and run UUIDs — so a held batch can come back; children waiting on a held parent come back with it.
