import XCTest
@testable import BudgetCore

final class ComparisonHorizonTests: XCTestCase {
    private func utc(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        return cal.date(from: DateComponents(year: y, month: m, day: d))!
    }

    func testEndMonths() {
        let today = utc(2026, 10, 7)
        XCTAssertEqual(ComparisonHorizon.endOfThisYear.endMonth(today: today).year, 2026)
        XCTAssertEqual(ComparisonHorizon.endOfThisYear.endMonth(today: today).month, 12)
        XCTAssertEqual(ComparisonHorizon.twoYears.endMonth(today: today).year, 2028)
        XCTAssertEqual(ComparisonHorizon.twoYears.endMonth(today: today).month, 10)
        XCTAssertEqual(ComparisonHorizon.fiveYears.endMonth(today: today).year, 2031)
        XCTAssertEqual(ComparisonHorizon.tenYears.endMonth(today: today).year, 2036)
        XCTAssertEqual(ComparisonHorizon.default, .twoYears)
    }

    func testYearsRunFromTodaysToTheHorizons() {
        let today = utc(2026, 1, 1)
        XCTAssertEqual(ComparisonHorizon.endOfThisYear.years(today: today), [2026])
        XCTAssertEqual(ComparisonHorizon.twoYears.years(today: today), [2026, 2027, 2028])
        XCTAssertEqual(ComparisonHorizon.tenYears.years(today: today).count, 11)
    }

    func testLabels() {
        XCTAssertEqual(ComparisonHorizon.allCases.map(\.label), ["End of this year", "2 years", "5 years", "10 years"])
    }
}
