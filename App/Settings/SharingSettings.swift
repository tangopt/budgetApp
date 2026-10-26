// App/Settings/SharingSettings.swift
import SwiftUI
import Combine
import BudgetCore
import GRDB

/// Settings ▸ Sharing (sharing spec 2026-10-25 §3 goal 6, §7). Before the ownership sheet: the explanation and, for
/// the admin, Set owners… (`OwnershipSheet`). Afterwards: My accounts (a level picker each; a change opens
/// `LevelChangeConfirm` and is made only on Change), Joint accounts (always Everything) and My tax years and income
/// (Everything; Hidden not available yet). A member sees their own sections and no Set owners….
struct SharingSettings: View {
    /// Snapshot routes pass their own (a copy of the demo before the sheet).
    var model: SharingSettingsModel? = nil
    @ObservedObject private var current = AppEnvironment.Current.shared

    var body: some View {
        if let model {
            SharingSettingsContent(model: model)
        } else if let environment = current.environment {
            SharingSettingsContent(model: SharingSettingsModel(dbQueue: environment.dbQueue))
                .id(ObjectIdentifier(environment.dbQueue))
        } else {
            Text("Open Mango's window first.")
                .font(.callout).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 200)
        }
    }
}

extension Notification.Name {
    /// Owners or a level changed (Settings ▸ Sharing): the main window's screen on show reads its figures again.
    static let sharingChanged = Notification.Name("mango.sharingChanged")
}

@MainActor
final class SharingSettingsModel: ObservableObject {
    @Published private(set) var overview: SharingOverview?
    /// Why the pane has nothing to show or change (signed out, sign-in not set up); nil when it does.
    @Published private(set) var unavailable: String?
    /// The admin's display name, the ownership sheet's owner choice.
    @Published private(set) var adminName = ""
    /// The ownership sheet's rows, while it is open (`SharingSetup.proposal`).
    @Published var ownershipRows: [SharingSetup.Row]?
    /// The level change being confirmed (`SharingLevelChangeFlow`: one at a time, Change only once counted).
    @Published private(set) var flow = SharingLevelChangeFlow()
    @Published var error: String?
    @Published private(set) var isWorking = false

    let dbQueue: DatabaseQueue

    init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
    }

    var pending: SharingLevelChangeFlow.Pending? { flow.pending }

    func load() async {
        do {
            guard let actor = try await dbQueue.loadSignedInActor() else {
                overview = nil
                unavailable = SharingCopy.needsSignInSetUp
                return
            }
            let (overview, adminName) = try await dbQueue.read { db in
                (try SharingOverview.load(actor: actor, db: db),
                 try String.fetchOne(db, sql: "SELECT displayName FROM appUser WHERE isAdmin = 1 ORDER BY id LIMIT 1") ?? "")
            }
            self.overview = overview
            self.adminName = adminName
            unavailable = nil
        } catch is SignedOutWrite {
            // Locked: nothing is shown or changed until someone signs in (the pane reloads then).
            overview = nil
            unavailable = SharingCopy.needsSignIn
        } catch {
            self.error = describe(error)
        }
    }

    // MARK: The ownership sheet

    func openOwnershipSheet() async {
        error = nil
        do {
            guard let actor = try await dbQueue.loadSignedInActor() else { throw SharingError.notAdmin }
            ownershipRows = try await dbQueue.read { db in try SharingSetup.proposal(admin: actor, db: db) }
        } catch {
            self.error = describe(error)
        }
    }

    /// All or nothing (`SharingSetup.save`); on success the sheet closes and the pane shows your accounts.
    func saveOwnership(_ rows: [SharingSetup.Row]) async throws {
        isWorking = true
        defer { isWorking = false }
        try await dbQueue.writeAsSignedInUser { db, actor in
            try SharingSetup.save(rows, admin: actor, db: db, now: Date())
        }
        ownershipRows = nil
        NotificationCenter.default.post(name: .sharingChanged, object: nil)
        await load()
    }

    // MARK: Changing a level

    /// Opens the confirmation, then counts the records to move off the main thread.
    func request(_ level: SharingLevel, for account: SharingOverview.AccountRow) {
        guard let id = flow.request(level, for: account) else { return }
        let accountId = account.id
        Task {
            do {
                let preview = try await dbQueue.read { db in try SharingOverview.preview(accountId: accountId, to: level, db: db) }
                flow.counted(preview, for: id)
            } catch {
                flow.failed(describe(error), for: id)
            }
        }
    }

    func confirmChange() async {
        guard let change = flow.beginChange() else { return }
        do {
            _ = try await dbQueue.writeAsSignedInUser { db, actor in
                try SharingLevels.set(change.level, accountId: change.accountId, actor: actor, db: db)
            }
            flow.changed(change.id)
            NotificationCenter.default.post(name: .sharingChanged, object: nil)
            await load()
        } catch {
            flow.failed(describe(error), for: change.id)
        }
    }

    func cancelChange() {
        flow.cancel()
    }

    private func describe(_ error: Error) -> String {
        if let error = error as? SharingError { return SharingCopy.error(error) }
        return error.localizedDescription
    }
}

