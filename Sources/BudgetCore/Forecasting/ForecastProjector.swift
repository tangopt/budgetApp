import Foundation

/// The month-by-month forecast net worth walk, shared by the dashboard (year-end figures and
/// the dashed forecast line) and the scenario lab's comparison (through
/// `DashboardCalculator.netWorthSeries`) so they cannot diverge.
public enum ForecastProjector {
    /// Running confirmed net worth at the END of every month strictly after
    /// `latestRealMonth`, through December of `throughYear`: starting net worth plus the
    /// accumulated `confirmedNetWorthImpact` (transfers excluded). Empty when
    /// `latestRealMonth` is already at or past that December.
    public static func monthlyProjection(startingNetWorth: Int, latestRealMonth: (year: Int, month: Int), throughYear: Int, categories: [Category], entries: [ForecastEntry], groups: [ForecastGroup], exceptions: [PlannedOccurrenceException]) -> [NetWorthPoint] {
        var points: [NetWorthPoint] = []
        var running = startingNetWorth
        var cursor = (year: latestRealMonth.year, month: latestRealMonth.month + 1)
        if cursor.month > 12 { cursor = (cursor.year + 1, 1) }
        while cursor.year <= throughYear {
            let range = MonthRange.of(year: cursor.year, month: cursor.month)
            let period = PayPeriod(startDate: range.start, endDate: range.end, type: .projected)
            running += ForecastCalculator.confirmedNetWorthImpact(period: period, categories: categories, entries: entries, groups: groups, exceptions: exceptions)
            points.append(NetWorthPoint(year: cursor.year, month: cursor.month, valueMinorUnits: running))
            cursor.month += 1
            if cursor.month > 12 { cursor = (cursor.year + 1, 1) }
        }
        return points
    }

    /// Forecast net worth at the end of December `year`; equals `startingNetWorth` when
    /// there are no months between `latestRealMonth` and that December.
    public static func forecastNetWorth(startingNetWorth: Int, latestRealMonth: (year: Int, month: Int), atEndOf year: Int, categories: [Category], entries: [ForecastEntry], groups: [ForecastGroup], exceptions: [PlannedOccurrenceException]) -> Int {
        monthlyProjection(startingNetWorth: startingNetWorth, latestRealMonth: latestRealMonth, throughYear: year, categories: categories, entries: entries, groups: groups, exceptions: exceptions).last?.valueMinorUnits ?? startingNetWorth
    }
}
