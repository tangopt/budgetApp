import XCTest
import GRDB
@testable import BudgetCore
import struct BudgetCore.Category
import struct BudgetCore.Transaction

/// Spec 2026-10-14 §2: a statement's closing balance is compared with the account's computed
/// balance (saved transactions + the staged rows that will be saved); a mismatch is flagged,
/// recorded on the account, and only resolved by an adjustment when the user asks for one.
final class StatementCheckTests: XCTestCase {
    private func day(_ y: Int, _ m: Int, _ d: Int) -> Date {
        MonthRange.calendar.date(from: DateComponents(year: y, month: m, day: d))!
    }

    /// An account opened with £10.00 on 1 Jan and a saved -£1.00 on 5 Jan.
    private func makeFixture(kind: AccountKind = .cash) throws -> (DatabaseManager, Account, ImportCoordinator) {
        let manager = try DatabaseManager(path: nil)
        try manager.migrate()
        let account = try manager.dbQueue.write { db -> Account in
            let account = try AccountEditing.add(db: db, name: "Current", currency: .gbp, kind: kind, openingBalanceEntered: 1_000, asOf: day(2026, 1, 1))
            try addSaved(db, account.id!, day(2026, 1, 5), -100)
            return account
        }
        let coordinator = ImportCoordinator(dbQueue: manager.dbQueue, categorizationService: CategorizationService(categorizer: FakeCategorizer()))
        return (manager, account, coordinator)
    }

    private func addSaved(_ db: Database, _ accountId: Int64, _ date: Date, _ amount: Int) throws {
        var batch = ImportBatch(accountId: accountId, sourceFileName: "old.csv", importedAt: date)
        try batch.insert(db)
        var t = Transaction(importBatchId: batch.id!, accountId: accountId, date: date, rawDescription: "Saved", amountMinorUnits: amount,
                            categoryId: nil, status: .pendingReview, categorizedBy: .none, fingerprint: UUID().uuidString)
        try t.insert(db)
    }

    private func staged(_ date: Date, _ amount: Int) -> StagedTransaction {
        StagedTransaction(parsed: ParsedTransaction(date: date, rawDescription: "Row \(amount)", amountMinorUnits: amount),
                          suggestedCategoryId: nil, source: .none, confidence: 0, fingerprint: UUID().uuidString)
    }

    private func decisions(_ rows: [StagedTransaction]) -> [ImportDecision] {
        rows.map { ImportDecision(stagedId: $0.id, finalCategoryId: nil) }
    }

    private func account(_ manager: DatabaseManager, _ id: Int64) throws -> Account {
        try manager.dbQueue.read { db in try Account.fetchOne(db, key: id)! }
    }

    // MARK: compare

    func testComparesTheClosingBalanceWithSavedPlusStagedRowsUpToTheClosingDay() throws {
        let (manager, account, _) = try makeFixture()
        let rows = [(date: day(2026, 1, 10), amountMinorUnits: -200),
                    (date: day(2026, 1, 15), amountMinorUnits: -50),   // the closing day counts
                    (date: day(2026, 1, 20), amountMinorUnits: -999)]  // after the closing day: ignored
        try manager.dbQueue.read { db in
            XCTAssertEqual(try StatementCheck.compare(db: db, accountId: account.id!, closing: StatementClosing(date: day(2026, 1, 15), balanceMinorUnits: 650), stagedRows: rows),
                           .matches(StatementClosing(date: day(2026, 1, 15), balanceMinorUnits: 650)))
            let result = try StatementCheck.compare(db: db, accountId: account.id!, closing: StatementClosing(date: day(2026, 1, 15), balanceMinorUnits: 600), stagedRows: rows)
            XCTAssertEqual(result, .mismatch(StatementMismatch(date: day(2026, 1, 15), statementMinorUnits: 600, computedMinorUnits: 650)))
            XCTAssertEqual(result.mismatch?.differenceMinorUnits, -50)
        }
    }

    func testRowsLeftOutAreNotCounted() throws {
        let (manager, account, _) = try makeFixture()
        try manager.dbQueue.read { db in
            let result = try StatementCheck.compare(db: db, accountId: account.id!, closing: StatementClosing(date: day(2026, 1, 15), balanceMinorUnits: 650),
                                                    stagedRows: [(date: day(2026, 1, 10), amountMinorUnits: -200)])
            XCTAssertEqual(result.mismatch?.computedMinorUnits, 700)
            XCTAssertEqual(result.mismatch?.differenceMinorUnits, -50)
        }
    }

