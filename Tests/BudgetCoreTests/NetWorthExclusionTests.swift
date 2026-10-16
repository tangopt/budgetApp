import XCTest
import GRDB
@testable import BudgetCore
import struct BudgetCore.Category

/// Count toward net worth (`Account.includeInNetWorth`): an account left out — a mortgage on a
/// property the app doesn't track — keeps its balance, but no net-worth figure counts it, and
/// money moved to or from it enters or leaves net worth.
final class NetWorthExclusionTests: XCTestCase {
    private func utc(_ y: Int, _ m: Int, _ d: Int) -> Date {
        MonthRange.calendar.date(from: DateComponents(year: y, month: m, day: d))!
    }

    private let current: Int64 = 1, mortgage: Int64 = 2
    private let pay: Int64 = 1, interest: Int64 = 2, toMortgage: Int64 = 3, toCurrent: Int64 = 4

    private func accounts(mortgageIncluded: Bool = false) -> [Account] {
        [Account(id: current, name: "Current", currency: .gbp, kind: .cash, trackingMode: .imported),
         Account(id: mortgage, name: "Mortgage", currency: .gbp, kind: .credit, trackingMode: .imported, includeInNetWorth: mortgageIncluded)]
    }
    // "Pay", not "Salary": no paydays, so pay months are calendar months.
    private var categories: [Category] {
        [Category(id: pay, name: "Pay", type: .income),
         Category(id: interest, name: "Mortgage interest", type: .expense),
         Category(id: toMortgage, name: "Transfer: Mortgage", type: .transfer, transferAccountId: mortgage),
         Category(id: toCurrent, name: "Transfer: Current", type: .transfer, transferAccountId: current)]
    }
    private let groups = [ForecastGroup(id: 1, name: "Planned", note: nil, isEnabled: true, isSystemManaged: false)]
    /// −£1,000 to the mortgage from Current on the 1st of every month.
    private var entries: [ForecastEntry] {
        [ForecastEntry(id: 1, groupId: 1, categoryId: toMortgage, amountMinorUnits: -100_000, frequency: .monthly, interval: 1, startDate: utc(2026, 1, 1), endDate: nil,
                       isEnabled: true, status: .confirmed, note: nil, accountId: current)]
    }
    private func txn(_ id: Int64, _ date: Date, _ amount: Int, _ category: Int64, account: Int64) -> Transaction {
        Transaction(id: id, importBatchId: 1, accountId: account, date: date, rawDescription: "T\(id)", amountMinorUnits: amount, categoryId: category, status: .confirmed, categorizedBy: .manual, fingerprint: "fp\(id)")
    }
    /// 1 Oct: £1,000 from Current to the mortgage (linked), £300 interest charged on the mortgage.
    private var transactions: [Transaction] {
        [txn(1, utc(2026, 10, 1), -100_000, toMortgage, account: current),
         txn(2, utc(2026, 10, 1), 100_000, toCurrent, account: mortgage),
         txn(3, utc(2026, 10, 1), -30_000, interest, account: mortgage)]
    }
    private let links = [TransferLink(id: 1, outTransactionId: 1, inTransactionId: 2, origin: .manual)]
    /// Current £10,000 and the mortgage £200,000 owed on 1 Jan.
    private var snapshots: [BalanceSnapshot] {
        [BalanceSnapshot(accountId: current, date: utc(2026, 1, 1), balanceMinorUnits: 1_000_000, note: nil),
         BalanceSnapshot(accountId: mortgage, date: utc(2026, 1, 1), balanceMinorUnits: -20_000_000, note: nil)]
    }
    private let rate = ExchangeRateSetting(eurToGbpRate: 0.5, updatedAt: Date(timeIntervalSince1970: 0))

    private func input(mortgageIncluded: Bool = false) -> DashboardInput {
        DashboardInput(today: utc(2026, 10, 15), accounts: accounts(mortgageIncluded: mortgageIncluded), snapshots: snapshots, transactions: transactions, categories: categories,
                       categoryGroups: [], forecastEntries: entries, forecastGroups: groups, exceptions: [], importBatches: [], rate: rate, transferLinks: links)
    }

    // MARK: Storage

