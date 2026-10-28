# Step 15: new household key when a member is removed — plan

Spec: `docs/superpowers/specs/2026-10-28-step15-key-rotation-design.md`; sync spec §9.1 "Rotation", §9 "Rotation re-wraps,
it doesn't re-seal", R15.5 (key wait).

## What exists
- `SyncEngineCore.rotateZoneKey()` (SyncDocumentFiles.swift): new key in the key store, marker saved over the last-seen
  version, every local data key re-wrapped (`rewrapStragglers`) and the document records pushed. No file is re-uploaded.
  Records sealed under the retired key stay so until their next edit (the gap this step closes).
- `HouseholdInvite.remove`: takes her off the household share, records who was removed.
- `SyncKeyExchange.Granter.grant`: seals **every** household key held to her device.
- Only the household zone is ever shared (private zones never are, sync spec §3.1), so "every zone she could read" is the
  household zone.

## Global constraints
- All crypto/sync in BudgetCore; the App only calls it. CloudKit fake in tests. No plaintext leaves the device.
- No CloudKit schema change: the sweep re-saves existing record types with the same two fields (`sealed`, `keyId`);
  rotation state lives in local `syncState` only.
- Filed SA years: the sweep re-seals records as they are on the server (same inner fields), never through the apply path,
  so nothing local changes and the filed-year check isn't involved.

## Task 1 — the re-seal sweep (BudgetCore)
`Sync/SyncKeyRotation.swift`:
- `SyncKeyRotation` (state in `syncState`): `revoked` key ids (kept for good, so a later grant never hands them out),
  `pending` (a removal's rotation or sweep not finished), `done`/`total` progress.
- `SyncEngineCore.resealSweep(progress:)`: reads the household from the start without document contents, finds every
  record sealed under a key other than the current one (data records, companions, an expired lease; never the marker,
  `documentFile`, or the key exchange's), re-seals it under the current key (a document record's wrapped data key is
  re-wrapped too) and saves it over the version read. A record changed meanwhile is read again on the next pass. Stamps
  this device holds for that version are updated, so its own re-seal doesn't come back as a change. Progress persisted per
  operation; a passing error leaves the state for a resume.
- Tests: every old-key record converted and the old key opens none of them; resumable after a dropped connection
  (counts continue); documents re-wrapped, not re-uploaded; no plaintext in any uploaded asset; new writes under the new key.

## Task 2 — removal rotates (BudgetCore)
- `HouseholdRemoval.remove(transport:engine:member:db:progress:)`: probes iCloud (a passing error refuses: `.offline`, nothing
  changed), records the revocation (every key held now), takes her off the share (`HouseholdInvite.remove`), then
  `engine.finishKeyRevocation` (rotate unless the current key is already a new one, then the sweep). `resumeIfPending` for
  after a quit/crash (called after each sync on the admin's Mac).
- `Granter.grant` leaves revoked keys out (none left: `noKeys`, so nothing goes while the rotation is pending).
- Tests: offline refusal; end-to-end remove → rotate → sweep; resume after interruption; re-invited member's grant holds only
  the new key.

## Task 3 — Settings ▸ Household (App)
- `HouseholdController.remove` goes through `HouseholdRemoval`; the progress line "Securing the household… 1,240 of 9,934";
  "Connect to the internet to remove someone"; the remove dialog says copies already downloaded can't be recalled.
  `RealSync` hands the controller its engine and resumes a pending sweep after each sync.
- Mac build and MangoPhone build.
