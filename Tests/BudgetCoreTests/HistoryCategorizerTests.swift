import XCTest
import GRDB
@testable import BudgetCore

final class HistoryCategorizerTests: XCTestCase {
    func entries(_ pairs: [(String, Int64)]) -> [HistoryEntry] {
        pairs.map { HistoryEntry(merchantKey: $0.0, categoryId: $0.1) }
    }

    func testMajorityOfAtLeastSeventyPercentWins() {
        let history = entries([("TESCO STORES", 1), ("TESCO STORES", 1), ("TESCO STORES", 1), ("TESCO STORES", 2), ("OTHER", 2)])
        let result = HistoryCategorizer.suggest(merchantKey: "TESCO STORES", history: history)
        XCTAssertEqual(result?.categoryId, 1)
        XCTAssertEqual(result?.count, 3)
        XCTAssertEqual(result?.share ?? 0, 0.75, accuracy: 0.0001)
    }

    func testEvenSplitHasNoSuggestion() {
        let history = entries([("TESCO STORES", 1), ("TESCO STORES", 2)])
        XCTAssertNil(HistoryCategorizer.suggest(merchantKey: "TESCO STORES", history: history))
    }

    func testSingleTransactionHasNoSuggestion() {
        let history = entries([("TESCO STORES", 1)])
        XCTAssertNil(HistoryCategorizer.suggest(merchantKey: "TESCO STORES", history: history))
    }

    func testUnknownKeyHasNoSuggestion() {
        XCTAssertNil(HistoryCategorizer.suggest(merchantKey: "NOPE", history: entries([("TESCO STORES", 1), ("TESCO STORES", 1)])))
    }

    func testBelowSeventyPercentHasNoSuggestion() {
        let history = entries([("A", 1), ("A", 1), ("A", 2)])  // 66%
        XCTAssertNil(HistoryCategorizer.suggest(merchantKey: "A", history: history))
    }

    func testLoadReturnsOnlyConfirmedCategorisedTransactionsWithKeys() throws {
        let manager = try DatabaseManager(path: nil)
        try manager.migrate()
        try manager.dbQueue.write { db in try CategorySeeder.seedDefaults(db) }
        try manager.dbQueue.write { db in
            var account = Account(name: "A", currency: .gbp, kind: .cash, trackingMode: .imported)
            try account.insert(db)
            var batch = ImportBatch(accountId: account.id!, sourceFileName: "x.csv", importedAt: Date())
            try batch.insert(db)
            let groceries = try Category.filter(Column("name") == "Groceries").fetchOne(db)!.id!
            func add(_ desc: String, _ cat: Int64?, _ status: TransactionStatus, _ fp: String) throws {
                var t = Transaction(importBatchId: batch.id!, accountId: account.id!, date: Date(), rawDescription: desc, amountMinorUnits: -100, categoryId: cat, status: status, categorizedBy: .manual, fingerprint: fp)
                try t.insert(db)
            }
            try add("TESCO STORES 2041", groceries, .confirmed, "1")
            try add("TESCO STORES 3312", groceries, .confirmed, "2")
            try add("TESCO STORES 9", groceries, .pendingReview, "3")
            try add("UNKNOWN", nil, .pendingReview, "4")
        }
        let history = try manager.dbQueue.read { db in try HistoryCategorizer.load(db: db) }
        XCTAssertEqual(history.map(\.merchantKey), ["TESCO STORES", "TESCO STORES"])
    }
}
