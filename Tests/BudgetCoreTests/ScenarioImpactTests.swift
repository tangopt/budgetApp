import XCTest
@testable import BudgetCore

/// The impact table's average monthly surplus and differences (spec
/// 2026-10-28-step17-scenario-comparison-design.md).
final class ScenarioImpactTests: XCTestCase {
    private func year(_ year: Int, income: Int, expenses: Int) -> PlanYearSummary {
        PlanYearSummary(year: year, yearEndNetWorth: nil, differenceVsBudget: nil, income: income, expenses: expenses, reserves: 0)
    }

    func testAverageMonthlySurplusFullYears() {
        let years = [year(2026, income: 3_600_000, expenses: 2_400_000), year(2027, income: 3_600_000, expenses: 2_400_000)]
        XCTAssertEqual(ScenarioImpact.averageMonthlySurplus(years, horizon: (year: 2027, month: 12)), 100_000)
    }

    func testAverageMonthlySurplusStopsAtHorizonMonth() {
        // 12,000 surplus in 2026, 6,000 over January–June 2027: 18,000 over 18 months.
        let years = [year(2026, income: 3_600_000, expenses: 2_400_000), year(2027, income: 1_800_000, expenses: 1_200_000)]
        XCTAssertEqual(ScenarioImpact.averageMonthlySurplus(years, horizon: (year: 2027, month: 6)), 100_000)
    }

    func testAverageMonthlySurplusRoundsHalfAwayFromZero() {
        XCTAssertEqual(ScenarioImpact.averageMonthlySurplus([year(2026, income: 0, expenses: 1)], horizon: (year: 2026, month: 3)), 0)
        XCTAssertEqual(ScenarioImpact.averageMonthlySurplus([year(2026, income: 0, expenses: 2)], horizon: (year: 2026, month: 3)), -1)
        XCTAssertEqual(ScenarioImpact.averageMonthlySurplus([year(2026, income: 3, expenses: 0)], horizon: (year: 2026, month: 2)), 2)
        XCTAssertEqual(ScenarioImpact.averageMonthlySurplus([year(2026, income: 0, expenses: 3)], horizon: (year: 2026, month: 2)), -2)
    }

    func testNoYearsIsZero() {
        XCTAssertEqual(ScenarioImpact.averageMonthlySurplus([], horizon: (year: 2027, month: 6)), 0)
    }

    func testDifferenceIsNilWhenEitherSideIsNil() {
        XCTAssertEqual(ScenarioImpact.difference(500, from: 200), 300)
        XCTAssertEqual(ScenarioImpact.difference(200, from: 500), -300)
        XCTAssertNil(ScenarioImpact.difference(nil, from: 200))
        XCTAssertNil(ScenarioImpact.difference(500, from: nil))
        XCTAssertNil(ScenarioImpact.difference(nil, from: nil))
    }
}
