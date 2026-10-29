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
