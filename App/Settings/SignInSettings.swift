// App/Settings/SignInSettings.swift
import SwiftUI
import BudgetCore
import GRDB

extension LockTimeout {
    /// Settings ▸ Sign-in's "Lock after" choices.
    var title: String {
        switch self {
        case .minutes(60): "1 hour"
        case .minutes(let minutes): "\(minutes) minutes"
        case .never: "Never"
        }
    }
}

/// Settings ▸ Sign-in (auth spec §6): for everyone, their name, password, recovery key, Touch ID on this Mac
/// and the lock timeout; for admins, the household's app users on this Mac too. The Touch ID and timeout
/// edits apply on Save; every action asks for its own confirmation or sheet. Settings is covered by the lock
/// overlay while locked, so everything here is done by the person signed in.
struct SignInSettings: View {
    /// Snapshot routes pass their own (stand-in Touch ID).
    var model: SignInSettingsModel? = nil
    @ObservedObject private var current = AppEnvironment.Current.shared

    var body: some View {
        if let session = current.environment?.session {
            SignInSettingsContent(model: model ?? SignInSettingsModel(session: session), session: session)
        } else {
            Text("Open Mango's window first.")
                .font(.callout).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 200)
        }
    }
}

@MainActor
final class SignInSettingsModel: ObservableObject {
    enum Sheet: Identifiable {
        case changePassword
        case reset(AppUser)
        case add(Person)
        case recoveryKey(key: String, owner: String?)

        var id: String {
            switch self {
            case .changePassword: "change"
            case .reset(let user): "reset-\(user.id ?? 0)"
            case .add(let person): "add-\(person.id ?? 0)"
            case .recoveryKey(let key, _): "key-\(key)"
            }
        }
    }

    @Published private(set) var appUsers: [AppUser] = []
    @Published private(set) var withPassword: Set<Int64> = []
    @Published private(set) var unclaimed: [Person] = []
    /// The saved Touch ID and timeout, and the edits waiting for Save.
    @Published private(set) var savedTouchID = false
    @Published var touchID = false
    @Published private(set) var savedTimeout: LockTimeout
    @Published var timeout: LockTimeout
    @Published var sheet: Sheet?
    @Published var removing: AppUser?
    @Published var confirmingRegenerate = false
    @Published var error: String?
    @Published private(set) var isWorking = false

    let session: SessionModel
    private let biometrics: any BiometricUnlocker

    init(session: SessionModel, biometrics: (any BiometricUnlocker)? = nil) {
        self.session = session
        self.biometrics = biometrics ?? session.biometrics
        savedTimeout = session.lockTimeout
        timeout = session.lockTimeout
    }

    var me: AppUser? { session.currentUser }
    var isAdmin: Bool { me?.isAdmin == true }
    var touchIDAvailable: Bool { biometrics.isAvailable }
    var hasChanges: Bool { touchID != savedTouchID || timeout != savedTimeout }

    /// Who the open sheets and dialogs were for.
    private var shownFor: Int64?

    /// Someone else signed in: the sheets and dialogs open here were the last person's (a recovery key, a
    /// half-typed password, a confirmation), so they go. The same person again keeps them.
    func userChanged(to id: Int64?) {
        guard let id else { return }
        if let shownFor, shownFor != id {
            sheet = nil
            removing = nil
            confirmingRegenerate = false
            error = nil
        }
        shownFor = id
    }

    /// Someone else signed in (or the same person again): the edits waiting for Save were theirs, so they go.
    func discardEdits() async {
        savedTimeout = session.lockTimeout
        timeout = savedTimeout
        await load(discardingEdits: true)
    }

    func load(discardingEdits: Bool = false) async {
        let read = try? await session.dbQueue.read { db in
            (try AppUserStore.appUsers(db), Set(try LocalCredential.fetchAll(db).map(\.appUserId)), try AppUserStore.unclaimedPeople(db))
        }
        if let (users, credentials, people) = read {
            appUsers = users; withPassword = credentials; unclaimed = people
        }
        let enrolled = me?.id.map { biometrics.enrolledIds().contains($0) } ?? false
        if discardingEdits || savedTouchID == touchID { touchID = enrolled }
        savedTouchID = enrolled
    }

