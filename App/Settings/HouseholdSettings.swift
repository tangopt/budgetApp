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
    var busy = false
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
    @State private var anchor = ShareAnchor()

    var body: some View {
        HouseholdPane(state: controller.state, actions: controller.actions)
            .background(ShareAnchorView(anchor: anchor))
            .task {
                // Reads at once, then every few seconds while the pane is open (a request from her device appears).
                while !Task.isCancelled {
                    await controller.refresh(contactCloud: true)
                    try? await Task.sleep(for: .seconds(5))
                }
            }
            .onChange(of: controller.sharePrompt) { _, prompt in
                guard let prompt else { return }
                controller.sharePrompt = nil
                present(prompt)
            }
    }

    /// The system share sheet for the household's share: read-write (step 8), specific people only.
    private func present(_ prompt: HouseholdController.SharePrompt) {
        guard let view = anchor.view else { controller.shareFailed(); return }
        let provider = NSItemProvider()
        provider.registerCKShare(prompt.share, container: prompt.container,
                                 allowedSharingOptions: CKAllowedSharingOptions(allowedParticipantPermissionOptions: .readWrite,
                                                                                allowedParticipantAccessOptions: .specifiedRecipientsOnly))
        NSSharingServicePicker(items: [provider]).show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
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

    @Environment(\.theme) private var theme
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
                        Button(HouseholdCopy.inviteButton) { actions.invite() }.disabled(state.busy)
                    }
                    if state.status == .invited || state.status == .joined {
                        Button(HouseholdCopy.removeButton) { confirmsRemove = true }.disabled(state.busy)
                    }
                }
            }
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
