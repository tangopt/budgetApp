import XCTest
import GRDB
@testable import BudgetCore
import TestSupport

/// Custom kinds in the import review (spec 2026-10-24 §2): "New kind…" adds a pending kind to
/// the plan, usable at once by any item of the review; Confirm inserts it first and files the
/// documents under it; Undo takes it back; Discard forgets it; the kind is learnt per sender.
/// Synthetic data only (NIF 503504564 and the names are made up).
final class ImportCustomKindTests: XCTestCase {
    private var manager: DatabaseManager!
    private var db: DatabaseQueue { manager.dbQueue }
    private var folder: URL!
    private var library: EvidenceLibrary!
    private var pipeline: ImportPipeline!
    private var applier: ImportApplier!

    override func setUpWithError() throws {
        manager = try TestDatabase.migratedManager()
        try write { db in try CategorySeeder.seedDefaults(db) }
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("ImportCustomKindTests-\(UUID().uuidString)", isDirectory: true)
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

    private static let issuerLine = "Exemplo Termica, Lda. NIF 503504564"
    private static let issuerKey = "nif:503504564"

    private func pdf(_ name: String, _ lines: [String]) throws -> URL {
        let made = EvidenceTestPDFs.textPDF(lines, name: name)
        let directory = folder.appendingPathComponent("Drop-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try FileManager.default.moveItem(at: made, to: url)
        return url
    }

    /// A letter nothing built in recognises, dated `date` (dd/MM/yyyy), for `total` when given.
    private func letter(_ name: String, date: String, total: String? = nil, note: String = "") throws -> URL {
        var lines = [Self.issuerLine, "Rua Exemplo 1, Lisboa", "Data: \(date)", "Caro senhor, segue a informacao pedida. \(note)"]
        if let total { lines.append("TOTAL \(total) €") }
        return try pdf(name, lines)
    }

    private func top(_ plan: ImportPlan) -> [ImportItem] { plan.items.filter { $0.parentId == nil } }

    private func item(_ plan: ImportPlan, _ fileName: String) throws -> ImportItem {
        try XCTUnwrap(plan.items.first { $0.file.fileName == fileName })
    }

    private func kinds() throws -> [CustomDocumentKind] { try read { db in try CustomDocumentKind.fetchAll(db) } }

    /// Synchronous database access from the async tests.
    private func read<T>(_ body: (Database) throws -> T) throws -> T { try db.read(body) }
    private func write<T>(_ body: (Database) throws -> T) throws -> T { try db.write(body) }

    private func refusal(_ body: () async throws -> Void) async -> ImportResolutionError? {
        do {
            try await body()
            return nil
        } catch let error as ImportResolutionError {
            return error
        } catch {
            XCTFail("unexpected \(error)")
            return nil
        }
    }

    // MARK: New kind…

    func testNewKindIsUsableForOtherItemsOfTheReview() async throws {
        var plan = try await pipeline.plan([try letter("a.pdf", date: "05/03/2023"), try letter("b.pdf", date: "07/04/2023")])
        XCTAssertEqual(try item(plan, "a.pdf").recognition.kind, .unknown)
        let a = try item(plan, "a.pdf").id, b = try item(plan, "b.pdf").id

        plan = try await pipeline.resolve(plan, itemId: a, .createKind(name: "  Boiler service ", area: .property))
        XCTAssertEqual(plan.pendingKinds.count, 1)
        let pending = try XCTUnwrap(plan.pendingKinds.first)
        XCTAssertEqual(pending.name, "Boiler service")
        XCTAssertEqual(pending.area, .property)
        let first = try item(plan, "a.pdf")
        XCTAssertEqual(first.recognition.kind, .customEvidence(.pending(pending.id)))
        XCTAssertEqual(first.recognition.confidence, .certain)
        XCTAssertEqual(first.title, "Boiler service of 2023-03-05")
        XCTAssertEqual(first.section, .ready, "\(first.needsYouReasons)")
        XCTAssertEqual(first.placement?.metadata.kind, .other)
        XCTAssertTrue(first.placement?.canonicalName.hasPrefix("20230305 - Property - Boiler service") == true,
                      first.placement?.canonicalName ?? "")
        XCTAssertEqual(try kinds(), [], "nothing is written before Confirm")

        // The other item of the review takes it at once.
        plan = try await pipeline.resolve(plan, itemId: b, .chooseCustomKind(.pending(pending.id)))
        let second = try item(plan, "b.pdf")
        XCTAssertEqual(second.recognition.kind, .customEvidence(.pending(pending.id)))
        XCTAssertEqual(second.title, "Boiler service of 2023-04-07")
        XCTAssertEqual(plan.pendingKinds.count, 1)

        // The chooser: built-ins, saved custom kinds, then the review's pending ones, by label.
        try write { db in _ = try CustomDocumentKinds.create(db: db, name: "Alarm contract", area: .property, now: Date()) }
        let catalog = try read { db in try DocumentKindCatalog.load(db: db) }
        let choices = ImportKindChoice.choices(catalog: catalog, pending: plan.pendingKinds)
        let builtIns = DocumentKind.allCases.count
        XCTAssertEqual(choices.count, builtIns + 2)
        XCTAssertEqual(choices[builtIns].label, "Alarm contract")
        XCTAssertEqual(choices[builtIns + 1], ImportKindChoice(kind: .customEvidence(.pending(pending.id)), label: "Boiler service"))
        XCTAssertEqual(choices[builtIns + 1].resolution, .chooseCustomKind(.pending(pending.id)))
        XCTAssertEqual(choices.first { $0.label == "Insurance receipt" }?.resolution, .chooseKind(.insuranceReceipt))
        // "New kind…" says a taken name before Create, as the review refuses it (ignoring case, accents and spaces).
        XCTAssertEqual(ImportKindChoice.takenName(" repair BILL ", among: choices), "Repair bill")
        XCTAssertEqual(ImportKindChoice.takenName("álarm contract", among: choices), "Alarm contract")
        XCTAssertEqual(ImportKindChoice.takenName("boiler service", among: choices), "Boiler service")
        XCTAssertNil(ImportKindChoice.takenName("Lift service", among: choices))
        XCTAssertNil(ImportKindChoice.takenName("  ", among: choices))
        // A pending kind unknown to the review is refused.
        let unknown = await refusal { _ = try await self.pipeline.resolve(plan, itemId: b, .chooseCustomKind(.pending(UUID()))) }
        XCTAssertNotNil(unknown)
    }

    func testNewKindNameTakenIsRefused() async throws {
        try write { db in _ = try CustomDocumentKinds.create(db: db, name: "Água", area: .property, now: Date()) }
        var plan = try await pipeline.plan([try letter("a.pdf", date: "05/03/2023"), try letter("b.pdf", date: "07/04/2023")])
        let a = try item(plan, "a.pdf").id, b = try item(plan, "b.pdf").id

        let builtIn = await refusal { _ = try await self.pipeline.resolve(plan, itemId: a, .createKind(name: "insurance RECEIPT", area: .property)) }
        XCTAssertEqual(builtIn, .kindNameTaken("Insurance receipt"))
        let saved = await refusal { _ = try await self.pipeline.resolve(plan, itemId: a, .createKind(name: "agua", area: .other)) }
        XCTAssertEqual(saved, .kindNameTaken("Água"))
        XCTAssertEqual(saved?.localizedDescription, "There's already a kind called \u{201C}Água\u{201D}.")
        let empty = await refusal { _ = try await self.pipeline.resolve(plan, itemId: a, .createKind(name: "  ", area: .other)) }
        XCTAssertEqual(empty, .kindNameEmpty)

        plan = try await pipeline.resolve(plan, itemId: a, .createKind(name: "Boiler service", area: .property))
        let same = await refusal { _ = try await self.pipeline.resolve(plan, itemId: b, .createKind(name: "boiler sérvice", area: .other)) }
        XCTAssertEqual(same, .kindNameTaken("Boiler service"))
        XCTAssertEqual(plan.pendingKinds.count, 1)
        XCTAssertEqual(try kinds().map(\.name), ["Água"])
    }

    // MARK: Confirm, Discard, Undo

    func testConfirmInsertsThePendingKindAndFilesUnderIt() async throws {
        var plan = try await pipeline.plan([try letter("a.pdf", date: "05/03/2023"), try letter("b.pdf", date: "07/04/2023")])
        let a = try item(plan, "a.pdf").id, b = try item(plan, "b.pdf").id
        plan = try await pipeline.resolve(plan, itemId: a, .createKind(name: "Boiler service", area: .property))
        let pending = try XCTUnwrap(plan.pendingKinds.first)
        plan = try await pipeline.resolve(plan, itemId: b, .chooseCustomKind(.pending(pending.id)))
        // A custom kind is read like Other (no amount of its own): the user gives one.
        plan = try await pipeline.resolve(plan, itemId: a, .confirmFigure(.amount, .money(8500, .eur)))
        XCTAssertEqual(try item(plan, "a.pdf").recognition.kind, .customEvidence(.pending(pending.id)))
        XCTAssertTrue(plan.canConfirm)

        let summary = try applier.apply(plan, entryPoint: "Test")
        XCTAssertEqual(summary.filed, 2)
        let saved = try kinds()
        XCTAssertEqual(saved.map(\.name), ["Boiler service"])
        XCTAssertEqual(saved.first?.area, .property)
        let kindId = try XCTUnwrap(saved.first?.id)
        let documents = try read { db in try EvidenceDocument.order(Column("originalFileName")).fetchAll(db) }
        XCTAssertEqual(documents.map(\.kind), [.other, .other])
        XCTAssertEqual(documents.map(\.customKindId), [kindId, kindId])
        XCTAssertEqual(documents.first?.kindRef, .custom(kindId))
        XCTAssertTrue(documents.first?.canonicalName?.hasPrefix("20230305 - Property - Boiler service - ") == true,
                      documents.first?.canonicalName ?? "")
        XCTAssertEqual(documents.first?.amountMinorUnits, 8500)
        XCTAssertEqual(documents.last?.canonicalName, "20230407 - Property - Boiler service")
    }

    func testDiscardForgetsAPendingKind() async throws {
        var plan = try await pipeline.plan([try letter("a.pdf", date: "05/03/2023")])
        plan = try await pipeline.resolve(plan, itemId: try item(plan, "a.pdf").id, .createKind(name: "Boiler service", area: .property))
        XCTAssertEqual(plan.pendingKinds.count, 1)
        pipeline.discardPlanningCopy()
        XCTAssertEqual(try kinds(), [])

        // A new review knows nothing of it, and the name is free.
        plan = try await pipeline.plan([try letter("b.pdf", date: "07/04/2023")])
        XCTAssertEqual(plan.pendingKinds, [])
        XCTAssertEqual(try item(plan, "b.pdf").recognition.kind, .unknown)
        plan = try await pipeline.resolve(plan, itemId: try item(plan, "b.pdf").id, .createKind(name: "Boiler service", area: .other))
        XCTAssertEqual(plan.pendingKinds.map(\.name), ["Boiler service"])
    }

    func testUndoRemovesAKindTheRunCreated() async throws {
        var plan = try await pipeline.plan([try letter("a.pdf", date: "05/03/2023")])
        plan = try await pipeline.resolve(plan, itemId: try item(plan, "a.pdf").id, .createKind(name: "Boiler service", area: .property))
        let summary = try applier.apply(plan, entryPoint: "Test")
        XCTAssertEqual(try kinds().count, 1)
        pipeline.discardPlanningCopy()

        _ = try ImportUndo.undo(dbQueue: db, library: library, runId: summary.runId)
        XCTAssertEqual(try kinds(), [])
        XCTAssertEqual(try read { db in try EvidenceDocument.fetchCount(db) }, 0)
        XCTAssertEqual(try read { db in try ImportRule.fetchCount(db) }, 0, "the rule learnt with it goes too")

        // A kind another document took meanwhile: Undo refuses, as for any row used since.
        plan = try await pipeline.plan([try letter("b.pdf", date: "07/04/2023")])
        plan = try await pipeline.resolve(plan, itemId: try item(plan, "b.pdf").id, .createKind(name: "Boiler service", area: .property))
        let run = try applier.apply(plan, entryPoint: "Test")
        let kindId = try XCTUnwrap(try kinds().first?.id)
        try write { db in
            let url = try self.letter("c.pdf", date: "09/05/2023", note: "outra")
            var document = try self.library.add(db: db, url, metadata: EvidenceMetadata(kind: .other), analysis: nil).result.document
            document.customKindId = kindId
            try document.update(db)
        }
        do {
            _ = try ImportUndo.undo(dbQueue: db, library: library, runId: run.runId)
            XCTFail("expected a refusal")
        } catch ImportUndoError.refused(let conflicts) {
            XCTAssertFalse(conflicts.isEmpty)
        }
        XCTAssertEqual(try kinds().count, 1)
    }

    // MARK: Learning

    func testCustomKindIsLearntForTheIssuerAndSuggestedNextTime() async throws {
        var plan = try await pipeline.plan([try letter("a.pdf", date: "05/03/2023")])
        plan = try await pipeline.resolve(plan, itemId: try item(plan, "a.pdf").id, .createKind(name: "Boiler service", area: .property))
        let pending = try XCTUnwrap(plan.pendingKinds.first)
        let chosen = try item(plan, "a.pdf")
        XCTAssertEqual(chosen.ruleDrafts.map(\.kind), [.documentKind])
        XCTAssertEqual(chosen.ruleDrafts.first?.key, Self.issuerKey)
        XCTAssertEqual(chosen.ruleDrafts.first?.actionLabel, "Kind: Boiler service")
        XCTAssertEqual(chosen.ruleDrafts.first?.pendingKindId, pending.id)

        _ = try applier.apply(plan, entryPoint: "Test")
        pipeline.discardPlanningCopy()
        let kindId = try XCTUnwrap(try kinds().first?.id)
        let rule = try XCTUnwrap(try read { db in try ImportRuleStore.all(db: db) }.first)
        XCTAssertEqual(rule.kind, .documentKind)
        XCTAssertEqual(rule.actionLabel, "Kind: Boiler service")
        XCTAssertEqual(ImportLearning.decode(DocumentKindAction.self, rule.actionJSON), DocumentKindAction(kind: .other, customKindId: kindId))

        // Next time: suggested as the saved kind, named and filed under it.
        plan = try await pipeline.plan([try letter("b.pdf", date: "07/04/2023")])
        let next = try item(plan, "b.pdf")
        XCTAssertEqual(next.recognition.kind, .customEvidence(.saved(kindId)))
        XCTAssertEqual(next.recognition.reason, "Learnt: Exemplo Termica, Lda. → Boiler service")
        XCTAssertEqual(next.recognition.ruleId, rule.id)
        XCTAssertEqual(next.title, "Boiler service of 2023-04-07")
        XCTAssertEqual(next.placement?.metadata.customKindId, kindId)
        XCTAssertEqual(next.appliedRules.map(\.ruleId), [rule.id!])
        pipeline.discardPlanningCopy()

        // A rule whose kind is gone is skipped.
        try write { db in _ = try CustomDocumentKind.deleteAll(db) }
        plan = try await pipeline.plan([try letter("c.pdf", date: "09/05/2023")])
        XCTAssertEqual(try item(plan, "c.pdf").recognition.kind, .unknown)
        XCTAssertEqual(try item(plan, "c.pdf").appliedRules, [])
    }

    func testConfirmWithAKindMergedMeanwhileFailsAsOutOfDate() async throws {
        let (boiler, heating) = try write { db in
            (try CustomDocumentKinds.create(db: db, name: "Boiler service", area: .property, now: Date()).id!,
             try CustomDocumentKinds.create(db: db, name: "Heating", area: .property, now: Date()).id!)
        }
        var plan = try await pipeline.plan([try letter("a.pdf", date: "05/03/2023")])
        plan = try await pipeline.resolve(plan, itemId: try item(plan, "a.pdf").id, .chooseCustomKind(.saved(boiler)))
        XCTAssertEqual(try item(plan, "a.pdf").recognition.kind, .customEvidence(.saved(boiler)))
        XCTAssertTrue(plan.canConfirm)

        try write { db in _ = try CustomDocumentKinds.save(db: db, edits: [KindEdit(kindId: boiler, change: .merge(into: .custom(heating)))]) }
        XCTAssertThrowsError(try applier.apply(plan, entryPoint: "Test")) { error in
            XCTAssertEqual(error as? ImportApplyError, .notConfirmable)
        }
        XCTAssertEqual(try read { db in try EvidenceDocument.fetchCount(db) }, 0)
        XCTAssertEqual(try read { db in try ImportRun.fetchCount(db) }, 0)
    }

    func testANewKindsRuleFitsTheIssuersOtherDocuments() async throws {
        var plan = try await pipeline.plan([try letter("a.pdf", date: "05/03/2023"), try letter("b.pdf", date: "07/04/2023")])
        let a = try item(plan, "a.pdf").id, b = try item(plan, "b.pdf").id
        plan = try await pipeline.resolve(plan, itemId: a, .createKind(name: "Boiler service", area: .property))
        let pending = try XCTUnwrap(plan.pendingKinds.first)
        let fits = try await pipeline.ruleFits(plan)
        let fit = try XCTUnwrap(fits[a]?.first { $0.itemId == b })
        let change = try XCTUnwrap(fit.changes.first { $0.aspect == .kind })
        XCTAssertEqual(change.after, .text("Boiler service"))
        XCTAssertEqual(change.resolution, .chooseCustomKind(.pending(pending.id)))
        plan = try await pipeline.applyRule(plan, from: a, to: [b])
        XCTAssertEqual(try item(plan, "b.pdf").recognition.kind, .customEvidence(.pending(pending.id)))

        // Both learn the same thing: one rule, naming the kind saved at Confirm.
        _ = try applier.apply(plan, entryPoint: "Test")
        let kindId = try XCTUnwrap(try kinds().first?.id)
        let rules = try read { db in try ImportRuleStore.all(db: db) }
        XCTAssertEqual(rules.count, 1)
        XCTAssertEqual(rules.first.flatMap { ImportLearning.decode(DocumentKindAction.self, $0.actionJSON) },
                       DocumentKindAction(kind: .other, customKindId: kindId))
    }

    func testTwoNewKindsForOneIssuerTeachNothing() async throws {
        var plan = try await pipeline.plan([try letter("a.pdf", date: "05/03/2023"), try letter("b.pdf", date: "07/04/2023")])
        let a = try item(plan, "a.pdf").id, b = try item(plan, "b.pdf").id
        plan = try await pipeline.resolve(plan, itemId: a, .createKind(name: "Boiler service", area: .property))
        plan = try await pipeline.resolve(plan, itemId: b, .createKind(name: "Alarm contract", area: .property))
        let summary = try applier.apply(plan, entryPoint: "Test")
        XCTAssertEqual(Set(try kinds().map(\.name)), ["Boiler service", "Alarm contract"])
        XCTAssertEqual(try read { db in try ImportRule.fetchCount(db) }, 0)
        XCTAssertTrue(summary.notes.contains { $0.hasPrefix("Not learnt: different choices for Exemplo Termica") }, "\(summary.notes)")
    }

    func testMissingEvidenceAddForACustomKindDeclaresIt() async throws {
        let (kindId, propertyId) = try write { db -> (Int64, Int64) in
            var property = Property(name: "Property A", country: "PT")
            try Properties.save(db: db, &property)
            return (try CustomDocumentKinds.create(db: db, name: "Boiler service", area: .property, now: Date()).id!, property.id!)
        }
        let shortcut = ImportShortcut.attach(.property(propertyId), role: nil, from: .missingEvidence, expected: .custom(kindId))
        XCTAssertEqual(shortcut.intent.expected, .customEvidence(.saved(kindId)))
        let plan = try await pipeline.plan([try letter("a.pdf", date: "05/03/2023")], intent: shortcut.intent)
        let added = try item(plan, "a.pdf")
        XCTAssertEqual(added.recognition.kind, .customEvidence(.saved(kindId)))
        XCTAssertEqual(added.recognition.reason, "You added it as a Boiler service from Missing evidence ▸ Add")
        XCTAssertFalse(added.issues.contains { $0.id == "kindMismatch" })
    }

    func testACustomKindsAmountIsGuessedToCheck() async throws {
        var plan = try await pipeline.plan([try pdf("a.pdf", [Self.issuerLine, "Data: 05/03/2023", "Deslocacao 10,00 €",
                                                              "Valor final 85,00 €"])])
        let a = try item(plan, "a.pdf").id
        plan = try await pipeline.resolve(plan, itemId: a, .createKind(name: "Boiler service", area: .property))
        var read = try item(plan, "a.pdf")
        let amount = try XCTUnwrap(read.facts.first { $0.field == .amount })
        XCTAssertEqual(amount.value, .money(8500, .eur))
        XCTAssertEqual(amount.confidence, .needsReview)
        XCTAssertEqual(amount.reason, EvidenceDocumentReader.guessedAmountReason)
        XCTAssertEqual(read.section, .needsYou)
        XCTAssertTrue(read.needsYouReasons.contains(EvidenceDocumentReader.guessedAmountReason))
        plan = try await pipeline.resolve(plan, itemId: a, .confirmFigure(.amount, .money(8500, .eur)))
        read = try item(plan, "a.pdf")
        XCTAssertEqual(read.section, .ready, "\(read.needsYouReasons)")
        XCTAssertTrue(read.placement?.canonicalName.hasPrefix("20230305 - Property - Boiler service - ") == true)
    }

    // MARK: Kinds changed before Confirm

    func testConfirmAfterAKindMergedIntoABuiltInReadsTheItemAgain() async throws {
        let boiler = try write { db in try CustomDocumentKinds.create(db: db, name: "Boiler service", area: .property, now: Date()).id! }
        var plan = try await pipeline.plan([try letter("a.pdf", date: "05/03/2023")])
        let a = try item(plan, "a.pdf").id
        plan = try await pipeline.resolve(plan, itemId: a, .chooseCustomKind(.saved(boiler)))
        XCTAssertTrue(plan.canConfirm)
        try write { db in _ = try CustomDocumentKinds.save(db: db, edits: [KindEdit(kindId: boiler, change: .merge(into: .builtIn(.repairInvoice)))]) }
        XCTAssertThrowsError(try applier.apply(plan, entryPoint: "Test")) { XCTAssertEqual($0 as? ImportApplyError, .notConfirmable) }

        let reread = try await XCTUnwrapAsync(try await pipeline.rereadingChangedKinds(plan))
        let item = try self.item(reread, "a.pdf")
        XCTAssertEqual(item.recognition.kind, .evidence(.repairInvoice))
        XCTAssertEqual(item.recognition.confidence, .needsReview)
        XCTAssertEqual(item.recognition.reason, "Boiler service was merged into Repair bill: check it")
        XCTAssertEqual(item.section, .needsYou)
        XCTAssertFalse(item.ruleDrafts.contains { $0.actionJSON.contains("customKindId") }, "the gone kind isn't learnt")
        let nothing = try await pipeline.rereadingChangedKinds(reread)
        XCTAssertNil(nothing)
    }

    func testANewKindSavedMeanwhileUnderItsNameIsReused() async throws {
        var plan = try await pipeline.plan([try letter("a.pdf", date: "05/03/2023")])
        plan = try await pipeline.resolve(plan, itemId: try item(plan, "a.pdf").id, .createKind(name: "Boiler service", area: .property))
        // Saved meanwhile (another device), spelt otherwise and in another area.
        let saved = try write { db in try CustomDocumentKinds.create(db: db, name: "boiler sérvice", area: .other, now: Date()).id! }
        let summary = try applier.apply(plan, entryPoint: "Test")
        XCTAssertEqual(try kinds().map(\.id), [saved])
        let document = try XCTUnwrap(try read { db in try EvidenceDocument.fetchOne(db) })
        XCTAssertEqual(document.customKindId, saved)
        XCTAssertEqual(document.canonicalName, "20230305 - Other - boiler sérvice")
        let rule = try XCTUnwrap(try read { db in try ImportRuleStore.all(db: db) }.first)
        XCTAssertEqual(rule.actionLabel, "Kind: boiler sérvice")
        XCTAssertEqual(ImportLearning.decode(DocumentKindAction.self, rule.actionJSON)?.customKindId, saved)
        // Task 6 N3: the summary says the review's name and area weren't used.
        XCTAssertEqual(summary.notes, ["Boiler service (Property) was filed under the kind “boiler sérvice” (Other), saved meanwhile"])
        pipeline.discardPlanningCopy()

        _ = try ImportUndo.undo(dbQueue: db, library: library, runId: summary.runId)
        XCTAssertEqual(try kinds().map(\.id), [saved], "the run didn't make it: Undo leaves it")
        XCTAssertEqual(try read { db in try EvidenceDocument.fetchCount(db) }, 0)
    }

    func testAKindRenamedDuringTheReviewNamesTheDocument() async throws {
        let boiler = try write { db in try CustomDocumentKinds.create(db: db, name: "Boiler service", area: .property, now: Date()).id! }
        var plan = try await pipeline.plan([try letter("a.pdf", date: "05/03/2023")])
        plan = try await pipeline.resolve(plan, itemId: try item(plan, "a.pdf").id, .chooseCustomKind(.saved(boiler)))
        XCTAssertEqual(try item(plan, "a.pdf").placement?.canonicalName, "20230305 - Property - Boiler service")
        try write { db in _ = try CustomDocumentKinds.save(db: db, edits: [KindEdit(kindId: boiler, change: .rename(name: "Boiler check", area: .other))]) }
        _ = try applier.apply(plan, entryPoint: "Test")
        let document = try XCTUnwrap(try read { db in try EvidenceDocument.fetchOne(db) })
        XCTAssertEqual(document.canonicalName, "20230305 - Other - Boiler check")
        XCTAssertEqual(try read { db in try ImportRuleStore.all(db: db) }.first?.actionLabel, "Kind: Boiler check")
    }

    func testAMismatchNamesTheExpectedCustomKind() async throws {
        let (kindId, propertyId) = try write { db -> (Int64, Int64) in
            var property = Property(name: "Property A", country: "PT")
            try Properties.save(db: db, &property)
            return (try CustomDocumentKinds.create(db: db, name: "Boiler service", area: .property, now: Date()).id!, property.id!)
        }
        let shortcut = ImportShortcut.attach(.property(propertyId), role: nil, from: .missingEvidence, expected: .custom(kindId))
        let receipt = try pdf("r.pdf", [Self.issuerLine, "SEGURO MULTI-RISCO HABITACAO", "Data: 05/03/2023", "TOTAL 120,00 €"])
        let plan = try await pipeline.plan([receipt], intent: shortcut.intent)
        let issue = try XCTUnwrap(try item(plan, "r.pdf").issues.first { $0.id == "kindMismatch" })
        XCTAssertEqual(issue.reason, "Expected a Boiler service, this looks like a Insurance receipt")
    }

    /// Task 6 N1: the found side names a learnt custom kind too.
    func testAMismatchNamesTheFoundCustomKind() async throws {
        let propertyId = try write { db -> Int64 in
            var property = Property(name: "Property A", country: "PT")
            try Properties.save(db: db, &property)
            let kindId = try CustomDocumentKinds.create(db: db, name: "Boiler service", area: .property, now: Date()).id!
            try ImportRuleStore.learn(db: db, kind: .documentKind, key: Self.issuerKey, matchLabel: "Exemplo Termica, Lda.",
                                      action: DocumentKindAction(kind: .other, customKindId: kindId), actionLabel: "Kind: Boiler service",
                                      now: Date())
            return property.id!
        }
        let shortcut = ImportShortcut.attach(.property(propertyId), role: nil, from: .missingEvidence, expected: .builtIn(.insuranceReceipt))
        let plan = try await pipeline.plan([try letter("a.pdf", date: "05/03/2023")], intent: shortcut.intent)
        let issue = try XCTUnwrap(try item(plan, "a.pdf").issues.first { $0.id == "kindMismatch" })
        XCTAssertEqual(issue.reason, "Expected a Insurance receipt, this looks like a Boiler service")
    }

    /// Task 6 N2: a plan that files nothing under a saved custom kind is never read again (no fresh copy taken).
    func testAPlanWithoutSavedCustomKindsIsNotReadAgain() async throws {
        var plan = try await pipeline.plan([try letter("a.pdf", date: "05/03/2023")])
        XCTAssertFalse(plan.usesSavedCustomKinds)
        let copy = try XCTUnwrap(pipeline.planningCopyPath)
        let reread = try await pipeline.rereadingChangedKinds(plan)
        XCTAssertNil(reread)
        XCTAssertEqual(pipeline.planningCopyPath, copy, "no fresh copy for a plan with no saved custom kind")

        // A pending kind isn't saved yet either; a saved one is.
        plan = try await pipeline.resolve(plan, itemId: try item(plan, "a.pdf").id, .createKind(name: "Boiler service", area: .property))
        XCTAssertFalse(plan.usesSavedCustomKinds)
        let kindId = try write { db in try CustomDocumentKinds.create(db: db, name: "Lift service", area: .property, now: Date()).id! }
        plan = try await pipeline.plan(adding: [try letter("b.pdf", date: "07/04/2023")], to: plan, intent: .none)
        plan = try await pipeline.resolve(plan, itemId: try item(plan, "b.pdf").id, .chooseCustomKind(.saved(kindId)))
        XCTAssertTrue(plan.usesSavedCustomKinds)
    }

    func testANewKindComparesAsASavedKindOfItsName() async throws {
        var plan = try await pipeline.plan([try letter("a.pdf", date: "05/03/2023")])
        let a = try item(plan, "a.pdf").id
        plan = try await pipeline.resolve(plan, itemId: a, .createKind(name: "Boiler service", area: .property))
        plan = try await pipeline.resolve(plan, itemId: a, .confirmFigure(.amount, .money(8500, .eur)))
        // Meanwhile (another device): the kind under that name, and a document of it of the same day and amount.
        try write { db in
            let kindId = try CustomDocumentKinds.create(db: db, name: "boiler service", area: .property, now: Date()).id!
            let url = try self.letter("library.pdf", date: "05/03/2023", note: "biblioteca")
            var document = try self.library.add(db: db, url, metadata: EvidenceMetadata(kind: .other), analysis: nil).result.document
            document.customKindId = kindId
            document.docDate = MonthRange.calendar.date(from: DateComponents(year: 2023, month: 3, day: 5))
            document.amountMinorUnits = 8500
            document.currency = .eur
            try document.update(db)
        }
        // More files join the review: a fresh copy, and the pass compares the new kind as the saved one.
        plan = try await pipeline.plan(adding: [try letter("other.pdf", date: "01/01/2024", note: "outra")], to: plan, intent: .none)
        let first = try item(plan, "a.pdf")
        let issue = try XCTUnwrap(first.issues.first { $0.id == "possibleDuplicate" }, "\(first.issues.map(\.reason))")
        XCTAssertTrue(issue.reason.contains("also a boiler service dated 2023-03-05"), issue.reason)
    }

    func testUndoOfANewKindLeavesASyncTombstone() async throws {
        var plan = try await pipeline.plan([try letter("a.pdf", date: "05/03/2023")])
        plan = try await pipeline.resolve(plan, itemId: try item(plan, "a.pdf").id, .createKind(name: "Boiler service", area: .property))
        let summary = try applier.apply(plan, entryPoint: "Test")
        let kindId = try XCTUnwrap(try kinds().first?.id)
        let uuid = try XCTUnwrap(try read { db in try SyncRecordStore.existingUUID(table: "customDocumentKind", localId: kindId, db: db) })
        pipeline.discardPlanningCopy()
        _ = try ImportUndo.undo(dbQueue: db, library: library, runId: summary.runId)
        let tombstones = try read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM syncTombstone WHERE uuid = ? AND tableName = 'customDocumentKind'", arguments: [uuid])
        }
        XCTAssertEqual(tombstones, 1)
        let pending = try read { db in try SyncChangeTracker.pending(db: db) }
        XCTAssertTrue(pending.contains { $0.uuid == uuid && $0.kind == .delete } || !pending.contains { $0.uuid == uuid },
                      "the kind goes out as a delete, or never went out at all: \(pending.filter { $0.uuid == uuid })")
    }

    // MARK: Duplicates

    func testTwoFilesOfOneCustomKindAndDayAreDuplicates() async throws {
        var plan = try await pipeline.plan([try letter("a.pdf", date: "05/03/2023"),
                                            try letter("b.pdf", date: "05/03/2023", note: "segunda via")])
        let a = try item(plan, "a.pdf").id, b = try item(plan, "b.pdf").id
        plan = try await pipeline.resolve(plan, itemId: a, .createKind(name: "Boiler service", area: .property))
        let pending = try XCTUnwrap(plan.pendingKinds.first)
        // Read like Other, a custom kind has no amount of its own: the user confirms each.
        plan = try await pipeline.resolve(plan, itemId: b, .chooseCustomKind(.pending(pending.id)))
        plan = try await pipeline.resolve(plan, itemId: a, .confirmFigure(.amount, .money(8500, .eur)))
        plan = try await pipeline.resolve(plan, itemId: b, .confirmFigure(.amount, .money(8500, .eur)))
        let second = try item(plan, "b.pdf")
        let issue = try XCTUnwrap(second.issues.first { $0.id == "possibleDuplicate" }, "\(second.issues.map(\.reason))")
        XCTAssertEqual(issue.reason, "Possibly a duplicate of a.pdf: also a boiler service dated 2023-03-05 for €85.00")

        // Another kind the same day and amount: no alert.
        plan = try await pipeline.resolve(plan, itemId: b, .createKind(name: "Alarm contract", area: .property))
        plan = try await pipeline.resolve(plan, itemId: b, .confirmFigure(.amount, .money(8500, .eur)))
        XCTAssertFalse(try item(plan, "b.pdf").issues.contains { $0.id == "possibleDuplicate" })

        // Against the library: the saved kind is named too.
        plan = try await pipeline.resolve(plan, itemId: b, .leaveOut)
        _ = try applier.apply(plan, entryPoint: "Test")
        pipeline.discardPlanningCopy()
        XCTAssertEqual(try kinds().map(\.name), ["Boiler service"], "a new kind no applied item uses isn't saved")
        let kindId = try XCTUnwrap(try kinds().first { $0.name == "Boiler service" }?.id)
        plan = try await pipeline.plan([try letter("c.pdf", date: "05/03/2023", note: "terceira via")])
        XCTAssertEqual(try item(plan, "c.pdf").recognition.kind, .customEvidence(.saved(kindId)), "learnt from the first")
        plan = try await pipeline.resolve(plan, itemId: try item(plan, "c.pdf").id, .confirmFigure(.amount, .money(8500, .eur)))
        let third = try item(plan, "c.pdf")
        let again = try XCTUnwrap(third.issues.first { $0.id == "possibleDuplicate" }, "\(third.issues.map(\.reason))")
        XCTAssertTrue(again.reason.contains("also a boiler service"), again.reason)
    }

    private func XCTUnwrapAsync<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) async throws -> T {
        try XCTUnwrap(value, file: file, line: line)
    }
}

