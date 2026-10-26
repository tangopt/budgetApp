# Step 8 (lean): iPad screens, tenancy first — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (chosen) to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** the MangoPhone app becomes universal. On iPad it gets a sidebar layout with Property (Overview, Bills, Recharges, Rent receipts, Tenancies), Documents and Missing evidence. The member does tenancy work there within her Edit areas, over a household share that is now read-write. The admin's Mac re-validates every change.

**Architecture:**
- **One engine, three write modes.** `SyncEngineCore` gains `SyncWriteMode`:
  - `.full` is the Mac.
  - `.readOnly` is the iPhone and today's phone.
  - `.device(zones:)` is an iPad whose user has Edit somewhere. It pushes only to those zones. It never makes a zone, a key or a lease, and never rebuilds summaries.
- **Every iPad write goes through `DeviceWriter`** (BudgetCore). The actor is the app user bound to this device's iCloud user. The writer checks `ActorWrite.perform(area, origin)`, runs filed-year checks with no resolution (a question becomes an inline refusal), then asks for a push.
- **The member pushes `household` only**, through her shared database (`SyncZoneSplitTransport`, unchanged). The admin's iPad pushes `household` and his own private zone. The Mac's 7a re-validation (`revalidatesAccess`, server-attributed writer) keeps or reverts each change.
- **The share becomes read-write.** `makeZoneShare` now gives participants write access, with no public access as before. The Mac upgrades an existing read-only share by re-running the invite's gate and audit (`HouseholdInvite.allowMemberEdits`). FakeCloud enforces the same.
- **The iPad UI lives in `Sources/MangoUI/Pad/`.** It reuses the Mac's BudgetCore read models (`UtilityBills`, `Recharges`, `RechargeDetails`, `RentReceiptPayments`, `TransactionDocuments`, `EvidenceLinks`, `MissingEvidence`/`MissingEvidenceDetail`, `DocumentKindCatalog`) and the Mac's write APIs. The iPhone's `PhoneTabs` is untouched.

**Tech Stack:** Swift 6, GRDB 6.29, SwiftUI (iOS 26 `NavigationSplitView`, QuickLook), CloudKit (`CKShare.Participant.permission`), XCTest, XcodeGen.

**Spec:** `docs/superpowers/specs/2026-10-26-ipad-tenancy-design.md` (binding). Background: `2026-10-26-household-lean-design.md`, `2026-10-25-sharing-levels-design.md`, `2026-10-22-sync-and-access-design.md`, plan `2026-10-24-step4-iphone-read-only.md`.

## Global Constraints

- **Logic in BudgetCore.** Modes, the device writer, refusals, the share upgrade and all copy live in `Sources/BudgetCore`. `Phone/`, `App/` and `MangoUI` only call them. `scripts/build-core-ios.sh` stays green.
- **Sealed records:** no new record type, field or payload key. **No `SyncSchema.version` bump. No CloudKit Production schema change.** A participant's permission is share metadata, not schema.
- **Nothing below Everything ever in `household`.** Every new sync test runs over `ZoneAuditingTransport` / `TwoPersonHousehold`.
- **Filed SA returns 2020/21–2024/25 never change.** iPad writes go through `FiledYearEditCheck.save` / `EvidenceLinkGuard.checked` with `resolution: nil`. The Mac's incoming checks are unchanged.
- **Synthetic data only** ("Person A", "Person B", BudgetDemo).
- **Real sync is live on the admin's devices.** The admin's iPhone stays `.readOnly`. Writer mode is iPad-only (`userInterfaceIdiom == .pad`). No subagent touches the real DB, Keychain, iCloud, the installed app or the user's screen.
- **Commands** (`S8=/private/tmp/claude-501/-Users-pablo-dimenza-Documents-Code-budget/5fac4f61-c0c9-436b-881b-aebe445aa967/scratchpad/build-8`):
  - targeted (fix rounds): `swift test --scratch-path $S8 --filter '<Tests>'`
  - full suite, once at the end of each task: `swift test --scratch-path $S8 --parallel`
  - phone/iPad build: `xcodegen generate && scripts/build-phone.sh`
  - Mac build (Task 2 only): `xcodebuild -project Mango.xcodeproj -scheme Mango -configuration Debug -derivedDataPath $S8/dd CODE_SIGNING_ALLOWED=NO build`
  - snapshots: `scripts/render-phone-snapshots.sh $S8/snaps-pad --device ipad --only <routes>`
  - at most 2 building agents at once.
- **Model tags:** **[opus]** = privacy, sync, write path or filed year: most capable model, plus a spec+code review. **[sonnet]** = UI or small: quick review.

