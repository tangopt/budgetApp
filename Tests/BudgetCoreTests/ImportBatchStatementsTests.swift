import XCTest
import GRDB
@testable import BudgetCore

/// Several UK statements of one account in one import: staged per account in date order, the
/// rows an earlier statement of the batch holds are already imported for the later ones, and
/// each closing balance check counts the earlier statements' rows. Synthetic data only.
final class ImportBatchStatementsTests: XCTestCase {
    private var manager: DatabaseManager!
    private var db: DatabaseQueue { manager.dbQueue }
    private var folder: URL!
    private var library: EvidenceLibrary!
    private var pipeline: ImportPipeline!
    private var applier: ImportApplier!
    private var accountId: Int64!

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
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("ImportBatchStatementsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        library = EvidenceLibrary(root: folder.appendingPathComponent("Library", isDirectory: true), database: db)
        pipeline = ImportPipeline(dbQueue: db, library: library, categorizationService: CategorizationService(categorizer: FakeCategorizer()))
        applier = ImportApplier(dbQueue: db, databasePath: nil, library: library)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    /// A CSV statement with a running balance; `extra` changes the bytes (a re-download).
    private func statement(_ name: String, _ rows: [(day: String, description: String, amount: String, balance: String)],
                           extra: String = "") throws -> URL {
        let directory = folder.appendingPathComponent("Drop", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        let text = "Date,Description,Amount,Balance\n" + rows.map { "\($0.day),\($0.description),\($0.amount),\($0.balance)\n" }.joined() + extra
        try Data(text.utf8).write(to: url)
        return url
    }

    private func statementItem(_ name: String, in plan: ImportPlan) throws -> ImportItem {
        try XCTUnwrap(plan.items.first { $0.file.fileName == name && $0.parentId == nil }, "no \(name) in \(plan.items.map(\.file.fileName))")
    }

    private func stagedRows(_ item: ImportItem) -> [StagedTransaction] {
        if case .ukStatement(let effect) = item.effect { return effect.staged }
        return []
    }

    private func savedCount() throws -> Int {
        let id = accountId!
        return try db.read { db in try Transaction.filter(Column("accountId") == id).fetchCount(db) }
    }

    private var intent: ImportIntent { ImportIntent(accountId: accountId) }

    func testIdenticalRedownloadTwiceInOneBatchIsAllDuplicate() async throws {
        let rows = [("05/01/2026", "SHOP A", "-10.00", "-10.00"), ("06/01/2026", "SHOP B", "-5.00", "-15.00")]
            .map { (day: $0.0, description: $0.1, amount: $0.2, balance: $0.3) }
        let first = try statement("first.csv", rows)
        let second = try statement("second.csv", rows, extra: "\n")
        let plan = try await pipeline.plan([first, second], intent: intent)
        XCTAssertEqual(stagedRows(try statementItem("first.csv", in: plan)).count, 2)
        let again = try statementItem("second.csv", in: plan)
        XCTAssertEqual(stagedRows(again).count, 0, "the earlier statement of the batch holds every row")
        let child = try XCTUnwrap(plan.items.first { $0.parentId == again.id })
        XCTAssertEqual(child.duplicate?.of, "2 rows already imported")
        XCTAssertTrue(plan.canConfirm, "\(plan.items.map { ($0.title, $0.needsYouReasons) })")
        let summary = try applier.apply(plan, entryPoint: "Test")
        XCTAssertEqual(summary.transactions, 2)
        XCTAssertEqual(try savedCount(), 2)
    }

    func testOverlappingStatementsAddOnlyTheMissingRows() async throws {
        let janToMar = try statement("jan-mar.csv", [(day: "05/01/2026", description: "SHOP A", amount: "-10.00", balance: "-10.00"),
                                                     (day: "05/02/2026", description: "SHOP B", amount: "-20.00", balance: "-30.00"),
                                                     (day: "05/03/2026", description: "SHOP C", amount: "-30.00", balance: "-60.00")])
        let febToApr = try statement("feb-apr.csv", [(day: "05/02/2026", description: "SHOP B", amount: "-20.00", balance: "-30.00"),
                                                     (day: "05/03/2026", description: "SHOP C", amount: "-30.00", balance: "-60.00"),
                                                     (day: "05/04/2026", description: "SHOP D", amount: "-40.00", balance: "-100.00")])
        // Handed in latest first: staged in date order all the same.
        let plan = try await pipeline.plan([febToApr, janToMar], intent: intent)
        XCTAssertEqual(stagedRows(try statementItem("jan-mar.csv", in: plan)).map(\.parsed.rawDescription), ["SHOP A", "SHOP B", "SHOP C"])
        let later = try statementItem("feb-apr.csv", in: plan)
        XCTAssertEqual(stagedRows(later).map(\.parsed.rawDescription), ["SHOP D"])
        XCTAssertEqual(plan.items.first { $0.parentId == later.id }?.duplicate?.of, "2 rows already imported")
        XCTAssertEqual(later.section, .ready, "\(later.needsYouReasons)")
        XCTAssertTrue(plan.canConfirm, "\(plan.items.map { ($0.title, $0.needsYouReasons) })")
        _ = try applier.apply(plan, entryPoint: "Test")
        XCTAssertEqual(try savedCount(), 4)
    }

    func testConsecutiveStatementsCheckTheLaterBalanceWithTheEarlierRows() async throws {
        let jan = try statement("jan.csv", [(day: "05/01/2026", description: "SALARY", amount: "100.00", balance: "100.00"),
                                            (day: "20/01/2026", description: "SHOP A", amount: "-20.00", balance: "80.00")])
        let feb = try statement("feb.csv", [(day: "05/02/2026", description: "SHOP B", amount: "-30.00", balance: "50.00")])
        let plan = try await pipeline.plan([feb, jan], intent: intent)
        let later = try statementItem("feb.csv", in: plan)
        XCTAssertFalse(later.issues.contains { $0.id == "balanceMismatch" }, "\(later.needsYouReasons)")
        XCTAssertEqual(later.section, .ready, "\(later.needsYouReasons)")
        XCTAssertTrue(plan.canConfirm)
        _ = try applier.apply(plan, entryPoint: "Test")
        XCTAssertEqual(try savedCount(), 3)
        let id = accountId!
        let stored = try await db.read { db in try Account.fetchOne(db, key: id) }
        let account = try XCTUnwrap(stored)
        XCTAssertNil(account.statementMismatchMinorUnits)
    }

    func testRowsOfALeftOutEarlierStatementAreStillAdded() async throws {
        let janToMar = try statement("jan-mar.csv", [(day: "05/01/2026", description: "SHOP A", amount: "-10.00", balance: "-10.00"),
                                                     (day: "05/02/2026", description: "SHOP B", amount: "-20.00", balance: "-30.00")])
        let febToApr = try statement("feb-apr.csv", [(day: "05/02/2026", description: "SHOP B", amount: "-20.00", balance: "-30.00"),
                                                     (day: "05/04/2026", description: "SHOP D", amount: "-40.00", balance: "-70.00")])
        var plan = try await pipeline.plan([janToMar, febToApr], intent: intent)
        plan = try await pipeline.resolve(plan, itemId: try statementItem("jan-mar.csv", in: plan).id, .leaveOut)
        _ = try applier.apply(plan, entryPoint: "Test")
        let id = accountId!
        let saved = try await db.read { db in try Transaction.filter(Column("accountId") == id).fetchAll(db).map(\.rawDescription).sorted() }
        XCTAssertEqual(saved, ["SHOP B", "SHOP D"], "the row only the left-out statement added comes with the later one")
    }

    func testStatementAddedToTheReviewCountsTheOnesAlreadyInIt() async throws {
        let rows = [(day: "05/01/2026", description: "SHOP A", amount: "-10.00", balance: "-10.00")]
        let first = try await pipeline.plan([try statement("first.csv", rows)], intent: intent)
        let plan = try await pipeline.plan(adding: [try statement("second.csv", rows, extra: "\n")], to: first, intent: intent)
        XCTAssertEqual(stagedRows(try statementItem("second.csv", in: plan)).count, 0)
        _ = try applier.apply(plan, entryPoint: "Test")
        XCTAssertEqual(try savedCount(), 1)
    }
}
