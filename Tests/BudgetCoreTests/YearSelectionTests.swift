import XCTest
@testable import BudgetCore

final class YearSelectionTests: XCTestCase {
    func testTogglingAddsSortedAndRemovesButNeverTheLastYear() {
        XCTAssertEqual(YearSelection.toggled([2027], 2026), [2026, 2027])
        XCTAssertEqual(YearSelection.toggled([2026, 2027], 2028), [2026, 2027, 2028])
        XCTAssertEqual(YearSelection.toggled([2026, 2027, 2028], 2027), [2026, 2028])
        XCTAssertEqual(YearSelection.toggled([2026], 2026), [2026])
    }

    func testClampingKeepsAvailableYearsElseFallsBackToThePreferredOrFirst() {
        XCTAssertEqual(YearSelection.clamped([2026, 2030], to: [2026, 2027, 2028], preferred: 2026), [2026])
        XCTAssertEqual(YearSelection.clamped([2030], to: [2026, 2027], preferred: 2026), [2026])
        XCTAssertEqual(YearSelection.clamped([2030], to: [2027, 2028], preferred: 2026), [2027])
        XCTAssertEqual(YearSelection.clamped([2030], to: [], preferred: 2026), [2030])
    }
}
