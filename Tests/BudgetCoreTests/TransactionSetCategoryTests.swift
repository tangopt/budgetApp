import XCTest
import GRDB
@testable import BudgetCore
import struct BudgetCore.Category
import struct BudgetCore.Transaction

final class TransactionSetCategoryTests: XCTestCase {
    private func makeDB() throws -> (DatabaseManager, [Int64], Int64, Int64) {
        let m = try DatabaseManager(path: nil)
        try m.migrate()
        let result = try m.dbQueue.write { db -> ([Int64], Int64, Int64) in
            var account = Account(name: "Lloyds", currency: .gbp, kind: .cash, trackingMode: .imported)
            try account.insert(db)
            var batch = ImportBatch(accountId: account.id!, sourceFileName: "a.csv", importedAt: Date())
            try batch.insert(db)
            var eatingOut = Category(name: "Eating Out", type: .expense)
            try eatingOut.insert(db)
            var reserve = Category(name: "Holiday", type: .expense, isReserved: true)
            try reserve.insert(db)
            var ids: [Int64] = []
            for (index, description) in ["NANDOS LONDON", "PRET A MANGER"].enumerated() {
                var transaction = Transaction(importBatchId: batch.id!, accountId: account.id!, date: Date(), rawDescription: description,
                                              amountMinorUnits: -2250, categoryId: nil, status: .pendingReview, categorizedBy: .none,
                                              fingerprint: "f\(index)", note: index == 0 ? "Lunch" : nil)
                try transaction.insert(db)
                ids.append(transaction.id!)
            }
            return (ids, eatingOut.id!, reserve.id!)
        }
        return (m, result.0, result.1, result.2)
    }

    func testSetsEachTransactionConfirmedAndManualKeepingNotes() throws {
        let (m, ids, eatingOut, _) = try makeDB()
        try m.dbQueue.write { db in try TransactionEditing.setCategory(db: db, ids: ids, categoryId: eatingOut, remember: false) }
        let saved = try m.dbQueue.read { db in try Transaction.fetchAll(db, keys: ids) }
        XCTAssertEqual(saved.map(\.categoryId), [eatingOut, eatingOut])
        XCTAssertEqual(saved.map(\.status), [.confirmed, .confirmed])
        XCTAssertEqual(saved.map(\.categorizedBy), [.manual, .manual])
        XCTAssertEqual(saved.map(\.note), ["Lunch", nil])
        XCTAssertEqual(try m.dbQueue.read { db in try Rule.fetchCount(db) }, 0)
    }

    func testRememberLearnsARulePerMerchant() throws {
        let (m, ids, eatingOut, _) = try makeDB()
        try m.dbQueue.write { db in try TransactionEditing.setCategory(db: db, ids: ids, categoryId: eatingOut, remember: true) }
        let rules = try m.dbQueue.read { db in try Rule.fetchAll(db) }
        XCTAssertEqual(rules.count, 2)
        XCTAssertTrue(rules.allSatisfy { $0.categoryId == eatingOut })
    }

    func testRefusesAReserveAndWritesNothing() throws {
        let (m, ids, _, reserve) = try makeDB()
        XCTAssertThrowsError(try m.dbQueue.write { db in try TransactionEditing.setCategory(db: db, ids: ids, categoryId: reserve, remember: true) }) { error in
            XCTAssertEqual(error as? TransactionEditError, .reservedCategory)
        }
        let saved = try m.dbQueue.read { db in try Transaction.fetchAll(db, keys: ids) }
        XCTAssertEqual(saved.map(\.categoryId), [nil, nil])
    }

    func testAMissingTransactionThrows() throws {
        let (m, _, eatingOut, _) = try makeDB()
        XCTAssertThrowsError(try m.dbQueue.write { db in try TransactionEditing.setCategory(db: db, ids: [999], categoryId: eatingOut, remember: false) }) { error in
            XCTAssertEqual(error as? TransactionEditError, .transactionNotFound)
        }
    }