    func testNewAccountsCountTowardNetWorthAndTheSettingIsSaved() throws {
        let manager = try DatabaseManager(path: nil)
        try manager.migrate()
        try manager.dbQueue.write { db in
            let cash = try AccountEditing.add(db: db, name: "Cash", currency: .gbp, kind: .cash, openingBalanceEntered: nil, asOf: utc(2026, 1, 1))
            XCTAssertTrue(try Account.fetchOne(db, key: cash.id!)!.includeInNetWorth)
            let loan = try AccountEditing.add(db: db, name: "Loan", currency: .eur, kind: .credit, openingBalanceEntered: 100, asOf: utc(2026, 1, 1), includeInNetWorth: false)
            XCTAssertFalse(try Account.fetchOne(db, key: loan.id!)!.includeInNetWorth)
            try AccountEditing.update(db: db, accountId: loan.id!, name: "Loan", kind: .credit)
            XCTAssertFalse(try Account.fetchOne(db, key: loan.id!)!.includeInNetWorth, "nil keeps it")
            try AccountEditing.update(db: db, accountId: loan.id!, name: "Loan", kind: .credit, includeInNetWorth: true)
            XCTAssertTrue(try Account.fetchOne(db, key: loan.id!)!.includeInNetWorth)
            try AccountEditing.setIncludeInNetWorth(db: db, accountId: cash.id!, false)
            XCTAssertFalse(try Account.fetchOne(db, key: cash.id!)!.includeInNetWorth)
            XCTAssertThrowsError(try AccountEditing.setIncludeInNetWorth(db: db, accountId: 999, true))
        }
    }

    func testTheMigrationKeepsExistingAccountsCounted() throws {
        let manager = try DatabaseManager(path: nil)
        try manager.migrate(upTo: "addCategoryGroupType")
        try manager.dbQueue.write { db in
            try db.execute(sql: "INSERT INTO account (name, currency, kind, trackingMode) VALUES ('Old', 'gbp', 'cash', 'imported')")
        }
        try manager.migrate()
        let account = try manager.dbQueue.read { db in try Account.fetchOne(db) }
        XCTAssertEqual(account?.includeInNetWorth, true)
    }

    func testTheCategoryMarkIsNeverStored() throws {
        let manager = try DatabaseManager(path: nil)
        try manager.migrate()
        try manager.dbQueue.write { db in
            var category = Category(name: "Transfer: Loan", type: .transfer)
            category.isTiedToAccountOutsideNetWorth = true
            try category.insert(db)
            XCTAssertFalse(try Category.fetchOne(db, key: category.id!)!.isTiedToAccountOutsideNetWorth)
        }
    }

    func testMarkingFlagsOnlyTransfersTiedToExcludedAccounts() {
        let marked = categories.markingNetWorthExclusions(accounts: accounts())
        XCTAssertEqual(marked.filter(\.isTiedToAccountOutsideNetWorth).map(\.id), [toMortgage])
        XCTAssertTrue(categories.markingNetWorthExclusions(accounts: accounts(mortgageIncluded: true)).allSatisfy { !$0.isTiedToAccountOutsideNetWorth })
        let mortgageTransfer = marked.first { $0.id == toMortgage }!
        XCTAssertTrue(ForecastCalculator.countsInNetWorth(mortgageTransfer, accountIds: nil))
        XCTAssertTrue(ForecastCalculator.countsInNetWorth(mortgageTransfer, accountIds: [current, mortgage]))
        XCTAssertFalse(ForecastCalculator.countsInNetWorth(marked.first { $0.id == toCurrent }!, accountIds: nil))
        XCTAssertTrue(BudgetTotals.countsPlannedTransfer(mortgageTransfer, accountIds: nil))
    }

    // MARK: Balances

    func testNetWorthLeavesExcludedAccountsOut() {
        let balances = NetWorthCalculator.accountBalances(accounts: accounts(), snapshots: snapshots, transactions: transactions, rate: rate)
        XCTAssertEqual(balances.map(\.nativeBalanceMinorUnits), [900_000, -19_930_000], "the excluded account keeps its balance")
        XCTAssertEqual(NetWorthCalculator.netWorth(balances: balances), 900_000)
        XCTAssertEqual(NetWorthCalculator.monthEndNetWorth(accounts: accounts(), snapshots: snapshots, transactions: transactions, rate: rate, year: 2026, month: 10), 900_000)
        XCTAssertEqual(NetWorthCalculator.monthEndNetWorth(accounts: accounts(mortgageIncluded: true), snapshots: snapshots, transactions: transactions, rate: rate, year: 2026, month: 10), 900_000 - 19_930_000)
        // Only an excluded account with data: no net worth yet.
        XCTAssertNil(NetWorthCalculator.monthEndNetWorth(accounts: [accounts()[1]], snapshots: snapshots, transactions: transactions, rate: rate, year: 2026, month: 10))
    }

    func testTheRateImpactIgnoresExcludedAccounts() {
        let loan = Account(id: 3, name: "Loan", currency: .eur, kind: .credit, trackingMode: .imported, includeInNetWorth: false)
        let impact = ExchangeRateFetcher.netWorthImpact(accounts: accounts() + [loan], snapshots: snapshots + [BalanceSnapshot(accountId: 3, date: utc(2026, 1, 1), balanceMinorUnits: -1_000_000, note: nil)],
                                                        transactions: [], oldRate: rate, newRate: ExchangeRateSetting(eurToGbpRate: 0.9, updatedAt: Date(timeIntervalSince1970: 0)))
        XCTAssertEqual(impact, 0)
    }

