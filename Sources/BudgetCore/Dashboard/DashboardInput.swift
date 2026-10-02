import Foundation

/// Everything the dashboard needs, loaded once. `today` is part of the input so tests never
/// depend on the clock.
public struct DashboardInput {
    public let today: Date
    public let accounts: [Account]
    public let snapshots: [BalanceSnapshot]
    public let transactions: [Transaction]
    public let categories: [Category]
    public let categoryGroups: [CategoryGroup]
    public let forecastEntries: [ForecastEntry]
    public let forecastGroups: [ForecastGroup]
    public let importBatches: [ImportBatch]
    public let rate: ExchangeRateSetting
    /// Latest transaction date across all accounts ("D"); nil when there are no transactions.
    public let dataThrough: Date?
    /// Confirmed calendar-month totals per category, built once.
    let calendarTotals: [Int64: [Int: [Int: Int]]]

    public init(today: Date, accounts: [Account], snapshots: [BalanceSnapshot], transactions: [Transaction], categories: [Category], categoryGroups: [CategoryGroup], forecastEntries: [ForecastEntry], forecastGroups: [ForecastGroup], importBatches: [ImportBatch], rate: ExchangeRateSetting) {
        self.today = today
        self.accounts = accounts
        self.snapshots = snapshots
        self.transactions = transactions
        self.categories = categories
        self.categoryGroups = categoryGroups
        self.forecastEntries = forecastEntries
        self.forecastGroups = forecastGroups
        self.importBatches = importBatches
        self.rate = rate
        self.dataThrough = transactions.map(\.date).max()
        self.calendarTotals = BudgetGridCalculator.calendarTotalsLookup(transactions: transactions)
    }

    /// `today`, but never earlier than the data (a clock behind the data counts as "today = D").
    var effectiveToday: Date { dataThrough.map { max(today, $0) } ?? today }
}

public struct DataFreshness: Equatable {
    public enum Status: Equatable {
        case noData
        case upToDate
        /// More than 31 days between the latest transaction and today. `months` is whole
        /// elapsed calendar months (0 when under a month — show `days` then).
        case behind(months: Int, days: Int)
    }
    public let status: Status
    public let lastImportAt: Date?
    public let lastImportFileName: String?
    public let dataThrough: Date?
}

public enum CatchAllIssue: Equatable {
    case notDesignated
    case noAllowance
}

public struct AttentionItems: Equatable {
    public let uncategorizedCount: Int
    public let staleBalanceCount: Int
    public let oldestStaleSnapshotDate: Date?
    public let catchAllIssue: CatchAllIssue?
}

public struct AccountSummary: Equatable, Identifiable {
    public let id: Int64
    public let name: String
    public let kind: AccountKind
    public let currency: Currency
    public let nativeBalanceMinorUnits: Int
    public let gbpBalanceMinorUnits: Int
}

public struct UpcomingBill: Equatable, Identifiable {
    public let date: Date
    public let categoryName: String
    /// Signed (negative = money out), per occurrence.
    public let amountMinorUnits: Int
    public var id: String { "\(categoryName)-\(date.timeIntervalSince1970)-\(amountMinorUnits)" }
}

public struct CatchAllAllowance: Equatable {
    public let name: String
    /// Positive magnitude of the confirmed monthly allowance (0 when none).
    public let monthlyMinorUnits: Int
}
