import XCTest
@testable import BudgetCore

@MainActor
final class SalaryComparisonTests: XCTestCase {
    private func result(_ gross: Int, _ configure: (inout SalaryInputs) -> Void = { _ in }) -> SalaryResult {
        var inputs = SalaryInputs(grossAnnual: gross, taxYearStart: 2025)
        configure(&inputs)
        return SalaryCalculator.calculate(inputs)
    }

    func testDifferenceFromTwoSalaries() {
        // 45,357.40 − 25,119.60 = 20,237.80 a year; / 12 = 1,686.48 (1,686.4833…)
        let c = SalaryComparison.make(current: result(3_000_000), offer: result(6_000_000))
        XCTAssertEqual(c.annualDifference, 2_023_780)
        XCTAssertEqual(c.monthlyDifference, 168_648)
    }

    func testKeepPerExtraPound() {
        let c = SalaryComparison.make(current: result(3_000_000), offer: result(6_000_000))
        XCTAssertEqual(c.keepPerExtraPound, 5_800)
    }

    func testIdenticalAndNegativeDifference() {
        let same = SalaryComparison.make(current: result(4_000_000), offer: result(4_000_000))
        XCTAssertEqual(same.annualDifference, 0)
        XCTAssertEqual(same.monthlyDifference, 0)
        let lower = SalaryComparison.make(current: result(6_000_000), offer: result(3_000_000))
        XCTAssertEqual(lower.annualDifference, -2_023_780)
        XCTAssertEqual(lower.monthlyDifference, -168_648)
    }

    func testViewModelRecomputesOnInputChange() {
        let model = SalaryComparisonViewModel(current: SalaryInputs(grossAnnual: 3_000_000, taxYearStart: 2025))
        XCTAssertEqual(model.comparison.annualDifference, 0)
        model.offer.grossAnnual = 6_000_000
        XCTAssertEqual(model.comparison.annualDifference, 2_023_780)
        model.current.grossAnnual = 6_000_000
        XCTAssertEqual(model.comparison.annualDifference, 0)
        XCTAssertTrue(model.ready.offer)
        model.offer.grossAnnual = 0
        XCTAssertFalse(model.ready.offer)
    }

    func testSegmentsSumToGross() {
        let cases: [(Int, (inout SalaryInputs) -> Void)] = [
            (6_000_000, { _ in }),
            (6_000_000, { $0.bonusAnnual = 500_000; $0.studentLoan = .plan2; $0.postgraduateLoan = true }),
            (6_000_000, { $0.pension = .percentOfGross(basisPoints: 500); $0.pensionMethod = .salarySacrifice }),
            (6_000_000, { $0.pension = .percentOfGross(basisPoints: 500); $0.pensionMethod = .reliefAtSource }),
            (6_000_000, { $0.pension = .fixedAnnual(pence: 300_000); $0.pensionMethod = .netPay })
        ]
        for (gross, configure) in cases {
            let r = result(gross, configure)
            let sum = SalaryBarSegments.segments(r).reduce(0) { $0 + $1.pence }
            XCTAssertEqual(sum, r.inputs.grossAnnual + r.inputs.bonusAnnual)
        }
    }

    func testDefaultTaxYearFollowsToday() {
        let day = { (y: Int, m: Int, d: Int) in Calendar(identifier: .gregorian).date(from: DateComponents(timeZone: TimeZone(identifier: "UTC"), year: y, month: m, day: d))! }
        XCTAssertEqual(SalaryInputs.defaultTaxYear(today: day(2026, 10, 28)), 2026)
        XCTAssertEqual(SalaryInputs.defaultTaxYear(today: day(2026, 4, 1)), 2025)
        XCTAssertEqual(SalaryInputs.defaultTaxYear(today: day(2020, 1, 1)), 2025)
    }
}