    func testTheAccountsOverviewListsExcludedAccountsButLeavesThemOutOfTheTotals() {
        // The mortgage has nothing but an old opening balance: stale if it counted.
        let overview = AccountsOverview.make(accounts: accounts(), snapshots: snapshots, transactions: transactions.filter { $0.accountId == current }, rate: rate, today: utc(2026, 10, 15))
        XCTAssertEqual(overview.netWorthGBP, 900_000)
        let credit = overview.groups.first { $0.kind == .credit }
        XCTAssertEqual(credit?.rows.map(\.id), [mortgage])
        XCTAssertEqual(credit?.subtotalGBP, 0)
        XCTAssertEqual(credit?.rows.first?.isStale, false)
        XCTAssertEqual(overview.staleCount, 0)
        XCTAssertEqual(overview.changeVsPreviousMonthGBP, -100_000)
        let counted = AccountsOverview.make(accounts: accounts(mortgageIncluded: true), snapshots: snapshots, transactions: transactions.filter { $0.accountId == current }, rate: rate, today: utc(2026, 10, 15))
        XCTAssertEqual(counted.staleCount, 1)
    }

    func testTheDashboardIgnoresExcludedAccountsForStaleness() {
        let input = DashboardInput(today: utc(2026, 10, 15), accounts: accounts(), snapshots: snapshots, transactions: transactions.filter { $0.accountId == current },
                                   categories: categories, categoryGroups: [], forecastEntries: entries, forecastGroups: groups, exceptions: [], importBatches: [], rate: rate)
        XCTAssertEqual(DashboardCalculator.attentionItems(input).staleBalanceCount, 0)
        XCTAssertNil(DashboardCalculator.netWorthSeries(input).behindBalances)
    }

    // MARK: Net worth and its forecast

    func testThePaymentToAnExcludedAccountLeavesNetWorth() {
        let series = DashboardCalculator.netWorthSeries(input())
        XCTAssertEqual(series.currentNetWorthMinorUnits, 900_000)
        XCTAssertEqual(series.actual.last?.valueMinorUnits, 900_000)
        XCTAssertEqual(series.actual.first { $0.month == 9 }?.valueMinorUnits, 1_000_000)
        // October's payment is made; November and December's each take £1,000 out of net worth.
        XCTAssertEqual(series.yearEnds.first?.valueMinorUnits, 700_000)
        XCTAssertEqual(DashboardCalculator.budgetNetWorthMonths(input(), year: 2026, includeForecast: true)[10], 800_000)
        XCTAssertEqual(DashboardCalculator.yearEndNetWorth(input(), year: 2026)?.valueMinorUnits, 700_000)
        // Counted, the mortgage is a transfer between own accounts: net worth stays put.
        XCTAssertEqual(DashboardCalculator.netWorthSeries(input(mortgageIncluded: true)).yearEnds.first?.valueMinorUnits, 900_000 - 19_930_000)
    }

    func testAnAccountFilterLeavesExcludedAccountsOutOfNetWorth() {
        let marked = categories.markingNetWorthExclusions(accounts: accounts())
        let itemAccounts = PlannedItemAccounts(inferredByCategory: [:], categories: marked)
        for selection in [Set([current, mortgage]), Set([current])] {
            var filtered = input()
            filtered.accountFilter = PlanAccountFilter(accountIds: selection, itemAccounts: itemAccounts)
            XCTAssertEqual(DashboardCalculator.budgetNetWorthMonths(filtered, year: 2026, includeForecast: true)[9...11].map { $0 }, [900_000, 800_000, 700_000], "\(selection)")
        }
        var onlyMortgage = input()
        onlyMortgage.accountFilter = PlanAccountFilter(accountIds: [mortgage], itemAccounts: itemAccounts)
        XCTAssertNil(DashboardCalculator.netWorthActuals(onlyMortgage))
    }

    func testTheExcludedAccountsRowStillForecastsItsOwnBalance() {
        let input = input()
        let itemAccounts = PlannedItemAccounts(inferredByCategory: [:], categories: input.categories)
        let forecast = DashboardCalculator.budgetAccountForecast(input, actuals: DashboardCalculator.netWorthActuals(input), itemAccounts: itemAccounts, year: 2026, includeForecast: true)
        XCTAssertEqual(forecast.balance(accountId: current, month: 11)?.gbpMinorUnits, 800_000)
        XCTAssertEqual(forecast.balance(accountId: mortgage, month: 11)?.gbpMinorUnits, -19_830_000)
        XCTAssertEqual(forecast.balance(accountId: mortgage, month: 12)?.gbpMinorUnits, -19_730_000)
        XCTAssertEqual(forecast.unassigned[12], 0)
        // The counted rows and the unassigned row sum to the Net Worth row.
        let netWorth = DashboardCalculator.budgetNetWorthMonths(input, year: 2026, includeForecast: true)
        XCTAssertEqual(forecast.balance(accountId: current, month: 12)!.gbpMinorUnits + forecast.unassigned[12]!, netWorth[11])
    }

