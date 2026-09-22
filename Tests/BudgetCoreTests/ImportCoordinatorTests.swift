import XCTest
import GRDB
@testable import BudgetCore

final class ImportCoordinatorTests: XCTestCase {
    func makeSeededManager() throws -> (DatabaseManager, Account, ImportProfile) {
        let manager = try DatabaseManager(path: nil)
        try manager.migrate()
        try manager.dbQueue.write { db in try CategorySeeder.seedDefaults(db) }
        var account = Account(name: "Lloyds Classic", currency: .gbp, kind: .cash, trackingMode: .imported)
        try manager.dbQueue.write { db in try account.insert(db) }
        let profile = ImportProfile(accountId: account.id!, format: .csv, csvDelimiter: ",", csvDateColumnIndex: 0, csvDescriptionColumnIndex: 1, csvAmountColumnIndex: 2, csvDateFormat: "dd/MM/yyyy")
        return (manager, account, profile)
    }

    func testStagingCategorizesViaRuleAndSkipsExistingDuplicates() async throws {
        let (manager, account, profile) = try makeSeededManager()
        let groceries = try await manager.dbQueue.read { db in try Category.filter(Column("name") == "Groceries").fetchOne(db)! }
        try await manager.dbQueue.write { db in
            var rule = Rule(matchPattern: "SAINSBURYS", matchType: .contains, categoryId: groceries.id!, priority: 10)
            try rule.insert(db)
        }
        let fake = FakeCategorizer()
        let service = CategorizationService(categorizer: fake)
        let coordinator = ImportCoordinator(dbQueue: manager.dbQueue, categorizationService: service)

        let csv = "Date,Description,Amount\n01/07/2026,SAINSBURYS LONDON,-45.64\n02/07/2026,UNKNOWN SHOP,-10.00"
        let staged = try await coordinator.stageCSVImport(csvText: csv, profile: profile, accountId: account.id!)
        XCTAssertEqual(staged.staged.count, 2)
        XCTAssertEqual(staged.staged[0].suggestedCategoryId, groceries.id)
        XCTAssertEqual(staged.staged[0].source, .rule)
        XCTAssertEqual(staged.staged[1].suggestedCategoryId, nil)

        // Commit, then re-stage the same CSV — should be skipped as duplicates.
        let decisions = staged.staged.map { ImportDecision(stagedId: $0.id, finalCategoryId: $0.suggestedCategoryId ?? groceries.id!) }
        try coordinator.commit(accountId: account.id!, sourceFileName: "july.csv", staged: staged.staged, decisions: decisions)

        let restaged = try await coordinator.stageCSVImport(csvText: csv, profile: profile, accountId: account.id!)
        XCTAssertEqual(restaged.staged.count, 0)
        XCTAssertEqual(restaged.duplicateCount, 2)
    }

    func testCorrectingASuggestionCreatesARule() async throws {
        let (manager, account, profile) = try makeSeededManager()
        let eatingOut = try await manager.dbQueue.read { db in try Category.filter(Column("name") == "Eating Out").fetchOne(db)! }
        let fake = FakeCategorizer()
        fake.stubbedSuggestion = nil
        let service = CategorizationService(categorizer: fake)
        let coordinator = ImportCoordinator(dbQueue: manager.dbQueue, categorizationService: service)

        let csv = "Date,Description,Amount\n01/07/2026,NANDOS CROYDON,-22.50"
        let staged = try await coordinator.stageCSVImport(csvText: csv, profile: profile, accountId: account.id!)
        XCTAssertNil(staged.staged[0].suggestedCategoryId)

        let decisions = [ImportDecision(stagedId: staged.staged[0].id, finalCategoryId: eatingOut.id!)]
        try coordinator.commit(accountId: account.id!, sourceFileName: "july.csv", staged: staged.staged, decisions: decisions)

        let rules = try await manager.dbQueue.read { db in try Rule.fetchAll(db) }
        XCTAssertTrue(rules.contains { $0.matchPattern.contains("NANDOS CROYDON") && $0.categoryId == eatingOut.id })
    }
}
