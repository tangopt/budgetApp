import XCTest
@testable import BudgetCore

final class ForecastProjectorTests: XCTestCase {
    private func utc(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: DateComponents(year: y, month: m, day: d))!
    }

    // Salary +3,000 on the 25th, rent -1,000 on the 1st, a transfer that must NOT count: +2,000/month.
    // The arrays are built inline as call arguments (never named with a `[Category]` type —
    // a bare `Category` annotation is ambiguous in this test target).
    private func projection(start: Int, latest: (year: Int, month: Int), through year: Int, exceptions: [PlannedOccurrenceException] = []) -> [NetWorthPoint] {
        ForecastProjector.monthlyProjection(
            startingNetWorth: start, latestRealMonth: latest, throughYear: year,
            categories: [Category(id: 1, name: "Salary", type: .income), Category(id: 2, name: "Rent", type: .expense), Category(id: 3, name: "Savings", type: .transfer)],
            entries: [
                ForecastEntry(id: 1, groupId: 1, categoryId: 1, amountMinorUnits: 300_000, frequency: .monthly, interval: 1, startDate: utc(2026, 1, 25), endDate: nil, isEnabled: true, status: .manual, note: nil),
                ForecastEntry(id: 2, groupId: 1, categoryId: 2, amountMinorUnits: -100_000, frequency: .monthly, interval: 1, startDate: utc(2026, 1, 1), endDate: nil, isEnabled: true, status: .manual, note: nil),
                ForecastEntry(id: 3, groupId: 1, categoryId: 3, amountMinorUnits: -50_000, frequency: .monthly, interval: 1, startDate: utc(2026, 1, 10), endDate: nil, isEnabled: true, status: .manual, note: nil)
            ],
            groups: [ForecastGroup(id: 1, name: "G", note: nil, isEnabled: true, isSystemManaged: false)],
            exceptions: exceptions
        )
    }

    private func forecast(start: Int, latest: (year: Int, month: Int), atEndOf year: Int, exceptions: [PlannedOccurrenceException] = []) -> Int {
        ForecastProjector.forecastNetWorth(
            startingNetWorth: start, latestRealMonth: latest, atEndOf: year,
            categories: [Category(id: 1, name: "Salary", type: .income), Category(id: 2, name: "Rent", type: .expense), Category(id: 3, name: "Savings", type: .transfer)],
            entries: [
                ForecastEntry(id: 1, groupId: 1, categoryId: 1, amountMinorUnits: 300_000, frequency: .monthly, interval: 1, startDate: utc(2026, 1, 25), endDate: nil, isEnabled: true, status: .manual, note: nil),
                ForecastEntry(id: 2, groupId: 1, categoryId: 2, amountMinorUnits: -100_000, frequency: .monthly, interval: 1, startDate: utc(2026, 1, 1), endDate: nil, isEnabled: true, status: .manual, note: nil),
                ForecastEntry(id: 3, groupId: 1, categoryId: 3, amountMinorUnits: -50_000, frequency: .monthly, interval: 1, startDate: utc(2026, 1, 10), endDate: nil, isEnabled: true, status: .manual, note: nil)
            ],
            groups: [ForecastGroup(id: 1, name: "G", note: nil, isEnabled: true, isSystemManaged: false)],
            exceptions: exceptions
        )
    }

    func testProjectionAccumulatesMonthlyImpactAfterTheLatestRealMonth() {
        let points = projection(start: 1_000_000, latest: (2026, 2), through: 2026)
        XCTAssertEqual(points.count, 10) // March ... December
        XCTAssertEqual(points.first, NetWorthPoint(year: 2026, month: 3, valueMinorUnits: 1_200_000))
        XCTAssertEqual(points.last, NetWorthPoint(year: 2026, month: 12, valueMinorUnits: 3_000_000))
    }

    func testForecastNetWorthMatchesTheDecemberPointAcrossYears() {
        XCTAssertEqual(forecast(start: 1_000_000, latest: (2026, 2), atEndOf: 2026), 3_000_000)
        XCTAssertEqual(forecast(start: 1_000_000, latest: (2026, 2), atEndOf: 2027), 5_400_000)
    }

    func testNoMonthsToWalkReturnsTheStartingValue() {
        XCTAssertTrue(projection(start: 1_000_000, latest: (2026, 12), through: 2026).isEmpty)
        XCTAssertEqual(forecast(start: 1_000_000, latest: (2026, 12), atEndOf: 2026), 1_000_000)
    }

    func testProjectionRollsOverTheYearBoundary() {
        let points = projection(start: 0, latest: (2025, 11), through: 2026)
        // Dec 2025 has no entries yet (they start Jan 2026) → +0; then 12 months of +2,000.
        XCTAssertEqual(points.count, 13)
        XCTAssertEqual(points[0], NetWorthPoint(year: 2025, month: 12, valueMinorUnits: 0))
        XCTAssertEqual(points.last, NetWorthPoint(year: 2026, month: 12, valueMinorUnits: 2_400_000))
    }

    func testProjectionHonoursAnAmountOverride() {
        // Salary on 25 Mar 2026 is 2,500 instead of 3,000: March ends 500 lower, and so does every later point.
        let override = PlannedOccurrenceException(entryId: 1, originalDate: utc(2026, 3, 25), amountMinorUnits: 250_000)
        let points = projection(start: 1_000_000, latest: (2026, 2), through: 2026, exceptions: [override])
        XCTAssertEqual(points.first, NetWorthPoint(year: 2026, month: 3, valueMinorUnits: 1_150_000))
        XCTAssertEqual(points.last, NetWorthPoint(year: 2026, month: 12, valueMinorUnits: 2_950_000))
        XCTAssertEqual(forecast(start: 1_000_000, latest: (2026, 2), atEndOf: 2026, exceptions: [override]), 2_950_000)
    }
}
