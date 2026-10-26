# Step 7a (lean): the safety list and the invite — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (chosen) to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** close the step 6 safety list (server-attributed writers, attributed deletes, a full re-placement sweep, the unlinked-document rule, admin-only re-validation, account-change and removal drops, F-2, F-5), then let the admin invite the member from Mac Settings ▸ Household through a zone-wide CKShare that her iPad (iPhone app) accepts and pulls read-only.

**Architecture:**
- **The server says who wrote.** `SyncServerRecord.lastModifiedBy` (CloudKit `lastModifiedUserRecordID.recordName`) reaches the apply as `SyncPayload.serverWriter`, which only the receiving engine sets. The admin's Mac judges every field it takes from another iCloud user as that user's, whatever the payload's clocks claim.
- **Household deletes become deletion markers.** A marker is a save, so the server attributes it. A bare hard delete in `household` that this Mac didn't send is undone.
- **Placement is re-checked when any of its inputs change.** A content fingerprint of the router's inputs runs a full sweep that queues every misplaced record. The same read is one of the invite's gates, and the invite also audits the household zone on the server.
- **Sharing is a second transport protocol** (`SyncShareTransport`). `FakeCloud` models it with per-user sessions, a zone share, participants, accept and remove, and stamps `lastModifiedBy`. A member device uses `SyncZoneSplitTransport`: `household` goes to the admin's zone through her shared database, everything else to her own private database.
- **The household key reaches her device by a short key exchange**, confirmed by a 6-digit code that the admin and the member compare side by side (sync spec R15.7, Task 8).
  - Her request (a commitment, then her key) goes on the container's public database, under a name hashed from the share and her iCloud user.
  - The Mac answers in `household` with an ephemeral key, which goes into the code's transcript (commit-then-reveal).
  - The grant is sealed from that Mac key to hers, so only the Mac that answered can make one that opens.

**Tech Stack:** Swift 6, GRDB 6.29, SwiftUI (macOS 26, iOS 26), CloudKit (`CKDatabase` operations, `CKShare(recordZoneID:)`, `CKAcceptSharesOperation`), CryptoKit (Curve25519, HKDF, AES-GCM), XCTest, XcodeGen.

**Spec:** `docs/superpowers/specs/2026-10-26-household-lean-design.md` (binding). Background: `2026-10-25-sharing-levels-design.md`, `2026-10-22-sync-and-access-design.md` §3, §4.2 (R15), §6.2, §11, §12.

## Global Constraints

- **Logic in BudgetCore.** Gates, the sweep, attribution, drops, the key exchange and all copy live in `Sources/BudgetCore`. `App/`, `Phone/` and `MangoSync` only call them. `scripts/build-core-ios.sh` stays green.
- **Sealed records:** every data record and marker carries exactly `sealed` and `keyId` (R15). New reserved types (`keyRequest`, `keyGrant`) follow the `zoneKey` precedent: no data, no key material in the clear.
- **Nothing below Everything ever in `household`.** Every new sync test runs over `ZoneAuditingTransport` and the member stand-in (`TwoPersonHousehold`) on the FakeCloud share.
- **Filed SA returns 2020/21–2024/25 never change.** The existing filed-year checks apply to every apply, undo and drop.
- **No personal data in the repo.** Tests and the demo use synthetic names ("Person A", "Person B"). The member's real name is typed into the app.
- **Real DB:** never written by a subagent. Never without a backup and the user's go. Subagents never touch the real DB, Keychain, iCloud, the installed app or the user's screen.
- **No `SyncSchema.version` bump**: no synced column changes. The new payload fields are wire-only.
- **Member is read-only in 7a.** Her engine runs `readOnly: true`. Only the key exchange writes, through the transport and never through the engine.
- **Commands** (`S7=/private/tmp/claude-501/-Users-pablo-dimenza-Documents-Code-budget/5fac4f61-c0c9-436b-881b-aebe445aa967/scratchpad/build-7a`):
  - targeted (fix rounds): `swift test --scratch-path $S7 --filter '<Tests>'`
  - full suite, once at the end of each task: `swift test --scratch-path $S7 --parallel`
  - UI: `scripts/render-snapshots.sh $S7/snaps --quick --routes <r> --size 1100x700`; phone: `scripts/render-phone-snapshots.sh` (quick routes)
  - App-target tasks before review: `xcodegen generate && xcodebuild -project Mango.xcodeproj -scheme Mango -configuration Debug -derivedDataPath $S7/dd CODE_SIGNING_ALLOWED=NO build`; phone: `scripts/build-phone.sh`
  - at most 2 building agents at once.
