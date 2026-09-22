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
        let incomeCategoryIds = categories.filter { $0.type == .income }.compactMap(\.id)
        let incomeDates = transactions
            .filter { $0.status == .confirmed && incomeCategoryIds.contains($0.categoryId ?? -1) }
            .map(\.date).sorted()
        var allPeriods = PayPeriodDetector.generateActualPeriods(incomeDates: incomeDates)
        if let cadence = PayPeriodDetector.detectCadence(incomeDates: incomeDates) {
            allPeriods += PayPeriodDetector.generateProjectedPeriods(cadence: cadence, horizon: horizon)
        }
        periods = allPeriods
    }

    func categoryTotal(_ category: Category, in period: PayPeriod) -> Int {
        BudgetGridCalculator.categoryTotal(category: category, period: period, transactions: transactions, forecastEntries: forecastEntries, forecastGroups: forecastGroups)
    }

    func summary(for period: PayPeriod) -> PeriodSummary {
        BudgetGridCalculator.periodSummary(period: period, categories: categories, transactions: transactions, forecastEntries: forecastEntries, forecastGroups: forecastGroups)
    }
}
