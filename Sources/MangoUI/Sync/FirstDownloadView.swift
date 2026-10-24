import SwiftUI
import BudgetCore

/// The first download, before this iPhone has pulled once (iPhone spec §3.9, sync spec §5.7): "Downloading the
/// household's records… <n> so far" (`SyncStatusCopy.firstDownload`). Documents aren't downloaded on the phone in
/// this step.
public struct FirstDownloadView: View {
    public let received: Int
    @Environment(\.phoneTheme) private var theme

    public init(received: Int) {
        self.received = received
    }

    public var body: some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)
                .accessibilityHidden(true)
            Text(SyncStatusCopy.firstDownload(received: received).figuresUnbroken)
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
