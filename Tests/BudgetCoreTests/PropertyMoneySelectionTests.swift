import XCTest
@testable import BudgetCore

final class PropertyMoneySelectionTests: XCTestCase {
    private let ids = ["income", "costs", "interest"]

    func testStepsDownAndUp() {
        XCTAssertEqual(PropertyMoneySelection.step(ids: ids, from: "income", by: 1), "costs")
        XCTAssertEqual(PropertyMoneySelection.step(ids: ids, from: "interest", by: -1), "costs")
    }

    func testStopsAtTheEnds() {
        XCTAssertEqual(PropertyMoneySelection.step(ids: ids, from: "interest", by: 1), "interest")
        XCTAssertEqual(PropertyMoneySelection.step(ids: ids, from: "income", by: -1), "income")
    }

    func testNothingSelectedOrGone() {
        XCTAssertEqual(PropertyMoneySelection.step(ids: ids, from: nil, by: 1), "income")
        XCTAssertEqual(PropertyMoneySelection.step(ids: ids, from: nil, by: -1), "interest")
        XCTAssertEqual(PropertyMoneySelection.step(ids: ids, from: "gone", by: 1), "income")
        XCTAssertNil(PropertyMoneySelection.step(ids: [], from: "income", by: 1))
    }
}
