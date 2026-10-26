import XCTest
@testable import BudgetCore

final class HouseholdJoinTests: XCTestCase {
    func testRequesterStatusesMapToTheScreen() {
        XCTAssertEqual(HouseholdJoinState(requester: .waitingForMac), .waitingForKey)
        XCTAssertEqual(HouseholdJoinState(requester: .showCode("123456")), .showCode("123456"))
        XCTAssertEqual(HouseholdJoinState(requester: .received), .pulling)
        XCTAssertEqual(HouseholdJoinState(requester: .refused), .refused)
        XCTAssertEqual(HouseholdJoinState(requester: .expired), .expired)
        XCTAssertTrue(HouseholdJoinState.refused.offersStartAgain)
        XCTAssertTrue(HouseholdJoinState.expired.offersStartAgain)
        XCTAssertFalse(HouseholdJoinState.showCode("123456").offersStartAgain)
    }

    func testNothingShowsOnceTheFirstPullHasSucceeded() {
        XCTAssertNil(HouseholdJoinState.afterPull(status: .idle(lastSync: Date()), joined: true))
        XCTAssertNil(HouseholdJoinState.afterPull(status: .offline(since: Date(), retryAt: nil), joined: true))
    }

    func testAnAcceptedShareThatNeverReachesTheDeviceSaysStillJoiningWithAReason() {
        XCTAssertEqual(HouseholdJoinState.afterPull(status: .idle(lastSync: Date()), joined: false), .stillJoining(.notShownYet))
        XCTAssertEqual(HouseholdJoinState.afterPull(status: .offline(since: Date(), retryAt: nil), joined: false), .stillJoining(.offline))
        XCTAssertEqual(HouseholdJoinState.afterPull(status: .failed(reason: "database error"), joined: false),
                       .stillJoining(.syncStopped("database error")))
        XCTAssertEqual(HouseholdJoinState.afterPull(status: .syncing(.pulling), joined: false), .pulling)
        // Before any pull has finished there is nothing to report yet.
        XCTAssertEqual(HouseholdJoinState.afterPull(status: .idle(lastSync: nil), joined: false), .pulling)
        XCTAssertTrue(HouseholdJoinState.stillJoining(.offline).offersRetry)
        XCTAssertFalse(HouseholdCopy.stillJoiningReason(.notShownYet).isEmpty)
    }

    func testTheAdminsPhoneHasNoMembershipAndKeepsItsOwnZones() {
        XCTAssertEqual(HouseholdJoinState.plan(owner: nil, keyHeld: false), .ownZones)
        XCTAssertEqual(HouseholdJoinState.plan(owner: nil, keyHeld: true), .ownZones)
        XCTAssertEqual(HouseholdJoinState.plan(owner: "_owner", keyHeld: false), .exchangeKey)
        XCTAssertEqual(HouseholdJoinState.plan(owner: "_owner", keyHeld: true), .pullHousehold)
    }
}
