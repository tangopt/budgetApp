import XCTest
@testable import MangoUI
import BudgetCore
import GRDB
import TestSupport

/// The iPhone import's flow: files read and sorted, one at a time, the statement states (lease, offline, no access,
/// member, nothing new), documents through Check & link, Undo's scope, release on cancel, and a shared file opening the
/// review after unlock. The engine is a fake (`CheckAndLinkTests` and `PadStatementImportTests` cover the real one).
@MainActor
final class PhoneImportModelTests: XCTestCase {
    private var folder: URL!
    private var manager: DatabaseManager!
    private var inbox: ImportInbox!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("phone-import-tests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        manager = try TestDatabase.migratedManager()
        inbox = ImportInbox(directory: folder.appendingPathComponent("Inbox", isDirectory: true))
        try manager.dbQueue.write { db in
            var a = Person(name: "Person A", shortName: "A")
            try People.save(db: db, &a)
            var b = Person(name: "Person B", shortName: "B")
            try People.save(db: db, &b)
            var admin = AppUser(personId: a.id!, displayName: "A", cloudKitUserRecordName: "_admin", isAdmin: true, createdAt: Self.day(2026, 1, 1))
            try admin.insert(db)
            var member = AppUser(personId: b.id!, displayName: "B", cloudKitUserRecordName: "_member", isAdmin: false, createdAt: Self.day(2026, 1, 1))
            try member.insert(db)
        }
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: folder) }

    private static func day(_ y: Int, _ m: Int, _ d: Int) -> Date {
        MonthRange.calendar.date(from: DateComponents(year: y, month: m, day: d))!
    }

    // MARK: Fakes

    private final class FakeEngine: CheckAndLinking, @unchecked Sendable {
        var proposals: [String: CheckAndLinkProposal]
        var imports: [String] = []
        var saves: [String] = []
        var discards = 0
        var nextRun: Int64 = 100
        init(_ proposals: [String: CheckAndLinkProposal]) { self.proposals = proposals }

        func propose(_ item: TrayItem, in tray: DownloadsTray, propertyId: Int64?) async throws -> CheckAndLinkProposal {
            guard let proposal = proposals[item.fileName] else { throw CheckAndLinkRefusal.notInTray }
            return proposal
        }
        func choosePayment(_ transactionId: Int64?, in proposal: CheckAndLinkProposal) async throws -> CheckAndLinkProposal { proposal }
        func chooseKind(_ choice: ImportKindChoice, in proposal: CheckAndLinkProposal) async throws -> CheckAndLinkProposal { proposal }
        func save(_ proposal: CheckAndLinkProposal, item: TrayItem, tray: DownloadsTray, writer: DeviceWriter, now: Date) async throws -> CheckAndLinkResult {
            saves.append(item.fileName)
            if case .statement = proposal { return CheckAndLinkResult(documentId: nil, sentToMac: true, summary: CheckAndLinkCopy.sentToMac) }
            return CheckAndLinkResult(documentId: 5, summary: "Saved")
        }
        func discard(_ item: TrayItem?) { discards += 1 }
        func importStatement(_ proposal: CheckAndLinkProposal, item: TrayItem, tray: DownloadsTray, writer: DeviceWriter,
                             importer: PadStatementImport, now: Date) async throws -> CheckAndLinkResult {
            imports.append(item.fileName)
            nextRun += 1
            return CheckAndLinkResult(documentId: nil, importRunId: nextRun, summary: "Imported")
        }
    }

    private struct FakeLeases: ImportLeasing {
        var holder: ImportLeaseRecord?
        var offline = false
        var leaseDevice: SyncDevice { SyncDevice(id: "phone", name: "Phone") }
        func importZones() async -> [String]? { nil }
        func importLeaseHolder() async throws -> ImportLeaseRecord? {
            if offline { throw LeaseStoreError.unavailable("offline") }
            return holder
        }
        func acquireImportLease() async throws {}
        func releaseImportLease() async throws {}
        func catchUp() async throws {}
    }

    private func statement(_ title: String, rows: Int = 14, skipped: Int = 3, accountId: Int64? = 1, name: String? = "Current account") -> CheckAndLinkProposal {
        .statement(StatementImportSummary(
            check: CheckAndLinkCheck(title: title, fileName: title), accountId: accountId,
            accountName: name.map { CheckedValue(value: $0, origin: .known) }, currency: .eur,
            openingBalance: CheckedValue(value: 100_000, origin: .read), closingBalance: CheckedValue(value: 90_000, origin: .read),
            rowsToAdd: rows, alreadyImported: skipped))
    }

    private func bill(_ title: String) -> CheckAndLinkProposal {
        .utilityBill(UtilityBillFields(check: CheckAndLinkCheck(title: title, fileName: title), currency: .eur,
                                       amount: CheckedValue(value: 10_000, origin: .read)))
    }

    private func write(_ name: String, _ text: String = "x,y\n1,2\n") throws -> URL {
        let url = folder.appendingPathComponent("picked", isDirectory: true).appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        return url
    }

    private func model(_ engine: FakeEngine, leases: FakeLeases = FakeLeases(), as recordName: String = "_admin",
                       preset: PhoneImportModel.Preset = .init(), statements: Bool = true) -> PhoneImportModel {
        let writer = DeviceWriter(db: manager.dbQueue, viewer: { .iCloudUser(recordName: recordName) }, afterWrite: {})
        let library = EvidenceLibrary(root: folder.appendingPathComponent("Library", isDirectory: true), database: manager.dbQueue)
        let importer = statements ? PadStatementImport(dbQueue: manager.dbQueue, library: library, leases: leases) : nil
        let source = PhoneImportSource(inbox: inbox, engine: engine, writer: writer, statements: importer,
                                       accounts: { [PhoneImportAccount(id: 1, name: "Current account"), PhoneImportAccount(id: 2, name: "Savings")] },
                                       uncategorised: { _ in 4 })
        return PhoneImportModel(source: source, preset: preset)
    }

    // MARK: Tests

    func testFilesAreSortedAndReviewedInTheOrderChosen() async throws {
        let engine = FakeEngine(["a.csv": statement("a.csv"), "b.csv": bill("b.csv"), "c.csv": statement("c.csv", rows: 5, skipped: 0)])
        let model = model(engine)
        await model.start(urls: [try write("a.csv", "1\n"), try write("b.csv", "2\n"), try write("c.csv", "3\n"), try write("d.docx", "x")])
        XCTAssertEqual(model.stage, .reviewing)
        XCTAssertEqual(model.batch.files.map(\.name), ["a.csv", "b.csv", "c.csv", "d.docx"])
        XCTAssertEqual(model.batch.files.map(\.kind), [.statement, .document, .statement, .cantRead])
        XCTAssertEqual(model.currentFile?.name, "a.csv")
        XCTAssertEqual(model.batch.positionLabel, "File 1 of 4")
        XCTAssertEqual(model.statementCard, .importReady(rows: 14))

        await model.importStatement()
        XCTAssertEqual(engine.imports, ["a.csv"])
        XCTAssertEqual(model.currentFile?.name, "b.csv", "after a file, the next one")
        XCTAssertNil(model.statement)
        XCTAssertTrue(model.canSaveDocument)
        await model.saveDocument()
        XCTAssertEqual(engine.saves, ["b.csv"])
        await model.importStatement()
        XCTAssertEqual(model.currentFile?.name, "d.docx")
        XCTAssertEqual(model.currentFile?.kind, .cantRead)
        await model.nextFile()
        XCTAssertEqual(model.stage, .done)
        XCTAssertEqual(model.uncategorised, 4)
        let totals = model.batch.totals
        XCTAssertEqual(totals.newRows, 19)
        XCTAssertEqual(totals.alreadyInMango, 3)
        XCTAssertEqual(totals.documentsSaved, 1)
        XCTAssertEqual(totals.cantRead, 1)
    }

    func testAPhotoOfAStatementIsNotAStatement() async throws {
        let engine = FakeEngine(["scan.jpg": statement("scan.jpg")])
        let model = model(engine)
        await model.start(urls: [try write("scan.jpg", "jpeg bytes")])
        XCTAssertEqual(model.batch.files.first?.kind, .cantRead)
        XCTAssertEqual(model.batch.files.first?.problem, ImportInboxCopy.photoStatement)
    }

    func testDocumentsOnlyTurnsAStatementIntoACard() async throws {
        let engine = FakeEngine(["a.csv": statement("a.csv")])
        let model = model(engine, preset: .init(documentsOnly: true, linkTitle: "Electricity, October"))
        await model.start(urls: [try write("a.csv")])
        XCTAssertEqual(model.batch.files.first?.kind, .cantRead)
        XCTAssertEqual(model.batch.files.first?.problem, PhoneImportCopy.statementsAreImportedFromAccounts)
    }

    func testNothingNewMeansNoImportButDoneWithThisFile() async throws {
        let engine = FakeEngine(["a.csv": statement("a.csv", rows: 0, skipped: 17)])
        let model = model(engine)
        await model.start(urls: [try write("a.csv")])
        XCTAssertEqual(model.statementCard, .allAlreadyIn(rows: 17))
        XCTAssertFalse(model.canImportStatement, "no Import button for 0 new rows")
        await model.importStatement()
        XCTAssertEqual(engine.imports, [])
        await model.doneWithFile()
        XCTAssertEqual(model.stage, .done)
        XCTAssertEqual(model.batch.totals.alreadyInMango, 17)
        XCTAssertEqual(model.batch.undoRunIds, [])
        XCTAssertEqual(PhoneImportBatchCopy.allAlreadyIn(17), "All 17 rows are already in Mango")
    }

    func testLeaseHeldOfflineAndNoAccessStates() async throws {
        let engine = FakeEngine(["a.csv": statement("a.csv")])
        let held = ImportLeaseRecord(holderId: "mac", holderName: "Mac", takenAt: Self.day(2026, 10, 28), expiresAt: Self.day(2026, 10, 29))
        let heldModel = model(engine, leases: FakeLeases(holder: held))
        await heldModel.start(urls: [try write("a.csv")])
        if case .heldByOther(let message)? = heldModel.statementCard {
            XCTAssertTrue(message.hasPrefix("Mac is importing (started "), message)
        } else { XCTFail("held: \(String(describing: heldModel.statementCard))") }
        XCTAssertFalse(heldModel.canImportStatement)
        await heldModel.importStatement()
        XCTAssertEqual(engine.imports, [], "the file stays in the batch, nothing is imported")
        XCTAssertEqual(heldModel.batch.current, 0)

        let offline = model(engine, leases: FakeLeases(offline: true))
        await offline.start(urls: [try write("a.csv")])
        XCTAssertEqual(offline.statementCard, .offline(message: "Connect to the internet to import"))
        XCTAssertFalse(offline.canImportStatement)

        let noStatements = model(engine, statements: false)
        await noStatements.start(urls: [try write("a.csv")])
        XCTAssertEqual(noStatements.statementCard, .sendToMac)
    }

    func testAMemberGetsNoImportButTheNoteWhileMembersImportIsOff() async throws {
        XCTAssertFalse(PadStatementImport.membersImport)
        let engine = FakeEngine(["a.csv": statement("a.csv"), "b.pdf": bill("b.pdf")])
        let member = model(engine, as: "_member")
        await member.start(urls: [try write("a.csv"), try write("b.pdf", "%PDF-1.4 x")])
        XCTAssertEqual(member.statementCard, .ownerImports)
        XCTAssertFalse(member.canImportStatement)
        XCTAssertFalse(member.canSendToMac)
        let writer = DeviceWriter(db: manager.dbQueue, viewer: { .iCloudUser(recordName: "_member") }, afterWrite: {})
        let source = PhoneImportSource(inbox: inbox, engine: engine, writer: writer)
        let offered = await source.offersStatementImport()
        XCTAssertFalse(offered, "no Import button on Accounts for her")
        let adminWriter = DeviceWriter(db: manager.dbQueue, viewer: { .iCloudUser(recordName: "_admin") }, afterWrite: {})
        let adminOffered = await PhoneImportSource(inbox: inbox, engine: engine, writer: adminWriter).offersStatementImport()
        XCTAssertTrue(adminOffered)
        // Documents still check and save for her.
        await member.skipCurrent()
        XCTAssertTrue(member.canSaveDocument)
    }

    func testUndoCoversOnlyThisBatchsStatementRows() async throws {
        let engine = FakeEngine(["a.csv": statement("a.csv"), "b.pdf": bill("b.pdf")])
        let model = model(engine)
        await model.start(urls: [try write("a.csv"), try write("b.pdf", "%PDF-1.4 x")])
        await model.importStatement()
        await model.saveDocument()
        XCTAssertEqual(model.stage, .done)
        XCTAssertEqual(model.batch.undoRunIds, [101], "the one statement's run; the document is not in it")
        XCTAssertEqual(PhoneImportBatchCopy.undoNote(rows: 14), "Undo removes the 14 rows. Linked documents stay saved.")
    }

    func testStatementOfAnotherAccountThanTheOneStartedFromAsksFirst() async throws {
        let engine = FakeEngine(["a.csv": statement("a.csv", accountId: 2, name: "Savings")])
        let model = model(engine, preset: .init(accountId: 1, accountName: "Current account"))
        await model.start(urls: [try write("a.csv")])
        XCTAssertEqual(model.statementCard, .confirmAccount(detected: "Savings", preset: "Current account"))
        XCTAssertFalse(model.canImportStatement)
        model.confirmDetectedAccount()
        XCTAssertEqual(model.statementCard, .importReady(rows: 14))
    }

    func testUnmatchedAccountAsksForOne() async throws {
        let engine = FakeEngine(["a.csv": statement("a.csv", accountId: nil, name: nil)])
        let model = model(engine)
        await model.start(urls: [try write("a.csv")])
        XCTAssertEqual(model.statementCard, .needsAccount)
        XCTAssertEqual(model.accountChoices.map(\.name), ["Current account", "Savings"])
        XCTAssertFalse(model.canImportStatement)
    }

    func testCancelReleasesTheInboxCopies() async throws {
        let engine = FakeEngine(["a.csv": statement("a.csv"), "b.csv": statement("b.csv")])
        let model = model(engine)
        await model.start(urls: [try write("a.csv"), try write("b.csv", "other\n")])
        XCTAssertEqual(inbox.tray.items().count, 2)
        model.close()
        XCTAssertEqual(inbox.tray.items(), [])
    }

    func testASharedFileWaitsForUnlockThenOpensTheReview() async throws {
        let engine = FakeEngine(["shared.pdf": bill("shared.pdf")])
        let writer = DeviceWriter(db: manager.dbQueue, viewer: { .iCloudUser(recordName: "_admin") }, afterWrite: {})
        let coordinator = PhoneImportCoordinator(source: PhoneImportSource(inbox: inbox, engine: engine, writer: writer))
        let incoming = try write("shared.pdf", "%PDF-1.4 shared")
        coordinator.receiveShared(incoming)
        XCTAssertNil(coordinator.session, "locked: it waits behind the lock screen")
        XCTAssertEqual(coordinator.queuedURLs, [incoming.standardizedFileURL])
        coordinator.setLocked(false)
        let session = try XCTUnwrap(coordinator.session)
        XCTAssertNil(session.preset.accountId, "no preset account or link")
        // The review reads the file.
        for _ in 0..<200 where session.stage != .reviewing { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(session.stage, .reviewing)
        XCTAssertEqual(session.currentFile?.name, "shared.pdf")
        XCTAssertFalse(FileManager.default.fileExists(atPath: incoming.path), "the incoming copy is deleted once Mango has its own")
        // Locking closes it and releases the copy.
        coordinator.setLocked(true)
        XCTAssertNil(coordinator.session)
        XCTAssertEqual(inbox.tray.items(), [])
    }

    func testASharedFileWithNowhereToGoIsSaidSo() async throws {
        let coordinator = PhoneImportCoordinator(source: nil)
        let incoming = try write("shared.pdf", "%PDF-1.4 shared")
        coordinator.receiveShared(incoming)
        XCTAssertEqual(coordinator.notice, PhoneImportCopy.notAvailableHere)
        XCTAssertFalse(FileManager.default.fileExists(atPath: incoming.path))
        XCTAssertFalse(coordinator.isAvailable)
    }
}
