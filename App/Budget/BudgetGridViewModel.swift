// App/Budget/BudgetGridViewModel.swift
import Foundation
import BudgetCore
import struct BudgetCore.Category
import GRDB

enum GridGroupingMode {
    case payPeriod
    case calendar
}

@MainActor
final class BudgetGridViewModel: ObservableObject {
    @Published var categories: [Category] = []
    @Published var periods: [PayPeriod] = []
    @Published var transactions: [Transaction] = []
    @Published var forecastEntries: [ForecastEntry] = []
    @Published var forecastGroups: [ForecastGroup] = []
    @Published var groupingMode: GridGroupingMode = .payPeriod
    @Published var selectedYear: Int?
    @Published var errorMessage: String?

    private let dbQueue: DatabaseQueue

    init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
    }

    func load(horizon: Date) throws {
        categories = try dbQueue.read { db in try Category.fetchAll(db) }
        transactions = try dbQueue.read { db in try Transaction.fetchAll(db) }
        forecastEntries = try dbQueue.read { db in try ForecastEntry.fetchAll(db) }
        forecastGroups = try dbQueue.read { db in try ForecastGroup.fetchAll(db) }
        // Paydays come from the salary category only (not Bonus/refunds) — see PaydaySource.
        let paydayDates = PaydaySource.paydayDates(transactions: transactions, categories: categories)
        periods = PayPeriodDetector.allPeriods(incomeDates: paydayDates, horizon: horizon)
        selectDefaultYearIfNeeded()
    }

    func categoryTotal(_ category: Category, in period: PayPeriod) -> Int {
        BudgetGridCalculator.categoryTotal(category: category, period: period, transactions: transactions, forecastEntries: forecastEntries, forecastGroups: forecastGroups)
    }

    func summary(for period: PayPeriod) -> PeriodSummary {
        BudgetGridCalculator.periodSummary(period: period, categories: categories, transactions: transactions, forecastEntries: forecastEntries, forecastGroups: forecastGroups)
    }

    var availableYears: [Int] {
        BudgetGridCalculator.yearsWithData(transactions: transactions)
    }

    func yearlyTotal(_ year: Int) -> Int {
        BudgetGridCalculator.yearlyTotal(year: year, categories: categories, transactions: transactions)
    }

    func yearOverYearChange(_ year: Int) -> Double? {
        let previousYear = year - 1
        let previousTotal = availableYears.contains(previousYear) ? yearlyTotal(previousYear) : nil
        return BudgetGridCalculator.yearOverYearChange(currentYearTotal: yearlyTotal(year), previousYearTotal: previousTotal)
    }

    func calendarCategoryTotal(_ category: Category, year: Int, month: Int) -> Int {
        BudgetGridCalculator.categoryTotalForCalendarMonth(category: category, year: year, month: month, transactions: transactions)
    }

    /// Falls back to the most recent year with data whenever the current selection is
    /// unset or no longer has data (e.g. right after `load()`).
    private func selectDefaultYearIfNeeded() {
        if selectedYear == nil || !availableYears.contains(selectedYear!) {
            selectedYear = availableYears.last
        }
    }

    private static let calendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }()

    func transactions(forCategoryId categoryId: Int64, from startDate: Date, to endDate: Date) -> [Transaction] {
        transactions.filter { $0.categoryId == categoryId && $0.status == .confirmed && $0.date >= startDate && $0.date <= endDate }
    }

    /// Every enabled, non-hypothetical (`.auto`/`.manual`/`.confirmed`) `ForecastEntry`, in
    /// an enabled group, whose frequency actually fires at least once within `period` —
    /// the same filter `ForecastCalculator.confirmedTotal` applies to build the projected
    /// cell's total (it excludes `.hypothetical` entries, which only count toward the
    /// Forecast screen's preview total), surfaced here for the read-only drill-down.
    func contributingForecastEntries(for category: Category, in period: PayPeriod) -> [ForecastEntry] {
        let enabledGroupIds = Set(forecastGroups.filter(\.isEnabled).compactMap(\.id))
        return forecastEntries
            .filter { $0.categoryId == category.id && $0.isEnabled && $0.status != .hypothetical && enabledGroupIds.contains($0.groupId) }
            .filter { !FrequencyExpander.occurrences(for: $0, in: period).isEmpty }
    }

    func dateRange(forYear year: Int, month: Int) -> (start: Date, end: Date) {
        var startComponents = DateComponents(); startComponents.year = year; startComponents.month = month; startComponents.day = 1
        let start = Self.calendar.date(from: startComponents)!
        let end = Self.calendar.date(byAdding: DateComponents(month: 1, day: -1), to: start)!
        return (start, end)
    }

    func dateRange(forYear year: Int) -> (start: Date, end: Date) {
        var startComponents = DateComponents(); startComponents.year = year; startComponents.month = 1; startComponents.day = 1
        let start = Self.calendar.date(from: startComponents)!
        let end = Self.calendar.date(byAdding: DateComponents(year: 1, day: -1), to: start)!
        return (start, end)
    }

    /// Re-categorizes a single already-confirmed transaction (from a drill-down sheet).
    ///
    /// The write happens against a locally-built copy first; `self.transactions` is only
    /// mutated once that write has actually succeeded, mirroring
    /// `UncategorizedViewModel.assignCategory`. Mutating the in-memory array before the
    /// write (as an earlier version of this method did) would leave the grid cell showing
    /// the new category even when the DB write failed, silently diverging from the
    /// persisted row until the next launch reverted it.
    @discardableResult
    func recategorize(_ transaction: Transaction, to categoryId: Int64) -> Bool {
        errorMessage = nil
        guard let index = transactions.firstIndex(where: { $0.id == transaction.id }) else { return false }
        var updated = transactions[index]
        updated.categoryId = categoryId
        do {
            try dbQueue.write { db in try updated.update(db) }
        } catch {
            errorMessage = "Couldn't recategorize this transaction: \(error.localizedDescription)"
            return false
        }
        transactions[index] = updated
        return true
    }
}
