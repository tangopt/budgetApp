import XCTest
import GRDB
@testable import BudgetCore

/// The on-device model in the import pipeline: documents nothing recognises are asked about (at
/// most 2 at once, timed out as no answer), its guess is `.model` facts and a "Check what the
/// on-device model read" issue — never Ready on its own — and accepting or correcting it
/// resolves the issue, accepting drafting learnt rules. Synthetic data only (NIF 503504564 is
/// made up); the model is a stub.
final class ImportModelProposalTests: XCTestCase {
    private var manager: DatabaseManager!
    private var db: DatabaseQueue { manager.dbQueue }
    private var folder: URL!
    private var library: EvidenceLibrary!
    private var applier: ImportApplier!
    private var pipelines: [ImportPipeline] = []

    override func setUpWithError() throws {
        manager = try DatabaseManager(path: nil)
        try manager.migrate()
        try db.write { db in
            try CategorySeeder.seedDefaults(db)
            var person = Person(name: "Person A", shortName: "A")
            try person.insert(db)
        }
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("ImportModelProposalTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        library = EvidenceLibrary(root: folder.appendingPathComponent("Library", isDirectory: true), database: db)
        applier = ImportApplier(dbQueue: db, databasePath: nil, library: library)
    }

    override func tearDownWithError() throws {
        pipelines.forEach { $0.discardPlanningCopy() }
        try? FileManager.default.removeItem(at: folder)
    }

    // MARK: Stubs

    /// Answers every document with `guess` (or throws `error`), counting calls and the most at once.
    final class StubModel: DocumentModelReading, @unchecked Sendable {
        private let lock = NSLock()
        private var _calls = 0, _running = 0, _maxRunning = 0
        private var _texts: [String] = []
        let available: DocumentModelAvailability
        let guess: DocumentModelGuess?
        let error: Error?
        let delayNanoseconds: UInt64

        init(_ guess: DocumentModelGuess?, available: DocumentModelAvailability = .available, error: Error? = nil,
             delayNanoseconds: UInt64 = 0) {
            self.guess = guess
            self.available = available
            self.error = error
            self.delayNanoseconds = delayNanoseconds
        }

        var calls: Int { lock.withLock { _calls } }
        var maxRunning: Int { lock.withLock { _maxRunning } }

        func availability() -> DocumentModelAvailability { available }

        func read(text: String, fileName: String, kinds: [DocumentKind]) async throws -> DocumentModelGuess? {
            lock.withLock {
                _calls += 1
                _running += 1
                _maxRunning = max(_maxRunning, _running)
                _texts.append(text)
            }
            defer { lock.withLock { _running -= 1 } }
            if delayNanoseconds > 0 { try? await Task.sleep(nanoseconds: delayNanoseconds) }
            if case .unavailable(let message) = available { throw DocumentModelReadError.unavailable(message) }
            if let error { throw error }
            return guess
        }
    }

    /// Never answers and ignores cancellation (a stuck session).
    struct StuckModel: DocumentModelReading {
        func availability() -> DocumentModelAvailability { .available }
        func read(text: String, fileName: String, kinds: [DocumentKind]) async throws -> DocumentModelGuess? {
            await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }
            return nil
        }
    }

    private func pipeline(_ model: (any DocumentModelReading)?) -> ImportPipeline {
        let made = ImportPipeline(dbQueue: db, library: library, categorizationService: CategorizationService(categorizer: FakeCategorizer()),
                                  modelReader: model)
        pipelines.append(made)
        return made
    }

    // MARK: Helpers

    private static let issuerLine = "Example Seguros, S.A. NIF 503504564"
    private static let issuerKey = "nif:503504564"

    private func pdf(_ name: String, _ lines: [String]) throws -> URL {
        let made = EvidenceTestPDFs.textPDF(lines, name: name)
        let directory = folder.appendingPathComponent("Drop-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try FileManager.default.moveItem(at: made, to: url)
        return url
    }

    /// A letter nothing built in recognises.
    private func letter(_ name: String = "letter.pdf", day: String = "1") throws -> URL {
        try pdf(name, [Self.issuerLine, "Rua Exemplo 1, Lisboa", "Assunto: comunicacao \(day)", "Caro senhor, segue a informacao pedida."])
    }

    private static func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar.date(from: DateComponents(year: y, month: m, day: d))!
    }

