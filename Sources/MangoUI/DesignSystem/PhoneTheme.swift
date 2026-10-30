import SwiftUI
import BudgetCore
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// A theme set (`ThemeSet`, design review 2026-10-28 §3.5) as the phone and iPad draw it: its colour roles
/// (`ThemeRoles`), each a `Color` that resolves to the set's light or dark value by the trait collection. Classic's
/// grounds and primary text are the system's own and are drawn as the iOS system colours (the grouped backgrounds,
/// the label colour), so Classic looks like a stock iOS app. Read it with `@Environment(\.phoneTheme)`; the set's
/// fonts are `\.phoneFonts`, set beside it by the app (widgets keep the system font).
public struct PhoneTheme: Identifiable, Sendable {
    public let themeSet: ThemeSet
    public var id: String { themeSet.id }
    public var name: String { themeSet.name }
    /// The set's font pairing (what the app puts in `\.phoneFonts`).
    public var fonts: ThemeFontPairing { themeSet.fonts }
    /// Whether cards draw a border (Clear), nothing but surface steps (Flat), or neither.
    public var edges: ThemeSet.Edges { themeSet.edges }
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

    public init(_ themeSet: ThemeSet) {
        self.themeSet = themeSet
        let light = themeSet.light, dark = themeSet.dark
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
        // Zero and neutral amounts read as body text.
        neutralMoney = text
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

    /// The eight sets, in the picker's order.
    public static let all: [PhoneTheme] = ThemeSet.all.map(PhoneTheme.init)
    /// The default for new installs.
    public static let mango = PhoneTheme(.mango)
    public static let classic = PhoneTheme(.classic)

    /// The set with `id`, else Mango.
    public static func named(_ id: String) -> PhoneTheme {
        all.first { $0.id == id } ?? mango
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
    /// The phone's theme set (Mango, the default, unless the app sets another; the widgets read the app's choice
    /// from the App Group).
    @Entry public var phoneTheme: PhoneTheme = .mango
}
