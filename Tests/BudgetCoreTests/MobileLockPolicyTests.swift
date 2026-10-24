import XCTest
@testable import BudgetCore

final class MobileLockPolicyTests: XCTestCase {
    private let backgrounded = Date(timeIntervalSinceReferenceDate: 800_000_000)

    func testLocksAfterFiveMinutesInBackground() {
        XCTAssertEqual(MobileLockPolicy.backgroundGrace, 300)
        XCTAssertFalse(MobileLockPolicy.shouldLock(backgroundedAt: backgrounded, now: backgrounded.addingTimeInterval(299)))
        XCTAssertTrue(MobileLockPolicy.shouldLock(backgroundedAt: backgrounded, now: backgrounded.addingTimeInterval(300)))
        XCTAssertTrue(MobileLockPolicy.shouldLock(backgroundedAt: backgrounded, now: backgrounded.addingTimeInterval(3_600)))
        XCTAssertFalse(MobileLockPolicy.shouldLock(backgroundedAt: nil, now: backgrounded))
    }

    /// A clock that moved backwards can't prove the app was away for less than the grace, so it locks.
    func testClockMovedBackLocks() {
        XCTAssertTrue(MobileLockPolicy.shouldLock(backgroundedAt: backgrounded, now: backgrounded.addingTimeInterval(-1)))
    }

    func testNoPasscodeStaysLockedWithExplanation() {
        let copy = MobileLockPolicy.lockScreenCopy(.noPasscode)
        XCTAssertEqual(copy.title, "Mango needs a device passcode")
        XCTAssertEqual(copy.body, "Set a passcode in Settings to protect the household's figures.")
        XCTAssertEqual(copy.primary, "Open Settings")
        XCTAssertNil(copy.secondary)
        // canEvaluatePolicy failing with passcodeNotSet is the no-passcode state, whatever the biometry.
        XCTAssertEqual(MobileLockPolicy.availability(deviceOwner: .failed(.passcodeNotSet), biometry: .faceID), .noPasscode)
        XCTAssertEqual(MobileLockPolicy.availability(deviceOwner: .failed(.passcodeNotSet), biometry: nil), .noPasscode)
        XCTAssertFalse(MobileLockPolicy.canAttemptUnlock(.noPasscode))
    }

    func testCopyPerAvailability() {
        let face = MobileLockPolicy.lockScreenCopy(.biometrics(.faceID))
        XCTAssertEqual(face.title, "Mango is locked")
        XCTAssertEqual(face.body, "Your household's figures are hidden until you unlock.")
        XCTAssertEqual(face.primary, "Unlock with Face ID")
        XCTAssertEqual(face.secondary, "Use passcode")

        let touch = MobileLockPolicy.lockScreenCopy(.biometrics(.touchID))
        XCTAssertEqual(touch.title, "Mango is locked")
        XCTAssertEqual(touch.primary, "Unlock with Touch ID")
        XCTAssertEqual(touch.secondary, "Use passcode")

        let passcode = MobileLockPolicy.lockScreenCopy(.passcodeOnly)
        XCTAssertEqual(passcode.title, "Mango is locked")
        XCTAssertEqual(passcode.body, "Your household's figures are hidden until you unlock.")
        XCTAssertEqual(passcode.primary, "Unlock with passcode")
        XCTAssertNil(passcode.secondary)

        let unavailable = MobileLockPolicy.lockScreenCopy(.unavailable(.faceID))
        XCTAssertEqual(unavailable.title, "Mango is locked")
        XCTAssertEqual(unavailable.primary, "Try again")
        XCTAssertNil(unavailable.secondary)
    }

    /// The `.unavailable` explanation names only what this device has.
    func testUnavailableCopyFitsTheDevice() {
        XCTAssertEqual(MobileLockPolicy.lockScreenCopy(.unavailable(.faceID)).body,
                       "Face ID and the passcode can't be used right now. Try again in a moment.")
        XCTAssertEqual(MobileLockPolicy.lockScreenCopy(.unavailable(.touchID)).body,
                       "Touch ID and the passcode can't be used right now. Try again in a moment.")
        XCTAssertEqual(MobileLockPolicy.lockScreenCopy(.unavailable(nil)).body,
                       "The passcode can't be used right now. Try again in a moment.")
    }