    private static let fullGuess = DocumentModelGuess(kind: .insuranceReceipt, issuer: "Example Seguros", docDate: date(2025, 3, 4),
                                                      amountMinorUnits: 12_050, currency: .eur, reference: "APL-77")

    private func only(_ plan: ImportPlan) throws -> ImportItem {
        let top = plan.items.filter { $0.parentId == nil }
        XCTAssertEqual(top.count, 1, "\(top.map(\.file.fileName))")
        return try XCTUnwrap(top.first)
    }

    private func modelFacts(_ item: ImportItem) -> [ImportFigureField] {
        item.facts.filter { $0.source == .model }.map(\.field).sorted { $0.rawValue < $1.rawValue }
    }

    private func hasModelIssue(_ item: ImportItem) -> Bool {
        item.issues.contains { $0.kind == .confirmModelReading }
    }

    // MARK: Proposals

    func testModelGuessIsNeedsYouNeverReady() async throws {
        let model = StubModel(Self.fullGuess)
        let plan = try await pipeline(model).plan([try letter()])
        let item = try only(plan)
        XCTAssertEqual(model.calls, 1)
        XCTAssertEqual(item.section, .needsYou)
        XCTAssertEqual(item.recognition.kind, .evidence(.insuranceReceipt))
        XCTAssertEqual(item.recognition.confidence, .needsReview)
        XCTAssertEqual(item.recognition.reason, "Proposed by the on-device model")
        let issue = try XCTUnwrap(item.issues.first { $0.kind == .confirmModelReading })
        XCTAssertEqual(issue.reason, "Check what the on-device model read")
        XCTAssertTrue(ImportResolutions.accepts(issue, .acceptModelReading))
        XCTAssertEqual(modelFacts(item), [.amount, .docDate, .issuer, .reference].sorted { $0.rawValue < $1.rawValue })
        XCTAssertTrue(item.facts.filter { $0.source == .model }.allSatisfy { $0.confidence == .needsReview })
        XCTAssertEqual(item.facts.first { $0.field == .amount }?.value, .money(12_050, .eur))
        // The unknown kind question is gone: the model proposed one (still to check).
        XCTAssertFalse(item.issues.contains { if case .unknownKind = $0.kind { return true } else { return false } })
    }

    func testAcceptingModelReadingReadiesAndLearns() async throws {
        let pipeline = pipeline(StubModel(Self.fullGuess))
        var plan = try await pipeline.plan([try letter()])
        let proposed = try only(plan)
        plan = try await pipeline.resolve(plan, itemId: proposed.id, .acceptModelReading)
        let accepted = try only(plan)
        XCTAssertEqual(accepted.section, .ready, "\(accepted.needsYouReasons)")
        XCTAssertFalse(hasModelIssue(accepted))
        XCTAssertEqual(accepted.recognition.kind, .evidence(.insuranceReceipt))
        XCTAssertEqual(accepted.recognition.confidence, .certain)
        XCTAssertTrue(modelFacts(accepted).isEmpty)
        XCTAssertEqual(accepted.facts.first { $0.field == .issuer }?.source, .user)
        XCTAssertEqual(Set(accepted.ruleDrafts.map(\.kind)), [.documentKind, .issuer])

        _ = try applier.apply(plan, entryPoint: "Test")
        let rules = try await db.read { db in try ImportRuleStore.all(db: db) }
        let kind = try XCTUnwrap(rules.first { $0.kind == .documentKind })
        XCTAssertEqual(kind.matchKey, Self.issuerKey)
        XCTAssertEqual(ImportLearning.decode(DocumentKindAction.self, kind.actionJSON)?.kind, .insuranceReceipt)
        let issuer = try XCTUnwrap(rules.first { $0.kind == .issuer })
        XCTAssertEqual(ImportLearning.decode(IssuerAction.self, issuer.actionJSON)?.name, "Example Seguros")

        // Next time the learnt kind recognises the issuer: the model isn't asked.
        let next = StubModel(Self.fullGuess)
        let again = try await only(self.pipeline(next).plan([try letter("letter-2.pdf", day: "2")]))
        XCTAssertEqual(next.calls, 0)
        XCTAssertEqual(again.recognition.kind, .evidence(.insuranceReceipt))
        XCTAssertFalse(hasModelIssue(again))
    }

