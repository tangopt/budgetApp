// App/Auth/SetupFlowView.swift
import SwiftUI
import AppKit
import BudgetCore
import GRDB

/// First launch after the update (auth spec §6): pick who you are, choose a password and Touch ID, see the
/// recovery key once, then optionally add the other person (only for a shared macOS user, so "Later" is
/// the default). The new admin is signed in at the end.
@MainActor
final class SetupModel: ObservableObject {
    enum Step: Equatable {
        case who
        /// `owner` is nil for the new admin's own key.
        case recoveryKey(key: String, owner: String?)
        case offerOther(Person)
        case otherPassword(Person)
    }

    @Published var step: Step = .who
    @Published private(set) var people: [Person] = []
    @Published var personId: Int64?
    /// Nobody to pick (a new, empty database): the admin types their name and setup adds them as a person.
    @Published var newPersonName = ""
    @Published var password = ""
    @Published var confirmation = ""
    @Published var useTouchID = true
    @Published private(set) var isWorking = false
    @Published var error: String?

    let session: SessionModel
    let biometrics: any BiometricUnlocker
    private var admin: AppUser?
    /// Snapshot routes give their own people (possibly none); the app reads them.
    private var peopleLoaded = false

    init(session: SessionModel, biometrics: (any BiometricUnlocker)? = nil, people: [Person]? = nil) {
        self.session = session
        self.biometrics = biometrics ?? session.biometrics
        if let people {
            self.people = people
            personId = people.first?.id
            peopleLoaded = true
        }
    }

    private var trimmedNewName: String { newPersonName.trimmingCharacters(in: .whitespacesAndNewlines) }

    var touchIDAvailable: Bool { biometrics.isAvailable }
    var strength: PasswordStrength { PasswordStrength.assess(password) }
    var canCreate: Bool {
        let someone = people.isEmpty ? !trimmedNewName.isEmpty : personId != nil
        return someone && strength.isAcceptable && password == confirmation && !isWorking
    }

    func load() async {
        guard !peopleLoaded else { return }
        people = (try? await session.dbQueue.read { try AppUserStore.unclaimedPeople($0) }) ?? []
        peopleLoaded = true
        if personId == nil { personId = people.first?.id }
    }

