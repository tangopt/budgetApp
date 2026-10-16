import XCTest
@testable import BudgetCore
import struct BudgetCore.Category
import struct BudgetCore.Transaction
import GRDB

/// Budgets convert non-GBP accounts at the stored rate (`CurrencyConversion`): a €100 expense
/// at 0.85 counts as £85 in every budget figure, while balances and net worth keep converting
/// the native balance once.
final class CurrencyConversionTests: XCTestCase {
    private func utc(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        return cal.date(from: DateComponents(year: y, month: m, day: d))!
    }

    private let gbpId: Int64 = 1, eurId: Int64 = 2
    private let salaryId: Int64 = 1, groceriesId: Int64 = 2, savingsId: Int64 = 3
    private let rate = ExchangeRateSetting(eurToGbpRate: 0.85, updatedAt: Date(timeIntervalSince1970: 0))

    private var accounts: [Account] {
        [Account(id: gbpId, name: "Current", currency: .gbp, kind: .cash, trackingMode: .manual),
         Account(id: eurId, name: "Euro", currency: .eur, kind: .cash, trackingMode: .manual)]
    }

    private var categories: [Category] {
        [Category(id: salaryId, name: "Salary", type: .income),
         Category(id: groceriesId, name: "Groceries", type: .expense, groupId: 1),
         Category(id: savingsId, name: "Savings", type: .transfer)]
    }

    /// January and February closed; today is 15 March.
    private var calendar: PayCalendar {
        PayCalendar(salaryDates: [], manualCloses: [PayMonthClose(year: 2026, month: 1, closeDate: utc(2026, 1, 31)),
                                                  PayMonthClose(year: 2026, month: 2, closeDate: utc(2026, 2, 28))],
                    today: utc(2026, 3, 15))
    }

    private func txn(_ id: Int64, _ date: Date, _ amount: Int, _ category: Int64?, account: Int64) -> Transaction {
        Transaction(id: id, importBatchId: 1, accountId: account, date: date, rawDescription: "T\(id)", amountMinorUnits: amount,
                    categoryId: category, status: .confirmed, categorizedBy: .manual, fingerprint: "fp\(id)")
    }

    /// €100 of groceries from the EUR account and £50 from the GBP one, in February.
    private var transactions: [Transaction] {
        [txn(1, utc(2026, 2, 10), -10_000, groceriesId, account: eurId),
         txn(2, utc(2026, 2, 12), -5_000, groceriesId, account: gbpId)]
    }

    /// £1,000 and €1,000 on 1 January.
    private var snapshots: [BalanceSnapshot] {
        [BalanceSnapshot(accountId: gbpId, date: utc(2026, 1, 1), balanceMinorUnits: 100_000, note: nil),
         BalanceSnapshot(accountId: eurId, date: utc(2026, 1, 1), balanceMinorUnits: 100_000, note: nil)]
    }

    private func dashboard(_ transactions: [Transaction], accounts: [Account]? = nil, links: [TransferLink] = []) -> DashboardInput {
        DashboardInput(today: utc(2026, 3, 15), accounts: accounts ?? self.accounts, snapshots: snapshots, transactions: transactions, categories: categories,
                       categoryGroups: [CategoryGroup(id: 1, name: "Food")], forecastEntries: [], forecastGroups: [], exceptions: [], importBatches: [],
                       rate: rate, payCalendar: calendar, transferLinks: links)
    }

    private func comparison(_ transactions: [Transaction], links: [TransferLink] = []) -> ComparisonData {
        ComparisonData(today: utc(2026, 3, 15), accounts: accounts, snapshots: snapshots, transactions: transactions, transferLinks: links,
                       categories: categories, rate: rate, payCalendar: calendar, horizonYear: 2026, horizonMonth: 12)
    }

    // MARK: The helper

    func testConvertsOnlyNonGBPAccountsAndKeepsEverythingElse() {
        let conversion = CurrencyConversion(accounts: accounts, rate: rate)
        XCTAssertEqual(conversion.gbp(transactions[0]), -8_500)
        XCTAssertEqual(conversion.gbp(transactions[1]), -5_000)
        XCTAssertEqual(conversion.currency(ofAccount: eurId), .eur)
        XCTAssertEqual(conversion.currency(ofAccount: 99), .gbp)
        let converted = conversion.toGBP(transactions)
        XCTAssertEqual(converted.map(\.amountMinorUnits), [-8_500, -5_000])
        XCTAssertEqual(converted.map(\.id), transactions.map(\.id))
        XCTAssertEqual(converted.map(\.accountId), transactions.map(\.accountId))
    }

    func testGBPOnlyAccountsLeaveTransactionsUnchanged() {
        let gbpOnly = CurrencyConversion(accounts: [accounts[0]], rate: rate)
        let all = transactions
        XCTAssertEqual(gbpOnly.toGBP(all), all)
        XCTAssertEqual(CurrencyConversion.none.toGBP(all), all)
    }

    func testReadsTheAccountsAndStoredRateFromTheDatabase() throws {
        let manager = try DatabaseManager(path: nil)
        try manager.migrate()
        let queue = manager.dbQueue
        try queue.write { db in
            for var account in accounts { try account.insert(db) }
            var setting = rate
            try setting.insert(db)
        }
        let conversion = try queue.read { db in try CurrencyConversion.current(db: db) }
        XCTAssertEqual(conversion, CurrencyConversion(accounts: accounts, rate: rate))
    }

