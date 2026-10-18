// Tests/BudgetCoreTests/ThemePaletteTests.swift
import XCTest
@testable import BudgetCore

final class ThemePaletteTests: XCTestCase {
    private let expectedNames = [
        "Classic", "Ledger", "Ocean", "Forest", "Sunset", "Nord", "Solarized", "Dracula",
        "Graphite", "Sakura", "Lavender", "Desert", "Midnight", "Mint", "High Contrast",
    ]

    private func eachVariant(_ body: (ThemePalette, ThemeVariant, ThemeTokens) -> Void) {
        for palette in ThemePalette.all {
            for variant in ThemeVariant.allCases {
                body(palette, variant, palette.tokens(variant))
            }
        }
    }

    // MARK: Catalogue

    func testCatalogueHasTheFifteenThemesInOrder() {
        XCTAssertEqual(ThemePalette.all.map(\.name), expectedNames)
        XCTAssertEqual(Set(ThemePalette.all.map(\.id)).count, 15, "ids are unique")
        XCTAssertEqual(ThemePalette.defaultID, "classic")
        XCTAssertEqual(ThemePalette.all.first?.id, ThemePalette.defaultID)
    }

    func testLookupByIDFallsBackToClassic() {
        XCTAssertEqual(ThemePalette.named("nord").name, "Nord")
        XCTAssertEqual(ThemePalette.named("no-such-theme").id, "classic")
    }

    // MARK: Every token, both variants

    func testEveryThemeDefinesEveryTokenInBothVariants() {
        eachVariant { palette, variant, tokens in
            let label = "\(palette.name) \(variant)"
            XCTAssertEqual(tokens.named.count, ThemeTokens.tokenNames.count, label)
            for (name, color) in tokens.named {
                XCTAssertTrue((0...1).contains(color.alpha), "\(label) \(name) alpha")
                XCTAssertLessThanOrEqual(color.hexValue, 0xFFFFFF, "\(label) \(name)")
            }
            // Role colours are solid; tints are translucent (or the background, which may be clear).
            for (name, color) in tokens.solidColors {
                XCTAssertEqual(color.alpha, 1, "\(label) \(name) is solid")
            }
            XCTAssertGreaterThanOrEqual(tokens.chartSeries.count, 8, "\(label) chart series")
            XCTAssertTrue(tokens.chartSeries.allSatisfy { $0.alpha == 1 }, "\(label) chart series are solid")
            XCTAssertEqual(tokens.gridBackground(variant).alpha, 1, "\(label) grid background is opaque")
        }
    }

    func testVariantsMatchTheirAppearance() {
        // The app keeps the system's text colours, so light variants need light grounds and dark ones dark.
        eachVariant { palette, variant, tokens in
            let luminance = ColorMath.relativeLuminance(tokens.gridBackground(variant))
            if variant == .light {
                XCTAssertGreaterThan(luminance, 0.6, "\(palette.name) light background")
            } else {
                XCTAssertLessThan(luminance, 0.06, "\(palette.name) dark background")
            }
        }
    }

    // MARK: The distinguishability rule

    /// Income, expense and pending: CIEDE2000 ΔE ≥ 20 from each other and from body text.
    func testMoneyColoursAreDistinguishableFromEachOtherAndFromText() {
        eachVariant { palette, variant, tokens in
            let ground = tokens.gridBackground(variant)
            let text = ColorMath.composite(ThemeTokens.bodyText(variant), over: ground)
            let money = [("income", tokens.income), ("expense", tokens.expense), ("pending", tokens.pending)]
            for i in money.indices {
                for j in money.indices where j > i {
                    let difference = ColorMath.deltaE2000(money[i].1, money[j].1)
                    XCTAssertGreaterThanOrEqual(difference, ThemeRules.minimumMoneyDeltaE,
                                                "\(palette.name) \(variant): \(money[i].0) vs \(money[j].0) ΔE \(difference)")
                }
                let fromText = ColorMath.deltaE2000(money[i].1, text)
                XCTAssertGreaterThanOrEqual(fromText, ThemeRules.minimumMoneyDeltaE,
                                            "\(palette.name) \(variant): \(money[i].0) vs body text ΔE \(fromText)")
            }
        }
    }

