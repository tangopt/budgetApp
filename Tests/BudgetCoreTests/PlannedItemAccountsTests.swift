import XCTest
import GRDB
@testable import BudgetCore
import struct BudgetCore.Category
import TestSupport

/// Spec 2026-10-15 §2–§4: planned items' accounts, the plan per account set, net worth per account set.
final class PlannedItemAccountsTests: XCTestCase {
    private func utc(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        return cal.date(from: DateComponents(year: y, month: m, day: d))!
    }

    // Accounts: Current (1), Joint (2). Categories: Salary (1), Rent (2), "Transfer: Joint" (3,
    // tied to Joint), "Transfer: Current" (4, tied to Current), Gym (5, no history).
    private let current: Int64 = 1, joint: Int64 = 2
    private let salary: Int64 = 1, rent: Int64 = 2, toJoint: Int64 = 3, toCurrent: Int64 = 4, gym: Int64 = 5

    private var categories: [Category] {
        [Category(id: salary, name: "Salary", type: .income),
         Category(id: rent, name: "Rent", type: .expense),
         Category(id: toJoint, name: "Transfer: Joint", type: .transfer, transferAccountId: joint),
         Category(id: toCurrent, name: "Transfer: Current", type: .transfer, transferAccountId: current),
         Category(id: gym, name: "Gym", type: .expense)]
    }
    private var accounts: [Account] {
        [Account(id: current, name: "Current", currency: .gbp, kind: .cash, trackingMode: .imported),
         Account(id: joint, name: "Joint", currency: .gbp, kind: .cash, trackingMode: .imported)]
    }

    private func txn(_ id: Int64, _ account: Int64, _ date: Date, _ amount: Int, _ category: Int64?, status: TransactionStatus = .confirmed) -> Transaction {
        Transaction(id: id, importBatchId: 1, accountId: account, date: date, rawDescription: "T\(id)", amountMinorUnits: amount, categoryId: category, status: status, categorizedBy: .manual, fingerprint: "fp\(id)")
    }
    private func entry(_ id: Int64, _ category: Int64, _ amount: Int, day: Int, account: Int64? = nil) -> ForecastEntry {
        ForecastEntry(id: id, groupId: 1, categoryId: category, amountMinorUnits: amount, frequency: .monthly, interval: 1, startDate: utc(2026, 1, day), endDate: nil,
                      isEnabled: true, status: .confirmed, note: nil, accountId: account)
    }
    private let groups = [ForecastGroup(id: 1, name: "Planned", note: nil, isEnabled: true, isSystemManaged: false)]

    /// Salary into Current, rent from Joint, £500 a month Current → Joint.
    private var transactions: [Transaction] {
        [txn(1, current, utc(2026, 3, 25), 300_000, salary),
         txn(2, joint, utc(2026, 3, 1), -100_000, rent),
         txn(3, current, utc(2026, 3, 5), -50_000, toJoint)]
    }
    private var entries: [ForecastEntry] {
        [entry(1, salary, 300_000, day: 25), entry(2, rent, -100_000, day: 1), entry(3, toJoint, -50_000, day: 5)]
    }
    private var itemAccounts: PlannedItemAccounts {
        PlannedItemAccounts(inferredByCategory: PlannedItemAccounts.inferAccounts(budgetTransactions: transactions, since: utc(2025, 5, 1)), categories: categories)
    }
    private func filter(_ ids: Set<Int64>) -> PlanAccountFilter { PlanAccountFilter(accountIds: ids, itemAccounts: itemAccounts) }
    private var april: PayPeriod { PayPeriod(startDate: utc(2026, 4, 1), endDate: MonthRange.of(year: 2026, month: 4).end, type: .projected) }

    // MARK: Migration

