import XCTest
import GRDB
@testable import BudgetCore
import struct BudgetCore.Category
import struct BudgetCore.Transaction

/// Spec 2026-10-14 §3: converting recorded balances into an opening balance plus adjustments,
/// and the Accounts screen's computed history.
final class BalanceConversionTests: XCTestCase {
    private let now = MonthRange.calendar.date(from: DateComponents(year: 2026, month: 10, day: 15, hour: 9))!

    private func day(_ y: Int, _ m: Int, _ d: Int) -> Date {
        MonthRange.calendar.date(from: DateComponents(year: y, month: m, day: d))!
    }
    private func makeDB() throws -> DatabaseManager {
        let m = try DatabaseManager(path: nil)
        try m.migrate()
        return m
    }
    @discardableResult
    private func addAccount(_ db: Database, _ name: String, kind: AccountKind = .cash) throws -> Int64 {
        var account = Account(name: name, currency: .gbp, kind: kind, trackingMode: .manual)
        try account.insert(db)
        return account.id!
    }
    private func addSnapshot(_ db: Database, _ accountId: Int64, _ date: Date, _ balance: Int) throws {
        var snapshot = BalanceSnapshot(accountId: accountId, date: date, balanceMinorUnits: balance, note: "Numbers import")
        try snapshot.insert(db)
    }
    private func addImported(_ db: Database, _ accountId: Int64, _ date: Date, _ amount: Int) throws {
        var batch = ImportBatch(accountId: accountId, sourceFileName: "statement.csv", importedAt: date)
        try batch.insert(db)
        var t = Transaction(importBatchId: batch.id!, accountId: accountId, date: date, rawDescription: "x", amountMinorUnits: amount, categoryId: nil,
                            status: .confirmed, categorizedBy: .none, fingerprint: UUID().uuidString)
        try t.insert(db)
    }
    private func balance(_ db: Database, _ accountId: Int64, at date: Date?) throws -> Int? {
        NetWorthCalculator.balance(accountId: accountId, at: date, snapshots: try BalanceSnapshot.fetchAll(db), transactions: try Transaction.fetchAll(db))?.native
    }
    private func adjustments(_ db: Database, _ accountId: Int64) throws -> [Transaction] {
        try Transaction.filter(Column("accountId") == accountId && Column("note") == BalanceConversion.adjustmentNote).order(Column("date")).fetchAll(db)
    }

    /// (a) The spreadsheet's shape: a balance on the 1st of each month, aggregate transactions on the 15th.
    private func spreadsheetAccount(_ db: Database) throws -> Int64 {
        let id = try addAccount(db, "Lloyds")
        try addSnapshot(db, id, day(2025, 1, 1), 100_000)
        try addImported(db, id, day(2025, 1, 15), 20_000)
        try addSnapshot(db, id, day(2025, 2, 1), 125_000)   // computed 120,000 → +5,000
        try addImported(db, id, day(2025, 2, 15), -10_000)
        try addSnapshot(db, id, day(2025, 3, 1), 115_000)   // computed 115,000 → nothing
        try addImported(db, id, day(2025, 3, 15), 30_000)
        try addSnapshot(db, id, day(2025, 4, 1), 140_000)   // computed 145,000 → -5,000
        try addImported(db, id, day(2025, 4, 15), 1_000)
        return id
    }

