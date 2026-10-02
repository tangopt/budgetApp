import XCTest
@testable import BudgetCore

final class MonthBlendTests: XCTestCase {
    private func utc(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: DateComponents(year: y, month: m, day: d))!
    }

    func testClassifiesActualBlendedAndForecastMonths() {
        let dataThrough = utc(2026, 10, 13), today = utc(2026, 10, 14)
        XCTAssertEqual(MonthBlend.classify(year: 2025, month: 12, dataThrough: dataThrough, today: today), .actual)
        XCTAssertEqual(MonthBlend.classify(year: 2026, month: 9, dataThrough: dataThrough, today: today), .actual)
        XCTAssertEqual(MonthBlend.classify(year: 2026, month: 10, dataThrough: dataThrough, today: today), .blended)
        XCTAssertEqual(MonthBlend.classify(year: 2026, month: 11, dataThrough: dataThrough, today: today), .forecast)
        XCTAssertEqual(MonthBlend.classify(year: 2027, month: 1, dataThrough: dataThrough, today: today), .forecast)
    }

    func testNothingImportedThisMonthMakesTheCurrentMonthForecast() {
        let dataThrough = utc(2026, 9, 29), today = utc(2026, 10, 2)
        XCTAssertEqual(MonthBlend.classify(year: 2026, month: 9, dataThrough: dataThrough, today: today), .actual)
        XCTAssertEqual(MonthBlend.classify(year: 2026, month: 10, dataThrough: dataThrough, today: today), .forecast)
    }

    func testStaleDataTreatsTheGapMonthsAsForecast() {
        let dataThrough = utc(2026, 2, 14), today = utc(2026, 10, 2)
        XCTAssertEqual(MonthBlend.classify(year: 2026, month: 2, dataThrough: dataThrough, today: today), .actual)
        XCTAssertEqual(MonthBlend.classify(year: 2026, month: 3, dataThrough: dataThrough, today: today), .forecast)
        XCTAssertEqual(MonthBlend.classify(year: 2026, month: 10, dataThrough: dataThrough, today: today), .forecast)
    }

    func testNoDataAtAllIsForecast() {
        XCTAssertEqual(MonthBlend.classify(year: 2026, month: 10, dataThrough: nil, today: utc(2026, 10, 2)), .forecast)
    }

    // A clock behind the data never makes a later data month "forecast".
    func testDataAfterTodayIsTreatedAsToday() {
        let dataThrough = utc(2026, 10, 20), today = utc(2026, 10, 5)
        XCTAssertEqual(MonthBlend.classify(year: 2026, month: 9, dataThrough: dataThrough, today: today), .actual)
        XCTAssertEqual(MonthBlend.classify(year: 2026, month: 10, dataThrough: dataThrough, today: today), .blended)
        XCTAssertEqual(MonthBlend.classify(year: 2026, month: 11, dataThrough: dataThrough, today: today), .forecast)
    }

    // The data month is later than the clock's month: the clock is clamped up to the data, so
    // that later month is the (blended) current month and the clock's own month is history.
    // Without the `max(today, dataThrough)` clamp October would be forecast and November actual.
    func testDataInALaterMonthThanTodayMakesThatLaterMonthTheBlendedOne() {
        let dataThrough = utc(2026, 11, 3), today = utc(2026, 10, 28)
        XCTAssertEqual(MonthBlend.classify(year: 2026, month: 9, dataThrough: dataThrough, today: today), .actual)
        XCTAssertEqual(MonthBlend.classify(year: 2026, month: 10, dataThrough: dataThrough, today: today), .actual)
        XCTAssertEqual(MonthBlend.classify(year: 2026, month: 11, dataThrough: dataThrough, today: today), .blended)
        XCTAssertEqual(MonthBlend.classify(year: 2026, month: 12, dataThrough: dataThrough, today: today), .forecast)
    }

    func testActualAndForecastMonthsPassTheirOwnValueThrough() {
        XCTAssertEqual(MonthBlend.projectedTotal(actual: -500, expected: -850, categoryType: .expense, monthClass: .actual), -500)
        XCTAssertEqual(MonthBlend.projectedTotal(actual: -500, expected: -850, categoryType: .expense, monthClass: .forecast), -850)
    }

    func testBlendedIncomeTakesTheLarger() {
        XCTAssertEqual(MonthBlend.projectedTotal(actual: 100, expected: 300, categoryType: .income, monthClass: .blended), 300)
        XCTAssertEqual(MonthBlend.projectedTotal(actual: 400, expected: 300, categoryType: .income, monthClass: .blended), 400)
        XCTAssertEqual(MonthBlend.projectedTotal(actual: 100, expected: 0, categoryType: .income, monthClass: .blended), 100)
    }

    func testBlendedExpenseTakesTheLargerSpend() {
        // Signed: spend is negative, so the larger spend is the smaller (more negative) number.
        XCTAssertEqual(MonthBlend.projectedTotal(actual: -500, expected: -850, categoryType: .expense, monthClass: .blended), -850)
        XCTAssertEqual(MonthBlend.projectedTotal(actual: -900, expected: -850, categoryType: .expense, monthClass: .blended), -900)
        XCTAssertEqual(MonthBlend.projectedTotal(actual: 50, expected: -850, categoryType: .expense, monthClass: .blended), -850) // a refund
        XCTAssertEqual(MonthBlend.projectedTotal(actual: -25, expected: 0, categoryType: .expense, monthClass: .blended), -25) // unplanned
    }
}
