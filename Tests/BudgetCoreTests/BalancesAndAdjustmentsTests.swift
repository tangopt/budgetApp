import XCTest
import GRDB
@testable import BudgetCore
import struct BudgetCore.Category
import struct BudgetCore.Transaction
import TestSupport

/// Spec 2026-10-14 §1: balances from transactions, the built-in adjustment categories and
/// Update balance creating adjustment transactions.
final class BalancesAndAdjustmentsTests: XCTestCase {
    private func day(_ y: Int, _ m: Int, _ d: Int) -> Date {
        MonthRange.calendar.date(from: DateComponents(year: y, month: m, day: d))!
    }
    private func makeDB() throws -> DatabaseManager {
        return try TestDatabase.migratedManager()
    }
    private func txn(_ id: Int64, account: Int64, _ date: Date, _ amount: Int, category: Int64? = nil, isManual: Bool = false) -> Transaction {
        Transaction(id: id, importBatchId: 1, accountId: account, date: date, rawDescription: "T\(id)", amountMinorUnits: amount, categoryId: category,
                    status: .confirmed, categorizedBy: .manual, fingerprint: "fp\(id)", isManual: isManual)
    }
    private func addImported(_ db: Database, _ accountId: Int64, _ date: Date, _ amount: Int) throws {
        var batch = ImportBatch(accountId: accountId, sourceFileName: "statement.csv", importedAt: date)
        try batch.insert(db)
        var t = Transaction(importBatchId: batch.id!, accountId: accountId, date: date, rawDescription: "x", amountMinorUnits: amount, categoryId: nil,
                            status: .confirmed, categorizedBy: .none, fingerprint: UUID().uuidString)
        try t.insert(db)
    }
    private let rate = ExchangeRateSetting(eurToGbpRate: 0.87, updatedAt: Date())

    // MARK: Balance rule

    func testEveryAccountCountsTransactionsAfterItsOpeningBalanceWhateverItsTrackingMode() {
        for mode in AccountTrackingMode.allCases {
            let account = Account(id: 1, name: "A", currency: .gbp, kind: .investment, trackingMode: mode)
            let opening = BalanceSnapshot(id: 1, accountId: 1, date: day(2026, 1, 10), balanceMinorUnits: 100_000, note: nil)
            let transactions = [
                txn(1, account: 1, day(2026, 1, 5), -9_999),   // before the opening: ignored
                txn(2, account: 1, day(2026, 1, 10), -9_999),  // the opening day: already in the opening balance
                txn(3, account: 1, day(2026, 2, 3), -5_000),
                txn(4, account: 1, day(2026, 3, 3), 2_000, isManual: true),
                txn(5, account: 2, day(2026, 3, 3), 7_777),    // another account
            ]
            let now = NetWorthCalculator.accountBalances(accounts: [account], snapshots: [opening], transactions: transactions, rate: rate)
            XCTAssertEqual(now[0].nativeBalanceMinorUnits, 97_000, "\(mode)")
            let feb = MonthRange.of(year: 2026, month: 2)
            let february = NetWorthCalculator.monthlyBalance(account: account, snapshots: [opening], transactions: transactions, rate: rate, monthStart: feb.start, monthEnd: feb.end)
            XCTAssertEqual(february?.nativeBalanceMinorUnits, 95_000, "\(mode)")
            XCTAssertEqual(february?.isCarriedForward, false)
        }
    }

    func testBalanceAtADateUsesTheLatestSnapshotAtOrBeforeItThenTransactions() {
        let snapshots = [
            BalanceSnapshot(id: 1, accountId: 1, date: day(2026, 1, 1), balanceMinorUnits: 1_000, note: nil),
            BalanceSnapshot(id: 2, accountId: 1, date: day(2026, 3, 1), balanceMinorUnits: 5_000, note: nil),
        ]
        let transactions = [txn(1, account: 1, day(2026, 2, 1), 100), txn(2, account: 1, day(2026, 3, 2), 10)]
        XCTAssertNil(NetWorthCalculator.balance(accountId: 1, at: day(2025, 12, 31), snapshots: snapshots, transactions: transactions))
        XCTAssertEqual(NetWorthCalculator.balance(accountId: 1, at: day(2026, 2, 15), snapshots: snapshots, transactions: transactions)?.native, 1_100)
        XCTAssertEqual(NetWorthCalculator.balance(accountId: 1, at: day(2026, 3, 1), snapshots: snapshots, transactions: transactions)?.native, 5_000)
        XCTAssertEqual(NetWorthCalculator.balance(accountId: 1, at: nil, snapshots: snapshots, transactions: transactions)?.native, 5_010)
    }

