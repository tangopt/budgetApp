# Step 15: new household key when someone is removed — design

Status: 2026-10-28, written unattended; calls marked *(my call)*. Budget ~2%. Builds on sync spec
2026-10-22-sync-and-access-design.md §9 "Rotation" and the 2026-10-23 security review notes.

## Behaviour
- When the owner removes a member (Settings ▸ Household ▸ Remove), Mango makes a **new key for every zone she could
  read** (household zone and any area zone shared with her), re-wraps every document's data key under it (no file is
  re-uploaded), and **re-seals the records** sealed under the retired key in a background sweep (the "re-seal sweep"
  the security review deferred) so the removed person's old key opens nothing new or changed.
- Removal also revokes her CloudKit share participation first, then rotates; if offline, removal is refused with
  "Connect to the internet to remove someone" *(my call: never a half-removed state)*.
- The owner's other devices pick up the new key through iCloud Keychain as today ("waiting for the household key"
  until it arrives — never shown as an error).
- The app says plainly: "Copies Patricia already downloaded can't be recalled" — without the personal name except
  where the household/member list already shows it *(member names are allowed in Settings ▸ Household)*.
- Progress: "Securing the household… 1,240 of 9,934" in Settings ▸ Household; resumable after quit/crash.

- *Built (2026-10-28):* only the household zone is rotated: private zones are never shared (sync spec §3.1), so it is
  the only zone she could read. A future shared area zone must be added to `SyncKeyRotation`/`HouseholdRemoval`.
- *Security review fixes:* the sweep pulls first and re-seals as is only versions the admin's own user wrote; anyone
  else's goes up as the Mac holds it (re-validated, clocks clamped); a version the Mac hasn't applied is left to the pull
  path. Every push reads the server's household marker before sealing; a record pulled under a revoked key reopens the
  sweep. Taking her off the share is owed work, retried before anything is rotated ("Removing … — finishes when online").

## Constraints
All crypto/sync in MangoSync/BudgetCore; tests with the CloudKit fake: rotate → old key cannot open any record or
document written after rotation; re-seal sweep converts every old-key record; resume after interruption; offline
refusal; a re-invited member gets the new key only. No plaintext ever leaves the device; filed SA years unchanged;
no CloudKit schema change unless additive (say so).
