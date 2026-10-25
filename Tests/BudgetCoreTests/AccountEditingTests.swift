import XCTest
import GRDB
@testable import BudgetCore
import TestSupport

final class AccountEditingTests: XCTestCase {
    private func day(_ y: Int, _ m: Int, _ d: Int) -> Date {
        MonthRange.calendar.date(from: DateComponents(year: y, month: m, day: d))!
    }
    private func makeDB() throws -> DatabaseManager {
        return try TestDatabase.migratedManager()
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

    func testAliasOnlyUpdateKeepsBankNameBICAndRoutingNumber() throws {
        let m = try makeDB()
        try m.dbQueue.write { db in
            let a = try AccountEditing.add(db: db, name: "A", currency: .gbp, kind: .cash, openingBalanceEntered: nil, asOf: Date(),
                                           details: AccountDetails(region: .us, bankName: "Chase", routingNumber: "021000021", bic: "CHASUS33"))
            try AccountEditing.update(db: db, accountId: a.id!, name: "A", kind: .cash, details: AccountDetails(alias: "Joint"))
            let fetched = try Account.fetchOne(db, key: a.id!)!
            XCTAssertEqual(fetched.alias, "Joint")
            XCTAssertEqual(fetched.bankName, "Chase")
            XCTAssertEqual(fetched.bic, "CHASUS33")
            XCTAssertEqual(fetched.routingNumber, "021000021")
        }
    }
}
