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
    /// Each account's latest imported transaction date (`ImportCoverage`).
    let importedThrough: [Int64: Date]
    let netWorth: NetWorthSeries
    let yearChanges: [YearChange]
    let currentMonth: CurrentMonthTracking
    let topCategories: [CategorySpend]
    let attention: AttentionItems
    let bills: [UpcomingBill]
    let accounts: [AccountSummary]
    /// Selectable years for the year-at-a-glance chart: first data year ... next year.
    let yearRange: ClosedRange<Int>
    /// The stored EUR→GBP rate (the import card's note for a non-GBP account).
    let eurToGbpRate: Double
    /// Some account reaches the person signed in only as its summaries, or not at all: net worth says it
    /// "Includes everything you can see" (`SharingCopy.netWorthNote`).
    var showsNetWorthNote = false
    /// The review cards' read model (tax year, property month, evidence, mortgages, files waiting), as the person
    /// signed in may see it.
    var review = DashboardReview(tax: nil, property: nil, evidence: nil, mortgages: nil, importsWaiting: 0, attention: [])
}

@MainActor
final class DashboardViewModel: ObservableObject {
    @Published private(set) var content: DashboardContent?
    @Published private(set) var flows: [MonthlyFlow] = []
    @Published private(set) var selectedYear: Int
    /// Unreviewed transactions in the selected year (left out of its totals).
    @Published private(set) var unreviewed = UnreviewedSummary(count: 0, outflowMinorUnits: 0)
    @Published private(set) var errorMessage: String?
    /// Shown inline in the Close month sheet.
    @Published private(set) var closeErrorMessage: String?

    private let dbQueue: DatabaseQueue
    private let todayProvider: () -> Date
    private var input: DashboardInput?

    init(dbQueue: DatabaseQueue, today: @escaping () -> Date = { AppClock.now }) {
        self.dbQueue = dbQueue
        self.todayProvider = today
        self.selectedYear = MonthRange.components(of: today()).year
    }

    /// One batched read, then every display model computed once. Stale content stays in
    /// place if the read fails.
    func load() {
        do {
            let today = todayProvider()
            // As the person signed in sees it (`SharedActualsSource`): the other person's accounts below Everything as
            // their summaries, their Hidden ones not at all.
            let lastVisit = Self.lastVisit
            let (loaded, partial, review) = try dbQueue.read { db in
                let actuals = try SignedInActor.actuals(db: db, today: today)
                return (try DashboardInput.load(db: db, today: today, actuals: actuals), actuals.viewer.seesOnlyPart(of: try Account.fetchAll(db)),
                        try DashboardReview.load(db: db, today: today, lastVisit: lastVisit, viewer: try SignedInActor.actor(db: db)))
            }
            let netWorth = DashboardCalculator.netWorthSeries(loaded)
            let thisYear = MonthRange.components(of: today).year
            let firstYear = netWorth.actual.first?.year ?? thisYear
            let range = min(firstYear, thisYear)...(thisYear + 1)

            input = loaded
            content = DashboardContent(
                today: today,
                freshness: DashboardCalculator.dataFreshness(loaded),
                importedThrough: ImportCoverage.importedThroughByAccount(transactions: loaded.transactions, batches: loaded.importBatches, categories: loaded.categories),
                netWorth: netWorth,
                yearChanges: DashboardCalculator.yearOverYear(loaded, series: netWorth),
                currentMonth: DashboardCalculator.currentMonth(loaded),
                topCategories: DashboardCalculator.topCategories(loaded),
                attention: DashboardCalculator.attentionItems(loaded),
                bills: DashboardCalculator.upcomingBills(loaded),
                accounts: DashboardCalculator.accountSummaries(loaded),
                yearRange: range,
                eurToGbpRate: loaded.rate.eurToGbpRate,
                showsNetWorthNote: partial,
                review: review
            )
            if !range.contains(selectedYear) { selectedYear = thisYear }
            flows = DashboardCalculator.monthlyFlows(loaded, year: selectedYear)
            unreviewed = DashboardCalculator.unreviewed(loaded, year: selectedYear)
            errorMessage = nil
        } catch {
            errorMessage = "Couldn't load the dashboard: \(error.localizedDescription)"
        }
    }

    /// When the Dashboard was last seen on this device (`UserDefaults` `dashboardLastVisit`); nil before the first visit.
    static let lastVisitKey = "dashboardLastVisit"
    static var lastVisit: Date? {
        let seconds = UserDefaults.standard.double(forKey: lastVisitKey)
        return seconds > 0 ? Date(timeIntervalSince1970: seconds) : nil
    }

    /// The Dashboard disappeared: what changed since is measured from now.
    func markVisited() {
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.lastVisitKey)
    }

    /// Pay-month boundaries of the last successful load.
    var payCalendar: PayCalendar? { input?.payCalendar }

    /// Closes `month` on the picked day (00:00 UTC — see `PayCalendar.utcDay`), then reloads.
    /// On failure sets `closeErrorMessage` and returns false.
    @discardableResult
    func closeMonth(_ month: PayMonth, on date: Date) -> Bool {
        closeErrorMessage = nil
        do {
            try dbQueue.write(.budgetAndAccounts) { db in try PayCalendar.close(db: db, month: month, on: date, today: todayProvider()) }
        } catch PayCalendarError.invalidCloseDate {
            closeErrorMessage = payCalendar.map { PayMonthFormat.invalidCloseDateMessage(month, calendar: $0) } ?? "Pick a date inside \(PayMonthFormat.name(month))."
            return false
        } catch {
            closeErrorMessage = "Couldn't close \(PayMonthFormat.name(month)): \(error.localizedDescription)"
            return false
        }
        load()
        return true
    }

    func clearCloseError() { closeErrorMessage = nil }

    /// Recomputes only the year-at-a-glance months, from the already-loaded data.
    func selectYear(_ year: Int) {
        guard let input, content?.yearRange.contains(year) == true else { return }
        selectedYear = year
        flows = DashboardCalculator.monthlyFlows(input, year: year)
        unreviewed = DashboardCalculator.unreviewed(input, year: year)
    }
}
