import XCTest
import GRDB
@testable import BudgetCore
import TestSupport

/// UK bank CSV/PDF statements in the document importer: the account and saved profile are
/// resolved by the reader, rows are staged with rules-only categorisation, and each statement
/// becomes a review item (plus a duplicates child). Synthetic data only.
final class UKStatementReaderTests: XCTestCase {
    private var manager: DatabaseManager!
    private var dbQueue: DatabaseQueue { manager.dbQueue }
    private var accountId: Int64!
    private var groceriesId: Int64!
    private let csvRecognition = ImportRecognition(kind: .bankStatementCSV, confidence: .certain, reason: "CSV file")

    override func setUpWithError() throws {
        manager = try TestDatabase.migratedManager()
        try dbQueue.write { db in
            try CategorySeeder.seedDefaults(db)
            var account = Account(name: "Bank One", currency: .gbp, kind: .cash, trackingMode: .imported)
            try account.insert(db)
            accountId = account.id!
            groceriesId = try Category.filter(Column("name") == "Groceries").fetchOne(db)!.id!
            var rule = Rule(matchPattern: "TESCO", matchType: .contains, categoryId: groceriesId, priority: 10)
            try rule.insert(db)
        }
    }

    // MARK: Helpers

    private func profile(accountId: Int64, balance: Bool = false, accountColumns: Bool = false) -> ImportProfile {
        ImportProfile(accountId: accountId, format: .csv, csvDelimiter: ",", csvDateColumnIndex: 0, csvDescriptionColumnIndex: 1,
                      csvAmountColumnIndex: 2, csvBalanceColumnIndex: balance ? 3 : nil,
                      csvSortCodeColumnIndex: accountColumns ? 3 : nil, csvAccountNumberColumnIndex: accountColumns ? 4 : nil,
                      csvDateFormat: "dd/MM/yyyy")
    }

    @discardableResult
    private func save(_ profile: ImportProfile) throws -> ImportProfile {
        try ImportProfileStore(dbQueue: dbQueue).save(profile)
    }

    private func csvFile(_ text: String, name: String = "statement.csv") -> ImportFile {
        ImportFile(url: URL(fileURLWithPath: "/tmp/\(name)"), fileName: name, sha256: "sha-\(name)", byteCount: Int64(text.utf8.count),
                   fileExtension: "csv", text: text, textStatus: .text, usedOCR: false)
    }

    private func coordinator(suggesting name: String? = "Eating Out") -> ImportCoordinator {
        let fake = FakeCategorizer()
        fake.stubbedSuggestion = name.map { CategorySuggestion(categoryName: $0, confidence: 0.95) }
        return ImportCoordinator(dbQueue: dbQueue, categorizationService: CategorizationService(categorizer: fake))
    }

    private func context(accountId: Int64? = nil) throws -> ImportContext {
        try dbQueue.read { db in try ImportContext.load(db: db, intent: ImportIntent(accountId: accountId), now: Date()) }
    }

    private func resolve(_ file: ImportFile, context: ImportContext) throws -> UKStatementReader.Resolution {
        try dbQueue.read { db in try UKStatementReader.resolve(file: file, recognition: csvRecognition, context: context, db: db) }
    }

    private func items(_ file: ImportFile, accountId: Int64, profile: ImportProfile, staged: StagedImport, context: ImportContext) throws -> [ImportItem] {
        try dbQueue.read { db in
            // Checked as the pipeline checks the review (`StatementChecks`), here alone.
            try StatementChecks.recheck(UKStatementReader.items(file: file, recognition: csvRecognition, accountId: accountId, profile: profile,
                                                                staged: staged, context: context, db: db), db: db)
        }
    }

    private func commit(_ staged: [StagedTransaction], importRunId: Int64? = nil) throws {
        try dbQueue.write { db in
            _ = try ImportCoordinator.commit(db: db, accountId: accountId, sourceFileName: "earlier.csv", staged: staged,
                                             decisions: [], importRunId: importRunId)
        }
    }

