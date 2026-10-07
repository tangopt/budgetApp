import Foundation

public enum ForecastCalculator {
    public static func confirmedTotal(categoryId: Int64, period: PayPeriod, entries: [ForecastEntry], groups: [ForecastGroup], exceptions: [PlannedOccurrenceException]) -> Int {
        total(categoryId: categoryId, period: period, entries: entries, groups: groups, exceptions: exceptions, selectedScenarioGroupId: nil, includeHypothetical: false)
    }

    /// `selectedScenarioGroupId` scopes which scenario's hypothetical entries count —
    /// only entries belonging to that specific group are included, not "any enabled
    /// group" (unlike confirmed/auto/manual entries, which are still gated by their own
    /// group's `isEnabled`, unrelated to selection). `nil` means no scenario is selected,
    /// so no hypothetical entries count at all — `previewTotal` then equals `confirmedTotal`.
    public static func previewTotal(categoryId: Int64, period: PayPeriod, entries: [ForecastEntry], groups: [ForecastGroup], selectedScenarioGroupId: Int64?, exceptions: [PlannedOccurrenceException]) -> Int {
        total(categoryId: categoryId, period: period, entries: entries, groups: groups, exceptions: exceptions, selectedScenarioGroupId: selectedScenarioGroupId, includeHypothetical: true)
    }

    /// The confirmed forecast's net effect on account balances for one period — income
    /// minus expenses, transfer categories excluded (moving money to the user's own
    /// savings/ISA doesn't change net worth). Signed: positive means net worth grows.
    public static func confirmedNetWorthImpact(period: PayPeriod, categories: [Category], entries: [ForecastEntry], groups: [ForecastGroup], exceptions: [PlannedOccurrenceException]) -> Int {
        categories.reduce(0) { sum, category in
            guard category.type != .transfer, let categoryId = category.id else { return sum }
            return sum + confirmedTotal(categoryId: categoryId, period: period, entries: entries, groups: groups, exceptions: exceptions)
        }
    }

    /// The selected scenario's preview net effect on account balances for one period —
    /// `previewTotal` minus `confirmedTotal`, summed across non-transfer categories. This
    /// is the *delta* a scenario would add on top of the confirmed forecast, not a full
    /// preview total by itself. `nil` selection (or a scenario with no entries in a given
    /// category) contributes 0. Signed the same way as `confirmedNetWorthImpact`.
    public static func previewNetWorthDelta(period: PayPeriod, categories: [Category], entries: [ForecastEntry], groups: [ForecastGroup], selectedScenarioGroupId: Int64?, exceptions: [PlannedOccurrenceException]) -> Int {
        categories.reduce(0) { sum, category in
            guard category.type != .transfer, let categoryId = category.id else { return sum }
            let confirmed = confirmedTotal(categoryId: categoryId, period: period, entries: entries, groups: groups, exceptions: exceptions)
            let preview = previewTotal(categoryId: categoryId, period: period, entries: entries, groups: groups, selectedScenarioGroupId: selectedScenarioGroupId, exceptions: exceptions)
            return sum + (preview - confirmed)
        }
    }

    /// The entries that count toward the *confirmed* forecast (the budget's plan): budget
    /// entries only (`scenarioId == nil`, whatever the caller loaded) that `planEntries`
    /// keeps. Shared by `total` and by the dashboard's upcoming-bills list so the two can
    /// never apply different rules.
    public static func confirmedEntries(entries: [ForecastEntry], groups: [ForecastGroup]) -> [ForecastEntry] {
        planEntries(entries: entries.filter { $0.scenarioId == nil }, groups: groups)
    }

    /// The effective plan of a set of entries — the budget's, or one scenario's own entries:
    /// enabled, not hypothetical, not a scenario `removed` tombstone, in an enabled group.
    /// No scenario filter: pass only the entries of the plan being evaluated.
    public static func planEntries(entries: [ForecastEntry], groups: [ForecastGroup]) -> [ForecastEntry] {
        let enabledGroupIds = Set(groups.filter(\.isEnabled).compactMap(\.id))
        return entries.filter { $0.isEnabled && $0.status != .hypothetical && $0.scenarioChange != .removed && enabledGroupIds.contains($0.groupId) }
    }

    /// `confirmedTotal` for every category at once: one expansion of the planned items over
    /// `period`, keyed by each occurrence's (possibly re-filed) category. Categories with no
    /// occurrence are absent (a total of 0).
    public static func confirmedTotalsByCategory(period: PayPeriod, entries: [ForecastEntry], groups: [ForecastGroup], exceptions: [PlannedOccurrenceException]) -> [Int64: Int] {
        PlannedOccurrences.occurrences(entries: confirmedEntries(entries: entries, groups: groups), exceptions: exceptions, in: period)
            .reduce(into: [:]) { $0[$1.categoryId, default: 0] += $1.amountMinorUnits }
    }

    private static func total(categoryId: Int64, period: PayPeriod, entries: [ForecastEntry], groups: [ForecastGroup], exceptions: [PlannedOccurrenceException], selectedScenarioGroupId: Int64?, includeHypothetical: Bool) -> Int {
        let confirmed = confirmedEntries(entries: entries, groups: groups)
        let hypothetical = includeHypothetical
            ? entries.filter { $0.scenarioId == nil && $0.isEnabled && $0.status == .hypothetical && $0.groupId == selectedScenarioGroupId }
            : []
        // Expand every candidate entry (a re-filed occurrence can belong to another
        // category than its series), then keep occurrences filed under this category.
        // Only entries filed under this category, or with an occurrence re-filed somewhere, can contribute.
        let refiledEntryIds = Set(exceptions.filter { $0.categoryId != nil }.map(\.entryId))
        let candidates = (confirmed + hypothetical).filter { $0.categoryId == categoryId || ($0.id.map(refiledEntryIds.contains) ?? false) }
        return PlannedOccurrences.occurrences(entries: candidates, exceptions: exceptions, in: period)
            .filter { $0.categoryId == categoryId }
            .reduce(0) { $0 + $1.amountMinorUnits }
    }
}
