import XCTest
@testable import BudgetCore

/// A bonus paid once a year: the normal month and the bonus month on the PAYE basis, hand-worked from the 2026/27
/// rules (England): allowance £12,570 (£1,047.50 a month), basic band £37,700 (£3,141.67 a month) at 20%, higher 40%;
/// employee NI 8% from £12,570 to £50,270 a year (£1,047.50 to £4,189.17 a month), 2% above; Plan 2 student loan 9%
/// above £29,385 a year (£2,448.75 a month). Income tax is cumulative (month k: k/12 of the allowance and bands, less
/// the tax already taken); NI and loans are per month. Amounts pence.
final class SalaryBonusMonthTests: XCTestCase {
    private func calc(_ gross: Int, bonus: Int, paid: BonusPayment = .standard,
                      _ configure: (inout SalaryInputs) -> Void = { _ in }) -> SalaryResult {
        var inputs = SalaryInputs(grossAnnual: gross, bonusAnnual: bonus, taxYearStart: 2026, bonusPayment: paid)
        configure(&inputs)
        return SalaryCalculator.calculate(inputs)
    }

    func testBasicRateSalaryWhoseMarchBonusCrossesIntoHigherRate() throws {
        // £45,000 + £10,000 in March (month 12).
        // Normal month: pay 3,750.00; tax (3,750 − 1,047.50) × 20% = 540.50; NI 2,702.50 × 8% = 216.20
        //   → take-home 2,993.30.
        // March: pay 3,750 + 10,000 = 13,750.00. Tax to date on £55,000 against the whole year: 37,700 × 20% = 7,540
        //   + (42,430 − 37,700) 4,730 × 40% = 1,892 → 9,432.00, less 11 × 540.50 = 5,945.50 taken → 3,486.50.
        //   NI (4,189.17 − 1,047.50) × 8% = 251.33 + (13,750 − 4,189.17) × 2% = 191.22 → 442.55.
        //   → take-home 13,750 − 3,486.50 − 442.55 = 9,820.95.
        let r = calc(4_500_000, bonus: 1_000_000)
        let normal = try XCTUnwrap(r.normalMonth), bonus = try XCTUnwrap(r.bonusMonth)
        XCTAssertEqual(normal, SalaryPayslip(pay: 375_000, incomeTax: 54_050, employeeNI: 21_620, studentLoan: 0,
                                             postgraduateLoan: 0, employeePension: 0, takeHome: 299_330))
        XCTAssertEqual(bonus, SalaryPayslip(pay: 1_375_000, incomeTax: 348_650, employeeNI: 44_255, studentLoan: 0,
                                            postgraduateLoan: 0, employeePension: 0, takeHome: 982_095))
        XCTAssertEqual(r.takeHomeMonthly, 299_330, "the month is the normal month")
        // The year is unchanged: tax 9,432; NI 37,700 × 8% = 3,016 + 4,730 × 2% = 94.60 → 3,110.60; 42,457.40.
        XCTAssertEqual(r.incomeTax, 943_200)
        XCTAssertEqual(r.employeeNI, 311_060)
        XCTAssertEqual(r.takeHomeAnnual, 4_245_740)
        // The payslips: 11 × 2,993.30 + 9,820.95 = 42,747.25 (NI per month is 289.85 less than on the year).
        XCTAssertEqual(r.payslipsTakeHome, 4_274_725)
        XCTAssertTrue(r.notices.contains("NI is monthly: payslips total £42,747.25"), "\(r.notices)")
    }

    func testStudentLoanInTheBonusMonth() throws {
        // £28,000 + £5,000 in March, Plan 2.
        // Normal month: pay 2,333.33; tax 1,285.83 × 20% = 257.17; NI × 8% = 102.87; under 2,448.75, no loan
        //   → take-home 1,973.29.
        // March: pay 7,333.33. Tax to date on £33,000: 20,430 × 20% = 4,086.00, less 11/12 of 3,086 = 2,828.83 → 1,257.17.
        //   NI 251.33 + (7,333.33 − 4,189.17) × 2% = 62.88 → 314.22. Loan (7,333.33 − 2,448.75) × 9% = 439.61.
        //   → take-home 7,333.33 − 1,257.17 − 314.22 − 439.61 = 5,322.33.
        let r = calc(2_800_000, bonus: 500_000) { $0.studentLoan = .plan2 }
        XCTAssertEqual(r.normalMonth, SalaryPayslip(pay: 233_333, incomeTax: 25_717, employeeNI: 10_287, studentLoan: 0,
                                                    postgraduateLoan: 0, employeePension: 0, takeHome: 197_329))
        XCTAssertEqual(r.bonusMonth, SalaryPayslip(pay: 733_333, incomeTax: 125_717, employeeNI: 31_422, studentLoan: 43_961,
                                                   postgraduateLoan: 0, employeePension: 0, takeHome: 532_233))
        // The year's loan is (33,000 − 29,385) × 9% = 325.35: payroll takes 439.61 in the bonus month.
        XCTAssertEqual(r.studentLoan, 32_535)
    }

