// App/Auth/LockOverlay.swift
import SwiftUI
import AppKit
import Combine
import BudgetCore

/// Which window a lock overlay sits on: the main window shows the setup flow itself while Mango isn't set
/// up (`LaunchView`), so only the Settings window is covered then — and whenever it has no session yet.
enum LockOverlayScene {
    case main
    case settings
}

extension View {
    /// The lock screen over this window while Mango is locked (auth spec §6). It's opaque, so the content
    /// under it is hidden, not blurred. The content is also disabled: it takes no clicks, focus, typing or
    /// keyboard shortcuts; Settings' toolbar (its tabs) goes, and the main window's toolbar items hide. The session is the app's (`AppEnvironment.Current`),
    /// shared by every window; snapshot routes pass one of their own.
    func lockOverlay(_ scene: LockOverlayScene, session: SessionModel? = nil) -> some View {
        modifier(LockOverlayModifier(scene: scene, fixedSession: session))
    }
}

extension EnvironmentValues {
    /// The lock screen covers this window: views hosted apart from the root (the sidebar column, the
    /// toolbar, the title) hide themselves.
    @Entry var isLockCovered = false
}

/// The session a window's overlay follows, re-published whenever it changes. It's an object rather than an
/// `if let` over the content, so the content keeps its identity when the environment arrives (an `if` would
/// rebuild `LaunchView` and load the environment a second time).
@MainActor
private final class LockGate: ObservableObject {
    @Published private(set) var session: SessionModel?
    private var environmentSubscription: AnyCancellable?
    private var sessionSubscription: AnyCancellable?

    init(fixed: SessionModel?) {
        if let fixed {
            attach(fixed)
        } else {
            environmentSubscription = AppEnvironment.Current.shared.$environment
                .map { $0?.session }
                .removeDuplicates { $0 === $1 }
                .sink { [weak self] session in
                    MainActor.assumeIsolated { self?.attach(session) }
                }
        }
    }

    private func attach(_ session: SessionModel?) {
        self.session = session
        sessionSubscription = session?.objectWillChange.sink { [weak self] _ in
            MainActor.assumeIsolated { self?.objectWillChange.send() }
        }
    }
}

private struct LockOverlayModifier: ViewModifier {
    let scene: LockOverlayScene
    @StateObject private var gate: LockGate

    init(scene: LockOverlayScene, fixedSession: SessionModel?) {
        self.scene = scene
        _gate = StateObject(wrappedValue: LockGate(fixed: fixedSession))
    }

    private var covers: Bool {
        guard let session = gate.session else { return scene == .settings }
        if session.state == .notSetUp { return scene == .settings }
        return session.isCovered
    }

    func body(content: Content) -> some View {
        content
            .environment(\.isLockCovered, covers)
            .disabled(covers)
            .opacity(covers ? 0 : 1)
            .allowsHitTesting(!covers)
            .accessibilityHidden(covers)
            // Settings' toolbar is its tabs, so it goes. The main window keeps its toolbar (its items hide
            // themselves, `isLockCovered`): showing and hiding a window's toolbar changes the window's frame,
            // so every lock and unlock resized it.
            .toolbar(covers && scene == .settings ? .hidden : .automatic, for: .windowToolbar)
            .overlay {
                if covers {
                    cover.transition(.opacity)
                }
            }
            .onChange(of: gate.session?.isCovered ?? false, initial: true) { _, covered in
                if let session = gate.session { SheetCovers.shared.update(covered: covered, session: session) }
            }
    }

    @ViewBuilder private var cover: some View {
        if let session = gate.session, session.state != .notSetUp {
            LockScreenHost(session: session)
        } else if gate.session == nil {
            PlainCover(title: "Mango", message: "Open Mango to change settings.")
        } else {
            PlainCover(title: "Set up Mango", message: "Finish setting up in Mango's window first.")
        }
    }
}

/// The Settings window with nothing to change yet: before setup, or before Mango's window has opened the
/// database (or after it couldn't).
private struct PlainCover: View {
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "lock.fill").font(.largeTitle).foregroundStyle(.secondary)
            Text(title).font(.title3.weight(.semibold))
            Text(message).font(.callout).foregroundStyle(.secondary)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor).ignoresSafeArea())
        .focusable()
    }
}

