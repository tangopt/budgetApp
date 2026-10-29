import SwiftUI

/// The spacing scale the iPhone and iPad share (design review 2026-10-28 §3.3; it began as the iPad's `PadSpacing`):
/// 4 · 8 · 12 · 16 · 24 · 32, and the gaps named by use. Screens use these instead of their own numbers, so the two
/// devices line up.
public enum MangoSpacing {
    public static let xxs: CGFloat = 4
    public static let xs: CGFloat = 8
    public static let s: CGFloat = 12
    public static let m: CGFloat = 16
    public static let l: CGFloat = 24
    public static let xl: CGFloat = 32

    /// Between a page's sections (header and cards, a grid and the list under it).
    public static let section: CGFloat = l
    /// Between tiles and cards in a grid or a row.
    public static let tile: CGFloat = s
    /// A card's and tile's inner padding.
    public static let cardPadding: CGFloat = m
    /// The iPhone's leading and trailing screen margin (the iPad's page inset is `PadMetrics.pageInset`).
    public static let phoneGutter: CGFloat = m
}

/// Corner radii (§3.3), drawn with continuous corners; search fields are capsules.
public enum MangoRadius {
    /// Chips and pills.
    public static let chip: CGFloat = 8
    /// Controls: buttons, inputs, pickers.
    public static let control: CGFloat = 12
    /// Cards and tiles.
    public static let card: CGFloat = 16
    /// Sheets.
    public static let sheet: CGFloat = 24
}

/// Elevation (§3.3): cards sit flat on the background (e0); the side panel and floating tab bar (e1) and menus and
/// toasts (e2) cast a soft shadow in light mode. Dark mode lifts with lighter surfaces, not shadows.
public enum MangoElevation: Sendable {
    case e0, e1, e2

    /// The shadow's opacity, blur radius and downward offset in light mode.
    public var shadow: (opacity: Double, radius: CGFloat, y: CGFloat) {
        switch self {
        case .e0: (0, 0, 0)
        case .e1: (0.08, 24, 8)
        case .e2: (0.18, 40, 12)
        }
    }
}

extension View {
    /// The elevation's shadow, light mode only.
    public func mangoElevation(_ elevation: MangoElevation) -> some View {
        modifier(MangoElevationModifier(elevation: elevation))
    }
}

private struct MangoElevationModifier: ViewModifier {
    let elevation: MangoElevation
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let shadow = elevation.shadow
        content.shadow(color: .black.opacity(colorScheme == .dark ? 0 : shadow.opacity), radius: shadow.radius / 2, y: shadow.y)
    }
}
