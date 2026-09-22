import XCTest
import GRDB
@testable import BudgetCore

final class TransactionTests: XCTestCase {
    func testInsertBatchAndTransaction() throws {
        let manager = try DatabaseManager(path: nil)
        try manager.migrate()
        var account = Account(name: "Lloyds Classic", currency: .gbp, kind: .cash, trackingMode: .imported)
        try manager.dbQueue.write { db in try account.insert(db) }

        var batch = ImportBatch(accountId: account.id!, sourceFileName: "july.csv", importedAt: Date())
        try manager.dbQueue.write { db in try batch.insert(db) }

        var transaction = Transaction(
            importBatchId: batch.id!,
            accountId: account.id!,
            date: Date(),
            rawDescription: "SAINSBURYS LONDON",
            amountMinorUnits: -4564,
            categoryId: nil,
            status: .pendingReview,
            categorizedBy: .none,
            fingerprint: "abc123"
        )
        try manager.dbQueue.write { db in try transaction.insert(db) }

        let fetched = try manager.dbQueue.read { db in
            try Transaction.filter(Column("fingerprint") == "abc123").fetchOne(db)
        }
        XCTAssertEqual(fetched?.amountMinorUnits, -4564)
        XCTAssertEqual(fetched?.status, .pendingReview)
    }

    func testFingerprintMustBeUniquePerAccount() throws {
        let manager = try DatabaseManager(path: nil)
        try manager.migrate()
        var account = Account(name: "Lloyds Classic", currency: .gbp, kind: .cash, trackingMode: .imported)
        try manager.dbQueue.write { db in try account.insert(db) }
        var batch = ImportBatch(accountId: account.id!, sourceFileName: "a.csv", importedAt: Date())
        try manager.dbQueue.write { db in try batch.insert(db) }

        var t1 = Transaction(importBatchId: batch.id!, accountId: account.id!, date: Date(), rawDescription: "X", amountMinorUnits: -100, categoryId: nil, status: .pendingReview, categorizedBy: .none, fingerprint: "dup")
        try manager.dbQueue.write { db in try t1.insert(db) }

        var t2 = Transaction(importBatchId: batch.id!, accountId: account.id!, date: Date(), rawDescription: "X", amountMinorUnits: -100, categoryId: nil, status: .pendingReview, categorizedBy: .none, fingerprint: "dup")
        XCTAssertThrowsError(try manager.dbQueue.write { db in try t2.insert(db) })
    }
}