    /// Resolve → stage (rules only) → items, as the pipeline does.
    private func plan(_ file: ImportFile, context: ImportContext) async throws -> [ImportItem] {
        let resolution = try resolve(file, context: context)
        guard case .resolved(let resolvedAccountId, let profile) = resolution else {
            XCTFail("not resolved: \(resolution)")
            return []
        }
        let staged = try await UKStatementReader.stage(file: file, recognition: csvRecognition, accountId: resolvedAccountId,
                                                      profile: profile, coordinator: coordinator())
        return try items(file, accountId: resolvedAccountId, profile: profile, staged: staged, context: context)
    }

    private func propose(_ file: ImportFile, context: ImportContext) throws -> [ImportItem] {
        try dbQueue.read { db in try UKStatementReader().propose([(file, csvRecognition)], context: context, db: db) }
    }

    private static let threeRows = "Date,Description,Amount\n01/07/2026,TESCO STORES,-12.50\n02/07/2026,NEWSHOP LTD,-8.00\n03/07/2026,SALARY,1500.00"

    private func insertPastNewshopRow() throws {
        try dbQueue.write { db in
            var batch = ImportBatch(accountId: accountId, sourceFileName: "old.csv", importedAt: Date())
            try batch.insert(db)
            var past = Transaction(importBatchId: batch.id!, accountId: accountId, date: Date(timeIntervalSince1970: 0),
                                   rawDescription: "NEWSHOP LTD", amountMinorUnits: -100, categoryId: groceriesId,
                                   status: .confirmed, categorizedBy: .manual, fingerprint: "old-1")
            try past.insert(db)
        }
    }

    private func newRun() throws -> Int64 {
        try dbQueue.write { db in
            var run = ImportRun(confirmedAt: Date(), entryPoint: "Import…", summary: "test")
            try run.insert(db)
            return run.id!
        }
    }

    private func batchRunIds() throws -> [Int64?] {
        try dbQueue.read { db in try ImportBatch.fetchAll(db).map(\.importRunId) }
    }

    /// Bank One gets 99-88-77 / 99998888; Bank Two (11-22-33 / 11112222) and Bank Three
    /// (no details) are added. Returns their ids.
    private func addAccountsWithDetails() throws -> (other: Int64, blank: Int64) {
        try dbQueue.write { db in
            var other = Account(name: "Bank Two", currency: .gbp, kind: .cash, trackingMode: .imported, sortCode: "11-22-33", accountNumber: "11112222")
            try other.insert(db)
            var blank = Account(name: "Bank Three", currency: .gbp, kind: .cash, trackingMode: .imported)
            try blank.insert(db)
            var mine = try Account.fetchOne(db, key: accountId)!
            mine.sortCode = "99-88-77"
            mine.accountNumber = "99998888"
            try mine.update(db)
            return (other.id!, blank.id!)
        }
    }

    // MARK: Coordinator: rules-only categorisation

    func testRulesOnlyLeavesUnmatchedRowsUncategorised() async throws {
        // A past categorised NEWSHOP row: history would suggest it under `.full`.
        try insertPastNewshopRow()
        let csv = "Date,Description,Amount\n01/07/2026,TESCO STORES,-12.50\n02/07/2026,NEWSHOP LTD,-8.00\n03/07/2026,OTHER PLACE,-3.00"
        let coordinator = coordinator(suggesting: "Eating Out")

        let full = try await coordinator.stageCSVImport(csvText: csv, profile: profile(accountId: accountId), accountId: accountId)
        XCTAssertNotNil(full.staged.first { $0.parsed.rawDescription == "OTHER PLACE" }?.suggestedCategoryId, "the categorizer would suggest")
        XCTAssertNotNil(full.staged.first { $0.parsed.rawDescription == "NEWSHOP LTD" }?.suggestedCategoryId, "history would suggest")

        let staged = try await coordinator.stageCSVImport(csvText: csv, profile: profile(accountId: accountId), accountId: accountId,
                                                          categorization: .rulesOnly)
        let tesco = staged.staged.first { $0.parsed.rawDescription == "TESCO STORES" }
        XCTAssertEqual(tesco?.source, .rule)
        XCTAssertEqual(tesco?.suggestedCategoryId, groceriesId)
        XCTAssertEqual(tesco?.confidence, 1)
        for description in ["NEWSHOP LTD", "OTHER PLACE"] {
            let row = staged.staged.first { $0.parsed.rawDescription == description }
            XCTAssertNil(row?.suggestedCategoryId, description)
            XCTAssertEqual(row?.source, CategorizedBy.none, description)
        }
    }