    func testMigrationAddsAccountIdThatClearsWhenTheAccountIsDeletedAndScenarioCopiesKeepIt() throws {
        let manager = try DatabaseManager(path: nil)
        try manager.migrate()
        try manager.dbQueue.write { db in
            XCTAssertTrue(try db.columns(in: "forecastEntry").contains { $0.name == "accountId" })
            var account = Account(name: "Joint", currency: .gbp, kind: .cash, trackingMode: .imported)
            try account.insert(db)
            var gym = Category(name: "Gym", type: .expense)
            try gym.insert(db)
            let added = try PlannedItems.add(db: db, categoryId: gym.id!, amountMinorUnits: -4_500, frequency: .monthly, interval: 1, startDate: utc(2026, 11, 1), endDate: nil, accountId: account.id)
            XCTAssertEqual(try ForecastEntry.fetchOne(db, key: added.id!)?.accountId, account.id)

            let scenario = try Scenarios.create(db: db, name: "Plan B")
            XCTAssertEqual(try ForecastEntry.inScenario(db, id: scenario.id!).map(\.accountId), [account.id])

            _ = try account.delete(db)
            XCTAssertNil(try ForecastEntry.fetchOne(db, key: added.id!)?.accountId)
        }
    }

    // MARK: Inference

    func testInferenceTakesTheAccountWithMostTransactions() {
        let txns = [txn(1, current, utc(2026, 3, 1), -1_000, gym), txn(2, joint, utc(2026, 3, 2), -1_000, gym), txn(3, joint, utc(2026, 2, 2), -1_000, gym)]
        XCTAssertEqual(PlannedItemAccounts.inferAccounts(budgetTransactions: txns, since: utc(2025, 5, 1)), [gym: joint])
    }

    func testInferenceTieGoesToTheMostRecentTransactionsAccount() {
        let txns = [txn(1, current, utc(2026, 3, 9), -1_000, gym), txn(2, joint, utc(2026, 3, 2), -1_000, gym),
                    txn(3, joint, utc(2026, 1, 2), -1_000, gym), txn(4, current, utc(2026, 1, 1), -1_000, gym)]
        XCTAssertEqual(PlannedItemAccounts.inferAccounts(budgetTransactions: txns, since: utc(2025, 5, 1)), [gym: current])
    }

    func testInferenceUsesTheWindowAndFallsBackToAllHistory() {
        // Rent: Joint in the window, though Current had more before it. Gym: nothing in the
        // window, so all history (Current).
        let txns = [txn(1, joint, utc(2026, 3, 1), -1_000, rent),
                    txn(2, current, utc(2024, 3, 1), -1_000, rent), txn(3, current, utc(2024, 4, 1), -1_000, rent),
                    txn(4, current, utc(2024, 3, 1), -1_000, gym)]
        XCTAssertEqual(PlannedItemAccounts.inferAccounts(budgetTransactions: txns, since: utc(2025, 5, 1)), [rent: joint, gym: current])
    }

    func testInferenceIgnoresUnreviewedAndUncategorisedTransactionsAndIsNilWithoutHistory() {
        let txns = [txn(1, current, utc(2026, 3, 1), -1_000, gym, status: .pendingReview), txn(2, current, utc(2026, 3, 1), -1_000, nil)]
        let accounts = PlannedItemAccounts(inferredByCategory: PlannedItemAccounts.inferAccounts(budgetTransactions: txns, since: utc(2025, 5, 1)), categories: categories)
        XCTAssertNil(accounts.inferredAccount(categoryId: gym))
        XCTAssertNil(accounts.effectiveAccount(of: entry(9, gym, -1_000, day: 1)))
    }

    func testWindowStartIsTwelvePayMonthsBackIncludingTheCurrentOne() {
        let calendar = PayCalendar(salaryDates: [], manualCloses: [], today: utc(2026, 10, 15))
        XCTAssertEqual(PlannedItemAccounts.windowStart(calendar: calendar), utc(2025, 11, 1))
    }

