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
}
