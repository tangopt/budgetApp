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
        case failed(String)
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
    private var throttle = SignInThrottle()
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
        if SnapshotMode.isActive, let snapshotUser {
            state = .signedIn(snapshotUser)
            return
        }
        state = isSetUp ? .locked : .notSetUp
        observeSystemLocks()
    }

    // MARK: Signing in

    func signIn(appUserId: Int64, password: String) async -> SignInResult {
        await attempt(appUserId: appUserId) { db in
            try AppUserStore.verifyPassword(db, appUserId: appUserId, password: password)
        }
    }

    /// "Forgot password?": the recovery key signs the user in so they can set a new password (auth spec §7).
    func signIn(appUserId: Int64, recoveryKey: String) async -> SignInResult {
        await attempt(appUserId: appUserId) { db in
            try AppUserStore.verifyRecoveryKey(db, appUserId: appUserId, key: recoveryKey)
        }
    }

    @discardableResult
    func signInWithBiometrics(appUserId: Int64) async -> BiometricSignInResult {
        guard !SnapshotMode.isActive else { return .cancelled }
        do {
            guard try await biometrics.unlock(appUserId: appUserId, reason: "unlock Mango") else { return .cancelled }
            try await begin(appUserId: appUserId)
            return .signedIn
        } catch BiometricUnlockError.notEnrolled {
            return .notEnrolled
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// After setup (or adding a user), the new user is signed in without asking again.
    func signInAfterSetUp(appUserId: Int64) async throws {
        try await begin(appUserId: appUserId)
    }

    // MARK: Locking

    /// Mango ▸ Lock, the sidebar lock button, idle, screen lock and sleep. Switch User… locks too.
    func lock() {
        guard case .signedIn = state, !SnapshotMode.isActive else { return }
        idleMonitor.stop()
        state = .locked
    }

    // MARK: Private

    /// Password and recovery-key checks share the throttle. PBKDF2 runs off the main thread (the
    /// database queue's), and a successful check may upgrade the hash, hence a write.
    private func attempt(appUserId: Int64, _ verify: @escaping @Sendable (Database) throws -> Bool) async -> SignInResult {
        let wait = throttle.delay(now: Date())
        guard wait <= 0 else { return .throttled(wait) }
        do {
            guard try await dbQueue.write(verify) else {
                throttle.recordFailure(now: Date())
                let wait = throttle.delay(now: Date())
                return wait > 0 ? .throttled(wait) : .wrongPassword
            }
            throttle.reset()
            try await begin(appUserId: appUserId)
            return .signedIn
        } catch {
            return .failed(error.localizedDescription)
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
        for name in [NSWorkspace.screensDidSleepNotification, NSWorkspace.willSleepNotification] {
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