## Review Focus

1. **The member changes a document's kind on an iPad that never downloaded its file** (lazy policy). Expect the pushed `evidenceDocument` to keep its file reference, and the Mac to keep the file. Task 1: `testDeviceWithoutFileKeepsDocumentFileReferenceOnPush`.
2. **The member loses Edit on Property while an edit is still queued** (offline). Expect the iPad to stop offering edits once the permission arrives. If the queued edit is pushed anyway, the Mac reverts it and her iPad converges. Task 4: `testQueuedEditAfterEditRemovedIsReverted`.
3. **A member write that routes outside `household`.** Example: a document linked only to a record placed privately. Expect it held back: not pushed to her private database, counted in `SyncPushReport.heldBack`, and nothing leaks. Task 1: `testDeviceModeHoldsBackRecordsOutsideItsZones`.
4. **The Mac and the iPad edit the same recharge statement.** Example: the Mac marks it sent while the iPad, offline, adds a line. Expect both kept by field merge, with no revert, since both writers have Edit. Task 4: `testMacAndMemberEditSameStatementBothKept`.
5. **The share upgrade runs twice, or while something blocks.** Expect one share, still `canWrite == false` while blocked, and upgraded once clear. Task 2: `testAllowMemberEditsTwiceKeepsOneShare`, `testAllowMemberEditsBlockedKeepsShareReadOnly`.

---

### Task 1 [opus]: Engine writer mode `.device(zones:)`

**Files:**
- Modify: `Sources/BudgetCore/Sync/SyncEngineCore.swift`, `Sources/BudgetCore/Sync/SyncDocumentFiles.swift` (push of a file-bearing row without its local file), `Tests/TestSupport/TwoPersonHousehold.swift`
- Create: `Sources/BudgetCore/Sync/SyncWriteMode.swift`
- Test: `Tests/BudgetCoreTests/SyncDeviceWriterModeTests.swift`

**Interfaces — Produces:**
- `public enum SyncWriteMode: Equatable, Sendable { case full; case readOnly; case device(zones: Set<String>) }`
- `SyncEngineCore.init(..., readOnly: Bool = false, mode: SyncWriteMode? = nil, ...)`: `mode` wins. When it is nil, `readOnly ? .readOnly : .full` (existing callers unchanged).
- `public nonisolated let mode: SyncWriteMode`. `readOnly` becomes a computed `mode == .readOnly`.
- `.device` behaves like `.readOnly` at every existing `readOnly` gate except push and apply:
  - no zone creation (`prepare`), no `recoverMissingZone`, no lease (`acquire/releaseImportLease` throw `ReadOnlyError.readOnly`)
  - `householdKey(create: false)` only (no key → `SyncKeyError.waitingForHouseholdKey`)
  - no `AccountSummaryBuilder.rebuild`, `cleansFiles == false`
  - apply is tracked as on the Mac (not `readOnlyApply`)
