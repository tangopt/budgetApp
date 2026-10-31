import XCTest
@testable import BudgetCore
import GRDB
import TestSupport

/// The iPhone's import inbox and batch: intake order and the 20-file cap, unreadable files as cards, copies released on
/// cancel, the original never moved; batch ordering, classification routing, totals, Undo's scope.
final class ImportInboxTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("import-inbox-tests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: folder) }

    private func inbox() -> ImportInbox { ImportInbox(directory: folder.appendingPathComponent("Inbox", isDirectory: true)) }

    private func write(_ name: String, _ text: String) throws -> URL {
        let url = folder.appendingPathComponent("picked", isDirectory: true).appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        return url
    }

    func testTakesPDFCSVAndPhotosInTheOrderOffered() throws {
        let inbox = inbox()
        let pdf = try WebFixtures.copy("bill.pdf")
        let csv = try write("march.csv", "date,amount\n2026-03-01,-10.00\n")
        let photo = try write("receipt.jpg", "not really a jpeg, but bytes")
        let intake = inbox.add([csv, pdf, photo])
        XCTAssertEqual(intake.entries.map(\.name), ["march.csv", "bill.pdf", "receipt.jpg"])
        XCTAssertEqual(intake.overflow, 0)
        XCTAssertNil(intake.overflowNote)
        XCTAssertEqual(inbox.tray.items().count, 3)
        let items = intake.entries.compactMap { entry -> TrayItem? in if case .file(let item) = entry { item } else { nil } }
        XCTAssertEqual(items.map(\.fileExtension), ["csv", "pdf", "jpg"])
    }

    func testOriginalStaysWhereItWas() throws {
        let csv = try write("march.csv", "a,b\n1,2\n")
        _ = inbox().add([csv])
        XCTAssertTrue(FileManager.default.fileExists(atPath: csv.path), "the picked file is copied, never moved or deleted")
    }

    func testMoreThanTwentyKeepsTheFirstTwentyAndCountsTheRest() throws {
        let urls = try (1...27).map { try write("f\($0).csv", "row \($0)\n") }
        let intake = inbox().add(urls)
        XCTAssertEqual(intake.entries.count, 20)
        XCTAssertEqual(intake.entries.first?.name, "f1.csv")
        XCTAssertEqual(intake.overflow, 7)
        XCTAssertEqual(intake.overflowNote, "20 of 27 added, import the rest next")
        XCTAssertEqual(PhoneImportBatch(intake).overflowNote, "20 of 27 added, import the rest next")
    }

    func testUnreadableFilesBecomeCardsAndTheBatchContinues() throws {
        let intake = inbox().add([try write("a.docx", "x"), try write("b.ofx", "OFXHEADER"), try write("c.csv", "1,2\n"), try write("empty.csv", "")])
        XCTAssertEqual(intake.entries.count, 4)
        XCTAssertEqual(intake.entries[0], .unsupported(name: "a.docx", reason: ImportInboxCopy.unsupported))
        XCTAssertEqual(intake.entries[1], .unsupported(name: "b.ofx", reason: ImportInboxCopy.ofx))
        if case .file = intake.entries[2] {} else { XCTFail("the CSV is kept") }
        XCTAssertEqual(intake.entries[3], .unsupported(name: "empty.csv", reason: ImportInboxCopy.empty))
        let batch = PhoneImportBatch(intake)
        XCTAssertEqual(batch.files.map(\.kind), [.cantRead, .cantRead, nil, .cantRead])
        XCTAssertEqual(inbox().tray.items().count, 1)
    }

    func testTheSameFileTwiceIsOneEntry() throws {
        let a = try write("a.csv", "same\n")
        let b = try write("b.csv", "same\n")
        XCTAssertEqual(inbox().add([a, b]).entries.count, 1)
    }

    func testCancelReleasesTheCopies() throws {
        let inbox = inbox()
        let intake = inbox.add([try write("a.csv", "x\n"), try WebFixtures.copy("bill.pdf")])
        let items = intake.entries.compactMap { entry -> TrayItem? in if case .file(let item) = entry { item } else { nil } }
        inbox.release(items)
        XCTAssertEqual(inbox.tray.items(), [])
        for item in items { XCTAssertFalse(FileManager.default.fileExists(atPath: inbox.tray.fileURL(for: item).path)) }
        _ = inbox.add([try write("b.csv", "y\n")])
        inbox.releaseAll()
        XCTAssertEqual(inbox.tray.items(), [])
    }

    func testTrayStillTakesOnlyPDFsByDefaultAndReadsOldIndexes() throws {
        let tray = DownloadsTray(directory: folder.appendingPathComponent("Tray", isDirectory: true))
        XCTAssertThrowsError(try tray.ingest(fileAt: try write("a.csv", "x\n"), suggestedName: "a.csv", sourceHost: nil)) {
            XCTAssertEqual($0 as? TrayError, .notAPDF)
        }
        let old = #"[{"id":"\#(UUID().uuidString)","fileName":"x.pdf","sha256":"s","byteCount":1,"receivedAt":0}]"#
        let decoded = try JSONDecoder().decode([TrayItem].self, from: Data(old.utf8))
        XCTAssertEqual(decoded.first?.fileExtension, "pdf")
    }

    // MARK: Batch

    private func file(_ name: String, _ kind: PhoneImportBatch.Kind? = nil) -> PhoneImportBatch.File { .init(id: UUID(), name: name, kind: kind) }

    func testBatchKeepsTheChosenOrderAndAdvancesPastSettledFiles() {
        let files = [file("1"), file("2"), file("3")]
        var batch = PhoneImportBatch(files: files)
        XCTAssertEqual(batch.positionLabel, "File 1 of 3")
        XCTAssertTrue(batch.finish(files[0].id, .saved(documentId: 1, title: "Bill", linked: true)))
        XCTAssertEqual(batch.current, 1)
        // Out of order: the review jumps to 3 and the primary on 3 acts on 3 only.
        batch.select(2)
        XCTAssertTrue(batch.skip(files[2].id))
        XCTAssertEqual(batch.current, 1, "after the last file, back to the first one still waiting")
        XCTAssertFalse(batch.finish(files[1].id, .alreadyInMango(rows: 3)))
        XCTAssertTrue(batch.isFinished)
        XCTAssertEqual(batch.files.map(\.outcome), [.saved(documentId: 1, title: "Bill", linked: true), .alreadyInMango(rows: 3), .notImported])
    }

    func testTotalsCountRowsDuplicatesDocumentsAndTheSkipped() {
        let files = (1...5).map { file("f\($0)") }
        var batch = PhoneImportBatch(files: files)
        batch.finish(files[0].id, .imported(accountId: 1, accountName: "Current", rows: 14, skipped: 3, runId: 10))
        batch.finish(files[1].id, .imported(accountId: 1, accountName: "Current", rows: 14, skipped: 2, runId: 11))
        batch.finish(files[2].id, .alreadyInMango(rows: 17))
        batch.finish(files[3].id, .saved(documentId: 4, title: "Water", linked: true))
        batch.skip(files[4].id)
        let totals = batch.totals
        XCTAssertEqual(totals.newRows, 28)
        XCTAssertEqual(totals.alreadyInMango, 22)
        XCTAssertEqual(totals.documentsSaved, 1)
        XCTAssertEqual(totals.documentsLinked, 1)
        XCTAssertEqual(totals.notImported, 1)
        XCTAssertEqual(batch.accountsTouched.map(\.rows), [28])
    }

    func testUndoCoversOnlyThisBatchsStatementRuns() {
        let files = (1...4).map { file("f\($0)") }
        var batch = PhoneImportBatch(files: files)
        batch.finish(files[0].id, .imported(accountId: 1, accountName: "A", rows: 5, skipped: 0, runId: 7))
        batch.finish(files[1].id, .saved(documentId: 9, title: "Doc", linked: false))
        batch.finish(files[2].id, .alreadyInMango(rows: 2))
        batch.finish(files[3].id, .imported(accountId: 2, accountName: "B", rows: 1, skipped: 0, runId: 8))
        XCTAssertEqual(batch.undoRunIds, [7, 8])
        batch.markUndone([7, 8])
        XCTAssertEqual(batch.undoRunIds, [])
        XCTAssertEqual(batch.totals.newRows, 0)
        XCTAssertEqual(batch.totals.documentsSaved, 1, "documents stay saved")
    }

    func testUnreadableCardIsAcknowledgedWithNext() {
        var batch = PhoneImportBatch(ImportInbox.Intake(entries: [.unsupported(name: "a.zip", reason: "no"), .unsupported(name: "b.ofx", reason: ImportInboxCopy.ofx)],
                                                   offered: 2, overflow: 0))
        let first = batch.files[0].id
        XCTAssertTrue(batch.acknowledgeUnreadable(first))
        XCTAssertEqual(batch.current, 1)
        XCTAssertEqual(batch.files[0].outcome, .cantRead(reason: "no"))
        XCTAssertEqual(batch.totals.cantRead, 1)
    }

    func testClassificationRoutesStatementsAndDocuments() {
        let check = CheckAndLinkCheck(title: "t", fileName: "f")
        let statement = CheckAndLinkProposal.statement(StatementImportSummary(check: check, currency: .eur))
        let bill = CheckAndLinkProposal.utilityBill(UtilityBillFields(check: check, currency: .eur))
        let other = CheckAndLinkProposal.document(DocumentFields(check: check, kind: .utilityInvoice, kindName: "Receipt"))
        XCTAssertEqual(PhoneImportBatch.kind(of: statement), .statement)
        XCTAssertEqual(PhoneImportBatch.kind(of: bill), .document)
        XCTAssertEqual(PhoneImportBatch.kind(of: other), .document)
        XCTAssertEqual(PhoneImportBatch.kind(of: statement, fileExtension: "csv"), .statement)
        XCTAssertEqual(PhoneImportBatch.kind(of: statement, fileExtension: "jpg"), .cantRead, "a photo of a statement is not a statement")
        XCTAssertEqual(PhoneImportBatch.kind(of: bill, fileExtension: "heic"), .document)
    }

    func testUncategorisedRowsOfTheRuns() throws {
        let manager = try TestDatabase.migratedManager()
        let count = try manager.dbQueue.read { db in try PhoneImportBatch.uncategorisedRows(runIds: [], db: db) }
        XCTAssertEqual(count, 0)
        let none = try manager.dbQueue.read { db in try PhoneImportBatch.uncategorisedRows(runIds: [1, 2], db: db) }
        XCTAssertEqual(none, 0)
    }
}
