// Tests/BudgetCoreTests/ThemeRolesTests.swift
import XCTest
@testable import BudgetCore

/// The phone's colour roles (design review 2026-10-28 §3.1), as every theme fills them.
final class ThemeRolesTests: XCTestCase {
    private func eachVariant(_ body: (ThemePalette, ThemeVariant, ThemeRoles) -> Void) {
        for palette in ThemePalette.all {
            for variant in ThemeVariant.allCases {
                body(palette, variant, palette.roles(variant))
            }
        }
    }

    /// Every text role reads at 4.5:1 or more on each ground it is drawn on, light and dark, in every theme.
    func testEveryTextRoleReachesFourPointFiveToOneOnItsGroundsInEveryTheme() {
        eachVariant { palette, variant, roles in
            for pair in roles.textPairs {
                for (groundName, ground) in pair.grounds {
                    let drawn = ColorMath.composite(pair.color, over: ground)
                    let ratio = ColorMath.contrastRatio(drawn, ground)
                    XCTAssertGreaterThanOrEqual(
                        ratio, ThemeRoles.minimumTextContrast,
                        "\(palette.name) \(variant): \(pair.text) \(drawn.hexString) on \(groundName) \(ground.hexString) is \(String(format: "%.2f", ratio)):1"
                    )
                }
            }
        }
    }

    func testEveryGroundIsOpaque() {
        eachVariant { palette, variant, roles in
            for (name, color) in roles.grounds + [("separator", roles.separator), ("accentTint", roles.accentTint)] {
                XCTAssertEqual(color.alpha, 1, "\(palette.name) \(variant) \(name)")
            }
        }
    }

    /// The tiers stay in order: secondary text is fainter than primary, tertiary fainter than secondary.
    func testTextTiersAreOrdered() {
        eachVariant { palette, variant, roles in
            let surface = roles.surface
            func contrast(_ color: ThemeColor) -> Double {
                ColorMath.contrastRatio(ColorMath.composite(color, over: surface), surface)
            }
            let label = "\(palette.name) \(variant)"
            XCTAssertGreaterThan(contrast(roles.text), contrast(roles.textSecondary), label)
            XCTAssertGreaterThan(contrast(roles.textSecondary), contrast(roles.textTertiary), label)
        }
    }

    /// A theme's colour that already reads is kept as it is; one that doesn't is moved, not replaced.
    func testLegibleColoursAreKeptAndClassicsSystemColoursAreFixedInLight() {
        let ledger = ThemePalette.named("ledger")
        XCTAssertEqual(ledger.roles(.light).income, ledger.light.income)
        XCTAssertEqual(ledger.roles(.light).accent, ledger.light.accent)

        // iOS's system blue, green and red are under 4.5:1 on the grouped background: darkened, no longer system.
        let classic = ThemePalette.named("classic").roles(.light)
        XCTAssertNil(classic.accent.system)
        XCTAssertNil(classic.income.system)
        XCTAssertNil(classic.expense.system)
        // Classic's grounds stay the system's grouped backgrounds.
        XCTAssertEqual(classic.background.system, .windowBackground)
        XCTAssertEqual(classic.surface.system, .controlBackground)
    }
}

/// The eight theme sets (design review 2026-10-28 §3.5): every role of every set, light and dark, reads; the
/// catalogue is complete; and the one-time migration maps every old colour theme and font to exactly one set.
final class ThemeSetTests: XCTestCase {
    private func eachVariant(_ body: (ThemeSet, ThemeVariant, ThemeRoles) -> Void) {
        for set in ThemeSet.all {
            for variant in ThemeVariant.allCases {
                body(set, variant, set.roles(variant))
            }
        }
    }

    // MARK: Contrast (8 sets x 2 palettes)

