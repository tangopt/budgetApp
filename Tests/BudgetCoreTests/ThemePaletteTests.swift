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
