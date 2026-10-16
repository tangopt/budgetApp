// Sources/BudgetCore/Themes/ThemeCatalog.swift
import Foundation

private func c(_ hex: UInt32) -> ThemeColor { .hex(hex) }
private func ink(_ hex: UInt32, _ alpha: Double) -> ThemeColor { .hex(hex, alpha: alpha) }

extension ThemePalette {
    /// Every theme, in the Settings grid's order.
    public static let all: [ThemePalette] = [
        classic, ledger, ocean, forest, sunset, nord, solarized, dracula,
        graphite, sakura, lavender, desert, midnight, mint, highContrast,
    ]

    // MARK: Classic — today's look, in system colours

    static let classic = ThemePalette(id: "classic", name: "Classic", light: classicTokens(.light), dark: classicTokens(.dark))

    private static func classicTokens(_ v: ThemeVariant) -> ThemeTokens {
        func s(_ system: ThemeColor.System) -> ThemeColor { .system(system, v) }
        return .make(
            accent: s(.accent), background: .clear, surface: s(.controlBackground), header: s(.controlBackground),
            stripe: .system(.label, v, alpha: 0.07), group: s(.orange), totals: s(.teal), reserved: s(.purple),
            transfer: s(.blue), adjustment: s(.gray),
            income: s(.green), expense: s(.red),
            // A darker amber in light mode so it reads on white; the system yellow in dark.
            pending: v == .light ? .hex(0xB87A00) : s(.yellow),
            neutral: s(.label),
            series: [s(.blue), s(.orange), s(.green), s(.purple), s(.pink), s(.teal), s(.brown), s(.indigo), s(.mint), s(.red)]
        )
    }

    // MARK: Ledger — an accounts book: cream paper, ink, red and green ruling

    static let ledger = ThemePalette(
        id: "ledger", name: "Ledger",
        light: .make(
            accent: c(0x2C4F7C), background: c(0xFBF6E8), surface: c(0xFFFBF0), header: c(0xF1E8D0),
            stripe: ink(0x6B5A3A, 0.07), group: c(0x9C7A45), totals: c(0x3E7A5A), reserved: c(0x7A4A72),
            transfer: c(0x2C4F7C), adjustment: c(0x8C8270),
            income: c(0x1E6B3C), expense: c(0xB0281E), pending: c(0x8A5A12), neutral: .system(.label, .light),
            series: [c(0x2C4F7C), c(0xB0281E), c(0x1E6B3C), c(0x7A4A72), c(0xB8822C), c(0x3E8A8C), c(0x6B4E2E), c(0x5A5FA8), c(0x8FA04A), c(0xC2607A)]
        ),
        dark: .make(
            accent: c(0x8FB3DE), background: c(0x1F1B15), surface: c(0x29241C), header: c(0x2D271E),
            stripe: ink(0xF3E7CC, 0.05), group: c(0xC9A46A), totals: c(0x7FBF98), reserved: c(0xC79BC0),
            transfer: c(0x8FB3DE), adjustment: c(0x9E9580),
            income: c(0x82C995), expense: c(0xEF7F72), pending: c(0xE3B45A), neutral: .system(.label, .dark),
            series: [c(0x8FB3DE), c(0xEF7F72), c(0x82C995), c(0xC79BC0), c(0xE3B45A), c(0x7CC6C4), c(0xC8A07A), c(0x6A7AC8), c(0xC7D47A), c(0xF0A0B8)]
        )
    )

    // MARK: Ocean — deep sea blues, sea green, coral, sand

    static let ocean = ThemePalette(
        id: "ocean", name: "Ocean",
        light: .make(
            accent: c(0x0B6FA4), background: c(0xF3F8FB), surface: c(0xFAFDFF), header: c(0xE3EEF5),
            stripe: ink(0x0B3A5C, 0.06), group: c(0x2A7FB0), totals: c(0x0E8A8F), reserved: c(0x6A58A8),
            transfer: c(0x1F64B0), adjustment: c(0x7C8D9A),
            income: c(0x0A7A5A), expense: c(0xC4384A), pending: c(0x9A6400), neutral: .system(.label, .light),
            series: [c(0x0B6FA4), c(0xB85A20), c(0x0A7A5A), c(0x6A58A8), c(0xD0457A), c(0x16A3B5), c(0x9C7A50), c(0x2A3A5A), c(0x6DBE8C), c(0xC4384A)]
        ),
        dark: .make(
            accent: c(0x4FB4E8), background: c(0x0E1A24), surface: c(0x14232F), header: c(0x182A38),
            stripe: ink(0xD8ECF8, 0.05), group: c(0x5BA6D6), totals: c(0x3CC2C8), reserved: c(0xA99BE6),
            transfer: c(0x6AA8F0), adjustment: c(0x8A9BA8),
            income: c(0x3ED6A2), expense: c(0xFF7C88), pending: c(0xF2C14E), neutral: .system(.label, .dark),
            series: [c(0x4FB4E8), c(0xFF9D5C), c(0x3ED6A2), c(0xA99BE6), c(0xFF7CB0), c(0x5FE0E8), c(0xD2AA7C), c(0x7F8CFF), c(0xB5E07A), c(0xFF7C88)]
        )
    )