/// A fresh lock screen each time a window is covered: nothing typed before survives a lock.
struct LockScreenHost: View {
    @StateObject private var model: LockScreenModel
    @ObservedObject private var session: SessionModel

    init(session: SessionModel) {
        self.session = session
        _model = StateObject(wrappedValue: LockScreenModel(session: session))
    }

    var body: some View {
        LockScreen(model: model)
            // Touch ID by itself when this lock screen comes up with Mango in front, and when Mango comes
            // forward while still locked.
            .onAppear { model.autoPromptTouchID() }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                model.autoPromptTouchID()
            }
            // Signed in from another window, or the lock screen replaced: a try still listening ends.
            .onDisappear { model.cancelTouchID() }
            // At launch the people are read after the first lock: pick the only one once they're in.
            .onChange(of: session.signInCandidates) {
                if model.selectedId == nil { model.prepare() }
            }
    }
}

// MARK: - The lock screen

/// One window's lock screen: who is picked and what they're typing. Every window has its own; the session
/// they sign in to is shared, and so are the steps after signing in (`SessionModel.afterSignIn`).
@MainActor
final class LockScreenModel: ObservableObject {
    enum Step: Equatable {
        /// The avatars; a Touch ID user picked shows the inline Touch ID and "Use password".
        case choose
        case password
        /// "Forgot password?".
        case recoveryKey
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
    /// The Touch ID try listening in this lock screen (its glyph shows under the avatars), nil otherwise.
    @Published private(set) var touchIDPrompt: InlineTouchIDPrompt?
    private var touchIDTask: Task<Bool, Never>?

    let session: SessionModel
    private let biometrics: any BiometricUnlocker
    /// Snapshot routes show their own people.
    private let fixedCandidates: [AppUser]?

    init(session: SessionModel, biometrics: (any BiometricUnlocker)? = nil, candidates: [AppUser]? = nil) {
        self.session = session
        self.biometrics = biometrics ?? session.biometrics
        self.fixedCandidates = candidates
        prepare()
    }

    var candidates: [AppUser] { fixedCandidates ?? session.signInCandidates }
    var selected: AppUser? { candidates.first { $0.id == selectedId } }
    func isEnrolled(_ user: AppUser) -> Bool { user.id.map(enrolled.contains) ?? false }