    /// Step 1's Continue: the admin and their password (PBKDF2 off the main thread), Touch ID if chosen.
    func createAdmin() async {
        guard canCreate else { return }
        // A person picked, or (nobody to pick) the name typed, added as a person with the admin.
        let picked = people.first { $0.id == personId }
        guard picked != nil || people.isEmpty else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            let (user, key) = try await create(personId: picked?.id, name: picked?.name ?? trimmedNewName, isAdmin: true)
            admin = user
            if useTouchID && touchIDAvailable, let id = user.id {
                do { try await biometrics.enrol(appUserId: id) } catch {
                    self.error = "Couldn't turn on Touch ID: \(error.localizedDescription) You can turn it on in Settings ▸ Sign-in."
                }
            }
            step = .recoveryKey(key: key, owner: nil)
        } catch {
            self.error = SignInErrorText.describe(error)
        }
    }

    /// "I've saved it": the other person's offer after the admin's own key, otherwise done.
    func savedKey(owner: String?) async {
        error = nil
        if owner == nil, let other = (try? await session.dbQueue.read { try AppUserStore.unclaimedPeople($0) })?.first {
            step = .offerOther(other)
        } else {
            await finish()
        }
    }

    func addOther(_ person: Person) {
        password = ""; confirmation = ""; error = nil
        step = .otherPassword(person)
    }

    /// They typed their own password: they get their own recovery key, and the admin stays the one signed in.
    func createOther(_ person: Person) async {
        guard person.id != nil, strength.isAcceptable, password == confirmation, !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            let (_, key) = try await create(personId: person.id, name: person.name, isAdmin: false)
            step = .recoveryKey(key: key, owner: person.name)
        } catch {
            self.error = SignInErrorText.describe(error)
        }
    }

    func finish() async {
        guard let id = admin?.id else { return }
        do {
            try await session.signInAfterSetUp(appUserId: id)
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// `personId` nil: the person is added first, in the same transaction.
    private func create(personId: Int64?, name: String, isAdmin: Bool) async throws -> (AppUser, String) {
        let password = self.password
        let result = try await session.dbQueue.write { db in
            var id = personId
            if id == nil {
                var person = Person(name: name)
                try person.insert(db)
                id = person.id
            }
            guard let id else { throw AppUserStoreError.unknownPerson }
            return try AppUserStore.create(db, personId: id, displayName: name, password: password, isAdmin: isAdmin, now: Date())
        }
        self.password = ""; confirmation = ""
        return (result.0, result.recoveryKey)
    }

    #if SNAPSHOTS
    /// Snapshot routes only: a step with what would have been typed.
    func snapshotShow(_ step: Step, password: String = "") {
        self.step = step
        self.password = password
        confirmation = password
    }
    #endif
}

struct SetupFlowView: View {
    @StateObject private var model: SetupModel

    init(model: @autoclosure @escaping () -> SetupModel) {
        _model = StateObject(wrappedValue: model())
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                VStack(spacing: 10) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 72, height: 72)
                    Text("Set up Mango")
                        .font(.title2.weight(.semibold))
                }
                card
                    .frame(width: SheetMetrics.formWidth)
            }
            .padding(32)
            .frame(maxWidth: .infinity)
        }
        .defaultScrollAnchor(.center)
        .scrollBounceBehavior(.basedOnSize)
        .frame(minWidth: 560, maxWidth: .infinity, minHeight: 360, maxHeight: .infinity)
        .task { await model.load() }
    }

    @ViewBuilder private var card: some View {
        Group {
            switch model.step {
            case .who: whoStep
            case .recoveryKey(let key, let owner):
                VStack(alignment: .leading, spacing: SheetMetrics.spacing) {
                    // Touch ID that couldn't be turned on is said here, where the admin lands after Continue.
                    errorLine
                    RecoveryKeyContent(key: key, ownerName: owner) { Task { await model.savedKey(owner: owner) } }
                }
            case .offerOther(let person): offerStep(person)
            case .otherPassword(let person): otherPasswordStep(person)
            }
        }
        .padding(SheetMetrics.padding)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color(nsColor: .separatorColor)))
    }

    private var whoStep: some View {
        VStack(alignment: .leading, spacing: SheetMetrics.spacing) {
            Text("Who are you?").font(.headline)
            if model.people.isEmpty {
                Text("There's no one in this database yet. Type your name and Mango adds you.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                TextField("Your name", text: $model.newPersonName)
                    .textFieldStyle(.roundedBorder)
            } else {
                Picker("Who are you?", selection: $model.personId) {
                    ForEach(model.people) { person in
                        Text(person.name).tag(Optional(person.id!))
                    }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
            }
            Divider()
            Text("Choose a password").font(.headline)
            NewPasswordFields(password: $model.password, confirmation: $model.confirmation)
            if model.touchIDAvailable {
                Toggle("Use Touch ID on this Mac", isOn: $model.useTouchID)
            }
            errorLine
            HStack {
                Text("You'll be this Mac's admin.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 8)
                if model.isWorking { ProgressView().controlSize(.small) }
                Button("Continue") { Task { await model.createAdmin() } }
                    .buttonStyle(.borderedProminent).prominentTint()
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canCreate)
            }
            .padding(.top, 4)
        }
    }

    private func offerStep(_ person: Person) -> some View {
        VStack(alignment: .leading, spacing: SheetMetrics.spacing) {
            Text("Add \(person.name) now?").font(.headline)
            Text("Only if \(person.name) uses this same macOS user: they choose their own password now. If they have their own macOS user, they set up Mango there instead.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            errorLine
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button("Add") { model.addOther(person) }
                Button("Later") { Task { await model.finish() } }
                    .buttonStyle(.borderedProminent).prominentTint()
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 4)
        }
    }

    private func otherPasswordStep(_ person: Person) -> some View {
        VStack(alignment: .leading, spacing: SheetMetrics.spacing) {
            Text("Add \(person.name) now?").font(.headline)
            Text("\(person.name), choose your password.")
                .font(.callout).foregroundStyle(.secondary)
            NewPasswordFields(password: $model.password, confirmation: $model.confirmation)
            errorLine
            HStack(spacing: 8) {
                Button("Later") { Task { await model.finish() } }
                    .keyboardShortcut(.cancelAction)
                Spacer(minLength: 0)
                if model.isWorking { ProgressView().controlSize(.small) }
                Button("Add") { Task { await model.createOther(person) } }
                    .buttonStyle(.borderedProminent).prominentTint()
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.strength.isAcceptable || model.password != model.confirmation || model.isWorking)
            }
            .padding(.top, 4)
        }
    }

    @ViewBuilder private var errorLine: some View {
        if let error = model.error {
            InlineBanner(.error, error)
        }
    }
}
