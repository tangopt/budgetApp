// App/Auth/SessionModel.swift
import AppKit
import BudgetCore
import GRDB

/// How long Mango waits without input before locking (Settings ▸ Sign-in). Stored in `auth.lockTimeout`
/// as minutes, 0 meaning Never.
enum LockTimeout: Hashable, Sendable {
    case minutes(Int)
    case never

    static let defaultsKey = "auth.lockTimeout"
    static let standard = LockTimeout.minutes(15)
    static let choices: [LockTimeout] = [.minutes(5), .minutes(15), .minutes(30), .minutes(60), .never]

    var seconds: TimeInterval? {
        switch self {
        case .minutes(let minutes): TimeInterval(minutes * 60)
        case .never: nil
        }
    }

    fileprivate var storedValue: Int {
        switch self {
        case .minutes(let minutes): minutes
        case .never: 0
        }
    }

    /// Anything not offered falls back to the default.
    fileprivate init(storedValue: Int?) {
        switch storedValue {
        case 0: self = .never
        case let minutes? where Self.choices.contains(.minutes(minutes)): self = .minutes(minutes)
        default: self = Self.standard
        }
    }
}

/// The signed-in app user of the running app, shared by every window including Settings (auth spec §3,
/// §9). It locks after inactivity, on screen lock and on sleep; locking keeps every window's state.
@MainActor
final class SessionModel: ObservableObject {
    enum State: Equatable {
        case notSetUp
        case locked
        case signedIn(AppUser)
    }

    enum SignInResult: Equatable {
        case signedIn
        case wrongPassword
        /// Too many wrong attempts: try again after this many seconds.
        case throttled(TimeInterval)
        /// Another attempt is still being checked.
        case busy
        case failed(String)
    }

    enum SessionError: Error {
        /// `signInAfterSetUp` outside first-launch setup: adding a user never signs you in as them.
        case alreadySetUp
    }

    enum BiometricSignInResult: Equatable {
        case signedIn
        /// Cancelled or not recognised: the lock screen stays, "Use password" is there.
        case cancelled
        /// Not enrolled on this Mac, or dropped because the fingerprints changed: ask for the password, then
        /// offer Touch ID again.
        case notEnrolled
        case failed(String)
    }

    @Published private(set) var state: State
    /// Bumped when Settings changes the timeout so views reading `lockTimeout` refresh.
    @Published private(set) var lockTimeoutRevision = 0

    let dbQueue: DatabaseQueue
    let biometrics: any BiometricUnlocker
    private let defaults: UserDefaults
    /// Password and recovery-key attempts share it: one throttle, one check at a time.
    private let gate: SignInGate
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private lazy var idleMonitor = IdleMonitor { [weak self] in self?.lock() }

    /// The user Confirm import and rule learning record (nil while locked or not set up).
    var currentAppUserId: Int64? {
        if case .signedIn(let user) = state { return user.id }
        return nil
    }

    var currentUser: AppUser? {
        if case .signedIn(let user) = state { return user }
        return nil
    }

    var lockTimeout: LockTimeout {
        get { LockTimeout(storedValue: defaults.object(forKey: LockTimeout.defaultsKey) as? Int) }
        set {
            defaults.set(newValue.storedValue, forKey: LockTimeout.defaultsKey)
            lockTimeoutRevision += 1
            if currentUser != nil { idleMonitor.start(timeout: newValue.seconds) }
        }
    }

    /// `isSetUp` is read by `AppEnvironment.load()` off the main thread. In the snapshot build the session
    /// starts signed in as `snapshotUser` and never locks (the only bypass, auth spec §8).
    init(dbQueue: DatabaseQueue, isSetUp: Bool, biometrics: any BiometricUnlocker,
         defaults: UserDefaults = .standard, snapshotUser: AppUser? = nil) {
        self.dbQueue = dbQueue
        self.biometrics = biometrics
        self.defaults = defaults
        self.gate = SignInGate(dbQueue: dbQueue)
        if SnapshotMode.isActive, let snapshotUser {
            state = .signedIn(snapshotUser)
            return
        }
        state = isSetUp ? .locked : .notSetUp
        observeSystemLocks()
    }

    // MARK: Signing in

    func signIn(appUserId: Int64, password: String) async -> SignInResult {
        await finish(appUserId: appUserId, await gate.password(appUserId: appUserId, password: password, now: Date()))
    }

    /// "Forgot password?": the recovery key signs the user in so they can set a new password (auth spec §7).
    func signIn(appUserId: Int64, recoveryKey: String) async -> SignInResult {
        await finish(appUserId: appUserId, await gate.recoveryKey(appUserId: appUserId, key: recoveryKey, now: Date()))
    }

    @discardableResult
    func signInWithBiometrics(appUserId: Int64) async -> BiometricSignInResult {
        guard !SnapshotMode.isActive else { return .cancelled }
        do {
            // Only someone who can sign in on this Mac with a password too.
            let candidates = try await dbQueue.read { try AppUserStore.signInCandidates($0) }
            guard candidates.contains(where: { $0.id == appUserId }) else {
                biometrics.remove(appUserId: appUserId)
                return .notEnrolled
            }
            guard try await biometrics.unlock(appUserId: appUserId, reason: "unlock Mango") else { return .cancelled }
            try await begin(appUserId: appUserId)
            return .signedIn
        } catch BiometricUnlockError.notEnrolled {
            return .notEnrolled
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// After first-launch setup only, the new admin is signed in without asking again. Adding another user
    /// later never signs you in as them.
    func signInAfterSetUp(appUserId: Int64) async throws {
        guard state == .notSetUp else { throw SessionError.alreadySetUp }
        try await begin(appUserId: appUserId)
    }

    /// Settings ▸ Sign-in's remove-user path (and turning Touch ID off): drops this Mac's enrolment.
    func removeBiometricEnrolment(appUserId: Int64) {
        biometrics.remove(appUserId: appUserId)
    }

    // MARK: Locking

    /// Mango ▸ Lock, the sidebar lock button, idle, screen lock and sleep. Switch User… locks too.
    func lock() {
        guard case .signedIn = state, !SnapshotMode.isActive else { return }
        idleMonitor.stop()
        state = .locked
    }

    // MARK: Private

    private func finish(appUserId: Int64, _ outcome: SignInGate.Outcome) async -> SignInResult {
        switch outcome {
        case .rejected: return .wrongPassword
        case .throttled(let wait): return .throttled(wait)
        case .busy: return .busy
        case .accepted:
            do {
                try await begin(appUserId: appUserId)
                return .signedIn
            } catch {
                return .failed(error.localizedDescription)
            }
        }
    }

    private func begin(appUserId: Int64) async throws {
        let user = try await dbQueue.write { db -> AppUser? in
            try AppUserStore.recordSignIn(db, appUserId: appUserId, now: Date())
            return try AppUser.fetchOne(db, key: appUserId)
        }
        guard let user else { throw AppUserStoreError.noSuchUser }
        state = .signedIn(user)
        idleMonitor.start(timeout: lockTimeout.seconds)
    }

    private func observeSystemLocks() {
        let workspace = NSWorkspace.shared.notificationCenter
        // Fast user switching counts as leaving the Mac.
        for name in [NSWorkspace.screensDidSleepNotification, NSWorkspace.willSleepNotification,
                     NSWorkspace.sessionDidResignActiveNotification] {
            observe(workspace, name)
        }
        observe(DistributedNotificationCenter.default(), Notification.Name("com.apple.screenIsLocked"))
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.lock() }
        }
        observers.append((center, token))
    }
}
