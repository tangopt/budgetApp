# Step 11: Accounts on the iPad — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (chosen) to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** each person looks after their own accounts from the iPad (see, add, edit details, set sharing level, update a manual balance, fetch a statement) without the Mac.

**Architecture:**
- **Reuse, don't rebuild.** The iPad already has an Accounts section (`PadSection.accounts`, ungrouped in the sidebar) showing the iPhone's `AccountsView`/`AccountsViewModel`/`AccountDetailView` (net worth header, grouped sections, `AccountRowPresentation.sharingBadge`, balance chart, recent transactions, "Update balance" via `QuickEditModel`). Step 11 adds a pad-specific screen around those view models plus the missing writes.
- **BudgetCore owns the writes** (`PadAccountEdits`): `AccountEditing.add/update/setIncludeInNetWorth` and `AccountSharing.apply` run through `DeviceWriter` in `.budgetAndAccounts`, filed-year checked; the Mac re-validates (`AccessAreaMap.accountDecision`: owner-only fields).
- **Fetch statement** reuses step 10's `BrowserModel` (`\.padBrowser`) and `CheckAndLinkModel`; a statement PDF is handed to the Mac as step 10 does (`CheckAndLinkSheetCopy.statementNote`). No import on the iPad (step 19).

**Tech Stack:** Swift 6, SwiftUI, GRDB 6.29, XCTest, XcodeGen.

**Spec:** `docs/superpowers/specs/2026-10-27-step11-ipad-accounts-design.md` (binding). Cited: `2026-10-25-sharing-levels-design.md`, step 10's plan (`2026-10-27-step10-ipad-property.md`) for the pad patterns.

## Global Constraints

