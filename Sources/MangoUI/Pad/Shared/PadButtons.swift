import SwiftUI

/// The iPad's one button system: primary (the page's main action), secondary, a text link, and destructive. Row actions
/// are icon buttons instead (`RowIconButton`).
enum PadButtonRole: CaseIterable, Sendable { case primary, secondary, textLink, destructive }

enum PadButtonSize: Sendable {
    case regular
    /// For dense rows.
    case small

    /// The least height and width a tap lands on, in points.
    var minimumTapTarget: CGFloat { self == .regular ? 44 : 36 }
}

struct PadButtonStyle: ButtonStyle {
    /// No regular button is smaller than this.
    static let minimumTapTarget: CGFloat = 44

    var role: PadButtonRole = .secondary
    var size: PadButtonSize = .regular
    @Environment(\.phoneTheme) private var theme
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        configuration.label
            .mangoFont(size == .small ? .subheadline : .body, weight: .semibold)
            .lineLimit(1)
            .padding(.horizontal, role == .textLink ? 4 : (size == .small ? 12 : 16))
            .frame(minWidth: size.minimumTapTarget, minHeight: size.minimumTapTarget)
            .foregroundStyle(foreground)
            .background(background, in: shape)
            .overlay { if role == .secondary { shape.strokeBorder(Color.secondary.opacity(0.35)) } }
            .contentShape(shape)
            .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.4)
    }

    private var foreground: Color {
        switch role {
        case .primary: .white
        case .secondary, .textLink: theme.accent
        case .destructive: .red
        }
    }

    private var background: Color {
        switch role {
        case .primary: theme.accent
        case .secondary: Color.secondary.opacity(0.08)
        case .textLink: .clear
        case .destructive: Color.red.opacity(0.1)
        }
    }
}

extension ButtonStyle where Self == PadButtonStyle {
    static func pad(_ role: PadButtonRole = .secondary, size: PadButtonSize = .regular) -> PadButtonStyle {
        PadButtonStyle(role: role, size: size)
    }
}
