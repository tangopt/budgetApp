// Tests/BudgetCoreTests/PayPeriodDetectorTests.swift
import XCTest
@testable import BudgetCore

final class PayPeriodDetectorTests: XCTestCase {
    func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var components = DateComponents()
        components.year = y; components.month = m; components.day = d
        return Calendar(identifier: .gregorian).date(from: components)!
    }

    func testDetectsCadenceFromRegularMonthlyIncome() {
        let dates = [date(2026, 4, 26), date(2026, 5, 26), date(2026, 6, 26)]
        let cadence = PayPeriodDetector.detectCadence(incomeDates: dates)
        XCTAssertNotNil(cadence)
        XCTAssertEqual(cadence!.averageIntervalDays, 30.5, accuracy: 1.0)
        XCTAssertEqual(cadence!.lastPayDate, date(2026, 6, 26))
    }

    func testToleratesWeekendShiftedPaydays() {
        // 26 April 2026 is a Sunday; a real payday would shift to Friday 24th.
        let dates = [date(2026, 3, 26), date(2026, 4, 24), date(2026, 5, 26)]
        let cadence = PayPeriodDetector.detectCadence(incomeDates: dates)
        XCTAssertNotNil(cadence)
    }

    func testReturnsNilWithInsufficientHistory() {
        let cadence = PayPeriodDetector.detectCadence(incomeDates: [date(2026, 6, 26)])
        XCTAssertNil(cadence)
    }

    func testGenerateActualPeriodsProducesConsecutiveNonOverlappingRanges() {
        let dates = [date(2026, 4, 26), date(2026, 5, 26), date(2026, 6, 26)]
        let periods = PayPeriodDetector.generateActualPeriods(incomeDates: dates)
        XCTAssertEqual(periods.count, 3)
        XCTAssertEqual(periods[0].startDate, date(2026, 4, 26))
        XCTAssertEqual(periods[0].endDate, date(2026, 5, 25))
        XCTAssertEqual(periods[1].startDate, date(2026, 5, 26))
        XCTAssertTrue(periods.allSatisfy { $0.type == .actual })
    }

    func testGenerateProjectedPeriodsExtrapolatesForwardToHorizon() {
        let cadence = PayCadence(averageIntervalDays: 30, lastPayDate: date(2026, 6, 26))
        let periods = PayPeriodDetector.generateProjectedPeriods(cadence: cadence, horizon: date(2026, 12, 31))
        XCTAssertTrue(periods.allSatisfy { $0.type == .projected })
        XCTAssertTrue(periods.first!.startDate > date(2026, 6, 26))
        XCTAssertTrue(periods.last!.endDate <= date(2027, 1, 30))
        XCTAssertTrue(periods.last!.startDate <= date(2026, 12, 31))
    }
}
