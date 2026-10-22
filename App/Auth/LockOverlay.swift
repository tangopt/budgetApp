// App/Auth/LockOverlay.swift
import SwiftUI
import AppKit
import BudgetCore

/// Which window a lock overlay sits on: the main window shows the setup flow itself while Mango isn't set
/// up (`LaunchView`), so only the Settings window is covered then.
enum LockOverlayScene {
    case main
    case settings
}

extension View {
    /// The lock screen over this window while Mango is locked (auth spec §6): opaque, so the content under
    /// it is hidden, not blurred; the window's toolbar goes and its content takes no clicks or focus.
    /// The session is the app's (`AppEnvironment.Current`), shared by every window.
    func lockOverlay(_ scene: LockOverlayScene) -> some View {
        modifier(LockOverlayModifier(scene: scene))
    }
}

private struct LockOverlayModifier: ViewModifier {
    let scene: LockOverlayScene
    @ObservedObject private var current = AppEnvironment.Current.shared

    func body(content: Content) -> some View {
        if let session = current.environment?.session {
            content.modifier(SessionLockOverlay(scene: scene, session: session))
        } else {
            content
        }
    }
}

private struct SessionLockOverlay: ViewModifier {
    let scene: LockOverlayScene
    @ObservedObject var session: SessionModel
    @StateObject private var model: LockScreenModel

    init(scene: LockOverlayScene, session: SessionModel) {
        self.scene = scene
        self.session = session
        _model = StateObject(wrappedValue: LockScreenModel(session: session))
    }

    private var covers: Bool {
        switch session.state {
        case .locked: true
        case .notSetUp: scene == .settings
        // A step after signing in (a new password after the recovery key, the Touch ID offer) keeps it up.
        case .signedIn: model.holdsOverlay
        }
    }

    func body(content: Content) -> some View {
        content
            .opacity(covers ? 0 : 1)
            .allowsHitTesting(!covers)
            .accessibilityHidden(covers)
            .toolbar(covers ? .hidden : .automatic, for: .windowToolbar)
            .overlay {
                if covers {
                    Group {
                        if session.state == .notSetUp {
                            NotSetUpCover()
                        } else {
                            LockScreen(model: model)
                        }
                    }
                    .transition(.opacity)
                }
            }
            .onChange(of: session.state, initial: true) { _, state in
                if state == .locked { model.prepare() }
                SheetCovers.shared.update(locked: state == .locked, session: session)
            }
            // At launch the people are read after the first lock: pick the only one once they're in.
            .onChange(of: session.signInCandidates) {
                if session.state == .locked && model.selectedId == nil { model.prepare() }
            }
    }
}

/// The Settings window before setup: nothing to change until someone can sign in.
private struct NotSetUpCover: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "lock.fill").font(.largeTitle).foregroundStyle(.secondary)
            Text("Set up Mango").font(.title3.weight(.semibold))
            Text("Finish setting up in Mango's window first.").font(.callout).foregroundStyle(.secondary)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor).ignoresSafeArea())
    }
}

// MARK: - The lock screen

/// One window's lock screen: who is picked and what they're typing. Every window has its own; the session
/// they sign in to is shared.
@MainActor
final class LockScreenModel: ObservableObject {
    enum Step: Equatable {
        /// The avatars; a Touch ID user picked shows "Use password".
        case choose
        case password
        /// "Forgot password?".
        case recoveryKey
        /// Signed in with the recovery key: a new password before the content shows.
        case newPassword
        /// Signed in with a password on a Mac with Touch ID they haven't turned on here.
        case offerTouchID
    }

    @Published var selectedId: Int64?
    @Published var step: Step = .choose
    @Published var password = ""
    @Published var recoveryKey = ""
    @Published var newPassword = ""
    @Published var confirmPassword = ""
    @Published var message: String?
    /// Too many wrong attempts: nothing is checked before this moment.
    @Published var throttledUntil: Date?
    @Published private(set) var isWorking = false
    @Published private(set) var enrolled: Set<Int64> = []
    @Published private(set) var touchIDAvailable = false

    let session: SessionModel
    private let biometrics: any BiometricUnlocker
    /// Snapshot routes show their own people.
    private let fixedCandidates: [AppUser]?

    init(session: SessionModel, biometrics: (any BiometricUnlocker)? = nil, candidates: [AppUser]? = nil) {
        self.session = session
        self.biometrics = biometrics ?? session.biometrics
        self.fixedCandidates = candidates
        refreshEnrolment()
    }

    var candidates: [AppUser] { fixedCandidates ?? session.signInCandidates }
    var selected: AppUser? { candidates.first { $0.id == selectedId } }
    var holdsOverlay: Bool { step == .newPassword || step == .offerTouchID }
    func isEnrolled(_ user: AppUser) -> Bool { user.id.map(enrolled.contains) ?? false }

