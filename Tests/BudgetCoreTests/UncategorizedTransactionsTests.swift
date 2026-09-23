import XCTest
import GRDB
@testable import BudgetCore

final class UncategorizedTransactionsTests: XCTestCase {
    func testFetchReturnsOnlyUncategorizedOrPendingReview() throws {
        let manager = try DatabaseManager(path: nil)
        try manager.migrate()
        try manager.dbQueue.write { db in
            try CategorySeeder.seedDefaults(db)
            let rent = try Category.filter(Column("name") == "Rent").fetchOne(db)!
            var account = Account(name: "Test", currency: .gbp, kind: .cash, trackingMode: .manual)
            try account.insert(db)
            var batch = ImportBatch(accountId: account.id!, sourceFileName: "x", importedAt: Date())
            try batch.insert(db)
            var confirmed = Transaction(importBatchId: batch.id!, accountId: account.id!, date: Date(), rawDescription: "A", amountMinorUnits: -100, categoryId: rent.id, status: .confirmed, categorizedBy: .manual, fingerprint: "a")
            try confirmed.insert(db)
            var pending = Transaction(importBatchId: batch.id!, accountId: account.id!, date: Date(), rawDescription: "B", amountMinorUnits: -200, categoryId: nil, status: .pendingReview, categorizedBy: .none, fingerprint: "b")
            try pending.insert(db)
        }
        let results = try manager.dbQueue.read { db in try UncategorizedTransactions.fetch(db: db) }
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].rawDescription, "B")
    }

    func testFetchOrdersByDateDescending() throws {
        let manager = try DatabaseManager(path: nil)
        try manager.migrate()
        try manager.dbQueue.write { db in
            var account = Account(name: "Test", currency: .gbp, kind: .cash, trackingMode: .manual)
            try account.insert(db)
            var batch = ImportBatch(accountId: account.id!, sourceFileName: "x", importedAt: Date())
            try batch.insert(db)
            var older = Transaction(importBatchId: batch.id!, accountId: account.id!, date: Date(timeIntervalSince1970: 1000), rawDescription: "Older", amountMinorUnits: -100, categoryId: nil, status: .pendingReview, categorizedBy: .none, fingerprint: "a")
            try older.insert(db)
            var newer = Transaction(importBatchId: batch.id!, accountId: account.id!, date: Date(timeIntervalSince1970: 2000), rawDescription: "Newer", amountMinorUnits: -200, categoryId: nil, status: .pendingReview, categorizedBy: .none, fingerprint: "b")
            try newer.insert(db)
        }
        let results = try manager.dbQueue.read { db in try UncategorizedTransactions.fetch(db: db) }
        XCTAssertEqual(results.map(\.rawDescription), ["Newer", "Older"])
    }
}
