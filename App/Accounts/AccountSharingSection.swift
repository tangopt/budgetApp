// App/Accounts/AccountSharingSection.swift
import SwiftUI
import BudgetCore

/// The Sharing part of Edit account (sync-ui, 2026-10-26: sharing is set in the account itself): the owner (the
/// signed-in person or Joint; Joint is always Everything) and how much the other person sees. A change shows, before
/// Save, how many records it moves (counted off the main thread) and, when it lowers the level, that Mango can't recall
/// what the other person may already have; Hidden lists what still needs the account and can't be saved. Nothing is
/// written until the sheet's Save (`AccountSharing.apply`). Someone who can't change it sees it read-only.
@MainActor
final class AccountSharingDraft: ObservableObject {
    /// As loaded; nil until loaded, or when nobody is signed in (no section then).
    @Published private(set) var original: AccountSharing.State?
    @Published var owner: SharingSetup.Owner = .joint
    @Published var level: SharingLevel = .everything
    /// The pending change counted (nil while counting, or with no change).
    @Published private(set) var preview: AccountSharing.Preview?
    @Published private(set) var isCounting = false

    private var counting: Task<Void, Never>?

    /// The edited owner and level, when they differ from the account's.
    var change: (owner: SharingSetup.Owner, level: SharingLevel)? {
        guard let original, owner != original.owner || level != original.level else { return nil }
        return (owner, level)
    }

    /// Save may go: no change, or one counted (or whose count failed: Save checks again) that nothing blocks.
    var canSave: Bool { change == nil || (!isCounting && preview?.isBlocked != true) }

    func load(accountId: Int64, viewModel: AccountsViewModel) async {
        guard let state = await viewModel.sharingState(accountId) else { return }
        original = state
        owner = state.owner
        level = state.level
    }

    /// The owner picker: Joint locks the level to Everything; back to the person, the account's default level.
    func setJoint(_ joint: Bool) {
        guard let original else { return }
        let choice = original.choosing(joint: joint)
        owner = choice.owner
        level = (choice.owner == original.owner) ? original.level : choice.level
    }

    /// A choice made programmatically: Joint or not, then a level.
    struct Preset {
        var joint: Bool?
        var level: SharingLevel?
    }

    func apply(_ preset: Preset, viewModel: AccountsViewModel) {
        if let joint = preset.joint { setJoint(joint) }
        if let level = preset.level { self.level = level }
        recount(viewModel: viewModel)
    }

    /// Counts what the edited choice would move, off the main thread; a newer choice cancels the count.
    func recount(viewModel: AccountsViewModel) {
        counting?.cancel()
        preview = nil
        guard let original, let change else {
            isCounting = false
            return
        }
        isCounting = true
        counting = Task { [weak self] in
            let preview = await viewModel.sharingPreview(original.accountId, owner: change.owner, level: change.level)
            guard !Task.isCancelled, let self else { return }
            self.preview = preview
            self.isCounting = false
        }
    }
}

struct AccountSharingSection: View {
    @ObservedObject var draft: AccountSharingDraft
    let viewModel: AccountsViewModel

    var body: some View {
        if let state = draft.original {
            // One row (the sheet is already tall): who owns it, then how much the other person sees.
            LabeledContent(SharingCopy.sectionTitle) {
                HStack(spacing: 8) {
                    Picker(SharingCopy.ownerLabel, selection: Binding(get: { draft.owner == .joint }, set: { joint in
                        draft.setJoint(joint)
                        draft.recount(viewModel: viewModel)
                    })) {
                        Text(personChoice(state)).tag(false)
                        Text(SharingCopy.jointChoice).tag(true)
                    }
                    .pickerStyle(.segmented).prominentTint()
                    .fixedSize()
                    .disabled(!state.canChangeOwner)
                    .accessibilityLabel(SharingCopy.ownerLabel)
                    Picker(SharingCopy.levelLabel, selection: Binding(get: { draft.level }, set: { level in
                        draft.level = level
                        draft.recount(viewModel: viewModel)
                    })) {
                        ForEach(SharingLevel.allCases.reversed(), id: \.self) { level in
                            Text(level.title).tag(level)
                        }
                    }
                    .fixedSize()
                    .disabled(!state.canChangeLevel || draft.owner == .joint)
                    .accessibilityLabel(SharingCopy.levelLabel)
                }
                .sheetFieldNote(note(state))
            }
            if draft.change != nil {
                LabeledContent("") { changeDetail(state) }
            }
        }
    }

    /// The owner picker's person: the signed-in person, or the other person when the account is theirs.
    private func personChoice(_ state: AccountSharing.State) -> String {
        if case .person(let id) = state.owner, id != state.personId { return state.otherName }
        return state.ownerName.isEmpty ? SharingCopy.ownerLabel : state.ownerName
    }

    /// Why the pickers can't be used, or what Joint means.
    private func note(_ state: AccountSharing.State) -> String? {
        if draft.owner == .joint { return state.canChangeOwner || draft.change != nil ? SharingCopy.jointLevelNote : SharingCopy.notYoursJoint }
        if !state.canChangeLevel { return SharingCopy.notYours(owner: state.otherName) }
        return nil
    }

    @ViewBuilder
    private func changeDetail(_ state: AccountSharing.State) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let preview = draft.preview {
                if preview.isBlocked {
                    ForEach(Array(preview.blockers.enumerated()), id: \.offset) { _, blocker in
                        Label(SharingCopy.blocker(blocker), systemImage: "link")
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text(SharingCopy.blockedNote)
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    // Only when something moves zone (a lower level that keeps the records private moves none).
                    if state.isConfirmed, preview.affectedCount > 0 {
                        Text(SharingCopy.moves(count: preview.affectedCount)).figureText()
                    }
                    if preview.isLowering {
                        InlineBanner(.warning, SharingCopy.lowerWarning(otherName: state.otherName))
                    } else {
                        Text(SharingCopy.raiseNote(otherName: state.otherName))
                            .font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if !state.isConfirmed {
                        Text(SharingCopy.confirmsDefaultsNote)
                            .font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } else if draft.isCounting {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(SharingCopy.counting).font(.callout).foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