    func testManualEntriesTheImportReplacesAreLeftOut() throws {
        let (manager, account, _) = try makeFixture()
        let manualId = try manager.dbQueue.write { db in
            try ManualTransactions.add(db: db, accountId: account.id!, date: day(2026, 1, 9), description: "Coffee", amountMinorUnits: -200, categoryId: nil, note: nil).id!
        }
        try manager.dbQueue.read { db in
            let result = try StatementCheck.compare(db: db, accountId: account.id!, closing: StatementClosing(date: day(2026, 1, 15), balanceMinorUnits: 700),
                                                    stagedRows: [(date: day(2026, 1, 10), amountMinorUnits: -200)], excludingTransactionIds: [manualId])
            XCTAssertEqual(result, .matches(StatementClosing(date: day(2026, 1, 15), balanceMinorUnits: 700)))
        }
    }

    func testAnEmptyAccountComputesZero() throws {
        let manager = try DatabaseManager(path: nil)
        try manager.migrate()
        try manager.dbQueue.write { db in
            var account = Account(name: "New", currency: .gbp, kind: .cash, trackingMode: .imported)
            try account.insert(db)
            let result = try StatementCheck.compare(db: db, accountId: account.id!, closing: StatementClosing(date: day(2026, 1, 15), balanceMinorUnits: 500),
                                                    stagedRows: [(date: day(2026, 1, 10), amountMinorUnits: 300)])
            XCTAssertEqual(result.mismatch, StatementMismatch(date: day(2026, 1, 15), statementMinorUnits: 500, computedMinorUnits: 300))
        }
    }

    // MARK: Finish import

    func testFinishingWithAMismatchRecordsItOnTheAccountAndAddsNothing() throws {
        let (manager, account, coordinator) = try makeFixture()
        let rows = [staged(day(2026, 1, 10), -200)]
        let outcome = try coordinator.commit(accountId: account.id!, sourceFileName: "jan.csv", staged: rows, decisions: decisions(rows),
                                             statement: StatementFinish(closing: StatementClosing(date: day(2026, 1, 15), balanceMinorUnits: 650), addAdjustment: false))
        XCTAssertEqual(outcome?.check.mismatch?.differenceMinorUnits, -50)
        XCTAssertNil(outcome?.adjustmentTransactionId)
        let saved = try self.account(manager, account.id!)
        XCTAssertEqual(saved.statementMismatchMinorUnits, -50)
        XCTAssertEqual(saved.statementMismatchDate, day(2026, 1, 15))
        let (transactions, snapshots) = try manager.dbQueue.read { db in (try Transaction.fetchCount(db), try BalanceSnapshot.fetchCount(db)) }
        XCTAssertEqual(transactions, 2)
        XCTAssertEqual(snapshots, 1, "statement balances are never stored as snapshots")
    }

    func testTickingTheAdjustmentAddsItOnTheClosingDateInTheSameWrite() throws {
        for (kind, role) in [(AccountKind.cash, CategoryBuiltInRole.balanceAdjustment), (.investment, .marketMovement)] {
            let (manager, account, coordinator) = try makeFixture(kind: kind)
            let rows = [staged(day(2026, 1, 10), -200)]
            let outcome = try coordinator.commit(accountId: account.id!, sourceFileName: "jan.csv", staged: rows, decisions: decisions(rows),
                                                 statement: StatementFinish(closing: StatementClosing(date: day(2026, 1, 15), balanceMinorUnits: 650), addAdjustment: true))
            XCTAssertEqual(outcome?.check.mismatch?.differenceMinorUnits, -50)
            let adjustment = try manager.dbQueue.read { db in try Transaction.fetchOne(db, key: outcome?.adjustmentTransactionId) }
            let category = try manager.dbQueue.read { db in try BuiltInCategories.category(db: db, role: role) }
            XCTAssertEqual(adjustment?.amountMinorUnits, -50)
            XCTAssertEqual(adjustment?.date, day(2026, 1, 15))
            XCTAssertEqual(adjustment?.categoryId, category.id)
            XCTAssertEqual(adjustment?.isManual, true)
            let balance = try manager.dbQueue.read { db in try BalanceUpdates.computedBalance(db: db, accountId: account.id!, asOf: day(2026, 1, 15)) }
            XCTAssertEqual(balance, 650)
            XCTAssertNil(try self.account(manager, account.id!).statementMismatchMinorUnits)
        }
    }

    func testAMatchingStatementAddsNoAdjustmentEvenWhenTicked() throws {
        let (manager, account, coordinator) = try makeFixture()
        let rows = [staged(day(2026, 1, 10), -200)]
        let outcome = try coordinator.commit(accountId: account.id!, sourceFileName: "jan.csv", staged: rows, decisions: decisions(rows),
                                             statement: StatementFinish(closing: StatementClosing(date: day(2026, 1, 15), balanceMinorUnits: 700), addAdjustment: true))
        XCTAssertEqual(outcome?.check, .matches(StatementClosing(date: day(2026, 1, 15), balanceMinorUnits: 700)))
        XCTAssertNil(outcome?.adjustmentTransactionId)
        XCTAssertEqual(try manager.dbQueue.read { db in try Transaction.fetchCount(db) }, 2)
    }

