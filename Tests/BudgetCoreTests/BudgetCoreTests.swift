import XCTest
@testable import BudgetCore

final class BudgetCoreTests: XCTestCase {
    func testVersionIsSet() {
        XCTAssertEqual(BudgetCore.version, "0.1.0")
    }
}
