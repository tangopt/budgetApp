# Step 12: Mac Dashboard review — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (chosen) to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** the Mac Dashboard gains four cards (Tax year position, Property month, Evidence and documents, Mortgage), folds the new property/tax/evidence signals into "Needs attention", and shows files waiting to import; each new card can be hidden in Settings.

**Architecture:** one BudgetCore read model, `DashboardReview.load(db:today:viewer:)`, composes existing figures (`TaxOverview`/`TaxOverview.selfAssessment`, `ThisMonthChecklist`, `MissingEvidence`, `WaitingDocuments`, `MortgageRate.Status`, `ImportWaitingList`) into plain values; `DashboardViewModel` loads it in the same `load()`; the cards only render it. Card visibility is a pure `DashboardCardVisibility` stored per device in `UserDefaults` (not synced).

**Tech Stack:** Swift 6, SwiftUI (macOS 26), GRDB 6.29, XCTest, XcodeGen.

**Spec:** `docs/superpowers/specs/2026-10-27-step12-dashboard-review-design.md` (binding). Style/commands from `2026-10-27-step10-ipad-property.md`. Step 9 plan (`WaitingDocuments`) is a dependency: this plan assumes step 9 is merged (see Call 1).

## Global Constraints

- **Logic in BudgetCore** (`Sources/BudgetCore/Dashboard/`); views in `App/Dashboard/` only render; no calculation in a view body. `scripts/build-core-ios.sh` stays green (no AppKit in BudgetCore).
- **Read-only Dashboard:** the only controls are navigation links and the Import button; no writes added (so `scripts/check-actor-writes.sh` is unaffected).
- **Fits 1100×700 with vertical scroll; no figure wraps; names truncate in the middle** (`.lineLimit(1).truncationMode(.middle)` on names, `.fixedSize()`/`minimumScaleFactor` never used to hide a wrap on figures).
- **Tenant's personal name never shown;** the tenancy's name only.
- **Permissions:** a section the viewer can't see (Property, Documents, Tax) is `nil` in the model and its card is not drawn.
- **Card visibility is per device** (`UserDefaults`, key `dashboardHiddenCards`), never synced, default all shown.
- **Filed SA returns 2020/21–2024/25 never change;** nothing here writes.
- **Tests never touch the real DB, Keychain, iCloud or `/Applications`.** Use `TestDatabase`, synthetic names. No subagent runs `scripts/install-app.sh`.
- **Nothing personal committed** (public repo).
- **Build the App target too** (`xcodebuild`), not only `swift test`, for Tasks 2–4.
- **Commands** (`S12=/tmp/mango-12-build`):
  - targeted: `swift test --scratch-path $S12 --filter '<Tests>'`
  - full suite once at the end of each task: `swift test --scratch-path $S12 --parallel`
  - Mac build: `xcodegen generate && xcodebuild -project Mango.xcodeproj -scheme Mango -configuration Debug -derivedDataPath $S12/dd CODE_SIGNING_ALLOWED=NO build`
  - Mac snapshots: `scripts/render-snapshots.sh --quick --routes dashboard --size 1100x700` (add `--scratch-path $S12` if the script takes it); report 0 wrap violations.
  - **at most 2 building agents at once.**
- **Model tags:** **[opus]** = money figures, permissions, filed-year-adjacent logic: most capable model plus spec+code review. **[sonnet]** = UI/settings: quick review.
- **Dropping tasks: drop from the end.** Task 4 is droppable alone; Tasks 2–3 are useless without 1.

## Review Focus

1. **Household with no property, no tenancy, no mortgage, or a viewer without Property/Documents/Tax access.** Expect those sections `nil` and their cards absent, never a zero-filled card. Task 1: `testNoPropertyHouseholdHasNoPropertyOrMortgageSection`, `testViewerWithoutAccessSeesNoSections`.
2. **Tax rules for the year missing (`noRulesForYear`), or a person with no income.** Expect the card to say the figures are not available yet, not a crash or £0 "refund". Task 1: `testMissingRulesGivesUnavailableNotZero`.
3. **A month with no tenancy statement, a first tenancy month, or two tenancies.** Expect one row per tenancy by tenancy name, steps "not applicable" counted out of the denominator. Task 1: `testChecklistProgressSkipsNotApplicable`, `testTwoTenanciesTwoRows`.
4. **Mortgage with no balance, no rate or no instalments left (repaid).** Expect missing fields nil and shown as "Not set", a repaid loan hidden. Task 1: `testMortgageMissingFieldsAreNil`, `testRepaidMortgageOmitted`.
5. **Hiding every new card, or a stale hidden-id stored from a removed card.** Expect the page to render the old cards only and unknown ids ignored. Task 2: `testUnknownHiddenIdIgnored`, `testAllHiddenLeavesLegacyCards`.

