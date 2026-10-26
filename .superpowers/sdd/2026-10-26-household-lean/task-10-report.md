# Task 10 report: the member's phone joins the household

## What was built
- `BudgetCore/Access/HouseholdJoin.swift`: `HouseholdJoinState` (accepting, waitingForKey, showCode, pulling, refused, expired, stillJoining(reason), cannotJoin, removed), `afterPull(status:joined:)`, `plan(owner:keyHeld:)` (`.ownZones` for the admin's phone), plus the copy (`HouseholdCopy`).
- `MangoSync/CloudKitShareAcceptance.swift`: validates the invitation (this container, the `household` zone, owner = the zone's owner name, owner identity as fallback) and accepts it (`CKContainer.accept`, the async form of `CKAcceptSharesOperation`).
- `Phone/Lock/PhoneSceneDelegate.swift`: `windowScene(_:userDidAcceptCloudKitShareWith:)` and cold-start `connectionOptions.cloudKitShareMetadata`, both into `Phone/Sync/PhoneShareInbox.swift` (holds it until the controller exists).
- `PhoneSyncController`: accepts only on a device with no household of its own (refuses: another household, a different owner, own household rows, sync off); records the membership only after iCloud accepted; then the plan: no key -> key exchange (`Requester.start`/`poll` every 3 s while the scene is active, resumed on foreground, new request on relaunch), key -> read-only engine over `SyncZoneSplitTransport`. `received` -> engine starts -> the join screen follows the first pull; core records `joined` after the first household pull. Removal shows the `removed` screen (replaces the old alert). Retry and Start again are wired.
- `project.yml`: `CKSharingSupported: true` (Phone/Info.plist regenerated).
- `MangoUI/Sync/HouseholdJoinView.swift` and `JoinRoutes`.

## Admin's phone
No membership gives `plan == .ownZones`: transport `CloudKitTransport()`, `householdIsShared: false`, `memberOwner == nil`, so `updateJoinState` returns at once and no join screen shows. Tested in `testTheAdminsPhoneHasNoMembershipAndKeepsItsOwnZones`; the code path (`owner == nil`) is unchanged from before.

## Snapshots
Routes join_accept, join_code, join_waiting_key, join_received, join_refused, join_expired, join_still_joining, join_cannot, join_removed. 0 violations, 0 coverage problems.
PNGs: /private/tmp/claude-501/-Users-pablo-dimenza-Documents-Code-budget/5fac4f61-c0c9-436b-881b-aebe445aa967/scratchpad/snaps10/join_*-{light,dark}-{large,xxxLarge,accessibility3}.png (e.g. join_code-light-large.png, join_still_joining-dark-accessibility3.png). I looked at join_code and join_still_joining.

## Concerns
1. Share acceptance, the shared-DB pulls and the public board are compile-checked only; they need the side-by-side run.
2. A failed accept keeps the invitation in memory only: after a relaunch she taps the link again. Membership is not recorded until iCloud accepts.
3. Zone owner name is taken from `share.recordID.zoneID.ownerName` (what the shared database addresses), with `ownerIdentity` as fallback; the Mac's key-request name uses the admin's user record name, which should be equal. Confirm in the real run.
4. While joining, Settings is not reachable (the join screen replaces the tabs); the lock still applies.
5. "Still joining" for a member with the key shows after a pull that ends idle without a household; no timer.
