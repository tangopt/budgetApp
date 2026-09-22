// Tests/BudgetCoreTests/FrequencyExpanderTests.swift
import XCTest
@testable import BudgetCore

final class FrequencyExpanderTests: XCTestCase {
    func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var c = DateComponents(); c.year = y; c.month = m; c.day = d
        return Calendar(identifier: .gregorian).date(from: c)!
    }

    func makeEntry(frequency: ForecastFrequency, interval: Int, startDate: Date, endDate: Date? = nil, amount: Int = 1000) -> ForecastEntry {
        ForecastEntry(groupId: 1, categoryId: 1, amountMinorUnits: amount, frequency: frequency, interval: interval, startDate: startDate, endDate: endDate, isEnabled: true, status: .auto, note: nil)
    }

    func testOnceOccursExactlyOnStartDateIfWithinPeriod() {
        let entry = makeEntry(frequency: .once, interval: 1, startDate: date(2026, 8, 15))
        let period = PayPeriod(startDate: date(2026, 7, 26), endDate: date(2026, 8, 25), type: .projected)
        XCTAssertEqual(FrequencyExpander.occurrences(for: entry, in: period), [date(2026, 8, 15)])
        XCTAssertEqual(FrequencyExpander.amount(for: entry, in: period), 1000)
    }

    func testOnceOutsidePeriodProducesNoOccurrences() {
        let entry = makeEntry(frequency: .once, interval: 1, startDate: date(2026, 9, 15))
        let period = PayPeriod(startDate: date(2026, 7, 26), endDate: date(2026, 8, 25), type: .projected)
        XCTAssertEqual(FrequencyExpander.occurrences(for: entry, in: period), [])
    }

    func testMonthlyOccursOnceInAMatchingPeriod() {
        let entry = makeEntry(frequency: .monthly, interval: 1, startDate: date(2026, 6, 26))
        let period = PayPeriod(startDate: date(2026, 8, 26), endDate: date(2026, 9, 25), type: .projected)
        XCTAssertEqual(FrequencyExpander.occurrences(for: entry, in: period), [date(2026, 8, 26)])
    }

    func testEveryTwoMonthsSkipsAlternatePeriods() {
        let entry = makeEntry(frequency: .monthly, interval: 2, startDate: date(2026, 6, 26))
        let matchingPeriod = PayPeriod(startDate: date(2026, 8, 26), endDate: date(2026, 9, 25), type: .projected)
        let skippedPeriod = PayPeriod(startDate: date(2026, 7, 26), endDate: date(2026, 8, 25), type: .projected)
        XCTAssertEqual(FrequencyExpander.occurrences(for: entry, in: matchingPeriod).count, 1)
        XCTAssertEqual(FrequencyExpander.occurrences(for: entry, in: skippedPeriod).count, 0)
    }

    func testWeeklyCanOccurMultipleTimesInOnePeriod() {
        let entry = makeEntry(frequency: .weekly, interval: 1, startDate: date(2026, 7, 26), amount: 500)
        let period = PayPeriod(startDate: date(2026, 7, 26), endDate: date(2026, 8, 25), type: .projected)
        let occurrences = FrequencyExpander.occurrences(for: entry, in: period)
        XCTAssertEqual(occurrences.count, 5) // 30-day period / 7-day interval
        XCTAssertEqual(FrequencyExpander.amount(for: entry, in: period), 2500)
    }

    func testRespectsEndDate() {
        let entry = makeEntry(frequency: .monthly, interval: 1, startDate: date(2026, 6, 26), endDate: date(2026, 8, 1))
        let period = PayPeriod(startDate: date(2026, 8, 26), endDate: date(2026, 9, 25), type: .projected)
        XCTAssertEqual(FrequencyExpander.occurrences(for: entry, in: period), [])
    }
}
