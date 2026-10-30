// Sources/BudgetCore/Themes/ThemeSet.swift
import Foundation

/// The fonts a theme set draws in (design review 2026-10-28 §3.5), as `FontCatalog` ids: **display** for large
/// titles, titles and headlines (and the sidebar's brand), **body** for everything else, **figure** for every figure
/// (`.figure` styles, `MoneyText`, `DateText`). A figure face without tabular digits is drawn in SF Pro's.
public struct ThemeFontPairing: Equatable, Sendable {
    public let display: String
    public let body: String
    public let figure: String

    public init(display: String, body: String, figure: String) {
        self.display = display
        self.body = body
        self.figure = figure
    }

    /// SF Pro throughout: the widgets' fonts (step 16 keeps them on the system font) and Classic's.
    public static let system = ThemeFontPairing(display: FontCatalog.defaultID, body: FontCatalog.defaultID, figure: FontCatalog.defaultID)

    public var displayFont: PhoneFont { FontCatalog.font(id: display) }
    public var bodyFont: PhoneFont { FontCatalog.font(id: body) }
    public var figureFont: PhoneFont { FontCatalog.font(id: figure) }

    /// The distinct faces' names in display, body, figure order: "SF Pro Rounded · SF Pro".
    public var names: String {
        var seen: [String] = []
        for name in [displayFont.name, bodyFont.name, figureFont.name] where !seen.contains(name) { seen.append(name) }
        return seen.joined(separator: " · ")
    }
}

/// One theme set (design review §3.5): a light and a dark palette filling every colour role (`ThemeRoles`) and a font
/// pairing, chosen together in Settings ▸ Appearance ▸ Theme. Eight sets replace the phone's 15 colour themes and 13
/// fonts; the Mac keeps its `ThemePalette`s.
public struct ThemeSet: Identifiable, Equatable, Sendable {
    /// How cards and controls are told apart from the ground.
    public enum Edges: Equatable, Sendable {
        /// Surface steps, with the system's hairlines in lists.
        case standard
        /// A visible 1 pt border (the `separator` role) on every card (Clear).
        case bordered
        /// No lines at all: surface steps only (Flat).
        case flat
    }

    public let id: String
    public let name: String
    /// A few words for the picker's VoiceOver label ("Editorial, serif headings").
    public let summary: String
    public let light: ThemeRoles
    public let dark: ThemeRoles
    public let fonts: ThemeFontPairing
    public let edges: Edges

    public func roles(_ variant: ThemeVariant) -> ThemeRoles {
        variant == .light ? light : dark
    }
}

// MARK: Catalogue

extension ThemeSet {
    public static let defaultID = "mango"

    /// The eight sets, in the picker's order.
    public static let all: [ThemeSet] = [mango, classic, editorial, clear, studio, calm, library, flat]

    /// The set with `id`, else Mango (an unknown id from a newer build, a hand-edited default).
    public static func named(_ id: String) -> ThemeSet {
        all.first { $0.id == id } ?? mango
    }

    public static let mango = ThemeSet(
        id: "mango", name: "Mango", summary: "warm, rounded headings",
        light: palette(.light, background: 0xF4F2EE, surface: 0xFFFFFF, surface2: 0xF8F6F2, separator: 0xE6E2DA,
                       text: 0x1B1A17, textSecondary: 0x5E5A52, textTertiary: 0x736E66,
                       accent: 0xB2520A, onAccent: 0xFFFFFF, accentTint: 0xFCE9D6, accentTintText: 0x8A4006,
                       income: 0x1D7A3A, expense: 0xB3261E, transfer: 0x2F5BC8, pending: 0x8A5A00,
                       incomeTint: 0xE4EFE7, pendingTint: 0xF1EBE0, expenseTint: 0xF6E5E4),
        dark: palette(.dark, background: 0x121110, surface: 0x1E1C1A, surface2: 0x282522, separator: 0x3A3632,
                      text: 0xF3F0EA, textSecondary: 0xB9B3A9, textTertiary: 0x9C968C,
                      accent: 0xFFA45C, onAccent: 0x121110, accentTint: 0x3A2614, accentTintText: 0xFFC58F,
                      income: 0x5BD48A, expense: 0xFF8A80, transfer: 0x8EAEFF, pending: 0xF2C14E,
                      incomeTint: 0x293D2E, pendingTint: 0x443A23, expenseTint: 0x47302C),
        fonts: ThemeFontPairing(display: "sf-rounded", body: "sf-pro", figure: "sf-pro"), edges: .standard)