    /// The Touch ID and timeout edits.
    func save() async {
        guard let id = me?.id else { return }
        error = nil
        if timeout != savedTimeout {
            session.lockTimeout = timeout
            savedTimeout = timeout
        }
        if touchID != savedTouchID {
            if touchID {
                do { try await biometrics.enrol(appUserId: id) } catch {
                    self.error = "Couldn't turn on Touch ID: \(AuthText.sentence(error.localizedDescription))"
                    touchID = false
                }
            } else {
                session.removeBiometricEnrolment(appUserId: id)
            }
            await load()
        }
    }

    // Each of these runs as the person signed in: the store's "caller verified the user" rests on that.

    func changePassword(_ password: String) async throws {
        guard let id = me?.id else { throw AppUserStoreError.noSuchUser }
        try await session.dbQueue.write { try AppUserStore.changePassword($0, appUserId: id, newPassword: password) }
    }

    func regenerateRecoveryKey() async {
        guard let id = me?.id else { return }
        await run {
            let key = try await self.session.dbQueue.write { try AppUserStore.regenerateRecoveryKey($0, appUserId: id) }
            self.sheet = .recoveryKey(key: key, owner: nil)
        }
    }

    func resetPassword(of user: AppUser, to password: String) async throws {
        guard let id = me?.id, let target = user.id else { throw AppUserStoreError.noSuchUser }
        try await session.dbQueue.write { try AppUserStore.resetPassword($0, of: target, by: id, newPassword: password) }
    }

    func add(_ person: Person, password: String) async throws {
        guard isAdmin, let personId = person.id else { throw AppUserStoreError.notAdmin }
        let key = try await session.dbQueue.write { db in
            try AppUserStore.create(db, personId: personId, displayName: person.name, password: password, isAdmin: false, now: Date()).recoveryKey
        }
        await refresh()
        sheet = .recoveryKey(key: key, owner: person.name)
    }

    func makeAdmin(_ user: AppUser) async {
        guard let id = me?.id, let target = user.id else { return }
        await run {
            try await self.session.dbQueue.write { try AppUserStore.setAdmin($0, target, true, by: id) }
            await self.refresh()
        }
    }

    /// Their password, their place on the lock screen and this Mac's Touch ID for them go.
    func remove(_ user: AppUser) async {
        guard let id = me?.id, let target = user.id else { return }
        await run {
            try await self.session.dbQueue.write { try AppUserStore.remove($0, target, by: id) }
            self.session.removeBiometricEnrolment(appUserId: target)
            await self.refresh()
        }
    }

    private func refresh() async {
        await load()
        await session.refreshCandidates()
    }

    private func run(_ work: @escaping () async throws -> Void) async {
        isWorking = true
        error = nil
        defer { isWorking = false }
        do { try await work() } catch { self.error = SignInErrorText.describe(error) }
    }
}

struct SignInSettingsContent: View {
    @StateObject private var model: SignInSettingsModel
    @ObservedObject private var session: SessionModel
    @Environment(\.theme) private var theme

    init(model: @autoclosure @escaping () -> SignInSettingsModel, session: SessionModel) {
        _model = StateObject(wrappedValue: model())
        self.session = session
    }