    func testAnAccountWithoutAnOpeningBalanceStartsFromZero() {
        let account = Account(id: 1, name: "A", currency: .gbp, kind: .cash, trackingMode: .manual)
        let transactions = [txn(1, account: 1, day(2026, 2, 1), 300), txn(2, account: 1, day(2026, 3, 1), -100)]
        XCTAssertNil(NetWorthCalculator.balance(accountId: 1, at: day(2026, 1, 31), snapshots: [], transactions: transactions))
        let feb = MonthRange.of(year: 2026, month: 2)
        XCTAssertEqual(NetWorthCalculator.monthlyBalance(account: account, snapshots: [], transactions: transactions, rate: rate, monthStart: feb.start, monthEnd: feb.end)?.nativeBalanceMinorUnits, 300)
        XCTAssertEqual(NetWorthCalculator.monthEndNetWorth(accounts: [account], snapshots: [], transactions: transactions, rate: rate, year: 2026, month: 3), 200)
        XCTAssertNil(NetWorthCalculator.monthEndNetWorth(accounts: [account], snapshots: [], transactions: transactions, rate: rate, year: 2026, month: 1))
    }

    // MARK: Built-in categories

    func testMigrationCreatesTheTwoBuiltInAdjustmentCategories() throws {
        let m = try makeDB()
        let builtIn = try m.dbQueue.read { db in try Category.filter(Column("builtInRole") != nil).order(Column("name")).fetchAll(db) }
        XCTAssertEqual(builtIn.map(\.name), ["Balance adjustment", "Market movement"])
        XCTAssertEqual(builtIn.map(\.builtInRole), [.balanceAdjustment, .marketMovement])
        XCTAssertEqual(Set(builtIn.map(\.type)), [.adjustment])
        XCTAssertTrue(builtIn.allSatisfy { !$0.isAssignable && $0.isBuiltIn && !$0.isReserved && $0.groupId == nil })
        XCTAssertEqual(try m.dbQueue.read { db in try BuiltInCategories.category(db: db, role: .marketMovement).name }, "Market movement")
    }

    func testMigrationAdoptsAnExistingCategoryOfTheSameName() throws {
        let m = try DatabaseManager(path: nil)
        try m.migrate(upTo: "addTransactionIsManual")
        try m.dbQueue.write { db in
            try db.execute(sql: "INSERT INTO categoryGroup (name) VALUES ('Misc')")
            try db.execute(sql: "INSERT INTO category (name, type, groupId) VALUES ('market movement', 'income', 1)")
            try db.execute(sql: "INSERT INTO rule (matchPattern, matchType, categoryId, priority) SELECT 'X', 'contains', id, 0 FROM category WHERE name = 'market movement'")
        }
        try m.migrate()
        let adopted = try m.dbQueue.read { db in try BuiltInCategories.category(db: db, role: .marketMovement) }
        XCTAssertEqual(adopted.name, "market movement")
        XCTAssertEqual(adopted.type, .adjustment)
        XCTAssertNil(adopted.groupId)
        XCTAssertEqual(try m.dbQueue.read { db in try Rule.fetchCount(db) }, 0)
        XCTAssertEqual(try m.dbQueue.read { db in try Category.filter(Column("builtInRole") != nil).fetchCount(db) }, 2)
    }

