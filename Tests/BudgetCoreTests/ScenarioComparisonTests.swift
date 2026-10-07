import XCTest
@testable import BudgetCore
import struct BudgetCore.Category

/// Comparison (spec 2026-10-08-scenario-lab-design.md, "Comparison"): net worth series per
/// plan, the yearly summary and the grid's diff flags, on a fixture worked by hand.
final class ScenarioComparisonTests: XCTestCase {
    private func utc(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        return cal.date(from: DateComponents(year: y, month: m, day: d))!
    }

    private let salaryId: Int64 = 1, rentId: Int64 = 2, gymId: Int64 = 3, holidayId: Int64 = 4, savingsId: Int64 = 5

    private var categories: [Category] {
        [Category(id: salaryId, name: "Salary", type: .income),
         Category(id: rentId, name: "Rent", type: .expense),
         Category(id: gymId, name: "Gym", type: .expense),
         Category(id: holidayId, name: "Holiday", type: .expense, isReserved: true),
         Category(id: savingsId, name: "Savings", type: .transfer)]
    }

    private func entry(_ id: Int64, _ category: Int64, _ amount: Int, start: Date, scenarioId: Int64? = nil, change: ScenarioChange? = nil, enabled: Bool = true) -> ForecastEntry {
        ForecastEntry(id: id, groupId: 1, categoryId: category, amountMinorUnits: amount, frequency: .monthly, interval: 1, startDate: start, endDate: nil, isEnabled: enabled, status: .manual, note: nil, scenarioId: scenarioId, change: change)
    }

    private let groups = [ForecastGroup(id: 1, name: "Planned", note: nil, isEnabled: true, isSystemManaged: false)]

    /// +3,000 salary on the 25th, -1,000 rent on the 1st: +2,000 a month.
    private var budget: PlanInput {
        PlanInput(entries: [entry(1, salaryId, 300_000, start: utc(2026, 1, 25)), entry(2, rentId, -100_000, start: utc(2026, 1, 1))],
                  exceptions: [], groups: groups)
    }

    /// The budget's copies with rent at -1,500, plus gym (-100 from April) and a holiday
    /// reserve (-100 from January 2027), and a tombstone that must count for nothing.
    private var scenario: PlanInput {
        PlanInput(entries: [entry(11, salaryId, 300_000, start: utc(2026, 1, 25), scenarioId: 7),
                            entry(12, rentId, -150_000, start: utc(2026, 1, 1), scenarioId: 7, change: .changed),
                            entry(13, gymId, -10_000, start: utc(2026, 4, 1), scenarioId: 7, change: .added),
                            entry(14, holidayId, -10_000, start: utc(2027, 1, 1), scenarioId: 7, change: .added),
                            entry(15, savingsId, -999_999, start: utc(2026, 1, 1), scenarioId: 7, change: .removed, enabled: false)],
                  exceptions: [PlannedOccurrenceException(id: 1, entryId: 13, originalDate: utc(2026, 6, 1), amountMinorUnits: -30_000)],
                  groups: groups)
    }

    /// January and February closed (actuals: salary +3,000, rent -1,000 each); March open and
    /// started; a manual account worth 10,000 since 1 Jan. Horizon: June 2027.
    private var data: ComparisonData {
        let account = Account(id: 1, name: "Current", currency: .gbp, kind: .cash, trackingMode: .manual)
        func txn(_ id: Int64, _ date: Date, _ amount: Int, _ category: Int64) -> Transaction {
            Transaction(id: id, importBatchId: 1, accountId: 1, date: date, rawDescription: "T\(id)", amountMinorUnits: amount, categoryId: category, status: .confirmed, categorizedBy: .manual, fingerprint: "fp\(id)")
        }
        let calendar = PayCalendar(salaryDates: [], manualCloses: [PayMonthClose(year: 2026, month: 1, closeDate: utc(2026, 1, 31)),
                                                                  PayMonthClose(year: 2026, month: 2, closeDate: utc(2026, 2, 28))],
                                   today: utc(2026, 3, 15))
        return ComparisonData(today: utc(2026, 3, 15), accounts: [account],
                              snapshots: [BalanceSnapshot(accountId: 1, date: utc(2026, 1, 1), balanceMinorUnits: 1_000_000, note: nil)],
                              transactions: [txn(1, utc(2026, 1, 5), -100_000, rentId), txn(2, utc(2026, 1, 25), 300_000, salaryId),
                                             txn(3, utc(2026, 2, 5), -100_000, rentId), txn(4, utc(2026, 2, 25), 300_000, salaryId)],
                              categories: categories, rate: ExchangeRateSetting(eurToGbpRate: 0.5, updatedAt: utc(2026, 1, 1)),
                              payCalendar: calendar, horizonYear: 2027, horizonMonth: 6)
    }

    private func value(_ points: [NetWorthPoint], _ year: Int, _ month: Int) -> Int? {
        points.first { $0.year == year && $0.month == month }?.valueMinorUnits
    }

