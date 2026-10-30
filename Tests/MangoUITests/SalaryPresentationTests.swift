import XCTest
@testable import BudgetCore
@testable import MangoUI

/// The salary calculator's layout rules and words (design review §3.4): tabs, the pinned strip, the other unit under
/// £/%, the "Where the money goes" rows and when rows stack.
final class SalaryPresentationTests: XCTestCase {
    private func inputs(gross: Int, bonus: Int = 0, bonusPercentBP: Int? = nil) -> SalaryInputs {
        SalaryInputs(grossAnnual: gross, bonusAnnual: bonus, taxYearStart: 2026, bonusPercentBP: bonusPercentBP)
    }

    func testTheIPhoneHasTwoTabsAndTheIPadShowsBothAtOnce() {
        XCTAssertEqual(SalaryPresentation.Tab.allCases.map(\.rawValue), ["Inputs", "Results"])
        XCTAssertFalse(SalaryPresentation.showsSideBySide(width: 393))
        XCTAssertFalse(SalaryPresentation.showsSideBySide(width: 699))
        XCTAssertTrue(SalaryPresentation.showsSideBySide(width: 834))
        XCTAssertFalse(SalaryPresentation.showsSideBySide(width: 834, size: .accessibility3), "tabs at accessibility sizes")
    }

    func testTheStripSaysWhatTheNewSalaryKeeps() {
        XCTAssertEqual(SalaryPresentation.stripText(annualDifference: 312_000), "New keeps +£3,120.00 a year")
        XCTAssertEqual(SalaryPresentation.stripText(annualDifference: -48_000), "New keeps \u{2212}£480.00 a year")
        XCTAssertEqual(SalaryPresentation.stripText(annualDifference: 0), "New keeps the same a year")
    }

    func testTheBonusShowsTheOtherUnit() {
        // 10% of £52,000.
        XCTAssertEqual(SalaryPresentation.bonusOtherUnit(inputs(gross: 5_200_000, bonusPercentBP: 1_000)), "= £5,200.00")
        // £5,200 of £52,000.
        XCTAssertEqual(SalaryPresentation.bonusOtherUnit(inputs(gross: 5_200_000, bonus: 520_000)), "= 10%")
        XCTAssertEqual(SalaryPresentation.bonusOtherUnit(inputs(gross: 4_000_000, bonus: 500_000)), "= 12.5%")
        XCTAssertEqual(SalaryPresentation.bonusOtherUnit(inputs(gross: 0, bonus: 500_000)), "= 0%")
        XCTAssertEqual(SalaryPresentation.bonusOtherUnit(inputs(gross: 4_000_000)), "= 0%")
    }

    func testThePensionShowsTheOtherUnit() {
        XCTAssertEqual(SalaryPresentation.pensionOtherUnit(.percentOfGross(basisPoints: 500), gross: 5_200_000), "= £2,600.00")
        XCTAssertEqual(SalaryPresentation.pensionOtherUnit(.fixedAnnual(pence: 260_000), gross: 5_200_000), "= 5%")
        XCTAssertEqual(SalaryPresentation.pensionOtherUnit(.percentOfGross(basisPoints: 0), gross: 5_200_000), "= £0.00")
    }

    func testEachBarIsOneHundredPercentAndTheDifferenceIsNewMinusCurrent() {
        let current = SalaryCalculator.calculate(inputs(gross: 4_000_000))
        var offerInputs = inputs(gross: 5_200_000)
        offerInputs.pension = .percentOfGross(basisPoints: 500)
        let offer = SalaryCalculator.calculate(offerInputs)
        let rows = SalaryPresentation.flowRows(.make(current: current, offer: offer))
        XCTAssertEqual(rows.first?.label, "Take-home")
        XCTAssertEqual(rows.map(\.currentShare).reduce(0, +), 1, accuracy: 0.0001)
        XCTAssertEqual(rows.map(\.newShare).reduce(0, +), 1, accuracy: 0.0001)
        for row in rows { XCTAssertEqual(row.difference, row.new - row.current) }
        XCTAssertEqual(rows.first { $0.label == "Take-home" }?.difference, offer.takeHomeAnnual - current.takeHomeAnnual)
        // The new salary pays a pension; the current doesn't, yet its row is there for the comparison.
        XCTAssertEqual(rows.first { $0.label == "Pension" }?.current, 0)
    }

    func testRowsStackFromTheLargestRegularSizeUp() {
        XCTAssertFalse(SalaryPresentation.stacksRows(at: .large))
        XCTAssertTrue(SalaryPresentation.stacksRows(at: .xxxLarge))
        XCTAssertTrue(SalaryPresentation.stacksRows(at: .accessibility3))
    }
}