    func testSkipsAndCountsBuiltInRowsWithoutLearning() throws {
        let (m, ids, eatingOut, _) = try makeDB()
        let builtInId = try m.dbQueue.write { db -> Int64 in
            let adjustment = try Category.filter(Column("builtInRole") == CategoryBuiltInRole.balanceAdjustment.rawValue).fetchOne(db)!
            try db.execute(sql: "UPDATE transaction_ SET categoryId = ? WHERE id = ?", arguments: [adjustment.id!, ids[0]])
            return adjustment.id!
        }
        let result = try m.dbQueue.write { db in try TransactionEditing.setCategory(db: db, ids: ids, categoryId: eatingOut, remember: true) }
        XCTAssertEqual(result, SetCategoryResult(updatedCount: 1, skippedBuiltInCount: 1))
        let saved = try m.dbQueue.read { db in try Transaction.fetchAll(db, keys: ids) }
        XCTAssertEqual(saved.map(\.categoryId), [builtInId, eatingOut])
        let rules = try m.dbQueue.read { db in try Rule.fetchAll(db) }
        XCTAssertEqual(rules.count, 1)
        XCTAssertFalse(rules.contains { $0.matchPattern.contains("NANDOS") })
    }

    func testRefusesABuiltInTarget() throws {
        let (m, ids, _, _) = try makeDB()
        let builtInId = try m.dbQueue.write { db -> Int64 in
            let movement = try Category.filter(Column("builtInRole") == CategoryBuiltInRole.marketMovement.rawValue).fetchOne(db)!
            return movement.id!
        }
        XCTAssertThrowsError(try m.dbQueue.write { db in try TransactionEditing.setCategory(db: db, ids: ids, categoryId: builtInId, remember: false) }) { error in
            XCTAssertEqual(error as? TransactionEditError, .builtInCategory)
        }
    }

    func testNeverLearnsFromActiveTransferLegs() throws {
        let (m, ids, eatingOut, _) = try makeDB()
        try m.dbQueue.write { db in
            var link = TransferLink(outTransactionId: ids[0], inTransactionId: ids[1], origin: .manual)
            try link.insert(db)
        }
        let result = try m.dbQueue.write { db in try TransactionEditing.setCategory(db: db, ids: ids, categoryId: eatingOut, remember: true) }
        XCTAssertEqual(result.updatedCount, 2)
        XCTAssertEqual(try m.dbQueue.read { db in try Rule.fetchCount(db) }, 0)
    }

    func testADismissedLinkDoesNotStopLearning() throws {
        let (m, ids, eatingOut, _) = try makeDB()
        try m.dbQueue.write { db in
            var link = TransferLink(outTransactionId: ids[0], inTransactionId: ids[1], origin: .auto, isDismissed: true)
            try link.insert(db)
        }
        try m.dbQueue.write { db in try TransactionEditing.setCategory(db: db, ids: ids, categoryId: eatingOut, remember: true) }
        XCTAssertEqual(try m.dbQueue.read { db in try Rule.fetchCount(db) }, 2)
    }
}

final class TransactionEditBuiltInTests: XCTestCase {
    func testEditRefusesABuiltInTargetWithItsOwnMessage() throws {
        let m = try DatabaseManager(path: nil)
        try m.migrate()
        let (id, builtInId) = try m.dbQueue.write { db -> (Int64, Int64) in
            var account = Account(name: "Lloyds", currency: .gbp, kind: .cash, trackingMode: .imported)
            try account.insert(db)
            var batch = ImportBatch(accountId: account.id!, sourceFileName: "a.csv", importedAt: Date())
            try batch.insert(db)
            var transaction = Transaction(importBatchId: batch.id!, accountId: account.id!, date: Date(), rawDescription: "X",
                                          amountMinorUnits: -1, categoryId: nil, status: .pendingReview, categorizedBy: .none, fingerprint: "x")
            try transaction.insert(db)
            let builtIn = try Category.filter(Column("builtInRole") == CategoryBuiltInRole.balanceAdjustment.rawValue).fetchOne(db)!
            return (transaction.id!, builtIn.id!)
        }
        XCTAssertThrowsError(try m.dbQueue.write { db in try TransactionEditing.update(db: db, id: id, categoryId: builtInId, note: nil) }) { error in
            XCTAssertEqual(error as? TransactionEditError, .builtInCategory)
            XCTAssertFalse(error.localizedDescription.contains("Reserved"))
        }
    }
}
