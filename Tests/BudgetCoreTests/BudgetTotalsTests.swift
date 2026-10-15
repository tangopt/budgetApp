// Tests/BudgetCoreTests/BudgetTotalsTests.swift
import XCTest
import GRDB
@testable import BudgetCore
import struct BudgetCore.Category

/// Spec 2026-10-15 budget-totals-and-unassigned: the Totals block (§1) and assigning
/// unassigned planned items (§2).
final class BudgetTotalsTests: XCTestCase {
    private func utc(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        return cal.date(from: DateComponents(year: y, month: m, day: d))!
    }

    // Accounts: Current (1), Joint (2). Categories: Salary (1), Rent (2), "Transfer: Joint" (3,
    // tied to Joint), "Transfer: Current" (4, tied to Current), Gift (5, external), Holiday (6,
    // reserve), Market movement (7, adjustment), Savings move (8, untied transfer).
    private let current: Int64 = 1, joint: Int64 = 2
    private let salary: Int64 = 1, rent: Int64 = 2, toJoint: Int64 = 3, toCurrent: Int64 = 4, gift: Int64 = 5, holiday: Int64 = 6, market: Int64 = 7, savings: Int64 = 8

    private var categories: [Category] {
        [Category(id: salary, name: "Salary", type: .income),
         Category(id: rent, name: "Rent", type: .expense),
         Category(id: toJoint, name: "Transfer: Joint", type: .transfer, transferAccountId: joint),
         Category(id: toCurrent, name: "Transfer: Current", type: .transfer, transferAccountId: current),
         Category(id: gift, name: "Gift", type: .transfer, isExternalTransfer: true),
         Category(id: holiday, name: "Holiday", type: .expense, isReserved: true),
         Category(id: market, name: "Market movement", type: .adjustment),
         Category(id: savings, name: "Savings move", type: .transfer)]
    }
    private func category(_ id: Int64) -> Category { categories.first { $0.id == id }! }

    private func txn(_ id: Int64, _ account: Int64, _ date: Date, _ amount: Int, _ category: Int64?) -> Transaction {
        Transaction(id: id, importBatchId: 1, accountId: account, date: date, rawDescription: "T\(id)", amountMinorUnits: amount, categoryId: category, status: .confirmed, categorizedBy: .manual, fingerprint: "fp\(id)")
    }

    private let none: BudgetTotals.Cell = (0, 0, .none)

    private func assertCell(_ cell: BudgetTotals.Cell, _ value: Int, _ pending: Int, _ state: PendingState, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(cell.value, value, "value", file: file, line: line)
        XCTAssertEqual(cell.pending, pending, "pending", file: file, line: line)
        XCTAssertEqual(cell.state, state, "state", file: file, line: line)
    }

    // MARK: Rows

    func testCollapsedShowsOnlyNet() {
        XCTAssertEqual(BudgetTotals.Row.visible(collapsed: false), [.totalIn, .totalOut, .net])
        XCTAssertEqual(BudgetTotals.Row.visible(collapsed: true), [.net])
    }

    func testRowsIncludeIncomeExpensesAndCountedTransfersByDirection() {
        let income = category(salary), expense = category(rent), external = category(gift), adjustment = category(market), reserve = category(holiday)
        XCTAssertTrue(BudgetTotals.Row.totalIn.includes(income, amount: 100, countedTransfer: false))
        XCTAssertFalse(BudgetTotals.Row.totalOut.includes(income, amount: 100, countedTransfer: false))
        XCTAssertTrue(BudgetTotals.Row.totalOut.includes(expense, amount: -100, countedTransfer: false))
        XCTAssertTrue(BudgetTotals.Row.totalOut.includes(reserve, amount: -100, countedTransfer: false))
        XCTAssertTrue(BudgetTotals.Row.net.includes(expense, amount: 20, countedTransfer: false))
        XCTAssertTrue(BudgetTotals.Row.totalIn.includes(external, amount: 100, countedTransfer: true))
        XCTAssertFalse(BudgetTotals.Row.totalIn.includes(external, amount: -100, countedTransfer: true))
        XCTAssertTrue(BudgetTotals.Row.totalOut.includes(external, amount: -100, countedTransfer: true))
        XCTAssertFalse(BudgetTotals.Row.net.includes(category(toJoint), amount: -100, countedTransfer: false))
        for row in BudgetTotals.Row.allCases { XCTAssertFalse(row.includes(adjustment, amount: 100, countedTransfer: true)) }
    }

