import Foundation

/// The impact table's derived figures (spec 2026-10-28-step17-scenario-comparison-design.md).
public enum ScenarioImpact {
    /// (Income − expenses) over the months shown, per month, in pence, rounded half away from
    /// zero: 12 months a year, the horizon's month in its last year. 0 for no years.
    public static func averageMonthlySurplus(_ years: [PlanYearSummary], horizon: (year: Int, month: Int)) -> Int {
        guard let last = years.last else { return 0 }
        let months = 12 * (years.count - 1) + (last.year == horizon.year ? horizon.month : 12)
        guard months > 0 else { return 0 }
        let surplus = years.map { $0.income - $0.expenses }.reduce(0, +)
        let rounded = (2 * abs(surplus) + months) / (2 * months)
        return surplus < 0 ? -rounded : rounded
    }

    /// `value` minus the budget's; nil when either is missing.
    public static func difference(_ value: Int?, from budget: Int?) -> Int? {
        guard let value, let budget else { return nil }
        return value - budget
    }
}
