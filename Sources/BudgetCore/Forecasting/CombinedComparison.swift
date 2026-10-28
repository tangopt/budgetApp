import Foundation

/// One line of the Compare tab: a plan's net worth forecast, its yearly summary and its
/// average monthly surplus.
public struct ComparisonLine: Equatable, Sendable {
    /// "budget", "scenario-<id>" or "combined".
    public let id: String
    public let name: String
    public let forecast: [NetWorthPoint]
    public let years: [PlanYearSummary]
    public let averageMonthlySurplus: Int

    public init(id: String, name: String, forecast: [NetWorthPoint], years: [PlanYearSummary], averageMonthlySurplus: Int) {
        self.id = id
        self.name = name
        self.forecast = forecast
        self.years = years
        self.averageMonthlySurplus = averageMonthlySurplus
    }
}

/// The Compare tab's lines: the budget, each ticked scenario and, on request, the scenarios
/// combined (spec 2026-10-28-step17-scenario-comparison-design.md). Pure.
public enum CombinedComparison {
    /// Scenarios that can be ticked in Compare at once.
    public static let maxTicked = 4

    /// The actual months once, then the budget, the scenarios (in the order given) and, when
    /// `includeCombined` and at least two scenarios are given, the combined line last.
    public static func lines(_ data: ComparisonData, budget: PlanInput, scenarios: [ScenarioPlan], includeCombined: Bool)
        -> (actual: [NetWorthPoint], lines: [ComparisonLine], overlaps: [ScenarioOverlap]) {
        let actuals = ScenarioComparison.actuals(data)
        let budgetSeries = ScenarioComparison.netWorthSeries(data, plan: budget, actuals: actuals)
        let horizon = (year: data.horizonYear, month: data.horizonMonth)

        func line(_ id: String, _ name: String, _ plan: PlanInput, _ series: PlanNetWorthSeries) -> ComparisonLine {
            let years = ScenarioComparison.yearSummaries(data, plan: plan, series: series, budgetSeries: budgetSeries)
            return ComparisonLine(id: id, name: name, forecast: series.forecast, years: years,
                                  averageMonthlySurplus: ScenarioImpact.averageMonthlySurplus(years, horizon: horizon))
        }

        var lines = [line("budget", "Budget", budget, budgetSeries)]
        for scenario in scenarios {
            if Task.isCancelled { break }
            let series = ScenarioComparison.netWorthSeries(data, plan: scenario.plan, actuals: actuals)
            lines.append(line("scenario-\(scenario.id)", scenario.name, scenario.plan, series))
        }
        var overlaps: [ScenarioOverlap] = []
        if scenarios.count >= 2 {
            let combined = ScenarioCombinator.combine(budget: budget, scenarios: scenarios)
            overlaps = combined.overlaps
            if includeCombined, !Task.isCancelled {
                let series = ScenarioComparison.netWorthSeries(data, plan: combined.plan, actuals: actuals)
                lines.append(line("combined", "Combined", combined.plan, series))
            }
        }
        return (budgetSeries.actual, lines, overlaps)
    }

    /// The selection with ids that are no longer available (deleted scenarios) dropped.
    public static func pruned(selection: Set<Int64>, available: Set<Int64>) -> Set<Int64> {
        selection.intersection(available)
    }

    /// The selection to keep after a tick: the new one, unless it grows past `maxTicked`,
    /// when the previous one stays.
    public static func limited(old: Set<Int64>, new: Set<Int64>) -> Set<Int64> {
        new.count > maxTicked && new.count > old.count ? old : new
    }

    /// The first `maxTicked` of `ids` in list order (the first load's selection).
    public static func initialSelection(_ ids: [Int64]) -> Set<Int64> {
        Set(ids.prefix(maxTicked))
    }
}