    func testSpreadsheetShapeKeepsTheOpeningAndAddsAdjustmentsReproducingEveryRecordedBalance() throws {
        let manager = try makeDB()
        try manager.dbQueue.write { db in
            let id = try spreadsheetAccount(db)
            let currentBefore = try balance(db, id, at: nil)
            let report = try BalanceConversion.convert(db: db, now: now)

            XCTAssertEqual(report.violations, [])
            let accountReport = try XCTUnwrap(report.accounts.first { $0.accountId == id })
            XCTAssertEqual(accountReport.opening?.date, day(2025, 1, 1))
            XCTAssertEqual(accountReport.opening?.balanceMinorUnits, 100_000)
            XCTAssertEqual(accountReport.adjustmentCount, 2)
            XCTAssertEqual(accountReport.adjustmentSumMinorUnits, 0)
            XCTAssertEqual(accountReport.archivedCount, 3)
            XCTAssertEqual(accountReport.latestSnapshotDate, day(2025, 4, 1))
            XCTAssertEqual(accountReport.lastActivityBefore, day(2025, 4, 15))
            XCTAssertEqual(accountReport.lastActivityAfter, day(2025, 4, 15))

            let remaining = try BalanceSnapshot.filter(Column("accountId") == id).fetchAll(db)
            XCTAssertEqual(remaining.map(\.date), [day(2025, 1, 1)])
            let archived = try BalanceSnapshotArchive.order(Column("date")).fetchAll(db)
            XCTAssertEqual(archived.map(\.balanceMinorUnits), [125_000, 115_000, 140_000])
            XCTAssertEqual(archived.map(\.note), ["Numbers import", "Numbers import", "Numbers import"])

            let added = try adjustments(db, id)
            XCTAssertEqual(added.map(\.date), [day(2025, 2, 1), day(2025, 4, 1)])
            XCTAssertEqual(added.map(\.amountMinorUnits), [5_000, -5_000])
            XCTAssertEqual(added.map(\.rawDescription), ["Balance adjustment (converted)", "Balance adjustment (converted)"])
            XCTAssertTrue(added.allSatisfy(\.isManual))
            let category = try BuiltInCategories.category(db: db, role: .balanceAdjustment)
            XCTAssertTrue(added.allSatisfy { $0.categoryId == category.id })

            for snapshot in archived {
                XCTAssertEqual(try balance(db, id, at: BalanceUpdates.endOfDay(snapshot.date)), snapshot.balanceMinorUnits)
            }
            XCTAssertEqual(try balance(db, id, at: nil), currentBefore)
            XCTAssertEqual(try balance(db, id, at: nil), 141_000)
            // Mid-month balances follow the transactions as before.
            XCTAssertEqual(try balance(db, id, at: day(2025, 2, 20)), 115_000)
        }
    }

    /// (b) A statement-imported account: opening balance, bank transactions and statement
    /// closing balances recorded at the end of their day (dated that day, like its transactions).
    func testStatementShapeTreatsARecordedBalanceAsTheEndOfItsDay() throws {
        let manager = try makeDB()
        try manager.dbQueue.write { db in
            let id = try addAccount(db, "Monzo")
            try addSnapshot(db, id, day(2026, 1, 10), 50_000)
            try addImported(db, id, day(2026, 1, 12), -2_000)
            try addImported(db, id, day(2026, 1, 20), -3_000)
            try addImported(db, id, day(2026, 1, 31), -500)
            try addSnapshot(db, id, day(2026, 1, 31), 44_500)   // matches, the 31st's spend included
            try addImported(db, id, day(2026, 2, 3), -1_000)
            try addImported(db, id, day(2026, 2, 28), 10_000)
            try addSnapshot(db, id, day(2026, 2, 28), 54_000)   // computed 53,500 → +500
            try addImported(db, id, day(2026, 3, 5), -4_000)
            let before = try balance(db, id, at: nil)

            let report = try BalanceConversion.convert(db: db, now: now)
            XCTAssertEqual(report.violations, [])
            XCTAssertEqual(try adjustments(db, id).map(\.amountMinorUnits), [500])
            XCTAssertEqual(try adjustments(db, id).map(\.date), [day(2026, 2, 28)])
            XCTAssertEqual(try balance(db, id, at: BalanceUpdates.endOfDay(day(2026, 1, 31))), 44_500)
            XCTAssertEqual(try balance(db, id, at: BalanceUpdates.endOfDay(day(2026, 2, 28))), 54_000)
            XCTAssertEqual(try balance(db, id, at: nil), before)
            XCTAssertEqual(before, 50_000)
        }
    }

    /// (c) An investment account with only recorded balances: Market movement adjustments.
    func testInvestmentAccountGetsMarketMovements() throws {
        let manager = try makeDB()
        try manager.dbQueue.write { db in
            let id = try addAccount(db, "ISA", kind: .investment)
            try addSnapshot(db, id, day(2025, 1, 1), 1_000_000)
            try addSnapshot(db, id, day(2025, 2, 1), 1_050_000)
            try addSnapshot(db, id, day(2025, 3, 1), 1_020_000)

            let report = try BalanceConversion.convert(db: db, now: now)
            XCTAssertEqual(report.violations, [])
            let added = try adjustments(db, id)
            XCTAssertEqual(added.map(\.amountMinorUnits), [50_000, -30_000])
            XCTAssertEqual(added.map(\.rawDescription), ["Market movement (converted)", "Market movement (converted)"])
            let category = try BuiltInCategories.category(db: db, role: .marketMovement)
            XCTAssertTrue(added.allSatisfy { $0.categoryId == category.id })
            XCTAssertEqual(try balance(db, id, at: nil), 1_020_000)
            XCTAssertEqual(try balance(db, id, at: MonthRange.of(year: 2025, month: 1).end), 1_000_000)
        }
    }