    func testCommitStampsTheImportRun() async throws {
        let staged = try await coordinator().stageCSVImport(csvText: Self.threeRows, profile: profile(accountId: accountId), accountId: accountId,
                                                            categorization: .rulesOnly)
        let runId = try newRun()
        try commit(staged.staged, importRunId: runId)
        XCTAssertEqual(try batchRunIds(), [runId])
    }

    // MARK: Reader

    func testCSVForAccountWithProfileIsReadyWithRowCount() async throws {
        try save(profile(accountId: accountId))
        let file = csvFile(Self.threeRows)
        let context = try context(accountId: accountId)
        XCTAssertTrue(try propose(file, context: context).isEmpty, "a resolved statement is staged by the pipeline")

        let items = try await plan(file, context: context)
        XCTAssertEqual(items.count, 1)
        let item = try XCTUnwrap(items.first)
        XCTAssertEqual(item.section, .ready, "\(item.needsYouReasons)")
        XCTAssertEqual(item.title, "Bank One statement 1 Jul 2026–3 Jul 2026")
        XCTAssertEqual(item.groupKey, "Bank statements")
        XCTAssertEqual(item.placement?.metadata.kind, .bankStatement)
        XCTAssertTrue(item.facts.contains { $0.field == .reference && $0.value == .text("Bank One") })
        guard case .ukStatement(let effect) = item.effect else { return XCTFail("effect \(item.effect)") }
        XCTAssertEqual(effect.accountId, accountId)
        XCTAssertEqual(effect.sourceFileName, "statement.csv")
        XCTAssertEqual(effect.staged.count, 3)
        XCTAssertNil(effect.statement)
        XCTAssertEqual(effect.decisions.map(\.learnRule), [false, false, false])
        XCTAssertEqual(effect.decisions.map(\.finalCategoryId), effect.staged.map(\.suggestedCategoryId))

        let plan = ImportPlan(items: items)
        XCTAssertEqual(plan.readyGroups.map(\.summary), ["1 statement → 3 transactions"])
    }

    func testAlreadyImportedRowsBecomeADuplicateChild() async throws {
        let saved = try save(profile(accountId: accountId))
        let first = try await coordinator().stageCSVImport(
            csvText: "Date,Description,Amount\n01/07/2026,TESCO STORES,-12.50\n02/07/2026,NEWSHOP LTD,-8.00",
            profile: saved, accountId: accountId, categorization: .rulesOnly)
        try commit(first.staged)

        let items = try await plan(csvFile(Self.threeRows), context: try context(accountId: accountId))
        XCTAssertEqual(items.count, 2)
        let parent = try XCTUnwrap(items.first { $0.parentId == nil })
        let child = try XCTUnwrap(items.first { $0.parentId != nil })
        XCTAssertEqual(child.parentId, parent.id)
        XCTAssertEqual(child.duplicate, ImportDuplicate(level: .transactions, of: "2 rows already imported"))
        XCTAssertEqual(child.section, .duplicates)
        XCTAssertEqual(parent.section, .ready)
        guard case .ukStatement(let effect) = parent.effect else { return XCTFail("effect \(parent.effect)") }
        XCTAssertEqual(effect.staged.map(\.parsed.rawDescription), ["SALARY"])
        XCTAssertEqual(ImportPlan(items: items).readyGroups.map(\.summary), ["1 statement → 1 transaction"])
    }

    func testCSVWithoutProfileIsNeedsYouNoProfile() throws {
        let items = try propose(csvFile(Self.threeRows), context: try context(accountId: accountId))
        XCTAssertEqual(items.count, 1)
        let item = try XCTUnwrap(items.first)
        XCTAssertEqual(item.section, .needsYou)
        XCTAssertEqual(item.issues.map(\.kind), [.statement(.noProfile(format: .csv, accountId: accountId))])
        XCTAssertEqual(item.issues.first?.offers, [])
    }

