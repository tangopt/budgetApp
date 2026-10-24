import XCTest
import SwiftUI
import BudgetCore
@testable import MangoUI

/// The design system's rules that aren't drawing: how an amount reads by role, when a row stacks, how a day is
/// written, how far a figure may shrink (iPhone spec §4; ui-polish spec §1.4).
final class DesignSystemTests: XCTestCase {
    // MARK: Money by role

    func testIncomeShowsAsGivenInTheIncomeTone() {
        let shown = MoneyPresentation(minorUnits: 250_000, currency: .gbp, role: .income)
        XCTAssertEqual(shown.text, "£2,500.00")
        XCTAssertEqual(shown.tone, .income)
        XCTAssertEqual(shown.spoken, "received £2,500.00")
    }

    func testAnExpenseMagnitudeShowsNegativeWithATrueMinus() {
        let shown = MoneyPresentation(minorUnits: 1_234_567, currency: .eur, role: .expense)
        XCTAssertEqual(shown.text, "\u{2212}€12,345.67")
        XCTAssertEqual(shown.tone, .expense)
        XCTAssertEqual(shown.spoken, "spent €12,345.67")
    }

    func testARefundedExpenseReadsAsAGainNeverAsASpend() {
        let shown = MoneyPresentation(minorUnits: -2_499, currency: .gbp, role: .expense)
        XCTAssertEqual(shown.text, "£24.99")
        XCTAssertEqual(shown.tone, .income)
    }

    func testIncomeReversedShowsNegativeInTheExpenseTone() {
        let shown = MoneyPresentation(minorUnits: -1_000, currency: .gbp, role: .income)
        XCTAssertEqual(shown.text, "\u{2212}£10.00")
        XCTAssertEqual(shown.tone, .expense)
    }

    func testTransferKeepsItsSignInTheTransferTone() {
        let out = MoneyPresentation(minorUnits: -50_000, currency: .gbp, role: .transfer)
        XCTAssertEqual(out.text, "\u{2212}£500.00")
        XCTAssertEqual(out.tone, .transfer)
        XCTAssertEqual(out.spoken, "moved £500.00")
    }

    func testAPositiveTransferHasNoPlusAndStaysInTheTransferTone() {
        let into = MoneyPresentation(minorUnits: 50_000, currency: .gbp, role: .transfer)
        XCTAssertEqual(into.text, "£500.00")
        XCTAssertEqual(into.tone, .transfer)
        XCTAssertEqual(into.spoken, "moved £500.00")
    }

    func testAmountsUnderOnePound() {
        XCTAssertEqual(MoneyPresentation(minorUnits: 5, currency: .gbp, role: .neutral).text, "£0.05")
        XCTAssertEqual(MoneyPresentation(minorUnits: -5, currency: .gbp, role: .neutral).text, "\u{2212}£0.05")
        let spent = MoneyPresentation(minorUnits: 99, currency: .eur, role: .expense)
        XCTAssertEqual(spent.text, "\u{2212}€0.99")
        XCTAssertEqual(spent.spoken, "spent €0.99")
    }

    func testNeutralIsNeverColoured() {
        XCTAssertEqual(MoneyPresentation(minorUnits: -12_345, currency: .gbp, role: .neutral).tone, .neutral)
        XCTAssertEqual(MoneyPresentation(minorUnits: 12_345, currency: .gbp, role: .neutral).tone, .neutral)
        XCTAssertEqual(MoneyPresentation(minorUnits: -12_345, currency: .gbp, role: .neutral).spoken, "minus £123.45")
    }

    func testABalanceIsNeutralUnlessOwed() {
        let held = MoneyPresentation(minorUnits: 123_456_789, currency: .gbp, role: .balance)
        XCTAssertEqual(held.text, "£1,234,567.89")
        XCTAssertEqual(held.tone, .neutral)
        XCTAssertEqual(held.spoken, "balance £1,234,567.89")
        let owed = MoneyPresentation(minorUnits: -8_147, currency: .gbp, role: .balance)
        XCTAssertEqual(owed.text, "\u{2212}£81.47")
        XCTAssertEqual(owed.tone, .expense)
        XCTAssertEqual(owed.spoken, "owed £81.47")
    }

