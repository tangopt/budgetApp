// App/Settings/SyncSettings.swift
import SwiftUI
import BudgetCore

/// Settings ▸ Sync. The status line through `SyncStatusCopy` (the phone's words).
/// - The real database (step 6 Task 13): before the upload, "Sync is off", a sentence, and "Turn on sync…"
///   (`TurnOnSyncSheet`) when nothing blocks it or only what the person can clear does (`SyncTurnOnFlow.offersTurnOn`);
///   otherwise the blockers' copy. While the first upload runs, its progress and "Show upload…" (the sheet again).
///   Afterwards the live status, the last sync's counts and "Sync now". When sync can't run although it was turned on
///   (another iCloud user, say), why.
/// - A DEBUG `--sync-demo` launch on the demo database: its live status, the last sync's counts and "Sync now".
struct SyncSettings: View {
    @ObservedObject private var current = AppEnvironment.Current.shared

    var body: some View {
        if let environment = current.environment {
            LiveSyncSettings(environment: environment, realSync: environment.realSync)
                .id(ObjectIdentifier(environment))
        } else {
            SyncSettingsPane(status: .off, isRunning: false, report: nil, onSyncNow: nil)
        }
    }
}

private struct LiveSyncSettings: View {
    @ObservedObject var environment: AppEnvironment
    @ObservedObject var realSync: RealSync
    @StateObject private var turnOn: TurnOnSyncModelHolder = TurnOnSyncModelHolder()
    @State private var showsSheet = false

    var body: some View {
        pane
            .task {
                guard !environment.isSyncRunning else { return }
                await model.refresh()
            }
            .sheet(isPresented: $showsSheet, onDismiss: { Task { await model.refresh() } }) {
                TurnOnSyncSheet(model: model)
            }
    }

    @ViewBuilder private var pane: some View {
        if environment.isSyncRunning {
            // The DEBUG demo.
            SyncSettingsPane(status: environment.syncStatus, isRunning: true, report: environment.syncLastReport,
                             onSyncNow: syncNow, isDemo: true)
        } else {
            SyncSettingsPane(status: realSync.status, isRunning: realSync.isRunning, report: environment.syncLastReport,
                             onSyncNow: realSyncNow, real: summary, onTurnOn: { showsSheet = true })
        }
    }

    private var syncNow: @MainActor () async -> Void {
        let environment = environment
        return { await environment.syncNow() }
    }

    private var realSyncNow: (@MainActor () async -> Void)? {
        guard realSync.isRunning else { return nil }
        return syncNow
    }

    private var model: TurnOnSyncModel { turnOn.model(environment) }

    private var summary: SyncSettingsPane.Real {
        let facts = model.facts
        let screen = SyncTurnOnFlow.screen(facts)
        let stage = facts.progress.stage
        return SyncSettingsPane.Real(stage: stage,
                                     uploadLine: stage == .uploading ? screen.uploadLine : nil,
                                     refusal: stage == .done ? realSync.refusal : nil,
                                     blockerLines: SyncTurnOnFlow.offersTurnOn(stage: stage, blockers: facts.blockers) ? [] : screen.blockerLines,
                                     offersTurnOn: facts.work != .checking && SyncTurnOnFlow.offersTurnOn(stage: stage, blockers: facts.blockers))
    }
}

/// Keeps one sheet model per window's environment (made on first use).
@MainActor
private final class TurnOnSyncModelHolder: ObservableObject {
    private var made: TurnOnSyncModel?
    private var forwarding: Any?

    func model(_ environment: AppEnvironment) -> TurnOnSyncModel {
        if let made { return made }
        let model = TurnOnSyncModel(environment: environment)
        made = model
        forwarding = model.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        return model
    }
}

/// The pane itself, from values (snapshot routes pass their own).
struct SyncSettingsPane: View {
    /// The real database's turn-on, as the pane shows it.
    struct Real: Equatable {
        var stage: SyncTurnOn.Stage
        /// While the first upload runs: its progress line.
        var uploadLine: String?
        /// Why sync doesn't run although it was turned on.
        var refusal: String?
        /// Blockers the person can't clear here (no "Turn on sync…" then).
        var blockerLines: [String]
        var offersTurnOn: Bool
    }

    let status: SyncStatus
    let isRunning: Bool
    let report: SyncReport?
    /// "Sync now"; nil hides the button (sync is off here).
    let onSyncNow: (@MainActor () async -> Void)?
    var isDemo = false
    var real: Real? = nil
    var onTurnOn: (() -> Void)? = nil

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
            if let refusal = real?.refusal {
                LabeledContent("") {
                    Text(refusal).foregroundStyle(theme.pending).fixedSize(horizontal: false, vertical: true)
                }
            }
            if let line = real?.uploadLine {
                LabeledContent("First upload:") {
                    Text(line.figuresUnbroken).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
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
            }
            if isDemo {
                Text("Demo database only (Debug build, --sync-demo): records go to the Development container, sealed under the demo household key.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let real, real.stage < .done {
                if real.stage < .uploading {
                    Text(SyncTurnOnFlow.settingsOff)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !real.blockerLines.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(real.blockerLines, id: \.self) { line in
                            Text(line).foregroundStyle(theme.pending).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .font(.callout)
                }
                if real.offersTurnOn, let onTurnOn {
                    LabeledContent("") {
                        Button(real.stage >= .uploading ? SyncTurnOnFlow.settingsShowUpload : SyncTurnOnFlow.settingsButton, action: onTurnOn)
                    }
                }
            } else if real == nil {
                Text(SyncTurnOnFlow.settingsOff)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, 8)
        .reportsIdealHeight()
    }

    private func counts(_ report: SyncReport) -> String {
        "received \(report.pull.received) · sent \(report.push.saved) · refused \(report.push.refused)"
    }
}
