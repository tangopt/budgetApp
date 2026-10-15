import Foundation

public struct YearEndForecast: Equatable {
    public let year: Int
    public let valueMinorUnits: Int
    public let changeMinorUnits: Int
    public let percent: Double?
}

public struct BehindBalances: Equatable {
    /// Accounts needing updates (`BalanceStaleness.needsUpdates`) whose last activity is
    /// older than the data-through month.
    public let accountCount: Int
    public let oldestSnapshotDate: Date
}

public struct NetWorthSeries: Equatable {
    /// Month values from the first month with a balance through the data-through month.
    public let actual: [NetWorthPoint]
    /// Starts at the actual series' last month (the calendar month of the data-through date,
    /// anchored at the current net worth) so the two lines meet, then runs the Forecast
    /// screen's walk — from the pay month containing the data-through date — to December of
    /// next year. When the data runs past payday that pay month is the next calendar month,
    /// which repeats the anchor value.
    public let forecast: [NetWorthPoint]
    public let currentNetWorthMinorUnits: Int?
    public let asOf: Date?
    public let changeVsPreviousMonthMinorUnits: Int?
    /// This year and next year, matching the Forecast screen's headline figures.
    public let yearEnds: [YearEndForecast]
    public let behindBalances: BehindBalances?

    public static let empty = NetWorthSeries(actual: [], forecast: [], currentNetWorthMinorUnits: nil, asOf: nil, changeVsPreviousMonthMinorUnits: nil, yearEnds: [], behindBalances: nil)
}

/// A calendar year's closing net worth: the real 31 Dec value for a completed year, the
/// forecast to December for this year (and later ones).
public struct YearEndNetWorth: Equatable {
    public let valueMinorUnits: Int
    public let isForecast: Bool
}

/// The plan-independent part of a net worth series: the actual months, the current net
/// worth and where the forecast walk starts. Computed once, it is shared by every plan the
/// scenario comparison projects.
public struct NetWorthActuals: Equatable, Sendable {
    /// As `NetWorthSeries.actual`.
    public let actual: [NetWorthPoint]
    public let currentNetWorthMinorUnits: Int
    /// The forecast line's leading points at the current net worth (the data month when it
    /// precedes the walk's pay month, then that pay month); empty without transactions.
    let forecastAnchors: [NetWorthPoint]
    /// The pay month holding the latest transaction; nil without transactions.
    let walkStartYear: Int?
    let walkStartMonth: Int?
    /// That pay month's confirmed budget-facing actuals per category (the covered accounts'),
    /// and whether it is closed: what the walk needs for the month's remaining plan
    /// (`ForecastProjector.remainingPlanned`).
    let walkStartActuals: [Int64: Int]
    let walkStartIsClosed: Bool

    /// The walk's starting value for a plan: the current net worth plus what the plan still
    /// expects in the walk-start month (spec 2026-10-15 net-worth-forecast-fix §1).
    public func projectionStart(categories: [Category], entries: [ForecastEntry], groups: [ForecastGroup], exceptions: [PlannedOccurrenceException], filter: PlanAccountFilter? = nil) -> Int {
        guard let year = walkStartYear, let month = walkStartMonth, !walkStartIsClosed else { return currentNetWorthMinorUnits }
        return currentNetWorthMinorUnits + ForecastProjector.remainingPlanned(year: year, month: month, actuals: walkStartActuals, categories: categories, entries: entries,
                                                                              groups: groups, exceptions: exceptions, filter: filter)
    }

    /// The forecast net worth at the end of December `year` from `start` (`projectionStart`),
    /// shared by the Dashboard's year-ends and the Budget's year cards (`yearEndNetWorth`): a
    /// December before the walk-start month's year is the current net worth (nothing planned
    /// counts yet — e.g. data past December's payday starts the walk in next year's January).
    /// Nil without transactions.
    public func forecastYearEnd(_ year: Int, start: Int, categories: [Category], entries: [ForecastEntry], groups: [ForecastGroup], exceptions: [PlannedOccurrenceException], filter: PlanAccountFilter? = nil) -> Int? {
        guard let startYear = walkStartYear, let startMonth = walkStartMonth else { return nil }
        guard year >= startYear else { return currentNetWorthMinorUnits }
        return ForecastProjector.forecastNetWorth(startingNetWorth: start, latestRealMonth: (startYear, startMonth), atEndOf: year, categories: categories, entries: entries,
                                                  groups: groups, exceptions: exceptions, filter: filter)
    }
}