    func testZeroIsNeutralWhateverTheRole() {
        for role in [MoneyRole.income, .expense, .neutral, .balance] {
            let shown = MoneyPresentation(minorUnits: 0, currency: .gbp, role: role)
            XCTAssertEqual(shown.text, "£0.00", "\(role)")
            XCTAssertEqual(shown.tone, .neutral, "\(role)")
        }
    }

    // MARK: Fitting a figure

    func testAFigureShrinksToSeventyPercentAtMostByDefault() {
        XCTAssertEqual(FigureFit.shrink().minimumScale, 0.7)
        XCTAssertEqual(FigureFit.natural.minimumScale, 1)
        XCTAssertEqual(FigureFit.shrink(minimumScale: 0.8).minimumScale, 0.8)
    }

    // MARK: Rows stack at accessibility sizes

    func testRowsStackTheAmountUnderTheLabelOnlyAtAccessibilitySizes() {
        XCTAssertFalse(AmountRowLayout.stacks(at: .large))
        XCTAssertFalse(AmountRowLayout.stacks(at: .xxxLarge))
        XCTAssertTrue(AmountRowLayout.stacks(at: .accessibility1))
        XCTAssertTrue(AmountRowLayout.stacks(at: .accessibility5))
    }

    func testAStackedRowLetsANaturalFigureShrinkToTheMinimum() {
        XCTAssertEqual(AmountRowLayout.fit(.natural, at: .large), .natural)
        XCTAssertEqual(AmountRowLayout.fit(.natural, at: .xxxLarge), .natural)
        XCTAssertEqual(AmountRowLayout.fit(.natural, at: .accessibility3), .shrink(minimumScale: 0.7))
        XCTAssertEqual(AmountRowLayout.fit(.shrink(minimumScale: 0.8), at: .accessibility5), .shrink(minimumScale: 0.8))
    }

    // MARK: Days

    func testADayReadsAsDayMonthYearWhateverTheDeviceLocale() {
        XCTAssertEqual(PhoneDateFormat.day(MonthRange.calendar.date(from: DateComponents(year: 2026, month: 1, day: 8))!), "8 Jan 2026")
        XCTAssertEqual(PhoneDateFormat.day(nil), "—")
        XCTAssertEqual(PhoneDateFormat.spoken(nil), "No date")
        XCTAssertEqual(PhoneDateFormat.spoken(MonthRange.calendar.date(from: DateComponents(year: 2026, month: 1, day: 8))!), "8 Jan 2026")
    }

    // MARK: Themes

    func testEveryCatalogueThemeHasAPhoneTheme() {
        XCTAssertEqual(PhoneTheme.all.map(\.id), ThemePalette.all.map(\.id))
        XCTAssertEqual(PhoneTheme.named("no-such-theme").id, "classic")
    }

    /// Income figures stay legible in light mode: at least 4.5:1 on a card (ruling, fix round 1); dark keeps the
    /// theme's own income colour.
    func testLightIncomeReachesFourPointFiveToOneOnACardAndDarkIsUnchanged() {
        for palette in ThemePalette.all {
            let light = PhoneTheme.incomeToken(palette, .light)
            let card = PhoneTheme.opaqueSurface(palette, .light)
            XCTAssertGreaterThanOrEqual(ColorMath.contrastRatio(light, card), 4.5, palette.id)
            XCTAssertEqual(PhoneTheme.incomeToken(palette, .dark), palette.dark.income, palette.id)
        }
        // Classic's system green (about 2.2:1 on white) is darkened, not kept.
        XCTAssertNotEqual(PhoneTheme.incomeToken(ThemePalette.named("classic"), .light), ThemePalette.named("classic").light.income)
    }
}