    func testExplicitAccountWinsOverTheInferredOne() {
        XCTAssertEqual(itemAccounts.effectiveAccount(of: entry(1, salary, 1, day: 1)), current)
        XCTAssertEqual(itemAccounts.effectiveAccount(of: entry(1, salary, 1, day: 1, account: joint)), joint)
    }

    // MARK: The plan per account set

    func testUnfilteredTotalsAreUnchanged() {
        let old = ForecastCalculator.confirmedTotalsByCategory(period: april, entries: entries, groups: groups, exceptions: [])
        XCTAssertEqual(old, [salary: 300_000, rent: -100_000, toJoint: -50_000])
        XCTAssertEqual(ForecastCalculator.confirmedTotalsByCategory(period: april, entries: entries, groups: groups, exceptions: [], filter: nil), old)
        XCTAssertEqual(ForecastCalculator.confirmedNetWorthImpact(period: april, categories: categories, entries: entries, groups: groups, exceptions: [], filter: nil), 200_000)
    }

    func testPayingAccountSeesTheOutgoingTransfer() {
        XCTAssertEqual(ForecastCalculator.confirmedTotalsByCategory(period: april, entries: entries, groups: groups, exceptions: [], filter: filter([current])),
                       [salary: 300_000, toJoint: -50_000])
    }

    func testTiedAccountSeesTheIncomingTransferUnderThePayingAccountsTransferCategory() {
        XCTAssertEqual(ForecastCalculator.confirmedTotalsByCategory(period: april, entries: entries, groups: groups, exceptions: [], filter: filter([joint])),
                       [rent: -100_000, toCurrent: 50_000])
    }

    func testBothTransferLegsSelectedCountOnceAsSent() {
        XCTAssertEqual(ForecastCalculator.confirmedTotalsByCategory(period: april, entries: entries, groups: groups, exceptions: [], filter: filter([current, joint])),
                       [salary: 300_000, rent: -100_000, toJoint: -50_000])
    }

    func testItemsWithNoEffectiveAccountAreHiddenWhileFiltered() {
        let plan = entries + [entry(4, gym, -4_500, day: 10)]
        XCTAssertEqual(ForecastCalculator.confirmedTotalsByCategory(period: april, entries: plan, groups: groups, exceptions: [], filter: nil)[gym], -4_500)
        XCTAssertNil(ForecastCalculator.confirmedTotalsByCategory(period: april, entries: plan, groups: groups, exceptions: [], filter: filter([current, joint]))[gym])
        // Given an account, it shows there.
        let explicit = entries + [entry(4, gym, -4_500, day: 10, account: joint)]
        XCTAssertEqual(ForecastCalculator.confirmedTotalsByCategory(period: april, entries: explicit, groups: groups, exceptions: [], filter: filter([joint]))[gym], -4_500)
    }

    func testIncomingLegFollowsAnOccurrencesAmountOverride() {
        let override = PlannedOccurrenceException(entryId: 3, originalDate: utc(2026, 4, 5), amountMinorUnits: -70_000)
        XCTAssertEqual(ForecastCalculator.confirmedTotalsByCategory(period: april, entries: entries, groups: groups, exceptions: [override], filter: filter([joint]))[toCurrent], 70_000)
    }

    func testLegsMarkTheIncomingSide() {
        let occurrence = PlannedOccurrence(entryId: 3, originalDate: utc(2026, 4, 5), date: utc(2026, 4, 5), categoryId: toJoint, amountMinorUnits: -50_000, isException: false)
        let legs = itemAccounts.legs(of: occurrence, entry: entries[2])
        XCTAssertEqual(legs.map(\.accountId), [current, joint])
        XCTAssertEqual(legs.map(\.isIncomingTransfer), [false, true])
        XCTAssertEqual(legs[1].occurrence.categoryId, toCurrent)
        XCTAssertEqual(legs[1].occurrence.amountMinorUnits, 50_000)
    }

