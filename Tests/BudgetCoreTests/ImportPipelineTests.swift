import XCTest
import GRDB
@testable import BudgetCore

/// The pipeline: handed-in files → a reviewable plan (load, detect, read, duplicates, filed-year
/// guard), files added later, and the user's resolutions. Nothing is written. Synthetic data only.
final class ImportPipelineTests: XCTestCase {
    private var manager: DatabaseManager!
    private var db: DatabaseQueue { manager.dbQueue }
    private var propertyId: Int64!
    private var library: EvidenceLibrary!
    private var pipeline: ImportPipeline!
    private var folder: URL!
    private var tenancyId: Int64!

    override func setUpWithError() throws {
        manager = try DatabaseManager(path: nil)
        try manager.migrate()
        try db.write { db in
            var property = Property(name: "Property A", country: "PT")
            try Properties.save(db: db, &property)
            propertyId = property.id!
            var tenancy = Tenancy(propertyId: propertyId, referenceLabel: "Room Contract AB", contractNumber: "1001",
                                  tenantName: "TENANT B", startDate: Self.date(2024, 1, 1))
            try Tenancies.save(db: db, &tenancy)
            tenancyId = tenancy.id!
            for (number, month) in [("1", 1), ("2", 2)] {
                var receipt = RentReceipt(tenancyId: tenancy.id!, receiptNumber: number, periodStart: Self.date(2024, month, 1),
                                          periodEnd: Self.date(2024, month, month == 2 ? 29 : 31), receiptDate: Self.date(2024, month, 3),
                                          amountMinorUnits: 60_000, status: .issued)
                try RentReceipts.save(db: db, &receipt)
            }
        }
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("ImportPipelineTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        library = EvidenceLibrary(root: folder.appendingPathComponent("Library", isDirectory: true), database: db)
        pipeline = ImportPipeline(dbQueue: db, library: library, categorizationService: CategorizationService(categorizer: FakeCategorizer()))
    }

    override func tearDownWithError() throws {
        if let enumerator = FileManager.default.enumerator(atPath: folder.path) {
            for case let path as String in enumerator {
                try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: folder.appendingPathComponent(path).path)
            }
        }
        try? FileManager.default.removeItem(at: folder)
    }

