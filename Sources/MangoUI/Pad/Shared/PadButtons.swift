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
        let shape = RoundedRectangle(cornerRadius: MangoRadius.control, style: .continuous)
        configuration.label
            .mangoFont(size == .small ? .subheadline : .body, weight: .semibold)
            .lineLimit(1)
            .padding(.horizontal, role == .textLink ? 4 : (size == .small ? 12 : 16))
            .frame(minWidth: size.minimumTapTarget, minHeight: size.minimumTapTarget)
            .foregroundStyle(foreground)
            .background(background, in: shape)
            // Secondary: surface, accent text, a hairline (none in Flat, where the surface step does it).
            .overlay { if role == .secondary, MangoEdgeRules.drawsDividers(theme.edges) { shape.strokeBorder(theme.separator) } }
            .contentShape(shape)
            .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.4)
    }

    private var foreground: Color {
        switch role {
        case .primary: theme.onAccent
        case .secondary, .textLink: theme.accent
        case .destructive: theme.expense
        }
    }

    private var background: Color {
        switch role {
        case .primary: theme.accent
        case .secondary: theme.surface
        case .textLink: .clear
        case .destructive: theme.expenseTint
        }
    }
}

extension ButtonStyle where Self == PadButtonStyle {
    static func pad(_ role: PadButtonRole = .secondary, size: PadButtonSize = .regular) -> PadButtonStyle {
        PadButtonStyle(role: role, size: size)
    }
}