    func testAvailabilityFromTheDevice() {
        XCTAssertEqual(MobileLockPolicy.availability(deviceOwner: .available, biometry: .faceID), .biometrics(.faceID))
        XCTAssertEqual(MobileLockPolicy.availability(deviceOwner: .available, biometry: .touchID), .biometrics(.touchID))
        XCTAssertEqual(MobileLockPolicy.availability(deviceOwner: .available, biometry: nil), .passcodeOnly)
        XCTAssertEqual(MobileLockPolicy.availability(deviceOwner: .failed(.other), biometry: .faceID), .unavailable(.faceID))
        XCTAssertEqual(MobileLockPolicy.availability(deviceOwner: .failed(.other), biometry: nil), .unavailable(nil))
        XCTAssertTrue(MobileLockPolicy.canAttemptUnlock(.biometrics(.faceID)))
        XCTAssertTrue(MobileLockPolicy.canAttemptUnlock(.passcodeOnly))
        XCTAssertTrue(MobileLockPolicy.canAttemptUnlock(.unavailable(nil)))
    }

    // MARK: Background timing on the continuous clock (fix round 1)

    private func stamp(_ wallOffset: TimeInterval, _ continuousOffset: Duration,
                       base: ContinuousClock.Instant) -> MobileLockPolicy.BackgroundStamp {
        MobileLockPolicy.BackgroundStamp(date: backgrounded.addingTimeInterval(wallOffset), instant: base + continuousOffset)
    }

    /// The continuous clock measures the grace; a wall clock set back can't shorten it.
    func testGraceIsMeasuredOnTheContinuousClock() {
        let base = ContinuousClock.now
        let start = stamp(0, .zero, base: base)
        XCTAssertFalse(MobileLockPolicy.shouldLock(since: start, now: stamp(299, .seconds(299), base: base)))
        XCTAssertTrue(MobileLockPolicy.shouldLock(since: start, now: stamp(300, .seconds(300), base: base)))
        // Ten minutes away, but the wall clock was corrected back by eight: still locks.
        XCTAssertTrue(MobileLockPolicy.shouldLock(since: start, now: stamp(120, .seconds(600), base: base)))
        XCTAssertFalse(MobileLockPolicy.shouldLock(since: nil, now: stamp(600, .seconds(600), base: base)))
    }

    /// A wall clock that went backwards still locks (guard kept from the first version).
    func testClockMovedBackStillLocksWithTheContinuousClock() {
        let base = ContinuousClock.now
        XCTAssertTrue(MobileLockPolicy.shouldLock(since: stamp(0, .zero, base: base), now: stamp(-1, .seconds(5), base: base)))
    }

    /// An unlock that lands while the scene is in the background is timed from then, so it can't stay
    /// unlocked indefinitely; the background is stamped while unlocking as well as while unlocked.
    func testUnlockLandingInBackgroundIsTimed() {
        XCTAssertTrue(MobileLockPolicy.stampsBackground(.unlocked))
        XCTAssertTrue(MobileLockPolicy.stampsBackground(.unlocking))
        XCTAssertFalse(MobileLockPolicy.stampsBackground(.locked))

        let base = ContinuousClock.now
        let now = stamp(10, .seconds(10), base: base)
        let earlier = stamp(0, .zero, base: base)
        XCTAssertEqual(MobileLockPolicy.stampAfterUnlock(sceneIsActive: false, existing: nil, now: now), now)
        XCTAssertEqual(MobileLockPolicy.stampAfterUnlock(sceneIsActive: false, existing: earlier, now: now), earlier)
        XCTAssertNil(MobileLockPolicy.stampAfterUnlock(sceneIsActive: true, existing: nil, now: now))
        // Back in front: the stamp taken while unlocking still decides.
        XCTAssertEqual(MobileLockPolicy.stampAfterUnlock(sceneIsActive: true, existing: earlier, now: now), earlier)
    }
}
