import Foundation

/// Magnitudes (income and expenses are both positive).
public struct FlowTotals: Equatable {
    public var actual: Int
    public var expected: Int
    public var projected: Int

    public init(actual: Int, expected: Int, projected: Int) {
        self.actual = actual
        self.expected = expected
        self.projected = projected
    }
}

public struct CurrentMonthTracking: Equatable {
    public let year: Int
    public let month: Int
    public let dayOfMonth: Int
    public let daysInMonth: Int
    public let monthClass: MonthClass
    public let income: FlowTotals
    public let expenses: FlowTotals
    /// Positive magnitude of the reserves' projected spend this month; already included in
    /// `expenses.projected` and `expenses.expected`.
    public let reservedProjected: Int
    /// Transactions dated this month with no category or still pending review — not in the
    /// totals (like the Budget grid), shown as a footnote.
    public let unreviewedCount: Int
    public let unreviewedOutflowMinorUnits: Int

    /// Signed: income minus expenses, for each of actual / expected / projected.
    public var net: FlowTotals {
        FlowTotals(actual: income.actual - expenses.actual, expected: income.expected - expenses.expected, projected: income.projected - expenses.projected)
    }
}

/// One month of the year-at-a-glance chart. `*Remaining` is the part of the month's
/// projection that hasn't happened yet (hatched in the chart); it is 0 for actual months
/// and equals the whole forecast for forecast months. All values are positive magnitudes.
public struct MonthlyFlow: Equatable, Identifiable {
    public let year: Int
    public let month: Int
    public let monthClass: MonthClass
    public let incomeActual: Int
    public let incomeRemaining: Int
    public let expenseActual: Int
    public let expenseRemaining: Int
    /// Positive magnitude; the part of `expenseRemaining` that comes from reserves (always
    /// <= `expenseRemaining`).
    public let reservedRemaining: Int

    public var id: Int { month }
    public var incomeTotal: Int { incomeActual + incomeRemaining }
    public var expenseTotal: Int { expenseActual + expenseRemaining }
    public var net: Int { incomeTotal - expenseTotal }
    public var netActual: Int { incomeActual - expenseActual }
}

public struct YearTotals: Equatable {
    public let incomeProjected: Int
    public let incomeActual: Int
    public let expenseProjected: Int
    public let expenseActual: Int
    public var netProjected: Int { incomeProjected - expenseProjected }
    public var netActual: Int { incomeActual - expenseActual }
    /// True when part of the year is still forecast (so "of which actual" is worth showing).
    public var hasForecast: Bool { incomeProjected != incomeActual || expenseProjected != expenseActual }
}

/// Transactions with no category or still pending review: left out of every total (like the
/// Budget grid), so any card showing totals notes them. `outflowMinorUnits` is the money
/// out among them, as a positive magnitude.
public struct UnreviewedSummary: Equatable {
    public let count: Int
    public let outflowMinorUnits: Int

    public init(count: Int, outflowMinorUnits: Int) {
        self.count = count
        self.outflowMinorUnits = outflowMinorUnits
    }
}

public struct CategorySpend: Equatable, Identifiable {
    public let name: String
    public let actual: Int
    public let expected: Int
    public let projected: Int
    /// True when every category rolled into this row is excluded from the auto-forecast
    /// because a reserve covers it, so a zero expectation is intentional.
    public let isCoveredByReserve: Bool
    public var id: String { name }
    public var isOver: Bool { expected > 0 && actual > expected }
    public var isUnplanned: Bool { expected == 0 && actual > 0 && !isCoveredByReserve }

    public init(name: String, actual: Int, expected: Int, projected: Int, isCoveredByReserve: Bool = false) {
        self.name = name
        self.actual = actual
        self.expected = expected
        self.projected = projected
        self.isCoveredByReserve = isCoveredByReserve
    }
}

extension DashboardCalculator {
    // MARK: Shared per-month computation

    private struct MonthTotals {
        var income = FlowTotals(actual: 0, expected: 0, projected: 0)
        var expenses = FlowTotals(actual: 0, expected: 0, projected: 0)
        var reservedProjected = 0
    }

    /// Per non-transfer category: actual (confirmed transactions), expected (confirmed
    /// forecast for the whole calendar month — independent of whether the month "is actual"),
    /// and the projected value under `MonthBlend`. Expected is skipped for actual months
    /// unless `includeExpected` (the current-month card always wants it).
    private static func categoryAmounts(_ input: DashboardInput, year: Int, month: Int, monthClass: MonthClass, includeExpected: Bool, visit: (Category, _ actual: Int, _ expected: Int, _ projected: Int) -> Void) {
        let range = MonthRange.of(year: year, month: month)
        let period = PayPeriod(startDate: range.start, endDate: range.end, type: .projected)
        for category in input.categories {
            guard let categoryId = category.id, category.type != .transfer else { continue }
            let actual = monthClass == .forecast ? 0 : (input.calendarTotals[categoryId]?[year]?[month] ?? 0)
            let expected = (monthClass != .actual || includeExpected)
                ? ForecastCalculator.confirmedTotal(categoryId: categoryId, period: period, entries: input.forecastEntries, groups: input.forecastGroups)
                : 0
            let projected = MonthBlend.projectedTotal(actual: actual, expected: expected, categoryType: category.type, monthClass: monthClass)
            visit(category, actual, expected, projected)
        }
    }

