import XCTest
@testable import BudgetCore

/// Worked examples, hand-computed from the 2025/26 rules: personal allowance £12,570 (down £1 per
/// £2 of adjusted net income above £100,000), basic band £37,700 of taxable income at 20%,
/// higher 40%, additional 45% above £125,140 taxable; employee NI 8% from £12,570 to £50,270 and
/// 2% above. Amounts are pence.
final class SalaryCalculatorTests: XCTestCase {
    private func calc(_ gross: Int, year: Int = 2025, _ configure: (inout SalaryInputs) -> Void = { _ in }) -> SalaryResult {
        var inputs = SalaryInputs(grossAnnual: gross, taxYearStart: year)
        configure(&inputs)
        return SalaryCalculator.calculate(inputs)
    }

    // MARK: Worked examples

    func testExample30k() {
        // Taxable 30,000 − 12,570 = 17,430 × 20% = 3,486.00
        // NI (30,000 − 12,570) × 8% = 1,394.40
        // Take-home 30,000 − 3,486 − 1,394.40 = 25,119.60; / 12 = 2,093.30
        // +£100: tax +20, NI +8 → keeps 72 → marginal 28%
        let r = calc(3_000_000)
        XCTAssertEqual(r.incomeTax, 348_600)
        XCTAssertEqual(r.employeeNI, 139_440)
        XCTAssertEqual(r.takeHomeAnnual, 2_511_960)
        XCTAssertEqual(r.takeHomeMonthly, 209_330)
        XCTAssertEqual(r.marginalRateBP, 2_800)
        XCTAssertEqual(r.keepPerExtraPoundBP, 7_200)
        XCTAssertEqual(r.personalAllowance, 1_257_000)
        XCTAssertEqual(r.notices, [])
    }

    func testExample60k() {
        // Taxable 47,430: 37,700 × 20% = 7,540 + 9,730 × 40% = 3,892 → 11,432.00
        // NI 37,700 × 8% = 3,016 + (60,000 − 50,270) 9,730 × 2% = 194.60 → 3,210.60
        // Take-home 60,000 − 11,432 − 3,210.60 = 45,357.40; marginal 40% + 2% = 42%
        let r = calc(6_000_000)
        XCTAssertEqual(r.incomeTax, 1_143_200)
        XCTAssertEqual(r.employeeNI, 321_060)
        XCTAssertEqual(r.takeHomeAnnual, 4_535_740)
        XCTAssertEqual(r.marginalRateBP, 4_200)
        XCTAssertEqual(r.incomeTaxByBand, [
            BandAmount(name: "Basic", rateBP: 2_000, taxable: 3_770_000, tax: 754_000),
            BandAmount(name: "Higher", rateBP: 4_000, taxable: 973_000, tax: 389_200)
        ])
    }

    func testExample110kTaperZone() {
        // PA 12,570 − (110,000 − 100,000) / 2 = 7,570; taxable 102,430
        // Tax 7,540 + (102,430 − 37,700) 64,730 × 40% = 25,892 → 33,432.00
        // NI 3,016 + (110,000 − 50,270) 59,730 × 2% = 1,194.60 → 4,210.60
        // Take-home 110,000 − 33,432 − 4,210.60 = 72,357.40
        // +£100: PA −50 so taxable +150 × 40% = 60, NI +2 → 62%
        let r = calc(11_000_000)
        XCTAssertEqual(r.personalAllowance, 757_000)
        XCTAssertEqual(r.incomeTax, 3_343_200)
        XCTAssertEqual(r.employeeNI, 421_060)
        XCTAssertEqual(r.takeHomeAnnual, 7_235_740)
        XCTAssertEqual(r.marginalRateBP, 6_200)
        XCTAssertEqual(r.notices, [], "the default code is tapered from the table, no notice")
    }

    func testTypedCodeAlreadyTaperedIsNotTaperedAgain() {
        // HMRC's code for 115,000: 12,570 − 7,500 = 5,070 → 507L. Kept as given, not cut again to 0.
        let r = calc(11_500_000) { $0.taxCode = "507L" }
        XCTAssertEqual(r.personalAllowance, 507_000)
        XCTAssertEqual(r.notices, [SalaryCalculator.typedCodeTaperNotice])
    }