    // MARK: Which transfers count

    func testPlannedTransfersCountWhenExternalOrCrossingTheSelection() {
        XCTAssertTrue(BudgetTotals.countsPlannedTransfer(category(gift), accountIds: nil))
        XCTAssertFalse(BudgetTotals.countsPlannedTransfer(category(toJoint), accountIds: nil))
        XCTAssertTrue(BudgetTotals.countsPlannedTransfer(category(toJoint), accountIds: [current]))
        XCTAssertFalse(BudgetTotals.countsPlannedTransfer(category(toJoint), accountIds: [current, joint]))
        XCTAssertFalse(BudgetTotals.countsPlannedTransfer(category(savings), accountIds: [current]))
        XCTAssertFalse(BudgetTotals.countsPlannedTransfer(category(salary), accountIds: nil))
    }

    func testCounterpartAccountsFollowActiveLinks() {
        let transactions = [txn(1, current, utc(2026, 10, 5), -50_000, toJoint), txn(2, joint, utc(2026, 10, 5), 50_000, toCurrent),
                            txn(3, current, utc(2026, 10, 6), -1_000, savings), txn(4, joint, utc(2026, 10, 6), 1_000, savings)]
        let links = [TransferLink(id: 1, outTransactionId: 1, inTransactionId: 2, origin: .auto),
                     TransferLink(id: 2, outTransactionId: 3, inTransactionId: 4, origin: .auto, isDismissed: true)]
        XCTAssertEqual(BudgetTotals.counterpartAccounts(transactions: transactions, links: links), [1: [joint], 2: [current]])
    }

    func testTransactionTransfersCountOnlyAcrossTheSelection() {
        let out = txn(1, current, utc(2026, 10, 5), -50_000, toJoint)
        let incoming = txn(2, joint, utc(2026, 10, 5), 50_000, toCurrent)
        let gift = txn(3, current, utc(2026, 10, 7), 20_000, gift)
        let untied = txn(4, current, utc(2026, 10, 8), -1_000, savings)
        let rent = txn(5, current, utc(2026, 10, 1), -100_000, rent)
        // All accounts: only external transfers.
        XCTAssertTrue(BudgetTotals.countsTransfer(gift, category: category(self.gift), accountIds: nil, counterpartAccounts: nil))
        XCTAssertFalse(BudgetTotals.countsTransfer(out, category: category(toJoint), accountIds: nil, counterpartAccounts: [joint]))
        XCTAssertFalse(BudgetTotals.countsTransfer(rent, category: category(self.rent), accountIds: nil, counterpartAccounts: nil))
        // Current only: the linked out leg leaves the selection; Joint only: the in leg arrives.
        XCTAssertTrue(BudgetTotals.countsTransfer(out, category: category(toJoint), accountIds: [current], counterpartAccounts: [joint]))
        XCTAssertTrue(BudgetTotals.countsTransfer(incoming, category: category(toCurrent), accountIds: [joint], counterpartAccounts: [current]))
        // Both selected: within the selection.
        XCTAssertFalse(BudgetTotals.countsTransfer(out, category: category(toJoint), accountIds: [current, joint], counterpartAccounts: [joint]))
        // Unlinked: by the tied account; an untied one never.
        XCTAssertTrue(BudgetTotals.countsTransfer(out, category: category(toJoint), accountIds: [current], counterpartAccounts: nil))
        XCTAssertFalse(BudgetTotals.countsTransfer(out, category: category(toJoint), accountIds: [current, joint], counterpartAccounts: nil))
        XCTAssertFalse(BudgetTotals.countsTransfer(untied, category: category(savings), accountIds: [current], counterpartAccounts: nil))
        // A linked untied transfer counts by its other leg.
        XCTAssertTrue(BudgetTotals.countsTransfer(untied, category: category(savings), accountIds: [current], counterpartAccounts: [joint]))
    }

