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

        let unavailable = MobileLockPolicy.lockScreenCopy(.unavailable)
        XCTAssertEqual(unavailable.title, "Mango is locked")
        XCTAssertEqual(unavailable.primary, "Try again")
        XCTAssertNil(unavailable.secondary)
    }

    func testAvailabilityFromTheDevice() {
        XCTAssertEqual(MobileLockPolicy.availability(deviceOwner: .available, biometry: .faceID), .biometrics(.faceID))
        XCTAssertEqual(MobileLockPolicy.availability(deviceOwner: .available, biometry: .touchID), .biometrics(.touchID))
        XCTAssertEqual(MobileLockPolicy.availability(deviceOwner: .available, biometry: nil), .passcodeOnly)
        XCTAssertEqual(MobileLockPolicy.availability(deviceOwner: .failed(.other), biometry: .faceID), .unavailable)
        XCTAssertTrue(MobileLockPolicy.canAttemptUnlock(.biometrics(.faceID)))
        XCTAssertTrue(MobileLockPolicy.canAttemptUnlock(.passcodeOnly))
        XCTAssertTrue(MobileLockPolicy.canAttemptUnlock(.unavailable))
    }
}
