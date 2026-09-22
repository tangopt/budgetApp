// Tests/BudgetCoreTests/ImportCoordinatorPDFTests.swift
import XCTest
import GRDB
@testable import BudgetCore

final class ImportCoordinatorPDFTests: XCTestCase {
    func testStagePDFImportCategorizesAndDedups() async throws {
        let manager = try DatabaseManager(path: nil)
        try manager.migrate()
        try await manager.dbQueue.write { db in try CategorySeeder.seedDefaults(db) }
        var account = Account(name: "Lloyds Classic", currency: .gbp, kind: .cash, trackingMode: .imported)
        try await manager.dbQueue.write { db in try account.insert(db) }
        let groceries = try await manager.dbQueue.read { db in try Category.filter(Column("name") == "Groceries").fetchOne(db)! }
        try await manager.dbQueue.write { db in
            var rule = Rule(matchPattern: "SAINSBURYS", matchType: .contains, categoryId: groceries.id!, priority: 10)
            try rule.insert(db)
        }

        let coordinator = ImportCoordinator(dbQueue: manager.dbQueue, categorizationService: CategorizationService(categorizer: FakeCategorizer()))
        let config = PDFLayoutConfig(regexPattern: #"^(\d{2} \w{3} \d{2})\s+(.+?)\s+([\d.]+)\s*(?:DR|CR)?$"#, dateFormat: "dd MMM yy")
        let lines = ["01 Jul 26   SAINSBURYS LONDON SW1        45.64 DR"]

        let staged = try await coordinator.stagePDFImport(lines: lines, config: config, accountId: account.id!)
        XCTAssertEqual(staged.staged.count, 1)
        XCTAssertEqual(staged.staged[0].suggestedCategoryId, groceries.id)

        let decisions = [ImportDecision(stagedId: staged.staged[0].id, finalCategoryId: groceries.id)]
        try coordinator.commit(accountId: account.id!, sourceFileName: "statement.pdf", staged: staged.staged, decisions: decisions)

        let restaged = try await coordinator.stagePDFImport(lines: lines, config: config, accountId: account.id!)
        XCTAssertEqual(restaged.staged.count, 0)
        XCTAssertEqual(restaged.duplicateCount, 1)
    }
}
