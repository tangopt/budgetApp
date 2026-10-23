import Foundation
import LocalAuthentication

/// How a Touch ID try in Mango's own window ended, from the `LAError` it threw (the inline prompt has no
/// buttons of its own: "Use password" cancels it, and the words come from Mango).
public enum TouchIDAttemptEnd: Equatable, Sendable {
    /// "Use password", another person picked, the lock screen gone, or the system interrupted it: no message.
    case cancelled
    /// Too many misses in this try: Mango says so and offers another try.
    case notRecognised
    /// Too many misses overall: Touch ID is off until the Mac's own password is entered.
    case lockedOut
    /// No Touch ID now (no sensor, no fingerprints, the keyboard disconnected).
    case unavailable
    /// Anything else: shown with the system's wording.
    case other

    public static func classify(laErrorCode code: Int) -> TouchIDAttemptEnd {
        switch LAError.Code(rawValue: code) {
        case .userCancel, .appCancel, .systemCancel, .userFallback, .notInteractive: .cancelled
        case .authenticationFailed: .notRecognised
        case .biometryLockout: .lockedOut
        case .biometryNotAvailable, .biometryNotEnrolled, .passcodeNotSet: .unavailable
        #if os(macOS)
        case .biometryNotPaired, .biometryDisconnected: .unavailable
        #endif
        default: .other
        }
    }

    /// The unlocker's answer: false for a cancel, a `BiometricUnlockError` for a refusal, nil for `.other`
    /// (the caller rethrows the system's own error).
    public var unlockError: BiometricUnlockError? {
        switch self {
        case .cancelled: nil
        case .notRecognised: .notRecognised
        case .lockedOut: .lockedOut
        case .unavailable: .unavailable
        case .other: nil
        }
    }
}

/// The lock screen's own words around the inline Touch ID prompt.
public enum TouchIDInlineText {
    /// Under the Touch ID glyph while it listens.
    public static let listening = "Touch ID to unlock"
    public static let notRecognised = "Touch ID didn't recognise that finger. Try again, or use your password."
    public static let lockedOut = "Touch ID is locked after too many tries. Enter your password."
}