/// One bar of the year-over-year chart. Completed years are all `realised`; the current
/// year splits at the latest actual month; future years are all `forecast`.
public struct YearChange: Equatable, Identifiable {
    public let year: Int
    public let realisedMinorUnits: Int
    public let forecastMinorUnits: Int
    /// Total change as a fraction of the baseline's magnitude; nil when the baseline is 0.
    public let percent: Double?
    /// Set (to the baseline month) for the first data year, whose baseline is its first
    /// available month rather than the previous December.
    public let partialFromMonth: Int?
    public var id: Int { year }
    public var totalMinorUnits: Int { realisedMinorUnits + forecastMinorUnits }
}

extension DashboardCalculator {
    /// `forecastThroughYear` (default: next year) is how far the forecast line runs; the
    /// scenario comparison passes its horizon's year. `yearEnds` are always this and next year.
    public static func netWorthSeries(_ input: DashboardInput, forecastThroughYear: Int? = nil) -> NetWorthSeries {
        guard let actuals = netWorthActuals(input) else { return .empty }
        let current = actuals.currentNetWorthMinorUnits
        let actual = actuals.actual
        let dataMonth = input.dataThrough.map { MonthRange.components(of: $0) }
        let thisYear = MonthRange.components(of: input.today).year
        let start = actuals.projectionStart(categories: input.categories, entries: input.forecastEntries, groups: input.forecastGroups, exceptions: input.exceptions, filter: input.accountFilter)
        let forecast = netWorthForecast(actuals, start: start, throughYear: forecastThroughYear ?? thisYear + 1, categories: input.categories, entries: input.forecastEntries,
                                        groups: input.forecastGroups, exceptions: input.exceptions, filter: input.accountFilter)
        var yearEnds: [YearEndForecast] = []
        if actuals.walkStartYear != nil {
            func forecastValue(atEndOf year: Int) -> Int {
                actuals.forecastYearEnd(year, start: start, categories: input.categories, entries: input.forecastEntries, groups: input.forecastGroups,
                                        exceptions: input.exceptions, filter: input.accountFilter) ?? current
            }
            for year in [thisYear, thisYear + 1] {
                let value = forecastValue(atEndOf: year)
                // Baseline: last December's REAL net worth once that pay month is closed,
                // else last December's forecast.
                let baseline: Int
                if input.payCalendar.isClosed(PayMonth(year: year - 1, month: 12)) {
                    baseline = monthEndNetWorth(input, year: year - 1, month: 12) ?? 0
                } else {
                    baseline = forecastValue(atEndOf: year - 1)
                }
                let change = value - baseline
                yearEnds.append(YearEndForecast(year: year, valueMinorUnits: value, changeMinorUnits: change, percent: baseline != 0 ? Double(change) / Double(abs(baseline)) : nil))
            }
        }

        // "As of": the latest activity (snapshot, transaction up to today or balance confirmation) of any account.
        let asOf = input.netWorthAccounts.compactMap { BalanceStaleness.lastActivity(account: $0, snapshots: input.snapshots, transactions: input.transactions, today: input.today) }.max()

        let changeVsPrevious: Int? = actual.count >= 2 ? actual[actual.count - 1].valueMinorUnits - actual[actual.count - 2].valueMinorUnits : nil

        // Behind: an account that needs updates (`BalanceStaleness.needsUpdates`: investments
        // and accounts never imported into) whose last activity predates the data month.
        var behindDates: [Date] = []
        if let dataMonth {
            let dataIndex = MonthRange.index(year: dataMonth.year, month: dataMonth.month)
            for account in input.netWorthAccounts where BalanceStaleness.needsUpdates(account: account, transactions: input.transactions) {
                guard let latest = BalanceStaleness.lastActivity(account: account, snapshots: input.snapshots, transactions: input.transactions, today: input.today) else { continue }
                let parts = MonthRange.components(of: latest)
                if MonthRange.index(year: parts.year, month: parts.month) < dataIndex { behindDates.append(latest) }
            }
        }
        let behind = behindDates.min().map { BehindBalances(accountCount: behindDates.count, oldestSnapshotDate: $0) }

        return NetWorthSeries(actual: actual, forecast: forecast, currentNetWorthMinorUnits: current, asOf: asOf, changeVsPreviousMonthMinorUnits: changeVsPrevious, yearEnds: yearEnds, behindBalances: behind)
    }

