import XCTest
import GRDB
@testable import BudgetCore

/// "Check it" ticked off in place and taken back: a figure or recognition to check becomes the
/// user's ("Checked by you", certain) without retyping; the undo puts back exactly what was
/// there; a model field checked is accepted field by field (its kind and issuer name learnt);
/// a held item takes neither. Synthetic data only (NIF 503504564 is made up); the model is a stub.
final class ImportChecksTests: XCTestCase {
    private var manager: DatabaseManager!
    private var db: DatabaseQueue { manager.dbQueue }
    private var folder: URL!
    private var library: EvidenceLibrary!
    private var pipelines: [ImportPipeline] = []

    override func setUpWithError() throws {
        manager = try DatabaseManager(path: nil)
        try manager.migrate()
        try db.write { db in
            try CategorySeeder.seedDefaults(db)
            var person = Person(name: "Person A", shortName: "A")
            try person.insert(db)
        }
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("ImportChecksTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        library = EvidenceLibrary(root: folder.appendingPathComponent("Library", isDirectory: true), database: db)
    }

    override func tearDownWithError() throws {
        pipelines.forEach { $0.discardPlanningCopy() }
        try? FileManager.default.removeItem(at: folder)
    }

    private func pipeline(readers: [any ImportReader]? = nil, model: (any DocumentModelReading)? = nil) -> ImportPipeline {
        let made = ImportPipeline(dbQueue: db, library: library, categorizationService: CategorizationService(categorizer: FakeCategorizer()),
                                  readers: readers, modelReader: model)
        pipelines.append(made)
        return made
    }

    private func letter(_ name: String = "letter.pdf") throws -> URL {
        let made = EvidenceTestPDFs.textPDF(["Example Seguros, S.A. NIF 503504564", "Rua Exemplo 1, Lisboa",
                                             "Caro senhor, segue a informacao pedida."], name: name)
        let directory = folder.appendingPathComponent("Drop-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try FileManager.default.moveItem(at: made, to: url)
        return url
    }

    private func only(_ plan: ImportPlan) throws -> ImportItem {
        let top = plan.items.filter { $0.parentId == nil }
        XCTAssertEqual(top.count, 1)
        return try XCTUnwrap(top.first)
    }

    private static func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar.date(from: DateComponents(year: y, month: m, day: d))!
    }

    /// Reads any unrecognised file as an insurance receipt to check, its amount read by text
    /// recognition (with the question it raises) and its date from the file name.
    private struct ScannedReceiptReader: ImportReader {
        func handles(_ kind: ImportKind) -> Bool { kind == .unknown || kind == .evidence(.other) }

        func propose(_ files: [(file: ImportFile, recognition: ImportRecognition)], context: ImportContext, db: Database) throws -> [ImportItem] {
            files.map { file in
                ImportItem(file: file.file,
                           recognition: ImportRecognition(kind: .evidence(.insuranceReceipt), confidence: .needsReview, reason: "Looks like an insurance receipt"),
                           title: "Insurance receipt",
                           facts: [ImportFact(field: .amount, value: .money(4210, .eur), source: .ocr, confidence: .needsReview, reason: "Read by text recognition"),
                                   ImportFact(field: .docDate, value: .date(ImportChecksTests.date(2025, 3, 5)), source: .fileName,
                                              confidence: .needsReview, reason: "From the file name")],
                           placement: ImportPlacement(metadata: EvidenceMetadata(kind: .insuranceReceipt), canonicalName: "receipt.pdf"),
                           issues: [ImportIssue(id: "confirmFigure.amount", kind: .confirmFigure(.amount), reason: "Amount read by text recognition: check it")],
                           groupKey: "Other documents")
            }
        }
    }

    // MARK: Ticking off

    func testMarkingMakesItCertainAndTheItemCanLeaveNeedsYou() async throws {
        let pipeline = pipeline(readers: [ScannedReceiptReader()])
        var plan = try await pipeline.plan([try letter()])
        let id = try only(plan).id
        XCTAssertEqual(try only(plan).section, .needsYou)
        plan = try await pipeline.resolve(plan, itemId: id, .markChecked(.figure(.amount)))
        var item = try only(plan)
        let amount = try XCTUnwrap(item.facts.first { $0.field == .amount })
        XCTAssertEqual(amount.value, .money(4210, .eur), "the value stays")
        XCTAssertEqual(amount.source, .user)
        XCTAssertEqual(amount.confidence, .certain)
        XCTAssertEqual(amount.reason, "Checked by you")
        XCTAssertFalse(item.issues.contains { $0.kind == .confirmFigure(.amount) }, "its question is answered")
        XCTAssertTrue(plan.isMarkedChecked(id, .figure(.amount)))

        plan = try await pipeline.resolve(plan, itemId: id, .markChecked(.figure(.docDate)))
        plan = try await pipeline.resolve(plan, itemId: id, .markChecked(.recognition))
        item = try only(plan)
        XCTAssertEqual(item.recognition.confidence, .certain)
        XCTAssertEqual(item.recognition.reason, "Checked by you")
        XCTAssertEqual(item.section, .ready, "\(item.needsYouReasons)")
        XCTAssertTrue(item.ruleDrafts.isEmpty, "a checked reading (not the model's) teaches nothing")
    }

    func testMarkingIsOnlyOfferedWhereSomethingWaits() async throws {
        let pipeline = pipeline(readers: [ScannedReceiptReader()])
        var plan = try await pipeline.plan([try letter()])
        let id = try only(plan).id
        XCTAssertFalse(ImportChecks.canMark(.figure(.reference), on: try only(plan)), "no such figure")
        plan = try await pipeline.resolve(plan, itemId: id, .markChecked(.figure(.amount)))
        XCTAssertFalse(ImportChecks.canMark(.figure(.amount), on: try only(plan)), "already certain")
        do {
            _ = try await pipeline.resolve(plan, itemId: id, .markChecked(.figure(.amount)))
            XCTFail("nothing left to check")
        } catch let error as ImportResolutionError {
            XCTAssertEqual(error, .notOffered(.markChecked(.figure(.amount))))
        }
        do {
            _ = try await pipeline.resolve(plan, itemId: id, .unmarkChecked(.figure(.docDate)))
            XCTFail("never ticked")
        } catch let error as ImportResolutionError {
            XCTAssertEqual(error, .notOffered(.unmarkChecked(.figure(.docDate))))
        }
    }

    // MARK: Taking it back

    func testUndoPutsBackExactlyWhatWasThere() async throws {
        let pipeline = pipeline(readers: [ScannedReceiptReader()])
        let start = try await pipeline.plan([try letter()])
        let id = try only(start).id
        var plan = try await pipeline.resolve(start, itemId: id, .markChecked(.figure(.amount)))
        plan = try await pipeline.resolve(plan, itemId: id, .unmarkChecked(.figure(.amount)))
        XCTAssertEqual(try only(plan), try only(start), "value, source, confidence, reason and its question")
        XCTAssertFalse(plan.isMarkedChecked(id, .figure(.amount)))
        XCTAssertEqual(try only(plan).section, .needsYou)

        // Another tick made since: this one's figure and question come back, the other stays.
        plan = try await pipeline.resolve(plan, itemId: id, .markChecked(.figure(.amount)))
        plan = try await pipeline.resolve(plan, itemId: id, .markChecked(.figure(.docDate)))
        plan = try await pipeline.resolve(plan, itemId: id, .unmarkChecked(.figure(.amount)))
        let item = try only(plan)
        XCTAssertEqual(item.facts.first { $0.field == .amount }, try only(start).facts.first { $0.field == .amount })
        XCTAssertTrue(item.issues.contains { $0.kind == .confirmFigure(.amount) })
        XCTAssertEqual(item.facts.first { $0.field == .docDate }?.reason, "Checked by you")
        XCTAssertTrue(plan.isMarkedChecked(id, .figure(.docDate)))

        // Typed over since: the tick is no longer there to take back.
        plan = try await pipeline.resolve(plan, itemId: id, .confirmFigure(.docDate, .date(Self.date(2025, 3, 6))))
        XCTAssertFalse(plan.isMarkedChecked(id, .figure(.docDate)))
    }

    // MARK: The model's reading

    func testCheckingModelFieldsAcceptsThemFieldByFieldAndUndoTakesTheirRulesBack() async throws {
        let guess = DocumentModelGuess(kind: .insuranceReceipt, issuer: "Example Seguros", docDate: Self.date(2025, 3, 4))
        let pipeline = pipeline(model: ImportModelProposalTests.StubModel(guess))
        let start = try await pipeline.plan([try letter()])
        let id = try only(start).id
        XCTAssertTrue(try only(start).issues.contains { $0.kind == .confirmModelReading })

        var plan = try await pipeline.resolve(start, itemId: id, .markChecked(.figure(.issuer)))
        var item = try only(plan)
        XCTAssertEqual(item.facts.first { $0.field == .issuer }?.source, .user)
        XCTAssertEqual(item.ruleDrafts.map(\.kind), [.issuer])
        XCTAssertTrue(item.issues.contains { $0.kind == .confirmModelReading }, "the kind and date still wait")

        plan = try await pipeline.resolve(plan, itemId: id, .markChecked(.recognition))
        plan = try await pipeline.resolve(plan, itemId: id, .markChecked(.figure(.docDate)))
        item = try only(plan)
        XCTAssertFalse(item.issues.contains { $0.kind == .confirmModelReading }, "every field accepted")
        XCTAssertEqual(item.recognition.reason, ImportModelProposals.acceptedReason)
        XCTAssertEqual(Set(item.ruleDrafts.map(\.kind)), [.issuer, .documentKind])
        XCTAssertEqual(item.section, .ready, "\(item.needsYouReasons)")

        plan = try await pipeline.resolve(plan, itemId: id, .unmarkChecked(.figure(.docDate)))
        plan = try await pipeline.resolve(plan, itemId: id, .unmarkChecked(.recognition))
        item = try only(plan)
        XCTAssertEqual(item.ruleDrafts.map(\.kind), [.issuer], "the kind's rule goes with its tick")
        XCTAssertTrue(item.issues.contains { $0.kind == .confirmModelReading }, "the model's question is back")
        plan = try await pipeline.resolve(plan, itemId: id, .unmarkChecked(.figure(.issuer)))
        XCTAssertEqual(try only(plan), try only(start))
    }

    func testUndoAfterUseTheseBringsTheModelsQuestionBack() async throws {
        let guess = DocumentModelGuess(kind: .insuranceReceipt, issuer: "Example Seguros", docDate: Self.date(2025, 3, 4))
        let pipeline = pipeline(model: ImportModelProposalTests.StubModel(guess))
        var plan = try await pipeline.plan([try letter()])
        let id = try only(plan).id
        plan = try await pipeline.resolve(plan, itemId: id, .markChecked(.figure(.issuer)))
        plan = try await pipeline.resolve(plan, itemId: id, .acceptModelReading)
        XCTAssertFalse(try only(plan).issues.contains { $0.kind == .confirmModelReading })
        plan = try await pipeline.resolve(plan, itemId: id, .unmarkChecked(.figure(.issuer)))
        let item = try only(plan)
        XCTAssertEqual(item.facts.first { $0.field == .issuer }?.source, .model, "the model's issuer, to check again")
        XCTAssertTrue(item.issues.contains { $0.kind == .confirmModelReading }, "the question it raised is back: \(item.issues)")
        XCTAssertEqual(item.section, .needsYou)
    }

    func testUndoIsRefusedAfterARetypeOrAReread() async throws {
        let pipeline = pipeline(readers: [ScannedReceiptReader()])
        var plan = try await pipeline.plan([try letter()])
        let id = try only(plan).id
        plan = try await pipeline.resolve(plan, itemId: id, .markChecked(.figure(.amount)))
        let retyped = try await pipeline.resolve(plan, itemId: id, .confirmFigure(.amount, .money(4300, .eur)))
        do {
            _ = try await pipeline.resolve(retyped, itemId: id, .unmarkChecked(.figure(.amount)))
            XCTFail("typed over since: nothing to take back")
        } catch let error as ImportResolutionError {
            XCTAssertEqual(error, .notOffered(.unmarkChecked(.figure(.amount))))
        }
        plan = try await pipeline.resolve(plan, itemId: id, .markChecked(.recognition))
        let reread = try await pipeline.resolve(plan, itemId: id, .chooseKind(.insurancePolicy))
        for target in [ImportCheckTarget.figure(.amount), .recognition] {
            XCTAssertFalse(reread.isMarkedChecked(id, target))
            do {
                _ = try await pipeline.resolve(reread, itemId: id, .unmarkChecked(target))
                XCTFail("read again since: nothing to take back")
            } catch let error as ImportResolutionError {
                XCTAssertEqual(error, .notOffered(.unmarkChecked(target)))
            }
        }
    }

    // MARK: All at once

    /// `ScannedReceiptReader`'s item, also asking which of two debits paid it (a choice).
    private struct ScannedReceiptWithChoiceReader: ImportReader {
        func handles(_ kind: ImportKind) -> Bool { kind == .unknown || kind == .evidence(.other) }

        func propose(_ files: [(file: ImportFile, recognition: ImportRecognition)], context: ImportContext, db: Database) throws -> [ImportItem] {
            try ScannedReceiptReader().propose(files, context: context, db: db).map { item in
                var item = item
                item.issues.append(ImportIssue(id: "chooseLink", kind: .chooseLink([
                    LinkCandidate(entity: .transaction(901), label: "Debit A", reasons: ["Same amount"]),
                    LinkCandidate(entity: .transaction(902), label: "Debit B", reasons: ["Same amount"])
                ]), reason: "2 debits could have paid it: which one?", offers: [.fileWithoutLink]))
                return item
            }
        }
    }

    func testMarkAllTicksEveryCheckButNoChoiceAndUndoAllRestoresTheItem() async throws {
        let pipeline = pipeline(readers: [ScannedReceiptWithChoiceReader()])
        let start = try await pipeline.plan([try letter()])
        let id = try only(start).id
        XCTAssertEqual(Set(ImportChecks.tickable(try only(start))), [.recognition, .figure(.amount), .figure(.docDate)])
        XCTAssertTrue(ImportChecks.canMarkAll(try only(start)))

        var plan = try await pipeline.resolve(start, itemId: id, .markAllChecked)
        let item = try only(plan)
        XCTAssertFalse(item.facts.contains { $0.confidence == .needsReview })
        XCTAssertEqual(item.recognition.confidence, .certain)
        XCTAssertTrue(item.issues.contains { if case .chooseLink = $0.kind { return true } else { return false } }, "the choice stays")
        XCTAssertEqual(item.section, .needsYou)
        XCTAssertTrue(plan.isMarkedAllChecked(id))
        XCTAssertTrue(plan.isMarkedChecked(id, .figure(.amount)), "each tick can be taken back on its own too")
        XCTAssertFalse(ImportChecks.canMarkAll(item))

        plan = try await pipeline.resolve(plan, itemId: id, .unmarkAllChecked)
        XCTAssertEqual(try only(plan), try only(start))
        XCTAssertFalse(plan.isMarkedAllChecked(id))
        XCTAssertFalse(plan.isMarkedChecked(id, .figure(.amount)))

        // One taken back on its own first: the rest go with Undo all.
        plan = try await pipeline.resolve(plan, itemId: id, .markAllChecked)
        plan = try await pipeline.resolve(plan, itemId: id, .unmarkChecked(.figure(.amount)))
        XCTAssertTrue(plan.isMarkedAllChecked(id))
        plan = try await pipeline.resolve(plan, itemId: id, .unmarkAllChecked)
        let back = try only(plan)
        XCTAssertEqual(back.facts, try only(start).facts)
        XCTAssertEqual(back.recognition, try only(start).recognition)
        XCTAssertEqual(Set(back.issues.map(\.id)), Set(try only(start).issues.map(\.id)))
    }

    func testMarkAllIsOfferedAgainWithTwoChecksAndUndoAllTakesEveryTickBack() async throws {
        let pipeline = pipeline(readers: [ScannedReceiptWithChoiceReader()])
        let start = try await pipeline.plan([try letter()])
        let id = try only(start).id
        var plan = try await pipeline.resolve(start, itemId: id, .markAllChecked)
        plan = try await pipeline.resolve(plan, itemId: id, .unmarkChecked(.figure(.amount)))
        plan = try await pipeline.resolve(plan, itemId: id, .unmarkChecked(.figure(.docDate)))
        XCTAssertTrue(plan.isMarkedAllChecked(id), "the recognition tick is still in place")
        XCTAssertTrue(ImportChecks.canMarkAll(try only(plan)), "two checks again: offered again")
        plan = try await pipeline.resolve(plan, itemId: id, .markAllChecked)
        XCTAssertFalse(try only(plan).facts.contains { $0.confidence == .needsReview })
        plan = try await pipeline.resolve(plan, itemId: id, .unmarkAllChecked)
        let back = try only(plan)
        XCTAssertEqual(back.facts, try only(start).facts)
        XCTAssertEqual(back.recognition, try only(start).recognition, "the earlier mark-all's tick goes too")
        XCTAssertFalse(plan.isMarkedAllChecked(id))
    }

    func testMarkAllIsOfferedOnlyWithTwoChecks() async throws {
        let pipeline = pipeline(readers: [ScannedReceiptReader()])
        var plan = try await pipeline.plan([try letter()])
        let id = try only(plan).id
        plan = try await pipeline.resolve(plan, itemId: id, .markChecked(.figure(.amount)))
        plan = try await pipeline.resolve(plan, itemId: id, .markChecked(.figure(.docDate)))
        XCTAssertEqual(ImportChecks.tickable(try only(plan)), [.recognition])
        XCTAssertFalse(ImportChecks.canMarkAll(try only(plan)), "one check: its own pill")
        do {
            _ = try await pipeline.resolve(plan, itemId: id, .markAllChecked)
            XCTFail("one check only")
        } catch let error as ImportResolutionError {
            XCTAssertEqual(error, .notOffered(.markAllChecked))
        }
        do {
            _ = try await pipeline.resolve(plan, itemId: id, .unmarkAllChecked)
            XCTFail("never marked all")
        } catch let error as ImportResolutionError {
            XCTAssertEqual(error, .notOffered(.unmarkAllChecked))
        }
    }

    func testMarkAllOnAModelReadingDraftsAsUseTheseDoes() async throws {
        let guess = DocumentModelGuess(kind: .insuranceReceipt, issuer: "Example Seguros", docDate: Self.date(2025, 3, 4))
        let pipeline = pipeline(model: ImportModelProposalTests.StubModel(guess))
        let start = try await pipeline.plan([try letter()])
        let id = try only(start).id
        let viaAll = try only(try await pipeline.resolve(start, itemId: id, .markAllChecked))
        let viaUse = try only(try await pipeline.resolve(start, itemId: id, .acceptModelReading))
        XCTAssertEqual(Set(viaAll.ruleDrafts.map(\.actionJSON)), Set(viaUse.ruleDrafts.map(\.actionJSON)))
        XCTAssertEqual(Set(viaAll.ruleDrafts.map(\.kind)), [.documentKind, .issuer])
        XCTAssertFalse(viaAll.issues.contains { $0.kind == .confirmModelReading })
        XCTAssertEqual(viaAll.section, .ready, "\(viaAll.needsYouReasons)")
    }

    // MARK: Held items

    func testAHeldItemTakesNoTick() async throws {
        let p60 = try await db.write { db -> ImportItem in
            let personId = try XCTUnwrap(try Person.fetchOne(db)?.id)
            var year = TaxYear(startYear: 2024, personId: personId, status: .filed)
            try year.insert(db)
            var employment = Employment(startYear: 2024, personId: personId, employerName: "Acme Ltd")
            try Employments.save(db: db, &employment)
            var income = EmploymentIncome(employmentId: employment.id!, source: .p60, payMinorUnits: 4_000_000, taxDeductedMinorUnits: 600_000)
            try Employments.save(db: db, &income)
            let confirmed = PayrollFormImport.Confirmed(kind: .p60, personId: personId, startYear: 2024, employerName: "Acme Ltd",
                                                        payMinorUnits: 4_100_000, taxDeductedMinorUnits: 600_000)
            return ImportItem(file: ImportFile(url: URL(fileURLWithPath: "/synthetic/x.pdf"), fileName: "x.pdf", sha256: "x", byteCount: 1,
                                               fileExtension: "pdf", text: nil, textStatus: .noText, usedOCR: false),
                              recognition: ImportRecognition(kind: .payrollForm(.p60), confidence: .certain, reason: "test"),
                              title: "P60 2024/25 Acme Ltd",
                              facts: [ImportFact(field: .pay, value: .money(4_100_000, .gbp), source: .ocr, confidence: .needsReview, reason: "OCR")],
                              effect: .payrollForm(confirmed), groupKey: "Payroll forms")
        }
        let pipeline = pipeline(readers: [HeldReader(p60: p60)], model: ImportModelProposalTests.StubModel(DocumentModelGuess(kind: .p60)))
        let plan = try await pipeline.plan([try letter()])
        let item = try only(plan)
        XCTAssertTrue(item.isHeldByFiledYear, "\(item.issues)")
        XCTAssertTrue(ImportChecks.tickable(item).isEmpty)
        do {
            _ = try await pipeline.resolve(plan, itemId: item.id, .markAllChecked)
            XCTFail("a held item takes only Leave out")
        } catch let error as ImportResolutionError {
            XCTAssertEqual(error, .notOffered(.markAllChecked))
        }
        for target in [ImportCheckTarget.recognition, .figure(.pay)] {
            XCTAssertFalse(ImportChecks.canMark(target, on: item))
            do {
                _ = try await pipeline.resolve(plan, itemId: item.id, .markChecked(target))
                XCTFail("a held item takes only Leave out")
            } catch let error as ImportResolutionError {
                XCTAssertEqual(error, .notOffered(.markChecked(target)))
            }
        }
    }

    /// Reads a P60 the model proposed as the given item (its file and recognition kept).
    private struct HeldReader: ImportReader {
        let p60: ImportItem

        func handles(_ kind: ImportKind) -> Bool { kind == .payrollForm(.p60) }

        func propose(_ files: [(file: ImportFile, recognition: ImportRecognition)], context: ImportContext, db: Database) throws -> [ImportItem] {
            files.map { file in
                var item = p60
                item.id = UUID()
                item.file = file.file
                item.recognition = file.recognition
                return item
            }
        }
    }
}