    // MARK: - Net worth series

    func testNetWorthSeriesPerPlanSharesTheActualsAndProjectsEachPlanToTheHorizon() {
        let budgetSeries = ScenarioComparison.netWorthSeries(data, plan: budget)
        let scenarioSeries = ScenarioComparison.netWorthSeries(data, plan: scenario)

        XCTAssertEqual(budgetSeries.actual.map(\.valueMinorUnits), [1_000_000, 1_000_000]) // Jan, Feb
        XCTAssertEqual(scenarioSeries.actual, budgetSeries.actual)

        // Both start at February's actual and run to June 2027, no further.
        XCTAssertEqual(budgetSeries.forecast.first, NetWorthPoint(year: 2026, month: 2, valueMinorUnits: 1_000_000))
        XCTAssertEqual(budgetSeries.forecast.last.map { [$0.year, $0.month] }, [2027, 6])
        XCTAssertEqual(scenarioSeries.forecast.last.map { [$0.year, $0.month] }, [2027, 6])

        XCTAssertEqual(value(budgetSeries.forecast, 2026, 3), 1_200_000)
        XCTAssertEqual(value(budgetSeries.forecast, 2026, 12), 3_000_000)
        XCTAssertEqual(value(budgetSeries.forecast, 2027, 6), 4_200_000)

        // Scenario: +1,500 in March, +1,400 from April (June's gym is -300), and from 2027
        // the -100 reserve too.
        XCTAssertEqual(value(scenarioSeries.forecast, 2026, 3), 1_150_000)
        XCTAssertEqual(value(scenarioSeries.forecast, 2026, 12), 2_390_000)
        XCTAssertEqual(value(scenarioSeries.forecast, 2027, 6), 3_170_000)
    }

    func testTheBudgetsSeriesMatchesTheDashboards() {
        let series = ScenarioComparison.netWorthSeries(data, plan: budget)
        let d = data
        let input = DashboardInput(today: d.today, accounts: d.accounts, snapshots: d.snapshots, transactions: d.transactions, categories: d.categories, categoryGroups: [],
                                   forecastEntries: budget.entries, forecastGroups: budget.groups, exceptions: budget.exceptions, importBatches: [], rate: d.rate, payCalendar: d.payCalendar)
        let dashboard = DashboardCalculator.netWorthSeries(input)
        XCTAssertEqual(series.actual, dashboard.actual)
        // The dashboard runs to December next year; the comparison stops at the horizon.
        XCTAssertEqual(series.forecast.count, 17) // February's anchor + March 2026 ... June 2027
        XCTAssertEqual(series.forecast, Array(dashboard.forecast.prefix(series.forecast.count)))
    }

    func testSharedActualsGiveEachPlanTheSameSeries() throws {
        let actuals = try XCTUnwrap(ScenarioComparison.actuals(data))
        XCTAssertEqual(actuals.actual, ScenarioComparison.netWorthSeries(data, plan: budget).actual)
        for plan in [budget, scenario] {
            XCTAssertEqual(ScenarioComparison.netWorthSeries(data, plan: plan, actuals: actuals), ScenarioComparison.netWorthSeries(data, plan: plan))
        }
    }

    func testTheDashboardsSeriesIsItsActualsPlusItsForecast() throws {
        let d = data
        let input = DashboardInput(today: d.today, accounts: d.accounts, snapshots: d.snapshots, transactions: d.transactions, categories: d.categories, categoryGroups: [],
                                   forecastEntries: budget.entries, forecastGroups: budget.groups, exceptions: budget.exceptions, importBatches: [], rate: d.rate, payCalendar: d.payCalendar)
        let actuals = try XCTUnwrap(DashboardCalculator.netWorthActuals(input))
        let series = DashboardCalculator.netWorthSeries(input)
        XCTAssertEqual(actuals.actual, series.actual)
        XCTAssertEqual(actuals.currentNetWorthMinorUnits, series.currentNetWorthMinorUnits)
        XCTAssertEqual(DashboardCalculator.netWorthForecast(actuals, throughYear: 2027, categories: input.categories, entries: input.forecastEntries,
                                                            groups: input.forecastGroups, exceptions: input.exceptions), series.forecast)
    }

    func testNoSnapshotsMeansNoActuals() {
        let d = data
        let empty = ComparisonData(today: d.today, accounts: d.accounts, snapshots: [], transactions: d.transactions, categories: d.categories, rate: d.rate,
                                   payCalendar: d.payCalendar, horizonYear: d.horizonYear, horizonMonth: d.horizonMonth)
        XCTAssertNil(ScenarioComparison.actuals(empty))
        XCTAssertEqual(ScenarioComparison.netWorthSeries(empty, plan: budget, actuals: nil), ScenarioComparison.netWorthSeries(empty, plan: budget))
    }

    // MARK: - Summary

