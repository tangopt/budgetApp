import XCTest
import GRDB
@testable import BudgetCore

final class AccountEditingTests: XCTestCase {
    private func day(_ y: Int, _ m: Int, _ d: Int) -> Date {
        MonthRange.calendar.date(from: DateComponents(year: y, month: m, day: d))!
    }
    private func makeDB() throws -> DatabaseManager {
        let m = try DatabaseManager(path: nil)
        try m.migrate()
        return m
    }
    private func snapshots(_ db: Database, _ id: Int64) throws -> [BalanceSnapshot] {
        try BalanceSnapshot.filter(Column("accountId") == id).order(Column("date")).fetchAll(db)
    }
    private func addTxn(_ db: Database, _ accountId: Int64, _ date: Date, _ amount: Int) throws {
        var batch = ImportBatch(accountId: accountId, sourceFileName: "f", importedAt: date)
        try batch.insert(db)
        var t = Transaction(importBatchId: batch.id!, accountId: accountId, date: date, rawDescription: "x", amountMinorUnits: amount, categoryId: nil, status: .confirmed, categorizedBy: .none, fingerprint: UUID().uuidString)
        try t.insert(db)
    }

    func testAddInsertsAndSignsCreditOpeningBalance() throws {
        let m = try makeDB()
        try m.dbQueue.write { db in
            let card = try AccountEditing.add(db: db, name: " Card ", currency: .gbp, kind: .credit, trackingMode: .manual, openingBalanceEntered: 30_000, asOf: day(2026, 10, 7))
            XCTAssertEqual(card.name, "Card")
            XCTAssertNotNil(card.id)
            let s = try snapshots(db, card.id!)
            XCTAssertEqual(s.map(\.balanceMinorUnits), [-30_000])
            XCTAssertEqual(s.map(\.date), [day(2026, 10, 7)])
            let cash = try AccountEditing.add(db: db, name: "Cash", currency: .gbp, kind: .cash, trackingMode: .manual, openingBalanceEntered: nil, asOf: day(2026, 10, 7))
            XCTAssertTrue(try snapshots(db, cash.id!).isEmpty)
        }
    }

    func testAddRejectsEmptyAndDuplicateNames() throws {
        let m = try makeDB()
        try m.dbQueue.write { db in
            XCTAssertThrowsError(try AccountEditing.add(db: db, name: "  ", currency: .gbp, kind: .cash, trackingMode: .manual, openingBalanceEntered: nil, asOf: Date())) { XCTAssertEqual($0 as? AccountEditError, .emptyName) }
            try AccountEditing.add(db: db, name: "A", currency: .gbp, kind: .cash, trackingMode: .manual, openingBalanceEntered: nil, asOf: Date())
            XCTAssertThrowsError(try AccountEditing.add(db: db, name: " A ", currency: .gbp, kind: .cash, trackingMode: .manual, openingBalanceEntered: nil, asOf: Date())) { XCTAssertEqual($0 as? AccountEditError, .duplicateName) }
        }
    }

    func testUpdateRulesAndRename() throws {
        let m = try makeDB()
        try m.dbQueue.write { db in
            let a = try AccountEditing.add(db: db, name: "A", currency: .gbp, kind: .cash, trackingMode: .manual, openingBalanceEntered: 100, asOf: day(2026, 10, 1))
            let b = try AccountEditing.add(db: db, name: "B", currency: .gbp, kind: .cash, trackingMode: .manual, openingBalanceEntered: nil, asOf: day(2026, 10, 1))
            try AccountEditing.update(db: db, accountId: a.id!, name: "A2", kind: .investment, trackingMode: .manual)
            let fetched = try Account.fetchOne(db, key: a.id!)!
            XCTAssertEqual(fetched.name, "A2")
            XCTAssertEqual(fetched.kind, .investment)
            XCTAssertThrowsError(try AccountEditing.update(db: db, accountId: a.id!, name: "A2", kind: .credit, trackingMode: .manual)) { XCTAssertEqual($0 as? AccountEditError, .creditKindChange) }
            XCTAssertThrowsError(try AccountEditing.update(db: db, accountId: a.id!, name: "B", kind: .investment, trackingMode: .manual)) { XCTAssertEqual($0 as? AccountEditError, .duplicateName) }
            XCTAssertThrowsError(try AccountEditing.update(db: db, accountId: 999, name: "Z", kind: .cash, trackingMode: .manual)) { XCTAssertEqual($0 as? AccountEditError, .accountNotFound) }
            XCTAssertFalse(try AccountEditing.hasHistory(db: db, accountId: b.id!))
            try AccountEditing.update(db: db, accountId: b.id!, name: "B", kind: .credit, trackingMode: .manual)
            XCTAssertEqual(try Account.fetchOne(db, key: b.id!)!.kind, .credit)
            XCTAssertTrue(try AccountEditing.hasHistory(db: db, accountId: a.id!))
        }
    }

