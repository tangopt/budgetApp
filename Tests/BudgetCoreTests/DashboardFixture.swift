import Foundation
@testable import BudgetCore

/// Builds `DashboardInput` values with a small fixed chart of accounts. Only returns
/// `DashboardInput` (never `[Category]`) because a bare `Category` annotation is ambiguous
/// in this test target.
enum DashboardFixture {
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()
    static func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d))!
    }

    static let salaryId: Int64 = 1, rentId: Int64 = 2, savingsId: Int64 = 3, groceriesId: Int64 = 4, diningId: Int64 = 5, bulkId: Int64 = 6

    private static func entry(_ id: Int64, _ category: Int64, _ amount: Int, start: Date, status: ForecastEntryStatus = .manual, enabled: Bool = true, end: Date? = nil) -> ForecastEntry {
        ForecastEntry(id: id, groupId: 1, categoryId: category, amountMinorUnits: amount, frequency: .monthly, interval: 1, startDate: start, endDate: end, isEnabled: enabled, status: status, note: nil)
    }

    /// +3,000 salary on the 25th, -1,000 rent on the 1st: +2,000/month.
    static var salaryAndRent: [ForecastEntry] {
        [entry(1, salaryId, 300_000, start: date(2026, 1, 25)), entry(2, rentId, -100_000, start: date(2026, 1, 1))]
    }
    /// `salaryAndRent` plus -400 dining on the 14th: +1,600/month.
    static var withDining: [ForecastEntry] {
        salaryAndRent + [entry(3, diningId, -40_000, start: date(2026, 1, 14))]
    }

    static func txn(_ id: Int64, _ day: Date, _ amount: Int, category: Int64?, status: TransactionStatus = .confirmed, account: Int64 = 1) -> Transaction {
        Transaction(id: id, importBatchId: 1, accountId: account, date: day, rawDescription: "T\(id)", amountMinorUnits: amount, categoryId: category, status: status, categorizedBy: .manual, fingerprint: "fp\(id)")
    }

    static func snapshot(_ account: Int64, _ day: Date, _ balance: Int) -> BalanceSnapshot {
        BalanceSnapshot(accountId: account, date: day, balanceMinorUnits: balance, note: nil)
    }

    static func input(
        today: Date,
        accounts: [Account]? = nil,
        snapshots: [BalanceSnapshot] = [],
        transactions: [Transaction] = [],
        importBatches: [ImportBatch] = [],
        entries: [ForecastEntry]? = nil,
        catchAllId: Int64? = nil
    ) -> DashboardInput {
        DashboardInput(
            today: today,
            accounts: accounts ?? [Account(id: 1, name: "Current", currency: .gbp, kind: .cash, trackingMode: .manual)],
            snapshots: snapshots,
            transactions: transactions,
            categories: [
                Category(id: salaryId, name: "Salary", type: .income, isCatchAll: false),
                Category(id: rentId, name: "Rent", type: .expense, isCatchAll: catchAllId == rentId),
                Category(id: savingsId, name: "Savings", type: .transfer, isCatchAll: false),
                Category(id: groceriesId, name: "Groceries", type: .expense, groupId: 1, isCatchAll: catchAllId == groceriesId),
                Category(id: diningId, name: "Dining", type: .expense, groupId: 1, isCatchAll: catchAllId == diningId),
                Category(id: bulkId, name: "Bulk other", type: .expense, isCatchAll: catchAllId == bulkId)
            ],
            categoryGroups: [CategoryGroup(id: 1, name: "Food")],
            forecastEntries: entries ?? withDining,
            forecastGroups: [ForecastGroup(id: 1, name: "Detected recurring", note: nil, isEnabled: true, isSystemManaged: true)],
            importBatches: importBatches,
            rate: ExchangeRateSetting(eurToGbpRate: 0.5, updatedAt: date(2026, 1, 1))
        )
    }
}
