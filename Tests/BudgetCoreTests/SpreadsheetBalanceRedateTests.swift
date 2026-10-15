import XCTest
import GRDB
@testable import BudgetCore
import struct BudgetCore.Transaction

/// 2026-10-15 follow-up: the corrected spreadsheet balances move from the 1st of M+1 to the last
/// day of M, and the spreadsheet accounts get a 31 Dec 2019 opening.
final class SpreadsheetBalanceRedateTests: XCTestCase {
    private typealias Redate = SpreadsheetBalanceRedate
    private let now = MonthRange.calendar.date(from: DateComponents(year: 2026, month: 10, day: 15, hour: 9))!
    private let corrected = SpreadsheetBalanceCorrection.correctedNote

    private func day(_ y: Int, _ m: Int, _ d: Int) -> Date {
        MonthRange.calendar.date(from: DateComponents(year: y, month: m, day: d))!
    }
    private func makeDB() throws -> DatabaseManager {
        let m = try DatabaseManager(path: nil)
        try m.migrate()
        return m
    }
    private func account(_ db: Database, _ name: String, currency: Currency = .gbp) throws -> Int64 {
        var account = Account(name: name, currency: currency, kind: .cash, trackingMode: .manual)
        try account.insert(db)
        return account.id!
    }
    private func snapshot(_ db: Database, _ accountId: Int64, _ date: Date, _ balance: Int, note: String) throws {
        var s = BalanceSnapshot(accountId: accountId, date: date, balanceMinorUnits: balance, note: note)
        try s.insert(db)
    }
    private func imported(_ db: Database, _ accountId: Int64, _ date: Date, _ amount: Int) throws {
        var batch = ImportBatch(accountId: accountId, sourceFileName: "statement.csv", importedAt: date)
        try batch.insert(db)
        var t = Transaction(importBatchId: batch.id!, accountId: accountId, date: date, rawDescription: "x", amountMinorUnits: amount, categoryId: nil,
                            status: .confirmed, categorizedBy: .none, fingerprint: UUID().uuidString)
        try t.insert(db)
    }
    private func monthEnd(_ db: Database, _ accountId: Int64, _ y: Int, _ m: Int) throws -> Int? {
        NetWorthCalculator.balance(accountId: accountId, at: MonthRange.of(year: y, month: m).end,
                                   snapshots: try BalanceSnapshot.fetchAll(db), transactions: try Transaction.fetchAll(db))?.native
    }
    private func adjustmentDates(_ db: Database, _ accountId: Int64) throws -> [Date] {
        try Transaction.filter(Column("accountId") == accountId && Column("note") == BalanceConversion.adjustmentNote).order(Column("date")).fetchAll(db).map(\.date)
    }

    private struct Fixture { var current: Int64 = 0; var international: Int64 = 0; var euro: Int64 = 0; var revolut: Int64 = 0 }

    /// The state CorrectSpreadsheetBalances leaves: corrected column values (Jan–Mar 2020) dated
    /// the 1st of the next month, a statement balance (1 May 2020) and later imports, converted.
    private func fixture(_ db: Database, firstOfMonthImport: Bool = false) throws -> Fixture {
        var f = Fixture()
        f.current = try account(db, "Lloyds Classic")
        try imported(db, f.current, day(2020, 1, 16), -202_418)
        try snapshot(db, f.current, day(2020, 2, 1), 850_675, note: corrected)
        try imported(db, f.current, day(2020, 2, 15), 10_000)
        try snapshot(db, f.current, day(2020, 3, 1), 870_675, note: corrected)   // +10,000 adjustment
        if firstOfMonthImport { try imported(db, f.current, day(2020, 3, 1), -5_000) }
        try imported(db, f.current, day(2020, 3, 15), -1_000)
        try snapshot(db, f.current, day(2020, 4, 1), 869_675, note: corrected)   // no adjustment (without the 1st-of-month import)
        try snapshot(db, f.current, day(2020, 5, 1), 900_000, note: "Statement balance — s.csv")
        try imported(db, f.current, day(2026, 4, 10), 2_500)

        f.international = try account(db, "Lloyds International Premier GBP")
        try snapshot(db, f.international, day(2020, 2, 1), 248_533, note: corrected)
        try snapshot(db, f.international, day(2020, 3, 1), 276_513, note: corrected)
        try snapshot(db, f.international, day(2020, 4, 1), 300_000, note: corrected)
        try snapshot(db, f.international, day(2026, 5, 1), 350_000, note: "Statement balance — i.csv")

        f.euro = try account(db, "Lloyds International Account (EUR)", currency: .eur)
        try snapshot(db, f.euro, day(2020, 2, 1), 261_340, note: corrected)
        try snapshot(db, f.euro, day(2020, 3, 1), 261_340, note: corrected)

        f.revolut = try account(db, "Revolut")
        try imported(db, f.revolut, day(2025, 9, 15), 4_000)

        try BalanceConversion.convert(db: db, now: now)
        return f
    }