    func testTransactionsAlsoBlockCreditKindChange() throws {
        let m = try makeDB()
        try m.dbQueue.write { db in
            let a = try AccountEditing.add(db: db, name: "A", currency: .gbp, kind: .cash, trackingMode: .imported, openingBalanceEntered: nil, asOf: Date())
            try addTxn(db, a.id!, day(2026, 10, 1), -100)
            XCTAssertThrowsError(try AccountEditing.update(db: db, accountId: a.id!, name: "A", kind: .credit, trackingMode: .imported)) { XCTAssertEqual($0 as? AccountEditError, .creditKindChange) }
        }
    }

    func testSaveWritesSnapshotsAndSignsCredit() throws {
        let m = try makeDB()
        try m.dbQueue.write { db in
            let a = try AccountEditing.add(db: db, name: "A", currency: .gbp, kind: .cash, trackingMode: .manual, openingBalanceEntered: nil, asOf: Date())
            let c = try AccountEditing.add(db: db, name: "C", currency: .gbp, kind: .credit, trackingMode: .manual, openingBalanceEntered: nil, asOf: Date())
            let w = try BalanceUpdates.save(db: db, entries: [.init(accountId: a.id!, enteredMinorUnits: 500, note: "n"), .init(accountId: c.id!, enteredMinorUnits: 200, note: nil)], asOf: day(2026, 10, 7))
            XCTAssertTrue(w.isEmpty)
            XCTAssertEqual(try snapshots(db, a.id!).map(\.balanceMinorUnits), [500])
            XCTAssertEqual(try snapshots(db, c.id!).map(\.balanceMinorUnits), [-200])
            XCTAssertEqual(try snapshots(db, a.id!).map(\.date), [day(2026, 10, 7)])
        }
    }

    func testImportedDriftWarnsAndManualNever() throws {
        let m = try makeDB()
        try m.dbQueue.write { db in
            let imp = try AccountEditing.add(db: db, name: "Imp", currency: .eur, kind: .cash, trackingMode: .imported, openingBalanceEntered: 1_000, asOf: day(2026, 10, 1))
            let man = try AccountEditing.add(db: db, name: "Man", currency: .gbp, kind: .cash, trackingMode: .manual, openingBalanceEntered: 1_000, asOf: day(2026, 10, 1))
            try addTxn(db, imp.id!, day(2026, 10, 3), -300)
            // computed 700; entering 800 -> drift +100
            let w = try BalanceUpdates.save(db: db, entries: [.init(accountId: imp.id!, enteredMinorUnits: 800, note: nil), .init(accountId: man.id!, enteredMinorUnits: 5, note: nil)], asOf: day(2026, 10, 7))
            XCTAssertEqual(w, [ReconciliationWarning(accountName: "Imp", driftMinorUnits: 100, currency: .eur)])
            XCTAssertEqual(try snapshots(db, imp.id!).count, 2)
            // matching balance -> no warning
            let ok = try BalanceUpdates.save(db: db, entries: [.init(accountId: imp.id!, enteredMinorUnits: 800, note: nil)], asOf: day(2026, 10, 8))
            XCTAssertTrue(ok.isEmpty)
        }
    }

    func testUnknownAccountThrowsAndRollsBack() throws {
        let m = try makeDB()
        var id: Int64 = 0
        try m.dbQueue.write { db in
            id = try AccountEditing.add(db: db, name: "A", currency: .gbp, kind: .cash, trackingMode: .manual, openingBalanceEntered: nil, asOf: Date()).id!
        }
        XCTAssertThrowsError(try m.dbQueue.write { db in
            _ = try BalanceUpdates.save(db: db, entries: [.init(accountId: id, enteredMinorUnits: 1, note: nil), .init(accountId: 999, enteredMinorUnits: 1, note: nil)], asOf: Date())
        }) { XCTAssertEqual($0 as? AccountEditError, .accountNotFound) }
        XCTAssertEqual(try m.dbQueue.read { try BalanceSnapshot.fetchCount($0) }, 0)
    }
}
