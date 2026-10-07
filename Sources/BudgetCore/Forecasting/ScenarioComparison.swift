import Foundation

/// One plan to compare — the budget's, or one scenario's own entries — as loaded: entries
/// (`ForecastEntry.budget` or `ForecastEntry.inScenario`, tombstones included), their
/// exceptions, and the forecast groups.
public struct PlanInput: Equatable, Sendable {
    public var entries: [ForecastEntry]
    public var exceptions: [PlannedOccurrenceException]
    public var groups: [ForecastGroup]

    public init(entries: [ForecastEntry], exceptions: [PlannedOccurrenceException], groups: [ForecastGroup]) {
        self.entries = entries
        self.exceptions = exceptions
        self.groups = groups
    }
}

/// What every plan in a comparison shares: the actuals, the pay calendar, today and the
/// horizon (the last calendar month shown).
public struct ComparisonData: Sendable {
    public let today: Date
    public let accounts: [Account]
    public let snapshots: [BalanceSnapshot]
    public let transactions: [Transaction]
    public let categories: [Category]
    public let rate: ExchangeRateSetting
    public let payCalendar: PayCalendar
    public let horizonYear: Int
    public let horizonMonth: Int

    public init(today: Date, accounts: [Account], snapshots: [BalanceSnapshot], transactions: [Transaction], categories: [Category], rate: ExchangeRateSetting, payCalendar: PayCalendar, horizonYear: Int, horizonMonth: Int) {
        self.today = today
        self.accounts = accounts
        self.snapshots = snapshots
        self.transactions = transactions
        self.categories = categories
        self.rate = rate
        self.payCalendar = payCalendar
        self.horizonYear = horizonYear
        self.horizonMonth = horizonMonth
    }

    var horizonIndex: Int { MonthRange.index(year: horizonYear, month: horizonMonth) }
}

/// A plan's net worth lines: the shared actual months, then its forecast to the horizon
/// (as `DashboardCalculator.netWorthSeries`: anchored at the current net worth, then
/// `ForecastProjector.monthlyProjection` with the plan's entries).
public struct PlanNetWorthSeries: Equatable, Sendable {
    public let actual: [NetWorthPoint]
    public let forecast: [NetWorthPoint]
}

/// One plan's row for one year of the summary table. Flows are positive magnitudes over the
/// year's months up to the horizon: closed months are actuals, open and future months follow
/// the plan (`DashboardCalculator.monthlyFlows`). `reserves` is the reserves' part of
/// `expenses`.
public struct PlanYearSummary: Equatable, Sendable {
    public let year: Int
    /// Net worth at the end of December, or of the horizon's month in its last year; nil
    /// when there's no point for that month (no data).
    public let yearEndNetWorth: Int?
    /// `yearEndNetWorth` minus the budget's (0 for the budget itself).
    public let differenceVsBudget: Int?
    public let income: Int
    public let expenses: Int
    public let reserves: Int

    public init(year: Int, yearEndNetWorth: Int?, differenceVsBudget: Int?, income: Int, expenses: Int, reserves: Int) {
        self.year = year
        self.yearEndNetWorth = yearEndNetWorth
        self.differenceVsBudget = differenceVsBudget
        self.income = income
        self.expenses = expenses
        self.reserves = reserves
    }
}

/// One category × month of a scenario's grid: its value as the Budget grid computes one
/// (`PlanStatus.cell`; reserves by `ReservedCategories.monthAllowances`) with the scenario's
/// plan, the Budget's value, and whether they differ.
public struct ScenarioGridCell: Equatable {
    public let value: Int
    public let pending: Int
    public let state: PendingState
    public let budgetValue: Int
    public var differsFromBudget: Bool { value != budgetValue }
}

/// The scenario comparison (spec 2026-10-08-scenario-lab-design.md, "Comparison"). Pure:
/// each plan is evaluated with the dashboard's and the Budget grid's own calculators, over
/// the same actuals and pay calendar.
public enum ScenarioComparison {
    /// The plan-independent part of every plan's series (`DashboardCalculator.netWorthActuals`):
    /// compute it once and pass it to `netWorthSeries(_:plan:actuals:)` for each plan. Nil
    /// without snapshots.
    public static func actuals(_ data: ComparisonData) -> NetWorthActuals? {
        DashboardCalculator.netWorthActuals(input(data, PlanInput(entries: [], exceptions: [], groups: [])))
    }

    /// The plan's series over shared `actuals` (from `actuals(_:)` with the same `data`).
    public static func netWorthSeries(_ data: ComparisonData, plan: PlanInput, actuals: NetWorthActuals?) -> PlanNetWorthSeries {
        guard let actuals else { return PlanNetWorthSeries(actual: [], forecast: []) }
        let plan = normalized(plan)
        let forecast = DashboardCalculator.netWorthForecast(actuals, throughYear: data.horizonYear, categories: data.categories, entries: plan.entries,
                                                            groups: plan.groups, exceptions: plan.exceptions)
        return PlanNetWorthSeries(actual: actuals.actual, forecast: forecast.filter { $0.id <= data.horizonIndex })
    }

    /// One plan's series on its own (its actuals computed for it).
    public static func netWorthSeries(_ data: ComparisonData, plan: PlanInput) -> PlanNetWorthSeries {
        let series = DashboardCalculator.netWorthSeries(input(data, plan), forecastThroughYear: data.horizonYear)
        return PlanNetWorthSeries(actual: series.actual, forecast: series.forecast.filter { $0.id <= data.horizonIndex })
    }