/// Confirm import refused because a kind changed (`ImportSession`): the items are read again, never stuck.
@MainActor
final class ImportCustomKindSessionTests: XCTestCase {
    private var folder: URL!
    private var session: ImportSession!

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("ImportCustomKindSessionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        session?.discard()
        await session?.settled()
        session?.pipeline.discardPlanningCopy()
        try? FileManager.default.removeItem(at: folder)
    }

    private func letter(_ name: String, date: String) throws -> URL {
        let made = EvidenceTestPDFs.textPDF(["Exemplo Termica, Lda. NIF 503504564", "Data: \(date)", "Caro senhor, segue a informacao."], name: name)
        let url = folder.appendingPathComponent(name)
        try FileManager.default.moveItem(at: made, to: url)
        return url
    }

    private nonisolated static func write<T>(_ db: DatabaseQueue, _ body: (Database) throws -> T) throws -> T { try db.write(body) }

    func testConfirmAfterKindsWereMergedOrDeletedReadsTheirItemsAgain() async throws {
        let manager = try TestDatabase.migratedManager()
        let db = manager.dbQueue
        let (boiler, heating, alarm) = try Self.write(db) { db -> (Int64, Int64, Int64) in
            try CategorySeeder.seedDefaults(db)
            return (try CustomDocumentKinds.create(db: db, name: "Boiler service", area: .property, now: Date()).id!,
                    try CustomDocumentKinds.create(db: db, name: "Heating", area: .property, now: Date()).id!,
                    try CustomDocumentKinds.create(db: db, name: "Alarm contract", area: .property, now: Date()).id!)
        }
        let library = EvidenceLibrary(root: folder.appendingPathComponent("Library", isDirectory: true), database: db)
        session = ImportSession(dbQueue: db, databasePath: nil, library: library,
                                categorizationService: CategorizationService(categorizer: FakeCategorizer()), modelReader: nil)
        session.start([try letter("a.pdf", date: "05/03/2023"), try letter("b.pdf", date: "07/04/2023")], entryPoint: "Test")
        await session.settled()
        func item(_ name: String) throws -> ImportItem { try XCTUnwrap(session.plan?.items.first { $0.file.fileName == name }) }
        session.resolve(try item("a.pdf").id, .chooseCustomKind(.saved(boiler)))
        session.resolve(try item("b.pdf").id, .chooseCustomKind(.saved(alarm)))
        await session.settled()
        XCTAssertEqual(session.plan?.canConfirm, true)

        try Self.write(db) { db in
            _ = try CustomDocumentKinds.save(db: db, edits: [KindEdit(kindId: boiler, change: .merge(into: .custom(heating)))])
            _ = try CustomDocumentKind.deleteOne(db, key: alarm)
        }
        session.confirm(confirmedBy: nil)
        await session.settled()
        XCTAssertEqual(session.phase, .review)
        XCTAssertEqual(session.problem?.title, ImportSession.kindsChangedProblem)
        let merged = try item("a.pdf")
        XCTAssertEqual(merged.recognition.kind, .customEvidence(.saved(heating)))
        XCTAssertEqual(merged.recognition.reason, "Boiler service was merged into Heating: check it")
        XCTAssertEqual(merged.kindName, "Heating")
        XCTAssertEqual(merged.section, .needsYou)
        let gone = try item("b.pdf")
        XCTAssertEqual(gone.recognition.kind, .unknown)
        XCTAssertTrue(gone.needsYouReasons.contains("Its kind Alarm contract no longer exists"), "\(gone.needsYouReasons)")
        XCTAssertTrue(gone.issues.contains { if case .unknownKind = $0.kind { return true }; return false })
        XCTAssertEqual(session.selectedItemId, merged.id)

        // Answered, the review confirms.
        session.resolve(merged.id, .chooseCustomKind(.saved(heating)))
        session.resolve(gone.id, .createKind(name: "Alarm contract", area: .property))
        await session.settled()
        XCTAssertEqual(session.plan?.canConfirm, true, "\(session.plan?.items.map(\.needsYouReasons) ?? [])")
        session.confirm(confirmedBy: nil)
        await session.settled()
        guard case .finished(let summary) = session.phase else { return XCTFail("\(session.phase) \(String(describing: session.problem))") }
        XCTAssertEqual(summary.filed, 2)
    }
}
