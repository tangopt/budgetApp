import XCTest
@testable import BudgetCore

final class MoneyTests: XCTestCase {
    func testFormatInputExamples() {
        XCTAssertEqual(Money.formatInput(4400751), "44,007.51")
        XCTAssertEqual(Money.formatInput(0), "0.00")
        XCTAssertEqual(Money.formatInput(-1200), "-12.00")
        XCTAssertEqual(Money.formatInput(100000000), "1,000,000.00")
        XCTAssertEqual(Money.formatInput(5), "0.05")
        XCTAssertEqual(Money.formatInput(99999), "999.99")
        XCTAssertEqual(Money.formatInput(100000), "1,000.00")
        XCTAssertEqual(Money.formatInput(-123456789), "-1,234,567.89")
    }

    func testFormatInputRoundTripsThroughParse() {
        let values = [0, 1, 5, 99, 100, 101, 99999, 100000, 4400751, 100000000, 123456789012,
                      -1, -99, -100, -1200, -4400751, -100000000]
        for value in values {
            XCTAssertEqual(Money.parseMinorUnits(Money.formatInput(value)), value, "round trip \(value)")
        }
    }
}
