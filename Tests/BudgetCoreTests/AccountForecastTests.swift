import XCTest
import GRDB
@testable import BudgetCore
import struct BudgetCore.Category

/// Spec 2026-10-15 account-forecast-balances: the main account, and the Budget's account rows
/// following the forecast.
final class AccountForecastTests: XCTestCase {
    private func utc(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        return cal.date(from: DateComponents(year: y, month: m, day: d))!
    }

    // Accounts: Current (1), Joint (2), Euro (3, EUR). Categories: Salary (1), Rent (2),
    // "Transfer: Joint" (3, tied to Joint), "Transfer: Current" (4, tied to Current), Gym (5, no
    // history), Gift (6, external transfer), Holiday (7, reserve).
    private let current: Int64 = 1, joint: Int64 = 2, euro: Int64 = 3
    private let salary: Int64 = 1, rent: Int64 = 2, toJoint: Int64 = 3, toCurrent: Int64 = 4, gym: Int64 = 5, gift: Int64 = 6, holiday: Int64 = 7

    private var categories: [Category] {
        [Category(id: salary, name: "Salary", type: .income),
         Category(id: rent, name: "Rent", type: .expense),
         Category(id: toJoint, name: "Transfer: Joint", type: .transfer, transferAccountId: joint),
         Category(id: toCurrent, name: "Transfer: Current", type: .transfer, transferAccountId: current),
         Category(id: gym, name: "Gym", type: .expense),
         Category(id: gift, name: "Gift", type: .transfer, isExternalTransfer: true),
         Category(id: holiday, name: "Holiday", type: .expense, isReserved: true)]
    }
    private func accounts(main: Int64? = nil) -> [Account] {
        var list = [Account(id: current, name: "Current", currency: .gbp, kind: .cash, trackingMode: .imported),
                    Account(id: joint, name: "Joint", currency: .gbp, kind: .cash, trackingMode: .imported),
                    Account(id: euro, name: "Euro", currency: .eur, kind: .cash, trackingMode: .imported)]
        for index in list.indices where list[index].id == main { list[index].isMain = true }
        return list
    }