    /// Called whenever Mango locks: back to the avatars, nothing typed kept. One person is picked already.
    func prepare() {
        refreshEnrolment()
        password = ""; recoveryKey = ""; newPassword = ""; confirmPassword = ""
        message = nil
        if candidates.count == 1, let only = candidates.first {
            selectedId = only.id
            step = isEnrolled(only) && touchIDAvailable ? .choose : .password
        } else {
            selectedId = nil
            step = .choose
        }
    }

    /// Clicking an avatar: Touch ID when they turned it on here, otherwise their password.
    func select(_ user: AppUser) {
        guard !isWorking, let id = user.id else { return }
        selectedId = id
        message = nil
        password = ""
        if isEnrolled(user) && touchIDAvailable {
            step = .choose
            Task { await useTouchID() }
        } else {
            step = .password
        }
    }

    func useTouchID() async {
        guard let id = selectedId, !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        switch await session.signInWithBiometrics(appUserId: id) {
        case .signedIn:
            finish()
        case .cancelled:
            break
        case .notEnrolled:
            // The fingerprints changed, or Touch ID was turned off elsewhere: the password once, then the offer.
            enrolled.remove(id)
            step = .password
            message = "Touch ID isn't on for you here any more. Enter your password."
        case .failed(let error):
            message = error
        }
    }

    func usePassword() {
        step = .password
        message = nil
    }

    func forgotPassword() {
        step = .recoveryKey
        recoveryKey = ""
        message = nil
    }

    func submitPassword() async {
        guard let id = selectedId, !password.isEmpty, !isWorking, !isThrottled else { return }
        isWorking = true
        let result = await session.signIn(appUserId: id, password: password)
        isWorking = false
        password = ""
        switch result {
        case .signedIn:
            if touchIDAvailable && !enrolled.contains(id) { message = nil; step = .offerTouchID } else { finish() }
        default:
            handleFailure(result, wrong: "Wrong password.")
        }
    }

    func submitRecoveryKey() async {
        guard let id = selectedId, !recoveryKey.isEmpty, !isWorking, !isThrottled else { return }
        isWorking = true
        let result = await session.signIn(appUserId: id, recoveryKey: recoveryKey)
        isWorking = false
        switch result {
        case .signedIn:
            recoveryKey = ""
            message = nil
            step = .newPassword
        default:
            handleFailure(result, wrong: "That recovery key doesn't match.")
        }
    }

    var newPasswordStrength: PasswordStrength { PasswordStrength.assess(newPassword) }
    var canSaveNewPassword: Bool { newPasswordStrength.isAcceptable && newPassword == confirmPassword && !isWorking }

    /// After the recovery key: the session is signed in, which is the proof the store relies on.
    func saveNewPassword() async {
        guard canSaveNewPassword, let id = session.currentAppUserId else { return }
        isWorking = true
        defer { isWorking = false }
        let password = newPassword
        do {
            // PBKDF2 runs on the database queue, off the main thread.
            try await session.dbQueue.write { try AppUserStore.changePassword($0, appUserId: id, newPassword: password) }
            newPassword = ""; confirmPassword = ""
            if touchIDAvailable && !enrolled.contains(id) { message = nil; step = .offerTouchID } else { finish() }
        } catch {
            message = SignInErrorText.describe(error)
        }
    }

    func turnOnTouchID() async {
        guard let id = session.currentAppUserId else { finish(); return }
        isWorking = true
        defer { isWorking = false }
        do {
            try await biometrics.enrol(appUserId: id)
            finish()
        } catch {
            message = "Touch ID couldn't be turned on: \(error.localizedDescription)"
        }
    }

    func finish() {
        message = nil
        step = .choose
    }

    var isThrottled: Bool { (throttledUntil ?? .distantPast) > Date() }

    private func handleFailure(_ result: SessionModel.SignInResult, wrong: String) {
        switch result {
        case .wrongPassword: message = wrong
        case .throttled(let wait):
            let until = Date().addingTimeInterval(wait)
            throttledUntil = until
            message = nil
            // Sign In comes back when the wait is over.
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(wait))
                if self?.throttledUntil == until { self?.throttledUntil = nil }
            }
        case .failed(let error): message = error
        case .busy, .signedIn: break
        }
    }

    private func refreshEnrolment() {
        enrolled = biometrics.enrolledIds()
        touchIDAvailable = biometrics.isAvailable
    }
}

