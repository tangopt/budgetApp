import Foundation

/// The month-by-month forecast net worth walk, shared by the dashboard (year-end figures and
/// the dashed forecast line) and the scenario lab's comparison (through
/// `DashboardCalculator.netWorthSeries`) so they cannot diverge.
public enum ForecastProjector {
    /// Running confirmed net worth at the END of every month strictly after
    /// `latestRealMonth`, through December of `throughYear`: starting net worth plus the
    /// accumulated `confirmedNetWorthImpact` (transfers excluded) — for `filter`'s accounts
    /// when set (spec 2026-10-15 §4). Empty when
    /// `latestRealMonth` is already at or past that December.
    public static func monthlyProjection(startingNetWorth: Int, latestRealMonth: (year: Int, month: Int), throughYear: Int, categories: [Category], entries: [ForecastEntry], groups: [ForecastGroup], exceptions: [PlannedOccurrenceException], filter: PlanAccountFilter? = nil) -> [NetWorthPoint] {
        var points: [NetWorthPoint] = []
        var running = startingNetWorth
        var cursor = (year: latestRealMonth.year, month: latestRealMonth.month + 1)
        if cursor.month > 12 { cursor = (cursor.year + 1, 1) }
        while cursor.year <= throughYear {
            let range = MonthRange.of(year: cursor.year, month: cursor.month)
            let period = PayPeriod(startDate: range.start, endDate: range.end, type: .projected)
            running += ForecastCalculator.confirmedNetWorthImpact(period: period, categories: categories, entries: entries, groups: groups, exceptions: exceptions, filter: filter)
            points.append(NetWorthPoint(year: cursor.year, month: cursor.month, valueMinorUnits: running))
            cursor.month += 1
            if cursor.month > 12 { cursor = (cursor.year + 1, 1) }
        }
        return points
    }

    /// Forecast net worth at the end of December `year`; equals `startingNetWorth` when
    /// there are no months between `latestRealMonth` and that December.
    public static func forecastNetWorth(startingNetWorth: Int, latestRealMonth: (year: Int, month: Int), atEndOf year: Int, categories: [Category], entries: [ForecastEntry], groups: [ForecastGroup], exceptions: [PlannedOccurrenceException], filter: PlanAccountFilter? = nil) -> Int {
        monthlyProjection(startingNetWorth: startingNetWorth, latestRealMonth: latestRealMonth, throughYear: year, categories: categories, entries: entries, groups: groups, exceptions: exceptions, filter: filter).last?.valueMinorUnits ?? startingNetWorth
    }

    /// What the plan still expects in the walk-start month `year`/`month` (spec 2026-10-15
    /// net-worth-forecast-fix §1), as the Budget grid's pending amounts: per category that
    /// counts in net worth (`ForecastCalculator.netWorthTotals`), the calendar month's planned
    /// total beyond the pay month's `actuals` (`PlanStatus.cell`'s pending, so paid items aren't
    /// counted twice); reserves by what's left of their allowances after the month's unforecast
    /// spend (`ReservedCategories.monthAllowances`, as the grid's reserve rows). With `filter`,
    /// the selected accounts' plan (`actuals` must be theirs too); incoming planned transfers
    /// filed outside a counting category have no actuals to match, so count in full.
    public static func remainingPlanned(year: Int, month: Int, actuals: [Int64: Int], categories: [Category], entries: [ForecastEntry], groups: [ForecastGroup], exceptions: [PlannedOccurrenceException], filter: PlanAccountFilter? = nil) -> Int {
        let range = MonthRange.of(year: year, month: month)
        let period = PayPeriod(startDate: range.start, endDate: range.end, type: .projected)
        let planned = ForecastCalculator.netWorthTotals(period: period, categories: categories, entries: entries, groups: groups, exceptions: exceptions, filter: filter)
        var total = planned.incomingElsewhere
        var reserves: [(id: Int64, name: String, allowance: Int)] = []
        for category in categories {
            guard let id = category.id, let plan = planned.byCategory[id], plan != 0 else { continue }
            if category.isReserved {
                reserves.append((id, category.name, plan))
            } else {
                total += PlanStatus.cell(actual: actuals[id] ?? 0, planned: plan, categoryType: category.type, monthClass: .blended).pending
            }
        }
        if !reserves.isEmpty {
            // Unforecast spend: expense categories with actuals and no plan for these accounts.
            let plannedTotals = ForecastCalculator.confirmedTotalsByCategory(period: period, entries: entries, groups: groups, exceptions: exceptions, filter: filter)
            let monthTotals = actuals.mapValues { [year: [month: $0]] }
            let left = ReservedCategories.monthAllowances(reserves, monthClass: .blended) {
                ReservedCategories.unforecastSpend(year: year, month: month, categories: categories, monthTotals: monthTotals, plannedTotals: plannedTotals)
            }
            total += left.values.reduce(0, +)
        }
        return total
    }
}
