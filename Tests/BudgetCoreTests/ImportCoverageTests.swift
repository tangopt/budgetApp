import XCTest
@testable import BudgetCore
import struct BudgetCore.Transaction
import struct BudgetCore.Category

/// "Imported up to": the latest date of a statement-imported transaction per account.
final class ImportCoverageTests: XCTestCase {
    private typealias F = DashboardFixture
    private func date(_ y: Int, _ m: Int, _ d: Int) -> Date { F.date(y, m, d) }

    private let adjustmentId: Int64 = 900
    private let movementId: Int64 = 901
    private var categories: [Category] {
        [Category(id: adjustmentId, name: "Balance adjustment", type: .adjustment, builtInRole: .balanceAdjustment),
         Category(id: movementId, name: "Market movement", type: .adjustment, builtInRole: .marketMovement),
         Category(id: F.rentId, name: "Rent", type: .expense)]
    }
    private let batches = [
        ImportBatch(id: 1, accountId: 1, sourceFileName: "oct.csv", importedAt: Date(timeIntervalSince1970: 0)),
        ImportBatch(id: 2, accountId: 1, sourceFileName: ManualTransactions.batchSourceFileName, importedAt: Date(timeIntervalSince1970: 0)),
        ImportBatch(id: 3, accountId: 1, sourceFileName: "History.numbers", importedAt: Date(timeIntervalSince1970: 0)),
        ImportBatch(id: 4, accountId: 2, sourceFileName: "isa.pdf", importedAt: Date(timeIntervalSince1970: 0)),
        ImportBatch(id: 5, accountId: 3, sourceFileName: "Budget.NUMBERS", importedAt: Date(timeIntervalSince1970: 0)),
    ]

    private func txn(_ id: Int64, _ day: Date, batch: Int64, account: Int64 = 1, category: Int64? = nil, manual: Bool = false) -> Transaction {
        var t = F.txn(id, day, -100, category: category, account: account)
        t.importBatchId = batch
        t.isManual = manual
        return t
    }

    func testLatestImportedDateIgnoringManualAdjustmentsAndSpreadsheetHistory() {
        let transactions = [
            txn(1, date(2026, 10, 12), batch: 1, category: F.rentId),
            txn(2, date(2026, 9, 1), batch: 1),
            txn(3, date(2026, 10, 20), batch: 2, manual: true),                          // manual entry
            txn(4, date(2026, 10, 25), batch: 1, category: adjustmentId),               // adjustment, even if not manual
            txn(5, date(2026, 11, 1), batch: 3),                                         // spreadsheet history
            txn(6, date(2026, 10, 30), batch: 1, manual: true),                          // flagged manual
            txn(7, date(2026, 12, 1), batch: 4, account: 2),                             // another account
        ]
        XCTAssertEqual(ImportCoverage.importedThrough(accountId: 1, transactions: transactions, batches: batches, categories: categories), date(2026, 10, 12))
        XCTAssertEqual(ImportCoverage.importedThrough(accountId: 2, transactions: transactions, batches: batches, categories: categories), date(2026, 12, 1))
        XCTAssertNil(ImportCoverage.importedThrough(accountId: 3, transactions: transactions, batches: batches, categories: categories))
    }

    func testInvestmentMarketMovementAndHistoryOnlyMeanNotImported() {
        let transactions = [
            txn(1, date(2026, 10, 1), batch: 4, account: 2, category: movementId),
            txn(2, date(2026, 10, 2), batch: 5, account: 3),
        ]
        XCTAssertNil(ImportCoverage.importedThrough(accountId: 2, transactions: transactions, batches: batches, categories: categories))
        XCTAssertNil(ImportCoverage.importedThrough(accountId: 3, transactions: transactions, batches: batches, categories: categories))
        XCTAssertTrue(ImportCoverage.importedThroughByAccount(transactions: transactions, batches: batches, categories: categories).isEmpty)
    }

    func testPerAccountMap() {
        let transactions = [
            txn(1, date(2026, 10, 12), batch: 1),
            txn(2, date(2026, 10, 3), batch: 1),
            txn(3, date(2026, 8, 5), batch: 4, account: 2),
            txn(4, date(2026, 9, 5), batch: 4, account: 2, manual: true),
        ]
        XCTAssertEqual(ImportCoverage.importedThroughByAccount(transactions: transactions, batches: batches, categories: categories),
                       [1: date(2026, 10, 12), 2: date(2026, 8, 5)])
    }
}
