# Step 19: import bank statements on the iPad (shared import lease) — Implementation Plan

**Goal:** On the iPad, a checked bank statement (BBVA or UK, from the Downloads tray) can be **imported on the iPad**
under the household import lease, instead of only being sent to the Mac's waiting list. A member without import
access for that account gets "Send to the Mac" (today's behaviour); the owner can hand a statement to the Mac
("Finish on the Mac").

**Spec:** `docs/superpowers/specs/2026-10-28-step19-ipad-statement-import-design.md`. Background: sync spec §5.2.

## Architecture

- **What exists:** `ImportLease` (compare-and-set lease, 30 min, renewed by the push every 10 min while a batch
  uploads, released once its close is uploaded), `SyncImportGate` (BudgetCore refuses Confirm/Undo without a held
  lease when sync is on), `SyncEngineCore.acquireImportLease` (Mac only), `ImportApplier` (the import engine:
  run, change capture, sync batch, follow-ons, waiting-document links, filed-year backstop), `CheckAndLink` (the
  iPad's review of a tray file through `ImportPipeline`; statements go to the waiting list), `DeviceWriter`
  (actor + area + `writeCheckingFiledYears`).
- **What is new:**
  1. The engine lets an iPad that pushes the household (`.device` mode) take and release the lease (it never
     makes a key for it). `ImportLeasing` is the lease seam (`SyncEngineCore` conforms).
  2. `ImportApplier.apply(_:entryPoint:writer:)`: the same engine, its one transaction run through
     `DeviceWriter.writeWithActor(.import, origin: .import, scope: .everyYear)`. `PadStatementImport` decides the
     route (import here / held by another device / offline / send to the Mac), takes the lease, applies, and
     releases the lease when the apply fails. `CheckAndLink.importStatement` feeds it the checked plan.
  3. UI: the check-and-link sheet's statement gets **Import** (with the held/offline banner), **Finish on the Mac**
     (owner) or **Send to the Mac** (no import access). App wiring in `PhoneBrowser`/`PhoneSyncController`.

## Global constraints

- No second import engine; logic in BudgetCore; writes via `DeviceWriter` (actor, area, filed-year check).
- Filed SA years 2020/21–2024/25 never change (`writeCheckingFiledYears` + the applier's own backstop).
- Lease duration stays the household's 30 minutes (sync spec §5.2; the Mac and iPad share it). *(plan call: the
  design's "10 min" is read as the renewal cadence, which the push already uses.)*
- No CloudKit schema change: `importLease`, `importRun` and the batch records exist already.
- Tests on `TestDatabase` / `TwoPersonHousehold` only. `swift test --scratch-path /private/tmp/claude-501/step19-spm --parallel`,
  the Mac `xcodebuild` and the MangoPhone build before each commit.

## Tasks

### Task 1: the iPad may take the import lease
- `SyncWriteMode.takesLease` (full, or a device pushing the household). `acquireImportLease`/`releaseImportLease`
  allowed then; the key is never made on a device.
- `ImportLeasing` protocol (`importLeaseHolder`, `acquireImportLease`, `releaseImportLease`, `leaseDevice`,
  `pushZones`); `SyncEngineCore` conforms.
- Tests: the admin's iPad takes the lease; contention (Mac holds → iPad refused "Importing on Mac", and the
  reverse); a member's iPad takes it on the shared household; read-only devices still refused.

### Task 2: the apply path and the route
- `ImportApplier.apply(_:entryPoint:writer:now:)`; `PadStatementImport` (`route`, `importStatement`, `undo`,
  `canImport`), `PadStatementImportCopy`; `SyncZoneRouter.runZone(account:)`;
  `CheckAndLink.importStatement`.
- Tests: import writes an importRun + sync batch with the iPad's entry point and actor; duplicates skipped;
  contention → refusal, nothing written; expiry → importable; member without import access → `.sendToMac`; offline
  → message; filed year refused and nothing written; lease released after a failed apply; Undo from the iPad.

### Task 3: the sheet and the app
- `CheckAndLinkModel`: route, `importStatement()`, `sendToMac()`; sheet buttons and banners; snapshot routes
  (import ready, held by the Mac, offline, member send-to-Mac); `PhoneBrowser` wiring with the sync engine.
- Snapshot PNGs looked at; 0 wrap violations.