    func testMalformedModelAnswerKeepsOnlyValidFields() async throws {
        let reader = FoundationModelsDocumentReader(availability: { .available }, timeoutNanoseconds: 5_000_000_000) { _ in
            DocumentGuessSchema(kind: "Spaceship manifest", issuer: "", documentDate: "2025-02-30", amount: "12,50",
                                currency: "EUR", reference: "")
        }
        let plan = try await pipeline(reader).plan([try letter()])
        let item = try only(plan)
        XCTAssertEqual(modelFacts(item), [.amount])
        XCTAssertEqual(item.facts.map(\.field), [.amount])
        XCTAssertEqual(item.facts.first?.value, .money(1_250, .eur))
        XCTAssertEqual(item.recognition.kind, .unknown)
        XCTAssertEqual(item.section, .needsYou)
        XCTAssertTrue(hasModelIssue(item))
        // Still asked what it is.
        XCTAssertTrue(item.issues.contains { if case .unknownKind = $0.kind { return true } else { return false } })
    }

    func testUnavailableModelSaysWhy() async throws {
        let message = "On-device model unavailable: Apple Intelligence is turned off"
        let model = StubModel(Self.fullGuess, available: .unavailable(message))
        let item = try await only(pipeline(model).plan([try letter()]))
        XCTAssertEqual(model.calls, 0)
        let issue = try XCTUnwrap(item.issues.first { if case .unknownKind = $0.kind { return true } else { return false } })
        XCTAssertEqual(issue.reason, message)
        XCTAssertEqual(item.recognition.kind, .unknown)
        XCTAssertFalse(hasModelIssue(item))
        XCTAssertEqual(item.section, .needsYou)
    }

    func testModelThatBecomesUnavailableWhileReadingSaysWhy() async throws {
        let message = "On-device model is still downloading"
        let model = StubModel(nil, error: DocumentModelReadError.unavailable(message))
        let item = try await only(pipeline(model).plan([try letter()]))
        XCTAssertEqual(model.calls, 1)
        let issue = try XCTUnwrap(item.issues.first { if case .unknownKind = $0.kind { return true } else { return false } })
        XCTAssertEqual(issue.reason, message)
    }

    func testRecognisedDocumentsNeverReachTheModel() async throws {
        let model = StubModel(Self.fullGuess)
        let p60 = PayrollFormTestPDFs.textPDF(PayrollFormTestPDFs.p60RowLayout, name: "p60.pdf")
        let receipt = try pdf("receipt.pdf", [Self.issuerLine, "SEGURO MULTI-RISCO HABITACAO", "Data: 04/03/2025", "TOTAL 120,00 €"])
        let plan = try await pipeline(model).plan([p60, receipt])
        XCTAssertEqual(model.calls, 0)
        XCTAssertFalse(plan.items.contains(where: hasModelIssue))
        XCTAssertFalse(plan.items.contains { $0.facts.contains { $0.source == .model } })
    }

    func testTimedOutModelIsNoAnswer() async throws {
        var pipeline = pipeline(StuckModel())
        pipeline.modelTimeoutNanoseconds = 50_000_000
        let started = Date()
        let item = try await only(pipeline.plan([try letter()]))
        XCTAssertLessThan(Date().timeIntervalSince(started), 10)
        XCTAssertEqual(item.recognition.kind, .unknown)
        XCTAssertFalse(hasModelIssue(item))
        XCTAssertTrue(item.facts.isEmpty)
        XCTAssertEqual(item.issues.first { if case .unknownKind = $0.kind { return true } else { return false } }?.reason,
                       "What kind of document is this?")
    }

