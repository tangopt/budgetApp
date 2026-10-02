import Foundation

public enum ForecastCalculator {
    public static func confirmedTotal(categoryId: Int64, period: PayPeriod, entries: [ForecastEntry], groups: [ForecastGroup]) -> Int {
        total(categoryId: categoryId, period: period, entries: entries, groups: groups, selectedScenarioGroupId: nil, includeHypothetical: false)
    }

    /// `selectedScenarioGroupId` scopes which scenario's hypothetical entries count —
    /// only entries belonging to that specific group are included, not "any enabled
    /// group" (unlike confirmed/auto/manual entries, which are still gated by their own
    /// group's `isEnabled`, unrelated to selection). `nil` means no scenario is selected,
    /// so no hypothetical entries count at all — `previewTotal` then equals `confirmedTotal`.
    public static func previewTotal(categoryId: Int64, period: PayPeriod, entries: [ForecastEntry], groups: [ForecastGroup], selectedScenarioGroupId: Int64?) -> Int {
        total(categoryId: categoryId, period: period, entries: entries, groups: groups, selectedScenarioGroupId: selectedScenarioGroupId, includeHypothetical: true)
    }

    /// The confirmed forecast's net effect on account balances for one period — income
    /// minus expenses, transfer categories excluded (moving money to the user's own
    /// savings/ISA doesn't change net worth). Signed: positive means net worth grows.
    public static func confirmedNetWorthImpact(period: PayPeriod, categories: [Category], entries: [ForecastEntry], groups: [ForecastGroup]) -> Int {
        categories.reduce(0) { sum, category in
            guard category.type != .transfer, let categoryId = category.id else { return sum }
            return sum + confirmedTotal(categoryId: categoryId, period: period, entries: entries, groups: groups)
        }
    }

    /// The selected scenario's preview net effect on account balances for one period —
    /// `previewTotal` minus `confirmedTotal`, summed across non-transfer categories. This
    /// is the *delta* a scenario would add on top of the confirmed forecast, not a full
    /// preview total by itself. `nil` selection (or a scenario with no entries in a given
    /// category) contributes 0. Signed the same way as `confirmedNetWorthImpact`.
    public static func previewNetWorthDelta(period: PayPeriod, categories: [Category], entries: [ForecastEntry], groups: [ForecastGroup], selectedScenarioGroupId: Int64?) -> Int {
        categories.reduce(0) { sum, category in
            guard category.type != .transfer, let categoryId = category.id else { return sum }
            let confirmed = confirmedTotal(categoryId: categoryId, period: period, entries: entries, groups: groups)
            let preview = previewTotal(categoryId: categoryId, period: period, entries: entries, groups: groups, selectedScenarioGroupId: selectedScenarioGroupId)
            return sum + (preview - confirmed)
        }
    }

    /// The entries that count toward the *confirmed* forecast: enabled, not hypothetical, and
    /// in an enabled group. Shared by `total` and by the dashboard's upcoming-bills list so
    /// the two can never apply different rules.
    public static func confirmedEntries(entries: [ForecastEntry], groups: [ForecastGroup]) -> [ForecastEntry] {
        let enabledGroupIds = Set(groups.filter(\.isEnabled).compactMap(\.id))
        return entries.filter { $0.isEnabled && $0.status != .hypothetical && enabledGroupIds.contains($0.groupId) }
    }

    private static func total(categoryId: Int64, period: PayPeriod, entries: [ForecastEntry], groups: [ForecastGroup], selectedScenarioGroupId: Int64?, includeHypothetical: Bool) -> Int {
        let confirmed = confirmedEntries(entries: entries, groups: groups)
        let hypothetical = includeHypothetical
            ? entries.filter { $0.isEnabled && $0.status == .hypothetical && $0.groupId == selectedScenarioGroupId }
            : []
        return (confirmed + hypothetical)
            .filter { $0.categoryId == categoryId }
            .reduce(0) { $0 + FrequencyExpander.amount(for: $1, in: period) }
    }
}
