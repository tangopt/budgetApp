import Foundation

public struct YearEndForecast: Equatable {
    public let year: Int
    public let valueMinorUnits: Int
    public let changeMinorUnits: Int
    public let percent: Double?
}

public struct BehindBalances: Equatable {
    /// Non-imported accounts whose latest snapshot is older than the data-through month.
    public let accountCount: Int
    public let oldestSnapshotDate: Date
}

public struct NetWorthSeries: Equatable {
    /// Month values from the first snapshot month through the data-through month.
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
        guard let firstSnapshot = input.snapshots.map(\.date).min(), let lastSnapshot = input.snapshots.map(\.date).max() else {
            return .empty
        }
        let balances = NetWorthCalculator.accountBalances(accounts: input.accounts, snapshots: input.snapshots, transactions: input.transactions, rate: input.rate)
        let current = NetWorthCalculator.netWorth(balances: balances)

        let dataMonth = input.dataThrough.map { MonthRange.components(of: $0) }
        let lastActualMonth = dataMonth ?? MonthRange.components(of: lastSnapshot)

        // Actual: one point per month, snapshots carried forward (the same formula as the Budget grid).
        var actual: [NetWorthPoint] = []
        var cursor = MonthRange.components(of: firstSnapshot)
        let lastActualIndex = MonthRange.index(year: lastActualMonth.year, month: lastActualMonth.month)
        while MonthRange.index(year: cursor.year, month: cursor.month) <= lastActualIndex {
            if let value = monthEndNetWorth(input, year: cursor.year, month: cursor.month) {
                actual.append(NetWorthPoint(year: cursor.year, month: cursor.month, valueMinorUnits: value))
            }
            cursor = (cursor.month == 12) ? (cursor.year + 1, 1) : (cursor.year, cursor.month + 1)
        }

        // Forecast: anchored at the current net worth in the pay month holding the latest
        // transaction, then the shared month walk from the month after it. The dashed line
        // also starts where the solid one ends (`dataMonth`): past payday the pay month is the
        // next calendar month, which would otherwise leave a one-month gap between them.
        let thisYear = MonthRange.components(of: input.today).year
        var forecast: [NetWorthPoint] = []
        var yearEnds: [YearEndForecast] = []
        if let dataMonth, let dataThrough = input.dataThrough {
            let payMonth = input.payCalendar.month(containing: dataThrough)
            let walkStart = (year: payMonth.year, month: payMonth.month)
            let projection = ForecastProjector.monthlyProjection(startingNetWorth: current, latestRealMonth: walkStart, throughYear: forecastThroughYear ?? thisYear + 1, categories: input.categories, entries: input.forecastEntries, groups: input.forecastGroups, exceptions: input.exceptions)
            forecast = [NetWorthPoint(year: walkStart.year, month: walkStart.month, valueMinorUnits: current)] + projection
            if MonthRange.index(year: dataMonth.year, month: dataMonth.month) < MonthRange.index(year: walkStart.year, month: walkStart.month) {
                forecast.insert(NetWorthPoint(year: dataMonth.year, month: dataMonth.month, valueMinorUnits: current), at: 0)
            }

            func forecastValue(atEndOf year: Int) -> Int {
                ForecastProjector.forecastNetWorth(startingNetWorth: current, latestRealMonth: walkStart, atEndOf: year, categories: input.categories, entries: input.forecastEntries, groups: input.forecastGroups, exceptions: input.exceptions)
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

        // "As of": the latest of the last snapshot and the latest transaction of imported accounts.
        let importedIds = Set(input.accounts.filter { $0.trackingMode == .imported }.compactMap(\.id))
        let importedLatest = input.transactions.filter { importedIds.contains($0.accountId) }.map(\.date).max()
        let asOf = [lastSnapshot, importedLatest].compactMap { $0 }.max()

        let changeVsPrevious: Int? = actual.count >= 2 ? actual[actual.count - 1].valueMinorUnits - actual[actual.count - 2].valueMinorUnits : nil

        // Behind: a non-imported account whose latest snapshot predates the data month.
        var behindDates: [Date] = []
        if let dataMonth {
            let dataIndex = MonthRange.index(year: dataMonth.year, month: dataMonth.month)
            for account in input.accounts where account.trackingMode != .imported {
                guard let latest = input.snapshots.filter({ $0.accountId == account.id }).map(\.date).max() else { continue }
                let parts = MonthRange.components(of: latest)
                if MonthRange.index(year: parts.year, month: parts.month) < dataIndex { behindDates.append(latest) }
            }
        }
        let behind = behindDates.min().map { BehindBalances(accountCount: behindDates.count, oldestSnapshotDate: $0) }

        return NetWorthSeries(actual: actual, forecast: forecast, currentNetWorthMinorUnits: current, asOf: asOf, changeVsPreviousMonthMinorUnits: changeVsPrevious, yearEnds: yearEnds, behindBalances: behind)
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
        NetWorthCalculator.monthEndNetWorth(accounts: input.accounts, snapshots: input.snapshots, transactions: input.transactions, rate: input.rate, year: year, month: month)
    }
}
