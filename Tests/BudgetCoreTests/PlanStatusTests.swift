import XCTest
@testable import BudgetCore

final class PlanStatusTests: XCTestCase {
    func check(_ r: (value: Int, pending: Int, state: PendingState), _ value: Int, _ pending: Int, _ state: PendingState, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(r.value, value, "value", file: file, line: line)
        XCTAssertEqual(r.pending, pending, "pending", file: file, line: line)
        XCTAssertEqual(r.state, state, "state", file: file, line: line)
    }

    func testExpenseAllExpected() {
        check(PlanStatus.cell(actual: 0, planned: -10000, categoryType: .expense, monthClass: .blended), -10000, -10000, .allExpected)
        check(PlanStatus.cell(actual: 0, planned: -10000, categoryType: .expense, monthClass: .forecast), -10000, -10000, .allExpected)
    }

    func testExpensePartial() {
        check(PlanStatus.cell(actual: -4000, planned: -10000, categoryType: .expense, monthClass: .blended), -10000, -6000, .partial)
    }

    /// A refund against an expense plan isn't progress towards it: still all expected.
    func testActualInTheOppositeDirectionIsAllExpected() {
        check(PlanStatus.cell(actual: 1000, planned: -10000, categoryType: .expense, monthClass: .blended), -10000, -11000, .allExpected)
        check(PlanStatus.cell(actual: -500, planned: 300000, categoryType: .income, monthClass: .blended), 300000, 300500, .allExpected)
        check(PlanStatus.cell(actual: 2000, planned: -10000, categoryType: .transfer, monthClass: .blended), -10000, -12000, .allExpected)
    }

    func testExpenseCovered() {
        check(PlanStatus.cell(actual: -12000, planned: -10000, categoryType: .expense, monthClass: .blended), -12000, 0, .none)
        check(PlanStatus.cell(actual: -10000, planned: -10000, categoryType: .expense, monthClass: .blended), -10000, 0, .none)
    }

    func testNothingPlanned() {
        check(PlanStatus.cell(actual: -500, planned: 0, categoryType: .expense, monthClass: .blended), -500, 0, .none)
        check(PlanStatus.cell(actual: 0, planned: 0, categoryType: .income, monthClass: .forecast), 0, 0, .none)
    }

    func testClosedMonthShowsActualOnly() {
        check(PlanStatus.cell(actual: -4000, planned: -10000, categoryType: .expense, monthClass: .actual), -4000, 0, .none)
        check(PlanStatus.cell(actual: 0, planned: 300000, categoryType: .income, monthClass: .actual), 0, 0, .none)
    }

    func testIncomeDirection() {
        check(PlanStatus.cell(actual: 0, planned: 300000, categoryType: .income, monthClass: .blended), 300000, 300000, .allExpected)
        check(PlanStatus.cell(actual: 100000, planned: 300000, categoryType: .income, monthClass: .blended), 300000, 200000, .partial)
        check(PlanStatus.cell(actual: 310000, planned: 300000, categoryType: .income, monthClass: .blended), 310000, 0, .none)
    }

    func testTransferFollowsSignOfPlan() {
        check(PlanStatus.cell(actual: -3000, planned: -10000, categoryType: .transfer, monthClass: .blended), -10000, -7000, .partial)
        check(PlanStatus.cell(actual: 0, planned: 10000, categoryType: .transfer, monthClass: .blended), 10000, 10000, .allExpected)
        check(PlanStatus.cell(actual: 12000, planned: 10000, categoryType: .transfer, monthClass: .blended), 12000, 0, .none)
        check(PlanStatus.cell(actual: -3000, planned: 0, categoryType: .transfer, monthClass: .blended), -3000, 0, .none)
    }

    /// The displayed value matches the Forecast grid's blend for an open month.
    func testValueMatchesMonthBlend() {
        for (a, p, t) in [(-4000, -10000, CategoryType.expense), (100000, 300000, .income), (-3000, -10000, .transfer), (2000, 10000, .transfer), (-12000, -10000, .expense)] {
            XCTAssertEqual(PlanStatus.cell(actual: a, planned: p, categoryType: t, monthClass: .blended).value,
                           MonthBlend.projectedTotal(actual: a, expected: p, categoryType: t, monthClass: .blended))
        }
    }

    func testCombinePartialWinsOverAllExpected() {
        let a = PlanStatus.cell(actual: 0, planned: -10000, categoryType: .expense, monthClass: .blended)
        let b = PlanStatus.cell(actual: -4000, planned: -10000, categoryType: .expense, monthClass: .blended)
        let c = PlanStatus.cell(actual: -500, planned: 0, categoryType: .expense, monthClass: .blended)
        check(PlanStatus.combine([a, b, c]), -20500, -16000, .partial)
    }

    func testCombineAllExpectedWhenAnyPendingAndNonePartial() {
        let a = PlanStatus.cell(actual: 0, planned: -10000, categoryType: .expense, monthClass: .blended)
        let covered = PlanStatus.cell(actual: -12000, planned: -10000, categoryType: .expense, monthClass: .blended)
        check(PlanStatus.combine([a, covered]), -22000, -10000, .allExpected)
    }

    func testCombineNothingPending() {
        let closed = PlanStatus.cell(actual: -4000, planned: -10000, categoryType: .expense, monthClass: .actual)
        check(PlanStatus.combine([closed, closed]), -8000, 0, .none)
        check(PlanStatus.combine([]), 0, 0, .none)
    }
}
