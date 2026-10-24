import XCTest
import GRDB
@testable import BudgetCore

/// Plan "Import documents 4" Task 3: a source folder's new and changed files go into the
/// importer's review carrying their folder metadata; on Confirm import the scan records get the
/// document and the changes are acknowledged (duplicates and left-out files too). Synthetic
/// files in temporary folders: Property A with tenancy contract 1001 (receipt 1 of €600.00),
/// Bank A with a €120.00 debit on 10/03/2024.
final class SourceFolderImportTests: XCTestCase {
    private var manager: DatabaseManager!
    private var db: DatabaseQueue { manager.dbQueue }
    private var base: URL!
    private var folderURL: URL!
    private var library: EvidenceLibrary!
    private var scanner: SourceFolderScanner!
    private var pipeline: ImportPipeline!
    private var applier: ImportApplier!

    private static func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        MonthRange.calendar.date(from: DateComponents(year: y, month: m, day: d))!
    }

    override func setUpWithError() throws {
        manager = try DatabaseManager(path: nil)
        try manager.migrate()
        try seed()
        base = FileManager.default.temporaryDirectory.appendingPathComponent("SourceFolderImportTests-\(UUID().uuidString)", isDirectory: true)
        folderURL = base.appendingPathComponent("Papers", isDirectory: true)
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        library = EvidenceLibrary(root: base.appendingPathComponent("Library", isDirectory: true), database: db)
        scanner = SourceFolderScanner(library: library)
        pipeline = ImportPipeline(dbQueue: db, library: library, categorizationService: CategorizationService(categorizer: FakeCategorizer()))
        applier = ImportApplier(dbQueue: db, databasePath: nil, library: library)
    }

    override func tearDownWithError() throws {
        pipeline.discardPlanningCopy()
        try? FileManager.default.removeItem(at: base)
    }

    private func seed() throws {
        try db.write { db in
            var property = Property(name: "Property A", country: "PT")
            try Properties.save(db: db, &property)
            var tenancy = Tenancy(propertyId: property.id!, referenceLabel: "Room Contract AB", contractNumber: "1001",
                                  tenantName: "TENANT B", startDate: Self.date(2024, 1, 1))
            try Tenancies.save(db: db, &tenancy)
            var receipt = RentReceipt(tenancyId: tenancy.id!, receiptNumber: "1", periodStart: Self.date(2024, 1, 1),
                                      periodEnd: Self.date(2024, 1, 31), receiptDate: Self.date(2024, 1, 3),
                                      amountMinorUnits: 60_000, status: .issued)
            try RentReceipts.save(db: db, &receipt)
            var account = Account(name: "Bank A", currency: .eur, kind: .cash, trackingMode: .imported)
            try account.insert(db)
            var batch = ImportBatch(accountId: account.id!, sourceFileName: "earlier.csv", importedAt: Date())
            try batch.insert(db)
            try Properties.setAccount(db: db, propertyId: property.id!, accountId: account.id!, role: .current)
            var debit = Transaction(importBatchId: batch.id!, accountId: account.id!, date: Self.date(2024, 3, 10), rawDescription: "PAYMENT 77",
                                    amountMinorUnits: -12_000, categoryId: nil, status: .confirmed, categorizedBy: .manual,
                                    fingerprint: "fp-debit")
            try debit.insert(db)
        }
    }

    // MARK: Files

    @discardableResult
    private func write(_ relativePath: String, _ contents: String) throws -> URL {
        let url = folderURL.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
        return url
    }

    /// A text PDF placed at `relativePath` in the folder (replacing what is there).
    @discardableResult
    private func pdf(_ relativePath: String, _ lines: [String]) throws -> URL {
        let made = EvidenceTestPDFs.textPDF(lines, name: (relativePath as NSString).lastPathComponent)
        let url = folderURL.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.moveItem(at: made, to: url)
        try? FileManager.default.removeItem(at: made.deletingLastPathComponent())
        return url
    }

    private static let insuranceLines = ["SEGURO MULTI-RISCO HABITACAO", "Data: 10/03/2024", "TOTAL 120,00 €", "ATCUD:ABCD1234-77"]

    private func receiptLines() -> [String] {
        RentReceiptPDFsTests.lines(receipt: "1", start: "2024-01-01", end: "2024-01-31", amount: "600,00", received: "600,00",
                                   receivedOn: "2024-01-03")
    }

    private func setModified(_ url: URL, _ date: Date) throws {
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }

    private func sourceFile(_ relativePath: String) throws -> SourceFile {
        try XCTUnwrap(try db.read { db in try SourceFile.filter(Column("relativePath") == relativePath).fetchOne(db) })
    }

    /// A synchronous read (async tests would pick GRDB's async overload).
    private func read<T>(_ body: (Database) throws -> T) throws -> T {
        try db.read(body)
    }

    private func registered() throws -> SourceFolder {
        try scanner.register(folderURL)
    }

    /// Scans the folder and plans its new and changed files.
    private func scanAndPlan(_ folder: SourceFolder) async throws -> (SourceFolderScanner.ScanResult, ImportPlan) {
        let current = try XCTUnwrap(try scanner.sourceFolders().first { $0.id == folder.id })
        let result = try scanner.scan(current, options: .init(analyzeNewFiles: false))
        let plan = try await pipeline.plan(folder: current, scanner: scanner, inputs: SourceFolderImport.inputs(from: result))
        return (result, plan)
    }

    // MARK: Inputs

    func testNewAndChangedFilesBecomeInputs() throws {
        let folder = try registered()
        let changed = try write("Bills/a.txt", "first")
        try setModified(changed, Self.date(2024, 1, 1))
        try write("unchanged.txt", "same")
        _ = try scanner.scan(folder, options: .init(analyzeNewFiles: false))

        try write("Bills/a.txt", "second version")
        try setModified(changed, Self.date(2024, 2, 1))
        try write("b.txt", "new")
        try write(".DS_Store", "x")
        let result = try scanner.scan(try XCTUnwrap(scanner.sourceFolders().first), options: .init(analyzeNewFiles: false))

        let inputs = SourceFolderImport.inputs(from: result)
        let folderId = try XCTUnwrap(folder.id)
        XCTAssertEqual(inputs.map(\.relativePath), ["Bills/a.txt", "b.txt", "unchanged.txt"],
                       "unchanged.txt is not in the library, so it is still new")
        XCTAssertEqual(inputs.map(\.isChange), [true, false, false])
        XCTAssertTrue(inputs.allSatisfy { $0.folderId == folderId })
        let first = try XCTUnwrap(inputs.first)
        XCTAssertTrue(SourceFolderScanner.sameInstant(first.modifiedAt, Self.date(2024, 2, 1)))
        XCTAssertEqual(first.url.lastPathComponent, "a.txt")
    }

    func testFilesInTheLibraryAreNotInputs() throws {
        let folder = try registered()
        let url = try write("kept.txt", "kept")
        try library.add(url)
        let result = try scanner.scan(folder, options: .init(analyzeNewFiles: false))
        XCTAssertEqual(result.inLibrary.map(\.relativePath), ["kept.txt"])
        XCTAssertEqual(SourceFolderImport.inputs(from: result), [])
    }

    // MARK: Planning and applying

    func testPlannedFilesCarryTheirFolderMetadata() async throws {
        let folder = try registered()
        try pdf("Insurance/seguro.pdf", Self.insuranceLines)
        let (_, plan) = try await scanAndPlan(folder)
        let item = try XCTUnwrap(plan.items.first)
        XCTAssertEqual(item.file.sourceFolderId, folder.id)
        XCTAssertEqual(item.file.sourceRelativePath, "Insurance/seguro.pdf")
        XCTAssertNotNil(item.file.sourceModifiedAt)
        XCTAssertEqual(item.placement?.metadata.sourceFolderId, folder.id)
        XCTAssertEqual(item.placement?.metadata.sourceRelativePath, "Insurance/seguro.pdf")
        XCTAssertEqual(plan.state.intents[item.id]?.entryPoint, "Source folder ▸ Papers")
    }

    /// A scan started while a review is open joins it: each file keeps its own shortcut's intent.
    func testFolderFilesJoinAnOpenReviewKeepingEachIntent() async throws {
        let folder = try registered()
        try pdf("Insurance/seguro.pdf", Self.insuranceLines)
        let elsewhere = base.appendingPathComponent("Elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        let note = elsewhere.appendingPathComponent("note.txt")
        try Data("a note".utf8).write(to: note)
        let open = try await pipeline.plan([note], intent: ImportShortcut.documents(dropped: true).intent)
        let noteItem = try XCTUnwrap(open.items.first)

        let current = try XCTUnwrap(try scanner.sourceFolders().first { $0.id == folder.id })
        let result = try scanner.scan(current, options: .init(analyzeNewFiles: false))
        let plan = try await pipeline.plan(folder: current, scanner: scanner, inputs: SourceFolderImport.inputs(from: result), to: open)

        XCTAssertEqual(plan.items.filter { $0.parentId == nil }.count, 2)
        XCTAssertEqual(plan.intent(of: noteItem.id).entryPoint, "Documents ▸ Drop")
        let folderItem = try XCTUnwrap(plan.items.first { $0.file.sourceRelativePath == "Insurance/seguro.pdf" })
        XCTAssertEqual(plan.intent(of: folderItem.id).entryPoint, "Source folder ▸ Papers")
        XCTAssertEqual(folderItem.file.sourceFolderId, folder.id)
    }

    func testFiledFileIsRecordedOnItsScanRecord() async throws {
        let folder = try registered()
        try pdf("Insurance/seguro.pdf", Self.insuranceLines)
        let (_, plan) = try await scanAndPlan(folder)
        XCTAssertTrue(plan.canConfirm, "\(plan.items.map(\.needsYouReasons))")
        let summary = try applier.apply(plan, entryPoint: "Source folder ▸ Papers")
        let documentId = try XCTUnwrap(try read { db in
            try ImportRunFile.filter(Column("runId") == summary.runId).fetchOne(db)?.documentId
        })
        XCTAssertEqual(try sourceFile("Insurance/seguro.pdf").documentId, documentId)
        let document = try XCTUnwrap(try read { db in try EvidenceDocument.fetchOne(db, key: documentId) })
        XCTAssertEqual(document.sourceFolderId, folder.id)
        XCTAssertEqual(document.sourceRelativePath, "Insurance/seguro.pdf")
        // The scan state is otherwise unchanged; the next scan sees the file in the library.
        let again = try scanner.scan(try XCTUnwrap(scanner.sourceFolders().first), options: .init(analyzeNewFiles: false))
        XCTAssertEqual(again.inLibrary.map(\.relativePath), ["Insurance/seguro.pdf"])
    }

    /// Changes the insurance receipt's bytes (same ATCUD) and adds rent receipt 1, then plans.
    private func changedDuplicatePlan(_ folder: SourceFolder) async throws -> (firstDocument: Int64, plan: ImportPlan) {
        let url = try pdf("seguro.pdf", Self.insuranceLines)
        try setModified(url, Self.date(2024, 3, 11))
        let (_, first) = try await scanAndPlan(folder)
        let firstRun = try applier.apply(first, entryPoint: "Source folder ▸ Papers")
        let firstDocument = try XCTUnwrap(try read { db in
            try ImportRunFile.filter(Column("runId") == firstRun.runId).fetchOne(db)?.documentId
        })

        let changed = try pdf("seguro.pdf", Self.insuranceLines + ["Segunda via"])
        try setModified(changed, Self.date(2024, 3, 20))
        try pdf("r1.pdf", receiptLines())
        let (result, plan) = try await scanAndPlan(folder)
        XCTAssertEqual(result.changed.map(\.relativePath), ["seguro.pdf"])
        XCTAssertEqual(result.new.map(\.relativePath), ["r1.pdf"])
        XCTAssertEqual(try scanner.pendingChanges(inFolder: try XCTUnwrap(folder.id)).map(\.relativePath), ["seguro.pdf"])
        return (firstDocument, plan)
    }

    func testChangedFileThatIsSameDocumentIsAcknowledged() async throws {
        let folder = try registered()
        let (firstDocument, plan) = try await changedDuplicatePlan(folder)
        let duplicate = try XCTUnwrap(plan.items.first { $0.file.fileName == "seguro.pdf" })
        XCTAssertEqual(duplicate.section, .duplicates)
        XCTAssertEqual(duplicate.duplicate?.level, .document)
        XCTAssertTrue(plan.canConfirm, "\(plan.items.map(\.needsYouReasons))")

        _ = try applier.apply(plan, entryPoint: "Source folder ▸ Papers")
        XCTAssertEqual(try scanner.pendingChanges(inFolder: try XCTUnwrap(folder.id)), [])
        XCTAssertEqual(try sourceFile("seguro.pdf").documentId, firstDocument)
        // The next scan: the file is the document already in the library, not new again.
        let again = try scanner.scan(try XCTUnwrap(scanner.sourceFolders().first), options: .init(analyzeNewFiles: false))
        XCTAssertEqual(again.changed, [])
        XCTAssertEqual(again.new, [])
        XCTAssertEqual(Set(again.inLibrary.map(\.relativePath)), ["r1.pdf", "seguro.pdf"])
    }

    func testLeftOutChangedFileIsAcknowledged() async throws {
        let folder = try registered()
        var (_, plan) = try await changedDuplicatePlan(folder)
        let index = try XCTUnwrap(plan.items.firstIndex { $0.file.fileName == "seguro.pdf" })
        plan.items[index].isLeftOut = true
        _ = try applier.apply(plan, entryPoint: "Source folder ▸ Papers")
        XCTAssertEqual(try scanner.pendingChanges(inFolder: try XCTUnwrap(folder.id)), [])
        XCTAssertNil(try sourceFile("seguro.pdf").documentId, "left out: no document recorded")
    }

    func testUndoRestoresThePendingChange() async throws {
        let folder = try registered()
        let (_, plan) = try await changedDuplicatePlan(folder)
        let before = try sourceFile("seguro.pdf")
        let summary = try applier.apply(plan, entryPoint: "Source folder ▸ Papers")
        _ = try ImportUndo.undo(dbQueue: db, library: library, runId: summary.runId)
        XCTAssertEqual(try scanner.pendingChanges(inFolder: try XCTUnwrap(folder.id)).map(\.relativePath), ["seguro.pdf"])
        XCTAssertEqual(try sourceFile("seguro.pdf"), before)
    }

    func testStaticAcknowledgeChangeClearsThePendingChange() throws {
        let folder = try registered()
        let url = try write("a.txt", "one")
        try setModified(url, Self.date(2024, 1, 1))
        _ = try scanner.scan(folder, options: .init(analyzeNewFiles: false))
        try write("a.txt", "two!")
        try setModified(url, Self.date(2024, 1, 2))
        _ = try scanner.scan(try XCTUnwrap(scanner.sourceFolders().first), options: .init(analyzeNewFiles: false))
        let folderId = try XCTUnwrap(folder.id)
        XCTAssertTrue(try db.write { db in try SourceFolderScanner.acknowledgeChange(db: db, folderId: folderId, relativePath: "a.txt") })
        XCTAssertFalse(try db.write { db in try SourceFolderScanner.acknowledgeChange(db: db, folderId: folderId, relativePath: "a.txt") })
        XCTAssertEqual(try scanner.pendingChanges(inFolder: folderId), [])
    }

    // MARK: Fix round 1

    func testCopiesOfOneDocumentInTheBatchAreBothRecorded() async throws {
        let folder = try registered()
        try pdf("seguro.pdf", Self.insuranceLines)
        try pdf("seguro segunda via.pdf", Self.insuranceLines + ["Segunda via"])
        let (_, plan) = try await scanAndPlan(folder)
        let copy = try XCTUnwrap(plan.items.first { $0.duplicate != nil }, "\(plan.items.map(\.needsYouReasons))")
        XCTAssertEqual(copy.duplicate?.level, .document)
        XCTAssertNil(copy.duplicate?.existingDocumentId)
        XCTAssertNotNil(copy.duplicate?.originalItemId)
        XCTAssertTrue(plan.canConfirm, "\(plan.items.map(\.needsYouReasons))")
        let summary = try applier.apply(plan, entryPoint: "Source folder ▸ Papers")
        let filed = try XCTUnwrap(try read { db in
            try ImportRunFile.filter(Column("runId") == summary.runId && Column("outcome") != ImportFileOutcome.duplicate.rawValue).fetchOne(db)?.documentId
        })
        XCTAssertEqual(try sourceFile("seguro.pdf").documentId, filed)
        XCTAssertEqual(try sourceFile("seguro segunda via.pdf").documentId, filed)
        let again = try scanner.scan(try XCTUnwrap(scanner.sourceFolders().first), options: .init(analyzeNewFiles: false))
        XCTAssertEqual(again.new, [])
        XCTAssertEqual(again.inLibrary.count, 2)
    }

    func testFileGoneSinceTheScanIsAnUnreadableItem() async throws {
        let folder = try registered()
        let url = try pdf("seguro.pdf", Self.insuranceLines)
        try pdf("r1.pdf", receiptLines())
        let result = try scanner.scan(folder, options: .init(analyzeNewFiles: false))
        try FileManager.default.removeItem(at: url)
        let plan = try await pipeline.plan(folder: try XCTUnwrap(scanner.sourceFolders().first), scanner: scanner,
                                           inputs: SourceFolderImport.inputs(from: result))
        XCTAssertEqual(plan.items.count, 2)
        let gone = try XCTUnwrap(plan.items.first { $0.file.fileName == "seguro.pdf" })
        XCTAssertTrue(ImportResolutions.isUnreadable(gone))
        XCTAssertEqual(gone.issues.first?.reason, "Gone from the folder since the scan")
        XCTAssertEqual(gone.file.sourceRelativePath, "seguro.pdf")
    }

    func testFileChangedAfterTheReviewIsRefusedAtConfirm() async throws {
        let folder = try registered()
        try pdf("seguro.pdf", Self.insuranceLines)
        let (_, plan) = try await scanAndPlan(folder)
        try pdf("seguro.pdf", Self.insuranceLines + ["Alterado"])
        XCTAssertThrowsError(try applier.apply(plan, entryPoint: "Source folder ▸ Papers")) { error in
            XCTAssertEqual(error as? ImportApplyError, .planOutdated("seguro.pdf changed since it was read"))
        }
        XCTAssertEqual(try read { try EvidenceDocument.fetchCount($0) }, 0)
    }

    func testFileDeletedAfterTheReviewIsRefusedAtConfirm() async throws {
        let folder = try registered()
        let url = try pdf("seguro.pdf", Self.insuranceLines)
        let (_, plan) = try await scanAndPlan(folder)
        try FileManager.default.removeItem(at: url)
        XCTAssertThrowsError(try applier.apply(plan, entryPoint: "Source folder ▸ Papers")) { error in
            guard case .planOutdated(let text)? = error as? ImportApplyError else { return XCTFail("\(error)") }
            XCTAssertTrue(text.hasPrefix("seguro.pdf is no longer where it was read"), text)
        }
    }

    func testFolderUnavailableAtConfirmIsRefused() async throws {
        let folder = try registered()
        try pdf("seguro.pdf", Self.insuranceLines)
        let (_, plan) = try await scanAndPlan(folder)
        try FileManager.default.removeItem(at: folderURL)
        XCTAssertThrowsError(try applier.apply(plan, entryPoint: "Source folder ▸ Papers")) { error in
            guard case .planOutdated(let text)? = error as? ImportApplyError else { return XCTFail("\(error)") }
            XCTAssertTrue(text.hasPrefix("The folder Papers can't be found"), text)
        }
    }

    func testFolderMovedBetweenReviewAndConfirmStillFiles() async throws {
        let folder = try registered()
        try pdf("Insurance/seguro.pdf", Self.insuranceLines)
        let (_, plan) = try await scanAndPlan(folder)
        let moved = base.appendingPathComponent("Papers moved", isDirectory: true)
        try FileManager.default.moveItem(at: folderURL, to: moved)
        let summary = try applier.apply(plan, entryPoint: "Source folder ▸ Papers")
        XCTAssertEqual(summary.filed, 1)
        XCTAssertNotNil(try sourceFile("Insurance/seguro.pdf").documentId)
    }

    func testFileChangedAgainBeforeConfirmIsLeftPending() async throws {
        let folder = try registered()
        let (_, plan) = try await changedDuplicatePlan(folder)
        let again = try pdf("seguro.pdf", Self.insuranceLines + ["Terceira via"])
        try setModified(again, Self.date(2024, 4, 1))
        _ = try scanner.scan(try XCTUnwrap(scanner.sourceFolders().first), options: .init(analyzeNewFiles: false))
        _ = try applier.apply(plan, entryPoint: "Source folder ▸ Papers")
        let folderId = try XCTUnwrap(folder.id)
        XCTAssertEqual(try scanner.pendingChanges(inFolder: folderId).map(\.relativePath), ["seguro.pdf"])
        XCTAssertNil(try sourceFile("seguro.pdf").documentId)
    }

    // MARK: A new version of a filed file (final review, Ruling 4)

    /// The insurance receipt filed and linked to the tenancy, then changed in the folder into
    /// another receipt (another ATCUD, amount and date): planned again.
    private func newVersionPlan(_ folder: SourceFolder) async throws -> (previous: Int64, tenancyId: Int64, plan: ImportPlan) {
        let url = try pdf("seguro.pdf", Self.insuranceLines)
        try setModified(url, Self.date(2024, 3, 11))
        let (_, first) = try await scanAndPlan(folder)
        let firstRun = try applier.apply(first, entryPoint: "Source folder ▸ Papers")
        let previous = try XCTUnwrap(try read { db in try ImportRunFile.filter(Column("runId") == firstRun.runId).fetchOne(db)?.documentId })
        let tenancyId = try XCTUnwrap(try read { db in try Tenancy.fetchOne(db)?.id })
        try await db.write { db in _ = try EvidenceLinks.link(db: db, documentId: previous, to: .tenancy(tenancyId), role: "Insurance") }

        let changed = try pdf("seguro.pdf", ["SEGURO MULTI-RISCO HABITACAO", "Data: 10/04/2025", "TOTAL 135,00 €", "ATCUD:ABCD1234-99"])
        try setModified(changed, Self.date(2025, 4, 11))
        let (result, plan) = try await scanAndPlan(folder)
        XCTAssertEqual(result.changed.map(\.relativePath), ["seguro.pdf"])
        XCTAssertEqual(result.changed.first?.previousDocumentId, previous)
        return (previous, tenancyId, plan)
    }

    func testNewVersionTakesThePreviousVersionsLinks() async throws {
        let folder = try registered()
        let (previous, tenancyId, plan) = try await newVersionPlan(folder)
        let item = try XCTUnwrap(plan.items.first { $0.file.fileName == "seguro.pdf" })
        XCTAssertNil(item.duplicate)
        let previousName = try XCTUnwrap(try read { db in try EvidenceDocument.fetchOne(db, key: previous)?.displayName })
        XCTAssertTrue(item.notes.contains("New version of \(previousName)"), "\(item.notes)")
        let link = try XCTUnwrap(item.links.first { $0.entity == .tenancy(tenancyId) }, "\(item.links)")
        XCTAssertEqual(link.confidence, .certain)
        XCTAssertEqual(link.role, "Insurance")
        XCTAssertTrue(link.reasons.contains(ImportPipeline.previousVersionReason), "\(link.reasons)")
        XCTAssertEqual(link.replacing, [previous])
        XCTAssertTrue(plan.canConfirm, "\(plan.items.map(\.needsYouReasons))")

        let summary = try applier.apply(plan, entryPoint: "Source folder ▸ Papers")
        let newDocument = try XCTUnwrap(try read { db in try ImportRunFile.filter(Column("runId") == summary.runId).fetchOne(db)?.documentId })
        XCTAssertNotEqual(newDocument, previous)
        try read { db in
            XCTAssertTrue(try EvidenceLinks.links(db: db, for: newDocument).contains { $0.entity == .tenancy(tenancyId) && $0.role == "Insurance" })
            XCTAssertFalse(try EvidenceLinks.links(db: db, for: previous).contains { $0.entity == .tenancy(tenancyId) })
            XCTAssertTrue(try EvidenceDocument.exists(db, key: previous), "the previous version stays in the library")
        }

        // Undo: the previous version is linked again, the new one gone.
        _ = try ImportUndo.undo(dbQueue: db, library: library, runId: summary.runId)
        try read { db in
            XCTAssertTrue(try EvidenceLinks.links(db: db, for: previous).contains { $0.entity == .tenancy(tenancyId) && $0.role == "Insurance" })
            XCTAssertFalse(try EvidenceDocument.exists(db, key: newDocument))
        }
        XCTAssertEqual(try scanner.pendingChanges(inFolder: try XCTUnwrap(folder.id)).map(\.relativePath), ["seguro.pdf"])
    }

    func testNewVersionsLinkReplacementIsSimulatedByTheGuard() async throws {
        let folder = try registered()
        let (previous, tenancyId, plan) = try await newVersionPlan(folder)
        let item = try XCTUnwrap(plan.items.first { $0.file.fileName == "seguro.pdf" })
        // What the guard performs is what apply does: the previous version unlinked there.
        try await db.write { db in
            try db.inSavepoint {
                var placeholder = EvidenceDocument(sha256: "placeholder", storedRelativePath: "p", originalFileName: "p", byteCount: 1, addedAt: Date())
                try placeholder.insert(db)
                try ImportEffects.applyRecords(db: db, item: item, documentId: placeholder.id, importRunId: nil)
                XCTAssertFalse(try EvidenceLinks.links(db: db, for: previous).contains { $0.entity == .tenancy(tenancyId) })
                return .rollback
            }
        }
    }

    /// N2: the claim checks see the links a new version takes: its previous version's
    /// transaction already holding another document of its kind is asked about (the previous
    /// version itself never is).
    func testNewVersionsTakenTransactionLinkIsClaimChecked() async throws {
        let folder = try registered()
        let url = try pdf("seguro.pdf", Self.insuranceLines)
        try setModified(url, Self.date(2024, 3, 11))
        let (_, first) = try await scanAndPlan(folder)
        let firstRun = try applier.apply(first, entryPoint: "Source folder ▸ Papers")
        let previous = try XCTUnwrap(try read { db in try ImportRunFile.filter(Column("runId") == firstRun.runId).fetchOne(db)?.documentId })
        let debitId = try XCTUnwrap(try read { db in try Transaction.filter(Column("fingerprint") == "fp-debit").fetchOne(db)?.id })
        let kind = try XCTUnwrap(try read { db in try EvidenceDocument.fetchOne(db, key: previous)?.kind })
        let other = base.appendingPathComponent("other-receipt.txt")
        try Data("Another receipt".utf8).write(to: other)
        let otherDocument = try XCTUnwrap(try library.add(other, metadata: EvidenceMetadata(kind: kind, docDate: Self.date(2025, 4, 10))).document.id)
        try await db.write { db in
            _ = try EvidenceLinks.link(db: db, documentId: previous, to: .transaction(debitId))
            _ = try EvidenceLinks.link(db: db, documentId: otherDocument, to: .transaction(debitId))
        }

        let changed = try pdf("seguro.pdf", ["SEGURO MULTI-RISCO HABITACAO", "Data: 10/04/2025", "TOTAL 135,00 €", "ATCUD:ABCD1234-99"])
        try setModified(changed, Self.date(2025, 4, 11))
        let (_, plan) = try await scanAndPlan(folder)
        let item = try XCTUnwrap(plan.items.first { $0.file.fileName == "seguro.pdf" })
        XCTAssertTrue(item.links.contains { $0.entity == .transaction(debitId) && $0.replacing == [previous] }, "\(item.links)")
        let issue = try XCTUnwrap(item.issues.first { $0.id == "sameKindOnTransaction.\(debitId)" }, "\(item.issues)")
        XCTAssertTrue(issue.reason.contains("other-receipt.txt"), issue.reason)
        XCTAssertEqual(item.section, .needsYou)
    }
}