    /// (d) Manual transactions before and after the last recorded balance.
    func testManualTransactionsAfterTheLastRecordedBalanceStillCount() throws {
        let manager = try makeDB()
        try manager.dbQueue.write { db in
            let id = try addAccount(db, "Cash")
            try addSnapshot(db, id, day(2025, 1, 1), 10_000)
            try ManualTransactions.add(db: db, accountId: id, date: day(2025, 2, 5), description: "Gift", amountMinorUnits: 10_000, categoryId: nil, note: nil)
            try addSnapshot(db, id, day(2025, 3, 1), 30_000)    // computed 20,000 → +10,000
            try ManualTransactions.add(db: db, accountId: id, date: day(2025, 3, 10), description: "Found", amountMinorUnits: 5_000, categoryId: nil, note: nil)
            try ManualTransactions.add(db: db, accountId: id, date: day(2026, 12, 1), description: "Future", amountMinorUnits: 700, categoryId: nil, note: nil)
            let today = try balance(db, id, at: BalanceUpdates.endOfDay(now))
            let all = try balance(db, id, at: nil)

            let report = try BalanceConversion.convert(db: db, now: now)
            XCTAssertEqual(report.violations, [])
            XCTAssertEqual(try adjustments(db, id).map(\.amountMinorUnits), [10_000])
            XCTAssertEqual(try balance(db, id, at: BalanceUpdates.endOfDay(now)), today)
            XCTAssertEqual(today, 35_000)
            XCTAssertEqual(try balance(db, id, at: nil), all)
        }
    }

    /// Several recorded balances on one day: the newest wins, the rest are archived unchecked.
    func testSameDaySnapshotsAreSuperseded() throws {
        let manager = try makeDB()
        try manager.dbQueue.write { db in
            let id = try addAccount(db, "Amex", kind: .credit)
            try addSnapshot(db, id, day(2025, 1, 1), -1_000)
            try addSnapshot(db, id, day(2025, 1, 1), -2_000)    // wins over the first
            try addImported(db, id, day(2025, 1, 10), -500)
            try addSnapshot(db, id, day(2025, 2, 1), -9_999)
            try addSnapshot(db, id, day(2025, 2, 1), -3_000)    // wins: computed -2,500 → -500
            let before = try balance(db, id, at: nil)

            let report = try BalanceConversion.convert(db: db, now: now)
            XCTAssertEqual(report.violations, [])
            let accountReport = try XCTUnwrap(report.accounts.first)
            XCTAssertEqual(accountReport.opening?.balanceMinorUnits, -2_000)
            XCTAssertEqual(accountReport.supersededCount, 2)
            XCTAssertEqual(accountReport.archivedCount, 3)
            XCTAssertEqual(try adjustments(db, id).map(\.amountMinorUnits), [-500])
            XCTAssertEqual(try balance(db, id, at: nil), before)
        }
    }

    /// (e) Running it twice does nothing the second time; accounts without balances are left alone.
    func testSecondRunDoesNothing() throws {
        let manager = try makeDB()
        try manager.dbQueue.write { db in
            let id = try spreadsheetAccount(db)
            let empty = try addAccount(db, "Empty")
            try addImported(db, empty, day(2025, 5, 1), 1_234)
            let first = try BalanceConversion.convert(db: db, now: now)
            XCTAssertFalse(first.isNoOp)
            XCTAssertNil(first.accounts.first { $0.accountId == empty }?.opening)
            let transactions = try Transaction.fetchCount(db)

            let second = try BalanceConversion.convert(db: db, now: now)
            XCTAssertTrue(second.isNoOp)
            XCTAssertEqual(second.violations, [])
            XCTAssertEqual(second.accounts.first { $0.accountId == id }?.adjustmentCount, 0)
            XCTAssertEqual(try Transaction.fetchCount(db), transactions)
            XCTAssertEqual(try BalanceSnapshotArchive.fetchCount(db), 3)
            XCTAssertEqual(try BalanceSnapshot.fetchCount(db), 1)
            XCTAssertFalse(second.text.isEmpty)
        }
    }

