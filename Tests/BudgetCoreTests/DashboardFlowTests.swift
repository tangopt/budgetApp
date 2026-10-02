import XCTest
@testable import BudgetCore

final class DashboardFlowTests: XCTestCase {
    private typealias F = DashboardFixture
    private func date(_ y: Int, _ m: Int, _ d: Int) -> Date { F.date(y, m, d) }

    /// Mid-October, data through 13 Oct: rent paid (matches its expectation), groceries
    /// unplanned, dining over its expectation, salary not yet in; two unreviewed outflows.
    private var blendedInput: DashboardInput {
        F.input(today: date(2026, 10, 14), transactions: [
            F.txn(1, date(2026, 1, 1), -100_000, category: F.rentId),
            F.txn(2, date(2026, 1, 25), 300_000, category: F.salaryId),
            F.txn(3, date(2026, 10, 1), -100_000, category: F.rentId),
            F.txn(4, date(2026, 10, 5), -25_000, category: F.groceriesId),
            F.txn(5, date(2026, 10, 13), -55_000, category: F.diningId),
            F.txn(6, date(2026, 10, 5), -3_000, category: nil, status: .pendingReview),
            F.txn(7, date(2026, 10, 6), -2_000, category: F.groceriesId, status: .pendingReview)
        ])
    }

    // MARK: current month

    func testBlendedCurrentMonthUsesTheLargerOfActualAndExpectedPerCategory() {
        let month = DashboardCalculator.currentMonth(blendedInput)
        XCTAssertEqual(month.monthClass, .blended)
        XCTAssertEqual(month.dayOfMonth, 14)
        XCTAssertEqual(month.daysInMonth, 31)
        XCTAssertEqual(month.income, FlowTotals(actual: 0, expected: 300_000, projected: 300_000))
        // Rent 100k (=expected), groceries 25k unplanned, dining 55k over its 40k expectation.
        XCTAssertEqual(month.expenses, FlowTotals(actual: 180_000, expected: 140_000, projected: 180_000))
        XCTAssertEqual(month.net, FlowTotals(actual: -180_000, expected: 160_000, projected: 120_000))
    }

    func testUnreviewedTransactionsAreCountedButNotInTheTotals() {
        let month = DashboardCalculator.currentMonth(blendedInput)
        XCTAssertEqual(month.unreviewedCount, 2)
        XCTAssertEqual(month.unreviewedOutflowMinorUnits, 5_000)
    }

    // The Forecast grid hides expected amounts once a month has transactions; the dashboard
    // must keep reading them from the forecast.
    func testExpectedStillComesFromTheForecastWhenTheMonthHasTransactions() {
        XCTAssertEqual(DashboardCalculator.currentMonth(blendedInput).expenses.expected, 140_000)
    }

    func testCurrentMonthWithNothingImportedYetIsForecastOnly() {
        let input = F.input(today: date(2026, 10, 2), transactions: [F.txn(1, date(2026, 2, 14), -55_000, category: F.diningId)])
        let month = DashboardCalculator.currentMonth(input)
        XCTAssertEqual(month.monthClass, .forecast)
        XCTAssertEqual(month.income, FlowTotals(actual: 0, expected: 300_000, projected: 300_000))
        XCTAssertEqual(month.expenses, FlowTotals(actual: 0, expected: 140_000, projected: 140_000))
    }

    func testBulkAllowanceCountsInFullEvenWithNoActuals() {
        let withBulk = F.withDining + [ForecastEntry(id: 9, groupId: 1, categoryId: F.bulkId, amountMinorUnits: -17_139, frequency: .monthly, interval: 1, startDate: date(2026, 1, 14), endDate: nil, isEnabled: true, status: .manual, note: nil)]
        let input = F.input(today: date(2026, 10, 14), transactions: [F.txn(1, date(2026, 10, 13), -55_000, category: F.diningId)], entries: withBulk, catchAllId: F.bulkId)
        // Expected 100k rent + 40k dining + 17,139 bulk; actual only dining (55k) → projected 100k + 55k + 17,139.
        XCTAssertEqual(DashboardCalculator.currentMonth(input).expenses.projected, 172_139)
    }

    // MARK: monthly flows

