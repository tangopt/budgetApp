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
    /// `walkStartActuals` per account id (the account rows' remaining plan).
    let walkStartActualsByAccount: [Int64: [Int64: Int]]
    let walkStartIsClosed: Bool
    /// The `MonthRange.index`es `actual` was worked out over (first data month through the data
    /// month), a month with no point there having no data: those month-ends need no recomputing.
    let actualMonths: ClosedRange<Int>?

    /// The month-end net worth `actual` holds for `index`: `.some(nil)` for a month in
    /// `actualMonths` with no data, nil when `index` is outside it.
    func monthEnd(atIndex index: Int) -> Int?? {
        guard let actualMonths, actualMonths.contains(index) else { return nil }
        return .some(actual.first { $0.id == index }?.valueMinorUnits)
    }

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

/// A forecast account balance: GBP for totals, the account's own currency for display.
public struct AccountForecastBalance: Equatable, Sendable {
    public let gbpMinorUnits: Int
    public let nativeMinorUnits: Int

    public init(gbpMinorUnits: Int, nativeMinorUnits: Int) {
        self.gbpMinorUnits = gbpMinorUnits
        self.nativeMinorUnits = nativeMinorUnits
    }
}

/// One year of the Budget's account rows' forecast months (`DashboardCalculator.budgetAccountForecast`).
public struct BudgetAccountForecast: Equatable, Sendable {
    /// Month (1…12) → account id → forecast balance; months without a forecast are absent.
    public let accounts: [Int: [Int64: AccountForecastBalance]]
    /// Month → the planned items with no account, accumulated (GBP), for the same months.
    public let unassigned: [Int: Int]
    /// Months past today with no forecast (Show forecast off): the rows show "—" there.
    public let blankMonths: Set<Int>

    public init(accounts: [Int: [Int64: AccountForecastBalance]], unassigned: [Int: Int], blankMonths: Set<Int> = []) {
        self.accounts = accounts
        self.unassigned = unassigned
        self.blankMonths = blankMonths
    }

    public static let empty = BudgetAccountForecast(accounts: [:], unassigned: [:])

    public func balance(accountId: Int64, month: Int) -> AccountForecastBalance? {
        accounts[month]?[accountId]
    }

    /// Whether `month` is a forecast month (an account row shows the forecast, not the actual).
    public func isForecast(month: Int) -> Bool {
        unassigned[month] != nil
    }

