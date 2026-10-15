import Foundation

public enum ForecastCalculator {
    public static func confirmedTotal(categoryId: Int64, period: PayPeriod, entries: [ForecastEntry], groups: [ForecastGroup], exceptions: [PlannedOccurrenceException]) -> Int {
        total(categoryId: categoryId, period: period, entries: entries, groups: groups, exceptions: exceptions)
    }

    /// The confirmed forecast's net effect on account balances for one period — income minus
    /// expenses plus external transfers (money to or from other people, spec 2026-10-15
    /// net-worth-forecast-fix §2); transfers between the user's own accounts and adjustments
    /// excluded (`countsInNetWorth`). Signed: positive means net worth grows. One expansion of
    /// the plan over the period (`confirmedTotalsByCategory`).
    public static func confirmedNetWorthImpact(period: PayPeriod, categories: [Category], entries: [ForecastEntry], groups: [ForecastGroup], exceptions: [PlannedOccurrenceException]) -> Int {
        netWorthImpact(totals: confirmedTotalsByCategory(period: period, entries: entries, groups: groups, exceptions: exceptions), categories: categories, accountIds: nil)
    }

    /// Whether a category's amounts change the net worth of `accountIds` (nil = every account):
    /// income, expenses and external transfers always; a transfer category tied to an account
    /// only under a filter that leaves that account out (money crossing the selection's
    /// boundary — a planned incoming leg is filed under the paying account's transfer
    /// category, tied to an unselected account); other transfers and adjustments never.
    public static func countsInNetWorth(_ category: Category, accountIds: Set<Int64>?) -> Bool {
        if category.type.isFlow { return true }
        guard category.type == .transfer else { return false }
        if category.isExternalTransfer { return true }
        guard let accountIds, let tied = category.transferAccountId else { return false }
        return !accountIds.contains(tied)
    }

