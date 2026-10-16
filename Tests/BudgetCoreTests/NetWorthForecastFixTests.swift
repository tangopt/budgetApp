import XCTest
@testable import BudgetCore
import struct BudgetCore.Category

/// Spec 2026-10-15 net-worth-forecast-fix §1–§2: the walk starts from today with the rest of
/// the current month's plan, and external transfers count.
final class NetWorthForecastFixTests: XCTestCase {
    private func utc(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        return cal.date(from: DateComponents(year: y, month: m, day: d))!
    }

    private let current: Int64 = 1, joint: Int64 = 2
    private let pay: Int64 = 1, rent: Int64 = 2, groceries: Int64 = 3, santander: Int64 = 4, savings: Int64 = 5, holiday: Int64 = 6

    // "Pay", not "Salary": no paydays, so pay months are calendar months.
    private var categories: [Category] {
        [Category(id: pay, name: "Pay", type: .income),
         Category(id: rent, name: "Rent", type: .expense),
         Category(id: groceries, name: "Groceries", type: .expense),
         Category(id: santander, name: "Transfer: Santander Person B", type: .transfer, isExternalTransfer: true),
         Category(id: savings, name: "Transfer: Savings", type: .transfer),
         Category(id: holiday, name: "Holiday", type: .expense, isReserved: true)]
    }
    private let groups = [ForecastGroup(id: 1, name: "Planned", note: nil, isEnabled: true, isSystemManaged: false)]

    private func entry(_ id: Int64, _ category: Int64, _ amount: Int, day: Int, account: Int64? = nil) -> ForecastEntry {
        ForecastEntry(id: id, groupId: 1, categoryId: category, amountMinorUnits: amount, frequency: .monthly, interval: 1, startDate: utc(2026, 1, day), endDate: nil,
                      isEnabled: true, status: .confirmed, note: nil, accountId: account)
    }
    /// +£8,104.31 pay on the 24th, −£1,000 rent on the 1st, −£400 groceries on the 10th,
    /// −£1,250 to Santander (external) on the 28th, −£500 to own savings on the 2nd.
    private var entries: [ForecastEntry] {
        [entry(1, pay, 810_431, day: 24), entry(2, rent, -100_000, day: 1), entry(3, groceries, -40_000, day: 10),
         entry(4, santander, -125_000, day: 28), entry(5, savings, -50_000, day: 2)]
    }
    private func txn(_ id: Int64, _ date: Date, _ amount: Int, _ category: Int64, account: Int64 = 1) -> Transaction {
        Transaction(id: id, importBatchId: 1, accountId: account, date: date, rawDescription: "T\(id)", amountMinorUnits: amount, categoryId: category, status: .confirmed, categorizedBy: .manual, fingerprint: "fp\(id)")
    }
    /// Data through 12 Oct: rent paid in full, £150 of groceries so far. Current: £10,000 − £1,150.
    private var transactions: [Transaction] {
        [txn(1, utc(2026, 10, 1), -100_000, rent), txn(2, utc(2026, 10, 12), -15_000, groceries)]
    }
    private var accounts: [Account] {
        [Account(id: current, name: "Current", currency: .gbp, kind: .cash, trackingMode: .imported),
         Account(id: joint, name: "Joint", currency: .gbp, kind: .cash, trackingMode: .imported)]
    }

    private func input(entries: [ForecastEntry]? = nil, manualCloses: [PayMonthClose] = []) -> DashboardInput {
        DashboardInput(today: utc(2026, 10, 15), accounts: accounts,
                       snapshots: [BalanceSnapshot(accountId: current, date: utc(2026, 1, 1), balanceMinorUnits: 1_000_000, note: nil)],
                       transactions: transactions, categories: categories, categoryGroups: [], forecastEntries: entries ?? self.entries, forecastGroups: groups,
                       exceptions: [], importBatches: [], rate: ExchangeRateSetting(eurToGbpRate: 0.5, updatedAt: utc(2026, 1, 1)), manualCloses: manualCloses)
    }
    private func month(_ m: Int) -> PayPeriod {
        let range = MonthRange.of(year: 2026, month: m)
        return PayPeriod(startDate: range.start, endDate: range.end, type: .projected)
    }

    // Remaining October: pay +810_431, groceries −25_000 (−40_000 planned, −15_000 paid),
    // Santander −125_000; rent is paid (0); own savings excluded.
    private let octoberRemaining = 810_431 - 25_000 - 125_000
    // A full month: pay − rent − groceries − Santander.
    private let fullMonth = 810_431 - 100_000 - 40_000 - 125_000

    func testRemainingPlanCountsOnlyWhatActualsHaveNotCovered() {
        let remaining = ForecastProjector.remainingPlanned(year: 2026, month: 10, actuals: [rent: -100_000, groceries: -15_000], categories: categories,
                                                           entries: entries, groups: groups, exceptions: [])
        XCTAssertEqual(remaining, octoberRemaining)
    }

    func testYearEndIncludesTheRestOfThisMonthOnceThenFullMonths() throws {
        let yearEnd = try XCTUnwrap(DashboardCalculator.yearEndNetWorth(input(), year: 2026))
        XCTAssertEqual(yearEnd, YearEndNetWorth(valueMinorUnits: 885_000 + octoberRemaining + 2 * fullMonth, isForecast: true))
    }

    func testAClosedWalkStartMonthHasNothingRemaining() throws {
        let closed = input(manualCloses: [PayMonthClose(year: 2026, month: 10, closeDate: utc(2026, 10, 12))])
        XCTAssertEqual(try XCTUnwrap(DashboardCalculator.yearEndNetWorth(closed, year: 2026)).valueMinorUnits, 885_000 + 2 * fullMonth)
    }