    func testTypedCodeCappedAtTaperedAllowance() {
        // 1185L (an adjustment of −720) on 110,000: never more than the tapered 7,570.
        let r = calc(11_000_000) { $0.taxCode = "1185L" }
        XCTAssertEqual(r.personalAllowance, 757_000)
        XCTAssertEqual(r.notices, [SalaryCalculator.typedCodeTaperNotice])
        // Below 100,000 the typed code is used as it is, with no notice.
        let low = calc(6_000_000) { $0.taxCode = "1185L" }
        XCTAssertEqual(low.personalAllowance, 1_185_000)
        XCTAssertEqual(low.notices, [])
    }

    func testExample125140() {
        // PA 0; taxable 125,140: 7,540 + (125,140 − 37,700) 87,440 × 40% = 34,976 → 42,516.00
        // NI 3,016 + (125,140 − 50,270) 74,870 × 2% = 1,497.40 → 4,513.40
        // Take-home 125,140 − 42,516 − 4,513.40 = 78,110.60; +£100: 45% + 2% = 47%
        let r = calc(12_514_000)
        XCTAssertEqual(r.personalAllowance, 0)
        XCTAssertEqual(r.incomeTax, 4_251_600)
        XCTAssertEqual(r.employeeNI, 451_340)
        XCTAssertEqual(r.takeHomeAnnual, 7_811_060)
        XCTAssertEqual(r.marginalRateBP, 4_700)
    }

    func testSalarySacrifice5pc60k() {
        // Pension 5% × 60,000 = 3,000 sacrificed → pay for tax and NI 57,000
        // Tax: taxable 44,430: 7,540 + 6,730 × 40% = 2,692 → 10,232.00
        // NI 3,016 + (57,000 − 50,270) 6,730 × 2% = 134.60 → 3,150.60
        // Take-home 60,000 − 3,000 − 10,232 − 3,150.60 = 43,617.40
        let r = calc(6_000_000) { $0.pension = .percentOfGross(basisPoints: 500); $0.pensionMethod = .salarySacrifice }
        XCTAssertEqual(r.incomeTax, 1_023_200)
        XCTAssertEqual(r.employeeNI, 315_060)
        XCTAssertEqual(r.employeePension, 300_000)
        XCTAssertEqual(r.takeHomeAnnual, 4_361_740)
    }

    func testNetPay5pc60k() {
        // Taxable pay 57,000 → tax 10,232.00 (as above); NI on the full 60,000: 3,210.60
        // Take-home 60,000 − 3,000 − 10,232 − 3,210.60 = 43,557.40
        let r = calc(6_000_000) { $0.pension = .percentOfGross(basisPoints: 500); $0.pensionMethod = .netPay }
        XCTAssertEqual(r.incomeTax, 1_023_200)
        XCTAssertEqual(r.employeeNI, 321_060)
        XCTAssertEqual(r.employeePension, 300_000)
        XCTAssertEqual(r.takeHomeAnnual, 4_355_740)
    }

    func testReliefAtSource5pc60k() {
        // Gross contribution 3,000; employee pays 80% = 2,400; basic band 37,700 + 3,000 = 40,700
        // Taxable 47,430: 40,700 × 20% = 8,140 + 6,730 × 40% = 2,692 → 10,832.00
        // NI 3,210.60; take-home 60,000 − 2,400 − 10,832 − 3,210.60 = 43,557.40
        let r = calc(6_000_000) { $0.pension = .percentOfGross(basisPoints: 500); $0.pensionMethod = .reliefAtSource }
        XCTAssertEqual(r.employeePension, 240_000)
        XCTAssertEqual(r.incomeTax, 1_083_200)
        XCTAssertEqual(r.employeeNI, 321_060)
        XCTAssertEqual(r.takeHomeAnnual, 4_355_740)
    }

    func testTaperRestoredBySacrifice() {
        // 110,000 − 10,000 sacrificed = 100,000 → no taper, PA 12,570; taxable 87,430
        // Tax 7,540 + (87,430 − 37,700) 49,730 × 40% = 19,892 → 27,432.00
        let r = calc(11_000_000) { $0.pension = .fixedAnnual(pence: 1_000_000); $0.pensionMethod = .salarySacrifice }
        XCTAssertEqual(r.personalAllowance, 1_257_000)
        XCTAssertEqual(r.incomeTax, 2_743_200)
    }

