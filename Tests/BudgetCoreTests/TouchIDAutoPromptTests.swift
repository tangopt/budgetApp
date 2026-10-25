import XCTest
@testable import BudgetCore

final class TouchIDAutoPromptTests: XCTestCase {
    private func user(last: Int64? = nil, _ candidates: [Int64], enrolled: Set<Int64>, available: Bool = true) -> Int64? {
        TouchIDAutoPrompt.user(lastSignedIn: last, candidates: candidates, enrolled: enrolled, touchIDAvailable: available)
    }

    func testWhoIsAskedForTouchID() {
        let cases: [(name: String, last: Int64?, candidates: [Int64], enrolled: Set<Int64>, available: Bool, expected: Int64?)] = [
            ("the last signed-in wins when enrolled", 2, [1, 2], [1, 2], true, 2),
            ("the only enrolled candidate when the last is not enrolled", 2, [1, 2], [1], true, 1),
            ("the only enrolled candidate when there is no last", nil, [1, 2], [2], true, 2),
            ("ambiguous means nobody", nil, [1, 2], [1, 2], true, nil),
            ("a last that is not a candidate means nobody when both are enrolled", 3, [1, 2], [1, 2], true, nil),
            ("none enrolled means nobody", nil, [1, 2], [], true, nil),
            ("enrolment of someone who cannot sign in does not count (last)", 9, [1], [9], true, nil),
            ("enrolment of someone who cannot sign in does not count (other)", nil, [1], [1, 9], true, 1),
            ("no Touch ID means nobody", 1, [1], [1], false, nil),
        ]
        for c in cases {
            XCTAssertEqual(user(last: c.last, c.candidates, enrolled: c.enrolled, available: c.available), c.expected, c.name)
        }
    }

    /// At launch the lock screen comes up before the people are read: nobody to ask yet, and the lock's
    /// one prompt is still owed for when they are.
    func testUnobodyYetLeavesThePromptOwed() {
        let p = TouchIDAutoPrompt()
        XCTAssertNil(user([], enrolled: [1]))
        XCTAssertTrue(p.shouldPrompt(isLocked: true, appIsActive: true, otherStepInProgress: false))
        XCTAssertEqual(user([1], enrolled: [1]), 1)
    }

    /// The glyph never reached a window (the try didn't start): not decided, so the next trigger asks again.
    func testUtryThatNeverStartedIsStillOwed() {
        var p = TouchIDAutoPrompt()
        p.promptStarted()
        XCTAssertFalse(p.shouldPrompt(isLocked: true, appIsActive: true, otherStepInProgress: false))
        p.promptEnded(decided: false)
        XCTAssertTrue(p.shouldPrompt(isLocked: true, appIsActive: true, otherStepInProgress: false))
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

    func testUnewLockPromptsAgain() {
        var p = TouchIDAutoPrompt()
        p.promptStarted()
        p.promptEnded(decided: true)
        p.lockBegan()
        XCTAssertTrue(p.shouldPrompt(isLocked: true, appIsActive: true, otherStepInProgress: false))
    }
}