---

### Task 1 [opus]: `DashboardReview` read model

**Files:**
- Create: `Sources/BudgetCore/Dashboard/DashboardReview.swift`
- Modify: `Sources/BudgetCore/DocumentImport/ImportWaitingList.swift` (add `public static func waitingCount(db: Database) throws -> Int` over the existing internal `waiting(db:)`)
- Test: `Tests/BudgetCoreTests/DashboardReviewTests.swift` (use `TestDatabase`, `DashboardFixture` where it helps)

**Interfaces — Produces:**
```swift
public struct DashboardReview: Equatable, Sendable {
    public struct TaxPosition: Equatable, Sendable {
        public struct PersonLine: Equatable, Identifiable, Sendable {
            public var personId: Int64; public var name: String
            public var status: TaxYearStatus
            public var estimateMinorUnits: Int?        // + due, - refund (SA102 box 2 sign); nil = unavailable
            public var unavailableReason: String?      // "The UK tax rules for 2026/27 aren't in the app yet."
            public var id: Int64 { personId }
        }
        public struct NextPayment: Equatable, Sendable { public var date: Date; public var amountMinorUnits: Int; public var label: String }
        public var year: UKTaxYear
        public var people: [PersonLine]
        public var nextPaymentOnAccount: NextPayment?  // earliest upcoming of the people's `Result.nextPaymentOnAccount` with `year.deadlines`
    }
    public struct PropertyRow: Equatable, Identifiable, Sendable {
        public enum Rent: Equatable, Sendable { case received, late, notDueYet, notApplicable }
        public var tenancyId: Int64; public var tenancyName: String
        public var stepsDone: Int; public var stepsTotal: Int   // total excludes .notApplicable
        public var rent: Rent
        public var statementStatus: String                      // "Sent" / "Drafted" / "Not drafted" / "Not applicable"
        public var id: Int64 { tenancyId }
    }
    public struct EvidenceSummary: Equatable, Sendable {
        public var taxYear: UKTaxYear
        public var missingCount: Int                 // tax items only (excludes Item.isForRecharges), not done, not waived
        public var waitingForPayment: Int            // WaitingDocuments.states == .waiting
        public var linkedSinceLastVisit: Int?        // nil when not derivable (Call 2)
    }
    public struct MortgageSummary: Equatable, Sendable {
        public var propertyName: String
        public var owedMinorUnits: Int?; public var currency: Currency
        public var nextDue: Date?; public var nextInstalmentMinorUnits: Int?
        public var ratePercent: Double?; public var nextReview: Date?
    }
    public var tax: TaxPosition?; public var property: [PropertyRow]?; public var evidence: EvidenceSummary?
    public var mortgages: [MortgageSummary]?; public var importsWaiting: Int
    public var attention: [AttentionLine]
    public struct AttentionLine: Equatable, Identifiable, Sendable { public enum Kind: String, Sendable { case taxDeadline, rentLate, evidenceMissing, documentsWaiting, importsWaiting, mortgageReview }; public var kind: Kind; public var text: String; public var id: String { kind.rawValue } }

    public static func load(db: Database, today: Date, lastVisit: Date?, viewer: AccessActor? = nil) throws -> DashboardReview
}
```

- [ ] **Step 1: Write the failing tests** in `DashboardReviewTests`, synthetic data, injected `today`:
  - `testNoPropertyHouseholdHasNoPropertyOrMortgageSection`: `property == []`/`mortgages == []` only if viewer can see Property and none exist → assert `property == nil` and `mortgages == nil` when there are no properties (card absent), `tax` still present when a person has a tax year record.
  - `testViewerWithoutAccessSeesNoSections`: a member without Property/Documents/Tax → `tax == nil, property == nil, evidence == nil, mortgages == nil`; `importsWaiting` still counted.
  - `testMissingRulesGivesUnavailableNotZero`: tax year with no rules → person line `estimateMinorUnits == nil`, `unavailableReason` = `TaxOverview.selfAssessment`'s message.
  - `testEstimateSignAndNextPayment`: one person, income fixture with known `SelfAssessment.Result` → `estimateMinorUnits` equals the result's balancing figure, `nextPaymentOnAccount.date == year.deadlines.secondPaymentOnAccount` when today is before it, nil after the last deadline.
  - `testChecklistProgressSkipsNotApplicable`: tenancy in its first month (step 1 `.notApplicable`) with 1 done → `stepsDone == 1, stepsTotal == 3`.
  - `testTwoTenanciesTwoRows`: rows carry `tenancyName`; assert no `Tenancy.tenantName` string appears in any `PropertyRow` field or `attention` text.
  - `testRentLateAfterDueDayWithoutCredit`: today after the tenancy's rent day, no linked rent credit this month → `.late`; credit linked → `.received`; before the day → `.notDueYet`.
  - `testEvidenceCountsTaxItemsOnly`: items with `isForRecharges == true` and waived items are excluded from `missingCount`.
  - `testWaitingForPaymentCount`: two waiting documents (step 9 fixture) → `waitingForPayment == 2`; a lapsed one is not counted.
  - `testMortgageMissingFieldsAreNil`, `testRepaidMortgageOmitted`: terms with no rate → `ratePercent == nil`; balance 0 and no instalments left → absent.
  - `testAttentionLines`: late rent, missing evidence, waiting imports and a deadline within 60 days each add one `AttentionLine` with fixed copy ("Rent not received for <tenancy name>", "N tax documents missing", "N files waiting to import", "Payment on account due <date>"); nothing to flag → `attention == []`.
