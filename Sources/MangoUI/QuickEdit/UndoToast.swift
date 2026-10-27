import SwiftUI
import BudgetCore

/// The toast at the foot of Quick sort: what was just done, with Undo while there is a way back. It stays six seconds
/// (`QuickEditModel.toastSeconds`), then goes by itself.
struct UndoToastView: View {
    let toast: UndoToast
    let onUndo: () -> Void
    @Environment(\.phoneTheme) private var theme

    var body: some View {
        HStack(spacing: 12) {
            Text(toast.message)
                .font(.callout)
                .lineLimit(2)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            if toast.canUndo {
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