    // MARK: Budget grid (cells and Totals) and plan status

    func testBudgetGridCellsAndTotalsCountTheEuroExpenseAtTheRate() {
        let data = comparison(transactions)
        let actuals = ScenarioComparison.gridActuals(data)
        XCTAssertEqual(actuals.monthTotals[groceriesId]?[2026]?[2], -13_500)
        // The side panel's list stays in each account's currency.
        XCTAssertEqual(actuals.budgetFacing.map(\.amountMinorUnits), [-10_000, -5_000])

        let plan = PlanInput(entries: [], exceptions: [], groups: [])
        let grid = ScenarioComparison.grid(data, actuals: actuals, scenario: plan, budget: plan, year: 2026)
        XCTAssertEqual(grid.cells[groceriesId]?[2]?.value, -13_500)
        XCTAssertEqual(grid.totals[.totalOut]?[2]?.value, -13_500)
        XCTAssertEqual(grid.totals[.net]?[2]?.value, -13_500)
    }

    func testGBPOnlyTotalsAreUnchanged() {
        let gbpOnly = [txn(2, utc(2026, 2, 12), -5_000, groceriesId, account: gbpId)]
        let actuals = ScenarioComparison.gridActuals(comparison(gbpOnly))
        XCTAssertEqual(actuals.monthTotals[groceriesId]?[2026]?[2], -5_000)
        XCTAssertEqual(dashboard(gbpOnly).monthTotals, PayMonthTotals.lookup(transactions: gbpOnly, calendar: calendar))
    }

    // MARK: Dashboard

    func testDashboardFlowsCountTheEuroExpenseAtTheRate() throws {
        let input = dashboard(transactions)
        XCTAssertEqual(input.monthTotals[groceriesId]?[2026]?[2], -13_500)
        let february = try XCTUnwrap(DashboardCalculator.monthlyFlows(input, year: 2026).first { $0.month == 2 })
        XCTAssertEqual(february.expenseActual, 13_500)
        // Net worth keeps the native balance, converted once: £950 + €900 × 0.85.
        XCTAssertEqual(DashboardCalculator.netWorthSeries(input).currentNetWorthMinorUnits, 95_000 + 76_500)
        let euro = try XCTUnwrap(DashboardCalculator.accountSummaries(input).first { $0.id == eurId })
        XCTAssertEqual(euro.nativeBalanceMinorUnits, 90_000)
        XCTAssertEqual(euro.gbpBalanceMinorUnits, 76_500)
    }

    func testNetWorthIsNotConvertedTwice() {
        let input = dashboard(transactions)
        let direct = NetWorthCalculator.monthEndNetWorth(accounts: accounts, snapshots: snapshots, transactions: transactions, rate: rate, year: 2026, month: 2)
        XCTAssertEqual(direct, 171_500)
        XCTAssertEqual(DashboardCalculator.netWorthSeries(input).actual.first { $0.month == 2 }?.valueMinorUnits, direct)
    }

    // MARK: Categories

    func testCategoryAverageAndDistributionCountTheEuroExpenseAtTheRate() {
        let converted = CurrencyConversion(accounts: accounts, rate: rate).toGBP(transactions)
        // Pay months Jan and Feb are closed: the window holds February (and January) only.
        let averages = CategoryStats.monthlyAverages(transactions: converted, calendar: calendar)
        XCTAssertEqual(averages[groceriesId], CategoryStats.monthlyAverages(transactions: [txn(9, utc(2026, 2, 10), -13_500, groceriesId, account: gbpId)], calendar: calendar)[groceriesId])
        XCTAssertNotNil(averages[groceriesId])

        let distribution = CategoryDistribution.compute(year: 2026, transactions: converted, categories: categories,
                                                        groups: [CategoryGroup(id: 1, name: "Food")], calendar: calendar)
        XCTAssertEqual(distribution.expenseTotal, 13_500)
    }

    // MARK: Transfers

    func testATransferAcrossCurrenciesCountsOnceAsSentInGBP() {
        // €100 sent from the EUR account, £85 received in the GBP one, linked.
        let out = txn(10, utc(2026, 2, 15), -10_000, savingsId, account: eurId)
        let inLeg = txn(11, utc(2026, 2, 16), 8_500, savingsId, account: gbpId)
        let links = [TransferLink(id: 1, outTransactionId: 10, inTransactionId: 11, origin: .auto)]
        let input = dashboard([out, inLeg], links: links)
        XCTAssertEqual(input.budgetTransactions.map(\.id), [10])
        XCTAssertEqual(input.monthTotals[savingsId]?[2026]?[2], -8_500)
        XCTAssertEqual(ScenarioComparison.gridActuals(comparison([out, inLeg], links: links)).monthTotals[savingsId]?[2026]?[2], -8_500)
        // Net worth: both legs, native; -€100 × 0.85 + £85 leaves it where it started.
        XCTAssertEqual(DashboardCalculator.netWorthSeries(input).currentNetWorthMinorUnits, 100_000 + 85_000)
    }
}
