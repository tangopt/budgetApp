import XCTest
@testable import BudgetCore

final class DashboardFlowTests: XCTestCase {
    private typealias F = DashboardFixture
    private func date(_ y: Int, _ m: Int, _ d: Int) -> Date { F.date(y, m, d) }

    /// Mid-October, data through 13 Oct: rent paid (matches its expectation), groceries
    /// unplanned, dining over its expectation, salary not yet in; two unreviewed outflows.
    private var blendedTransactions: [Transaction] {
        [
            F.txn(1, date(2026, 1, 1), -100_000, category: F.rentId),
            F.txn(2, date(2026, 1, 25), 300_000, category: F.salaryId),
            F.txn(3, date(2026, 10, 1), -100_000, category: F.rentId),
            F.txn(4, date(2026, 10, 5), -25_000, category: F.groceriesId),
            F.txn(5, date(2026, 10, 13), -55_000, category: F.diningId),
            F.txn(6, date(2026, 10, 5), -3_000, category: nil, status: .pendingReview),
            F.txn(7, date(2026, 10, 6), -2_000, category: F.groceriesId, status: .pendingReview)
        ]
    }

    /// Manual closes on the last day of every calendar month from January 2025 through
    /// `year`/`month`: pay months equal calendar months and those months are closed (`.actual`).
    /// Manual closes rather than salaries, which would add income to the totals under test.
    private func closedThrough(_ year: Int, _ month: Int) -> [PayMonthClose] {
        var closes: [PayMonthClose] = []
        var cursor = (year: 2025, month: 1)
        while cursor.year * 12 + cursor.month <= year * 12 + month {
            let next = cursor.month == 12 ? (cursor.year + 1, 1) : (cursor.year, cursor.month + 1)
            closes.append(PayMonthClose(year: cursor.year, month: cursor.month, closeDate: date(next.0, next.1, 1).addingTimeInterval(-86_400)))
            cursor = next
        }
        return closes
    }

