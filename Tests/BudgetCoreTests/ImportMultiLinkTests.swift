import XCTest
import GRDB
@testable import BudgetCore

/// One document on several transactions in the import review (spec 2026-10-24 §4c): two debits of
/// one merchant that add up to the document are proposed as its instalments — always asked
/// ("Keep both links" / "File without a link"), never linked on their own; Confirm writes both links.
/// Synthetic data only (the names, NIF and amounts are made up).
final class ImportMultiLinkTests: XCTestCase {
    private var manager: DatabaseManager!
    private var db: DatabaseQueue { manager.dbQueue }
    private var folder: URL!
    private var library: EvidenceLibrary!
    private var pipeline: ImportPipeline!
    private var applier: ImportApplier!
    private var account: Int64 = 0
    private var batch: Int64 = 0

    override func setUpWithError() throws {
        manager = try DatabaseManager(path: nil)
        try manager.migrate()
        try db.write { db in
            try CategorySeeder.seedDefaults(db)
            var euros = Account(name: "Bank EUR", currency: .eur, kind: .cash, trackingMode: .imported)
            try euros.insert(db)
            account = euros.id!
            var importBatch = ImportBatch(accountId: account, sourceFileName: "synthetic.csv", importedAt: Date())
            try importBatch.insert(db)
            batch = importBatch.id!
        }
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("ImportMultiLinkTests-\(UUID().uuidString)", isDirectory: true)
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

    private static func day(_ y: Int, _ m: Int, _ d: Int) -> Date {
        UKTaxYear.utcCalendar.date(from: DateComponents(year: y, month: m, day: d))!
    }

    @discardableResult
    private func debit(_ date: Date, _ amount: Int, _ description: String, account: Int64? = nil, batch: Int64? = nil,
                       category: Int64? = nil) throws -> Int64 {
        try db.write { db in
            var transaction = Transaction(importBatchId: batch ?? self.batch, accountId: account ?? self.account, date: date,
                                          rawDescription: description, amountMinorUnits: amount, categoryId: category, status: .confirmed,
                                          categorizedBy: .manual, fingerprint: UUID().uuidString)
            try transaction.insert(db)
            return transaction.id!
        }
    }

    private func pdf(_ name: String, _ lines: [String]) throws -> URL {
        let made = EvidenceTestPDFs.textPDF(lines, name: name)
        let directory = folder.appendingPathComponent("Drop-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try FileManager.default.moveItem(at: made, to: url)
        return url
    }

    /// A plumber's bill of €79.95 dated 5 March 2023.
    private func repairBill() throws -> URL {
        try pdf("bill.pdf", ["Canalizacoes Exemplo Lda NIF 503504564", "FATURA-RECIBO FR 2023/15", "Data: 05/03/2023",
                             "Reparacao de autoclismo", "Total 79,95 EUR"])
    }

    /// Synchronous database access from the async tests.
    private func write<T>(_ body: (Database) throws -> T) throws -> T { try db.write(body) }

    private func item(_ plan: ImportPlan) throws -> ImportItem {
        try XCTUnwrap(plan.items.first { $0.file.fileName == "bill.pdf" })
    }

    private func links() throws -> [Int64] {
        try db.read { db in
            try Int64.fetchAll(db, sql: "SELECT entityId FROM documentLink WHERE entityType = ? ORDER BY entityId",
                               arguments: [EvidenceEntityType.transaction.rawValue])
        }
    }

    // MARK: Instalments

    func testInstalmentsAreAskedNeverCertain() async throws {
        let first = try debit(Self.day(2023, 3, 5), -4_000, "PAG CANALIZACOES EXEMPLO 0001")
        let second = try debit(Self.day(2023, 3, 25), -3_995, "PAG CANALIZACOES EXEMPLO 0002")
        try debit(Self.day(2023, 3, 10), -3_995, "COMPRA SUPERMERCADO 77")
        var plan = try await pipeline.plan([try repairBill()])
        let asked = try item(plan)
        XCTAssertEqual(asked.recognition.kind, .evidence(.repairInvoice))
        let reason = "Paid in 2 instalments: €40.00 + €39.95"
        XCTAssertEqual(asked.links.map(\.entity), [.transaction(first), .transaction(second)])
        XCTAssertEqual(asked.links.map(\.confidence), [.needsReview, .needsReview], "never certain on its own")
        XCTAssertEqual(asked.issues.map(\.id), [EvidenceDocumentReader.instalmentsIssueId])
        XCTAssertEqual(asked.issues.first?.kind, .readerProblem(reason))
        XCTAssertEqual(asked.issues.first?.offers, [.acknowledge, .fileWithoutLink])
        XCTAssertEqual(asked.section, .needsYou)
        XCTAssertEqual(asked.needsYouReasons, [reason], "the question asks about both links once")
        XCTAssertFalse(plan.canConfirm)

        // File without a link: both proposed links go.
        let unlinked = try await pipeline.resolve(plan, itemId: asked.id, issueId: EvidenceDocumentReader.instalmentsIssueId, .fileWithoutLink)
        XCTAssertEqual(try item(unlinked).links, [])
        XCTAssertEqual(try item(unlinked).section, .ready)

        // Keep both links: both certain, checked by the user; Confirm writes both.
        plan = try await pipeline.resolve(plan, itemId: asked.id, issueId: EvidenceDocumentReader.instalmentsIssueId, .acknowledge)
        let kept = try item(plan)
        XCTAssertEqual(kept.links.map(\.entity), [.transaction(first), .transaction(second)])
        XCTAssertEqual(kept.links.map(\.confidence), [.certain, .certain])
        XCTAssertTrue(kept.links.allSatisfy { $0.reasons == [reason, ImportChecks.checkedReason] }, "\(kept.links.map(\.reasons))")
        XCTAssertEqual(kept.section, .ready, "\(kept.needsYouReasons)")
        XCTAssertTrue(plan.canConfirm)
        _ = try applier.apply(plan, entryPoint: "Test")
        XCTAssertEqual(try links(), [first, second])
    }

    func testSeveralPairsAskWhichOne() async throws {
        let ids = try [(5, -4_000), (25, -3_995), (6, -4_000), (26, -3_995)].map { day, amount in
            try debit(Self.day(2023, 3, day), amount, "PAG CANALIZACOES EXEMPLO \(day)")
        }
        let plan = try await pipeline.plan([try repairBill()])
        let asked = try item(plan)
        XCTAssertEqual(asked.links, [])
        XCTAssertFalse(asked.issues.contains { $0.id == EvidenceDocumentReader.instalmentsIssueId })
        let issue = try XCTUnwrap(asked.issues.first { $0.id == "chooseLink" })
        guard case .chooseLink(let candidates) = issue.kind else { return XCTFail("\(issue.kind)") }
        XCTAssertEqual(Set(candidates.map(\.entity)), Set(ids.map(EvidenceEntity.transaction)))
        XCTAssertTrue(candidates.allSatisfy { $0.reasons == ["Paid in 2 instalments: €40.00 + €39.95"] })
        XCTAssertEqual(issue.reason, "It may have been paid in instalments, and several pairs of payments add up to it: which ones are they?")
    }

    func testADebitOfTheWholeAmountIsNotSplitIntoInstalments() async throws {
        try debit(Self.day(2023, 3, 5), -4_000, "PAG CANALIZACOES EXEMPLO 0001")
        try debit(Self.day(2023, 3, 25), -3_995, "PAG CANALIZACOES EXEMPLO 0002")
        let whole = try debit(Self.day(2023, 3, 6), -7_995, "PAG CANALIZACOES EXEMPLO 0003")
        let plan = try await pipeline.plan([try repairBill()])
        let read = try item(plan)
        XCTAssertFalse(read.issues.contains { $0.id == EvidenceDocumentReader.instalmentsIssueId })
        XCTAssertEqual(read.links.map(\.entity), [.transaction(whole)])
        XCTAssertEqual(read.links.map(\.confidence), [.certain])
    }

    /// A rental property of Person A, whose 2024/25 return is filed, with a Legal category (legal fees);
    /// returns the category.
    private func filedYearProperty() throws -> Int64 {
        try write { db -> Int64 in
            var person = Person(name: "Person A", shortName: "A")
            try People.save(db: db, &person)
            var year = TaxYear(startYear: 2024, personId: person.id!, status: .filed)
            try year.insert(db)
            var property = Property(name: "Property A", country: "PT", currency: .eur)
            try Properties.save(db: db, &property)
            _ = try Properties.setOwners(db: db, propertyId: property.id!, [PropertyOwner(propertyId: property.id!, personId: person.id!, shareBasisPoints: 10_000)])
            try Properties.setAccount(db: db, propertyId: property.id!, accountId: self.account, role: .current)
            var group = CategoryGroup(name: "Property A")
            try group.insert(db)
            try Properties.addCategoryGroup(db: db, propertyId: property.id!, categoryGroupId: group.id!)
            var legal = Category(name: "Legal", type: .expense, groupId: group.id)
            try legal.insert(db)
            try TaxExpenseTypeMap.seed(db: db, propertyId: property.id!)
            try TaxExpenseTypeMap.set(db: db, categoryId: legal.id!, expenseType: .legalFees)
            for year in [2024, 2025] {
                var rate = HMRCRate(startYear: year, currencyCode: "EUR", gbpPerUnit: 0.85, source: .manual)
                try rate.insert(db)
            }
            return legal.id!
        }
    }

    /// A legal bill dated in the filed 2024/25 year, paid in two instalments either side of 5 April: an
    /// invoice dates its expenses, so keeping both links would move the second into the filed year.
    /// The item is held (leave out only) and Confirm never writes it.
    func testInstalmentsThatWouldChangeAFiledYearAreHeld() async throws {
        let legal = try filedYearProperty()
        let paidBefore = try debit(Self.day(2025, 3, 30), -4_000, "PAG ADVOGADOS DEMO 0001", category: legal)
        let paidAfter = try debit(Self.day(2025, 4, 20), -3_995, "PAG ADVOGADOS DEMO 0002", category: legal)
        let bill = try pdf("bill.pdf", ["Advogados Demo, Sociedade de Advogados NIF 503504564", "FATURA FT 2025/7", "Data: 30/03/2025",
                                        "Honorarios", "Total 79,95 EUR"])
        var plan = try await pipeline.plan([bill])
        let asked = try item(plan)
        XCTAssertEqual(asked.recognition.kind, .evidence(.legalInvoice))
        XCTAssertEqual(asked.links.map(\.entity), [.transaction(paidBefore), .transaction(paidAfter)])
        XCTAssertFalse(asked.issues.contains { ImportResolutions.isFiledYearHold($0) }, "nothing linked yet")

        plan = try await pipeline.resolve(plan, itemId: asked.id, issueId: EvidenceDocumentReader.instalmentsIssueId, .acknowledge)
        let held = try item(plan)
        XCTAssertTrue(held.issues.contains { ImportResolutions.isFiledYearHold($0) }, "\(held.issues.map(\.reason))")
        XCTAssertEqual(held.section, .needsYou)
        XCTAssertFalse(plan.canConfirm)
        XCTAssertEqual(try links(), [])
    }

    /// By hand too: linking a legal bill dated in the filed 2024/25 year to its second instalment, paid
    /// in 2025/26, would move that payment into the filed year — refused, nothing written. A repair
    /// bill (dated by its payments) links.
    func testLinkingTheRestOfAFiledYearInvoiceByHandIsRefused() throws {
        let legal = try filedYearProperty()
        let paidBefore = try debit(Self.day(2025, 3, 30), -4_000, "PAG ADVOGADOS DEMO 0001", category: legal)
        let paidAfter = try debit(Self.day(2025, 4, 20), -3_995, "PAG ADVOGADOS DEMO 0002", category: legal)
        func bill(_ kind: DocumentKind, _ sha: String) throws -> Int64 {
            try write { db in
                var document = EvidenceDocument(sha256: sha, storedRelativePath: "x/\(sha).pdf", originalFileName: "\(sha).pdf", byteCount: 1,
                                                kind: kind, docDate: Self.day(2025, 3, 30), amountMinorUnits: 7_995, currency: .eur, addedAt: Date())
                try document.insert(db)
                try EvidenceLinks.link(db: db, documentId: document.id!, to: .transaction(paidBefore))
                return document.id!
            }
        }
        let invoice = try bill(.legalInvoice, "legal")
        let refusal = EvidenceLinkGuard.Failure.changesFiledYear(years: ["2024/25"])
        // The Documents inspector's Link.
        XCTAssertThrowsError(try library.link(invoice, to: .transaction(paidAfter))) {
            XCTAssertEqual($0 as? EvidenceLinkGuard.Failure, refusal)
            XCTAssertEqual(($0 as? LocalizedError)?.errorDescription, "Not linked: this would change the filed 2024/25 return.")
        }
        // Edit transaction's Save, with the link staged from Link document…: nothing saved, the note neither.
        XCTAssertThrowsError(try write { db in
            try TransactionEditing.save(db: db, id: paidAfter, changes: TransactionEditChanges(categoryId: legal, note: "second half",
                                                                                                documents: EvidenceLinkChanges(link: [invoice])))
        }) { XCTAssertEqual($0 as? EvidenceLinkGuard.Failure, refusal) }
        XCTAssertEqual(try links(), [paidBefore])
        XCTAssertNil(try db.read { db in try Transaction.fetchOne(db, key: paidAfter) }?.note)

        // A repair bill doesn't date the payments: linked.
        let repair = try bill(.repairInvoice, "repair")
        try library.link(repair, to: .transaction(paidAfter))
        XCTAssertEqual(try links(), [paidBefore, paidBefore, paidAfter])
    }
}
