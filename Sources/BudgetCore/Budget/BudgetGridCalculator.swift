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
    private static let calendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }()

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
            // Totals are signed (negative = money out). Expenses and transfers are
            // displayed as positive outflows, so subtract the signed total rather than
            // adding abs(total): money coming IN on an expense/transfer category (a
            // refund, a transfer back from savings) then correctly reduces the outflow
            // and increases Money Remaining instead of being counted as more spending.
            switch category.type {
            case .income: income += total
            case .expense: expenses -= total
            case .transfer: transfers -= total
            }
        }
        return PeriodSummary(period: period, incomeMinorUnits: income, expensesMinorUnits: expenses, transfersMinorUnits: transfers)
    }

    public static func categoryTotalForCalendarMonth(category: Category, year: Int, month: Int, transactions: [Transaction]) -> Int {
        transactions
            .filter { transaction in
                guard transaction.categoryId == category.id, transaction.status == .confirmed else { return false }
                let components = calendar.dateComponents([.year, .month], from: transaction.date)
                return components.year == year && components.month == month
            }
            .reduce(0) { $0 + $1.amountMinorUnits }
    }

    /// Net position for the whole calendar year (income − expenses − transfers), signed
    /// the same way `periodSummary`'s `moneyRemainingMinorUnits` is — the headline figure
    /// shown on each year picker chip.
    public static func yearlyTotal(year: Int, categories: [Category], transactions: [Transaction]) -> Int {
        var income = 0, expenses = 0, transfers = 0
        for category in categories {
            var monthlyTotal = 0
            for month in 1...12 {
                monthlyTotal += categoryTotalForCalendarMonth(category: category, year: year, month: month, transactions: transactions)
            }
            switch category.type {
            case .income: income += monthlyTotal
            case .expense: expenses -= monthlyTotal
            case .transfer: transfers -= monthlyTotal
            }
        }
        return income - expenses - transfers
    }

    /// nil when there's nothing to compare against (no prior year, or the prior year's
    /// total was exactly zero, which would make a percentage meaningless/infinite).
    public static func yearOverYearChange(currentYearTotal: Int, previousYearTotal: Int?) -> Double? {
        guard let previousYearTotal, previousYearTotal != 0 else { return nil }
        return Double(currentYearTotal - previousYearTotal) / Double(abs(previousYearTotal))
    }

    public static func yearsWithData(transactions: [Transaction]) -> [Int] {
        Set(transactions.map { calendar.component(.year, from: $0.date) }).sorted()
    }
}
