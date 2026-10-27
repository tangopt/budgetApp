// App/Settings/HouseholdSettings.swift
import AppKit
import CloudKit
import SwiftUI
import BudgetCore

/// Where the member stands, as the pane shows it.
enum HouseholdMemberState: Equatable {
    case notInvited, invited, joined, removed
}

/// Whether the household's share lets the joined member make changes (`HouseholdInvite.needsEditUpgrade`).
enum HouseholdEdits: Equatable {
    /// Read-only (a 7a share): "Let … make changes" upgrades it, behind the invite's gate.
    case waiting
    case allowed
}

/// What the pane shows (values only: the live controller and the snapshot routes both build one).
struct HouseholdPaneState: Equatable {
    /// The member's name; nil: nobody added yet (the add form).
    var member: String?
    var status: HouseholdMemberState = .notInvited
    /// People already in Mango without a user (a pick instead of a new name).
    var unclaimed: [String] = []
    /// Why the invite can't go yet (`HouseholdCopy.blocker`), one line each.
    var blockers: [String] = []
    /// More than one person accepted (`HouseholdCopy.ambiguousParticipants`).
    var ambiguous: String?
    /// Her device's request: the 6-digit code to compare ("123 456").
    var keyCode: String?
    /// The Mac isn't answering her requests for a while.
    var locked = false
    /// Joined (step 8): whether the share lets her make changes yet; nil when she hasn't joined.
    var edits: HouseholdEdits?
    /// Joined: what she can do, area by area, as saved (`PermissionGrid`); nil: no grid shown.
    var grid: PermissionGrid?
    var busy = false
    /// What's running, in plain words ("Checking the household…"), while the buttons wait.
    var progress: String?
    var error: String?

    static let empty = HouseholdPaneState()
}

/// What the pane can do; the live controller fills these in. Snapshot routes pass none.
struct HouseholdActions {
    var add: (_ unclaimedIndex: Int?, _ name: String) -> Void = { _, _ in }
    var invite: () -> Void = {}
    var allowEdits: () -> Void = {}
    var remove: () -> Void = {}
    var give: () -> Void = {}
    var notNow: () -> Void = {}
    var saveGrid: (PermissionGrid) -> Void = { _ in }
}

/// Settings ▸ Household (admin only): add the person, invite her to the household's share, give her device the key,
/// remove her.
struct HouseholdSettings: View {
    @ObservedObject private var current = AppEnvironment.Current.shared

    var body: some View {
        if let environment = current.environment {
            LiveHouseholdSettings(controller: environment.realSync.household)
                .id(ObjectIdentifier(environment))
        } else {
            Text("Open Mango's window first.")
                .font(.callout).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 200)
        }
    }
}

private struct LiveHouseholdSettings: View {
    @ObservedObject var controller: HouseholdController
    @State private var presenter = HouseholdSharePresenter()

    var body: some View {
        HouseholdPane(state: controller.state, actions: controller.actions, shareAnchor: presenter.anchor)
            .onAppear {
                // The controller shows the sheet itself once the share is ready (no state round trip through the view).
                let presenter = presenter
                controller.presenter = { prompt in presenter.present(prompt) }
            }
            .onDisappear { controller.presenter = nil }
            .task {
                // Reads at once, then every few seconds while the pane is open (a request from her device appears).
                while !Task.isCancelled {
                    await controller.refresh(contactCloud: true)
                    try? await Task.sleep(for: .seconds(5))
                }
            }
    }
}

/// Shows the system share sheet for the household's share (read-write, specific people only), pointing at the
/// "Invite…" button. The picker is kept while it shows.
@MainActor
final class HouseholdSharePresenter {
    let anchor = ShareAnchor()
    private var picker: NSSharingServicePicker?

