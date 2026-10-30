import SwiftUI

/// The fixed vocabulary of actions inside list rows: the same icon for the same action everywhere.
enum RowAction: CaseIterable, Sendable {
    case openSite, linkDocument, check, email, notExpected, download, discard
    /// Step 10, Task 11 (controller ruling): the Bills & recharges row actions.
    case linkPayment, addToRecharge, markSent, recordPayment, view, unlink
    /// A card's or panel's edit (design review I5: card edits are icon buttons, not outlined text buttons).
    case edit

    var systemImage: String {
        switch self {
        case .openSite: "globe"
        case .linkDocument: "paperclip"
        case .check: "magnifyingglass"
        case .email: "envelope"
        case .notExpected: "bell.slash"
        case .download: "tray.and.arrow.down"
        case .discard: "trash"
        case .linkPayment: "link"
        case .addToRecharge: "doc.badge.plus"
        case .markSent: "paperplane"
        case .recordPayment: "checkmark.circle"
        case .view: "eye"
        // The Mac's unlink icon ("link.slash" is no SF Symbol: it drew nothing).
        case .unlink: "xmark.circle"
        case .edit: "pencil"
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
        case .discard: "Discard"
        case .linkPayment: "Link payment"
        case .addToRecharge: "Add to recharge"
        case .markSent: "Mark sent"
        case .recordPayment: "Record payment"
        case .view: "View"
        case .unlink: "Unlink"
        case .edit: "Edit"
        }
    }

    /// The label naming the action and the item it acts on ("Link document, Gas bill").
    /// Whether the icon is drawn in the destructive tint.
    var isDestructive: Bool { self == .discard || self == .unlink }

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
                .mangoFont(.body, weight: .semibold)
                .foregroundStyle(action.isDestructive ? theme.expense : theme.accent)
                .frame(width: Self.targetSize(size), height: Self.targetSize(size))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(RowAction.link(action, item: item))
        .help(action.accessibilityLabel)
    }
}