    func testALaterMatchingStatementClearsTheMismatchButAnEarlierOneDoesNot() throws {
        let (manager, account, coordinator) = try makeFixture()
        let feb = [staged(day(2026, 2, 10), -100)]
        try coordinator.commit(accountId: account.id!, sourceFileName: "feb.csv", staged: feb, decisions: decisions(feb),
                               statement: StatementFinish(closing: StatementClosing(date: day(2026, 2, 15), balanceMinorUnits: 1), addAdjustment: false))
        XCTAssertEqual(try self.account(manager, account.id!).statementMismatchDate, day(2026, 2, 15))

        // An earlier statement (no rows left to save) that matches leaves the later mismatch alone.
        try coordinator.finishStatement(accountId: account.id!, sourceFileName: "jan.csv",
                                        statement: StatementFinish(closing: StatementClosing(date: day(2026, 1, 15), balanceMinorUnits: 900), addAdjustment: false))
        XCTAssertEqual(try self.account(manager, account.id!).statementMismatchMinorUnits, 1 - 800)

        let mar = [staged(day(2026, 3, 10), 50)]
        try coordinator.commit(accountId: account.id!, sourceFileName: "mar.csv", staged: mar, decisions: decisions(mar),
                               statement: StatementFinish(closing: StatementClosing(date: day(2026, 3, 31), balanceMinorUnits: 850), addAdjustment: false))
        let cleared = try self.account(manager, account.id!)
        XCTAssertNil(cleared.statementMismatchMinorUnits)
        XCTAssertNil(cleared.statementMismatchDate)
    }

    func testFinishingWithNothingToSaveStillChecksAndCanAdjust() throws {
        let (manager, account, coordinator) = try makeFixture()
        let outcome = try coordinator.finishStatement(accountId: account.id!, sourceFileName: "jan.csv",
                                                      statement: StatementFinish(closing: StatementClosing(date: day(2026, 1, 15), balanceMinorUnits: 880), addAdjustment: true))
        XCTAssertEqual(outcome.check.mismatch?.differenceMinorUnits, -20)
        XCTAssertNotNil(outcome.adjustmentTransactionId)
        XCTAssertEqual(try manager.dbQueue.read { db in try BalanceUpdates.computedBalance(db: db, accountId: account.id!, asOf: day(2026, 1, 31)) }, 880)
    }

    func testAFailedCommitRecordsNoMismatch() throws {
        let (manager, account, coordinator) = try makeFixture()
        let rows = [staged(day(2026, 1, 10), -200)]
        try coordinator.commit(accountId: account.id!, sourceFileName: "jan.csv", staged: rows, decisions: decisions(rows))
        // The same fingerprints again violate the unique key.
        XCTAssertThrowsError(try coordinator.commit(accountId: account.id!, sourceFileName: "jan.csv", staged: rows, decisions: decisions(rows),
                                                    statement: StatementFinish(closing: StatementClosing(date: day(2026, 1, 15), balanceMinorUnits: 1), addAdjustment: true)))
        let saved = try self.account(manager, account.id!)
        XCTAssertNil(saved.statementMismatchMinorUnits)
        XCTAssertEqual(try manager.dbQueue.read { db in try Transaction.fetchCount(db) }, 2)
    }

    func testUpdateBalanceOnOrAfterTheMismatchDateClearsIt() throws {
        let (manager, account, coordinator) = try makeFixture()
        try coordinator.finishStatement(accountId: account.id!, sourceFileName: "jan.csv",
                                        statement: StatementFinish(closing: StatementClosing(date: day(2026, 1, 15), balanceMinorUnits: 880), addAdjustment: false))
        try manager.dbQueue.write { db in
            _ = try BalanceUpdates.save(db: db, entries: [BalanceUpdates.Entry(accountId: account.id!, enteredMinorUnits: 870)], asOf: day(2026, 1, 10))
        }
        XCTAssertNotNil(try self.account(manager, account.id!).statementMismatchMinorUnits, "an earlier update doesn't resolve it")
        try manager.dbQueue.write { db in
            _ = try BalanceUpdates.save(db: db, entries: [BalanceUpdates.Entry(accountId: account.id!, enteredMinorUnits: 870)], asOf: day(2026, 1, 15))
        }
        XCTAssertNil(try self.account(manager, account.id!).statementMismatchMinorUnits)
    }