    /// Net worth at the end of `year`: the real December month-end for years before today's,
    /// the Dashboard's forecast-to-December (same walk as `netWorthSeries.yearEnds`) for this
    /// year and later. Nil when there is no data to base it on.
    ///
    /// With `includeForecast` false (the Budget's Show forecast off, spec 2026-10-15 §1) this
    /// year is the actual net worth today (`isForecast` false) and later years are nil; past
    /// years are unchanged.
    public static func yearEndNetWorth(_ input: DashboardInput, year: Int, includeForecast: Bool = true) -> YearEndNetWorth? {
        let thisYear = MonthRange.components(of: input.today).year
        if year < thisYear {
            return monthEndNetWorth(input, year: year, month: 12).map { YearEndNetWorth(valueMinorUnits: $0, isForecast: false) }
        }
        if !includeForecast {
            guard year == thisYear, let actuals = netWorthActuals(input) else { return nil }
            return YearEndNetWorth(valueMinorUnits: actuals.currentNetWorthMinorUnits, isForecast: false)
        }
        guard let actuals = netWorthActuals(input) else { return nil }
        let start = actuals.projectionStart(categories: input.categories, entries: input.forecastEntries, groups: input.forecastGroups, exceptions: input.exceptions, filter: input.accountFilter)
        return actuals.forecastYearEnd(year, start: start, categories: input.categories, entries: input.forecastEntries, groups: input.forecastGroups,
                                       exceptions: input.exceptions, filter: input.accountFilter)
            .map { YearEndNetWorth(valueMinorUnits: $0, isForecast: true) }
    }

    /// The Budget's Net Worth row for `year` (spec 2026-10-15 §1, §4; net-worth-forecast-fix §3),
    /// January first: the actual month-end net worth (balances carried forward) through the
    /// month of `effectiveToday`; with `includeForecast`, the walk-start month (the pay month
    /// holding the latest data) when it isn't over yet shows the current net worth plus its
    /// remaining plan, and later months the forecast walk; without it later months are nil
    /// ("—"). Nil also where there's no data yet. Covers `input.accountFilter`'s accounts when set.
    public static func budgetNetWorthMonths(_ input: DashboardInput, year: Int, includeForecast: Bool) -> [Int?] {
        let today = MonthRange.components(of: input.effectiveToday)
        let todayIndex = MonthRange.index(year: today.year, month: today.month)
        var forecast: [Int: Int] = [:]
        var walkStart: (index: Int, value: Int)?
        if includeForecast, MonthRange.index(year: year, month: 12) >= todayIndex, let actuals = netWorthActuals(input) {
            let start = actuals.projectionStart(categories: input.categories, entries: input.forecastEntries, groups: input.forecastGroups, exceptions: input.exceptions, filter: input.accountFilter)
            for point in netWorthForecast(actuals, start: start, throughYear: year, categories: input.categories, entries: input.forecastEntries, groups: input.forecastGroups,
                                          exceptions: input.exceptions, filter: input.accountFilter) {
                forecast[point.id] = point.valueMinorUnits
            }
            if let startYear = actuals.walkStartYear, let startMonth = actuals.walkStartMonth {
                let index = MonthRange.index(year: startYear, month: startMonth)
                if index >= todayIndex { walkStart = (index, start) }
            }
        }
        return (1...12).map { month in
            let index = MonthRange.index(year: year, month: month)
            if let walkStart, walkStart.index == index { return walkStart.value }
            return index <= todayIndex ? monthEndNetWorth(input, year: year, month: month) : forecast[index]
        }
    }