    /// (f) A broken result fails verification: the error carries the violations and the
    /// caller's transaction rolls everything back.
    func testInvariantFailureAbortsAndRollsBack() throws {
        let manager = try makeDB()
        let id = try manager.dbQueue.write { db in try spreadsheetAccount(db) }
        XCTAssertThrowsError(try manager.dbQueue.write { db in
            try BalanceConversion.convert(db: db, now: self.now) { db in
                // A stray transaction before the last recorded balance breaks it.
                try ManualTransactions.add(db: db, accountId: id, date: self.day(2025, 3, 20), description: "Bug", amountMinorUnits: 1, categoryId: nil, note: nil)
            }
        }) { error in
            guard case BalanceConversionError.invariantViolated(let report) = error else { return XCTFail("\(error)") }
            XCTAssertFalse(report.violations.isEmpty)
            XCTAssertTrue(report.violations.contains { $0.contains("1 Apr 2025") }, "\(report.violations)")
        }
        try manager.dbQueue.read { db in
            XCTAssertEqual(try BalanceSnapshot.fetchCount(db), 4)
            XCTAssertEqual(try BalanceSnapshotArchive.fetchCount(db), 0)
            XCTAssertEqual(try adjustments(db, id).count, 0)
            XCTAssertEqual(try Transaction.fetchCount(db), 4)
        }
    }

    /// A later recorded balance that needed no adjustment still counts as activity after the
    /// conversion (`Account.balanceConfirmedAt`): staleness and "as of" don't move earlier.
    func testConversionKeepsLastActivityWhenALaterBalanceNeededNoAdjustment() throws {
        let manager = try makeDB()
        try manager.dbQueue.write { db in
            let id = try addAccount(db, "ISA", kind: .investment)
            try addSnapshot(db, id, day(2026, 1, 1), 100_000)
            try addImported(db, id, day(2026, 1, 15), 20_000)
            try addSnapshot(db, id, day(2026, 9, 1), 120_000)   // matches: no adjustment
            let account = try XCTUnwrap(Account.fetchOne(db, key: id))
            let before = BalanceStaleness.lastActivity(account: account, snapshots: try BalanceSnapshot.fetchAll(db), transactions: try Transaction.fetchAll(db), today: now)
            XCTAssertEqual(before, day(2026, 9, 1))

            let report = try BalanceConversion.convert(db: db, now: now)
            XCTAssertEqual(report.violations, [])
            XCTAssertEqual(try adjustments(db, id).count, 0)
            let accountReport = try XCTUnwrap(report.accounts.first)
            XCTAssertEqual(accountReport.latestSnapshotDate, day(2026, 9, 1))
            XCTAssertEqual(accountReport.lastActivityBefore, day(2026, 9, 1))
            XCTAssertEqual(accountReport.lastActivityAfter, day(2026, 9, 1))
            XCTAssertTrue(report.text.contains("last activity 1 Sep 2026 → 1 Sep 2026"), report.text)

            let converted = try XCTUnwrap(Account.fetchOne(db, key: id))
            XCTAssertEqual(converted.balanceConfirmedAt, day(2026, 9, 1))
            let snapshots = try BalanceSnapshot.fetchAll(db), transactions = try Transaction.fetchAll(db)
            XCTAssertEqual(BalanceStaleness.lastActivity(account: converted, snapshots: snapshots, transactions: transactions, today: now), before)
            XCTAssertFalse(BalanceStaleness.isStale(account: converted, snapshots: snapshots, transactions: transactions, today: now))
            let overview = AccountsOverview.make(accounts: [converted], snapshots: snapshots, transactions: transactions,
                                                 rate: ExchangeRateSetting(eurToGbpRate: 0.87, updatedAt: now), today: now)
            XCTAssertEqual(overview.asOf, day(2026, 9, 1))
        }
    }

    /// The safety net: a transaction later on a recorded balance's day than the balance itself
    /// counted after it before; after conversion that day's end equals the recorded balance,
    /// so the month-end and current balances would change — the conversion aborts.
    func testTransactionLaterOnARecordedBalancesDayAbortsTheConversion() throws {
        let manager = try makeDB()
        try manager.dbQueue.write { db in
            let id = try addAccount(db, "Monzo")
            try addSnapshot(db, id, day(2026, 1, 1), 10_000)
            try addSnapshot(db, id, day(2026, 2, 1), 12_000)
            try addImported(db, id, MonthRange.calendar.date(from: DateComponents(year: 2026, month: 2, day: 1, hour: 10))!, -500)
        }
        XCTAssertThrowsError(try manager.dbQueue.write { db in try BalanceConversion.convert(db: db, now: self.now) }) { error in
            guard case BalanceConversionError.invariantViolated(let report) = error else { return XCTFail("\(error)") }
            XCTAssertTrue(report.violations.contains { $0.contains("28 Feb 2026") }, "\(report.violations)")
        }
        try manager.dbQueue.read { db in
            XCTAssertEqual(try BalanceSnapshot.fetchCount(db), 2)
            XCTAssertEqual(try BalanceSnapshotArchive.fetchCount(db), 0)
        }
    }