    func testAClosingDateBeforeTheOpeningBalanceCantBeCheckedAndRecordsNothing() throws {
        let (manager, account, coordinator) = try makeFixture()
        let closing = StatementClosing(date: day(2025, 12, 31), balanceMinorUnits: 5_000)
        try manager.dbQueue.read { db in
            XCTAssertEqual(try StatementCheck.compare(db: db, accountId: account.id!, closing: closing, stagedRows: [(date: day(2025, 12, 20), amountMinorUnits: -10)]),
                           .cannotCheck(closing))
        }
        let outcome = try coordinator.finishStatement(accountId: account.id!, sourceFileName: "dec.csv", statement: StatementFinish(closing: closing, addAdjustment: true))
        XCTAssertEqual(outcome.check, .cannotCheck(closing))
        XCTAssertNil(outcome.adjustmentTransactionId)
        let saved = try self.account(manager, account.id!)
        XCTAssertNil(saved.statementMismatchMinorUnits)
        XCTAssertNil(saved.statementLastCheckedDate)
        XCTAssertEqual(try manager.dbQueue.read { db in try Transaction.fetchCount(db) }, 1)
    }

    func testImportingTheMissingEarlierPeriodClearsALaterMismatch() throws {
        let (manager, account, coordinator) = try makeFixture()
        // February's statement: the bank also had a -£1.00 on 20 Jan the app hasn't seen.
        let feb = [staged(day(2026, 2, 10), -100)]
        try coordinator.commit(accountId: account.id!, sourceFileName: "feb.csv", staged: feb, decisions: decisions(feb),
                               statement: StatementFinish(closing: StatementClosing(date: day(2026, 2, 15), balanceMinorUnits: 700), addAdjustment: false))
        let flagged = try self.account(manager, account.id!)
        XCTAssertEqual(flagged.statementMismatchMinorUnits, -100)
        XCTAssertEqual(flagged.statementMismatchClosingMinorUnits, 700)

        let jan = [staged(day(2026, 1, 20), -100)]
        let outcome = try coordinator.commit(accountId: account.id!, sourceFileName: "jan.csv", staged: jan, decisions: decisions(jan),
                                             statement: StatementFinish(closing: StatementClosing(date: day(2026, 1, 31), balanceMinorUnits: 800), addAdjustment: false))
        XCTAssertEqual(outcome?.check, .matches(StatementClosing(date: day(2026, 1, 31), balanceMinorUnits: 800)))
        let cleared = try self.account(manager, account.id!)
        XCTAssertNil(cleared.statementMismatchMinorUnits)
        XCTAssertNil(cleared.statementMismatchDate)
        XCTAssertNil(cleared.statementMismatchClosingMinorUnits)
        XCTAssertEqual(cleared.statementLastCheckedDate, day(2026, 2, 15))
    }

    func testAPartialFixUpdatesTheStoredDifference() throws {
        let (manager, account, coordinator) = try makeFixture()
        try coordinator.finishStatement(accountId: account.id!, sourceFileName: "feb.csv",
                                        statement: StatementFinish(closing: StatementClosing(date: day(2026, 2, 15), balanceMinorUnits: 600), addAdjustment: false))
        XCTAssertEqual(try self.account(manager, account.id!).statementMismatchMinorUnits, -300)
        let jan = [staged(day(2026, 1, 20), -100)]
        // Every Finish import re-checks it, even one without a statement balance.
        try coordinator.commit(accountId: account.id!, sourceFileName: "jan.csv", staged: jan, decisions: decisions(jan))
        XCTAssertEqual(try self.account(manager, account.id!).statementMismatchMinorUnits, -200)
    }

    func testAnEarlierStatementNeverOverridesALaterCheckedOne() throws {
        let (manager, account, coordinator) = try makeFixture()
        try coordinator.finishStatement(accountId: account.id!, sourceFileName: "feb.csv",
                                        statement: StatementFinish(closing: StatementClosing(date: day(2026, 2, 15), balanceMinorUnits: 900), addAdjustment: false))
        XCTAssertEqual(try self.account(manager, account.id!).statementLastCheckedDate, day(2026, 2, 15))
        let outcome = try coordinator.finishStatement(accountId: account.id!, sourceFileName: "jan.csv",
                                                      statement: StatementFinish(closing: StatementClosing(date: day(2026, 1, 15), balanceMinorUnits: 1), addAdjustment: false))
        XCTAssertNotNil(outcome.check.mismatch)
        let saved = try self.account(manager, account.id!)
        XCTAssertNil(saved.statementMismatchMinorUnits)
        XCTAssertEqual(saved.statementLastCheckedDate, day(2026, 2, 15))
    }
}