- **Model tags:** **[opus]** = touches privacy or sync: most capable model, plus a spec+code review before the next task. **[sonnet]** = UI or small: lighter model, a quick review.
- **Controller-only** (end of plan): the real invite with the user and the member present, TestFlight, and any real-DB write.

## Review Focus

1. **The member's device pulls before the Mac has bound her iCloud user to her appUser.** Expect household only: no viewer and no private-zone fetch. Once the bind arrives, her viewer follows. Task 7: `testMemberViewerFollowsOnceHerRecordNameIsBound`.
2. **A document the member already holds in `household` becomes private** (unlinked and not property, or later linked only to a private record). Expect the sweep to move it, and her device to drop the row with no staging orphan. Task 4: `testSweepMovesUnlinkedNonPropertyDocumentOutAndMemberDropsIt`.
3. **Two admin Macs both delete in `household`.** Expect neither to undo the other: both deletes are markers attributed to the admin. Task 3: `testSecondAdminMacDeleteIsNotUndone`.
4. **The phone relaunches with the same iCloud user, or after an account-status blip** (`couldNotDetermine`). Expect nothing dropped. Only a different, known record name drops data. Task 5: `testSameICloudUserAfterRelaunchKeepsData`, `testUndeterminedAccountDropsNothing`.
5. **"Invite…" pressed twice, or after the app quit mid-invite.** Expect the existing share to be reused, never a second share. Task 7: `testInviteTwiceReusesTheShare`.

---

### Task 1 [opus]: FakeCloud zone share, server writer, split transport

**Files:**
- Modify: `Sources/BudgetCore/Sync/SyncTransport.swift`, `Sources/BudgetCore/Sync/FakeCloud.swift`, `Sources/BudgetCore/Sync/ZoneAuditingTransport.swift` (pass `lastModifiedBy` through), `Tests/TestSupport/TwoPersonHousehold.swift`, `Tests/TestSupport/LossyTransport.swift`, `Sources/MangoSync/CloudKitTransport.swift`
- Create: `Sources/BudgetCore/Sync/SyncShareTransport.swift`, `Sources/BudgetCore/Sync/SyncZoneSplitTransport.swift`, `Sources/MangoSync/CloudKitTransport+Sharing.swift`
- Test: `Tests/BudgetCoreTests/FakeCloudShareTests.swift`

**Interfaces — Produces:**
- `SyncServerRecord.lastModifiedBy: String?`: the iCloud user record name the server says wrote this version. Init gets a defaulted parameter `lastModifiedBy: String? = nil`.
- `public struct SyncShareParticipant: Equatable, Sendable { userRecordName: String; status: Status /* .invited, .accepted */; canWrite: Bool }`
- `public struct SyncZoneShare: Equatable, Sendable { zone: String; url: URL?; ownerRecordName: String; participants: [SyncShareParticipant] }`
- `public protocol SyncShareTransport: Sendable`:
  - `currentUserRecordName() async throws -> String`
  - `zoneShare(_ zone: String) async throws -> SyncZoneShare?`
  - `makeZoneShare(_ zone: String, title: String) async throws -> SyncZoneShare` (idempotent: returns the existing share)
  - `removeParticipant(userRecordName: String, zone: String) async throws`
- `FakeCloud`:
  - `init(..., ownerRecordName: String = "fake-owner")`. The base object acts as that user, so existing tests are unchanged.
  - `session(as userRecordName: String) -> FakeCloudSession`, where `FakeCloudSession: SyncTransport, SyncShareTransport`.
  - `invite(_ userRecordName: String, zone: String, canWrite: Bool = true)` stands in for the system share sheet.
  - `accept(zone: String, as userRecordName: String)`.
- FakeCloud rules:
  - A zone is owned by the user who created it.
  - Another user reaches it only as an accepted participant: reads, plus writes when `canWrite`. Anyone else, or a removed participant, gets `SyncTransportError.zoneNotFound(zone)`.
  - Every saved version and deletion stamps the acting user into `lastModifiedBy`.
- `public struct SyncZoneSplitTransport: SyncTransport { init(household: any SyncTransport, others: any SyncTransport) }` routes by zone name. `operationLimits` is the smaller of the two.
- `TwoPersonHousehold`:
  - `adminICloudUser = "fake-owner"`, `memberICloudUser = "fake-member"`.
  - The member's audit wraps `cloud.session(as: memberICloudUser)`.
  - `make` invites and accepts her on `household` and writes both record names on the appUsers.
