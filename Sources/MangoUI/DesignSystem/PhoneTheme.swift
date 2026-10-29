import SwiftUI
import BudgetCore
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// A `ThemeCatalog` theme as the phone draws it: its colour roles (`ThemeRoles`, design review 2026-10-28 §3.1), each
/// a `Color` that resolves to the theme's light or dark value by the trait collection (iPhone spec §4: the same 15
/// themes as the Mac). Classic's grounds and text are system colours and are drawn as the iOS system colours (the
/// grouped backgrounds, the label colour), so Classic looks like a stock iOS app; its accent and money colours are
/// darkened in light mode, where the system's are under 4.5:1. Read it with `@Environment(\.phoneTheme)`.
public struct PhoneTheme: Identifiable, Sendable {
    public let palette: ThemePalette
    public var id: String { palette.id }
    public var name: String { palette.name }
    /// The roles' values, light and dark, for the contrast maths.
    public let lightRoles: ThemeRoles
    public let darkRoles: ThemeRoles

    // Grounds.
    /// Behind a screen's cards.
    public let background: Color
    /// A card's fill: cards, panels, rows.
    public let surface: Color
    /// Inside a card: tiles, category discs, thumbnails.
    public let surface2: Color
    /// Hairlines.
    public let separator: Color

    // Text.
    /// Primary text and figures.
    public let text: Color
    /// Detail lines and labels (≥ 4.5:1, unlike the system's `.secondary`).
    public let textSecondary: Color
    /// Placeholders and disabled hints.
    public let textTertiary: Color

    // Accent.
    /// Primary buttons, the selection bar, links, the controls' tint.
    public let accent: Color
    /// A label on an accent fill.
    public let onAccent: Color
    /// Selected rows, pickers, "to do".
    public let accentTint: Color
    /// Text on `accentTint`.
    public let accentTintText: Color

    // Status.
    public let income: Color
    public let expense: Color
    public let transfer: Color
    /// Amber: offline, pending, what limits the data.
    public let pending: Color
    /// Needs attention but isn't wrong: over pace, a missing document, a notice.
    public let warning: Color
    public let incomeTint: Color
    public let expenseTint: Color
    public let transferTint: Color
    public let pendingTint: Color
    public let warningTint: Color
    public let neutralMoney: Color

    /// The palette's theme with the roles derived from it.
    public init(_ palette: ThemePalette) {
        self.init(palette, light: palette.roles(.light), dark: palette.roles(.dark))
    }

    /// A theme from explicit roles (the theme sets, step 8, fill them directly).
    public init(_ palette: ThemePalette, light: ThemeRoles, dark: ThemeRoles) {
        self.palette = palette
        lightRoles = light
        darkRoles = dark
        func color(_ role: KeyPath<ThemeRoles, ThemeColor>) -> Color {
            Self.color(light: light[keyPath: role], dark: dark[keyPath: role])
        }
        background = color(\.background)
        surface = color(\.surface)
        surface2 = color(\.surface2)
        separator = color(\.separator)
        text = color(\.text)
        textSecondary = color(\.textSecondary)
        textTertiary = color(\.textTertiary)
        accent = color(\.accent)
        onAccent = color(\.onAccent)
        accentTint = color(\.accentTint)
        accentTintText = color(\.accentTintText)
        income = color(\.income)
        expense = color(\.expense)
        transfer = color(\.transfer)
        pending = color(\.pending)
        warning = color(\.warning)
        incomeTint = color(\.incomeTint)
        expenseTint = color(\.expenseTint)
        transferTint = color(\.transferTint)
        pendingTint = color(\.pendingTint)
        warningTint = color(\.warningTint)
        neutralMoney = Self.color(light: palette.light.neutralMoney, dark: palette.dark.neutralMoney)
    }

    /// The roles for a variant.
    public func roles(_ variant: ThemeVariant) -> ThemeRoles {
        variant == .light ? lightRoles : darkRoles
    }

    /// The colour an amount of this tone is drawn in.
    public func color(_ tone: MoneyTone) -> Color {
        switch tone {
        case .income: income
        case .expense: expense
        case .transfer: transfer
        case .neutral: neutralMoney
        }
    }

    public static let all: [PhoneTheme] = ThemePalette.all.map(PhoneTheme.init)
    public static let classic = PhoneTheme(ThemePalette.named(ThemePalette.defaultID))

    /// The theme with `id`, else Classic.
    public static func named(_ id: String) -> PhoneTheme {
        all.first { $0.id == id } ?? classic
    }

    // MARK: Token → Color

    /// One Color for a token's light and dark values: the system colour itself when both are the same system colour
    /// at the same opacity (Classic), else a dynamic colour.
    static func color(light: ThemeColor, dark: ThemeColor) -> Color {
        if let system = light.system, system == dark.system, light.alpha == dark.alpha {
            let base = systemColor(system)
            return light.alpha == 1 ? base : base.opacity(light.alpha)
        }
        if light.system == nil, dark.system == nil, light.alpha == 0, dark.alpha == 0 {
            return .clear
        }
        #if canImport(UIKit)
        return Color(uiColor: UIColor { traits in
            platformColor(traits.userInterfaceStyle == .dark ? dark : light)
        })
        #else
        return Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return platformColor(isDark ? dark : light)
        })
        #endif
    }

    private static func systemColor(_ system: ThemeColor.System) -> Color {
        switch system {
        case .accent: .accentColor
        case .label: .primary
        case .controlBackground, .windowBackground: systemBackground(system)
        case .green: .green
        case .red: .red
        case .blue: .blue
        case .orange: .orange
        case .teal: .teal
        case .purple: .purple
        case .pink: .pink
        case .brown: .brown
        case .indigo: .indigo
        case .mint: .mint
        case .gray: .gray
        case .yellow: .yellow
        }
    }

    /// iOS's grouped backgrounds: the screen's (`windowBackground`) and a card's (`controlBackground`).
    private static func systemBackground(_ system: ThemeColor.System) -> Color {
        #if canImport(UIKit)
        system == .windowBackground ? Color(uiColor: .systemGroupedBackground) : Color(uiColor: .secondarySystemGroupedBackground)
        #else
        system == .windowBackground ? Color(nsColor: .windowBackgroundColor) : Color(nsColor: .controlBackgroundColor)
        #endif
    }

    #if canImport(UIKit)
    private static func platformColor(_ token: ThemeColor) -> UIColor {
        guard let system = token.system else {
            return UIColor(red: token.red, green: token.green, blue: token.blue, alpha: token.alpha)
        }
        let base: UIColor = switch system {
        case .accent: .tintColor
        case .label: .label
        case .controlBackground: .secondarySystemGroupedBackground
        case .windowBackground: .systemGroupedBackground
        case .green: .systemGreen
        case .red: .systemRed
        case .blue: .systemBlue
        case .orange: .systemOrange
        case .teal: .systemTeal
        case .purple: .systemPurple
        case .pink: .systemPink
        case .brown: .systemBrown
        case .indigo: .systemIndigo
        case .mint: .systemMint
        case .gray: .systemGray
        case .yellow: .systemYellow
        }
        return token.alpha == 1 ? base : base.withAlphaComponent(token.alpha)
    }
    #else
    private static func platformColor(_ token: ThemeColor) -> NSColor {
        NSColor(srgbRed: token.red, green: token.green, blue: token.blue, alpha: token.effectiveAlpha)
    }
    #endif
}

extension EnvironmentValues {
    /// The phone's theme (Classic unless the app sets another).
    @Entry public var phoneTheme: PhoneTheme = .classic
}
