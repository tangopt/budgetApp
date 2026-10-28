import SwiftUI
import BudgetCore

/// The sync status as one line, the words `SyncStatusCopy`'s (the one place the copy lives, in BudgetCore, tested):
/// secondary text, with amber's icon for what limits the data. Never red; waiting for the household key is neutral.
/// Home's empty state and Settings ▸ About show it.
public struct SyncStatusLine: View {
    public let status: SyncStatus
    public let now: Date
    @Environment(\.phoneTheme) private var theme

    public init(status: SyncStatus, now: Date) {
        self.status = status
        self.now = now
    }

    public var body: some View {
        let copy = SyncStatusCopy.text(status, now: now)
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: copy.tone == .amber ? "exclamationmark.triangle.fill" : "arrow.triangle.2.circlepath")
                .foregroundStyle(copy.tone == .amber ? theme.pending : Color.secondary)
                .accessibilityHidden(true)
            Text(copy.text.figuresUnbroken)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .mangoFont(.footnote)
        .accessibilityElement(children: .combine)
    }
}