    func testFullMonthsAfterTheWalkStartAreUnchangedByTheStart() {
        // The projector itself: each full month adds its impact to whatever start it's given.
        let points = ForecastProjector.monthlyProjection(startingNetWorth: 0, latestRealMonth: (2026, 10), throughYear: 2026, categories: categories, entries: entries, groups: groups, exceptions: [])
        XCTAssertEqual(points.map(\.valueMinorUnits), [fullMonth, 2 * fullMonth])
    }

    func testExternalTransfersCountInNetWorthAndOwnTransfersDoNot() {
        XCTAssertEqual(ForecastCalculator.confirmedNetWorthImpact(period: month(11), categories: categories, entries: entries, groups: groups, exceptions: []), fullMonth)
        XCTAssertTrue(ForecastCalculator.countsInNetWorth(categories[3], accountIds: nil))
        XCTAssertFalse(ForecastCalculator.countsInNetWorth(categories[4], accountIds: nil))
    }

    func testUnderAFilterAnExternalTransferCountsForItsEffectiveAccount() {
        let plan = entries.map { $0.id == 4 ? entry(4, santander, -125_000, day: 28, account: joint) : $0 }
        let itemAccounts = PlannedItemAccounts(inferredByCategory: [pay: current, rent: current, groceries: current, savings: current], categories: categories)
        func impact(_ ids: Set<Int64>) -> Int {
            ForecastCalculator.confirmedNetWorthImpact(period: month(11), categories: categories, entries: plan, groups: groups, exceptions: [],
                                                       filter: PlanAccountFilter(accountIds: ids, itemAccounts: itemAccounts))
        }
        XCTAssertEqual(impact([joint]), -125_000)
        XCTAssertEqual(impact([current]), fullMonth + 125_000)
    }

    func testReservesRemainingIsWhatsLeftAfterUnforecastSpend() {
        // A £300 holiday allowance; £100 spent on an unplanned expense category this month.
        var plan = entries
        plan.append(entry(6, holiday, -30_000, day: 1))
        let all = categories + [Category(id: 7, name: "Gifts", type: .expense)]
        let remaining = ForecastProjector.remainingPlanned(year: 2026, month: 10, actuals: [rent: -100_000, groceries: -15_000, 7: -10_000], categories: all,
                                                           entries: plan, groups: groups, exceptions: [])
        XCTAssertEqual(remaining, octoberRemaining - 20_000)
    }

    func testDashboardBudgetAndForecastShareTheWalk() throws {
        let input = input()
        let expected = 885_000 + octoberRemaining + 2 * fullMonth
        let series = DashboardCalculator.netWorthSeries(input)
        XCTAssertEqual(series.yearEnds.first?.valueMinorUnits, expected)
        XCTAssertEqual(series.forecast.first(where: { $0.year == 2026 && $0.month == 12 })?.valueMinorUnits, expected)
        // October's anchor meets the solid line at today's net worth; November carries the rest of October.
        XCTAssertEqual(series.forecast.first, NetWorthPoint(year: 2026, month: 10, valueMinorUnits: 885_000))
        XCTAssertEqual(series.forecast.dropFirst().first, NetWorthPoint(year: 2026, month: 11, valueMinorUnits: 885_000 + octoberRemaining + fullMonth))

        let row = DashboardCalculator.budgetNetWorthMonths(input, year: 2026, includeForecast: true)
        XCTAssertEqual(row[9], 885_000 + octoberRemaining)   // this month: today + what's still expected
        XCTAssertEqual(row[10], 885_000 + octoberRemaining + fullMonth)
        XCTAssertEqual(row[11], expected)
        XCTAssertEqual(DashboardCalculator.budgetNetWorthMonths(input, year: 2026, includeForecast: false)[9], 885_000)

        let data = ComparisonData(today: input.today, accounts: accounts, snapshots: input.snapshots, transactions: transactions, categories: categories,
                                  rate: input.rate, payCalendar: input.payCalendar, horizonYear: 2026, horizonMonth: 12)
        let plan = PlanInput(entries: entries, exceptions: [], groups: groups)
        XCTAssertEqual(ScenarioComparison.netWorthSeries(data, plan: plan, actuals: ScenarioComparison.actuals(data)).forecast.last?.valueMinorUnits, expected)
    }

    // Review fix: an imported-but-unreviewed salary is already in the balance, so it counts as paid.
    func testAnUnreviewedTransactionInTheWalkStartMonthCountsAsPaid() throws {
        var unreviewed = txn(3, utc(2026, 10, 12), 810_431, pay)
        unreviewed.status = .pendingReview
        let input = DashboardInput(today: utc(2026, 10, 15), accounts: accounts,
                                   snapshots: [BalanceSnapshot(accountId: current, date: utc(2026, 1, 1), balanceMinorUnits: 1_000_000, note: nil)],
                                   transactions: transactions + [unreviewed], categories: categories, categoryGroups: [], forecastEntries: entries, forecastGroups: groups,
                                   exceptions: [], importBatches: [], rate: ExchangeRateSetting(eurToGbpRate: 0.5, updatedAt: utc(2026, 1, 1)))
        // Today's net worth gains the pay; October's remaining loses it: the same year-end.
        XCTAssertEqual(DashboardCalculator.netWorthSeries(input).currentNetWorthMinorUnits, 885_000 + 810_431)
        XCTAssertEqual(try XCTUnwrap(DashboardCalculator.yearEndNetWorth(input, year: 2026)).valueMinorUnits, 885_000 + octoberRemaining + 2 * fullMonth)
    }
}