    func testScotland40k() {
        // Taxable 27,430. Starter 2,827 × 19% = 537.13; basic (14,921 − 2,827) 12,094 × 20% = 2,418.80;
        // intermediate (27,430 − 14,921) 12,509 × 21% = 2,626.89 → 5,582.82
        // NI (40,000 − 12,570) 27,430 × 8% = 2,194.40; take-home 40,000 − 5,582.82 − 2,194.40 = 32,222.78
        let r = calc(4_000_000) { $0.region = .scotland }
        XCTAssertEqual(r.incomeTax, 558_282)
        XCTAssertEqual(r.employeeNI, 219_440)
        XCTAssertEqual(r.takeHomeAnnual, 3_222_278)
        XCTAssertEqual(r.incomeTaxByBand.map(\.name), ["Starter", "Basic", "Intermediate"])
        XCTAssertEqual(r.incomeTaxByBand.map(\.tax), [53_713, 241_880, 262_689])
    }

    func testPlan2Loan40k() {
        // Loan (40,000 − 28,470) 11,530 × 9% = 1,037.70; tax 27,430 × 20% = 5,486.00; NI 2,194.40
        // Take-home 40,000 − 5,486 − 2,194.40 − 1,037.70 = 31,281.90
        let r = calc(4_000_000) { $0.studentLoan = .plan2 }
        XCTAssertEqual(r.studentLoan, 103_770)
        XCTAssertEqual(r.incomeTax, 548_600)
        XCTAssertEqual(r.employeeNI, 219_440)
        XCTAssertEqual(r.takeHomeAnnual, 3_128_190)
    }

    func testPostgraduatePlusPlan2() {
        // Postgraduate (40,000 − 21,000) 19,000 × 6% = 1,140.00; take-home 31,281.90 − 1,140 = 30,141.90
        let r = calc(4_000_000) { $0.studentLoan = .plan2; $0.postgraduateLoan = true }
        XCTAssertEqual(r.postgraduateLoan, 114_000)
        XCTAssertEqual(r.studentLoan, 103_770)
        XCTAssertEqual(r.incomeTax, 548_600)
        XCTAssertEqual(r.employeeNI, 219_440)
        XCTAssertEqual(r.takeHomeAnnual, 3_014_190)
    }

    func testBIK() {
        // Taxable 50,000 + 3,000 − 12,570 = 40,430: 7,540 + 2,730 × 40% = 1,092 → 8,632.00
        // NI on cash pay only: (50,000 − 12,570) 37,430 × 8% = 2,994.40
        //   (the brief said 3,016.00, which is 37,700 × 8%, the NI at £50,270; 50,000 is below that)
        // Take-home (BIK is not cash) 50,000 − 8,632 − 2,994.40 = 38,373.60
        // BIK tax: without it 37,430 × 20% = 7,486 → 8,632 − 7,486 = 1,146.00
        let r = calc(5_000_000) { $0.benefitsInKindAnnual = 300_000 }
        XCTAssertEqual(r.incomeTax, 863_200)
        XCTAssertEqual(r.employeeNI, 299_440)
        XCTAssertEqual(r.takeHomeAnnual, 3_837_360)
        XCTAssertEqual(r.benefitsInKindTax, 114_600)
    }

    func testKCode() {
        // K475 adds 4,750: taxable 34,750 × 20% = 6,950.00 (under the 50%-of-pay limit of 15,000)
        // NI 1,394.40; take-home 30,000 − 6,950 − 1,394.40 = 21,655.60
        let r = calc(3_000_000) { $0.taxCode = "K475" }
        XCTAssertEqual(r.incomeTax, 695_000)
        XCTAssertEqual(r.employeeNI, 139_440)
        XCTAssertEqual(r.takeHomeAnnual, 2_165_560)
        XCTAssertEqual(r.personalAllowance, 0)
    }

    func testBRCode() {
        // BR: 30,000 × 20% = 6,000.00, no allowance; NI 1,394.40; take-home 22,605.60
        let r = calc(3_000_000) { $0.taxCode = "BR" }
        XCTAssertEqual(r.incomeTax, 600_000)
        XCTAssertEqual(r.employeeNI, 139_440)
        XCTAssertEqual(r.takeHomeAnnual, 2_260_560)
        XCTAssertEqual(r.personalAllowance, 0)
    }

    func testBonusEqualsSalary() {
        // 50,000 + 10,000 bonus is taxed as 60,000 (example 2): tax 11,432.00
        let withBonus = calc(5_000_000) { $0.bonusAnnual = 1_000_000 }
        let salary = calc(6_000_000)
        XCTAssertEqual(withBonus.incomeTax, 1_143_200)
        XCTAssertEqual(withBonus.incomeTax, salary.incomeTax)
        XCTAssertEqual(withBonus.employeeNI, salary.employeeNI)
        XCTAssertEqual(withBonus.takeHomeAnnual, salary.takeHomeAnnual)
        XCTAssertEqual(withBonus.marginalRateBP, salary.marginalRateBP)
    }