    func testCountedTransfersAndTheirMonthlyFlows() {
        let all = [txn(1, current, utc(2026, 10, 5), -50_000, toJoint), txn(2, joint, utc(2026, 10, 5), 50_000, toCurrent),
                   txn(3, current, utc(2026, 10, 7), 20_000, gift), txn(4, current, utc(2026, 10, 9), -5_000, gift),
                   txn(5, current, utc(2026, 10, 1), -100_000, rent)]
        let links = [TransferLink(id: 1, outTransactionId: 1, inTransactionId: 2, origin: .auto)]
        let counterparts = BudgetTotals.counterpartAccounts(transactions: all, links: links)
        let calendar = PayCalendar(salaryDates: [], manualCloses: [], today: utc(2026, 10, 15))

        // All accounts (the in leg is hidden by budgetFacing): the gifts only.
        let shownAll = TransferLinks.budgetFacing(all, links: links)
        let countedAll = BudgetTotals.countedTransfers(shownAll, categories: categories, accountIds: nil, counterpartAccounts: counterparts)
        XCTAssertEqual(countedAll.compactMap(\.id), [3, 4])
        let month = calendar.month(containing: utc(2026, 10, 7))
        XCTAssertEqual(BudgetTotals.transferActuals(countedAll, calendar: calendar)[gift]?[month.year]?[month.month], BudgetTotals.Flow(incoming: 20_000, outgoing: -5_000))

        // Joint only: the in leg arrives from Current.
        let shownJoint = TransferLinks.budgetFacing(all, links: links, accountIds: [joint])
        XCTAssertEqual(BudgetTotals.countedTransfers(shownJoint, categories: categories, accountIds: [joint], counterpartAccounts: counterparts).compactMap(\.id), [2])
        // Both: the out leg stays (as sent) but nets to zero within the selection.
        let shownBoth = TransferLinks.budgetFacing(all, links: links, accountIds: [current, joint])
        XCTAssertEqual(BudgetTotals.countedTransfers(shownBoth, categories: categories, accountIds: [current, joint], counterpartAccounts: counterparts).compactMap(\.id), [3, 4])
    }

    // MARK: A month

    private let planned: [Int64: Int] = [1: 300_000, 2: -100_000, 3: -50_000, 5: 20_000, 6: -10_000, 7: 999]

    func testFutureMonthIsAllExpectedAndLeavesOwnTransfersOut() {
        let reserves: BudgetTotals.Cell = (-10_000, -10_000, .allExpected)
        let totals = BudgetTotals.month(categories: categories, actuals: [:], transferActuals: [:], planned: planned, reserves: reserves,
                                        monthClass: .forecast, includeForecast: true, accountIds: nil)
        assertCell(totals.totalIn, 320_000, 320_000, .allExpected)
        assertCell(totals.totalOut, -110_000, -110_000, .allExpected)
        assertCell(BudgetTotals.cell(.net, totalIn: totals.totalIn, totalOut: totals.totalOut), 210_000, 210_000, .allExpected)
    }

    func testOpenMonthBlendsActualsWithWhatThePlanStillExpects() {
        // Salary in full, half the rent, a gift received and a gift given (both external).
        let actuals: [Int64: Int] = [salary: 300_000, rent: -50_000, market: 12_345]
        let flows: [Int64: BudgetTotals.Flow] = [gift: BudgetTotals.Flow(incoming: 5_000, outgoing: -2_000)]
        let totals = BudgetTotals.month(categories: categories, actuals: actuals, transferActuals: flows, planned: planned, reserves: (-4_000, -4_000, .allExpected),
                                        monthClass: .blended, includeForecast: true, accountIds: nil)
        // In: salary 300k + gift received 5k + the gift plan's 17k still expected (20k planned, 3k net so far).
        assertCell(totals.totalIn, 322_000, 17_000, .partial)
        // Out: rent 50k + 50k pending, the gift given 2k, reserves 4k.
        assertCell(totals.totalOut, -106_000, -54_000, .partial)
    }