    func testNetWorthImpactPerAccountSet() {
        func impact(_ ids: Set<Int64>) -> Int {
            ForecastCalculator.confirmedNetWorthImpact(period: april, categories: categories, entries: entries, groups: groups, exceptions: [], filter: filter(ids))
        }
        XCTAssertEqual(impact([current]), 250_000)          // salary − transfer out
        XCTAssertEqual(impact([joint]), -50_000)            // rent + transfer in
        XCTAssertEqual(impact([current, joint]), 200_000)   // the transfer stays inside
    }

    // Review fix: an incoming planned transfer into a selected tied account counts even when
    // it can't be filed under its payer's own transfer category.
    func testIncomingTransferWithNoPayerOrAPayerWithoutTransferCategoryCounts() {
        let savingsAccount: Int64 = 3
        let unknownPayer = PlanAccountFilter(accountIds: [joint], itemAccounts: PlannedItemAccounts(inferredByCategory: [:], categories: categories))
        let plan = [entry(3, toJoint, -50_000, day: 5)]
        XCTAssertEqual(ForecastCalculator.confirmedNetWorthImpact(period: april, categories: categories, entries: plan, groups: groups, exceptions: [], filter: unknownPayer), 50_000)
        XCTAssertEqual(ForecastProjector.remainingPlanned(year: 2026, month: 4, actuals: [:], categories: categories, entries: plan, groups: groups, exceptions: [], filter: unknownPayer), 50_000)

        let fromSavings = [entry(3, toJoint, -50_000, day: 5, account: savingsAccount)]
        XCTAssertEqual(ForecastCalculator.confirmedNetWorthImpact(period: april, categories: categories, entries: fromSavings, groups: groups, exceptions: [], filter: filter([joint])), 50_000)
        XCTAssertEqual(ForecastCalculator.confirmedNetWorthImpact(period: april, categories: categories, entries: fromSavings, groups: groups, exceptions: [], filter: filter([savingsAccount])), -50_000)
        XCTAssertEqual(ForecastCalculator.confirmedNetWorthImpact(period: april, categories: categories, entries: fromSavings, groups: groups, exceptions: [], filter: filter([joint, savingsAccount])), 0)
    }

    func testScenarioDifferencesDescribeAnAccountChange() throws {
        let manager = try TestDatabase.migratedManager()
        try manager.dbQueue.write { db in
            var account = Account(name: "Joint", currency: .gbp, kind: .cash, trackingMode: .imported)
            try account.insert(db)
            var gym = Category(name: "Gym", type: .expense)
            try gym.insert(db)
            try PlannedItems.add(db: db, categoryId: gym.id!, amountMinorUnits: -4_500, frequency: .monthly, interval: 1, startDate: utc(2026, 11, 1), endDate: nil)
            let scenario = try Scenarios.create(db: db, name: "Plan B")
            var copy = try XCTUnwrap(ForecastEntry.inScenario(db, id: scenario.id!).first)
            copy.accountId = account.id
            copy.scenarioChange = .changed
            try copy.update(db)
            XCTAssertEqual(try Scenarios.differences(db: db, scenarioId: scenario.id!).first?.fieldChanges, ["Account: Automatic → Joint"])
        }
    }

    func testReserveUnforecastSpendWithPlannedTotalsMatchesTheEntriesVersion() {
        let monthTotals: [Int64: [Int: [Int: Int]]] = [gym: [2026: [4: -3_000]], rent: [2026: [4: -100_000]]]
        let fromEntries = ReservedCategories.unforecastSpend(year: 2026, month: 4, categories: categories, monthTotals: monthTotals, entries: entries, groups: groups, exceptions: [])
        let totals = ForecastCalculator.confirmedTotalsByCategory(period: april, entries: entries, groups: groups, exceptions: [])
        XCTAssertEqual(fromEntries, 3_000)
        XCTAssertEqual(ReservedCategories.unforecastSpend(year: 2026, month: 4, categories: categories, monthTotals: monthTotals, plannedTotals: totals), fromEntries)
    }

