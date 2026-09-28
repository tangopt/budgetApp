import Foundation

public enum ForecastCalculator {
    public static func confirmedTotal(categoryId: Int64, period: PayPeriod, entries: [ForecastEntry], groups: [ForecastGroup]) -> Int {
        total(categoryId: categoryId, period: period, entries: entries, groups: groups, includeHypothetical: false)
    }

    public static func previewTotal(categoryId: Int64, period: PayPeriod, entries: [ForecastEntry], groups: [ForecastGroup]) -> Int {
        total(categoryId: categoryId, period: period, entries: entries, groups: groups, includeHypothetical: true)
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

    private static func total(categoryId: Int64, period: PayPeriod, entries: [ForecastEntry], groups: [ForecastGroup], includeHypothetical: Bool) -> Int {
        let enabledGroupIds = Set(groups.filter(\.isEnabled).compactMap(\.id))
        return entries
            .filter { $0.categoryId == categoryId }
            .filter { $0.isEnabled }
            .filter { enabledGroupIds.contains($0.groupId) }
            .filter { entry in
                switch entry.status {
                case .auto, .manual, .confirmed: return true
                case .hypothetical: return includeHypothetical
                }
            }
            .reduce(0) { $0 + FrequencyExpander.amount(for: $1, in: period) }
    }
}