    func testMigrationAdoptionClearsExternalTransferAndIsRefusedForPlannedLinkedOrReservedCategories() throws {
        // name → (setup SQL, expected built-in name, the original keeps its own row)
        let cases: [(String, String, String, Bool)] = [
            ("external", "INSERT INTO category (name, type, isExternalTransfer) VALUES ('Balance adjustment', 'transfer', 1)", "Balance adjustment", false),
            ("planned", """
                INSERT INTO category (name, type) VALUES ('Balance adjustment', 'expense');
                INSERT INTO forecastGroup (name, isEnabled, isSystemManaged) VALUES ('G', 1, 0);
                INSERT INTO forecastEntry (groupId, categoryId, amountMinorUnits, frequency, interval, startDate, isEnabled, status)
                    VALUES (1, (SELECT id FROM category WHERE name = 'Balance adjustment'), -100, 'monthly', 1, '2026-01-01', 1, 'manual');
                """, "Balance adjustment (built-in)", true),
            ("linked", """
                INSERT INTO category (name, type) VALUES ('Balance adjustment', 'transfer');
                INSERT INTO account (name, currency, kind, trackingMode) VALUES ('A', 'gbp', 'cash', 'imported'), ('B', 'gbp', 'cash', 'imported');
                INSERT INTO importBatch (accountId, sourceFileName, importedAt) VALUES (1, 'f', '2026-01-01');
                INSERT INTO transaction_ (importBatchId, accountId, date, rawDescription, amountMinorUnits, categoryId, status, categorizedBy, fingerprint)
                    VALUES (1, 1, '2026-01-01', 'out', -100, (SELECT id FROM category WHERE name = 'Balance adjustment'), 'confirmed', 'manual', 'a'),
                           (1, 2, '2026-01-01', 'in', 100, NULL, 'confirmed', 'manual', 'b');
                INSERT INTO transferLink (outTransactionId, inTransactionId, origin) VALUES (1, 2, 'manual');
                """, "Balance adjustment (built-in)", true),
            ("reserve", "INSERT INTO category (name, type, isReserved) VALUES ('Balance adjustment', 'expense', 1)", "Balance adjustment (built-in)", true),
        ]
        for (label, sql, expectedName, keepsOriginal) in cases {
            let m = try DatabaseManager(path: nil)
            try m.migrate(upTo: "addTransactionIsManual")
            try m.dbQueue.write { db in try db.execute(sql: sql) }
            try m.migrate()
            let builtIn = try m.dbQueue.read { db in try BuiltInCategories.category(db: db, role: .balanceAdjustment) }
            XCTAssertEqual(builtIn.name, expectedName, label)
            XCTAssertEqual(builtIn.type, .adjustment, label)
            XCTAssertFalse(builtIn.isExternalTransfer, label)
            XCTAssertFalse(builtIn.isReserved, label)
            let original = try m.dbQueue.read { db in try Category.filter(Column("name") == "Balance adjustment").fetchOne(db) }
            XCTAssertEqual(original != nil && original?.builtInRole == nil, keepsOriginal, label)
        }
    }

    func testBuiltInCategoriesCannotBeRenamedMovedOrDeleted() throws {
        let m = try makeDB()
        try m.dbQueue.write { db in
            let category = try BuiltInCategories.category(db: db, role: .balanceAdjustment)
            var group = CategoryGroup(name: "G")
            try group.insert(db)
            XCTAssertThrowsError(try Categories.rename(db: db, id: category.id!, name: "Fix")) { XCTAssertEqual($0 as? CategoryEditError, .builtIn(name: "Balance adjustment")) }
            XCTAssertThrowsError(try Categories.move(db: db, ids: [category.id!], toGroupId: group.id)) { XCTAssertEqual($0 as? CategoryEditError, .builtIn(name: "Balance adjustment")) }
            XCTAssertThrowsError(try Categories.delete(db: db, id: category.id!)) { XCTAssertEqual($0 as? CategoryEditError, .builtIn(name: "Balance adjustment")) }
            XCTAssertEqual(try Category.fetchOne(db, key: category.id!)?.name, "Balance adjustment")
            XCTAssertNil(try Category.fetchOne(db, key: category.id!)?.groupId)
        }
    }