    /// Today's iOS look. Its grounds and primary text are the system's own (grouped backgrounds, the label colour), so
    /// they keep following the system's accessibility settings; the values are what iOS draws.
    public static let classic = ThemeSet(
        id: "classic", name: "Classic", summary: "the system look",
        light: palette(.light, background: 0xF2F2F7, surface: 0xFFFFFF, surface2: 0xEDEDF2, separator: 0xD1D1D6,
                       text: 0x000000, textSecondary: 0x58585D, textTertiary: 0x6B6B6F,
                       accent: 0x0A5FD0, onAccent: 0xFFFFFF, accentTint: 0xDCE9FC, accentTintText: 0x0A4AA0,
                       income: 0x207A35, expense: 0xAB1F15, transfer: 0x6B3FC0, pending: 0x8F5600,
                       incomeTint: 0xE4EFE7, pendingTint: 0xF2EBE0, expenseTint: 0xF5E4E3, system: true),
        dark: palette(.dark, background: 0x000000, surface: 0x1C1C1E, surface2: 0x2C2C2E, separator: 0x38383A,
                      text: 0xFFFFFF, textSecondary: 0xAEAEB2, textTertiary: 0x939397,
                      accent: 0x4DA3FF, onAccent: 0x000000, accentTint: 0x10294D, accentTintText: 0xA9CFFF,
                      income: 0x4CD97B, expense: 0xFF6B63, transfer: 0xB49BFF, pending: 0xFFC947,
                      incomeTint: 0x253E2F, pendingTint: 0x453B25, expenseTint: 0x452A2A, system: true),
        fonts: .system, edges: .standard)

    public static let editorial = ThemeSet(
        id: "editorial", name: "Editorial", summary: "serif headings",
        light: palette(.light, background: 0xF6F1E7, surface: 0xFFFDF8, surface2: 0xF0EADD, separator: 0xDDD4C2,
                       text: 0x1A1714, textSecondary: 0x57514A, textTertiary: 0x6B645A,
                       accent: 0x8E1B22, onAccent: 0xFFFFFF, accentTint: 0xF6DEDC, accentTintText: 0x721218,
                       income: 0x247840, expense: 0xB03618, transfer: 0x2F4F9A, pending: 0x85540A,
                       incomeTint: 0xE5EFE8, pendingTint: 0xF0EAE2, expenseTint: 0xF6E7E3),
        dark: palette(.dark, background: 0x15120F, surface: 0x1F1B17, surface2: 0x2A251F, separator: 0x3D362D,
                      text: 0xF1EBDF, textSecondary: 0xBDB4A5, textTertiary: 0x9A9283,
                      accent: 0xF0837C, onAccent: 0x15120F, accentTint: 0x3B1B1A, accentTintText: 0xFFB4AE,
                      income: 0x6FD493, expense: 0xFF9A6B, transfer: 0x9DB6F2, pending: 0xE9BC55,
                      incomeTint: 0x2D3C2D, pendingTint: 0x433822, expenseTint: 0x473226),
        fonts: ThemeFontPairing(display: "new-york", body: "sf-pro", figure: "sf-pro"), edges: .standard)