- [ ] **Step 2: Run, expect FAIL** (`DashboardReview` undefined): `swift test --scratch-path $S12 --filter DashboardReviewTests`.
- [ ] **Step 3: Implement `DashboardReview.load`** in `DashboardReview.swift`, composing only existing APIs: `TaxOverview.rows(db:now:)` filtered to `UKTaxYear.containing(today)` for people and status, `TaxOverview.selfAssessment(db:startYear:personId:)` for the estimate and `nextPaymentOnAccount`; `ThisMonthChecklist.build(db:tenancyId:today:trayCount: 0, viewer:)` per active tenancy (`isHidden` → skip); `MissingEvidence.items(db:taxYear:)` filtered `!isForRecharges && !isDone`; `WaitingDocuments.states(db:now:)`; `MortgageRate.status(db:propertyId:today:)` plus `PropertyFinance.balance` over the property's loan accounts for `owed`; `ImportWaitingList.waitingCount`. Permission checks mirror `ThisMonthChecklist`'s `canView(_ area:)`. Rent state: see Call 3.
- [ ] **Step 4: Run, expect PASS**; then full suite; `scripts/build-core-ios.sh` is not run (no building beyond swift test per the lean mandate unless the suite touches it).
- [ ] **Step 5: Commit**
```bash
git add Sources/BudgetCore/Dashboard/DashboardReview.swift Sources/BudgetCore/DocumentImport/ImportWaitingList.swift Tests/BudgetCoreTests/DashboardReviewTests.swift
git commit -m "Dashboard review: read model for tax, property, evidence, mortgage and waiting imports"
```

### Task 2 [sonnet]: Card visibility setting and view-model wiring

**Files:**
- Create: `Sources/BudgetCore/Dashboard/DashboardCardVisibility.swift`
- Modify: `App/Settings/SettingsView.swift` (inside `AppearanceSettings`, line ~143: a "Dashboard cards" `GroupBox` with one `Toggle` per `DashboardCardVisibility.Card`), `App/Dashboard/DashboardViewModel.swift` (`DashboardContent.review: DashboardReview`, loaded inside the existing `dbQueue.read`; `lastVisit` from `UserDefaults` `dashboardLastVisit`, updated when the Dashboard disappears)
- Test: `Tests/BudgetCoreTests/DashboardCardVisibilityTests.swift`

**Interfaces — Produces:**
```swift
public struct DashboardCardVisibility: Equatable, Sendable {
    public enum Card: String, CaseIterable, Sendable { case taxYear, propertyMonth, evidence, mortgage
        public var title: String }          // "Tax year position", "Property month", "Evidence and documents", "Mortgage"
    public var hidden: Set<Card>
    public init(stored: [String]?)         // unknown ids dropped
    public var stored: [String] { get }
    public func shows(_ card: Card) -> Bool
    public static let storageKey = "dashboardHiddenCards"
}
```
- [ ] **Step 1: Failing tests:** `testDefaultShowsAll`, `testRoundTrip`, `testUnknownHiddenIdIgnored`, `testAllHiddenLeavesLegacyCards` (all four hidden → `Card.allCases.allSatisfy { !shows($0) }`; `stored` has four ids).
- [ ] **Step 2: Run** `swift test --scratch-path $S12 --filter DashboardCardVisibilityTests`, expect FAIL.
- [ ] **Step 3: Implement** the struct; in the Appearance pane bind through `@AppStorage(DashboardCardVisibility.storageKey)` storing a comma-joined string (the pane re-reads on change; the Dashboard observes the same key with `@AppStorage`); extend `DashboardViewModel.load` as above. The Appearance pane's `sized(.appearance)` height grows to fit four toggles.
- [ ] **Step 4: Run tests PASS; Mac build.**
- [ ] **Step 5: Commit** (`git add` the four files; message "Dashboard review: per-device card visibility and review loading").