    // MARK: Forest — pine, moss, bark, berry

    static let forest = ThemePalette(
        id: "forest", name: "Forest",
        light: .make(
            accent: c(0x2F6B3F), background: c(0xF4F7F0), surface: c(0xFAFCF7), header: c(0xE5ECDC),
            stripe: ink(0x2A3A22, 0.06), group: c(0x8A6A3C), totals: c(0x5E8A3A), reserved: c(0x75507F),
            transfer: c(0x3A6A8A), adjustment: c(0x868C7C),
            income: c(0x2A7A34), expense: c(0xB0362A), pending: c(0x8C6400), neutral: .system(.label, .light),
            series: [c(0x2F6B3F), c(0xC0682A), c(0x7FA040), c(0x75507F), c(0xB04060), c(0x3A8A8A), c(0x8A6A3C), c(0x3A6A8A), c(0xC9A640), c(0xB0362A)]
        ),
        dark: .make(
            accent: c(0x86C48A), background: c(0x141A14), surface: c(0x1B231B), header: c(0x1F281F),
            stripe: ink(0xE2EEDC, 0.05), group: c(0xC4A06A), totals: c(0x9CC070), reserved: c(0xB894C8),
            transfer: c(0x7FB0D0), adjustment: c(0x98A090),
            income: c(0x8BD47E), expense: c(0xF08A72), pending: c(0xE8C860), neutral: .system(.label, .dark),
            series: [c(0x86C48A), c(0xF0A060), c(0xC4D870), c(0xB894C8), c(0xF080A0), c(0x70C8C0), c(0xC4A06A), c(0x7FB0D0), c(0xE8C860), c(0xF08A72)]
        )
    )

    // MARK: Sunset — orange, magenta, violet and gold over a warm dusk

    static let sunset = ThemePalette(
        id: "sunset", name: "Sunset",
        light: .make(
            accent: c(0xC7470E), background: c(0xFFF7F0), surface: c(0xFFFBF7), header: c(0xFCE7D8),
            stripe: ink(0x5A2A14, 0.06), group: c(0xE0702A), totals: c(0x8E44AD), reserved: c(0x6A4AD0),
            transfer: c(0x3A5BC8), adjustment: c(0x9A8A84),
            income: c(0x157A62), expense: c(0xC2185B), pending: c(0x9E6200), neutral: .system(.label, .light),
            series: [c(0xC7470E), c(0x8E44AD), c(0xE0A020), c(0xC2185B), c(0x157A62), c(0x3A5BC8), c(0xF07A50), c(0x3A3A6A), c(0x9A6A4A), c(0x2AA0A0)]
        ),
        dark: .make(
            accent: c(0xFF8A4C), background: c(0x1E1416), surface: c(0x281A1D), header: c(0x2C1C20),
            stripe: ink(0xFFE6DA, 0.05), group: c(0xFFA05C), totals: c(0xC890F0), reserved: c(0xA48CFF),
            transfer: c(0x80A4FF), adjustment: c(0xA89894),
            income: c(0x52D3A8), expense: c(0xFF6FA0), pending: c(0xFFCB62), neutral: .system(.label, .dark),
            series: [c(0xFF8A4C), c(0xC890F0), c(0xFFCB62), c(0xFF6FA0), c(0x52D3A8), c(0x80A4FF), c(0xFFB49A), c(0xE0D8C8), c(0xD0A080), c(0x5CD0D8)]
        )
    )

