import XCTest
@testable import BudgetCore

final class DashboardNetWorthTests: XCTestCase {
    private typealias F = DashboardFixture
    private func date(_ y: Int, _ m: Int, _ d: Int) -> Date { F.date(y, m, d) }

    // The transactions in these fixtures are in an account outside the chart (9): they set
    // the data-through date without moving account 1's balance.
    private var series2026Input: DashboardInput {
        F.input(
            today: date(2026, 4, 15),
            snapshots: [F.snapshot(1, date(2025, 12, 1), 1_000_000), F.snapshot(1, date(2026, 1, 1), 1_100_000), F.snapshot(1, date(2026, 2, 1), 1_200_000)],
            transactions: [F.txn(1, date(2026, 2, 10), -1_000, category: F.rentId, account: 9)],
            entries: F.salaryAndRent,
            // December 2025 closed (on its last day, so pay months still equal calendar months).
            manualCloses: [PayMonthClose(year: 2025, month: 12, closeDate: date(2025, 12, 31))]
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
        // February's remaining plan (+3,000 salary, −990 rent beyond the −10 paid) joins the walk.
        XCTAssertEqual(series.forecast.last, NetWorthPoint(year: 2027, month: 12, valueMinorUnits: 5_801_000))
    }

    func testYearEndForecastsCompareAgainstTheRightBaseline() throws {
        let yearEnds = DashboardCalculator.netWorthSeries(series2026Input).yearEnds
        XCTAssertEqual(yearEnds.map(\.year), [2026, 2027])
        // Dec 2026 vs the REAL Dec 2025 (1_000_000); Dec 2027 vs the FORECAST Dec 2026. Both
        // include February's remaining plan (+201_000).
        XCTAssertEqual(yearEnds[0].valueMinorUnits, 3_401_000)
        XCTAssertEqual(yearEnds[0].changeMinorUnits, 2_401_000)
        XCTAssertEqual(try XCTUnwrap(yearEnds[0].percent), 2.401, accuracy: 0.0001)
        XCTAssertEqual(yearEnds[1].valueMinorUnits, 5_801_000)
        XCTAssertEqual(yearEnds[1].changeMinorUnits, 2_400_000)
        XCTAssertEqual(try XCTUnwrap(yearEnds[1].percent), 2_400_000.0 / 3_401_000.0, accuracy: 0.0001)
    }

    // Same rule as the Forecast grid: the real December is the baseline only once that pay
    // month is closed. Data reaching past December doesn't close it on its own.
    func testYearEndNetWorthIsRealForPastYearsAndForecastForThisOne() throws {
        let input = series2026Input
        let past = try XCTUnwrap(DashboardCalculator.yearEndNetWorth(input, year: 2025))
        XCTAssertEqual(past, YearEndNetWorth(valueMinorUnits: 1_000_000, isForecast: false))
        let series = DashboardCalculator.netWorthSeries(input)
        let current = try XCTUnwrap(DashboardCalculator.yearEndNetWorth(input, year: 2026))
        XCTAssertTrue(current.isForecast)
        XCTAssertEqual(current.valueMinorUnits, series.yearEnds[0].valueMinorUnits)
        XCTAssertEqual(try XCTUnwrap(DashboardCalculator.yearEndNetWorth(input, year: 2027)).valueMinorUnits, series.yearEnds[1].valueMinorUnits)
        XCTAssertNil(DashboardCalculator.yearEndNetWorth(input, year: 2020))
    }

    /// Past years' cards and months read the shared `NetWorthActuals` (the Budget grid's
    /// cache): the same figures as working each one out, in both Show forecast states.
    func testYearEndAndNetWorthRowWithSharedActualsMatchTheUncachedOnes() {
        let input = series2026Input
        let actuals = DashboardCalculator.netWorthActuals(input)
        for includeForecast in [true, false] {
            for year in 2024...2028 {
                XCTAssertEqual(DashboardCalculator.yearEndNetWorth(input, actuals: actuals, year: year, includeForecast: includeForecast),
                               DashboardCalculator.yearEndNetWorth(input, year: year, includeForecast: includeForecast), "\(includeForecast) \(year)")
                XCTAssertEqual(DashboardCalculator.budgetNetWorthMonths(input, actuals: actuals, year: year, includeForecast: includeForecast),
                               DashboardCalculator.budgetNetWorthMonths(input, year: year, includeForecast: includeForecast), "\(includeForecast) \(year)")
            }
        }
    }

    // Data past December's payday starts the walk in next January: this year's card and the
    // Dashboard both show today's net worth, without January's plan.
    func testYearEndAgreesWithTheDashboardWhenDataRunsPastDecembersPayday() throws {
        let input = F.input(
            today: date(2026, 12, 30), snapshots: [F.snapshot(1, date(2026, 7, 1), 1_000_000)],
            transactions: [F.txn(1, date(2026, 12, 28), -1_000, category: F.rentId, account: 9)],
            entries: F.salaryAndRent, salaries: [date(2026, 11, 24), date(2026, 12, 24)]
        )
        XCTAssertEqual(input.payCalendar.month(containing: date(2026, 12, 28)), PayMonth(year: 2027, month: 1))
        let series = DashboardCalculator.netWorthSeries(input)
        let current = try XCTUnwrap(series.currentNetWorthMinorUnits)
        XCTAssertEqual(series.yearEnds.first?.valueMinorUnits, current)
        XCTAssertEqual(DashboardCalculator.yearEndNetWorth(input, year: 2026), YearEndNetWorth(valueMinorUnits: current, isForecast: true))
        XCTAssertEqual(DashboardCalculator.yearEndNetWorth(input, year: 2027)?.valueMinorUnits, series.yearEnds.last?.valueMinorUnits)
    }

    func testYearEndBaselineIsTheForecastWhileLastDecemberIsOpen() throws {
        let input = F.input(
            today: date(2026, 4, 15),
            snapshots: [F.snapshot(1, date(2025, 12, 1), 1_000_000), F.snapshot(1, date(2026, 1, 1), 1_100_000), F.snapshot(1, date(2026, 2, 1), 1_200_000)],
            transactions: [F.txn(1, date(2026, 2, 10), -1_000, category: F.rentId, account: 9)],
            entries: F.salaryAndRent
        )
        XCTAssertFalse(input.payCalendar.isClosed(PayMonth(year: 2025, month: 12)))
        let yearEnd = try XCTUnwrap(DashboardCalculator.netWorthSeries(input).yearEnds.first)
        let forecastDec2025 = ForecastProjector.forecastNetWorth(startingNetWorth: 1_200_000, latestRealMonth: (2026, 2), atEndOf: 2025, categories: input.categories, entries: input.forecastEntries, groups: input.forecastGroups, exceptions: input.exceptions)
        XCTAssertEqual(yearEnd.valueMinorUnits, 3_401_000)
        XCTAssertEqual(yearEnd.changeMinorUnits, 3_401_000 - forecastDec2025)
        XCTAssertNotEqual(yearEnd.changeMinorUnits, 2_200_000) // not the real Dec 2025 (1_000_000)
    }

    // Salary on 15 Sep, data through 20 Sep (past payday), today 5 Oct: the walk starts in
    // the October pay month, but the dashed line starts where the solid one ends (September).
    func testForecastStartsWhereTheActualLineEndsWhenDataRunsPastPayday() throws {
        let snapshots = [F.snapshot(1, date(2026, 7, 1), 1_000_000), F.snapshot(1, date(2026, 9, 1), 1_200_000)]
        let entries = F.salaryAndRent
        let input = F.input(
            today: date(2026, 10, 5), snapshots: snapshots,
            transactions: [F.txn(1, date(2026, 9, 20), -1_000, category: F.rentId, account: 9)],
            entries: entries, salaries: [date(2026, 8, 15), date(2026, 9, 15)]
        )
        XCTAssertEqual(input.payCalendar.month(containing: date(2026, 9, 20)), PayMonth(year: 2026, month: 10))
        let series = DashboardCalculator.netWorthSeries(input)
        let lastActual = try XCTUnwrap(series.actual.last)
        let current = try XCTUnwrap(series.currentNetWorthMinorUnits)
        XCTAssertEqual(lastActual.year, 2026); XCTAssertEqual(lastActual.month, 9)
        XCTAssertEqual(series.forecast.first, NetWorthPoint(year: 2026, month: 9, valueMinorUnits: current))

        // Then the October pay month's end (current + its remaining plan: +3,000 salary, −990
        // rent beyond the −10 paid), then the projector's walk from November.
        let remaining = ForecastProjector.remainingPlanned(year: 2026, month: 10, actuals: [F.rentId: -1_000], categories: input.categories, entries: input.forecastEntries, groups: input.forecastGroups, exceptions: input.exceptions)
        XCTAssertEqual(remaining, 201_000)
        let projection = ForecastProjector.monthlyProjection(startingNetWorth: current + remaining, latestRealMonth: (2026, 10), throughYear: 2027, categories: input.categories, entries: input.forecastEntries, groups: input.forecastGroups, exceptions: input.exceptions)
        XCTAssertEqual(Array(series.forecast.dropFirst()), [NetWorthPoint(year: 2026, month: 10, valueMinorUnits: current + remaining)] + projection)
    }

    // Importing through April while the balance was last recorded in February: the line runs
    // flat and the banner data is populated.
    func testBalancesOlderThanTheDataMonthAreFlagged() {
        let input = F.input(
            today: date(2026, 4, 15),
            snapshots: [F.snapshot(1, date(2026, 2, 1), 1_200_000)],
            transactions: [F.txn(1, date(2026, 4, 10), -1_000, category: F.rentId, account: 9)],
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
            transactions: [F.txn(1, date(2026, 2, 14), -1_000, category: F.rentId, account: 9)],
            entries: F.salaryAndRent,
            manualCloses: [PayMonthClose(year: 2025, month: 12, closeDate: date(2025, 12, 31))]
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
        XCTAssertEqual(changes[2].forecastMinorUnits, 2_201_000) // February's remaining plan included
        XCTAssertEqual(changes[2].totalMinorUnits, 2_501_000)

        // Next year: entirely forecast (Dec 2027 7_901_000 - Dec 2026 5_501_000).
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
            transactions: [F.txn(1, date(2025, 12, 15), -1_000, category: F.rentId, account: 9)],
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
