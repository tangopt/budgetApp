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

    func testCommitLearnsAKeyRuleOnlyWhenLearnRuleIsTrue() async throws {
        let (manager, account, profile) = try makeSeededManager()
        let eatingOut = try await manager.dbQueue.read { db in try Category.filter(Column("name") == "Eating Out").fetchOne(db)! }
        let coordinator = makeCoordinator(manager)
        let csv = "Date,Description,Amount\n01/07/2026,NANDOS CROYDON 2041,-22.50\n02/07/2026,PIZZA PLACE 9981,-12.00"
        let staged = try await coordinator.stageCSVImport(csvText: csv, profile: profile, accountId: account.id!)

        let decisions = [
            ImportDecision(stagedId: staged.staged[0].id, finalCategoryId: eatingOut.id!, learnRule: true),
            ImportDecision(stagedId: staged.staged[1].id, finalCategoryId: eatingOut.id!, learnRule: false)
        ]
        try coordinator.commit(accountId: account.id!, sourceFileName: "july.csv", staged: staged.staged, decisions: decisions)

        let rules = try await manager.dbQueue.read { db in try Rule.fetchAll(db) }
        XCTAssertEqual(rules.map(\.matchPattern), ["NANDOS CROYDON"])
    }

    func testStagingSuggestsFromHistoryOfAllAccounts() async throws {
        let (manager, account, profile) = try makeSeededManager()
        let groceries = try await manager.dbQueue.read { db in try Category.filter(Column("name") == "Groceries").fetchOne(db)! }
        var other = Account(name: "Other", currency: .gbp, kind: .cash, trackingMode: .imported)
        try await manager.dbQueue.write { db in
            try other.insert(db)
            var batch = ImportBatch(accountId: other.id!, sourceFileName: "o.csv", importedAt: Date())
            try batch.insert(db)
            for i in 0..<2 {
                var t = Transaction(importBatchId: batch.id!, accountId: other.id!, date: Date(), rawDescription: "TESCO STORES 10\(i)", amountMinorUnits: -500, categoryId: groceries.id!, status: .confirmed, categorizedBy: .manual, fingerprint: "h\(i)")
                try t.insert(db)
            }
        }
        let coordinator = makeCoordinator(manager)
        let staged = try await coordinator.stageCSVImport(csvText: "Date,Description,Amount\n01/07/2026,TESCO STORES 3312,-9.00", profile: profile, accountId: account.id!)
        XCTAssertEqual(staged.staged[0].suggestedCategoryId, groceries.id)
        XCTAssertEqual(staged.staged[0].source, .history)
        XCTAssertEqual(staged.staged[0].historyCount, 2)
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

    // Categorization now runs in batches of 25 (see `ImportCoordinator.categorizationBatchSize`)
    // instead of one model call per row — this exercises a file with more rows than one
    // batch to confirm staging still produces every row, in the original file order,
    // across a batch boundary.
    func testStagingAcrossMultipleCategorizationBatchesPreservesOrderAndCount() async throws {
        let (manager, account, profile) = try makeSeededManager()
        let coordinator = makeCoordinator(manager)
        var lines = ["Date,Description,Amount"]
        for i in 1...30 {
            lines.append("01/07/2026,SHOP \(i),-\(i).00")
        }
        let csv = lines.joined(separator: "\n")

        let staged = try await coordinator.stageCSVImport(csvText: csv, profile: profile, accountId: account.id!)

        XCTAssertEqual(staged.staged.count, 30)
        XCTAssertEqual(staged.staged.map(\.parsed.rawDescription), (1...30).map { "SHOP \($0)" })
        XCTAssertTrue(staged.staged.allSatisfy { $0.suggestedCategoryId == nil && $0.source == .none })
    }

    func testStagingReportsProgressAfterEachCategorizationBatch() async throws {
        let (manager, account, profile) = try makeSeededManager()
        let coordinator = makeCoordinator(manager)
        var lines = ["Date,Description,Amount"]
        for i in 1...30 {
            lines.append("01/07/2026,SHOP \(i),-\(i).00")
        }
        let csv = lines.joined(separator: "\n")

        final class ProgressRecorder: @unchecked Sendable {
            var calls: [(Int, Int)] = []
        }
        let recorder = ProgressRecorder()
        _ = try await coordinator.stageCSVImport(csvText: csv, profile: profile, accountId: account.id!) { current, total in
            recorder.calls.append((current, total))
        }

        // 30 rows at a batch size of 25: one partial report at 25, one final report at 30.
        XCTAssertEqual(recorder.calls.map(\.0), [25, 30])
        XCTAssertTrue(recorder.calls.allSatisfy { $0.1 == 30 })
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
        XCTAssertEqual(rentEntry.status, .manual) // detection adds ordinary planned items
        XCTAssertEqual(entries.first { $0.categoryId == income }?.amountMinorUnits, 280000)
    }

    private func utcDate(_ y: Int, _ m: Int, _ d: Int, hour: Int = 0) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: DateComponents(year: y, month: m, day: d, hour: hour))!
    }

    private func balanceProfile(accountId: Int64) -> ImportProfile {
        ImportProfile(accountId: accountId, format: .csv, csvDelimiter: ",", csvDateColumnIndex: 0, csvDescriptionColumnIndex: 1, csvAmountColumnIndex: 2, csvBalanceColumnIndex: 3, csvDateFormat: "dd/MM/yyyy")
    }

    // Newest-first, with two rows on 1 Feb (REFUND listed before RENT, as a bank would).
    private let newestFirstCSV = """
    Date,Description,Amount,Balance
    02/03/2026,SHOP C,-2.50,977.50
    20/02/2026,SHOP B,-15.00,980.00
    01/02/2026,REFUND,30.00,995.00
    01/02/2026,RENT,-5.00,965.00
    31/01/2026,SHOP A,-20.00,970.00
    15/01/2026,SHOP 0,-10.00,990.00
    """

    func testStagingAttachesVerifiedStatementBalances() async throws {
        let (manager, account, _) = try makeSeededManager()
        let coordinator = ImportCoordinator(dbQueue: manager.dbQueue, categorizationService: CategorizationService(categorizer: FakeCategorizer()))
        let staged = try await coordinator.stageCSVImport(csvText: newestFirstCSV, profile: balanceProfile(accountId: account.id!), accountId: account.id!)
        XCTAssertEqual(staged.statementBalances, .available([
            StatementBalancePoint(date: utcDate(2026, 2, 1), balanceMinorUnits: 99_500, isClosing: false),
            StatementBalancePoint(date: utcDate(2026, 3, 1), balanceMinorUnits: 98_000, isClosing: false),
            StatementBalancePoint(date: utcDate(2026, 3, 2), balanceMinorUnits: 97_750, isClosing: true)
        ]))
    }

    func testStatementBalancesAreNotProvidedWithoutABalanceColumn() async throws {
        let (manager, account, profile) = try makeSeededManager()
        let coordinator = ImportCoordinator(dbQueue: manager.dbQueue, categorizationService: CategorizationService(categorizer: FakeCategorizer()))
        let staged = try await coordinator.stageCSVImport(csvText: "Date,Description,Amount\n01/07/2026,SHOP,-10.00", profile: profile, accountId: account.id!)
        XCTAssertEqual(staged.statementBalances, .notProvided)
    }

    // Balances are a fact about the whole file, so a re-stage whose every row is already
    // imported (all duplicates) still carries them.
    func testRestagingAnAlreadyImportedFileStillCarriesBalances() async throws {
        let (manager, account, _) = try makeSeededManager()
        let coordinator = ImportCoordinator(dbQueue: manager.dbQueue, categorizationService: CategorizationService(categorizer: FakeCategorizer()))
        let profile = balanceProfile(accountId: account.id!)
        let first = try await coordinator.stageCSVImport(csvText: newestFirstCSV, profile: profile, accountId: account.id!)
        try coordinator.commit(accountId: account.id!, sourceFileName: "a.csv", staged: first.staged, decisions: [])
        let second = try await coordinator.stageCSVImport(csvText: newestFirstCSV, profile: profile, accountId: account.id!)
        XCTAssertEqual(second.staged.count, 0)
        XCTAssertEqual(second.duplicateCount, 6)
        XCTAssertEqual(second.statementBalances, first.statementBalances)
    }

    func testRecordStatementBalancesInsertsThenIsIdempotent() throws {
        let (manager, account, _) = try makeSeededManager()
        let coordinator = ImportCoordinator(dbQueue: manager.dbQueue, categorizationService: CategorizationService(categorizer: FakeCategorizer()))
        let points = [
            StatementBalancePoint(date: utcDate(2026, 3, 1), balanceMinorUnits: 98_000, isClosing: false),
            StatementBalancePoint(date: utcDate(2026, 3, 2), balanceMinorUnits: 97_750, isClosing: true)
        ]
        let first = try coordinator.recordStatementBalances(accountId: account.id!, sourceFileName: "a.csv", points: points)
        XCTAssertEqual(first, StatementBalanceRecording(added: 2, updated: 0))
        let second = try coordinator.recordStatementBalances(accountId: account.id!, sourceFileName: "a.csv", points: points)
        XCTAssertEqual(second, StatementBalanceRecording(added: 0, updated: 2))

        let snapshots = try manager.dbQueue.read { db in try BalanceSnapshot.order(Column("date")).fetchAll(db) }
        XCTAssertEqual(snapshots.map(\.balanceMinorUnits), [98_000, 97_750])
        XCTAssertEqual(snapshots.first?.note, "Statement balance — a.csv")
    }

    func testRecordStatementBalancesReplacesSameDateSnapshotButNotALegacyTimeOfDayOne() throws {
        let (manager, account, _) = try makeSeededManager()
        let coordinator = ImportCoordinator(dbQueue: manager.dbQueue, categorizationService: CategorizationService(categorizer: FakeCategorizer()))
        try manager.dbQueue.write { db in
            var sameDate = BalanceSnapshot(accountId: account.id!, date: utcDate(2026, 3, 1), balanceMinorUnits: 1, note: "old")
            try sameDate.insert(db)
            // A legacy typed snapshot carries a time of day, so it never matches a statement date.
            var typed = BalanceSnapshot(accountId: account.id!, date: utcDate(2026, 3, 1, hour: 9), balanceMinorUnits: 2, note: "typed")
            try typed.insert(db)
        }
        let result = try coordinator.recordStatementBalances(
            accountId: account.id!, sourceFileName: "a.csv",
            points: [StatementBalancePoint(date: utcDate(2026, 3, 1), balanceMinorUnits: 98_000, isClosing: false)]
        )
        XCTAssertEqual(result, StatementBalanceRecording(added: 0, updated: 1))
        let snapshots = try manager.dbQueue.read { db in try BalanceSnapshot.order(Column("date")).fetchAll(db) }
        XCTAssertEqual(snapshots.map(\.balanceMinorUnits), [98_000, 2])
        XCTAssertEqual(snapshots.first?.note, "Statement balance — a.csv")
        XCTAssertEqual(snapshots.last?.note, "typed")
    }

    // Balances typed on the Accounts screen are dated 00:00 UTC on the picked day, so a
    // statement balance for that day replaces it: the bank's figure wins.
    func testRecordStatementBalancesReplacesAMidnightTypedSnapshotOnTheStatementDay() throws {
        let (manager, account, _) = try makeSeededManager()
        let coordinator = ImportCoordinator(dbQueue: manager.dbQueue, categorizationService: CategorizationService(categorizer: FakeCategorizer()))
        try manager.dbQueue.write { db in
            _ = try BalanceUpdates.save(db: db, entries: [.init(accountId: account.id!, enteredMinorUnits: 50_000, note: "typed")], asOf: utcDate(2026, 3, 1))
        }
        let result = try coordinator.recordStatementBalances(
            accountId: account.id!, sourceFileName: "a.csv",
            points: [StatementBalancePoint(date: utcDate(2026, 3, 1), balanceMinorUnits: 98_000, isClosing: false)]
        )
        XCTAssertEqual(result, StatementBalanceRecording(added: 0, updated: 1))
        let snapshots = try manager.dbQueue.read { db in try BalanceSnapshot.filter(Column("accountId") == account.id!).fetchAll(db) }
        XCTAssertEqual(snapshots.map(\.balanceMinorUnits), [98_000])
        XCTAssertEqual(snapshots.first?.note, "Statement balance — a.csv")
    }

    func testRecordStatementBalancesNeverTouchesAnotherAccountsSnapshotOnTheSameDate() throws {
        let (manager, account, _) = try makeSeededManager()
        let coordinator = ImportCoordinator(dbQueue: manager.dbQueue, categorizationService: CategorizationService(categorizer: FakeCategorizer()))
        var joint = Account(name: "Joint", currency: .gbp, kind: .cash, trackingMode: .manual)
        try manager.dbQueue.write { db in
            try joint.insert(db)
            var other = BalanceSnapshot(accountId: joint.id!, date: utcDate(2026, 3, 1), balanceMinorUnits: 12_345, note: "other")
            try other.insert(db)
        }
        let result = try coordinator.recordStatementBalances(
            accountId: account.id!, sourceFileName: "a.csv",
            points: [StatementBalancePoint(date: utcDate(2026, 3, 1), balanceMinorUnits: 98_000, isClosing: false)]
        )
        XCTAssertEqual(result, StatementBalanceRecording(added: 1, updated: 0))
        let otherSnapshots = try manager.dbQueue.read { db in try BalanceSnapshot.filter(Column("accountId") == joint.id!).fetchAll(db) }
        XCTAssertEqual(otherSnapshots.count, 1)
        XCTAssertEqual(otherSnapshots.first?.balanceMinorUnits, 12_345)
        XCTAssertEqual(otherSnapshots.first?.note, "other")
        let ownSnapshots = try manager.dbQueue.read { db in try BalanceSnapshot.filter(Column("accountId") == account.id!).fetchAll(db) }
        XCTAssertEqual(ownSnapshots.count, 1)
        XCTAssertEqual(ownSnapshots.first?.balanceMinorUnits, 98_000)
        XCTAssertEqual(ownSnapshots.first?.note, "Statement balance — a.csv")
    }

    // Finish import: every row of a review is saved by one commit — one ImportBatch.
    func testCommitSavesEveryRowInOneBatch() async throws {
        let (manager, account, profile) = try makeSeededManager()
        let coordinator = makeCoordinator(manager)
        let csv = "Date,Description,Amount\n01/07/2026,TESCO,-12.00\n02/07/2026,PRET,-3.30\n03/07/2026,MYSTERY,-1.00"
        let staged = try await coordinator.stageCSVImport(csvText: csv, profile: profile, accountId: account.id!)
        try coordinator.commit(accountId: account.id!, sourceFileName: "july.csv", staged: staged.staged, decisions: acceptAll(staged))

        let (batches, transactions) = try await manager.dbQueue.read { db in (try ImportBatch.fetchAll(db), try Transaction.fetchAll(db)) }
        XCTAssertEqual(batches.count, 1)
        XCTAssertEqual(transactions.count, 3)
        XCTAssertTrue(transactions.allSatisfy { $0.importBatchId == batches.first?.id })
    }

    func testCommitRecordsStatementBalancesInTheSameWrite() async throws {
        let (manager, account, profile) = try makeSeededManager()
        let coordinator = makeCoordinator(manager)
        let staged = try await coordinator.stageCSVImport(csvText: "Date,Description,Amount\n01/03/2026,TESCO,-12.00", profile: profile, accountId: account.id!)
        let points = [
            StatementBalancePoint(date: utcDate(2026, 3, 1), balanceMinorUnits: 98_000, isClosing: false),
            StatementBalancePoint(date: utcDate(2026, 3, 2), balanceMinorUnits: 97_750, isClosing: true)
        ]
        let recorded = try coordinator.commit(accountId: account.id!, sourceFileName: "a.csv", staged: staged.staged, decisions: acceptAll(staged), statementBalancePoints: points)

        XCTAssertEqual(recorded, StatementBalanceRecording(added: 2, updated: 0))
        let snapshots = try await manager.dbQueue.read { db in try BalanceSnapshot.order(Column("date")).fetchAll(db) }
        XCTAssertEqual(snapshots.map(\.balanceMinorUnits), [98_000, 97_750])
        XCTAssertEqual(snapshots.first?.note, "Statement balance — a.csv")
    }

    // Balances are part of the commit's write, so a commit that fails leaves none behind.
    func testAFailedCommitRecordsNoStatementBalances() async throws {
        let (manager, account, profile) = try makeSeededManager()
        let coordinator = makeCoordinator(manager)
        let staged = try await coordinator.stageCSVImport(csvText: "Date,Description,Amount\n01/03/2026,TESCO,-12.00", profile: profile, accountId: account.id!)
        try coordinator.commit(accountId: account.id!, sourceFileName: "a.csv", staged: staged.staged, decisions: acceptAll(staged))

        // Committing the same staged rows again violates the [accountId, fingerprint] key.
        let points = [StatementBalancePoint(date: utcDate(2026, 3, 1), balanceMinorUnits: 98_000, isClosing: true)]
        XCTAssertThrowsError(try coordinator.commit(accountId: account.id!, sourceFileName: "a.csv", staged: staged.staged, decisions: acceptAll(staged), statementBalancePoints: points))

        let (batches, snapshots) = try await manager.dbQueue.read { db in (try ImportBatch.fetchCount(db), try BalanceSnapshot.fetchCount(db)) }
        XCTAssertEqual(batches, 1)
        XCTAssertEqual(snapshots, 0)
    }
}