    /// One row per year from today's to the horizon's. `series` is the plan's
    /// `netWorthSeries` and `budgetSeries` the budget's (the same one for the budget's own
    /// row), computed once by the caller and shared with the chart.
    public static func yearSummaries(_ data: ComparisonData, plan: PlanInput, series: PlanNetWorthSeries, budgetSeries: PlanNetWorthSeries) -> [PlanYearSummary] {
        let firstYear = MonthRange.components(of: data.today).year
        guard firstYear <= data.horizonYear else { return [] }
        let planInput = input(data, plan)
        let planValues = values(series)
        let budgetValues = series == budgetSeries ? planValues : values(budgetSeries)
        return (firstYear...data.horizonYear).map { year in
            let lastMonth = year == data.horizonYear ? data.horizonMonth : 12
            let flows = DashboardCalculator.monthlyFlows(planInput, year: year).filter { $0.month <= lastMonth }
            let totals = DashboardCalculator.yearTotals(flows)
            let index = MonthRange.index(year: year, month: lastMonth)
            let value = planValues[index]
            let difference = value.flatMap { v in budgetValues[index].map { v - $0 } }
            return PlanYearSummary(year: year, yearEndNetWorth: value, differenceVsBudget: difference,
                                   income: totals.incomeProjected, expenses: totals.expenseProjected,
                                   reserves: flows.map(\.reservedRemaining).reduce(0, +))
        }
    }

    /// Every category's twelve cells of `year`, by category id then month.
    public static func gridCells(_ data: ComparisonData, scenario: PlanInput, budget: PlanInput, year: Int) -> [Int64: [Int: ScenarioGridCell]] {
        let monthTotals = PayMonthTotals.lookup(transactions: data.transactions, calendar: data.payCalendar)
        let scenarioPlan = normalized(scenario)
        let budgetPlan = normalized(budget)
        var result: [Int64: [Int: ScenarioGridCell]] = [:]
        for month in 1...12 {
            let monthClass = data.payCalendar.monthClass(PayMonth(year: year, month: month))
            let mine = cells(data, scenarioPlan, year: year, month: month, monthClass: monthClass, monthTotals: monthTotals)
            let theirs = cells(data, budgetPlan, year: year, month: month, monthClass: monthClass, monthTotals: monthTotals)
            for (categoryId, cell) in mine {
                result[categoryId, default: [:]][month] = ScenarioGridCell(value: cell.value, pending: cell.pending, state: cell.state, budgetValue: theirs[categoryId]?.value ?? 0)
            }
        }
        return result
    }

    // MARK: - Helpers

    /// The plan's entries as the calculators read a plan: they only count budget entries
    /// (`ForecastCalculator.confirmedEntries`), so a scenario's own entries are handed over
    /// as if they were the budget. Tombstones, disabled entries and disabled groups still
    /// drop out (`planEntries`); entry ids (and so exception keys) are unchanged.
    static func normalized(_ plan: PlanInput) -> PlanInput {
        var plan = plan
        plan.entries = plan.entries.map { entry in
            var entry = entry
            entry.scenarioId = nil
            return entry
        }
        return plan
    }

    private static func input(_ data: ComparisonData, _ plan: PlanInput) -> DashboardInput {
        let plan = normalized(plan)
        return DashboardInput(today: data.today, accounts: data.accounts, snapshots: data.snapshots, transactions: data.transactions,
                              categories: data.categories, categoryGroups: [], forecastEntries: plan.entries, forecastGroups: plan.groups,
                              exceptions: plan.exceptions, importBatches: [], rate: data.rate, payCalendar: data.payCalendar)
    }

    /// Month index → value, actual months winning where the two lines meet.
    private static func values(_ series: PlanNetWorthSeries) -> [Int: Int] {
        var result: [Int: Int] = [:]
        for point in series.forecast { result[point.id] = point.valueMinorUnits }
        for point in series.actual { result[point.id] = point.valueMinorUnits }
        return result
    }

    /// One month of the Budget grid for a (normalized) plan: `PlanStatus.cell` of the pay
    /// month's actual and the calendar month's plan; reserves by `monthAllowances`.
    private static func cells(_ data: ComparisonData, _ plan: PlanInput, year: Int, month: Int, monthClass: MonthClass, monthTotals: [Int64: [Int: [Int: Int]]]) -> [Int64: (value: Int, pending: Int, state: PendingState)] {
        let range = MonthRange.of(year: year, month: month)
        let period = PayPeriod(startDate: range.start, endDate: range.end, type: .projected)
        let planned = ForecastCalculator.confirmedTotalsByCategory(period: period, entries: plan.entries, groups: plan.groups, exceptions: plan.exceptions)
        let reserves: [(id: Int64, name: String, allowance: Int)] = data.categories.compactMap { category in
            guard category.isReserved, let id = category.id else { return nil }
            return (id, category.name, planned[id] ?? 0)
        }
        let allowances = ReservedCategories.monthAllowances(reserves, monthClass: monthClass) {
            ReservedCategories.unforecastSpend(year: year, month: month, categories: data.categories, monthTotals: monthTotals, entries: plan.entries, groups: plan.groups, exceptions: plan.exceptions)
        }
        var result: [Int64: (value: Int, pending: Int, state: PendingState)] = [:]
        for category in data.categories {
            guard let id = category.id else { continue }
            if category.isReserved {
                let value = allowances[id] ?? 0
                result[id] = (value, value, value == 0 ? .none : .allExpected)
            } else {
                result[id] = PlanStatus.cell(actual: monthTotals[id]?[year]?[month] ?? 0, planned: planned[id] ?? 0,
                                             categoryType: category.type, monthClass: monthClass)
            }
        }
        return result
    }
}
