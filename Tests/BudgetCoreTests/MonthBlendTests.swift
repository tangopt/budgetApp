import XCTest
@testable import BudgetCore

final class MonthBlendTests: XCTestCase {
    func testActualAndForecastMonthsPassTheirOwnValueThrough() {
        XCTAssertEqual(MonthBlend.projectedTotal(actual: -500, expected: -850, categoryType: .expense, monthClass: .actual), -500)
        XCTAssertEqual(MonthBlend.projectedTotal(actual: -500, expected: -850, categoryType: .expense, monthClass: .forecast), -850)
    }

    func testBlendedIncomeTakesTheLarger() {
        XCTAssertEqual(MonthBlend.projectedTotal(actual: 100, expected: 300, categoryType: .income, monthClass: .blended), 300)
        XCTAssertEqual(MonthBlend.projectedTotal(actual: 400, expected: 300, categoryType: .income, monthClass: .blended), 400)
        XCTAssertEqual(MonthBlend.projectedTotal(actual: 100, expected: 0, categoryType: .income, monthClass: .blended), 100)
    }

    func testBlendedExpenseTakesTheLargerSpend() {
        // Signed: spend is negative, so the larger spend is the smaller (more negative) number.
        XCTAssertEqual(MonthBlend.projectedTotal(actual: -500, expected: -850, categoryType: .expense, monthClass: .blended), -850)
        XCTAssertEqual(MonthBlend.projectedTotal(actual: -900, expected: -850, categoryType: .expense, monthClass: .blended), -900)
        XCTAssertEqual(MonthBlend.projectedTotal(actual: 50, expected: -850, categoryType: .expense, monthClass: .blended), -850) // a refund
        XCTAssertEqual(MonthBlend.projectedTotal(actual: -25, expected: 0, categoryType: .expense, monthClass: .blended), -25) // unplanned
    }
}