    func testBuiltInCategoriesAreNotPickableAndShowReadOnlyUnderAdjustments() throws {
        let m = try makeDB()
        let categories = try m.dbQueue.read { db in try Category.fetchAll(db) }
        let builtInIds = Set(categories.filter(\.isBuiltIn).compactMap(\.id))
        let picker = CategoryPickerSections.build(categories: categories, groups: [], suggestedId: builtInIds.first, recentIds: Array(builtInIds),
                                                  amountMinorUnits: -100, query: "", showAll: true)
        let picked = Set(picker.flatMap(\.entries).compactMap { entry -> Int64? in if case .pick(let id) = entry.action { return id } else { return nil } })
        XCTAssertTrue(picked.isDisjoint(with: builtInIds))

        let sections = CategorySections.build(categories: categories, groups: [], search: "")
        XCTAssertEqual(sections.last?.type, .adjustment)
        XCTAssertEqual(sections.last?.ungrouped.map(\.name), ["Balance adjustment", "Market movement"])
        XCTAssertEqual(sections.last?.groups, [])
        XCTAssertEqual(CategorySections.build(categories: categories, groups: [], search: "market").map(\.type), [.adjustment])
        XCTAssertFalse(CategorySections.build(categories: categories.filter { !$0.isBuiltIn }, groups: [], search: "").contains { $0.type == .adjustment })
    }

    func testImportedTransactionsCantBeFiledIntoABuiltInCategoryByHand() throws {
        let m = try makeDB()
        try m.dbQueue.write { db in
            var account = Account(name: "A", currency: .gbp, kind: .cash, trackingMode: .imported)
            try account.insert(db)
            try addImported(db, account.id!, day(2026, 1, 1), -100)
            let transaction = try Transaction.fetchOne(db)!
            let category = try BuiltInCategories.category(db: db, role: .balanceAdjustment)
            XCTAssertThrowsError(try TransactionEditing.update(db: db, id: transaction.id!, categoryId: category.id, note: nil))
        }
    }

    func testAdjustmentsStayOutOfTheBudgetFlowsAndThePlanButCountInNetWorth() {
        let account = Account(id: 1, name: "ISA", currency: .gbp, kind: .investment, trackingMode: .manual)
        let categories = [Category(id: 1, name: "Salary", type: .income), Category(id: 2, name: "Market movement", type: .adjustment, builtInRole: .marketMovement)]
        let transactions = [txn(1, account: 1, day(2026, 1, 15), 1_000, category: 1), txn(2, account: 1, day(2026, 1, 20), 50_000, category: 2, isManual: true)]
        let period = PayPeriod(startDate: day(2026, 1, 1), endDate: day(2026, 1, 31), type: .actual)
        let summary = BudgetGridCalculator.periodSummary(period: period, categories: categories, transactions: transactions, forecastEntries: [], forecastGroups: [], exceptions: [])
        XCTAssertEqual(summary.incomeMinorUnits, 1_000)
        XCTAssertEqual(summary.expensesMinorUnits, 0)
        XCTAssertEqual(summary.transfersMinorUnits, 0)
        XCTAssertEqual(BudgetGridCalculator.categoryTotal(category: categories[1], period: period, transactions: transactions, forecastEntries: [], forecastGroups: [], exceptions: []), 50_000)

        let planned = PlanStatus.cell(actual: 50_000, planned: 20_000, categoryType: .adjustment, monthClass: .blended)
        XCTAssertEqual(planned.value, 50_000)
        XCTAssertEqual(planned.pending, 0)
        XCTAssertEqual(MonthBlend.projectedTotal(actual: 5, expected: 9, categoryType: .adjustment, monthClass: .blended), 5)

        let opening = BalanceSnapshot(id: 1, accountId: 1, date: day(2025, 12, 31), balanceMinorUnits: 100_000, note: nil)
        XCTAssertEqual(NetWorthCalculator.monthEndNetWorth(accounts: [account], snapshots: [opening], transactions: transactions, rate: rate, year: 2026, month: 1), 151_000)

        let entry = ForecastEntry(id: 1, groupId: 1, categoryId: 2, amountMinorUnits: 9_999, frequency: .monthly, interval: 1, startDate: day(2026, 1, 1), endDate: nil, isEnabled: true, status: .manual, note: nil)
        let group = ForecastGroup(id: 1, name: "G", note: nil, isEnabled: true, isSystemManaged: false)
        XCTAssertEqual(ForecastCalculator.confirmedNetWorthImpact(period: PayPeriod(startDate: day(2026, 2, 1), endDate: day(2026, 2, 28), type: .projected),
                                                                  categories: categories, entries: [entry], groups: [group], exceptions: []), 0)
    }

