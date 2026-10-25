import XCTest
import GRDB
@testable import BudgetCore
import struct BudgetCore.Category
import struct BudgetCore.Transaction
import TestSupport

/// Spec 2026-10-15: the one-off correction of the spreadsheet balances.
final class SpreadsheetBalanceCorrectionTests: XCTestCase {
    private typealias Correction = SpreadsheetBalanceCorrection
    private let now = MonthRange.calendar.date(from: DateComponents(year: 2026, month: 10, day: 15, hour: 9))!

    private func day(_ y: Int, _ m: Int, _ d: Int) -> Date {
        MonthRange.calendar.date(from: DateComponents(year: y, month: m, day: d))!
    }

    private struct Fixture {
        var current: Int64 = 0
        var euro: Int64 = 0
        var saver: Int64 = 0
        var isa: Int64 = 0
        var statementId: Int64 = 0
    }

    private func makeDB() throws -> DatabaseManager {
        return try TestDatabase.migratedManager()
    }

    private func account(_ db: Database, _ name: String, currency: Currency = .gbp, kind: AccountKind = .cash) throws -> Int64 {
        var account = Account(name: name, currency: currency, kind: kind, trackingMode: .manual)
        try account.insert(db)
        return account.id!
    }

    @discardableResult
    private func snapshot(_ db: Database, _ accountId: Int64, _ date: Date, _ balance: Int, note: String = "Numbers import") throws -> Int64 {
        var s = BalanceSnapshot(accountId: accountId, date: date, balanceMinorUnits: balance, note: note)
        try s.insert(db)
        return s.id!
    }

    private func batch(_ db: Database, _ accountId: Int64, _ file: String) throws -> Int64 {
        if let existing = try ImportBatch.filter(Column("accountId") == accountId && Column("sourceFileName") == file).fetchOne(db) { return existing.id! }
        var b = ImportBatch(accountId: accountId, sourceFileName: file, importedAt: day(2026, 9, 1))
        try b.insert(db)
        return b.id!
    }

    @discardableResult
    private func transaction(_ db: Database, _ accountId: Int64, _ date: Date, _ description: String, _ amount: Int,
                             file: String = "Budget copy.numbers", categoryId: Int64? = nil) throws -> Int64 {
        var t = Transaction(importBatchId: try batch(db, accountId, file), accountId: accountId, date: date, rawDescription: description,
                            amountMinorUnits: amount, categoryId: categoryId, status: .confirmed, categorizedBy: .none, fingerprint: UUID().uuidString)
        try t.insert(db)
        return t.id!
    }

    /// The database as MigrateAccountBalances + ConvertBalances left it: each spreadsheet column M
    /// dated the 1st of M, the EUR account in GBP, the partial February column included, then converted.
    private func buggyDatabase(_ db: Database) throws -> Fixture {
        var f = Fixture()
        var income = Category(name: "Income", type: .income)
        try income.insert(db)

        // Current: column Nov 800, Dec 1,000, Jan 1,300, Feb (partial) 1,750; salary 500 on the 14th.
        f.current = try account(db, "Lloyds Classic")
        try snapshot(db, f.current, day(2025, 11, 1), 80_000)
        try snapshot(db, f.current, day(2025, 12, 1), 100_000)
        try snapshot(db, f.current, day(2026, 1, 1), 130_000)
        try snapshot(db, f.current, day(2026, 2, 1), 175_000)
        try transaction(db, f.current, day(2025, 11, 14), "Income", 50_000, categoryId: income.id)
        try transaction(db, f.current, day(2025, 12, 14), "Groceries", -30_000)
        try transaction(db, f.current, day(2025, 12, 14), "Income", 50_000, categoryId: income.id)
        try transaction(db, f.current, day(2026, 1, 14), "Groceries", -20_000)
        try transaction(db, f.current, day(2026, 1, 14), "Income", 50_000, categoryId: income.id)
        try transaction(db, f.current, day(2026, 2, 14), "Groceries", -5_000)   // includes the 16 Feb Sainsbury's
        try transaction(db, f.current, day(2026, 2, 14), "Income", 50_000, categoryId: income.id)   // the forecast
        try transaction(db, f.current, day(2026, 2, 16), "SAINSBURYS S/MKTS", -1_000, file: "bank.csv")
        try transaction(db, f.current, day(2026, 2, 20), "OTHER", -3_000, file: "bank.csv")
        try transaction(db, f.current, day(2026, 2, 25), "SALARY", 50_000, file: "bank.csv", categoryId: income.id)
        try snapshot(db, f.current, day(2026, 3, 1), 222_000, note: "Statement balance — bank.csv")

        // EUR account: GBP-converted values instead of the EUR row.
        f.euro = try account(db, "Euro", currency: .eur)
        try snapshot(db, f.euro, day(2025, 12, 1), 86_000)
        try snapshot(db, f.euro, day(2026, 1, 1), 86_000)

        // Saver: 20,000 paid in during December; a statement balance on 1 Jan.
        f.saver = try account(db, "Saver")
        try snapshot(db, f.saver, day(2025, 11, 1), 0)
        try snapshot(db, f.saver, day(2025, 12, 1), 2_000_000)
        f.statementId = try snapshot(db, f.saver, day(2026, 1, 1), 2_000_000, note: "Statement balance — saver.csv")

        // Investment ISA: column Dec 100, Jan 120.
        f.isa = try account(db, "ISA", kind: .investment)
        try snapshot(db, f.isa, day(2025, 12, 1), 10_000)
        try snapshot(db, f.isa, day(2026, 1, 1), 12_000)

        try BalanceConversion.convert(db: db, now: now)
        return f
    }

