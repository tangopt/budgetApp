import Foundation

/// One pay month as the iPhone's Month screen shows it (iPhone spec §3.3): the summary grid
/// and a row per category with money in it. Actuals are the Budget grid's
/// (`BudgetGridCalculator.categoryTotal` over the pay month), plans the calendar month's
/// confirmed plan (as the grid's), and the summary the Mac dashboard's year chart for the
/// month (`DashboardCalculator.monthlyFlows`).
public struct PayMonthReview: Equatable {
    public struct Row: Equatable, Identifiable {
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
        /// direction: expenses outward, income inward, transfers by the plan's sign (else
        /// outward). "£x left" / "£x over plan".
        public var remainingMinorUnits: Int { direction * (planMinorUnits - actualMinorUnits) }

        /// +1 for money in, −1 for money out.
        var direction: Int {
            switch category.type {
            case .income: return 1
            case .expense, .adjustment: return -1
            case .transfer: return planMinorUnits > 0 ? 1 : -1
            }
        }
    }

    public let month: PayMonth
    /// The pay month's first day ... last moment of its close day (`PayCalendar.range`).
    public let range: (start: Date, end: Date)
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

    public static func == (a: PayMonthReview, b: PayMonthReview) -> Bool {
        a.month == b.month && a.range.start == b.range.start && a.range.end == b.range.end
            && a.incomeMinorUnits == b.incomeMinorUnits && a.spentMinorUnits == b.spentMinorUnits
            && a.stillExpectedMinorUnits == b.stillExpectedMinorUnits && a.leftToSpendMinorUnits == b.leftToSpendMinorUnits
            && a.rows == b.rows
    }

    /// `calendar` is normally `input.payCalendar` (the summary figures always use that one).
    public static func make(month: PayMonth, input: DashboardInput, calendar: PayCalendar) -> PayMonthReview {
        let range = calendar.range(of: month)
        let period = PayPeriod(startDate: range.start, endDate: range.end, type: .actual)
        let calendarMonth = MonthRange.of(year: month.year, month: month.month)
        let planPeriod = PayPeriod(startDate: calendarMonth.start, endDate: calendarMonth.end, type: .projected)
        let planned = ForecastCalculator.confirmedTotalsByCategory(period: planPeriod, entries: input.forecastEntries,
                                                                   groups: input.forecastGroups, exceptions: input.exceptions)
        // Only the month's transactions reach the grid's per-category sum.
        let transactions = input.budgetTransactions.filter { $0.date >= range.start && $0.date <= range.end }

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

        let flow = DashboardCalculator.monthlyFlows(input, year: month.year)[month.month - 1]
        return PayMonthReview(month: month, range: range, incomeMinorUnits: flow.incomeTotal, spentMinorUnits: flow.expenseActual,
                              stillExpectedMinorUnits: flow.expenseRemaining, leftToSpendMinorUnits: flow.net, rows: rows)
    }

    /// An outflow (expense, or a transfer not planned inward) past its plan; with no plan, any
    /// outflow unless a reserve covers the category (`excludeFromAutoForecast`, as the
    /// dashboard's `CategorySpend.isUnplanned`). Income is never over plan.
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
}
