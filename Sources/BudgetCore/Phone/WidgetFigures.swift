import Foundation
import GRDB

/// This month's recharge pipeline for one tenancy, as the Property month widget shows it (step 18): bills in, statement
/// sent, paid by the tenant. Labelled by the tenancy's name, never the tenant's. Read from `ThisMonthChecklist` and the
/// month's statement; nothing here is stored.
public struct RechargePipelineFigures: Codable, Equatable, Sendable {
    /// One expected provider's bill this month: in (checked) or still out.
    public struct Utility: Codable, Equatable, Sendable {
        public var name: String
        public var kind: String
        public var isIn: Bool

        public init(name: String, kind: String, isIn: Bool) {
            self.name = name
            self.kind = kind
            self.isIn = isIn
        }
    }

    public enum Step: Int, Codable, CaseIterable, Sendable {
        case billsIn, statementSent, paidByTenant
    }

    public var tenancyName: String
    /// The first day of the month.
    public var month: Date
    public var billsIn: Int
    public var billsExpected: Int
    public var utilities: [Utility]
    public var statementSent: Bool
    public var paidByTenant: Bool
    /// What the tenant still owes on this month's statement (0 when paid or when nothing is recharged).
    public var outstandingMinorUnits: Int
    public var currencyCode: String

    public init(tenancyName: String, month: Date, utilities: [Utility], statementSent: Bool, paidByTenant: Bool,
                outstandingMinorUnits: Int, currencyCode: String) {
        self.tenancyName = tenancyName
        self.month = month
        self.utilities = utilities
        self.billsIn = utilities.filter(\.isIn).count
        self.billsExpected = utilities.count
        self.statementSent = statementSent
        self.paidByTenant = paidByTenant
        self.outstandingMinorUnits = max(0, outstandingMinorUnits)
        self.currencyCode = currencyCode
    }

    /// All expected bills are in (and at least one was expected).
    public var allBillsIn: Bool { billsExpected > 0 && billsIn == billsExpected }

    /// Whether the pipeline's `step` is complete: the bills are all in, the statement is sent, the tenant has paid.
    public func isDone(_ step: Step) -> Bool {
        switch step {
        case .billsIn: allBillsIn
        case .statementSent: statementSent
        case .paidByTenant: paidByTenant
        }
    }

    /// How many of the three steps are complete (0...3).
    public var stepsDone: Int { Step.allCases.filter(isDone).count }

    /// The pipeline for `statement` (this month's, nil when none yet) with `paidMinorUnits` linked to it.
    /// A statement is sent once it is no longer a draft; paid once it is marked paid or its credits cover its total.
    public static func make(tenancyName: String, month: Date, providers: [ThisMonthChecklist.ProviderBill], statement: RechargeStatement?,
                            paidMinorUnits: Int, currency: Currency) -> RechargePipelineFigures {
        let utilities = providers.map { Utility(name: $0.name, kind: $0.kind.rawValue, isIn: $0.state == .checked) }
        let total = statement?.totalMinorUnits ?? 0
        let sent = statement.map { $0.status != .draft } ?? false
        let paid = statement.map { $0.status == .paid || (total > 0 && paidMinorUnits >= total) } ?? false
        return RechargePipelineFigures(tenancyName: tenancyName, month: month, utilities: utilities, statementSent: sent, paidByTenant: paid,
                                    outstandingMinorUnits: paid ? 0 : total - paidMinorUnits, currencyCode: currency.rawValue.uppercased())
    }

    /// One row per tenancy running this month the viewer may see (`viewer` nil: everything), by property then tenancy.
    /// Reads only.
    public static func all(db: Database, today: Date, viewer: AccessActor?) throws -> [RechargePipelineFigures] {
        let calendar = MonthRange.calendar
        let (year, monthNumber) = MonthRange.components(of: PropertyDates.day(today))
        let start = MonthRange.of(year: year, month: monthNumber).start
        let end = calendar.date(byAdding: .month, value: 1, to: start)!
        var rows: [RechargePipelineFigures] = []
        for property in try Properties.all(db: db) {
            guard let propertyId = property.id else { continue }
            for tenancy in try Tenancies.all(db: db, propertyId: propertyId) {
                guard let tenancyId = tenancy.id, tenancy.startDate < end, tenancy.endDate.map({ $0 >= start }) ?? true else { continue }
                let checklist = try ThisMonthChecklist.build(db: db, tenancyId: tenancyId, today: today, trayCount: 0, viewer: viewer)
                guard !checklist.isHidden else { continue }
                let statement = try Recharges.statements(db: db, tenancyId: tenancyId).first { $0.month == start }
                let outstanding = try statement?.id.map { try Recharges.outstanding(db: db, statementId: $0) }
                let paidSoFar = statement.map { $0.totalMinorUnits - (outstanding ?? $0.totalMinorUnits) } ?? 0
                rows.append(make(tenancyName: checklist.tenancyName, month: start, providers: checklist.step(.billsIn)?.providers ?? [],
                                 statement: statement, paidMinorUnits: paidSoFar, currency: property.currency))
            }
        }
        return rows
    }
}

