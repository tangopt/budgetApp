import Foundation

public enum DashboardCalculator {
    static var calendar: Calendar { MonthRange.calendar }

    // MARK: Data freshness

    public static func dataFreshness(_ input: DashboardInput) -> DataFreshness {
        let lastBatch = input.importBatches.max { $0.importedAt < $1.importedAt }
        guard let dataThrough = input.dataThrough else {
            return DataFreshness(status: .noData, lastImportAt: lastBatch?.importedAt, lastImportFileName: lastBatch?.sourceFileName, dataThrough: nil)
        }
        let today = calendar.startOfDay(for: input.today) // `Date()` carries a time of day
        let threshold = calendar.date(byAdding: .day, value: -31, to: today)!
        let status: DataFreshness.Status
        if dataThrough < threshold {
            let months = calendar.dateComponents([.month], from: dataThrough, to: today).month ?? 0
            let days = calendar.dateComponents([.day], from: dataThrough, to: today).day ?? 0
            status = .behind(months: months, days: days)
        } else {
            status = .upToDate
        }
        return DataFreshness(status: status, lastImportAt: lastBatch?.importedAt, lastImportFileName: lastBatch?.sourceFileName, dataThrough: dataThrough)
    }

    // MARK: Needs attention

    public static func attentionItems(_ input: DashboardInput) -> AttentionItems {
        let uncategorized = input.transactions.filter { $0.categoryId == nil || $0.status == .pendingReview }.count

        let today = calendar.startOfDay(for: input.today) // `Date()` carries a time of day
        let threshold = calendar.date(byAdding: .day, value: -45, to: today)!
        var staleCount = 0
        var oldest: Date?
        for account in input.accounts where account.trackingMode != .imported {
            let latest = input.snapshots.filter { $0.accountId == account.id }.map(\.date).max()
            if let latest {
                if latest < threshold {
                    staleCount += 1
                    oldest = oldest.map { min($0, latest) } ?? latest
                }
            } else {
                staleCount += 1 // never had a balance recorded
            }
        }

        let issue: CatchAllIssue?
        if let catchAll = input.categories.first(where: { $0.isCatchAll }) {
            let hasAllowance = ForecastCalculator.confirmedEntries(entries: input.forecastEntries, groups: input.forecastGroups).contains { $0.categoryId == catchAll.id }
            issue = hasAllowance ? nil : .noAllowance
        } else {
            issue = .notDesignated
        }
        return AttentionItems(uncategorizedCount: uncategorized, staleBalanceCount: staleCount, oldestStaleSnapshotDate: oldest, catchAllIssue: issue)
    }

    public static func catchAllAllowance(_ input: DashboardInput) -> CatchAllAllowance? {
        guard let category = input.categories.first(where: { $0.isCatchAll }), let id = category.id else { return nil }
        let parts = MonthRange.components(of: input.effectiveToday)
        let range = MonthRange.of(year: parts.year, month: parts.month)
        let period = PayPeriod(startDate: range.start, endDate: range.end, type: .projected)
        let monthly = -ForecastCalculator.confirmedTotal(categoryId: id, period: period, entries: input.forecastEntries, groups: input.forecastGroups)
        return CatchAllAllowance(name: category.name, monthlyMinorUnits: monthly)
    }

    // MARK: Accounts

    /// Every account, largest GBP balance first (a credit account owed money sorts last).
    public static func accountSummaries(_ input: DashboardInput) -> [AccountSummary] {
        NetWorthCalculator.accountBalances(accounts: input.accounts, snapshots: input.snapshots, transactions: input.transactions, rate: input.rate)
            .compactMap { balance -> AccountSummary? in
                guard let id = balance.account.id else { return nil }
                return AccountSummary(id: id, name: balance.account.name, kind: balance.account.kind, currency: balance.account.currency, nativeBalanceMinorUnits: balance.nativeBalanceMinorUnits, gbpBalanceMinorUnits: balance.gbpBalanceMinorUnits)
            }
            .sorted { $0.gbpBalanceMinorUnits > $1.gbpBalanceMinorUnits }
    }

    // MARK: Upcoming bills

    /// Confirmed expense entries expanded over [start of today, end of day today + `days`],
    /// sorted by date. The caller shows the first few and "+ N more".
    public static func upcomingBills(_ input: DashboardInput, days: Int = 30) -> [UpcomingBill] {
        let startOfToday = calendar.startOfDay(for: input.today)
        let end = calendar.date(byAdding: .day, value: days + 1, to: startOfToday)!.addingTimeInterval(-1)
        let period = PayPeriod(startDate: startOfToday, endDate: end, type: .projected)
        let expenseCategories = Dictionary(uniqueKeysWithValues: input.categories.compactMap { category -> (Int64, String)? in
            guard category.type == .expense, let id = category.id else { return nil }
            return (id, category.name)
        })
        var bills: [UpcomingBill] = []
        for entry in ForecastCalculator.confirmedEntries(entries: input.forecastEntries, groups: input.forecastGroups) {
            guard let name = expenseCategories[entry.categoryId] else { continue }
            for occurrence in FrequencyExpander.occurrences(for: entry, in: period) {
                bills.append(UpcomingBill(date: occurrence, categoryName: name, amountMinorUnits: entry.amountMinorUnits))
            }
        }
        return bills.sorted { $0.date != $1.date ? $0.date < $1.date : $0.categoryName < $1.categoryName }
    }
}