/// "Mango is locked": the app's icon, an avatar per person who can sign in on this Mac and the step in hand.
struct LockScreen: View {
    @ObservedObject var model: LockScreenModel
    @Environment(\.theme) private var theme
    @FocusState private var focused: Bool

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                VStack(spacing: 10) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 72, height: 72)
                    Text(model.step == .newPassword || model.step == .offerTouchID ? "Mango" : "Mango is locked")
                        .font(.title2.weight(.semibold))
                }
                if model.step != .newPassword && model.step != .offerTouchID {
                    avatars
                }
                stepContent
                    .frame(maxWidth: 340)
            }
            .padding(32)
            .frame(maxWidth: .infinity)
        }
        .defaultScrollAnchor(.center)
        .scrollBounceBehavior(.basedOnSize)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor).ignoresSafeArea())
        .onAppear { if model.selectedId == nil && model.step == .choose { model.prepare() } }
    }

    private var avatars: some View {
        HStack(alignment: .top, spacing: 24) {
            ForEach(model.candidates) { user in
                Button { model.select(user) } label: {
                    VStack(spacing: 8) {
                        UserAvatar(name: user.displayName, size: 64, isSelected: user.id == model.selectedId)
                        Text(user.displayName)
                            .font(.callout)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .frame(width: 104)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(model.isEnrolled(user) && model.touchIDAvailable ? "Sign in as \(user.displayName) with Touch ID" : "Sign in as \(user.displayName)")
                .accessibilityLabel("Sign in as \(user.displayName)")
            }
        }
    }

    @ViewBuilder private var stepContent: some View {
        switch model.step {
        case .choose:
            if let user = model.selected, model.isEnrolled(user), model.touchIDAvailable {
                VStack(spacing: 10) {
                    Button { Task { await model.useTouchID() } } label: { Label("Use Touch ID", systemImage: "touchid") }
                        .buttonStyle(.borderedProminent).prominentTint()
                        .disabled(model.isWorking)
                    Button("Use password") { model.usePassword() }
                        .buttonStyle(.link)
                    messageLine
                }
            }
        case .password:
            VStack(spacing: 10) {
                HStack(spacing: 8) {
                    SecureField("Password", text: $model.password)
                        .textFieldStyle(.roundedBorder)
                        .focused($focused)
                        .onSubmit { Task { await model.submitPassword() } }
                    Button("Sign In") { Task { await model.submitPassword() } }
                        .buttonStyle(.borderedProminent).prominentTint()
                        .keyboardShortcut(.defaultAction)
                        .disabled(model.password.isEmpty || model.isWorking || model.isThrottled)
                }
                messageLine
                HStack(spacing: 16) {
                    Button("Forgot password?") { model.forgotPassword() }
                    if let user = model.selected, model.isEnrolled(user), model.touchIDAvailable {
                        Button("Use Touch ID") { Task { await model.useTouchID() } }
                    }
                }
                .buttonStyle(.link)
                .font(.callout)
            }
            .onAppear { focused = true }
        case .recoveryKey:
            VStack(spacing: 10) {
                Text("Enter your recovery key").font(.headline)
                Text("The 24 characters you saved when you set up Mango. Dashes and spaces don't matter.")
                    .font(.callout).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                TextField("XXXX-XXXX-XXXX-XXXX-XXXX-XXXX", text: $model.recoveryKey)
                    .textFieldStyle(.roundedBorder)
                    .font(.body.monospaced())
                    .multilineTextAlignment(.center)
                    .focused($focused)
                    .onSubmit { Task { await model.submitRecoveryKey() } }
                messageLine
                HStack(spacing: 16) {
                    Button("Use password") { model.usePassword() }
                        .buttonStyle(.link)
                        .font(.callout)
                    Button("Continue") { Task { await model.submitRecoveryKey() } }
                        .buttonStyle(.borderedProminent).prominentTint()
                        .keyboardShortcut(.defaultAction)
                        .disabled(model.recoveryKey.isEmpty || model.isWorking || model.isThrottled)
                }
            }
            .onAppear { focused = true }
        case .newPassword:
            VStack(spacing: 10) {
                Text("Choose a password").font(.headline)
                Text("You signed in with your recovery key. Set a new password to carry on.")
                    .font(.callout).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                NewPasswordFields(password: $model.newPassword, confirmation: $model.confirmPassword)
                messageLine
                Button("Save") { Task { await model.saveNewPassword() } }
                    .buttonStyle(.borderedProminent).prominentTint()
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canSaveNewPassword)
            }
        case .offerTouchID:
            VStack(spacing: 10) {
                Image(systemName: "touchid").font(.largeTitle).foregroundStyle(theme.accent)
                Text("Use Touch ID on this Mac").font(.headline)
                Text("Next time, unlock Mango with your fingerprint. Your password still works.")
                    .font(.callout).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                messageLine
                HStack(spacing: 8) {
                    Button("Not Now") { model.finish() }
                    Button("Turn On") { Task { await model.turnOnTouchID() } }
                        .buttonStyle(.borderedProminent).prominentTint()
                        .keyboardShortcut(.defaultAction)
                        .disabled(model.isWorking)
                }
            }
        }
    }

    /// A wrong attempt, or the throttle's countdown ("Try again in N s").
    @ViewBuilder private var messageLine: some View {
        if let until = model.throttledUntil, until > Date() {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let remaining = until.timeIntervalSince(context.date)
                Text(remaining > 0 ? AuthText.tryAgain(after: remaining) : " ")
                    .font(.callout)
                    .foregroundStyle(theme.expense)
            }
        } else if let message = model.message {
            Text(message)
                .font(.callout)
                .foregroundStyle(theme.expense)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A person's initials in a circle (the lock screen, the sidebar footer, Settings ▸ Sign-in).
struct UserAvatar: View {
    let name: String
    var size: CGFloat = 28
    var isSelected = false
    @Environment(\.theme) private var theme

    var body: some View {
        Text(AuthText.initials(name))
            .font(.system(size: size * 0.38, weight: .semibold, design: .rounded))
            .foregroundStyle(.white)
            .lineLimit(1)
            .frame(width: size, height: size)
            .background(Circle().fill(theme.accent.gradient))
            .overlay {
                if isSelected {
                    Circle().strokeBorder(theme.accent, lineWidth: 2.5).padding(-4)
                }
            }
            .accessibilityHidden(true)
    }
}

/// "Choose a password": the password twice, with the strength hint ("At least 10 characters" until it is).
struct NewPasswordFields: View {
    @Binding var password: String
    @Binding var confirmation: String
    @Environment(\.theme) private var theme

    private var strength: PasswordStrength { PasswordStrength.assess(password) }
    private var mismatch: Bool { !confirmation.isEmpty && confirmation != password }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SecureField("New password", text: $password)
                .textFieldStyle(.roundedBorder)
            SecureField("Type it again", text: $confirmation)
                .textFieldStyle(.roundedBorder)
            HStack(spacing: 6) {
                StrengthMeter(strength: strength)
                Text(mismatch ? "The two passwords don't match" : strength.hint)
                    .font(.caption)
                    .foregroundStyle(mismatch ? theme.expense : Color.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Three bars filled as the password gets stronger.
private struct StrengthMeter: View {
    let strength: PasswordStrength
    @Environment(\.theme) private var theme

    private var colour: Color {
        switch strength {
        case .tooShort, .weak: theme.expense
        case .fair: theme.pending
        case .strong: theme.income
        }
    }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(1...3, id: \.self) { level in
                Capsule()
                    .fill(strength.rawValue >= level ? colour : Color.secondary.opacity(0.25))
                    .frame(width: 12, height: 4)
            }
        }
        .accessibilityElement()
        .accessibilityLabel(strength.hint)
    }
}

/// How the store's refusals read in the sign-in screens.
enum SignInErrorText {
    static func describe(_ error: Error) -> String {
        switch error as? AppUserStoreError {
        case .passwordTooShort: "Passwords need at least \(AppUserStore.minimumPasswordLength) characters."
        case .lastAdmin: "Someone has to stay an admin who can sign in on this Mac."
        case .notAdmin: "Only an admin can do that."
        case .cannotRemoveSelf: "You can't remove yourself while you're signed in."
        case .personAlreadyHasUser: "That person can already sign in."
        case .noCredential: "They have no password on this Mac yet."
        case .emptyName: "The name can't be empty."
        case .unknownPerson, .noSuchUser: "That person isn't in this database any more."
        case nil: error.localizedDescription
        }
    }
}

// MARK: - Sheets

/// Sheets and alerts are windows of their own: while Mango is locked each gets an opaque lock screen over
/// it, so nothing in them shows and the window that holds the sheet can still be unlocked from it.
@MainActor
final class SheetCovers {
    static let shared = SheetCovers()
    private var covers: [ObjectIdentifier: NSView] = [:]
    private var observer: NSObjectProtocol?
    private weak var session: SessionModel?

    func update(locked: Bool, session: SessionModel) {
        guard !SnapshotMode.isActive else { return }
        self.session = session
        if locked {
            for window in NSApp.windows where window.isSheet { cover(window) }
            if observer == nil {
                // A sheet that opens while locked (an alert from a background task).
                observer = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { [weak self] note in
                    MainActor.assumeIsolated {
                        guard let window = note.object as? NSWindow, window.isSheet else { return }
                        self?.cover(window)
                    }
                }
            }
        } else {
            for cover in covers.values { cover.removeFromSuperview() }
            covers = [:]
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
        }
    }

    private func cover(_ window: NSWindow) {
        guard let session, covers[ObjectIdentifier(window)] == nil, let content = window.contentView else { return }
        let host = NSHostingView(rootView: LockScreen(model: LockScreenModel(session: session)).themedRoot())
        host.frame = content.bounds
        host.autoresizingMask = [.width, .height]
        content.addSubview(host, positioned: .above, relativeTo: nil)
        covers[ObjectIdentifier(window)] = host
    }
}