    private func txn(_ id: Int64, _ account: Int64, _ date: Date, _ amount: Int, _ category: Int64?) -> Transaction {
        Transaction(id: id, importBatchId: 1, accountId: account, date: date, rawDescription: "T\(id)", amountMinorUnits: amount, categoryId: category, status: .confirmed, categorizedBy: .manual, fingerprint: "fp\(id)")
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
    private var baseEntries: [ForecastEntry] {
        [entry(1, salary, 300_000, day: 25), entry(2, rent, -100_000, day: 1), entry(3, toJoint, -50_000, day: 5)]
    }
    private func itemAccounts(main: Int64? = nil) -> PlannedItemAccounts {
        PlannedItemAccounts(inferredByCategory: PlannedItemAccounts.inferAccounts(budgetTransactions: transactions, since: utc(2025, 5, 1)), categories: categories, mainAccountId: main)
    }
    private var april: PayPeriod { PayPeriod(startDate: utc(2026, 4, 1), endDate: MonthRange.of(year: 2026, month: 4).end, type: .projected) }

    /// Today 15 Apr 2026; data through 25 Mar. Current opened at £10,000, Joint at £2,000, Euro at €1,000.
    private func input(entries: [ForecastEntry], main: Int64? = nil, rate: Double = 0.5, today: Date? = nil) -> DashboardInput {
        DashboardInput(today: today ?? utc(2026, 4, 15), accounts: accounts(main: main),
                       snapshots: [BalanceSnapshot(accountId: current, date: utc(2026, 1, 1), balanceMinorUnits: 1_000_000, note: nil),
                                   BalanceSnapshot(accountId: joint, date: utc(2026, 1, 1), balanceMinorUnits: 200_000, note: nil),
                                   BalanceSnapshot(accountId: euro, date: utc(2026, 1, 1), balanceMinorUnits: 100_000, note: nil)],
                       transactions: transactions, categories: categories, categoryGroups: [], forecastEntries: entries, forecastGroups: groups,
                       exceptions: [], importBatches: [], rate: ExchangeRateSetting(eurToGbpRate: rate, updatedAt: utc(2026, 1, 1)))
    }
    private func forecast(_ entries: [ForecastEntry], main: Int64? = nil, year: Int = 2026, includeForecast: Bool = true, rate: Double = 0.5) -> BudgetAccountForecast {
        let input = input(entries: entries, main: main, rate: rate)
        return DashboardCalculator.budgetAccountForecast(input, actuals: DashboardCalculator.netWorthActuals(input), itemAccounts: itemAccounts(main: main), year: year, includeForecast: includeForecast)
    }

    // MARK: Main account

    func testMigrationAddsIsMainAndSetMainKeepsAtMostOne() throws {
        let manager = try DatabaseManager(path: nil)
        try manager.migrate()
        try manager.dbQueue.write { db in
            XCTAssertTrue(try db.columns(in: "account").contains { $0.name == "isMain" })
            let a = try AccountEditing.add(db: db, name: "A", currency: .gbp, kind: .cash, openingBalanceEntered: nil, asOf: utc(2026, 1, 1))
            let b = try AccountEditing.add(db: db, name: "B", currency: .gbp, kind: .cash, openingBalanceEntered: nil, asOf: utc(2026, 1, 1))
            XCTAssertFalse(try Account.fetchOne(db, key: a.id!)!.isMain)
            try AccountEditing.setMain(db: db, accountId: a.id)
            XCTAssertEqual(try Account.fetchAll(db).filter(\.isMain).map(\.id), [a.id])
            try AccountEditing.setMain(db: db, accountId: b.id)
            XCTAssertEqual(try Account.fetchAll(db).filter(\.isMain).map(\.id), [b.id])
            try AccountEditing.setMain(db: db, accountId: nil)
            XCTAssertTrue(try Account.fetchAll(db).filter(\.isMain).isEmpty)
            XCTAssertThrowsError(try AccountEditing.setMain(db: db, accountId: 999))
            // The database refuses a second main account.
            try db.execute(sql: "UPDATE account SET isMain = 1 WHERE id = ?", arguments: [a.id])
            XCTAssertThrowsError(try db.execute(sql: "UPDATE account SET isMain = 1 WHERE id = ?", arguments: [b.id]))
        }
    }

    func testEffectiveAccountFallsBackToTheMainAccount() {
        let gymEntry = entry(9, gym, -4_500, day: 3)
        XCTAssertNil(itemAccounts().effectiveAccount(of: gymEntry))
        XCTAssertEqual(itemAccounts(main: joint).effectiveAccount(of: gymEntry), joint)
        XCTAssertEqual(itemAccounts(main: joint).automaticAccount(categoryId: gym), joint)
        XCTAssertTrue(itemAccounts(main: joint).isMainFallback(categoryId: gym))
        // History and an explicit account come first.
        XCTAssertEqual(itemAccounts(main: joint).effectiveAccount(of: entry(1, salary, 300_000, day: 25)), current)
        XCTAssertFalse(itemAccounts(main: joint).isMainFallback(categoryId: salary))
        XCTAssertEqual(itemAccounts(main: joint).effectiveAccount(of: entry(9, gym, -4_500, day: 3, account: euro)), euro)
    }

    // MARK: Legs per account

    func testInternalTransferMovesMoneyBetweenAccountsAndNetWorthIsUnchanged() {
        let impact = ForecastCalculator.netWorthImpactByAccount(period: april, categories: categories, entries: baseEntries, groups: groups, exceptions: [], itemAccounts: itemAccounts())
        XCTAssertEqual(impact[current], 250_000)
        XCTAssertEqual(impact[joint], -50_000)
        XCTAssertEqual(impact.values.reduce(0, +), ForecastCalculator.confirmedNetWorthImpact(period: april, categories: categories, entries: baseEntries, groups: groups, exceptions: []))
    }

    func testExternalTransferLowersThePayer() {
        let entries = [entry(5, gift, -20_000, day: 10, account: joint)]
        let impact = ForecastCalculator.netWorthImpactByAccount(period: april, categories: categories, entries: entries, groups: groups, exceptions: [], itemAccounts: itemAccounts())
        XCTAssertEqual(impact, [joint: -20_000])
    }

    func testItemsWithNoAccountAreUnassignedUntilThereIsAMainAccount() {
        let entries = [entry(6, gym, -4_500, day: 3)]
        XCTAssertEqual(ForecastCalculator.netWorthImpactByAccount(period: april, categories: categories, entries: entries, groups: groups, exceptions: [], itemAccounts: itemAccounts()),
                       [nil: -4_500])
        XCTAssertEqual(ForecastCalculator.netWorthImpactByAccount(period: april, categories: categories, entries: entries, groups: groups, exceptions: [], itemAccounts: itemAccounts(main: joint)),
                       [joint: -4_500])
    }

    func testRemainingPlanSplitsByAccountAndSumsToTheWholePlansRemainder() {
        // Rent split £1,000 Joint / £300 Current; Joint's £1,000 paid in March: Current's £300
        // is still expected.
        let entries = baseEntries + [entry(4, rent, -30_000, day: 20, account: current), entry(6, gym, -4_500, day: 3)]
        let actuals: [Int64: Int] = [salary: 300_000, rent: -100_000, toJoint: -50_000]
        let byAccountActuals: [Int64: [Int64: Int]] = [current: [salary: 300_000, toJoint: -50_000], joint: [rent: -100_000]]
        let byAccount = ForecastProjector.remainingPlannedByAccount(year: 2026, month: 3, actuals: actuals, actualsByAccount: byAccountActuals, categories: categories, entries: entries,
                                                                    groups: groups, exceptions: [], itemAccounts: itemAccounts())
        XCTAssertEqual(byAccount[joint] ?? 0, 0)
        XCTAssertEqual(byAccount[current], -30_000)
        XCTAssertEqual(byAccount[nil], -4_500)
        // £1,200 paid from Current: the whole plan's £100 remainder (counted once) is Joint's, still unpaid.
        let wrong = ForecastProjector.remainingPlannedByAccount(year: 2026, month: 3, actuals: [rent: -120_000], actualsByAccount: [current: [rent: -120_000]], categories: categories,
                                                                entries: [entry(2, rent, -100_000, day: 1), entry(4, rent, -30_000, day: 20, account: current)],
                                                                groups: groups, exceptions: [], itemAccounts: itemAccounts())
        XCTAssertEqual(wrong[joint], -10_000)
        XCTAssertEqual(wrong[current] ?? 0, 0)
        XCTAssertEqual(byAccount.values.reduce(0, +),
                       ForecastProjector.remainingPlanned(year: 2026, month: 3, actuals: actuals, categories: categories, entries: entries, groups: groups, exceptions: []))
    }

    func testAnUnpaidInternalTransferIsStillExpectedOnBothSides() {
        let byAccount = ForecastProjector.remainingPlannedByAccount(year: 2026, month: 3, actuals: [:], actualsByAccount: [:], categories: categories, entries: [entry(3, toJoint, -50_000, day: 5)],
                                                                    groups: groups, exceptions: [], itemAccounts: itemAccounts())
        XCTAssertEqual(byAccount[current], -50_000)
        XCTAssertEqual(byAccount[joint], 50_000)
    }

    private func remaining(_ entries: [ForecastEntry], actualsByAccount: [Int64: [Int64: Int]]) -> (byAccount: [Int64?: Int], whole: Int) {
        let actuals = actualsByAccount.values.reduce(into: [Int64: Int]()) { totals, byCategory in byCategory.forEach { totals[$0.key, default: 0] += $0.value } }
        let byAccount = ForecastProjector.remainingPlannedByAccount(year: 2026, month: 3, actuals: actuals, actualsByAccount: actualsByAccount, categories: categories, entries: entries,
                                                                    groups: groups, exceptions: [], itemAccounts: itemAccounts())
        return (byAccount.filter { $0.value != 0 },
                ForecastProjector.remainingPlanned(year: 2026, month: 3, actuals: actuals, categories: categories, entries: entries, groups: groups, exceptions: []))
    }

    func testMixedSignPlanSharesTheRemainderOnlyAmongAccountsExpectingItsDirection() {
        // A gift of £100 in on Current and £300 out from Joint: the plan's £200 out is Joint's.
        let result = remaining([entry(5, gift, 10_000, day: 10, account: current), entry(8, gift, -30_000, day: 12, account: joint)], actualsByAccount: [:])
        XCTAssertEqual(result.byAccount, [joint: -20_000])
        XCTAssertEqual(result.byAccount.values.reduce(0, +), result.whole)
    }

    func testRemainderNoAccountExpectsGoesToTheLargestLegOfItsSign() {
        // Each account paid its rent (Current more than planned), a refund landed on Euro: the
        // plan's £10 still expected goes to one rent account, whole.
        let result = remaining([entry(2, rent, -10_000, day: 1, account: current), entry(4, rent, -10_000, day: 20, account: joint)],
                               actualsByAccount: [current: [rent: -15_000], joint: [rent: -10_000], euro: [rent: 6_000]])
        XCTAssertEqual(result.whole, -1_000)
        XCTAssertEqual(result.byAccount, [current: -1_000])
    }

    func testAnUnpaidTiedTransferLegIsKeptWhenAnotherPayerSentMore() {
        // Current sent £600 of its planned £500 to Joint; Euro's £100 hasn't gone yet.
        let result = remaining([entry(3, toJoint, -50_000, day: 5, account: current), entry(9, toJoint, -10_000, day: 6, account: euro)],
                               actualsByAccount: [current: [toJoint: -60_000]])
        XCTAssertEqual(result.byAccount, [euro: -10_000, joint: 10_000])
        XCTAssertEqual(result.whole, 0)
    }

    // MARK: Account rows

    func testAccountRowsFollowTheirOwnPlannedLegs() {
        let rows = forecast(baseEntries)
        // Now: Current £12,500, Joint £1,000. Nine projected months (Apr…Dec) from the March walk start.
        XCTAssertEqual(rows.balance(accountId: current, month: 12)?.gbpMinorUnits, 3_500_000)
        XCTAssertEqual(rows.balance(accountId: joint, month: 12)?.gbpMinorUnits, -350_000)
        XCTAssertEqual(rows.balance(accountId: joint, month: 5)?.gbpMinorUnits, 0)
        XCTAssertEqual(rows.balance(accountId: euro, month: 12), AccountForecastBalance(gbpMinorUnits: 50_000, nativeMinorUnits: 100_000))
        // April (today) is actual, as on the Net Worth row.
        XCTAssertNil(rows.balance(accountId: current, month: 4))
        XCTAssertTrue(rows.unassigned.isEmpty || rows.unassigned.values.allSatisfy { $0 == 0 })
        XCTAssertFalse(rows.hasUnassigned)
    }

    func testShowForecastOffHasNoForecastMonths() {
        XCTAssertEqual(forecast(baseEntries, includeForecast: false), BudgetAccountForecast(accounts: [:], unassigned: [:], blankMonths: Set(5...12)))
        XCTAssertEqual(forecast(baseEntries, year: 2027, includeForecast: false).blankMonths, Set(1...12))
        XCTAssertEqual(forecast(baseEntries, year: 2025), .empty)
    }

    func testEuroAccountConvertsPlannedPoundsAtTheStoredRate() {
        let rows = forecast(baseEntries + [entry(7, rent, -10_000, day: 2, account: euro)])
        // £100 a month is €200 at 0.5: nine months from €1,000 (£500). March's £100 is still expected (no actual).
        let december = rows.balance(accountId: euro, month: 12)
        XCTAssertEqual(december?.gbpMinorUnits, 50_000 - 10 * 10_000)
        XCTAssertEqual(december?.nativeMinorUnits, 100_000 - 10 * 20_000)
    }

    func testUnassignedRowCarriesItemsWithNoAccount() {
        let entries = baseEntries + [entry(6, gym, -4_500, day: 3)]
        let rows = forecast(entries)
        XCTAssertTrue(rows.hasUnassigned)
        XCTAssertEqual(rows.unassigned[12], -45_000)  // March's still expected + nine months
        let withMain = forecast(entries, main: joint)
        XCTAssertFalse(withMain.hasUnassigned)
        XCTAssertEqual(withMain.balance(accountId: joint, month: 12)?.gbpMinorUnits, -350_000 - 45_000)
    }

    /// Every month of every year, both Show forecast states: the account rows (actual
    /// month-ends where there's no forecast) plus the unassigned row sum to the Net Worth row.
    func testAccountRowsSumToTheNetWorthRow() {
        let plans: [(String, [ForecastEntry], Int64?)] = [
            ("base", baseEntries, nil),
            ("split rent, unassigned gym, euro, gift, reserve",
             baseEntries + [entry(4, rent, -30_000, day: 20, account: current), entry(6, gym, -4_500, day: 3), entry(7, rent, -10_000, day: 2, account: euro),
                            entry(8, gift, -7_000, day: 12, account: joint), entry(9, holiday, -20_000, day: 1), entry(10, toCurrent, -1_000, day: 9, account: euro)], nil),
            ("main account", baseEntries + [entry(6, gym, -4_500, day: 3)], joint),
        ]
        // Today in the walk-start month too, so it shows today's balance plus its remaining plan.
        for (name, entries, main) in plans + plans.map({ ("\($0.0) on 28 Mar", $0.1, $0.2) }) {
            let input = input(entries: entries, main: main, today: name.hasSuffix("28 Mar") ? utc(2026, 3, 28) : nil)
            let actuals = DashboardCalculator.netWorthActuals(input)
            let accounts = accounts(main: main)
            for includeForecast in [true, false] {
                for year in 2025...2028 {
                    let row = DashboardCalculator.budgetNetWorthMonths(input, actuals: actuals, year: year, includeForecast: includeForecast)
                    let rows = DashboardCalculator.budgetAccountForecast(input, actuals: actuals, itemAccounts: itemAccounts(main: main), year: year, includeForecast: includeForecast)
                    if name.hasSuffix("28 Mar"), year == 2026 { XCTAssertEqual(rows.isForecast(month: 3), includeForecast, name) }
                    for month in 1...12 {
                        let range = MonthRange.of(year: year, month: month)
                        var sum: Int?
                        for account in accounts {
                            let value = rows.balance(accountId: account.id!, month: month)?.gbpMinorUnits
                                ?? (rows.isForecast(month: month) || rows.blankMonths.contains(month) ? nil
                                    : NetWorthCalculator.monthlyBalance(account: account, snapshots: input.snapshots, transactions: input.transactions, rate: input.rate,
                                                                        monthStart: range.start, monthEnd: range.end)?.gbpBalanceMinorUnits)
                            if let value { sum = (sum ?? 0) + value }
                        }
                        if let unassigned = rows.unassigned[month] { sum = (sum ?? 0) + unassigned }
                        XCTAssertEqual(sum, row[month - 1], "\(name) forecast \(includeForecast) \(year)-\(month)")
                    }
                }
            }
        }
    }
}