    // MARK: Nord — arcticicestudio's Polar Night, Snow Storm, Frost and Aurora
    // Dark uses the published colours, except the expense red, lifted from Aurora #BF616A
    // (≈3:1 on Polar Night) to #D57780 so it stays ≥ 3:1 on the tinted rows; pending is Frost
    // #81A1C1 (Aurora yellow sits too close to Aurora green). Aurora is made for dark grounds,
    // so the light variant (Snow Storm) deepens Aurora and Frost to keep money legible.

    static let nord = ThemePalette(
        id: "nord", name: "Nord",
        light: .make(
            accent: c(0x5E81AC), background: c(0xECEFF4), surface: c(0xF4F6F9), header: c(0xE5E9F0),
            stripe: ink(0x2E3440, 0.05), group: c(0xD08770), totals: c(0x5E81AC), reserved: c(0xB48EAD),
            transfer: c(0x5E81AC), adjustment: c(0x4C566A),
            income: c(0x4E7A35), expense: c(0xA8434D), pending: c(0x2F6E85), neutral: .system(.label, .light),
            series: [c(0x5E81AC), c(0xB0634A), c(0x6F9A50), c(0xB48EAD), c(0xBF616A), c(0x5E9C9B), c(0xA88A50), c(0x3B4252), c(0x88C0D0), c(0x8F6A90)]
        ),
        dark: .make(
            accent: c(0x88C0D0), background: c(0x2E3440), surface: c(0x3B4252), header: c(0x3B4252),
            stripe: ink(0x242933, 0.35), group: c(0xD08770), totals: c(0x5E81AC), reserved: c(0xB48EAD),
            transfer: c(0x81A1C1), adjustment: c(0x7B88A1),
            income: c(0xA3BE8C), expense: c(0xD57780), pending: c(0x81A1C1), neutral: .system(.label, .dark),
            series: [c(0x88C0D0), c(0xD08770), c(0xA3BE8C), c(0xB48EAD), c(0xBF616A), c(0xEBCB8B), c(0x5E81AC), c(0x81A1C1)],
            strength: .scaled(0.8), planFill: 0.5
        )
    )

    // MARK: Solarized — Ethan Schoonover's base and accent colours
    // Pending is violet (light) / cyan (dark): Solarized's yellow is too close to its green.
    // Two accents are nudged for contrast: the light green deepened (#859900 → #6B7A00, just
    // under 3:1 on base3) and the dark red lifted (#DC322F → #F0524F on base03's tints).

    static let solarized = ThemePalette(
        id: "solarized", name: "Solarized",
        light: .make(
            accent: c(0x268BD2), background: c(0xFDF6E3), surface: c(0xFDF6E3), header: c(0xEEE8D5),
            stripe: ink(0x93A1A1, 0.12), group: c(0xCB4B16), totals: c(0x2AA198), reserved: c(0xD33682),
            transfer: c(0x268BD2), adjustment: c(0x93A1A1),
            income: c(0x6B7A00), expense: c(0xDC322F), pending: c(0x6C71C4), neutral: .system(.label, .light),
            series: [c(0x268BD2), c(0xCB4B16), c(0x859900), c(0x6C71C4), c(0xD33682), c(0x2AA198), c(0xB58900), c(0x586E75), c(0xDC322F), c(0x93A1A1)],
            planFill: 0.85
        ),
        dark: .make(
            accent: c(0x268BD2), background: c(0x002B36), surface: c(0x073642), header: c(0x073642),
            stripe: ink(0x073642, 0.6), group: c(0xCB4B16), totals: c(0x6C71C4), reserved: c(0xD33682),
            transfer: c(0x268BD2), adjustment: c(0x586E75),
            income: c(0x859900), expense: c(0xF0524F), pending: c(0x2AA198), neutral: .system(.label, .dark),
            series: [c(0x268BD2), c(0xCB4B16), c(0x859900), c(0x6C71C4), c(0xD33682), c(0x2AA198), c(0xB58900), c(0x93A1A1), c(0xDC322F)],
            planFill: 0.7
        )
    )

    // MARK: Dracula — the Dracula palette, and its official light sibling Alucard