    func testDashboardFlowsLeaveAdjustmentsOut() {
        let account = Account(id: 1, name: "Cash", currency: .gbp, kind: .cash, trackingMode: .imported)
        let categories = [Category(id: 1, name: "Food", type: .expense), Category(id: 2, name: "Balance adjustment", type: .adjustment, builtInRole: .balanceAdjustment)]
        let transactions = [txn(1, account: 1, day(2026, 3, 5), -2_000, category: 1), txn(2, account: 1, day(2026, 3, 6), -70_000, category: 2, isManual: true)]
        let input = DashboardInput(today: day(2026, 3, 10), accounts: [account], snapshots: [], transactions: transactions, categories: categories, categoryGroups: [],
                                   forecastEntries: [], forecastGroups: [], exceptions: [], importBatches: [], rate: rate)
        let march = DashboardCalculator.monthlyFlows(input, year: 2026)[2]
        XCTAssertEqual(march.expenseActual, 2_000)
        XCTAssertEqual(march.incomeActual, 0)
        XCTAssertEqual(DashboardCalculator.currentMonth(input).expenses.actual, 2_000)
        XCTAssertEqual(DashboardCalculator.netWorthSeries(input).currentNetWorthMinorUnits, -72_000)
    }

    func testAutoForecastNeverPlansAnAdjustmentCategory() throws {
        let m = try makeDB()
        try m.dbQueue.write { db in
            var account = Account(name: "ISA", currency: .gbp, kind: .investment, trackingMode: .manual)
            try account.insert(db)
            let category = try BuiltInCategories.category(db: db, role: .marketMovement)
            for month in 1...6 {
                try ManualTransactions.add(db: db, accountId: account.id!, date: day(2026, month, 3), description: "Market movement", amountMinorUnits: 10_000, categoryId: category.id, note: nil, allowBuiltIn: true)
            }
            let periods = (1...6).map { month in
                let range = MonthRange.of(year: 2026, month: month)
                return PayPeriod(startDate: range.start, endDate: range.end, type: .actual)
            }
            try AutoForecastGenerator.regenerate(db: db, actualPeriods: periods)
            XCTAssertEqual(try ForecastEntry.filter(Column("categoryId") == category.id).fetchCount(db), 0)
        }
    }

    // MARK: Update balance

    func testUpdateBalanceAddsABalanceAdjustmentForTheDifferenceOnACashAccount() throws {
        let m = try makeDB()
        try m.dbQueue.write { db in
            let account = try AccountEditing.add(db: db, name: "Current", currency: .gbp, kind: .cash, openingBalanceEntered: 100_000, asOf: day(2026, 1, 1))
            try addImported(db, account.id!, day(2026, 1, 10), -30_000)
            try addImported(db, account.id!, day(2026, 1, 20), -5_000) // that day: counted
            try addImported(db, account.id!, day(2026, 1, 21), -1_000) // after: not counted
            XCTAssertEqual(try BalanceUpdates.computedBalance(db: db, accountId: account.id!, asOf: day(2026, 1, 20)), 65_000)
            let outcomes = try BalanceUpdates.save(db: db, entries: [.init(accountId: account.id!, enteredMinorUnits: 64_000, note: " checked app ")], asOf: day(2026, 1, 20))
            XCTAssertEqual(outcomes.map(\.differenceMinorUnits), [-1_000])
            XCTAssertEqual(outcomes.map(\.role), [.balanceAdjustment])
            let adjustment = try Transaction.fetchOne(db, key: outcomes[0].transactionId!)!
            XCTAssertEqual(adjustment.amountMinorUnits, -1_000)
            XCTAssertEqual(adjustment.date, day(2026, 1, 20))
            XCTAssertEqual(adjustment.categoryId, try BuiltInCategories.category(db: db, role: .balanceAdjustment).id)
            XCTAssertEqual(adjustment.rawDescription, "Balance adjustment")
            XCTAssertEqual(adjustment.note, "checked app")
            XCTAssertEqual(adjustment.status, .confirmed)
            XCTAssertTrue(adjustment.isManual)
            XCTAssertEqual(try ImportBatch.fetchOne(db, key: adjustment.importBatchId)?.sourceFileName, ManualTransactions.batchSourceFileName)
            XCTAssertEqual(try BalanceSnapshot.fetchCount(db), 1) // the opening balance only
            XCTAssertEqual(try BalanceUpdates.computedBalance(db: db, accountId: account.id!, asOf: day(2026, 1, 20)), 64_000)
        }
    }