    // MARK: More

    func testPlan1Plan4Plan5Thresholds() {
        // On 40,000 at 9%: plan 1 (40,000 − 26,065) 13,935 → 1,254.15; plan 4 (− 32,745) 7,255 → 652.95;
        // plan 5 (− 25,000) 15,000 → 1,350.00. 2026/27 plan 2 (− 29,385) 10,615 → 955.35
        XCTAssertEqual(calc(4_000_000) { $0.studentLoan = .plan1 }.studentLoan, 125_415)
        XCTAssertEqual(calc(4_000_000) { $0.studentLoan = .plan4 }.studentLoan, 65_295)
        XCTAssertEqual(calc(4_000_000) { $0.studentLoan = .plan5 }.studentLoan, 135_000)
        XCTAssertEqual(calc(4_000_000, year: 2026) { $0.studentLoan = .plan2 }.studentLoan, 95_535)
        // Below the threshold: nothing.
        XCTAssertEqual(calc(2_500_000) { $0.studentLoan = .plan1 }.studentLoan, 0)
    }

    func testStudentLoanIgnoresNetPayButNotSacrifice() {
        // Plan 2 on 40,000 with 4,000 pension: net pay leaves the loan on 40,000 (1,037.70);
        // sacrifice cuts pay to 36,000: (36,000 − 28,470) 7,530 × 9% = 677.70
        XCTAssertEqual(calc(4_000_000) { $0.studentLoan = .plan2; $0.pension = .fixedAnnual(pence: 400_000) }.studentLoan, 103_770)
        XCTAssertEqual(calc(4_000_000) {
            $0.studentLoan = .plan2; $0.pension = .fixedAnnual(pence: 400_000); $0.pensionMethod = .salarySacrifice
        }.studentLoan, 67_770)
    }

    func testEmployerPensionNotInTakeHome() {
        // Employer 5% of 60,000 = 3,000; take-home stays 45,357.40 (example 2)
        let r = calc(6_000_000) { $0.employerPension = .percentOfGross(basisPoints: 500) }
        XCTAssertEqual(r.employerPension, 300_000)
        XCTAssertEqual(r.takeHomeAnnual, 4_535_740)
    }

    func testWeeklyAndMonthly() {
        // 25,119.60 / 12 = 2,093.30; / 52 = 483.0692… → 483.07
        let r = calc(3_000_000)
        XCTAssertEqual(r.takeHomeMonthly, 209_330)
        XCTAssertEqual(r.takeHomeWeekly, 48_307)
        // Effective: (3,486 + 1,394.40) / 30,000 = 16.268% → 1 627 bp
        XCTAssertEqual(r.effectiveRateBP, 1_627)
    }

    func testOtherCodes() {
        // 0T: no allowance, normal bands: 30,000 × 20% = 6,000. NT: no tax.
        XCTAssertEqual(calc(3_000_000) { $0.taxCode = "0T" }.incomeTax, 600_000)
        XCTAssertEqual(calc(3_000_000) { $0.taxCode = "NT" }.incomeTax, 0)
        // D0: 30,000 × 40% = 12,000; D1: × 45% = 13,500; Scotland D0 at 21% = 6,300, D1 at 42% = 12,600.
        XCTAssertEqual(calc(3_000_000) { $0.taxCode = "D0" }.incomeTax, 1_200_000)
        XCTAssertEqual(calc(3_000_000) { $0.taxCode = "D1" }.incomeTax, 1_350_000)
        XCTAssertEqual(calc(3_000_000) { $0.taxCode = "SD0"; $0.region = .scotland }.incomeTax, 630_000)
        XCTAssertEqual(calc(3_000_000) { $0.taxCode = "SD1"; $0.region = .scotland }.incomeTax, 1_260_000)
        // 1000L: allowance 10,000 → (30,000 − 10,000) × 20% = 4,000
        XCTAssertEqual(calc(3_000_000) { $0.taxCode = "1000L" }.incomeTax, 400_000)
        // K code limit: 10,000 pay with K5000 (+50,000) would be 7,540 + 22,300 × 40% = 16,460;
        // capped at half of pay = 5,000
        let k = calc(1_000_000) { $0.taxCode = "K5000" }
        XCTAssertEqual(k.incomeTax, 500_000)
        XCTAssertTrue(k.notices.contains("K code: tax limited to half of pay"))
        // An S prefix on an England salary is example 1 unchanged.
        XCTAssertEqual(calc(3_000_000) { $0.taxCode = "S1257L" }.incomeTax, 348_600)
        // Unreadable code: 1257L with the notice.
        let bad = calc(3_000_000) { $0.taxCode = "abc" }
        XCTAssertEqual(bad.incomeTax, 348_600)
        XCTAssertEqual(bad.notices, ["Using 1257L: couldn't read that code"])
    }

