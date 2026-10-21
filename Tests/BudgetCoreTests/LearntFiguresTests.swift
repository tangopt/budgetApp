import XCTest
import GRDB
@testable import BudgetCore

/// "Remember for this issuer": a corrected figure, ticked, teaches where it sits on the issuer's
/// layout (a label and which occurrence of it, never the value); the next document of the
/// issuer is read there, and when the label is gone the built-in reading stays and says so.
/// Synthetic data only (NIF 503504564 is made up).
final class LearntFiguresTests: XCTestCase {
    private var manager: DatabaseManager!
    private var db: DatabaseQueue { manager.dbQueue }
    private var folder: URL!
    private var library: EvidenceLibrary!
    private var pipeline: ImportPipeline!
    private var applier: ImportApplier!
    private var accountId: Int64!
    private var batchId: Int64!
    private var propertyId: Int64!
    private var utilitiesId: Int64!

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
            var property = Property(name: "Property A", country: "PT")
            try Properties.save(db: db, &property)
            propertyId = property.id!
            try Properties.setAccount(db: db, propertyId: propertyId, accountId: accountId, role: .current)
            var group = CategoryGroup(name: "Property A")
            try group.insert(db)
            try Properties.addCategoryGroup(db: db, propertyId: propertyId, categoryGroupId: group.id!)
            var utilities = Category(name: "Electricity", type: .expense, groupId: group.id)
            try utilities.insert(db)
            utilitiesId = utilities.id!
            var power = UtilityProvider(propertyId: propertyId, name: "Demo Power", kind: .electricity,
                                        bankDescriptionPattern: "DEMO PWR", invoiceRules: Self.powerRules)
            try Recharges.saveProvider(db: db, &power)
        }
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("LearntFiguresTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        library = EvidenceLibrary(root: folder.appendingPathComponent("Library", isDirectory: true), database: db)
        pipeline = ImportPipeline(dbQueue: db, library: library, categorizationService: CategorizationService(categorizer: FakeCategorizer()))
        applier = ImportApplier(dbQueue: db, databasePath: nil, library: library)
    }

    override func tearDownWithError() throws {
        pipeline.discardPlanningCopy()
        try? FileManager.default.removeItem(at: folder)
    }

    // MARK: Helpers

    private static let issuerLine = "Example Seguros, S.A. NIF 503504564"
    private static let issuerKey = "nif:503504564"

    private static let powerRules = UtilityInvoiceRules(
        textMarkers: ["DEMO POWER"], fileNameMarkers: ["LUZ"],
        invoiceNumberPatterns: [#"INVOICE NO\.?\s*(FT \d+/\d+)"#],
        issueDateLabels: ["ISSUED ON"], periodLabels: ["BILLING PERIOD:"],
        amountLabels: ["AMOUNT DUE"], refundLabels: ["AMOUNT TO REFUND"])

    private func pdf(_ name: String, _ lines: [String]) throws -> URL {
        let made = EvidenceTestPDFs.textPDF(lines, name: name)
        let directory = folder.appendingPathComponent("Drop-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try FileManager.default.moveItem(at: made, to: url)
        return url
    }

    /// An insurance receipt: the built-in reading takes the TOTAL; the premium due sits after "Valor a pagar".
    private func receipt(_ name: String, date: String, due: String, total: String, label: String = "Valor a pagar") throws -> URL {
        try pdf(name, [Self.issuerLine, "SEGURO MULTI-RISCO HABITACAO", "Data: \(date)", "\(label): \(due) €", "TOTAL \(total) €"])
    }

    private static func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        MonthRange.calendar.date(from: DateComponents(year: y, month: m, day: d))!
    }

    @discardableResult
    private func transaction(_ date: Date, _ amount: Int, _ text: String, categoryId: Int64? = nil) throws -> Int64 {
        try db.write { db in
            var transaction = Transaction(importBatchId: batchId, accountId: accountId, date: date, rawDescription: text,
                                          amountMinorUnits: amount, categoryId: categoryId, status: .confirmed, categorizedBy: .manual,
                                          fingerprint: UUID().uuidString)
            try transaction.insert(db)
            return transaction.id!
        }
    }

    private func only(_ plan: ImportPlan) throws -> ImportItem {
        let top = plan.items.filter { $0.parentId == nil }
        XCTAssertEqual(top.count, 1, "\(top.map(\.file.fileName))")
        return try XCTUnwrap(top.first)
    }

    private func rules() throws -> [ImportRule] { try db.read { db in try ImportRuleStore.all(db: db) } }

    private func fact(_ item: ImportItem, _ field: ImportFigureField) -> ImportFact? {
        item.facts.first { $0.field == field }
    }

    @discardableResult
    private func learnPosition(_ field: ImportFigureField, label: String, occurrence: Int = 0, key: String = issuerKey,
                               enabled: Bool = true) throws -> ImportRule {
        try db.write { db in
            var rule = try ImportRuleStore.learn(db: db, kind: .figurePosition, key: "\(key)#\(field.rawValue)",
                                                 matchLabel: "Example Seguros, S.A.",
                                                 action: FigurePositionAction(field: field, label: label, occurrence: occurrence),
                                                 actionLabel: "\(field.displayName): after “\(label)”", now: Date())
            if !enabled {
                rule.isEnabled = false
                try rule.update(db)
            }
            return rule
        }
    }

    // MARK: Finding and reading a position

    func testLabelBeforeAmount() {
        let text = "Example Seguros\nValor a pagar: 42,10 €\nTOTAL 120,00 €"
        let found = LearntFigures.label(for: .money(4210, .eur), field: .amount, in: text)
        XCTAssertEqual(found?.label, "Valor a pagar")
        XCTAssertEqual(found?.occurrence, 0)
    }

    func testSecondOccurrence() {
        let text = "Total: 10,00 €\nIVA 2,30 €\nTotal: 12,30 €"
        let found = LearntFigures.label(for: .money(1230, .eur), field: .amount, in: text)
        XCTAssertEqual(found?.label, "Total")
        XCTAssertEqual(found?.occurrence, 1)
        let action = FigurePositionAction(field: .amount, label: "Total", occurrence: 1)
        XCTAssertEqual(LearntFigures.read(action, field: .amount, in: "Total: 20,00 €\nIVA 4,60 €\nTotal: 24,60 €"), .money(2460, .eur))
    }

    func testLabelForADateAndItsForms() {
        let day = Self.date(2024, 3, 5)
        XCTAssertEqual(LearntFigures.label(for: .date(day), field: .docDate, in: "Ref 12\nData de emissão 05/03/2024")?.label, "Data de emissão")
        XCTAssertEqual(LearntFigures.label(for: .date(day), field: .docDate, in: "Issued on: 2024-03-05")?.label, "Issued on")
        XCTAssertEqual(LearntFigures.label(for: .money(123_456, .eur), field: .amount, in: "Amount due 1.234,56 EUR")?.label, "Amount due")
        XCTAssertEqual(LearntFigures.label(for: .money(123_456, .gbp), field: .amount, in: "Balance £1,234.56")?.label, "Balance")
        let action = FigurePositionAction(field: .docDate, label: "Data de emissao", occurrence: 0)
        XCTAssertEqual(LearntFigures.read(action, field: .docDate, in: "DATA DE EMISSÃO\n 06.04.2024"), .date(Self.date(2024, 4, 6)),
                       "case, accents and a line break between label and value don't matter")
    }

    func testNoLabelWhenTheValueIsAbsentOrUnlabelled() {
        XCTAssertNil(LearntFigures.label(for: .money(4210, .eur), field: .amount, in: "Total 142,10 €"), "part of another number")
        XCTAssertNil(LearntFigures.label(for: .money(4210, .eur), field: .amount, in: "Header\n42,10 €"), "no words before it")
        XCTAssertNil(LearntFigures.label(for: .text("FT 1"), field: .invoiceNumber, in: "Invoice FT 1"), "only money and dates")
    }

    func testALabelThatReadsAnotherNumberIsNotLearnt() {
        XCTAssertNil(LearntFigures.label(for: .money(4210, .eur), field: .amount, in: "IVA 23% 9,66 42,10"),
                     "after “IVA” the first amount is 9,66: the position wouldn't read the figure again")
    }

    func testThousandsAreGrouped() {
        let found = LearntFigures.label(for: .money(104_210, .eur), field: .amount, in: "Subtotal 900,00\nTotal a pagar 1.042,10 €")
        XCTAssertEqual(found?.label, "Total a pagar")
        XCTAssertEqual(found?.occurrence, 0)
        XCTAssertEqual(LearntFigures.label(for: .money(104_210, .gbp), field: .amount, in: "Balance due £1,042.10")?.label, "Balance due")
        XCTAssertEqual(LearntFigures.label(for: .money(104_210, .eur), field: .amount, in: "Total 1042,10")?.label, "Total")
    }

    // MARK: Learning and reading

    func testReadUsesLearntPositionOverBuiltIn() async throws {
        var plan = try await pipeline.plan([try receipt("receipt-1.pdf", date: "05/03/2024", due: "42,10", total: "120,00")])
        let first = try only(plan)
        XCTAssertEqual(first.recognition.kind, .evidence(.insuranceReceipt))
        XCTAssertEqual(fact(first, .amount)?.value, .money(12_000, .eur), "the built-in reading takes the total")

        plan = try await pipeline.resolve(plan, itemId: first.id, .confirmFigureRemembering(.amount, .money(4210, .eur)))
        let corrected = try only(plan)
        XCTAssertEqual(fact(corrected, .amount)?.value, .money(4210, .eur))
        XCTAssertEqual(fact(corrected, .amount)?.source, .user)
        XCTAssertEqual(corrected.ruleDrafts.map(\.kind), [.figurePosition])
        XCTAssertEqual(corrected.ruleDrafts.first?.key, "\(Self.issuerKey)#amount")
        XCTAssertEqual(corrected.ruleDrafts.first?.actionLabel, "Amount: after “Valor a pagar”")
        XCTAssertEqual(try rules().count, 0, "nothing is learnt before Confirm import")
        _ = try applier.apply(plan, entryPoint: "Test")
        let learnt = try XCTUnwrap(try rules().first)
        XCTAssertEqual(learnt.kind, .figurePosition)
        XCTAssertEqual(ImportLearning.decode(FigurePositionAction.self, learnt.actionJSON),
                       FigurePositionAction(field: .amount, label: "Valor a pagar", occurrence: 0))
        pipeline.discardPlanningCopy()

        plan = try await pipeline.plan([try receipt("receipt-2.pdf", date: "05/04/2024", due: "55,20", total: "130,00")])
        let next = try only(plan)
        let amount = try XCTUnwrap(fact(next, .amount))
        XCTAssertEqual(amount.value, .money(5520, .eur))
        XCTAssertEqual(amount.source, .learntRule)
        XCTAssertEqual(amount.confidence, .certain)
        XCTAssertEqual(amount.reason, "Learnt position: after “Valor a pagar”")
        XCTAssertEqual(next.appliedRules.map(\.ruleId), [learnt.id!])
        XCTAssertEqual(next.appliedRules.first?.kind, .figurePosition)
        XCTAssertEqual(next.placement?.metadata.amountMinorUnits, 5520, "the document is filed with the learnt figure")
        XCTAssertEqual(next.section, .ready, "\(next.needsYouReasons)")

        _ = try applier.apply(plan, entryPoint: "Test")
        XCTAssertEqual(try rules().first?.useCount, 1, "marked used on Confirm import")
    }

    func testMissingLabelFallsBackAndSaysSo() async throws {
        try learnPosition(.amount, label: "Valor a pagar")
        let plan = try await pipeline.plan([try receipt("receipt.pdf", date: "05/03/2024", due: "42,10", total: "120,00",
                                                        label: "Premio liquido")])
        let item = try only(plan)
        let amount = try XCTUnwrap(fact(item, .amount))
        XCTAssertEqual(amount.value, .money(12_000, .eur), "the built-in reading stays")
        XCTAssertEqual(amount.source, .textLayer)
        XCTAssertEqual(amount.confidence, .needsReview)
        XCTAssertEqual(amount.reason, "Learnt position not found (after “Valor a pagar”)")
        XCTAssertEqual(item.section, .needsYou)
        XCTAssertTrue(item.needsYouReasons.contains("Learnt position not found (after “Valor a pagar”)"), "\(item.needsYouReasons)")
        XCTAssertTrue(item.appliedRules.isEmpty, "a rule that read nothing wasn't used")
    }

    func testValueIsNeverLearnt() async throws {
        var plan = try await pipeline.plan([try receipt("receipt.pdf", date: "05/03/2024", due: "42,10", total: "120,00")])
        plan = try await pipeline.resolve(plan, itemId: try only(plan).id, .confirmFigureRemembering(.amount, .money(4210, .eur)))
        _ = try applier.apply(plan, entryPoint: "Test")
        let rule = try XCTUnwrap(try rules().first)
        for value in ["4210", "42,10", "42.10"] {
            XCTAssertFalse(rule.actionJSON.contains(value), rule.actionJSON)
            XCTAssertFalse(rule.actionLabel.contains(value), rule.actionLabel)
            XCTAssertFalse(rule.matchKey.contains(value), rule.matchKey)
        }
    }

    func testAPlainConfirmClearsTheNotPlacedNote() async throws {
        var plan = try await pipeline.plan([try receipt("receipt.pdf", date: "05/03/2024", due: "42,10", total: "120,00")])
        let id = try only(plan).id
        plan = try await pipeline.resolve(plan, itemId: id, .confirmFigureRemembering(.amount, .money(9999, .eur)))
        XCTAssertTrue(try only(plan).notes.contains(LearntFigures.notPlacedNote))
        plan = try await pipeline.resolve(plan, itemId: id, .confirmFigure(.amount, .money(9999, .eur)))
        XCTAssertFalse(try only(plan).notes.contains(LearntFigures.notPlacedNote))
    }

    func testWithoutAnIssuerTheFigureIsFixedForThisDocumentOnly() async throws {
        var plan = try await pipeline.plan([try pdf("receipt.pdf", ["RECIBO", "Total seguro multi-risco habitacao", "Data: 05/03/2024",
                                                                     "Total a pagar: 42,10 €", "TOTAL 120,00 €"])])
        let item = try only(plan)
        plan = try await pipeline.resolve(plan, itemId: item.id, .confirmFigureRemembering(.amount, .money(4210, .eur)))
        let fixed = try only(plan)
        XCTAssertTrue(fixed.ruleDrafts.isEmpty)
        XCTAssertTrue(fixed.notes.contains(LearntFigures.noIssuerNote), "\(fixed.notes)")
        XCTAssertFalse(fixed.notes.contains(LearntFigures.notPlacedNote))
    }

    func testOnlyEvidenceInvoicesAndPayrollFormsLearnPositions() {
        let file = file([Self.issuerLine, "Valor a pagar: 42,10 €"].joined(separator: "\n"))
        let issuer = IssuerKey(key: Self.issuerKey, label: "Example Seguros, S.A.")
        func drafts(_ kind: ImportKind) -> [ImportRuleDraft] {
            let item = ImportItem(file: file, recognition: ImportRecognition(kind: kind, confidence: .certain, reason: "test"), title: "x")
            return ImportLearning.drafts(for: item, resolution: .confirmFigureRemembering(.amount, .money(4210, .eur)), issuer: issuer)
        }
        XCTAssertEqual(drafts(.evidence(.insuranceReceipt)).count, 1)
        XCTAssertEqual(drafts(.utilityInvoice).count, 1)
        XCTAssertEqual(drafts(.payrollForm(.p60)).count, 1)
        XCTAssertTrue(drafts(.rentReceiptPDF).isEmpty)
        XCTAssertTrue(drafts(.transferAdvice).isEmpty)
        XCTAssertTrue(drafts(.bankStatementPDF).isEmpty)
    }

    func testMarkingAVanishedRuleUsedIsHarmless() throws {
        let rule = try learnPosition(.amount, label: "Valor a pagar")
        try db.write { db in
            _ = try ImportRule.deleteOne(db, key: rule.id!)
            try ImportRuleStore.markUsed(db: db, ids: [rule.id!], now: Date())
        }
        XCTAssertTrue(try rules().isEmpty)
    }

    func testPlainConfirmTeachesNothingAndAnUnlabelledFigureIsFixedForThisDocumentOnly() async throws {
        var plan = try await pipeline.plan([try receipt("receipt.pdf", date: "05/03/2024", due: "42,10", total: "120,00")])
        let id = try only(plan).id
        plan = try await pipeline.resolve(plan, itemId: id, .confirmFigure(.amount, .money(4210, .eur)))
        XCTAssertTrue(try only(plan).ruleDrafts.isEmpty, "only a ticked figure is remembered")

        plan = try await pipeline.resolve(plan, itemId: id, .confirmFigureRemembering(.amount, .money(9999, .eur)))
        let item = try only(plan)
        XCTAssertEqual(fact(item, .amount)?.value, .money(9999, .eur), "still fixed for this document")
        XCTAssertTrue(item.ruleDrafts.isEmpty)
        XCTAssertTrue(item.notes.contains("Couldn't find where this figure sits: it is fixed for this document only"), "\(item.notes)")

        plan = try await pipeline.resolve(plan, itemId: id, .confirmFigureRemembering(.amount, .money(4210, .eur)))
        let found = try only(plan)
        XCTAssertEqual(found.ruleDrafts.map(\.kind), [.figurePosition])
        XCTAssertFalse(found.notes.contains("Couldn't find where this figure sits: it is fixed for this document only"))
        plan = try await pipeline.resolve(plan, itemId: id, .confirmFigure(.amount, .money(4210, .eur)))
        XCTAssertTrue(try only(plan).ruleDrafts.isEmpty, "the figure changed again without the tick: nothing to remember")
    }

    func testDisabledRuleIsIgnored() async throws {
        try learnPosition(.amount, label: "Valor a pagar", enabled: false)
        let plan = try await pipeline.plan([try receipt("receipt.pdf", date: "05/03/2024", due: "42,10", total: "120,00")])
        let item = try only(plan)
        XCTAssertEqual(fact(item, .amount)?.value, .money(12_000, .eur))
        XCTAssertEqual(fact(item, .amount)?.confidence, .certain)
        XCTAssertTrue(item.appliedRules.isEmpty)
    }

    func testAnotherIssuersRuleIsIgnored() async throws {
        try learnPosition(.amount, label: "Valor a pagar", key: "nif:501964843")
        let plan = try await pipeline.plan([try receipt("receipt.pdf", date: "05/03/2024", due: "42,10", total: "120,00")])
        XCTAssertEqual(fact(try only(plan), .amount)?.value, .money(12_000, .eur))
    }

    func testCorrectingALearntFigureOverridesItsRule() async throws {
        try learnPosition(.amount, label: "Valor a pagar")
        var plan = try await pipeline.plan([try receipt("receipt.pdf", date: "05/03/2024", due: "42,10", total: "120,00")])
        let item = try only(plan)
        XCTAssertEqual(fact(item, .amount)?.value, .money(4210, .eur))
        XCTAssertEqual(item.appliedRules.map(\.kind), [.figurePosition])
        plan = try await pipeline.resolve(plan, itemId: item.id, .confirmFigure(.amount, .money(12_000, .eur)))
        XCTAssertTrue(try only(plan).appliedRules.isEmpty, "a learnt figure the user corrected wasn't used")
    }

    func testARereadDropsAPositionDraftWhoseFigureItLostAndKeepsAnOverriddenRuleOff() async throws {
        var plan = try await pipeline.plan([try receipt("receipt.pdf", date: "05/03/2024", due: "42,10", total: "120,00")])
        let id = try only(plan).id
        plan = try await pipeline.resolve(plan, itemId: id, .confirmFigureRemembering(.amount, .money(4210, .eur)))
        XCTAssertEqual(try only(plan).ruleDrafts.map(\.kind), [.figurePosition])
        plan = try await pipeline.resolve(plan, itemId: id, .chooseKind(.insuranceReceipt))
        XCTAssertEqual(fact(try only(plan), .amount)?.source, .textLayer, "read again: the typed figure is gone")
        XCTAssertEqual(try only(plan).ruleDrafts.map(\.kind), [], "so is the position it would teach (and the app reads the kind itself)")

        try learnPosition(.amount, label: "Valor a pagar")
        pipeline.discardPlanningCopy()
        plan = try await pipeline.plan([try receipt("receipt-2.pdf", date: "05/04/2024", due: "42,10", total: "120,00")])
        let learnt = try only(plan)
        XCTAssertEqual(fact(learnt, .amount)?.source, .learntRule)
        plan = try await pipeline.resolve(plan, itemId: learnt.id, .confirmFigure(.amount, .money(12_000, .eur)))
        plan = try await pipeline.resolve(plan, itemId: learnt.id, .chooseKind(.insuranceReceipt))
        let reread = try only(plan)
        XCTAssertEqual(fact(reread, .amount)?.value, .money(12_000, .eur), "the overridden position isn't read again")
        XCTAssertEqual(fact(reread, .amount)?.confidence, .certain)
        XCTAssertTrue(reread.appliedRules.isEmpty)
    }

    func testAKindChangeClearsTheFixedForThisDocumentNotes() async throws {
        var plan = try await pipeline.plan([try receipt("receipt.pdf", date: "05/03/2024", due: "42,10", total: "120,00")])
        let id = try only(plan).id
        plan = try await pipeline.resolve(plan, itemId: id, .confirmFigureRemembering(.amount, .money(9999, .eur)))
        XCTAssertTrue(try only(plan).notes.contains(LearntFigures.notPlacedNote))
        plan = try await pipeline.resolve(plan, itemId: id, .chooseKind(.insurancePolicy))
        let notes = try only(plan).notes
        XCTAssertTrue(notes.filter(LearntFigures.fixedNotes.contains).isEmpty, "\(notes)")
    }

    func testRememberingIsOfferedOnlyWhereAPositionCanBeLearnt() {
        let issuer = IssuerKey(key: Self.issuerKey, label: "Example Seguros, S.A.")
        func item(_ kind: ImportKind, facts: [ImportFact] = []) -> ImportItem {
            ImportItem(file: file("x"), recognition: ImportRecognition(kind: kind, confidence: .certain, reason: "test"), title: "x", facts: facts)
        }
        let receipt = item(.evidence(.insuranceReceipt))
        XCTAssertTrue(LearntFigures.offersRemembering(receipt, field: .amount, issuer: issuer))
        XCTAssertTrue(LearntFigures.offersRemembering(receipt, field: .docDate, issuer: issuer))
        XCTAssertFalse(LearntFigures.offersRemembering(receipt, field: .amount, issuer: nil), "no issuer key")
        XCTAssertFalse(LearntFigures.offersRemembering(receipt, field: .reference, issuer: issuer), "not money or a date")
        XCTAssertFalse(LearntFigures.offersRemembering(receipt, field: .issuer, issuer: issuer))
        XCTAssertFalse(LearntFigures.offersRemembering(item(.rentReceiptPDF), field: .amount, issuer: issuer))
        XCTAssertTrue(LearntFigures.offersRemembering(item(.utilityInvoice), field: .amount, issuer: issuer))
        // A payroll form's positions only fill a figure its reader didn't find.
        let read = ImportFact(field: .pay, value: .money(100, .gbp), source: .textLayer, confidence: .certain, reason: "read")
        XCTAssertFalse(LearntFigures.offersRemembering(item(.payrollForm(.p60), facts: [read]), field: .pay, issuer: issuer))
        let ocr = ImportFact(field: .pay, value: .money(100, .gbp), source: .ocr, confidence: .needsReview, reason: "read")
        XCTAssertFalse(LearntFigures.offersRemembering(item(.payrollForm(.p60), facts: [ocr]), field: .pay, issuer: issuer))
        XCTAssertTrue(LearntFigures.offersRemembering(item(.payrollForm(.p60)), field: .pay, issuer: issuer), "missing")
        let learnt = ImportFact(field: .pay, value: .money(100, .gbp), source: .learntRule, confidence: .certain, reason: "learnt")
        XCTAssertTrue(LearntFigures.offersRemembering(item(.payrollForm(.p60), facts: [learnt]), field: .pay, issuer: issuer))
    }

    // MARK: Readers

    private func file(_ text: String, usedOCR: Bool = false) -> ImportFile {
        ImportFile(url: folder.appendingPathComponent("scan.pdf"), fileName: "scan.pdf", sha256: UUID().uuidString, byteCount: 1,
                   fileExtension: "pdf", text: text, textStatus: usedOCR ? .image : .text, usedOCR: usedOCR)
    }

    private func context() throws -> ImportContext {
        try db.read { try ImportContext.load(db: $0, intent: .none, now: Self.date(2024, 6, 1)) }
    }

    func testAScannedFileReadAtALearntPositionNeedsReview() throws {
        try learnPosition(.amount, label: "Valor a pagar")
        let text = [Self.issuerLine, "SEGURO MULTI-RISCO HABITACAO", "Data: 05/03/2024", "Valor a pagar: 42,10 €", "TOTAL 120,00 €"]
            .joined(separator: "\n")
        let context = try context()
        let item = try XCTUnwrap(try db.read { db in
            try EvidenceDocumentReader().propose([(file(text, usedOCR: true), ImportRecognition(kind: .evidence(.insuranceReceipt),
                                                                                              confidence: .certain, reason: "test"))],
                                                 context: context, db: db)
        }.first)
        let amount = try XCTUnwrap(fact(item, .amount))
        XCTAssertEqual(amount.value, .money(4210, .eur))
        XCTAssertEqual(amount.source, .learntRule)
        XCTAssertEqual(amount.confidence, .needsReview, "never certain from text recognition")
        XCTAssertEqual(item.section, .needsYou)
    }

    func testAFigureLearntOnALineKeyNeedsReview() throws {
        try learnPosition(.amount, label: "Valor a pagar", key: "line:EXAMPLE LETTERS LDA")
        let text = ["Example Letters Lda", "SEGURO MULTI-RISCO HABITACAO", "Data: 05/03/2024", "Valor a pagar: 42,10 €", "TOTAL 120,00 €"]
            .joined(separator: "\n")
        let context = try context()
        let item = try XCTUnwrap(try db.read { db in
            try EvidenceDocumentReader().propose([(file(text), ImportRecognition(kind: .evidence(.insuranceReceipt), confidence: .certain, reason: "test"))],
                                                 context: context, db: db)
        }.first)
        let amount = try XCTUnwrap(fact(item, .amount))
        XCTAssertEqual(amount.value, .money(4210, .eur))
        XCTAssertEqual(amount.source, .learntRule)
        XCTAssertEqual(amount.confidence, .needsReview, "a first line never makes a figure certain")
        XCTAssertTrue(amount.reason.contains("Learnt from the first line “Example Seguros, S.A.”: check it"), amount.reason)
        XCTAssertEqual(item.section, .needsYou)
    }

    func testALearntInvoiceAmountRecordsAndLinksTheInvoice() throws {
        // The invoice's built-in reading takes "Amount due"; this issuer's real figure sits after "Total to pay".
        try learnPosition(.amount, label: "Total to pay", key: "nif:503504564")
        let debit = try transaction(Self.date(2023, 3, 20), -8_000, "DEMO PWR DD 123", categoryId: utilitiesId)
        let text = ["Demo Power, S.A. NIF 503504564", "Issued on: 5 de março 2023",
                    "Billing period: 1 de janeiro a 28 de fevereiro 2023", "Amount due 100,00 EUR", "Total to pay 80,00 EUR",
                    "Invoice no. FT 1/23"].joined(separator: "\n")
        let context = try context()
        let item = try XCTUnwrap(try db.read { db in
            try UtilityInvoiceImportReader().propose([(file(text), ImportRecognition(kind: .utilityInvoice, confidence: .certain, reason: "test"))],
                                                     context: context, db: db)
        }.first)
        XCTAssertEqual(fact(item, .amount)?.value, .money(8_000, .eur))
        XCTAssertEqual(fact(item, .amount)?.source, .learntRule)
        guard case .utilityInvoice(let invoice) = item.effect else { return XCTFail("effect \(item.effect)") }
        XCTAssertEqual(invoice.amountMinorUnits, 8_000, "the invoice is recorded with the learnt figure")
        XCTAssertEqual(invoice.transactionId, debit, "and matched to the debit of that figure")
        XCTAssertEqual(item.links.map(\.entity), [.transaction(debit)])
        XCTAssertEqual(item.section, .ready, "\(item.needsYouReasons)")
    }

    func testACreditNoteKeepsItsSign() throws {
        try learnPosition(.amount, label: "Refund total")
        let text = [Self.issuerLine, "Refund total 25,00 €"].joined(separator: "\n")
        var item = ImportItem(file: file(text), recognition: ImportRecognition(kind: .evidence(.other), confidence: .certain, reason: "test"),
                              title: "Credit note",
                              facts: [ImportFact(field: .amount, value: .money(-3_000, .eur), source: .textLayer, confidence: .certain, reason: "Refund")])
        let context = try context()
        LearntFigures.apply(to: &item, readings: LearntFigures.readings(item.file, context: context))
        XCTAssertEqual(fact(item, .amount)?.value, .money(-2_500, .eur))
    }

    func testRentReceiptsAndTransferAdvicesAreNotReadAtLearntPositions() throws {
        try learnPosition(.amount, label: "Valor a pagar")
        let text = [Self.issuerLine, "Valor a pagar: 42,10 €"].joined(separator: "\n")
        let context = try context()
        let receipt = try XCTUnwrap(try db.read { db in
            try RentReceiptPDFReader().propose([(file(text), ImportRecognition(kind: .rentReceiptPDF, confidence: .certain, reason: "test"))],
                                               context: context, db: db)
        }.first)
        XCTAssertFalse(receipt.facts.contains { $0.source == .learntRule })
        XCTAssertTrue(receipt.appliedRules.isEmpty)
        let advice = try XCTUnwrap(try db.read { db in
            try TransferAdviceReader().propose([(file(text), ImportRecognition(kind: .transferAdvice, confidence: .certain, reason: "test"))],
                                               context: context, db: db)
        }.first)
        XCTAssertFalse(advice.facts.contains { $0.source == .learntRule })
        XCTAssertTrue(advice.appliedRules.isEmpty)
    }

    private static let employerLine = "Acme Trading Ltd"
    private static let employerKey = "line:ACME TRADING LTD"

    private func p60(_ extraction: PayrollFormExtraction, text: String) -> (file: ImportFile, recognition: ImportRecognition) {
        var file = file(text)
        file.payrollExtraction = extraction
        return (file, ImportRecognition(kind: .payrollForm(.p60), confidence: .certain, reason: "test"))
    }

    func testAPayrollFormKeepsItsReadingAndFillsOnlyWhatItMissed() throws {
        try learnPosition(.pay, label: "Pay in this employment", key: Self.employerKey)
        try learnPosition(.taxDeducted, label: "Tax deducted", key: Self.employerKey)
        try learnPosition(.docDate, label: "Leaving date", key: Self.employerKey)
        let text = [Self.employerLine, "P60 End of Year Certificate", "Pay in this employment 41.000,00", "Tax deducted 6.000,00"]
            .joined(separator: "\n")
        let extraction = PayrollFormExtraction(kind: .p60, entryMethod: .textLayer, startYear: 2024, employerName: "Acme Trading Ltd",
                                               payMinorUnits: 4_000_000, warnings: ["No pay and tax figures found."])
        let context = try context()
        let item = try XCTUnwrap(try db.read { db in try PayrollFormImportReader().propose([p60(extraction, text: text)], context: context, db: db) }.first)
        XCTAssertEqual(fact(item, .pay)?.value, .money(4_000_000, .gbp), "the form's own reading stays")
        XCTAssertEqual(fact(item, .pay)?.source, .textLayer)
        XCTAssertEqual(fact(item, .pay)?.confidence, .certain)
        let tax = try XCTUnwrap(fact(item, .taxDeducted))
        XCTAssertEqual(tax.value, .money(600_000, .gbp))
        XCTAssertEqual(tax.source, .learntRule)
        XCTAssertFalse(item.issues.contains { $0.kind == .missingFigure(.taxDeducted) || $0.kind == .missingFigure(.pay) }, "\(item.issues)")
        XCTAssertEqual(item.appliedRules.count, 1, "only the rule that filled a figure")
        XCTAssertFalse(item.notes.contains { $0.hasPrefix("Learnt position not found") }, "a label not found says nothing on a form")
        XCTAssertFalse(item.facts.contains { $0.reason.hasPrefix("Learnt position not found") })
    }

    func testALearntFigureOnAFiledYearIsHeldByTheGuard() throws {
        try db.write { db in
            var person = Person(name: "Person A", shortName: "A", ukNino: "QQ 12 34 56 C")
            try People.save(db: db, &person)
            var year = TaxYear(startYear: 2024, personId: person.id!, status: .filed)
            try year.insert(db)
            var employment = Employment(startYear: 2024, personId: person.id!, employerName: "Acme Trading Ltd")
            try Employments.save(db: db, &employment)
            var income = EmploymentIncome(employmentId: employment.id!, source: .p60, payMinorUnits: 4_000_000, taxDeductedMinorUnits: 600_000)
            try Employments.save(db: db, &income)
        }
        try learnPosition(.pay, label: "Pay in this employment", key: Self.employerKey)
        let text = [Self.employerLine, "P60 End of Year Certificate", "Pay in this employment 41.000,00", "Tax deducted 6.000,00"]
            .joined(separator: "\n")
        let extraction = PayrollFormExtraction(kind: .p60, entryMethod: .textLayer, startYear: 2024, employerName: "Acme Trading Ltd",
                                               nationalInsuranceNumber: "QQ123456C", taxDeductedMinorUnits: 600_000)
        let context = try context()
        let held = try db.write { db -> ImportItem in
            let read = try XCTUnwrap(try PayrollFormImportReader().propose([p60(extraction, text: text)], context: context, db: db).first)
            return try XCTUnwrap(try FiledYearGuard.annotate([read], db: db).first)
        }
        XCTAssertEqual(fact(held, .pay)?.source, .learntRule)
        guard case .payrollForm(let confirmed) = held.effect else { return XCTFail("effect \(held.effect)") }
        XCTAssertEqual(confirmed.payMinorUnits, 4_100_000, "the effect carries the learnt pay")
        XCTAssertTrue(held.isHeldByFiledYear, "the guard sees the learnt figure: \(held.issues)")
    }
}
