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

### Task 8: CloudKit transport (App target, off) and the migration rehearsal

**Files:**
- Create: `App/Sync/CloudKitTransport.swift` (`CKSyncEngine` and `CKDatabase` implementing `SyncTransport`; `encryptedValues` for every field; the container `iCloud.ubberninja.mango`).
- Not wired to any UI. A DEBUG-only launch argument `--sync-demo` enables it only when `BUDGET_DB_PATH` names a file whose `DemoMarker` says it is the demo database.
- The rehearsal is controller-run: copy the real database, migrate (`createSync`) and `backfill`, then compare every existing table (identical) and run the Tax and SA regressions (identical). Generate the full outgoing payload set offline and report record counts per type and the total size. Check no plaintext field is outside `encryptedFields`.

**Steps:**
- [ ] Build the transport; the app builds. A unit test runs the transport's payload↔`CKRecord` mapping without the network: `CKRecord` objects can be created offline.
- [ ] The controller runs the rehearsal and records the numbers in the plan's Result section.
- [ ] **User-attended, step 4 kick-off (not in this step):** one launch with the demo database and `--sync-demo` against the **development** container. Check that a record round-trips and that the CloudKit console shows only encrypted fields.

## Result

(filled in after the rehearsal)

## Prerequisite recorded for later steps (ruling R10, 2026-10-23)

Transaction fingerprints embed the importing device's local account id, so the same statement imported on two devices isn't recognised as the same rows. Before any second device can import statements (the member's Mac in step 6, the iPad in step 8), add a **portable fingerprint**:
- a new column computed from the account's UUID;
- existing rows backfilled by re-deriving each row's occurrence number against its stored local fingerprint, with no existing value changed;
- used by sync identity and by every importer's duplicate check.
