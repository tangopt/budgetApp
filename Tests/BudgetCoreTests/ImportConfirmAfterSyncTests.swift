import XCTest
import GRDB
@testable import BudgetCore

/// Confirm import on a database as the app opens it since build step 3: a file on disk, opened by
/// `DatabaseManager` (recursive triggers on) and migrated through `createSync` and
/// `importChangeRowUuid`, so every tracked table has its sync triggers. Driven through
/// `ImportSession` as the Imports screen drives it: read → review → Confirm import. What the run
/// wrote is committed and queued for sync, the planning copy is gone, and a Confirm that fails is
/// said in the review. Synthetic data only: Property A, its account Bank A with a €120.00 debit,
/// an insurance receipt of €120.00 made up for the test.
@MainActor
final class ImportConfirmAfterSyncTests: XCTestCase {
    private var folder: URL!
    private var manager: DatabaseManager!
    private var session: ImportSession!
    private var debitId: Int64 = 0
    private var db: DatabaseQueue { manager.dbQueue }

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("ImportConfirmAfterSyncTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let path = folder.appendingPathComponent("budget.sqlite").path
        manager = try DatabaseManager(path: path)
        try manager.migrate()
        try seed()
        let library = EvidenceLibrary(root: folder.appendingPathComponent("Evidence", isDirectory: true), database: db)
        session = ImportSession(dbQueue: db, databasePath: path, library: library,
                                categorizationService: CategorizationService(categorizer: FakeCategorizer()), modelReader: nil)
    }

    override func tearDown() async throws {
        if let session {
            session.discard()
            await session.settled()
            session.pipeline.discardPlanningCopy()
        }
        session = nil
        try? manager?.dbQueue.close()
        manager = nil
        try? FileManager.default.removeItem(at: folder)
    }

