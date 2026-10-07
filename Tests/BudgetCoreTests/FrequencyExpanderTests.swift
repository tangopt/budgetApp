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

    /// Regression test for a bug where `endDate` carried a raw `Date` from a date-only
    /// `DatePicker` (whatever time-of-day the picker's initial value happened to have —
    /// "now", or an existing entry's stored time). The add sheets fix this
    /// by always storing 23:59:59 UTC on the picked calendar day. This test
    /// verifies that once `endDate` is normalized that way, the final intended occurrence
    /// — which itself lands at 00:00:00 UTC on the very same calendar day, since every
    /// occurrence here is stepped from a midnight `startDate` — is still included, i.e.
    /// isn't dropped by an off-by-a-few-hours comparison between the occurrence's own
    /// timestamp and a mis-normalized end date.
    func testEndDateNormalizedToEndOfDayIncludesFinalOccurrence() {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        func d(_ y: Int, _ m: Int, _ day: Int) -> Date { utc.date(from: DateComponents(year: y, month: m, day: day))! }
        // The final intended occurrence is Aug 26, 2026 (start Jun 26 + 2 monthly steps).
        let normalizedEndOfDay: Date = {
            var components = utc.dateComponents([.year, .month, .day], from: d(2026, 8, 26))
            components.hour = 23; components.minute = 59; components.second = 59
            return utc.date(from: components)!
        }()
        let entry = makeEntry(frequency: .monthly, interval: 1, startDate: d(2026, 6, 26), endDate: normalizedEndOfDay)
        let period = PayPeriod(startDate: d(2026, 8, 1), endDate: d(2026, 8, 31), type: .projected)
        XCTAssertEqual(FrequencyExpander.occurrences(for: entry, in: period), [d(2026, 8, 26)])
    }

    func testMonthEndStartDateDoesNotDriftAfterFebruary() {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        func d(_ y: Int, _ m: Int, _ day: Int) -> Date { utc.date(from: DateComponents(year: y, month: m, day: day))! }
        let entry = makeEntry(frequency: .monthly, interval: 1, startDate: d(2026, 1, 31))
        let period = PayPeriod(startDate: d(2026, 1, 1), endDate: d(2026, 5, 31), type: .projected)
        XCTAssertEqual(FrequencyExpander.occurrences(for: entry, in: period), [d(2026, 1, 31), d(2026, 2, 28), d(2026, 3, 31), d(2026, 4, 30), d(2026, 5, 31)])
    }

    // MARK: - Anchor day

    private func utc(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        return cal.date(from: DateComponents(year: y, month: m, day: d))!
    }

    func testMonthlyAnchorDayRestoresMonthEnd() {
        var entry = makeEntry(frequency: .monthly, interval: 1, startDate: utc(2027, 2, 28))
        entry.anchorDay = 31
        let period = PayPeriod(startDate: utc(2027, 2, 1), endDate: utc(2027, 5, 31), type: .projected)
        XCTAssertEqual(FrequencyExpander.occurrences(for: entry, in: period), [utc(2027, 2, 28), utc(2027, 3, 31), utc(2027, 4, 30), utc(2027, 5, 31)])
    }

    func testAnnualAnchorDayOn29February() {
        var entry = makeEntry(frequency: .annually, interval: 1, startDate: utc(2027, 2, 28))
        entry.anchorDay = 29
        let period = PayPeriod(startDate: utc(2027, 1, 1), endDate: utc(2029, 12, 31), type: .projected)
        XCTAssertEqual(FrequencyExpander.occurrences(for: entry, in: period), [utc(2027, 2, 28), utc(2028, 2, 29), utc(2029, 2, 28)])
    }

    func testNoAnchorDayUsesTheStartDay() {
        let entry = makeEntry(frequency: .monthly, interval: 1, startDate: utc(2027, 1, 31))
        let period = PayPeriod(startDate: utc(2027, 1, 1), endDate: utc(2027, 4, 30), type: .projected)
        XCTAssertEqual(FrequencyExpander.occurrences(for: entry, in: period), [utc(2027, 1, 31), utc(2027, 2, 28), utc(2027, 3, 31), utc(2027, 4, 30)])
    }

    func testAnchorBeforeStartDayNeverYieldsADateBeforeStart() {
        var entry = makeEntry(frequency: .monthly, interval: 1, startDate: utc(2026, 10, 15))
        entry.anchorDay = 1
        let period = PayPeriod(startDate: utc(2026, 9, 1), endDate: utc(2026, 12, 31), type: .projected)
        let dates = FrequencyExpander.occurrences(for: entry, in: period)
        XCTAssertTrue(dates.allSatisfy { $0 >= entry.startDate })
        XCTAssertEqual(dates, [utc(2026, 11, 1), utc(2026, 12, 1)])
    }
}