    func testAccountFoundBySortCodeWhenNoIntent() async throws {
        let (other, blank) = try addAccountsWithDetails()
        for id in [accountId!, other, blank] { try save(profile(accountId: id, accountColumns: true)) }
        let csv = "Date,Description,Amount,Sort Code,Account Number\n"
            + "01/07/2026,TESCO STORES,-12.50,'99-88-77,99998888\n02/07/2026,NEWSHOP LTD,-8.00,'99-88-77,99998888"
        let context = try context()

        let resolution = try resolve(csvFile(csv), context: context)
        guard case .resolved(let found, let profile) = resolution else { return XCTFail("not resolved: \(resolution)") }
        XCTAssertEqual(found, accountId)
        XCTAssertEqual(profile.accountId, accountId)
        XCTAssertTrue(try propose(csvFile(csv), context: context).isEmpty)

        let items = try await plan(csvFile(csv), context: context)
        XCTAssertEqual(items.first?.section, .ready, "\(items.first?.needsYouReasons ?? [])")
        XCTAssertEqual(items.first?.title, "Bank One statement 1 Jul 2026–2 Jul 2026")
        XCTAssertEqual(items.first?.facts.first { $0.field == .reference }?.reason, "Sort code and account number match Bank One")
    }

    func testUnknownAccountWhenNothingMatches() throws {
        try save(profile(accountId: accountId, accountColumns: true))
        let csv = "Date,Description,Amount,Sort Code,Account Number\n01/07/2026,TESCO STORES,-12.50,10-20-30,10203040"
        let items = try propose(csvFile(csv), context: try context())
        XCTAssertEqual(items.map { $0.issues.map(\.kind) }, [[.statement(.unknownAccount)]])
        XCTAssertEqual(items.first?.section, .needsYou)
    }

    func testUnparsedLinesNeedAcknowledging() async throws {
        try save(profile(accountId: accountId))
        let csv = Self.threeRows + "\nnot a date,BROKEN ROW,abc"
        let items = try await plan(csvFile(csv), context: try context(accountId: accountId))
        let item = try XCTUnwrap(items.first)
        XCTAssertEqual(item.section, .needsYou)
        let issue = try XCTUnwrap(item.issues.first)
        guard case .statement(.unparsedLines(let lines)) = issue.kind else { return XCTFail("issue \(issue.kind)") }
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(issue.offers, [.acknowledge])
    }

    func testClosingBalanceMismatchIsNeedsYou() async throws {
        try save(profile(accountId: accountId, balance: true))
        // The account has nothing yet, so it computes −20.50 while the statement closes at 79.50.
        let csv = "Date,Description,Amount,Balance\n01/07/2026,TESCO STORES,-12.50,87.50\n02/07/2026,NEWSHOP LTD,-8.00,79.50"
        let items = try await plan(csvFile(csv), context: try context(accountId: accountId))
        let item = try XCTUnwrap(items.first)
        XCTAssertEqual(item.section, .needsYou)
        guard case .statement(.balanceMismatch(let mismatch)) = item.issues.first?.kind else {
            return XCTFail("issues \(item.issues)")
        }
        XCTAssertEqual(mismatch.statementMinorUnits, 7950)
        XCTAssertEqual(mismatch.computedMinorUnits, -2050)
        guard case .ukStatement(let effect) = item.effect else { return XCTFail("effect \(item.effect)") }
        XCTAssertEqual(effect.statement?.closing.balanceMinorUnits, 7950)
        XCTAssertEqual(effect.statement?.addAdjustment, false)
    }

    private func setDetails(_ id: Int64, sortCode: String?, accountNumber: String?) throws {
        try dbQueue.write { db in
            var account = try Account.fetchOne(db, key: id)!
            account.sortCode = sortCode
            account.accountNumber = accountNumber
            try account.update(db)
        }
    }

    private func addAccount(_ name: String, sortCode: String?, accountNumber: String?) throws -> Int64 {
        try dbQueue.write { db in
            var account = Account(name: name, currency: .gbp, kind: .cash, trackingMode: .imported, sortCode: sortCode, accountNumber: accountNumber)
            try account.insert(db)
            return account.id!
        }
    }

    private static func detailsCSV(sortCode: String, accountNumber: String) -> String {
        "Date,Description,Amount,Sort Code,Account Number\n01/07/2026,TESCO STORES,-12.50,\(sortCode),\(accountNumber)"
    }

