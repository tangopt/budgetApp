// Tests/BudgetCoreTests/YearOverYearTests.swift
import XCTest
@testable import BudgetCore

final class YearOverYearTests: XCTestCase {
    func testPositivePreviousGrowth() {
        let delta = YearOverYear.delta(current: 1200, previous: 1000)
        XCTAssertEqual(delta.amount, 200)
        XCTAssertEqual(delta.fraction!, 0.2, accuracy: 1e-9)
    }

    func testNegativePreviousFractionUsesMagnitude() {
        // Expenses are negative: spending 900 instead of 1000 is +100, +10% of |previous|.
        let delta = YearOverYear.delta(current: -900, previous: -1000)
        XCTAssertEqual(delta.amount, 100)
        XCTAssertEqual(delta.fraction!, 0.1, accuracy: 1e-9)
    }

    func testZeroPreviousHasNoFraction() {
        let delta = YearOverYear.delta(current: 500, previous: 0)
        XCTAssertEqual(delta.amount, 500)
        XCTAssertNil(delta.fraction)
    }

    func testBothZero() {
        let delta = YearOverYear.delta(current: 0, previous: 0)
        XCTAssertEqual(delta.amount, 0)
        XCTAssertNil(delta.fraction)
    }

    func testImprovementByCategoryType() {
        XCTAssertEqual(YearOverYear.isImprovement(amount: 100, categoryType: .expense), true)
        XCTAssertEqual(YearOverYear.isImprovement(amount: -100, categoryType: .expense), false)
        XCTAssertEqual(YearOverYear.isImprovement(amount: 100, categoryType: .income), true)
        XCTAssertEqual(YearOverYear.isImprovement(amount: -100, categoryType: .income), false)
        XCTAssertNil(YearOverYear.isImprovement(amount: 100, categoryType: .transfer))
        XCTAssertNil(YearOverYear.isImprovement(amount: 100, categoryType: nil))
        XCTAssertNil(YearOverYear.isImprovement(amount: 0, categoryType: .expense))
    }
}