    private static func monthTotals(_ input: DashboardInput, year: Int, month: Int, monthClass: MonthClass, includeExpected: Bool) -> MonthTotals {
        var totals = MonthTotals()
        categoryAmounts(input, year: year, month: month, monthClass: monthClass, includeExpected: includeExpected) { category, actual, expected, projected in
            switch category.type {
            case .income:
                totals.income.actual += actual; totals.income.expected += expected; totals.income.projected += projected
            case .expense:
                // Signed outflows → positive magnitudes.
                totals.expenses.actual -= actual; totals.expenses.expected -= expected; totals.expenses.projected -= projected
                if category.isReserved { totals.reservedProjected -= projected }
            case .transfer:
                break
            }
        }
        return totals
    }

    // MARK: Current month

    public static func currentMonth(_ input: DashboardInput) -> CurrentMonthTracking {
        let today = input.effectiveToday
        let parts = MonthRange.components(of: today)
        let monthClass = MonthBlend.classify(year: parts.year, month: parts.month, dataThrough: input.dataThrough, today: input.today)
        let totals = monthTotals(input, year: parts.year, month: parts.month, monthClass: monthClass, includeExpected: true)

        let range = MonthRange.of(year: parts.year, month: parts.month)
        let unreviewed = unreviewedSummary(input, from: range.start, through: range.end)

        return CurrentMonthTracking(
            year: parts.year, month: parts.month,
            dayOfMonth: calendar.component(.day, from: today),
            daysInMonth: calendar.range(of: .day, in: .month, for: today)!.count,
            monthClass: monthClass, income: totals.income, expenses: totals.expenses,
            reservedProjected: totals.reservedProjected,
            unreviewedCount: unreviewed.count, unreviewedOutflowMinorUnits: unreviewed.outflowMinorUnits
        )
    }

    // MARK: Unreviewed

    /// Unreviewed transactions dated within the UTC calendar `year`.
    public static func unreviewed(_ input: DashboardInput, year: Int) -> UnreviewedSummary {
        unreviewedSummary(input, from: MonthRange.of(year: year, month: 1).start, through: MonthRange.of(year: year, month: 12).end)
    }

    private static func unreviewedSummary(_ input: DashboardInput, from start: Date, through end: Date) -> UnreviewedSummary {
        let unreviewed = input.transactions.filter { $0.date >= start && $0.date <= end && ($0.categoryId == nil || $0.status == .pendingReview) }
        let outflow = -unreviewed.map(\.amountMinorUnits).filter { $0 < 0 }.reduce(0, +)
        return UnreviewedSummary(count: unreviewed.count, outflowMinorUnits: outflow)
    }

    // MARK: Year at a glance

    public static func monthlyFlows(_ input: DashboardInput, year: Int) -> [MonthlyFlow] {
        (1...12).map { month in
            let monthClass = MonthBlend.classify(year: year, month: month, dataThrough: input.dataThrough, today: input.today)
            let totals = monthTotals(input, year: year, month: month, monthClass: monthClass, includeExpected: false)
            let expenseRemaining = max(totals.expenses.projected - totals.expenses.actual, 0)
            return MonthlyFlow(
                year: year, month: month, monthClass: monthClass,
                incomeActual: totals.income.actual, incomeRemaining: max(totals.income.projected - totals.income.actual, 0),
                expenseActual: totals.expenses.actual, expenseRemaining: expenseRemaining, reservedRemaining: min(totals.reservedProjected, expenseRemaining)
            )
        }
    }

    public static func yearTotals(_ flows: [MonthlyFlow]) -> YearTotals {
        YearTotals(
            incomeProjected: flows.map(\.incomeTotal).reduce(0, +), incomeActual: flows.map(\.incomeActual).reduce(0, +),
            expenseProjected: flows.map(\.expenseTotal).reduce(0, +), expenseActual: flows.map(\.expenseActual).reduce(0, +)
        )
    }

    // MARK: Top categories

    /// Expense categories for the current month, rolled up by `CategoryGroup` exactly like
    /// the grids (a group is the sum of its members; ungrouped categories stand alone),
    /// ranked by projected month-end spend.
    public static func topCategories(_ input: DashboardInput, limit: Int = 5) -> [CategorySpend] {
        let parts = MonthRange.components(of: input.effectiveToday)
        let monthClass = MonthBlend.classify(year: parts.year, month: parts.month, dataThrough: input.dataThrough, today: input.today)
        let groupNames = Dictionary(uniqueKeysWithValues: input.categoryGroups.compactMap { group -> (Int64, String)? in group.id.map { ($0, group.name) } })

        var rolled: [String: (actual: Int, expected: Int, projected: Int, covered: Bool)] = [:]
        categoryAmounts(input, year: parts.year, month: parts.month, monthClass: monthClass, includeExpected: true) { category, actual, expected, projected in
            guard category.type == .expense, !category.isReserved else { return }
            let key = category.groupId.flatMap { groupNames[$0] } ?? category.name
            var entry = rolled[key] ?? (0, 0, 0, true)
            entry.covered = entry.covered && category.excludeFromAutoForecast
            entry.actual -= actual; entry.expected -= expected; entry.projected -= projected
            rolled[key] = entry
        }
        return rolled
            .map { CategorySpend(name: $0.key, actual: $0.value.actual, expected: $0.value.expected, projected: $0.value.projected, isCoveredByReserve: $0.value.covered) }
            .filter { $0.actual != 0 || $0.expected != 0 || $0.projected != 0 }
            .sorted { $0.projected != $1.projected ? $0.projected > $1.projected : $0.name < $1.name }
            .prefix(limit)
            .map { $0 }
    }
}
