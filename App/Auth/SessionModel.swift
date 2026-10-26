// App/Auth/SessionModel.swift
import AppKit
import BudgetCore
import GRDB
import OSLog

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

        /// Who is signed in; nil while locked or before sign-in is set up.
        var signedInId: Int64? {
            if case .signedIn(let user) = self { return user.id }
            return nil
        }
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
        /// Cancelled: the lock screen stays, "Use password" is there.
        case cancelled
        /// The finger wasn't recognised: the lock screen says so and offers another try.
        case notRecognised
        /// Too many misses: Touch ID is off until the Mac's own password; ask for Mango's password.
        case lockedOut
        /// Not enrolled on this Mac, or dropped because the fingerprints changed: ask for the password, then
        /// offer Touch ID again.
        case notEnrolled
        case failed(String)
    }

    @Published private(set) var state: State {
        didSet {
            publishWriter()
            if state == .locked && oldValue != .locked { autoPrompt.lockBegan() }
        }
    }
    /// Touch ID by itself on the lock screen, once per lock; shared by every window's lock screen.
    private(set) var autoPrompt = TouchIDAutoPrompt()
    /// Bumped when Settings changes the timeout so views reading `lockTimeout` refresh.
    @Published private(set) var lockTimeoutRevision = 0
    /// Who can sign in on this Mac (the lock screen's avatars). More than one means a shared macOS user,
    /// and Mango ▸ Switch User… shows. Re-read by `refreshCandidates()` after setup and Settings changes.
    @Published private(set) var signInCandidates: [AppUser] = []
    /// A step every window shows before the content after signing in: a new password after the recovery key
    /// (required), or the offer to turn Touch ID on here. While it is set the windows stay covered.
    @Published private(set) var afterSignIn: AfterSignIn?

    enum AfterSignIn: Equatable {
        case newPassword
        case offerTouchID
    }

    /// Someone is signed in and nothing covers the windows: menus, drops and panels may act on the data.
    var canActOnData: Bool { currentUser != nil && !isCovered }

    /// The app's session (`AppEnvironment.Current`), for code with no session of its own (an open panel that
    /// has just returned): false when there is none.
    static var appCanActOnData: Bool { AppEnvironment.Current.shared.environment?.session.canActOnData ?? false }

    /// The windows, sheets and popovers stay covered: locked, or signed in with a step still to do.
    var isCovered: Bool {
        switch state {
        case .locked: true
        case .notSetUp: false
        case .signedIn: afterSignIn != nil
        }
    }

    let dbQueue: DatabaseQueue
    let biometrics: any BiometricUnlocker
    private let defaults: UserDefaults
    /// Password and recovery-key attempts share it: one throttle, one check at a time.
    private let gate: SignInGate
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private lazy var idleMonitor = IdleMonitor { [weak self] in self?.lock() }

    /// The last person signed in, kept through a lock: what the lock covered was theirs (`SheetCovers`).
    private(set) var lastSignedInId: Int64?

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
            publishWriter()
            return
        }
        state = isSetUp ? .locked : .notSetUp
        publishWriter()
        observeSystemLocks()
        SheetCovers.shared.trackTransients()
        Task { await refreshCandidates() }
    }

    /// Re-reads `signInCandidates` off the main thread.
    func refreshCandidates() async {
        guard let candidates = try? await dbQueue.read({ try AppUserStore.signInCandidates($0) }) else { return }
        if candidates != signInCandidates { signInCandidates = candidates }
        // The signed-in user's name or admin flag may have changed.
        if case .signedIn(let user) = state, let fresh = candidates.first(where: { $0.id == user.id }), fresh != user {
            state = .signedIn(fresh)
        }
    }

    // MARK: Signing in

    /// `offerTouchID`: they aren't enrolled on a Mac with Touch ID, so the windows ask once before showing.
    func signIn(appUserId: Int64, password: String, offerTouchID: Bool = false) async -> SignInResult {
        await finish(appUserId: appUserId, await gate.password(appUserId: appUserId, password: password, now: Date()),
                     then: offerTouchID ? .offerTouchID : nil)
    }

    /// "Forgot password?": the recovery key signs the user in so they can set a new password (auth spec §7).
    /// Every window then asks for a new password before showing anything.
    func signIn(appUserId: Int64, recoveryKey: String) async -> SignInResult {
        await finish(appUserId: appUserId, await gate.recoveryKey(appUserId: appUserId, key: recoveryKey, now: Date()),
                     then: .newPassword)
    }

    /// The required step after the recovery key. PBKDF2 runs on the database queue, off the main thread.
    func chooseNewPassword(_ password: String, thenOfferTouchID: Bool) async throws {
        guard case .signedIn(let user) = state, let id = user.id else { throw AppUserStoreError.noSuchUser }
        try await dbQueue.write { try AppUserStore.changePassword($0, appUserId: id, newPassword: password) }
        afterSignIn = thenOfferTouchID ? .offerTouchID : nil
    }

    /// Who the app's writes are made as (`SignedInActor`), and the database's default writer for what BudgetCore
    /// writes on its own (`ActorWrite.useDefaultWriter`): the signed-in user, else the admin.
    private func publishWriter() {
        let id: Int64?
        switch state {
        case .signedIn(let user):
            id = user.id
            SignedInActor.state = user.id.map { .signedIn(appUserId: $0) } ?? .notSetUp
        case .locked:
            id = nil
            SignedInActor.state = .signedOut
        case .notSetUp:
            id = nil
            SignedInActor.state = .notSetUp
        }
        do {
            try dbQueue.write { db in try ActorWrite.useDefaultWriter(appUserId: id, db: db) }
        } catch {
            Logger(subsystem: "com.personal.budget", category: "Auth").error("Setting the default writer failed: \(String(describing: type(of: error)), privacy: .public)")
        }
    }

    /// The signed-in user's own new password (sign-in bookkeeping: their credentials aren't synced data).
    func changeOwnPassword(_ password: String) async throws {
        guard let id = currentAppUserId else { throw AppUserStoreError.noSuchUser }
        try await dbQueue.write { try AppUserStore.changePassword($0, appUserId: id, newPassword: password) }
    }

    /// A new recovery key for the signed-in user (sign-in bookkeeping).
    func regenerateOwnRecoveryKey() async throws -> String {
        guard let id = currentAppUserId else { throw AppUserStoreError.noSuchUser }
        return try await dbQueue.write { try AppUserStore.regenerateRecoveryKey($0, appUserId: id) }
    }

    /// The Touch ID offer answered (turned on or not now).
    func finishOffer() {
        if afterSignIn == .offerTouchID { afterSignIn = nil }
    }

    /// A lock screen asks to start Touch ID by itself: true for the one window that should (the others, and
    /// later asks in the same lock, get false). `end` it with `autoPromptEnded`.
    func claimAutoPrompt(otherStepInProgress: Bool) -> Bool {
        guard !SnapshotMode.isActive, afterSignIn == nil,
              autoPrompt.shouldPrompt(isLocked: state == .locked, appIsActive: NSApp.isActive,
                                      otherStepInProgress: otherStepInProgress) else { return false }
        autoPrompt.promptStarted()
        return true
    }

    func autoPromptEnded(decided: Bool) { autoPrompt.promptEnded(decided: decided) }

    /// Touch ID asks in `prompt`, the lock screen's own view, never in a system panel.
    @discardableResult
    func signInWithBiometrics(appUserId: Int64, prompt: InlineTouchIDPrompt) async -> BiometricSignInResult {
        guard !SnapshotMode.isActive else { return .cancelled }
        do {
            // Only someone who can sign in on this Mac with a password too.
            let candidates = try await dbQueue.read { try AppUserStore.signInCandidates($0) }
            guard candidates.contains(where: { $0.id == appUserId }) else {
                biometrics.remove(appUserId: appUserId)
                return .notEnrolled
            }
            guard try await biometrics.unlock(appUserId: appUserId, reason: "unlock Mango", prompt: prompt) else { return .cancelled }
            try await begin(appUserId: appUserId)
            return .signedIn
        } catch BiometricUnlockError.notEnrolled {
            return .notEnrolled
        } catch BiometricUnlockError.notRecognised {
            return .notRecognised
        } catch BiometricUnlockError.lockedOut {
            return .lockedOut
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
        // Straight away, not on the windows' next update: an open or save panel running modally has to go now.
        SheetCovers.shared.update(covered: true, session: self)
    }

    #if SNAPSHOTS
    /// Snapshot routes only: signs in as `user` without a password (the demo's synthetic users).
    func snapshotSignIn(_ user: AppUser) {
        lastSignedInId = user.id
        state = .signedIn(user)
    }

    /// Snapshot routes only: a session of the route's own shown locked.
    func snapshotLock() {
        state = .locked
    }
    #endif

    // MARK: Private

    private func finish(appUserId: Int64, _ outcome: SignInGate.Outcome, then step: AfterSignIn? = nil) async -> SignInResult {
        switch outcome {
        case .rejected: return .wrongPassword
        case .throttled(let wait): return .throttled(wait)
        case .busy: return .busy
        case .accepted:
            do {
                try await begin(appUserId: appUserId, then: step)
                return .signedIn
            } catch {
                return .failed(error.localizedDescription)
            }
        }
    }

    private func begin(appUserId: Int64, then step: AfterSignIn? = nil) async throws {
        let user = try await dbQueue.write { db -> AppUser? in
            try AppUserStore.recordSignIn(db, appUserId: appUserId, now: Date())
            return try AppUser.fetchOne(db, key: appUserId)
        }
        guard let user else { throw AppUserStoreError.noSuchUser }
        // Set before the state changes, so no window shows its content in between.
        afterSignIn = step
        lastSignedInId = user.id
        state = .signedIn(user)
        idleMonitor.start(timeout: lockTimeout.seconds)
        await refreshCandidates()
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
