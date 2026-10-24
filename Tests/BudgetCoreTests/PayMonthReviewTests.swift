import XCTest
import GRDB
@testable import BudgetCore
@testable import BudgetDemo

final class PayMonthReviewTests: XCTestCase {
    /// On the demo, every row's actual is the Budget grid's figure for the pay month
    /// (`BudgetGridCalculator.categoryTotal` over its `PayPeriod`), its plan the calendar
    /// month's confirmed plan, and the summary figures the Mac dashboard's for the month.
    func testReviewRowsEqualTheBudgetGrid() throws {
        let (manager, evidence) = try PhoneDemoFixture.build()
        defer { try? FileManager.default.removeItem(at: evidence) }
        let input = try manager.dbQueue.read { db in try PhoneDemoFixture.input(db) }
        let calendar = input.payCalendar

        // A closed month (September) and the open one (October).
        for month in [calendar.current.previous, calendar.current] {
            let review = PayMonthReview.make(month: month, input: input)
            let range = calendar.range(of: month)
            XCTAssertEqual(review.month, month)
            XCTAssertEqual(review.range.start, range.start)
            XCTAssertEqual(review.range.end, range.end)
            XCTAssertFalse(review.rows.isEmpty)

            let period = PayPeriod(startDate: range.start, endDate: range.end, type: .actual)
            let calendarMonth = MonthRange.of(year: month.year, month: month.month)
            let planPeriod = PayPeriod(startDate: calendarMonth.start, endDate: calendarMonth.end, type: .projected)
            for row in review.rows {
                XCTAssertEqual(row.id, row.category.id)
                XCTAssertEqual(row.actualMinorUnits, BudgetGridCalculator.categoryTotal(
                    category: row.category, period: period, transactions: input.budgetTransactions,
                    forecastEntries: input.forecastEntries, forecastGroups: input.forecastGroups, exceptions: input.exceptions), row.category.name)
                XCTAssertEqual(row.planMinorUnits, BudgetGridCalculator.categoryTotal(
                    category: row.category, period: planPeriod, transactions: input.budgetTransactions,
                    forecastEntries: input.forecastEntries, forecastGroups: input.forecastGroups, exceptions: input.exceptions), row.category.name)
                XCTAssertTrue(row.actualMinorUnits != 0 || row.planMinorUnits != 0)
            }
            // Every category with money in the month has its row; none is an adjustment.
            for category in input.categories where category.type != .adjustment {
                let actual = BudgetGridCalculator.categoryTotal(category: category, period: period, transactions: input.budgetTransactions,
                                                                forecastEntries: [], forecastGroups: [], exceptions: [])
                if actual != 0 { XCTAssertTrue(review.rows.contains { $0.id == category.id }, category.name) }
            }
            XCTAssertTrue(review.rows.allSatisfy { $0.category.type != .adjustment })
            XCTAssertEqual(review.rows(of: .expense) + review.rows(of: .income) + review.rows(of: .transfer),
                           review.rows.sorted { (order($0), $0.category.name, $0.id) < (order($1), $1.category.name, $1.id) })

            // The summary: the dashboard's figures for the month (year chart).
            let flow = DashboardCalculator.monthlyFlows(input, year: month.year)[month.month - 1]
            XCTAssertEqual(review.incomeMinorUnits, flow.incomeTotal)
            XCTAssertEqual(review.spentMinorUnits, flow.expenseActual)
            XCTAssertEqual(review.stillExpectedMinorUnits, flow.expenseRemaining)
            XCTAssertEqual(review.leftToSpendMinorUnits, flow.net)
            // Spent is the expense rows' actuals.
            XCTAssertEqual(review.spentMinorUnits, -review.rows(of: .expense).map(\.actualMinorUnits).reduce(0, +))
        }

        // The open month agrees with Home.
        let home = try manager.dbQueue.read { db in try HomeSummary.make(input, db: db) }
        let current = PayMonthReview.make(month: calendar.current, input: input)
        XCTAssertEqual(current.spentMinorUnits, home.month.expenses.actual)
        XCTAssertEqual(current.stillExpectedMinorUnits, home.leftToSpendMinorUnits)
        XCTAssertEqual(current.incomeMinorUnits, home.month.income.projected)
        XCTAssertEqual(current.leftToSpendMinorUnits, home.month.net.projected)
        // A closed month expects nothing more.
        XCTAssertEqual(PayMonthReview.make(month: calendar.current.previous, input: input).stillExpectedMinorUnits, 0)
    }

    private func order(_ row: PayMonthReview.Row) -> Int {
        switch row.category.type {
        case .expense: return 0
        case .income: return 1
        case .transfer: return 2
        case .adjustment: return 3
        }
    }

