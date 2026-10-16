// App/DesignSystem/Theme.swift
import SwiftUI
import AppKit
import BudgetCore

/// A colour theme as the views draw it: each `ThemePalette` token as a SwiftUI `Color` that
/// resolves to the light or dark variant by the effective appearance, so one value serves
/// both. Read it from the environment (`@Environment(\.theme)`); `ThemedRoot` injects the
/// chosen one (Settings ▸ Theme) at every window's root.
///
/// Classic's tokens are system colours and are drawn as exactly those (`Color.green`,
/// `Color.accentColor.opacity(0.08)`, …), so it is today's look.
struct Theme: Identifiable, Equatable, Sendable {
    let palette: ThemePalette
    var id: String { palette.id }
    var name: String { palette.name }

    let accent: Color
    let selectionOutline: Color
    let selectionFill: Color
    let noteMarker: Color
    let windowBackground: Color
    /// An opaque window-coloured fill (side panels, chart hover cards): the theme's
    /// background, or the system window colour where the theme has none (Classic).
    let windowFill: Color
    let surface: Color
    let gridHeaderBackground: Color
    let rowStripe: Color
    let groupRowTint: Color
    let sectionHeaderTint: Color
    let totalsTint: Color
    let totalsNetTint: Color
    let totalsStripe: Color
    let reserved: Color
    let reservedTint: Color
    let netWorthTint: Color
    let adjustment: Color
    let transfer: Color
    let income: Color
    let expense: Color
    let pending: Color
    let neutralMoney: Color
    let yoyGood: Color
    let yoyBad: Color
    let chartSeries: [Color]
    /// Classic: the accent is the system's, so the root sets no `.tint`.
    let usesSystemAccent: Bool

    init(_ palette: ThemePalette) {
        self.palette = palette
        let light = palette.light, dark = palette.dark
        func color(_ token: KeyPath<ThemeTokens, ThemeColor>) -> Color {
            Theme.color(light: light[keyPath: token], dark: dark[keyPath: token])
        }
        accent = color(\.accent)
        selectionOutline = color(\.selectionOutline)
        selectionFill = color(\.selectionFill)
        noteMarker = color(\.noteMarker)
        windowBackground = color(\.windowBackground)
        windowFill = light.windowBackground.alpha == 0 && dark.windowBackground.alpha == 0
            ? Color(nsColor: .windowBackgroundColor) : windowBackground
        surface = color(\.surface)
        gridHeaderBackground = color(\.gridHeaderBackground)
        rowStripe = color(\.rowStripe)
        groupRowTint = color(\.groupRowTint)
        sectionHeaderTint = color(\.sectionHeaderTint)
        totalsTint = color(\.totalsTint)
        totalsNetTint = color(\.totalsNetTint)
        totalsStripe = color(\.totalsStripe)
        reserved = color(\.reserved)
        reservedTint = color(\.reservedTint)
        netWorthTint = color(\.netWorthTint)
        adjustment = color(\.adjustmentsTint)
        transfer = color(\.transfer)
        income = color(\.income)
        expense = color(\.expense)
        pending = color(\.pending)
        neutralMoney = color(\.neutralMoney)
        yoyGood = color(\.yoyGood)
        yoyBad = color(\.yoyBad)
        let count = min(light.chartSeries.count, dark.chartSeries.count)
        chartSeries = (0..<count).map { Theme.color(light: light.chartSeries[$0], dark: dark.chartSeries[$0]) }
        usesSystemAccent = light.accent.system == .accent && dark.accent.system == .accent
    }

    static func == (lhs: Theme, rhs: Theme) -> Bool { lhs.id == rhs.id }

    /// The `appTheme` default: the chosen theme's id.
    static let storageKey = "appTheme"

    static let all: [Theme] = ThemePalette.all.map(Theme.init)
    static let classic = all.first { $0.id == ThemePalette.defaultID } ?? Theme(ThemePalette.named(ThemePalette.defaultID))

    /// The theme with `id`, else Classic.
    static func named(_ id: String) -> Theme {
        all.first { $0.id == id } ?? classic
    }

    // MARK: Role helpers

    /// Chart series `index` (wrapping): 0 is the Budget / the main line.
    func series(_ index: Int) -> Color {
        chartSeries[((index % chartSeries.count) + chartSeries.count) % chartSeries.count]
    }

    /// A body row's alternating shade.
    func rowBackground(_ shaded: Bool) -> Color { shaded ? rowStripe : Color.clear }