    func testAtMostTwoModelCallsAtOnceWithProgress() async throws {
        let model = StubModel(DocumentModelGuess(issuer: "Example Seguros"), delayNanoseconds: 50_000_000)
        let urls = try (1...5).map { try letter("letter-\($0).pdf", day: "\($0)") }
        let seen = Seen()
        let plan = try await pipeline(model).plan(urls) { seen.add($0.currentFile) }
        XCTAssertEqual(model.calls, 5)
        XCTAssertLessThanOrEqual(model.maxRunning, 2)
        XCTAssertEqual(plan.items.filter(hasModelIssue).count, 5)
        XCTAssertTrue(seen.all.contains("Asking the on-device model about letter-3.pdf"), "\(seen.all)")
        XCTAssertEqual(seen.final, .some(nil), "no file is being asked about once the model has answered")
    }

    final class Seen: @unchecked Sendable {
        private let lock = NSLock()
        private var files: [String] = []
        private var last: String??
        func add(_ file: String?) { lock.withLock { last = .some(file); if let file { files.append(file) } } }
        var all: [String] { lock.withLock { files } }
        var final: String?? { lock.withLock { last } }
    }

    // MARK: Field by field

    func testCorrectingFieldsResolvesFieldByField() async throws {
        let model = StubModel(DocumentModelGuess(issuer: "Example Seguros", docDate: Self.date(2025, 3, 4)))
        let pipeline = pipeline(model)
        var plan = try await pipeline.plan([try letter()])
        let id = try only(plan).id
        // Its kind chosen: the model's figures still wait.
        plan = try await pipeline.resolve(plan, itemId: id, .chooseKind(.insuranceReceipt))
        var item = try only(plan)
        XCTAssertEqual(model.calls, 1, "a reread doesn't ask the model again")
        XCTAssertEqual(item.recognition.kind, .evidence(.insuranceReceipt))
        XCTAssertTrue(hasModelIssue(item))
        XCTAssertEqual(modelFacts(item), [.docDate, .issuer])
        XCTAssertEqual(item.section, .needsYou)
        // The issuer named: the date still waits.
        plan = try await pipeline.resolve(plan, itemId: id, .setIssuer("Example Seguros SA"))
        item = try only(plan)
        XCTAssertEqual(modelFacts(item), [.docDate])
        XCTAssertTrue(hasModelIssue(item))
        // The date checked: no model figure left, the item is ready, and only the user's corrections teach.
        plan = try await pipeline.resolve(plan, itemId: id, .confirmFigure(.docDate, .date(Self.date(2025, 3, 4))))
        item = try only(plan)
        XCTAssertFalse(hasModelIssue(item))
        XCTAssertTrue(modelFacts(item).isEmpty)
        XCTAssertEqual(item.section, .ready, "\(item.needsYouReasons)")
        XCTAssertEqual(Set(item.ruleDrafts.map(\.kind)), [.documentKind, .issuer])
    }

    func testConfirmingAModelFigureKeepsTheOthersToCheck() async throws {
        let pipeline = pipeline(StubModel(DocumentModelGuess(issuer: "Example Seguros", docDate: Self.date(2025, 3, 4))))
        var plan = try await pipeline.plan([try letter()])
        let id = try only(plan).id
        plan = try await pipeline.resolve(plan, itemId: id, .confirmFigure(.docDate, .date(Self.date(2025, 3, 5))))
        let item = try only(plan)
        XCTAssertEqual(modelFacts(item), [.issuer])
        XCTAssertTrue(hasModelIssue(item))
        XCTAssertEqual(item.section, .needsYou)
    }

    func testAcceptingIsOnlyOfferedWithAModelReading() async throws {
        let pipeline = pipeline(nil)
        let plan = try await pipeline.plan([try letter()])
        let item = try only(plan)
        XCTAssertFalse(hasModelIssue(item))
        do {
            _ = try await pipeline.resolve(plan, itemId: item.id, .acceptModelReading)
            XCTFail("accepted without a model reading")
        } catch let error as ImportResolutionError {
            XCTAssertEqual(error, .notOffered(.acceptModelReading))
        }
    }

    // MARK: Effect-bearing kinds

    private func personId() throws -> Int64 {
        try db.read { db in try XCTUnwrap(try Person.fetchOne(db)?.id) }
    }