    func testEveryTextRoleReachesFourPointFiveToOneOnItsGroundsInEverySet() {
        eachVariant { set, variant, roles in
            for pair in roles.textPairs {
                for (groundName, ground) in pair.grounds {
                    let ratio = ColorMath.contrastRatio(ColorMath.composite(pair.color, over: ground), ground)
                    XCTAssertGreaterThanOrEqual(
                        ratio, ThemeRoles.minimumTextContrast,
                        "\(set.name) \(variant): \(pair.text) \(pair.color.hexString) on \(groundName) \(ground.hexString) is \(String(format: "%.2f", ratio)):1"
                    )
                }
            }
        }
    }

    func testOnAccentLabelsAndTintTextHaveTheMarginsTheDesignReviewGives() {
        eachVariant { set, variant, roles in
            XCTAssertGreaterThanOrEqual(ColorMath.contrastRatio(roles.onAccent, roles.accent), 5.1, "\(set.name) \(variant) on-accent")
            XCTAssertGreaterThanOrEqual(ColorMath.contrastRatio(roles.accentTintText, roles.accentTint), 6.3, "\(set.name) \(variant) accent-tint text")
        }
    }

    func testEveryRoleIsOpaqueAndTiersAreOrdered() {
        eachVariant { set, variant, roles in
            let label = "\(set.name) \(variant)"
            for (name, color) in roles.grounds + [("separator", roles.separator), ("accentTint", roles.accentTint)] {
                XCTAssertEqual(color.alpha, 1, "\(label) \(name)")
            }
            func contrast(_ color: ThemeColor) -> Double { ColorMath.contrastRatio(color, roles.surface) }
            XCTAssertGreaterThan(contrast(roles.text), contrast(roles.textSecondary), label)
            XCTAssertGreaterThan(contrast(roles.textSecondary), contrast(roles.textTertiary), label)
        }
    }

    /// Clear draws its borders in `separator`: at least 3:1 on the grounds (non-text contrast).
    func testClearsBordersAreVisible() {
        for variant in ThemeVariant.allCases {
            let roles = ThemeSet.clear.roles(variant)
            for (name, ground) in roles.grounds {
                XCTAssertGreaterThanOrEqual(ColorMath.contrastRatio(roles.separator, ground), 3.0, "\(variant) on \(name)")
            }
        }
        XCTAssertEqual(ThemeSet.clear.edges, .bordered)
        XCTAssertEqual(ThemeSet.flat.edges, .flat)
    }

    // MARK: Catalogue

    func testEightSetsInOrderWithMangoTheDefault() {
        XCTAssertEqual(ThemeSet.all.map(\.id), ["mango", "classic", "editorial", "clear", "studio", "calm", "library", "flat"])
        XCTAssertEqual(ThemeSet.all.map(\.name), ["Mango", "Classic", "Editorial", "Clear", "Studio", "Calm", "Library", "Flat"])
        XCTAssertEqual(ThemeSet.defaultID, "mango")
        XCTAssertEqual(ThemeSet.named("nope").id, "mango")
        XCTAssertEqual(ThemeSet.named("library").id, "library")
        XCTAssertEqual(Set(ThemeSet.all.map(\.id)).count, 8)
    }

    func testAccentsAreTheDesignReviews() {
        let accents: [String: (UInt32, UInt32)] = [
            "mango": (0xB2520A, 0xFFA45C), "classic": (0x0A5FD0, 0x4DA3FF), "editorial": (0x8E1B22, 0xF0837C),
            "clear": (0x0A2472, 0x9DBBFF), "studio": (0x00695C, 0xC6F24E), "calm": (0x3A6849, 0x8CC4A0),
            "library": (0x1F4D36, 0x8FC7A0), "flat": (0x2546D6, 0x7C9BFF),
        ]
        for set in ThemeSet.all {
            XCTAssertEqual(set.light.accent.hexValue, accents[set.id]?.0, set.id)
            XCTAssertEqual(set.dark.accent.hexValue, accents[set.id]?.1, set.id)
        }
    }