    func testShowForecastOffIsActualsOnly() {
        let actuals: [Int64: Int] = [salary: 300_000, rent: -50_000]
        let flows: [Int64: BudgetTotals.Flow] = [gift: BudgetTotals.Flow(incoming: 5_000)]
        let totals = BudgetTotals.month(categories: categories, actuals: actuals, transferActuals: flows, planned: planned, reserves: none,
                                        monthClass: .blended, includeForecast: false, accountIds: nil)
        assertCell(totals.totalIn, 305_000, 0, .none)
        assertCell(totals.totalOut, -50_000, 0, .none)
    }

    func testClosedMonthIsActualsOnly() {
        let totals = BudgetTotals.month(categories: categories, actuals: [salary: 290_000], transferActuals: [:], planned: planned, reserves: none,
                                        monthClass: .actual, includeForecast: true, accountIds: nil)
        assertCell(totals.totalIn, 290_000, 0, .none)
        assertCell(totals.totalOut, 0, 0, .none)
    }

    func testFilterCountsPlannedTransfersLeavingTheSelection() {
        // Current only: the planned £500 to Joint leaves the selection.
        let current = BudgetTotals.month(categories: categories, actuals: [:], transferActuals: [:], planned: planned, reserves: none,
                                         monthClass: .forecast, includeForecast: true, accountIds: [self.current])
        assertCell(current.totalOut, -150_000, -150_000, .allExpected)
        // Joint only: the incoming leg is filed under "Transfer: Current" (tied to the unselected Current).
        let joint = BudgetTotals.month(categories: categories, actuals: [:], transferActuals: [:], planned: [toCurrent: 50_000], reserves: none,
                                       monthClass: .forecast, includeForecast: true, accountIds: [self.joint])
        assertCell(joint.totalIn, 50_000, 50_000, .allExpected)
        // Both: within the selection.
        let both = BudgetTotals.month(categories: categories, actuals: [:], transferActuals: [:], planned: planned, reserves: none,
                                      monthClass: .forecast, includeForecast: true, accountIds: [self.current, self.joint])
        assertCell(both.totalOut, -100_000, -100_000, .allExpected)
    }

    func testFilterSplitsCountedTransferActualsByDirection() {
        // Current only, £300 of the planned £500 to Joint sent so far.
        let flows: [Int64: BudgetTotals.Flow] = [toJoint: BudgetTotals.Flow(outgoing: -30_000)]
        let totals = BudgetTotals.month(categories: categories, actuals: [:], transferActuals: flows, planned: [toJoint: -50_000], reserves: none,
                                        monthClass: .blended, includeForecast: true, accountIds: [current])
        assertCell(totals.totalOut, -50_000, -20_000, .partial)
        assertCell(totals.totalIn, 0, 0, .none)
    }

    // MARK: Unassigned planned items (§2)

    private let groups = [ForecastGroup(id: 1, name: "Planned", note: nil, isEnabled: true, isSystemManaged: false)]
    private func entry(_ id: Int64, _ category: Int64, _ amount: Int, account: Int64? = nil) -> ForecastEntry {
        ForecastEntry(id: id, groupId: 1, categoryId: category, amountMinorUnits: amount, frequency: .monthly, interval: 1, startDate: utc(2026, 1, 10), endDate: nil,
                      isEnabled: true, status: .confirmed, note: nil, accountId: account)
    }
    private var november: PayPeriod { PayPeriod(startDate: utc(2026, 11, 1), endDate: MonthRange.of(year: 2026, month: 11).end, type: .projected) }

    func testUnassignedOccurrencesAreTheNetWorthImpactWithNoAccount() {
        // No history and no main account: only Rent (explicit Current) has an account.
        let itemAccounts = PlannedItemAccounts(inferredByCategory: [:], categories: categories)
        let entries = [entry(1, salary, 300_000), entry(2, rent, -100_000, account: current), entry(3, gift, 20_000), entry(4, toJoint, -50_000), entry(5, savings, -1_000)]
        let unassigned = ForecastCalculator.unassignedOccurrences(period: november, categories: categories, entries: entries, groups: groups, exceptions: [], itemAccounts: itemAccounts)
        // Salary, Gift and the tied transfer (net worth moves out of nowhere into Joint); not the untied one.
        XCTAssertEqual(unassigned.map(\.entryId), [1, 3, 4])
        let impact = ForecastCalculator.netWorthImpactByAccount(period: november, categories: categories, entries: entries, groups: groups, exceptions: [], itemAccounts: itemAccounts)
        XCTAssertEqual(unassigned.reduce(0) { $0 + $1.amountMinorUnits }, impact[nil])
    }

