import SwiftUI

/// The fixed vocabulary of actions inside list rows: the same icon for the same action everywhere.
enum RowAction: CaseIterable, Sendable {
    case openSite, linkDocument, check, email, notExpected, download

    var systemImage: String {
        switch self {
        case .openSite: "globe"
        case .linkDocument: "paperclip"
        case .check: "magnifyingglass"
        case .email: "envelope"
        case .notExpected: "bell.slash"
        case .download: "arrow.down.tray"
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .openSite: "Open site"
        case .linkDocument: "Link document"
        case .check: "Check"
        case .email: "Email"
        case .notExpected: "Not expected any more"
        case .download: "Download"
        }
    }

    /// The label naming the action and the item it acts on ("Link document, Gas bill").
    static func link(_ action: RowAction, item: String?) -> String {
        guard let item, !item.isEmpty else { return action.accessibilityLabel }
        return "\(action.accessibilityLabel), \(item)"
    }
}

/// An icon-only button for a row action: a 44 pt target (36 pt in dense rows), labelled for VoiceOver with the action
/// and the item, and a pointer hint.
struct RowIconButton: View {
    let action: RowAction
    var item: String?
    var size: PadButtonSize = .regular
    let perform: () -> Void
    @Environment(\.phoneTheme) private var theme

    init(_ action: RowAction, item: String? = nil, size: PadButtonSize = .regular, perform: @escaping () -> Void) {
        self.action = action
        self.item = item
        self.size = size
        self.perform = perform
    }

    static func targetSize(_ size: PadButtonSize) -> CGFloat { size.minimumTapTarget }

    var body: some View {
        Button(action: perform) {
            Image(systemName: action.systemImage)
                .font(.body.weight(.semibold))
                .foregroundStyle(theme.accent)
                .frame(width: Self.targetSize(size), height: Self.targetSize(size))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(RowAction.link(action, item: item))
        .help(action.accessibilityLabel)
    }
}
