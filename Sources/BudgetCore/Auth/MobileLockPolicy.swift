import Foundation

/// The iPhone and iPad lock (auth spec §10; plan step 4 Global Constraints "Lock"). The phone unlocks with
/// `LAContext.deviceOwnerAuthentication` (Face ID or Touch ID, the device passcode as fallback) and locks on
/// launch, after `backgroundGrace` in the background, and on demand. The decisions live here, the `LAContext`
/// calls in the app; no secret is stored anywhere.
public enum MobileLockPolicy {
    /// Five minutes in the background locks the app.
    public static let backgroundGrace: TimeInterval = 300

    public enum BiometryKind: Sendable {
        case faceID
        case touchID
    }

    /// What this device can unlock with right now.
    public enum Availability: Equatable, Sendable {
        case biometrics(BiometryKind)
        case passcodeOnly
        /// `canEvaluatePolicy(.deviceOwnerAuthentication)` failed with `passcodeNotSet`: nothing can unlock,
        /// so the app stays locked and explains why.
        case noPasscode
        /// Any other failure (for example a passcode lockout): stays locked, offers to try again.
        case unavailable
    }

    /// The outcome of `canEvaluatePolicy(.deviceOwnerAuthentication)`, without LocalAuthentication types.
    public enum DeviceOwnerCheck: Equatable, Sendable {
        case available
        case failed(Failure)

        public enum Failure: Equatable, Sendable {
            case passcodeNotSet
            case other
        }
    }

    /// `biometry`: the enrolled biometry the context reports (`nil` when none is enrolled or usable).
    public static func availability(deviceOwner: DeviceOwnerCheck, biometry: BiometryKind?) -> Availability {
        switch deviceOwner {
        case .failed(.passcodeNotSet): return .noPasscode
        case .failed(.other): return .unavailable
        case .available:
            if let biometry { return .biometrics(biometry) }
            return .passcodeOnly
        }
    }

    /// Whether the lock screen's primary button asks the system to authenticate. With no passcode it opens
    /// Settings instead, and the content stays hidden.
    public static func canAttemptUnlock(_ availability: Availability) -> Bool {
        availability != .noPasscode
    }

    /// Whether coming back to the foreground locks. `backgroundedAt` nil: the app never went to the background
    /// (or is already locked), so nothing changes. A clock that moved backwards can't prove the app was away for
    /// less than the grace, so it locks.
    public static func shouldLock(backgroundedAt: Date?, now: Date) -> Bool {
        guard let backgroundedAt else { return false }
        let away = now.timeIntervalSince(backgroundedAt)
        return away < 0 || away >= backgroundGrace
    }

    public static func lockScreenCopy(_ availability: Availability)
        -> (title: String, body: String, primary: String?, secondary: String?) {
        let title = "Mango is locked"
        let body = "Your household's figures are hidden until you unlock."
        switch availability {
        case .biometrics(.faceID):
            return (title, body, "Unlock with Face ID", "Use passcode")
        case .biometrics(.touchID):
            return (title, body, "Unlock with Touch ID", "Use passcode")
        case .passcodeOnly:
            return (title, body, "Unlock with passcode", nil)
        case .noPasscode:
            return ("Mango needs a device passcode",
                    "Set a passcode in Settings to protect the household's figures.", "Open Settings", nil)
        case .unavailable:
            return (title, "Face ID and the passcode can't be used right now. Try again in a moment.", "Try again", nil)
        }
    }
}