- `CloudKitTransport`:
  - `init(database:zoneOwnerName: String? = nil, …)`: zone IDs use `ownerName` when it is given (the shared database).
  - `lastModifiedBy` comes from `record.lastModifiedUserRecordID?.recordName`, with `CKCurrentUserDefaultName` mapped to `container.userRecordID()` (fetched once).
  - `+Sharing` implements `SyncShareTransport`: `CKShare(recordZoneID:)`, `publicPermission = .none`, fetch the share by `CKRecordNameZoneWideShare`, remove a participant by matching `userIdentity.userRecordID.recordName`.

- [ ] Write failing tests:
  - `testSavesCarryTheActingUser` (session B saves; `changes` shows `lastModifiedBy == "fake-member"`)
  - `testNonParticipantGetsZoneNotFound`
  - `testInvitedButNotAcceptedCannotRead`
  - `testAcceptedParticipantReadsAndWrites`
  - `testReadOnlyParticipantSaveRefused`
  - `testRemovedParticipantGetsZoneNotFound`
  - `testMakeZoneShareIsIdempotent`
  - `testSplitTransportRoutesHouseholdToSharedSide`
- [ ] Run `--filter FakeCloudShareTests` → FAIL. Implement. Re-run → PASS.
- [ ] Full suite green: the step 6 suites (`AccessRevalidationTests`, `SyncZonesEngineTests` …) pass with the rewired `TwoPersonHousehold`. App target builds.
- [ ] Commit `"Sync: FakeCloud zone share, server-attributed writer, split transport"`.

### Task 2 [opus]: Writer identity from the server; re-validate only on the admin's Mac

**Files:**
- Modify: `Sources/BudgetCore/Sync/SyncPayload.swift`, `Sources/BudgetCore/Sync/SyncTransport.swift` (`SyncWireRecord.init(_:)` clears it), `Sources/BudgetCore/Sync/SyncEngineCore.swift` (set on every received and refused-save record), `Sources/BudgetCore/Access/AccessRevalidation.swift`, `Sources/BudgetCore/Sync/SyncMerge.swift` (clock clamp), `App/Sync/RealSync.swift`
- Test: `Tests/BudgetCoreTests/ServerWriterTests.swift`

**Interfaces:**
- Consumes: Task 1 (`lastModifiedBy`, sessions).
- Produces:
  - `SyncPayload.serverWriter: String?`: an iCloud record name. It is never on the wire: the engine overwrites it from `SyncServerRecord.lastModifiedBy` on every receive (staging keeps it).
  - `AccessRevalidation.attributedWriter(_ payload: SyncPayload, selfUser: String?, db: Database) throws -> Attribution`, where `enum Attribution { case selfUser, appUser(String), unknown }`. The cases:
    - nil `serverWriter`: judged by the clocks, as in step 6.
    - the admin's record name: `.selfUser`.
    - another appUser's `cloudKitUserRecordName`: `.appUser(uuid)`.
    - else: `.unknown` (every taken field reverted, writer named `unknownWriterName`).
  - `AccessRevalidation.shouldRevalidate(signedInAppUserId: Int64?, iCloudUserRecordName: String?, db: Database) throws -> Bool`: true only when that appUser `isAdmin` and its `cloudKitUserRecordName == iCloudUserRecordName`.
- Rules:
  - With `.appUser(u)`, every taken field is judged as `u`. Clock `by`, writerless clocks and dates before `ownershipConfirmedAt` are ignored for attribution.
  - The applied clocks are stored with `by = u`.
  - A clock from a non-self writer later than the server's `modifiedAt` is clamped to it before the merge.
  - An `.import` origin counts only when the run's `importRun` insert clock `by` equals the attributed writer.
  - `RealSync.startEngine` passes `revalidatesAccess: shouldRevalidate(...)`.

- [ ] Failing tests (member pushes through her session):
  - `testMemberClaimingAdminWriterIsJudgedAsMember`
  - `testWriterlessBackdatedClockFromMemberIsJudged`
  - `testFutureDatedMemberClockIsClampedToServerTime`
  - `testReusedAdminImportRunTagCountsAsHandEdit`
  - `testUnknownICloudWriterIsReverted`
  - `testServerWriterOnTheWireIsOverwritten`
  - `testOnlyAdminMacWithMatchingICloudUserRevalidates` (4 cases: admin+match → true; admin+other user → false; member → false; nil → false)