    public static let clear = ThemeSet(
        id: "clear", name: "Clear", summary: "highest contrast, visible borders",
        light: palette(.light, background: 0xF3F5F8, surface: 0xFFFFFF, surface2: 0xE8ECF2, separator: 0x737E92,
                       text: 0x0B1020, textSecondary: 0x2F3747, textTertiary: 0x4B5565,
                       accent: 0x0A2472, onAccent: 0xFFFFFF, accentTint: 0xD9E3FA, accentTintText: 0x0A2472,
                       income: 0x12742F, expense: 0x98001B, transfer: 0x5B2E9E, pending: 0x7A4A00,
                       incomeTint: 0xE3EEE6, pendingTint: 0xEFE9E0, expenseTint: 0xF3E0E4),
        dark: palette(.dark, background: 0x05070D, surface: 0x0F141F, surface2: 0x1A2130, separator: 0x7C879B,
                      text: 0xFFFFFF, textSecondary: 0xD5DBE6, textTertiary: 0xAEB8C8,
                      accent: 0x9DBBFF, onAccent: 0x05070D, accentTint: 0x1B2B58, accentTintText: 0xD2E0FF,
                      income: 0x6BE59A, expense: 0xFF8080, transfer: 0xC9ADFF, pending: 0xFFD166,
                      incomeTint: 0x203A35, pendingTint: 0x3A362C, expenseTint: 0x3A2730),
        fonts: ThemeFontPairing(display: "atkinson-hyperlegible", body: "atkinson-hyperlegible", figure: "atkinson-hyperlegible"),
        edges: .bordered)

    public static let studio = ThemeSet(
        id: "studio", name: "Studio", summary: "graphite, mono figures",
        light: palette(.light, background: 0xEDF0F1, surface: 0xFFFFFF, surface2: 0xE3E8EA, separator: 0xCBD2D6,
                       text: 0x14181B, textSecondary: 0x4A545B, textTertiary: 0x5D6971,
                       accent: 0x00695C, onAccent: 0xFFFFFF, accentTint: 0xD3EEE8, accentTintText: 0x00473E,
                       income: 0x1B773C, expense: 0xA8231A, transfer: 0x3556B8, pending: 0x855300,
                       incomeTint: 0xE4EFE8, pendingTint: 0xF0EAE0, expenseTint: 0xF5E5E4),
        dark: palette(.dark, background: 0x0E1012, surface: 0x171A1D, surface2: 0x20252A, separator: 0x323941,
                      text: 0xECEFF1, textSecondary: 0xB0B8BF, textTertiary: 0x8C959D,
                      accent: 0xC6F24E, onAccent: 0x0E1012, accentTint: 0x1F2C10, accentTintText: 0xD9F78F,
                      income: 0x5FE0A8, expense: 0xFF8579, transfer: 0x8FB0FF, pending: 0xFFC857,
                      incomeTint: 0x243E36, pendingTint: 0x413927, expenseTint: 0x412D2E),
        fonts: ThemeFontPairing(display: "ibm-plex-sans", body: "ibm-plex-sans", figure: "ibm-plex-mono"), edges: .standard)

    public static let calm = ThemeSet(
        id: "calm", name: "Calm", summary: "sage, humanist type",
        light: palette(.light, background: 0xF1F4F0, surface: 0xFBFCFA, surface2: 0xE7ECE5, separator: 0xD6DDD3,
                       text: 0x232A25, textSecondary: 0x505B54, textTertiary: 0x606C66,
                       accent: 0x3A6849, onAccent: 0xFFFFFF, accentTint: 0xDDEBDF, accentTintText: 0x2A4A37,
                       income: 0x25793F, expense: 0xA32B21, transfer: 0x42609C, pending: 0x80560A,
                       incomeTint: 0xE5EFE8, pendingTint: 0xF0EBE2, expenseTint: 0xF4E6E4),
        dark: palette(.dark, background: 0x141815, surface: 0x1D221E, surface2: 0x272E29, separator: 0x38413A,
                      text: 0xE8EDE8, textSecondary: 0xB4BEB6, textTertiary: 0x929D94,
                      accent: 0x8CC4A0, onAccent: 0x141815, accentTint: 0x243428, accentTintText: 0xB5E0C3,
                      income: 0x72D894, expense: 0xF59388, transfer: 0x9AB4E8, pending: 0xE8BF63,
                      incomeTint: 0x2C4333, pendingTint: 0x423E2A, expenseTint: 0x443631),
        fonts: ThemeFontPairing(display: "manrope", body: "source-sans-3", figure: "sf-pro"), edges: .standard)