    func testUpdateBalanceOnAnInvestmentAccountRecordsAMarketMovement() throws {
        let m = try makeDB()
        try m.dbQueue.write { db in
            let isa = try AccountEditing.add(db: db, name: "ISA", currency: .gbp, kind: .investment, openingBalanceEntered: 1_000_000, asOf: day(2026, 1, 1))
            let outcomes = try BalanceUpdates.save(db: db, entries: [.init(accountId: isa.id!, enteredMinorUnits: 1_050_000)], asOf: day(2026, 2, 1))
            XCTAssertEqual(outcomes.map(\.role), [.marketMovement])
            let adjustment = try Transaction.fetchOne(db, key: outcomes[0].transactionId!)!
            XCTAssertEqual(adjustment.amountMinorUnits, 50_000)
            XCTAssertEqual(adjustment.categoryId, try BuiltInCategories.category(db: db, role: .marketMovement).id)
            XCTAssertEqual(adjustment.rawDescription, "Market movement")
        }
    }

    func testUpdateBalanceOnACreditCardSignsTheAmountOwed() throws {
        let m = try makeDB()
        try m.dbQueue.write { db in
            let card = try AccountEditing.add(db: db, name: "Card", currency: .gbp, kind: .credit, openingBalanceEntered: 30_000, asOf: day(2026, 1, 1))
            // £350 owed now: £50 more owed → -5,000.
            let outcomes = try BalanceUpdates.save(db: db, entries: [.init(accountId: card.id!, enteredMinorUnits: 35_000)], asOf: day(2026, 1, 5))
            XCTAssertEqual(outcomes.map(\.differenceMinorUnits), [-5_000])
            XCTAssertEqual(outcomes.map(\.role), [.balanceAdjustment])
        }
    }

    func testAMatchingBalanceWritesNothing() throws {
        let m = try makeDB()
        try m.dbQueue.write { db in
            let account = try AccountEditing.add(db: db, name: "Current", currency: .eur, kind: .cash, openingBalanceEntered: 100, asOf: day(2026, 1, 1))
            let outcomes = try BalanceUpdates.save(db: db, entries: [.init(accountId: account.id!, enteredMinorUnits: 100)], asOf: day(2026, 1, 9))
            XCTAssertEqual(outcomes, [BalanceUpdates.Outcome(accountId: account.id!, accountName: "Current", currency: .eur, differenceMinorUnits: 0, role: nil, transactionId: nil)])
            XCTAssertEqual(try Transaction.fetchCount(db), 0)
            XCTAssertEqual(try BalanceSnapshot.fetchCount(db), 1)
        }
    }

    func testBulkUpdateAdjustsEachAccountByItsKind() throws {
        let m = try makeDB()
        try m.dbQueue.write { db in
            let cash = try AccountEditing.add(db: db, name: "Cash", currency: .gbp, kind: .cash, openingBalanceEntered: 1_000, asOf: day(2026, 1, 1))
            let isa = try AccountEditing.add(db: db, name: "ISA", currency: .gbp, kind: .investment, openingBalanceEntered: 2_000, asOf: day(2026, 1, 1))
            let same = try AccountEditing.add(db: db, name: "Same", currency: .gbp, kind: .cash, openingBalanceEntered: 3_000, asOf: day(2026, 1, 1))
            let outcomes = try BalanceUpdates.save(db: db, entries: [.init(accountId: cash.id!, enteredMinorUnits: 900), .init(accountId: isa.id!, enteredMinorUnits: 2_500),
                                                                     .init(accountId: same.id!, enteredMinorUnits: 3_000)], asOf: day(2026, 3, 1))
            XCTAssertEqual(outcomes.map(\.differenceMinorUnits), [-100, 500, 0])
            XCTAssertEqual(outcomes.map(\.role), [.balanceAdjustment, .marketMovement, nil])
            XCTAssertEqual(try Transaction.fetchCount(db), 2)
        }
    }

