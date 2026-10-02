import XCTest
@testable import BudgetCore

final class DashboardNetWorthTests: XCTestCase {
    private typealias F = DashboardFixture
    private func date(_ y: Int, _ m: Int, _ d: Int) -> Date { F.date(y, m, d) }

    private var series2026Input: DashboardInput {
        F.input(
            today: date(2026, 4, 15),
            snapshots: [F.snapshot(1, date(2025, 12, 1), 1_000_000), F.snapshot(1, date(2026, 1, 1), 1_100_000), F.snapshot(1, date(2026, 2, 1), 1_200_000)],
            transactions: [F.txn(1, date(2026, 2, 10), -1_000, category: F.rentId)],
            entries: F.salaryAndRent
        )
    }

    func testActualSeriesRunsFromTheFirstSnapshotMonthToTheDataMonth() {
        let series = DashboardCalculator.netWorthSeries(series2026Input)
        XCTAssertEqual(series.actual, [
            NetWorthPoint(year: 2025, month: 12, valueMinorUnits: 1_000_000),
            NetWorthPoint(year: 2026, month: 1, valueMinorUnits: 1_100_000),
            NetWorthPoint(year: 2026, month: 2, valueMinorUnits: 1_200_000)
        ])
        XCTAssertEqual(series.currentNetWorthMinorUnits, 1_200_000)
        XCTAssertEqual(series.changeVsPreviousMonthMinorUnits, 100_000)
        XCTAssertEqual(series.asOf, date(2026, 2, 1))
        XCTAssertNil(series.behindBalances)
    }

    func testForecastStartsAtTheDataMonthAndMatchesTheProjector() {
        let series = DashboardCalculator.netWorthSeries(series2026Input)
        XCTAssertEqual(series.forecast.first, NetWorthPoint(year: 2026, month: 2, valueMinorUnits: 1_200_000))
        XCTAssertEqual(series.forecast.count, 23) // Feb 2026 anchor + Mar 2026 ... Dec 2027
        XCTAssertEqual(series.forecast.last, NetWorthPoint(year: 2027, month: 12, valueMinorUnits: 5_600_000))
    }

    func testYearEndForecastsCompareAgainstTheRightBaseline() throws {
        let yearEnds = DashboardCalculator.netWorthSeries(series2026Input).yearEnds
        XCTAssertEqual(yearEnds.map(\.year), [2026, 2027])
        // Dec 2026 vs the REAL Dec 2025 (1_000_000); Dec 2027 vs the FORECAST Dec 2026.
        XCTAssertEqual(yearEnds[0].valueMinorUnits, 3_200_000)
        XCTAssertEqual(yearEnds[0].changeMinorUnits, 2_200_000)
        XCTAssertEqual(try XCTUnwrap(yearEnds[0].percent), 2.2, accuracy: 0.0001)
        XCTAssertEqual(yearEnds[1].valueMinorUnits, 5_600_000)
        XCTAssertEqual(yearEnds[1].changeMinorUnits, 2_400_000)
        XCTAssertEqual(try XCTUnwrap(yearEnds[1].percent), 0.75, accuracy: 0.0001)
    }

    // Importing through April while the balance was last recorded in February: the line runs
    // flat and the banner data is populated.
    func testBalancesOlderThanTheDataMonthAreFlagged() {
        let input = F.input(
            today: date(2026, 4, 15),
            snapshots: [F.snapshot(1, date(2026, 2, 1), 1_200_000)],
            transactions: [F.txn(1, date(2026, 4, 10), -1_000, category: F.rentId)],
            entries: F.salaryAndRent
        )
        let series = DashboardCalculator.netWorthSeries(input)
        XCTAssertEqual(series.actual.map(\.valueMinorUnits), [1_200_000, 1_200_000, 1_200_000]) // Feb, Mar, Apr
        XCTAssertEqual(series.behindBalances, BehindBalances(accountCount: 1, oldestSnapshotDate: date(2026, 2, 1)))
    }

    func testImportedAccountsAreNeverBehind() {
        let imported = Account(id: 1, name: "Imported", currency: .gbp, kind: .cash, trackingMode: .imported)
        let input = F.input(
            today: date(2026, 4, 15), accounts: [imported],
            snapshots: [F.snapshot(1, date(2026, 2, 1), 1_200_000)],
            transactions: [F.txn(1, date(2026, 4, 10), -1_000, category: F.rentId)]
        )
        XCTAssertNil(DashboardCalculator.netWorthSeries(input).behindBalances)
    }