    func testTheWalkStartMonthsRemainingPaymentMovesTheExcludedAccountToo() {
        // Nothing paid yet in October: the remaining £1,000 leaves Current and reaches the mortgage.
        let unpaid = DashboardInput(today: utc(2026, 10, 15), accounts: accounts(), snapshots: snapshots, transactions: [txn(9, utc(2026, 10, 2), -5_000, interest, account: current)],
                                    categories: categories, categoryGroups: [], forecastEntries: entries, forecastGroups: groups, exceptions: [], importBatches: [], rate: rate)
        let itemAccounts = PlannedItemAccounts(inferredByCategory: [:], categories: unpaid.categories)
        let actuals = DashboardCalculator.netWorthActuals(unpaid)
        let forecast = DashboardCalculator.budgetAccountForecast(unpaid, actuals: actuals, itemAccounts: itemAccounts, year: 2026, includeForecast: true)
        XCTAssertEqual(forecast.balance(accountId: current, month: 10)?.gbpMinorUnits, 1_000_000 - 5_000 - 100_000)
        XCTAssertEqual(forecast.balance(accountId: mortgage, month: 10)?.gbpMinorUnits, -20_000_000 + 100_000)
        XCTAssertEqual(DashboardCalculator.budgetNetWorthMonths(unpaid, year: 2026, includeForecast: true)[9], 1_000_000 - 5_000 - 100_000)
    }

    func testTheNetWorthImpactByAccountMovesTheExcludedAccount() {
        let marked = categories.markingNetWorthExclusions(accounts: accounts())
        let range = MonthRange.of(year: 2026, month: 11)
        let period = PayPeriod(startDate: range.start, endDate: range.end, type: .projected)
        let itemAccounts = PlannedItemAccounts(inferredByCategory: [:], categories: marked)
        let byAccount = ForecastCalculator.netWorthImpactByAccount(period: period, categories: marked, entries: entries, groups: groups, exceptions: [], itemAccounts: itemAccounts)
        XCTAssertEqual(byAccount[current], -100_000)
        XCTAssertEqual(byAccount[mortgage], 100_000)
        XCTAssertEqual(ForecastCalculator.confirmedNetWorthImpact(period: period, categories: marked, entries: entries, groups: groups, exceptions: []), -100_000)
        XCTAssertEqual(ForecastCalculator.confirmedNetWorthImpact(period: period, categories: categories, entries: entries, groups: groups, exceptions: []), 0)
    }

    // MARK: Budget

    func testTheBudgetTotalsCountMoneyToAnExcludedAccount() {
        let marked = categories.markingNetWorthExclusions(accounts: accounts())
        let counterparts = BudgetTotals.counterpartAccounts(transactions: transactions, links: links)
        let facing = TransferLinks.budgetFacing(transactions, links: links)
        XCTAssertEqual(BudgetTotals.countedTransfers(facing, categories: marked, accountIds: nil, counterpartAccounts: counterparts).compactMap(\.id), [1])
        XCTAssertEqual(BudgetTotals.countedTransfers(facing, categories: marked, accountIds: [current, mortgage], counterpartAccounts: counterparts).compactMap(\.id), [1])
        XCTAssertEqual(BudgetTotals.countedTransfers(facing, categories: categories, accountIds: nil, counterpartAccounts: counterparts).compactMap(\.id), [])
    }

    func testTransactionsOnAnExcludedAccountCountInBudgetFlows() {
        let flows = DashboardCalculator.monthlyFlows(input(), year: 2026)
        XCTAssertEqual(flows[9].expenseActual, 30_000, "the interest on the mortgage is spending; the payment a transfer")
    }

    func testTheScenarioComparisonLeavesExcludedAccountsOut() {
        let data = ComparisonData(today: utc(2026, 10, 15), accounts: accounts(), snapshots: snapshots, transactions: transactions, transferLinks: links, categories: categories,
                                  rate: rate, payCalendar: input().payCalendar, horizonYear: 2026, horizonMonth: 12)
        let series = ScenarioComparison.netWorthSeries(data, plan: PlanInput(entries: entries, exceptions: [], groups: groups))
        XCTAssertEqual(series.forecast.last?.valueMinorUnits, 700_000)
        XCTAssertEqual(ScenarioComparison.gridActuals(data).countedTransferIds, [1])
    }
}
