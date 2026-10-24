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
    /// When the scene went to the background while unlocked or unlocking (continuous and wall clock); nil otherwise.
    private var backgroundStamp: MobileLockPolicy.BackgroundStamp?
    /// Whether the scene is in front (`scenePhase == .active`), fed by `LockCover`.
    private var sceneIsActive = true
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
        case "unavailable": return .unavailable(.faceID)
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
        let usable = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &biometryError)
        // biometryType is set by the canEvaluatePolicy calls above, whether they passed or not.
        let hardware: MobileLockPolicy.BiometryKind? = switch context.biometryType {
        case .faceID: .faceID
        case .touchID: .touchID
        default: nil
        }
        // Available: only usable biometry is offered. Failed: the hardware names the `.unavailable` wording.
        let biometry = check == .available ? (usable ? hardware : nil) : hardware
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
        if case .unavailable = availability {
            state = .locked(availability)
            return
        }
        guard MobileLockPolicy.canAttemptUnlock(availability) else {
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
        backgroundStamp = nil
        autoPromptPending = true
        availability = Self.currentAvailability()
        state = .locked(availability)
    }

    /// `now` is taken on both clocks (`MobileLockPolicy.BackgroundStamp.now()`). Stamped while unlocking too: an
    /// unlock that succeeds in the background is then timed from here.
    func sceneDidEnterBackground(now: MobileLockPolicy.BackgroundStamp) {
        if MobileLockPolicy.stampsBackground(phase), backgroundStamp == nil { backgroundStamp = now }
    }

    func sceneActivityChanged(isActive: Bool) {
        sceneIsActive = isActive
    }

    func sceneWillEnterForeground(now: MobileLockPolicy.BackgroundStamp) {
        if case .locked = state {
            // A passcode may have been set (or removed) in Settings meanwhile.
            availability = Self.currentAvailability()
            state = .locked(availability)
            return
        }
        if MobileLockPolicy.shouldLock(since: backgroundStamp, now: now) {
            lock()
        }
        // Still unlocking (the prompt is up): keep the stamp so a success is timed from the background.
        if state != .unlocking { backgroundStamp = nil }
    }

    private var phase: MobileLockPolicy.LockPhase {
        switch state {
        case .locked: .locked
        case .unlocking: .unlocking
        case .unlocked: .unlocked
        }
    }

    /// A success that lands while the scene is away keeps (or starts) the background stamp, so the grace still
    /// applies; in front with no stamp, nothing is timed.
    private func finishUnlock() {
        backgroundStamp = MobileLockPolicy.stampAfterUnlock(sceneIsActive: sceneIsActive, existing: backgroundStamp,
                                                            now: .now())
        state = .unlocked
        if sceneIsActive, let stamp = backgroundStamp {
            // Already back in front: decide now rather than waiting for the next background.
            if MobileLockPolicy.shouldLock(since: stamp, now: .now()) { lock() } else { backgroundStamp = nil }
        }
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
