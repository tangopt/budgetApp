import Foundation
import LocalAuthentication
import BudgetCore
import OSLog

/// The phone's lock (auth spec §10): locked on launch, after `MobileLockPolicy.backgroundGrace` in the background,
/// and on demand. Unlocking is `LAContext` only: Face ID or Touch ID first when the primary button is tapped, the
/// device passcode as fallback. Nothing is stored: no secret, no Keychain item, no flag that survives a relaunch.
@MainActor
final class PhoneLockModel: ObservableObject {
    enum State: Equatable {
        case locked(MobileLockPolicy.Availability)
        case unlocking
        case unlocked
    }

    @Published private(set) var state: State
    /// What the device could unlock with when last checked (the lock screen keeps showing it while unlocking).
    private(set) var availability: MobileLockPolicy.Availability
    /// When the scene went to the background while unlocked; nil otherwise.
    private var backgroundedAt: Date?
    /// The lock screen offers Face ID by itself once per lock, never again after a cancel.
    private var autoPromptPending = true

    private static let log = Logger(subsystem: "ubberninja.mango.ios", category: "Lock")

    init() {
        let availability = Self.currentAvailability()
        self.availability = availability
        self.state = Self.startsUnlocked ? .unlocked : .locked(availability)
    }

    /// Snapshot builds skip the lock (plan step 4 Global Constraints), and so does `MANGO_UNLOCKED=1` in simulator
    /// DEBUG builds (the attended checks). Every other build starts locked.
    private static var startsUnlocked: Bool {
        #if SNAPSHOTS
        return true
        #elseif DEBUG && targetEnvironment(simulator)
        return ProcessInfo.processInfo.environment["MANGO_UNLOCKED"] == "1"
        #else
        return false
        #endif
    }

    /// Asks `LAContext` what can unlock this device now. Status codes are logged, nothing else.
    static func currentAvailability() -> MobileLockPolicy.Availability {
        #if DEBUG && targetEnvironment(simulator)
        // The simulator always reports a usable passcode, so the attended checks pick the state to render.
        switch ProcessInfo.processInfo.environment["MANGO_LOCK_AVAILABILITY"] {
        case "noPasscode": return .noPasscode
        case "unavailable": return .unavailable
        case "faceID": return .biometrics(.faceID)
        case "touchID": return .biometrics(.touchID)
        case "passcode": return .passcodeOnly
        default: break
        }
        #endif
        let context = LAContext()
        var error: NSError?
        let check: MobileLockPolicy.DeviceOwnerCheck
        if context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) {
            check = .available
        } else if let error, error.domain == LAErrorDomain, error.code == LAError.passcodeNotSet.rawValue {
            check = .failed(.passcodeNotSet)
        } else {
            log.error("Device owner authentication unavailable, code \(error?.code ?? 0, privacy: .public)")
            check = .failed(.other)
        }
        var biometryError: NSError?
        var biometry: MobileLockPolicy.BiometryKind?
        if context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &biometryError) {
            switch context.biometryType {
            case .faceID: biometry = .faceID
            case .touchID: biometry = .touchID
            default: biometry = nil
            }
        }
        return MobileLockPolicy.availability(deviceOwner: check, biometry: biometry)
    }

    /// Whether the lock screen should offer biometrics by itself (once per lock, only while the app is active).
    func takeAutoPrompt() -> Bool {
        guard autoPromptPending, case .locked(.biometrics) = state else { return false }
        autoPromptPending = false
        return true
    }

    /// `allowPasscodeOnly` false (the primary button): biometrics first, then the passcode if the person asks for
    /// it or biometrics are locked out. True ("Use passcode", or no biometrics): `deviceOwnerAuthentication`.
    func unlock(allowPasscodeOnly: Bool) async {
        guard case .locked = state else { return }
        availability = Self.currentAvailability()
        guard MobileLockPolicy.canAttemptUnlock(availability), availability != .unavailable else {
            state = .locked(availability)
            return
        }
        state = .unlocking
        let reason = "Unlock Mango to see the household's figures."
        var useDeviceOwner = allowPasscodeOnly
        if !allowPasscodeOnly, case .biometrics = availability {
            let context = LAContext()
            context.localizedFallbackTitle = "Use Passcode"
            switch await Self.evaluate(context, .deviceOwnerAuthenticationWithBiometrics, reason: reason) {
            case .success:
                finishUnlock()
                return
            case .failure(let code):
                // Fallback chosen, or biometrics locked out or not usable: the passcode decides.
                let toPasscode: Set<LAError.Code> = [.userFallback, .biometryLockout, .biometryNotAvailable,
                                                     .biometryNotEnrolled]
                guard let code, toPasscode.contains(code) else {
                    relock()
                    return
                }
                useDeviceOwner = true
            }
        }
        if useDeviceOwner || availability == .passcodeOnly {
            switch await Self.evaluate(LAContext(), .deviceOwnerAuthentication, reason: reason) {
            case .success: finishUnlock()
            case .failure: relock()
            }
        }
    }

    func lock() {
        backgroundedAt = nil
        autoPromptPending = true
        availability = Self.currentAvailability()
        state = .locked(availability)
    }

    func sceneDidEnterBackground(now: Date) {
        if state == .unlocked { backgroundedAt = now }
    }

    func sceneWillEnterForeground(now: Date) {
        if case .locked = state {
            // A passcode may have been set (or removed) in Settings meanwhile.
            availability = Self.currentAvailability()
            state = .locked(availability)
            return
        }
        if MobileLockPolicy.shouldLock(backgroundedAt: backgroundedAt, now: now) {
            lock()
        }
        backgroundedAt = nil
    }

    private func finishUnlock() {
        backgroundedAt = nil
        state = .unlocked
    }

    private func relock() {
        availability = Self.currentAvailability()
        state = .locked(availability)
    }

    private enum Outcome {
        case success
        case failure(LAError.Code?)
    }

    /// One evaluation on its own context. Only the error code is kept (and logged).
    private static func evaluate(_ context: LAContext, _ policy: LAPolicy, reason: String) async -> Outcome {
        do {
            return try await context.evaluatePolicy(policy, localizedReason: reason) ? .success : .failure(nil)
        } catch let error as LAError {
            log.info("Unlock not completed, code \(error.code.rawValue, privacy: .public)")
            return .failure(error.code)
        } catch {
            return .failure(nil)
        }
    }
}