struct SharingSettingsContent: View {
    @StateObject private var model: SharingSettingsModel

    init(model: @autoclosure @escaping () -> SharingSettingsModel) {
        _model = StateObject(wrappedValue: model())
    }

    var body: some View {
        Form {
            if let unavailable = model.unavailable {
                Section { Text(unavailable).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }
            if let overview = model.overview {
                if overview.isConfirmed {
                    confirmed(overview)
                } else {
                    Section {
                        Text(overview.isAdmin ? SharingCopy.setupExplanation : SharingCopy.waitingForOwners)
                            .fixedSize(horizontal: false, vertical: true)
                        if overview.canSetOwners {
                            HStack {
                                Spacer()
                                Button(SharingCopy.setOwnersButton) { Task { await model.openOwnershipSheet() } }
                                    .buttonStyle(.borderedProminent).prominentTint()
                            }
                        }
                    }
                }
            }
            if let error = model.error {
                Section { InlineBanner(.error, error) }
            }
        }
        .formStyle(.grouped)
        .frame(height: 520)
        .task { await model.load() }
        // Someone else signed in, or the lock ended: the pane is theirs.
        .onReceive(AppEnvironment.Current.shared.environment?.session.$state.map(\.signedInId).removeDuplicates().dropFirst().eraseToAnyPublisher()
                   ?? Empty().eraseToAnyPublisher()) { _ in Task { await model.load() } }
        .sheet(isPresented: Binding(get: { model.ownershipRows != nil }, set: { if !$0 { model.ownershipRows = nil } })) {
            if let rows = model.ownershipRows {
                OwnershipSheet(rows: rows, adminName: model.adminName, onSave: { try await model.saveOwnership($0) })
            }
        }
        .sheet(item: Binding(get: { model.pending }, set: { if $0 == nil { model.cancelChange() } })) { change in
            LevelChangeConfirm(change: change, otherName: model.overview?.otherName ?? SharingCopy.otherPersonFallback,
                               onCancel: { model.cancelChange() }, onChange: { Task { await model.confirmChange() } })
        }
    }

    @ViewBuilder
    private func confirmed(_ overview: SharingOverview) -> some View {
        Section {
            if overview.own.isEmpty {
                Text(SharingCopy.noOwnAccounts).foregroundStyle(.secondary)
            }
            ForEach(overview.own) { account in
                HStack(spacing: 10) {
                    accountName(account)
                    Spacer(minLength: 8)
                    Picker(SharingCopy.levelColumn, selection: Binding(get: { account.level }, set: { model.request($0, for: account) })) {
                        ForEach(SharingLevel.allCases.reversed(), id: \.self) { level in
                            Text(level.title).tag(level)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .accessibilityLabel("\(SharingCopy.levelColumn) \(account.displayName)")
                }
            }
        } header: {
            Text(SharingCopy.myAccounts)
        } footer: {
            Text(SharingCopy.myAccountsNote).font(.caption).foregroundStyle(.secondary)
        }
        if !overview.joint.isEmpty {
            Section {
                ForEach(overview.joint) { account in
                    HStack(spacing: 10) {
                        accountName(account)
                        Spacer(minLength: 8)
                        Text(SharingLevel.everything.title).foregroundStyle(.secondary).fixedSize()
                    }
                }
            } header: {
                Text(SharingCopy.jointAccounts)
            } footer: {
                Text(SharingCopy.jointAccountsNote).font(.caption).foregroundStyle(.secondary)
            }
        }
        Section {
            HStack(spacing: 10) {
                Text(SharingCopy.taxAndIncome).lineLimit(1)
                Spacer(minLength: 8)
                // Hidden can't be chosen yet (sharing spec §10): only Everything takes.
                Picker(SharingCopy.taxAndIncome, selection: .constant(overview.taxIncomeLevel)) {
                    Text(SharingLevel.everything.title).tag(TaxIncomeLevel.everything)
                    Text(SharingCopy.hiddenNotAvailable).tag(TaxIncomeLevel.hidden).selectionDisabled()
                }
                .labelsHidden()
                .fixedSize()
            }
        } footer: {
            Text(SharingCopy.taxAndIncomeNote).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func accountName(_ account: SharingOverview.AccountRow) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(account.displayName).lineLimit(1).truncationMode(.middle)
            if let bank = account.bankName, !bank.isEmpty {
                Text(bank).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
        }
    }
}