    private static func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        MonthRange.calendar.date(from: DateComponents(year: y, month: m, day: d))!
    }

    // MARK: Files

    /// A file in `subfolder` of the test folder (the handed-in folder is `Drop`).
    private func place(_ url: URL, as name: String, in subfolder: String = "Drop") throws -> URL {
        let directory = folder.appendingPathComponent(subfolder, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = directory.appendingPathComponent(name)
        try FileManager.default.copyItem(at: url, to: target)
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        return target
    }

    /// Rent receipt nº 1 of contract 1001, matching the stored receipt.
    private func receiptPDF(_ name: String = "r1.pdf", in subfolder: String = "Drop") throws -> URL {
        let lines = RentReceiptPDFsTests.lines(receipt: "1", start: "2024-01-01", end: "2024-01-31", amount: "600,00", received: "600,00",
                                               receivedOn: "2024-01-03")
        return try place(EvidenceTestPDFs.textPDF(lines, name: name), as: name, in: subfolder)
    }

    /// A text file nothing recognises.
    private func note(_ name: String = "note.txt", in subfolder: String = "Drop") throws -> URL {
        let directory = folder.appendingPathComponent(subfolder, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try Data("Hello there. Synthetic words only, nothing to recognise.".utf8).write(to: url)
        return url
    }

    /// A PDF already in the library, and its copy in the handed-in folder.
    private func copyOfLibraryFile() throws -> URL {
        let original = try place(EvidenceTestPDFs.textPDF(["Synthetic page", "Nothing else"], name: "kept.pdf"), as: "kept.pdf", in: "Elsewhere")
        _ = try library.add(original, metadata: EvidenceMetadata(kind: .other))
        let copy = folder.appendingPathComponent("Drop", isDirectory: true).appendingPathComponent("kept copy.pdf")
        try FileManager.default.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: original, to: copy)
        return copy
    }

    /// A portal receipts export of contract 2002 (no tenancy yet).
    private func export() throws -> URL {
        let rows = [RentReceiptImportTests.ExportRow(contract: "2002", receipt: "1", start: "2025-01-01", end: "2025-01-31"),
                    RentReceiptImportTests.ExportRow(contract: "2002", receipt: "2", start: "2025-02-01", end: "2025-02-28",
                                                     status: "Anulado")]
        let directory = folder.appendingPathComponent("Drop", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("export.xlsx")
        try RentReceiptImportTests.export(rows).write(to: url)
        return url
    }

    private func item(named name: String, in plan: ImportPlan) throws -> ImportItem {
        try XCTUnwrap(plan.items.first { $0.file.fileName == name && $0.parentId == nil }, "no \(name) in \(plan.items.map(\.file.fileName))")
    }

    private func rowCounts() throws -> [String: Int] {
        try db.read { db in
            let tables = try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'")
            var counts: [String: Int] = [:]
            for table in tables { counts[table] = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \"\(table)\"") }
            return counts
        }
    }

    // MARK: Planning

    func testPlanSortsFilesIntoSections() async throws {
        _ = try receiptPDF()
        _ = try note()
        _ = try copyOfLibraryFile()
        let plan = try await pipeline.plan([folder.appendingPathComponent("Drop", isDirectory: true)])
        XCTAssertEqual(plan.items(in: .ready).map(\.file.fileName), ["r1.pdf"])
        XCTAssertEqual(plan.items(in: .needsYou).map(\.file.fileName), ["note.txt"])
        XCTAssertEqual(plan.items(in: .duplicates).map(\.file.fileName), ["kept copy.pdf"])
        XCTAssertEqual(plan.items(in: .duplicates).first?.duplicate?.level, .file)
        XCTAssertFalse(plan.canConfirm)
        XCTAssertEqual(plan.readyGroups.map(\.summary), ["1 rent receipt → linked to its receipt"])
    }

    func testProgressReportsEveryFile() async throws {
        let urls = [try receiptPDF(), try note(), try copyOfLibraryFile()]
        let seen = ProgressLog()
        _ = try await pipeline.plan(urls, progress: { seen.append($0) })
        let reports = seen.all.filter { $0.stage == .reading }
        XCTAssertEqual(reports.map(\.completed), [0, 1, 2, 3])
        XCTAssertTrue(reports.allSatisfy { $0.total == 3 })
        XCTAssertEqual(Set(reports.dropFirst().compactMap(\.currentFile)), ["r1.pdf", "note.txt", "kept copy.pdf"])
    }

    /// A filed 2023/24 for a person owning the property, so the guard checks the receipt.
    private func filedYear() throws {
        try db.write { db in
            var person = Person(name: "Person A", shortName: "A")
            try People.save(db: db, &person)
            _ = try Properties.setOwners(db: db, propertyId: propertyId, [
                PropertyOwner(propertyId: propertyId, personId: person.id!, shareBasisPoints: 10_000)
            ])
            var year = TaxYear(startYear: 2023, personId: person.id!, status: .filed)
            try year.insert(db)
        }
    }

    /// Receipt nº 2's PDF (February 2024).
    private func secondReceiptPDF() throws -> URL {
        let lines = RentReceiptPDFsTests.lines(receipt: "2", start: "2024-02-01", end: "2024-02-29", amount: "600,00", received: "600,00",
                                               receivedOn: "2024-02-03")
        return try place(EvidenceTestPDFs.textPDF(lines, name: "r2.pdf"), as: "r2.pdf", in: "Drop")
    }

    func testProgressGoesThroughThePassesAfterReading() async throws {
        try filedYear()
        let urls = [try receiptPDF(), try note(), try secondReceiptPDF()]
        let seen = ProgressLog()
        _ = try await pipeline.plan(urls, progress: { seen.append($0) })
        let after = seen.all.filter { $0.stage != .reading }
        XCTAssertEqual(after.map(\.stage), [.matching, .duplicates, .filedYears, .filedYears, .filedYears, .filedYears])
        XCTAssertEqual(after.filter { $0.stage == .filedYears }.map { [$0.completed, $0.total] }, [[0, 0], [0, 2], [1, 2], [2, 2]])
        XCTAssertEqual(after.map(\.stageText), ["Matching the documents to your records…", "Checking for duplicates…",
                                                 "Checking filed tax years…", "Checking filed tax years (0 of 2)…",
                                                 "Checking filed tax years (1 of 2)…", "Checking filed tax years (2 of 2)…"])
        // Each report comes no earlier than the one before it.
        XCTAssertTrue(zip(seen.all, seen.all.dropFirst()).allSatisfy { $1.isNotBefore($0) })
        XCTAssertFalse(ImportProgress(completed: 3, total: 3).isNotBefore(ImportProgress(.matching)))
        XCTAssertFalse(ImportProgress(completed: 1, total: 2, stage: .filedYears).isNotBefore(ImportProgress(completed: 2, total: 2, stage: .filedYears)))
    }

    func testCancellationStopsTheFiledYearCheck() async throws {
        try filedYear()
        let urls = [try receiptPDF(), try secondReceiptPDF()]
        let seen = ProgressLog()
        let outer = OuterTaskBox()
        let pipeline = pipeline!
        let task = Task {
            try await pipeline.plan(urls, progress: { report in
                seen.append(report)
                // Cancelled while the guard takes its figures (inside the database access): it
                // stops before the first item.
                if report.stage == .filedYears { outer.cancel() }
            })
        }
        outer.set(task)
        do {
            _ = try await task.value
            XCTFail("planning went on after cancellation")
        } catch is CancellationError {
        }
        XCTAssertEqual(seen.all.filter { $0.stage == .filedYears }.map(\.total), [0])
    }

    func testAddingTheSameFileLaterIsADuplicate() async throws {
        let url = try receiptPDF()
        let first = try await pipeline.plan([url])
        XCTAssertEqual(first.items(in: .ready).count, 1)
        let copy = folder.appendingPathComponent("Later", isDirectory: true).appendingPathComponent("r1 again.pdf")
        try FileManager.default.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: url, to: copy)
        let plan = try await pipeline.plan(adding: [copy], to: first, intent: .none)
        XCTAssertEqual(plan.items.count, 2)
        XCTAssertEqual(plan.items(in: .ready).map(\.file.fileName), ["r1.pdf"])
        XCTAssertEqual(plan.items(in: .duplicates).first?.duplicate,
                       ImportDuplicate(level: .file, of: "Same file as r1.pdf", originalItemId: plan.items(in: .ready).first?.id))
        XCTAssertTrue(plan.canConfirm)
    }

    func testCancellationStopsReading() async throws {
        let urls = try (1...6).map { try note("note \($0).txt") }
        let seen = ProgressLog()
        do {
            _ = try await pipeline.plan(urls, progress: { report in
                seen.append(report)
                // Cancel the planning task itself once the first file is read.
                if report.completed == 1 { withUnsafeCurrentTask { $0?.cancel() } }
            })
            XCTFail("planning went on after cancellation")
        } catch is CancellationError {
        }
        XCTAssertEqual(seen.all.map(\.completed).max(), 1)
    }

    /// The app reads in a detached task under its own reading task: cancelling the outer task
    /// (Cancel, Discard) must reach the planning (`DetachedWork.run` forwards it).
    func testCancellingTheOuterTaskReachesDetachedPlanning() async throws {
        let urls = try (1...12).map { try note("note \($0).txt") }
        let seen = ProgressLog()
        let outer = OuterTaskBox()
        let pipeline = pipeline!
        let task = Task {
            try await DetachedWork.run(priority: .userInitiated) {
                try await pipeline.plan(urls, progress: { report in
                    seen.append(report)
                    if report.completed == 1 { outer.cancel() }
                })
            }
        }
        outer.set(task)
        do {
            _ = try await task.value
            XCTFail("planning went on after the outer task was cancelled")
        } catch is CancellationError {
        }
        XCTAssertLessThan(seen.all.map(\.completed).max() ?? 0, urls.count)
    }

    func testDetachedWorkReturnsTheResult() async throws {
        let value = try await DetachedWork.run { 42 }
        XCTAssertEqual(value, 42)
    }

    func testPlanWritesNothing() async throws {
        let urls = [try export(), try receiptPDF(), try note()]
        let before = try rowCounts()
        let plan = try await pipeline.plan(urls)
        XCTAssertEqual(try rowCounts(), before)
        // The export's preview writes, so it only works in the readers' (rolled back) write pass.
        let export = try item(named: "export.xlsx", in: plan)
        XCTAssertEqual(export.section, .ready, "\(export.needsYouReasons)")
        XCTAssertEqual(export.title, "Receipts export: 1 tenancy, 2 receipts (2 new, 1 cancelled)")
    }

    /// Planning runs on a private copy of the database: the real one is never written, the copy
    /// (a temporary file of its own) is rolled back too, and it is deleted when discarded.
    func testPlanWorksOnAPrivateCopyDeletedWhenDiscarded() async throws {
        let urls = [try export(), try receiptPDF(), try note()]
        let before = try rowCounts()
        _ = try await pipeline.plan(urls)
        XCTAssertEqual(try rowCounts(), before)
        let path = try XCTUnwrap(pipeline.planningCopyPath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        XCTAssertNotEqual(path, db.path)
        let copy = try DatabaseQueue(path: path)
        let copied = try await copy.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM rentReceipt") }
        XCTAssertEqual(copied, before["rentReceipt"], "every pass on the copy is rolled back")
        try copy.close()
        pipeline.discardPlanningCopy()
        XCTAssertNil(pipeline.planningCopyPath)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }

    func testAddingFilesTakesAFreshCopy() async throws {
        let first = try await pipeline.plan([try note()])
        let path = try XCTUnwrap(pipeline.planningCopyPath)
        _ = try await pipeline.plan(adding: [try note("other.txt")], to: first, intent: .none)
        XCTAssertNotEqual(pipeline.planningCopyPath, path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path), "the replaced copy is deleted")
    }

    /// A long planning pass never holds the app's queue: a read on it completes while a slow
    /// reader is mid-plan.
    func testPlanningDoesNotBlockReadsOfTheDatabase() async throws {
        let slow = SlowReader()
        let pipeline = ImportPipeline(dbQueue: db, library: library, categorizationService: CategorizationService(categorizer: FakeCategorizer()),
                                      readers: [slow])
        let url = try note()
        let planning = Task { try await pipeline.plan([url]) }
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                _ = slow.entered.wait(timeout: .now() + 10)
                continuation.resume()
            }
        }
        let read = expectation(description: "a read of the app's database while planning")
        let queue = db
        DispatchQueue.global().async {
            _ = try? queue.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM property") }
            read.fulfill()
        }
        await fulfillment(of: [read], timeout: 2)
        slow.release.signal()
        let plan = try await planning.value
        XCTAssertEqual(plan.items.map(\.file.fileName), ["note.txt"])
    }

    func testStatementIsStagedOutsideAndReadInside() async throws {
        let accountId = try await db.write { db -> Int64 in
            var account = Account(name: "Bank One", currency: .gbp, kind: .cash, trackingMode: .imported)
            try account.insert(db)
            return account.id!
        }
        _ = try ImportProfileStore(dbQueue: db).save(ImportProfile(accountId: accountId, format: .csv, csvDelimiter: ",", csvDateColumnIndex: 0,
                                                                   csvDescriptionColumnIndex: 1, csvAmountColumnIndex: 2, csvDateFormat: "dd/MM/yyyy"))
        let directory = folder.appendingPathComponent("Drop", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("statement.csv")
        try Data("Date,Description,Amount\n01/07/2026,SHOP A,-12.50\n02/07/2026,SHOP B,-3.00\n".utf8).write(to: url)
        let before = try rowCounts()
        let plan = try await pipeline.plan([url], intent: ImportIntent(accountId: accountId))
        XCTAssertEqual(try rowCounts(), before)
        let item = try item(named: "statement.csv", in: plan)
        XCTAssertEqual(item.section, .ready, "\(item.needsYouReasons)")
        XCTAssertEqual(plan.readyGroups.map(\.summary), ["1 statement → 2 transactions"])
    }

    func testIntentMismatchIsNeedsYou() async throws {
        let plan = try await pipeline.plan([try receiptPDF()], intent: ImportIntent(expected: .utilityInvoice))
        let item = try item(named: "r1.pdf", in: plan)
        XCTAssertEqual(item.section, .needsYou)
        XCTAssertEqual(item.issues.map(\.id), ["kindMismatch"])
    }

    // MARK: Resolutions

    func testLeaveOutEnablesConfirm() async throws {
        let plan = try await pipeline.plan([try receiptPDF(), try note()])
        XCTAssertFalse(plan.canConfirm)
        let note = try item(named: "note.txt", in: plan)
        let resolved = try await pipeline.resolve(plan, itemId: note.id, .leaveOut)
        XCTAssertEqual(try item(named: "note.txt", in: resolved).section, .leftOut)
        XCTAssertTrue(resolved.canConfirm)
        // Leaving it out again puts it back.
        let back = try await pipeline.resolve(resolved, itemId: note.id, .leaveOut)
        XCTAssertEqual(try item(named: "note.txt", in: back).section, .needsYou)
        XCTAssertFalse(back.canConfirm)
    }

    func testChooseKindReproposesItem() async throws {
        let plan = try await pipeline.plan([try note()])
        let note = try item(named: "note.txt", in: plan)
        let resolved = try await pipeline.resolve(plan, itemId: note.id, .chooseKind(.insuranceReceipt))
        let item = try item(named: "note.txt", in: resolved)
        XCTAssertEqual(item.id, note.id)
        XCTAssertEqual(item.recognition, ImportRecognition(kind: .evidence(.insuranceReceipt), confidence: .certain, reason: "Chosen by you"))
        XCTAssertEqual(item.section, .ready, "\(item.needsYouReasons)")
        XCTAssertEqual(resolved.readyGroups.map(\.summary), ["1 insurance receipt document → filed"])
    }

    func testResolutionNotOfferedIsRejected() async throws {
        let plan = try await pipeline.plan([try note()])
        let note = try item(named: "note.txt", in: plan)
        do {
            _ = try await pipeline.resolve(plan, itemId: note.id, .acknowledge)
            XCTFail("acknowledged an unknown kind")
        } catch let error as ImportResolutionError {
            XCTAssertEqual(error, .notOffered(.acknowledge))
        }
    }

    func testChooseTargetReproposesItem() async throws {
        let second = try await db.write { db -> Int64 in
            var property = Property(name: "Property B", country: "PT")
            try Properties.save(db: db, &property)
            return property.id!
        }
        let plan = try await pipeline.plan([try export()])
        let export = try item(named: "export.xlsx", in: plan)
        XCTAssertEqual(export.issues.map(\.kind), [.chooseTarget(.property, options: [propertyId, second])])
        XCTAssertEqual(export.effect, .none)
        let resolved = try await pipeline.resolve(plan, itemId: export.id, .chooseTarget(.property, second))
        let item = try item(named: "export.xlsx", in: resolved)
        XCTAssertEqual(item.id, export.id)
        XCTAssertEqual(item.section, .ready, "\(item.needsYouReasons)")
        guard case .rentReceiptsExport(let id, _) = item.effect else { return XCTFail("effect \(item.effect)") }
        XCTAssertEqual(id, second)
        // An option not offered is refused.
        do {
            _ = try await pipeline.resolve(plan, itemId: export.id, .chooseTarget(.property, 999))
            XCTFail("chose a property not offered")
        } catch let error as ImportResolutionError {
            XCTAssertEqual(error, .notOffered(.chooseTarget(.property, 999)))
        }
    }

    func testChildrenFollowTheirParentOut() async throws {
        let file = ImportFile(url: URL(fileURLWithPath: "/nonexistent/s.csv"), fileName: "s.csv", sha256: "s1", byteCount: 1,
                              fileExtension: "csv", text: nil, textStatus: .noText, usedOCR: false)
        let recognition = ImportRecognition(kind: .bankStatementCSV, confidence: .certain, reason: "test")
        let parent = ImportItem(file: file, recognition: recognition, title: "Statement", effect: .none,
                                issues: [ImportIssue(id: "noTransactions", kind: .readerProblem("No transactions"), reason: "No transactions")])
        let child = ImportItem(file: file, recognition: recognition, title: "Rows", effect: .none,
                               duplicate: ImportDuplicate(level: .transactions, of: "2 rows already imported"), parentId: parent.id)
        let out = try await pipeline.resolve(ImportPlan(items: [parent, child]), itemId: parent.id, .leaveOut)
        XCTAssertEqual(out.items.map(\.section), [.leftOut, .leftOut])
        let back = try await pipeline.resolve(out, itemId: parent.id, .leaveOut)
        XCTAssertEqual(back.items.map(\.section), [.needsYou, .duplicates])
    }

    func testAcknowledgedPossibleDuplicateStaysAcknowledged() async throws {
        @Sendable func receipt(_ name: String) -> ImportItem {
            let file = ImportFile(url: URL(fileURLWithPath: "/nonexistent/\(name)"), fileName: name, sha256: name, byteCount: 1,
                                  fileExtension: "pdf", text: nil, textStatus: .noText, usedOCR: false)
            return ImportItem(file: file, recognition: ImportRecognition(kind: .evidence(.insuranceReceipt), confidence: .certain, reason: "test"),
                              title: name, facts: [ImportFact(field: .docDate, value: .date(Self.date(2023, 3, 5)), source: .textLayer, confidence: .certain, reason: "test"),
                                                   ImportFact(field: .amount, value: .money(12000, .eur), source: .textLayer, confidence: .certain, reason: "test")])
        }
        let annotated = try await db.read { try ImportDuplicates.annotate([receipt("a.pdf"), receipt("b.pdf")], db: $0) }
        XCTAssertEqual(annotated[1].needsYouReasons, ["Possibly the same document as a.pdf"])
        let acknowledged = try await pipeline.resolve(ImportPlan(items: annotated), itemId: annotated[1].id, .acknowledge)
        XCTAssertEqual(acknowledged.items.map(\.section), [.ready, .ready])
        // Another resolution re-runs the duplicate pass: the acknowledgement holds.
        let again = try await pipeline.resolve(acknowledged, itemId: annotated[0].id, .leaveOut)
        XCTAssertEqual(again.items.map(\.section), [.leftOut, .ready])
        let back = try await pipeline.resolve(again, itemId: annotated[0].id, .leaveOut)
        XCTAssertEqual(back.items.map(\.section), [.ready, .ready])
        XCTAssertEqual(back.items[1].issues, [])
    }

    // MARK: Item edits

    private func invoiceItem() -> ImportItem {
        let file = ImportFile(url: URL(fileURLWithPath: "/nonexistent/i.pdf"), fileName: "i.pdf", sha256: "i1", byteCount: 1,
                              fileExtension: "pdf", text: nil, textStatus: .noText, usedOCR: false)
        let candidates = [LinkCandidate(entity: .transaction(42), label: "DEMO POWER DD −€50.00", reasons: ["Booked on 2023-03-06"]),
                          LinkCandidate(entity: .transaction(43), label: "DEMO POWER DD −€50.00", reasons: ["Booked on 2023-03-20"])]
        return ImportItem(file: file, recognition: ImportRecognition(kind: .utilityInvoice, confidence: .certain, reason: "test"),
                          title: "Invoice", effect: .utilityInvoice(UtilityInvoice(providerId: 1, issueDate: Self.date(2023, 3, 5), amountMinorUnits: 5000)),
                          issues: [ImportIssue(id: "chooseLink", kind: .chooseLink(candidates), reason: "Which one?", offers: [.fileWithoutLink])])
    }

    func testChooseLinkOnUtilityInvoiceSetsItsTransaction() throws {
        let item = try XCTUnwrap(try ImportResolutions.apply(.chooseLink(.transaction(43)), to: invoiceItem()))
        XCTAssertEqual(item.issues, [])
        XCTAssertEqual(item.links.map(\.entity), [.transaction(43)])
        XCTAssertEqual(item.links.first?.confidence, .certain)
        XCTAssertEqual(item.links.first?.madeByEffect, true)
        guard case .utilityInvoice(let invoice) = item.effect else { return XCTFail("effect \(item.effect)") }
        XCTAssertEqual(invoice.transactionId, 43)
        XCTAssertEqual(item.section, .ready)
        XCTAssertThrowsError(try ImportResolutions.apply(.chooseLink(.transaction(7)), to: invoiceItem()))
    }

    func testChosenLinkToTheReplaceTargetKeepsTheReplacement() async throws {
        // An older document on the property, which the "replace" shortcut's file replaces.
        func stored(_ name: String) throws -> Int64 {
            let url = folder.appendingPathComponent(name)
            try Data("Synthetic \(name)".utf8).write(to: url)
            return try library.add(url, metadata: EvidenceMetadata(kind: .other)).document.id!
        }
        let old = try stored("old.txt")
        _ = try library.link(old, to: .property(propertyId))
        let new = try stored("new.txt")
        XCTAssertNotEqual(old, new)
        let file = ImportFile(url: URL(fileURLWithPath: "/nonexistent/d.pdf"), fileName: "d.pdf", sha256: "d1", byteCount: 1,
                              fileExtension: "pdf", text: nil, textStatus: .noText, usedOCR: false)
        let candidates = [LinkCandidate(entity: .property(propertyId), label: "Property A", reasons: ["x"]),
                          LinkCandidate(entity: .transaction(42), label: "OTHER", reasons: ["x"])]
        let item = ImportItem(file: file, recognition: ImportRecognition(kind: .evidence(.other), confidence: .certain, reason: "test"),
                              title: "Document", effect: .file,
                              issues: [ImportIssue(id: "chooseLink", kind: .chooseLink(candidates), reason: "Which one?")])
        var plan = ImportPlan(items: [item])
        plan.state.intents[item.id] = ImportIntent(target: .init(entity: .property(propertyId), replacing: [old]))
        let resolved = try await pipeline.resolve(plan, itemId: item.id, .chooseLink(.property(propertyId)))
        let link = try XCTUnwrap(resolved.items.first?.links.first)
        XCTAssertEqual(link.entity, .property(propertyId))
        XCTAssertEqual(link.replacing, [old])
        // What the guard simulates and the importer applies.
        let resolvedItem = try XCTUnwrap(resolved.items.first)
        try await db.write { db in
            try ImportEffects.applyRecords(db: db, item: resolvedItem, documentId: new, importRunId: nil)
        }
        let linked = try await db.read { db in try EvidenceLinks.documents(db: db, for: .property(self.propertyId)).compactMap(\.id) }
        XCTAssertEqual(linked, [new])
    }

    func testFileWithoutLinkClearsTheChoice() throws {
        let item = try XCTUnwrap(try ImportResolutions.apply(.fileWithoutLink, to: invoiceItem()))
        XCTAssertEqual(item.issues, [])
        XCTAssertEqual(item.links, [])
        guard case .utilityInvoice(let invoice) = item.effect else { return XCTFail("effect \(item.effect)") }
        XCTAssertNil(invoice.transactionId)
        XCTAssertEqual(item.section, .ready)
    }

    func testConfirmFigureMakesTheFactTheUsers() throws {
        var item = invoiceItem()
        item.issues = [ImportIssue(id: "missingFigure.amount", kind: .missingFigure(.amount), reason: "No amount could be read")]
        let confirmed = try XCTUnwrap(try ImportResolutions.apply(.confirmFigure(.amount, .money(6000, .eur)), to: item))
        XCTAssertEqual(confirmed.issues, [])
        XCTAssertEqual(confirmed.facts.first { $0.field == .amount }?.source, .user)
        XCTAssertEqual(confirmed.facts.first { $0.field == .amount }?.value, .money(6000, .eur))
        guard case .utilityInvoice(let invoice) = confirmed.effect else { return XCTFail("effect \(confirmed.effect)") }
        XCTAssertEqual(invoice.amountMinorUnits, 6000)
        // A value of the wrong type is refused.
        XCTAssertThrowsError(try ImportResolutions.apply(.confirmFigure(.amount, .text("six")), to: item))
    }

    func testFiledYearHoldsOnlyLeaveOut() throws {
        let impact = FiledYearImpact(startYear: 2022, person: "Person A", isPaid: false,
                                     returnChanges: [FiledYearImpact.Line(label: "SA box", before: "£1", after: "£2")],
                                     informationChanges: [], taxDifferenceMinorUnits: 0, causes: [])
        var item = invoiceItem()
        item.issues = [ImportIssue(id: "filed-2022-Person A", kind: .filedYear(impact), reason: "Held", offers: [.leaveOut]),
                       ImportIssue(id: "filed-check", kind: .readerProblem("Couldn't check"), reason: "Couldn't check", offers: [.leaveOut])]
        for resolution in [ImportResolution.acknowledge, .fileWithoutLink, .chooseLink(.transaction(42)), .confirmFigure(.amount, .money(1, .eur))] {
            XCTAssertThrowsError(try ImportResolutions.apply(resolution, to: item), "\(resolution)")
        }
        XCTAssertEqual(try ImportResolutions.apply(.leaveOut, to: item)?.section, .leftOut)
    }

    // MARK: Fix round 1

    func testUnreadableFileCannotBeGivenAKind() async throws {
        let url = try note("locked.txt")
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: url.path)
        let plan = try await pipeline.plan([url])
        let locked = try item(named: "locked.txt", in: plan)
        XCTAssertEqual(locked.section, .needsYou)
        for resolution in [ImportResolution.chooseKind(.insuranceReceipt), .acknowledge, .fileWithoutLink,
                           .confirmFigure(.amount, .money(1, .eur))] {
            do {
                _ = try await pipeline.resolve(plan, itemId: locked.id, resolution)
                XCTFail("\(resolution) taken on an unreadable file")
            } catch let error as ImportResolutionError {
                XCTAssertEqual(error, .notOffered(resolution))
            }
        }
        XCTAssertEqual(try item(named: "locked.txt", in: plan).section, .needsYou)
    }

    func testChosenTenancySettlesAnAmbiguousContract() async throws {
        let other = try await db.write { db -> Int64 in
            var property = Property(name: "Property B", country: "PT")
            try Properties.save(db: db, &property)
            var tenancy = Tenancy(propertyId: property.id!, referenceLabel: "Other", contractNumber: "1001",
                                  tenantName: "TENANT B", startDate: Self.date(2024, 1, 1))
            try Tenancies.save(db: db, &tenancy)
            return tenancy.id!
        }
        let plan = try await pipeline.plan([try receiptPDF()])
        let receipt = try item(named: "r1.pdf", in: plan)
        XCTAssertEqual(receipt.issues.map(\.kind), [.chooseTarget(.tenancy, options: [tenancyId, other])])
        let resolved = try await pipeline.resolve(plan, itemId: receipt.id, .chooseTarget(.tenancy, tenancyId))
        let item = try item(named: "r1.pdf", in: resolved)
        XCTAssertEqual(item.section, .ready, "\(item.needsYouReasons)")
        let receiptId = try await db.read { try RentReceipts.receipt(db: $0, tenancyId: self.tenancyId, receiptNumber: "1")!.id! }
        XCTAssertEqual(item.links.map(\.entity), [.rentReceipt(receiptId)])
    }

    func testChangingTheKindDropsTargetsChosenForTheOldKind() async throws {
        let other = try await db.write { db -> Int64 in
            var property = Property(name: "Property B", country: "PT")
            try Properties.save(db: db, &property)
            var tenancy = Tenancy(propertyId: property.id!, referenceLabel: "Other", contractNumber: "1001",
                                  tenantName: "TENANT B", startDate: Self.date(2024, 1, 1))
            try Tenancies.save(db: db, &tenancy)
            return tenancy.id!
        }
        let plan = try await pipeline.plan([try receiptPDF()], intent: ImportIntent(expected: .utilityInvoice))
        let receipt = try item(named: "r1.pdf", in: plan)
        XCTAssertTrue(receipt.issues.contains { $0.kind == .chooseTarget(.tenancy, options: [tenancyId, other]) }, "\(receipt.issues)")
        let chosen = try await pipeline.resolve(plan, itemId: receipt.id, .chooseTarget(.tenancy, tenancyId))
        XCTAssertEqual(chosen.state.intents[receipt.id]?.target?.entity, .tenancy(tenancyId))
        let changed = try await pipeline.resolve(chosen, itemId: receipt.id, .chooseKind(.insuranceReceipt))
        let item = try item(named: "r1.pdf", in: changed)
        XCTAssertEqual(item.recognition.kind, .evidence(.insuranceReceipt))
        XCTAssertFalse(item.links.contains { $0.entity.type == .tenancy }, "\(item.links)")
        XCTAssertEqual(changed.state.intents[receipt.id], ImportIntent(expected: .utilityInvoice))
    }

    // MARK: Utility invoices without a record

    private func utilityPipeline() -> ImportPipeline {
        var detector = ImportDetector(providers: [])
        detector.recognisers = [{ _ in ImportRecognition(kind: .utilityInvoice, confidence: .certain, reason: "test") }]
        return ImportPipeline(dbQueue: db, library: library, categorizationService: CategorizationService(categorizer: FakeCategorizer()),
                              detector: detector)
    }

    private func provider() async throws -> Int64 {
        try await db.write { db in
            let rules = UtilityInvoiceRules(textMarkers: ["DEMO POWER"], fileNameMarkers: ["LUZ"],
                                            invoiceNumberPatterns: [#"INVOICE NO\.?\s*(FT \d+/\d+)"#],
                                            issueDateLabels: ["ISSUED ON"], periodLabels: ["BILLING PERIOD:"],
                                            amountLabels: ["AMOUNT DUE"], refundLabels: ["AMOUNT TO REFUND"])
            var power = UtilityProvider(propertyId: self.propertyId, name: "Demo Power", kind: .electricity,
                                        bankDescriptionPattern: "DEMO PWR", invoiceRules: rules)
            try Recharges.saveProvider(db: db, &power)
            return power.id!
        }
    }

    private func unnamedInvoice(amount: Bool = true) throws -> URL {
        let lines = ["Customer copy", "Issued on: 5 de março 2023"] + (amount ? ["Amount due 100,00 EUR"] : []) + ["Invoice no. FT 1/23"]
        return try place(EvidenceTestPDFs.textPDF(lines, name: "invoice.pdf"), as: "invoice.pdf")
    }

    func testInvoiceOfUnknownProviderAsksForTheProvider() async throws {
        let providerId = try await provider()
        let pipeline = utilityPipeline()
        let plan = try await pipeline.plan([try unnamedInvoice()])
        let invoice = try item(named: "invoice.pdf", in: plan)
        XCTAssertEqual(invoice.section, .needsYou)
        XCTAssertTrue(invoice.issues.contains { $0.kind == .chooseTarget(.provider, options: [providerId]) }, "\(invoice.issues)")
        XCTAssertTrue(invoice.issues.contains { $0.id == UtilityInvoiceImportReader.documentOnlyIssueId && $0.offers == [.fileWithoutLink] })
        let resolved = try await pipeline.resolve(plan, itemId: invoice.id, .chooseTarget(.provider, providerId))
        let item = try item(named: "invoice.pdf", in: resolved)
        XCTAssertEqual(item.section, .ready, "\(item.needsYouReasons)")
        guard case .utilityInvoice(let record) = item.effect else { return XCTFail("effect \(item.effect)") }
        XCTAssertEqual(record.providerId, providerId)
        XCTAssertEqual(record.amountMinorUnits, 10_000)
    }

    func testInvoiceWithoutRecordCanBeFiledAsDocumentOnly() async throws {
        _ = try await provider()
        let pipeline = utilityPipeline()
        let plan = try await pipeline.plan([try unnamedInvoice()])
        let invoice = try item(named: "invoice.pdf", in: plan)
        let resolved = try await pipeline.resolve(plan, itemId: invoice.id, .fileWithoutLink)
        let item = try item(named: "invoice.pdf", in: resolved)
        XCTAssertEqual(item.section, .ready, "\(item.needsYouReasons)")
        XCTAssertEqual(item.effect, .file)
        XCTAssertTrue(item.notes.contains(UtilityInvoiceImportReader.documentOnlyNote), "\(item.notes)")
    }

    func testConfirmingAMissingAmountAloneLeavesNoRecordNeedsYou() async throws {
        _ = try await provider()
        let pipeline = utilityPipeline()
        let plan = try await pipeline.plan([try unnamedInvoice(amount: false)], intent: ImportIntent(propertyId: propertyId))
        let invoice = try item(named: "invoice.pdf", in: plan)
        XCTAssertTrue(invoice.issues.contains { $0.kind == .missingFigure(.amount) }, "\(invoice.issues)")
        let resolved = try await pipeline.resolve(plan, itemId: invoice.id, .confirmFigure(.amount, .money(10_000, .eur)))
        let item = try item(named: "invoice.pdf", in: resolved)
        XCTAssertEqual(item.section, .needsYou)
        XCTAssertTrue(item.issues.contains { $0.id == UtilityInvoiceImportReader.documentOnlyIssueId })
    }

    // MARK: Batch checks after resolutions

    func testLeftOutOriginalIsNoLongerTheOriginal() async throws {
        let url = try receiptPDF()
        let first = try await pipeline.plan([url])
        let copy = folder.appendingPathComponent("Later", isDirectory: true).appendingPathComponent("r1 again.pdf")
        try FileManager.default.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: url, to: copy)
        let plan = try await pipeline.plan(adding: [copy], to: first, intent: .none)
        let original = try item(named: "r1.pdf", in: plan)
        let out = try await pipeline.resolve(plan, itemId: original.id, .leaveOut)
        XCTAssertEqual(try item(named: "r1 again.pdf", in: out).section, .ready)
        let back = try await pipeline.resolve(out, itemId: original.id, .leaveOut)
        XCTAssertEqual(try item(named: "r1 again.pdf", in: back).section, .duplicates)
    }

    func testChildCannotComeBackWhileItsParentIsOut() async throws {
        let file = ImportFile(url: URL(fileURLWithPath: "/nonexistent/s.csv"), fileName: "s.csv", sha256: "s1", byteCount: 1,
                              fileExtension: "csv", text: nil, textStatus: .noText, usedOCR: false)
        let recognition = ImportRecognition(kind: .bankStatementCSV, confidence: .certain, reason: "test")
        let parent = ImportItem(file: file, recognition: recognition, title: "Statement", effect: .none)
        let child = ImportItem(file: file, recognition: recognition, title: "Rows", effect: .none,
                               duplicate: ImportDuplicate(level: .transactions, of: "2 rows already imported"), parentId: parent.id)
        let out = try await pipeline.resolve(ImportPlan(items: [parent, child]), itemId: parent.id, .leaveOut)
        do {
            _ = try await pipeline.resolve(out, itemId: child.id, .leaveOut)
            XCTFail("child put back while its parent is out")
        } catch let error as ImportResolutionError {
            XCTAssertEqual(error, .notOffered(.leaveOut))
        }
    }

    func testAcknowledgedMismatchSurvivesARead() async throws {
        let second = try await db.write { db -> Int64 in
            var property = Property(name: "Property B", country: "PT")
            try Properties.save(db: db, &property)
            return property.id!
        }
        let plan = try await pipeline.plan([try export()], intent: ImportIntent(expected: .utilityInvoice))
        let export = try item(named: "export.xlsx", in: plan)
        XCTAssertTrue(export.issues.contains { $0.id == "kindMismatch" })
        let acknowledged = try await pipeline.resolve(plan, itemId: export.id, issueId: "kindMismatch", .acknowledge)
        let resolved = try await pipeline.resolve(acknowledged, itemId: export.id, .chooseTarget(.property, second))
        let item = try item(named: "export.xlsx", in: resolved)
        XCTAssertEqual(item.section, .ready, "\(item.needsYouReasons)")
    }

    func testPossibleDuplicateIsSettledPerDocument() async throws {
        @Sendable func receipt(_ name: String) -> ImportItem {
            let file = ImportFile(url: URL(fileURLWithPath: "/nonexistent/\(name)"), fileName: name, sha256: name, byteCount: 1,
                                  fileExtension: "pdf", text: nil, textStatus: .noText, usedOCR: false)
            return ImportItem(file: file, recognition: ImportRecognition(kind: .evidence(.insuranceReceipt), confidence: .certain, reason: "test"),
                              title: name, facts: [ImportFact(field: .docDate, value: .date(Self.date(2023, 3, 5)), source: .textLayer, confidence: .certain, reason: "test"),
                                                   ImportFact(field: .amount, value: .money(12000, .eur), source: .textLayer, confidence: .certain, reason: "test")])
        }
        let annotated = try await db.read { try ImportDuplicates.annotate([receipt("a.pdf"), receipt("b.pdf")], db: $0) }
        let acknowledged = try await pipeline.resolve(ImportPlan(items: annotated), itemId: annotated[1].id, .acknowledge)
        // Another document of the same date and amount appears (the review sees it when files are
        // next added: planning works on a copy taken then): the user hasn't settled that one.
        try await db.write { db in
            var document = EvidenceDocument(sha256: "l1", storedRelativePath: "l1/l1.pdf", originalFileName: "Insurance March.pdf", byteCount: 1,
                                            canonicalName: "Insurance March", kind: .insuranceReceipt, docDate: Self.date(2023, 3, 5),
                                            amountMinorUnits: 12000, currency: .eur, textStatus: .noText, addedAt: Date())
            try document.insert(db)
        }
        let refreshed = try await pipeline.plan(adding: [], to: acknowledged, intent: .none)
        let again = try await pipeline.resolve(refreshed, itemId: annotated[0].id, .leaveOut)
        XCTAssertEqual(again.items[1].needsYouReasons, ["Possibly the same document as Insurance March"])
    }

    func testReadyGroupCopyForExportsAndAdvices() {
        let file = ImportFile(url: URL(fileURLWithPath: "/nonexistent/x"), fileName: "x", sha256: "x", byteCount: 1,
                              fileExtension: "pdf", text: nil, textStatus: .noText, usedOCR: false)
        func row(_ number: String, _ status: RentReceiptStatus) -> RentReceiptsExport.Row {
            RentReceiptsExport.Row(rowNumber: 1, reference: nil, contractNumber: "2002", receiptNumber: number, tenant: nil,
                                   periodStart: Self.date(2025, 1, 1), periodEnd: Self.date(2025, 1, 31), receiptDate: nil,
                                   amountMinorUnits: 100, status: status)
        }
        let export = ImportItem(file: file, recognition: ImportRecognition(kind: .rentReceiptsExport, confidence: .certain, reason: "test"),
                                title: "Export", effect: .rentReceiptsExport(propertyId: 1, rows: [row("1", .issued), row("2", .cancelled)]),
                                groupKey: "Rent receipts export")
        XCTAssertEqual(ImportPlan(items: [export]).readyGroups.map(\.summary), ["1 receipts export → 2 receipts, 1 cancelled"])
        func advice() -> ImportItem {
            ImportItem(file: file, recognition: ImportRecognition(kind: .transferAdvice, confidence: .certain, reason: "test"),
                       title: "Advice", groupKey: "Transfer advices")
        }
        XCTAssertEqual(ImportPlan(items: [advice()]).readyGroups.map(\.summary), ["1 transfer advice → linked to its credit"])
        XCTAssertEqual(ImportPlan(items: [advice(), advice()]).readyGroups.map(\.summary), ["2 transfer advices → linked to their credits"])
    }
}