- [ ] FAIL → implement → PASS. Full suite. App builds. Commit `"Access: judge incoming changes by the server's writer; re-validate only on the admin's Mac"`.

### Task 3 [opus]: Deletions attributed and re-validated

**Files:**
- Modify: `Sources/BudgetCore/Sync/SyncPayload.swift`, `Sources/BudgetCore/Sync/SyncEngineCore.swift` (push: a household delete saves a marker), `Sources/BudgetCore/Sync/SyncTranslator.swift` (`applyDelete`, a marker apply), `Sources/BudgetCore/Access/AccessRevalidation.swift`, `Sources/BudgetCore/Sync/SyncZoneGuard.swift` (allow a fieldless deletion marker)
- Test: `Tests/BudgetCoreTests/DeletionAttributionTests.swift`

**Interfaces — Produces:**
- `SyncPayload.deleted: Bool?`: a deletion marker. It has no fields and is saved over the record's last version in `household`. Receivers apply it as a delete. Private zones keep hard deletes.
- `AccessRevalidation.deleteVerdict(uuid: String, table: String, attribution: Attribution, db: Database) throws -> Verdict`: `AccessAreaMap.area(... change: .delete, row: local row ...)`.
- On the re-validating Mac:
  - A denied marker keeps the row. The row is queued with `resent: true` over the marker's stamp and logged: "Reverted a delete by <name>: no permission for <Area>".
  - A bare hard deletion in `household` is undone the same way, unless this Mac's own tombstone holds the record (`deletedBy` = self). That replaces `logUnjudgedDelete`.

- [ ] Failing tests:
  - `testMemberDeleteWithoutPermissionIsUndone`
  - `testMemberDeleteWithPermissionApplies` (a Documents row)
  - `testBareHardDeleteFromAnotherDeviceIsUndone`
  - `testOwnHardDeleteSeenOnPullIsKept`
  - `testSecondAdminMacDeleteIsNotUndone`
  - `testHouseholdDeleteTravelsAsSealedMarker` (the wire carries exactly `sealed` and `keyId`)
  - `testMemberDeviceDropsRowOnDeletionMarker`
- [ ] FAIL → implement → PASS. Full suite. Commit `"Sync: household deletes as attributed markers; the Mac undoes deletes without permission"`.

### Task 4 [opus]: Unlinked documents placed by rule; full re-placement sweep

**Files:**
- Modify: `Sources/BudgetCore/Sync/SyncZoneRouter.swift` (`documentPlacement`, no-referrer branch), `Sources/BudgetCore/Sync/SyncZoneGuard.swift` (same rule, independently), `Sources/BudgetCore/Sync/SyncEngineCore.swift` (run the sweep after `SyncZoneMoves.reconcile`)
- Create: `Sources/BudgetCore/Sync/SyncPlacementSweep.swift`
- Test: `Tests/BudgetCoreTests/PlacementSweepTests.swift`

**Interfaces — Produces:**
- Rule for a document with no referrer:
  - `household` when it is a property document: built-in kind whose `ImportNaming.area(of:) == "Property"`, or custom kind with `area == .property`.
  - Else the private zone of its inserter's person: the insert clock `by` → appUser → person.
  - Else the admin's private zone.
  - A document linked to a property (`documentLink` entityType `.property`) stays a referrer case (household).
- `SyncPlacementSweep`:
  - `static let fingerprintKey = "placementInputs"` (`syncState`).
  - `static func fingerprint(db: Database) throws -> Data`: SHA-256 over these, each ordered:
    - `SyncZoneMoves.currentFacts`
    - `documentLink(documentId, entityType, entityId)`
    - each `SyncZoneRouter.pinningTables` transaction column
    - `category(id, groupId)`
    - `propertyCategoryGroup`
    - `importBatch(importRunId, accountId)`
    - `document(id, kind, customKindId)`
    - `customDocumentKind(id, area)`
  - `static func misplaced(zones: Set<String>, db: Database) throws -> [SyncZoneMoves.PlacementChange]`: every tracked non-summary record whose router placement is not where it is (zone, presence or reduced form), as `reconcile`'s no-facts branch decides it. A record whose new zone isn't in `zones` is returned too.
  - `@discardableResult static func run(zones: Set<String>, db: Database, now: Date) throws -> Int`: when the fingerprint changed, queue `misplaced` for `zones` and store the fingerprint. One query and no routing when it is unchanged.
  - Misplaced records outside `zones` are logged with `SyncTranslator.needsAttention` and never queued to `household`.