- **Logic in BudgetCore** (`Sources/BudgetCore`); `Sources/MangoUI/Pad` renders and calls it. `scripts/build-core-ios.sh` stays green.
- **Writes** go through `DeviceWriter.writeCheckingFiledYears` (or Task 1's `writeWithActor`, same checks); a question becomes an inline refusal via `PadRefusalBanner`/`PadWriteModel`, nothing saved or queued; the Mac re-validates. Never bypass it.
- **Controls are hidden, not disabled** by permission (`DeviceWriter.canEdit(.budgetAndAccounts)`). Sharing controls show only on an account the viewer owns (the owner rule: nobody sets a level on someone else's account).
- **Fits 11" and 13" iPad, portrait and landscape**; no figure wraps or truncates; names truncate in the middle (`.lineLimit(1).truncationMode(.middle)`).
- **Edits save only on Save** or an explicit button; none on dismiss or on change.
- **Filed SA returns 2020/21–2024/25 never change.**
- **Private accounts never leak** to the other person: every list/detail reads through the viewer's `PhoneViewer`/`DeviceReadScope`, as the iPhone does.
- **Tenant's personal name appears only on Tenancies and in the recharge email.**
- **No new CloudKit record type; no schema change.**
- **Tests never touch the real DB, Keychain, iCloud, `/Applications` or real web sites.** Use `TestDatabase`, `TwoPersonHousehold`, BudgetDemo, `FakeCloud`. No subagent runs `scripts/install-app.sh`.
- **The Mac app is unchanged** except shared BudgetCore code.
- **Nothing personal committed** (public repo): synthetic names.
- **Build the App/Phone targets with `xcodebuild`** (`scripts/build-phone.sh`) for any task touching `Phone/`, `App/`, `project.yml`.
- **Commands** (`S11=/tmp/mango-11-build`):
  - targeted: `swift test --scratch-path $S11 --filter '<Tests>'`
  - full suite, once at the end of each task: `swift test --scratch-path $S11 --parallel`
  - phone/iPad build: `scripts/build-phone.sh`
  - Mac build: `xcodegen generate && xcodebuild -project Mango.xcodeproj -scheme Mango -configuration Debug -derivedDataPath $S11/dd CODE_SIGNING_ALLOWED=NO build`
  - iPad snapshots: `scripts/render-phone-snapshots.sh $S11/snaps --device ipad --only <routes>` at 11"/13" x portrait/landscape; 0 wrap violations.
  - `scripts/check-actor-writes.sh` → "actor writes OK" after any task adding a write path.
  - **at most 2 building agents at once.**
- **Model tags:** **[opus]** = privacy, write path, sharing, filed years: most capable model plus spec+code review. **[sonnet]** = UI: quick review.
- **Dropping tasks: drop from the end.** Task 4 is droppable alone; Task 3 next (then adding/editing stays on the Mac, Tasks 1–2 still deliver view + balance + sharing).

## Review Focus

1. **A member opens the other person's account (or one below Everything).** Expect balance-only/summary exactly as on the iPhone, no edit, sharing or update controls, never more. Task 2: `testOtherPersonsAccountOffersNoActions`.
2. **A member tries to set a level, or move to Joint, on an account she doesn't own** (stale screen after ownership changed). Expect an inline refusal, nothing saved. Task 1: `testSetLevelOnOthersAccountRefused`.
3. **Kind change to/from credit with history, or a name already used.** Expect the form's own error, nothing saved. Task 3: `testCreditKindLockedWithHistory`, `testDuplicateNameRefused`.
4. **Edit on a property-linked account that would move a filed return.** Expect `DeviceWriteRefusal.filedYear` as an inline refusal, nothing saved. Task 1: `testPropertyLinkedEditOnFiledYearRefused`.
5. **View-only user, or demo data (no writer).** Expect no Add/Edit/Sharing/Update controls and the view-only notice, no error. Task 2: `testNoEditControlsWithoutEdit`.

---

### Task 1 [opus]: Account writes for the iPad (BudgetCore)

**Files:**
- Create: `Sources/BudgetCore/Phone/PadAccountEdits.swift`
- Modify: `Sources/BudgetCore/Access/DeviceWriter.swift` (add `writeWithActor`, next to `writeCheckingFiledYears`)
- Test: `Tests/BudgetCoreTests/PadAccountEditsTests.swift`

**Interfaces — Produces:**
- `DeviceWriter.writeWithActor<T: Sendable>(_ area: AccessArea, origin: WriteOrigin = .edit, edit: String, scope: FiledYearEditCheck.Scope, _ body: @escaping @Sendable (Database, AccessActor) throws -> T) async throws -> T` — exactly `writeCheckingFiledYears`, but the body also receives the resolved actor (needed by `AccountSharing.apply`; `AccountEditing.add` takes `owner: AccessActor?`). Refactor so the two share one implementation.
- `enum PadAccountEdits` (all `static`, `async throws`, take `writer: DeviceWriter`):
  - `add(writer:name:currency:kind:manual:openingBalanceEntered:asOf:details:includeInNetWorth:joint:) -> Int64` (new account id): `AccountEditing.add(... trackingMode: manual ? .manual : .imported, owner: actor, joint:)`. `joint == true` throws `PadAccountError.jointNeedsAdmin` unless the actor `isAdmin`. Scope `Scope(dates: [asOf])` when an opening balance is given, else empty.
  - `update(writer:accountId:name:kind:details:includeInNetWorth:sharing:(owner: SharingSetup.Owner, level: SharingLevel)?)`: one transaction: `AccountEditing.update`, then `AccountSharing.apply` when `sharing` is non-nil. Scope `.everyYear` when the account is property-linked (`SharingDefaults.isPropertyLinked`) and kind or includeInNetWorth changed, else empty.
  - `sharingState(writer:dbReader:accountId:) -> AccountSharing.State?` (nil with no actor) and `canSetSharing(accountId:writer:dbReader:) -> Bool` (= the state's `canChangeLevel` and Edit on Budget & accounts).
- `enum PadAccountError: Error, Equatable, LocalizedError { case jointNeedsAdmin }`, copy: "Only the household's admin adds a joint account."
- No delete and no archive function exists (spec: deletion stays on the Mac).

- [ ] **Step 1: Write the failing tests** in `PadAccountEditsTests` (use `TwoPersonHousehold`, a `DeviceWriter` for member and for admin):
  - `testAddOwnAccountIsOwnedByWriterAtDefaultLevel`: member adds "Test Current" GBP, opening 1_000_00 asOf 2026-10-01 → account `ownerPersonId == member.personId`, `sharingLevel == SharingDefaults.level(...)`, one snapshot.
  - `testMemberCannotAddJoint`: `jointNeedsAdmin`, no account row added.
  - `testAdminAddsJointAtEverything`: `ownerPersonId == nil`, `sharingLevel == .everything`.
  - `testUpdateNameKindDetailsSavedTogetherWithLevel`: owner updates name and level in one call → both stored; if the level change throws (`SharingError.notOwner` case below) the name is unchanged (both or neither).
  - `testSetLevelOnOthersAccountRefused`: member sets level on the admin's account → throws, level and name unchanged.
  - `testPropertyLinkedEditOnFiledYearRefused`: kind change on a property-linked account with a filed 2022/23 return → `DeviceWriteRefusal.filedYear`, nothing saved.
  - `testViewOnlyWriterRefused`: writer without Edit on Budget & accounts → `AccessDenied`, nothing saved.
  - `testIncludeInNetWorthToggleSaved`.
  - `testCanSetSharingOnlyForOwnAccount`.
- [ ] **Step 2: Run** `swift test --scratch-path $S11 --filter PadAccountEditsTests` → FAIL (types not defined).
- [ ] **Step 3: Implement** `writeWithActor` then `PadAccountEdits` as specified (the actor comes from `DeviceWriter.actor(viewer, db:)` inside the same write transaction; sharing goes through `AccountSharing.apply(... now: AppClock.now)` — it enforces the owner rule, `AccessAreaMap` re-checks on the Mac).
- [ ] **Step 4: Run** the targeted tests → PASS; `swift test --scratch-path $S11 --parallel`; `scripts/check-actor-writes.sh` → "actor writes OK"; `scripts/build-core-ios.sh`.
- [ ] **Step 5: Commit**: `git add Sources/BudgetCore/Phone/PadAccountEdits.swift Sources/BudgetCore/Access/DeviceWriter.swift Tests/BudgetCoreTests/PadAccountEditsTests.swift && git commit -m "Step 11: iPad account writes (add, edit, sharing) through the device writer"`

### Task 2 [sonnet]: The Accounts screen on the iPad (list, detail panel, balance, fetch statement)

**Files:**
- Create: `Sources/MangoUI/Pad/Accounts/PadAccountsModel.swift`, `Sources/MangoUI/Pad/Accounts/PadAccountsView.swift`, `Sources/MangoUI/Pad/Accounts/PadAccountDetailView.swift`
- Modify: `Sources/MangoUI/Pad/PadRootView.swift` (`case .accounts` → `PadAccountsView`; keep the iPhone `AccountsView` for the phone), `Sources/MangoUI/Root/PhoneTabs.swift` (`padAccounts`, its `PadWriteModel(writer:, area: .budgetAndAccounts)` as `padAccountWrite`), `Sources/MangoUI/Pad/PadRoutes.swift` (snapshot routes), `Sources/MangoUI/Accounts/AccountDetailView.swift` (make its balance, chart and recent-transactions cards reusable from the pad detail, if not already internal)
- Test: `Tests/MangoUITests/PadAccountsModelTests.swift`

**Interfaces — Consumes:** `AccountsViewModel`/`AccountDetailModel`, `QuickEditModel.canUpdateBalance`, `PadWriteModel`, `\.padBrowser`, `PadAccountEdits` (Task 1).
**Produces:** `@MainActor final class PadAccountsModel: ObservableObject` — `selectedId: Int64?`, `actions(for accountId: Int64) async -> Set<PadAccountAction>`, `PadAccountAction { case addAccount, editDetails, setSharing, updateBalance, fetchStatement }`. `PadAccountsView(model:write:syncStatus:onRefresh:)`.

Layout: landscape/13" shows list left (the iPhone's grouped cards, net worth header) and the selected account's detail on the right (~380 pt panel like `DocumentPanel`); portrait 11" pushes the detail. Detail: balance, history chart, recent transactions (a row opens the transaction sheet with the document panel — reuse `\.documentPanelSource`), details block (bank, number masked via `AccountDetailsFormat`, currency, kind, "Updated by hand"/"From statements"), Sharing line (level + owner), buttons Edit (Task 3), Update balance, Fetch statement. "Fetch statement" opens the browser at the account's bank site if the saved sites have a host matching `bankName`, else the sites strip (`padBrowser?.isPresented = true`); the PDF goes through the tray and `CheckAndLinkSheet`, which hands statements to the Mac (step 10 copy, unchanged). Hidden unless `padBrowser != nil` and Edit on Budget & accounts.

- [ ] **Step 1: Write the failing tests** in `PadAccountsModelTests`:
  - `testOtherPersonsAccountOffersNoActions`: member viewing the admin's Balance-only account → `actions` is empty.
  - `testNoEditControlsWithoutEdit`: view-only writer and demo (nil writer) → no `addAccount`, `editDetails`, `setSharing`, `updateBalance`, `fetchStatement`.
  - `testSharingOnlyOnOwnAccount`: `setSharing` present for the owner's, absent for a joint account and the other person's.
  - `testUpdateBalanceOnlyOnManualAccount`: matches `PhoneQuickEdits.canUpdateBalance`.
  - `testListHidesWhatViewerCannotSee`: a private account of the other person is absent from the member's list (names truncate middle is a view test, via snapshots).
- [ ] **Step 2: Run** `swift test --scratch-path $S11 --filter PadAccountsModelTests` → FAIL.
- [ ] **Step 3: Implement** the model, views, `PhoneTabs` wiring and the root switch; add snapshot routes `pad-accounts`, `pad-account-detail`.
- [ ] **Step 4: Run** targeted tests → PASS; `scripts/build-phone.sh`; render the two routes at the four sizes → 0 wrap violations; `swift test --scratch-path $S11 --parallel`.
- [ ] **Step 5: Commit** only the files above: `git commit -m "Step 11: Accounts screen on the iPad with detail panel, balance update and statement fetch"`

### Task 3 [sonnet]: Add account and Edit details forms (Save only), with Sharing

**Files:**
- Create: `Sources/MangoUI/Pad/Accounts/PadAccountFormModel.swift`, `Sources/MangoUI/Pad/Accounts/PadAccountForms.swift`
- Modify: `Sources/MangoUI/Pad/Accounts/PadAccountsView.swift` / `PadAccountDetailView.swift` (present the sheets)
- Test: `Tests/MangoUITests/PadAccountFormModelTests.swift`

**Interfaces — Consumes:** `PadAccountEdits.add/update/sharingState`, `AccountDetails`/`AccountDetailsFormat` (validation, `errors(existing:)`), `SharingCopy` (labels, lowering warning, `AccountSharing.preview`). **Produces:** `PadAccountFormModel` (draft, `canSave`, `errors`, `save() async -> Bool`), sheets `PadAddAccountSheet`, `PadEditAccountSheet`.

Add: name, kind, currency, bank (region, bank name, region fields), "Updated by hand" toggle, count toward net worth, opening balance + date, owner "Mine"/"Joint" with Joint shown only when the writer is the admin. Edit: name, kind, bank details, count toward net worth, Sharing section (owner picker only if `canChangeOwner`, level picker only if `canChangeLevel`; lowering shows `AccountSharing.preview`'s count and `SharingCopy` warning; a blocker shows its copy). No delete or archive on the iPad: "Count toward net worth" off is how an account is set aside; Delete stays on the Mac and the form says so in one line. Cancel discards; nothing saves on dismiss.

- [ ] **Step 1: Write the failing tests**:
  - `testCancelWritesNothing` (draft edited, no `save()`, DB unchanged).
  - `testInvalidBankDetailsBlockSave` (bad sort code → `canSave == false`, error text from `AccountDetailsError`).
  - `testCreditKindLockedWithHistory` (kind picker offers no credit transition when `AccountEditing.hasHistory`).
  - `testDuplicateNameRefused` (error shown, nothing saved).
  - `testJointToggleHiddenForMember` / `testJointToggleShownForAdmin`.
  - `testLoweringShowsPreviewBeforeSave` (draft level below current → `preview.isLowering`, count from `AccountSharing.preview`).
  - `testSaveCallsOneTransaction` (name and level change together, via Task 1).
- [ ] **Step 2: Run** `swift test --scratch-path $S11 --filter PadAccountFormModelTests` → FAIL.
- [ ] **Step 3: Implement** the model (validation lives in BudgetCore types already; the model only wires drafts to `PadAccountEdits` and keeps refusals via `PadWriteModel.refuse/perform`) and the sheets.
- [ ] **Step 4: Run** targeted tests → PASS; `scripts/build-phone.sh`; snapshots of `pad-account-add`, `pad-account-edit` at the four sizes, 0 wrap violations; full suite.
- [ ] **Step 5: Commit**: `git commit -m "Step 11: add and edit accounts on the iPad, sharing in the account"`

### Task 4 [sonnet]: Verification pass and Mac parity check (droppable)

**Files:**
- Test: `Tests/MangoUITests/PadAccountsParityTests.swift`; modify `Tests/MangoUITests/PadSectionTests.swift` only if the sidebar changes (it does not).

- [ ] **Step 1: Write the failing tests**: `testEveryMacAccountActionIsAnsweredOrListedAsMacOnly` (a table like `PadProfileAction.macActions`: Add, Edit…, Sharing, Update balance, Set as main, Reorder, Delete → pad answer or "Mac only"); `testFiguresMatchTheMac` (`AccountsViewModel.figuresCheck` for the demo household: net worth and each row's balance equal the Mac's `AccountsOverview`).
- [ ] **Step 2: Run** → FAIL; **Step 3:** make the table and any missing wiring pass (Set as main and Reorder are Mac only, said so in the table); **Step 4:** `swift test --scratch-path $S11 --parallel`, Mac build, `scripts/build-phone.sh`; **Step 5: Commit** `git commit -m "Step 11: Mac parity checks for iPad accounts"`.

---

Self-review: spec coverage — sidebar item (already present), grouped list with badges/net worth (Task 2 reuse), detail with chart/transactions/details/sharing/update balance/fetch statement (Task 2), add and edit (Tasks 1, 3), writes via `DeviceWriter` with owner rule and inline refusals (Task 1), non-goals respected (no import, no delete, no rules).

## Calls extending or contradicting the spec

- **Contradicts:** sidebar. Accounts is already a top-level ungrouped item (step 8), so it stays there instead of moving under "Everything else".
- **Contradicts:** "archive". The `Account` model has no archive field and no schema change is allowed; the iPad sets an account aside with "Count toward net worth" off, deletion stays on the Mac.
- **Extends:** `DeviceWriter.writeWithActor` (new, same checks as `writeCheckingFiledYears`) because sharing writes need the actor.
- **Extends:** joint accounts: `AccessAreaMap` lets any editor insert a joint account, so the "member adds only her own" rule is enforced in `PadAccountEdits.add` (admin only) as well as in the form.
- **Extends:** filed-year scope for account edits is `.everyYear` only for property-linked accounts whose kind or net-worth flag changes; otherwise empty.
- **Extends:** "tracking manual/statements" is the legacy `trackingMode`; kept because `PhoneQuickEdits.updateManualBalance` still gates on it.