    /// The sum of `totals` (per category id) over the categories that count in net worth.
    public static func netWorthImpact(totals: [Int64: Int], categories: [Category], accountIds: Set<Int64>?) -> Int {
        categories.reduce(0) { sum, category in
            guard let id = category.id, let total = totals[id], countsInNetWorth(category, accountIds: accountIds) else { return sum }
            return sum + total
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

    /// `confirmedNetWorthImpact` for the filter's accounts (spec 2026-10-15 §4): the
    /// `netWorthTotals` summed. Nil filter = All accounts.
    public static func confirmedNetWorthImpact(period: PayPeriod, categories: [Category], entries: [ForecastEntry], groups: [ForecastGroup], exceptions: [PlannedOccurrenceException], filter: PlanAccountFilter?) -> Int {
        guard filter != nil else { return confirmedNetWorthImpact(period: period, categories: categories, entries: entries, groups: groups, exceptions: exceptions) }
        let totals = netWorthTotals(period: period, categories: categories, entries: entries, groups: groups, exceptions: exceptions, filter: filter)
        return totals.byCategory.values.reduce(0, +) + totals.incomingElsewhere
    }

    /// The plan's amounts in `period` that change the net worth of the filter's accounts, by
    /// leg (`PlannedItemAccounts.legs`): `byCategory` holds every leg filed under a category that
    /// counts (`countsInNetWorth`) — income, expenses, external transfers, and tied transfers
    /// crossing the selection's boundary (an incoming leg filed under its payer's own transfer
    /// category included); `incomingElsewhere` the incoming legs into a selected account filed
    /// anywhere else (no payer, or a payer without its own transfer category), which always
    /// count: money arriving from outside the selection. Nil filter: every category that
    /// counts for All accounts, nothing elsewhere.
    public static func netWorthTotals(period: PayPeriod, categories: [Category], entries: [ForecastEntry], groups: [ForecastGroup], exceptions: [PlannedOccurrenceException], filter: PlanAccountFilter?) -> (byCategory: [Int64: Int], incomingElsewhere: Int) {
        let counting = Set(categories.filter { countsInNetWorth($0, accountIds: filter?.accountIds) }.compactMap(\.id))
        guard let filter else {
            return (confirmedTotalsByCategory(period: period, entries: entries, groups: groups, exceptions: exceptions).filter { counting.contains($0.key) }, 0)
        }
        let plan = confirmedEntries(entries: entries, groups: groups)
        let occurrences = PlannedOccurrences.occurrences(entries: plan, exceptions: exceptions, in: period)
        var byCategory: [Int64: Int] = [:]
        var elsewhere = 0
        for leg in filter.itemAccounts.legs(occurrences, entries: plan, accountIds: filter.accountIds) {
            let occurrence = leg.occurrence
            if counting.contains(occurrence.categoryId) {
                byCategory[occurrence.categoryId, default: 0] += occurrence.amountMinorUnits
            } else if leg.isIncomingTransfer {
                elsewhere += occurrence.amountMinorUnits
            }
        }
        return (byCategory, elsewhere)
    }

    /// `confirmedNetWorthImpact` (All accounts) split by account (account-forecast spec §2): each
    /// occurrence on its effective (paying) account — income, expenses and external transfers
    /// as they are; a transfer tied to another account out of the payer and into the tied
    /// account (net worth unchanged); other transfers and adjustments nowhere. The nil key holds
    /// the items with no effective account. The values sum to `confirmedNetWorthImpact`.
    public static func netWorthImpactByAccount(period: PayPeriod, categories: [Category], entries: [ForecastEntry], groups: [ForecastGroup], exceptions: [PlannedOccurrenceException], itemAccounts: PlannedItemAccounts) -> [Int64?: Int] {
        let plan = confirmedEntries(entries: entries, groups: groups)
        let byId = Dictionary(plan.compactMap { e in e.id.map { ($0, e) } }, uniquingKeysWith: { a, _ in a })
        let counting = Set(categories.filter { countsInNetWorth($0, accountIds: nil) }.compactMap(\.id))
        var result: [Int64?: Int] = [:]
        for occurrence in PlannedOccurrences.occurrences(entries: plan, exceptions: exceptions, in: period) {
            let payer = byId[occurrence.entryId].flatMap(itemAccounts.effectiveAccount(of:))
            let amount = occurrence.amountMinorUnits
            if counting.contains(occurrence.categoryId) {
                result[payer, default: 0] += amount
            } else if let tied = itemAccounts.tiedAccountByCategory[occurrence.categoryId], tied != payer {
                result[payer, default: 0] += amount
                result[tied, default: 0] -= amount
            }
        }
        return result
    }

    /// The occurrences behind `netWorthImpactByAccount`'s nil key (budget-totals spec §2): the
    /// confirmed plan's occurrences in `period` whose series has no effective account and that
    /// move net worth — a counting category, or a transfer tied to an account. By date.
    public static func unassignedOccurrences(period: PayPeriod, categories: [Category], entries: [ForecastEntry], groups: [ForecastGroup], exceptions: [PlannedOccurrenceException], itemAccounts: PlannedItemAccounts) -> [PlannedOccurrence] {
        let plan = confirmedEntries(entries: entries, groups: groups)
        let byId = Dictionary(plan.compactMap { e in e.id.map { ($0, e) } }, uniquingKeysWith: { a, _ in a })
        let counting = Set(categories.filter { countsInNetWorth($0, accountIds: nil) }.compactMap(\.id))
        return PlannedOccurrences.occurrences(entries: plan, exceptions: exceptions, in: period)
            .filter { occurrence in
                guard let entry = byId[occurrence.entryId], itemAccounts.effectiveAccount(of: entry) == nil else { return false }
                return counting.contains(occurrence.categoryId) || itemAccounts.tiedAccountByCategory[occurrence.categoryId] != nil
            }
            .sorted { ($0.date, $0.entryId) < ($1.date, $1.entryId) }
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
