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

    func makeCoordinator(_ manager: DatabaseManager) -> ImportCoordinator {
        ImportCoordinator(dbQueue: manager.dbQueue, categorizationService: CategorizationService(categorizer: FakeCategorizer()))
    }

    func acceptAll(_ staged: StagedImport) -> [ImportDecision] {
        staged.staged.map { ImportDecision(stagedId: $0.id, finalCategoryId: $0.suggestedCategoryId) }
    }

    // C1 probe: two identical-looking rows in one statement (two £3.30 coffees, same
    // shop, same day) used to share a fingerprint; the second insert violated the
    // unique key and the whole commit silently rolled back.
    func testIdenticalRowsWithinOneStatementAreAllCommittedAndStillDedupOnReimport() async throws {
        let (manager, account, profile) = try makeSeededManager()
        let coordinator = makeCoordinator(manager)
        let csv = "Date,Description,Amount\n03/07/2026,PRET A MANGER,-3.30\n03/07/2026,PRET A MANGER,-3.30\n04/07/2026,TESCO,-12.00"

        let staged = try await coordinator.stageCSVImport(csvText: csv, profile: profile, accountId: account.id!)
        XCTAssertEqual(staged.staged.count, 3)
        XCTAssertEqual(Set(staged.staged.map(\.fingerprint)).count, 3)
        try coordinator.commit(accountId: account.id!, sourceFileName: "july.csv", staged: staged.staged, decisions: acceptAll(staged))

        let count = try await manager.dbQueue.read { db in try Transaction.fetchCount(db) }
        XCTAssertEqual(count, 3)

        // Re-importing the same statement: both coffees are recognised as duplicates.
        let restaged = try await coordinator.stageCSVImport(csvText: csv, profile: profile, accountId: account.id!)
        XCTAssertEqual(restaged.staged.count, 0)
        XCTAssertEqual(restaged.duplicateCount, 3)

        // An overlapping statement with a third identical coffee: only the new one stages.
        let overlapping = csv + "\n03/07/2026,PRET A MANGER,-3.30"
        let overlapStaged = try await coordinator.stageCSVImport(csvText: overlapping, profile: profile, accountId: account.id!)
        XCTAssertEqual(overlapStaged.staged.count, 1)
        XCTAssertEqual(overlapStaged.duplicates.count, 3)
        try coordinator.commit(accountId: account.id!, sourceFileName: "july2.csv", staged: overlapStaged.staged, decisions: acceptAll(overlapStaged))
        let finalCount = try await manager.dbQueue.read { db in try Transaction.fetchCount(db) }
        XCTAssertEqual(finalCount, 4)
    }

    // C3 probe: rows left "Uncategorized" were silently skipped by commit.
    func testUncategorizedRowsArePersistedPendingReview() async throws {
        let (manager, account, profile) = try makeSeededManager()
        let coordinator = makeCoordinator(manager)
        let csv = "Date,Description,Amount\n01/07/2026,MYSTERY SHOP,-10.00\n02/07/2026,ANOTHER MYSTERY,-20.00"
        let staged = try await coordinator.stageCSVImport(csvText: csv, profile: profile, accountId: account.id!)
        XCTAssertTrue(staged.staged.allSatisfy { $0.suggestedCategoryId == nil })

        try coordinator.commit(accountId: account.id!, sourceFileName: "july.csv", staged: staged.staged, decisions: acceptAll(staged))

        let saved = try await manager.dbQueue.read { db in try Transaction.fetchAll(db) }
        XCTAssertEqual(saved.count, 2)
        XCTAssertTrue(saved.allSatisfy { $0.categoryId == nil && $0.status == .pendingReview && $0.categorizedBy == CategorizedBy.none })
        XCTAssertEqual(saved.map(\.amountMinorUnits).reduce(0, +), -3000)
    }

    // I4: unparsed lines and the actual duplicate rows are carried to the review screen.
    func testStagedImportCarriesUnparsedLinesAndDuplicateRows() async throws {
        let (manager, account, profile) = try makeSeededManager()
        let coordinator = makeCoordinator(manager)
        let first = "Date,Description,Amount\n01/07/2026,TESCO,-12.00"
        let firstStaged = try await coordinator.stageCSVImport(csvText: first, profile: profile, accountId: account.id!)
        try coordinator.commit(accountId: account.id!, sourceFileName: "a.csv", staged: firstStaged.staged, decisions: acceptAll(firstStaged))

        let second = "Date,Description,Amount\n01/07/2026,TESCO,-12.00\nGARBAGE LINE\n02/07/2026,BOOTS,-5.00"
        let staged = try await coordinator.stageCSVImport(csvText: second, profile: profile, accountId: account.id!)
        XCTAssertEqual(staged.staged.map(\.parsed.rawDescription), ["BOOTS"])
        XCTAssertEqual(staged.duplicates.map(\.rawDescription), ["TESCO"])
        XCTAssertEqual(staged.duplicates.first?.amountMinorUnits, -1200)
        XCTAssertEqual(staged.unparsedLines, ["GARBAGE LINE"])
    }

    // I4 / spec: duplicates are force-importable for genuine collisions.
    func testForceImportingADuplicateCommitsWithoutCollision() async throws {
        let (manager, account, profile) = try makeSeededManager()
        let coordinator = makeCoordinator(manager)
        let csv = "Date,Description,Amount\n01/07/2026,TESCO,-12.00"
        let first = try await coordinator.stageCSVImport(csvText: csv, profile: profile, accountId: account.id!)
        try coordinator.commit(accountId: account.id!, sourceFileName: "a.csv", staged: first.staged, decisions: acceptAll(first))

        let restaged = try await coordinator.stageCSVImport(csvText: csv + "\n02/07/2026,BOOTS,-5.00", profile: profile, accountId: account.id!)
        let forced = try await coordinator.stageForcedDuplicates(restaged.duplicates, accountId: account.id!, alreadyStaged: restaged.staged)
        XCTAssertEqual(forced.count, 1)
        let all = restaged.staged + forced
        XCTAssertEqual(Set(all.map(\.fingerprint)).count, 2)
        try coordinator.commit(accountId: account.id!, sourceFileName: "b.csv", staged: all, decisions: all.map { ImportDecision(stagedId: $0.id, finalCategoryId: nil) })
        let count = try await manager.dbQueue.read { db in try Transaction.fetchCount(db) }
        XCTAssertEqual(count, 3)
    }

    // C5: committing an import regenerates the "Detected recurring" forecast.
    func testCommitRegeneratesDefaultForecast() async throws {
        let (manager, account, profile) = try makeSeededManager()
        let (income, rent) = try await manager.dbQueue.read { db in
            (try Category.filter(Column("name") == "Income").fetchOne(db)!.id!, try Category.filter(Column("name") == "Rent").fetchOne(db)!.id!)
        }
        let coordinator = makeCoordinator(manager)
        let csv = """
        Date,Description,Amount
        26/04/2026,SALARY,2800.00
        28/04/2026,RENT,-1800.00
        26/05/2026,SALARY,2800.00
        28/05/2026,RENT,-1800.00
        26/06/2026,SALARY,2800.00
        28/06/2026,RENT,-1800.00
        """
        let staged = try await coordinator.stageCSVImport(csvText: csv, profile: profile, accountId: account.id!)
        let decisions = staged.staged.map { ImportDecision(stagedId: $0.id, finalCategoryId: $0.parsed.amountMinorUnits > 0 ? income : rent) }
        try coordinator.commit(accountId: account.id!, sourceFileName: "q2.csv", staged: staged.staged, decisions: decisions)

        let entries = try await manager.dbQueue.read { db in try ForecastEntry.fetchAll(db) }
        let rentEntry = try XCTUnwrap(entries.first { $0.categoryId == rent })
        XCTAssertEqual(rentEntry.amountMinorUnits, -180000)
        XCTAssertEqual(rentEntry.status, .auto)
        XCTAssertEqual(entries.first { $0.categoryId == income }?.amountMinorUnits, 280000)
    }
}
