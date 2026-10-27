import XCTest
@testable import BudgetCore

/// The comparison of a tax year with the year before: figures side by side, the differences and
/// the reasons that can be told. Pure; amounts in pence.
final class TaxReturnComparisonTests: XCTestCase {
    private func pounds(_ value: Int) -> Int { value * 100 }

    private func result(_ year: Int, _ inputs: SelfAssessment.Inputs) -> SelfAssessment.Result {
        SelfAssessment.calculate(inputs, rules: UKTaxRules.forYear(year)!)
    }

    private func line(_ comparison: TaxReturnComparison.Result, _ label: String) throws -> TaxReturnComparison.Line {
        try XCTUnwrap(comparison.groups.flatMap(\.lines).first { $0.label == label }, "no line \(label)")
    }

    func testNoPreviousReturnGivesNothing() {
        let current = result(2025, .init(startYear: 2025, employments: [.init(employerName: "Example Ltd", pay: pounds(40_000), taxDeducted: pounds(5_000))]))
        XCTAssertNil(TaxReturnComparison.compare(previous: nil, current: current))
        let empty = result(2024, .init(startYear: 2024))
        XCTAssertFalse(TaxReturnComparison.hasData(empty))
        XCTAssertNil(TaxReturnComparison.compare(previous: empty, current: current))
    }

    func testIncomeSourcesDifferencesAndWhy() throws {
        let previous = result(2024, .init(
            startYear: 2024,
            employments: [.init(employerName: "Example Ltd", pay: pounds(40_000), taxDeducted: pounds(5_000))],
            properties: [.init(name: "Property A", country: "PT", income: pounds(10_000), expenses: pounds(2_000), financeCosts: 0, foreignTax: 0)]))
        let current = result(2025, .init(
            startYear: 2025,
            employments: [.init(employerName: "Example Ltd", pay: pounds(45_000), taxDeducted: pounds(6_000)),
                          .init(employerName: "Other Ltd", pay: pounds(5_000), taxDeducted: 0)],
            properties: [.init(name: "Property A", country: "PT", income: pounds(10_000), expenses: pounds(2_000), financeCosts: 0, foreignTax: 0)]))
        let comparison = try XCTUnwrap(TaxReturnComparison.compare(previous: previous, current: current))
        XCTAssertEqual(comparison.previousLabel, "2024/25")
        XCTAssertEqual(comparison.currentLabel, "2025/26")

        let example = try line(comparison, "Example Ltd")
        XCTAssertEqual(example.difference, pounds(5_000))
        XCTAssertTrue(example.isChanged)
        XCTAssertNil(example.why)
        let other = try line(comparison, "Other Ltd")
        XCTAssertFalse(other.inPrevious)
        XCTAssertEqual(other.why, "New employment this year: none in 2024/25")
        let property = try line(comparison, "Property A")
        XCTAssertFalse(property.isChanged)
        XCTAssertEqual(try line(comparison, "Total income").difference, pounds(10_000))
        XCTAssertGreaterThan(comparison.changedCount, 0)
        XCTAssertEqual(comparison.groups.map(\.section), TaxReturnComparison.Section.allCases)
    }

    func testMissingSourceAndTaxFigures() throws {
        let previous = result(2024, .init(
            startYear: 2024,
            employments: [.init(employerName: "Old Ltd", pay: pounds(60_000), taxDeducted: pounds(10_000))], paymentsOnAccountMade: pounds(1_000)))
        let current = result(2025, .init(
            startYear: 2025,
            employments: [.init(employerName: "New Ltd", pay: pounds(30_000), taxDeducted: pounds(3_000))], paymentsOnAccountMade: pounds(2_000)))
        let comparison = try XCTUnwrap(TaxReturnComparison.compare(previous: previous, current: current))
        XCTAssertEqual(try line(comparison, "Old Ltd").why, "No employment in 2025/26: it was in 2024/25")
        XCTAssertEqual(try line(comparison, "Income Tax due").difference, current.calculation.incomeTaxDue - previous.calculation.incomeTaxDue)
        XCTAssertEqual(try line(comparison, "Payments on account made").difference, pounds(1_000))
        let higher = try line(comparison, "Higher rate tax")
        XCTAssertFalse(higher.inCurrent)
        XCTAssertEqual(higher.why, "No income in this band in 2025/26")
        XCTAssertEqual(try line(comparison, "Balancing payment").current, current.calculation.balancingPayment)
    }

    func testComparingAYearWithItselfChangesNothing() throws {
        let year = result(2024, .init(
            startYear: 2024, employments: [.init(employerName: "Example Ltd", pay: pounds(60_000), taxDeducted: pounds(10_000))],
            properties: [.init(name: "Property A", country: "PT", income: pounds(10_000), expenses: pounds(2_000), financeCosts: pounds(500), foreignTax: pounds(300))]))
        let comparison = try XCTUnwrap(TaxReturnComparison.compare(previous: year, current: year))
        XCTAssertEqual(comparison.changedCount, 0)
    }
}