    /// Update balance with nothing to adjust still records the confirmation and clears staleness.
    func testUpdateBalanceWithZeroDifferenceConfirmsTheBalance() throws {
        let manager = try makeDB()
        try manager.dbQueue.write { db in
            let id = try addAccount(db, "ISA", kind: .investment)
            try addSnapshot(db, id, day(2026, 1, 1), 100_000)
            let today = day(2026, 10, 15)
            var snapshots = try BalanceSnapshot.fetchAll(db), transactions = try Transaction.fetchAll(db)
            XCTAssertTrue(BalanceStaleness.isStale(account: try XCTUnwrap(Account.fetchOne(db, key: id)), snapshots: snapshots, transactions: transactions, today: today))

            let outcomes = try BalanceUpdates.save(db: db, entries: [.init(accountId: id, enteredMinorUnits: 100_000)], asOf: today)
            XCTAssertEqual(outcomes.map(\.differenceMinorUnits), [0])
            XCTAssertEqual(try Transaction.fetchCount(db), 0)
            let account = try XCTUnwrap(Account.fetchOne(db, key: id))
            XCTAssertEqual(account.balanceConfirmedAt, today)
            snapshots = try BalanceSnapshot.fetchAll(db)
            transactions = try Transaction.fetchAll(db)
            XCTAssertFalse(BalanceStaleness.isStale(account: account, snapshots: snapshots, transactions: transactions, today: today))
            XCTAssertEqual(BalanceStaleness.lastActivity(account: account, snapshots: snapshots, transactions: transactions, today: today), today)

            // An earlier Update balance never moves the confirmation back.
            _ = try BalanceUpdates.save(db: db, entries: [.init(accountId: id, enteredMinorUnits: 100_000)], asOf: day(2026, 6, 1))
            XCTAssertEqual(try Account.fetchOne(db, key: id)?.balanceConfirmedAt, today)
        }
    }

    // MARK: Account history

    func testHistoryPlotsComputedMonthEndsAndListsTheOpeningAndAdjustments() throws {
        let manager = try makeDB()
        try manager.dbQueue.write { db in
            let id = try spreadsheetAccount(db)
            try BalanceConversion.convert(db: db, now: now)
            let names = Dictionary(uniqueKeysWithValues: try Category.filter(Column("builtInRole") != nil).fetchAll(db).map { ($0.id!, $0.name) })
            let today = day(2025, 6, 10)
            let history = AccountHistory.make(accountId: id, snapshots: try BalanceSnapshot.fetchAll(db), transactions: try Transaction.fetchAll(db),
                                              adjustmentCategoryNames: names, today: today)
            XCTAssertEqual(history.points.map(\.date), [
                BalanceUpdates.endOfDay(day(2025, 1, 1)),
                MonthRange.of(year: 2025, month: 1).end, MonthRange.of(year: 2025, month: 2).end, MonthRange.of(year: 2025, month: 3).end,
                MonthRange.of(year: 2025, month: 4).end, MonthRange.of(year: 2025, month: 5).end,
                BalanceUpdates.endOfDay(today),
            ])
            XCTAssertEqual(history.points.map(\.balanceMinorUnits), [100_000, 120_000, 115_000, 145_000, 141_000, 141_000, 141_000])
            XCTAssertEqual(history.entries.map(\.kind), [
                .adjustment(categoryName: "Balance adjustment"), .adjustment(categoryName: "Balance adjustment"), .opening,
            ])
            XCTAssertEqual(history.entries.map(\.date), [day(2025, 4, 1), day(2025, 2, 1), day(2025, 1, 1)])
            XCTAssertEqual(history.entries.map(\.amountMinorUnits), [-5_000, 5_000, 100_000])
        }
    }

    func testHistoryListsLegacyRecordedBalancesAfterTheOpening() {
        let snapshots = [
            BalanceSnapshot(id: 1, accountId: 1, date: day(2025, 1, 1), balanceMinorUnits: 100, note: nil),
            BalanceSnapshot(id: 2, accountId: 1, date: day(2025, 3, 1), balanceMinorUnits: 300, note: "Statement"),
        ]
        let history = AccountHistory.make(accountId: 1, snapshots: snapshots, transactions: [], adjustmentCategoryNames: [:], today: day(2025, 3, 20))
        XCTAssertEqual(history.entries.map(\.kind), [.recordedBalance, .opening])
        XCTAssertEqual(history.points.map(\.balanceMinorUnits), [100, 100, 100, 300])
    }
}