    func testModelGuessedUtilityInvoiceIsReadAsOneAndKeepsWhatWasAcceptedOnAReread() async throws {
        let providerId = try await db.write { db -> Int64 in
            var property = Property(name: "Property A", country: "PT")
            try Properties.save(db: db, &property)
            var provider = UtilityProvider(propertyId: property.id!, name: "Demo Water", kind: .water)
            try Recharges.saveProvider(db: db, &provider)
            return provider.id!
        }
        let guess = DocumentModelGuess(kind: .utilityInvoice, docDate: Self.date(2025, 3, 4), amountMinorUnits: 4_210, currency: .eur,
                                       reference: "FT 2025/77")
        let pipeline = pipeline(StubModel(guess))
        var plan = try await pipeline.plan([try letter()])
        var item = try only(plan)
        XCTAssertEqual(item.recognition.kind, .utilityInvoice)
        XCTAssertTrue(item.recognition.proposedByModel)
        XCTAssertTrue(item.issues.contains { $0.kind == .chooseTarget(.provider, options: [providerId]) }, "read by the invoice reader: \(item.issues)")
        XCTAssertTrue(hasModelIssue(item))
        XCTAssertEqual(item.section, .needsYou)

        plan = try await pipeline.resolve(plan, itemId: item.id, .acceptModelReading)
        item = try only(plan)
        XCTAssertFalse(hasModelIssue(item))
        XCTAssertTrue(modelFacts(item).isEmpty)
        XCTAssertEqual(item.section, .needsYou, "its provider is still to choose: \(item.needsYouReasons)")

        plan = try await pipeline.resolve(plan, itemId: item.id, .chooseTarget(.provider, providerId))
        item = try only(plan)
        XCTAssertEqual(item.facts.first { $0.field == .amount }?.value, .money(4_210, .eur), "\(item.facts)")
        XCTAssertEqual(item.facts.first { $0.field == .amount }?.source, .user)
        XCTAssertFalse(item.issues.contains { $0.kind == .missingFigure(.amount) }, "\(item.issues)")
        XCTAssertFalse(hasModelIssue(item))
        // The invoice reader makes its record only from what it reads itself: still a question, never Ready.
        XCTAssertTrue(item.issues.contains { $0.id == UtilityInvoiceImportReader.documentOnlyIssueId }, "\(item.issues)")
        XCTAssertEqual(item.section, .needsYou)
    }

    func testModelGuessedPayrollFormIsReadAsOneAndAnUnfitReferenceStaysAQuestion() async throws {
        let guess = DocumentModelGuess(kind: .p60, issuer: "Example Employer Ltd", reference: "not a reference")
        let pipeline = pipeline(StubModel(guess))
        var plan = try await pipeline.plan([try letter()])
        var item = try only(plan)
        XCTAssertEqual(item.recognition.kind, .payrollForm(.p60))
        XCTAssertTrue(item.issues.contains { $0.kind == .missingFigure(.taxYear) }, "read by the payroll reader: \(item.issues)")
        XCTAssertTrue(item.issues.contains { $0.kind == .missingFigure(.issuer) })
        XCTAssertTrue(hasModelIssue(item))
        XCTAssertEqual(item.section, .needsYou)

        plan = try await pipeline.resolve(plan, itemId: item.id, .acceptModelReading)
        item = try only(plan)
        XCTAssertFalse(hasModelIssue(item))
        XCTAssertEqual(item.facts.first { $0.field == .issuer }?.source, .user)
        XCTAssertFalse(item.issues.contains { $0.kind == .missingFigure(.issuer) }, "the employer is written: \(item.issues)")
        XCTAssertEqual(item.facts.first { $0.field == .reference }?.source, .model, "not a PAYE reference: not written")
        let question = try XCTUnwrap(item.issues.first { $0.kind == .confirmFigure(.reference) })
        XCTAssertEqual(question.reason, "Reference read by the on-device model doesn't fit: check it")
        if case .payrollForm(let confirmed) = item.effect {
            XCTAssertEqual(confirmed.employerName, "Example Employer Ltd")
            XCTAssertNil(confirmed.payeReference)
        }
        XCTAssertEqual(item.section, .needsYou)
        XCTAssertEqual(item.ruleDrafts.map(\.kind), [.documentKind, .issuer])
        do {
            _ = try await pipeline.resolve(plan, itemId: item.id, .confirmFigure(.reference, .text("still not one")))
            XCTFail("an unchecked PAYE reference")
        } catch let error as ImportResolutionError {
            XCTAssertEqual(error, .notOffered(.confirmFigure(.reference, .text("still not one"))))
        }

        // Read again for its person: the accepted employer survives (and is still taught), the reference is still asked.
        plan = try await pipeline.resolve(plan, itemId: item.id, .chooseTarget(.person, try personId()))
        item = try only(plan)
        XCTAssertEqual(item.facts.first { $0.field == .issuer }?.value, .text("Example Employer Ltd"))
        XCTAssertEqual(item.facts.first { $0.field == .issuer }?.source, .user)
        XCTAssertFalse(item.issues.contains { $0.kind == .missingFigure(.issuer) }, "\(item.issues)")
        XCTAssertEqual(Set(item.ruleDrafts.map(\.kind)), [.documentKind, .issuer])
        XCTAssertTrue(item.issues.contains { $0.kind == .confirmFigure(.reference) }, "\(item.issues)")
        XCTAssertFalse(hasModelIssue(item))

        plan = try await pipeline.resolve(plan, itemId: item.id, .confirmFigure(.reference, .text("123/AB456")))
        item = try only(plan)
        XCTAssertTrue(modelFacts(item).isEmpty)
        XCTAssertFalse(item.issues.contains { $0.kind == .confirmFigure(.reference) })
    }