    /// Income, expense and pending: WCAG contrast ≥ 3:1 on the grid background and on every
    /// tinted row money sits on (stripes, group, section, totals, reserved, net worth), both
    /// variants. Classic keeps today's system colours exactly (the system green is lighter
    /// than 3:1 on white), so it is held to the ΔE rule only. High Contrast meets 7:1.
    func testMoneyColoursContrastWithEveryRowBackground() {
        eachVariant { palette, variant, tokens in
            guard palette.id != ThemePalette.defaultID else { return }
            let minimum = palette.id == "high-contrast" ? 7.0 : ThemeRules.minimumMoneyContrast
            for (rowName, row) in tokens.moneyRowBackgrounds(variant) {
                for (name, color) in [("income", tokens.income), ("expense", tokens.expense), ("pending", tokens.pending)] {
                    let ratio = ColorMath.contrastRatio(color, row)
                    XCTAssertGreaterThanOrEqual(ratio, minimum, "\(palette.name) \(variant): \(name) on \(rowName) \(ratio)")
                }
            }
        }
    }

    /// The first two chart colours are also used as text (the Dashboard's expenses and net).
    func testLeadingSeriesColoursReadAsTextOnTheBackground() {
        eachVariant { palette, variant, tokens in
            guard palette.id != ThemePalette.defaultID else { return }
            for index in 0..<2 {
                let ratio = ColorMath.contrastRatio(tokens.chartSeries[index], tokens.gridBackground(variant))
                XCTAssertGreaterThanOrEqual(ratio, 3, "\(palette.name) \(variant): series \(index) \(ratio)")
            }
        }
    }

    func testBadgeGlyphsReadOnTheirFill() {
        eachVariant { palette, variant, tokens in
            for type in CategoryType.allCases {
                let glyph = tokens.badgeGlyph(type, variant)
                if palette.id == ThemePalette.defaultID {
                    XCTAssertEqual(glyph, .hex(0xFFFFFF), "Classic keeps white glyphs")
                    continue
                }
                let ratio = ColorMath.contrastRatio(glyph, tokens.badgeFill(type, variant))
                XCTAssertGreaterThanOrEqual(ratio, 3, "\(palette.name) \(variant) \(type) glyph \(ratio)")
            }
        }
        // Light fills take a black glyph, dark ones white.
        XCTAssertEqual(ThemePalette.named("dracula").dark.badgeGlyph(.income, .dark), .hex(0x000000))
        XCTAssertEqual(ThemePalette.named("high-contrast").light.badgeGlyph(.expense, .light), .hex(0xFFFFFF))
    }

    func testMoneyBackgroundsIncludeCardsSelectionAndPlanFills() {
        let names = ThemePalette.named("nord").dark.moneyRowBackgrounds(.dark).map(\.0)
        XCTAssertTrue(names.contains("surface"))
        XCTAssertTrue(names.contains("selection"))
        XCTAssertTrue(names.contains("differs fill (series 0)"))
        XCTAssertTrue(names.contains("differences cell (series 7)"))
    }

    func testAccentIsVisibleOnTheGrid() {
        eachVariant { palette, variant, tokens in
            let ratio = ColorMath.contrastRatio(tokens.accent, tokens.gridBackground(variant))
            XCTAssertGreaterThanOrEqual(ratio, 3, "\(palette.name) \(variant) accent \(ratio)")
        }
    }

    func testChartSeriesColoursAreDistinct() {
        eachVariant { palette, variant, tokens in
            let series = tokens.chartSeries
            for i in series.indices {
                for j in series.indices where j > i {
                    let difference = ColorMath.deltaE2000(series[i], series[j])
                    // Classic keeps the system palette as it is (teal and mint sit close).
                    let minimum = palette.id == ThemePalette.defaultID ? 3.0 : ThemeRules.minimumSeriesDeltaE
                    XCTAssertGreaterThanOrEqual(difference, minimum, "\(palette.name) \(variant): series \(i) vs \(j) ΔE \(difference)")
                }
            }
        }
    }