    private func s(_ account: String, _ date: String, _ value: Int, _ currency: String = "gbp") -> Correction.CorrectedSnapshot {
        Correction.CorrectedSnapshot(account: account, date: date, valueMinorUnits: value, currency: currency)
    }

    /// What the script produces for the fixture: column M on the 1st of M+1, Current + that
    /// column's income, EUR in EUR, no partial February column.
    private var input: Correction.Input {
        Correction.Input(snapshots: [
            s("Lloyds Classic", "2025-12-01", 130_000), s("Lloyds Classic", "2026-01-01", 150_000), s("Lloyds Classic", "2026-02-01", 180_000),
            s("Euro", "2026-01-01", 100_000, "eur"), s("Euro", "2026-02-01", 100_000, "eur"),
            s("Saver", "2025-12-01", 0), s("Saver", "2026-01-01", 2_000_000),
            s("ISA", "2026-01-01", 10_000), s("ISA", "2026-02-01", 12_000),
        ], deleteTransactions: [
            Correction.TransactionToDelete(account: "Lloyds Classic", date: "2026-02-14", description: "Income", amountMinorUnits: 50_000, sourceFileName: "Budget copy.numbers"),
            Correction.TransactionToDelete(account: "Lloyds Classic", date: "2026-02-16", description: "SAINSBURYS S/MKTS", amountMinorUnits: -1_000),
        ])
    }

    private func adjustments(_ db: Database, _ accountId: Int64) throws -> [Transaction] {
        try Transaction.filter(Column("accountId") == accountId && Column("note") == BalanceConversion.adjustmentNote).order(Column("date")).fetchAll(db)
    }

    func testCorrectsDatesValuesAndTheFebruaryDuplicatesThenConvertsAgain() throws {
        let manager = try makeDB()
        try manager.dbQueue.write { db in
            let f = try buggyDatabase(db)
            XCTAssertFalse(try adjustments(db, f.current).isEmpty, "the buggy conversion left adjustments on Current")

            let report = try Correction.apply(db: db, input: input, now: now)
            XCTAssertEqual(report.conversion.violations, [])

            // Current: opening 1 Dec = column Nov + Nov income; every later balance reproduced without an adjustment.
            XCTAssertEqual(try adjustments(db, f.current), [])
            let currentOpening = try XCTUnwrap(report.conversion.accounts.first { $0.accountId == f.current }?.opening)
            XCTAssertEqual(currentOpening.date, day(2025, 12, 1))
            XCTAssertEqual(currentOpening.balanceMinorUnits, 130_000)
            XCTAssertEqual(currentOpening.note, Correction.correctedNote)
            XCTAssertEqual(try Transaction.filter(Column("accountId") == f.current && Column("rawDescription") == "SAINSBURYS S/MKTS").fetchCount(db), 0)
            XCTAssertEqual(try Transaction.filter(Column("accountId") == f.current && Column("rawDescription") == "Income").fetchCount(db), 3)

            // Saver: the corrected 1 Jan value is dropped for the statement balance, which is
            // restored (same id) and becomes the +20,000 adjustment on 1 Jan.
            let saver = try XCTUnwrap(report.accounts.first { $0.accountId == f.saver })
            XCTAssertEqual(saver.droppedDates, [day(2026, 1, 1)])
            XCTAssertEqual(saver.restoredOtherCount, 1)
            XCTAssertEqual(try adjustments(db, f.saver).map(\.amountMinorUnits), [2_000_000])
            XCTAssertEqual(try adjustments(db, f.saver).map(\.date), [day(2026, 1, 1)])
            let archivedStatement = try XCTUnwrap(try BalanceSnapshotArchive.fetchOne(db, key: f.statementId))
            XCTAssertEqual(archivedStatement.note, "Statement balance — saver.csv")

            // ISA: the market movement moves a month later.
            XCTAssertEqual(try adjustments(db, f.isa).map(\.date), [day(2026, 2, 1)])
            XCTAssertEqual(try adjustments(db, f.isa).map(\.rawDescription), ["Market movement (converted)"])
            XCTAssertEqual(try adjustments(db, f.isa).map(\.amountMinorUnits), [2_000])

            // No old spreadsheet balance is left, live or archived.
            XCTAssertEqual(try BalanceSnapshot.filter(Column("note") == Correction.numbersNote).fetchCount(db), 0)
            XCTAssertEqual(try BalanceSnapshotArchive.filter(Column("note") == Correction.numbersNote).fetchCount(db), 0)

            // Today: unchanged except the EUR account, now in EUR.
            let changes = report.todayChanges
            XCTAssertEqual(changes.map(\.name), ["Euro"])
            XCTAssertEqual(changes.first?.after, 100_000)
            XCTAssertEqual(report.before.today[f.current], report.after.today[f.current])

            // Pay calendar: the forecast 14 Feb salary made February end on the 14th; now the 25th.
            let feb = PayMonth(year: 2026, month: 2)
            XCTAssertEqual(report.before.paydays.first { $0.month == feb }?.closeDate, day(2026, 2, 14))
            XCTAssertEqual(report.after.paydays.first { $0.month == feb }?.closeDate, day(2026, 2, 25))
            XCTAssertEqual(report.after.payMonthOf["2026-02-16"], feb)
            XCTAssertEqual(report.after.payMonthOf["2026-02-20"], feb)

            // Month ends: Current's January end now includes the salary of January (1 Feb = 1,800).
            XCTAssertEqual(report.after.monthEnds[f.current]?["2026-01"] ?? nil, 180_000)
            XCTAssertFalse(report.text.isEmpty)
        }
    }