    /// Back to the avatars, nothing typed kept. One person is picked already.
    func prepare() {
        enrolled = biometrics.enrolledIds()
        touchIDAvailable = biometrics.isAvailable
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

    /// Clicking an avatar: Touch ID when they turned it on here, otherwise their password. A try still
    /// listening for someone else ends first.
    func select(_ user: AppUser) {
        if touchIDPrompt != nil {
            Task { await cancelTouchIDAndWait(); select(user) }
            return
        }
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

    /// The avatar row's arrow keys: moves the pick without signing in.
    func movePick(by offset: Int) {
        if touchIDPrompt != nil {
            Task { await cancelTouchIDAndWait(); movePick(by: offset) }
            return
        }
        guard !candidates.isEmpty, !isWorking else { return }
        let index = candidates.firstIndex { $0.id == selectedId }.map { $0 + offset } ?? (offset > 0 ? 0 : candidates.count - 1)
        selectedId = candidates[min(max(index, 0), candidates.count - 1)].id
        step = .choose
        message = nil
    }

    /// Starts Touch ID without a click for the one person it's clear about (`TouchIDAutoPrompt`): not in
    /// the background, not over another step, and once per lock (again only if the last try never got an
    /// answer because Mango went to the background). "Use password" ends it.
    func autoPromptTouchID() {
        guard fixedCandidates == nil, step == .choose, !isWorking, session.afterSignIn == nil,
              session.state == .locked, touchIDAvailable || !biometrics.enrolledIds().isEmpty else { return }
        enrolled = biometrics.enrolledIds()
        touchIDAvailable = biometrics.isAvailable
        guard let id = TouchIDAutoPrompt.user(
            lastSignedIn: session.lastSignedInId, candidates: candidates.compactMap(\.id),
            enrolled: enrolled, touchIDAvailable: touchIDAvailable),
              session.claimAutoPrompt(otherStepInProgress: false) else { return }
        selectedId = id
        message = nil
        Task {
            let ran = await useTouchID()
            // Answered while Mango was in front; if it went to the background (or never started) it wasn't.
            session.autoPromptEnded(decided: ran && NSApp.isActive)
        }
    }

    /// Touch ID in this lock screen: the glyph shows under the avatars and listens; the finger is asked for
    /// there, not in a system panel. True when the try ran (the glyph came up and was answered or cancelled).
    @discardableResult
    func useTouchID() async -> Bool {
        guard let id = selectedId, !isWorking, touchIDTask == nil else { return false }
        let task = Task { await runTouchID(appUserId: id) }
        touchIDTask = task
        let ran = await task.value
        touchIDTask = nil
        return ran
    }

    private func runTouchID(appUserId id: Int64) async -> Bool {
        isWorking = true
        step = .choose
        message = nil
        let prompt = InlineTouchIDPrompt()
        touchIDPrompt = prompt
        defer {
            touchIDPrompt = nil
            isWorking = false
        }
        // Never evaluated before its view is on screen: that would bring up the system's panel.
        guard await prompt.waitUntilPaired() else { return false }
        let result = await session.signInWithBiometrics(appUserId: id, prompt: prompt)
        switch result {
        case .signedIn:
            message = nil
        case .cancelled:
            break
        case .notRecognised:
            message = TouchIDInlineText.notRecognised
        case .lockedOut:
            step = .password
            message = TouchIDInlineText.lockedOut
        case .notEnrolled:
            // The fingerprints changed, or Touch ID was turned off elsewhere: the password once, then the offer.
            enrolled.remove(id)
            step = .password
            message = "Touch ID isn't on for you here any more. Enter your password."
        case .failed(let error):
            message = "Touch ID didn't work: \(AuthText.sentence(error)) Enter your password."
            step = .password
        }
        return true
    }

    /// Ends a try still listening (it comes back as a cancel).
    func cancelTouchID() { touchIDPrompt?.cancel() }

    private func cancelTouchIDAndWait() async {
        cancelTouchID()
        _ = await touchIDTask?.value
    }

    /// Next to the listening glyph (and Esc): ends the try and asks for the password.
    func usePassword() {
        cancelTouchID()
        step = .password
        message = nil
    }

    func forgotPassword() {
        step = .recoveryKey
        recoveryKey = ""
        message = nil
    }

    private func offersTouchID(_ id: Int64) -> Bool { touchIDAvailable && !enrolled.contains(id) }

    func submitPassword() async {
        guard let id = selectedId, !password.isEmpty, !isWorking, !isThrottled else { return }
        isWorking = true
        let result = await session.signIn(appUserId: id, password: password, offerTouchID: offersTouchID(id))
        isWorking = false
        password = ""
        if result == .signedIn { message = nil } else { handleFailure(result, wrong: "Wrong password.") }
    }

    /// Signed in, every window then asks for a new password (`SessionModel.afterSignIn`).
    func submitRecoveryKey() async {
        guard let id = selectedId, !recoveryKey.isEmpty, !isWorking, !isThrottled else { return }
        isWorking = true
        let result = await session.signIn(appUserId: id, recoveryKey: recoveryKey)
        isWorking = false
        if result == .signedIn {
            recoveryKey = ""
            message = nil
        } else {
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
        do {
            try await session.chooseNewPassword(newPassword, thenOfferTouchID: offersTouchID(id))
            newPassword = ""; confirmPassword = ""
            message = nil
        } catch {
            message = SignInErrorText.describe(error)
        }
    }

    func turnOnTouchID() async {
        guard let id = session.currentAppUserId else { session.finishOffer(); return }
        isWorking = true
        defer { isWorking = false }
        do {
            try await biometrics.enrol(appUserId: id)
            enrolled.insert(id)
            message = nil
            session.finishOffer()
        } catch {
            // Shown on the offer, which stays up so it's read; "Not Now" carries on.
            message = "Couldn't turn on Touch ID: \(AuthText.sentence(error.localizedDescription))"
        }
    }

    func notNow() {
        message = nil
        session.finishOffer()
    }

    var isThrottled: Bool { (throttledUntil ?? .distantPast) > Date() }

    #if SNAPSHOTS
    /// Snapshot routes only: the inline Touch ID shown listening, never evaluated.
    func snapshotShowTouchIDListening() {
        step = .choose
        touchIDPrompt = InlineTouchIDPrompt()
    }
    #endif

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
}

/// "Mango is locked": the app's icon, an avatar per person who can sign in on this Mac and the step in hand.
/// The keyboard is always somewhere on it (the avatars, a field or the offer), never in the hidden content.
struct LockScreen: View {
    @ObservedObject var model: LockScreenModel
    @ObservedObject private var session: SessionModel
    @Environment(\.theme) private var theme
    @FocusState private var focus: Field?

    private enum Field: Hashable { case avatars, password, recoveryKey, offer }

    /// What this window shows: a step after signing in (shared by every window) or the lock screen's own.
    private enum Shown: Equatable {
        case lock(LockScreenModel.Step)
        case newPassword
        case offerTouchID
    }

    init(model: LockScreenModel) {
        self.model = model
        self.session = model.session
    }

    private var shown: Shown {
        if case .signedIn = session.state, let after = session.afterSignIn {
            return after == .newPassword ? .newPassword : .offerTouchID
        }
        return .lock(model.step)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                VStack(spacing: 10) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 72, height: 72)
                    Text(shown == .newPassword || shown == .offerTouchID ? "Mango" : "Mango is locked")
                        .font(.title2.weight(.semibold))
                }
                if case .lock = shown {
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
        .onChange(of: shown, initial: true) { _, shown in
            // After the step's view is in, so the field exists to take the focus.
            DispatchQueue.main.async { focus = Self.field(for: shown) }
        }
    }

    private static func field(for shown: Shown) -> Field? {
        switch shown {
        case .lock(.choose): .avatars
        case .lock(.password): .password
        case .lock(.recoveryKey): .recoveryKey
        // The new-password fields take it themselves (`NewPasswordFields.focusFirst`).
        case .newPassword: nil
        case .offerTouchID: .offer
        }
    }

    /// Clickable, and focusable as one row: ←/→ move the pick, Return or Space signs in as them.
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
                .focusable(false)
                .help(model.isEnrolled(user) && model.touchIDAvailable ? "Sign in as \(user.displayName) with Touch ID" : "Sign in as \(user.displayName)")
                .accessibilityLabel("Sign in as \(user.displayName)")
            }
        }
        .padding(6)
        .focusable()
        .focusEffectDisabled()
        .focused($focus, equals: .avatars)
        .onKeyPress(.leftArrow) { model.movePick(by: -1); return .handled }
        .onKeyPress(.rightArrow) { model.movePick(by: 1); return .handled }
        .onKeyPress(keys: [.return, .space]) { _ in
            if let user = model.selected ?? model.candidates.first { model.select(user) }
            return .handled
        }
    }