    func testEveryPairingNamesCatalogueFontsAndEveryFigureFaceHasTabularDigits() {
        let ids = Set(FontCatalog.all.map(\.id))
        let expected: [String: [String]] = [
            "mango": ["sf-rounded", "sf-pro", "sf-pro"], "classic": ["sf-pro", "sf-pro", "sf-pro"],
            "editorial": ["new-york", "sf-pro", "sf-pro"],
            "clear": ["atkinson-hyperlegible", "atkinson-hyperlegible", "atkinson-hyperlegible"],
            "studio": ["ibm-plex-sans", "ibm-plex-sans", "ibm-plex-mono"], "calm": ["manrope", "source-sans-3", "sf-pro"],
            "library": ["source-serif-4", "source-serif-4", "source-serif-4"], "flat": ["inter", "inter", "inter"],
        ]
        for set in ThemeSet.all {
            let fonts = [set.fonts.display, set.fonts.body, set.fonts.figure]
            XCTAssertEqual(fonts, expected[set.id], set.id)
            for id in fonts { XCTAssertTrue(ids.contains(id), "\(set.id): \(id)") }
            XCTAssertTrue(set.fonts.figureFont.hasTabularDigits, set.id)
        }
        XCTAssertEqual(ThemeSet.mango.fonts.names, "SF Pro Rounded · SF Pro")
        XCTAssertEqual(ThemeSet.studio.fonts.names, "IBM Plex Sans · IBM Plex Mono")
        XCTAssertEqual(ThemeSet.flat.fonts.names, "Inter")
    }

    // MARK: Migration

    private let oldThemes = [
        "classic", "ledger", "ocean", "forest", "sunset", "nord", "solarized", "dracula", "graphite", "sakura",
        "lavender", "desert", "midnight", "mint", "high-contrast",
    ]
    private let oldFonts = [
        "sf-pro", "sf-rounded", "new-york", "inter", "ibm-plex-sans", "source-sans-3", "public-sans", "dm-sans",
        "manrope", "atkinson-hyperlegible", "lexend", "source-serif-4", "ibm-plex-mono",
    ]

    func testTheOldThemeIdsAreTheMacCatalogues() {
        XCTAssertEqual(oldThemes, ThemePalette.all.map(\.id))
    }

    func testEveryOldThemeMapsToItsSet() {
        let expected: [String: String] = [
            "classic": "classic", "ocean": "flat", "ledger": "library",
            "sunset": "mango", "solarized": "mango", "sakura": "mango", "desert": "mango",
            "forest": "calm", "nord": "calm", "lavender": "calm", "mint": "calm",
            "dracula": "studio", "graphite": "studio", "midnight": "flat", "high-contrast": "clear",
        ]
        for theme in oldThemes {
            let result = ThemeSetMigration.result(colorTheme: theme, font: "sf-pro")
            XCTAssertEqual(result.setID, expected[theme], theme)
            XCTAssertEqual(result.setsDarkAppearance, theme == "midnight", theme)
        }
    }

    /// The font decides only on Classic.
    func testTheFontBreaksTheTieOnlyOnClassic() {
        let onClassic: [String: String] = [
            "new-york": "editorial", "source-serif-4": "library", "ibm-plex-sans": "studio", "ibm-plex-mono": "studio",
            "atkinson-hyperlegible": "clear", "lexend": "clear", "manrope": "calm", "source-sans-3": "calm",
            "public-sans": "calm", "sf-rounded": "mango", "inter": "flat", "sf-pro": "classic", "dm-sans": "classic",
        ]
        XCTAssertEqual(Set(onClassic.keys), Set(oldFonts))
        for font in oldFonts {
            XCTAssertEqual(ThemeSetMigration.result(colorTheme: "classic", font: font).setID, onClassic[font], font)
            XCTAssertEqual(ThemeSetMigration.result(colorTheme: "ledger", font: font).setID, "library", font)
            XCTAssertEqual(ThemeSetMigration.result(colorTheme: "midnight", font: font).setID, "flat", font)
        }
    }