    func testMonthlyFlowsClassifyEachMonthOfTheYear() {
        let flows = DashboardCalculator.monthlyFlows(blendedInput, year: 2026)
        XCTAssertEqual(flows.count, 12)
        XCTAssertEqual(flows.prefix(9).map(\.monthClass), Array(repeating: .actual, count: 9))
        XCTAssertEqual(flows[9].monthClass, .blended)
        XCTAssertEqual(flows[10].monthClass, .forecast)
        XCTAssertEqual(flows[11].monthClass, .forecast)
    }

    func testActualBlendedAndForecastMonthShapes() {
        let flows = DashboardCalculator.monthlyFlows(blendedInput, year: 2026)
        // January: actual only.
        XCTAssertEqual([flows[0].incomeActual, flows[0].incomeRemaining, flows[0].expenseActual, flows[0].expenseRemaining], [300_000, 0, 100_000, 0])
        // October: salary still to come (remaining 300k); expenses already at their projection.
        XCTAssertEqual([flows[9].incomeActual, flows[9].incomeRemaining, flows[9].expenseActual, flows[9].expenseRemaining], [0, 300_000, 180_000, 0])
        // November: forecast only.
        XCTAssertEqual([flows[10].incomeActual, flows[10].incomeRemaining, flows[10].expenseActual, flows[10].expenseRemaining], [0, 300_000, 0, 140_000])
        XCTAssertEqual(flows[10].net, 160_000)
    }

    func testPastYearsAreAllActual() {
        let flows = DashboardCalculator.monthlyFlows(blendedInput, year: 2025)
        XCTAssertTrue(flows.allSatisfy { $0.monthClass == .actual })
        XCTAssertTrue(flows.allSatisfy { $0.incomeRemaining == 0 && $0.expenseRemaining == 0 })
    }

    func testNextYearIsAllForecast() {
        let flows = DashboardCalculator.monthlyFlows(blendedInput, year: 2027)
        XCTAssertTrue(flows.allSatisfy { $0.monthClass == .forecast })
        XCTAssertEqual(flows[0].incomeRemaining, 300_000)
    }

    func testYearTotalsSeparateProjectedFromActualToDate() {
        let totals = DashboardCalculator.yearTotals(DashboardCalculator.monthlyFlows(blendedInput, year: 2026))
        XCTAssertEqual(totals.incomeProjected, 1_200_000) // Jan 300k + Oct 300k + Nov 300k + Dec 300k
        XCTAssertEqual(totals.incomeActual, 300_000)
        XCTAssertEqual(totals.expenseProjected, 560_000) // 100k + 180k + 140k + 140k
        XCTAssertEqual(totals.expenseActual, 280_000) // 100k + 180k
        XCTAssertEqual(totals.netProjected, 640_000)
        XCTAssertEqual(totals.netActual, 20_000)
    }

    // MARK: top categories

    func testTopCategoriesRollUpByGroupAndFlagOverspend() {
        let top = DashboardCalculator.topCategories(blendedInput, limit: 5)
        XCTAssertEqual(top.map(\.name), ["Rent", "Food"])
        XCTAssertEqual(top[0].actual, 100_000)
        XCTAssertFalse(top[0].isOver)
        // Food = groceries (25k, unplanned) + dining (55k vs 40k expected).
        XCTAssertEqual(top[1].actual, 80_000)
        XCTAssertEqual(top[1].expected, 40_000)
        XCTAssertEqual(top[1].projected, 80_000)
        XCTAssertTrue(top[1].isOver)
    }

    func testTopCategoriesAreExpectedOnlyBeforeAnyActualsAndRespectTheLimit() {
        let input = F.input(today: date(2026, 10, 2), transactions: [F.txn(1, date(2026, 2, 14), -55_000, category: F.diningId)])
        let top = DashboardCalculator.topCategories(input, limit: 1)
        XCTAssertEqual(top.map(\.name), ["Rent"])
        XCTAssertEqual(top[0].actual, 0)
        XCTAssertEqual(top[0].projected, 100_000)
    }

    func testAnUnplannedCategoryIsFlagged() {
        let input = F.input(today: date(2026, 10, 14), transactions: [F.txn(1, date(2026, 10, 13), -25_000, category: F.bulkId)])
        let unplanned = DashboardCalculator.topCategories(input, limit: 5).first { $0.name == "Bulk other" }
        XCTAssertEqual(unplanned?.isUnplanned, true)
    }
}