    func testABonusBeforeMarchIsOverTaxedInItsMonthAndGivenBackAfter() throws {
        // £40,000 + £10,000 in December (month 9).
        // Tax to date in December on 8 × 3,333.33 + 13,333.33 = 40,000 against 9/12: allowance 9,427.50, basic band
        //   28,275: taxable 30,572.50 → 28,275 × 20% = 5,655 + 2,297.50 × 40% = 919 → 6,574.00, less 8/12 of 5,486
        //   = 3,657.33 → 2,916.67 (a March bonus would pay 2,000 + 457.17 = 2,457.17).
        let r = calc(4_000_000, bonus: 1_000_000, paid: .yearly(month: 12))
        XCTAssertEqual(r.bonusMonth?.incomeTax, 291_667)
        // The year's tax is the same: (50,000 − 12,570) × 20% = 7,486.
        let code = TaxCode.parse("1257L").code
        let slips = SalaryCalculator.payslips(r.inputs, rules: .y2026, code: code, allowance: 1_257_000, bonusIn: 9)
        XCTAssertEqual(slips.reduce(0) { $0 + $1.incomeTax }, r.incomeTax)
        XCTAssertEqual(r.incomeTax, 748_600)
        XCTAssertTrue(r.notices.contains { $0.hasPrefix("PAYE refunds £") }, "\(r.notices)")
    }

    func testSpreadMonthlyIsTheYearInTwelfths() {
        let yearly = calc(4_500_000, bonus: 1_000_000)
        let monthly = calc(4_500_000, bonus: 1_000_000, paid: .monthly)
        XCTAssertNil(monthly.bonusMonth)
        XCTAssertNil(monthly.normalMonth)
        XCTAssertNil(monthly.payslipsTakeHome)
        XCTAssertEqual(monthly.takeHomeMonthly, SalaryCalculator.roundHalfUp(monthly.takeHomeAnnual, 12))
        // How it's paid never changes the year.
        XCTAssertEqual(yearly.takeHomeAnnual, monthly.takeHomeAnnual)
        XCTAssertEqual(yearly.incomeTax, monthly.incomeTax)
        XCTAssertEqual(yearly.employeeNI, monthly.employeeNI)
        XCTAssertEqual(yearly.marginalRateBP, monthly.marginalRateBP)
    }

    func testAPercentagePensionComesOffTheBonusToo() throws {
        // 5% salary sacrifice on £40,000 + £10,000 in March: 5% of 13,333.33 = 666.67 in March, 166.67 a normal month.
        let r = calc(4_000_000, bonus: 1_000_000) { $0.pension = .percentOfGross(basisPoints: 500); $0.pensionMethod = .salarySacrifice }
        XCTAssertEqual(r.normalMonth?.employeePension, 16_667)
        XCTAssertEqual(r.bonusMonth?.employeePension, 66_667)
        // A fixed yearly amount is a twelfth a month, bonus or not: 1,200 → 100.
        let fixed = calc(4_000_000, bonus: 1_000_000) { $0.pension = .fixedAnnual(pence: 120_000); $0.pensionMethod = .netPay }
        XCTAssertEqual(fixed.normalMonth?.employeePension, 10_000)
        XCTAssertEqual(fixed.bonusMonth?.employeePension, 10_000)
    }

    func testTaxYearMonths() {
        XCTAssertEqual(SalaryCalculator.taxYearMonth(4), 1)
        XCTAssertEqual(SalaryCalculator.taxYearMonth(12), 9)
        XCTAssertEqual(SalaryCalculator.taxYearMonth(1), 10)
        XCTAssertEqual(SalaryCalculator.taxYearMonth(3), 12)
    }

    func testSavedInputsWithoutBonusPaymentDecodeAsYearlyInMarch() throws {
        let saved = SalaryInputs(grossAnnual: 3_000_000, bonusAnnual: 200_000, taxYearStart: 2026, bonusPayment: .monthly)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(saved)) as? [String: Any])
        XCTAssertNotNil(object["bonusPayment"])
        object.removeValue(forKey: "bonusPayment")
        let decoded = try JSONDecoder().decode(SalaryInputs.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(decoded.bonusPayment, .yearly(month: 3))
        let roundTrip = try JSONDecoder().decode(SalaryInputs.self, from: JSONEncoder().encode(saved))
        XCTAssertEqual(roundTrip, saved)
    }
}
