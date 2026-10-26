// App/Sync/SidebarSyncRow.swift
import SwiftUI
import BudgetCore

/// The small sync line at the foot of the main window's sidebar, above who is signed in (sync-ui, 2026-10-26): shown
/// only while the real sync is on (`SyncSidebarStatus`). Syncing: a spinner and "Syncing…", during the first upload
/// "1,248 of 3,006" and a thin bar; up to date: "Synced 2 min ago"; offline: "Sync paused"; anything to look at:
/// a warning glyph and "Sync needs attention", which opens Settings ▸ Sync. It follows `RealSync`'s published status
/// and progress; it reads and writes nothing itself.
struct SidebarSyncRow: View {
    @ObservedObject var realSync: RealSync
    /// Snapshot routes show a state without a running sync.
    @Environment(\.sidebarSyncOverride) private var override

    private var row: SyncSidebarStatus? {
        override ?? SyncSidebarStatus.make(isRunning: realSync.isRunning, status: realSync.status, progress: realSync.progress,
                                           refusal: realSync.refusal)
    }

    var body: some View {
        if let row {
            SidebarSyncRowContent(row: row)
        }
    }
}

struct SidebarSyncRowContent: View {
    let row: SyncSidebarStatus
    @Environment(\.openSettings) private var openSettings
    @Environment(\.theme) private var theme

    var body: some View {
        if row.opensSettings {
            Button {
                SettingsNavigation.shared.show(.sync)
                openSettings()
            } label: {
                content.contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Open Settings ▸ Sync")
        } else {
            content
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .top, spacing: 6) {
                glyph
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    // Two lines at most in a narrow sidebar, never cut.
                    Text(row.text(now: context.date))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            // The first upload: a thin bar, then how far ("1,248 of 3,006").
            if let fraction = row.fraction {
                HStack(spacing: 6) {
                    ProgressView(value: fraction)
                        .progressViewStyle(.linear)
                        .controlSize(.mini)
                    if let detail = row.detail {
                        Text(detail)
                            .figureText()
                            .lineLimit(1)
                            .fixedSize()
                    }
                }
            }
        }
        .font(.caption)
        .foregroundStyle(row == .attention ? theme.pending : Color.secondary)
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var glyph: some View {
        switch row {
        case .syncing:
            ProgressView().controlSize(.mini)
        case .synced:
            Image(systemName: "checkmark.icloud")
        case .paused:
            Image(systemName: "pause.circle")
        case .attention:
            Image(systemName: "exclamationmark.triangle.fill")
        }
    }
}

private struct SidebarSyncOverrideKey: EnvironmentKey {
    static let defaultValue: SyncSidebarStatus? = nil
}

extension EnvironmentValues {
    /// A sync row state to show regardless of the real sync (snapshot routes only).
    var sidebarSyncOverride: SyncSidebarStatus? {
        get { self[SidebarSyncOverrideKey.self] }
        set { self[SidebarSyncOverrideKey.self] = newValue }
    }
}