- [ ] Failing tests:
  - `testUnlinkedNonPropertyDocumentIsPrivateToItsInserter`
  - `testUnlinkedPropertyKindDocumentIsHousehold`
  - `testUnlinkedCustomPropertyKindDocumentIsHousehold`
  - `testDocumentLaterLinkedOnlyToPrivateRecordLeavesHousehold`
  - `testLostPinMovesTransactionOut`
  - `testCategoryMovedOutOfPropertyGroupMovesItsTransactionsOut`
  - `testSweepMovesUnlinkedNonPropertyDocumentOutAndMemberDropsIt`
  - `testUnchangedInputsRouteNothing` (`reconcileRoutings`-style counter)
  - `testGuardRefusesUnlinkedNonPropertyDocumentInHousehold`
- [ ] FAIL → implement → PASS. Full suite (perf: `SyncPerformanceTests` unchanged within its bounds). Commit `"Sync: unlinked documents by rule; full re-placement sweep when placement inputs change"`.

### Task 5 [opus]: Dropping data: removal from the household, iCloud account change

**Files:**
- Create: `Sources/BudgetCore/Sync/SyncLocalData.swift`, `Sources/BudgetCore/Sync/SyncHouseholdMembership.swift`
- Modify: `Sources/BudgetCore/Sync/SyncEngineCore.swift` (`SyncPullReport.leftHousehold`), `Phone/Sync/PhoneSyncController.swift`
- Test: `Tests/BudgetCoreTests/SyncLocalDataTests.swift`

**Interfaces — Produces:**
- `SyncLocalData.dropZone(_ zone: String, db: Database) throws -> Int`: deletes every row whose `syncRecord.zone == zone`, children first, as a move-marker drop does. It runs inside `SyncChangeTracker.applyingIncoming`, so nothing is queued. It also drops their `syncRecord`, staging, presence and the zone's token, and leaves no tombstones.
- `SyncLocalData.dropPrivateZones(db: Database) throws -> Int`: every `private-*` zone.
- `SyncAccountSwitch.deviceUserKey = "deviceICloudUser"`.
- `SyncAccountSwitch.check(current: String?, db: Database) throws -> Action`, with `enum Action { case keep, remember, dropPrivate }`:
  - nil: `keep`
  - none stored: `remember`
  - equal: `keep`
  - different: `dropPrivate`, after which the new name is stored.
- Engine: when `household` is reached through a split transport (`SyncEngineCore(..., householdIsShared: Bool = false)`) and its fetch throws `zoneNotFound`, the pull sets `leftHousehold = true` and creates nothing.
- `SyncHouseholdMembership` (member device, local `syncState`): `record(ownerRecordName: String, db:)`, `current(db:) -> String?`, `forget(db:)`.
- Phone controller:
  - On `dropPrivate`: drop the private zones, remove their keys (`KeychainSyncKeyStore+Removal`), restart the engine with `.none`.
  - On `leftHousehold`: drop `household`, remove its keys and `SyncHouseholdMembership.forget`, then show the notice `"You're no longer in this household. Its data was removed from this device."` (moved into `HouseholdCopy.removedNotice` in Task 7).