    func testControlTextReadsOnTheControlAccent() {
        // White text on the accent fill reads, or the accent is light enough for dark text;
        // an accent that already does is kept, and a shaded one keeps its hue.
        let white = ThemeColor.hex(0xFFFFFF)
        eachVariant { palette, variant, tokens in
            let control = tokens.controlAccent
            let contrast = ColorMath.contrastRatio(control, white)
            let luminance = ColorMath.relativeLuminance(control)
            XCTAssertTrue(contrast >= ThemeRules.minimumControlTextContrast || luminance >= ThemeRules.darkControlTextLuminance,
                          "\(palette.name) \(variant): control accent \(control.hexString) white contrast \(contrast)")
            if control != tokens.accent {
                XCTAssertLessThan(ColorMath.relativeLuminance(control), ColorMath.relativeLuminance(tokens.accent))
                let a = ColorMath.lab(control), b = ColorMath.lab(tokens.accent)
                let hue = { (lab: ColorMath.Lab) in atan2(lab.b, lab.a) * 180 / .pi }
                var difference = abs(hue(a) - hue(b))
                if difference > 180 { difference = 360 - difference }
                XCTAssertLessThan(difference, 20, "\(palette.name) \(variant): shading moved the hue \(difference)°")
            }
        }
        // Classic keeps the system accent; Nord's dark frost is shaded; Midnight's gold isn't.
        XCTAssertEqual(ThemePalette.named("classic").dark.controlAccent, ThemePalette.named("classic").dark.accent)
        XCTAssertNotEqual(ThemePalette.named("nord").dark.controlAccent, ThemePalette.named("nord").dark.accent)
        XCTAssertEqual(ThemePalette.named("midnight").dark.controlAccent, ThemePalette.named("midnight").dark.accent)
    }

    func testLightVariantsKeepTheirAccentForControls() {
        // Light variants' accents already carry white text; only dark variants' are shaded.
        for palette in ThemePalette.all {
            XCTAssertEqual(palette.light.controlAccent, palette.light.accent, "\(palette.name) light")
        }
    }

    func testShadingReachesItsLuminanceAndOnlyDarkens() {
        // 8-bit channels: the luminance within rounding of the target (0.004), no channel lighter.
        let step = 0.5 / 255
        for color in [ThemeColor.hex(0x88C0D0), .hex(0xB4B8C2), .hex(0xFF8A4C), .hex(0x66B2FF), .hex(0xE8B84A), .hex(0xFFFFFF)] {
            for target in [0.05, 0.15, 0.30] {
                let shaded = ColorMath.shaded(color, toLuminance: target)
                let luminance = ColorMath.relativeLuminance(shaded)
                XCTAssertEqual(luminance, target, accuracy: 0.004, "\(color.hexString) → \(target): \(shaded.hexString) at \(luminance)")
                XCTAssertLessThanOrEqual(luminance, ColorMath.relativeLuminance(color))
                XCTAssertLessThanOrEqual(shaded.red, color.red + step)
                XCTAssertLessThanOrEqual(shaded.green, color.green + step)
                XCTAssertLessThanOrEqual(shaded.blue, color.blue + step)
            }
        }
        // Already darker than the target: unchanged.
        XCTAssertEqual(ColorMath.shaded(.hex(0x2C4F7C), toLuminance: 0.30), .hex(0x2C4F7C))
    }

    func testAccentReadsOnCardsAndTheWindow() {
        // The accent stays the tint of labels (bordered buttons, icons, links): 3:1 on the
        // window and on cards in every theme. No theme fails today; one that does is a palette
        // to fix, not to shade here.
        eachVariant { palette, variant, tokens in
            let ground = tokens.gridBackground(variant)
            let surface = ColorMath.composite(tokens.surface, over: ground)
            for (name, background) in [("window", ground), ("surface", surface)] {
                let ratio = ColorMath.contrastRatio(tokens.accent, background)
                XCTAssertGreaterThanOrEqual(ratio, 3, "\(palette.name) \(variant): accent on \(name) \(ratio)")
            }
        }
    }

