import XCTest
import GRDB
@testable import BudgetCore
import struct BudgetCore.Category
import struct BudgetCore.Transaction
import TestSupport

final class TransactionEditingTests: XCTestCase {
    private func makeDB() throws -> (DatabaseManager, Int64) {
        let m = try TestDatabase.migratedManager()
        let id = try m.dbQueue.write { db -> Int64 in
            var account = Account(name: "Lloyds", currency: .gbp, kind: .cash, trackingMode: .imported)
            try account.insert(db)
            var batch = ImportBatch(accountId: account.id!, sourceFileName: "a.csv", importedAt: Date())
            try batch.insert(db)
            var transaction = Transaction(importBatchId: batch.id!, accountId: account.id!, date: Date(), rawDescription: "NANDOS", amountMinorUnits: -2250,
                                          categoryId: nil, status: .pendingReview, categorizedBy: .none, fingerprint: "f")
            try transaction.insert(db)
            return transaction.id!
        }
        return (m, id)
    }

    private func category(_ m: DatabaseManager, _ name: String, reserved: Bool = false) throws -> Int64 {
        try m.dbQueue.write { db in
            var category = Category(name: name, type: .expense, isReserved: reserved)
            try category.insert(db)
            return category.id!
        }
    }

    func testSettingACategoryConfirmsItAsManualAndSavesTheNote() throws {
        let (m, id) = try makeDB()
        let eatingOut = try category(m, "Eating Out")
        try m.dbQueue.write { db in try TransactionEditing.update(db: db, id: id, categoryId: eatingOut, note: "  Birthday dinner  ") }
        let saved = try m.dbQueue.read { db in try Transaction.fetchOne(db, key: id)! }
        XCTAssertEqual(saved.categoryId, eatingOut)
        XCTAssertEqual(saved.categorizedBy, .manual)
        XCTAssertEqual(saved.status, .confirmed)
        XCTAssertEqual(saved.note, "Birthday dinner")
    }

    func testNoRuleIsLearned() throws {
        let (m, id) = try makeDB()
        let eatingOut = try category(m, "Eating Out")
        try m.dbQueue.write { db in try TransactionEditing.update(db: db, id: id, categoryId: eatingOut, note: nil) }
        XCTAssertEqual(try m.dbQueue.read { db in try Rule.fetchCount(db) }, 0)
    }

    func testABlankNoteClearsIt() throws {
        let (m, id) = try makeDB()
        let eatingOut = try category(m, "Eating Out")
        try m.dbQueue.write { db in try TransactionEditing.update(db: db, id: id, categoryId: eatingOut, note: "x") }
        try m.dbQueue.write { db in try TransactionEditing.update(db: db, id: id, categoryId: eatingOut, note: "  ") }
        XCTAssertNil(try m.dbQueue.read { db in try Transaction.fetchOne(db, key: id)!.note })
    }

    func testClearingTheCategorySendsItBackToReview() throws {
        let (m, id) = try makeDB()
        let eatingOut = try category(m, "Eating Out")
        try m.dbQueue.write { db in try TransactionEditing.update(db: db, id: id, categoryId: eatingOut, note: nil) }
        try m.dbQueue.write { db in try TransactionEditing.update(db: db, id: id, categoryId: nil, note: "later") }
        let saved = try m.dbQueue.read { db in try Transaction.fetchOne(db, key: id)! }
        XCTAssertNil(saved.categoryId)
        XCTAssertEqual(saved.status, .pendingReview)
        XCTAssertEqual(saved.categorizedBy, .none)
        XCTAssertEqual(saved.note, "later")
    }

    func testRefusesUnknownTransactionAndReservedOrUnknownCategory() throws {
        let (m, id) = try makeDB()
        let reserve = try category(m, "Misc reserve", reserved: true)
        XCTAssertThrowsError(try m.dbQueue.write { db in try TransactionEditing.update(db: db, id: 999, categoryId: nil, note: nil) }) { error in
            XCTAssertEqual(error as? TransactionEditError, .transactionNotFound)
        }
        XCTAssertThrowsError(try m.dbQueue.write { db in try TransactionEditing.update(db: db, id: id, categoryId: reserve, note: nil) }) { error in
            XCTAssertEqual(error as? TransactionEditError, .reservedCategory)
        }
        XCTAssertThrowsError(try m.dbQueue.write { db in try TransactionEditing.update(db: db, id: id, categoryId: 999, note: nil) }) { error in
            XCTAssertEqual(error as? TransactionEditError, .categoryNotFound)
        }
    }

    // A note-only edit leaves how the transaction was categorised alone.
    func testANoteOnlyEditKeepsCategorizedByAndStatus() throws {
        let (m, id) = try makeDB()
        let eatingOut = try category(m, "Eating Out")
        try m.dbQueue.write { db in
            var transaction = try Transaction.fetchOne(db, key: id)!
            transaction.categoryId = eatingOut
            transaction.status = .confirmed
            transaction.categorizedBy = .rule
            try transaction.update(db)
            try TransactionEditing.update(db: db, id: id, categoryId: eatingOut, note: "Team lunch")
        }
        let saved = try m.dbQueue.read { db in try Transaction.fetchOne(db, key: id)! }
        XCTAssertEqual(saved.categorizedBy, .rule)
        XCTAssertEqual(saved.status, .confirmed)
        XCTAssertEqual(saved.note, "Team lunch")
    }
}