    // MARK: Cache and batch checks

    func testAGuessIsCachedForFilesAddedLater() async throws {
        let model = StubModel(Self.fullGuess)
        let pipeline = pipeline(model)
        let url = try letter()
        var plan = try await pipeline.plan([url])
        let copy = folder.appendingPathComponent("copy-\(UUID().uuidString).pdf")
        try FileManager.default.copyItem(at: url, to: copy)
        plan = try await pipeline.plan(adding: [copy], to: plan, intent: .none)
        XCTAssertEqual(model.calls, 1, "the same file is never asked twice")
        let added = try XCTUnwrap(plan.items.first { $0.file.url == copy })
        XCTAssertEqual(added.recognition.kind, .evidence(.insuranceReceipt))
        XCTAssertEqual(added.section, .duplicates, "the duplicate pass sees the model's item: \(added.needsYouReasons)")
    }

    func testTheFiledYearGuardSeesAModelProposedItem() async throws {
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
                              title: "P60 2024/25 Acme Ltd", effect: .payrollForm(confirmed), groupKey: "Payroll forms")
        }
        let model = StubModel(DocumentModelGuess(kind: .p60))
        let held = ImportPipeline(dbQueue: db, library: library, categorizationService: CategorizationService(categorizer: FakeCategorizer()),
                                  readers: [ModelP60Reader(p60: p60)], modelReader: model)
        pipelines.append(held)
        let item = try await only(held.plan([try letter()]))
        XCTAssertEqual(model.calls, 1)
        XCTAssertTrue(item.recognition.proposedByModel)
        XCTAssertTrue(item.isHeldByFiledYear, "model proposals come before the filed-year guard: \(item.issues)")
    }

    func testTheUnavailableNoticeIsTheModelsOwnMessage() {
        for message in DocumentModelAvailability.unavailableMessages {
            let issue = ImportIssue(id: "unknownKind", kind: .unknownKind(proposed: nil), reason: message)
            XCTAssertTrue(ImportModelProposals.isUnavailableNotice(issue), message)
        }
        XCTAssertEqual(DocumentModelAvailability.unavailableMessages.count, 4)
        XCTAssertTrue(DocumentModelAvailability.unavailableMessages.contains("On-device model unavailable: Apple Intelligence is turned off"))
        XCTAssertFalse(ImportModelProposals.isUnavailableNotice(ImportIssue(id: "unknownKind", kind: .unknownKind(proposed: nil),
                                                                            reason: "What is this document?")))
        XCTAssertFalse(ImportModelProposals.isUnavailableNotice(ImportIssue(id: "x", kind: .readerProblem("On-device model unavailable"),
                                                                            reason: "On-device model unavailable")))
    }
}

/// Reads a P60 the model proposed as the given item (its file and recognition kept).
private struct ModelP60Reader: ImportReader {
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
