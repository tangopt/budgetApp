// Tests/BudgetCoreTests/RecurrenceEndTests.swift
import XCTest
@testable import BudgetCore

final class RecurrenceEndTests: XCTestCase {
    private func utc(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal.date(from: DateComponents(year: y, month: m, day: d))!
    }

    func testMonthlyAnchoredAtMonthEndClampsShortMonths() {
        let start = utc(2026, 1, 31)
        XCTAssertEqual(RecurrenceEnd.endDate(start: start, frequency: .monthly, interval: 1, anchorDay: 31, occurrences: 3), utc(2026, 3, 31))
        XCTAssertEqual(RecurrenceEnd.endDate(start: start, frequency: .monthly, interval: 1, anchorDay: 31, occurrences: 2), utc(2026, 2, 28))
    }

    func testWeeklyEveryTwoWeeks() {
        XCTAssertEqual(RecurrenceEnd.endDate(start: utc(2026, 1, 1), frequency: .weekly, interval: 2, anchorDay: nil, occurrences: 3), utc(2026, 1, 29))
    }

    func testAnnually() {
        XCTAssertEqual(RecurrenceEnd.endDate(start: utc(2026, 6, 15), frequency: .annually, interval: 1, anchorDay: nil, occurrences: 2), utc(2027, 6, 15))
    }

    func testQuarterlyViaMonthlyInterval() {
        XCTAssertEqual(RecurrenceEnd.endDate(start: utc(2026, 1, 1), frequency: .monthly, interval: 3, anchorDay: nil, occurrences: 4), utc(2026, 10, 1))
    }

    func testSingleOccurrenceAndOnceReturnStart() {
        let start = utc(2026, 4, 10)
        XCTAssertEqual(RecurrenceEnd.endDate(start: start, frequency: .monthly, interval: 1, anchorDay: nil, occurrences: 1), start)
        XCTAssertEqual(RecurrenceEnd.endDate(start: start, frequency: .once, interval: 1, anchorDay: nil, occurrences: 5), start)
    }
}
