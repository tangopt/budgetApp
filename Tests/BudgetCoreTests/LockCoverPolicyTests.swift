import XCTest
@testable import BudgetCore

final class LockCoverPolicyTests: XCTestCase {
    func testSameUserGetsTheirSheetsBack() {
        XCTAssertEqual(LockCoverPolicy.onUncover(coveredFor: 1, signedIn: 1), .restore)
    }

    func testAnotherUserNeverSeesThem() {
        XCTAssertEqual(LockCoverPolicy.onUncover(coveredFor: 1, signedIn: 2), .dismiss)
    }

    func testUnknownOwnerOrNobodyDismisses() {
        XCTAssertEqual(LockCoverPolicy.onUncover(coveredFor: nil, signedIn: 2), .dismiss)
        XCTAssertEqual(LockCoverPolicy.onUncover(coveredFor: 1, signedIn: nil), .dismiss)
        XCTAssertEqual(LockCoverPolicy.onUncover(coveredFor: nil, signedIn: nil), .dismiss)
    }
}
