// Sources/BudgetCore/Themes/ThemeRoles.swift
import Foundation

/// The iPhone and iPad's semantic colour roles for one variant (design review 2026-10-28 §3.1): what a screen draws
/// with, named by use, not by hue. Every role is an opaque colour except `text`, which may stand for the system label
/// colour (Classic) so it keeps following the system's accessibility settings.
///
/// Today every role is derived from a `ThemePalette` (`derived(from:_:)`), the Mac's 15 themes. The theme sets
/// (design review §3.5, step 8) fill the same roles with their own values instead, so screens drawn from the roles
/// change palette without changing code.
public struct ThemeRoles: Equatable, Sendable {
    // Grounds.
    /// Behind a screen's cards.
    public var background: ThemeColor
    /// Cards, panels and rows.
    public var surface: ThemeColor
    /// Inside a card: tiles, category discs, thumbnails.
    public var surface2: ThemeColor
    /// Hairlines.
    public var separator: ThemeColor

    // Text.
    /// Primary text and figures.
    public var text: ThemeColor
    /// Detail lines and labels.
    public var textSecondary: ThemeColor
    /// Placeholders and disabled hints.
    public var textTertiary: ThemeColor

    // Accent.
    /// Primary buttons, the selection bar, links.
    public var accent: ThemeColor
    /// A label on an accent fill (a primary button's).
    public var onAccent: ThemeColor
    /// Selected rows, pickers, "to do".
    public var accentTint: ThemeColor
    /// Text on `accentTint`.
    public var accentTintText: ThemeColor

    // Status. Each colour reads as text on every ground and on its own tint (a status pill: the word on the tint).
    /// Money in; done.
    public var income: ThemeColor
    /// Money out, over plan; a problem.
    public var expense: ThemeColor
    /// Money moved between the household's own accounts.
    public var transfer: ThemeColor
    /// Estimates, waiting, close to plan.
    public var pending: ThemeColor
    /// Needs attention but isn't wrong: over pace, a missing document, a notice.
    public var warning: ThemeColor
    public var incomeTint: ThemeColor
    public var expenseTint: ThemeColor
    public var transferTint: ThemeColor
    public var pendingTint: ThemeColor
    public var warningTint: ThemeColor

    public init(
        background: ThemeColor, surface: ThemeColor, surface2: ThemeColor, separator: ThemeColor,
        text: ThemeColor, textSecondary: ThemeColor, textTertiary: ThemeColor,
        accent: ThemeColor, onAccent: ThemeColor, accentTint: ThemeColor, accentTintText: ThemeColor,
        income: ThemeColor, expense: ThemeColor, transfer: ThemeColor, pending: ThemeColor, warning: ThemeColor,
        incomeTint: ThemeColor, expenseTint: ThemeColor, transferTint: ThemeColor, pendingTint: ThemeColor,
        warningTint: ThemeColor
    ) {
        self.background = background
        self.surface = surface
        self.surface2 = surface2
        self.separator = separator
        self.text = text
        self.textSecondary = textSecondary
        self.textTertiary = textTertiary
        self.accent = accent
        self.onAccent = onAccent
        self.accentTint = accentTint
        self.accentTintText = accentTintText
        self.income = income
        self.expense = expense
        self.transfer = transfer
        self.pending = pending
        self.warning = warning
        self.incomeTint = incomeTint
        self.expenseTint = expenseTint
        self.transferTint = transferTint
        self.pendingTint = pendingTint
        self.warningTint = warningTint
    }

    /// The smallest contrast any text role keeps on the grounds it is drawn on (WCAG AA).
    public static let minimumTextContrast = 4.5

    /// The grounds text sits on: the screen, a card, a tile inside a card.
    public var grounds: [(String, ThemeColor)] {
        [("background", background), ("surface", surface), ("surface2", surface2)]
    }