- `pushAll` in `.device` sends only records whose zone is in `zones`. Others stay pending.
- `SyncPushReport.heldBack: Int`: the pending records outside the zones.
- `TwoPersonHousehold.make(..., memberMode: SyncWriteMode = .full)` (today's default kept). New `adminTablet: Device`: `.device(zones: [household, private zone A])` over `audit`, with `adminKeys`.
- `TwoPersonHousehold.memberTabletMode = .device(zones: [SyncZones.household])`.

- [ ] **Step 1: Write the failing tests** in `SyncDeviceWriterModeTests`:
  - `testDeviceModeNeverCreatesAZone`: fresh cloud with no `household`. Device push → `cloud` zone list unchanged, report empty.
  - `testDeviceModeTakesNoLease`: `acquireImportLease()` throws `ReadOnlyError.readOnly`.
  - `testDeviceModeWithoutKeyWaits`: no household key → push throws `SyncKeyError.waitingForHouseholdKey`. `adminKeys` unchanged.
  - `testMemberDevicePushesHouseholdEditAttributedToHer`: she edits a `utilityInvoice` note, then pushes. `cloud` version `lastModifiedBy == memberICloudUser`, and `memberAudit` has no violations.
  - `testDeviceModeHoldsBackRecordsOutsideItsZones`: forced assignment (`setAssignmentOverride`) to `memberZone` → not saved anywhere, `report.heldBack == 1`, still pending.
  - `testDeviceModeDoesNotRebuildSummaries`: dirty summaries → push → no `accountSummary` row changed.
  - `testDeviceWithoutFileKeepsDocumentFileReferenceOnPush`: lazy `phoneDocuments`, file never downloaded. Change `evidenceDocument.kind` → push → Mac pulls → same file reference, file still on the Mac.
  - `testReadOnlyFlagStillMeansReadOnly`: `readOnly: true` → `mode == .readOnly`.
- [ ] **Step 2: Run** `swift test --scratch-path $S8 --filter SyncDeviceWriterModeTests`. Expected: FAIL (no `mode`).
- [ ] **Step 3: Implement** `SyncWriteMode` and the gates above. The file-reference rule: a row whose file isn't local pushes its stored reference unchanged and never re-uploads.
- [ ] **Step 4: Run** the targeted tests → PASS. Then the full suite → PASS (existing sync tests unchanged).
- [ ] **Step 5: Commit** `git commit -m "Sync: device writer mode — pushes its zones only, never makes zones, keys or leases"`

### Task 2 [opus]: The household share becomes read-write; safe upgrade

**Files:**
- Modify: `Sources/BudgetCore/Sync/SyncShareTransport.swift` (doc of `makeZoneShare`), `Sources/BudgetCore/Sync/FakeCloud.swift` (`readOnly` set → `readWrite`; `invite(canWrite:)` honoured as given until `makeZoneShare` upgrades), `Sources/MangoSync/CloudKitTransport+Sharing.swift`, `Sources/BudgetCore/Access/HouseholdInvite.swift`, `Sources/BudgetCore/Access/HouseholdCopy.swift`, `App/Settings/HouseholdSettings.swift`
- Test: `Tests/BudgetCoreTests/FakeCloudShareTests.swift`, `Tests/BudgetCoreTests/HouseholdInviteTests.swift`

**Interfaces — Produces:**
- `makeZoneShare(_:title:)`: no public access, and every non-owner participant `canWrite == true`. An existing share is upgraded in place, never made twice.
- CloudKit: `existing.publicPermission = .none`, every non-owner participant with `.readOnly` set to `.readWrite`, saved `.ifServerRecordUnchanged`. On `serverRecordChanged`, fetch again and retry once.
- `public static func allowMemberEdits(transport: any SyncTransport & SyncShareTransport, keys: any SyncKeyStore, db: any DatabaseWriter, title: String) async throws -> HouseholdInvite.Result`:
  - the same gates as `invite` (local blockers, orphan files, server audit, local again), then `makeZoneShare`
  - nothing changes when no participant has `canWrite == false` (returns `.share` without a save)
- `public static func needsEditUpgrade(_ share: SyncZoneShare?) -> Bool`: an accepted participant has `canWrite == false`.
- Copy (`HouseholdCopy`):
  - `editsAllowed(_ name: String) -> String` = `"\(name) can make changes within their permissions."`
  - `editsWaiting(_ name: String) -> String` = `"\(name) can view only for now:"` (followed by `blocker(_:alreadyShared: true)` lines)
  - `allowEditsButton(_ name: String) -> String` = `"Let \(name) make changes"`
- Mac: while `status == .joined` and `needsEditUpgrade`, Household settings shows `editsWaiting` and the button. The button runs `allowMemberEdits`, and its result shows `editsAllowed` or the blockers. There is no automatic upgrade: the real share changes only when the admin presses it. The share sheet's `allowedParticipantPermissionOptions` becomes `.readWrite`, so a new invite is read-write from the start.

- [ ] **Step 1: Write the failing tests:**
  - `FakeCloudShareTests.testMadeShareLetsParticipantWrite`: invite + accept + `makeZoneShare` → member session save succeeds, `lastModifiedBy == fake-member`.
  - `testUninvitedUserStillCannotReach`: `zoneNotFound`.
  - `testRemovedParticipantCannotWrite`: `zoneNotFound`.
  - `HouseholdInviteTests.testAllowMemberEditsUpgradesReadOnlyShare`: `invite(canWrite: false)` + accept → `needsEditUpgrade == true` → `allowMemberEdits` → `.share` with `canWrite == true`.
  - `testAllowMemberEditsTwiceKeepsOneShare`: the same URL both times.
  - `testAllowMemberEditsBlockedKeepsShareReadOnly`: `pendingUpload(1)` → `.blocked([.pendingUpload(1)])`, and still `canWrite == false`.
  - `testAllowMemberEditsAuditViolationKeepsShareReadOnly`: a planted private record in `household` → `.blocked([.householdAudit(1)])`.
  - `testEditsCopy`: the three exact strings with `"Person B"`.
- [ ] **Step 2: Run** `--filter 'FakeCloudShareTests|HouseholdInviteTests'` → FAIL.
- [ ] **Step 3: Implement** the above. Update the 7a tests that asserted read-only to the new rule; list each one in the commit message.
- [ ] **Step 4: Run** the targeted tests, then the full suite, then the Mac build → PASS. Run `scripts/check-actor-writes.sh` → "actor writes OK".
- [ ] **Step 5: Commit** `git commit -m "Household: the share is read-write; the Mac upgrades a read-only share behind the invite's gate"`

### Task 3 [opus]: `DeviceWriter`: actor, area, origin, filed-year refusals

**Files:**
- Create: `Sources/BudgetCore/Access/DeviceWriter.swift`, `Sources/BudgetCore/Access/DeviceWriteCopy.swift`
- Test: `Tests/BudgetCoreTests/DeviceWriterTests.swift`

**Interfaces — Produces:**
- `public struct DeviceWriter: Sendable { public init(db: any DatabaseWriter, viewer: @escaping @Sendable () -> PhoneViewer, afterWrite: @escaping @Sendable () -> Void) }`
  - `.iCloudUser(recordName)` → `AppUser.forCloudKitUser`. `.demoAdmin` → the admin. `.everyone` → admin (tests).
  - `func actor() async throws -> AccessActor?` (nil: no bound user yet)
  - `func canEdit(_ area: AccessArea) async -> Bool` (false with no actor)
  - `func write<T: Sendable>(_ area: AccessArea, origin: WriteOrigin = .edit, _ body: @escaping @Sendable (Database) throws -> T) async throws -> T`: no actor → `DeviceWriteRefusal.notLinkedYet`. Else `ActorWrite.perform(actor, area:origin:)`, then `afterWrite()` on success only.
  - `func writeCheckingFiledYears<T: Sendable>(_ area: AccessArea, origin: WriteOrigin = .edit, edit: String, scope: FiledYearEditCheck.Scope, _ body: @escaping @Sendable (Database) throws -> T) async throws -> T`: `FiledYearEditCheck.save(resolution: nil)`. `.asks(q)` → throws `DeviceWriteRefusal.filedYear(q)`, nothing written.
- `public enum DeviceWriteRefusal: Error, Equatable, LocalizedError { case notLinkedYet; case filedYear(FiledYearEditCheck.Question) }`
- `public enum DeviceWriteMode { public static func decide(recordName: String?, isMember: Bool, isPad: Bool, db: Database) throws -> SyncWriteMode }`:
  - `.readOnly` unless `isPad` and the bound actor has Edit on any area
  - member → `.device(zones: [household])`
  - admin → `.device(zones: [household, privateZone(personUuid of the actor)])`
- `DeviceWriteCopy` (exact):
  - `notLinkedYet` = `"Mango hasn't linked this iPad to you yet. Sync, then try again."`
  - `filedYear(years: [String])` = `"Not saved: this would change the filed \(y) return. To change it anyway, use the Mac."` with one year; plural `"the filed 2022/23 and 2023/24 returns"` (", " then " and " before the last)
  - `viewOnly(_ area: AccessArea)` = `"View only: you don't have Edit on \(area.title)."`
  - `AccessDenied` and `EvidenceLinkGuard.Failure` keep their own `errorDescription`.

- [ ] **Step 1: Write the failing tests:**
  - `testMemberWritesPropertyStampedHerWithOrigin`: `syncRecord.origin == "propertyMatching"`, writer is her appUser UUID, `afterWrite` called once.
  - `testMemberBudgetWriteDenied`: `.budgetAndAccounts` → `AccessDenied(area: .budgetAndAccounts)`, nothing written, `afterWrite` not called.
  - `testUnboundDeviceRefusesNotLinkedYet`.
  - `testFiledYearQuestionBecomesRefusal`: re-dating a 2023/24 property expense → `.filedYear` with `years.map(\.label) == ["2023/24"]`, the row unchanged.
  - `testEvidenceLinkGuardRefusalPassesThrough`: unlinking a document from a 2022/23 transaction → `EvidenceLinkGuard.Failure.changesFiledYear(years: ["2022/23"])`.
  - `testDecideModes`: iPhone → `.readOnly`; iPad member with Edit → `[household]`; iPad admin → `[household, privateZone(A)]`; iPad member with all View → `.readOnly`; unbound → `.readOnly`.
  - `testCopyStrings`: every string above, one-year and two-year forms.
- [ ] **Step 2: Run** `--filter DeviceWriterTests` → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** the targeted tests, then the full suite → PASS.
- [ ] **Step 5: Commit** `git commit -m "Access: DeviceWriter — iPad writes as the bound user, filed-year questions refused inline"`

### Task 4 [opus]: End-to-end: the member's tenancy work reaches the Mac

**Files:**
- Test: `Tests/BudgetCoreTests/MemberTabletEndToEndTests.swift` (`TwoPersonHousehold.make(revalidatesAccess: true, memberMode: memberTabletMode)`, share made by `makeZoneShare`)
- Modify: `Tests/TestSupport/SharingFixture.swift` only if the fixture lacks a tenancy, a provider, an invoice and a draft statement on `propertyId` (add them, synthetic)

**Interfaces — Consumes:** Tasks 1–3. Every member write goes through `DeviceWriter(db: member, viewer: .iCloudUser(memberICloudUser))` calling the Mac's own APIs: `UtilityInvoiceIntake.attach`, `Recharges.saveInvoice` (`transactionId`), `Recharges.setLine`, `Recharges.markSent`, `Recharges.linkPayment`, `RentReceiptPayments.link`, `EvidenceLinks.link`, `CustomDocumentKinds`/the document kind field.

- [ ] **Step 1: Write the tests.** Each one: member writes → member push → Mac pull (re-validates) → Mac push → member pull.
  - `testMemberLinksInvoiceDocumentKept`: the Mac row has `documentId`. `UtilityBills.read` stage `.invoiceIn` → `.linkedToPayment` after `transactionId`.
  - `testMemberAddsToRechargeKept`: stage `.inRecharge` on the Mac.
  - `testMemberMarksSentKept`: statement `.sent` on the Mac, stage `.sentToTenant`.
  - `testMemberRecordsTenantPaymentKept`: `rechargePayment` row on the Mac, stage `.paidByTenant` when fully paid.
  - `testMemberLinksDocumentKept`: `documentLink` with origin `documentLink` kept.
  - `testMemberLinksRentReceiptPaymentKept`.
  - `testMemberBudgetCategoryChangeRevertedByMac`: bypass `DeviceWriter` (raw write stamped as her) to change a household transaction's `categoryId` → the Mac reverts → her device converges on the original.
  - `testQueuedEditAfterEditRemovedIsReverted`: the Mac sets her Property to View after she queued `markSent` offline. The push is reverted by the Mac.
  - `testMacAndMemberEditSameStatementBothKept`.
  - `testFiledYearMemberEditNeverReachesCloud`: `DeviceWriteRefusal.filedYear`, and her pending count is 0.
  - `testAdminTabletEditKeptAndPhoneStillPulls`: `adminTablet` marks sent → the Mac keeps it → `adminPhone` (read-only) pulls it. Every audit is clean.
  - `testNothingBelowEverythingReachesHousehold`: after all of the above, `audit`/`memberAudit` have no violations.
- [ ] **Step 2: Run** `--filter MemberTabletEndToEndTests`. Expected: PASS once Tasks 1–3 are in. Any failure is a real gap: fix it in the owning Task's file, with a targeted test there.
- [ ] **Step 3: Run** the full suite → PASS.
- [ ] **Step 4: Commit** `git commit -m "Tests: the member's iPad tenancy edits reach the Mac, re-validated; out-of-area edits reverted"`

### Task 5 [opus]: `PhoneSyncController` writer mode on iPad

**Files:**
- Modify: `Phone/Sync/PhoneSyncController.swift`, `Phone/PhoneEnvironment.swift`, `Phone/MangoPhoneApp.swift` (makes the `DeviceWriter`), `Phone/PhoneDatabase.swift` (the iPad's library folder: `Application Support/Mango/Library`)
- Test: `Tests/BudgetCoreTests/DeviceWriterTests.swift` (mode re-decided: `testModeFollowsPermissionChange`)

**Interfaces:**
- `startEngine(viewer:)` makes the engine with `mode: DeviceWriteMode.decide(recordName: viewerRecordName, isMember: memberOwner != nil, isPad: UIDevice.current.userInterfaceIdiom == .pad, db:)`.
  - iPad: `documents: SyncDocumentFiles(root: libraryRoot, policy: .lazy)`. iPhone: `nil`, as today.
- `@Published private(set) var writeMode: SyncWriteMode`. After each sync whose pull changed `appUser`/`permission` rows, a different decided mode re-makes the engine, one at a time (the `followViewer` pattern).
- `func localChange()` → `scheduler.requestSync(.localChange)`. It is `DeviceWriter.afterWrite`.
- `func openDocument(uuid: String) async throws -> URL` → `SyncEngineCore.downloadDocument(uuid:)`.
- Demo data: a `DeviceWriter` over the demo queue with `.demoAdmin` and `afterWrite: {}`. It never syncs.

- [ ] **Step 1: Write the failing test** `testModeFollowsPermissionChange`. A pull that turns the member's Property to View, with every other area at View too, makes `decide` return `.readOnly`.
- [ ] **Step 2: Run** it → FAIL. **Step 3: Implement.**
- [ ] **Step 4: Run** the targeted test, the full suite, and `xcodegen generate && scripts/build-phone.sh` → PASS.
- [ ] **Step 5: Commit** `git commit -m "iPad: the sync engine writes for a user with Edit; iPhone stays read-only"`

### Task 6 [sonnet]: Universal target, iPad sidebar, iPad snapshot sizes

**Files:**
- Modify: `project.yml`:
  - `TARGETED_DEVICE_FAMILY: "1,2"`
  - `INFOPLIST_KEY_UISupportedInterfaceOrientations_iPad: "UIInterfaceOrientationPortrait UIInterfaceOrientationPortraitUpsideDown UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight"`
  - the iPhone key unchanged
- Modify: `Phone/MangoPhoneApp.swift` (`.pad` → `PadRootView`, else `PhoneTabs`), `Phone/Snapshots/PhoneSnapshotRunner.swift`, `scripts/render-phone-snapshots.sh`, `Sources/MangoUI/Demo/DemoRoutes.swift`
- Create: `Sources/MangoUI/Pad/PadRootView.swift`, `Sources/MangoUI/Pad/PadSection.swift`
- Test: `Tests/MangoUITests/PadRootTests.swift`

**Interfaces — Produces:**
- `public enum PadSection: Hashable, CaseIterable, Sendable { case home, month, accounts, propertyOverview, bills, recharges, rentReceipts, tenancies, documents, missingEvidence, search }` with `title`:
  - "Home", "Month", "Accounts", "Overview", "Bills", "Recharges", "Rent receipts", "Tenancies", "Documents", "Missing evidence", "Search"
  - sidebar groups: (none) Home/Month/Accounts/Search; "Property"; "Documents" (Documents, Missing evidence)
- `public struct PadRootView: View { public init(tabs: PhoneTabsModel, writer: DeviceWriter, syncStatus: SyncStatus) }`:
  - `NavigationSplitView`; the detail of Home/Month/Accounts/Search reuses the iPhone screens' views
  - the Property group is hidden when `!tabs.hasProperty`
  - the lock cover, banners and Settings sheet stay as on iPhone
- Snapshot harness: `--device ipad` boots `IOS_SIM_DEVICE` (default "iPad Pro 13-inch (M5)"). It renders each `DemoRoute` with `pad: true` at 834×1194, 1194×834, 1032×1376 and 1376×1032, light and dark, at `.large` and `.xxxLarge`. Names are `<route>-<w>x<h>-<appearance>-<size>.png`. The wrap probe runs as on iPhone.
- `DemoRoute.pad: Bool = false`. New route `pad-root`.

- [ ] **Step 1: Write the failing tests:**
  - `PadRootTests.testSectionsAndTitles`: order and exact titles.
  - `testPropertyGroupHiddenWithoutProperty`.
  - `testPhoneRoutesUnchanged`: `DemoRoutes.all.filter { !$0.pad }` names are as before.
- [ ] **Step 2: Run** `--filter PadRootTests` → FAIL. **Step 3: Implement.**
- [ ] **Step 4: Run** the targeted tests and the full suite. Then `xcodegen generate && scripts/build-phone.sh` and `scripts/render-phone-snapshots.sh $S8/snaps-pad --device ipad --only pad-root`: 0 wrap violations. Then the iPhone run `--only gallery,home`: unchanged.
- [ ] **Step 5: Commit** `git commit -m "iPad: universal app, sidebar layout; snapshot harness renders iPad sizes"`

### Task 7 [sonnet]: iPad Property: Overview, Tenancies, Bills (read)

**Files:**
- Create: `Sources/MangoUI/Pad/Property/PadPropertyModel.swift`, `PadOverviewView.swift`, `PadTenanciesView.swift`, `PadBillsView.swift`
- Test: `Tests/MangoUITests/PadPropertyTests.swift`

**Interfaces — Produces:**
- `@MainActor public final class PadPropertyModel: ObservableObject { init(dbQueue: any DatabaseReader, today: @escaping () -> Date) }`:
  - `@Published tenancies: [Tenancy]`, `@Published selectedTenancyId: Int64?` (the current tenancy first)
  - `@Published bills: UtilityBillsGrid?` from `UtilityBills.read`
  - `func reload() async` (called on sync reload)
- Overview reuses the iPhone `PropertyView` cards (`ThisMonthCard`, `MortgageCard`, `ComingUpList`) in a two-column grid.
- Bills: rows are providers, columns are months, and cells show the stage title (`UtilityBillStage.title`) and amount. A tap selects the cell for Task 8's actions. The header counts per stage are `grid.count(stage)` with the stage titles.

- [ ] **Step 1: Write the failing tests** on the demo database:
  - `testBillsGridMatchesMacReadModel`: equals `UtilityBills.read` for the demo tenancy.
  - `testCurrentTenancySelectedFirst`.
- [ ] **Step 2–4:** run → FAIL → implement → targeted tests + full suite PASS. Add routes `pad-property-overview`, `pad-tenancies` and `pad-bills` and render them at all 4 iPad sizes: 0 wrap violations.
- [ ] **Step 5: Commit** `git commit -m "iPad: Property overview, tenancies and the bills grid"`

### Task 8 [opus]: iPad Bills, Recharges and Rent receipts actions

**Files:**
- Create: `Sources/MangoUI/Pad/Property/PadBillActions.swift`, `PadRechargesView.swift`, `PadRechargesModel.swift`, `PadRentReceiptsView.swift`, `Sources/MangoUI/Pad/PadRefusalBanner.swift`
- Test: `Tests/MangoUITests/PadPropertyActionsTests.swift`

**Interfaces — Consumes:** `DeviceWriter` (Task 3). Every action uses `writer.writeCheckingFiledYears(.property, origin:edit:scope:)` and calls these BudgetCore APIs (no new BudgetCore write logic):
- "Link invoice…" → `UtilityInvoiceIntake.attach` (origin `.documentLink`)
- "Link payment…" → `Recharges.saveInvoice` with `transactionId`, candidates from `UtilityInvoiceIntake.paymentCandidates` (`.propertyMatching`)
- "Add to recharge" → `Recharges.draftStatement` + `Recharges.setLine` (`.edit`)
- "Mark sent" → `Recharges.markSent(at: today)` (`.edit`)
- "Record payment…" → `Recharges.linkPayment` from `RechargeEmail.paymentSuggestions` (`.propertyMatching`)
- Rent receipts "Link payment…" → `RentReceiptPayments.link` from `candidateCredits` (`.propertyMatching`)

**Produces:** `PadRefusalBanner(message: String?)`, an `InlineBanner` under the acted-on row showing `error.localizedDescription` (`DeviceWriteRefusal`, `AccessDenied`, `EvidenceLinkGuard.Failure`). With `!canEdit(.property)`, actions are hidden and the banner shows `DeviceWriteCopy.viewOnly(.property)`.

- [ ] **Step 1: Write the failing tests** (demo db, `DeviceWriter` with `.demoAdmin`, plus a member-actor variant):
  - `testMarkSentMovesStageToSentToTenant`
  - `testRecordPaymentMovesStageToPaidByTenant`
  - `testAddToRechargeMovesStageToInRecharge`
  - `testLinkPaymentMovesStageToLinkedToPayment`
  - `testViewOnlyHidesActionsAndShowsCopy`
  - `testFiledYearRefusalShownInline`: the banner text equals `DeviceWriteCopy.filedYear(years: ["2023/24"])`, and the row is unchanged.
  - `testEachActionCallsAfterWriteOnce`
- [ ] **Step 2–4:** run → FAIL → implement → targeted tests + full suite PASS. Build the phone app. Add routes `pad-recharges` and `pad-rent-receipts` plus a `pad-bills-refusal` route, rendered at 4 sizes: 0 wrap violations.
- [ ] **Step 5: Commit** `git commit -m "iPad: bill, recharge and rent receipt actions through the device writer, refusals inline"`

### Task 9 [sonnet]: iPad Documents library and preview (read)

**Files:**
- Create: `Sources/MangoUI/Pad/Documents/PadDocumentsModel.swift`, `PadDocumentsView.swift`, `PadDocumentPreview.swift` (`QLPreviewController` wrapper)
- Test: `Tests/MangoUITests/PadDocumentsTests.swift`

**Interfaces — Produces:**
- `PadDocumentsModel(dbQueue:, catalog: DocumentKindCatalog, open: @escaping @Sendable (String) async throws -> URL)` (`open` = `PhoneSyncController.openDocument`).
  - List: `EvidenceDocument` rows grouped by kind title (`DocumentKindCatalog`), with a search field, and filters "All" / "Unlinked" (`EvidenceLinks.unlinkedDocuments`).
  - Detail: kind, date, period and links (titles as on the Mac: `PropertyEvidence.title` / `TaxEvidence.title`, else `"\(kind) no longer exists"`).
- Preview copy: while downloading, `"Downloading…"`. On failure, `"Couldn't download this document. Try again when you're online."`

- [ ] **Step 1: Write the failing tests:**
  - `testUnlinkedFilterMatchesEvidenceLinks`
  - `testGroupsByCatalogKindTitle`
  - `testOpenFailureShowsCopy`
- [ ] **Step 2–4:** run → FAIL → implement → PASS. Add route `pad-documents` (4 sizes, 0 wrap violations).
- [ ] **Step 5: Commit** `git commit -m "iPad: Documents library with preview"`

### Task 10 [opus]: Documents and Missing evidence edits

**Files:**
- Create: `Sources/MangoUI/Pad/Documents/PadDocumentActions.swift`, `Sources/MangoUI/Pad/Documents/PadMissingEvidenceModel.swift`, `PadMissingEvidenceView.swift`, `PadMissingEvidencePanel.swift`
- Test: `Tests/MangoUITests/PadDocumentActionsTests.swift`

**Interfaces — Consumes:** `DeviceWriter`. The Mac APIs:
- "Link to…" → `EvidenceLinks.link` inside `EvidenceLinkGuard.checked` (`.documents`, `.documentLink`)
- "Unlink" → `EvidenceLinks.unlink` inside `EvidenceLinkGuard.checked`
- "Change kind…" → the kind write the Mac's inspector makes, inside `EvidenceLinkGuard.checked(refusal: Failure.detailsChangeFiledYear)` (`.documents`, `.edit`)
- Missing evidence:
  - the list is the Mac's `MissingEvidenceViewModel.checklist` logic, moved to BudgetCore as `MissingEvidence.checklist(db:period:propertyId:taxFiguresOnly:requirements:)` if it is App-only today; the Mac then calls the moved function
  - the side panel shows `MissingEvidenceDetail.attached` + `suggestions`
  - "Link" → `MissingEvidence.link(db:documentId:to:actor:)` (`.documents`, `.documentLink`)
  - waivers and requirement edits stay on the Mac (no iPad control)

- [ ] **Step 1: Write the failing tests:**
  - `testLinkFromPanelClearsShortfall`
  - `testUnlinkFromFiledYearTransactionRefusedInline`: banner `"Links not changed: this would change the filed 2022/23 return."`
  - `testChangeKindRefusedInlineWhenItMovesFiledYear`: `"Details not saved: …"`
  - `testMemberWithoutDocumentsEditSeesViewOnly`: `DeviceWriteCopy.viewOnly(.documents)`
  - `testChecklistSameAsMac`: the moved function gives the same items as before on the demo db.
- [ ] **Step 2–4:** run → FAIL → implement → targeted tests + full suite + Mac build (if the checklist moved) + phone build PASS. Add routes `pad-missing-evidence` and `pad-document-refusal` (4 sizes, 0 wrap violations).
- [ ] **Step 5: Commit** `git commit -m "iPad: link, unlink and change kind; Missing evidence with its side panel"`

### Task 11 [sonnet]: iPad fit pass and iPhone regression

**Files:** only the `Sources/MangoUI/Pad/*` views the report names.

- [ ] **Step 1: Run** `scripts/render-phone-snapshots.sh $S8/snaps-pad --device ipad` (every `pad-*` route at 4 sizes) and the iPhone run (every phone route).
- [ ] **Step 2:** Fix every wrap or truncation in a figure on iPad. The iPhone report must be identical to `main`'s (no new violations).
- [ ] **Step 3: Run** the full suite and the phone build → PASS.
- [ ] **Step 4: Commit** `git commit -m "iPad: every screen fits 11-inch and 13-inch, portrait and landscape"`

---

## Controller-only (after Task 11, not subagents)

- Whole-branch review. Run `scripts/check-actor-writes.sh`, `scripts/build-core-ios.sh` and the Mac build. Merge to `main`, run `xcodegen` in the main checkout, then `scripts/install-app.sh` (memory: auto-install).
- **CloudKit Production schema: no additions.** No record type, field or index changes. A participant's permission lives on the `CKShare`.
- **What the user does:**
  1. In the installed Mac app, open Settings ▸ Household and press "Let <name> make changes". This upgrades the real share, so it is the user's own action. The status then shows `editsAllowed`, or the blockers to clear first.
  2. Upload a new TestFlight build: universal iPhone + iPad, `CURRENT_PROJECT_VERSION` bumped, via `scripts/archive-phone.sh`. The upload needs the user's go.
  3. Install it on the member's iPad and on the admin's iPad.