    /// Whether the "Not assigned to an account" row has anything to show this year.
    public var hasUnassigned: Bool {
        unassigned.values.contains { $0 != 0 }
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
        let start = actuals.projectionStart(categories: input.categories, entries: input.netWorthEntries, groups: input.forecastGroups, exceptions: input.exceptions, filter: input.netWorthFilter)
        let forecast = netWorthForecast(actuals, start: start, throughYear: forecastThroughYear ?? thisYear + 1, categories: input.categories, entries: input.netWorthEntries,
                                        groups: input.forecastGroups, exceptions: input.exceptions, filter: input.netWorthFilter)
        var yearEnds: [YearEndForecast] = []
        if actuals.walkStartYear != nil {
            func forecastValue(atEndOf year: Int) -> Int {
                actuals.forecastYearEnd(year, start: start, categories: input.categories, entries: input.netWorthEntries, groups: input.forecastGroups,
                                        exceptions: input.exceptions, filter: input.netWorthFilter) ?? current
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
        yearEndNetWorth(input, year: year, includeForecast: includeForecast, actuals: { netWorthActuals(input) }, monthEnd: { monthEndNetWorth(input, year: $0, month: $1) })
    }

    /// `yearEndNetWorth` with `actuals` already worked out (`netWorthActuals(input)`, same
    /// input): the same result, without walking the whole history again (the Budget grid
    /// asks for every year card).
    public static func yearEndNetWorth(_ input: DashboardInput, actuals: NetWorthActuals?, year: Int, includeForecast: Bool = true) -> YearEndNetWorth? {
        yearEndNetWorth(input, year: year, includeForecast: includeForecast, actuals: { actuals }, monthEnd: { monthEndNetWorth(input, actuals: actuals, year: $0, month: $1) })
    }

    private static func yearEndNetWorth(_ input: DashboardInput, year: Int, includeForecast: Bool, actuals netWorthActuals: () -> NetWorthActuals?,
                                        monthEnd monthEndNetWorth: (_ year: Int, _ month: Int) -> Int?) -> YearEndNetWorth? {
        let thisYear = MonthRange.components(of: input.today).year
        if year < thisYear {
            return monthEndNetWorth(year, 12).map { YearEndNetWorth(valueMinorUnits: $0, isForecast: false) }
        }
        if !includeForecast {
            guard year == thisYear, let actuals = netWorthActuals() else { return nil }
            return YearEndNetWorth(valueMinorUnits: actuals.currentNetWorthMinorUnits, isForecast: false)
        }
        guard let actuals = netWorthActuals() else { return nil }
        let start = actuals.projectionStart(categories: input.categories, entries: input.netWorthEntries, groups: input.forecastGroups, exceptions: input.exceptions, filter: input.netWorthFilter)
        return actuals.forecastYearEnd(year, start: start, categories: input.categories, entries: input.netWorthEntries, groups: input.forecastGroups,
                                       exceptions: input.exceptions, filter: input.netWorthFilter)
            .map { YearEndNetWorth(valueMinorUnits: $0, isForecast: true) }
    }

    /// The Budget's Net Worth row for `year` (spec 2026-10-15 §1, §4; net-worth-forecast-fix §3),
    /// January first: the actual month-end net worth (balances carried forward) through the
    /// month of `effectiveToday`; with `includeForecast`, the walk-start month (the pay month
    /// holding the latest data) when it isn't over yet shows the current net worth plus its
    /// remaining plan, and later months the forecast walk; without it later months are nil
    /// ("—"). Nil also where there's no data yet. Covers `input.accountFilter`'s accounts when set.
    public static func budgetNetWorthMonths(_ input: DashboardInput, year: Int, includeForecast: Bool) -> [Int?] {
        budgetNetWorthMonths(input, year: year, includeForecast: includeForecast, actuals: { netWorthActuals(input) }, monthEnd: { monthEndNetWorth(input, year: $0, month: $1) })
    }

    /// `budgetNetWorthMonths` with `actuals` already worked out (`netWorthActuals(input)`, same
    /// input): the same result, its actual months reused rather than recomputed.
    public static func budgetNetWorthMonths(_ input: DashboardInput, actuals: NetWorthActuals?, year: Int, includeForecast: Bool) -> [Int?] {
        budgetNetWorthMonths(input, year: year, includeForecast: includeForecast, actuals: { actuals }, monthEnd: { monthEndNetWorth(input, actuals: actuals, year: $0, month: $1) })
    }

    private static func budgetNetWorthMonths(_ input: DashboardInput, year: Int, includeForecast: Bool, actuals netWorthActuals: () -> NetWorthActuals?,
                                             monthEnd monthEndNetWorth: (_ year: Int, _ month: Int) -> Int?) -> [Int?] {
        let today = MonthRange.components(of: input.effectiveToday)
        let todayIndex = MonthRange.index(year: today.year, month: today.month)
        var forecast: [Int: Int] = [:]
        var walkStart: (index: Int, value: Int)?
        if includeForecast, MonthRange.index(year: year, month: 12) >= todayIndex, let actuals = netWorthActuals() {
            let start = actuals.projectionStart(categories: input.categories, entries: input.netWorthEntries, groups: input.forecastGroups, exceptions: input.exceptions, filter: input.netWorthFilter)
            for point in netWorthForecast(actuals, start: start, throughYear: year, categories: input.categories, entries: input.netWorthEntries, groups: input.forecastGroups,
                                          exceptions: input.exceptions, filter: input.netWorthFilter) {
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
            return index <= todayIndex ? monthEndNetWorth(year, month) : forecast[index]
        }
    }

    /// The Budget's account rows' forecast months for `year` (account-forecast spec §2): the
    /// months `budgetNetWorthMonths` forecasts (the walk-start month when it isn't over yet, and
    /// every later month; with `includeForecast` off none, the later months `blankMonths`), per account and for the items with no
    /// account. Each account starts from today's balance plus its share of the walk-start month's
    /// remaining plan (`ForecastProjector.remainingPlannedByAccount`) and adds its planned legs
    /// month by month (`ForecastCalculator.netWorthImpactByAccount`); the unassigned row starts
    /// from zero. Every account has a value in every forecast month, so the accounts plus the
    /// unassigned row sum to the Net Worth row. `input` and `actuals` must cover All accounts
    /// (no `accountFilter`).
    public static func budgetAccountForecast(_ input: DashboardInput, actuals: NetWorthActuals?, itemAccounts: PlannedItemAccounts, year: Int, includeForecast: Bool) -> BudgetAccountForecast {
        let today = MonthRange.components(of: input.effectiveToday)
        let todayIndex = MonthRange.index(year: today.year, month: today.month)
        let decemberIndex = MonthRange.index(year: year, month: 12)
        guard includeForecast else {
            return BudgetAccountForecast(accounts: [:], unassigned: [:], blankMonths: Set((1...12).filter { MonthRange.index(year: year, month: $0) > todayIndex }))
        }
        guard decemberIndex >= todayIndex, let actuals, let startYear = actuals.walkStartYear, let startMonth = actuals.walkStartMonth else { return .empty }
        let startIndex = MonthRange.index(year: startYear, month: startMonth)

        let balances = NetWorthCalculator.accountBalances(accounts: input.accounts, snapshots: input.snapshots, transactions: input.transactions, rate: input.rate)
        var running: [Int64?: Int] = [:]
        for balance in balances { if let id = balance.account.id { running[id] = balance.gbpBalanceMinorUnits } }
        if !actuals.walkStartIsClosed {
            let remaining = ForecastProjector.remainingPlannedByAccount(year: startYear, month: startMonth, actuals: actuals.walkStartActuals, actualsByAccount: actuals.walkStartActualsByAccount,
                                                                         categories: input.categories, entries: input.forecastEntries, groups: input.forecastGroups,
                                                                         exceptions: input.exceptions, itemAccounts: itemAccounts)
            for (account, amount) in remaining { running[account, default: 0] += amount }
        }

        var accounts: [Int: [Int64: AccountForecastBalance]] = [:]
        var unassigned: [Int: Int] = [:]
        func record(_ index: Int) {
            let parts = (year: index / 12, month: index % 12 + 1)
            guard parts.year == year else { return }
            for balance in balances {
                guard let id = balance.account.id else { continue }
                let gbp = running[id] ?? 0
                accounts[parts.month, default: [:]][id] = AccountForecastBalance(gbpMinorUnits: gbp, nativeMinorUnits: native(gbp, balance: balance, rate: input.rate))
            }
            unassigned[parts.month] = running[nil] ?? 0
        }
        if startIndex >= todayIndex { record(startIndex) }
        var index = startIndex + 1
        while index <= decemberIndex {
            let range = MonthRange.of(year: index / 12, month: index % 12 + 1)
            let impact = ForecastCalculator.netWorthImpactByAccount(period: PayPeriod(startDate: range.start, endDate: range.end, type: .projected), categories: input.categories,
                                                                    entries: input.forecastEntries, groups: input.forecastGroups, exceptions: input.exceptions, itemAccounts: itemAccounts)
            for (account, amount) in impact { running[account, default: 0] += amount }
            if index > todayIndex { record(index) }
            index += 1
        }
        return BudgetAccountForecast(accounts: accounts, unassigned: unassigned)
    }

    /// A forecast GBP balance in the account's own currency: today's native balance plus the
    /// planned change converted at the stored rate.
    private static func native(_ gbp: Int, balance: AccountBalance, rate: ExchangeRateSetting) -> Int {
        switch balance.account.currency {
        case .gbp: return gbp
        case .eur:
            guard rate.eurToGbpRate > 0 else { return balance.nativeBalanceMinorUnits }
            return balance.nativeBalanceMinorUnits + Int((Double(gbp - balance.gbpBalanceMinorUnits) / rate.eurToGbpRate).rounded())
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
        let firstIndex = MonthRange.index(year: cursor.year, month: cursor.month)
        let actualMonths = firstIndex <= lastActualIndex ? firstIndex...lastActualIndex : nil
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
            return NetWorthActuals(actual: actual, currentNetWorthMinorUnits: current, forecastAnchors: [], walkStartYear: nil, walkStartMonth: nil, walkStartActuals: [:],
                                   walkStartActualsByAccount: [:], walkStartIsClosed: false,
                                   actualMonths: actualMonths)
        }
        let payMonth = input.payCalendar.month(containing: dataThrough)
        var anchors = [NetWorthPoint(year: payMonth.year, month: payMonth.month, valueMinorUnits: current)]
        if MonthRange.index(year: dataMonth.year, month: dataMonth.month) < MonthRange.index(year: payMonth.year, month: payMonth.month) {
            anchors.insert(NetWorthPoint(year: dataMonth.year, month: dataMonth.month, valueMinorUnits: current), at: 0)
        }
        // The walk-start month's actuals for the remaining plan: budget-facing transactions of
        // every status (current net worth already holds unreviewed ones, so they count as paid).
        let range = input.payCalendar.range(of: payMonth)
        let facing = input.netWorthFilter.map { input.conversion.toGBP(TransferLinks.budgetFacing(input.transactions, links: input.transferLinks, accountIds: $0.accountIds)) } ?? input.budgetTransactions
        var walkStartActuals: [Int64: Int] = [:]
        var walkStartActualsByAccount: [Int64: [Int64: Int]] = [:]
        for transaction in facing {
            guard let categoryId = transaction.categoryId, transaction.date >= range.start, transaction.date <= range.end else { continue }
            walkStartActuals[categoryId, default: 0] += transaction.amountMinorUnits
            walkStartActualsByAccount[transaction.accountId, default: [:]][categoryId, default: 0] += transaction.amountMinorUnits
        }
        return NetWorthActuals(actual: actual, currentNetWorthMinorUnits: current, forecastAnchors: anchors, walkStartYear: payMonth.year, walkStartMonth: payMonth.month,
                               walkStartActuals: walkStartActuals, walkStartActualsByAccount: walkStartActualsByAccount, walkStartIsClosed: input.payCalendar.isClosed(payMonth), actualMonths: actualMonths)
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

    /// `monthEndNetWorth`, read from `actuals` where it already holds the month.
    private static func monthEndNetWorth(_ input: DashboardInput, actuals: NetWorthActuals?, year: Int, month: Int) -> Int? {
        if let known = actuals?.monthEnd(atIndex: MonthRange.index(year: year, month: month)) { return known }
        return monthEndNetWorth(input, year: year, month: month)
    }

    private static func monthEndNetWorth(_ input: DashboardInput, year: Int, month: Int) -> Int? {
        NetWorthCalculator.monthEndNetWorth(accounts: input.netWorthAccounts, snapshots: input.snapshots, transactions: input.transactions, rate: input.rate, year: year, month: month)
    }
}