    /// Every text role with the grounds it must read on (each ≥ `minimumTextContrast`): the text tiers, the accent
    /// and the status colours on every ground (the status colours on their own tint too), and the labels on the
    /// accent and its tint.
    public var textPairs: [(text: String, color: ThemeColor, grounds: [(String, ThemeColor)])] {
        let onGrounds: [(String, ThemeColor)] = [
            ("text", text), ("textSecondary", textSecondary), ("textTertiary", textTertiary), ("accent", accent),
        ]
        let status: [(String, ThemeColor, String, ThemeColor)] = [
            ("income", income, "incomeTint", incomeTint), ("expense", expense, "expenseTint", expenseTint),
            ("transfer", transfer, "transferTint", transferTint), ("pending", pending, "pendingTint", pendingTint),
            ("warning", warning, "warningTint", warningTint),
        ]
        return onGrounds.map { ($0.0, $0.1, grounds) }
            + status.map { ($0.0, $0.1, grounds + [($0.2, $0.3)]) }
            + [("onAccent", onAccent, [("accent", accent)]), ("accentTintText", accentTintText, [("accentTint", accentTint)])]
    }
}

// MARK: Derived from a palette

extension ThemeRoles {
    /// The roles for one of the 15 palettes: its own grounds, accent and money colours, each text colour moved just
    /// far enough (darker in light, lighter in dark, same hue) to reach `minimumTextContrast` on every ground it is
    /// drawn on. Classic's system grounds are measured as iOS draws them (the grouped backgrounds).
    public static func derived(from palette: ThemePalette, _ variant: ThemeVariant) -> ThemeRoles {
        let tokens = palette.tokens(variant)
        let light = variant == .light
        let white = ThemeColor.hex(0xFFFFFF), black = ThemeColor.hex(0x000000)

        // Grounds, opaque.
        let base = light ? white : black
        let background = tokens.windowBackground.alpha == 0
            ? ThemeColor(hexValue: light ? IOSGroundValues.groupedBackgroundLight : IOSGroundValues.groupedBackgroundDark,
                         system: .windowBackground)
            : ColorMath.composite(tokens.windowBackground, over: base)
        let surface = tokens.surface.system == .controlBackground
            ? ThemeColor(hexValue: light ? IOSGroundValues.cardLight : IOSGroundValues.cardDark, system: .controlBackground)
            : ColorMath.composite(tokens.surface, over: background)
        let ink = light ? black : white
        let surface2 = ColorMath.composite(ink.opacity(light ? 0.04 : 0.07), over: surface)
        let separator = ColorMath.composite(ink.opacity(light ? 0.12 : 0.16), over: surface)
        let grounds = [background, surface, surface2]

        // Text tiers: the system label; the secondary and tertiary tiers are the ink laid over a card just thickly
        // enough to read (iOS's own secondary label is about 3.5:1 on white).
        let text = ThemeTokens.bodyText(variant)
        let textSecondary = inkTier(over: surface, reaching: 6.0, on: grounds)
        let textTertiary = inkTier(over: surface, reaching: minimumTextContrast + 0.25, on: grounds)

        // Accent.
        let accent = legible(tokens.accent, on: grounds, variant)
        let onAccent = ColorMath.contrastRatio(white, accent) >= ColorMath.contrastRatio(black, accent) ? white : black
        let accentTint = tint(of: tokens.accent, over: surface, variant)
        let accentTintText = legible(accent, on: [accentTint], variant)

        // Status: legible on every ground, then on its tint.
        func status(_ color: ThemeColor) -> (ThemeColor, ThemeColor) {
            let tinted = tint(of: color, over: surface, variant)
            return (legible(color, on: grounds + [tinted], variant), tinted)
        }
        let warningBase: ThemeColor = tokens.accent.system != nil
            ? .system(.orange, variant)
            : .hex(light ? 0xC2560A : 0xFF9F4A)
        let (income, incomeTint) = status(tokens.income)
        let (expense, expenseTint) = status(tokens.expense)
        let (transfer, transferTint) = status(tokens.transfer)
        let (pending, pendingTint) = status(tokens.pending)
        let (warning, warningTint) = status(warningBase)

        return ThemeRoles(
            background: background, surface: surface, surface2: surface2, separator: separator,
            text: text, textSecondary: textSecondary, textTertiary: textTertiary,
            accent: accent, onAccent: onAccent, accentTint: accentTint, accentTintText: accentTintText,
            income: income, expense: expense, transfer: transfer, pending: pending, warning: warning,
            incomeTint: incomeTint, expenseTint: expenseTint, transferTint: transferTint, pendingTint: pendingTint,
            warningTint: warningTint
        )
    }

