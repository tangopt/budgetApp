import XCTest
import GRDB
@testable import BudgetCore

/// A correction that drafts a rule (a kind, an issuer's name, a link, where a figure sits) checked
/// against the other documents of the same review and applied to the ones the user ticks, as the
/// user's own answers there; each change undone on its own, or with the correction's undo; nothing
/// learnt before Confirm import. Synthetic data only (NIF 503504564 is made up).
final class ImportRuleFitsTests: XCTestCase {
    private var manager: DatabaseManager!
    private var db: DatabaseQueue { manager.dbQueue }
    private var folder: URL!
    private var library: EvidenceLibrary!
    private var pipelines: [ImportPipeline] = []
    private var pipeline: ImportPipeline!
    private var applier: ImportApplier!
    private var accountId: Int64!
    private var batchId: Int64!

    override func setUpWithError() throws {
        manager = try DatabaseManager(path: nil)
        try manager.migrate()
        try db.write { db in
            try CategorySeeder.seedDefaults(db)
            var account = Account(name: "Bank A", currency: .eur, kind: .cash, trackingMode: .imported)
            try account.insert(db)
            accountId = account.id!
            var batch = ImportBatch(accountId: accountId, sourceFileName: "bank.csv", importedAt: Date())
            try batch.insert(db)
            batchId = batch.id!
        }
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("ImportRuleFitsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        library = EvidenceLibrary(root: folder.appendingPathComponent("Library", isDirectory: true), database: db)
        pipeline = makePipeline()
        applier = ImportApplier(dbQueue: db, databasePath: nil, library: library)
    }

    override func tearDownWithError() throws {
        pipelines.forEach { $0.discardPlanningCopy() }
        try? FileManager.default.removeItem(at: folder)
    }

    // MARK: Helpers

    private static let issuerLine = "Example Seguros, S.A. NIF 503504564"
    private static let issuerKey = "nif:503504564"

    private func makePipeline(model: (any DocumentModelReading)? = nil) -> ImportPipeline {
        let made = ImportPipeline(dbQueue: db, library: library, categorizationService: CategorizationService(categorizer: FakeCategorizer()),
                                  modelReader: model)
        pipelines.append(made)
        return made
    }

    private func pdf(_ name: String, _ lines: [String]) throws -> URL {
        let made = EvidenceTestPDFs.textPDF(lines, name: name)
        let directory = folder.appendingPathComponent("Drop-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try FileManager.default.moveItem(at: made, to: url)
        return url
    }

    /// A letter of the issuer nothing built in recognises.
    private func letter(_ name: String, day: String) throws -> URL {
        try pdf(name, [Self.issuerLine, "Rua Exemplo 1, Lisboa", "Assunto: comunicacao \(day)", "Caro senhor, segue a informacao pedida."])
    }

    /// A letter of another issuer (keyed by its first line).
    private func otherLetter(_ name: String) throws -> URL {
        try pdf(name, ["Example Letters Lda", "Rua Exemplo 2, Porto", "Assunto: aviso", "Caro senhor, segue o aviso."])
    }

    /// An insurance receipt of `amount` (e.g. "120,00") dated `date` (dd/MM/yyyy).
    private func receipt(_ name: String, date: String, amount: String) throws -> URL {
        try pdf(name, [Self.issuerLine, "SEGURO MULTI-RISCO HABITACAO", "Data: \(date)", "TOTAL \(amount) €"])
    }

    private static func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        MonthRange.calendar.date(from: DateComponents(year: y, month: m, day: d))!
    }

    @discardableResult
    private func transaction(_ date: Date, _ amount: Int, _ text: String) throws -> Int64 {
        try db.write { db in
            var transaction = Transaction(importBatchId: batchId, accountId: accountId, date: date, rawDescription: text,
                                          amountMinorUnits: amount, categoryId: nil, status: .confirmed, categorizedBy: .manual,
                                          fingerprint: UUID().uuidString)
            try transaction.insert(db)
            return transaction.id!
        }
    }

    private func item(_ plan: ImportPlan, _ name: String) throws -> ImportItem {
        try XCTUnwrap(plan.items.first { $0.file.fileName == name }, "\(plan.items.map(\.file.fileName))")
    }

    private func rules() throws -> [ImportRule] { try db.read { db in try ImportRuleStore.all(db: db) } }

    // MARK: Which documents fit

    func testANameFitsOnlyTheOtherDocumentsOfTheSameIssuer() async throws {
        var plan = try await pipeline.plan([try letter("a.pdf", day: "1"), try letter("b.pdf", day: "2"), try otherLetter("c.pdf")])
        let fits1 = try await pipeline.ruleFits(plan)
        XCTAssertEqual(fits1, [:], "no correction yet")
        let a = try item(plan, "a.pdf"), b = try item(plan, "b.pdf")
        plan = try await pipeline.resolve(plan, itemId: a.id, .setIssuer("Seguradora Exemplo"))

        let fits = try await pipeline.ruleFits(plan)
        XCTAssertEqual(Array(fits.keys), [a.id])
        let fit = try XCTUnwrap(fits[a.id]?.first)
        XCTAssertEqual(fits[a.id]?.map(\.itemId), [b.id], "not the other issuer's letter, not the corrected one")
        XCTAssertEqual(fit.documentName, "b.pdf")
        XCTAssertEqual(fit.changes, [ImportRuleChange(aspect: .name, label: "Name", before: .none, after: .text("Seguradora Exemplo"),
                                                      resolution: .setIssuer("Seguradora Exemplo"))])
    }

    func testADocumentTheUserAnsweredOrThatAlreadyHasItIsNotAFit() async throws {
        var plan = try await pipeline.plan([try letter("a.pdf", day: "1"), try letter("b.pdf", day: "2"), try letter("c.pdf", day: "3")])
        let a = try item(plan, "a.pdf"), b = try item(plan, "b.pdf"), c = try item(plan, "c.pdf")
        plan = try await pipeline.resolve(plan, itemId: b.id, .setIssuer("Another Name"))
        plan = try await pipeline.resolve(plan, itemId: c.id, .chooseKind(.insuranceReceipt))
        // (A kind first: choosing it reads the letter again, dropping a name given before.)
        plan = try await pipeline.resolve(plan, itemId: a.id, .chooseKind(.insuranceReceipt))
        plan = try await pipeline.resolve(plan, itemId: a.id, .setIssuer("Seguradora Exemplo"))
        let fits = try await pipeline.ruleFits(plan)
        // b's name is the user's; c's kind is the user's (and already that kind): only c's name, b's kind.
        XCTAssertEqual(fits[a.id]?.first { $0.itemId == b.id }?.changes.map(\.aspect), [.kind])
        XCTAssertEqual(fits[a.id]?.first { $0.itemId == c.id }?.changes.map(\.aspect), [.name])
        let kind = try XCTUnwrap(fits[a.id]?.first { $0.itemId == b.id }?.changes.first)
        XCTAssertEqual(kind.before, .text("Unknown"))
        XCTAssertEqual(kind.after, .text("Insurance receipt"))
        XCTAssertEqual(kind.resolution, .chooseKind(.insuranceReceipt))
    }

    func testHeldDuplicateAndLeftOutDocumentsAreNeverFits() {
        let drafts = [ImportRuleDraft(kind: .issuer, key: Self.issuerKey, matchLabel: "Example Seguros, S.A.",
                                      actionJSON: "{\"name\":\"Seguradora Exemplo\"}", actionLabel: "Name: Seguradora Exemplo")]
        var source = Self.syntheticItem("source")
        source.ruleDrafts = drafts
        let open = Self.syntheticItem("open")
        var held = Self.syntheticItem("held")
        held.issues = [ImportIssue(id: FiledYearGuard.checkFailedIssueId, kind: .readerProblem("check failed"), reason: "check failed", offers: [.leaveOut])]
        var duplicate = Self.syntheticItem("duplicate")
        duplicate.duplicate = ImportDuplicate(level: .file, of: "Same file as open.pdf")
        var out = Self.syntheticItem("out")
        out.isLeftOut = true
        let plan = ImportPlan(items: [source, open, held, duplicate, out])
        var context = ImportRuleFits.Context()
        for item in plan.items { context.issuers[item.id] = IssuerKey(key: Self.issuerKey, label: "Example Seguros, S.A.") }
        XCTAssertEqual(ImportRuleFits.fits(from: source.id, in: plan, context: context).map(\.itemId), [open.id])

        // A left-out source offers nothing.
        var outSource = plan
        outSource.items[0].isLeftOut = true
        XCTAssertEqual(ImportRuleFits.fits(from: source.id, in: outSource, context: context), [])
    }

    func testARecordLinkAndARememberedFigureFitWhereTheDocumentOffersThem() {
        let key = IssuerKey(key: Self.issuerKey, label: "Example Seguros, S.A.")
        let drafts = [
            ImportRuleDraft(kind: .link, key: ImportRuleKind.linkKey(issuer: key, family: .record), matchLabel: key.label,
                            actionJSON: ImportLearning.encode(LinkAction(entity: .property(7)))!, actionLabel: "Link to Property A"),
            ImportRuleDraft(kind: .figurePosition, key: ImportRuleKind.figurePositionKey(issuer: key, field: .amount), matchLabel: key.label,
                            actionJSON: ImportLearning.encode(FigurePositionAction(field: .amount, label: "Valor a pagar", occurrence: 0))!,
                            actionLabel: "Amount: after “Valor a pagar”"),
        ]
        var source = Self.syntheticItem("source")
        source.ruleDrafts = drafts
        var asking = Self.syntheticItem("asking", text: Self.issuerLine + "\nIVA 9,66\nValor a pagar: 45,10 €")
        asking.facts = [ImportFact(field: .amount, value: .money(966, .eur), source: .textLayer, confidence: .certain, reason: "Read")]
        asking.issues = [ImportIssue(id: "chooseLink", kind: .chooseLink([LinkCandidate(entity: .property(7), label: "Property A", reasons: []),
                                                                          LinkCandidate(entity: .property(8), label: "Property B", reasons: [])]),
                                     reason: "Which property?")]
        var linked = Self.syntheticItem("linked", text: Self.issuerLine + "\nValor a pagar: 12,00 €")
        linked.links = [ProposedLink(entity: .property(8), label: "Property B", confidence: .certain, reasons: [])]
        linked.facts = [ImportFact(field: .amount, value: .money(1200, .eur), source: .user, confidence: .certain, reason: "Checked by you")]
        let plan = ImportPlan(items: [source, asking, linked])
        var context = ImportRuleFits.Context()
        for item in plan.items { context.issuers[item.id] = key }

        let fits = ImportRuleFits.fits(from: source.id, in: plan, context: context)
        XCTAssertEqual(fits.map(\.itemId), [asking.id], "a certain link of that type and the user's figure stay")
        XCTAssertEqual(fits.first?.changes, [
            ImportRuleChange(aspect: .link(.record), label: "Link", before: .none, after: .text("Property A"), resolution: .chooseLink(.property(7))),
            ImportRuleChange(aspect: .figure(.amount), label: "Amount", before: .figure(.money(966, .eur)), after: .figure(.money(4510, .eur)),
                             resolution: .confirmFigure(.amount, .money(4510, .eur))),
        ])
    }

    func testAMerchantFitsWhenExactlyOneOfferedTransactionPaysTheDocument() async throws {
        let first = try transaction(Self.date(2024, 4, 5), -12_000, "DEMO SEGUROS 77")
        let second = try transaction(Self.date(2024, 10, 5), -9_500, "DEMO SEGUROS 78")
        var plan = try await pipeline.plan([try receipt("r1.pdf", date: "10/03/2024", amount: "120,00"),
                                            try receipt("r2.pdf", date: "10/09/2024", amount: "95,00")])
        let r1 = try item(plan, "r1.pdf"), r2 = try item(plan, "r2.pdf")
        plan = try await pipeline.resolve(plan, itemId: r1.id, .chooseLink(.transaction(first)))
        let merchantFits = try await pipeline.ruleFits(plan)
        let fit = try XCTUnwrap(merchantFits[r1.id]?.first)
        XCTAssertEqual(fit.itemId, r2.id)
        XCTAssertEqual(fit.changes.map(\.aspect), [.link(.transaction)])
        XCTAssertEqual(fit.changes.first?.resolution, .chooseLink(.transaction(second)))

        plan = try await pipeline.applyRule(plan, from: r1.id, to: [r2.id])
        let changed = try item(plan, "r2.pdf")
        XCTAssertEqual(changed.links.filter { $0.confidence == .certain }.map(\.entity), [.transaction(second)])
        XCTAssertEqual(changed.section, .ready, "\(changed.needsYouReasons)")
    }

    func testEachFileIsWorkedOutOnceAcrossRepeatedChecks() async throws {
        var plan = try await pipeline.plan([try letter("a.pdf", day: "1"), try letter("b.pdf", day: "2"), try letter("c.pdf", day: "3")])
        let a = try item(plan, "a.pdf"), b = try item(plan, "b.pdf")
        plan = try await pipeline.resolve(plan, itemId: a.id, .setIssuer("Seguradora Exemplo"))
        for _ in 0..<3 { _ = try await pipeline.ruleFits(plan) }
        XCTAssertEqual(pipeline.ruleFitCache.derivations, 3, "each file's issuer key and recognition once")
        plan = try await pipeline.applyRule(plan, from: a.id, to: [b.id])
        _ = try await pipeline.ruleFits(plan)
        XCTAssertEqual(pipeline.ruleFitCache.derivations, 3, "applying and checking again read no file again")
    }

    func testAPendingRecordLinkShowsAsToCheck() {
        let key = IssuerKey(key: Self.issuerKey, label: "Example Seguros, S.A.")
        var source = Self.syntheticItem("source")
        source.ruleDrafts = [ImportRuleDraft(kind: .link, key: ImportRuleKind.linkKey(issuer: key, family: .record), matchLabel: key.label,
                                             actionJSON: ImportLearning.encode(LinkAction(entity: .property(7)))!, actionLabel: "Link to Property A")]
        var pending = Self.syntheticItem("pending")
        pending.links = [ProposedLink(entity: .property(7), label: "Property A", confidence: .needsReview, reasons: ["Same address"])]
        let plan = ImportPlan(items: [source, pending])
        var context = ImportRuleFits.Context()
        for item in plan.items { context.issuers[item.id] = key }
        XCTAssertEqual(ImportRuleFits.fits(from: source.id, in: plan, context: context).first?.changes.first?.before, .text("To check: Property A"))
    }

    // MARK: Applying

    func testApplyingChangesOnlyTheTickedDocumentsAsTheUsersAnswers() async throws {
        var plan = try await pipeline.plan([try letter("a.pdf", day: "1"), try letter("b.pdf", day: "2"), try letter("c.pdf", day: "3")])
        let a = try item(plan, "a.pdf"), b = try item(plan, "b.pdf"), c = try item(plan, "c.pdf")
        plan = try await pipeline.resolve(plan, itemId: a.id, .chooseKind(.insuranceReceipt))
        plan = try await pipeline.resolve(plan, itemId: a.id, .setIssuer("Seguradora Exemplo"))
        let fits2 = try await pipeline.ruleFits(plan)
        XCTAssertEqual(fits2[a.id]?.map(\.itemId), [b.id, c.id])

        plan = try await pipeline.applyRule(plan, from: a.id, to: [b.id])
        let changed = try item(plan, "b.pdf")
        XCTAssertEqual(changed.recognition.kind, .evidence(.insuranceReceipt))
        XCTAssertEqual(changed.facts.first { $0.field == .issuer }?.value, .text("Seguradora Exemplo"))
        XCTAssertEqual(changed.facts.first { $0.field == .issuer }?.source, .user, "the user's answer, through the one path")
        XCTAssertEqual(Set(changed.ruleDrafts.map(\.kind)), [.documentKind, .issuer])
        XCTAssertEqual(plan.ruleChangeSource(of: b.id)?.id, a.id)
        XCTAssertEqual(plan.ruleChangeSource(of: b.id)?.name, "a.pdf")
        XCTAssertEqual(try item(plan, "c.pdf").recognition.kind, .unknown, "unticked: unchanged")
        XCTAssertNil(plan.ruleChangeSource(of: c.id))
        XCTAssertEqual(plan.ruleChangedItems(from: a.id), [b.id])

        // The changed document isn't a source of its own; the source still fits the unticked one.
        let fits = try await pipeline.ruleFits(plan)
        XCTAssertEqual(Array(fits.keys), [a.id])
        XCTAssertEqual(fits[a.id]?.map(\.itemId), [c.id])

        XCTAssertEqual(try rules(), [], "nothing is learnt before Confirm import")
        plan = try await pipeline.resolve(plan, itemId: c.id, .leaveOut)
        _ = try applier.apply(plan, entryPoint: "Test")
        XCTAssertEqual(Set(try rules().map(\.kind)), [.documentKind, .issuer], "learnt once on Confirm import")
    }

    func testUndoingOneChangeRevertsOnlyThatDocument() async throws {
        let start = try await pipeline.plan([try letter("a.pdf", day: "1"), try letter("b.pdf", day: "2"), try letter("c.pdf", day: "3")])
        let a = try item(start, "a.pdf"), b = try item(start, "b.pdf"), c = try item(start, "c.pdf")
        var plan = try await pipeline.resolve(start, itemId: a.id, .chooseKind(.insuranceReceipt))
        plan = try await pipeline.applyRule(plan, from: a.id, to: [b.id, c.id])
        XCTAssertEqual(plan.ruleChangedItems(from: a.id), [b.id, c.id])

        plan = try await pipeline.undoRuleChange(plan, itemId: b.id)
        XCTAssertEqual(try item(plan, "b.pdf"), b, "as it was before the rule changed it")
        XCTAssertFalse(plan.state.chosenKinds.contains(b.id))
        XCTAssertEqual(try item(plan, "c.pdf").recognition.kind, .evidence(.insuranceReceipt), "the other change stays")
        XCTAssertEqual(try item(plan, "a.pdf").recognition.kind, .evidence(.insuranceReceipt), "the correction stays")
        XCTAssertEqual(plan.ruleChangedItems(from: a.id), [c.id])
        let fits3 = try await pipeline.ruleFits(plan)
        XCTAssertEqual(fits3[a.id]?.map(\.itemId), [b.id], "it fits again")

        // An answer of the user's own on the changed document makes the change theirs: no undo of its own.
        plan = try await pipeline.resolve(plan, itemId: c.id, .setIssuer("Seguradora Exemplo"))
        XCTAssertNil(plan.ruleChangeSource(of: c.id))
        do {
            _ = try await pipeline.undoRuleChange(plan, itemId: c.id)
            XCTFail("nothing to undo")
        } catch let error as ImportResolutionError {
            XCTAssertEqual(error, .itemNotFound(c.id))
        }
    }

    /// The model reads an issuer on a.pdf only (the other letters get nothing).
    private final class FirstLetterModel: DocumentModelReading, @unchecked Sendable {
        func availability() -> DocumentModelAvailability { .available }
        func read(text: String, fileName: String, kinds: [DocumentKind]) async throws -> DocumentModelGuess? {
            fileName == "a.pdf" ? DocumentModelGuess(issuer: "Seguradora Exemplo") : nil
        }
    }

    func testUndoingTheCorrectionOffersToUndoTheChangesItMade() async throws {
        let pipeline = makePipeline(model: FirstLetterModel())
        let start = try await pipeline.plan([try letter("a.pdf", day: "1"), try letter("b.pdf", day: "2")])
        let a = try item(start, "a.pdf"), b = try item(start, "b.pdf")
        XCTAssertEqual(a.facts.first { $0.field == .issuer }?.source, .model)
        var plan = try await pipeline.resolve(start, itemId: a.id, .markChecked(.figure(.issuer)))
        let fits4 = try await pipeline.ruleFits(plan)
        XCTAssertEqual(fits4[a.id]?.map(\.itemId), [b.id])
        XCTAssertEqual(plan.ruleChangesUndoneWith(.unmarkChecked(.figure(.issuer)), on: a.id), [], "nothing changed yet")
        plan = try await pipeline.applyRule(plan, from: a.id, to: [b.id])
        XCTAssertEqual(try item(plan, "b.pdf").facts.first { $0.field == .issuer }?.value, .text("Seguradora Exemplo"))

        XCTAssertEqual(plan.ruleChangesUndoneWith(.unmarkChecked(.figure(.issuer)), on: a.id), [b.id])
        XCTAssertEqual(plan.ruleChangesUndoneWith(.unmarkChecked(.recognition), on: a.id), [], "not ticked")

        // Keep them: only the tick is taken back.
        let kept = try await pipeline.resolve(plan, itemId: a.id, .unmarkChecked(.figure(.issuer)))
        XCTAssertEqual(try item(kept, "a.pdf"), a)
        XCTAssertEqual(kept.ruleChangeSource(of: b.id)?.id, a.id)

        // Undo all: the tick and the change it made.
        var all = try await pipeline.resolve(plan, itemId: a.id, .unmarkChecked(.figure(.issuer)))
        all = try await pipeline.undoRuleChanges(all, from: a.id)
        XCTAssertEqual(try item(all, "a.pdf"), a)
        XCTAssertEqual(try item(all, "b.pdf"), b)
        XCTAssertEqual(all.ruleChangedItems(from: a.id), [])
    }

    // MARK: Synthetic items

    private static func syntheticItem(_ name: String, text: String = issuerLine + "\nCarta") -> ImportItem {
        let file = ImportFile(url: URL(fileURLWithPath: "/synthetic/\(name).pdf"), fileName: "\(name).pdf", sha256: "sha-\(name)", byteCount: 1,
                              fileExtension: "pdf", text: text, textStatus: .text, usedOCR: false)
        return ImportItem(file: file, recognition: ImportRecognition(kind: .evidence(.insuranceReceipt), confidence: .certain, reason: "test"),
                          title: name, groupKey: "Insurance receipt documents")
    }
}
