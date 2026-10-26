import XCTest
import GRDB
@testable import BudgetCore
import TestSupport

/// Corrections made in the review become learnt rules on Confirm import (inside the run, undone
/// with it): a document's kind, its issuer's name and where its documents link. The next import
/// applies them, naming the rule on the item. Synthetic data only (NIF 503504564 is made up).
final class ImportLearningTests: XCTestCase {
    private var manager: DatabaseManager!
    private var db: DatabaseQueue { manager.dbQueue }
    private var folder: URL!
    private var library: EvidenceLibrary!
    private var pipeline: ImportPipeline!
    private var applier: ImportApplier!
    private var accountId: Int64!
    private var batchId: Int64!
    private var propertyId: Int64!

    override func setUpWithError() throws {
        manager = try TestDatabase.migratedManager()
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
        }
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("ImportLearningTests-\(UUID().uuidString)", isDirectory: true)
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

    private func pdf(_ name: String, _ lines: [String]) throws -> URL {
        let made = EvidenceTestPDFs.textPDF(lines, name: name)
        let directory = folder.appendingPathComponent("Drop-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try FileManager.default.moveItem(at: made, to: url)
        return url
    }

    /// A letter nothing built in recognises.
    private func letter(_ name: String, day: String) throws -> URL {
        try pdf(name, [Self.issuerLine, "Rua Exemplo 1, Lisboa", "Assunto: comunicacao \(day)", "Caro senhor, segue a informacao pedida."])
    }

    /// An insurance receipt of 120,00 € dated `date` (dd/MM/yyyy).
    private func receipt(_ name: String, date: String) throws -> URL {
        try pdf(name, [Self.issuerLine, "SEGURO MULTI-RISCO HABITACAO", "Data: \(date)", "TOTAL 120,00 €"])
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

    private func only(_ plan: ImportPlan) throws -> ImportItem {
        let top = plan.items.filter { $0.parentId == nil }
        XCTAssertEqual(top.count, 1, "\(top.map(\.file.fileName))")
        return try XCTUnwrap(top.first)
    }

    private func rules() throws -> [ImportRule] { try db.read { db in try ImportRuleStore.all(db: db) } }

    private func chooseLinkCandidates(_ item: ImportItem) -> [LinkCandidate] {
        item.issues.compactMap { issue -> [LinkCandidate]? in
            if case .chooseLink(let candidates) = issue.kind { return candidates }
            return nil
        }.first ?? []
    }

    private func learnKind(_ kind: DocumentKind, enabled: Bool = true) throws {
        try db.write { db in
            var rule = try ImportRuleStore.learn(db: db, kind: .documentKind, key: Self.issuerKey, matchLabel: "Example Seguros, S.A.",
                                                 action: DocumentKindAction(kind: kind), actionLabel: "Kind: \(kind.displayName)", now: Date())
            if !enabled {
                rule.isEnabled = false
                try rule.update(db)
            }
        }
    }

    // MARK: Document kind

    func testChoosingKindForUnknownDocumentLearnsAndAppliesNextTime() async throws {
        var plan = try await pipeline.plan([try letter("letter-1.pdf", day: "1")])
        let unknown = try only(plan)
        XCTAssertEqual(unknown.recognition.kind, .unknown)
        plan = try await pipeline.resolve(plan, itemId: unknown.id, .chooseKind(.insuranceReceipt))
        let chosen = try only(plan)
        XCTAssertEqual(chosen.recognition.kind, .evidence(.insuranceReceipt))
        XCTAssertEqual(chosen.section, .ready, "\(chosen.needsYouReasons)")
        XCTAssertEqual(chosen.ruleDrafts.map(\.kind), [.documentKind])
        XCTAssertEqual(chosen.ruleDrafts.first?.key, Self.issuerKey)
        XCTAssertEqual(chosen.ruleDrafts.first?.matchLabel, "Example Seguros, S.A.")
        XCTAssertEqual(try rules().count, 0, "nothing is learnt before Confirm import")

        _ = try applier.apply(plan, entryPoint: "Test")
        let learnt = try rules()
        XCTAssertEqual(learnt.map(\.kind), [.documentKind])
        XCTAssertEqual(learnt.first?.matchKey, Self.issuerKey)
        XCTAssertEqual(learnt.first?.actionJSON, "{\"kind\":\"insuranceReceipt\"}")
        XCTAssertEqual(learnt.first?.useCount, 0)
        pipeline.discardPlanningCopy()

        plan = try await pipeline.plan([try letter("letter-2.pdf", day: "2")])
        let next = try only(plan)
        XCTAssertEqual(next.recognition.kind, .evidence(.insuranceReceipt))
        XCTAssertEqual(next.recognition.confidence, .certain)
        XCTAssertEqual(next.recognition.reason, "Learnt: Example Seguros, S.A. → Insurance receipt")
        XCTAssertEqual(next.appliedRules.count, 1)
        XCTAssertEqual(next.appliedRules.first?.ruleId, learnt.first?.id)
        XCTAssertEqual(next.appliedRules.first?.kind, .documentKind)
        XCTAssertEqual(next.appliedRules.first?.label, "Learnt: Example Seguros, S.A. → Insurance receipt")
        XCTAssertEqual(next.section, .ready, "\(next.needsYouReasons)")
        XCTAssertTrue(next.ruleDrafts.isEmpty)

        _ = try applier.apply(plan, entryPoint: "Test")
        let used = try XCTUnwrap(try rules().first)
        XCTAssertEqual(used.useCount, 1, "marked used when applied")
        XCTAssertNotNil(used.lastUsedAt)
    }

    func testBuiltInRecognitionWinsOverLearntRule() async throws {
        let url = PayrollFormTestPDFs.textPDF(PayrollFormTestPDFs.p60RowLayout, name: "p60.pdf")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let file = try ImportFile.load(url, ocr: false)
        let issuer = try XCTUnwrap(IssuerKey.derive(text: file.text, fileName: file.fileName, ownNIFs: []), "the P60 has an issuer")
        _ = try await db.write { db in
            try ImportRuleStore.learn(db: db, kind: .documentKind, key: issuer.key, matchLabel: issuer.label,
                                      action: DocumentKindAction(kind: .other), actionLabel: "Kind: Other", now: Date())
        }
        let plan = try await pipeline.plan([url])
        let item = try only(plan)
        XCTAssertEqual(item.recognition.kind, .payrollForm(.p60))
        XCTAssertFalse(item.appliedRules.contains { $0.kind == .documentKind }, "\(item.appliedRules)")
    }

    func testDisabledRuleIsNotApplied() async throws {
        try learnKind(.insuranceReceipt, enabled: false)
        var plan = try await pipeline.plan([try letter("letter-1.pdf", day: "1")])
        var item = try only(plan)
        XCTAssertEqual(item.recognition.kind, .unknown)
        XCTAssertEqual(item.appliedRules, [])
        pipeline.discardPlanningCopy()

        // Re-enabled: applied again.
        try await db.write { db in try db.execute(sql: "UPDATE importRule SET isEnabled = 1") }
        plan = try await pipeline.plan([try letter("letter-2.pdf", day: "2")])
        item = try only(plan)
        XCTAssertEqual(item.recognition.kind, .evidence(.insuranceReceipt))
        XCTAssertEqual(item.appliedRules.count, 1)
    }

    func testDocumentWithoutIssuerDraftsNothing() async throws {
        var plan = try await pipeline.plan([try pdf("blank.pdf", ["12345"])])
        let unknown = try only(plan)
        plan = try await pipeline.resolve(plan, itemId: unknown.id, .chooseKind(.insuranceReceipt))
        XCTAssertEqual(try only(plan).recognition.kind, .evidence(.insuranceReceipt), "the correction still fixes this document")
        XCTAssertEqual(try only(plan).ruleDrafts, [])
    }

    // MARK: Issuer

    func testNamedIssuerIsLearntAndApplied() async throws {
        try learnKind(.insuranceReceipt)
        var plan = try await pipeline.plan([try letter("letter-1.pdf", day: "1")])
        var item = try only(plan)
        plan = try await pipeline.resolve(plan, itemId: item.id, .setIssuer("Seguradora Exemplo"))
        item = try only(plan)
        let fact = try XCTUnwrap(item.facts.first { $0.field == .issuer })
        XCTAssertEqual(fact.value, .text("Seguradora Exemplo"))
        XCTAssertEqual(fact.source, .user)
        XCTAssertEqual(item.ruleDrafts.map(\.kind), [.issuer])
        XCTAssertEqual(item.ruleDrafts.first?.actionJSON, "{\"name\":\"Seguradora Exemplo\"}")
        _ = try applier.apply(plan, entryPoint: "Test")
        XCTAssertEqual(Set(try rules().map(\.kind)), [.documentKind, .issuer])
        pipeline.discardPlanningCopy()

        plan = try await pipeline.plan([try letter("letter-2.pdf", day: "2")])
        item = try only(plan)
        let learnt = try XCTUnwrap(item.facts.first { $0.field == .issuer })
        XCTAssertEqual(learnt.value, .text("Seguradora Exemplo"))
        XCTAssertEqual(learnt.source, .learntRule)
        XCTAssertEqual(learnt.confidence, .certain)
        XCTAssertEqual(Set(item.appliedRules.map(\.kind)), [.documentKind, .issuer])
        XCTAssertEqual(item.section, .ready, "\(item.needsYouReasons)")
    }

    func testBlankIssuerNameIsRefused() async throws {
        let plan = try await pipeline.plan([try letter("letter-1.pdf", day: "1")])
        do {
            _ = try await pipeline.resolve(plan, itemId: try only(plan).id, .setIssuer("  "))
            XCTFail("a blank name is refused")
        } catch let error as ImportResolutionError {
            XCTAssertEqual(error, .notOffered(.setIssuer("  ")))
        }
    }

    func testAnIssuerCanBeNamedOnDocumentsButNotOnStatementsOrHeldItems() {
        func item(_ kind: ImportKind) -> ImportItem {
            let file = ImportFile(url: URL(fileURLWithPath: "/tmp/x.pdf"), fileName: "x.pdf", sha256: "x", byteCount: 1,
                                  fileExtension: "pdf", text: "x", textStatus: .text, usedOCR: false)
            return ImportItem(file: file, recognition: ImportRecognition(kind: kind, confidence: .certain, reason: "test"), title: "x")
        }
        XCTAssertTrue(ImportResolutions.takesIssuerName(item(.evidence(.insuranceReceipt))))
        XCTAssertTrue(ImportResolutions.takesIssuerName(item(.unknown)))
        XCTAssertFalse(ImportResolutions.takesIssuerName(item(.bankStatementCSV)))
        var out = item(.evidence(.insuranceReceipt))
        out.isLeftOut = true
        XCTAssertFalse(ImportResolutions.takesIssuerName(out))
    }

    func testAStatementTakesNoIssuerName() async throws {
        let url = folder.appendingPathComponent("statement-\(UUID().uuidString).csv")
        try "Date,Description,Amount\n01/03/2024,CORNER SHOP,-10.00\n".write(to: url, atomically: true, encoding: .utf8)
        let plan = try await pipeline.plan([url])
        let item = try only(plan)
        XCTAssertEqual(item.recognition.kind, .bankStatementCSV)
        do {
            _ = try await pipeline.resolve(plan, itemId: item.id, .setIssuer("Example Bank"))
            XCTFail("a statement takes no issuer name")
        } catch let error as ImportResolutionError {
            XCTAssertEqual(error, .notOffered(.setIssuer("Example Bank")))
        }
    }

    // MARK: Links

    func testChosenTransactionLinkIsLearntByMerchant() async throws {
        let april = try transaction(Self.date(2024, 4, 5), -12_000, "DEMO SEGUROS 77")
        var plan = try await pipeline.plan([try receipt("seguro-1.pdf", date: "10/03/2024")])
        var item = try only(plan)
        XCTAssertEqual(chooseLinkCandidates(item).map(\.entity), [.transaction(april)], "\(item.issues)")
        plan = try await pipeline.resolve(plan, itemId: item.id, .chooseLink(.transaction(april)))
        item = try only(plan)
        XCTAssertEqual(item.section, .ready, "\(item.needsYouReasons)")
        XCTAssertEqual(item.ruleDrafts.map(\.kind), [.link])
        XCTAssertEqual(item.ruleDrafts.first?.actionJSON, "{\"descriptionKey\":\"DEMO SEGUROS\",\"sourceAccountId\":\(accountId!)}")
        _ = try applier.apply(plan, entryPoint: "Test")
        XCTAssertEqual(try rules().map(\.kind), [.link])
        pipeline.discardPlanningCopy()

        // Next time: an amount-only candidate with the same merchant is the link.
        let october = try transaction(Self.date(2024, 10, 5), -12_000, "DEMO SEGUROS 78")
        plan = try await pipeline.plan([try receipt("seguro-2.pdf", date: "10/09/2024")])
        item = try only(plan)
        XCTAssertEqual(item.section, .ready, "\(item.needsYouReasons)")
        XCTAssertEqual(item.links.map(\.entity), [.transaction(october)])
        XCTAssertEqual(item.links.first?.confidence, .certain)
        XCTAssertTrue(item.links.first?.reasons.contains("Learnt: Example Seguros, S.A. is paid by “DEMO SEGUROS”") == true,
                      "\(item.links)")
        XCTAssertEqual(item.appliedRules.map(\.kind), [.link])
        XCTAssertFalse(item.links.first?.reasons.contains(ImportResolutions.chosenReasonText) == true, "the rule chose it, not the user")
        XCTAssertTrue(chooseLinkCandidates(item).isEmpty)
    }

    func testTwoLearntCandidatesStayNeedsYouWithTheLearntFirst() async throws {
        _ = try await db.write { db in
            try ImportRuleStore.learn(db: db, kind: .link, key: Self.issuerKey, matchLabel: "Example Seguros, S.A.",
                                      action: LinkAction(descriptionKey: "DEMO SEGUROS"), actionLabel: "Paid by “DEMO SEGUROS”", now: Date())
        }
        let other = try transaction(Self.date(2024, 3, 11), -12_000, "OTHER SHOP")
        let first = try transaction(Self.date(2024, 3, 12), -12_000, "DEMO SEGUROS 1")
        let second = try transaction(Self.date(2024, 3, 12), -12_000, "DEMO SEGUROS 2")
        let plan = try await pipeline.plan([try receipt("seguro.pdf", date: "10/03/2024")])
        let item = try only(plan)
        XCTAssertEqual(item.section, .needsYou)
        XCTAssertTrue(item.links.allSatisfy { $0.confidence == .needsReview }, "\(item.links)")
        let candidates = chooseLinkCandidates(item)
        XCTAssertEqual(Set(candidates.prefix(2).map(\.entity)), [.transaction(first), .transaction(second)], "\(candidates)")
        XCTAssertTrue(candidates.map(\.entity).contains(.transaction(other)))
        XCTAssertTrue(candidates[0].reasons.contains("Learnt: Example Seguros, S.A. is paid by “DEMO SEGUROS”"), "\(candidates[0])")
    }

    func testSeveralChosenTransactionsDraftNoLinkAndUnlinkDraftsNone() async throws {
        let a = try transaction(Self.date(2024, 4, 5), -6_000, "DEMO SEGUROS 1")
        let b = try transaction(Self.date(2024, 4, 6), -6_000, "DEMO SEGUROS 2")
        var plan = try await pipeline.plan([try receipt("seguro.pdf", date: "10/03/2024")])
        let id = try only(plan).id
        plan = try await pipeline.resolve(plan, itemId: id, .linkTransactions([a]))
        XCTAssertEqual(try only(plan).ruleDrafts.map(\.actionJSON), ["{\"descriptionKey\":\"DEMO SEGUROS\",\"sourceAccountId\":\(accountId!)}"])
        plan = try await pipeline.resolve(plan, itemId: id, .linkTransactions([a, b]))
        XCTAssertEqual(try only(plan).ruleDrafts, [], "a split payment isn't a pattern")
        plan = try await pipeline.resolve(plan, itemId: id, .linkTransactions([b]))
        XCTAssertEqual(try only(plan).ruleDrafts.count, 1)
        plan = try await pipeline.resolve(plan, itemId: id, .unlink(.transaction(b)))
        XCTAssertEqual(try only(plan).ruleDrafts, [])
    }

    func testLearntEntityLinkIsCertainAndMissingTargetIsSkipped() async throws {
        _ = try await db.write { db in
            try ImportRuleStore.learn(db: db, kind: .link, key: Self.issuerKey, matchLabel: "Example Seguros, S.A.",
                                      action: LinkAction(entity: .property(self.propertyId)), actionLabel: "Link to Property A", now: Date())
        }
        var plan = try await pipeline.plan([try receipt("seguro.pdf", date: "10/03/2024")])
        var item = try only(plan)
        let link = try XCTUnwrap(item.links.first { $0.entity == .property(propertyId) }, "\(item.links)")
        XCTAssertEqual(link.confidence, .certain)
        XCTAssertEqual(link.reasons, ["Learnt: Example Seguros, S.A. documents go to Property A"])
        XCTAssertEqual(item.appliedRules.map(\.kind), [.link])
        pipeline.discardPlanningCopy()

        try await db.write { db in try db.execute(sql: "UPDATE importRule SET actionJSON = ?", arguments: ["{\"entity\":{\"type\":\"property\",\"id\":9999}}"]) }
        plan = try await pipeline.plan([try receipt("seguro-b.pdf", date: "10/03/2024")])
        item = try only(plan)
        XCTAssertFalse(item.links.contains { $0.entity.type == .property }, "\(item.links)")
        XCTAssertEqual(item.appliedRules, [])
    }

    // MARK: Undo

    func testUndoRemovesRulesTheRunLearnt() async throws {
        var plan = try await pipeline.plan([try letter("letter-1.pdf", day: "1")])
        plan = try await pipeline.resolve(plan, itemId: try only(plan).id, .chooseKind(.insuranceReceipt))
        let summary = try applier.apply(plan, entryPoint: "Test")
        XCTAssertEqual(try rules().count, 1)
        _ = try ImportUndo.undo(dbQueue: db, library: library, runId: summary.runId)
        XCTAssertEqual(try rules().count, 0, "the learnt rule goes with the run")
    }

    func testUndoRestoresARuleTheRunChanged() async throws {
        try learnKind(.insurancePolicy)
        let before = try XCTUnwrap(try rules().first)
        // The rule recognises the letter as a policy; the user corrects it to a receipt.
        var plan = try await pipeline.plan([try letter("letter-1.pdf", day: "1")])
        XCTAssertEqual(try only(plan).recognition.kind, .evidence(.insurancePolicy))
        plan = try await pipeline.resolve(plan, itemId: try only(plan).id, .chooseKind(.insuranceReceipt))
        let summary = try applier.apply(plan, entryPoint: "Test")
        XCTAssertEqual(try rules().first?.actionJSON, "{\"kind\":\"insuranceReceipt\"}")
        _ = try ImportUndo.undo(dbQueue: db, library: library, runId: summary.runId)
        XCTAssertEqual(try rules(), [before], "the rule as it was before the run")
    }

    // MARK: Fix round 1

    private func learnMerchant() throws {
        try db.write { db in
            try ImportRuleStore.learn(db: db, kind: .link, key: Self.issuerKey, matchLabel: "Example Seguros, S.A.",
                                      action: LinkAction(descriptionKey: "DEMO SEGUROS"), actionLabel: "Paid by “DEMO SEGUROS”", now: Date())
        }
    }

    /// An insurance receipt read with `amount` (from `source`), asking which of `candidates` paid it.
    private func askingItem(_ candidates: [Int64], amount: ImportFactValue, source: ImportFactSource, usedOCR: Bool = false) -> ImportItem {
        let file = ImportFile(url: URL(fileURLWithPath: "/synthetic/seguro.pdf"), fileName: "seguro.pdf", sha256: "sha-seguro", byteCount: 1,
                              fileExtension: "pdf", text: Self.issuerLine + "\nSEGURO MULTI-RISCO HABITACAO\nTOTAL 120,00 €",
                              textStatus: .text, usedOCR: usedOCR)
        let offered = candidates.map { LinkCandidate(entity: .transaction($0), label: "Transaction \($0)", reasons: ["Amount €120.00"]) }
        return ImportItem(file: file, recognition: ImportRecognition(kind: .evidence(.insuranceReceipt), confidence: .certain, reason: "test"),
                          title: "Insurance receipt",
                          facts: [ImportFact(field: .amount, value: amount, source: source, confidence: .certain, reason: "Amount on the document")],
                          issues: [ImportIssue(id: "chooseLink", kind: .chooseLink(offered), reason: "Matched on amount only", offers: [.fileWithoutLink])],
                          groupKey: "Insurance receipt documents")
    }

    private func learnt(_ item: ImportItem) throws -> ImportItem {
        try db.read { db in try ImportLearning.applyLinkRules(item, rules: try ImportRuleStore.all(db: db), db: db) }
    }

    func testOnlyACertainReadAmountMakesALearntLinkCertain() throws {
        try learnMerchant()
        let other = try transaction(Self.date(2024, 3, 11), -12_000, "OTHER SHOP")
        let paid = try transaction(Self.date(2024, 4, 5), -12_000, "DEMO SEGUROS 77")
        for source in [ImportFactSource.ocr, .model, .fileName] {
            let item = try learnt(askingItem([other, paid], amount: .money(12_000, .eur), source: source, usedOCR: source == .ocr))
            XCTAssertEqual(item.links, [], "\(source): an amount to check never makes the link certain")
            XCTAssertEqual(chooseLinkCandidates(item).map(\.entity), [.transaction(paid), .transaction(other)], "\(source): the merchant's first")
            XCTAssertTrue(chooseLinkCandidates(item)[0].reasons.contains("Learnt: Example Seguros, S.A. is paid by “DEMO SEGUROS”"))
            XCTAssertEqual(item.appliedRules, [])
        }
        let read = try learnt(askingItem([other, paid], amount: .money(12_000, .eur), source: .textLayer))
        XCTAssertEqual(read.links.map(\.entity), [.transaction(paid)])
        XCTAssertEqual(read.links.first?.confidence, .certain)
        XCTAssertTrue(chooseLinkCandidates(read).isEmpty)
    }

    func testALearntLinkNeedsTheDocumentsCurrency() throws {
        try learnMerchant()
        let paid = try transaction(Self.date(2024, 4, 5), -12_000, "DEMO SEGUROS 77")
        let item = try learnt(askingItem([paid], amount: .money(12_000, .gbp), source: .textLayer))
        XCTAssertEqual(item.links, [], "€120 is not £120")
        XCTAssertEqual(chooseLinkCandidates(item).map(\.entity), [.transaction(paid)])
    }

    func testLearntKindOfAScannedFileNeedsReview() throws {
        let file = ImportFile(url: URL(fileURLWithPath: "/synthetic/scan.pdf"), fileName: "scan.pdf", sha256: "sha-scan", byteCount: 1,
                              fileExtension: "pdf", text: Self.issuerLine + "\nCarta", textStatus: .text, usedOCR: true)
        let rule = ImportRule(id: 1, kind: .documentKind, matchKey: Self.issuerKey, matchLabel: "Example Seguros, S.A.",
                              actionJSON: "{\"kind\":\"insuranceReceipt\"}", actionLabel: "Kind: Insurance receipt", createdAt: Date())
        let recognition = try XCTUnwrap(ImportLearning.recogniser(rules: [rule], ownNIFs: [])(file))
        XCTAssertEqual(recognition.kind, .evidence(.insuranceReceipt))
        XCTAssertEqual(recognition.confidence, .needsReview, "read by text recognition: to check")
        var typed = file
        typed.usedOCR = false
        XCTAssertEqual(ImportLearning.recogniser(rules: [rule], ownNIFs: [])(typed)?.confidence, .certain)
    }

    func testAnIssuerTheRereadDroppedIsNotLearnt() async throws {
        var plan = try await pipeline.plan([try letter("letter-1.pdf", day: "1")])
        let id = try only(plan).id
        plan = try await pipeline.resolve(plan, itemId: id, .setIssuer("Seguradora Exemplo"))
        XCTAssertEqual(try only(plan).ruleDrafts.map(\.kind), [.issuer])
        plan = try await pipeline.resolve(plan, itemId: id, .chooseKind(.insuranceReceipt))
        let reread = try only(plan)
        XCTAssertFalse(reread.facts.contains { $0.field == .issuer }, "\(reread.facts)")
        XCTAssertEqual(reread.ruleDrafts.map(\.kind), [.documentKind], "the name the reread dropped is not taught")
        _ = try applier.apply(plan, entryPoint: "Test")
        XCTAssertEqual(try rules().map(\.kind), [.documentKind])
    }

    func testATargetRereadKeepsTheDraftsItStillCarries() async throws {
        let providerId = try await db.write { db -> Int64 in
            var provider = UtilityProvider(propertyId: self.propertyId, name: "Demo Water", kind: .water)
            try Recharges.saveProvider(db: db, &provider)
            return provider.id!
        }
        var plan = try await pipeline.plan([try letter("letter-1.pdf", day: "1")])
        let id = try only(plan).id
        plan = try await pipeline.resolve(plan, itemId: id, .chooseKind(.utilityInvoice))
        XCTAssertEqual(try only(plan).recognition.kind, .utilityInvoice)
        XCTAssertEqual(try only(plan).ruleDrafts.map(\.kind), [.documentKind])
        plan = try await pipeline.resolve(plan, itemId: id, .chooseTarget(.provider, providerId))
        let reread = try only(plan)
        XCTAssertEqual(reread.recognition.kind, .utilityInvoice)
        XCTAssertEqual(reread.ruleDrafts.map(\.kind), [.documentKind], "the kind survives the provider's reread")
        XCTAssertEqual(reread.ruleDrafts.first?.actionJSON, "{\"kind\":\"utilityInvoice\"}")
    }

    func testCorrectingTheIssuerFigureDraftsAnIssuerRule() async throws {
        var plan = try await pipeline.plan([try letter("letter-1.pdf", day: "1")])
        plan = try await pipeline.resolve(plan, itemId: try only(plan).id, .confirmFigure(.issuer, .text("Seguradora Exemplo")))
        let item = try only(plan)
        XCTAssertEqual(item.ruleDrafts.map(\.kind), [.issuer])
        XCTAssertEqual(item.ruleDrafts.first?.actionJSON, "{\"name\":\"Seguradora Exemplo\"}")
    }

    func testALearntRecordLinkDefersToACertainLinkOfTheSameType() async throws {
        let otherId = try await db.write { db -> Int64 in
            var property = Property(name: "Property B", country: "PT")
            try Properties.save(db: db, &property)
            return property.id!
        }
        _ = try await db.write { db in
            try ImportRuleStore.learn(db: db, kind: .link, key: Self.issuerKey, matchLabel: "Example Seguros, S.A.",
                                      action: LinkAction(entity: .property(self.propertyId)), actionLabel: "Link to Property A", now: Date())
        }
        let intent = ImportIntent(target: ImportIntent.Target(entity: .property(otherId)))
        let plan = try await pipeline.plan([try receipt("seguro.pdf", date: "10/03/2024")], intent: intent)
        let item = try only(plan)
        XCTAssertEqual(item.links.filter { $0.entity.type == .property }.map(\.entity), [.property(otherId)], "the user's own target stays the only property")
        XCTAssertEqual(item.appliedRules, [])
    }

    func testRereadAfterUnlinkingALearntLinkKeepsItUnlinked() async throws {
        _ = try await db.write { db in
            try ImportRuleStore.learn(db: db, kind: .link, key: Self.issuerKey, matchLabel: "Example Seguros, S.A.",
                                      action: LinkAction(entity: .property(self.propertyId)), actionLabel: "Link to Property A", now: Date())
        }
        var plan = try await pipeline.plan([try receipt("seguro.pdf", date: "10/03/2024")])
        let id = try only(plan).id
        XCTAssertEqual(try only(plan).appliedRules.map(\.kind), [.link])
        plan = try await pipeline.resolve(plan, itemId: id, .unlink(.property(propertyId)))
        XCTAssertEqual(try only(plan).appliedRules, [])
        plan = try await pipeline.resolve(plan, itemId: id, .chooseKind(.insurancePolicy))
        let reread = try only(plan)
        XCTAssertFalse(reread.links.contains { $0.entity == .property(propertyId) }, "the user unlinked it: \(reread.links)")
        XCTAssertEqual(reread.appliedRules, [])
        let summary = try applier.apply(plan, entryPoint: "Test")
        XCTAssertGreaterThan(summary.runId, 0)
        XCTAssertEqual(try rules().first { $0.kind == .link }?.useCount, 0, "a rule the user overrode is not used")
    }

    func testUnlinkingAnotherLinkKeepsTheLearntLinkOnAReread() async throws {
        _ = try await db.write { db in
            try ImportRuleStore.learn(db: db, kind: .link, key: Self.issuerKey, matchLabel: "Example Seguros, S.A.",
                                      action: LinkAction(entity: .property(self.propertyId)), actionLabel: "Link to Property A", now: Date())
        }
        let paid = try transaction(Self.date(2024, 3, 12), -12_000, "DEMO SEGUROS 77")
        var plan = try await pipeline.plan([try receipt("seguro.pdf", date: "10/03/2024")])
        let id = try only(plan).id
        let read = try only(plan)
        XCTAssertTrue(read.links.contains { $0.entity == .transaction(paid) && $0.confidence == .certain }, "\(read.links)")
        plan = try await pipeline.resolve(plan, itemId: id, .unlink(.transaction(paid)))
        XCTAssertEqual(try only(plan).appliedRules.map(\.kind), [.link], "the learnt property link is still on the item")
        plan = try await pipeline.resolve(plan, itemId: id, .chooseKind(.insurancePolicy))
        let reread = try only(plan)
        XCTAssertTrue(reread.links.contains { $0.entity == .property(propertyId) && $0.confidence == .certain }, "\(reread.links)")
        XCTAssertEqual(reread.appliedRules.map(\.kind), [.link])
    }

    func testACorrectedIssuerNameIsTrimmedAndKept() async throws {
        var plan = try await pipeline.plan([try letter("letter-1.pdf", day: "1")])
        let id = try only(plan).id
        plan = try await pipeline.resolve(plan, itemId: id, .confirmFigure(.issuer, .text("  Seguradora Exemplo ")))
        XCTAssertEqual(try only(plan).facts.first { $0.field == .issuer }?.value, .text("Seguradora Exemplo"))
        plan = try await pipeline.resolve(plan, itemId: id, .leaveOut)
        plan = try await pipeline.resolve(plan, itemId: id, .leaveOut)
        XCTAssertEqual(try only(plan).ruleDrafts.map(\.actionJSON), ["{\"name\":\"Seguradora Exemplo\"}"], "the draft matches the fact it came from")
    }

    func testUndoRestoresTheUseCountsTheRunAdded() async throws {
        try learnKind(.insuranceReceipt)
        let before = try XCTUnwrap(try rules().first)
        let plan = try await pipeline.plan([try letter("letter-1.pdf", day: "1")])
        let summary = try applier.apply(plan, entryPoint: "Test")
        XCTAssertEqual(try rules().first?.useCount, 1)
        _ = try ImportUndo.undo(dbQueue: db, library: library, runId: summary.runId)
        let after = try XCTUnwrap(try rules().first)
        XCTAssertEqual(after.useCount, 0)
        XCTAssertNil(after.lastUsedAt)
        XCTAssertEqual(after, before)
    }

    func testLearntKindAndLinkOnAFiledYearItemAreHeld() async throws {
        let p60 = try await db.write { db -> ImportItem in
            var person = Person(name: "Person A", shortName: "A")
            try People.save(db: db, &person)
            var year = TaxYear(startYear: 2024, personId: person.id!, status: .filed)
            try year.insert(db)
            var employment = Employment(startYear: 2024, personId: person.id!, employerName: "Acme Ltd")
            try Employments.save(db: db, &employment)
            var income = EmploymentIncome(employmentId: employment.id!, source: .p60, payMinorUnits: 4_000_000, taxDeductedMinorUnits: 600_000)
            try Employments.save(db: db, &income)
            try ImportRuleStore.learn(db: db, kind: .documentKind, key: Self.issuerKey, matchLabel: "Example Seguros, S.A.",
                                      action: DocumentKindAction(kind: .p60), actionLabel: "Kind: P60", now: Date())
            try ImportRuleStore.learn(db: db, kind: .link, key: Self.issuerKey, matchLabel: "Example Seguros, S.A.",
                                      action: LinkAction(entity: .property(self.propertyId)), actionLabel: "Link to Property A", now: Date())
            let confirmed = PayrollFormImport.Confirmed(kind: .p60, personId: person.id!, startYear: 2024, employerName: "Acme Ltd",
                                                        payMinorUnits: 4_100_000, taxDeductedMinorUnits: 600_000)
            return ImportItem(file: ImportFile(url: URL(fileURLWithPath: "/synthetic/x.pdf"), fileName: "x.pdf", sha256: "x", byteCount: 1,
                                               fileExtension: "pdf", text: nil, textStatus: .noText, usedOCR: false),
                              recognition: ImportRecognition(kind: .payrollForm(.p60), confidence: .certain, reason: "test"),
                              title: "P60 2024/25 Acme Ltd",
                              facts: [ImportFact(field: .taxYear, value: .year(2024), source: .textLayer, confidence: .certain, reason: "Year")],
                              effect: .payrollForm(confirmed), groupKey: "Payroll forms")
        }
        let held = ImportPipeline(dbQueue: db, library: library, categorizationService: CategorizationService(categorizer: FakeCategorizer()),
                                  readers: [StubP60Reader(p60: p60)])
        defer { held.discardPlanningCopy() }
        let plan = try await held.plan([try letter("letter-1.pdf", day: "1")])
        let item = try only(plan)
        XCTAssertEqual(item.recognition.kind, .payrollForm(.p60))
        XCTAssertNotNil(item.recognition.ruleId)
        XCTAssertEqual(Set(item.appliedRules.map(\.kind)), [.documentKind, .link])
        XCTAssertTrue(item.isHeldByFiledYear, "learnt rules are applied before the filed-year guard: \(item.issues)")
        XCTAssertEqual(item.section, .needsYou)
    }

    // MARK: Final review fixes

    private static let lineKey = "line:EXAMPLE LETTERS LDA"

    /// A letter whose issuer has no number: keyed by its first line.
    private func lineLetter(_ name: String) throws -> URL {
        try pdf(name, ["Example Letters Lda", "Rua Exemplo 1, Lisboa", "Assunto: comunicacao", "Caro senhor, segue a informacao pedida."])
    }

    func testALearntRuleOnALineKeyLeavesTheItemNeedsYou() async throws {
        try await db.write { db in
            try ImportRuleStore.learn(db: db, kind: .documentKind, key: Self.lineKey, matchLabel: "Example Letters Lda",
                                      action: DocumentKindAction(kind: .insuranceReceipt), actionLabel: "Kind: Insurance receipt", now: Date())
            try ImportRuleStore.learn(db: db, kind: .link, key: Self.lineKey + "#record", matchLabel: "Example Letters Lda",
                                      action: LinkAction(entity: .property(self.propertyId)), actionLabel: "Link to Property A", now: Date())
            try ImportRuleStore.learn(db: db, kind: .issuer, key: Self.lineKey, matchLabel: "Example Letters Lda",
                                      action: IssuerAction(name: "Letters Co"), actionLabel: "Name: Letters Co", now: Date())
        }
        let plan = try await pipeline.plan([try lineLetter("line.pdf")])
        let item = try only(plan)
        let check = "Learnt from the first line “Example Letters Lda”: check it"
        XCTAssertEqual(item.recognition.kind, .evidence(.insuranceReceipt))
        XCTAssertEqual(item.recognition.confidence, .needsReview, "a first line never makes a kind certain")
        XCTAssertTrue(item.recognition.reason.contains(check), item.recognition.reason)
        let link = try XCTUnwrap(item.links.first { $0.entity == .property(propertyId) }, "\(item.links)")
        XCTAssertEqual(link.confidence, .needsReview, "a first line never makes a link certain")
        XCTAssertTrue(link.reasons.contains { $0.contains(check) }, "\(link.reasons)")
        let issuer = try XCTUnwrap(item.facts.first { $0.field == .issuer })
        XCTAssertEqual(issuer.confidence, .needsReview)
        XCTAssertTrue(issuer.reason.contains(check), issuer.reason)
        XCTAssertEqual(item.section, .needsYou)
        XCTAssertEqual(Set(item.appliedRules.map(\.kind)), [.documentKind, .link, .issuer])
    }

    func testALearntMerchantOnALineKeyNeverChoosesTheTransaction() throws {
        try db.write { db in
            try ImportRuleStore.learn(db: db, kind: .link, key: Self.lineKey + "#transaction", matchLabel: "Example Letters Lda",
                                      action: LinkAction(descriptionKey: "DEMO SEGUROS"), actionLabel: "Paid by “DEMO SEGUROS”", now: Date())
        }
        let other = try transaction(Self.date(2024, 3, 11), -12_000, "OTHER SHOP")
        let paid = try transaction(Self.date(2024, 4, 5), -12_000, "DEMO SEGUROS 77")
        var asking = askingItem([other, paid], amount: .money(12_000, .eur), source: .textLayer)
        asking.file.text = "Example Letters Lda\nRECIBO\nTOTAL 120,00 €"
        let item = try learnt(asking)
        XCTAssertEqual(item.links, [], "a first line never makes a link certain")
        let candidates = chooseLinkCandidates(item)
        XCTAssertEqual(candidates.map(\.entity), [.transaction(paid), .transaction(other)], "the merchant's first")
        XCTAssertTrue(candidates[0].reasons.contains { $0.contains("Learnt from the first line “Example Letters Lda”: check it") }, "\(candidates[0])")
    }

    func testARecordLinkRuleSurvivesAMerchantChoiceAndBothApplyNextTime() async throws {
        // A record link learnt before link rules were keyed per family (the bare issuer key).
        _ = try await db.write { db in
            try ImportRuleStore.learn(db: db, kind: .link, key: Self.issuerKey, matchLabel: "Example Seguros, S.A.",
                                      action: LinkAction(entity: .property(self.propertyId)), actionLabel: "Link to Property A", now: Date())
        }
        let april = try transaction(Self.date(2024, 4, 5), -12_000, "DEMO SEGUROS 77")
        var plan = try await pipeline.plan([try receipt("seguro-1.pdf", date: "10/03/2024")])
        var item = try only(plan)
        XCTAssertTrue(item.links.contains { $0.entity == .property(propertyId) && $0.confidence == .certain }, "\(item.links)")
        XCTAssertEqual(chooseLinkCandidates(item).map(\.entity), [.transaction(april)], "\(item.issues)")
        plan = try await pipeline.resolve(plan, itemId: item.id, .chooseLink(.transaction(april)))
        item = try only(plan)
        XCTAssertEqual(item.ruleDrafts.map(\.key), [Self.issuerKey + "#transaction"])
        XCTAssertNil(item.ruleDrafts.first?.replaces, "a merchant doesn't replace the record link")
        XCTAssertEqual(item.appliedRules.map(\.kind), [.link], "the record link is still used")
        _ = try applier.apply(plan, entryPoint: "Test")
        let learnt = try rules().filter { $0.kind == .link }
        XCTAssertEqual(learnt.count, 2, "\(learnt)")
        let actions = learnt.compactMap { ImportLearning.decode(LinkAction.self, $0.actionJSON) }
        XCTAssertTrue(actions.contains(LinkAction(entity: .property(propertyId))))
        XCTAssertTrue(actions.contains(LinkAction(descriptionKey: "DEMO SEGUROS", sourceAccountId: accountId)), "learnt from the payment's account")
        pipeline.discardPlanningCopy()

        let october = try transaction(Self.date(2024, 10, 5), -12_000, "DEMO SEGUROS 78")
        plan = try await pipeline.plan([try receipt("seguro-2.pdf", date: "10/09/2024")])
        item = try only(plan)
        XCTAssertTrue(item.links.contains { $0.entity == .property(propertyId) && $0.confidence == .certain }, "\(item.links)")
        XCTAssertTrue(item.links.contains { $0.entity == .transaction(october) && $0.confidence == .certain }, "\(item.links)")
        XCTAssertEqual(item.appliedRules.map(\.kind), [.link, .link])
        XCTAssertEqual(item.section, .ready, "\(item.needsYouReasons)")
    }

    func testWillRememberNamesTheRuleItReplaces() async throws {
        _ = try await db.write { db in
            try ImportRuleStore.learn(db: db, kind: .link, key: Self.issuerKey, matchLabel: "Example Seguros, S.A.",
                                      action: LinkAction(descriptionKey: "OTHER INSURER"), actionLabel: "Paid by “OTHER INSURER”", now: Date())
        }
        let april = try transaction(Self.date(2024, 4, 5), -12_000, "DEMO SEGUROS 77")
        var plan = try await pipeline.plan([try receipt("seguro-1.pdf", date: "10/03/2024")])
        plan = try await pipeline.resolve(plan, itemId: try only(plan).id, .chooseLink(.transaction(april)))
        let draft = try XCTUnwrap(try only(plan).ruleDrafts.first)
        XCTAssertEqual(draft.replaces, "Paid by “OTHER INSURER”")
        _ = try applier.apply(plan, entryPoint: "Test")
        let learnt = try rules().filter { $0.kind == .link }
        XCTAssertEqual(learnt.map(\.matchKey), [Self.issuerKey + "#transaction"], "the old rule is the one replaced")
        XCTAssertEqual(learnt.first?.actionJSON, "{\"descriptionKey\":\"DEMO SEGUROS\",\"sourceAccountId\":\(accountId!)}")
    }

    func testConflictingChoicesForOneIssuerInOneRunAreNotLearnt() async throws {
        var plan = try await pipeline.plan([try letter("letter-1.pdf", day: "1"), try letter("letter-2.pdf", day: "2")])
        let ids = plan.items.filter { $0.parentId == nil }.map(\.id)
        XCTAssertEqual(ids.count, 2)
        plan = try await pipeline.resolve(plan, itemId: ids[0], .chooseKind(.insuranceReceipt))
        plan = try await pipeline.resolve(plan, itemId: ids[1], .chooseKind(.insurancePolicy))
        let summary = try applier.apply(plan, entryPoint: "Test")
        XCTAssertFalse(try rules().contains { $0.kind == .documentKind }, "neither choice is learnt")
        let note = "Not learnt: different choices for Example Seguros, S.A. (Document type) in this import"
        XCTAssertEqual(summary.notes, [note])
        let stored = try await db.read { db in try ImportRun.fetchOne(db, key: summary.runId)?.summary }
        XCTAssertTrue(stored?.contains(note) == true, stored ?? "")
    }

    func testNoKindIsLearntForADocumentTheAppRecognisesItself() async throws {
        var plan = try await pipeline.plan([try receipt("seguro.pdf", date: "10/03/2024")])
        let read = try only(plan)
        XCTAssertNil(read.recognition.ruleId)
        XCTAssertFalse(read.recognition.proposedByModel)
        XCTAssertEqual(read.recognition.confidence, .certain, "a built-in recogniser read it")
        plan = try await pipeline.resolve(plan, itemId: read.id, .chooseKind(.insurancePolicy))
        let item = try only(plan)
        XCTAssertEqual(item.recognition.kind, .evidence(.insurancePolicy))
        XCTAssertFalse(item.ruleDrafts.contains { $0.kind == .documentKind }, "\(item.ruleDrafts)")
        XCTAssertTrue(item.notes.contains(ImportLearning.recognisesItselfNote), "\(item.notes)")
    }

    // MARK: Issuers that aren't (rule-issuer)

    private static func textFile(_ lines: [String]) -> ImportFile {
        ImportFile(url: URL(fileURLWithPath: "/tmp/\(UUID().uuidString)/a.pdf"), fileName: "a.pdf", sha256: UUID().uuidString,
                   byteCount: 1, fileExtension: "pdf", text: lines.joined(separator: "\n"), textStatus: .glyph, usedOCR: false)
    }

    func testPaidByIsNeverDraftedFromAReferenceOnlyDescription() {
        let item = ImportItem(file: Self.textFile([Self.issuerLine]), recognition: ImportRecognition(kind: .evidence(.insuranceReceipt),
                              confidence: .certain, reason: "test"), title: "x")
        let issuer = IssuerKey(key: Self.issuerKey, label: "Example Seguros, S.A.")
        func paidBy(_ description: String) -> [String] {
            ImportLearning.drafts(for: item, resolution: .chooseLink(.transaction(1)), issuer: issuer,
                                  transactionDescriptions: [1: description]).map(\.actionLabel)
        }
        for reference in ["XYZ 1234567890123", "SMR 1234567890123", "SEPADD/ ADC/12345678", "TRF 12345 PG", "MB 1234 AB", "AB/ /CODE1 12"] {
            XCTAssertEqual(paidBy(reference), [], reference)
        }
        XCTAssertEqual(paidBy("SEPADD/DEMO SEGUROS ADC/12345678"), ["Paid by “SEPADD/DEMO SEGUROS”"])
        XCTAssertEqual(paidBy("DEMO SEGUROS 77"), ["Paid by “DEMO SEGUROS”"])
        XCTAssertEqual(paidBy("CARD PAYMENT TO DEMOMART 12"), ["Paid by “CARD PAYMENT TO DEMOMART”"])
        // Three-letter brands are names.
        XCTAssertEqual(paidBy("DD MEO 1234567890123"), ["Paid by “DD MEO”"])
        XCTAssertEqual(paidBy("COMPRA EDP 1234567890"), ["Paid by “COMPRA EDP”"])
        XCTAssertEqual(paidBy("SEPADD/NOS COMUNICACOES ADC/12345678"), ["Paid by “SEPADD/NOS COMUNICACOES”"])
        XCTAssertEqual(paidBy("NOS 1234"), ["Paid by “NOS”"])
    }

    func testMerchantPatternsNeedARealName() {
        XCTAssertFalse(ImportLearning.isMerchantPattern("XYZ", description: "XYZ 1234567890123"), "a code and a reference only")
        XCTAssertFalse(ImportLearning.isMerchantPattern("SEPADD", description: "SEPADD/ ADC/12345678"))
        XCTAssertFalse(ImportLearning.isMerchantPattern("PAYPAL", description: "PAYPAL 12"))
        XCTAssertFalse(ImportLearning.isMerchantPattern("DD TRF PG MB", description: "DD TRF PG MB 12"))
        XCTAssertTrue(ImportLearning.isMerchantPattern("DD XYZ", description: "DD XYZ 1234567890123"))
        XCTAssertTrue(ImportLearning.isMerchantPattern("EDP", description: "EDP 1234"))
        XCTAssertTrue(ImportLearning.isMerchantPattern("DEMO SEGUROS", description: "DEMO SEGUROS 77"))
    }

    func testNothingIsLearntAboutABanksOwnLetterhead() {
        let item = ImportItem(file: Self.textFile(["Banco Demo SA"]), recognition: ImportRecognition(kind: .evidence(.insuranceReceipt),
                              confidence: .certain, reason: "test"), title: "x")
        let bank = IssuerKey(key: "nif:500000000", label: "Banco Bilbao Vizcaya Argentaria S.A. - S")
        XCTAssertEqual(ImportLearning.drafts(for: item, resolution: .chooseKind(.insuranceReceipt), issuer: bank), [])
        XCTAssertEqual(ImportLearning.drafts(for: item, resolution: .setIssuer("Demo Seguros"), issuer: bank), [])
        let insurer = IssuerKey(key: "nif:500000000", label: "Demo Seguros")
        XCTAssertEqual(ImportLearning.drafts(for: item, resolution: .chooseKind(.insuranceReceipt), issuer: insurer).map(\.kind), [.documentKind])
    }

    func testABankDebitAdviceFiledAsAReceiptTeachesNothing() async throws {
        let debit = try transaction(Self.date(2025, 2, 3), -1_000, "XYZ 1234567890123")
        var plan = try await pipeline.plan([try pdf("advice.pdf", IssuerKeyTests.bareDebitAdvice)])
        let id = try only(plan).id
        plan = try await pipeline.resolve(plan, itemId: id, .chooseKind(.insuranceReceipt))
        XCTAssertEqual(try only(plan).ruleDrafts, [], "no greeting, no bank: no issuer, no kind rule")
        plan = try await pipeline.resolve(plan, itemId: id, .linkTransactions([debit]))
        XCTAssertEqual(try only(plan).ruleDrafts, [], "a reference is never a merchant")
    }
}

/// Reads a P60 recognised by a learnt rule as the given item (its file and recognition kept).
private struct StubP60Reader: ImportReader {
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
