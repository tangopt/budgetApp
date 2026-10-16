// Sources/BudgetCore/Themes/ThemeTokens.swift
import Foundation

/// The rule every theme meets (spec 2026-10-16): income, expense and pending money stay
/// clearly apart from each other and from body text, and legible on the grid.
public enum ThemeRules {
    /// CIEDE2000 ΔE between income, expense and pending, and between each and body text.
    public static let minimumMoneyDeltaE = 20.0
    /// WCAG contrast of income, expense and pending on the grid background and its row tints.
    public static let minimumMoneyContrast = 3.0
    /// CIEDE2000 ΔE between any two chart series colours.
    public static let minimumSeriesDeltaE = 10.0
}

/// One variant's colours: the roles the app draws with. Tints carry their opacity; role
/// colours are solid.
public struct ThemeTokens: Equatable, Sendable {
    // Accent and selection.
    public var accent: ThemeColor
    public var selectionOutline: ThemeColor
    public var selectionFill: ThemeColor
    /// A cell's note corner marker.
    public var noteMarker: ThemeColor

    // Surfaces.
    /// Over the system window background behind the screens; clear keeps the system's.
    public var windowBackground: ThemeColor
    /// Cards and panels (the Dashboard's and Accounts' cards).
    public var surface: ThemeColor
    /// The grids' frozen header row.
    public var gridHeaderBackground: ThemeColor

    // Grid rows.
    /// Every other body row.
    public var rowStripe: ThemeColor
    public var groupRowTint: ThemeColor
    public var sectionHeaderTint: ThemeColor
    public var totalsTint: ThemeColor
    public var totalsNetTint: ThemeColor
    /// The Totals rows' leading stripe.
    public var totalsStripe: ThemeColor
    /// Reserves and account rows' stripe (and the chart's reserved hatch).
    public var reserved: ThemeColor
    public var reservedTint: ThemeColor
    public var netWorthTint: ThemeColor
    /// Adjustment categories' stripe and badge.
    public var adjustmentsTint: ThemeColor
    /// Transfer categories' stripe and badge.
    public var transfer: ThemeColor

    // Money.
    /// Positive money (and income categories' stripe and badge).
    public var income: ThemeColor
    /// Negative money (and expense categories' stripe and badge).
    public var expense: ThemeColor
    /// Expected, not yet confirmed money.
    public var pending: ThemeColor
    /// Zero and neutral money.
    public var neutralMoney: ThemeColor
    /// A year-on-year change for the better / worse.
    public var yoyGood: ThemeColor
    public var yoyBad: ThemeColor

    /// Chart series in order (the Budget's line first, then each scenario; the Dashboard's
    /// net, expenses, …).
    public var chartSeries: [ThemeColor]

    /// Every single-colour token by name, in declaration order.
    public var named: [(String, ThemeColor)] {
        [
            ("accent", accent), ("selectionOutline", selectionOutline), ("selectionFill", selectionFill),
            ("noteMarker", noteMarker), ("windowBackground", windowBackground), ("surface", surface),
            ("gridHeaderBackground", gridHeaderBackground), ("rowStripe", rowStripe), ("groupRowTint", groupRowTint),
            ("sectionHeaderTint", sectionHeaderTint), ("totalsTint", totalsTint), ("totalsNetTint", totalsNetTint),
            ("totalsStripe", totalsStripe), ("reserved", reserved), ("reservedTint", reservedTint),
            ("netWorthTint", netWorthTint), ("adjustmentsTint", adjustmentsTint), ("transfer", transfer),
            ("income", income), ("expense", expense), ("pending", pending), ("neutralMoney", neutralMoney),
            ("yoyGood", yoyGood), ("yoyBad", yoyBad),
        ]
    }

    public static let tokenNames = [
        "accent", "selectionOutline", "selectionFill", "noteMarker", "windowBackground", "surface",
        "gridHeaderBackground", "rowStripe", "groupRowTint", "sectionHeaderTint", "totalsTint", "totalsNetTint",
        "totalsStripe", "reserved", "reservedTint", "netWorthTint", "adjustmentsTint", "transfer",
        "income", "expense", "pending", "neutralMoney", "yoyGood", "yoyBad",
    ]