    func testASecondRunIsRefusedAndChangesNothing() throws {
        let manager = try makeDB()
        try manager.dbQueue.write { db in
            _ = try buggyDatabase(db)
            _ = try Correction.apply(db: db, input: input, now: now)
        }
        let before = try manager.dbQueue.read { db in (try Transaction.fetchCount(db), try BalanceSnapshot.fetchCount(db), try BalanceSnapshotArchive.fetchCount(db)) }
        XCTAssertThrowsError(try manager.dbQueue.write { db in try Correction.apply(db: db, input: input, now: now) }) { error in
            XCTAssertEqual(error as? Correction.CorrectionError, .alreadyCorrected)
        }
        let after = try manager.dbQueue.read { db in (try Transaction.fetchCount(db), try BalanceSnapshot.fetchCount(db), try BalanceSnapshotArchive.fetchCount(db)) }
        XCTAssertTrue(before == after)
    }

    func testAMissingTransactionToDeleteAbortsAndRollsBack() throws {
        let manager = try makeDB()
        try manager.dbQueue.write { db in _ = try buggyDatabase(db) }
        let countBefore = try manager.dbQueue.read { db in try Transaction.fetchCount(db) }
        var bad = input
        bad.deleteTransactions.append(Correction.TransactionToDelete(account: "Lloyds Classic", date: "2026-02-16", description: "NOW AF2B5 Sky Cine", amountMinorUnits: -399))
        XCTAssertThrowsError(try manager.dbQueue.write { db in try Correction.apply(db: db, input: bad, now: now) }) { error in
            guard case .transactionNotFound(_, let matches)? = error as? Correction.CorrectionError else { return XCTFail("\(error)") }
            XCTAssertEqual(matches, 0)
        }
        XCTAssertEqual(try manager.dbQueue.read { db in try Transaction.fetchCount(db) }, countBefore)
    }

    func testRefusesAWrongCurrencyAnUnknownAccountAndAnAccountLeftWithoutValues() throws {
        let manager = try makeDB()
        try manager.dbQueue.write { db in _ = try buggyDatabase(db) }

        var wrongCurrency = input
        wrongCurrency.snapshots[3].currency = "gbp"
        XCTAssertThrowsError(try manager.dbQueue.write { db in try Correction.apply(db: db, input: wrongCurrency, now: now) }) { error in
            XCTAssertEqual(error as? Correction.CorrectionError, .currencyMismatch(account: "Euro", expected: "eur", got: "gbp"))
        }
        var unknown = input
        unknown.snapshots[0].account = "Nope"
        XCTAssertThrowsError(try manager.dbQueue.write { db in try Correction.apply(db: db, input: unknown, now: now) }) { error in
            XCTAssertEqual(error as? Correction.CorrectionError, .unknownAccount("Nope"))
        }
        var missing = input
        missing.snapshots.removeAll { $0.account == "ISA" }
        XCTAssertThrowsError(try manager.dbQueue.write { db in try Correction.apply(db: db, input: missing, now: now) }) { error in
            XCTAssertEqual(error as? Correction.CorrectionError, .missingSpreadsheetValues(account: "ISA"))
        }
    }

    func testRefusesToDeleteALinkedTransaction() throws {
        let manager = try makeDB()
        try manager.dbQueue.write { db in
            let f = try buggyDatabase(db)
            let out = try XCTUnwrap(try Transaction.filter(Column("rawDescription") == "SAINSBURYS S/MKTS").fetchOne(db)?.id)
            let other = try transaction(db, f.saver, day(2026, 2, 16), "IN", 1_000, file: "saver.csv")
            var link = TransferLink(outTransactionId: out, inTransactionId: other, origin: .manual)
            try link.insert(db)
        }
        XCTAssertThrowsError(try manager.dbQueue.write { db in try Correction.apply(db: db, input: input, now: now) }) { error in
            guard case .linkedTransaction? = error as? Correction.CorrectionError else { return XCTFail("\(error)") }
        }
    }
}
