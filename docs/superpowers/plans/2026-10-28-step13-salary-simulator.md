# Step 13: UK take-home salary simulator — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (chosen) to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** compare two UK salaries ("Current" and "Offer") in take-home terms on Mac, iPad and iPhone, from versioned UK tax rules, with "Current" prefilled from the person's latest P60/payslip.

**Architecture:**
- **BudgetCore owns everything that is arithmetic or state:** `Sources/BudgetCore/Salary/` holds the rules table (`SalaryRules`), the calculator (`SalaryCalculator`), the comparison (`SalaryComparison`), the observable view model (`SalaryComparisonViewModel`), the prefill (`SalaryPrefill`) and the per-device draft store (`SalaryDraftStore`). Views only render and call them.
- **Pure and annual:** inputs in, `SalaryResult` out, no database, no clock, no payroll rounding (annual calculation, per month = year / 12, per week = year / 52). The existing `UKTaxRules` (England only, SA-oriented: dividends, savings) is not extended; `SalaryRules` is separate and may read the shared bands from it for tests only.
- **Nothing syncs, nothing writes the DB.** Drafts are per-device `UserDefaults` JSON. Step 14 builds on `SalaryResult` and `SalaryComparisonInputs` (both `Codable`).

**Tech Stack:** Swift 6, SwiftUI, Observation, Swift Charts, XCTest, XcodeGen.

**Spec:** `docs/superpowers/specs/2026-10-28-step13-salary-simulator-design.md` (binding; *(my call)* items there are accepted). Previous plan (style, commands): `2026-10-27-step10-ipad-property.md`. Step 14 (`2026-10-28-step14-job-offer-forecast.md`) consumes Task 1 and Task 2's types, so their names are fixed here.

## Global Constraints