    func testTheChartAccentStandsApartFromTheMoneyColours() {
        // A net line over income and expense bars, a waterfall's totals beside its changes:
        // the accent where it's apart from both, else the first colour that is.
        eachVariant { palette, variant, tokens in
            let chartAccent = tokens.chartAccent
            for (name, money) in [("income", tokens.income), ("expense", tokens.expense)] {
                let difference = ColorMath.deltaE2000(chartAccent, money)
                XCTAssertGreaterThanOrEqual(difference, ThemeRules.minimumMoneyDeltaE,
                                            "\(palette.name) \(variant): chart accent vs \(name) ΔE \(difference)")
            }
        }
        for variant in ThemeVariant.allCases {
            let classic = ThemePalette.named("classic").tokens(variant)
            XCTAssertEqual(classic.chartAccent, classic.accent, "Classic's charts keep the accent")
        }
        // Forest's accent is a green: its net lines and totals take another colour.
        XCTAssertNotEqual(ThemePalette.named("forest").light.chartAccent, ThemePalette.named("forest").light.accent)
    }

    // MARK: Classic is today's look

    func testClassicIsTodaysSystemColours() {
        let classic = ThemePalette.named("classic")
        for variant in ThemeVariant.allCases {
            let tokens = classic.tokens(variant)
            XCTAssertEqual(tokens.accent.system, .accent)
            XCTAssertEqual(tokens.selectionOutline.system, .accent)
            XCTAssertEqual(tokens.selectionFill, ThemeColor.system(.accent, variant, alpha: 0.12))
            XCTAssertEqual(tokens.noteMarker, ThemeColor.system(.accent, variant, alpha: 0.85))
            XCTAssertEqual(tokens.windowBackground.alpha, 0, "no tint over the system window")
            XCTAssertEqual(tokens.gridHeaderBackground.system, .controlBackground)
            XCTAssertEqual(tokens.surface.system, .controlBackground)
            XCTAssertEqual(tokens.rowStripe, ThemeColor.system(.label, variant, alpha: 0.07))
            XCTAssertEqual(tokens.groupRowTint, ThemeColor.system(.orange, variant, alpha: 0.10))
            XCTAssertEqual(tokens.sectionHeaderTint, ThemeColor.system(.accent, variant, alpha: 0.08))
            XCTAssertEqual(tokens.totalsTint, ThemeColor.system(.teal, variant, alpha: 0.17))
            XCTAssertEqual(tokens.totalsNetTint, ThemeColor.system(.teal, variant, alpha: 0.28))
            XCTAssertEqual(tokens.totalsStripe.system, .teal)
            XCTAssertEqual(tokens.reservedTint, ThemeColor.system(.purple, variant, alpha: 0.08))
            XCTAssertEqual(tokens.netWorthTint, ThemeColor.system(.purple, variant, alpha: 0.10))
            XCTAssertEqual(tokens.reserved.system, .purple)
            XCTAssertEqual(tokens.income.system, .green)
            XCTAssertEqual(tokens.expense.system, .red)
            XCTAssertEqual(tokens.transfer.system, .blue)
            XCTAssertEqual(tokens.adjustmentsTint.system, .gray)
            XCTAssertEqual(tokens.yoyGood.system, .green)
            XCTAssertEqual(tokens.yoyBad.system, .red)
            XCTAssertEqual(tokens.neutralMoney.system, .label)
            XCTAssertEqual(tokens.differsFillOpacity, 0.22)
            XCTAssertEqual(tokens.differencesCellOpacity, 0.10)
            XCTAssertEqual(tokens.chartSeries.map(\.system),
                           [.blue, .orange, .green, .purple, .pink, .teal, .brown, .indigo, .mint, .red])
        }
        // Pending: a darker amber (0.72, 0.48, 0) in light mode, the system yellow in dark.
        XCTAssertEqual(classic.light.pending, .hex(0xB87A00))
        XCTAssertEqual(classic.dark.pending.system, .yellow)
    }

    func testSystemColoursCarryTheirResolvedValues() {
        XCTAssertEqual(ThemeColor.system(.green, .light).hexValue, 0x34C759)
        XCTAssertEqual(ThemeColor.system(.green, .dark).hexValue, 0x30D158)
        XCTAssertEqual(ThemeColor.system(.red, .light).hexValue, 0xFF383C)
        XCTAssertEqual(ThemeColor.system(.controlBackground, .dark).hexValue, 0x1E1E1E)
        // The label colour is translucent black / white; opacity multiplies it.
        XCTAssertEqual(ThemeColor.system(.label, .light, alpha: 0.07).effectiveAlpha, 0.847 * 0.07, accuracy: 1e-9)
    }
}
