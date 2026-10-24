import SwiftUI
import BudgetCore
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// A `ThemeCatalog` theme as the phone draws it: the tokens the phone uses, each a `Color` that resolves to the
/// theme's light or dark value by the trait collection (iPhone spec §4: the same 15 themes as the Mac). Classic's
/// tokens are system colours and are drawn as the iOS system colours (`Color.green`, the grouped backgrounds), so
/// Classic looks like a stock iOS app. Read it with `@Environment(\.phoneTheme)`.
public struct PhoneTheme: Identifiable, Sendable {
    public let palette: ThemePalette
    public var id: String { palette.id }
    public var name: String { palette.name }

    public let accent: Color
    /// Behind a screen's cards.
    public let background: Color
    /// A card's fill.
    public let surface: Color
    public let income: Color
    public let expense: Color
    public let transfer: Color
    /// Amber: offline, pending, what limits the data.
    public let pending: Color
    public let neutralMoney: Color

    public init(_ palette: ThemePalette) {
        self.palette = palette
        let light = palette.light, dark = palette.dark
        func color(_ token: KeyPath<ThemeTokens, ThemeColor>) -> Color {
            Self.color(light: light[keyPath: token], dark: dark[keyPath: token])
        }
        accent = color(\.accent)
        // Classic has no background of its own (clear): the system's grouped background.
        let clearBackground = light.windowBackground.alpha == 0 && dark.windowBackground.alpha == 0
        background = clearBackground ? Self.systemBackground(.windowBackground) : color(\.windowBackground)
        surface = color(\.surface)
        income = Self.color(light: Self.incomeToken(palette, .light), dark: Self.incomeToken(palette, .dark))
        expense = color(\.expense)
        transfer = color(\.transfer)
        pending = color(\.pending)
        neutralMoney = color(\.neutralMoney)
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

    // MARK: Legible income

    /// The smallest contrast an income figure keeps against a card in light mode (ruling, fix round 1).
    public static let minimumLightIncomeContrast = 4.5

    /// A card's colour, opaque: the surface over the screen background over white (light) or black (dark).
    public static func opaqueSurface(_ palette: ThemePalette, _ variant: ThemeVariant) -> ThemeColor {
        let tokens = palette.tokens(variant)
        let base = ThemeColor.hex(variant == .light ? 0xFFFFFF : 0x000000)
        let screen = ColorMath.composite(tokens.windowBackground, over: base)
        return ColorMath.composite(tokens.surface, over: screen)
    }

    /// The income colour the phone draws: in light, the theme's income where it reaches 4.5:1 on a card, else a
    /// darker shade of it that does (Classic's system green is about 2.2:1 on white); in dark, the theme's own.
    public static func incomeToken(_ palette: ThemePalette, _ variant: ThemeVariant) -> ThemeColor {
        let income = palette.tokens(variant).income
        guard variant == .light else { return income }
        let card = opaqueSurface(palette, .light)
        let drawn = ColorMath.composite(income, over: card)
        guard ColorMath.contrastRatio(drawn, card) < minimumLightIncomeContrast else { return income }
        // A little past the minimum, so rounding to 8-bit channels can't land under it.
        let target = (ColorMath.relativeLuminance(card) + 0.05) / (minimumLightIncomeContrast + 0.1) - 0.05
        return ColorMath.shaded(drawn, toLuminance: target)
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