    /// The series' plan-independent part (`NetWorthActuals`); nil when no account has a
    /// balance yet (no snapshot and no transaction).
    public static func netWorthActuals(_ input: DashboardInput) -> NetWorthActuals? {
        // Where each account's balance starts: its first snapshot (the opening balance), or
        // its first transaction when it has no snapshot (`NetWorthCalculator.balance`).
        let starts: [Date] = input.netWorthAccounts.compactMap { account in
            input.snapshots.lazy.filter { $0.accountId == account.id }.map(\.date).min()
                ?? input.transactions.lazy.filter { $0.accountId == account.id }.map(\.date).min()
        }
        let latestActivity = input.netWorthAccounts.compactMap { BalanceStaleness.lastActivity(account: $0, snapshots: input.snapshots, transactions: input.transactions, today: input.today) }.max()
        guard let firstData = starts.min(), let lastData = latestActivity ?? starts.max() else { return nil }
        let balances = NetWorthCalculator.accountBalances(accounts: input.netWorthAccounts, snapshots: input.snapshots, transactions: input.transactions, rate: input.rate)
        let current = NetWorthCalculator.netWorth(balances: balances)

        let dataMonth = input.dataThrough.map { MonthRange.components(of: $0) }
        let lastActualMonth = dataMonth ?? MonthRange.components(of: lastData)

        // Actual: one point per month, balances carried forward (the same formula as the Budget grid).
        var actual: [NetWorthPoint] = []
        var cursor = MonthRange.components(of: firstData)
        let lastActualIndex = MonthRange.index(year: lastActualMonth.year, month: lastActualMonth.month)
        while MonthRange.index(year: cursor.year, month: cursor.month) <= lastActualIndex {
            if let value = monthEndNetWorth(input, year: cursor.year, month: cursor.month) {
                actual.append(NetWorthPoint(year: cursor.year, month: cursor.month, valueMinorUnits: value))
            }
            cursor = (cursor.month == 12) ? (cursor.year + 1, 1) : (cursor.year, cursor.month + 1)
        }

        // Forecast anchors: the current net worth in the pay month holding the latest
        // transaction (the walk runs from the month after it). The dashed line also starts
        // where the solid one ends (`dataMonth`): past payday the pay month is the next
        // calendar month, which would otherwise leave a one-month gap between them.
        guard let dataMonth, let dataThrough = input.dataThrough else {
            return NetWorthActuals(actual: actual, currentNetWorthMinorUnits: current, forecastAnchors: [], walkStartYear: nil, walkStartMonth: nil, walkStartActuals: [:], walkStartIsClosed: false)
        }
        let payMonth = input.payCalendar.month(containing: dataThrough)
        var anchors = [NetWorthPoint(year: payMonth.year, month: payMonth.month, valueMinorUnits: current)]
        if MonthRange.index(year: dataMonth.year, month: dataMonth.month) < MonthRange.index(year: payMonth.year, month: payMonth.month) {
            anchors.insert(NetWorthPoint(year: dataMonth.year, month: dataMonth.month, valueMinorUnits: current), at: 0)
        }
        // The walk-start month's actuals for the remaining plan: budget-facing transactions of
        // every status (current net worth already holds unreviewed ones, so they count as paid).
        let range = input.payCalendar.range(of: payMonth)
        let facing = input.accountFilter.map { TransferLinks.budgetFacing(input.transactions, links: input.transferLinks, accountIds: $0.accountIds) } ?? input.budgetTransactions
        let walkStartActuals = facing.reduce(into: [Int64: Int]()) { totals, transaction in
            guard let categoryId = transaction.categoryId, transaction.date >= range.start, transaction.date <= range.end else { return }
            totals[categoryId, default: 0] += transaction.amountMinorUnits
        }
        return NetWorthActuals(actual: actual, currentNetWorthMinorUnits: current, forecastAnchors: anchors, walkStartYear: payMonth.year, walkStartMonth: payMonth.month,
                               walkStartActuals: walkStartActuals, walkStartIsClosed: input.payCalendar.isClosed(payMonth))
    }