    /// An expense over its plan, or spent with no plan (and no reserve covering it), is
    /// flagged; one within it, an income above its plan and a reserve-covered category are not.
    func testOverPlanRowsFlagged() throws {
        let d = DashboardFixture.date
        let today = d(2026, 3, 20)
        let input = DashboardFixture.input(
            today: today,
            transactions: [
                DashboardFixture.txn(1, d(2026, 3, 2), -150_000, category: DashboardFixture.rentId),       // plan -1,000: over
                DashboardFixture.txn(2, d(2026, 3, 14), -10_000, category: DashboardFixture.diningId),     // plan -400: within
                DashboardFixture.txn(3, d(2026, 3, 5), -2_000, category: DashboardFixture.groceriesId),    // no plan: over
                DashboardFixture.txn(4, d(2026, 3, 6), -3_000, category: DashboardFixture.bulkId),         // no plan, covered: not
                DashboardFixture.txn(5, d(2026, 3, 10), 350_000, category: DashboardFixture.salaryId),     // income above plan: not
                DashboardFixture.txn(6, d(2026, 3, 11), -50_000, category: DashboardFixture.savingsId)     // transfer, no plan
            ],
            excludedId: DashboardFixture.bulkId
        )
        let review = PayMonthReview.make(month: PayMonth(year: 2026, month: 3), input: input)
        func row(_ id: Int64) throws -> PayMonthReview.Row { try XCTUnwrap(review.rows.first { $0.id == id }) }

        XCTAssertEqual(try row(DashboardFixture.rentId).actualMinorUnits, -150_000)
        XCTAssertEqual(try row(DashboardFixture.rentId).planMinorUnits, -100_000)
        XCTAssertTrue(try row(DashboardFixture.rentId).isOverPlan)
        XCTAssertEqual(try row(DashboardFixture.rentId).remainingMinorUnits, -50_000)

        XCTAssertFalse(try row(DashboardFixture.diningId).isOverPlan)
        XCTAssertEqual(try row(DashboardFixture.diningId).remainingMinorUnits, 30_000)

        XCTAssertTrue(try row(DashboardFixture.groceriesId).isOverPlan)
        XCTAssertFalse(try row(DashboardFixture.bulkId).isOverPlan)
        XCTAssertFalse(try row(DashboardFixture.salaryId).isOverPlan)
        XCTAssertFalse(try row(DashboardFixture.savingsId).isOverPlan)
        XCTAssertEqual(review.rows.filter(\.isOverPlan).map(\.id).sorted(), [DashboardFixture.rentId, DashboardFixture.groceriesId].sorted())
        XCTAssertEqual(review.rows(of: .transfer).map(\.id), [DashboardFixture.savingsId])
    }

    /// A month with no transactions and no plan has no rows and nothing to show.
    func testEmptyMonthHasNoRows() throws {
        let d = DashboardFixture.date
        let input = DashboardFixture.input(today: d(2026, 3, 20), entries: [])
        let review = PayMonthReview.make(month: PayMonth(year: 2026, month: 3), input: input)
        XCTAssertTrue(review.rows.isEmpty)
        XCTAssertTrue(review.rows(of: .expense).isEmpty)
        XCTAssertEqual(review.incomeMinorUnits, 0)
        XCTAssertEqual(review.spentMinorUnits, 0)
        XCTAssertEqual(review.stillExpectedMinorUnits, 0)
        XCTAssertEqual(review.leftToSpendMinorUnits, 0)

        // On the demo, a month long before its history is just as empty.
        let (manager, evidence) = try PhoneDemoFixture.build()
        defer { try? FileManager.default.removeItem(at: evidence) }
        let demo = try manager.dbQueue.read { db in try PhoneDemoFixture.input(db) }
        XCTAssertTrue(PayMonthReview.make(month: PayMonth(year: 2015, month: 1), input: demo).rows.isEmpty)
    }

    /// A transfer or income with no plan has nothing "left": only planned rows (and
    /// unplanned spending, which is all over plan) carry a remainder.
    func testUnplannedTransfersAndIncomeHaveNoRemainder() throws {
        let d = DashboardFixture.date
        let input = DashboardFixture.input(
            today: d(2026, 3, 20),
            transactions: [
                DashboardFixture.txn(1, d(2026, 3, 11), 50_000, category: DashboardFixture.savingsId),     // inward, unplanned
                DashboardFixture.txn(2, d(2026, 3, 12), -20_000, category: DashboardFixture.savingsId),    // outward, unplanned
                DashboardFixture.txn(3, d(2026, 3, 5), -2_000, category: DashboardFixture.groceriesId)     // expense, unplanned
            ],
            entries: []
        )
        let review = PayMonthReview.make(month: PayMonth(year: 2026, month: 3), input: input)
        XCTAssertNil(try XCTUnwrap(review.rows.first { $0.id == DashboardFixture.savingsId }).remainingMinorUnits)
        XCTAssertEqual(try XCTUnwrap(review.rows.first { $0.id == DashboardFixture.groceriesId }).remainingMinorUnits, -2_000)

        let salary = DashboardFixture.input(today: d(2026, 3, 20),
                                            transactions: [DashboardFixture.txn(1, d(2026, 3, 11), 10_000, category: DashboardFixture.diningId),
                                                           DashboardFixture.txn(2, d(2026, 3, 12), 30_000, category: DashboardFixture.salaryId)],
                                            entries: [])
        let income = PayMonthReview.make(month: PayMonth(year: 2026, month: 3), input: salary)
        XCTAssertNil(try XCTUnwrap(income.rows.first { $0.id == DashboardFixture.salaryId }).remainingMinorUnits)
    }

    /// The one-month flow is the year chart's month, for every month of the demo's year.
    func testOneMonthFlowEqualsTheYearChart() throws {
        let (manager, evidence) = try PhoneDemoFixture.build()
        defer { try? FileManager.default.removeItem(at: evidence) }
        let input = try manager.dbQueue.read { db in try PhoneDemoFixture.input(db) }
        for year in [2025, 2026] {
            let flows = DashboardCalculator.monthlyFlows(input, year: year)
            for month in 1...12 {
                XCTAssertEqual(DashboardCalculator.monthlyFlow(input, month: PayMonth(year: year, month: month)), flows[month - 1])
            }
        }
    }
}