    private static func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        MonthRange.calendar.date(from: DateComponents(year: y, month: m, day: d))!
    }

    private func seed() throws {
        try db.write { db in
            var property = Property(name: "Property A", country: "PT")
            try Properties.save(db: db, &property)
            var account = Account(name: "Bank A", currency: .eur, kind: .cash, trackingMode: .imported)
            try account.insert(db)
            var batch = ImportBatch(accountId: account.id!, sourceFileName: "earlier.csv", importedAt: Date())
            try batch.insert(db)
            try Properties.setAccount(db: db, propertyId: property.id!, accountId: account.id!, role: .current)
            var debit = Transaction(importBatchId: batch.id!, accountId: account.id!, date: Self.date(2024, 3, 10), rawDescription: "PAYMENT 77",
                                    amountMinorUnits: -12_000, categoryId: nil, status: .confirmed, categorizedBy: .manual,
                                    fingerprint: "fp-debit")
            try debit.insert(db)
            debitId = debit.id!
        }
    }

    /// An insurance receipt of €120.00 paid by the debit.
    private func insurancePDF() throws -> URL {
        let made = EvidenceTestPDFs.textPDF(["SEGURO MULTI-RISCO HABITACAO", "Data: 10/03/2024", "TOTAL 120,00 €"], name: "seguro.pdf")
        let directory = folder.appendingPathComponent("Drop", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("seguro.pdf")
        try FileManager.default.moveItem(at: made, to: url)
        try? FileManager.default.removeItem(at: made.deletingLastPathComponent())
        return url
    }

    /// Reads the file into a review and waits for it to be ready to confirm.
    private func review() async throws {
        XCTAssertTrue(session.start([try insurancePDF()], entryPoint: "Import…"))
        await session.settled()
        XCTAssertEqual(session.phase, .review)
        let plan = try XCTUnwrap(session.plan)
        XCTAssertTrue(plan.canConfirm, "\(plan.items.map { ($0.file.fileName, $0.needsYouReasons) })")
    }

    private func pendingTables() async throws -> [String: Set<Int64>] {
        try await db.read { db in
            var pending: [String: Set<Int64>] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT tableName, localId FROM syncPending WHERE kind = 'insert'") {
                pending[row["tableName"], default: []].insert(row["localId"])
            }
            return pending
        }
    }

    func testDatabaseHasTheSyncSchema() throws {
        try db.read { db in
            XCTAssertTrue(try db.tableExists("syncPending"))
            XCTAssertTrue(try db.columns(in: "importChange").contains { $0.name == "rowUuid" })
            XCTAssertEqual(try Int.fetchOne(db, sql: "PRAGMA recursive_triggers"), 1)
            XCTAssertGreaterThan(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sqlite_master WHERE type = 'trigger' AND tbl_name = 'document'") ?? 0, 0)
        }
    }

    /// The live bug's path: the run, its document and the document's link are committed, and
    /// each is queued for sync.
    func testConfirmCommitsTheRunDocumentAndLinkAndQueuesThemForSync() async throws {
        try await review()
        let copy = try XCTUnwrap(session.pipeline.planningCopyPath)
        session.confirm(confirmedBy: nil)
        await session.settled()
        guard case .finished(let summary) = session.phase else {
            return XCTFail("Confirm didn't finish: \(session.phase), \(session.problem?.title ?? "no problem shown")")
        }
        XCTAssertNil(session.problem)
        XCTAssertEqual(summary.filed, 1)
        XCTAssertEqual(summary.linked, 1)

        // Read through a connection of its own: what is committed on disk, not the session's view.
        let reader = try DatabaseQueue(path: folder.appendingPathComponent("budget.sqlite").path)
        defer { try? reader.close() }
        let debitId = debitId
        let (documentId, linkId) = try await reader.read { db -> (Int64, Int64) in
            let run = try XCTUnwrap(ImportRun.fetchOne(db, key: summary.runId))
            XCTAssertEqual(run.entryPoint, "Import…")
            let file = try XCTUnwrap(ImportRunFile.filter(Column("runId") == summary.runId).fetchOne(db))
            XCTAssertEqual(file.outcome, .linked)
            let documentId = try XCTUnwrap(file.documentId)
            XCTAssertNotNil(try EvidenceDocument.fetchOne(db, key: documentId))
            let link = try XCTUnwrap(DocumentLink.filter(Column("documentId") == documentId).fetchAll(db)
                .first { $0.entity == .transaction(debitId) })
            return (documentId, try XCTUnwrap(link.id))
        }
        let pending = try await pendingTables()
        XCTAssertEqual(pending["importRun"], [summary.runId])
        XCTAssertEqual(pending["document"], [documentId])
        XCTAssertEqual(pending["documentLink"], [linkId])
        XCTAssertEqual(pending["importRunFile"]?.count, 1)
        XCTAssertGreaterThan(pending["importChange"]?.count ?? 0, 0)
        try await db.read { db in
            for (table, id) in [("importRun", summary.runId), ("document", documentId), ("documentLink", linkId)] {
                XCTAssertNotNil(try SyncRecordStore.existingUUID(table: table, localId: id, db: db), "\(table) \(id) has a sync record")
            }
        }

        XCTAssertNil(session.pipeline.planningCopyPath, "Confirm releases the planning copy")
        XCTAssertFalse(FileManager.default.fileExists(atPath: copy))
    }

    /// A Confirm that fails says so in the review (and writes nothing): never a silent no-op.
    func testFailedConfirmIsShownInTheReviewAndWritesNothing() async throws {
        try await review()
        let debitId = debitId
        try await db.write { db in _ = try Transaction.deleteOne(db, key: debitId) }
        session.confirm(confirmedBy: nil)
        await session.settled()
        XCTAssertEqual(session.phase, .review)
        let problem = try XCTUnwrap(session.problem, "the failure is shown")
        XCTAssertTrue(problem.title.hasPrefix("Nothing was imported"), problem.title)
        let runs = try await db.read { db in try ImportRun.fetchCount(db) }
        XCTAssertEqual(runs, 0)
        let pending = try await pendingTables()
        XCTAssertNil(pending["document"])
    }

    /// Discarding the review deletes its planning copy.
    func testDiscardDeletesThePlanningCopy() async throws {
        try await review()
        let copy = try XCTUnwrap(session.pipeline.planningCopyPath)
        XCTAssertTrue(copy.hasPrefix(ImportPlanningCopy.processFolder.path), "copies live in this process's folder")
        session.discard()
        await session.settled()
        XCTAssertNil(session.pipeline.planningCopyPath)
        XCTAssertFalse(FileManager.default.fileExists(atPath: copy))
    }
}
