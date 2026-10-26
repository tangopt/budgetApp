import SwiftUI
import BudgetCore

/// The lock badge on one of the viewer's own accounts shared below Everything (step 6; the Mac's `SharingBadge`):
/// a lock and `SharingCopy.badge`'s words, secondary. Wraps at large sizes rather than truncating.
public struct SharingBadgeView: View {
    let text: String

    public init(text: String) {
        self.text = text
    }

    /// The badge for `level`; nothing at Everything.
    public init?(level: SharingLevel) {
        guard let text = SharingCopy.badge(level) else { return nil }
        self.text = text
    }

    public var body: some View {
        Label {
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "lock.fill")
                .accessibilityHidden(true)
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .labelStyle(.titleAndIcon)
    }
}