- [ ] Failing tests:
  - `testDropZoneRemovesRowsAndQueuesNothing`
  - `testDropPrivateZonesKeepsHousehold`
  - `testSameICloudUserAfterRelaunchKeepsData`
  - `testUndeterminedAccountDropsNothing`
  - `testDifferentICloudUserDropsPrivateData`
  - `testRemovedParticipantPullReportsLeftHousehold` (FakeCloud remove)
  - `testFiledYearFiguresUnchangedAfterDropOnAdminSide` (the drop runs on the member's device only; the Mac's filed figures don't move)
- [ ] FAIL → implement → PASS. Full suite. `scripts/build-phone.sh`. Commit `"Sync: drop a zone's data on removal or an iCloud account change"`.

### Task 6 [sonnet]: F-2 tools own their accounts; F-5 removing an owner is refused

**Files:**
- Modify: `Sources/BudgetCore/Import/BBVAHistoryImport.swift`, `BBVAFundMortgageImport.swift` (each `apply` gains `owner: AccessActor?` and passes it to every `AccountEditing.add`), `Tools/Sources/ImportBBVAHistory/main.swift`, `Tools/Sources/ImportBBVAFundAndMortgage/main.swift`, `Sources/BudgetCore/Property/Properties.swift` (`People.delete`, `PropertyError.personOwnsAccounts(count: Int)`), `App/Property/PropertyViewModel.swift` (copy)
- Test: `Tests/BudgetCoreTests/ToolOwnershipTests.swift`

**Exact values:**
- Tool prompt, after the dry-run summary, before any write: `Accounts this tool creates will be owned by <admin display name>. Continue? [y/N] `. Anything but `y`/`Y` prints `Nothing imported.` and exits 0. The owner is `AccessActor.admin(db:)`.
- `People.delete` checks `account.ownerPersonId = id` before deleting; with a count > 0 it throws `.personOwnsAccounts(count:)`.
- Copy: `That person owns 1 account, so they can't be removed.` / `That person owns <n> accounts, so they can't be removed.`

- [ ] Failing tests:
  - `testHistoryImportOwnsAccountsByGivenOwner`
  - `testFundMortgageImportOwnsAccountsByGivenOwner`
  - `testNilOwnerKeepsJointEverything` (before ownership is confirmed)
  - `testDeletingPersonWhoOwnsAccountsIsRefused`
  - `testRefusalCopyCountsAccounts`
- [ ] FAIL → implement → PASS. `cd Tools && swift build --scratch-path $S7/tools`. Full suite. Commit `"Tools own the accounts they create; removing an account owner is refused with copy"`.

### Task 7 [opus]: Invite core: member, gate, share, bind, remove

**Files:**
- Create: `Sources/BudgetCore/Access/HouseholdInvite.swift`, `Sources/BudgetCore/Access/HouseholdCopy.swift`
- Modify: `Sources/BudgetCore/Auth/AppUserStore.swift` (`addMember`)
- Test: `Tests/BudgetCoreTests/HouseholdInviteTests.swift`

**Interfaces — Produces:**
- `AppUserStore.addMember(_ db: Database, personId: Int64?, name: String, by actorId: Int64, now: Date) throws -> AppUser`:
  - Admin only.
  - A nil `personId` creates the `person` (via `People.save`).
  - No password and no local credential; `isAdmin = false`.
  - Written through `ActorWrite.perform(.householdSettings)`.
  - Refuses a second member.
- `HouseholdInvite.Blocker: Equatable`: `.ownershipNotConfirmed`, `.syncNotOn`, `.noMember`, `.pendingUpload(Int)`, `.misplaced(Int)`, `.householdAudit(Int)`, `.offline`.
- `HouseholdInvite.localBlockers(db: Database) throws -> [Blocker]`: `SharingSetup.isConfirmed`, the turn-on stage, a member, `SyncChangeTracker.pending` + `SyncZoneMoves.unfinished`, `SyncPlacementSweep.misplaced(zones: admin's)`.
- `HouseholdInvite.auditServer(transport: any SyncTransport, keys: any SyncKeyStore, db: Database) async throws -> [SyncZoneGuard.Violation]`: every page of `household` from nil, unsealed and checked with `SyncZoneGuard(db:).review`.
- `HouseholdInvite.invite(transport: any SyncTransport & SyncShareTransport, keys:, db: any DatabaseWriter, title: String) async throws -> Result`, with `enum Result { case blocked([Blocker]), share(SyncZoneShare) }`:
  - Runs the local blockers, then the audit; a passing transport error is `.offline`.
  - Then `makeZoneShare(SyncZones.household, title:)`.
- `HouseholdInvite.bindAcceptedParticipant(share: SyncZoneShare, db: Database) throws -> Bool`: the single accepted participant not yet on any appUser is written to the member's `cloudKitUserRecordName`, as the admin. Two unknown participants bind nobody and are logged.
- `HouseholdInvite.status(share: SyncZoneShare?, member: AppUser?) -> Status`: `.notInvited`, `.invited`, `.joined`.
- `HouseholdInvite.remove(transport: any SyncShareTransport, member: AppUser) async throws`: `removeParticipant`.
- `HouseholdCopy` (exact strings; Task 5's notices move here):
  - `paneTitle = "Household"`
  - `addTitle = "Add someone to the household"`
  - `addField = "Name"`
  - `addButton = "Add"`
  - `inviteButton = "Invite…"`
  - `inviteExplainer(name) = "Invite \(name) to Mango. They'll see what your sharing levels allow, and can't change anything yet."`
  - `status`: `"Not invited yet"`, `"Invited — waiting for them to accept"`, `"Joined"`
  - `removeButton = "Remove from household…"`
  - `removeTitle(name) = "Remove \(name) from the household?"`
  - `removeMessage = "Their devices stop syncing and delete the household's data. Your data stays on this Mac."`
  - Blockers:
    - `"Confirm who owns each account first, in Settings ▸ Sharing."`
    - `"Turn on iCloud sync first, in Settings ▸ Sync."`
    - `"Add the person you're inviting first."`
    - `"Mango still has \(n) change(s) to upload. Sync now, then try again."` (1 → "1 change")
    - `"\(n) record(s) aren't in the right place yet. Sync now, then try again."`
    - `"\(n) record(s) in the household shouldn't be there. Nothing was shared."`
    - `"Mango couldn't check iCloud. Try again when you're online."`
  - `removedNotice = "You're no longer in this household. Its data was removed from this device."`
  - `accountChangedNotice = "This device's iCloud account changed. Mango removed the previous person's private data."`

- [ ] Failing tests (over `TwoPersonHousehold` with the member not yet invited):
  - `testInviteBlockedUntilOwnershipConfirmed`
  - `testInviteBlockedWhilePending`
  - `testInviteBlockedByMisplacedRecord`
  - `testInviteRefusedWhileARecordBelowEverythingIsInHousehold` (planted through `setAssignmentOverride`)
  - `testInviteMakesZoneShare`
  - `testInviteTwiceReusesTheShare`
  - `testAcceptedParticipantIsBoundToMember`
  - `testTwoUnknownParticipantsBindNobody`
  - `testMemberViewerFollowsOnceHerRecordNameIsBound`
  - `testMemberNeverReceivesPrivateRecordsAfterJoining` (full pull through her session; `ZoneAuditingTransport` clean; her zone set is household + hers)
  - `testRemoveThenMemberLeavesHousehold`
  - `testAddMemberRefusedForNonAdmin`
- [ ] FAIL → implement → PASS. Full suite. Commit `"Household: add the member, gate and audit before the invite, share, bind, remove"`.

### Task 8 [opus]: Household key exchange

**Files:**
- Create: `Sources/BudgetCore/Sync/SyncKeyExchange.swift`
- Modify: `Sources/BudgetCore/Sync/SyncEngineCore.swift` (`reservedRecordTypes` += `keyRequest`, `keyGrant`)
- Test: `Tests/BudgetCoreTests/SyncKeyExchangeTests.swift`

**Interfaces — Produces:**
- `SyncKeyExchange.requestRecordType = "keyRequest"`, `grantRecordType = "keyGrant"`, `info = "mango-household-key-v1"`, `keyId = "exchange-v1"`.
- Member: `static func request(transport: any SyncTransport, now: Date) async throws -> PendingRequest`:
  - `PendingRequest` holds `requestId`, a `Curve25519.KeyAgreement.PrivateKey` (kept in memory) and `code: String`.
  - Saves `keyRequest-<id>` in `household` with fields `publicKey` (32 bytes, not secret) and `requestedAt`.
- `static func code(publicKey: Data) -> String`: the first 4 bytes of SHA-256, big-endian, mod 1,000,000, zero-padded to 6 digits, shown as `"123 456"`.
- Mac: `static func openRequests(transport:) async throws -> [Request]` (`Request`: id, code, `lastModifiedBy`). The admin's Mac shows only requests whose `lastModifiedBy` is the bound member's record name.
- Mac: `static func grant(_ request: Request, keys: any SyncKeyStore, transport:) async throws`:
  - Every household key from `keys.allKeys(zone: household)` is sealed with AES-GCM under HKDF-SHA256 of the ECDH secret (salt = request id, info above).
  - Saved as `keyGrant-<id>` with exactly `sealed` (= ephemeral public key ‖ box) and `keyId`.
- Member: `static func receive(_ pending: PendingRequest, transport:, into keys: any SyncKeyStore) async throws -> Bool`: opens the grant, stores the keys, deletes both records. A wrong box stores nothing.
- Copy (in `HouseholdCopy`):
  - `keyRequestTitle(name) = "\(name)'s device is asking for the household key."`
  - `keyRequestCheck(code) = "Check that it shows this code: \(code)"`
  - `giveKeyButton = "Give the key"`
  - `notNowButton = "Not now"`
  - `showCode(admin, code) = "Show this code to \(admin) on the Mac: \(code)"`
  - `waitingForKey = "Waiting for the household key…"`

- [ ] Failing tests:
  - `testGrantDeliversAllHouseholdKeysToRequester`
  - `testCodeMatchesOnBothSides`
  - `testRequestFromNonMemberIsNotListed`
  - `testTamperedGrantStoresNothing`
  - `testGrantRecordCarriesExactlySealedAndKeyId`
  - `testEngineIgnoresExchangeRecords`
  - `testMemberOpensHouseholdAfterGrant` (end to end over `TwoPersonHousehold` with `memberKeys` starting empty)
- [ ] FAIL → implement → PASS. Full suite. Commit `"Sync: household key exchange confirmed by a side-by-side code"`.

### Task 9 [sonnet]: Mac Settings ▸ Household

**Files:**
- Create: `App/Settings/HouseholdSettings.swift`, routes in `App/Snapshots/SharingSnapshots.swift`
- Modify: `App/Settings/SettingsView.swift` (pane `.household`, `HouseholdCopy.paneTitle`, `person.2.circle`, admin only), `App/Sync/RealSync.swift` (`bindAcceptedParticipant` and `openRequests` on each sync), the Mac `Info.plist` (`CKSharingSupported` = YES)

**Behaviour:**
- Shows the member row (name, `HouseholdCopy` status) or the add form (name field, or a pick from `AppUserStore.unclaimedPeople`).
- "Invite…" calls `HouseholdInvite.invite`:
  - Blockers are listed in place, with their copy.
  - A share opens `NSSharingServicePicker` with `NSItemProvider.registerCKShare(_:container:allowedSharingOptions:)` (`CKAllowedSharingOptions(allowedParticipantPermissionOptions: .readWrite, allowedParticipantAccessOptions: .specifiedRecipientsOnly)`).
- A key request shows the `keyRequest…` copy with the code and the buttons.
- Remove shows a confirmation dialog with the `remove…` copy.
- Snapshot routes (demo data): `household_add`, `household_blocked`, `household_invited`, `household_key_request`.

- [ ] Render the routes: `scripts/render-snapshots.sh $S7/snaps --quick --routes household --size 1100x700`. No figure or label wraps or truncates.
- [ ] App builds. Full suite. Commit `"Mac: Settings ▸ Household — add, invite, give the key, remove"`.

### Task 10 [sonnet]: iPad/iPhone: accept, key, read-only household

**Files:**
- Modify: `Phone/Lock/PhoneSceneDelegate.swift` (`windowScene(_:userDidAcceptCloudKitShareWith:)` → `CKAcceptSharesOperation` → `SyncHouseholdMembership.record(ownerRecordName: metadata.ownerIdentity.userRecordID?.recordName)`), `Phone/Sync/PhoneSyncController.swift`, `Phone/Info.plist` (`CKSharingSupported`), phone snapshot routes in `Phone/Snapshots`

**Behaviour:**
- With a membership, the engine is `SyncEngineCore(transport: SyncZoneSplitTransport(household: CloudKitTransport(database: container.sharedCloudDatabase, zoneOwnerName: owner), others: CloudKitTransport()), readOnly: true, householdIsShared: true, viewer: …)`.
- With no household key, it runs `SyncKeyExchange.request` and shows `showCode` / `waitingForKey`, then polls `receive` on each sync.
- The existing lock (`PhoneLockModel`) is on from first launch. The existing viewer-follow shows what the levels allow.
- Task 5's drops are wired, with their notices.
- Without a membership, it behaves as today (the admin's phone).
- Snapshot routes: `join_waiting_key`, `join_removed`.

- [ ] `scripts/build-phone.sh` green. Render the phone routes. Full suite. Commit `"Phone: accept the household share, receive the key, follow removal"`.

---

## Controller steps (not subagent tasks)

1. Whole-branch review [opus] → merge to `main` → `xcodegen generate` → `scripts/install-app.sh`.
2. With the user: back up the real DB. On the Mac: Settings ▸ Household → add the member (name typed by the user) → Invite…. The gate must pass, including the server audit. If anything is blocked, stop and report.
3. The user adds her Apple Account as a TestFlight tester (their action) → archive/upload the phone build (needs the user's go) → she installs it on her iPad.
4. Side by side: she accepts the link. The Mac binds her. Compare the codes → "Give the key". Her iPad pulls `household` only. Check that her zone set is household + her own, and that nothing below Everything shows.
5. Optional rehearsal of removal on the demo database only, never the real share.

Not in 7a: key rotation after a removal, member writes, iPad-native screens.
