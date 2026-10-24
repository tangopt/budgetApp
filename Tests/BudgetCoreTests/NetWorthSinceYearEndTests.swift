import XCTest
@testable import BudgetCore

/// The iPhone Accounts header's "since last December" (iPhone spec §3.6): today's net worth against last December's
/// real month end (`DashboardCalculator.yearEndNetWorth(year − 1, includeForecast: false)`).
final class NetWorthSinceYearEndTests: XCTestCase {
    private func date(_ y: Int, _ m: Int, _ d: Int) -> Date { DashboardFixture.date(y, m, d) }

    func testTheChangeIsTodaysNetWorthMinusLastDecembersMonthEnd() throws {
        let input = DashboardFixture.input(
            today: date(2026, 10, 15),
            snapshots: [DashboardFixture.snapshot(1, date(2025, 6, 1), 100_000)],
            transactions: [DashboardFixture.txn(1, date(2025, 11, 3), -2_000, category: DashboardFixture.groceriesId),
                           DashboardFixture.txn(2, date(2026, 2, 1), 5_000, category: DashboardFixture.salaryId)])
        let december = try XCTUnwrap(DashboardCalculator.yearEndNetWorth(input, year: 2025, includeForecast: false))
        XCTAssertEqual(december.valueMinorUnits, 98_000)

        let change = try XCTUnwrap(DashboardCalculator.changeSinceLastYearEnd(input, netWorthMinorUnits: 103_000))
        XCTAssertEqual(change, NetWorthSinceYearEnd(year: 2025, yearEndMinorUnits: 98_000, changeMinorUnits: 5_000))
    }

    func testNoDecemberFigureMeansNoChange() {
        let input = DashboardFixture.input(today: date(2026, 10, 15),
                                           snapshots: [DashboardFixture.snapshot(1, date(2026, 3, 1), 100_000)])
        XCTAssertNil(DashboardCalculator.changeSinceLastYearEnd(input, netWorthMinorUnits: 100_000))
    }
}