    /// 15 colour themes x 13 fonts: each pair lands on exactly one of the eight sets.
    func testEveryOldPairMapsToOneOfTheEightSets() {
        let ids = Set(ThemeSet.all.map(\.id))
        var reached = Set<String>()
        for theme in oldThemes {
            for font in oldFonts {
                let id = ThemeSetMigration.result(colorTheme: theme, font: font).setID
                XCTAssertTrue(ids.contains(id), "\(theme) + \(font) -> \(id)")
                reached.insert(id)
            }
        }
        XCTAssertEqual(reached, ids)
    }

    func testAFreshInstallGetsMangoAndAnUnknownThemeToo() {
        XCTAssertEqual(ThemeSetMigration.result(colorTheme: nil, font: nil), .init(setID: "mango", setsDarkAppearance: false))
        XCTAssertEqual(ThemeSetMigration.result(colorTheme: nil, font: "new-york").setID, "editorial")
        XCTAssertEqual(ThemeSetMigration.result(colorTheme: "no-such-theme", font: nil).setID, "mango")
        XCTAssertEqual(ThemeSetMigration.result(colorTheme: "classic", font: nil).setID, "classic")
    }
}

/// The stored theme set: the one-time migration from the old keys and the widgets' copy.
final class ThemeSetPreferenceTests: XCTestCase {
    private func defaults(_ values: [String: String]) -> UserDefaults {
        let suite = "ThemeSetPreferenceTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        for (key, value) in values { defaults.set(value, forKey: key) }
        return defaults
    }

    func testAFreshInstallStoresMango() {
        let store = defaults([:])
        XCTAssertEqual(ThemeSetPreference.migrate(store), "mango")
        XCTAssertEqual(store.string(forKey: ThemeSetPreference.key), "mango")
        XCTAssertNil(store.string(forKey: ThemeSetPreference.appearanceKey))
    }

    func testTheOldKeysPickTheSetOnceAndStayForARollback() {
        let store = defaults(["phone.theme": "ledger", "phone.font": "inter"])
        XCTAssertEqual(ThemeSetPreference.migrate(store), "library")
        XCTAssertEqual(store.string(forKey: "phone.theme"), "ledger")
        XCTAssertEqual(store.string(forKey: "phone.font"), "inter")
        // Chosen later in Settings: a second launch keeps it.
        store.set("studio", forKey: ThemeSetPreference.key)
        XCTAssertEqual(ThemeSetPreference.migrate(store), "studio")
    }

    func testMidnightSetsDarkOnceAndOtherwiseTheAppearanceIsKept() {
        let store = defaults(["phone.theme": "midnight", "phone.appearance": "light"])
        XCTAssertEqual(ThemeSetPreference.migrate(store), "flat")
        XCTAssertEqual(store.string(forKey: "phone.appearance"), "dark")
        // The person sets Light again: the migration doesn't run again.
        store.set("light", forKey: "phone.appearance")
        ThemeSetPreference.migrate(store)
        XCTAssertEqual(store.string(forKey: "phone.appearance"), "light")

        let kept = defaults(["phone.theme": "dracula", "phone.appearance": "system"])
        XCTAssertEqual(ThemeSetPreference.migrate(kept), "studio")
        XCTAssertEqual(kept.string(forKey: "phone.appearance"), "system")
    }

    func testClassicWithAFontTakesTheFontsSet() {
        XCTAssertEqual(ThemeSetPreference.migrate(defaults(["phone.theme": "classic", "phone.font": "new-york"])), "editorial")
        XCTAssertEqual(ThemeSetPreference.migrate(defaults(["phone.theme": "classic"])), "classic")
    }

    func testTheWidgetsReadTheSharedSet() {
        let group = defaults([:])
        XCTAssertEqual(ThemeSetPreference.widgetSet(group).id, "mango")
        ThemeSetPreference.share("calm", with: group)
        XCTAssertEqual(ThemeSetPreference.widgetSet(group).id, "calm")
        ThemeSetPreference.share("nonsense", with: group)
        XCTAssertEqual(ThemeSetPreference.widgetSet(group).id, "mango")
    }
}
