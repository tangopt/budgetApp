import SwiftUI
import BudgetCore

/// The first download, before this iPhone has pulled once (iPhone spec §3.9, sync spec §5.7): "Downloading the
/// household's records… <n> so far" (`SyncStatusCopy.firstDownload`). Documents aren't downloaded on the phone in
/// this step.
///
/// `waiting`: a sync found nothing to download yet (the household's zone isn't there): "Waiting for the household's
/// records from the Mac", tried again on the scheduler's timers. With `actions`, the ways out underneath: Settings,
/// Lock, Sync now (while sync runs here) and Try with demo data.
public struct FirstDownloadView: View {
    /// What the waiting screen offers.
    public struct WaitingActions {
        public let onSettings: () -> Void
        public let onLock: () -> Void
        /// Nil while sync is off here.
        public let onSyncNow: (() async -> Void)?
        public let onTryDemo: () -> Void

        public init(onSettings: @escaping () -> Void, onLock: @escaping () -> Void, onSyncNow: (() async -> Void)?,
                    onTryDemo: @escaping () -> Void) {
            self.onSettings = onSettings
            self.onLock = onLock
            self.onSyncNow = onSyncNow
            self.onTryDemo = onTryDemo
        }
    }

    public let received: Int
    public let waiting: Bool
    public let actions: WaitingActions?
    @Environment(\.phoneTheme) private var theme
    @State private var syncing = false

    public init(received: Int, waiting: Bool = false, actions: WaitingActions? = nil) {
        self.received = received
        self.waiting = waiting
        self.actions = actions
    }

    public var body: some View {
        VStack(spacing: 32) {
            message
            if waiting, let actions {
                buttons(actions)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.background.ignoresSafeArea())
    }

    private func buttons(_ actions: WaitingActions) -> some View {
        VStack(spacing: 12) {
            Button(action: actions.onTryDemo) {
                Label("Try with demo data", systemImage: "theatermasks")
                    .frame(maxWidth: .infinity, minHeight: 36)
            }
            .buttonStyle(.borderedProminent)
            if let onSyncNow = actions.onSyncNow {
                Button {
                    syncing = true
                    Task {
                        await onSyncNow()
                        syncing = false
                    }
                } label: {
                    Label("Sync now", systemImage: "arrow.triangle.2.circlepath")
                        .frame(maxWidth: .infinity, minHeight: 36)
                }
                .buttonStyle(.bordered)
                .disabled(syncing)
            }
            HStack(spacing: 12) {
                Button(action: actions.onSettings) {
                    Label("Settings", systemImage: "gearshape")
                        .frame(maxWidth: .infinity, minHeight: 36)
                }
                Button(action: actions.onLock) {
                    Label("Lock", systemImage: "lock")
                        .frame(maxWidth: .infinity, minHeight: 36)
                }
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: 360)
    }

    private var message: some View {
        VStack(spacing: 16) {
            if waiting {
                Image(systemName: "icloud.and.arrow.down")
                    .font(.system(size: 44))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            } else {
                ProgressView()
                    .controlSize(.large)
                    .accessibilityHidden(true)
            }
            Text((waiting ? SyncStatusCopy.firstDownloadWaiting : SyncStatusCopy.firstDownload(received: received)).figuresUnbroken)
                .font(.headline)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Text("This happens once; afterwards only changes come down.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}
