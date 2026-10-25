import SwiftUI
import BudgetCore

/// The first download, before this iPhone has pulled once (iPhone spec §3.9, sync spec §5.7): "Downloading the
/// household's records… <n> so far" (`SyncStatusCopy.firstDownload`). Documents aren't downloaded on the phone in
/// this step.
///
/// `waiting`: a sync found nothing to download yet (the household's zone isn't there): "Waiting for the household's
/// records from the Mac", tried again on the scheduler's timers.
public struct FirstDownloadView: View {
    public let received: Int
    public let waiting: Bool
    @Environment(\.phoneTheme) private var theme

    public init(received: Int, waiting: Bool = false) {
        self.received = received
        self.waiting = waiting
    }

    public var body: some View {
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
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.background.ignoresSafeArea())
        .accessibilityElement(children: .combine)
    }
}
