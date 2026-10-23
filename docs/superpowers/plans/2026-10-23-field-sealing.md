# Field sealing and the household key in iCloud Keychain — Implementation Plan

> **For agentic workers:** subagent-driven. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Apple never holds readable field values or the household key: Mango seals every synced record's
fields itself, and the zone (household) key lives in iCloud Keychain instead of a CloudKit record.

**Why (step 4 kick-off finding, 2026-10-23):** in the CloudKit Console (Development, acting as the user's UK
account, no Advanced Data Protection) the `encryptedValues` fields of the demo records were readable: the
values shown were base64 of the plaintext (`{"string":…`, `{"int":…`, `{"date":…`). So `encryptedValues` are
not end-to-end for this account, and the `zoneKey` record — which carries the household key in an encrypted
field — exposes the document keys too. Only demo data was uploaded.

**Spec:** docs/superpowers/specs/2026-10-22-sync-and-access-design.md (§4.2, §9, §9.1 change; see Task 1).

## Global Constraints
- Nothing real is uploaded; the only CloudKit use stays the DEBUG `--sync-demo` with the demo DB.
- Filed SA years 2020/21–2024/25 can never change through sync (FiledYearSyncCheck unchanged and on every apply path).
- No personal data in the repo or tests; tests use FakeCloud and an in-memory key store — never the real Keychain.
- BudgetCore holds the logic (iOS reuse); the App target provides the real Keychain-backed store only.
- CryptoKit AES-GCM-256 (as DocumentCrypto). Swift 6-safe.

## Decisions (controller's, binding)
1. **One sealed blob per record.** All of a record's synced fields (today's `encryptedFields` dictionary,
   including the UUID foreign keys) are encoded deterministically (sorted keys) and sealed with AES-GCM under
   the zone key. AAD binds `recordType`, `recordName`, zone name and the key id, so a blob can't be moved to
   another record or type. The CloudKit record carries exactly two fields, both still in `encryptedValues`
   (defence in depth): `sealed` (the box) and `keyId` (the zone key id that sealed it). No other field.
   Large payloads already sent as assets (R4) are sealed the same way (check they are; if not, seal them).
2. **Wire format version** byte in the blob (`MSB1`-style magic + version), so a later change can be detected.
   Unknown version or wrong key → the record is staged as unreadable (existing path), never applied.
3. **The household key moves to iCloud Keychain.** A `SyncKeyStore` protocol in BudgetCore
   (`key(zone:) -> SymmetricKey?`, `store(_:zone:)`, `allKeys(zone:)` for retired keys by id). The App's
   implementation uses a synchronizable generic-password item (`kSecAttrSynchronizable = true`,
   data-protection keychain, `kSecAttrAccessibleAfterFirstUnlock`, service `ubberninja.mango.sync`, account
   `<container>/<zone>/<keyId>`), never biometry-bound. Tests use an in-memory store.
4. **The `zoneKey` CloudKit record no longer carries key material.** It becomes a non-secret marker:
   it holds only the current key id and its creation time (in `encryptedValues`; neither is secret), so
   devices know which key is current. Keep R14's `documentFile` records unchanged except that their wrapped
   data keys are wrapped by the zone key from the key store.
5. **Bootstrap:** a device with no key for the zone, and a server with no `zoneKey` marker → creates the key,
   stores it in the key store, then saves the marker. A device with no key but a marker on the server (another
   device made it; iCloud Keychain hasn't delivered it yet) → **waits**: pull stages records it can't open as
   unreadable-with-reason "waiting for the household key", push defers, and nothing creates a second key. When
   the key arrives, `retryStaged` opens them.
6. **Local copy:** the device's `syncState` no longer stores the key (remove `zoneKeys.<zone>` key material;
   keep the id/version if useful). Migrate: if a local keyring exists from step 3, move it into the key store
   once and delete it from `syncState` (append-only migration or at engine start).
7. **Sharing (steps 5–6) is out of scope** but don't block it: the key store is per zone, and a later shared
   zone will receive its key by a key exchange with the other person's devices (to design then).
8. The rehearsal tool's plaintext assertion is updated: each outgoing record has exactly `sealed` + `keyId`,
   the blob doesn't contain any source value bytes, and record names stay opaque.

## Task 1: Spec and plan notes
- [ ] Update the sync spec: §4.2 (fields sealed by the app; `encryptedValues` kept only as a second layer),
  §9 (replace "Field values are end-to-end encrypted (`encryptedValues`)" and the "To verify" bullet with the
  finding above, dated 2026-10-23), §9.1 (zone key in iCloud Keychain, marker record, bootstrap/wait), and a
  ruling R15 recording decisions 1–8. Add a dated note to docs/superpowers/plans/2026-10-23-step3-sync-foundation.md.

## Task 2: Implementation (TDD)
Files (expected): `Sources/BudgetCore/Sync/FieldSealing.swift` (new: seal/open of a record's fields),
`Sources/BudgetCore/Sync/SyncKeyStore.swift` (new: protocol + in-memory store), changes in
`SyncDocumentFiles.swift` (`SyncZoneKeys` → marker + key store), `SyncPayload.swift` / `SyncTranslator.swift` /
`SyncEngineCore.swift` (seal on push, open on pull; wait state), `CloudKitRecordMapping.swift` (two fields),
`FakeCloud.swift` if needed, `SyncRehearsal.swift` (assertion), `App/Sync/KeychainSyncKeyStore.swift` (new),
`App/Sync/SyncDemoMode.swift` / `CloudKitTransport.swift` wiring.
Tests must cover at least:
- [ ] seal/open round trip; wrong key, tampered box, moved blob (other recordName/type/zone) all fail and stage unreadable.
- [ ] a pushed wire record has exactly `sealed` and `keyId`; no source value bytes appear in it.
- [ ] two devices on FakeCloud sharing one in-memory key store sync both ways (existing multi-device tests keep passing).
- [ ] device B without the key: records staged "waiting for the household key", no second key created, no marker overwrite; after the key arrives, retry applies them.
- [ ] documents still seal/open with the key from the store; a step 3 local keyring migrates into the store once and is removed from `syncState`.
- [ ] filed-year protection unchanged (existing FiledYearSyncCheck tests pass through the sealed path).

## Verification
Mac suite, scripts/build-core-ios.sh, scripts/test-core-ios.sh, Mango Debug build (CODE_SIGNING_ALLOWED=NO), and
the rehearsal tool on the demo DB. Then the controller re-runs the attended demo sync after resetting the
Development zone.