    public static let library = ThemeSet(
        id: "library", name: "Library", summary: "parchment, one serif",
        light: palette(.light, background: 0xF3EBDA, surface: 0xFBF6EA, surface2: 0xEBE2CE, separator: 0xD6CAB0,
                       text: 0x231C14, textSecondary: 0x4F4538, textTertiary: 0x62574A,
                       accent: 0x1F4D36, onAccent: 0xFFFFFF, accentTint: 0xDCE8DA, accentTintText: 0x173B29,
                       income: 0x2C7140, expense: 0xA8321E, transfer: 0x3A5A94, pending: 0x85540A,
                       incomeTint: 0xE6EEE8, pendingTint: 0xF0EAE2, expenseTint: 0xF5E6E4),
        dark: palette(.dark, background: 0x1A1510, surface: 0x231D17, surface2: 0x2E261E, separator: 0x433A2E,
                      text: 0xEFE6D2, textSecondary: 0xBFB39C, textTertiary: 0xA09580,
                      accent: 0x8FC7A0, onAccent: 0x1A1510, accentTint: 0x25382B, accentTintText: 0xBFE3C9,
                      income: 0x86D69A, expense: 0xFF9A82, transfer: 0x9DB4E8, pending: 0xE5BC5C,
                      incomeTint: 0x353E2F, pendingTint: 0x463A23, expenseTint: 0x4B342A),
        fonts: ThemeFontPairing(display: "source-serif-4", body: "source-serif-4", figure: "source-serif-4"), edges: .standard)

    /// Flat colour blocks: no borders, shadows or hairlines; `separator` is a surface step for fills and gaps. Light
    /// expense is the pill text #BA1729 (§3.5 lists #C2182B on grounds and #BA1729 on its tile): one role draws both,
    /// so it takes the darker, which reads on every ground and on the tile.
    public static let flat = ThemeSet(
        id: "flat", name: "Flat", summary: "flat colour blocks",
        light: palette(.light, background: 0xF6F7FB, surface: 0xFFFFFF, surface2: 0xE9ECF6, separator: 0xDFE3F0,
                       text: 0x0F1530, textSecondary: 0x434B66, textTertiary: 0x586080,
                       accent: 0x2546D6, onAccent: 0xFFFFFF, accentTint: 0xDCE4FF, accentTintText: 0x1B35A8,
                       income: 0x0E7038, expense: 0xBA1729, transfer: 0x5B30C9, pending: 0x8A5200,
                       incomeTint: 0xCFE2D7, pendingTint: 0xE8DCCC, expenseTint: 0xF3D1D5, transferTint: 0xDED6F4,
                       tintMix: 0.20),
        dark: palette(.dark, background: 0x0A0F1F, surface: 0x131A30, surface2: 0x1C2540, separator: 0x263054,
                      text: 0xF2F4FF, textSecondary: 0xB4BCD8, textTertiary: 0x939CBC,
                      accent: 0x7C9BFF, onAccent: 0x0A0F1F, accentTint: 0x1E2D66, accentTintText: 0xC9D6FF,
                      income: 0x5FDC95, expense: 0xFF8A8F, transfer: 0xB79CFF, pending: 0xF5C451,
                      incomeTint: 0x274C4A, pendingTint: 0x4E4639, expenseTint: 0x503749, transferTint: 0x3E3C66,
                      tintMix: 0.26),
        fonts: ThemeFontPairing(display: "inter", body: "inter", figure: "inter"), edges: .flat)