    static let dracula = ThemePalette(
        id: "dracula", name: "Dracula",
        light: .make(
            accent: c(0x644AC9), background: c(0xFFFBEB), surface: c(0xFFFDF5), header: c(0xF2EEDB),
            stripe: ink(0x6C664B, 0.08), group: c(0xA34D14), totals: c(0x036A96), reserved: c(0xA3144D),
            transfer: c(0x036A96), adjustment: c(0x6C664B),
            income: c(0x14710A), expense: c(0xCB3A2A), pending: c(0x846E15), neutral: .system(.label, .light),
            series: [c(0x644AC9), c(0xA34D14), c(0x14710A), c(0xA3144D), c(0x036A96), c(0x846E15), c(0xCB3A2A), c(0x6C664B), c(0x2F9C8A), c(0xC56CB0)]
        ),
        dark: .make(
            accent: c(0xBD93F9), background: c(0x282A36), surface: c(0x303241), header: c(0x343746),
            stripe: ink(0x44475A, 0.5), group: c(0xFFB86C), totals: c(0x6272A4), reserved: c(0xFF79C6),
            transfer: c(0x8BE9FD), adjustment: c(0x6272A4),
            income: c(0x50FA7B), expense: c(0xFF5555), pending: c(0xF1FA8C), neutral: .system(.label, .dark),
            series: [c(0xBD93F9), c(0xFFB86C), c(0x50FA7B), c(0xFF79C6), c(0x8BE9FD), c(0xF1FA8C), c(0xFF5555), c(0x6272A4), c(0x44A0B0)],
            planFill: 0.6
        )
    )

    // MARK: Graphite — quiet greys with muted money colours

    static let graphite = ThemePalette(
        id: "graphite", name: "Graphite",
        light: .make(
            accent: c(0x4A5160), background: c(0xF4F4F5), surface: c(0xFAFAFA), header: c(0xE6E6E9),
            stripe: ink(0x18181B, 0.05), group: c(0x71717A), totals: c(0x52525B), reserved: c(0x6E6A86),
            transfer: c(0x5A6B80), adjustment: c(0x9A9AA2),
            income: c(0x2E7A4C), expense: c(0xB02A34), pending: c(0x8C6500), neutral: .system(.label, .light),
            series: [c(0x4A5160), c(0xC07040), c(0x4E8A60), c(0x7A6A9A), c(0xB04A6A), c(0x4A8A9A), c(0x9A8A6A), c(0x2A2A30), c(0xA0A0A8), c(0x6A7AB0)]
        ),
        dark: .make(
            accent: c(0xB4B8C2), background: c(0x1A1A1C), surface: c(0x232326), header: c(0x26262A),
            stripe: ink(0xFFFFFF, 0.045), group: c(0xA1A1AA), totals: c(0xA1A1AA), reserved: c(0xA8A2C8),
            transfer: c(0x9AAEC6), adjustment: c(0x7A7A82),
            income: c(0x6CC08A), expense: c(0xF07A7E), pending: c(0xE0B44A), neutral: .system(.label, .dark),
            series: [c(0xB4B8C2), c(0xE0A070), c(0x7CC090), c(0xA8A2C8), c(0xE08AA8), c(0x7CC0D0), c(0xC8B890), c(0x6E6E78), c(0xE8E8EC), c(0x8A9CE0)]
        )
    )

    // MARK: Sakura — cherry blossom pinks with leaf green

    static let sakura = ThemePalette(
        id: "sakura", name: "Sakura",
        light: .make(
            accent: c(0xC2306A), background: c(0xFFF6F8), surface: c(0xFFFBFC), header: c(0xFBE6EC),
            stripe: ink(0x6A2A40, 0.05), group: c(0xD6608A), totals: c(0xA8457A), reserved: c(0x7A55C0),
            transfer: c(0x3A72B8), adjustment: c(0xA08C94),
            income: c(0x2A7A50), expense: c(0xB8322E), pending: c(0x956200), neutral: .system(.label, .light),
            series: [c(0xC2306A), c(0x2A7A50), c(0xE08A40), c(0x7A55C0), c(0x3A72B8), c(0xE07AA0), c(0x8AA040), c(0x9A6A50), c(0x40A0A0), c(0xB8322E)]
        ),
        dark: .make(
            accent: c(0xF590B5), background: c(0x1F1519), surface: c(0x291C21), header: c(0x2D1E24),
            stripe: ink(0xFFE4EC, 0.05), group: c(0xF590B5), totals: c(0xE88AC0), reserved: c(0xB898F0),
            transfer: c(0x88B4F0), adjustment: c(0xA8949C),
            income: c(0x72D49A), expense: c(0xFF8478), pending: c(0xF4C460), neutral: .system(.label, .dark),
            series: [c(0xF590B5), c(0x72D49A), c(0xF8B070), c(0xB898F0), c(0x88B4F0), c(0xFFC0D8), c(0xC8DC80), c(0xD0A890), c(0x70D0D0), c(0xFF8478)]
        )
    )