    // MARK: Net worth per account set

    /// Today 15 Apr 2026; data through 25 Mar. Current opened at £10,000, Joint at £2,000.
    private func input(_ ids: Set<Int64>?) -> DashboardInput {
        var input = DashboardInput(today: utc(2026, 4, 15), accounts: accounts,
                                   snapshots: [BalanceSnapshot(accountId: current, date: utc(2026, 1, 1), balanceMinorUnits: 1_000_000, note: nil),
                                               BalanceSnapshot(accountId: joint, date: utc(2026, 1, 1), balanceMinorUnits: 200_000, note: nil)],
                                   transactions: transactions, categories: categories, categoryGroups: [], forecastEntries: entries, forecastGroups: groups,
                                   exceptions: [], importBatches: [], rate: ExchangeRateSetting(eurToGbpRate: 0.5, updatedAt: utc(2026, 1, 1)))
        input.accountFilter = ids.map(filter)
        return input
    }

    func testYearEndNetWorthFollowsTheAccountSet() {
        // Now: Current 1_250_000, Joint 100_000. Nine projected months (Apr…Dec).
        XCTAssertEqual(DashboardCalculator.yearEndNetWorth(input(nil), year: 2026), YearEndNetWorth(valueMinorUnits: 3_150_000, isForecast: true))
        XCTAssertEqual(DashboardCalculator.yearEndNetWorth(input([current, joint]), year: 2026), YearEndNetWorth(valueMinorUnits: 3_150_000, isForecast: true))
        XCTAssertEqual(DashboardCalculator.yearEndNetWorth(input([current]), year: 2026), YearEndNetWorth(valueMinorUnits: 3_500_000, isForecast: true))
        // Joint: March's planned £500 from Current hasn't arrived yet, so it's still expected.
        XCTAssertEqual(DashboardCalculator.yearEndNetWorth(input([joint]), year: 2026), YearEndNetWorth(valueMinorUnits: -300_000, isForecast: true))
        XCTAssertEqual(DashboardCalculator.yearEndNetWorth(input([joint]), year: 2025), nil)
        XCTAssertEqual(DashboardCalculator.netWorthSeries(input([current])).currentNetWorthMinorUnits, 1_250_000)
    }

    func testForecastOffGivesTodaysActualNetWorthForThisYearAndNothingLater() {
        XCTAssertEqual(DashboardCalculator.yearEndNetWorth(input(nil), year: 2026, includeForecast: false), YearEndNetWorth(valueMinorUnits: 1_350_000, isForecast: false))
        XCTAssertEqual(DashboardCalculator.yearEndNetWorth(input([joint]), year: 2026, includeForecast: false), YearEndNetWorth(valueMinorUnits: 100_000, isForecast: false))
        XCTAssertNil(DashboardCalculator.yearEndNetWorth(input(nil), year: 2027, includeForecast: false))
    }

    func testBudgetNetWorthRowIsActualToTodayThenForecastOrBlank() {
        let on = DashboardCalculator.budgetNetWorthMonths(input(nil), year: 2026, includeForecast: true)
        XCTAssertEqual(Array(on.prefix(4)), [1_200_000, 1_200_000, 1_350_000, 1_350_000])
        XCTAssertEqual(on[4], 1_750_000)  // May: two projected months from the March walk start
        XCTAssertEqual(on[11], 3_150_000)
        let off = DashboardCalculator.budgetNetWorthMonths(input(nil), year: 2026, includeForecast: false)
        XCTAssertEqual(Array(off.prefix(4)), Array(on.prefix(4)))
        XCTAssertEqual(Array(off.dropFirst(4)), Array(repeating: nil, count: 8))
        let currentOnly = DashboardCalculator.budgetNetWorthMonths(input([current]), year: 2026, includeForecast: true)
        XCTAssertEqual(currentOnly[0], 1_000_000)
        XCTAssertEqual(currentOnly[11], 3_500_000)
    }