    func testAnAccountWithoutAnOpeningBalanceIsAdjustedFromZero() throws {
        let m = try makeDB()
        try m.dbQueue.write { db in
            let account = try AccountEditing.add(db: db, name: "Wallet", currency: .gbp, kind: .cash, openingBalanceEntered: nil, asOf: day(2026, 1, 1))
            try addImported(db, account.id!, day(2026, 1, 3), 500)
            let outcomes = try BalanceUpdates.save(db: db, entries: [.init(accountId: account.id!, enteredMinorUnits: 800)], asOf: day(2026, 1, 4))
            XCTAssertEqual(outcomes.map(\.differenceMinorUnits), [300])
        }
    }

    func testUpdateBalanceMustBeDatedAfterEveryRecordedBalanceFromThatDayOn() throws {
        let m = try makeDB()
        try m.dbQueue.write { db in
            let account = try AccountEditing.add(db: db, name: "Current", currency: .gbp, kind: .cash, openingBalanceEntered: 100, asOf: day(2026, 1, 10))
            // A later recorded balance (legacy statement snapshot) blocks every day up to it.
            try BalanceUpdates.upsertSnapshot(db: db, accountId: account.id!, date: day(2026, 3, 1), balanceMinorUnits: 500, note: nil)
            for (date, blocking) in [(day(2026, 1, 9), day(2026, 1, 10)), (day(2026, 1, 10), day(2026, 1, 10)), (day(2026, 2, 1), day(2026, 3, 1)), (day(2026, 3, 1), day(2026, 3, 1))] {
                XCTAssertEqual(try BalanceUpdates.blockingBalanceDate(db: db, accountId: account.id!, asOf: date), blocking)
                XCTAssertThrowsError(try BalanceUpdates.save(db: db, entries: [.init(accountId: account.id!, enteredMinorUnits: 200)], asOf: date)) {
                    XCTAssertEqual($0 as? BalanceUpdateError, .recordedBalance(accountName: "Current", date: blocking))
                    XCTAssertEqual($0.localizedDescription, "Current: there's a recorded balance on \(blocking == day(2026, 1, 10) ? "10 Jan 2026" : "1 Mar 2026") — pick a later date.")
                }
            }
            XCTAssertNil(try BalanceUpdates.blockingBalanceDate(db: db, accountId: account.id!, asOf: day(2026, 3, 2)))
            XCTAssertEqual(try BalanceUpdates.save(db: db, entries: [.init(accountId: account.id!, enteredMinorUnits: 200)], asOf: day(2026, 3, 2)).map(\.differenceMinorUnits), [-300])
        }
    }

    func testManualEntriesCantBeFiledIntoBuiltInCategoriesByHand() throws {
        let m = try makeDB()
        try m.dbQueue.write { db in
            let account = try AccountEditing.add(db: db, name: "Current", currency: .gbp, kind: .cash, openingBalanceEntered: 1_000, asOf: day(2026, 1, 1))
            let builtIn = try BuiltInCategories.category(db: db, role: .balanceAdjustment)
            XCTAssertThrowsError(try ManualTransactions.add(db: db, accountId: account.id!, date: day(2026, 1, 5), description: "x", amountMinorUnits: -1, categoryId: builtIn.id, note: nil)) {
                XCTAssertEqual($0 as? ManualTransactionError, .reservedCategory)
            }
            let other = try ManualTransactions.add(db: db, accountId: account.id!, date: day(2026, 1, 5), description: "x", amountMinorUnits: -1, categoryId: nil, note: nil)
            XCTAssertThrowsError(try ManualTransactions.update(db: db, id: other.id!, date: day(2026, 1, 5), description: "x", amountMinorUnits: -1, accountId: account.id!, categoryId: builtIn.id, note: nil)) {
                XCTAssertEqual($0 as? ManualTransactionError, .reservedCategory)
            }
            // An adjustment itself can still be edited (its category kept).
            let outcome = try BalanceUpdates.save(db: db, entries: [.init(accountId: account.id!, enteredMinorUnits: 900)], asOf: day(2026, 1, 10))[0]
            try ManualTransactions.update(db: db, id: outcome.transactionId!, date: day(2026, 1, 10), description: "Balance adjustment", amountMinorUnits: -99,
                                          accountId: account.id!, categoryId: builtIn.id, note: "fixed")
            XCTAssertEqual(try Transaction.fetchOne(db, key: outcome.transactionId!)?.note, "fixed")
        }
    }

