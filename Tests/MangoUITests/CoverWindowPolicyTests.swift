import XCTest
@testable import MangoUI

/// When the cover window shows, takes VoiceOver and touches, dismisses what the content presented, and announces
/// itself (plan step 4, Task 11 fix rounds 1–2).
final class CoverWindowPolicyTests: XCTestCase {
    func testUnlockedAndActiveIsOutOfTheWay() {
        let state = CoverWindowPolicy.state(locked: false, active: true, wasShown: false)
        XCTAssertFalse(state.isShown)
        XCTAssertFalse(state.takesAccessibilityAndTouches)
        XCTAssertFalse(state.dismissesPresented)
        XCTAssertFalse(state.announcesScreenChange)
    }

    /// Unlocking (or coming back unlocked) takes the cover away from an active scene: VoiceOver moves to the app.
    func testTheCoverGoingAwayAnnouncesTheApp() {
        let state = CoverWindowPolicy.state(locked: false, active: true, wasShown: true)
        XCTAssertFalse(state.isShown)
        XCTAssertFalse(state.takesAccessibilityAndTouches)
        XCTAssertTrue(state.announcesScreenChange)
    }

    func testInactiveCoversWithoutDismissingOrAnnouncing() {
        let state = CoverWindowPolicy.state(locked: false, active: false, wasShown: false)
        XCTAssertTrue(state.isShown)
        XCTAssertTrue(state.takesAccessibilityAndTouches)
        XCTAssertFalse(state.dismissesPresented, "going to the app switcher must not close a sheet")
        XCTAssertFalse(state.announcesScreenChange, "nobody is looking while the scene is inactive")
    }

    func testALockWhileActiveCoversDismissesAndAnnounces() {
        let state = CoverWindowPolicy.state(locked: true, active: true, wasShown: false)
        XCTAssertTrue(state.isShown)
        XCTAssertTrue(state.takesAccessibilityAndTouches)
        XCTAssertTrue(state.dismissesPresented)
        XCTAssertTrue(state.announcesScreenChange)
    }

    /// Back in front after a relock in the background: the cover was already up (privacy), and now shows the lock
    /// screen to an active scene, so VoiceOver hears it.
    func testAnnouncementWhileLockedAndActive() {
        let cases: [(name: String, wasActive: Bool, announces: Bool)] = [
            // Back in front after a relock in the background: the cover was already up (privacy), and now shows the lock
            // screen to an active scene, so VoiceOver hears it.
            ("becoming active while locked announces the lock screen", false, true),
            ("no repeat announcement while it stays locked and active", true, false),
        ]
        for c in cases {
            let state = CoverWindowPolicy.state(locked: true, active: true, wasShown: true, wasActive: c.wasActive)
            XCTAssertTrue(state.isShown, c.name)
            XCTAssertEqual(state.announcesScreenChange, c.announces, c.name)
        }
    }
}