    private static let pdfConfig = PDFLayoutConfig(regexPattern: #"^(\d{2} \w{3} \d{2})\s+(.+?)\s+([\d.]+)\s*(?:DR|CR)?$"#, dateFormat: "dd MMM yy")
    private static let pdfLines = ["01 Jul 26   TESCO STORES        12.50 DR", "02 Jul 26   NEWSHOP LTD        8.00 DR"]
    private let pdfRecognition = ImportRecognition(kind: .bankStatementPDF, confidence: .certain, reason: "Bank statement wording")

    private func pdfProfile(layout: Bool = true) throws -> ImportProfile {
        try save(ImportProfile(accountId: accountId, format: .pdf, pdfLayoutConfig: layout ? try Self.pdfConfig.encoded() : nil))
    }

    private func pdfFile(_ url: URL, text: String?) -> ImportFile {
        ImportFile(url: url, fileName: url.lastPathComponent, sha256: "sha-pdf", byteCount: 1, fileExtension: "pdf", text: text,
                   textStatus: text == nil ? .image : .text, usedOCR: false)
    }

    private func resolvePDF(_ file: ImportFile, context: ImportContext) throws -> UKStatementReader.Resolution {
        try dbQueue.read { db in try UKStatementReader.resolve(file: file, recognition: pdfRecognition, context: context, db: db) }
    }

    // MARK: Fix round 1

    func testSortCodeOnlyAgreementIsUnknownAccount() throws {
        try setDetails(accountId, sortCode: "99-88-77", accountNumber: nil)
        try save(profile(accountId: accountId, accountColumns: true))
        let resolution = try resolve(csvFile(Self.detailsCSV(sortCode: "99-88-77", accountNumber: "22223333")), context: try context())
        guard case .unresolved(let item) = resolution else { return XCTFail("resolved: \(resolution)") }
        XCTAssertEqual(item.issues.map(\.kind), [.statement(.unknownAccount)])
    }

    func testSharedSortCodePicksTheAccountWithTheNumber() async throws {
        try setDetails(accountId, sortCode: "99-88-77", accountNumber: "99998888")
        let sibling = try addAccount("Bank Two", sortCode: "99-88-77", accountNumber: "99997777")
        for id in [accountId!, sibling] { try save(profile(accountId: id, accountColumns: true)) }
        let file = csvFile(Self.detailsCSV(sortCode: "99-88-77", accountNumber: "99997777"))
        let context = try context()
        guard case .resolved(let found, _) = try resolve(file, context: context) else { return XCTFail("not resolved") }
        XCTAssertEqual(found, sibling)
        let items = try await plan(file, context: context)
        guard case .ukStatement(let effect) = items.first?.effect else { return XCTFail("no effect") }
        XCTAssertNil(effect.accountFill)
    }

    func testAccountNumberOnlyFileMatchesByNumber() async throws {
        try setDetails(accountId, sortCode: "99-88-77", accountNumber: "99998888")
        try save(profile(accountId: accountId, accountColumns: true))
        let csv = "Date,Description,Amount,Sort Code,Account Number\n01/07/2026,TESCO STORES,-12.50,,99998888"
        let items = try await plan(csvFile(csv), context: try context())
        XCTAssertEqual(items.first?.facts.first { $0.field == .reference }?.reason, "Account number matches Bank One")
    }

    func testTwoEquallyMatchingAccountsAreUnknown() throws {
        try setDetails(accountId, sortCode: "99-88-77", accountNumber: "99998888")
        let twin = try addAccount("Bank Two", sortCode: "99-88-77", accountNumber: "99998888")
        for id in [accountId!, twin] { try save(profile(accountId: id, accountColumns: true)) }
        let resolution = try resolve(csvFile(Self.detailsCSV(sortCode: "99-88-77", accountNumber: "99998888")), context: try context())
        guard case .unresolved(let item) = resolution else { return XCTFail("resolved: \(resolution)") }
        XCTAssertEqual(item.issues.map(\.kind), [.statement(.unknownAccount)])
    }

    func testIntentAccountWithOtherDetailsIsAReaderProblem() async throws {
        try setDetails(accountId, sortCode: "99-88-77", accountNumber: "99998888")
        try save(profile(accountId: accountId, accountColumns: true))
        let items = try await plan(csvFile(Self.detailsCSV(sortCode: "11-22-33", accountNumber: "11112222")), context: try context(accountId: accountId))
        let item = try XCTUnwrap(items.first)
        XCTAssertEqual(item.section, .needsYou)
        XCTAssertEqual(item.issues.map(\.id), ["accountMismatch"])
        guard case .readerProblem(let message) = item.issues.first?.kind else { return XCTFail("issues \(item.issues)") }
        XCTAssertEqual(message, "This file is for sort code 11-22-33, account 11112222 — Bank One is 99-88-77, 99998888.")
        XCTAssertEqual(item.facts.first { $0.field == .reference }?.reason, "You chose Bank One")
    }

    func testPDFStagedWithTheSavedLayout() async throws {
        let profile = try pdfProfile()
        let file = pdfFile(EvidenceTestPDFs.textPDF(Self.pdfLines, name: "statement.pdf"), text: nil)
        let context = try context(accountId: accountId)
        guard case .resolved(let found, let resolved) = try resolvePDF(file, context: context) else { return XCTFail("not resolved") }
        XCTAssertEqual(resolved, profile)
        let staged = try await UKStatementReader.stage(file: file, recognition: pdfRecognition, accountId: found, profile: resolved,
                                                      coordinator: coordinator())
        XCTAssertEqual(staged.staged.map(\.parsed.rawDescription), ["TESCO STORES", "NEWSHOP LTD"])
        XCTAssertEqual(staged.staged.first?.source, .rule)
    }

    func testScannedPDFFallsBackToTheFileText() async throws {
        let profile = try pdfProfile()
        let file = pdfFile(EvidenceTestPDFs.imagePDF(name: "scan.pdf"), text: Self.pdfLines.joined(separator: "\n"))
        let staged = try await UKStatementReader.stage(file: file, recognition: pdfRecognition, accountId: accountId, profile: profile,
                                                      coordinator: coordinator())
        XCTAssertEqual(staged.staged.count, 2)
    }

    func testPDFProfileWithoutLayoutIsNeedsYou() throws {
        _ = try pdfProfile(layout: false)
        let file = pdfFile(URL(fileURLWithPath: "/tmp/statement.pdf"), text: nil)
        guard case .unresolved(let item) = try resolvePDF(file, context: try context(accountId: accountId)) else { return XCTFail("resolved") }
        XCTAssertEqual(item.section, .needsYou)
        XCTAssertEqual(item.issues.map(\.id), ["noPDFLayout"])
    }

    func testPDFWithoutProfileIsNoProfile() throws {
        let file = pdfFile(URL(fileURLWithPath: "/tmp/statement.pdf"), text: nil)
        guard case .unresolved(let item) = try resolvePDF(file, context: try context(accountId: accountId)) else { return XCTFail("resolved") }
        XCTAssertEqual(item.issues.map(\.kind), [.statement(.noProfile(format: .pdf, accountId: accountId))])
    }

    func testStatementSummaryPlurals() {
        func item(rows: Int) -> ImportItem {
            let staged = (0..<rows).map { index in
                StagedTransaction(parsed: ParsedTransaction(date: Date(), rawDescription: "ROW \(index)", amountMinorUnits: -100),
                                  suggestedCategoryId: nil, source: .none, confidence: 0, fingerprint: "f\(index)")
            }
            return ImportItem(file: csvFile("", name: "s\(rows).csv"), recognition: csvRecognition, title: "Statement",
                              effect: .ukStatement(UKStatementEffect(accountId: 1, sourceFileName: "s.csv", staged: staged, statement: nil, accountFill: nil)),
                              groupKey: UKStatementReader.groupKey)
        }
        XCTAssertEqual(ImportPlan(items: [item(rows: 2), item(rows: 1), item(rows: 3)]).readyGroups.map(\.summary), ["3 statements → 6 transactions"])
    }

    func testDefaultReadersIncludeTheStatementReaderBeforeEvidence() {
        let readers = ImportReaders.defaultReaders(providers: [])
        let index = readers.firstIndex { $0 is UKStatementReader }
        XCTAssertNotNil(index)
        XCTAssertEqual(readers.firstIndex { $0.handles(.bankStatementCSV) }, index)
        XCTAssertEqual(readers.firstIndex { $0.handles(.bankStatementPDF) }, index)
    }
}