    /// The role colours, which are always drawn solid.
    public var solidColors: [(String, ThemeColor)] {
        [
            ("accent", accent), ("selectionOutline", selectionOutline), ("totalsStripe", totalsStripe),
            ("reserved", reserved), ("adjustmentsTint", adjustmentsTint), ("transfer", transfer),
            ("income", income), ("expense", expense), ("pending", pending), ("neutralMoney", neutralMoney),
            ("yoyGood", yoyGood), ("yoyBad", yoyBad), ("surface", surface), ("gridHeaderBackground", gridHeaderBackground),
        ]
    }

    /// Body text: the system label colour (themes keep the system's text colours).
    public static func bodyText(_ variant: ThemeVariant) -> ThemeColor {
        .system(.label, variant)
    }

    /// The opaque colour grid rows sit on: `windowBackground` over the system window.
    public func gridBackground(_ variant: ThemeVariant) -> ThemeColor {
        ColorMath.composite(windowBackground, over: .system(.windowBackground, variant))
    }

    /// Every row background money is drawn on, composited over the grid background.
    public func moneyRowBackgrounds(_ variant: ThemeVariant) -> [(String, ThemeColor)] {
        let ground = gridBackground(variant)
        let tints: [(String, ThemeColor)] = [
            ("stripe", rowStripe), ("group", groupRowTint), ("section header", sectionHeaderTint),
            ("totals", totalsTint), ("net", totalsNetTint), ("reserved", reservedTint), ("net worth", netWorthTint),
        ]
        return [("background", ground)] + tints.map { ($0.0, ColorMath.composite($0.1, over: ground)) }
    }
}

extension ThemeTokens {
    /// How strongly a theme's tints are laid on (Classic's are 1).
    public struct TintStrength: Sendable {
        public var scale: Double
        public static let standard = TintStrength(scale: 1)
        public static func scaled(_ scale: Double) -> TintStrength { TintStrength(scale: scale) }
    }

    /// A variant from its base colours, the tints derived as Classic derives them: section
    /// headers 8% accent, group rows 10% `group`, totals 17% / 28% `totals`, reserved 8%,
    /// net worth 10% `reserved`, the selection 12% accent (each times `strength`).
    public static func make(
        accent: ThemeColor, background: ThemeColor, surface: ThemeColor, header: ThemeColor,
        stripe: ThemeColor, group: ThemeColor, totals: ThemeColor, reserved: ThemeColor,
        transfer: ThemeColor, adjustment: ThemeColor,
        income: ThemeColor, expense: ThemeColor, pending: ThemeColor, neutral: ThemeColor,
        series: [ThemeColor], strength: TintStrength = .standard
    ) -> ThemeTokens {
        let k = strength.scale
        return ThemeTokens(
            accent: accent, selectionOutline: accent, selectionFill: accent.opacity(min(0.12 * k, 1)),
            noteMarker: accent.opacity(0.85),
            windowBackground: background, surface: surface, gridHeaderBackground: header,
            rowStripe: stripe, groupRowTint: group.opacity(min(0.10 * k, 1)),
            sectionHeaderTint: accent.opacity(min(0.08 * k, 1)),
            totalsTint: totals.opacity(min(0.17 * k, 1)), totalsNetTint: totals.opacity(min(0.28 * k, 1)),
            totalsStripe: totals, reserved: reserved,
            reservedTint: reserved.opacity(min(0.08 * k, 1)), netWorthTint: reserved.opacity(min(0.10 * k, 1)),
            adjustmentsTint: adjustment, transfer: transfer,
            income: income, expense: expense, pending: pending, neutralMoney: neutral,
            yoyGood: income, yoyBad: expense, chartSeries: series
        )
    }
}

/// A named theme: a light and a dark variant.
public struct ThemePalette: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let light: ThemeTokens
    public let dark: ThemeTokens

    public func tokens(_ variant: ThemeVariant) -> ThemeTokens {
        variant == .light ? light : dark
    }

    public static let defaultID = "classic"

    /// The theme with `id`, else Classic.
    public static func named(_ id: String) -> ThemePalette {
        all.first { $0.id == id } ?? classic
    }
}
