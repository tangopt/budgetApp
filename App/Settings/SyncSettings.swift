// App/Settings/SyncSettings.swift
import SwiftUI
import BudgetCore

/// Settings ▸ Sync (plan step 4 Task 13). The status line through `SyncStatusCopy` (the phone's words). The real
/// database never syncs in this build, so it reads "Sync is off" with a sentence saying when that changes, and no
/// switch: the switch comes with the user's go. Only a DEBUG `--sync-demo` launch on the demo database shows a
/// live status, the last sync's counts and "Sync now".
struct SyncSettings: View {
    @ObservedObject private var current = AppEnvironment.Current.shared

    var body: some View {
        if let environment = current.environment {
            LiveSyncSettings(environment: environment)
        } else {
            SyncSettingsPane(status: .off, isRunning: false, report: nil, onSyncNow: nil)
        }
    }
}

private struct LiveSyncSettings: View {
    @ObservedObject var environment: AppEnvironment

    var body: some View {
        SyncSettingsPane(status: environment.syncStatus, isRunning: environment.isSyncRunning,
                         report: environment.syncLastReport, onSyncNow: syncNow)
    }

    private var syncNow: (@MainActor () async -> Void)? {
        guard environment.isSyncRunning else { return nil }
        let environment = environment
        return { await environment.syncNow() }
    }
}

/// The pane itself, from values (snapshot routes pass their own).
struct SyncSettingsPane: View {
    static let offExplanation = "Sync for your data turns on in a later step."

    let status: SyncStatus
    let isRunning: Bool
    let report: SyncReport?
    /// "Sync now"; nil hides the button (sync is off here).
    let onSyncNow: (@MainActor () async -> Void)?

    @Environment(\.theme) private var theme
    @State private var syncing = false

    var body: some View {
        Form {
            LabeledContent("Status:") {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    let line = SyncStatusCopy.text(status, now: context.date)
                    Text(line.text)
                        .foregroundStyle(line.tone == .amber ? theme.pending : Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let detail = SyncStatusCopy.detail(status) {
                LabeledContent("Details:") {
                    Text(detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            if isRunning {
                if let report {
                    LabeledContent("Last sync:") {
                        Text(counts(report)).figureText()
                    }
                }
                LabeledContent("") {
                    Button {
                        guard let onSyncNow, !syncing else { return }
                        syncing = true
                        Task { @MainActor in
                            await onSyncNow()
                            syncing = false
                        }
                    } label: {
                        Text(syncing ? "Syncing…" : "Sync now")
                    }
                    .disabled(syncing || onSyncNow == nil)
                }
                Text("Demo database only (Debug build, --sync-demo): records go to the Development container, sealed under the demo household key.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(Self.offExplanation)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, 8)
    }

    private func counts(_ report: SyncReport) -> String {
        "received \(report.pull.received) · sent \(report.push.saved) · refused \(report.push.refused)"
    }
}