    // MARK: Lavender — soft violets with a jade income

    static let lavender = ThemePalette(
        id: "lavender", name: "Lavender",
        light: .make(
            accent: c(0x6A48C8), background: c(0xF8F6FC), surface: c(0xFCFBFE), header: c(0xEDE8F8),
            stripe: ink(0x3A2A6A, 0.05), group: c(0x9A7AE0), totals: c(0x7A5AD0), reserved: c(0xB0408A),
            transfer: c(0x3A6AD0), adjustment: c(0x9A94A8),
            income: c(0x1F7A5A), expense: c(0xC0304A), pending: c(0x946000), neutral: .system(.label, .light),
            series: [c(0x6A48C8), c(0xB85F1E), c(0x1F9A6A), c(0xB0408A), c(0x3A6AD0), c(0xC0A030), c(0x40A0B0), c(0x8A6A9A), c(0xA08AE8), c(0xC0304A)]
        ),
        dark: .make(
            accent: c(0xB89CF6), background: c(0x19162A), surface: c(0x211D35), header: c(0x252040),
            stripe: ink(0xEDE6FF, 0.05), group: c(0xA88CF0), totals: c(0xB89CF6), reserved: c(0xF08AC8),
            transfer: c(0x88A8F8), adjustment: c(0x9A94B0),
            income: c(0x6EE0B4), expense: c(0xFF7A8A), pending: c(0xF8D060), neutral: .system(.label, .dark),
            series: [c(0xB89CF6), c(0xF8A870), c(0x6EE0B4), c(0xF08AC8), c(0x88A8F8), c(0xF8D060), c(0x70D0E0), c(0xC8A8C8), c(0x7060D0), c(0xFF7A8A)]
        )
    )

    // MARK: Desert — sand, terracotta, sage and a desert-sky teal

    static let desert = ThemePalette(
        id: "desert", name: "Desert",
        light: .make(
            accent: c(0xA8521C), background: c(0xFBF5EB), surface: c(0xFFFAF2), header: c(0xF2E4CE),
            stripe: ink(0x5A3A1A, 0.06), group: c(0xC08552), totals: c(0x8A6A40), reserved: c(0x7A5A8C),
            transfer: c(0x3A7488), adjustment: c(0xA09482),
            income: c(0x52732A), expense: c(0xB02A2A), pending: c(0x8A6400), neutral: .system(.label, .light),
            series: [c(0x3A7488), c(0xA8521C), c(0x52732A), c(0x7A5A8C), c(0xD09A3A), c(0xB04A5A), c(0x8A6A40), c(0x5A8AB0), c(0xA0A050), c(0x6A4A3A)]
        ),
        dark: .make(
            accent: c(0xE59D5E), background: c(0x1E1913), surface: c(0x28211A), header: c(0x2C241B),
            stripe: ink(0xF6E8D2, 0.05), group: c(0xD8A06A), totals: c(0xC8A878), reserved: c(0xB898C8),
            transfer: c(0x78B8C8), adjustment: c(0xA09482),
            income: c(0x8CC878), expense: c(0xF07868), pending: c(0xF0C860), neutral: .system(.label, .dark),
            series: [c(0x78B8C8), c(0xE59D5E), c(0xA8C870), c(0xB898C8), c(0xF0C860), c(0xF08890), c(0xC8A878), c(0x8AA8F0), c(0xE0E0A0), c(0xA07860)]
        )
    )

    // MARK: Midnight — navy with gold

