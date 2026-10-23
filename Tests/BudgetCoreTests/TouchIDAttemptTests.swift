import XCTest
import LocalAuthentication
@testable import BudgetCore

final class TouchIDAttemptTests: XCTestCase {
    private func end(_ code: LAError.Code) -> TouchIDAttemptEnd { TouchIDAttemptEnd.classify(laErrorCode: code.rawValue) }

    func testCancelsAreSilent() {
        // "Use password" invalidates the context (appCancel); the system may interrupt (systemCancel).
        for code in [LAError.Code.userCancel, .appCancel, .systemCancel, .userFallback, .notInteractive] {
            XCTAssertEqual(end(code), .cancelled, "\(code)")
            XCTAssertNil(end(code).unlockError)
        }
    }

    func testMissedFingerIsNotRecognised() {
        XCTAssertEqual(end(.authenticationFailed), .notRecognised)
        XCTAssertEqual(end(.authenticationFailed).unlockError, .notRecognised)
    }

    func testLockoutSendsToThePassword() {
        XCTAssertEqual(end(.biometryLockout), .lockedOut)
        XCTAssertEqual(end(.biometryLockout).unlockError, .lockedOut)
    }

    func testNoTouchIDIsUnavailable() {
        for code in [LAError.Code.biometryNotAvailable, .biometryNotEnrolled, .passcodeNotSet, .biometryDisconnected, .biometryNotPaired] {
            XCTAssertEqual(end(code), .unavailable, "\(code)")
            XCTAssertEqual(end(code).unlockError, .unavailable)
        }
    }

    func testAnythingElseKeepsTheSystemsError() {
        XCTAssertEqual(end(.invalidContext), .other)
        XCTAssertEqual(TouchIDAttemptEnd.classify(laErrorCode: 12345), .other)
        XCTAssertNil(TouchIDAttemptEnd.other.unlockError)
    }

    func testInlineWordsAreSentences() {
        for text in [TouchIDInlineText.notRecognised, TouchIDInlineText.lockedOut] {
            XCTAssertEqual(AuthText.sentence(text), text)
        }
        XCTAssertEqual(BiometricUnlockError.notRecognised.errorDescription, "Touch ID didn't recognise that finger.")
        XCTAssertEqual(BiometricUnlockError.lockedOut.errorDescription, "Touch ID is locked after too many tries.")
    }
}