    func testNoSnapshotsGivesAnEmptySeries() {
        let series = DashboardCalculator.netWorthSeries(F.input(today: date(2026, 4, 15)))
        XCTAssertEqual(series, NetWorthSeries.empty)
        XCTAssertTrue(series.actual.isEmpty)
        XCTAssertNil(series.currentNetWorthMinorUnits)
    }

    // MARK: year over year

    private var yoyInput: DashboardInput {
        F.input(
            today: date(2026, 10, 2),
            snapshots: [
                F.snapshot(1, date(2024, 1, 1), 1_000_000), F.snapshot(1, date(2024, 12, 1), 2_200_000),
                F.snapshot(1, date(2025, 12, 1), 3_000_000), F.snapshot(1, date(2026, 2, 1), 3_300_000)
            ],
            transactions: [F.txn(1, date(2026, 2, 14), -1_000, category: F.rentId)],
            entries: F.salaryAndRent
        )
    }

    func testYearOverYearSplitsRealisedAndForecastParts() throws {
        let input = yoyInput
        let changes = DashboardCalculator.yearOverYear(input, series: DashboardCalculator.netWorthSeries(input))
        XCTAssertEqual(changes.map(\.year), [2024, 2025, 2026, 2027])

        // First year: measured from the first available month (Jan 2024) to Dec 2024.
        XCTAssertEqual(changes[0].realisedMinorUnits, 1_200_000)
        XCTAssertEqual(changes[0].forecastMinorUnits, 0)
        XCTAssertEqual(changes[0].partialFromMonth, 1)
        XCTAssertEqual(try XCTUnwrap(changes[0].percent), 1.2, accuracy: 0.0001)

        // Completed year: Dec to Dec.
        XCTAssertEqual(changes[1].realisedMinorUnits, 800_000)
        XCTAssertNil(changes[1].partialFromMonth)
        XCTAssertEqual(try XCTUnwrap(changes[1].percent), 800.0 / 2200.0, accuracy: 0.0001)

        // Current year: realised = latest actual (Feb 2026: 3_300_000) - Dec 2025 (3_000_000); the rest is forecast.
        XCTAssertEqual(changes[2].realisedMinorUnits, 300_000)
        XCTAssertEqual(changes[2].forecastMinorUnits, 2_000_000)
        XCTAssertEqual(changes[2].totalMinorUnits, 2_300_000)

        // Next year: entirely forecast (Dec 2027 7_700_000 - Dec 2026 5_300_000).
        XCTAssertEqual(changes[3].realisedMinorUnits, 0)
        XCTAssertEqual(changes[3].forecastMinorUnits, 2_400_000)
    }

    // The 2026 bar must equal the year-end headline on the net worth card.
    func testYearOverYearAgreesWithTheYearEndForecast() throws {
        let input = yoyInput
        let series = DashboardCalculator.netWorthSeries(input)
        let changes = DashboardCalculator.yearOverYear(input, series: series)
        XCTAssertEqual(changes[2].totalMinorUnits, try XCTUnwrap(series.yearEnds.first { $0.year == 2026 }).changeMinorUnits)
        XCTAssertEqual(changes[3].totalMinorUnits, try XCTUnwrap(series.yearEnds.first { $0.year == 2027 }).changeMinorUnits)
    }

    func testNegativeYearsKeepTheirSign() {
        let input = F.input(
            today: date(2025, 12, 20),
            snapshots: [F.snapshot(1, date(2024, 1, 1), 1_000_000), F.snapshot(1, date(2024, 12, 1), 800_000), F.snapshot(1, date(2025, 12, 1), 700_000)],
            transactions: [F.txn(1, date(2025, 12, 15), -1_000, category: F.rentId)],
            entries: F.salaryAndRent
        )
        let changes = DashboardCalculator.yearOverYear(input, series: DashboardCalculator.netWorthSeries(input))
        XCTAssertEqual(changes[0].realisedMinorUnits, -200_000) // 2024: Jan → Dec
        XCTAssertEqual(changes[1].realisedMinorUnits, -100_000) // 2025: Dec → Dec
    }

    func testYearOverYearIsEmptyWithoutHistory() {
        let input = F.input(today: date(2026, 4, 15))
        XCTAssertTrue(DashboardCalculator.yearOverYear(input, series: DashboardCalculator.netWorthSeries(input)).isEmpty)
    }
}