    /// One variant's roles from §3.5's table. Roles the table doesn't list are derived as §3.5 derives the pills:
    /// the transfer tint is transfer mixed `tintMix` (12% light, 18% dark) into the surface; warning is an orange
    /// moved just far enough to read on every ground and on its own tint. `system` marks Classic's grounds and
    /// primary text as the system's.
    private static func palette(
        _ variant: ThemeVariant,
        background: UInt32, surface: UInt32, surface2: UInt32, separator: UInt32,
        text: UInt32, textSecondary: UInt32, textTertiary: UInt32,
        accent: UInt32, onAccent: UInt32, accentTint: UInt32, accentTintText: UInt32,
        income: UInt32, expense: UInt32, transfer: UInt32, pending: UInt32,
        incomeTint: UInt32, pendingTint: UInt32, expenseTint: UInt32, transferTint: UInt32? = nil,
        tintMix: Double? = nil, system: Bool = false
    ) -> ThemeRoles {
        let light = variant == .light
        let mix = tintMix ?? (light ? 0.12 : 0.18)
        let surfaceColor = ThemeColor(hexValue: surface, system: system ? .controlBackground : nil)
        let backgroundColor = ThemeColor(hexValue: background, system: system ? .windowBackground : nil)
        let grounds: [ThemeColor] = [backgroundColor, surfaceColor, .hex(surface2)]
        func tint(_ color: UInt32) -> ThemeColor {
            ColorMath.composite(ThemeColor.hex(color).opacity(mix), over: .hex(surface))
        }
        let transferTintColor = transferTint.map { ThemeColor.hex($0) } ?? tint(transfer)
        let warningBase: UInt32 = light ? 0xC2560A : 0xFF9F4A
        let warningTint = tint(warningBase)
        let warning = ThemeRoles.legible(.hex(warningBase), on: grounds + [warningTint], variant)
        return ThemeRoles(
            background: backgroundColor, surface: surfaceColor, surface2: .hex(surface2), separator: .hex(separator),
            text: ThemeColor(hexValue: text, system: system ? .label : nil),
            textSecondary: .hex(textSecondary), textTertiary: .hex(textTertiary),
            accent: .hex(accent), onAccent: .hex(onAccent), accentTint: .hex(accentTint), accentTintText: .hex(accentTintText),
            income: .hex(income), expense: .hex(expense), transfer: .hex(transfer), pending: .hex(pending), warning: warning,
            incomeTint: .hex(incomeTint), expenseTint: .hex(expenseTint), transferTint: transferTintColor,
            pendingTint: .hex(pendingTint), warningTint: warningTint
        )
    }
}

// MARK: Migration from the colour theme and font

/// The one-time move from the phone's two old choices (one of 15 colour themes, one of 13 fonts) to a theme set
/// (design review §3.5 "Migration"). Mapped by colour theme; the font decides only when the colour theme was Classic,
/// the neutral one. The old keys are left in place so a rollback still reads them.
public enum ThemeSetMigration {
    public struct Result: Equatable, Sendable {
        public let setID: String
        /// The old theme was a dark one (Midnight): Appearance is set to Dark, once.
        public let setsDarkAppearance: Bool
    }

    public static func result(colorTheme: String?, font: String?) -> Result {
        switch colorTheme {
        case nil:
            // Never picked a colour theme: a fresh install, unless a font was picked (then it decides, as on Classic).
            guard let font, !font.isEmpty else { return Result(setID: ThemeSet.defaultID, setsDarkAppearance: false) }
            return Result(setID: setID(forClassicWithFont: font), setsDarkAppearance: false)
        case "classic": return Result(setID: setID(forClassicWithFont: font), setsDarkAppearance: false)
        case "ocean": return Result(setID: "flat", setsDarkAppearance: false)
        case "ledger": return Result(setID: "library", setsDarkAppearance: false)
        case "sunset", "solarized", "sakura", "desert": return Result(setID: "mango", setsDarkAppearance: false)
        case "forest", "nord", "lavender", "mint": return Result(setID: "calm", setsDarkAppearance: false)
        case "dracula", "graphite": return Result(setID: "studio", setsDarkAppearance: false)
        case "midnight": return Result(setID: "flat", setsDarkAppearance: true)
        case "high-contrast": return Result(setID: "clear", setsDarkAppearance: false)
        default: return Result(setID: ThemeSet.defaultID, setsDarkAppearance: false)
        }
    }

    /// The tie-break on Classic: the font's character picks the set.
    static func setID(forClassicWithFont font: String?) -> String {
        switch font {
        case "new-york": "editorial"
        case "source-serif-4": "library"
        case "ibm-plex-sans", "ibm-plex-mono": "studio"
        case "atkinson-hyperlegible", "lexend": "clear"
        case "manrope", "source-sans-3", "public-sans": "calm"
        case "sf-rounded": "mango"
        case "inter": "flat"
        default: "classic" // SF Pro, DM Sans, none
        }
    }
}
