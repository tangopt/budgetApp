import XCTest
@testable import BudgetCore

final class TouchIDAutoPromptTests: XCTestCase {
    private func user(last: Int64? = nil, _ candidates: [Int64], enrolled: Set<Int64>, available: Bool = true) -> Int64? {
        TouchIDAutoPrompt.user(lastSignedIn: last, candidates: candidates, enrolled: enrolled, touchIDAvailable: available)
    }

    func testUlastSignedInWinsWhenEnrolled() {
        XCTAssertEqual(user(last: 2, [1, 2], enrolled: [1, 2]), 2)
    }

    func testUonlyEnrolledCandidateWhenLastIsNotEnrolled() {
        XCTAssertEqual(user(last: 2, [1, 2], enrolled: [1]), 1)
        XCTAssertEqual(user([1, 2], enrolled: [2]), 2)
    }

    func testUambiguousOrNoneEnrolledMeansNobody() {
        XCTAssertEqual(user([1, 2], enrolled: [1, 2]), nil)
        XCTAssertEqual(user(last: 3, [1, 2], enrolled: [1, 2]), nil)
        XCTAssertEqual(user([1, 2], enrolled: []), nil)
    }

    func testUenrolmentOfSomeoneWhoCannotSignInDoesNotCount() {
        XCTAssertEqual(user(last: 9, [1], enrolled: [9]), nil)
        XCTAssertEqual(user([1], enrolled: [1, 9]), 1)
    }

    func testUnoTouchIDMeansNobody() {
        XCTAssertEqual(user(last: 1, [1], enrolled: [1], available: false), nil)
    }

    func testUpromptsOnceWhenLockedAndActive() {
        var p = TouchIDAutoPrompt()
        XCTAssertTrue(p.shouldPrompt(isLocked: true, appIsActive: true, otherStepInProgress: false))
        p.promptStarted()
        XCTAssertFalse(p.shouldPrompt(isLocked: true, appIsActive: true, otherStepInProgress: false))
        p.promptEnded(decided: true)
        XCTAssertFalse(p.shouldPrompt(isLocked: true, appIsActive: true, otherStepInProgress: false))
    }

    func testUneverWhenInactiveNotLockedOrBusy() {
        let p = TouchIDAutoPrompt()
        XCTAssertFalse(p.shouldPrompt(isLocked: true, appIsActive: false, otherStepInProgress: false))
        XCTAssertFalse(p.shouldPrompt(isLocked: false, appIsActive: true, otherStepInProgress: false))
        XCTAssertFalse(p.shouldPrompt(isLocked: true, appIsActive: true, otherStepInProgress: true))
    }

    func testUundecidedPromptAsksAgainOnActivation() {
        var p = TouchIDAutoPrompt()
        p.promptStarted()
        p.promptEnded(decided: false)
        XCTAssertTrue(p.shouldPrompt(isLocked: true, appIsActive: true, otherStepInProgress: false))
    }

    func testUnewLockPromptsAgain() {
        var p = TouchIDAutoPrompt()
        p.promptStarted()
        p.promptEnded(decided: true)
        p.lockBegan()
        XCTAssertTrue(p.shouldPrompt(isLocked: true, appIsActive: true, otherStepInProgress: false))
    }
}
