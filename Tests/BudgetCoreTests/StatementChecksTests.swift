import XCTest
import GRDB
@testable import BudgetCore

/// Statement checks over the whole review (`StatementChecks.recheck`), for UK and BBVA
/// statements: closing balances chained per account in date order, import anyway with a
/// reason, possible duplicate rows as keep/skip children, and every resolution or Leave out
/// re-staging and re-checking the account's statements. Synthetic data only.
final class StatementChecksTests: XCTestCase {
    private var manager: DatabaseManager!
    private var db: DatabaseQueue { manager.dbQueue }
    private var folder: URL!
    private var library: EvidenceLibrary!
    private var pipeline: ImportPipeline!
    private var applier: ImportApplier!
    private var accountId: Int64!

    private func day(_ y: Int, _ m: Int, _ d: Int) -> Date {
        MonthRange.calendar.date(from: DateComponents(year: y, month: m, day: d))!
    }

    override func setUpWithError() throws {
        manager = try DatabaseManager(path: nil)
        try manager.migrate()
        accountId = try db.write { db -> Int64 in
            try CategorySeeder.seedDefaults(db)
            var account = Account(name: "Bank One", currency: .gbp, kind: .cash, trackingMode: .imported)
            try account.insert(db)
            return account.id!
        }
        _ = try ImportProfileStore(dbQueue: db).save(ImportProfile(accountId: accountId, format: .csv, csvDelimiter: ",", csvDateColumnIndex: 0,
                                                                   csvDescriptionColumnIndex: 1, csvAmountColumnIndex: 2,
                                                                   csvBalanceColumnIndex: 3, csvDateFormat: "dd/MM/yyyy"))
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("StatementChecksTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        library = EvidenceLibrary(root: folder.appendingPathComponent("Library", isDirectory: true), database: db)
        pipeline = ImportPipeline(dbQueue: db, library: library, categorizationService: CategorizationService(categorizer: FakeCategorizer()))
        applier = ImportApplier(dbQueue: db, databasePath: nil, library: library)
    }

    override func tearDownWithError() throws {
        pipeline.discardPlanningCopy()
        try? FileManager.default.removeItem(at: folder)
    }

    // MARK: UK helpers

    private typealias Row = (day: String, description: String, amount: String, balance: String)

    private func statement(_ name: String, _ rows: [Row]) throws -> URL {
        let directory = folder.appendingPathComponent("Drop", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        let text = "Date,Description,Amount,Balance\n" + rows.map { "\($0.day),\($0.description),\($0.amount),\($0.balance)\n" }.joined()
        try Data(text.utf8).write(to: url)
        return url
    }

    private func item(_ name: String, in plan: ImportPlan) throws -> ImportItem {
        try XCTUnwrap(plan.items.first { $0.file.fileName == name && $0.parentId == nil }, "no \(name) in \(plan.items.map(\.file.fileName))")
    }

    private func ukRows(_ item: ImportItem) -> [String] {
        if case .ukStatement(let effect) = item.effect { return effect.staged.map(\.parsed.rawDescription) }
        return []
    }

    private func balanceIssues(_ item: ImportItem) -> [ImportIssue] {
        item.issues.filter { if case .statement(.balanceMismatch) = $0.kind { return true }; return false }
    }

    private var intent: ImportIntent { ImportIntent(accountId: accountId) }

    private func savedDescriptions() throws -> [String] {
        let id = accountId!
        return try db.read { db in try Transaction.filter(Column("accountId") == id).fetchAll(db).map(\.rawDescription).sorted() }
    }

    /// A row saved by an earlier import of the account (its own batch).
    @discardableResult
    private func saveEarlierRow(_ description: String, _ amount: Int, on date: Date) throws -> Int64 {
        let id = accountId!
        return try db.write { db in
            let parsed = ParsedTransaction(date: date, rawDescription: description, amountMinorUnits: amount, balanceAfterMinorUnits: nil)
            let row = StagedTransaction(parsed: parsed, suggestedCategoryId: nil, source: .none, confidence: 0, fingerprint: "earlier-\(description)")
            _ = try ImportCoordinator.commit(db: db, accountId: id, sourceFileName: "earlier.csv", staged: [row], decisions: [])
            return try XCTUnwrap(try Transaction.filter(Column("fingerprint") == "earlier-\(description)").fetchOne(db)?.id)
        }
    }

    private func rowChildren(of parent: ImportItem, in plan: ImportPlan) -> [ImportItem] {
        plan.items.filter { $0.parentId == parent.id && $0.effect == .none && ($0.duplicate == nil || $0.duplicate?.of == "Skipped: not imported") }
    }

    // MARK: Statements already in the library (final review)

    func testAFiledStatementWithItsRowsUnsavedStillAddsThemBesideTheLaterOne() async throws {
        let a = try statement("a.csv", [(day: "05/01/2026", description: "SHOP A", amount: "-10.00", balance: "-10.00"),
                                        (day: "05/02/2026", description: "SHOP B", amount: "-20.00", balance: "-30.00")])
        let b = try statement("b.csv", [(day: "05/02/2026", description: "SHOP B", amount: "-20.00", balance: "-30.00"),
                                        (day: "05/03/2026", description: "SHOP C", amount: "-30.00", balance: "-60.00")])
        let filed = try library.add(a, metadata: EvidenceMetadata(kind: .bankStatement)).document
        let plan = try await pipeline.plan([a, b], intent: intent)
        let first = try item("a.csv", in: plan), later = try item("b.csv", in: plan)
        XCTAssertNil(first.duplicate, "its rows aren't saved: it isn't a duplicate")
        XCTAssertEqual(first.section, .ready, "\(first.needsYouReasons)")
        XCTAssertTrue(first.notes.contains("Document already in the library as \(filed.displayName)"), "\(first.notes)")
        XCTAssertEqual(ukRows(first), ["SHOP A", "SHOP B"])
        XCTAssertEqual(ukRows(later), ["SHOP C"])
        XCTAssertEqual(later.section, .ready, "\(later.needsYouReasons)")
        _ = try applier.apply(plan, entryPoint: "Test")
        XCTAssertEqual(try savedDescriptions(), ["SHOP A", "SHOP B", "SHOP C"])
        let documents = try await db.read { db in try EvidenceDocument.fetchCount(db) }
        XCTAssertEqual(documents, 2, "a.csv's library document re-used")

        // Dropped again, every row saved: now a duplicate.
        pipeline.discardPlanningCopy()
        let again = try await pipeline.plan([a], intent: intent)
        XCTAssertEqual(try item("a.csv", in: again).duplicate?.of, "Identical file: already in the library as \(filed.displayName)")
    }

    // MARK: Balance mismatch and import anyway

    func testMismatchedClosingIsNeedsYouAndImportAnywayWithReasonReadies() async throws {
        // Nothing saved yet: the account would be at £100.00, the statement closes at £90.00.
        var plan = try await pipeline.plan([try statement("jan.csv", [(day: "05/01/2026", description: "SALARY", amount: "100.00", balance: "90.00")])],
                                           intent: intent)
        let jan = try item("jan.csv", in: plan)
        XCTAssertEqual(jan.section, .needsYou)
        let issue = try XCTUnwrap(balanceIssues(jan).first)
        XCTAssertEqual(issue.id, "balance-\(accountId!)-2026-01-05")
        XCTAssertEqual(balanceIssues(jan).count, 1)
        XCTAssertFalse(plan.canConfirm)

        plan = try await pipeline.resolve(plan, itemId: jan.id, .importAnyway(reason: "  The bank's fee isn't in the export "))
        let answered = try item("jan.csv", in: plan)
        XCTAssertEqual(answered.section, .ready, "\(answered.needsYouReasons)")
        XCTAssertEqual(answered.resolutionNote, "The bank's fee isn't in the export")
        XCTAssertEqual(plan.resolutionReasons, [jan.id: "The bank's fee isn't in the export"])
        XCTAssertTrue(plan.canConfirm)

        let summary = try applier.apply(plan, entryPoint: "Test", reasons: plan.resolutionReasons)
        let run = try await db.read { db in try ImportRun.fetchOne(db, key: summary.runId) }
        let json = try XCTUnwrap(run?.reasonsJSON)
        XCTAssertTrue(json.contains(jan.id.uuidString) && json.contains("The bank's fee isn't in the export"), json)
        // The mismatch is recorded on the account (no adjustment added).
        let id = accountId!
        let account = try await db.read { db in try Account.fetchOne(db, key: id) }
        XCTAssertEqual(account?.statementMismatchMinorUnits, -1_000)
        XCTAssertEqual(try savedDescriptions(), ["SALARY"])
    }

    func testImportAnywayNeedsANonBlankReason() async throws {
        let plan = try await pipeline.plan([try statement("jan.csv", [(day: "05/01/2026", description: "SALARY", amount: "100.00", balance: "90.00")])],
                                           intent: intent)
        let jan = try item("jan.csv", in: plan)
        do {
            _ = try await pipeline.resolve(plan, itemId: jan.id, .importAnyway(reason: "   "))
            XCTFail("a blank reason is refused")
        } catch let error as ImportResolutionError {
            XCTAssertEqual(error, .reasonRequired)
        }
        // The plan after the refusal (out and back in, every check run again): still asking.
        var after = try await pipeline.resolve(plan, itemId: jan.id, .leaveOut)
        after = try await pipeline.resolve(after, itemId: jan.id, .leaveOut)
        let still = try item("jan.csv", in: after)
        XCTAssertEqual(still.section, .needsYou)
        XCTAssertNil(still.resolutionNote)
        XCTAssertEqual(balanceIssues(still).count, 1)
        XCTAssertFalse(after.canConfirm)

        // A statement that matches has nothing to import anyway.
        let matching = try await pipeline.plan([try statement("feb.csv", [(day: "05/02/2026", description: "SHOP", amount: "-5.00", balance: "-5.00")])],
                                               intent: intent)
        let feb = try item("feb.csv", in: matching)
        XCTAssertEqual(feb.section, .ready, "\(feb.needsYouReasons)")
        do {
            _ = try await pipeline.resolve(matching, itemId: feb.id, .importAnyway(reason: "Because"))
            XCTFail("no mismatch to import anyway")
        } catch let error as ImportResolutionError {
            XCTAssertEqual(error, .notOffered(.importAnyway(reason: "Because")))
        }
    }

    // MARK: Possible duplicates

    func testPossibleDuplicateRowIsAChildNeedsYou() async throws {
        let existing = try saveEarlierRow("CARD SHOP A", -1_000, on: day(2026, 1, 4))
        var plan = try await pipeline.plan([try statement("jan.csv", [(day: "05/01/2026", description: "SHOP A LONDON", amount: "-10.00", balance: "-20.00"),
                                                                     (day: "06/01/2026", description: "OTHER", amount: "-5.00", balance: "-25.00")])],
                                           intent: intent)
        let jan = try item("jan.csv", in: plan)
        let children = rowChildren(of: jan, in: plan)
        XCTAssertEqual(children.count, 1, "\(plan.items.map(\.title))")
        let child = try XCTUnwrap(children.first)
        XCTAssertEqual(child.title, "5 Jan 2026 SHOP A LONDON -£10.00")
        let issue = try XCTUnwrap(child.issues.first)
        guard case .statement(.possibleDuplicate(let existingId, _)) = issue.kind else { return XCTFail("\(issue.kind)") }
        XCTAssertEqual(existingId, existing)
        XCTAssertEqual(issue.reason, "Looks like “CARD SHOP A” of 4 Jan 2026 already saved")
        XCTAssertEqual(child.section, .needsYou)
        XCTAssertEqual(jan.section, .needsYou, "the statement waits for its rows")
        XCTAssertTrue(balanceIssues(jan).isEmpty, "\(jan.issues)")
        XCTAssertFalse(plan.canConfirm)

        plan = try await pipeline.resolve(plan, itemId: child.id, .keepRow)
        XCTAssertEqual(try XCTUnwrap(plan.items.first { $0.id == child.id }).section, .ready)
        let kept = try item("jan.csv", in: plan)
        XCTAssertEqual(kept.section, .ready, "\(kept.needsYouReasons)")
        XCTAssertEqual(ukRows(kept), ["SHOP A LONDON", "OTHER"])
        XCTAssertTrue(plan.canConfirm)
        let summary = try applier.apply(plan, entryPoint: "Test")
        XCTAssertEqual(summary.transactions, 2)
        XCTAssertEqual(try savedDescriptions(), ["CARD SHOP A", "OTHER", "SHOP A LONDON"])
    }

    func testSkipRowDropsItAndRechecksBalance() async throws {
        try saveEarlierRow("CARD SHOP A", -1_000, on: day(2026, 1, 4))
        var plan = try await pipeline.plan([try statement("jan.csv", [(day: "05/01/2026", description: "SHOP A LONDON", amount: "-10.00", balance: "-20.00"),
                                                                     (day: "06/01/2026", description: "OTHER", amount: "-5.00", balance: "-25.00")])],
                                           intent: intent)
        let jan = try item("jan.csv", in: plan)
        let child = try XCTUnwrap(rowChildren(of: jan, in: plan).first)
        plan = try await pipeline.resolve(plan, itemId: child.id, .skipRow)

        let skipped = try item("jan.csv", in: plan)
        XCTAssertEqual(ukRows(skipped), ["OTHER"])
        // Without the row the account would be at −£15.00, the statement says −£25.00.
        let mismatch = try XCTUnwrap(balanceIssues(skipped).first, "\(skipped.issues)")
        guard case .statement(.balanceMismatch(let values)) = mismatch.kind else { return XCTFail() }
        XCTAssertEqual(values.computedMinorUnits, -1_500)
        XCTAssertEqual(values.statementMinorUnits, -2_500)
        let after = try XCTUnwrap(plan.items.first { $0.id == child.id }, "the skipped row stays shown")
        XCTAssertTrue(after.issues.isEmpty, "\(after.issues)")
        XCTAssertEqual(after.section, .duplicates, "shown with the rows the statement doesn't add")
        XCTAssertEqual(after.duplicate?.of, "Skipped: not imported")

        // Kept again: back in, and the balance matches again.
        plan = try await pipeline.resolve(plan, itemId: child.id, .keepRow)
        let back = try item("jan.csv", in: plan)
        XCTAssertEqual(ukRows(back), ["SHOP A LONDON", "OTHER"])
        XCTAssertTrue(balanceIssues(back).isEmpty, "\(back.issues)")
    }

    func testASkippedRowStillCountsInTheStatementsPeriod() async throws {
        // The order key the checks and apply read from the facts must be the one staging used.
        try saveEarlierRow("CARD SHOP A", -1_000, on: day(2026, 1, 4))
        var plan = try await pipeline.plan([try statement("jan.csv", [(day: "05/01/2026", description: "SHOP A LONDON", amount: "-10.00", balance: "-20.00"),
                                                                     (day: "06/01/2026", description: "OTHER", amount: "-5.00", balance: "-25.00")])],
                                           intent: intent)
        let child = try XCTUnwrap(rowChildren(of: try item("jan.csv", in: plan), in: plan).first)
        plan = try await pipeline.resolve(plan, itemId: child.id, .skipRow)
        let skipped = try item("jan.csv", in: plan)
        XCTAssertEqual(ukRows(skipped), ["OTHER"])
        XCTAssertEqual(skipped.facts.first { $0.field == .periodStart }?.value, .date(day(2026, 1, 5)))
        XCTAssertEqual(skipped.facts.first { $0.field == .periodEnd }?.value, .date(day(2026, 1, 6)))
        XCTAssertEqual(skipped.title, "Bank One statement 5 Jan 2026–6 Jan 2026")
    }

    func testCertainDuplicatesAreNotPossibleDuplicates() async throws {
        // A first import saves SHOP A; a later download repeats it (a certain duplicate).
        let first = try await pipeline.plan([try statement("jan.csv", [(day: "05/01/2026", description: "SHOP A", amount: "-10.00", balance: "-10.00")])],
                                            intent: intent)
        _ = try applier.apply(first, entryPoint: "Test")
        pipeline.discardPlanningCopy()
        // A manual entry the next statement's row replaces.
        let id = accountId!
        try await db.write { db in
            _ = try ManualTransactions.add(db: db, accountId: id, date: self.day(2026, 1, 7), description: "Cash at market",
                                           amountMinorUnits: -700, categoryId: nil, note: nil)
        }
        let plan = try await pipeline.plan([try statement("jan-again.csv", [(day: "05/01/2026", description: "SHOP A", amount: "-10.00", balance: "-10.00"),
                                                                           (day: "07/01/2026", description: "MARKET", amount: "-7.00", balance: "-17.00")])],
                                           intent: intent)
        let again = try item("jan-again.csv", in: plan)
        XCTAssertEqual(ukRows(again), ["MARKET"])
        XCTAssertTrue(rowChildren(of: again, in: plan).isEmpty, "\(plan.items.map { ($0.title, $0.needsYouReasons) })")
        XCTAssertEqual(again.section, .ready, "\(again.needsYouReasons)")
    }

    // MARK: Chaining across the batch

    func testLeavingOutEarlierStatementRechecksLaterOne() async throws {
        let jan = try statement("jan.csv", [(day: "05/01/2026", description: "SALARY", amount: "100.00", balance: "100.00"),
                                            (day: "20/01/2026", description: "SHOP A", amount: "-20.00", balance: "80.00")])
        let feb = try statement("feb.csv", [(day: "05/02/2026", description: "SHOP B", amount: "-30.00", balance: "50.00")])
        var plan = try await pipeline.plan([jan, feb], intent: intent)
        XCTAssertEqual(try item("feb.csv", in: plan).section, .ready)
        XCTAssertEqual(try item("jan.csv", in: plan).section, .ready)

        plan = try await pipeline.resolve(plan, itemId: try item("jan.csv", in: plan).id, .leaveOut)
        let later = try item("feb.csv", in: plan)
        XCTAssertEqual(later.section, .needsYou)
        let mismatch = try XCTUnwrap(balanceIssues(later).first, "\(later.issues)")
        XCTAssertEqual(mismatch.id, "balance-\(accountId!)-2026-02-05")
        guard case .statement(.balanceMismatch(let values)) = mismatch.kind else { return XCTFail() }
        XCTAssertEqual(values.computedMinorUnits, -3_000)

        // Back in: matches again.
        plan = try await pipeline.resolve(plan, itemId: try item("jan.csv", in: plan).id, .leaveOut)
        let backIn = try item("feb.csv", in: plan)
        XCTAssertEqual(backIn.section, .ready, "\(backIn.needsYouReasons)")
        XCTAssertTrue(plan.canConfirm)
    }

    func testLeavingOutEarlierOverlappingUKStatementMovesItsSharedRowsToTheLater() async throws {
        let janToMar = try statement("jan-mar.csv", [(day: "05/01/2026", description: "SHOP A", amount: "-10.00", balance: "-10.00"),
                                                     (day: "05/02/2026", description: "SHOP B", amount: "-20.00", balance: "-30.00")])
        let febToApr = try statement("feb-apr.csv", [(day: "05/02/2026", description: "SHOP B", amount: "-20.00", balance: "-30.00"),
                                                     (day: "05/04/2026", description: "SHOP D", amount: "-40.00", balance: "-70.00")])
        var plan = try await pipeline.plan([janToMar, febToApr], intent: intent)
        XCTAssertEqual(ukRows(try item("feb-apr.csv", in: plan)), ["SHOP D"])

        // Out and back in: the later one is staged again each time (never both holding SHOP B).
        plan = try await pipeline.resolve(plan, itemId: try item("jan-mar.csv", in: plan).id, .leaveOut)
        XCTAssertEqual(ukRows(try item("feb-apr.csv", in: plan)), ["SHOP B", "SHOP D"])
        plan = try await pipeline.resolve(plan, itemId: try item("jan-mar.csv", in: plan).id, .leaveOut)
        XCTAssertEqual(ukRows(try item("feb-apr.csv", in: plan)), ["SHOP D"])
        plan = try await pipeline.resolve(plan, itemId: try item("jan-mar.csv", in: plan).id, .leaveOut)

        let later = try item("feb-apr.csv", in: plan)
        XCTAssertEqual(ukRows(later), ["SHOP B", "SHOP D"])
        // Its own rows close at −£60.00, the statement says −£70.00 (SHOP A was only on the left-out one).
        XCTAssertEqual(balanceIssues(later).count, 1, "\(later.issues)")
        plan = try await pipeline.resolve(plan, itemId: later.id, .importAnyway(reason: "SHOP A was on the earlier statement"))
        let summary = try applier.apply(plan, entryPoint: "Test", reasons: plan.resolutionReasons)
        XCTAssertEqual(summary.transactions, 2)
        XCTAssertEqual(try savedDescriptions(), ["SHOP B", "SHOP D"])
        let files = try await db.read { db in try ImportRunFile.filter(Column("runId") == summary.runId).fetchAll(db) }
        let laterFile = files.first { $0.fileName == "feb-apr.csv" && $0.outcome == .transactions }
        XCTAssertEqual(laterFile?.detail, "2 transactions")
    }

    func testEarlierStatementAddedLaterTakesTheSharedRows() async throws {
        let febToApr = try statement("feb-apr.csv", [(day: "05/02/2026", description: "SHOP B", amount: "-20.00", balance: "-30.00"),
                                                     (day: "05/04/2026", description: "SHOP D", amount: "-40.00", balance: "-70.00")])
        let janToMar = try statement("jan-mar.csv", [(day: "05/01/2026", description: "SHOP A", amount: "-10.00", balance: "-10.00"),
                                                     (day: "05/02/2026", description: "SHOP B", amount: "-20.00", balance: "-30.00")])
        let first = try await pipeline.plan([febToApr], intent: intent)
        XCTAssertEqual(try item("feb-apr.csv", in: first).section, .needsYou, "alone, SHOP A is missing from its balance")
        let plan = try await pipeline.plan(adding: [janToMar], to: first, intent: intent)
        XCTAssertEqual(ukRows(try item("jan-mar.csv", in: plan)), ["SHOP A", "SHOP B"])
        let later = try item("feb-apr.csv", in: plan)
        XCTAssertEqual(ukRows(later), ["SHOP D"])
        XCTAssertEqual(later.section, .ready, "\(later.needsYouReasons)")
        XCTAssertTrue(plan.canConfirm, "\(plan.items.map { ($0.title, $0.needsYouReasons) })")
        _ = try applier.apply(plan, entryPoint: "Test")
        XCTAssertEqual(try savedDescriptions(), ["SHOP A", "SHOP B", "SHOP D"])
    }

    // MARK: Fix round 1

    private func addAccount(_ name: String) throws -> Int64 {
        let id = try db.write { db -> Int64 in
            var account = Account(name: name, currency: .gbp, kind: .cash, trackingMode: .imported)
            try account.insert(db)
            return account.id!
        }
        _ = try ImportProfileStore(dbQueue: db).save(ImportProfile(accountId: id, format: .csv, csvDelimiter: ",", csvDateColumnIndex: 0,
                                                                   csvDescriptionColumnIndex: 1, csvAmountColumnIndex: 2,
                                                                   csvBalanceColumnIndex: 3, csvDateFormat: "dd/MM/yyyy"))
        return id
    }

    func testReadingAStatementOntoAnotherAccountRestagesTheOneLeft() async throws {
        let other = try addAccount("Bank Two")
        let janToMar = try statement("jan-mar.csv", [(day: "05/01/2026", description: "SHOP A", amount: "-10.00", balance: "-10.00"),
                                                     (day: "05/02/2026", description: "SHOP B", amount: "-20.00", balance: "-30.00")])
        let febToApr = try statement("feb-apr.csv", [(day: "05/02/2026", description: "SHOP B", amount: "-20.00", balance: "-30.00"),
                                                     (day: "05/04/2026", description: "SHOP D", amount: "-40.00", balance: "-70.00")])
        var plan = try await pipeline.plan([janToMar, febToApr], intent: intent)
        XCTAssertEqual(ukRows(try item("feb-apr.csv", in: plan)), ["SHOP D"])

        plan = try await pipeline.resolve(plan, itemId: try item("jan-mar.csv", in: plan).id, .chooseTarget(.account, other))
        let moved = try item("jan-mar.csv", in: plan)
        XCTAssertEqual(StatementChecks.accountId(of: moved), other)
        let left = try item("feb-apr.csv", in: plan)
        XCTAssertEqual(ukRows(left), ["SHOP B", "SHOP D"], "the one left on the account holds the shared row again")
        XCTAssertEqual(balanceIssues(left).count, 1, "and its balance is checked without the other's rows")
        plan = try await pipeline.resolve(plan, itemId: left.id, .importAnyway(reason: "SHOP A went to the other account"))
        XCTAssertTrue(plan.canConfirm, "\(plan.items.map { ($0.title, $0.needsYouReasons) })")
        _ = try applier.apply(plan, entryPoint: "Test", reasons: plan.resolutionReasons)
        XCTAssertEqual(try savedDescriptions(), ["SHOP B", "SHOP D"])
    }

    func testASkippedRowIsSkippedOnEveryStatementOfTheAccount() async throws {
        try saveEarlierRow("CARD SHOP X", -1_000, on: day(2026, 2, 4))
        let janToMar = try statement("jan-mar.csv", [(day: "05/01/2026", description: "SHOP A", amount: "-10.00", balance: "-10.00"),
                                                     (day: "05/02/2026", description: "SHOP X LTD", amount: "-10.00", balance: "-30.00")])
        let febToApr = try statement("feb-apr.csv", [(day: "05/02/2026", description: "SHOP X LTD", amount: "-10.00", balance: "-30.00"),
                                                     (day: "05/04/2026", description: "SHOP D", amount: "-40.00", balance: "-70.00")])
        var plan = try await pipeline.plan([janToMar, febToApr], intent: intent)
        let earlier = try item("jan-mar.csv", in: plan)
        let child = try XCTUnwrap(rowChildren(of: earlier, in: plan).first, "\(plan.items.map(\.title))")
        plan = try await pipeline.resolve(plan, itemId: child.id, .skipRow)

        XCTAssertEqual(ukRows(try item("jan-mar.csv", in: plan)), ["SHOP A"])
        let later = try item("feb-apr.csv", in: plan)
        XCTAssertEqual(ukRows(later), ["SHOP D"], "the later statement treats the skipped row as handled")
        XCTAssertTrue(rowChildren(of: later, in: plan).isEmpty, "\(plan.items.map(\.title))")
        let skipped = try XCTUnwrap(plan.items.first { $0.id == child.id })
        XCTAssertNotEqual(skipped.section, .ready, "a skipped row is not a Ready item")
        XCTAssertEqual(skipped.duplicate?.of, "Skipped: not imported")
        for item in plan.items.filter({ $0.parentId == nil }) where !balanceIssues(item).isEmpty {
            plan = try await pipeline.resolve(plan, itemId: item.id, .importAnyway(reason: "SHOP X is the saved card payment"))
        }
        XCTAssertTrue(plan.canConfirm, "\(plan.items.map { ($0.title, $0.needsYouReasons) })")
        _ = try applier.apply(plan, entryPoint: "Test", reasons: plan.resolutionReasons)
        XCTAssertEqual(try savedDescriptions(), ["CARD SHOP X", "SHOP A", "SHOP D"])
    }

    func testAnImportAnywayAnswerDoesNotOutliveItsMismatch() async throws {
        let jan = try statement("jan.csv", [(day: "05/01/2026", description: "SALARY", amount: "100.00", balance: "100.00")])
        let feb = try statement("feb.csv", [(day: "05/02/2026", description: "SHOP B", amount: "-30.00", balance: "70.00")])
        var plan = try await pipeline.plan([jan, feb], intent: intent)
        let janId = try item("jan.csv", in: plan).id, febId = try item("feb.csv", in: plan).id
        plan = try await pipeline.resolve(plan, itemId: janId, .leaveOut)
        plan = try await pipeline.resolve(plan, itemId: febId, .importAnyway(reason: "January comes later"))
        XCTAssertEqual(try item("feb.csv", in: plan).section, .ready)
        plan = try await pipeline.resolve(plan, itemId: janId, .leaveOut)
        XCTAssertEqual(try item("feb.csv", in: plan).section, .ready)
        plan = try await pipeline.resolve(plan, itemId: janId, .leaveOut)
        let again = try item("feb.csv", in: plan)
        XCTAssertEqual(again.section, .needsYou, "the same mismatch again needs a reason again")
        XCTAssertNil(again.resolutionNote)
        XCTAssertTrue(plan.resolutionReasons.isEmpty)
    }

    /// The review shows a statement's rows under it (`isRowChild`), a skipped one as such (`isSkippedRow`).
    func testRowChildrenAreKnownByTheirStatement() async throws {
        try saveEarlierRow("CARD SHOP A", -1_000, on: day(2026, 1, 4))
        var plan = try await pipeline.plan([try statement("jan.csv", [(day: "05/01/2026", description: "SHOP A LONDON", amount: "-10.00", balance: "-10.00")])],
                                           intent: intent)
        let jan = try item("jan.csv", in: plan)
        let child = try XCTUnwrap(rowChildren(of: jan, in: plan).first)
        XCTAssertTrue(StatementChecks.isRowChild(child, of: jan))
        XCTAssertFalse(StatementChecks.isSkippedRow(child))
        XCTAssertFalse(StatementChecks.isRowChild(jan, of: jan))
        plan = try await pipeline.resolve(plan, itemId: child.id, .skipRow)
        let skipped = try XCTUnwrap(plan.items.first { $0.id == child.id })
        XCTAssertTrue(StatementChecks.isSkippedRow(skipped))
        XCTAssertTrue(StatementChecks.isRowChild(skipped, of: try item("jan.csv", in: plan)))
    }

    func testAKeptRowCanBeSkippedAndTheBalanceAsksAgain() async throws {
        try saveEarlierRow("CARD SHOP A", -1_000, on: day(2026, 1, 4))
        var plan = try await pipeline.plan([try statement("jan.csv", [(day: "05/01/2026", description: "SHOP A LONDON", amount: "-10.00", balance: "-20.00")])],
                                           intent: intent)
        let janId = try item("jan.csv", in: plan).id
        let child = try XCTUnwrap(rowChildren(of: try item("jan.csv", in: plan), in: plan).first)
        plan = try await pipeline.resolve(plan, itemId: child.id, .skipRow)
        plan = try await pipeline.resolve(plan, itemId: janId, .importAnyway(reason: "It is the saved one"))
        let answered = try item("jan.csv", in: plan)
        XCTAssertEqual(answered.section, .ready, "\(answered.needsYouReasons)")
        plan = try await pipeline.resolve(plan, itemId: child.id, .keepRow)
        XCTAssertEqual(try item("jan.csv", in: plan).section, .ready)
        XCTAssertEqual(ukRows(try item("jan.csv", in: plan)), ["SHOP A LONDON"])
        // Kept, then skipped again: the mismatch asks for a reason again.
        plan = try await pipeline.resolve(plan, itemId: child.id, .skipRow)
        XCTAssertEqual(ukRows(try item("jan.csv", in: plan)), [])
        XCTAssertEqual(try item("jan.csv", in: plan).section, .needsYou)
        XCTAssertFalse(plan.canConfirm)
    }

    func testASavedRowACertainDuplicateMatchesIsNotALookalike() async throws {
        let first = try await pipeline.plan([try statement("jan.csv", [(day: "05/01/2026", description: "SHOP A", amount: "-10.00", balance: "-10.00")])],
                                            intent: intent)
        _ = try applier.apply(first, entryPoint: "Test")
        pipeline.discardPlanningCopy()
        // A later download repeats SHOP A and adds a café payment of the same amount the next day.
        let plan = try await pipeline.plan([try statement("jan-again.csv", [(day: "05/01/2026", description: "SHOP A", amount: "-10.00", balance: "-10.00"),
                                                                           (day: "06/01/2026", description: "CAFE", amount: "-10.00", balance: "-20.00")])],
                                           intent: intent)
        let again = try item("jan-again.csv", in: plan)
        XCTAssertEqual(ukRows(again), ["CAFE"])
        XCTAssertTrue(rowChildren(of: again, in: plan).isEmpty, "SHOP A is the saved row's own copy: \(plan.items.map(\.title))")
        XCTAssertEqual(again.section, .ready, "\(again.needsYouReasons)")
    }

    // MARK: BBVA

    private var bbvaId: Int64!
    private var loanId: Int64!

    private func makeBBVAAccounts() throws {
        try db.write { db in
            bbvaId = try AccountEditing.add(db: db, name: BBVAHistoryImport.accountName, currency: .eur, kind: .cash, openingBalanceEntered: 250_000,
                                            asOf: day(2026, 1, 31)).id!
            loanId = try AccountEditing.add(db: db, name: BBVAFundMortgageImport.loanAccountName, currency: .eur, kind: .credit,
                                            openingBalanceEntered: 1_050_000, asOf: day(2026, 1, 31), includeInNetWorth: false).id!
            _ = try AccountEditing.add(db: db, name: BBVAFundMortgageImport.fundAccountName, currency: .eur, kind: .investment,
                                       openingBalanceEntered: 100_000, asOf: day(2026, 1, 31))
            let costs = try CategoryGroups.create(db: db, name: "Flat costs", type: .expense)
            _ = try Categories.create(db: db, name: BBVAFundMortgageImport.interestCategoryName, type: .expense, groupId: costs.id)
        }
    }

    /// February 2026: the instalment (receipt 40), a fund subscription and a shop payment; closing €1,627.47.
    private let february = """
        EXTRATO GLOBAL
        PERÍODO DE 2026/02/01 A 2026/02/28
        ACTIVO
        DEPÓSITOS À ORDEM 1.627,47
        PRODUTOS DE POUPANÇA 1.060,50
        PASSIVO
        EMPRÉSTIMOS 9.800,00
        Conta Nº: 000/123456789   EUR   CONTA BBVA
        Saldo inicial 2.500,00
        02/05 02/05 COBR. REC. TOT 000 00-000000-0 -812,53 1.687,47
        02/20 02/20 SUBSCRIÇÃO PERI         100,0000 -50,00 1.637,47
        02/27 02/27 PAGAMENTO LOJA EXEMPLO -10,00 1.627,47
        Saldo final 1.627,47
        Saldo disponivel 1.627,47
        Conta Nº: 000/222222222 EUR SAMPLE FUND
        Saldo inicial 10,000 100,0000 1.000,00
        02/18 02/20 SUBSCRIÇÃO PERIÓDICA 0,500 100,0000 50,00
        Saldo final 10,500 101,0000 1.060,50
        Conta Nº: 000/333333333 EUR HOME LOAN
        Capital em Dívida 9.800,00
        COBRANÇAS EFECTUADAS
        Nº. Recibo: 40/480 Data Inicio Liquidação: 2026-01-05 Total recibo:             812,53
        Data Valor: 2026-02-05 Data Fim Liquidação: 2026-02-05
        Data Oper. Capital Juros Comissões Juros de Mora Impostos Total EUR Total em atraso Capital em dívida
        2026-02-05           700,00       112,53         0,00             0,00         0,00           812,53             0,00       9.800,00
        """

    /// The first ten days of February (a partial download): the instalment and its receipt.
    private let earlyFebruary = """
        EXTRATO GLOBAL
        PERÍODO DE 2026/02/01 A 2026/02/10
        ACTIVO
        DEPÓSITOS À ORDEM 1.687,47
        PASSIVO
        EMPRÉSTIMOS 9.800,00
        Conta Nº: 000/123456789   EUR   CONTA BBVA
        Saldo inicial 2.500,00
        02/05 02/05 COBR. REC. TOT 000 00-000000-0 -812,53 1.687,47
        Saldo final 1.687,47
        Conta Nº: 000/333333333 EUR HOME LOAN
        Capital em Dívida 9.800,00
        COBRANÇAS EFECTUADAS
        Nº. Recibo: 40/480 Data Inicio Liquidação: 2026-01-05 Total recibo:             812,53
        Data Valor: 2026-02-05 Data Fim Liquidação: 2026-02-05
        Data Oper. Capital Juros Comissões Juros de Mora Impostos Total EUR Total em atraso Capital em dívida
        2026-02-05           700,00       112,53         0,00             0,00         0,00           812,53             0,00       9.800,00
        """

    /// March 2026 after February: one shop payment; closing €1,617.47.
    private let march = """
        EXTRATO GLOBAL
        PERÍODO DE 2026/03/01 A 2026/03/31
        DEPÓSITOS À ORDEM 1.617,47
        Conta Nº: 000/123456789   EUR   CONTA BBVA
        Saldo inicial 1.627,47
        03/10 03/10 PAGAMENTO LOJA EXEMPLO -10,00 1.617,47
        Saldo final 1.617,47
        """

    private func pdf(_ text: String, name: String) -> URL {
        EvidenceTestPDFs.textPDF(text.components(separatedBy: "\n"), name: name)
    }

    private func bbva(_ item: ImportItem) throws -> BBVAStatementEffect {
        guard case .bbvaStatement(let effect) = item.effect else {
            XCTFail("not a BBVA statement effect: \(item.effect)")
            throw CancellationError()
        }
        return effect
    }

    private func rows(_ accountId: Int64) throws -> [Transaction] {
        try db.read { db in try Transaction.filter(Column("accountId") == accountId).order(Column("date"), Column("id")).fetchAll(db) }
    }

    func testLeavingOutEarlierBBVAStatementMovesItsSharedRowsAndLegsToTheLater() async throws {
        try makeBBVAAccounts()
        var plan = try await pipeline.plan([pdf(february, name: "february.pdf"), pdf(earlyFebruary, name: "early.pdf")])
        XCTAssertEqual(try bbva(try item("february.pdf", in: plan)).staged.count, 2, "the instalment is the early download's")

        plan = try await pipeline.resolve(plan, itemId: try item("early.pdf", in: plan).id, .leaveOut)
        let later = try item("february.pdf", in: plan)
        let effect = try bbva(later)
        XCTAssertEqual(effect.staged.count, 3, "the instalment comes with the later statement")
        XCTAssertEqual(effect.instalments.count, 1, "and its legs")
        XCTAssertEqual(later.section, .ready, "\(later.needsYouReasons)")
        XCTAssertTrue(plan.canConfirm, "\(plan.items.map { ($0.title, $0.needsYouReasons) })")

        let summary = try applier.apply(plan, entryPoint: "Test")
        XCTAssertEqual(summary.transactions, 3)
        XCTAssertEqual(try rows(bbvaId).count, 3)
        XCTAssertEqual(try rows(loanId).map(\.amountMinorUnits), [81_253, -11_253])
    }

    func testLeavingOutEarlierBBVAMonthRechecksTheLaterBalance() async throws {
        try makeBBVAAccounts()
        var plan = try await pipeline.plan([pdf(march, name: "march.pdf"), pdf(february, name: "february.pdf")])
        let marchItem = try item("march.pdf", in: plan)
        XCTAssertEqual(marchItem.section, .ready, "\(marchItem.needsYouReasons)")

        plan = try await pipeline.resolve(plan, itemId: try item("february.pdf", in: plan).id, .leaveOut)
        let later = try item("march.pdf", in: plan)
        XCTAssertEqual(later.section, .needsYou)
        let mismatch = try XCTUnwrap(balanceIssues(later).first, "\(later.issues)")
        XCTAssertEqual(mismatch.id, "balance-\(bbvaId!)-2026-03-31")
        guard case .statement(.balanceMismatch(let values)) = mismatch.kind else { return XCTFail() }
        XCTAssertEqual(values.computedMinorUnits, 249_000)
        XCTAssertEqual(values.statementMinorUnits, 161_747)
    }

    func testASkippedInstalmentDebitNeverLetsAReceiptPair() async throws {
        try makeBBVAAccounts()
        // A saved row like the instalment debit (another description): it becomes a possible duplicate.
        let id = bbvaId!
        try await db.write { db in
            let parsed = ParsedTransaction(date: self.day(2026, 2, 4), rawDescription: "PRESTACAO HABITACAO", amountMinorUnits: -81_253,
                                           balanceAfterMinorUnits: nil)
            let row = StagedTransaction(parsed: parsed, suggestedCategoryId: nil, source: .none, confidence: 0, fingerprint: "earlier-instalment")
            _ = try ImportCoordinator.commit(db: db, accountId: id, sourceFileName: "earlier", staged: [row], decisions: [])
        }
        var plan = try await pipeline.plan([pdf(february, name: "february.pdf"), pdf(earlyFebruary, name: "early.pdf")])
        let early = try item("early.pdf", in: plan)
        let child = try XCTUnwrap(rowChildren(of: early, in: plan).first, "\(plan.items.map(\.title))")
        plan = try await pipeline.resolve(plan, itemId: child.id, .skipRow)

        let text = "Instalment of 05/02/2026 −€812.53 was skipped: its receipt has no debit"
        for name in ["early.pdf", "february.pdf"] {
            let statement = try item(name, in: plan)
            XCTAssertTrue(try bbva(statement).instalments.isEmpty, name)
            XCTAssertTrue(statement.issues.contains { $0.id == "instalmentMismatch.skipped.40" && $0.reason == text
                                                      && $0.kind == .statement(.instalmentMismatch(text)) }, "\(name): \(statement.issues.map(\.reason))")
            XCTAssertEqual(statement.section, .needsYou)
        }
        XCTAssertFalse(plan.canConfirm)
    }

    func testASkippedSubscriptionDebitNeverLetsAFundMovementPair() async throws {
        try makeBBVAAccounts()
        // A saved row like the subscription debit (another description): it becomes a possible duplicate.
        let id = bbvaId!
        try await db.write { db in
            let parsed = ParsedTransaction(date: self.day(2026, 2, 19), rawDescription: "FUND TOP UP", amountMinorUnits: -5_000,
                                           balanceAfterMinorUnits: nil)
            let row = StagedTransaction(parsed: parsed, suggestedCategoryId: nil, source: .none, confidence: 0, fingerprint: "earlier-subscription")
            _ = try ImportCoordinator.commit(db: db, accountId: id, sourceFileName: "earlier", staged: [row], decisions: [])
        }
        var plan = try await pipeline.plan([pdf(february, name: "february.pdf")])
        let statement = try item("february.pdf", in: plan)
        let child = try XCTUnwrap(rowChildren(of: statement, in: plan).first, "\(plan.items.map(\.title))")
        plan = try await pipeline.resolve(plan, itemId: child.id, .skipRow)

        let text = "Subscription of 20/02/2026 −€50.00 was skipped: its fund movement has no debit"
        let after = try item("february.pdf", in: plan)
        XCTAssertTrue(try bbva(after).fundPairs.isEmpty)
        XCTAssertTrue(after.issues.contains { $0.id == "fundMismatch.skipped.0" && $0.reason == text
                                              && $0.kind == .statement(.fundMismatch(text)) }, "\(after.issues.map(\.reason))")
        XCTAssertEqual(after.section, .needsYou)
        XCTAssertFalse(plan.canConfirm)
    }
}