    /// The Budget grid works `netWorthActuals` out once and passes it in for every year and
    /// both Show forecast states: the figures must match working it out each time.
    func testNetWorthFiguresWithSharedActualsMatchTheUncachedOnes() {
        for ids in [nil, [current], [joint], [current, joint]] as [Set<Int64>?] {
            let input = input(ids)
            let actuals = DashboardCalculator.netWorthActuals(input)
            XCTAssertNotNil(actuals)
            for includeForecast in [true, false] {
                for year in 2024...2028 {
                    XCTAssertEqual(DashboardCalculator.budgetNetWorthMonths(input, actuals: actuals, year: year, includeForecast: includeForecast),
                                   DashboardCalculator.budgetNetWorthMonths(input, year: year, includeForecast: includeForecast), "\(String(describing: ids)) \(includeForecast) \(year)")
                    XCTAssertEqual(DashboardCalculator.yearEndNetWorth(input, actuals: actuals, year: year, includeForecast: includeForecast),
                                   DashboardCalculator.yearEndNetWorth(input, year: year, includeForecast: includeForecast), "\(String(describing: ids)) \(includeForecast) \(year)")
                }
            }
        }
    }

    // MARK: Editing

    private func editingFixture() throws -> (DatabaseManager, entryId: Int64, accountId: Int64) {
        let manager = try TestDatabase.migratedManager()
        let ids = try manager.dbQueue.write { db -> (Int64, Int64) in
            var rent = Category(name: "Rent", type: .expense)
            try rent.insert(db)
            var group = ForecastGroup(name: "Planned", note: nil, isEnabled: true, isSystemManaged: false)
            try group.insert(db)
            var account = Account(name: "Joint", currency: .gbp, kind: .cash, trackingMode: .imported)
            try account.insert(db)
            var entry = ForecastEntry(groupId: group.id!, categoryId: rent.id!, amountMinorUnits: -100_000, frequency: .monthly, interval: 1, startDate: utc(2026, 8, 15), endDate: nil,
                                      isEnabled: true, status: .manual, note: nil, accountId: account.id)
            try entry.insert(db)
            return (entry.id!, account.id!)
        }
        return (manager, ids.0, ids.1)
    }
    private var editCalendar: PayCalendar { PayCalendar(salaryDates: [utc(2026, 8, 31), utc(2026, 9, 30)], manualCloses: [], today: utc(2026, 10, 5)) }

    func testEditFollowingKeepsTheAccountUnlessChanged() throws {
        let (manager, entryId, accountId) = try editingFixture()
        try manager.dbQueue.write { db in
            try PlannedItemEditing.editFollowing(db: db, entryId: entryId, originalDate: utc(2026, 10, 15), change: OccurrenceChange(amountMinorUnits: -110_000), calendar: editCalendar)
            let kept = try ForecastEntry.order(Column("id")).fetchAll(db).last!
            XCTAssertEqual(kept.accountId, accountId)
            try PlannedItemEditing.editFollowing(db: db, entryId: kept.id!, originalDate: utc(2026, 11, 15), change: OccurrenceChange(accountId: .some(nil)), calendar: editCalendar)
            XCTAssertNil(try ForecastEntry.order(Column("id")).fetchAll(db).last!.accountId)
        }
    }

    func testAnAccountChangeToOnlyThisOccurrenceIsRefused() throws {
        let (manager, entryId, _) = try editingFixture()
        try manager.dbQueue.write { db in
            XCTAssertThrowsError(try PlannedItemEditing.editOccurrence(db: db, entryId: entryId, originalDate: utc(2026, 10, 15), change: OccurrenceChange(accountId: .some(nil)), calendar: editCalendar)) {
                XCTAssertEqual($0 as? PlannedItemEditError, .accountNeedsFollowing)
            }
        }
    }
}
