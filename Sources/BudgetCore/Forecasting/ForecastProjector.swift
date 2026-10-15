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

    /// `remainingPlanned` (All accounts) split by account (account-forecast spec §2), the nil key
    /// holding the items with no effective account; the values sum to `remainingPlanned`. Each
    /// category's remainder is worked out once over every account (`actuals`, so a payment made
    /// from another account still counts) and shared by its items' accounts in proportion to
    /// what each account still expects on its own (`actualsByAccount`: account id → category id
    /// → the pay month's budget-facing actual; `allocate`). A transfer tied to another account
    /// moves each payer's own pending amount out of it and into the tied account; reserves share
    /// what's left of their allowances by their amounts.
    public static func remainingPlannedByAccount(year: Int, month: Int, actuals: [Int64: Int], actualsByAccount: [Int64: [Int64: Int]], categories: [Category], entries: [ForecastEntry],
                                                 groups: [ForecastGroup], exceptions: [PlannedOccurrenceException], itemAccounts: PlannedItemAccounts) -> [Int64?: Int] {
        let range = MonthRange.of(year: year, month: month)
        let period = PayPeriod(startDate: range.start, endDate: range.end, type: .projected)
        let plan = ForecastCalculator.confirmedEntries(entries: entries, groups: groups)
        let byId = Dictionary(plan.compactMap { e in e.id.map { ($0, e) } }, uniquingKeysWith: { a, _ in a })
        // The paying legs: category → account → planned amount.
        var legs: [Int64: [Int64?: Int]] = [:]
        for occurrence in PlannedOccurrences.occurrences(entries: plan, exceptions: exceptions, in: period) {
            let payer = byId[occurrence.entryId].flatMap(itemAccounts.effectiveAccount(of:))
            legs[occurrence.categoryId, default: [:]][payer, default: 0] += occurrence.amountMinorUnits
        }
        var result: [Int64?: Int] = [:]
        /// Each paying account's own pending amount in the category, against its own actuals.
        func ownPending(_ category: Category, id: Int64) -> [Int64?: Int] {
            Dictionary(uniqueKeysWithValues: (legs[id] ?? [:]).map { account, planned in
                (account, PlanStatus.cell(actual: account.flatMap { actualsByAccount[$0]?[id] } ?? 0, planned: planned, categoryType: category.type, monthClass: .blended).pending)
            })
        }
        var reserves: [(id: Int64, name: String, allowance: Int)] = []
        for category in categories {
            guard let id = category.id, let byAccount = legs[id] else { continue }
            let planned = byAccount.values.reduce(0, +)
            guard planned != 0 else { continue }
            if ForecastCalculator.countsInNetWorth(category, accountIds: nil) {
                if category.isReserved {
                    reserves.append((id, category.name, planned))
                    continue
                }
                // Counted once over every account (a payment from another account still
                // counts), shared by what each account still expects on its own.
                let pending = PlanStatus.cell(actual: actuals[id] ?? 0, planned: planned, categoryType: category.type, monthClass: .blended).pending
                for (account, share) in allocate(pending, weights: ownPending(category, id: id), planned: byAccount) { result[account, default: 0] += share }
            } else if let tied = itemAccounts.tiedAccountByCategory[id] {
                // A tied transfer leaves net worth alone: each payer's own pending amount moves
                // out of it and into the tied account (an unpaid leg stays expected even when
                // another payer sent more than planned).
                for (account, pending) in ownPending(category, id: id) where pending != 0 && account != tied {
                    result[account, default: 0] += pending
                    result[tied, default: 0] -= pending
                }
            }
        }
        if !reserves.isEmpty {
            let plannedTotals = ForecastCalculator.confirmedTotalsByCategory(period: period, entries: entries, groups: groups, exceptions: exceptions)
            let monthTotals = actuals.mapValues { [year: [month: $0]] }
            let left = ReservedCategories.monthAllowances(reserves, monthClass: .blended) {
                ReservedCategories.unforecastSpend(year: year, month: month, categories: categories, monthTotals: monthTotals, plannedTotals: plannedTotals)
            }
            // Reserves never hold transactions: shared by their allowances' amounts.
            for (id, amount) in left {
                for (account, share) in allocate(amount, weights: legs[id] ?? [:], planned: legs[id] ?? [:]) { result[account, default: 0] += share }
            }
        }
        return result
    }

    /// `amount` shared in proportion to the `weights` with its sign (whole minor units, summing
    /// exactly to `amount`; the rounding remainder goes to the largest weight). With no such
    /// weight, all of it goes to the account with the largest `planned` leg of its sign (else
    /// the largest leg; no legs → unassigned).
    static func allocate(_ amount: Int, weights: [Int64?: Int], planned: [Int64?: Int]) -> [Int64?: Int] {
        guard amount != 0 else { return [:] }
        func sorted(_ values: [Int64?: Int]) -> [Int64?] { values.keys.sorted { ($0 ?? .min) < ($1 ?? .min) } }
        /// The key with the largest magnitude (the first in key order among equals); nil when empty.
        func largest(_ values: [Int64?: Int]) -> Int64?? {
            sorted(values).reduce(nil as Int64??) { best, key in
                guard let current = best else { return .some(key) }
                return abs(values[key]!) > abs(values[current]!) ? .some(key) : best
            }
        }
        let same = weights.filter { $0.value.signum() == amount.signum() }
        guard let top = largest(same) else {
            let sameLegs = planned.filter { $0.value.signum() == amount.signum() }
            return [(largest(sameLegs) ?? largest(planned)) ?? nil: amount]
        }
        let total = same.values.reduce(0, +)
        var shares: [Int64?: Int] = [:]
        var given = 0
        for key in sorted(same) where key != top {
            let share = Int((Double(amount) * Double(same[key]!) / Double(total)).rounded(.towardZero))
            if share != 0 { shares[key] = share; given += share }
        }
        shares[top] = amount - given
        return shares
    }
}