    private var blendedInput: DashboardInput {
        F.input(today: date(2026, 10, 14), transactions: blendedTransactions, manualCloses: closedThrough(2026, 9))
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

    func testCurrentMonthExpectedHonoursASkipAndAMove() {
        // Nothing imported, so the current month is expected-only: rent 100k + dining 40k.
        let today = date(2026, 10, 14)
        let skipRent = PlannedOccurrenceException(entryId: 2, originalDate: date(2026, 10, 1), isSkipped: true)
        XCTAssertEqual(DashboardCalculator.currentMonth(F.input(today: today, entries: F.withDining, exceptions: [skipRent])).expenses.expected, 40_000)
        // Dining moved into November leaves October with rent only.
        let moveDining = PlannedOccurrenceException(entryId: 3, originalDate: date(2026, 10, 14), date: date(2026, 11, 3))
        XCTAssertEqual(DashboardCalculator.currentMonth(F.input(today: today, entries: F.withDining, exceptions: [moveDining])).expenses.expected, 100_000)
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

    // An open pay month that has started is `.blended` even with nothing imported (projected
    // = expected then); the card keys "showing expected only" off `hasTransactions`.
    func testCurrentMonthWithNothingImportedYetShowsExpectedOnly() {
        let input = F.input(today: date(2026, 10, 2), transactions: [F.txn(1, date(2026, 2, 14), -55_000, category: F.diningId)], manualCloses: closedThrough(2026, 9))
        let month = DashboardCalculator.currentMonth(input)
        XCTAssertEqual(month.monthClass, .blended)
        XCTAssertFalse(month.hasTransactions)
        XCTAssertEqual(month.income, FlowTotals(actual: 0, expected: 300_000, projected: 300_000))
        XCTAssertEqual(month.expenses, FlowTotals(actual: 0, expected: 140_000, projected: 140_000))
    }

    func testBulkAllowanceCountsInFullEvenWithNoActuals() {
        let withBulk = F.withDining + [ForecastEntry(id: 9, groupId: 1, categoryId: F.bulkId, amountMinorUnits: -17_139, frequency: .monthly, interval: 1, startDate: date(2026, 1, 14), endDate: nil, isEnabled: true, status: .manual, note: nil)]
        let input = F.input(today: date(2026, 10, 14), transactions: [F.txn(1, date(2026, 10, 13), -55_000, category: F.diningId)], entries: withBulk, reservedId: F.bulkId)
        // Expected 100k rent + 40k dining + 17,139 bulk; actual only dining (55k) → projected 100k + 55k + 17,139.
        XCTAssertEqual(DashboardCalculator.currentMonth(input).expenses.projected, 172_139)
    }

    // Transfers (Savings here) are neither income nor expense: a confirmed transfer
    // transaction and a transfer forecast entry must not move any flow figure.
    func testTransfersAreExcludedFromEveryFlowFigure() {
        let transferEntry = ForecastEntry(id: 9, groupId: 1, categoryId: F.savingsId, amountMinorUnits: -50_000, frequency: .monthly, interval: 1, startDate: date(2026, 1, 1), endDate: nil, isEnabled: true, status: .manual, note: nil)
        let withTransfers = F.input(
            today: date(2026, 10, 14),
            transactions: blendedTransactions + [F.txn(8, date(2026, 10, 8), -200_000, category: F.savingsId)],
            entries: F.withDining + [transferEntry],
            manualCloses: closedThrough(2026, 9)
        )
        let baseline = blendedInput

        let month = DashboardCalculator.currentMonth(withTransfers)
        XCTAssertEqual(month, DashboardCalculator.currentMonth(baseline))
        XCTAssertEqual(month.income, FlowTotals(actual: 0, expected: 300_000, projected: 300_000))
        XCTAssertEqual(month.expenses, FlowTotals(actual: 180_000, expected: 140_000, projected: 180_000))
        XCTAssertEqual(month.unreviewedCount, 2)

        let flows = DashboardCalculator.monthlyFlows(withTransfers, year: 2026)
        XCTAssertEqual(flows, DashboardCalculator.monthlyFlows(baseline, year: 2026))
        XCTAssertEqual([flows[9].incomeActual, flows[9].incomeRemaining, flows[9].expenseActual, flows[9].expenseRemaining], [0, 300_000, 180_000, 0])

        let top = DashboardCalculator.topCategories(withTransfers)
        XCTAssertEqual(top, DashboardCalculator.topCategories(baseline))
        XCTAssertEqual(top.map(\.name), ["Rent", "Food"])
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

    func testCategoryCoveredByAReserveIsNotUnplanned() {
        let txns = [F.txn(1, date(2026, 10, 5), -25_000, category: F.groceriesId), F.txn(2, date(2026, 10, 6), -10_000, category: F.rentId)]
        // Rent is covered by a reserve; groceries (rolled into Food) is an ordinary category.
        let input = F.input(today: date(2026, 10, 14), transactions: txns, entries: [], excludedId: F.rentId)
        let top = DashboardCalculator.topCategories(input, limit: 5)
        let covered = top.first { $0.name == "Rent" }!
        XCTAssertEqual(covered.actual, 10_000)
        XCTAssertFalse(covered.isUnplanned)
        XCTAssertTrue(covered.isCoveredByReserve)
        let ordinary = top.first { $0.name == "Food" }!
        XCTAssertTrue(ordinary.isUnplanned)
        XCTAssertFalse(ordinary.isCoveredByReserve)
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

    private var bulkReserve: ForecastEntry {
        ForecastEntry(id: 9, groupId: 1, categoryId: F.bulkId, amountMinorUnits: -200_000, frequency: .monthly, interval: 1, startDate: date(2026, 1, 1), endDate: nil, isEnabled: true, status: .confirmed, note: nil)
    }

    func testCurrentMonthReportsTheReserveSeparatelyAndInsideExpenses() {
        let input = F.input(today: date(2026, 10, 14), transactions: [F.txn(1, date(2026, 10, 13), -55_000, category: F.diningId)], entries: F.withDining + [bulkReserve], reservedId: F.bulkId)
        let month = DashboardCalculator.currentMonth(input)
        XCTAssertEqual(month.monthClass, .blended)
        XCTAssertEqual(month.reservedProjected, 200_000)
        // 100k rent + max(55k actual, 40k expected) dining + 200k reserve.
        XCTAssertEqual(month.expenses.projected, 355_000)
    }

    func testReserveIsZeroInActualMonthsAndRemainingInBlendedAndForecastMonths() {
        let input = F.input(today: date(2026, 10, 14), transactions: [F.txn(1, date(2026, 9, 3), -1_000, category: F.diningId), F.txn(2, date(2026, 10, 13), -55_000, category: F.diningId)], entries: F.withDining + [bulkReserve], reservedId: F.bulkId, manualCloses: closedThrough(2026, 9))
        let flows = DashboardCalculator.monthlyFlows(input, year: 2026)
        XCTAssertEqual(flows[8].monthClass, .actual)     // September
        XCTAssertEqual(flows[8].reservedRemaining, 0)
        XCTAssertEqual(flows[9].monthClass, .blended)    // October
        XCTAssertEqual(flows[9].reservedRemaining, 200_000)
        XCTAssertEqual(flows[10].monthClass, .forecast)  // November
        XCTAssertEqual(flows[10].reservedRemaining, 200_000)
        XCTAssertGreaterThanOrEqual(flows[10].expenseRemaining, flows[10].reservedRemaining)
    }

    func testUnforecastSpendReducesTheReserveInTheCurrentMonth() {
        // Groceries has nothing forecast, so its 60k comes out of the 200k reserve; dining
        // is forecast and doesn't.
        let input = F.input(today: date(2026, 10, 14), transactions: [F.txn(1, date(2026, 10, 3), -60_000, category: F.groceriesId), F.txn(2, date(2026, 10, 13), -55_000, category: F.diningId)], entries: F.withDining + [bulkReserve], reservedId: F.bulkId)
        let month = DashboardCalculator.currentMonth(input)
        XCTAssertEqual(month.monthClass, .blended)
        XCTAssertEqual(month.reservedProjected, 140_000)
        // 100k rent + 60k groceries + max(55k, 40k) dining + 140k remaining reserve.
        XCTAssertEqual(month.expenses.projected, 355_000)
        // Expected still shows the full allowance: 100k rent + 40k dining + 200k reserve.
        XCTAssertEqual(month.expenses.expected, 340_000)
    }

    func testUnforecastSpendOverTheAllowanceLeavesNothingReserved() {
        let input = F.input(today: date(2026, 10, 14), transactions: [F.txn(1, date(2026, 10, 3), -230_000, category: F.groceriesId)], entries: F.withDining + [bulkReserve], reservedId: F.bulkId)
        let month = DashboardCalculator.currentMonth(input)
        XCTAssertEqual(month.reservedProjected, 0)
        // 100k rent + 230k groceries + 40k dining + 0 reserve.
        XCTAssertEqual(month.expenses.projected, 370_000)
        let flows = DashboardCalculator.monthlyFlows(input, year: 2026)
        XCTAssertEqual(flows[9].reservedRemaining, 0)
        XCTAssertEqual(flows[10].reservedRemaining, 200_000)   // November: no actuals yet
    }

    func testTopCategoriesLeavesReservesOut() {
        let input = F.input(today: date(2026, 10, 14), transactions: [F.txn(1, date(2026, 10, 13), -55_000, category: F.diningId)], entries: F.withDining + [bulkReserve], reservedId: F.bulkId)
        XCTAssertFalse(DashboardCalculator.topCategories(input).contains { $0.name == "Bulk other" })
    }

    // MARK: pay months

    /// Salary on the 15th of January ... `last` month of 2026.
    private func salaries(through last: Int) -> [Date] { (1...last).map { date(2026, $0, 15) } }

    func testCurrentMonthIsThePayMonthContainingToday() {
        let input = F.input(
            today: date(2026, 10, 5),
            transactions: [F.txn(1, date(2026, 9, 15), -10_000, category: F.groceriesId), F.txn(2, date(2026, 9, 16), -20_000, category: F.groceriesId)],
            salaries: salaries(through: 9)
        )
        let month = DashboardCalculator.currentMonth(input)
        XCTAssertEqual([month.year, month.month], [2026, 10])
        XCTAssertEqual(month.start, date(2026, 9, 16))
        XCTAssertEqual(month.end, date(2026, 10, 16).addingTimeInterval(-1))
        XCTAssertEqual(month.dayOfMonth, 20)
        XCTAssertEqual(month.daysInMonth, 30)
        XCTAssertEqual(month.monthClass, .blended)
        XCTAssertTrue(month.hasTransactions)
        XCTAssertEqual(month.expenses.actual, 20_000)

        let flows = DashboardCalculator.monthlyFlows(input, year: 2026)
        XCTAssertEqual(flows[8].expenseActual, 10_000)   // payday row stays in September
        XCTAssertEqual(flows[8].incomeActual, 300_000)
        XCTAssertEqual(flows[9].expenseActual, 20_000)   // the day after belongs to October
    }

    func testCurrentPayMonthWithNoTransactionsYet() {
        let input = F.input(today: date(2026, 10, 5), salaries: salaries(through: 9))
        // October runs 16 Sep - 15 Oct; nothing is dated in it.
        XCTAssertFalse(DashboardCalculator.currentMonth(input).hasTransactions)
    }

    func testClosedMonthReleasesItsReserveAndOpenMonthsKeepWhatIsLeft() {
        let input = F.input(
            today: date(2026, 10, 5),
            // 30k unforecast in September's pay month, 60k in October's (16 Sep onwards).
            transactions: [F.txn(1, date(2026, 9, 10), -30_000, category: F.groceriesId), F.txn(2, date(2026, 9, 20), -60_000, category: F.groceriesId)],
            entries: F.withDining + [bulkReserve], reservedId: F.bulkId,
            salaries: salaries(through: 9)
        )
        let flows = DashboardCalculator.monthlyFlows(input, year: 2026)
        XCTAssertEqual(flows[8].monthClass, .actual)       // September: closed by its salary
        XCTAssertEqual(flows[8].reservedRemaining, 0)
        XCTAssertEqual(flows[8].expenseRemaining, 0)
        XCTAssertEqual(flows[9].monthClass, .blended)      // October: open, current
        XCTAssertEqual(flows[9].reservedRemaining, 140_000)
        XCTAssertEqual(flows[10].monthClass, .forecast)    // November
        XCTAssertEqual(flows[10].reservedRemaining, 200_000)
        XCTAssertEqual(DashboardCalculator.currentMonth(input).reservedProjected, 140_000)
    }

    func testOpenPastMonthIsBlendedAndKeepsItsReserve() {
        let input = F.input(today: date(2026, 10, 5), entries: F.withDining + [bulkReserve], reservedId: F.bulkId, salaries: salaries(through: 2))
        let flows = DashboardCalculator.monthlyFlows(input, year: 2026)
        XCTAssertEqual(flows[1].monthClass, .actual)       // February: salary imported
        XCTAssertEqual(flows[2].monthClass, .blended)      // March: never closed
        XCTAssertEqual(flows[2].reservedRemaining, 200_000)
    }

    func testManualCloseClosesTheMonth() {
        let input = F.input(
            today: date(2026, 10, 5),
            entries: F.withDining + [bulkReserve], reservedId: F.bulkId,
            salaries: salaries(through: 9),
            manualCloses: [PayMonthClose(year: 2026, month: 10, closeDate: date(2026, 10, 3))]
        )
        let flows = DashboardCalculator.monthlyFlows(input, year: 2026)
        XCTAssertEqual(flows[9].monthClass, .actual)
        XCTAssertEqual(flows[9].reservedRemaining, 0)
        XCTAssertEqual(input.payCalendar.current, PayMonth(year: 2026, month: 11))
    }
}
