import Foundation
import GRDB

/// One pay month as the iPhone's Month screen shows it (iPhone spec §3.3): the summary grid
/// and a row per category with money in it. Actuals are the Budget grid's
/// (`BudgetGridCalculator.categoryTotal` over the pay month), plans the calendar month's
/// confirmed plan (as the grid's), and the summary the Mac dashboard's year chart for the
/// month (`DashboardCalculator.monthlyFlow`). Rows and summary share `input.payCalendar`.
public struct PayMonthReview: Equatable, Sendable {
    /// A pay month's first day ... last moment of its close day.
    public struct DayRange: Equatable, Sendable {
        public let start: Date
        public let end: Date
    }

    public struct Row: Equatable, Identifiable, Sendable {
        /// The category's id.
        public let id: Int64
        public let category: Category
        /// Signed (negative = money out), like the Budget grid.
        public let actualMinorUnits: Int
        /// Signed: the calendar month's confirmed plan.
        public let planMinorUnits: Int
        /// An outflow beyond its plan, or spending with no plan that no reserve covers.
        public let isOverPlan: Bool

        /// What the plan still allows (positive) or how far past it (negative), in the plan's
        /// direction: expenses outward, income inward, transfers by the plan's sign. "£x left"
        /// / "£x over plan". Nil for income or a transfer with no plan (nothing to measure
        /// against); an unplanned expense is all over plan.
        public var remainingMinorUnits: Int? {
            switch category.type {
            case .expense: return actualMinorUnits - planMinorUnits
            case .income: return planMinorUnits == 0 ? nil : planMinorUnits - actualMinorUnits
            case .transfer: return planMinorUnits == 0 ? nil : planMinorUnits.signum() * (planMinorUnits - actualMinorUnits)
            case .adjustment: return nil
            }
        }
    }

    public let month: PayMonth
    /// The pay month's range (`PayCalendar.range`).
    public let range: DayRange
    /// Projected income (actual for a closed month), positive.
    public let incomeMinorUnits: Int
    /// Spending so far, positive.
    public let spentMinorUnits: Int
    /// Planned spending not yet spent (the hatched part), positive; 0 for a closed month.
    public let stillExpectedMinorUnits: Int
    /// Income less spent less still expected: what the month leaves (signed).
    public let leftToSpendMinorUnits: Int
    /// Expense rows, then income, then transfers; by name within each.
    public let rows: [Row]

    public func rows(of type: CategoryType) -> [Row] { rows.filter { $0.category.type == type } }

    public static func make(month: PayMonth, input: DashboardInput) -> PayMonthReview {
        let bounds = input.payCalendar.range(of: month)
        let period = PayPeriod(startDate: bounds.start, endDate: bounds.end, type: .actual)
        let calendarMonth = MonthRange.of(year: month.year, month: month.month)
        let planPeriod = PayPeriod(startDate: calendarMonth.start, endDate: calendarMonth.end, type: .projected)
        let planned = ForecastCalculator.confirmedTotalsByCategory(period: planPeriod, entries: input.forecastEntries,
                                                                   groups: input.forecastGroups, exceptions: input.exceptions)
        // Only the month's transactions reach the grid's per-category sum.
        let transactions = input.budgetTransactions.filter { $0.date >= bounds.start && $0.date <= bounds.end }

        var rows: [Row] = []
        for category in input.categories where category.type != .adjustment {
            guard let id = category.id else { continue }
            let actual = BudgetGridCalculator.categoryTotal(category: category, period: period, transactions: transactions,
                                                            forecastEntries: [], forecastGroups: [], exceptions: [])
            let plan = planned[id] ?? 0
            guard actual != 0 || plan != 0 else { continue }
            rows.append(Row(id: id, category: category, actualMinorUnits: actual, planMinorUnits: plan,
                            isOverPlan: isOverPlan(category, actual: actual, plan: plan)))
        }
        func rank(_ type: CategoryType) -> Int {
            switch type {
            case .expense: return 0
            case .income: return 1
            case .transfer: return 2
            case .adjustment: return 3
            }
        }
        rows.sort { (rank($0.category.type), $0.category.name, $0.id) < (rank($1.category.type), $1.category.name, $1.id) }

        let flow = DashboardCalculator.monthlyFlow(input, month: month)
        return PayMonthReview(month: month, range: DayRange(start: bounds.start, end: bounds.end), incomeMinorUnits: flow.incomeTotal,
                              spentMinorUnits: flow.expenseActual, stillExpectedMinorUnits: flow.expenseRemaining,
                              leftToSpendMinorUnits: flow.net, rows: rows)
    }

    /// An outflow (expense, or a transfer not planned inward) past its plan; with no plan, any
    /// expense spending unless a reserve covers the category (`excludeFromAutoForecast`, as the
    /// dashboard's `CategorySpend.isUnplanned`). Income and unplanned transfers are never over.
    static func isOverPlan(_ category: Category, actual: Int, plan: Int) -> Bool {
        switch category.type {
        case .income, .adjustment:
            return false
        case .expense, .transfer:
            if plan > 0 { return false } // planned inward (a transfer back, a refund)
            let spent = -actual, allowed = -plan
            guard spent > 0 else { return false }
            if allowed == 0 { return category.type == .expense && !category.excludeFromAutoForecast && !category.isReserved }
            return spent > allowed
        }
    }

    // MARK: A row's transactions

    /// One transaction behind a row's actual, as the row counts it: the amount in pounds (euro amounts at the
    /// stored rate, as `DashboardInput.budgetTransactions`), with the account's own amount when it isn't pounds.
    public struct RowTransaction: Equatable, Identifiable, Sendable {
        /// The transaction with `amountMinorUnits` in GBP.
        public let transaction: Transaction
        public let accountName: String
        /// The account's currency and the amount in it (equal to the GBP amount for a pounds account).
        public let originalCurrency: Currency
        public let originalMinorUnits: Int

        public var id: Int64 { transaction.id ?? -1 }
        public var date: Date { transaction.date }
        public var description: String { transaction.rawDescription }
        public var gbpMinorUnits: Int { transaction.amountMinorUnits }
        public var isConverted: Bool { originalCurrency != .gbp }
    }

    /// Exactly the transactions a row's actual sums (`BudgetGridCalculator.categoryTotal` over
    /// `budgetTransactions`): the category's confirmed, budget-facing transactions (no incoming leg of an
    /// active transfer link) within `range`, in GBP; newest first. Filtered in SQL, so a tap reads one
    /// category's month, not the ledger.
    public static func transactions(db: Database, categoryId: Int64, range: DayRange) throws -> [RowTransaction] {
        let found = try Transaction.budgetFacing
            .filter(Column("categoryId") == categoryId && Column("status") == TransactionStatus.confirmed.rawValue
                    && Column("date") >= range.start && Column("date") <= range.end)
            .order(Column("date").desc, Column("id").desc)
            .fetchAll(db)
        let accounts = try Account.fetchAll(db)
        let conversion = CurrencyConversion(accounts: accounts, rate: try ExchangeRateSetting.currentOrDefault(db: db))
        let names = Dictionary(accounts.compactMap { account in account.id.map { ($0, account.displayName) } },
                               uniquingKeysWith: { first, _ in first })
        return found.map { original in
            var counted = original
            counted.amountMinorUnits = conversion.gbp(original)
            return RowTransaction(transaction: counted, accountName: names[original.accountId] ?? "",
                                  originalCurrency: conversion.currency(ofAccount: original.accountId),
                                  originalMinorUnits: original.amountMinorUnits)
        }
    }
}
