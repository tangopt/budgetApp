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

    // MARK: - Final-review fixes (UTC dates, matching the UTC-pinned statement parsers)

    func utcDate(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal.date(from: DateComponents(year: y, month: m, day: d))!
    }

    // I2: projected periods step by calendar month keeping the payday's day-of-month,
    // instead of drifting by a fixed day count.
    func testProjectedPeriodsKeepDayOfMonthAcrossFebruary() {
        let cadence = PayCadence(averageIntervalDays: 30.4, lastPayDate: utcDate(2026, 1, 26))
        let periods = PayPeriodDetector.generateProjectedPeriods(cadence: cadence, horizon: utcDate(2026, 6, 1))
        XCTAssertEqual(periods.map(\.startDate), [utcDate(2026, 2, 26), utcDate(2026, 3, 26), utcDate(2026, 4, 26), utcDate(2026, 5, 26)])
        XCTAssertEqual(periods[0].endDate, utcDate(2026, 3, 25))
        XCTAssertEqual(periods.last!.endDate, utcDate(2026, 6, 25))
    }

    func testProjectedPeriodsFromMonthEndAnchorDoNotDriftPermanently() {
        let cadence = PayCadence(averageIntervalDays: 30.4, lastPayDate: utcDate(2026, 1, 31))
        let periods = PayPeriodDetector.generateProjectedPeriods(cadence: cadence, horizon: utcDate(2026, 4, 30))
        XCTAssertEqual(periods.map(\.startDate), [utcDate(2026, 2, 28), utcDate(2026, 3, 31), utcDate(2026, 4, 30)])
        XCTAssertEqual(periods[0].endDate, utcDate(2026, 3, 30))
    }

    // I2 (probe scenario): a monthly forecast entry fires exactly once in every projected
    // period across a February boundary. With the old fixed 30-day stepping
    // (26 Jan → 25 Feb → 27 Mar → 26 Apr) the Feb and Mar periods each caught a
    // different number of occurrences.
    func testMonthlyForecastFiresOncePerProjectedPeriodAcrossFebruary() {
        let cadence = PayCadence(averageIntervalDays: 30, lastPayDate: utcDate(2026, 1, 26))
        let periods = PayPeriodDetector.generateProjectedPeriods(cadence: cadence, horizon: utcDate(2026, 12, 31))
        let rentOnThe26th = ForecastEntry(groupId: 1, categoryId: 1, amountMinorUnits: -280000, frequency: .monthly, interval: 1, startDate: utcDate(2026, 1, 26), endDate: nil, isEnabled: true, status: .auto, note: nil)
        let billOnThe31st = ForecastEntry(groupId: 1, categoryId: 2, amountMinorUnits: -1000, frequency: .monthly, interval: 1, startDate: utcDate(2026, 1, 31), endDate: nil, isEnabled: true, status: .auto, note: nil)
        XCTAssertEqual(periods.count, 11)
        for period in periods {
            XCTAssertEqual(FrequencyExpander.occurrences(for: rentOnThe26th, in: period).count, 1, "rent in period starting \(period.startDate)")
            XCTAssertEqual(FrequencyExpander.occurrences(for: billOnThe31st, in: period).count, 1, "31st bill in period starting \(period.startDate)")
        }
    }

    func testOpenActualPeriodEndsTheDayBeforeFirstProjectedPeriod() {
        let dates = [utcDate(2026, 4, 26), utcDate(2026, 5, 26), utcDate(2026, 6, 26)]
        let actual = PayPeriodDetector.generateActualPeriods(incomeDates: dates)
        let projected = PayPeriodDetector.generateProjectedPeriods(cadence: PayPeriodDetector.detectCadence(incomeDates: dates)!, horizon: utcDate(2026, 9, 1))
        XCTAssertEqual(actual.last!.startDate, utcDate(2026, 6, 26))
        XCTAssertEqual(actual.last!.endDate, utcDate(2026, 7, 25))
        XCTAssertEqual(projected.first!.startDate, utcDate(2026, 7, 26))
    }

    // C6: same-day duplicate paydays previously produced a period ending before it
    // started and a duplicate startDate (breaking ForEach(periods, id: \.startDate)).
    func testSameDayDuplicatePaydaysProduceUniqueWellFormedPeriods() {
        let dates = [utcDate(2026, 4, 26), utcDate(2026, 5, 26), utcDate(2026, 5, 26), utcDate(2026, 6, 26)]
        let periods = PayPeriodDetector.allPeriods(incomeDates: dates, horizon: utcDate(2026, 10, 1))
        XCTAssertEqual(Set(periods.map(\.startDate)).count, periods.count)
        XCTAssertTrue(periods.allSatisfy { $0.endDate >= $0.startDate })
        XCTAssertEqual(periods.filter { $0.type == .actual }.map(\.startDate), [utcDate(2026, 4, 26), utcDate(2026, 5, 26), utcDate(2026, 6, 26)])
    }

    func testNearbyExtraPaydayIsCollapsedIntoTheSamePeriod() {
        // A second salary-sized credit 3 days after payday must not split the period.
        let dates = [utcDate(2026, 4, 26), utcDate(2026, 5, 26), utcDate(2026, 5, 29), utcDate(2026, 6, 26)]
        XCTAssertEqual(PayPeriodDetector.paydayAnchors(dates), [utcDate(2026, 4, 26), utcDate(2026, 5, 26), utcDate(2026, 6, 26)])
        XCTAssertNotNil(PayPeriodDetector.detectCadence(incomeDates: dates))
    }

    // C6 (probe scenario): a bonus and a refund on non-payday dates, plus a bonus on
    // payday itself, must not create extra periods — only the "Income" (salary)
    // category is a payday signal.
    func testPaydaySourceUsesOnlySalaryCategory() {
        let categories = [
            Category(id: 1, name: "Income", type: .income),
            Category(id: 2, name: "Bonus", type: .income),
            Category(id: 3, name: "Other income/refunds", type: .income),
            Category(id: 4, name: "Rent", type: .expense)
        ]
        func tx(_ id: Int64, _ date: Date, _ amount: Int, _ categoryId: Int64, status: TransactionStatus = .confirmed) -> Transaction {
            Transaction(id: id, importBatchId: 1, accountId: 1, date: date, rawDescription: "T\(id)", amountMinorUnits: amount, categoryId: categoryId, status: status, categorizedBy: .manual, fingerprint: "f\(id)")
        }
        let transactions = [
            tx(1, utcDate(2026, 4, 26), 280000, 1),
            tx(2, utcDate(2026, 5, 26), 280000, 1),
            tx(3, utcDate(2026, 6, 26), 285000, 1),
            tx(4, utcDate(2026, 5, 10), 50000, 2),   // bonus, off-payday
            tx(5, utcDate(2026, 6, 26), 100000, 2),  // bonus, same day as salary
            tx(6, utcDate(2026, 6, 3), 2500, 3),     // refund
            tx(7, utcDate(2026, 6, 12), 500, 1),     // tiny credit miscategorised as Income
            tx(8, utcDate(2026, 6, 1), -180000, 4),  // rent
            tx(9, utcDate(2026, 3, 26), 280000, 1, status: .pendingReview)
        ]
        let paydays = PaydaySource.paydayDates(transactions: transactions, categories: categories)
        XCTAssertEqual(paydays, [utcDate(2026, 4, 26), utcDate(2026, 5, 26), utcDate(2026, 6, 26)])

        let periods = PayPeriodDetector.allPeriods(incomeDates: paydays, horizon: utcDate(2026, 9, 30))
        XCTAssertEqual(periods.filter { $0.type == .actual }.count, 3)
        XCTAssertEqual(Set(periods.map(\.startDate)).count, periods.count)
        XCTAssertTrue(periods.allSatisfy { $0.endDate >= $0.startDate })
    }

    func testPaydaySourceReturnsEmptyWithoutSalaryCategory() {
        let categories = [Category(id: 2, name: "Bonus", type: .income)]
        let transactions = [Transaction(id: 1, importBatchId: 1, accountId: 1, date: utcDate(2026, 5, 10), rawDescription: "B", amountMinorUnits: 50000, categoryId: 2, status: .confirmed, categorizedBy: .manual, fingerprint: "b")]
        XCTAssertEqual(PaydaySource.paydayDates(transactions: transactions, categories: categories), [])
    }
}
