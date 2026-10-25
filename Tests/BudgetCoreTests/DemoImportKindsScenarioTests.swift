import XCTest
import GRDB
@testable import BudgetCore
@testable import BudgetDemo

/// The demo's import-kind samples through `ImportSession` on the demo database, as the Imports
/// screen drives them: the three documents of one debit import without a duplicate alert, the
/// instalment pair is asked, the unknown file left out is offered to set aside and kept for later,
/// and a new kind made in a later import suggests the waiting file again. Synthetic data only.
@MainActor
final class DemoImportKindsScenarioTests: XCTestCase {
    private var folder: URL!
    private var sessions: [ImportSession] = []
    private static let fixedNow = Date(timeIntervalSince1970: 1_790_000_000)

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("DemoImportKinds-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        for session in sessions {
            session.discard()
            await session.settled()
            session.pipeline.discardPlanningCopy()
        }
        sessions = []
        try? FileManager.default.removeItem(at: folder)
    }

    private func demo() throws -> (db: DatabaseQueue, library: EvidenceLibrary, samples: [URL]) {
        let manager = try DatabaseManager(path: nil)
        try manager.migrate()
        let evidence = folder.appendingPathComponent("Evidence", isDirectory: true)
        try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)
        try DemoDatabase.build(dbQueue: manager.dbQueue, evidenceRoot: evidence)
        let samples = try DemoImportSamples.write(into: folder.appendingPathComponent("Samples", isDirectory: true), dbQueue: manager.dbQueue)
        sessions.append(ImportSession(dbQueue: manager.dbQueue, databasePath: nil, library: EvidenceLibrary(root: evidence, database: manager.dbQueue),
                                      categorizationService: CategorizationService(categorizer: FakeCategorizer()), modelReader: nil,
                                      now: { Self.fixedNow }))
        // Keep the manager alive with the session.
        managers.append(manager)
        return (manager.dbQueue, EvidenceLibrary(root: evidence, database: manager.dbQueue), samples)
    }

    private var managers: [DatabaseManager] = []

    private func sample(_ samples: [URL], _ names: String...) -> [URL] {
        names.map { name in samples.first { $0.lastPathComponent == name }! }
    }

    private func item(_ plan: ImportPlan?, _ name: String) throws -> ImportItem {
        let plan = try XCTUnwrap(plan)
        return try XCTUnwrap(plan.items.first { $0.file.fileName == name }, "\(plan.items.map(\.file.fileName))")
    }

    private func finished(_ session: ImportSession) throws -> ImportRunSummary {
        guard case .finished(let summary) = session.phase else {
            struct NotFinished: Error { var phase: String }
            XCTFail("not finished: \(session.phase) \(String(describing: session.problem))")
            throw NotFinished(phase: "\(session.phase)")
        }
        return summary
    }

    private func transactionId(_ db: DatabaseQueue, _ description: String, _ date: Date? = nil) throws -> Int64 {
        try db.read { db in
            var request = Transaction.filter(Column("rawDescription") == description)
            if let date { request = request.filter(Column("date") == date) }
            return try XCTUnwrap(try request.fetchOne(db)).id!
        }
    }

    private func documentNames(_ db: DatabaseQueue, linkedTo transactionId: Int64) throws -> [String] {
        try db.read { db in
            try String.fetchAll(db, sql: """
                SELECT d.originalFileName FROM documentLink l JOIN \(EvidenceDocument.databaseTableName) d ON d.id = l.documentId
                WHERE l.entityType = ? AND l.entityId = ? ORDER BY d.originalFileName
                """, arguments: [EvidenceEntityType.transaction.rawValue, transactionId])
        }
    }

    // MARK: The database

    func testDemoDatabaseHoldsTheNewKindsFeatures() throws {
        let (db, _, _) = try demo()
        // One debit with three documents; one invoice on two debits (the budget popover's cases).
        let tiling = try transactionId(db, "TILING EXEMPLO LDA")
        XCTAssertEqual(try documentNames(db, linkedTo: tiling).count, 3)
        let first = try transactionId(db, "SHUTTERS EXEMPLO LDA", DemoDatabase.date(2026, 6, 12))
        let second = try transactionId(db, "SHUTTERS EXEMPLO LDA", DemoDatabase.date(2026, 7, 10))
        XCTAssertEqual(try documentNames(db, linkedTo: first), ["Shutters invoice FT 2026-41.pdf"])
        XCTAssertEqual(try documentNames(db, linkedTo: second), ["Shutters invoice FT 2026-41.pdf"])
        // A custom kind with a document, and a file waiting for later.
        try db.read { db in
            let kind = try XCTUnwrap(try CustomDocumentKind.filter(Column("name") == "Boiler service").fetchOne(db))
            XCTAssertEqual(kind.area, .property)
            XCTAssertEqual(try EvidenceDocument.filter(Column("customKindId") == kind.id).fetchCount(db), 1)
            let waiting = try ImportWaitingFile.fetchAll(db)
            XCTAssertEqual(waiting.map(\.originalFileName), [DemoDatabase.waitingLetter.fileName])
            // The repair rule takes a repair bill or an older "other" document.
            let repairs = try EvidenceRequirement.fetchAll(db).filter { $0.name.lowercased().contains("repair") }
            XCTAssertFalse(repairs.isEmpty)
            XCTAssertTrue(repairs.allSatisfy { Set($0.kinds) == [.repairInvoice, .other] }, "\(repairs.map(\.kinds))")
        }
    }

    // MARK: Three documents of one debit

    func testTheThreeDocumentsOfOneDebitImportWithoutAnAlert() async throws {
        let (db, _, samples) = try demo()
        let session = sessions[0]
        session.start(sample(samples, "Exemplo Serviços FR 2026-31.pdf", "Exemplo Serviços RC 2026-22.pdf", "BBVA aviso de débito 2026-08-18.pdf"),
                      entryPoint: "Test")
        await session.settled()
        let plan = try XCTUnwrap(session.plan)
        let described = plan.items.map { "\($0.file.fileName): \($0.section) \($0.needsYouReasons)" }.joined(separator: "\n")
        XCTAssertEqual(plan.items.map(\.section), [.ready, .ready, .ready], described)
        XCTAssertTrue(plan.items.allSatisfy { $0.issues.isEmpty && $0.duplicate == nil }, described)
        XCTAssertEqual(Set(plan.items.map(\.recognition.kind)),
                       [.evidence(.repairInvoice), .evidence(.bankTransferProof), .evidence(.bankDebitAdvice)], described)
        XCTAssertTrue(plan.canConfirm)
        session.confirm(confirmedBy: nil)
        await session.settled()
        _ = try finished(session)
        let debit = try transactionId(db, DemoDatabase.Builder.sampleRepairDebit.description)
        XCTAssertEqual(try documentNames(db, linkedTo: debit).count, 3)
    }

    func testTheStampDutyNoteLinksToItsDebit() async throws {
        let (db, _, samples) = try demo()
        let session = sessions[0]
        session.start(sample(samples, "Nota de cobrança Imposto do Selo.pdf"), entryPoint: "Test")
        await session.settled()
        let note = try item(session.plan, "Nota de cobrança Imposto do Selo.pdf")
        XCTAssertEqual(note.recognition.kind, .evidence(.stampDuty))
        XCTAssertEqual(note.section, .ready, "\(note.needsYouReasons)")
        session.confirm(confirmedBy: nil)
        await session.settled()
        _ = try finished(session)
        XCTAssertEqual(try documentNames(db, linkedTo: try transactionId(db, DemoDatabase.Builder.sampleStampDutyDebit.description)).count, 1)
    }

    // MARK: Instalments

    func testTheInstalmentPairIsAskedThenKeptOnBothDebits() async throws {
        let (db, _, samples) = try demo()
        let session = sessions[0]
        let name = "Carpintaria Exemplo FT 2026-57.pdf"
        session.start(sample(samples, name), entryPoint: "Test")
        await session.settled()
        let asked = try item(session.plan, name)
        XCTAssertEqual(asked.section, .needsYou)
        XCTAssertEqual(asked.needsYouReasons, ["Paid in 2 instalments: €250.00 + €250.00"])
        XCTAssertEqual(asked.links.count, 2)
        XCTAssertEqual(asked.links.map(\.confidence), [.needsReview, .needsReview])
        XCTAssertFalse(try XCTUnwrap(session.plan).canConfirm)
        session.resolve(asked.id, issueId: EvidenceDocumentReader.instalmentsIssueId, .acknowledge)
        await session.settled()
        XCTAssertEqual(try item(session.plan, name).section, .ready)
        session.confirm(confirmedBy: nil)
        await session.settled()
        _ = try finished(session)
        let pair = DemoDatabase.Builder.sampleInstalmentDebits
        for day in [pair.first, pair.second] {
            XCTAssertEqual(try documentNames(db, linkedTo: try transactionId(db, pair.description, day)).count, 1)
        }
    }

    // MARK: Set aside, waiting, a new kind

    func testTheUnknownFileIsSetAsideKeptAndSuggestedAgainOnceItsKindExists() async throws {
        let (db, _, samples) = try demo()
        let session = sessions[0]
        let note = "Fogo Limpo note.pdf"
        // Imported with the stamp duty note, so the run has something to import.
        session.start(sample(samples, note, "Nota de cobrança Imposto do Selo.pdf"), entryPoint: "Test")
        await session.settled()
        let unknown = try item(session.plan, note)
        XCTAssertEqual(unknown.recognition.kind, .unknown)
        // Left out: the run finishes, offering the file to set aside.
        session.resolve(unknown.id, .leaveOut)
        await session.settled()
        session.confirm(confirmedBy: nil)
        await session.settled()
        let summary = try finished(session)
        XCTAssertEqual(summary.setAside.map(\.fileName), [note])
        XCTAssertEqual(session.takeSetAsideOffer().map(\.fileName), [note])
        // Keep for later: it waits beside the demo's own waiting letter, neither suggested yet.
        let kept = try await session.keep(summary.setAside)
        XCTAssertEqual(kept.kept.map(\.originalFileName), [note])
        await session.settled()
        XCTAssertEqual(Set(session.waiting.map(\.originalFileName)), [note, DemoDatabase.waitingLetter.fileName])
        XCTAssertTrue(session.waiting.allSatisfy { $0.suggestion == nil })

        // A later import: a letter of the same sender gets a new kind, "Chimney inspection".
        let later = folder.appendingPathComponent("Later", isDirectory: true)
        try FileManager.default.createDirectory(at: later, withIntermediateDirectories: true)
        let reminder = later.appendingPathComponent("Fogo Limpo reminder.pdf")
        try DemoPDF.data(DemoDatabase.page(issuer: "Fogo Limpo Lda", title: "Chimney inspection reminder",
                                           lines: [("Property", "Property A"), ("Inspection due", "September 2027"), ("Message", "Please book a visit.")]))
            .write(to: reminder)
        session.start([reminder], entryPoint: "Test")
        await session.settled()
        let second = try item(session.plan, reminder.lastPathComponent)
        XCTAssertEqual(second.recognition.kind, .unknown)
        session.resolve(second.id, .createKind(name: "Chimney inspection", area: .property))
        await session.settled()
        XCTAssertEqual(try XCTUnwrap(session.plan).pendingKinds.map(\.name), ["Chimney inspection"])
        session.confirm(confirmedBy: nil)
        await session.settled()
        _ = try finished(session)
        let created = try await db.read { db in try CustomDocumentKind.filter(Column("name") == "Chimney inspection").fetchCount(db) }
        XCTAssertEqual(created, 1)
        await session.reloadWaiting()
        XCTAssertEqual(session.waiting.map(\.suggestion), [String?](repeating: "Now recognised as Chimney inspection", count: 2),
                       "\(session.waiting.map { "\($0.originalFileName): \($0.suggestion ?? "-")" })")
    }
}
