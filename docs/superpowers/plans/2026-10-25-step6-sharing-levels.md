# Build step 6: sharing levels, private zones and real sync — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (chosen) to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** every account knows its owner and sharing level; records below Everything live only in the owner's sealed `private-<person>` zone while the household zone gets stubs and summaries; level changes move records both ways; Layer 2 permissions are stored, checked at every write and re-validated on the Mac; and the Mac's real database is turned on for sync (Production) through a backed-up, resumable flow, after which a TestFlight iPhone pulls the household zone and the admin's private zone.

**Architecture:**
- **Ownership and levels are data** (`account.ownerPersonId`, `account.sharingLevel`, `personSharing`), synced in the household zone; the ownership sheet writes them once, on the Mac, admin only.
- **Routing is one pure BudgetCore function.** `SyncZoneRouter` decides, at push time, each record's zone (and what it omits) from the database's facts. `syncRecord.zone` becomes "where the record last went": when the router disagrees, the push saves the record in the new zone and leaves a sealed *move marker* in the old one. A guard re-routes every record of every save just before the transport sees it and throws on any disagreement, so nothing below Everything can reach `household`, even in a retried batch.
- **The engine syncs a zone set** (household + the viewer's own private zone), each zone with its own key from the key store (R15 bootstrap per zone). The member's private zone is never in the admin's set.
- **Summaries are synced tables** (`accountBalancePoint`, `accountSummaryMonth`) rebuilt by the owning device before each push, with name-derived UUIDs so they are deterministic; readers use them through `ActualsSource` for accounts the viewer can't see in full.
- **Permissions:** `AccessPolicy` + `memberPermission` (defaults when absent). Writes run through `ActorWrite.perform(actor, area, origin)`, which checks, then stamps the writer and the origin that the tracking triggers copy into `syncRecord.origin`; the payload carries both; the Mac's apply re-validates and reverts.
- **Turning on sync** is a BudgetCore state machine (`SyncTurnOn`) driven by a Mac sheet; `SyncActivation` allows the real database only once that flow has started.

**Tech Stack:** Swift 6, GRDB 6.29, SwiftUI (macOS 26, iOS 26), CloudKit (`CKDatabase` operations, R11), CryptoKit (R15), XCTest, XcodeGen.

**Spec:**
- `docs/superpowers/specs/2026-10-25-sharing-levels-design.md` (binding, all of it, §10 above all).
- `docs/superpowers/specs/2026-10-22-sync-and-access-design.md` §3 (zones, hub, §3.1), §4 (identity, R14, R15), §5 (behaviour, R12/R13), §6 (levels, summaries, permissions, UI), §8 (migration of today's database), §9 (security), §12 (test plan).
- Style and earlier rulings: `docs/superpowers/plans/2026-10-24-step4-iphone-read-only.md`.

## Global Constraints

- **Logic in BudgetCore.** Routing, summaries, levels, permissions, revalidation, turn-on stages and every copy string live in `Sources/BudgetCore` (tested there); `App/`, `Phone/` and `MangoUI` only call them. `scripts/build-core-ios.sh` stays green.
- **Records sealed, exactly `sealed` + `keyId`** (R15) in every zone, move markers and `accountDetails` included; each zone sealed under its own key (`SyncKeyStore` per zone name); only the owner's devices hold a private zone's key.
- **Nothing below Everything in `household`, ever** (spec §5 anti-goal 1): the router decides, the guard (`SyncZoneGuard`) checks every record of every save, and every new sync test runs over `ZoneAuditingTransport`.
- **No personal data in the repo:** account names, the ownership mapping and the joint account are entered in the app (or passed to tools at run time); tests and demo use synthetic data.
- **Filed SA returns 2020/21–2024/25 never change.** All existing filed-year guards apply to every actor and to every apply; a level change writes no data row.
- **Real database:** never written by a subagent; never without a timestamped backup, the user's go and the app quit (tools); the in-app turn-on flow makes its own backup first. Subagents never touch the real DB, the Keychain, iCloud, the installed app or the user's screen.
- **Tests are synthetic:** `TestDatabase.migrated()` / `TestDatabase.demo()` (Tests/TestSupport), `FakeCloud`, `InMemorySyncKeyStore`; two simulated people through `TwoPersonHousehold` (Task 5).
- **Sync schema:** `SyncSchema.version` 7 → **8**, once (Task 1), with `SyncChangeTrackerTests.pinnedHash` re-pinned; migrations append-only, each guarded so a second run is a no-op.
- **Copy rules:** "Mango"; levels shown as "Everything", "Category totals", "Balance only", "Hidden"; no figure wraps or truncates at 1100×700 (Mac) and at default and `xxxLarge` (iPhone); edits save only on Save.
- **Commands** (`S6=/private/tmp/claude-501/-Users-pablo-dimenza-Documents-Code-budget/5fac4f61-c0c9-436b-881b-aebe445aa967/scratchpad/build-s6`; `swift test` needs a scratch path outside `~/Documents` because of iCloud CodeSign):
  - targeted: `swift test --scratch-path $S6 --filter '<Tests>'`
  - full suite, once at the end of each task: `swift test --scratch-path $S6 --parallel`
  - UI fix rounds: `scripts/render-snapshots.sh $S6/snaps --quick --routes <a,b> --size 1100x700`; the full harness once before merge.
  - before merge: `xcodegen generate && xcodebuild -project Mango.xcodeproj -scheme Mango -configuration Debug -derivedDataPath $S6/dd CODE_SIGNING_ALLOWED=NO build` and `scripts/build-phone.sh`.
- **At most 2 building agents at once.** Fix rounds run targeted tests only.
- **Controller-only steps** (Task 14): anything touching CloudKit Production, the Keychain, the real database, the installed app or TestFlight is done by the controller with the user, never by a subagent.

## Review Focus

1. **An owner device receives the two halves of a move in either order** (household marker before or after the private save, also across pulls). Expect the local row to stay, with no transient delete and so no cascade loss of its links. Task 5: `testOwnerDeviceKeepsAMovedRecordWhicheverZoneArrivesFirst`.
2. **A shared record that points at a private one** (a transfer between a private and a shared account; a document link to a private transaction; a property-category transaction whose `importBatch` is private; a rent payment pinned to a private account's transaction). Expect the member's device to end with an empty `syncStaging`, no dangling references, and the shared side visible. Task 4: `testHouseholdNeverReferencesAPrivateRecord`; Task 5: `testMemberDeviceHasNoStagedOrphansAfterFullPull`.
3. **A level change interrupted mid-upload** (the network drops after the private save, before the household marker). Expect the next push to finish the move; at no point a readable household copy after the marker lands; nothing duplicated. Task 8: `testInterruptedLevelChangeResumesWithoutStaleCopy`.
4. **A member edit that mixes a permitted and an unpermitted field** (note on a property-category transaction plus the amount). Expect the note kept, the amount reverted to the server's previous value, one log line naming the person and "Budget & accounts". Task 9: `testMixedEditKeepsPermittedFieldAndRevertsTheOther`.
5. **Turning on sync where iCloud Keychain already holds a household key under the real scope** (left by an earlier test) **or after the app quit mid-upload.** Expect a refusal that explains it in the first case, and in the second the sheet reopening at "Uploading" and finishing from where it stopped, with no second key. Task 12: `testTurnOnRefusesWhenAStrayHouseholdKeyIsHeld`, `testTurnOnResumesAfterQuit`.

---

### Task 1: Ownership, levels and summary storage; sync schema 8

**Files:**
- Create: `Sources/BudgetCore/Access/SharingLevel.swift`, `Sources/BudgetCore/Access/SharingMigration.swift`, `Sources/BudgetCore/Access/AccountSummaryRows.swift`
- Modify: `Sources/BudgetCore/Models/Account.swift` (two properties), `Sources/BudgetCore/Database/DatabaseManager.swift` (register `registerSharingMigration` last), `Sources/BudgetCore/Sync/SyncSchema.swift` (entries, unique keys, `localOnlyTables`, version 8), `Sources/BudgetCore/Sync/SyncChangeTracker.swift` (triggers stamp `origin`), `Sources/BudgetCore/Sync/SyncRecordStore.swift` (`derivedUUID`), `Sources/BudgetCore/Sync/SyncTables.swift` (`SyncRecordRow.origin`)
- Test: `Tests/BudgetCoreTests/SharingStorageTests.swift`; re-pin in `Tests/BudgetCoreTests/SyncChangeTrackerTests.swift`

**Interfaces:**
- Produces:
  - `public enum SharingLevel: String, Codable, CaseIterable, Comparable, Sendable { case hidden, balanceOnly, categoryTotals, everything }` (order low → high), `public var title: String` ("Hidden", "Balance only", "Category totals", "Everything").
  - `public enum TaxIncomeLevel: String, Codable, CaseIterable, Sendable { case everything, hidden }`.
  - `Account.ownerPersonId: Int64?` (nil = joint) and `Account.sharingLevel: SharingLevel` (default `.everything`).
  - `public struct PersonSharing: Codable, FetchableRecord, MutablePersistableRecord { id: Int64?; personId: Int64; taxIncomeLevel: TaxIncomeLevel; ownershipConfirmedAt: Date? }` (table `personSharing`; `ownershipConfirmedAt` is set on the admin's person row by the ownership sheet).
  - `public struct AccountBalancePoint: Codable, FetchableRecord, MutablePersistableRecord { id: Int64?; accountId: Int64; payMonth: String /* "YYYY-MM" or "current" */; date: Date; balanceMinorUnits: Int }` and `public struct AccountSummaryMonth { id: Int64?; accountId: Int64; payMonth: String; categoryId: Int64?; amountMinorUnits: Int; transactionCount: Int }`.
  - `SyncRecordStore.derivedUUID(_ name: String) -> String` (the `builtInCategoryUUID` algorithm generalised; that function now calls it).
  - `SyncChangeTracker.setWriter(_ appUserUuid: String?, origin: WriteOriginRaw?, db:)` where `public typealias WriteOriginRaw = String` (Task 2 gives the enum).
- Migration `sharingLevels` (one migration; every statement guarded by `db.columns(in:)` / `tableExists`, so a second run changes nothing):
  - `account`: `ownerPersonId INTEGER REFERENCES person(id) ON DELETE RESTRICT`, `sharingLevel TEXT NOT NULL DEFAULT 'everything' CHECK (sharingLevel IN ('everything','categoryTotals','balanceOnly','hidden'))`. No existing value changes: every account stays joint/Everything until the ownership sheet.
  - `personSharing(id PK, personId INTEGER NOT NULL UNIQUE REFERENCES person(id) ON DELETE CASCADE, taxIncomeLevel TEXT NOT NULL DEFAULT 'everything' CHECK IN ('everything','hidden'), ownershipConfirmedAt DATETIME)`.
  - `memberPermission(id PK, appUserId INTEGER NOT NULL REFERENCES appUser(id) ON DELETE CASCADE, area TEXT NOT NULL, level TEXT NOT NULL CHECK (level IN ('none','view','edit')), UNIQUE(appUserId, area))`.
  - `accountBalancePoint(id PK, accountId INTEGER NOT NULL REFERENCES account(id) ON DELETE CASCADE, payMonth TEXT NOT NULL, date DATE NOT NULL, balanceMinorUnits INTEGER NOT NULL, UNIQUE(accountId, payMonth))`.
  - `accountSummaryMonth(id PK, accountId INTEGER NOT NULL REFERENCES account(id) ON DELETE CASCADE, payMonth TEXT NOT NULL, categoryId INTEGER REFERENCES category(id) ON DELETE CASCADE, amountMinorUnits INTEGER NOT NULL, transactionCount INTEGER NOT NULL, UNIQUE(accountId, payMonth, categoryId))`.
  - Local: `syncRecord.origin TEXT`, `syncWriter.origin TEXT`; table `syncZoneMove(uuid TEXT NOT NULL, zone TEXT NOT NULL, tableName TEXT NOT NULL, systemFields BLOB, pending INTEGER NOT NULL DEFAULT 1, PRIMARY KEY(uuid, zone))` (move markers, Task 5); `syncCompanion(recordType TEXT NOT NULL, uuid TEXT NOT NULL, zone TEXT NOT NULL, systemFields BLOB, changeTag TEXT, PRIMARY KEY(recordType, uuid))` (Task 5); `syncAccessRevert(id PK, at DATETIME NOT NULL, writerAppUserUuid TEXT, area TEXT NOT NULL, tableName TEXT NOT NULL, uuid TEXT NOT NULL, fields TEXT NOT NULL)` (Task 9).
- `SyncSchema`: `account` gains synced `ownerPersonId` (FK person), `sharingLevel`; new entries after `appUser`: `personSharing` (`personId`, `taxIncomeLevel`, `ownershipConfirmedAt`; FK person), `memberPermission` (`appUserId`, `area`, `level`; FK appUser); after `category`: `accountBalancePoint`, `accountSummaryMonth` (FK account, category). Unique keys: `personSharing[personId]` identity, `memberPermission[appUserId, area]` identity, `accountBalancePoint[accountId, payMonth]` identity, `accountSummaryMonth[accountId, payMonth, categoryId]` identity. `localOnlyTables` += `syncZoneMove`, `syncCompanion`, `syncAccessRevert`. Version 8.
- Triggers: `touch()` also sets `syncRecord.origin = (SELECT origin FROM syncWriter WHERE id = 1)`.

- [ ] **Step 1: Write the failing tests:** `testMigrationAddsColumnsWithEverythingAndNoOwner` (a `migrate(upTo:)` pre-step-6 database with three accounts migrates; every account `ownerPersonId == nil`, `sharingLevel == .everything`, every other column byte-identical); `testSharingMigrationRunsTwiceWithoutChange` (run the migration body again on a migrated db: no error, `PRAGMA table_info` identical); `testLevelCheckRejectsUnknownValue`; `testDerivedUUIDIsStableAndV4Shaped` (`derivedUUID("x") == derivedUUID("x")`, version digit 4, variant in 89ab; `builtInCategoryUUID` unchanged for "salary"); `testTriggersStampOrigin` (`setWriter("u1", origin: "import")`, insert a transaction → `syncRecord.origin == "import"`, `modifiedBy == "u1"`). Re-pin `pinnedHash` for version 8 (the comment names version 8).
- [ ] **Step 2: Run** `swift test --scratch-path $S6 --filter 'SharingStorageTests|SyncSchemaTests|SyncChangeTrackerTests|SyncReferenceClassificationTests'`. Expected: FAIL (types and columns missing).
- [ ] **Step 3: Implement** the files and modifications above.
- [ ] **Step 4: Run** the filter, then the full suite. Expected: all pass (schema classification tests name nothing unlisted).
- [ ] **Step 5: Commit** "Sharing storage: account owner and level, personSharing, memberPermission, summary tables; sync schema 8 with write origin".

### Task 2: Access policy, actors and write origins

**Files:**
- Create: `Sources/BudgetCore/Access/AccessPolicy.swift`, `Sources/BudgetCore/Access/ActorWrite.swift`, `Sources/BudgetCore/Access/AccessAreaMap.swift`
- Test: `Tests/BudgetCoreTests/AccessPolicyTests.swift`

**Interfaces:**
- Consumes: Task 1 tables, `SyncChangeTracker.setWriter(_:origin:db:)`.
- Produces:
  - `public enum AccessAction: Sendable { case view, edit }`; `public enum PermissionLevel: String, Codable, Comparable, Sendable { case none, view, edit }`.
  - `public enum AccessArea: Hashable, Sendable { case budgetAndAccounts, property, forecast, tax(personUuid: String), documents, import, rulesAndCategories, householdSettings }` with `public var storageKey: String` ("budgetAndAccounts", …, "tax:<personUuid>") and `init?(storageKey:)`; `public var title: String` ("Budget & accounts", "Property", "Forecast", "Tax", "Documents", "Import", "Rules & categories", "Household settings").
  - `public struct MemberPermission: Codable, FetchableRecord, MutablePersistableRecord { id: Int64?; appUserId: Int64; area: String; level: PermissionLevel }`.
  - `public enum MemberPermissions { public static func defaultLevel(_ area: AccessArea, isAdmin: Bool) -> PermissionLevel; public static func ensureDefaults(appUserId: Int64, db: Database) throws }` — admin `.edit` everywhere; member `.edit` for `.documents`, `.import`, `.property`; `.view` for every other area (including each `.tax`). `ensureDefaults` writes the member's rows for the fixed areas and one `.tax` row per person; it never overwrites an existing row.
  - `public struct AccessActor: Equatable, Sendable { appUserId: Int64; appUserUuid: String; personId: Int64; isAdmin: Bool; public static func load(appUserId: Int64, db: Database) throws -> AccessActor }`; `public static let hub: AccessActor`-style construction is **not** provided: hub jobs use the admin's actor (`AccessActor.admin(db:)`).
  - `public enum AccessPolicy { public static func can(_ actor: AccessActor, _ action: AccessAction, _ area: AccessArea, db: Database) throws -> Bool; public static func canSetLevel(_ actor: AccessActor, accountId: Int64, db: Database) throws -> Bool }` — stored row, else default; `canSetLevel` is true only when `account.ownerPersonId == actor.personId` (joint: nobody; spec "Owner rule").
  - `public enum WriteOrigin: String, Codable, Sendable { case edit, `import`, propertyMatching, documentLink, system }`.
  - `public struct AccessDenied: Error, Equatable, LocalizedError { area: AccessArea }` ("You can't change <area title> in this household.").
  - `public enum ActorWrite { public static func perform<T>(_ actor: AccessActor, area: AccessArea, origin: WriteOrigin = .edit, db: Database, _ body: () throws -> T) throws -> T }` — checks `can(.edit)` (throws `AccessDenied`), sets `syncWriter(appUserUuid, origin)` for the body, restores the previous writer and origin after it (also on throw). Nested calls keep the outer origin unless the inner one is not `.edit`.
  - `public enum AccessAreaMap { public static func area(table: String, origin: WriteOrigin?, changedFields: Set<String>, row: [String: SyncValue], db: Database) throws -> AccessArea?; public static func isOwnerOnly(table: String, fields: Set<String>) -> Bool }` — the §10 rule, by origin first: `.import` → `.import`; `.propertyMatching` → `.property`; `.documentLink` → `.documents`; else by table: account, transaction_, transferLink, balanceSnapshot, balanceSnapshotArchive, payPeriod, payMonthClose → `.budgetAndAccounts`; category, categoryGroup, rule, importRule, taxExpenseTypeMap → `.rulesAndCategories`; forecastGroup, forecastEntry, plannedOccurrenceException, scenario, scenarioApplication → `.forecast`; property*, tenancy*, rentReceipt*, utility*, recharge*, mortgageRateOverride, interestIndexValue, propertyCheckDecision, evidenceRequirement, evidenceWaiver → `.property` (evidence rules are property records' requirements; documents stay `.documents`); document, documentLink, customDocumentKind → `.documents`; importRun, importBatch, importChange, importRunFile, importProfile, importWaitingFile → `.import`; employment, employmentIncome, benefitInKind, otherIncome, pensionContribution, hmrcPayment, taxYear, taxFiledBox, taxYearSplit, taxManualItem, taxPolicyReceipt, taxNotClaimed, taxTransactionOwner → `.tax(person of the row)` (`personId`, or the owning record's person; `.tax` of the admin when the row names no person); hmrcRate, taxAttributionRule, rechargeNettingRule, exchangeRateSetting, person, appUser, memberPermission, personSharing → `.householdSettings`. Exception (§10): on `transaction_` with changed fields ⊆ {`categoryId`, `note`, `status`, `categorizedBy`} the area is `.property` when the account is a property-linked account at Everything or the row's category (before or after) is a property category. `accountBalancePoint`, `accountSummaryMonth`, and `account.ownerPersonId`/`account.sharingLevel` are owner-only (`isOwnerOnly`), judged by `AccessPolicy.canSetLevel`.

- [ ] **Step 1: Write the failing tests:** `testEveryAreaAndLevelForAdminAndMember` (table over all areas × {admin, member} × {view, edit} against the defaults above); `testStoredRowOverridesDefault` (member `.forecast` row `none` → `can(view)` false); `testOnlyTheOwnerSetsALevel` (admin on member-owned: false; admin on joint: false; owner: true); `testEverySyncedTableHasAnArea` (for each `SyncSchema.tables` name, `area(...)` or `isOwnerOnly` answers; fails naming the table); `testPropertyNoteOnPropertyCategoryTransactionIsProperty` and `testAmountEditIsBudgetAndAccounts`; `testPerformRefusesWithoutEditAndRestoresWriter` (member actor, `.budgetAndAccounts` → `AccessDenied`; `syncWriter` unchanged after); `testPerformStampsOriginOnWrittenRows` (`.import` origin → `syncRecord.origin == "import"`); `testEnsureDefaultsWritesOnceAndKeepsChanges`.
- [ ] **Step 2: Run** `swift test --scratch-path $S6 --filter AccessPolicyTests`. Expected: FAIL.
- [ ] **Step 3: Implement** the three files.
- [ ] **Step 4: Run** the filter, then the full suite. Expected: pass.
- [ ] **Step 5: Commit** "Access: AccessPolicy, member permission defaults, AccessActor, ActorWrite with write origins, area map".

### Task 3: Ownership sheet logic and level setting (BudgetCore)

**Files:**
- Create: `Sources/BudgetCore/Access/SharingSetup.swift`, `Sources/BudgetCore/Access/SharingLevels.swift`, `Sources/BudgetCore/Access/SharingCopy.swift`
- Modify: `Sources/BudgetCore/NetWorth/AccountEditing.swift` (`add` sets the creating person as owner and the default level once ownership is confirmed)
- Test: `Tests/BudgetCoreTests/SharingSetupTests.swift`

**Interfaces:**
- Consumes: Tasks 1–2.
- Produces:
  - `public enum SharingDefaults { public static func level(ownerPersonId: Int64?, isPropertyLinked: Bool) -> SharingLevel }` — joint → `.everything`; property-linked (a `propertyAccount` row) → `.everything`; personal → `.balanceOnly`. Tax/income: `.everything` for every person.
  - `public enum SharingSetup { public struct Row: Equatable, Identifiable { id: Int64 /*accountId*/; displayName: String; bankName: String?; isPropertyLinked: Bool; owner: Owner; level: SharingLevel }; public enum Owner: Equatable { case person(Int64), joint }; public static func isConfirmed(db:) throws -> Bool; public static func proposal(admin: AccessActor, db:) throws -> [Row]; public static func save(_ rows: [Row], admin: AccessActor, db:, now: Date) throws }` — proposal: owner = the admin for every account, level from `SharingDefaults`; `save` (refused unless `admin.isAdmin` and not yet confirmed) writes every account's owner and level, a `personSharing` row per person (`.everything`), the admin row's `ownershipConfirmedAt = now`, and `MemberPermissions.ensureDefaults` for every non-admin app user, in the caller's one transaction, through `ActorWrite.perform(admin, area: .householdSettings)`. A joint row with a level other than Everything is refused (`SharingError.jointMustBeEverything`).
  - `public enum SharingLevels { public static func set(_ level: SharingLevel, accountId: Int64, actor: AccessActor, db:) throws -> Change; public static func blockers(accountId: Int64, to level: SharingLevel, db:) throws -> [Blocker]; public static func setTaxIncomeLevel(_ level: TaxIncomeLevel, personId: Int64, actor: AccessActor, db:) throws }` with `public struct Change: Equatable { from: SharingLevel; to: SharingLevel; isLowering: Bool }` and `public enum Blocker: Equatable { case propertyLink(propertyName: String), propertyOrTaxRows(count: Int), referencedBy(table: String, count: Int) }` — only `.hidden` has blockers (property link, a property-category transaction or a §10 property/tax row pointing at the account's transactions, an `importRule` / `evidenceRequirement` naming the account). `set` throws `SharingError.notOwner`, `.jointMustBeEverything`, `.blocked([Blocker])`; `setTaxIncomeLevel(.hidden)` throws `SharingError.notAvailableYet`. Moving the records is Task 8's.
  - `public enum SharingCopy` (exact strings): sheet title "Who owns each account?"; sheet note "Every account is yours unless you mark it Joint. Joint accounts are always shared in full."; owner choices "<admin display name>" and "Joint"; badge `badge(_ level: SharingLevel) -> String?` ("Shared as category totals", "Shared as balance only", "Not shared", nil for Everything); `lowerWarning(otherName:)` "Lowering the level stops sharing from now on. \(otherName) may already have a copy of this account's transactions on their devices or in their backups, and Mango can't recall it."; `raiseNote(otherName:)` "\(otherName) will see this account's transactions and documents."; tax/income `hiddenNotAvailable` "Hidden (not available yet)"; `privateLine(account:owner:count:)` "\(account) (\(owner)) · \(count) transaction(s) · details private" ("1 transaction", "7 transactions"); `netWorthNote` "Includes everything you can see"; blocker texts "Linked to the property \(name)", "\(count) property or tax records point at its transactions", "Named by \(count) \(table description)".

- [ ] **Step 1: Write the failing tests:** `testProposalOwnsEverythingAsAdminWithDefaults` (personal → Balance only, property-linked → Everything); `testSaveWritesOwnersLevelsAndConfirmsOnce` (second save refused; `personSharing` rows `.everything`); `testJointMustBeEverything`; `testOnlyAdminSavesOwnership`; `testSetRefusesNonOwnerAndJoint`; `testHiddenBlockedByPropertyLinkAndPropertyTransactions`; `testTaxIncomeHiddenIsNotAvailableYet`; `testNewAccountAfterConfirmationIsOwnedAndBalanceOnly` (via `AccountEditing.add` with the actor's person); `testPrivateLineCopy` (1 and 7).
- [ ] **Step 2: Run** `swift test --scratch-path $S6 --filter SharingSetupTests`. Expected: FAIL.
- [ ] **Step 3: Implement.** `AccountEditing.add` gains `owner: AccessActor? = nil` (nil keeps today's behaviour: joint, Everything, used before confirmation and by tools).
- [ ] **Step 4: Run** the filter, then the full suite. Expected: pass.
- [ ] **Step 5: Commit** "Sharing set-up: ownership sheet logic, defaults, owner-only level changes, blockers for Hidden, copy".

### Task 4: The zone router and the household guard (pure BudgetCore)

**Files:**
- Create: `Sources/BudgetCore/Sync/SyncZoneRouter.swift`, `Sources/BudgetCore/Sync/SyncZoneGuard.swift`, `Tests/TestSupport/SharingFixture.swift`
- Test: `Tests/BudgetCoreTests/SyncZoneRouterTests.swift`

**Interfaces:**
- Consumes: Tasks 1, 3; `SyncSchema` (foreign keys, logical, polymorphic and JSON references).
- Produces:
  - `public enum SyncZones { public static let household = "household"; public static func privateZone(personUuid: String) -> String /* "private-" + uuid */; public static func personUuid(ofPrivateZone zone: String) -> String? }` (`SyncRecordStore.householdZone` becomes an alias of `SyncZones.household`).
  - `public struct ZoneAssignment: Equatable, Sendable { zone: String; omittedFields: [String]; companion: Companion? }` with `public struct Companion: Equatable, Sendable { recordType: String /* "accountDetails" */; zone: String; fields: [String] }`.
  - `public final class SyncZoneRouter { public init(db: Database) throws; public func assignment(table: String, localId: Int64) throws -> ZoneAssignment }` — loads the facts once (accounts' owner, level, person UUIDs, property-linked accounts, property category ids, pinned transaction ids) and memoises per record.
  - `public static let SyncZoneRouter.privateAccountColumns = ["sortCode", "accountNumber", "iban", "routingNumber", "bic", "statementMismatchMinorUnits", "statementMismatchDate", "statementMismatchClosingMinorUnits", "statementLastCheckedDate"]`.
  - `Tests/TestSupport/SharingFixture.swift`: `public struct SharingFixture { personA, personB: Int64; personAUuid: String; shared, joint, privateAccount, totals, lisbon: Int64 (account ids); propertyId: Int64; public static func build(_ db: Database) throws -> SharingFixture }` — the fixture of Step 1, ownership confirmed through `SharingSetup.save`.
  - `public enum SyncZoneGuard { public struct Violation: Error, Equatable { recordType: String; recordName: String; expected: String; actual: String; reason: String } ; public static func check(_ payloads: [SyncPayload], router: SyncZoneRouter, db: Database) throws }` — re-routes each payload's row and throws the first `Violation` when: the payload's zone isn't the router's; a household payload carries a field the router omits; a household payload references (FK, logical, polymorphic or JSON) a record the router places in a private zone. Never includes values in the error.
- Routing rules (the algorithm; `P(account)` = `privateZone(owner's person UUID)`):
  1. **Account** at Everything (or joint): `household`, nothing omitted. Below Everything and not Hidden: `household` stub omitting `privateAccountColumns`, companion `accountDetails` in `P` carrying those columns. Hidden: `P`, no companion.
  2. **Records of an account** (`transaction_`, `importBatch`, `importProfile`, `balanceSnapshot`, `balanceSnapshotArchive`, `forecastEntry` with `accountId`): Everything → `household`; else `P`.
  3. **§10 exception:** a `transaction_` of an account below Everything goes to `household` when its category is a property category (`category.groupId` in `propertyCategoryGroup`) or it is *pinned* — named by `taxPolicyReceipt`, `taxNotClaimed`, `taxTransactionOwner`, `rentReceiptPayment`, `rechargePayment`, `rechargeLine` or `utilityInvoice`. It omits `importBatchId` and travels without the batch tag (Task 5). Those property/tax tables are always `household`.
  4. **Closure:** any other record goes to the private zone of a record it references (FK, logical, polymorphic, JSON) that the router places in a private zone; otherwise `household`. (Examples: `transferLink` with either side private → that side's `P`; `plannedOccurrenceException` follows its entry; `importRun` follows its batches' account; `importChange`/`importRunFile` follow their run; `documentLink` and `evidenceWaiver` follow their entity.)
  5. **Documents** (`document`): `P` when it has at least one referrer (`documentLink` targets, `utilityInvoice.documentId`, `rechargeLine.documentId`, `importRunFile.documentId`) and every referrer is routed to the same `P`; otherwise `household`. Its `documentFile` follows it.
  6. **Summaries** (`accountBalancePoint`, `accountSummaryMonth`), `personSharing`, `memberPermission`: always `household`. **Tax and income** tables: `household` (the per-person Hidden move is deferred, spec §10).
  7. A record whose table isn't listed by any rule above is `household` only through rule 4; the test over every table pins the outcome.

- [ ] **Step 1: Write the failing tests** (`SharingFixture` on `TestDatabase.migrated()`: admin person A, member person B, accounts *Shared* (A, Everything), *Joint* (nil), *Private* (A, Balance only), *Totals* (A, Category totals), *Lisbon* (A, Everything, property-linked), one property with a category group; transactions in each; a transfer Shared↔Private; a property-category transaction on Private with a `rentReceiptPayment`; documents linked to a Private transaction only, and to both):
  - `testAccountsRouteByLevel` (Private: household stub, omitted = `privateAccountColumns`, companion zone `private-<A>`; Hidden account: `private-<A>`, no companion);
  - `testPrivateTransactionsGoPrivateAndPropertyOnesStayShared` (property-category and pinned ones: household, `omittedFields == ["importBatchId"]`);
  - `testTransferBetweenPrivateAndSharedIsPrivate`;
  - `testDocumentFollowsItsLinks` (only-private links → private; any household referrer → household);
  - `testEveryTableRoutesWithoutThrowing` (every row of every synced table in `TestDatabase.demo()`, with the demo's accounts given owner A and the fixture's levels by hand, gets an assignment);
  - `testHouseholdNeverReferencesAPrivateRecord` (for every household assignment, every reference resolves to a household record);
  - `testGuardRejectsAPrivateRecordInAHouseholdBatch`, `testGuardRejectsAnOmittedFieldInAHouseholdPayload`, `testGuardRejectsAHouseholdReferenceToAPrivateRecord`, `testGuardErrorCarriesNoValues`.
- [ ] **Step 2: Run** `swift test --scratch-path $S6 --filter SyncZoneRouterTests`. Expected: FAIL.
- [ ] **Step 3: Implement** the router (facts loaded in a handful of queries, then memoised walks; parents before children by `SyncSchema.tables` order) and the guard.
- [ ] **Step 4: Run** the filter; time the demo-wide routing (must stay under 1 s for the demo; log the figure in the commit message body). Full suite.
- [ ] **Step 5: Commit** "Zone routing: pure router (levels, §10 property exception, closure, documents, stubs) and the household guard".

### Task 5: Multi-zone engine: per-zone keys, routed push, moves, stubs and companions

**Files:**
- Create: `Sources/BudgetCore/Sync/SyncZoneMoves.swift`, `Sources/BudgetCore/Sync/ZoneAuditingTransport.swift`, `Tests/TestSupport/TwoPersonHousehold.swift`
- Modify: `Sources/BudgetCore/Sync/SyncEngineCore.swift` (zone set, per-zone keys, routed push, guard before every save, pull order), `Sources/BudgetCore/Sync/SyncTranslator.swift` (outgoing uses the router; incoming stubs, companions, markers, zone-aware deletes and tombstones), `Sources/BudgetCore/Sync/SyncPayload.swift` (fields), `Sources/BudgetCore/Sync/SyncBatch.swift` (tags only records in the run's zone), `Sources/BudgetCore/Sync/SyncDocumentFiles.swift` (file records in the document's zone, sealed with that zone's key), `Sources/BudgetCore/Sync/TransportLeaseStore.swift` (unchanged zone, household), `Sources/BudgetCore/Sync/FiledYearSyncCheck.swift` (per-zone pulls checked alike)
- Test: `Tests/BudgetCoreTests/SyncZonesEngineTests.swift`

**Interfaces:**
- Consumes: Task 4 (`SyncZoneRouter`, `SyncZoneGuard`, `SyncZones`), Task 1 local tables.
- Produces:
  - `public struct SyncViewer: Equatable, Sendable { personUuid: String?; public static let none: SyncViewer }`; `SyncEngineCore.init(..., viewer: SyncViewer = .none, revalidatesAccess: Bool = false)` (the `revalidatesAccess` flag is used in Task 9). `SyncEngineCore.zones(db:) -> [String]` = `[household]` + `privateZone(viewer)` when set; the static `zones` constant is removed.
  - `SyncPayload` gains `omittedFields: [String]?`, `origin: String?`, `movedTo: String?` (a move marker: no fields).
  - `public enum SyncZoneMoves { public static func pending(db:) throws -> [(uuid: String, tableName: String, zone: String)]; static func record(uuid:tableName:from:systemFields:db:) throws; static func acknowledge(uuid:zone:stamp:db:) throws }`.
  - `public final class ZoneAuditingTransport: SyncTransport` wrapping any transport: records every save per zone and opens each record with the test key store; `public func householdViolations(router: (String) -> ZoneAssignment?) -> [String]`; `public var savesByZone: [String: [SyncWireRecord]]`.
  - `Tests/TestSupport/TwoPersonHousehold.swift`: `public final class TwoPersonHousehold` with `cloud: FakeCloud`, `audit: ZoneAuditingTransport`, `adminKeys`, `memberKeys` (separate `InMemorySyncKeyStore`s sharing only the household key), `adminMac`, `adminPhone` (read-only, viewer A), `memberDevice` (viewer B) — each a `(db: DatabaseQueue, engine: SyncEngineCore)`; `public static func make(levels: [Int64: SharingLevel] = [:]) throws -> TwoPersonHousehold` builds `SharingFixture` on `adminMac` (levels override the fixture's); `func syncAll() async throws` (admin Mac push, then phone and member pull).
- Behaviour (decided here):
  - **Push:** for each pending change the router's assignment decides the zone; a payload whose zone differs from `syncRecord.zone` is a move — the record is saved in the new zone (no system fields unless `syncZoneMove` holds a marker stamp there), a marker (`movedTo: newZone`) is saved over the old copy (its stamp from `syncRecord`), `syncRecord.zone` updated after both saves are acknowledged; a `documentFile` in the old zone is deleted outright and re-sealed in the new zone. A household stub sends its fields minus `omittedFields`; its companion `accountDetails` (record name = the account's UUID, zone `P`) is saved alongside, stamped in `syncCompanion`. Each record is sealed with its zone's key (`householdKey(zone:create:)`); `SyncZoneGuard.check` runs on every save chunk before `transport.save` and a violation fails the push, sending nothing from that chunk.
  - **Batches:** `SyncBatch.decorate` tags a record with its run only when the record's zone equals the run's zone; manifests count only those.
  - **Pull:** the zone set, private zones first, then household; zones the device doesn't pull are never fetched. Incoming rules: a marker whose `movedTo` is in this device's zone set is ignored; otherwise the row is deleted with tracking off and **no tombstone** (a later move back applies normally). A deletion applies only when the local `syncRecord.zone` equals the zone it came from. A save from zone Z sets `syncRecord.zone = Z`; a save whose tombstone's zone differs is taken (a move). A stub's omitted fields are left as they are when this device pulls the owner's private zone and set to NULL otherwise. `accountDetails` applies its columns to the account with that UUID (staged until the account exists), field by field with the carried clocks.
  - **Read-only devices** fetch their zone set, create nothing, and treat a missing private zone as "nothing yet".

- [ ] **Step 1: Write the failing tests** (all over `TwoPersonHousehold`; every test ends with `XCTAssertEqual(h.audit.householdViolations(...), [])`):
  - `testPrivateAccountUploadsToItsOwnZoneWithItsOwnKey` (the Private account's transactions only in `private-<A>`, sealed with a key id different from household's; the member's key store never holds it);
  - `testMemberSeesStubSummaryZoneOnly` (member's db: the Private account row with every `privateAccountColumns` value NULL, none of its transactions, its property-category transaction present);
  - `testAdminPhoneGetsEverything` (phone's Private account has the companion's columns and every transaction);
  - `testMemberNeverFetchesTheAdminsPrivateZone` and `testAdminNeverFetchesTheMembersPrivateZone` (`FakeCloud.calls` per device);
  - `testOwnerDeviceKeepsAMovedRecordWhicheverZoneArrivesFirst` (deliver the household marker before, then after, the private save; the row and its `transferLink`/`documentLink` survive both orders);
  - `testMemberDeviceHasNoStagedOrphansAfterFullPull` (`syncStaging` empty on the member's device);
  - `testPrivateRunsHouseholdRecordsTravelUntagged` (an import into Private writing one property-category transaction: the member applies it without waiting for a batch);
  - `testGuardStopsAPushThatWouldLeak` (force a stale `syncRecord.zone` and a router bug via a test hook: the push throws `SyncZoneGuard.Violation` and FakeCloud holds nothing new);
  - `testDocumentFileReSealedOnMove`;
  - `testFiledYearCheckRunsOnPrivatePulls` (a held change in `private-<A>` is held, as in household).
- [ ] **Step 2: Run** `swift test --scratch-path $S6 --filter SyncZonesEngineTests`. Expected: FAIL.
- [ ] **Step 3: Implement** the engine, translator, batch and document changes. Keep the existing household-only behaviour byte-identical when every account is Everything (existing sync tests unchanged).
- [ ] **Step 4: Run** the filter, then `swift test --scratch-path $S6 --filter 'Sync|FieldSealing|DocumentSync|ImportLease|FiledYear'`, then the full suite and `scripts/test-core-ios.sh`. Expected: pass.
- [ ] **Step 5: Commit** "Sync zones: per-zone keys, routed push with move markers, household stubs and account details companions, zone-aware pulls, guard on every save".

### Task 6: Summaries: builder, triggers, rebuild before push

**Files:**
- Create: `Sources/BudgetCore/Access/AccountSummaryBuilder.swift`
- Modify: `Sources/BudgetCore/Access/SharingMigration.swift` (second migration `summaryDirtyTriggers`: app triggers on `transaction_`, `balanceSnapshot`, `category`, `payMonthClose`, `account` that upsert `syncState('summaries.dirty')`), `Sources/BudgetCore/Sync/SyncEngineCore.swift` (`pushAll` rebuilds first when dirty and not read-only)
- Test: `Tests/BudgetCoreTests/AccountSummaryBuilderTests.swift`

**Interfaces:**
- Consumes: Tasks 1, 4, 5; `PayCalendar.load(db:today:)`, `PayCalendar.month(containing:)`, `closeDate(of:)`, `NetWorthCalculator.balance(accountId:at:snapshots:transactions:)`.
- Produces: `public enum AccountSummaryBuilder { public struct Outcome: Equatable { inserted: Int; updated: Int; deleted: Int }; public static func rebuild(ownerPersonId: Int64, db: Database, today: Date) throws -> Outcome; public static func payMonthKey(_ month: PayMonth) -> String /* "2026-10" */; public static func identity(table: String, accountUuid: String, payMonth: String, categoryUuid: String?) -> String }`.
  - For each account owned by `ownerPersonId` below Everything and not Hidden: `accountBalancePoint` for every pay month from the account's first activity to the last closed month (balance at `closeDate`) plus `payMonth = "current"` (balance and date at its latest activity). For Category totals also `accountSummaryMonth` per (pay month, category) over its transactions **not** routed to household (the §10 exception ones are counted from their shared rows instead). Accounts at Everything or Hidden have none (stale rows deleted).
  - Rows are upserted: an unchanged value writes nothing (so nothing is queued); new rows get `syncRecord` identities `derivedUUID(identity(...))` before insert, so every owner device makes the same record names.
  - Runs inside `ActorWrite.perform(owner, area: .budgetAndAccounts, origin: .system)`.

- [ ] **Step 1: Write the failing tests:** `testBalanceOnlyPublishesPayMonthEndsAndCurrentOnly` (no daily points; values equal `NetWorthCalculator.balance` at each close date); `testCategoryTotalsExcludeSharedPropertyTransactions`; `testRebuildWithNoChangeQueuesNothing` (second run: `Outcome(0,0,0)`, `SyncChangeTracker.pending` empty); `testTwoOwnerDevicesProduceIdenticalRecords` (two copies of the same db rebuild; record names and payloads equal); `testPayCalendarShiftRebuildsMonths` (a manual close moved: affected rows updated); `testRaisingToEverythingDeletesSummaries`; `testPushRebuildsWhenDirty` (an edit marks dirty; the next push sends the changed `accountSummaryMonth`); `testRebuildOnDemoIsFast` (< 0.5 s on `TestDatabase.demo()` with two private accounts).
- [ ] **Step 2: Run** `swift test --scratch-path $S6 --filter AccountSummaryBuilderTests`. Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** the filter and the full suite.
- [ ] **Step 5: Commit** "Account summaries: deterministic balance points and category totals, rebuilt by the owner's device before each push".

### Task 7: Reading summaries: actuals, drill-down and net worth for the other person's accounts

**Files:**
- Create: `Sources/BudgetCore/Access/SharedActualsSource.swift`
- Modify: `Sources/BudgetCore/Budget/ActualsSource.swift` (protocol gains `balanceSnapshots(_:)` with a default), `Sources/BudgetCore/Dashboard/DashboardInput+Load.swift` (takes an `ActualsSource`; default `.local`)
- Test: `Tests/BudgetCoreTests/SharedActualsSourceTests.swift`

**Interfaces:**
- Consumes: Tasks 1, 3, 5, 6; `BudgetGridCalculator`, `DashboardCalculator` net worth.
- Produces:
  - `public protocol ActualsSource { func transactions(_ db: Database) throws -> [Transaction]; func balanceSnapshots(_ db: Database) throws -> [BalanceSnapshot] }` (default `BalanceSnapshot.fetchAll`).
  - `public struct SharingViewer: Equatable, Sendable { personId: Int64?; public static func load(appUserId: Int64?, db:) throws -> SharingViewer; public func seesInFull(_ account: Account) -> Bool }` — in full when Everything, joint, or owned by the viewer; nil viewer sees everything (tools, tests).
  - `public struct SharedActualsSource: ActualsSource { public init(viewer: SharingViewer) }` — transactions of accounts seen in full, plus one synthetic transaction per `accountSummaryMonth` row (negative id, `accountId`, `categoryId`, amount, date = the pay month's range end, empty description, `status` reviewed); balance snapshots of accounts seen in full plus one synthetic snapshot per `accountBalancePoint` of the others; Hidden accounts of others contribute nothing.
  - `public enum SharedActuals { public struct PrivateLine: Equatable, Identifiable { id: Int64 /*accountId*/; text: String /* SharingCopy.privateLine */; amountMinorUnits: Int }; public static func privateLines(categoryIds: Set<Int64>, from: Date, to: Date, viewer: SharingViewer, db:) throws -> [PrivateLine]; public static func isSummary(_ t: Transaction) -> Bool /* id < 0 */ }`.
  - `public static func DashboardInput.load(db:today:actuals: any ActualsSource = .local)`.

- [ ] **Step 1: Write the failing tests:** `testGridTotalsWithSummariesEqualFullData` (member viewer on `TwoPersonHousehold`'s member device vs. admin viewer on the admin Mac: every category's pay-month total equal, spec §12); `testDrillDownListsSharedThenOneLinePerPrivateAccount` (text "Private (A) · 7 transactions · details private" with the fixture's short name); `testNetWorthCountsBalanceOnlyAndTotalsButNotHidden`; `testOwnerSeesOwnAccountsInFull` (admin viewer: no synthetic rows); `testNilViewerIsToday` (same transactions as `LocalActualsSource`).
- [ ] **Step 2: Run** `swift test --scratch-path $S6 --filter SharedActualsSourceTests`. Expected: FAIL.
- [ ] **Step 3: Implement.** No calculator changes beyond the source parameter.
- [ ] **Step 4: Run** the filter and the full suite (Dashboard and BudgetGrid suites unchanged).
- [ ] **Step 5: Commit** "Shared actuals: summaries feed the budget grid, drill-down lines and net worth for accounts the viewer can't see in full".

### Task 8: Level changes move records

**Files:**
- Modify: `Sources/BudgetCore/Access/SharingLevels.swift` (`set` queues the affected records), `Sources/BudgetCore/Sync/SyncZoneMoves.swift`
- Test: `Tests/BudgetCoreTests/SharingLevelChangeTests.swift`

**Interfaces:**
- Consumes: Tasks 3–6.
- Produces: `SharingLevels.set` (Task 3 signature) now also: re-routes with a fresh `SyncZoneRouter`, queues every record whose assignment changed as a pending update (`syncPending` kind `update`, no data row touched, no field clock changed), and marks summaries dirty. `public static func affectedCount(accountId: Int64, to level: SharingLevel, db:) throws -> Int` for the sheet's warning ("Moves 1,204 records").

- [ ] **Step 1: Write the failing tests** (`TwoPersonHousehold`, audited): `testLoweringMovesRecordsOutOfHouseholdAndMemberDropsThem` (Everything → Balance only: member's db has none of the account's transactions after sync, server household holds only markers for them, private zone holds them); `testRaisingMovesThemBackAndMemberGetsThem`; `testLowerThenRaiseLeavesNoDuplicates` (record names unique across zones, row counts equal before/after on every device); `testInterruptedLevelChangeResumesWithoutStaleCopy` (`FakeCloud.failSaveOperations(after: 1)` mid-move; restore; next push completes; household has no readable copy); `testLevelChangeWritesNoDataAndKeepsFiledYears` (every data table byte-identical; `TaxRegression` figures for 2020–2024 identical on the demo); `testSummariesAppearOnLoweringAndGoOnRaising`; `testAffectedCountMatchesMoves`.
- [ ] **Step 2: Run** `swift test --scratch-path $S6 --filter SharingLevelChangeTests`. Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** the filter, the `Sync` filter and the full suite.
- [ ] **Step 5: Commit** "Level changes: lowering and raising move records between zones with markers; nothing written to data; filed years untouched".

### Task 9: Permissions enforced: write paths and the Mac's re-validation

**Files:**
- Create: `Sources/BudgetCore/Access/AccessRevalidation.swift`, `scripts/check-actor-writes.sh`
- Modify: `Sources/BudgetCore/Sync/SyncTranslator.swift` (`applySave` asks `AccessRevalidation` when the engine `revalidatesAccess`), `Sources/BudgetCore/Sync/SyncEngineCore.swift` (passes the flag), `Sources/BudgetCore/DocumentImport/ImportSession.swift` (confirm/undo take `actor: AccessActor` and run in `ActorWrite.perform(actor, area: .import, origin: .import)`), the property matchers' public entry points (`RentCreditEvidence.applyAdvices`, `RechargeTrackerRebuild.apply`, `RentReceiptPDFs.apply`: `actor` + `origin: .propertyMatching`), evidence linking entry points in `Sources/BudgetCore/Evidence/` (`origin: .documentLink`), `App/AppEnvironment.swift` (`func write<T>(_ area: AccessArea, origin: WriteOrigin = .edit, _ body: (Database) throws -> T) async throws -> T` using the signed-in user's actor), every App data write (the ~65 `dbQueue.write` sites in the files listed by `grep -rln "dbQueue.write\|\.write {" App`) moved onto `environment.write(area:)`
- Test: `Tests/BudgetCoreTests/AccessRevalidationTests.swift`

**Interfaces:**
- Consumes: Tasks 1, 2, 5.
- Produces:
  - `public enum AccessRevalidation { public enum Verdict: Equatable { case allowed; case revert(fields: [String], area: AccessArea, writerAppUserUuid: String?) }; static func verdict(for payload: SyncPayload, local: [String: SyncValue]?, db: Database) throws -> Verdict; public static func recentReverts(limit: Int, db:) throws -> [String] }` — judges only the fields the merge would take from the incoming side, each by its clock's writer (`clock.by`) and the payload's `origin`; area from `AccessAreaMap`; owner-only fields need `canSetLevel`. A new record without permission is reverted by deleting it locally and queuing the delete. Reverted fields are re-stamped here (clock = now, writer = the Mac's user) so the Mac's values win on every device. Each revert writes a `syncAccessRevert` row; `recentReverts` renders "Reverted a change by \(displayName): no permission for \(area.title)". The os log line names no person and no value.
  - `scripts/check-actor-writes.sh`: exits non-zero listing `App/` lines that call `dbQueue.write` / `.write {` outside `AppEnvironment.swift`, `App/Snapshots/`, `App/Auth/` (sign-in bookkeeping) and `App/Sync/`; prints `actor writes OK` otherwise.

- [ ] **Step 1: Write the failing tests** (`TwoPersonHousehold`; the member device writes through `ActorWrite.perform` with the member's actor for permitted changes, and for an unpermitted one sets the writer directly — a modified client):
  - `testMemberImportIsKept` (origin import);
  - `testMemberRechargeMatchIsKept` (origin propertyMatching);
  - `testMemberNoteOnPropertyCategoryTransactionIsKept`;
  - `testMemberAmountEditIsRevertedAndLogged` (the Mac's value back on every device after the next round; `recentReverts` = ["Reverted a change by B: no permission for Budget & accounts"]);
  - `testMixedEditKeepsPermittedFieldAndRevertsTheOther`;
  - `testMemberCannotChangeTheAdminsLevel` (owner-only field reverted);
  - `testMemberNewCategoryIsRemoved` (rules & categories View: the new row deleted and the delete sent);
  - `testRevalidationNeverTouchesFiledYears` (a reverted field on a 2023 transaction goes through `FiledYearSyncCheck` unchanged);
  - `testPerformDeniesAtTheSource` (`ImportSession` confirm with a member actor lacking Import → `AccessDenied`, nothing written).
- [ ] **Step 2: Run** `swift test --scratch-path $S6 --filter AccessRevalidationTests`. Expected: FAIL.
- [ ] **Step 3: Implement** BudgetCore, then the App call sites (each picks its area from `AccessAreaMap`'s table list; imports `.import`/`.import`, property matching `.property`/`.propertyMatching`, linking `.documents`/`.documentLink`).
- [ ] **Step 4: Run** the filter, the full suite, `scripts/check-actor-writes.sh` (prints `actor writes OK`), and the Mac Debug `xcodebuild`.
- [ ] **Step 5: Commit** "Permissions: write paths take the actor and origin; the Mac re-validates incoming changes and reverts what wasn't allowed".

### Task 10: Mac UI: Settings ▸ Sharing, ownership sheet, badges, summary rows

**Files:**
- Create: `App/Settings/SharingSettings.swift`, `App/Settings/OwnershipSheet.swift`, `App/Settings/LevelChangeConfirm.swift`, `App/DesignSystem/SharingBadge.swift`, `Sources/BudgetDemo/DemoSharing.swift`, `App/Snapshots/SharingSnapshots.swift`
- Modify: `App/Settings/SettingsView.swift` (pane `.sharing`, "Sharing", `person.2.badge.key`), `App/Accounts/AccountsView.swift` (badge after the name), `App/Budget/BudgetCellPanel.swift` (private lines after the shared transactions), `App/Budget/BudgetGridViewModel.swift` and `App/Dashboard/DashboardViewModel.swift` (load through `SharedActualsSource(viewer:)`), `App/Dashboard/NetWorthCard.swift` (`SharingCopy.netWorthNote` as a caption when any account is summarised or hidden for the viewer), `Sources/BudgetDemo/DemoDatabase.swift` (calls `DemoSharing.apply` at the end of the build)
- Test: snapshot routes; `Tests/BudgetCoreTests/DemoDatabaseTests.swift` (`testDemoSharingKeepsAdminFigures`, `testDemoRoutesWithoutHouseholdViolations`: `SyncZoneGuard` accepts a push of the whole demo into `FakeCloud`)

**Interfaces:**
- Consumes: Tasks 3, 6, 7, 8.
- Produces:
  - `DemoSharing.apply(db:)`: ownership confirmed for demo person A (admin app user created if the demo has none: display name "A", no credential), one demo account joint, one Balance only, one Category totals, the rest by default; summaries rebuilt. The demo's figures for viewer A are unchanged (test `testDemoSharingKeepsAdminFigures`).
  - Settings ▸ Sharing (admin, before confirmation): the explanation and a "Set owners…" button opening `OwnershipSheet` (a table: account, bank, owner picker [admin's name | Joint], level picker [joint locks to Everything], Save/Cancel; Save is enabled from the start, since the proposal is valid as it is). After confirmation: "My accounts" (one row per own account: name, bank, level `Picker`; changing it opens `LevelChangeConfirm` with `affectedCount`, `lowerWarning`/`raiseNote`, Cancel/Change; a blocked Hidden shows the blockers and no Change button), "Joint accounts" (read-only, Everything), "My tax years and income" (Everything; Hidden shown disabled as `hiddenNotAvailable`). A member signed in sees only their own section and no ownership button.
  - `SharingBadge(level:)`: `lock.fill` + `SharingCopy.badge` in secondary style, one line; shown for the owner on accounts below Everything.
  - Snapshot routes (1100×700): `settings-sharing-setup`, `settings-sharing-ownership_sheet`, `settings-sharing`, `settings-sharing-lower_warning`, `settings-sharing-hidden_blocked`, `accounts-sharing_badges`, `budget-cell-private_lines` (viewer B), `dashboard-viewer_member` (net worth note).

- [ ] **Step 1:** `DemoSharing` and its test; run `swift test --scratch-path $S6 --filter DemoDatabaseTests` (FAIL first, then pass).
- [ ] **Step 2:** Build the views and routes.
- [ ] **Step 3: Verify:** `scripts/render-snapshots.sh $S6/snaps --quick --routes settings-sharing,accounts-sharing_badges,budget-cell-private_lines,dashboard-viewer_member --size 1100x700` → `wrap-report.txt` 0 violations; Mac Debug build; full suite.
- [ ] **Step 4: Commit** "Mac Settings ▸ Sharing: ownership sheet, per-account levels with warnings, tax and income, lock badges, private summary lines, net worth note".

### Task 11: iPhone: zone set, read-only Sharing, summary rows

**Files:**
- Create: `Sources/MangoUI/Settings/SharingSection.swift`, `Sources/MangoUI/DesignSystem/SharingBadgeView.swift`
- Modify: `Sources/MangoSync/CloudKitAccountStatus.swift` (`public static func userRecordName(container:) async throws -> String`), `Sources/BudgetCore/Access/SharedActualsSource.swift` (`SharingViewer.forCloudKitUser(recordName:db:)`), `Phone/Sync/PhoneSyncController.swift` (viewer from the iCloud user; engine `viewer:`; non-demo Release builds may sync the phone's own database, see below), `Sources/BudgetCore/Sync/SyncActivation.swift` (`phoneDecision`), `Sources/MangoUI/Settings/SettingsSheet.swift`, `Sources/MangoUI/Accounts/AccountRowView.swift`, `Sources/MangoUI/Month/MonthTransactionsView.swift`, the phone view models (load through `SharedActualsSource`), `Sources/MangoUI/Demo/DemoRoutes.swift`
- Test: `Tests/BudgetCoreTests/SyncActivationTests.swift` (new cases), `Tests/BudgetCoreTests/SharedActualsSourceTests.swift` (one case)

**Interfaces:**
- Consumes: Tasks 5, 7, 10 (`DemoSharing`).
- Produces:
  - `SharingViewer.forCloudKitUser(recordName: String?, db:) -> SharingViewer` (the `appUser` with that `cloudKitUserRecordName` → its person; none → `.init(personId: nil)` but the phone then shows only household data: `SharedActualsSource` treats a nil-person viewer **on the phone** as seeing in full only Everything/joint — parameter `strict: Bool`).
  - `SyncActivation.phoneDecision(isDemoData: Bool, isSyncDemoLaunch: Bool, hasCloudKitEntitlement: Bool) -> Decision`: demo data never syncs; `--sync-demo` keeps today's rules; otherwise allowed when the entitlement is present (the phone's database is its own and read-only). The pull zone set: household, then `private-<viewer person uuid>` once the household pull has named the viewer.
  - Settings sheet section "Sharing": own accounts with their level (text, no picker) and "Levels are changed on the Mac."; tax and income level. Accounts rows show `SharingBadgeView`; Month's category transactions list ends with the private lines.
  - Routes: `settings-sharing`, `accounts-sharing_badges`, `month-private_lines`.

- [ ] **Step 1: Write the failing tests:** `testPhoneDecisionAllowsRealSyncOnlyWithEntitlementAndNeverDemoData`; `testStrictNilViewerSeesOnlyShared`.
- [ ] **Step 2: Run** `swift test --scratch-path $S6 --filter 'SyncActivationTests|SharedActualsSourceTests'`. Expected: FAIL.
- [ ] **Step 3: Implement** BudgetCore, MangoSync, MangoUI and Phone changes.
- [ ] **Step 4: Verify:** filter passes; `scripts/build-phone.sh`; `scripts/render-phone-snapshots.sh $S6/phone-snaps --only settings-sharing,accounts-sharing_badges,month-private_lines` 0 violations at both sizes; full suite.
- [ ] **Step 5: Commit** "iPhone: pulls household and its owner's private zone, read-only Sharing, badges and private lines".

### Task 12: Turning on sync for the real database (BudgetCore) and the rehearsal

**Files:**
- Create: `Sources/BudgetCore/Sync/SyncTurnOn.swift`
- Modify: `Sources/BudgetCore/Sync/SyncActivation.swift` (`realDecision`), `Sources/BudgetCore/Sync/SyncRehearsal.swift` (zones, ownership, summaries, guard), `Tools/Sources/SyncRehearsal/main.swift` (flags)
- Test: `Tests/BudgetCoreTests/SyncTurnOnTests.swift`, `Tests/BudgetCoreTests/SyncRehearsalTests.swift` (new cases)

**Interfaces:**
- Consumes: Tasks 3–6; `MigrationBackup.copyDatabase`, `SyncRecordStore.backfill`, `SyncImportGate.setSyncOn`.
- Produces:
  - `public enum SyncTurnOn { public enum Stage: String, Codable, Sendable { case notStarted, backedUp, ownershipConfirmed, uploading, done }; public struct Progress: Equatable, Sendable { stage: Stage; backupPath: String?; total: Int; sent: Int }; public enum Blocker: Equatable, Sendable { case notAdmin, wrongEnvironment, noEntitlement, demoDatabase, strayHouseholdKey, noICloudAccount }; public static let backupPrefix = "budget.sqlite.pre-sync-backup-"; public static func progress(db:) throws -> Progress; public static func blockers(isAdmin: Bool, isProduction: Bool, hasEntitlement: Bool, isDemoDatabase: Bool, keyStoreHoldsHouseholdKey: Bool, serverHasHouseholdMarker: Bool, iCloudAvailable: Bool) -> [Blocker]; public static func backUp(manager: DatabaseManager, databasePath: String, now: Date) throws -> URL; public static func markOwnershipConfirmed(db:, now:) throws; public static func beginUpload(admin: AccessActor, cloudKitUserRecordName: String, db:, now:) throws -> Int; public static func markDone(db:, now:) throws }`.
    - Stages persist in `syncState` (`turnOn.stage`, `turnOn.backupPath`, `turnOn.total`), local only. `backUp` writes `<dir>/budget.sqlite.pre-sync-backup-yyyyMMdd-HHmmss` (local time, as `MigrationBackup`) and refuses to continue when the copy fails. `beginUpload` (stage must be `ownershipConfirmed`): sets the admin's `appUser.cloudKitUserRecordName`, runs `SyncRecordStore.backfill`, rebuilds the admin's summaries, `setSyncOn(true)`, stores `total` = pending count, stage `uploading`. `sent` = `total` − pending. `strayHouseholdKey` = key held locally and no marker on the server (a leftover test key would otherwise be adopted). The stage is never moved backwards; a relaunch in `uploading` continues.
  - Blocker copy (`SyncTurnOn.text(_ blocker:)`): "Only the household's admin can turn on sync."; "This build syncs with iCloud's development environment, not your data's."; "This build isn't signed for iCloud."; "This is the demo database."; "iCloud Keychain already holds a household key from a test. Remove it before turning on sync."; "Sign in to iCloud in System Settings first.".
  - `SyncActivation.realDecision(isAppDatabase: Bool, isDemoDatabase: Bool, stage: SyncTurnOn.Stage, hasCloudKitEntitlement: Bool, isProduction: Bool) -> Decision` — allowed only for the app's own, non-demo database, stage `uploading` or `done`, entitlement present, Production. The `--sync-demo` path is unchanged and never combines with it.
  - `SyncRehearsal.run(databasePath:libraryPath:keep:ownership: RehearsalOwnership)` with `public struct RehearsalOwnership { joint: Set<Int64>; levels: [Int64: SharingLevel] }` (defaults otherwise): applies `SharingSetup.save` on the copy, pushes into `FakeCloud` through `ZoneAuditingTransport`, and adds to the report `recordsByZone`, `householdViolations` (must be empty), `summaries` (counts), and an apply into two empty databases — the admin's other device (both zones; row counts and tax figures equal the copy) and a member stand-in (household only; no row of a private account's transactions; `syncStaging` empty). `passed` includes these. Tool flags: `--joint <id>` (repeatable), `--level <id>=<everything|categoryTotals|balanceOnly|hidden>` (repeatable); ids are typed at run time, never committed.

- [ ] **Step 1: Write the failing tests:** `testStagesAdvanceInOrderAndNeverBack`; `testBackupIsTimestampedBesideTheDatabase` (name matches `^budget\.sqlite\.pre-sync-backup-\d{8}-\d{6}$`, opens with identical row counts); `testBeginUploadSetsICloudUserAndQueuesEverything`; `testTurnOnRefusesWhenAStrayHouseholdKeyIsHeld`; `testTurnOnResumesAfterQuit` (upload half the records into FakeCloud, drop the engine, reopen: stage `uploading`, `sent` equals what landed, the rest goes, no second key marker); `testRealDecisionNeedsStageEntitlementProductionAndAppDatabase` (each refusal with its reason); `testRehearsalOnDemoPassesWithZones` (`TestDatabase.demo()` with one Balance only account: `passed`, `householdViolations` empty, member stand-in holds none of its transactions).
- [ ] **Step 2: Run** `swift test --scratch-path $S6 --filter 'SyncTurnOnTests|SyncRehearsalTests|SyncActivationTests'`. Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** the filter, `swift run --package-path Tools SyncRehearsal --help` (flags listed), full suite.
- [ ] **Step 5: Commit** "Turn on sync: backed-up, resumable stages for the real database; activation for it; rehearsal with zones, ownership and a member stand-in".

### Task 13: Mac "Turn on sync…" and the real sync; Development schema seeding

**Files:**
- Create: `App/Sync/RealSync.swift`, `App/Settings/TurnOnSyncSheet.swift`
- Modify: `App/Settings/SyncSettings.swift` ("Turn on sync…" when `SyncTurnOn.blockers` is empty or lists only fixable ones; progress while uploading; live status after), `App/AppEnvironment.swift` (starts `RealSync` when `SyncActivation.realDecision` allows), `App/Sync/SyncDemoMode.swift` (`--sync-demo --seed-schema`), `Sources/BudgetCore/Sync/SyncDemoReset.swift` (seed records builder), `App/Snapshots/SharingSnapshots.swift` (routes)
- Test: `Tests/BudgetCoreTests/SyncSchemaSeedTests.swift`

**Interfaces:**
- Consumes: Tasks 5, 6, 9, 10, 12; `CloudKitAccountStatus.userRecordName`.
- Produces:
  - `@MainActor final class RealSync`: `SyncEngineCore(db:, transport: CloudKitTransport(), device: SyncDevice(id: LocalSetting.macDeviceId, name: Host.current().localizedName ?? "Mac"), keyStore: KeychainSyncKeyStore(container: CloudKitTransport.keyScope(demo: false)), documents: SyncDocumentFiles(root:, policy: .eager), viewer: SyncViewer(personUuid: <signed-in user's person UUID>), revalidatesAccess: true)` and a `SyncScheduler`; `LocalSetting.macDeviceId(_:)` mirrors `phoneDeviceId`. Publishes `SyncStatus` and `SyncTurnOn.Progress`. Hub jobs stay the admin's.
  - `TurnOnSyncSheet`: steps in order, each a section with its state: **1 Back up** ("Back up now" → `SyncTurnOn.backUp`, shows the file name); **2 Who owns each account?** (embeds `OwnershipSheet` when not confirmed, else "Done"); **3 Upload** ("Start upload" → `beginUpload` then `RealSync.start`; "Uploading \(sent) of \(total) records"; "Upload paused — it continues where it stopped." when offline; "Your data is in iCloud." when done). Blockers are listed above the steps with their copy; Start stays disabled while any remains. Closing the sheet never cancels a running upload; reopening shows the current stage.
  - `SyncSchemaSeed.records(keys: any SyncKeyStore) throws -> [SyncWireRecord]`: one sealed placeholder record of every record type the engine can save (each `SyncSchema.tables` name, `zoneKey`, `documentFile`, `importLease`, `accountDetails`) in zone `schema-seed`; `--sync-demo --seed-schema` (DEBUG, Development, demo scope) creates the zone, saves them, deletes the zone, prints "Seeded \(n) record types" and exits. Production record types come from the user's "Deploy Schema Changes" in the CloudKit Console.
  - Routes (1100×700): `settings-sync-turn_on` (blockers), `settings-sync-turn_on-ownership`, `settings-sync-turn_on-uploading`, `settings-sync-on`.

- [ ] **Step 1: Write the failing test** `testSchemaSeedCoversEveryRecordType` (the seed's record types ⊇ every type the engine sends; each record is exactly `sealed` + `keyId`, or the marker / file shape).
- [ ] **Step 2: Run** `swift test --scratch-path $S6 --filter SyncSchemaSeedTests`. Expected: FAIL.
- [ ] **Step 3: Implement** the seed, `RealSync`, the sheet and the settings changes.
- [ ] **Step 4: Verify:** filter; full suite; `scripts/render-snapshots.sh $S6/snaps --quick --routes settings-sync --size 1100x700` 0 violations; Mac Debug build; `scripts/build-phone.sh`; `scripts/check-actor-writes.sh`; then the full Mac harness once (`scripts/render-snapshots.sh $S6/snaps-full --size 1100x700`) and the full phone harness, both 0 violations.
- [ ] **Step 5: Commit** "Mac: Turn on sync… (backup, ownership, upload with progress) and real sync in Production; schema seeding for the Development container".

### Task 14: Controller: merge, schema, rehearsal, the real run, TestFlight

Controller-run with the user. No subagent runs any step here.

- [ ] **Step 1: Merge and install.** Whole-branch review; `xcodebuild` Mac and `scripts/build-phone.sh`; merge to main; `xcodegen generate` in the main checkout; `scripts/install-app.sh`. Check the installed app: `codesign -d --entitlements - /Applications/Mango.app` lists `iCloud.ubberninja.mango`, environment `Production`, the keychain group.
- [ ] **Step 2 (user: go for Development):** team-signed Debug build, fresh demo from `MakeDemoDatabase`: `--sync-demo --seed-schema`. Expected: "Seeded <n> record types". The user opens the CloudKit Console (Development ▸ Schema) and confirms the new types (`accountBalancePoint`, `accountSummaryMonth`, `memberPermission`, `personSharing`, `accountDetails`), then **deploys the schema to Production** (Console ▸ Deploy Schema Changes).
- [ ] **Step 3 (user: Keychain check):** the user confirms no item under service `ubberninja.mango.sync` with account starting `iCloud.ubberninja.mango/household/` remains (Keychain Access, iCloud keychain) — the `strayHouseholdKey` blocker also catches it.
- [ ] **Step 4 (user: which account is joint, which go to Everything):** quit Mango; copy the real database to the scratchpad with the SQLite backup API (`sqlite3 <real> ".backup <S6>/rehearsal/budget.sqlite"`); `swift run --package-path Tools SyncRehearsal <copy> --library <evidence root> --joint <id> --level <id>=everything …`. Expected: `passed`, `householdViolations` 0, member stand-in with none of the private transactions, tax figures 2020–2024 identical. Record counts per zone in **Result**.
- [ ] **Step 5 (user's go at the moment of the first upload):** the user opens Mango ▸ Settings ▸ Sync ▸ Turn on sync…, backs up, sets owners exactly as rehearsed, starts the upload, and watches it finish ("Your data is in iCloud."). The controller reads the log for `SyncZoneGuard` violations (must be none) and records the backup file name, total and duration.
- [ ] **Step 6 (user: Xcode sign-in fixed):** `scripts/archive-phone.sh` exports the `.ipa`; cloud-managed distribution signing needs the user's Apple Account in Xcode ▸ Settings ▸ Accounts (the App Store Connect API key can't create cloud-managed distribution certificates). With the user's go: `MANGO_ASC_KEY_ID=… MANGO_ASC_ISSUER_ID=… MANGO_ASC_KEY_FILE=… scripts/archive-phone.sh --upload` (values from the key file's location, never committed).
- [ ] **Step 7 (user, on the iPhone):** install from TestFlight; unlock; first download completes; Home's net worth and Accounts' balances equal the Mac's; the Private accounts show their transactions (the admin's own zone); Settings ▸ Sharing lists the levels. Screenshots by the user.
- [ ] **Step 8:** fill **Result**: rehearsal counts, the backup file name, upload totals and time, the iPhone's first-download time, anything left (the member's invite is step 7).

## Rulings made in this plan (binding unless the user objects)

1. **Pinned transactions:** a private account's transaction is shared when its category is a property category *or* a §10 property/tax row points at it, so those rows never reference a private record.
2. **Closure:** any other record goes to the private zone of a private record it references; the household never references a private record (the guard checks it).
3. **Account stub + `accountDetails` companion:** below Everything (not Hidden), the account row stays in household without `privateAccountColumns`; those columns travel in an `accountDetails` record in the owner's zone. `balanceConfirmedAt` and `bankName` stay shared.
4. **Hidden accounts** route wholly private and are refused while property links, shared transactions or household rules name them.
5. **Moves use sealed markers** in the old zone instead of deletes, so an owner device never transiently deletes a moved record; markers carry no data. Pruning old markers is a follow-up.
6. **A private run's household records travel untagged** by the batch; manifests count only the run's zone.
7. **Summaries** are built only by the owner's writing device (the Mac), before each push, with name-derived UUIDs; the current balance point is dated at the latest activity, not today, so it doesn't change daily.
8. **`AccessActor`** (not `Actor`, which would shadow Swift's `Actor` protocol).
9. **Member permission rows** are written only for existing member app users; absent rows mean the defaults.
10. **The iPhone's viewer** is the app user whose `cloudKitUserRecordName` is the phone's iCloud user; the Mac writes the admin's at turn-on.

## Result

(Filled by Task 14.)