    private let openings = [
        Redate.Opening(account: "Lloyds Classic", valueMinorUnits: nil),
        Redate.Opening(account: "Lloyds International Premier GBP", valueMinorUnits: 208_359),
        Redate.Opening(account: "Lloyds International Account (EUR)", valueMinorUnits: 261_340),
    ]

    func testCorrectedBalancesMoveToTheMonthEndAndStatementAdjustmentsStay() throws {
        let manager = try makeDB()
        try manager.dbQueue.write { db in
            let f = try fixture(db)
            // Before: the end of February shows January's value.
            XCTAssertEqual(try monthEnd(db, f.international, 2020, 2), 248_533)
            XCTAssertEqual(try adjustmentDates(db, f.international), [day(2020, 3, 1), day(2020, 4, 1), day(2026, 5, 1)])
            XCTAssertEqual(try adjustmentDates(db, f.current), [day(2020, 3, 1), day(2020, 5, 1)])

            let report = try Redate.apply(db: db, openings: openings, now: now)

            XCTAssertEqual(try adjustmentDates(db, f.international), [day(2020, 1, 31), day(2020, 2, 29), day(2020, 3, 31), day(2026, 5, 1)])
            XCTAssertEqual(try adjustmentDates(db, f.current), [day(2020, 2, 29), day(2020, 5, 1)])
            XCTAssertEqual(try monthEnd(db, f.international, 2020, 1), 248_533)
            XCTAssertEqual(try monthEnd(db, f.international, 2020, 2), 276_513)
            XCTAssertEqual(try monthEnd(db, f.international, 2020, 3), 300_000)
            XCTAssertEqual(try monthEnd(db, f.current, 2020, 1), 850_675)
            XCTAssertEqual(try monthEnd(db, f.current, 2020, 2), 870_675)
            XCTAssertEqual(try monthEnd(db, f.current, 2020, 3), 869_675)
            XCTAssertEqual(try monthEnd(db, f.current, 2020, 4), 869_675)   // the 1 May statement balance stays in May
            XCTAssertEqual(try monthEnd(db, f.current, 2020, 5), 900_000)

            let archivedDays = try BalanceSnapshotArchive.filter(Column("accountId") == f.international && Column("note") == corrected)
                .order(Column("date")).fetchAll(db).map(\.date)
            XCTAssertEqual(archivedDays, [day(2020, 1, 31), day(2020, 2, 29), day(2020, 3, 31)])
            let statement = try BalanceSnapshotArchive.filter(Column("accountId") == f.international && Column("note") != corrected).fetchAll(db)
            XCTAssertEqual(statement.map(\.date), [day(2026, 5, 1)])

            let international = try XCTUnwrap(report.accounts.first { $0.accountId == f.international })
            XCTAssertEqual(international.movedAdjustmentCount, 2)
            XCTAssertEqual(international.movedRecordedCount, 3)
            XCTAssertEqual(international.keptAdjustmentCount, 1)
            XCTAssertEqual(report.before.unbounded, report.after.unbounded)
            XCTAssertEqual(report.before.dayEnds, report.after.dayEnds)
        }
    }

