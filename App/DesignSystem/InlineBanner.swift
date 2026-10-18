// App/DesignSystem/InlineBanner.swift
import SwiftUI

/// A message inside a screen (spec §1.2, C9): an icon in the style's colour, `.callout`
/// text, an optional trailing action and an optional ✕; 8 pt padding on 10% of the colour,
/// corner 8. Replaces the screens' own banner copies.
struct InlineBanner<Content: View, Action: View>: View {
    enum Style {
        case info, success, warning, error
    }

    let style: Style
    var onDismiss: (() -> Void)?
    let content: Content
    let action: Action
    @Environment(\.theme) private var theme

    init(_ style: Style, onDismiss: (() -> Void)? = nil, @ViewBuilder action: () -> Action,
         @ViewBuilder content: () -> Content) {
        self.style = style
        self.onDismiss = onDismiss
        self.content = content()
        self.action = action()
    }

    private var tint: Color {
        switch style {
        // Not the accent: some themes' accent is a warm colour that would read as a warning.
        case .info: return .secondary
        case .success: return theme.income
        case .warning: return theme.pending
        case .error: return theme.expense
        }
    }

    private var systemImage: String {
        switch style {
        case .info: return "info.circle.fill"
        case .success: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        }
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: systemImage).foregroundStyle(tint).accessibilityHidden(true)
            content
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            action.font(.callout)
            if let onDismiss {
                Button(action: onDismiss) { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Dismiss")
                    .accessibilityLabel("Dismiss")
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(tint.opacity(0.1)))
    }
}

extension InlineBanner where Action == EmptyView {
    /// A banner without an action.
    init(_ style: Style, onDismiss: (() -> Void)? = nil, @ViewBuilder content: () -> Content) {
        self.init(style, onDismiss: onDismiss, action: { EmptyView() }, content: content)
    }
}

extension InlineBanner where Content == Text, Action == EmptyView {
    /// A banner with plain text.
    init(_ style: Style, _ text: String, onDismiss: (() -> Void)? = nil) {
        self.init(style, onDismiss: onDismiss) { Text(text) }
    }
}