    /// `yearSummaries` with each plan's net worth series computed once, as the lab does.
    private func summaries(_ plan: PlanInput) -> [PlanYearSummary] {
        ScenarioComparison.yearSummaries(data, plan: plan, series: ScenarioComparison.netWorthSeries(data, plan: plan),
                                         budgetSeries: ScenarioComparison.netWorthSeries(data, plan: budget))
    }

    func testYearSummariesGiveYearEndNetWorthTheDifferenceAndTheYearsFlows() {
        let budgetRows = summaries(budget)
        let scenarioRows = summaries(scenario)

        XCTAssertEqual(budgetRows, [
            PlanYearSummary(year: 2026, yearEndNetWorth: 3_000_000, differenceVsBudget: 0, income: 3_600_000, expenses: 1_200_000, reserves: 0),
            // To the horizon (June) only.
            PlanYearSummary(year: 2027, yearEndNetWorth: 4_200_000, differenceVsBudget: 0, income: 1_800_000, expenses: 600_000, reserves: 0),
        ])
        // 2026 expenses: January + February actuals 200,000; March 150,000; April–December
        // 9 × 160,000 plus June's extra 20,000 = 1,810,000.
        XCTAssertEqual(scenarioRows, [
            PlanYearSummary(year: 2026, yearEndNetWorth: 2_390_000, differenceVsBudget: -610_000, income: 3_600_000, expenses: 1_810_000, reserves: 0),
            PlanYearSummary(year: 2027, yearEndNetWorth: 3_170_000, differenceVsBudget: -1_030_000, income: 1_800_000, expenses: 1_020_000, reserves: 60_000),
        ])
    }

    func testClosedMonthsUseActualsWhateverThePlanSays() {
        // A scenario that plans a different January still reports January's actuals.
        let flowsBudget = summaries(budget)[0]
        var changed = scenario
        changed.entries.append(entry(16, rentId, -900_000, start: utc(2026, 1, 1), scenarioId: 7, change: .added).with(endDate: utc(2026, 2, 28)))
        let rows = summaries(changed)
        XCTAssertEqual(rows[0].income, flowsBudget.income)
        XCTAssertEqual(rows[0].expenses, 1_810_000)
    }

    // MARK: - Grid

    func testGridCellsGiveTheScenarioValueAndFlagDifferencesFromTheBudget() throws {
        let cells = ScenarioComparison.gridCells(data, scenario: scenario, budget: budget, year: 2026)

        // Closed January: actuals in both, no difference.
        let rentJan = try XCTUnwrap(cells[rentId]?[1])
        XCTAssertEqual(rentJan.value, -100_000)
        XCTAssertEqual(rentJan.budgetValue, -100_000)
        XCTAssertFalse(rentJan.differsFromBudget)
        // Open months: the scenario's plan against the budget's.
        let rentMar = try XCTUnwrap(cells[rentId]?[3])
        XCTAssertEqual(rentMar.value, -150_000)
        XCTAssertEqual(rentMar.pending, -150_000)
        XCTAssertEqual(rentMar.budgetValue, -100_000)
        XCTAssertTrue(rentMar.differsFromBudget)
        XCTAssertEqual(cells[gymId]?[3]?.differsFromBudget, false)
        XCTAssertEqual(cells[gymId]?[6]?.value, -30_000)
        XCTAssertEqual(cells[gymId]?[6]?.differsFromBudget, true)
        XCTAssertEqual(cells[salaryId]?[7]?.value, 300_000)
        XCTAssertEqual(cells[salaryId]?[7]?.differsFromBudget, false)
        XCTAssertEqual(cells[savingsId]?[5]?.value, 0) // the tombstone counts for nothing
        XCTAssertEqual(cells[rentId]?.count, 12)

        // Reserves follow the grid's reserve rule.
        let next = ScenarioComparison.gridCells(data, scenario: scenario, budget: budget, year: 2027)
        XCTAssertEqual(next[holidayId]?[1]?.value, -10_000)
        XCTAssertEqual(next[holidayId]?[1]?.budgetValue, 0)
        XCTAssertEqual(next[holidayId]?[1]?.differsFromBudget, true)
        XCTAssertEqual(cells[holidayId]?[12]?.differsFromBudget, false)
    }
}

private extension ForecastEntry {
    init(id: Int64, groupId: Int64, categoryId: Int64, amountMinorUnits: Int, frequency: ForecastFrequency, interval: Int, startDate: Date, endDate: Date?, isEnabled: Bool, status: ForecastEntryStatus, note: String?, scenarioId: Int64?, change: ScenarioChange?) {
        self.init(id: id, groupId: groupId, categoryId: categoryId, amountMinorUnits: amountMinorUnits, frequency: frequency, interval: interval, startDate: startDate, endDate: endDate, isEnabled: isEnabled, status: status, note: note, anchorDay: nil, scenarioId: scenarioId, sourceEntryId: nil, scenarioChange: change)
    }

    func with(endDate: Date) -> ForecastEntry {
        var copy = self
        copy.endDate = endDate
        return copy
    }
}
