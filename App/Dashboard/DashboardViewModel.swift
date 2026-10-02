// App/Dashboard/DashboardViewModel.swift
import Foundation
import BudgetCore
import struct BudgetCore.Category
import GRDB

/// Everything the dashboard renders, computed once per load. Views are pure functions of
/// this — no calculation happens in a view body (the Forecast screen's per-scroll-frame
/// recompute is the cautionary precedent).
struct DashboardContent {
    let today: Date
    let freshness: DataFreshness
    let netWorth: NetWorthSeries
    let yearChanges: [YearChange]
    let currentMonth: CurrentMonthTracking
    let topCategories: [CategorySpend]
    let attention: AttentionItems
    let bills: [UpcomingBill]
    let accounts: [AccountSummary]
    let catchAll: CatchAllAllowance?
    /// Selectable years for the year-at-a-glance chart: first data year ... next year.
    let yearRange: ClosedRange<Int>
}

@MainActor
final class DashboardViewModel: ObservableObject {
    @Published private(set) var content: DashboardContent?
    @Published private(set) var flows: [MonthlyFlow] = []
    @Published private(set) var selectedYear: Int
    /// Unreviewed transactions in the selected year (left out of its totals).
    @Published private(set) var unreviewed = UnreviewedSummary(count: 0, outflowMinorUnits: 0)
    @Published private(set) var errorMessage: String?

    private let dbQueue: DatabaseQueue
    private let todayProvider: () -> Date
    private var input: DashboardInput?

    init(dbQueue: DatabaseQueue, today: @escaping () -> Date = { Date() }) {
        self.dbQueue = dbQueue
        self.todayProvider = today
        self.selectedYear = MonthRange.components(of: today()).year
    }

    /// One batched read, then every display model computed once. Stale content stays in
    /// place if the read fails.
    func load() {
        do {
            let today = todayProvider()
            let loaded = try dbQueue.read { db -> DashboardInput in
                DashboardInput(
                    today: today,
                    accounts: try Account.fetchAll(db),
                    snapshots: try BalanceSnapshot.fetchAll(db),
                    transactions: try Transaction.fetchAll(db),
                    categories: try Category.fetchAll(db),
                    categoryGroups: try CategoryGroup.fetchAll(db),
                    forecastEntries: try ForecastEntry.fetchAll(db),
                    forecastGroups: try ForecastGroup.fetchAll(db),
                    importBatches: try ImportBatch.fetchAll(db),
                    rate: try ExchangeRateSetting.currentOrDefault(db: db)
                )
            }
            let netWorth = DashboardCalculator.netWorthSeries(loaded)
            let thisYear = MonthRange.components(of: today).year
            let firstYear = netWorth.actual.first?.year ?? thisYear
            let range = min(firstYear, thisYear)...(thisYear + 1)

            input = loaded
            content = DashboardContent(
                today: today,
                freshness: DashboardCalculator.dataFreshness(loaded),
                netWorth: netWorth,
                yearChanges: DashboardCalculator.yearOverYear(loaded, series: netWorth),
                currentMonth: DashboardCalculator.currentMonth(loaded),
                topCategories: DashboardCalculator.topCategories(loaded),
                attention: DashboardCalculator.attentionItems(loaded),
                bills: DashboardCalculator.upcomingBills(loaded),
                accounts: DashboardCalculator.accountSummaries(loaded),
                catchAll: DashboardCalculator.catchAllAllowance(loaded),
                yearRange: range
            )
            if !range.contains(selectedYear) { selectedYear = thisYear }
            flows = DashboardCalculator.monthlyFlows(loaded, year: selectedYear)
            unreviewed = DashboardCalculator.unreviewed(loaded, year: selectedYear)
            errorMessage = nil
        } catch {
            errorMessage = "Couldn't load the dashboard: \(error.localizedDescription)"
        }
    }

    /// Recomputes only the year-at-a-glance months, from the already-loaded data.
    func selectYear(_ year: Int) {
        guard let input, content?.yearRange.contains(year) == true else { return }
        selectedYear = year
        flows = DashboardCalculator.monthlyFlows(input, year: year)
        unreviewed = DashboardCalculator.unreviewed(input, year: year)
    }
}