    /// False when there's no window to show it in (the pane says so).
    func present(_ prompt: HouseholdController.SharePrompt) -> Bool {
        guard let view = Self.target(anchor: anchor.view, fallback: NSApp.keyWindow ?? NSApp.mainWindow),
              let window = view.window else { return false }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        let provider = NSItemProvider()
        provider.registerCKShare(prompt.share, container: prompt.container,
                                 allowedSharingOptions: CKAllowedSharingOptions(allowedParticipantPermissionOptions: .readWrite,
                                                                                allowedParticipantAccessOptions: .specifiedRecipientsOnly))
        let picker = NSSharingServicePicker(items: [provider])
        self.picker = picker
        picker.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
        return true
    }

    /// The view the sheet points at: the anchor when it's on screen with a size, else the window's content view.
    static func target(anchor: NSView?, fallback: NSWindow?) -> NSView? {
        if let anchor, anchor.window != nil, !anchor.bounds.isEmpty { return anchor }
        return (anchor?.window ?? fallback)?.contentView
    }
}

/// The view the share sheet points at.
final class ShareAnchor { weak var view: NSView? }

private struct ShareAnchorView: NSViewRepresentable {
    let anchor: ShareAnchor
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        anchor.view = view
        return view
    }
    func updateNSView(_ view: NSView, context: Context) { anchor.view = view }
}

/// The pane itself, from values.
struct HouseholdPane: View {
    let state: HouseholdPaneState
    var actions = HouseholdActions()
    /// Where the share sheet points (the live pane's "Invite…"); snapshot routes pass none.
    var shareAnchor: ShareAnchor?

    /// Snapshot routes pass a draft already edited; otherwise it starts as the saved grid.
    init(state: HouseholdPaneState, actions: HouseholdActions = HouseholdActions(), draft: PermissionGrid? = nil,
         shareAnchor: ShareAnchor? = nil) {
        self.state = state
        self.actions = actions
        self.shareAnchor = shareAnchor
        _draft = State(initialValue: draft ?? state.grid)
    }

    @Environment(\.theme) private var theme
    /// The grid being edited; nothing is saved until Save.
    @State private var draft: PermissionGrid?
    @State private var name = ""
    @State private var pick: Int?
    @State private var confirmsRemove = false