    static let midnight = ThemePalette(
        id: "midnight", name: "Midnight",
        light: .make(
            accent: c(0x8A6200), background: c(0xF4F6FB), surface: c(0xFAFBFE), header: c(0xE2E8F4),
            stripe: ink(0x0B1A3A, 0.06), group: c(0x2E4478), totals: c(0x1E3A8A), reserved: c(0x6A4A9A),
            transfer: c(0x2E5AA8), adjustment: c(0x8A93A8),
            income: c(0x146A42), expense: c(0xB42335), pending: c(0x2F5BD3), neutral: .system(.label, .light),
            series: [c(0x1E3A8A), c(0xB8860B), c(0x1A7A4C), c(0x6A4A9A), c(0xB42335), c(0x2E8AA8), c(0xC06A9A), c(0x5A6A90), c(0x8AA0E0), c(0xA05A30)]
        ),
        dark: .make(
            accent: c(0xE8B84A), background: c(0x0B1426), surface: c(0x111C33), header: c(0x14213C),
            stripe: ink(0xDCE6FF, 0.045), group: c(0xE8B84A), totals: c(0x6A8AE0), reserved: c(0xB89AF0),
            transfer: c(0x7FA8F0), adjustment: c(0x8A96B0),
            income: c(0x5FD39A), expense: c(0xFF7A7A), pending: c(0x86B8FF), neutral: .system(.label, .dark),
            series: [c(0xE8B84A), c(0x86B8FF), c(0x5FD39A), c(0xB89AF0), c(0xFF7A7A), c(0x60D0E0), c(0xF0D890), c(0x4A6AC0), c(0xD0A070), c(0xF090C0)]
        )
    )

    // MARK: Mint — fresh greens and aqua

    static let mint = ThemePalette(
        id: "mint", name: "Mint",
        light: .make(
            accent: c(0x0A8A6C), background: c(0xF2FBF7), surface: c(0xF9FEFC), header: c(0xDDF3EA),
            stripe: ink(0x0A3A2A, 0.05), group: c(0x2A9A7A), totals: c(0x14907E), reserved: c(0x7A58C0),
            transfer: c(0x2A72B8), adjustment: c(0x8A9C96),
            income: c(0x157A4A), expense: c(0xC0344A), pending: c(0x9A6200), neutral: .system(.label, .light),
            series: [c(0x0A8A6C), c(0xB85A2E), c(0x2A72B8), c(0x7A58C0), c(0xD04A80), c(0xB8A030), c(0x5AC0A0), c(0x8A6A50), c(0x40A8D0), c(0xC0344A)]
        ),
        dark: .make(
            accent: c(0x5EE6CC), background: c(0x0F1B18), surface: c(0x152520), header: c(0x182A24),
            stripe: ink(0xDDFFF4, 0.045), group: c(0x5ECCAA), totals: c(0x4ED8C0), reserved: c(0xB49AF0),
            transfer: c(0x78B4F0), adjustment: c(0x8AA098),
            income: c(0x7CE8A0), expense: c(0xFF8A90), pending: c(0xF6C870), neutral: .system(.label, .dark),
            series: [c(0x5EE6CC), c(0xF8A070), c(0x78B4F0), c(0xB49AF0), c(0xF890C0), c(0xE0D070), c(0xC8F070), c(0xC8A890), c(0x4A9AC8), c(0xFF8A90)]
        )
    )

    // MARK: High Contrast — black and white with saturated, AAA-legible money

    static let highContrast = ThemePalette(
        id: "high-contrast", name: "High Contrast",
        light: .make(
            accent: c(0x0033CC), background: c(0xFFFFFF), surface: c(0xFFFFFF), header: c(0xE0E0E0),
            stripe: ink(0x000000, 0.06), group: c(0x000000), totals: c(0x000000), reserved: c(0x00606A),
            transfer: c(0x0033CC), adjustment: c(0x000000),
            income: c(0x004A14), expense: c(0x8A0000), pending: c(0x6A00A0), neutral: .system(.label, .light),
            series: [c(0x0033CC), c(0xC04000), c(0x006A1A), c(0x6A00A0), c(0xC0006A), c(0x00707A), c(0x7A5A00), c(0x5A8AFF), c(0xA00000)],
            strength: .scaled(0.4), planFill: 0.4
        ),
        dark: .make(
            accent: c(0x66B2FF), background: c(0x000000), surface: c(0x0A0A0A), header: c(0x1A1A1A),
            stripe: ink(0xFFFFFF, 0.06), group: c(0xFFFFFF), totals: c(0xFFFFFF), reserved: c(0xD9A3FF),
            transfer: c(0x66B2FF), adjustment: c(0xFFFFFF),
            income: c(0x4CFF7A), expense: c(0xFF8C8C), pending: c(0xFFD84A), neutral: .system(.label, .dark),
            series: [c(0x66B2FF), c(0xFF9A40), c(0x4CFF7A), c(0xD9A3FF), c(0xFF6EC0), c(0x40F0F0), c(0xFFD84A), c(0x3A6AFF), c(0xFF6E6E)],
            strength: .scaled(0.4), planFill: 0.4
        )
    )
}