    var body: some View {
        Form {
            if let me = session.currentUser {
                Section("You") {
                    HStack(spacing: 10) {
                        UserAvatar(name: me.displayName, size: 32)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(me.displayName).font(.headline).lineLimit(1)
                            Text(me.isAdmin ? "Admin on this Mac" : "Signed in on this Mac")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    LabeledContent("Password") {
                        Button("Change password…") { model.sheet = .changePassword }
                    }
                    LabeledContent("Recovery key") {
                        Button("Regenerate recovery key…") { model.confirmingRegenerate = true }
                    }
                }
                Section("This Mac") {
                    Toggle("Use Touch ID on this Mac", isOn: $model.touchID)
                        .disabled(!model.touchIDAvailable && !model.savedTouchID)
                    if !model.touchIDAvailable {
                        Text("This Mac has no Touch ID set up.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Picker("Lock after", selection: $model.timeout) {
                        ForEach(LockTimeout.choices, id: \.self) { choice in
                            Text(choice.title).tag(choice)
                        }
                    }
                    HStack {
                        Text("Mango also locks when the screen locks or the Mac sleeps.")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer(minLength: 8)
                        Button("Save") { Task { await model.save() } }
                            .buttonStyle(.borderedProminent).prominentTint()
                            .disabled(!model.hasChanges)
                    }
                }
                if me.isAdmin {
                    Section("Household") {
                        ForEach(model.appUsers) { user in
                            householdRow(user, me: me)
                        }
                        ForEach(model.unclaimed) { person in
                            HStack {
                                Text(person.name).foregroundStyle(.secondary)
                                Spacer(minLength: 8)
                                Button("Add \(person.name)…") { model.sheet = .add(person) }
                            }
                        }
                    }
                }
                if let error = model.error {
                    Section { InlineBanner(.error, error) }
                }
            }
        }
        .formStyle(.grouped)
        .frame(height: 520)
        .task {
            model.userChanged(to: session.currentUser?.id)
            await model.load()
        }
        .onChange(of: session.currentUser?.id) { _, id in
            model.userChanged(to: id)
            Task { await model.discardEdits() }
        }
        // Touch ID turned on from the offer after signing in.
        .onChange(of: session.afterSignIn) { Task { await model.load() } }
        .sheet(item: $model.sheet) { sheet in
            sheetView(sheet)
        }
        .confirmationDialog("Regenerate your recovery key?", isPresented: $model.confirmingRegenerate) {
            Button("Regenerate") { Task { await model.regenerateRecoveryKey() } }
        } message: {
            Text("The old key stops working. The new one is shown once.")
        }
        .confirmationDialog("Remove \(model.removing?.displayName ?? "")?", isPresented: Binding(
            get: { model.removing != nil }, set: { if !$0 { model.removing = nil } })) {
            Button("Remove", role: .destructive) {
                if let user = model.removing { Task { await model.remove(user) } }
            }
        } message: {
            Text("They can't sign in to Mango on this Mac any more, and their name goes from the imports and rules they confirmed.")
        }
    }

    private func householdRow(_ user: AppUser, me: AppUser) -> some View {
        let isMe = user.id == me.id
        let hasPassword = user.id.map(model.withPassword.contains) ?? false
        return HStack(spacing: 10) {
            UserAvatar(name: user.displayName, size: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(user.displayName).lineLimit(1)
                Text(isMe ? "You" : hasPassword ? "Can sign in on this Mac" : "No password on this Mac")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if user.isAdmin {
                StatusPill("Admin", tone: .accent)
            }
            if !isMe {
                Menu {
                    if !user.isAdmin {
                        Button("Make admin") { Task { await model.makeAdmin(user) } }
                    }
                    if hasPassword {
                        Button("Reset password…") { model.sheet = .reset(user) }
                    }
                    Divider()
                    Button("Remove…", role: .destructive) { model.removing = user }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("More for \(user.displayName)")
                .accessibilityLabel("More for \(user.displayName)")
            }
        }
    }

    @ViewBuilder private func sheetView(_ sheet: SignInSettingsModel.Sheet) -> some View {
        switch sheet {
        case .changePassword:
            PasswordSheet(title: "Change password", subtitle: "Your new password works from the next time Mango locks.") {
                try await model.changePassword($0)
            }
        case .reset(let user):
            PasswordSheet(title: "Reset \(user.displayName)'s password",
                          subtitle: "Tell \(user.displayName) the new password. Their recovery key doesn't change.") {
                try await model.resetPassword(of: user, to: $0)
            }
        case .add(let person):
            PasswordSheet(title: "Add \(person.name)", subtitle: "\(person.name) chooses their own password.", saveTitle: "Add", closesOnSave: false) {
                try await model.add(person, password: $0)
            }
        case .recoveryKey(let key, let owner):
            RecoveryKeySheet(key: key, ownerName: owner) { model.sheet = nil }
        }
    }
}

/// A new password typed twice; Save hashes it off the main thread and closes the sheet.
struct PasswordSheet: View {
    let title: String
    var subtitle: String? = nil
    var saveTitle = "Save"
    /// False when saving swaps the sheet for another (adding someone shows their recovery key).
    var closesOnSave = true
    let onSave: (String) async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var password = ""
    @State private var confirmation = ""
    @State private var error: String?
    @State private var isWorking = false

    private var canSave: Bool { PasswordStrength.assess(password).isAcceptable && password == confirmation && !isWorking }

    var body: some View {
        SheetScaffold(title: title, subtitle: subtitle, error: error, width: SheetMetrics.compactWidth,
                      onCancel: { dismiss() },
                      primary: SheetAction(saveTitle, isEnabled: canSave) { save() }) {
            NewPasswordFields(password: $password, confirmation: $confirmation)
        }
    }

    private func save() {
        isWorking = true
        error = nil
        let password = self.password
        Task {
            defer { isWorking = false }
            do {
                try await onSave(password)
                if closesOnSave { dismiss() }
            } catch {
                self.error = SignInErrorText.describe(error)
            }
        }
    }
}