/// The pay month's spending against its budget, as the Month spend widget shows it (step 18): spent so far, what was
/// expected by today (the month's budget spread evenly over its days), the budget, the days' running total, and the
/// categories over their budgets. Magnitudes are positive; the figures are Home's (`CurrentMonthTracking`).
public struct MonthSpendFigures: Codable, Equatable, Sendable {
    public struct CategoryOver: Codable, Equatable, Sendable {
        public var name: String
        public var spentMinorUnits: Int
        public var budgetMinorUnits: Int

        public init(name: String, spentMinorUnits: Int, budgetMinorUnits: Int) {
            self.name = name
            self.spentMinorUnits = spentMinorUnits
            self.budgetMinorUnits = budgetMinorUnits
        }

        public var overByMinorUnits: Int { spentMinorUnits - budgetMinorUnits }
    }

    /// Categories shown over budget.
    public static let overBudgetLimit = 3

    /// The pay month's first day.
    public var start: Date
    public var spentMinorUnits: Int
    /// The month's planned spending (Home's `plannedSpendingMinorUnits`).
    public var budgetMinorUnits: Int
    /// Day of the pay month today is (1 on its first day) and its length in days.
    public var dayOfMonth: Int
    public var daysInMonth: Int
    /// Spent by the end of each day, day 1 to `dayOfMonth` (so it ends at `spentMinorUnits`).
    public var cumulativeSpent: [Int]
    public var overBudget: [CategoryOver]
    public var currencyCode: String

    public init(start: Date, spentMinorUnits: Int, budgetMinorUnits: Int, dayOfMonth: Int, daysInMonth: Int, cumulativeSpent: [Int],
                overBudget: [CategoryOver], currencyCode: String = "GBP") {
        self.start = start
        self.spentMinorUnits = spentMinorUnits
        self.budgetMinorUnits = budgetMinorUnits
        self.dayOfMonth = dayOfMonth
        self.daysInMonth = daysInMonth
        self.cumulativeSpent = cumulativeSpent
        self.overBudget = overBudget
        self.currencyCode = currencyCode
    }

    /// The budget spread evenly over the month's days, up to the end of `day` (rounded to the nearest minor unit).
    public static func expected(budget: Int, day: Int, daysInMonth: Int) -> Int {
        guard daysInMonth > 0, budget > 0 else { return 0 }
        let clamped = min(max(day, 0), daysInMonth)
        return (budget * clamped * 2 + daysInMonth) / (daysInMonth * 2)
    }

    /// What was expected to be spent by the end of today.
    public var expectedToDateMinorUnits: Int {
        Self.expected(budget: budgetMinorUnits, day: dayOfMonth, daysInMonth: daysInMonth)
    }

    /// Spent less expected to date: positive when ahead of the pace.
    public var overPaceMinorUnits: Int { spentMinorUnits - expectedToDateMinorUnits }

    /// Spent as a share of the budget (0 without a budget); may pass 1.
    public var spentFraction: Double {
        budgetMinorUnits > 0 ? Double(spentMinorUnits) / Double(budgetMinorUnits) : 0
    }

    /// The budget's pace as a share of the month, today included.
    public var elapsedFraction: Double {
        daysInMonth > 0 ? Double(min(dayOfMonth, daysInMonth)) / Double(daysInMonth) : 0
    }

    /// The running total of `dailySpend` (day 1 first; spending positive, refunds negative).
    public static func cumulative(_ dailySpend: [Int]) -> [Int] {
        var total = 0
        return dailySpend.map { total += $0; return total }
    }

    /// The categories over their budgets, most over first, at most `overBudgetLimit`: a category with a budget whose
    /// spending passed it (the Mac's "over" flag, `CategorySpend.isOver`).
    public static func overBudget(_ categories: [CategorySpend]) -> [CategoryOver] {
        categories.filter(\.isOver)
            .map { CategoryOver(name: $0.name, spentMinorUnits: $0.actual, budgetMinorUnits: $0.expected) }
            .sorted { ($1.overByMinorUnits, $0.name) < ($0.overByMinorUnits, $1.name) }
            .prefix(overBudgetLimit).map { $0 }
    }

    /// Home's figures for the current pay month of `input`: spent is the month's confirmed expense actual, the budget its
    /// planned spending; the daily running total comes from the same transactions.
    public static func make(_ input: DashboardInput, month: CurrentMonthTracking) -> MonthSpendFigures {
        let calendar = MonthRange.calendar
        let expenseIds = Set(input.categories.filter { $0.type == .expense }.compactMap(\.id))
        var daily = Array(repeating: 0, count: max(1, month.dayOfMonth))
        for transaction in input.budgetTransactions {
            guard transaction.status == .confirmed, let categoryId = transaction.categoryId, expenseIds.contains(categoryId),
                  transaction.date >= month.start, transaction.date <= month.end else { continue }
            let index = calendar.dateComponents([.day], from: month.start, to: calendar.startOfDay(for: transaction.date)).day ?? 0
            guard index >= 0, index < daily.count else { continue }
            daily[index] -= transaction.amountMinorUnits
        }
        let categories = DashboardCalculator.topCategories(input, limit: Int.max)
        return MonthSpendFigures(start: month.start, spentMinorUnits: month.expenses.actual, budgetMinorUnits: month.expenses.projected,
                                 dayOfMonth: month.dayOfMonth, daysInMonth: month.daysInMonth, cumulativeSpent: cumulative(daily),
                                 overBudget: overBudget(categories))
    }
}
