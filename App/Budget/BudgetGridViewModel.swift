// App/Budget/BudgetGridViewModel.swift
import Foundation
import BudgetCore
import struct BudgetCore.Category
import GRDB

@MainActor
final class BudgetGridViewModel: ObservableObject {
    @Published var categories: [Category] = []
    @Published var periods: [PayPeriod] = []
    @Published var transactions: [Transaction] = []
    @Published var forecastEntries: [ForecastEntry] = []
    @Published var forecastGroups: [ForecastGroup] = []

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
    }

    func categoryTotal(_ category: Category, in period: PayPeriod) -> Int {
        BudgetGridCalculator.categoryTotal(category: category, period: period, transactions: transactions, forecastEntries: forecastEntries, forecastGroups: forecastGroups)
    }

    func summary(for period: PayPeriod) -> PeriodSummary {
        BudgetGridCalculator.periodSummary(period: period, categories: categories, transactions: transactions, forecastEntries: forecastEntries, forecastGroups: forecastGroups)
    }
}