    func testAnImportedRowNeverReplacesAnAdjustment() throws {
        let m = try makeDB()
        try m.dbQueue.write { db in
            let account = try AccountEditing.add(db: db, name: "Current", currency: .gbp, kind: .cash, openingBalanceEntered: 1_000, asOf: day(2026, 1, 1))
            _ = try BalanceUpdates.save(db: db, entries: [.init(accountId: account.id!, enteredMinorUnits: 900)], asOf: day(2026, 1, 10))
            let replacements = try ManualTransactions.stagedReplacements(db: db, accountId: account.id!, staged: [(date: day(2026, 1, 11), amountMinorUnits: -100)])
            XCTAssertTrue(replacements.isEmpty)
        }
    }

    func testAnAdjustmentIsNeverMatchedAsATransferLeg() throws {
        let m = try makeDB()
        try m.dbQueue.write { db in
            let current = try AccountEditing.add(db: db, name: "Current", currency: .gbp, kind: .cash, openingBalanceEntered: 1_000, asOf: day(2026, 1, 1))
            let savings = try AccountEditing.add(db: db, name: "Savings", currency: .gbp, kind: .cash, openingBalanceEntered: 1_000, asOf: day(2026, 1, 1))
            _ = try BalanceUpdates.save(db: db, entries: [.init(accountId: savings.id!, enteredMinorUnits: 1_500)], asOf: day(2026, 1, 10))
            try addImported(db, current.id!, day(2026, 1, 10), -500)
            XCTAssertEqual(try TransferMatcher.match(db: db, today: day(2026, 1, 20)), 0)
        }
    }

    func testUnknownAccountThrowsAndRollsBack() throws {
        let m = try makeDB()
        var id: Int64 = 0
        try m.dbQueue.write { db in
            id = try AccountEditing.add(db: db, name: "A", currency: .gbp, kind: .cash, openingBalanceEntered: nil, asOf: Date()).id!
        }
        XCTAssertThrowsError(try m.dbQueue.write { db in
            _ = try BalanceUpdates.save(db: db, entries: [.init(accountId: id, enteredMinorUnits: 1), .init(accountId: 999, enteredMinorUnits: 1)], asOf: Date())
        }) { XCTAssertEqual($0 as? AccountEditError, .accountNotFound) }
        XCTAssertEqual(try m.dbQueue.read { try Transaction.fetchCount($0) }, 0)
    }

    // MARK: Staleness

    func testOnlyInvestmentsAndAccountsNeverImportedIntoGoStaleMeasuredByLastActivity() {
        let today = day(2026, 6, 1)
        let cashImported = Account(id: 1, name: "Current", currency: .gbp, kind: .cash, trackingMode: .manual)
        let cashManual = Account(id: 2, name: "Wallet", currency: .gbp, kind: .cash, trackingMode: .imported)
        let isa = Account(id: 3, name: "ISA", currency: .gbp, kind: .investment, trackingMode: .imported)
        let old = day(2026, 3, 1)
        let snapshots = [BalanceSnapshot(id: 1, accountId: 3, date: old, balanceMinorUnits: 1, note: nil)]
        let transactions = [txn(1, account: 1, old, -1), txn(2, account: 2, old, -1, isManual: true), txn(3, account: 3, old, -1)]
        XCTAssertFalse(BalanceStaleness.isStale(account: cashImported, snapshots: snapshots, transactions: transactions, today: today))
        XCTAssertTrue(BalanceStaleness.isStale(account: cashManual, snapshots: snapshots, transactions: transactions, today: today))
        XCTAssertTrue(BalanceStaleness.isStale(account: isa, snapshots: snapshots, transactions: transactions, today: today))
        // A recent market movement keeps the ISA current.
        let moved = transactions + [txn(4, account: 3, day(2026, 5, 20), 100, isManual: true)]
        XCTAssertFalse(BalanceStaleness.isStale(account: isa, snapshots: snapshots, transactions: moved, today: today))
        XCTAssertEqual(BalanceStaleness.lastActivity(accountId: 3, snapshots: snapshots, transactions: moved, today: today), day(2026, 5, 20))
    }
}
