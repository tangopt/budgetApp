import XCTest
@testable import BudgetCore

/// The loan's projection to its end (synthetic figures only): instalment days, interest at
/// the rate ÷ 12, resets on revision days to the annuity that leaves the balloon, the final
/// instalment repaying the balloon.
final class MortgageProjectionTests: XCTestCase {
    private static func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        MonthRange.calendar.date(from: DateComponents(year: y, month: m, day: d))!
    }

    func testWithoutAFinalDayTheInstalmentRunsUntilRepaid() {
        let result = MortgageProjection.project(.init(owedMinorUnits: 1_000_000, asOf: Self.date(2026, 10, 15), annualRatePercent: 0,
                                                      instalmentMinorUnits: 300_000, paymentDay: 1))
        XCTAssertEqual(result.end, .repaid)
        XCTAssertEqual(result.payments.map(\.date), [Self.date(2026, 11, 1), Self.date(2026, 12, 1), Self.date(2027, 1, 1), Self.date(2027, 2, 1)])
        XCTAssertEqual(result.payments.map(\.owedMinorUnits), [700_000, 400_000, 100_000, 0])
        XCTAssertEqual(result.finalPaymentMinorUnits, 100_000)
        XCTAssertEqual(result.totalInterestMinorUnits, 0)
    }

    func testInterestIsTheRateOverTwelveOnWhatsOwed() {
        // 12% a year: 1% a month.
        let result = MortgageProjection.project(.init(owedMinorUnits: 1_000_000, asOf: Self.date(2026, 1, 1), annualRatePercent: 12,
                                                      instalmentMinorUnits: 510_000, paymentDay: 5))
        XCTAssertEqual(result.payments.map(\.interestMinorUnits), [10_000, 5_000])
        XCTAssertEqual(result.payments.map(\.owedMinorUnits), [500_000, 0])
        XCTAssertEqual(result.payments.last?.paidMinorUnits, 505_000)
        XCTAssertEqual(result.payments.first?.date, Self.date(2026, 1, 5))
    }

    func testTheFinalInstalmentRepaysTheBalloon() {
        let owed = 10_000_000, balloon = 4_000_000, rate = 3.0
        let instalment = Int(BBVAFundMortgageImport.annuityPayment(balance: owed, annualRate: rate, payments: 60, balloon: balloon).rounded())
        let result = MortgageProjection.project(.init(owedMinorUnits: owed, asOf: Self.date(2026, 10, 15), annualRatePercent: rate,
                                                      instalmentMinorUnits: instalment, paymentDay: 1,
                                                      finalInstalmentDate: Self.date(2031, 10, 1), balloonMinorUnits: balloon))
        XCTAssertEqual(result.end, .finalInstalment)
        XCTAssertEqual(result.payments.count, 60)
        XCTAssertEqual(result.finalDate, Self.date(2031, 10, 1))
        XCTAssertEqual(result.payments.last?.owedMinorUnits, 0)
        // The rate held: every reset gives the same instalment (to a cent or two of rounding).
        for payment in result.payments.dropLast() { XCTAssertEqual(payment.paidMinorUnits, instalment, accuracy: 2) }
        // Left before the final instalment: the balloon plus that month's capital.
        let beforeLast = result.payments[result.payments.count - 2].owedMinorUnits
        XCTAssertEqual(result.finalPaymentMinorUnits!, instalment + balloon, accuracy: 300)
        XCTAssertEqual(result.finalPaymentMinorUnits, beforeLast + Int((Double(beforeLast) * rate / 1200).rounded()))
        XCTAssertEqual(result.payments.map(\.owedMinorUnits), result.payments.map(\.owedMinorUnits).sorted(by: >))
    }

    func testTheInstalmentResetsOnTheFirstPaymentAfterARevision() {
        // Paying too little now: the bank resets the instalment at the next revision (1 Jan).
        let result = MortgageProjection.project(.init(owedMinorUnits: 10_000_000, asOf: Self.date(2026, 10, 15), annualRatePercent: 3,
                                                      instalmentMinorUnits: 50_000, paymentDay: 1,
                                                      finalInstalmentDate: Self.date(2036, 10, 1), balloonMinorUnits: 0))
        let paid = result.payments.map(\.paidMinorUnits)
        XCTAssertEqual(Array(paid.prefix(2)), [50_000, 50_000]) // 1 Nov, 1 Dec
        XCTAssertEqual(result.payments[2].date, Self.date(2027, 1, 1))
        XCTAssertGreaterThan(paid[2], 90_000)
        XCTAssertEqual(paid[3], paid[2]) // held until the next revision (and after: the rate doesn't move)
        XCTAssertEqual(result.payments.last?.owedMinorUnits, 0)
        XCTAssertEqual(result.payments.last!.paidMinorUnits, paid[2], accuracy: 300)

        // Other revision months: the reset waits for 1 March.
        let march = MortgageProjection.project(.init(owedMinorUnits: 10_000_000, asOf: Self.date(2026, 10, 15), annualRatePercent: 3,
                                                     instalmentMinorUnits: 50_000, paymentDay: 1,
                                                     finalInstalmentDate: Self.date(2036, 10, 1), revisionMonths: [3, 9]))
        XCTAssertEqual(Array(march.payments.prefix(4).map(\.paidMinorUnits)), [50_000, 50_000, 50_000, 50_000])
        XCTAssertGreaterThan(march.payments[4].paidMinorUnits, 90_000)
        XCTAssertEqual(march.payments[4].date, Self.date(2027, 3, 1))
    }

    func testShortMonthsAndAnOddFinalDay() {
        let result = MortgageProjection.project(.init(owedMinorUnits: 500_000, asOf: Self.date(2027, 1, 31), annualRatePercent: 0,
                                                      instalmentMinorUnits: 100_000, paymentDay: 31, finalInstalmentDate: Self.date(2027, 4, 15)))
        XCTAssertEqual(result.payments.map(\.date), [Self.date(2027, 2, 28), Self.date(2027, 3, 31), Self.date(2027, 4, 15)])
        XCTAssertEqual(result.payments.last?.paidMinorUnits, 300_000) // what the two instalments left
        XCTAssertEqual(result.payments.last?.owedMinorUnits, 0)
    }

    func testNothingToProjectOrNeverRepaid() {
        XCTAssertEqual(MortgageProjection.project(.init(owedMinorUnits: 0, asOf: Self.date(2026, 1, 1), annualRatePercent: 3,
                                                        instalmentMinorUnits: 1, paymentDay: 1)).end, .nothingToProject)
        XCTAssertEqual(MortgageProjection.project(.init(owedMinorUnits: 100_000, asOf: Self.date(2026, 1, 1), annualRatePercent: 3,
                                                        instalmentMinorUnits: 1, paymentDay: 1, finalInstalmentDate: Self.date(2025, 1, 1))).end,
                       .nothingToProject)
        let never = MortgageProjection.project(.init(owedMinorUnits: 10_000_000, asOf: Self.date(2026, 1, 1), annualRatePercent: 6,
                                                     instalmentMinorUnits: 40_000, paymentDay: 1))
        XCTAssertEqual(never.end, .neverRepaid)
        XCTAssertTrue(never.payments.isEmpty)
        XCTAssertNil(never.finalPaymentMinorUnits)
    }

    func testAFinalDayPastTheHorizonIsNotProjected() {
        let result = MortgageProjection.project(.init(owedMinorUnits: 10_000_000, asOf: Self.date(2026, 1, 1), annualRatePercent: 3,
                                                      instalmentMinorUnits: 50_000, paymentDay: 1, finalInstalmentDate: Self.date(2080, 1, 1)))
        XCTAssertEqual(result.end, .neverRepaid)
        XCTAssertTrue(result.payments.isEmpty)
        // At the horizon exactly: projected.
        let edge = MortgageProjection.project(.init(owedMinorUnits: 10_000_000, asOf: Self.date(2026, 1, 1), annualRatePercent: 3,
                                                    instalmentMinorUnits: 50_000, paymentDay: 1, finalInstalmentDate: Self.date(2076, 1, 1)))
        XCTAssertEqual(edge.end, .finalInstalment)
        XCTAssertEqual(edge.payments.count, MortgageProjection.maxPayments)
    }
}