    /// A plan's forecast line from shared `actuals`: the anchors (at the current net worth,
    /// where the solid line ends), then `ForecastProjector.monthlyProjection` with the plan's
    /// entries through `throughYear`, starting from `projectionStart` (the walk-start month's
    /// remaining plan included). Empty without transactions.
    public static func netWorthForecast(_ actuals: NetWorthActuals, throughYear: Int, categories: [Category], entries: [ForecastEntry], groups: [ForecastGroup], exceptions: [PlannedOccurrenceException], filter: PlanAccountFilter? = nil) -> [NetWorthPoint] {
        let start = actuals.projectionStart(categories: categories, entries: entries, groups: groups, exceptions: exceptions, filter: filter)
        return netWorthForecast(actuals, start: start, throughYear: throughYear, categories: categories, entries: entries, groups: groups, exceptions: exceptions, filter: filter)
    }

    /// `netWorthForecast` with the plan's `projectionStart` already worked out.
    static func netWorthForecast(_ actuals: NetWorthActuals, start: Int, throughYear: Int, categories: [Category], entries: [ForecastEntry], groups: [ForecastGroup], exceptions: [PlannedOccurrenceException], filter: PlanAccountFilter?) -> [NetWorthPoint] {
        guard let year = actuals.walkStartYear, let month = actuals.walkStartMonth else { return [] }
        // The data month's anchor meets the solid line at the current net worth; a later
        // walk-start (pay) month's anchor is that month's end: the current net worth plus its remaining plan.
        let walkStartIndex = MonthRange.index(year: year, month: month)
        let anchors = actuals.forecastAnchors.map { anchor in
            anchor.id == walkStartIndex && actuals.forecastAnchors.count > 1 ? NetWorthPoint(year: anchor.year, month: anchor.month, valueMinorUnits: start) : anchor
        }
        return anchors + ForecastProjector.monthlyProjection(startingNetWorth: start, latestRealMonth: (year, month), throughYear: throughYear,
                                                                             categories: categories, entries: entries, groups: groups, exceptions: exceptions, filter: filter)
    }

    /// One entry per year from the first data year to next year. See `YearChange`.
    public static func yearOverYear(_ input: DashboardInput, series: NetWorthSeries) -> [YearChange] {
        guard let firstActual = series.actual.first, let lastActual = series.actual.last else { return [] }
        var valueByIndex: [Int: Int] = [:]
        for point in series.forecast { valueByIndex[point.id] = point.valueMinorUnits }
        for point in series.actual { valueByIndex[point.id] = point.valueMinorUnits } // actual wins at the junction

        let lastActualIndex = lastActual.id
        let firstYear = firstActual.year
        let lastYear = MonthRange.components(of: input.today).year + 1
        guard firstYear <= lastYear else { return [] }

        var result: [YearChange] = []
        for year in firstYear...lastYear {
            let decemberIndex = MonthRange.index(year: year, month: 12)
            guard let december = valueByIndex[decemberIndex] else { continue }
            let isFirstYear = year == firstYear
            let baselineIndex = isFirstYear ? firstActual.id : MonthRange.index(year: year - 1, month: 12)
            guard let baseline = valueByIndex[baselineIndex] else { continue }
            let total = december - baseline

            let realised: Int
            if decemberIndex <= lastActualIndex {
                realised = total
            } else if baselineIndex <= lastActualIndex {
                realised = lastActual.valueMinorUnits - baseline
            } else {
                realised = 0
            }
            result.append(YearChange(
                year: year, realisedMinorUnits: realised, forecastMinorUnits: total - realised,
                percent: baseline != 0 ? Double(total) / Double(abs(baseline)) : nil,
                partialFromMonth: isFirstYear ? firstActual.month : nil
            ))
        }
        return result
    }

    private static func monthEndNetWorth(_ input: DashboardInput, year: Int, month: Int) -> Int? {
        NetWorthCalculator.monthEndNetWorth(accounts: input.netWorthAccounts, snapshots: input.snapshots, transactions: input.transactions, rate: input.rate, year: year, month: month)
    }
}
