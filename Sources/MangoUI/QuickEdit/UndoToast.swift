import SwiftUI
import BudgetCore

/// The toast at the foot of Quick sort: what was just done, with Undo while there is a way back. It stays six seconds
/// (`QuickEditModel.toastSeconds`), then goes by itself. The iPad's Checks shows the same toast after "Not expected any more".
struct UndoToastView: View {
    let message: String
    let canUndo: Bool
    let onUndo: () -> Void
    @Environment(\.phoneTheme) private var theme

    init(toast: UndoToast, onUndo: @escaping () -> Void) {
        self.init(message: toast.message, canUndo: toast.canUndo, onUndo: onUndo)
    }

    init(message: String, canUndo: Bool, onUndo: @escaping () -> Void) {
        self.message = message
        self.canUndo = canUndo
        self.onUndo = onUndo
    }

    var body: some View {
        HStack(spacing: 12) {
            Text(message)
                .font(.callout)
                .lineLimit(2)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            if canUndo {
                Button("Undo", action: onUndo)
                    .font(.callout.weight(.semibold))
                    .frame(minWidth: 44, minHeight: 44)
                    .accessibilityIdentifier("undo-button")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
        .frame(minHeight: 52)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.quaternary))
        .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("undo-toast")
    }
}