    /// A grid row's leading stripe and a category badge's colour, by type.
    func stripe(_ type: CategoryType) -> Color {
        switch type {
        case .income: return income
        case .expense: return expense
        case .transfer: return transfer
        case .adjustment: return adjustment
        }
    }

    /// A Totals row's background; Net a shade stronger.
    func totalsBackground(_ row: BudgetTotals.Row) -> Color {
        row == .net ? totalsNetTint : totalsTint
    }

    /// Money by sign: income for positive, expense for negative, neutral for zero.
    func money(_ sign: Int) -> Color {
        sign < 0 ? expense : (sign > 0 ? income : neutralMoney)
    }

    /// A change for the better or worse; secondary when neutral.
    func change(improvement: Bool?) -> Color {
        improvement.map { $0 ? yoyGood : yoyBad } ?? Color.secondary
    }

    // MARK: Token → Color

    /// One Color for a token's light and dark values: the system colour itself when both are
    /// the same system colour at the same opacity (Classic), else a dynamic colour.
    static func color(light: ThemeColor, dark: ThemeColor) -> Color {
        if let system = light.system, system == dark.system, light.alpha == dark.alpha {
            let base = systemColor(system)
            return light.alpha == 1 ? base : base.opacity(light.alpha)
        }
        if light.system == nil, dark.system == nil, light.alpha == 0, dark.alpha == 0 {
            return Color.clear
        }
        return Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua, .accessibilityHighContrastDarkAqua, .accessibilityHighContrastAqua])
                .map { $0 == .darkAqua || $0 == .accessibilityHighContrastDarkAqua } ?? false
            return nsColor(isDark ? dark : light)
        })
    }

    private static func systemColor(_ system: ThemeColor.System) -> Color {
        switch system {
        case .accent: return .accentColor
        case .label: return .primary
        case .controlBackground: return Color(nsColor: .controlBackgroundColor)
        case .windowBackground: return Color(nsColor: .windowBackgroundColor)
        case .green: return .green
        case .red: return .red
        case .blue: return .blue
        case .orange: return .orange
        case .teal: return .teal
        case .purple: return .purple
        case .pink: return .pink
        case .brown: return .brown
        case .indigo: return .indigo
        case .mint: return .mint
        case .gray: return .gray
        case .yellow: return .yellow
        }
    }

    private static func nsColor(_ token: ThemeColor) -> NSColor {
        guard let system = token.system else {
            return NSColor(srgbRed: token.red, green: token.green, blue: token.blue, alpha: token.alpha)
        }
        let base: NSColor
        switch system {
        case .accent: base = .controlAccentColor
        case .label: base = .labelColor
        case .controlBackground: base = .controlBackgroundColor
        case .windowBackground: base = .windowBackgroundColor
        case .green: base = .systemGreen
        case .red: base = .systemRed
        case .blue: base = .systemBlue
        case .orange: base = .systemOrange
        case .teal: base = .systemTeal
        case .purple: base = .systemPurple
        case .pink: base = .systemPink
        case .brown: base = .systemBrown
        case .indigo: base = .systemIndigo
        case .mint: base = .systemMint
        case .gray: base = .systemGray
        case .yellow: base = .systemYellow
        }
        return token.alpha == 1 ? base : base.withAlphaComponent(base.alphaComponent * token.alpha)
    }
}

extension EnvironmentValues {
    /// The app's colour theme (Settings ▸ Theme); Classic until `ThemedRoot` sets the chosen one.
    @Entry var theme: Theme = .classic
}

/// A window's root: the chosen theme in the environment (and as the controls' tint), and
/// the chosen appearance applied app-wide, at launch and whenever it changes. Changing
/// either re-renders in place; nothing reloads.
struct ThemedRoot: ViewModifier {
    @AppStorage(Theme.storageKey) private var themeID = ThemePalette.defaultID
    @AppStorage(AppAppearance.storageKey) private var appearance: AppAppearance = .system

    func body(content: Content) -> some View {
        let theme = Theme.named(themeID)
        content
            .environment(\.theme, theme)
            .tint(theme.usesSystemAccent ? nil : theme.accent)
            .onAppear { appearance.apply() }
            .onChange(of: appearance) { _, new in new.apply() }
    }
}

extension View {
    /// `ThemedRoot`: the chosen theme and appearance, for a window's root view.
    func themedRoot() -> some View { modifier(ThemedRoot()) }
}