    // MARK: Review focus

    func testZeroAndBelowAllowance() {
        let zero = calc(0)
        XCTAssertEqual(zero.incomeTax, 0)
        XCTAssertEqual(zero.employeeNI, 0)
        XCTAssertEqual(zero.takeHomeAnnual, 0)
        XCTAssertEqual(zero.effectiveRateBP, 0)
        XCTAssertEqual(zero.marginalRateBP, 0)
        XCTAssertEqual(zero.keepPerExtraPoundBP, 10_000)
        // 10,000: under the allowance and the NI threshold, nothing deducted.
        let low = calc(1_000_000) { $0.studentLoan = .plan2; $0.postgraduateLoan = true }
        XCTAssertEqual(low.incomeTax, 0)
        XCTAssertEqual(low.employeeNI, 0)
        XCTAssertEqual(low.studentLoan, 0)
        XCTAssertEqual(low.postgraduateLoan, 0)
        XCTAssertEqual(low.takeHomeAnnual, 1_000_000)
        XCTAssertEqual(low.effectiveRateBP, 0)
        XCTAssertTrue(low.incomeTaxByBand.isEmpty)
        // Negative input is treated as nothing.
        XCTAssertEqual(calc(-500_000).takeHomeAnnual, 0)
    }

    func testPensionCappedAtGross() {
        // 150% sacrifice on 30,000 → capped at 30,000: nothing to tax, take-home 0.
        let sacrifice = calc(3_000_000) { $0.pension = .percentOfGross(basisPoints: 15_000); $0.pensionMethod = .salarySacrifice }
        XCTAssertEqual(sacrifice.employeePension, 3_000_000)
        XCTAssertEqual(sacrifice.incomeTax, 0)
        XCTAssertEqual(sacrifice.employeeNI, 0)
        XCTAssertEqual(sacrifice.takeHomeAnnual, 0)
        XCTAssertTrue(sacrifice.notices.contains("Pension capped at gross pay"))
        // Fixed 50,000 net pay on 30,000 → capped at 30,000; NI is still due, take-home floored at 0.
        let netPay = calc(3_000_000) { $0.pension = .fixedAnnual(pence: 5_000_000) }
        XCTAssertEqual(netPay.employeePension, 3_000_000)
        XCTAssertEqual(netPay.incomeTax, 0)
        XCTAssertEqual(netPay.takeHomeAnnual, 0)
        XCTAssertEqual(netPay.takeHomeMonthly, 0)
        XCTAssertEqual(netPay.employeeNI, 139_440)
        XCTAssertEqual(netPay.effectiveRateBP, 465) // 1,394.40 / 30,000
        XCTAssertTrue(netPay.notices.contains("Deductions are more than pay; take-home shown as £0"))
        // Relief at source: capped at 30,000 gross, 24,000 paid.
        let ras = calc(3_000_000) { $0.pension = .fixedAnnual(pence: 5_000_000); $0.pensionMethod = .reliefAtSource }
        XCTAssertEqual(ras.employeePension, 2_400_000)
        // Adjusted net income 0, full allowance; tax 17,430 × 20% = 3,486; NI 1,394.40
        // Take-home 30,000 − 24,000 − 3,486 − 1,394.40 = 1,119.60
        XCTAssertEqual(ras.incomeTax, 348_600)
        XCTAssertEqual(ras.takeHomeAnnual, 111_960)
    }

    func testUnknownYearFallsBackWithNotice() {
        let later = calc(3_000_000, year: 2030)
        XCTAssertEqual(later.effectiveTaxYear, 2026)
        XCTAssertEqual(later.notices, ["No rules for 2030/31; using 2026/27"])
        XCTAssertEqual(later.incomeTax, calc(3_000_000, year: 2026).incomeTax)
        XCTAssertEqual(later.inputs.taxYearStart, 2030)
        let known = calc(3_000_000, year: 2026)
        XCTAssertEqual(known.effectiveTaxYear, 2026)
        XCTAssertEqual(known.notices, [])
        let earlier = calc(3_000_000, year: 2019)
        XCTAssertEqual(earlier.effectiveTaxYear, 2025)
        XCTAssertEqual(earlier.notices, ["No rules for 2019/20; using 2025/26"])
    }
}