    @ViewBuilder private var stepContent: some View {
        switch shown {
        case .lock(.choose):
            if let prompt = model.touchIDPrompt {
                // Touch ID listening right here: the glyph, Mango's own caption, and the way out.
                VStack(spacing: 10) {
                    InlineTouchIDView(prompt: prompt)
                    Text(TouchIDInlineText.listening)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Button("Use password") { model.usePassword() }
                        .buttonStyle(.link)
                        .keyboardShortcut(.cancelAction)
                    messageLine
                }
            } else if let user = model.selected, model.isEnrolled(user), model.touchIDAvailable {
                VStack(spacing: 10) {
                    Button { Task { await model.useTouchID() } } label: {
                        Label(model.message == nil ? "Use Touch ID" : "Try Touch ID Again", systemImage: "touchid")
                    }
                        .buttonStyle(.borderedProminent).prominentTint()
                        .disabled(model.isWorking)
                    Button("Use password") { model.usePassword() }
                        .buttonStyle(.link)
                    messageLine
                }
            }
        case .lock(.password):
            VStack(spacing: 10) {
                HStack(spacing: 8) {
                    SecureField("Password", text: $model.password)
                        .textFieldStyle(.roundedBorder)
                        .focused($focus, equals: .password)
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
        case .lock(.recoveryKey):
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
                    .focused($focus, equals: .recoveryKey)
                    .onSubmit { Task { await model.submitRecoveryKey() } }
                messageLine
                HStack(spacing: 16) {
                    Button("Use password") { model.usePassword() }
                        .buttonStyle(.link)
                        .font(.callout)
                        .keyboardShortcut(.cancelAction)
                    Button("Continue") { Task { await model.submitRecoveryKey() } }
                        .buttonStyle(.borderedProminent).prominentTint()
                        .keyboardShortcut(.defaultAction)
                        .disabled(model.recoveryKey.isEmpty || model.isWorking || model.isThrottled)
                }
            }
        case .newPassword:
            VStack(spacing: 10) {
                Text("Choose a password").font(.headline)
                Text("You signed in with your recovery key. Set a new password to carry on.")
                    .font(.callout).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                NewPasswordFields(password: $model.newPassword, confirmation: $model.confirmPassword, focusFirst: true)
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
                    Button("Not Now") { model.notNow() }
                        .keyboardShortcut(.cancelAction)
                    Button("Turn On") { Task { await model.turnOnTouchID() } }
                        .buttonStyle(.borderedProminent).prominentTint()
                        .keyboardShortcut(.defaultAction)
                        .disabled(model.isWorking)
                }
            }
            .focusable()
            .focusEffectDisabled()
            .focused($focus, equals: .offer)
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
    /// Puts the keyboard in the first field when shown (the lock screen's new-password step).
    var focusFirst = false
    @Environment(\.theme) private var theme
    @FocusState private var firstFocused: Bool

    private var strength: PasswordStrength { PasswordStrength.assess(password) }
    private var mismatch: Bool { !confirmation.isEmpty && confirmation != password }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SecureField("New password", text: $password)
                .textFieldStyle(.roundedBorder)
                .focused($firstFocused)
                .onAppear { if focusFirst { firstFocused = true } }
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

// MARK: - Sheets, panels and popovers

/// Sheets and alerts are windows of their own. While Mango is covered:
/// - each sheet's own content view is taken out of it and an opaque lock screen put in its place (and made
///   the first responder), so nothing in it shows, Return and Esc can't reach its Save or Cancel, and the
///   window that holds the sheet can still be unlocked from it. The content view is kept, with its state,
///   and put back with the first responder it had;
/// - open and save panels (modal or sheets, ours or SwiftUI's `fileImporter`/`fileExporter`) are cancelled,
///   so nothing chosen in them is used;
/// - popovers are closed through their `NSPopover`, so SwiftUI's `isPresented` follows, and open menus
///   (the menu bar's, context menus) stop tracking.
/// When the cover lifts, the sheets come back as they were if the same person signed in again, and end
/// otherwise (`LockCoverPolicy`): someone else never sees another person's recovery key or half-typed form.
@MainActor
final class SheetCovers {
    static let shared = SheetCovers()
    private struct Cover {
        weak var window: NSWindow?
        let original: NSView
        /// What had the keyboard in the sheet (a view inside `original`, or the window).
        weak var firstResponder: NSResponder?
    }
    private var covers: [ObjectIdentifier: Cover] = [:]
    private var observer: NSObjectProtocol?
    private weak var session: SessionModel?
    /// The popovers on show and the menus tracking, followed from launch (`trackTransients`).
    private let popovers = NSHashTable<NSPopover>.weakObjects()
    private let menus = NSHashTable<NSMenu>.weakObjects()
    private var popoverObservers: [NSObjectProtocol] = []
    /// Who was signed in when the cover went up (nil while nothing is covered).
    private var coveredFor: Int64?
    private var isCovering = false

    /// Follows every popover shown and menu opened from now on, so a lock can close them. Called once, by
    /// the session.
    func trackTransients() {
        guard popoverObservers.isEmpty, !SnapshotMode.isActive else { return }
        let center = NotificationCenter.default
        popoverObservers.append(center.addObserver(forName: NSPopover.didShowNotification, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let popover = note.object as? NSPopover else { return }
                self?.popovers.add(popover)
                // One that opens while covered (from a background task) goes at once.
                if self?.session?.isCovered == true { Self.close(popover) }
            }
        })
        popoverObservers.append(center.addObserver(forName: NSPopover.didCloseNotification, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                if let popover = note.object as? NSPopover { self?.popovers.remove(popover) }
            }
        })
        popoverObservers.append(center.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                if let menu = note.object as? NSMenu { self?.menus.add(menu) }
            }
        })
        popoverObservers.append(center.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                if let menu = note.object as? NSMenu { self?.menus.remove(menu) }
            }
        })
    }

    func update(covered: Bool, session: SessionModel) {
        guard !SnapshotMode.isActive else { return }
        self.session = session
        if covered {
            if !isCovering {
                isCovering = true
                coveredFor = session.lastSignedInId
            }
            // A menu open when the lock fires would act on hidden content.
            NSApp.mainMenu?.cancelTrackingWithoutAnimation()
            for menu in menus.allObjects { menu.cancelTrackingWithoutAnimation() }
            for popover in popovers.allObjects where popover.isShown { Self.close(popover) }
            for window in NSApp.windows { coverOrCancel(window) }
            if observer == nil {
                // A sheet or panel that opens while covered (an alert from a background task).
                observer = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { [weak self] note in
                    MainActor.assumeIsolated {
                        guard let window = note.object as? NSWindow else { return }
                        self?.coverOrCancel(window)
                    }
                }
            }
        } else {
            let outcome = LockCoverPolicy.onUncover(coveredFor: coveredFor, signedIn: session.currentAppUserId)
            for cover in covers.values {
                guard let window = cover.window else { continue }
                switch outcome {
                case .restore:
                    let frame = window.frame
                    window.contentView = cover.original
                    window.setFrame(frame, display: true)
                    window.makeFirstResponder(cover.firstResponder ?? cover.original)
                case .dismiss:
                    // Ended still showing the lock screen: what it held is never shown again.
                    if let parent = window.sheetParent { parent.endSheet(window, returnCode: .cancel) } else { window.close() }
                }
            }
            covers = [:]
            isCovering = false
            coveredFor = nil
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
        }
    }

    private static func close(_ popover: NSPopover) {
        popover.performClose(nil)
        // A popover whose delegate refuses closes anyway.
        if popover.isShown { popover.close() }
    }

    private func coverOrCancel(_ window: NSWindow) {
        if let panel = window as? NSSavePanel {
            // NSOpenPanel too. Never swapped: the panel's own views must stay its own.
            if panel.isVisible { panel.cancel(nil) }
        } else if window.isSheet {
            cover(window)
        }
    }

    private func cover(_ window: NSWindow) {
        guard let session, covers[ObjectIdentifier(window)] == nil, let content = window.contentView else { return }
        let frame = window.frame
        // A field being typed in has the shared field editor as first responder: keep the field itself.
        var previous = window.firstResponder
        if let editor = previous as? NSTextView, editor.isFieldEditor, let field = editor.delegate as? NSResponder { previous = field }
        let host = NSHostingView(rootView: LockScreenHost(session: session).themedRoot())
        // The sheet keeps its size: the lock screen scrolls if it needs more.
        host.sizingOptions = []
        host.frame = content.frame
        let keeps = previous === window || (previous as? NSView)?.isDescendant(of: content) == true
        covers[ObjectIdentifier(window)] = Cover(window: window, original: content, firstResponder: keeps ? previous : nil)
        window.contentView = host
        window.setFrame(frame, display: true)
        window.makeFirstResponder(host)
    }
}