    func testOpeningsOn31December2019() throws {
        let manager = try makeDB()
        try manager.dbQueue.write { db in
            let f = try fixture(db)
            let report = try Redate.apply(db: db, openings: openings, now: now)

            let live = try BalanceSnapshot.order(Column("accountId")).fetchAll(db)
            XCTAssertEqual(live.map(\.accountId), [f.current, f.international, f.euro])
            XCTAssertEqual(Set(live.map(\.date)), [day(2019, 12, 31)])
            XCTAssertEqual(Set(live.map(\.note)), [Redate.openingNote])
            // Current: the January 2020 value minus January's transactions; no adjustment needed.
            XCTAssertEqual(live[0].balanceMinorUnits, 850_675 + 202_418)
            // International: column D; the January difference is an adjustment on 31 Jan 2020.
            XCTAssertEqual(live[1].balanceMinorUnits, 208_359)
            XCTAssertEqual(live[2].balanceMinorUnits, 261_340)

            for id in [f.current, f.international, f.euro] {
                XCTAssertEqual(try monthEnd(db, id, 2019, 12), live.first { $0.accountId == id }?.balanceMinorUnits)
            }
            XCTAssertEqual(try monthEnd(db, f.current, 2020, 1), 850_675)
            XCTAssertEqual(try monthEnd(db, f.international, 2020, 1), 248_533)
            XCTAssertEqual(try monthEnd(db, f.euro, 2020, 1), 261_340)

            let current = try XCTUnwrap(report.accounts.first { $0.accountId == f.current })
            XCTAssertEqual(current.newOpening?.value, 1_053_093)
            XCTAssertEqual(current.oldOpening?.date, day(2020, 1, 31))
            XCTAssertTrue(current.newAdjustments.isEmpty)
            let international = try XCTUnwrap(report.accounts.first { $0.accountId == f.international })
            XCTAssertEqual(international.newAdjustments.map(\.date), [day(2020, 1, 31)])
            XCTAssertEqual(international.newAdjustments.map(\.amount), [248_533 - 208_359])
            let oldOpening = try BalanceSnapshotArchive.filter(Column("accountId") == f.current && Column("date") == day(2020, 1, 31)).fetchOne(db)
            XCTAssertEqual(oldOpening?.balanceMinorUnits, 850_675)
            XCTAssertEqual(oldOpening?.note, corrected)

            // Revolut untouched; year ends: 2019 gains the openings.
            XCTAssertEqual(try BalanceSnapshot.filter(Column("accountId") == f.revolut).fetchCount(db), 0)
            XCTAssertNil(report.before.yearEnds[2019] ?? nil)
            XCTAssertNotNil(report.after.yearEnds[2019] ?? nil)
            XCTAssertTrue(report.text.contains("Year-end net worth"))
        }
    }

    func testRefusesASecondRun() throws {
        let manager = try makeDB()
        try manager.dbQueue.write { db in
            _ = try fixture(db)
            _ = try Redate.apply(db: db, openings: openings, now: now)
            XCTAssertThrowsError(try Redate.apply(db: db, openings: openings, now: now)) { error in
                XCTAssertEqual(error as? Redate.RedateError, .alreadyApplied)
            }
        }
    }

    func testATransactionOnTheFirstBreaksTheMonthEndAndAborts() throws {
        let manager = try makeDB()
        try manager.dbQueue.write { db in
            _ = try fixture(db, firstOfMonthImport: true)
            XCTAssertThrowsError(try Redate.apply(db: db, openings: openings, now: now)) { error in
                guard case .invariantViolated(let violations)? = error as? Redate.RedateError else { return XCTFail("\(error)") }
                XCTAssertTrue(violations.contains { $0.contains("2020-02 month end") }, "\(violations)")
            }
        }
    }

    func testEveryCorrectedOpeningNeedsA2019Opening() throws {
        let manager = try makeDB()
        try manager.dbQueue.write { db in
            _ = try fixture(db)
            XCTAssertThrowsError(try Redate.apply(db: db, openings: Array(openings.prefix(2)), now: now)) { error in
                XCTAssertEqual(error as? Redate.RedateError, .missingOpening("Lloyds International Account (EUR)"))
            }
            XCTAssertThrowsError(try Redate.apply(db: db, openings: openings + [Redate.Opening(account: "Nope", valueMinorUnits: 0)], now: now)) { error in
                XCTAssertEqual(error as? Redate.RedateError, .unknownAccount("Nope"))
            }
        }
    }

    func testDefaultOpeningsMatchTheSpreadsheetColumnD() {
        XCTAssertEqual(Redate.defaultOpenings.map(\.account), ["Lloyds Classic", "Lloyds International Premier GBP", "Lloyds Club Joint",
                                                             "Lloyds Advantage ISA Saver", "Lloyds Investment ISA", "Lloyds International Account (EUR)"])
        XCTAssertEqual(Redate.defaultOpenings.map(\.valueMinorUnits), [nil, 208_359, 0, 0, 0, 261_340])
    }
}