### Task 3 [sonnet]: The four cards, ordered

**Files:**
- Create: `App/Dashboard/TaxYearPositionCard.swift`, `App/Dashboard/PropertyMonthCard.swift`, `App/Dashboard/EvidenceDocumentsCard.swift`, `App/Dashboard/MortgageCard.swift`
- Modify: `App/Dashboard/DashboardView.swift` (order per spec: freshness → current month → tax year → property month → evidence → net worth → rest as today; mortgage after accounts; each wrapped in `if let` section and `visibility.shows(...)`), reuse `DashboardCard`, `DashboardFormat`, `PaceMeter`, and `TwoUpRow`
- Test: snapshot routes only (no logic to unit test); `Tests/BudgetCoreTests` unchanged.

**Interfaces — Consumes:** `DashboardContent.review` (Task 1), `DashboardCardVisibility` (Task 2), `navigate: (AppScreen) -> Void`.

- [ ] **Step 1: Build each card from `DashboardCard`** with these links: Tax year → `.taxYears`; Property month → `.property`; Evidence and documents → `.missingEvidence` (missing count) and `.documents` (waiting); Mortgage → `.property`. Copy: tax line "Estimated tax due"/"Estimated refund" with `Money` formatting from `DashboardFormat`, "Not available yet" for nil estimates, status text from `TaxYearStatus.displayName`; property rows "<tenancy name> · N of M steps · Rent received|late|due"; evidence "N missing", "N waiting for their payment", "N linked since your last visit" only when non-nil; mortgage "Owed", "Next instalment <date> <amount>", "Rate x.xx% · review <date>", "Not set" for nil. Place the two property/mortgage cards two-up where space allows via `TwoUpRow`.
- [ ] **Step 2: Mac build** (Global Constraints command), expect BUILD SUCCEEDED.
- [ ] **Step 3: Snapshots:** `scripts/render-snapshots.sh --quick --routes dashboard --size 1100x700` with the demo database (BudgetDemo has tax, property, mortgage); open the PNGs, confirm the four cards present, no wrapped figure, names truncated in the middle, 0 wrap violations. Also render with all four hidden: legacy page only.
- [ ] **Step 4: Full suite** `swift test --scratch-path $S12 --parallel`.
- [ ] **Step 5: Commit** (`git add App/Dashboard`; "Dashboard review: tax year, property month, evidence and mortgage cards").

### Task 4 [sonnet]: Needs attention absorbs the new signals; import-waiting button (droppable)

**Files:**
- Modify: `App/Dashboard/SmallCards.swift` (`AttentionCard` gets `extra: [DashboardReview.AttentionLine]` rendered after the existing rows, each a link: `taxDeadline` → `.taxYears`, `rentLate` → `.property`, `evidenceMissing` → `.missingEvidence`, `documentsWaiting` → `.documents`, `importsWaiting` → `.imports`, `mortgageReview` → `.property`), `App/Dashboard/FreshnessImportCard.swift` (a line "N waiting for the Mac to import" with an "Import" button calling `navigate(.imports)`, shown only when `importsWaiting > 0`), `App/Dashboard/DashboardView.swift` (pass the lines)
- [ ] **Step 1:** Implement as above; the card's "all clear" empty state shows only when both old and new lists are empty.
- [ ] **Step 2: Mac build** passes; **Snapshots** as Task 3 plus a demo state with waiting imports (seed via `ImportWaitingList` fixture in BudgetDemo only if one exists, else a code-level `DashboardReview` preview value); 0 wrap violations.
- [ ] **Step 3: Full suite, commit** ("Dashboard review: attention list and waiting imports").

---

## Calls extending or contradicting the spec

1. **Dependency on step 9:** `WaitingDocuments` is not in the tree yet; Task 1 requires step 9 merged first. If it is not, `waitingForPayment` is 0 and its test is skipped (extends).
2. **"Documents linked automatically since the last visit"** has no stored event (step 9 keeps no auto-link log, only `autoLinkDeclined`). `linkedSinceLastVisit` is derived only if the document link record carries a creation time; otherwise nil and the row is omitted. Not invented storage; contradicts the spec only in that the row may be absent.
3. **Rent received/late** has no ready read model; derived from the month's linked rent credit vs the tenancy's rent day (extends, because the spec lists it without a source).
4. **Attention list** is a separate array on the review model rather than extending `AttentionItems`, to keep the existing `DashboardCalculator` untouched (extends).
5. **Visibility covers only the four new cards** (the old ones always show), and a nil section hides its card regardless of the setting (extends: the spec says "each new card").
6. **`ThisMonthChecklist` is built with `trayCount: 0`** (the downloads tray is iPad-only), so the Dashboard counts only done/needsYou/waiting steps (extends).