/// A reader that waits, mid-plan, until the test lets it go.
private final class SlowReader: ImportReader, @unchecked Sendable {
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)

    func handles(_ kind: ImportKind) -> Bool { true }

    func propose(_ files: [(file: ImportFile, recognition: ImportRecognition)], context: ImportContext, db: Database) throws -> [ImportItem] {
        entered.signal()
        _ = release.wait(timeout: .now() + 10)
        return files.map { ImportItem(file: $0.file, recognition: $0.recognition, title: $0.file.fileName) }
    }
}

/// Progress reports collected across threads.
/// The outer task, cancelled from the progress callback (set right after it starts; a
/// cancel asked for before then is applied when it is set).
private final class OuterTaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<ImportPlan, Error>?
    private var cancelled = false

    func set(_ task: Task<ImportPlan, Error>) {
        lock.lock(); defer { lock.unlock() }
        self.task = task
        if cancelled { task.cancel() }
    }

    func cancel() {
        lock.lock(); defer { lock.unlock() }
        cancelled = true
        task?.cancel()
    }
}

private final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var reports: [ImportProgress] = []

    func append(_ report: ImportProgress) {
        lock.lock(); defer { lock.unlock() }
        reports.append(report)
    }

    var all: [ImportProgress] {
        lock.lock(); defer { lock.unlock() }
        return reports
    }
}