    /// A status pill's or selected row's fill: the colour thinly over a card.
    static func tint(of color: ThemeColor, over surface: ThemeColor, _ variant: ThemeVariant) -> ThemeColor {
        ColorMath.composite(ThemeColor(hexValue: color.hexValue).opacity(variant == .light ? 0.13 : 0.2), over: surface)
    }

    /// The lowest contrast `color` (drawn over each) keeps against `grounds`.
    public static func worstContrast(_ color: ThemeColor, on grounds: [ThemeColor]) -> Double {
        grounds.map { ColorMath.contrastRatio(ColorMath.composite(color, over: $0), $0) }.min() ?? 21
    }

    /// `color` as it is when it already reaches `minimumTextContrast` (plus a hair, so 8-bit rounding can't land
    /// under it) on every ground; else the nearest shade that does: darker on light grounds, lighter on dark ones.
    static func legible(_ color: ThemeColor, on grounds: [ThemeColor], _ variant: ThemeVariant) -> ThemeColor {
        let target = minimumTextContrast + 0.1
        if worstContrast(color, on: grounds) >= target { return color }
        let drawn = ColorMath.composite(color, over: grounds[0])
        // Binary search on how far to move: 0 keeps the colour, 1 is black (light) or white (dark).
        var low = 0.0, high = 1.0
        for _ in 0..<24 {
            let mid = (low + high) / 2
            if worstContrast(moved(drawn, by: mid, variant), on: grounds) >= target { high = mid } else { low = mid }
        }
        return moved(drawn, by: high, variant)
    }

    /// `color` moved `amount` (0…1) of the way to black in light mode (scaling its light, so the hue holds) or to
    /// white in dark mode (in linear light).
    private static func moved(_ color: ThemeColor, by amount: Double, _ variant: ThemeVariant) -> ThemeColor {
        func channel(_ value: Double) -> UInt32 {
            let linear = ColorMath.linear(value)
            let moved = variant == .light ? linear * (1 - amount) : linear + (1 - linear) * amount
            return UInt32((min(max(ColorMath.encoded(moved), 0), 1) * 255).rounded())
        }
        return ThemeColor(hexValue: (channel(color.red) << 16) | (channel(color.green) << 8) | channel(color.blue))
    }

    /// The variant's ink (black in light, white in dark) laid over `surface` at the least opacity that reaches
    /// `contrast` on every ground: a neutral grey tinted by the theme's card.
    private static func inkTier(over surface: ThemeColor, reaching contrast: Double, on grounds: [ThemeColor]) -> ThemeColor {
        let isLight = ColorMath.relativeLuminance(surface) > 0.18
        let ink = ThemeColor.hex(isLight ? 0x000000 : 0xFFFFFF)
        var low = 0.0, high = 1.0
        for _ in 0..<24 {
            let mid = (low + high) / 2
            let candidate = ColorMath.composite(ink.opacity(mid), over: surface)
            if worstContrast(candidate, on: grounds) >= contrast { high = mid } else { low = mid }
        }
        return ColorMath.composite(ink.opacity(high), over: surface)
    }
}

/// iOS 26's grouped backgrounds, which Classic draws its screens and cards in: `systemGroupedBackground` and
/// `secondarySystemGroupedBackground`, light and dark.
enum IOSGroundValues {
    static let groupedBackgroundLight: UInt32 = 0xF2F2F7
    static let groupedBackgroundDark: UInt32 = 0x000000
    static let cardLight: UInt32 = 0xFFFFFF
    static let cardDark: UInt32 = 0x1C1C1E
}

extension ThemePalette {
    /// The phone's colour roles for a variant (derived; the theme sets will carry their own).
    public func roles(_ variant: ThemeVariant) -> ThemeRoles {
        ThemeRoles.derived(from: self, variant)
    }
}
