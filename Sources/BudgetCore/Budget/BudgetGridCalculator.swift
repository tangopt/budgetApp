// Sources/BudgetCore/Budget/BudgetGridCalculator.swift
import Foundation

public struct PeriodSummary {
    public let period: PayPeriod
    public let incomeMinorUnits: Int
    public let expensesMinorUnits: Int
    public let transfersMinorUnits: Int

    public var moneyRemainingMinorUnits: Int {
        incomeMinorUnits - expensesMinorUnits - transfersMinorUnits
    }
}

public enum BudgetGridCalculator {
    public static func categoryTotal(category: Category, period: PayPeriod, transactions: [Transaction], forecastEntries: [ForecastEntry], forecastGroups: [ForecastGroup]) -> Int {
        switch period.type {
        case .actual:
            return transactions
                .filter { $0.categoryId == category.id && $0.status == .confirmed && $0.date >= period.startDate && $0.date <= period.endDate }
                .reduce(0) { $0 + $1.amountMinorUnits }
        case .projected:
            return ForecastCalculator.confirmedTotal(categoryId: category.id!, period: period, entries: forecastEntries, groups: forecastGroups)
        }
    }

    public static func periodSummary(period: PayPeriod, categories: [Category], transactions: [Transaction], forecastEntries: [ForecastEntry], forecastGroups: [ForecastGroup]) -> PeriodSummary {
        var income = 0, expenses = 0, transfers = 0
        for category in categories {
            let total = categoryTotal(category: category, period: period, transactions: transactions, forecastEntries: forecastEntries, forecastGroups: forecastGroups)
            switch category.type {
            case .income: income += total
            case .expense: expenses += abs(total)
            case .transfer: transfers += abs(total)
            }
        }
        return PeriodSummary(period: period, incomeMinorUnits: income, expensesMinorUnits: expenses, transfersMinorUnits: transfers)
    }
}