- **Logic and rules in BudgetCore** (`Sources/BudgetCore/Salary/`), pure, no `Database`, no `Date()` inside the calculator. `scripts/build-core-ios.sh` stays green.
- **Amounts are pence (`Int`); rates are basis points (2 000 = 20%)**, as in `UKTaxRules`. Annual calculation; per month = year / 12, per week = year / 52; no payroll rounding.
- **Rules table is versioned per tax year and region, with the source (GOV.UK page) noted per value group.** Ship 2025/26 and 2026/27. **Values that cannot be verified offline are marked `check: true` in the table and listed in the task's report** for the user to confirm before relying on them.
- **At least 12 worked-example tests** (England, Scotland, the 60% zone, pension methods, student loan plans incl. postgraduate, BIK, K code).
- **Region:** England, Wales & Northern Ireland, or Scotland (income tax bands differ; NI doesn't).
- **Tax code:** default `1257L`; free-text override; K codes and BR/D0/D1/NT supported, simple parsing.
- **Not tax advice:** one line on every screen says it is an estimate.
- **Fits 1100×700 on Mac; 11" and 13" iPad portrait and landscape; iPhone.** No figure wraps or truncates; names truncate in the middle (`.lineLimit(1).truncationMode(.middle)`).
- **Nothing synced, no DB write, no effect on budget or tax figures.** No new CloudKit record type or field.
- **Tenant's personal name appears nowhere here.** Nothing personal committed (synthetic employers/amounts in tests).
- **Tests never touch the real DB, Keychain, iCloud or `/Applications`.** Use `TestDatabase` for the prefill test only; drafts use `UserDefaults(suiteName:)` with a unique suite removed in `tearDown`. No subagent runs `scripts/install-app.sh`.
- **Build the App/Phone targets with `xcodebuild`** (`scripts/build-phone.sh`, Mac build below) for any task touching `App/`, `Sources/MangoUI/`, `project.yml`.
- **Commands** (`S13=/tmp/mango-13-build`, outside `~/Documents` because of iCloud CodeSign issues):
  - targeted: `swift test --scratch-path $S13 --filter '<Tests>'`
  - full suite, once at the end of each task: `swift test --scratch-path $S13 --parallel`
  - phone/iPad build: `scripts/build-phone.sh`
  - Mac build: `xcodegen generate && xcodebuild -project Mango.xcodeproj -scheme Mango -configuration Debug -derivedDataPath $S13/dd CODE_SIGNING_ALLOWED=NO build`
  - snapshots: `scripts/render-phone-snapshots.sh $S13/snaps [--device ipad] --only <routes>`
  - **at most 2 building agents at once.**
- **Model tags:** **[opus]** = tax logic: most capable model plus a spec+code review. **[sonnet]** = UI/plumbing: quick review.
- **Dropping tasks: drop from the end.** Task 4 (prefill, drafts) is the first to go; Tasks 1–2 alone are a working Mac simulator. The whole step is droppable last in the unattended run.

## Review Focus

1. **Salary of £0, or below the personal allowance.** Expect zeros, never negative tax or NI, no division by zero in effective rate or "keep £x of each £1". Task 1: `testZeroAndBelowAllowance`.
2. **Pension larger than the salary, or a fixed pension amount above gross.** Expect it capped at gross (take-home 0, nothing negative). Task 1: `testPensionCappedAtGross`.
3. **Tax code the parser cannot read ("abc", "", lower case "1257l", "S1257L", "C1257L", emergency "1257L W1").** Expect trimmed and upper-cased, S/C prefixes accepted (S does not change the region the person picked), W1/M1/X suffix ignored, anything else falls back to 1257L with a visible "Using 1257L: couldn't read that code" notice. Task 1: `testTaxCodeParsing`.
4. **Tax year not in the table (a year after 2026/27).** Expect the latest year used with a notice, never a crash. Task 1: `testUnknownYearFallsBackWithNotice`.
5. **Both salaries identical, or Offer lower than Current.** Expect a zero difference and "no change", or a negative difference worded "less", never "+-£". Task 2: `testIdenticalAndNegativeDifference`.

---

### Task 1 [opus]: Rules table and calculator, with worked examples

**Files:**
- Create: `Sources/BudgetCore/Salary/SalaryRules.swift`, `SalaryInputs.swift`, `SalaryCalculator.swift`, `TaxCodeParser.swift`
- Test: `Tests/BudgetCoreTests/SalaryCalculatorTests.swift`, `SalaryRulesTests.swift`, `TaxCodeParserTests.swift`

**Interfaces:**
- Produces (all `public`, `Codable, Equatable, Sendable`):
  - `enum SalaryRegion: String { case englandWalesNI, scotland }`
  - `enum PensionMethod: String { case salarySacrifice, netPay, reliefAtSource }`
  - `enum PensionAmount { case percentOfGross(basisPoints: Int), fixedAnnual(pence: Int) }` (`Codable` by hand or synthesized)
  - `enum StudentLoanPlan: String, CaseIterable { case plan1, plan2, plan4, plan5 }`
  - `struct SalaryInputs { grossAnnual: Int; bonusAnnual: Int; taxYearStart: Int; region: SalaryRegion; taxCode: String; pension: PensionAmount; pensionMethod: PensionMethod; employerPension: PensionAmount; studentLoan: StudentLoanPlan?; postgraduateLoan: Bool; benefitsInKindAnnual: Int }` with `init(...)` defaults: bonus 0, `taxCode "1257L"`, pension `.percentOfGross(0)`, `.netPay`, loans none, BIK 0, `taxYearStart` required.
  - `struct SalaryResult { inputs; notices: [String]; effectiveTaxYear: Int; personalAllowance: Int; incomeTaxByBand: [BandAmount]; incomeTax, employeeNI, studentLoan, postgraduateLoan, employeePension, employerPension, benefitsInKindTax: Int; takeHomeAnnual: Int; takeHomeMonthly: Int; takeHomeWeekly: Int; effectiveRateBP: Int; marginalRateBP: Int }` and `struct BandAmount { name: String; rateBP: Int; taxable: Int; tax: Int }`
  - `struct SalaryRules { static func forYear(_ start: Int) -> SalaryRules?; static var latest: SalaryRules; static var all: [SalaryRules] }` with a `sources: [UKTaxRules.Source]` and `checkedFields: [String]` (the "check" values).
  - `enum SalaryCalculator { static func calculate(_ inputs: SalaryInputs) -> SalaryResult }` (marginal rate = take-home change for +£100 gross, as basis points of that £100, rounded; "keep per extra £1" is `10_000 - marginalRateBP`).
  - `struct TaxCode { enum Kind { case standard(allowance: Int), k(addition: Int), br, d0, d1, nt, zeroT }; static func parse(_ text: String) -> (code: TaxCode, notice: String?) }` (allowance = digits × 10 pounds + 9 for L, as HMRC; for 1257L the allowance is £12,570 exactly: use the table's personal allowance when the code is the default, else digits × 1000 pence).

- [ ] **Step 1: Write the rules tests.** `SalaryRulesTests`: `testTablesExistFor2025And2026`, `testEveryTableHasSources`, `testCheckedFieldsListed` (asserts `SalaryRules.forYear(2026)!.checkedFields` is non-empty and every name in it is a real stored property name via a `Mirror` check) and `testUnknownYearIsNil`.
- [ ] **Step 2: Write the 15 worked-example tests** in `SalaryCalculatorTests`, each asserting `incomeTax`, `employeeNI`, `takeHomeAnnual` exactly (pence), taxYearStart 2025, England unless stated, tax code 1257L. Hand-computed from the 2025/26 rules (PA £12,570, basic band £37,700, additional threshold £125,140, taper above £100,000, NI 8% between £12,570 and £50,270 and 2% above):
  1. `testExample30k`: £30,000 → tax £3,486.00, NI £1,394.40, take-home £25,119.60, month £2,093.30, marginal 2 800 bp.
  2. `testExample60k`: £60,000 → tax £11,432.00, NI £3,210.60, take-home £45,357.40, marginal 4 200 bp.
  3. `testExample110kTaperZone`: £110,000 → PA £7,570, tax £33,432.00, NI £4,210.60, take-home £72,357.40, marginal 6 200 bp (60% tax + 2% NI).
  4. `testExample125140`: → PA 0, tax £42,516.00, NI £4,513.40, take-home £78,110.60.
  5. `testSalarySacrifice5pc60k`: pension `.percentOfGross(500)`, `.salarySacrifice` → gross for tax and NI £57,000: tax £10,232.00, NI £3,150.60, employeePension £3,000.00, take-home £43,617.40.
  6. `testNetPay5pc60k`: `.netPay` → tax £10,232.00, NI £3,210.60 (NI on full pay), take-home £43,557.40.
  7. `testReliefAtSource5pc60k`: `.reliefAtSource` → employee pays £2,400.00 (80% of the £3,000 gross contribution; the pot gets £3,000), basic-rate band extended by £3,000: tax £10,832.00, NI £3,210.60, take-home £43,557.40.
  8. `testTaperRestoredBySacrifice`: £110,000, `.fixedAnnual(1_000_000)` sacrifice → tax gross £100,000 so PA £12,570: tax £27,432.00.
  9. `testScotland40k`: `.scotland`, £40,000 → tax £5,582.82 (starter 19% on £2,827; basic 20% to £14,921 taxable; intermediate 21% to £31,092; bands as taxable income above PA), NI £2,194.40, take-home £32,222.78.
  10. `testPlan2Loan40k`: `.plan2` → loan £1,037.70 (9% above £28,470), tax £5,486.00, NI £2,194.40, take-home £31,281.90.
  11. `testPostgraduatePlusPlan2`: £40,000, `.plan2` + postgraduate → postgraduate £1,140.00 (6% above £21,000), take-home £30,141.90.
  12. `testBIK`: £50,000 with BIK £3,000 → tax on £53,000 = £8,632.00, NI £3,016.00 (BIK is not NI-able for the employee), take-home £38,352.00 (BIK is not cash).
  13. `testKCode`: £30,000, code `K475` → taxable £34,750: tax £6,950.00, NI £1,394.40, take-home £21,655.60.
  14. `testBRCode`: `BR` on £30,000 → tax £6,000.00 flat 20%, no allowance.
  15. `testBonusEqualsSalary`: £50,000 + bonus £10,000 gives the same result as £60,000 and `incomeTax` for example 2.
  Also `testPlan1Plan4Plan5Thresholds` (one assert each at 2025/26 thresholds £26,065 / £32,745 / £25,000, 9%), `testEmployerPensionNotInTakeHome`, `testWeeklyAndMonthly`.
- [ ] **Step 3: Write the review-focus tests** named in Review Focus 1–4 (`testZeroAndBelowAllowance`, `testPensionCappedAtGross`, `testTaxCodeParsing`, `testUnknownYearFallsBackWithNotice`).
- [ ] **Step 4: Run to see them fail.** `swift test --scratch-path $S13 --filter 'Salary|TaxCodeParser'` → FAIL (types missing).
- [ ] **Step 5: Implement `SalaryRules`.** One `static let y2025`, `y2026` (struct literal, not computed). Stored: `personalAllowance`, `taperThreshold` (£100,000), `taperRateNumerator/Denominator` (£1 per £2), `basicRateBand`, `additionalThreshold`, three rUK rates + `scottishBands: [(upToTaxable: Int?, rateBP: Int, name: String)]`, NI (`niPrimaryThreshold`, `niUpperEarningsLimit`, `niMainRateBP` 800, `niUpperRateBP` 200), student loan thresholds per plan + rate 900, postgraduate threshold + rate 600, `reliefAtSourceRateBP` 2 000. Values with `check: true`: **all of 2026/27** (frozen thresholds assumed equal to 2025/26 except student loan thresholds Plan 1 £26,900, Plan 2 £29,385, Plan 4 £33,795, Plan 5 £25,000, postgraduate £21,000; NI main rate assumed 8%), the 2026/27 Scottish bands, and for 2025/26 the Scottish band edges (£2,827 / £14,921 / £31,092 / £62,430 taxable) and Plan 4/Plan 5 thresholds; list them in `checkedFields` by property name and in the task report. GOV.UK sources: income-tax-rates, rates-and-thresholds-for-employers-2025-to-2026, repayment-and-interest-rate-thresholds (student loans), scottish-income-tax.
- [ ] **Step 6: Implement `TaxCode.parse` and `SalaryCalculator.calculate`.** Order: gross for tax = gross + bonus − (salary sacrifice) + BIK (± K addition); `.reliefAtSource` extends the basic band by the gross contribution and the person pays 80%; `.netPay` deducts from taxable pay only; taper computed on adjusted net income (taxable pay less net-pay and relief-at-source gross contributions); NI on gross + bonus − salary sacrifice; student loan on gross + bonus − salary sacrifice (not net-pay pension); pension capped at gross. Round each component to pence half-up at the end, not mid-way.
- [ ] **Step 7: Run targeted tests, then the full suite and `scripts/build-core-ios.sh`.** Expected: all PASS; "actor writes" check not needed (no writes).
- [ ] **Step 8: Commit.** `git add Sources/BudgetCore/Salary Tests/BudgetCoreTests/Salary*Tests.swift Tests/BudgetCoreTests/TaxCodeParserTests.swift && git commit -m "Step 13 task 1: UK salary rules and calculator"`.

### Task 2 [sonnet]: Shared comparison view model and the Mac screen

**Files:**
- Create: `Sources/BudgetCore/Salary/SalaryComparison.swift`, `SalaryComparisonViewModel.swift`; `App/Salary/SalarySimulatorView.swift`, `App/Salary/SalaryColumnView.swift`
- Modify: `App/ContentView.swift` (add `AppScreen.salary = "Salary simulator"`, icon `sterlingsign.circle`, group "Overview", next to `.forecast`, its detail case)
- Test: `Tests/BudgetCoreTests/SalaryComparisonTests.swift`

**Interfaces:**
- Consumes: Task 1 `SalaryInputs`, `SalaryResult`, `SalaryCalculator.calculate`.
- Produces: `struct SalaryComparison { current: SalaryResult; offer: SalaryResult; monthlyDifference: Int; annualDifference: Int; keepPerExtraPound: Int /* pence kept of each extra £1 gross, offer side */; static func make(current:offer:) }`; `@MainActor @Observable final class SalaryComparisonViewModel { var current: SalaryInputs; var offer: SalaryInputs; private(set) var comparison: SalaryComparison; var ready: (current: Bool, offer: Bool); func reset(); init(current: SalaryInputs = .typicalCurrent(), offer: SalaryInputs? = nil) }` (offer defaults to current; `comparison` recomputed on every input change; `SalaryInputs.typicalCurrent(taxYearStart:)` defaults the tax year to the table's latest year that has started, via an injected `today: Date`). Plus `SalaryBarSegments.segments(_ result:) -> [(label: String, pence: Int)]` (take-home, income tax, NI, loans, pension) for the chart.

- [ ] **Step 1: Write failing tests** in `SalaryComparisonTests`: `testDifferenceFromTwoSalaries` (30k vs 60k: monthly diff £2,000.60+... assert `annualDifference == 4_523_780 - ... ` computed from Task 1 examples 1 and 2: £45,357.40 − £25,119.60 = £20,237.80/yr, month £1,686.48 rounded half-up), `testKeepPerExtraPound` (60k offer → 5 800 bp kept), `testIdenticalAndNegativeDifference` (difference 0; offer lower gives negative), `testViewModelRecomputesOnInputChange`, `testSegmentsSumToGross`.
- [ ] **Step 2: Run to see them fail**, `swift test --scratch-path $S13 --filter SalaryComparison`.
- [ ] **Step 3: Implement the BudgetCore types** above.
- [ ] **Step 4: Run and see them pass.**
- [ ] **Step 5: Build `SalarySimulatorView`** (Mac): two columns "Current" / "Offer" of `SalaryColumnView` (form: gross, bonus, tax year picker, region picker, tax code field with parse notice, pension % or £ + method + employer, student loan picker + postgraduate toggle, BIK) and a results panel under each (take-home per year/month/week, breakdown rows, personal allowance, effective and marginal rate) plus a centre comparison strip (difference per month and year, "of each extra £1 gross you keep £x") and a Swift Charts stacked bar "where the money goes". Numbers `.monospacedDigit().lineLimit(1).minimumScaleFactor(1)`; fits 1100×700 by letting the form scroll while the strip stays pinned. Footer line: "An estimate from published UK rates, not tax advice." Show each result's `notices` and, for any year whose rules have `checkedFields`, a muted "Rates for 2026/27 not yet confirmed" line.
- [ ] **Step 6: Wire the sidebar item** in `ContentView.swift`.
- [ ] **Step 7: Mac build** (command above) → BUILD SUCCEEDED; run the Mac snapshot script if it supports a route for the screen, else skip; then full suite.
- [ ] **Step 8: Commit.** `git add Sources/BudgetCore/Salary App/Salary App/ContentView.swift Tests/BudgetCoreTests/SalaryComparisonTests.swift && git commit -m "Step 13 task 2: salary comparison and Mac screen"`.

### Task 3 [sonnet]: iPad and iPhone screens

**Files:**
- Create: `Sources/MangoUI/Salary/SalarySimulatorScreen.swift` (shared by iPad and iPhone, adaptive: side by side at regular width, a "Current | Offer" segmented switch with a pinned comparison strip at compact width)
- Modify: `Sources/MangoUI/Pad/PadSection.swift` (`case salary`, title "Salary simulator", image `sterlingsign.circle`, in the "Everything else" group before `.evidence`), `Sources/MangoUI/Pad/PadRoutes.swift` (route to the screen), `Sources/MangoUI/Settings/SettingsSheet.swift` (a "Tools" section with a "Salary simulator" row, passed in as `onOpenSalary: (() -> Void)?` like the other optional closures), the phone host that presents Settings (find with `grep -rn "SettingsSheet(" Sources App`)
- Test: `Tests/MangoUITests/PadSectionTests.swift` (extend or create beside the existing sidebar tests)

**Interfaces:** Consumes Task 2 `SalaryComparisonViewModel`, `SalaryBarSegments`. Produces `SalarySimulatorScreen(viewModel:)`.

- [ ] **Step 1: Write failing tests:** `testSalaryIsInEverythingElseGroup` (`PadSection.groups(hasProperty:)` last group contains `.salary`, with and without property) and `testSalaryNotAPropertySection` (`requiresProperty == false`).
- [ ] **Step 2: Run to see them fail**, `swift test --scratch-path $S13 --filter PadSection`.
- [ ] **Step 3: Add the section, route and Settings row;** build `SalarySimulatorScreen` from the Task 2 view model with touch-sized controls and the decimal keyboard for amounts.
- [ ] **Step 4: Run tests, then `scripts/build-phone.sh`** → build succeeds.
- [ ] **Step 5: Render** `scripts/render-phone-snapshots.sh $S13/snaps --device ipad --only salary` at 11"/13" portrait and landscape and iPhone default; report 0 wrap violations (extend the harness's route list if it needs the new route).
- [ ] **Step 6: Full suite; commit.** `git add Sources/MangoUI Tests/MangoUITests && git commit -m "Step 13 task 3: salary simulator on iPad and iPhone"`.

### Task 4 [sonnet]: Prefill from payslip/P60 and per-device drafts

**Files:**
- Create: `Sources/BudgetCore/Salary/SalaryPrefill.swift`, `SalaryDraftStore.swift`
- Modify: `SalaryComparisonViewModel.swift` (load/save drafts, "Reset to my latest pay" action), the three screens (a "Use my latest payslip/P60" button on the Current column, hidden when there is nothing)
- Test: `Tests/BudgetCoreTests/SalaryPrefillTests.swift`, `SalaryDraftStoreTests.swift`

**Interfaces:**
- Consumes: `Employment`, `EmploymentIncome`, `EmploymentIncomeSource` (`.p60`, `.payslip`), Task 2 view model.
- Produces: `enum SalaryPrefill { static func latest(db: Database, personId: Int64, today: Date) throws -> SalaryInputs? }`; `struct SalaryDraftStore { init(defaults: UserDefaults = .standard, key: String = "salarySimulatorDraft.v1"); func load() -> SalaryDraft?; func save(_ draft: SalaryDraft); func clear() }`; `struct SalaryDraft: Codable, Equatable { current: SalaryInputs; offer: SalaryInputs }`.

- [ ] **Step 1: Write failing tests.** `SalaryPrefillTests` (with `TestDatabase`): `testPrefersLatestP60` (gross = `payMinorUnits` of the highest-year P60, tax code carried, region England), `testPayslipAnnualisedByPeriodEnd` (a payslip with `periodEnd` 5 July is year-to-date for 3 months of the UK tax year: gross = pay × 12 / 3), `testNothingWhenNoIncome` (nil), `testOtherPersonIgnored`. `SalaryDraftStoreTests`: `testRoundTrip`, `testCorruptDataIgnored` (load returns nil, no crash), `testClear`.
- [ ] **Step 2: Run to see them fail.**
- [ ] **Step 3: Implement.** Pension is not stored on payslips: the prefill leaves pension at 0 and the button's confirmation line says "Pension and student loan aren't on your payslip data; check them." Nothing saves back to the DB. Drafts save on every change (debounced 0.5 s in the view model), never synced; the draft wins over prefill until Reset.
- [ ] **Step 4: Run tests, then the Mac build and `scripts/build-phone.sh`.**
- [ ] **Step 5: Full suite; commit.** `git add Sources Tests && git commit -m "Step 13 task 4: salary prefill and drafts"`.

## Controller-only (after the last task, not subagents)

Report the `checkedFields` list to the user; merge to main, `xcodegen generate`, then `scripts/install-app.sh` (memory: auto-install after merges).
