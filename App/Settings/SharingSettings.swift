// App/Settings/SharingSettings.swift
import SwiftUI
import Combine
import BudgetCore
import GRDB

/// Settings ▸ Sharing (sharing spec 2026-10-25 §3 goal 6; sync-ui 2026-10-26): My tax years and income (Everything;
/// Hidden not available yet), and a line pointing to Accounts, where each account's owner and level are set
/// (`AccountSharingSection`).
struct SharingSettings: View {
    /// Snapshot routes pass their own.
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
    /// Owners or a level changed (an account's Sharing section, the turn-on): the main window's screen on show reads its
    /// figures again.
    static let sharingChanged = Notification.Name("mango.sharingChanged")
}

@MainActor
final class SharingSettingsModel: ObservableObject {
    /// The signed-in person's tax-and-income level; nil while nobody is signed in.
    @Published private(set) var taxIncomeLevel: TaxIncomeLevel?
    /// Why the pane has nothing to show (signed out, sign-in not set up); nil when it does.
    @Published private(set) var unavailable: String?
    @Published var error: String?

    let dbQueue: DatabaseQueue

    init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
    }

    func load() async {
        do {
            guard let actor = try await dbQueue.loadSignedInActor() else {
                taxIncomeLevel = nil
                unavailable = SharingCopy.needsSignInSetUp
                return
            }
            taxIncomeLevel = try await dbQueue.read { db in try SharingOverview.load(actor: actor, db: db).taxIncomeLevel }
            unavailable = nil
        } catch is SignedOutWrite {
            // Locked: nothing is shown until someone signs in (the pane reloads then).
            taxIncomeLevel = nil
            unavailable = SharingCopy.needsSignIn
        } catch {
            self.error = (error as? SharingError).map(SharingCopy.error) ?? error.localizedDescription
        }
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
            if let level = model.taxIncomeLevel {
                Section {
                    HStack(spacing: 10) {
                        Text(SharingCopy.taxAndIncome).lineLimit(1)
                        Spacer(minLength: 8)
                        // Hidden can't be chosen yet (sharing spec §10): only Everything takes.
                        Picker(SharingCopy.taxAndIncome, selection: .constant(level)) {
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
            Section {
                Label {
                    Text(SharingCopy.accountsPointer).fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "building.columns")
                }
                .foregroundStyle(.secondary)
            }
            if let error = model.error {
                Section { InlineBanner(.error, error) }
            }
        }
        .formStyle(.grouped)
        .frame(height: 320)
        .task { await model.load() }
        // Someone else signed in, or the lock ended: the pane is theirs.
        .onReceive(AppEnvironment.Current.shared.environment?.session.$state.map(\.signedInId).removeDuplicates().dropFirst().eraseToAnyPublisher()
                   ?? Empty().eraseToAnyPublisher()) { _ in Task { await model.load() } }
    }
}