    var body: some View {
        Form {
            if let member = state.member {
                memberSection(member)
            } else {
                addSection
            }
            if let error = state.error {
                LabeledContent("") {
                    Text(error).foregroundStyle(theme.pending).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .formStyle(.grouped)
        .reportsScrollContentHeight()
        // The saved grid changed (loaded, saved, another member): the draft starts again from it.
        .onChange(of: state.grid) { _, grid in draft = grid }
        .confirmationDialog(HouseholdCopy.removeTitle(state.member ?? ""), isPresented: $confirmsRemove, titleVisibility: .visible) {
            Button("Remove", role: .destructive) { actions.remove() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(HouseholdCopy.removeMessage)
        }
    }

    // MARK: Add

    private var addSection: some View {
        Section(HouseholdCopy.addTitle) {
            if !state.unclaimed.isEmpty {
                Picker("Person:", selection: $pick) {
                    Text(HouseholdCopy.newPerson).tag(Int?.none)
                    ForEach(Array(state.unclaimed.enumerated()), id: \.offset) { index, person in
                        Text(person).lineLimit(1).truncationMode(.middle).tag(Int?.some(index))
                    }
                }
            }
            if pick == nil {
                TextField(HouseholdCopy.addField + ":", text: $name)
            }
            LabeledContent("") {
                Button(HouseholdCopy.addButton) { actions.add(pick, name) }
                    .disabled(state.busy || (pick == nil && name.trimmingCharacters(in: .whitespaces).isEmpty))
            }
        }
    }

    // MARK: Member

    @ViewBuilder private func memberSection(_ member: String) -> some View {
        Section {
            LabeledContent("Member:") {
                Text(member).lineLimit(1).truncationMode(.middle)
            }
            LabeledContent("Status:") {
                Text(statusLine).foregroundStyle(state.status == .removed ? theme.pending : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if state.status == .notInvited || state.status == .removed {
                LabeledContent("") {
                    Text(HouseholdCopy.inviteExplainer(member)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            if let ambiguous = state.ambiguous {
                LabeledContent("") {
                    Text(ambiguous).foregroundStyle(theme.pending).fixedSize(horizontal: false, vertical: true)
                }
            }
            if let edits = state.edits {
                editsRow(member, edits)
            }
            if !state.blockers.isEmpty && state.edits != .waiting {
                LabeledContent("Not yet:") {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(state.blockers.enumerated()), id: \.offset) { _, line in
                            Text(line.figuresUnbroken).foregroundStyle(theme.pending).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            LabeledContent("") {
                HStack {
                    if state.status != .joined {
                        Button(HouseholdCopy.inviteButton) { actions.invite() }
                            .disabled(state.busy)
                            .background { if let shareAnchor { ShareAnchorView(anchor: shareAnchor) } }
                    }
                    if state.status == .invited || state.status == .joined {
                        Button(HouseholdCopy.removeButton) { confirmsRemove = true }.disabled(state.busy)
                    }
                }
            }
            if let progress = state.progress {
                LabeledContent("") {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text(progress).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        if state.status == .joined, let saved = state.grid, let draft {
            PermissionGridView(
                grid: draft, original: saved,
                onChange: { area, level in
                    guard let index = draft.rows.firstIndex(where: { $0.area == area }) else { return }
                    self.draft?.rows[index].level = level
                },
                onReset: { self.draft = draft.resetToDefaults() },
                onSave: { actions.saveGrid(draft) },
                onCancel: { self.draft = saved },
                busy: state.busy)
        }
        if let code = state.keyCode {
            keyRequest(member, code)
        } else if state.locked {
            Section {
                Text(HouseholdCopy.tooManyAttempts).foregroundStyle(theme.pending).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Joined: whether she can make changes; while the share is read-only, why the upgrade can't go yet (its blockers)
    /// and the button that upgrades it. Nothing upgrades without that press.
    @ViewBuilder private func editsRow(_ member: String, _ edits: HouseholdEdits) -> some View {
        LabeledContent("Changes:") {
            switch edits {
            case .allowed:
                Text(HouseholdCopy.editsAllowed(member)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            case .waiting:
                VStack(alignment: .leading, spacing: 4) {
                    Text(HouseholdCopy.editsWaiting(member)).fixedSize(horizontal: false, vertical: true)
                    ForEach(Array(state.blockers.enumerated()), id: \.offset) { _, line in
                        Text(line.figuresUnbroken).foregroundStyle(theme.pending).fixedSize(horizontal: false, vertical: true)
                    }
                    Button(HouseholdCopy.allowEditsButton(member)) { actions.allowEdits() }
                        .disabled(state.busy)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
        }
    }

    private var statusLine: String {
        switch state.status {
        case .notInvited: HouseholdCopy.status(.notInvited)
        case .invited: HouseholdCopy.status(.invited)
        case .joined: HouseholdCopy.status(.joined)
        case .removed: HouseholdCopy.removedStatus
        }
    }

    /// Her device is asking for the household key: the code, large, to compare with her screen.
    private func keyRequest(_ member: String, _ code: String) -> some View {
        Section {
            Text(HouseholdCopy.keyRequestTitle(member)).fixedSize(horizontal: false, vertical: true)
            Text(HouseholdCopy.keyRequestCheckLead)
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text(code)
                .font(.system(size: 40, weight: .semibold, design: .monospaced))
                .lineLimit(1).fixedSize()
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .accessibilityLabel(code)
            Text(HouseholdCopy.doTheseMatch).font(.headline).frame(maxWidth: .infinity)
            HStack {
                Spacer()
                Button(HouseholdCopy.notNowButton) { actions.notNow() }.disabled(state.busy)
                Button(HouseholdCopy.giveKeyButton) { actions.give() }.buttonStyle(.borderedProminent).disabled(state.busy)
                Spacer()
            }
        }
    }
}