    private func manager() throws -> DatabaseManager {
        let manager = try DatabaseManager(path: nil)
        try manager.migrate()
        return manager
    }

    /// Two unassigned series (Salary, Gym) and the database's ids.
    private func seedUnassigned(_ db: Database) throws -> (accountId: Int64, salaryEntry: Int64, gymEntry: Int64, categories: [Category]) {
        var account = Account(name: "Current", currency: .gbp, kind: .cash, trackingMode: .imported)
        try account.insert(db)
        var salary = Category(name: "Salary", type: .income)
        try salary.insert(db)
        var gym = Category(name: "Gym", type: .expense)
        try gym.insert(db)
        let first = try PlannedItems.add(db: db, categoryId: salary.id!, amountMinorUnits: 300_000, frequency: .monthly, interval: 1, startDate: utc(2026, 1, 25), endDate: nil)
        let second = try PlannedItems.add(db: db, categoryId: gym.id!, amountMinorUnits: -4_500, frequency: .monthly, interval: 1, startDate: utc(2026, 1, 3), endDate: nil)
        return (account.id!, first.id!, second.id!, [salary, gym])
    }

    private func impact(_ db: Database, categories: [Category]) throws -> [Int64?: Int] {
        ForecastCalculator.netWorthImpactByAccount(period: november, categories: categories, entries: try ForecastEntry.fetchAll(db), groups: try ForecastGroup.fetchAll(db),
                                                   exceptions: [], itemAccounts: PlannedItemAccounts(inferredByCategory: [:], categories: categories))
    }

    func testAssigningMovesTheAmountFromUnassignedToTheAccount() throws {
        try manager().dbQueue.write { db in
            let seed = try seedUnassigned(db)
            let before = try impact(db, categories: seed.categories)
            XCTAssertEqual(before, [nil: 295_500])

            try PlannedItems.assignAccount(db: db, entryIds: [seed.salaryEntry], accountId: seed.accountId)

            let after = try impact(db, categories: seed.categories)
            XCTAssertEqual(after, [seed.accountId: 300_000, nil: -4_500])
            XCTAssertEqual(after.values.reduce(0, +), before.values.reduce(0, +), "the sum (net worth) is unchanged")
            // The whole series, not split.
            let stored = try ForecastEntry.fetchOne(db, key: seed.salaryEntry)
            XCTAssertEqual(stored?.accountId, seed.accountId)
            XCTAssertEqual(stored?.startDate, utc(2026, 1, 25))
            XCTAssertEqual(try ForecastEntry.fetchCount(db), 2)
        }
    }

    func testAssignAllInOneWrite() throws {
        let dbQueue = try manager().dbQueue
        let seed = try dbQueue.write { db in try seedUnassigned(db) }
        try dbQueue.write { db in try PlannedItems.assignAccount(db: db, entryIds: [seed.salaryEntry, seed.gymEntry], accountId: seed.accountId) }
        try dbQueue.read { db in
            XCTAssertEqual(try impact(db, categories: seed.categories), [seed.accountId: 295_500])
        }
    }

    func testAssignWithAnUnknownItemSavesNothing() throws {
        let dbQueue = try manager().dbQueue
        let seed = try dbQueue.write { db in try seedUnassigned(db) }
        XCTAssertThrowsError(try dbQueue.write { db in try PlannedItems.assignAccount(db: db, entryIds: [seed.salaryEntry, 9_999], accountId: seed.accountId) }) { error in
            XCTAssertEqual(error as? PlannedItemEditError, .notFound)
        }
        try dbQueue.read { db in
            XCTAssertNil(try ForecastEntry.fetchOne(db, key: seed.salaryEntry)?.accountId)
        }
    }
}
