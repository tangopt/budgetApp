import Foundation

public enum ForecastCalculator {
    public static func confirmedTotal(categoryId: Int64, period: PayPeriod, entries: [ForecastEntry], groups: [ForecastGroup], exceptions: [PlannedOccurrenceException]) -> Int {
        total(categoryId: categoryId, period: period, entries: entries, groups: groups, exceptions: exceptions)
    }

    /// The confirmed forecast's net effect on account balances for one period — income
    /// minus expenses, transfer (and adjustment) categories excluded (moving money to the user's own
    /// savings/ISA doesn't change net worth). Signed: positive means net worth grows.
    /// One expansion of the plan over the period (`confirmedTotalsByCategory`).
    public static func confirmedNetWorthImpact(period: PayPeriod, categories: [Category], entries: [ForecastEntry], groups: [ForecastGroup], exceptions: [PlannedOccurrenceException]) -> Int {
        let totals = confirmedTotalsByCategory(period: period, entries: entries, groups: groups, exceptions: exceptions)
        return categories.reduce(0) { sum, category in
            guard category.type.isFlow, let categoryId = category.id else { return sum }
            return sum + (totals[categoryId] ?? 0)
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

    /// The confirmed plan's occurrences in `period` as the filter's accounts see them
    /// (`PlannedItemAccounts.occurrences`); every occurrence with no filter (All accounts).
    public static func confirmedOccurrences(period: PayPeriod, entries: [ForecastEntry], groups: [ForecastGroup], exceptions: [PlannedOccurrenceException], filter: PlanAccountFilter?) -> [PlannedOccurrence] {
        let plan = confirmedEntries(entries: entries, groups: groups)
        let occurrences = PlannedOccurrences.occurrences(entries: plan, exceptions: exceptions, in: period)
        guard let filter else { return occurrences }
        return filter.itemAccounts.occurrences(occurrences, entries: plan, accountIds: filter.accountIds)
    }

    /// `confirmedTotalsByCategory` for the filter's accounts (spec 2026-10-15 §3): planned items
    /// whose effective account is selected, plus incoming planned transfers into a selected
    /// account under the paying account's transfer category. Nil filter = All accounts.
    public static func confirmedTotalsByCategory(period: PayPeriod, entries: [ForecastEntry], groups: [ForecastGroup], exceptions: [PlannedOccurrenceException], filter: PlanAccountFilter?) -> [Int64: Int] {
        guard filter != nil else { return confirmedTotalsByCategory(period: period, entries: entries, groups: groups, exceptions: exceptions) }
        return confirmedOccurrences(period: period, entries: entries, groups: groups, exceptions: exceptions, filter: filter)
            .reduce(into: [:]) { $0[$1.categoryId, default: 0] += $1.amountMinorUnits }
    }

    /// `confirmedNetWorthImpact` for the filter's accounts (spec 2026-10-15 §4,
    /// `PlannedItemAccounts.netWorthImpact`). Nil filter = All accounts.
    public static func confirmedNetWorthImpact(period: PayPeriod, categories: [Category], entries: [ForecastEntry], groups: [ForecastGroup], exceptions: [PlannedOccurrenceException], filter: PlanAccountFilter?) -> Int {
        guard let filter else { return confirmedNetWorthImpact(period: period, categories: categories, entries: entries, groups: groups, exceptions: exceptions) }
        let plan = confirmedEntries(entries: entries, groups: groups)
        let occurrences = PlannedOccurrences.occurrences(entries: plan, exceptions: exceptions, in: period)
        return filter.itemAccounts.netWorthImpact(occurrences, entries: plan, categories: categories, accountIds: filter.accountIds)
    }

    private static func total(categoryId: Int64, period: PayPeriod, entries: [ForecastEntry], groups: [ForecastGroup], exceptions: [PlannedOccurrenceException]) -> Int {
        // Expand every candidate entry (a re-filed occurrence can belong to another
        // category than its series), then keep occurrences filed under this category.
        // Only entries filed under this category, or with an occurrence re-filed somewhere, can contribute.
        let refiledEntryIds = Set(exceptions.filter { $0.categoryId != nil }.map(\.entryId))
        let candidates = confirmedEntries(entries: entries, groups: groups).filter { $0.categoryId == categoryId || ($0.id.map(refiledEntryIds.contains) ?? false) }
        return PlannedOccurrences.occurrences(entries: candidates, exceptions: exceptions, in: period)
            .filter { $0.categoryId == categoryId }
            .reduce(0) { $0 + $1.amountMinorUnits }
    }
}
