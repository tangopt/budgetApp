import XCTest
import GRDB
@testable import BudgetCore
import TestSupport

/// Plan "Import documents 1b": in the review, a document is linked to one or several existing
/// transactions the user searched for (all of them its payments), links are removed ("Unlink"),
/// and Ready items can be corrected — each change re-checked for duplicates and filed years.
/// Synthetic data: Person A with a filed 2024/25 year and a stored P60 at Acme Ltd (pay
/// £40,000.00); Bank A (sterling, Property A's current account) with a few transactions.
final class ImportReviewLinkingTests: XCTestCase {
    private var manager: DatabaseManager!
    private var db: DatabaseQueue { manager.dbQueue }
    private var ids: [String: Int64] = [:]
    private var pipeline: ImportPipeline!
    private var folder: URL!

    private func id(_ key: String) -> Int64 { ids[key]! }

    private static func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        MonthRange.calendar.date(from: DateComponents(year: y, month: m, day: d))!
    }

    override func setUpWithError() throws {
        manager = try TestDatabase.migratedManager()
        try db.write { db in
            var person = Person(name: "Person A", shortName: "A")
            try People.save(db: db, &person)
            ids["A"] = person.id!
            var year = TaxYear(startYear: 2024, personId: person.id!, status: .filed)
            try year.insert(db)
            var employment = Employment(startYear: 2024, personId: person.id!, employerName: "Acme Ltd")
            try Employments.save(db: db, &employment)
            var income = EmploymentIncome(employmentId: employment.id!, source: .p60, payMinorUnits: 4_000_000, taxDeductedMinorUnits: 600_000)
            try Employments.save(db: db, &income)

            var property = Property(name: "Property A", country: "PT", currency: .gbp)
            try Properties.save(db: db, &property)
            ids["property"] = property.id!
            var account = Account(name: "Bank A", currency: .gbp, kind: .cash, trackingMode: .imported)
            try account.insert(db)
            ids["bank"] = account.id!
            var other = Account(name: "Bank B", currency: .gbp, kind: .cash, trackingMode: .imported)
            try other.insert(db)
            ids["other"] = other.id!
            try Properties.setAccount(db: db, propertyId: property.id!, accountId: account.id!, role: .current)
            var provider = UtilityProvider(propertyId: property.id!, name: "Service Co", kind: .electricity)
            try Recharges.saveProvider(db: db, &provider)
            ids["provider"] = provider.id!
            var category = Category(name: "Shopping", type: .expense)
            try category.insert(db)
            ids["shopping"] = category.id!

            var batch = ImportBatch(accountId: account.id!, sourceFileName: "bank-a.csv", importedAt: Date())
            try batch.insert(db)
            var otherBatch = ImportBatch(accountId: other.id!, sourceFileName: "bank-b.csv", importedAt: Date())
            try otherBatch.insert(db)
            func transaction(_ key: String, _ day: Date, _ description: String, _ amount: Int, account: String = "bank",
                             category: Int64? = nil) throws {
                var row = Transaction(importBatchId: account == "bank" ? batch.id! : otherBatch.id!, accountId: ids[account]!, date: day,
                                      rawDescription: description, amountMinorUnits: amount, categoryId: category, status: .confirmed,
                                      categorizedBy: .manual, fingerprint: UUID().uuidString)
                try row.insert(db)
                ids[key] = row.id!
            }
            try transaction("alpha", Self.date(2025, 3, 1), "SHOP ALPHA", -1_200, category: category.id)
            try transaction("beta", Self.date(2025, 3, 10), "SHOP BETA", -3_400)
            try transaction("part1", Self.date(2025, 4, 2), "SERVICE CO PART 1", -5_000)
            try transaction("part2", Self.date(2025, 4, 9), "SERVICE CO PART 2", -5_000)
            try transaction("elsewhere", Self.date(2025, 3, 5), "SHOP GAMMA", -1_200, account: "other")
        }
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("ImportReviewLinkingTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let library = EvidenceLibrary(root: folder.appendingPathComponent("Library", isDirectory: true), database: db)
        pipeline = ImportPipeline(dbQueue: db, library: library, categorizationService: CategorizationService(categorizer: FakeCategorizer()))
    }

    override func tearDownWithError() throws {
        pipeline?.discardPlanningCopy()
        try? FileManager.default.removeItem(at: folder)
    }

    // MARK: Items

    private func file(_ name: String) -> ImportFile {
        ImportFile(url: URL(fileURLWithPath: "/synthetic/\(name)"), fileName: name, sha256: "sha-\(name)", byteCount: 1,
                   fileExtension: (name as NSString).pathExtension, text: nil, textStatus: .noText, usedOCR: false)
    }

    private func certain(_ kind: ImportKind) -> ImportRecognition {
        ImportRecognition(kind: kind, confidence: .certain, reason: "test")
    }

    /// A Ready receipt document, with an amount and a date, linked to nothing.
    private func receiptItem(links: [ProposedLink] = []) -> ImportItem {
        ImportItem(file: file("receipt.pdf"), recognition: certain(.evidence(.insuranceReceipt)), title: "Receipt",
                   facts: [ImportFact(field: .amount, value: .money(1_200, .gbp), source: .textLayer, confidence: .certain, reason: "Read"),
                           ImportFact(field: .docDate, value: .date(Self.date(2025, 3, 1)), source: .textLayer, confidence: .certain, reason: "Read")],
                   links: links, effect: .file, groupKey: "Other documents")
    }

    private func invoiceItem() -> ImportItem {
        ImportItem(file: file("invoice.pdf"), recognition: certain(.utilityInvoice), title: "Service Co invoice",
                   facts: [ImportFact(field: .amount, value: .money(10_000, .gbp), source: .textLayer, confidence: .certain, reason: "Read")],
                   effect: .utilityInvoice(UtilityInvoice(providerId: id("provider"), invoiceNumber: "INV-1", issueDate: Self.date(2025, 4, 1),
                                                          amountMinorUnits: 10_000)),
                   groupKey: "Utility invoices", notes: ["Not linked: no matching transaction yet"])
    }

    private func p60Item(pay: Int) -> ImportItem {
        let confirmed = PayrollFormImport.Confirmed(kind: .p60, personId: id("A"), startYear: 2024, employerName: "Acme Ltd",
                                                    payMinorUnits: pay, taxDeductedMinorUnits: 600_000)
        return ImportItem(file: file("p60.pdf"), recognition: certain(.payrollForm(.p60)), title: "P60 2024/25 Acme Ltd",
                          facts: [ImportFact(field: .issuer, value: .text("Acme Ltd"), source: .textLayer, confidence: .certain, reason: "Employer"),
                                  ImportFact(field: .taxYear, value: .year(2024), source: .textLayer, confidence: .certain, reason: "Year"),
                                  ImportFact(field: .pay, value: .money(pay, .gbp), source: .textLayer, confidence: .certain, reason: "Pay")],
                          effect: .payrollForm(confirmed), groupKey: "Payroll forms")
    }

    private func resolve(_ item: ImportItem, _ resolution: ImportResolution) async throws -> ImportItem {
        let plan = try await pipeline.resolve(ImportPlan(items: [item]), itemId: item.id, resolution)
        return try XCTUnwrap(plan.items.first { $0.id == item.id })
    }

    /// Applies the item's records as the importer does, with a document standing for its file.
    private func apply(_ item: ImportItem) throws -> Int64 {
        try db.write { db in
            let documentId = try FiledYearGuard.placeholderDocument(db: db, item: item)
            try ImportEffects.applyRecords(db: db, item: item, documentId: documentId, importRunId: nil)
            return documentId
        }
    }

    private func documents(on key: String) throws -> [Int64] {
        try db.read { db in try EvidenceLinks.documents(db: db, for: .transaction(self.id(key))).compactMap(\.id) }
    }

    // MARK: Linking

    func testLinkingAReadyItemToTwoTransactionsKeepsItReadyAndApplyLinksBoth() async throws {
        let item = receiptItem()
        XCTAssertEqual(item.section, .ready)
        let linked = try await resolve(item, .linkTransactions([id("alpha"), id("beta")]))
        XCTAssertEqual(linked.section, .ready, "\(linked.needsYouReasons)")
        XCTAssertEqual(linked.links.map(\.entity), [.transaction(id("alpha")), .transaction(id("beta"))])
        XCTAssertEqual(linked.links.map(\.confidence), [.certain, .certain])
        XCTAssertTrue(linked.links.allSatisfy { $0.reasons == ["Chosen by you"] }, "\(linked.links.map(\.reasons))")
        XCTAssertEqual(linked.links.first?.label, "SHOP ALPHA -£12.00")
        let documentId = try apply(linked)
        XCTAssertEqual(try documents(on: "alpha"), [documentId])
        XCTAssertEqual(try documents(on: "beta"), [documentId])
    }

    func testLinkingReplacesProposedTransactionLinksAndSettlesTheQuestion() async throws {
        var item = receiptItem(links: [ProposedLink(entity: .transaction(id("beta")), label: "SHOP BETA", confidence: .needsReview, reasons: ["Same day"]),
                                       ProposedLink(entity: .property(id("property")), label: "Property A", confidence: .certain, reasons: ["Address"])])
        item.issues = [ImportIssue(id: "chooseLink", kind: .chooseLink([LinkCandidate(entity: .transaction(id("beta")), label: "SHOP BETA", reasons: [])]),
                                   reason: "Which one?", offers: [.fileWithoutLink])]
        XCTAssertEqual(item.section, .needsYou)
        let linked = try await resolve(item, .linkTransactions([id("alpha")]))
        XCTAssertEqual(linked.section, .ready, "\(linked.needsYouReasons)")
        XCTAssertEqual(linked.links.map(\.entity), [.property(id("property")), .transaction(id("alpha"))])
    }

    func testAddingALinkKeepsTheOthers() async throws {
        let item = receiptItem(links: [ProposedLink(entity: .transaction(id("alpha")), label: "SHOP ALPHA", confidence: .certain, reasons: ["Same amount"])])
        let added = try await resolve(item, .addTransactionLink(id("beta")))
        XCTAssertEqual(added.links.map(\.entity), [.transaction(id("alpha")), .transaction(id("beta"))])
        XCTAssertEqual(added.links.map(\.reasons), [["Same amount"], ["Chosen by you"]])
        XCTAssertEqual(added.section, .ready)
    }

    func testUnlinkingAProposedLink() async throws {
        let item = receiptItem(links: [ProposedLink(entity: .transaction(id("alpha")), label: "SHOP ALPHA", confidence: .certain, reasons: ["Same amount"])])
        let unlinked = try await resolve(item, .unlink(.transaction(id("alpha"))))
        XCTAssertEqual(unlinked.links, [])
        XCTAssertEqual(unlinked.section, .ready)
        XCTAssertTrue(unlinked.notes.contains(ImportResolutions.withoutLinkNote), "\(unlinked.notes)")
        // Only a link the item has.
        await XCTAssertThrowsAsync(try await self.resolve(item, .unlink(.transaction(self.id("beta")))))
    }

    func testUtilityInvoiceLinkedToTwoDebitsHasBothAsPayments() async throws {
        let linked = try await resolve(invoiceItem(), .linkTransactions([id("part1"), id("part2")]))
        XCTAssertEqual(linked.section, .ready, "\(linked.needsYouReasons)")
        guard case .utilityInvoice(let invoice) = linked.effect else { return XCTFail("effect \(linked.effect)") }
        // Several debits: equal standing, none is "the" payment.
        XCTAssertNil(invoice.transactionId)
        XCTAssertEqual(linked.links.map(\.entity), [.transaction(id("part1")), .transaction(id("part2"))])
        XCTAssertEqual(linked.links.map(\.madeByEffect), [false, false])
        XCTAssertEqual(linked.links.map(\.role), [nil, nil])
        XCTAssertFalse(linked.notes.contains("Not linked: no matching transaction yet"))

        let documentId = try apply(linked)
        XCTAssertEqual(try documents(on: "part1"), [documentId])
        XCTAssertEqual(try documents(on: "part2"), [documentId])
        try await db.read { db in
            let saved = try XCTUnwrap(try UtilityInvoice.filter(Column("invoiceNumber") == "INV-1").fetchOne(db))
            XCTAssertNil(saved.transactionId)
            // Paid: by both debits, dated by the last one.
            XCTAssertEqual(try Recharges.payments(db: db, saved).compactMap(\.id), [self.id("part1"), self.id("part2")])
            XCTAssertEqual(try Recharges.rechargeDate(db: db, saved), Self.date(2025, 4, 9))
            // Neither debit is offered as another invoice's payment.
            let candidates = try UtilityInvoiceIntake.paymentCandidates(db: db, propertyId: self.id("property"), provider: nil,
                                                                        amountMinorUnits: 5_000, issueDate: Self.date(2025, 4, 1))
            XCTAssertEqual(candidates.compactMap(\.id), [])
        }
    }

    func testUtilityInvoiceLinkedToOneDebitHasItAsItsPayment() async throws {
        let linked = try await resolve(invoiceItem(), .linkTransactions([id("part1")]))
        guard case .utilityInvoice(let invoice) = linked.effect else { return XCTFail("effect \(linked.effect)") }
        XCTAssertEqual(invoice.transactionId, id("part1"))
        XCTAssertEqual(linked.links.map(\.madeByEffect), [true])
        // A second debit added: both are payments, neither the invoice's own.
        let added = try await resolve(linked, .addTransactionLink(id("part2")))
        guard case .utilityInvoice(let both) = added.effect else { return XCTFail("effect \(added.effect)") }
        XCTAssertNil(both.transactionId)
        XCTAssertEqual(added.links.map(\.madeByEffect), [false, false])
        // One unlinked again: the other is the payment.
        let unlinked = try await resolve(added, .unlink(.transaction(id("part1"))))
        guard case .utilityInvoice(let one) = unlinked.effect else { return XCTFail("effect \(unlinked.effect)") }
        XCTAssertEqual(one.transactionId, id("part2"))
        XCTAssertEqual(unlinked.links.map(\.madeByEffect), [true])
    }

    func testAnInvoicePaidInPartsShowsEveryDebitOnItsChargeLine() async throws {
        let linked = try await resolve(invoiceItem(), .linkTransactions([id("part1"), id("part2")]))
        _ = try apply(linked)
        let debits = try await db.write { db -> [Int64] in
            let invoice = try XCTUnwrap(try UtilityInvoice.filter(Column("invoiceNumber") == "INV-1").fetchOne(db))
            var tenancy = Tenancy(propertyId: self.id("property"), referenceLabel: "Room 1", contractNumber: "9001",
                                  tenantName: "TENANT A", startDate: Self.date(2025, 1, 1))
            try Tenancies.save(db: db, &tenancy)
            var statement = RechargeStatement(tenancyId: tenancy.id!, month: Self.date(2025, 4, 1))
            try statement.insert(db)
            var line = RechargeLine(statementId: statement.id!, invoiceId: invoice.id, amountMinorUnits: 5_000)
            try line.insert(db)
            let detail = try RechargeDetails.statement(db: db, statementId: statement.id!)
            return detail.charges.first?.debits.compactMap(\.id) ?? []
        }
        XCTAssertEqual(debits, [id("part1"), id("part2")])
    }

    func testReadyGroupsCountLinksToTransactions() async throws {
        let invoice = try await resolve(invoiceItem(), .linkTransactions([id("part1"), id("part2")]))
        XCTAssertEqual(ImportPlan.summary([invoice]), "1 utility invoice → linked to its debit")
        let receipt = try await resolve(receiptItem(), .linkTransactions([id("alpha")]))
        XCTAssertEqual(ImportPlan.summary([receipt]), "1 insurance receipt document → filed, linked to its transaction")
        XCTAssertEqual(ImportPlan.summary([receiptItem()]), "1 insurance receipt document → filed")
    }

    /// Linking makes two receipts of one day claim one transaction: the user chose that link, so
    /// neither asks (spec §4b: links chosen by the user never raise a claim alert).
    func testALinkTheUserChoseNeverMakesTwoItemsClaimingOneTransactionAsk() async throws {
        let other = ImportItem(file: file("receipt-2.pdf"), recognition: certain(.evidence(.insuranceReceipt)), title: "Receipt 2",
                               facts: [ImportFact(field: .docDate, value: .date(Self.date(2025, 3, 1)), source: .textLayer, confidence: .certain, reason: "Read")],
                               links: [ProposedLink(entity: .transaction(id("alpha")), label: "SHOP ALPHA", confidence: .certain, reasons: ["Same amount"])],
                               effect: .file, groupKey: "Other documents")
        let item = receiptItem()
        let plan = try await pipeline.resolve(ImportPlan(items: [item, other]), itemId: item.id, .linkTransactions([id("alpha")]))
        for checked in plan.items {
            XCTAssertFalse(checked.issues.contains { $0.id.hasSuffix(".\(self.id("alpha"))") }, "\(checked.title): \(checked.issues)")
            XCTAssertEqual(checked.section, .ready, "\(checked.title): \(checked.needsYouReasons)")
        }
    }

    func testUnlinkingATransferAdvicesCreditFilesTheDocumentOnly() throws {
        let credits = try db.read { db in try Transaction.fetchAll(db, keys: [self.id("alpha"), self.id("beta")]) }
        let input = RentCreditEvidence.AdviceInput(source: .file(URL(fileURLWithPath: "/synthetic/advice.pdf")), name: "advice.pdf", sha256: "sha-advice",
                                                   advice: .init(date: Self.date(2025, 3, 1), amounts: [4_600], compactText: ""))
        let planned = RentCreditEvidence.AdvicePlanItem(input: input, outcome: .link, credits: credits)
        let item = ImportItem(file: file("advice.pdf"), recognition: certain(.transferAdvice), title: "Advice",
                              links: credits.map { ProposedLink(entity: .transaction($0.id!), role: RentCreditEvidence.adviceRole, label: $0.rawDescription,
                                                                confidence: .certain, reasons: ["Same day"], madeByEffect: true) },
                              effect: .transferAdvice(planned), groupKey: "Transfer advices")
        let unlinked = try XCTUnwrap(try ImportResolutions.apply(.unlink(.transaction(id("alpha"))), to: item))
        XCTAssertEqual(unlinked.effect, .file)
        XCTAssertEqual(unlinked.links.map(\.entity), [.transaction(id("beta"))])
        XCTAssertEqual(unlinked.links.first?.madeByEffect, false)
        XCTAssertEqual(unlinked.links.first?.role, RentCreditEvidence.adviceRole)
    }

    func testAKindChosenOnAReadyItemIsCheckedAgainstFiledYears() async throws {
        // The new kind is read again (a P60 changing the filed 2024/25 pay), then checked.
        let p60 = p60Item(pay: 4_100_000)
        let reader = KindReader(p60: p60)
        let library = EvidenceLibrary(root: folder.appendingPathComponent("Library2", isDirectory: true), database: db)
        let pipeline = ImportPipeline(dbQueue: db, library: library, categorizationService: CategorizationService(categorizer: FakeCategorizer()),
                                      readers: [reader])
        defer { pipeline.discardPlanningCopy() }
        let item = receiptItem()
        let plan = try await pipeline.resolve(ImportPlan(items: [item]), itemId: item.id, .chooseKind(.p60))
        let reread = try XCTUnwrap(plan.items.first)
        XCTAssertEqual(reread.id, item.id)
        XCTAssertEqual(reread.recognition.kind, .payrollForm(.p60))
        XCTAssertTrue(reread.isHeldByFiledYear, "\(reread.issues)")
    }

    func testHeldOrLeftOutItemRefusesLinkChanges() throws {
        let impact = FiledYearImpact(startYear: 2024, person: "Person A", isPaid: false,
                                     returnChanges: [FiledYearImpact.Line(label: "SA box", before: "£1", after: "£2")],
                                     informationChanges: [], taxDifferenceMinorUnits: 0, causes: [])
        var held = receiptItem(links: [ProposedLink(entity: .transaction(id("alpha")), label: "SHOP ALPHA", confidence: .certain, reasons: [])])
        held.issues = [ImportIssue(id: "filed-2024-Person A", kind: .filedYear(impact), reason: "Held", offers: [.leaveOut])]
        let labels = [EvidenceEntity.transaction(id("beta")): "SHOP BETA"]
        for resolution in [ImportResolution.linkTransactions([id("beta")]), .addTransactionLink(id("beta")), .unlink(.transaction(id("alpha"))),
                           .chooseKind(.other), .confirmFigure(.amount, .money(1, .gbp)), .chooseTarget(.property, id("property"))] {
            XCTAssertThrowsError(try ImportResolutions.apply(resolution, to: held, transactions: labels), "\(resolution)")
        }
        var out = receiptItem()
        out.isLeftOut = true
        XCTAssertThrowsError(try ImportResolutions.apply(.linkTransactions([id("beta")]), to: out, transactions: labels))
        XCTAssertEqual(try ImportResolutions.apply(.leaveOut, to: held)?.section, .leftOut)
    }

    func testANonexistentTransactionIsRefused() async throws {
        let item = receiptItem()
        do {
            _ = try await resolve(item, .linkTransactions([id("alpha"), 999_999]))
            XCTFail("linked to a transaction that doesn't exist")
        } catch let error as ImportResolutionError {
            XCTAssertEqual(error, .transactionNotFound(999_999))
        }
        XCTAssertThrowsError(try ImportResolutions.apply(.addTransactionLink(999_999), to: item))
        // At least one transaction.
        XCTAssertThrowsError(try ImportResolutions.apply(.linkTransactions([]), to: item))
    }

    // MARK: Corrections on Ready items

    func testEditingAFigureOnAReadyP60ForAFiledYearHoldsIt() async throws {
        let ready = try await resolve(p60Item(pay: 4_000_000), .confirmFigure(.pay, .money(4_000_000, .gbp)))
        XCTAssertEqual(ready.section, .ready, "\(ready.needsYouReasons)")
        let edited = try await resolve(ready, .confirmFigure(.pay, .money(4_100_000, .gbp)))
        XCTAssertEqual(edited.facts.first { $0.field == .pay }?.source, .user)
        XCTAssertEqual(edited.section, .needsYou)
        XCTAssertTrue(edited.isHeldByFiledYear, "\(edited.issues)")
    }

    func testReadyItemsTakeKindAndTargetCorrections() throws {
        let item = receiptItem()
        // Read again by the reader (nil), never refused.
        XCTAssertNil(try ImportResolutions.apply(.chooseKind(.p60), to: item))
        // A target only of the kind the item's reader reads (an invoice's provider).
        XCTAssertNil(try ImportResolutions.apply(.chooseTarget(.provider, id("provider")), to: invoiceItem()))
        XCTAssertThrowsError(try ImportResolutions.apply(.chooseTarget(.property, id("property")), to: item))
        XCTAssertThrowsError(try ImportResolutions.apply(.chooseTarget(.person, id("A")), to: invoiceItem()))
        let edited = try XCTUnwrap(try ImportResolutions.apply(.confirmFigure(.amount, .money(1_500, .gbp)), to: item))
        XCTAssertEqual(edited.facts.first { $0.field == .amount }?.value, .money(1_500, .gbp))
    }

    func testAChosenTargetMustExist() async throws {
        await XCTAssertThrowsAsync(try await self.resolve(self.invoiceItem(), .chooseTarget(.provider, 999_999)))
    }

    // MARK: Search

    func testSearchFindsByText() throws {
        let found = try db.read { db in try ImportTransactionSearch.search(db: db, query: ImportTransactionQuery(text: "shop")) }
        // Newest first, with what the peek shows.
        XCTAssertEqual(found.map(\.id), [id("beta"), id("elsewhere"), id("alpha")])
        let alpha = try XCTUnwrap(found.last)
        XCTAssertEqual(alpha.accountName, "Bank A")
        XCTAssertEqual(alpha.description, "SHOP ALPHA")
        XCTAssertEqual(alpha.amountMinorUnits, -1_200)
        XCTAssertEqual(alpha.currency, .gbp)
        XCTAssertEqual(alpha.categoryName, "Shopping")
        XCTAssertEqual(alpha.documentNames, [])
    }

    func testSearchFindsByAmountDateWindowAndAccount() throws {
        try db.read { db in
            let byAmount = try ImportTransactionSearch.search(db: db, query: ImportTransactionQuery(amountMinorUnits: 1_200))
            XCTAssertEqual(byAmount.map(\.id), [self.id("elsewhere"), self.id("alpha")])
            let window = try ImportTransactionSearch.search(db: db, query: ImportTransactionQuery(from: Self.date(2025, 3, 2), to: Self.date(2025, 4, 2)))
            XCTAssertEqual(window.map(\.id), [self.id("part1"), self.id("beta"), self.id("elsewhere")])
            let account = try ImportTransactionSearch.search(db: db, query: ImportTransactionQuery(amountMinorUnits: 1_200, accountId: self.id("bank")))
            XCTAssertEqual(account.map(\.id), [self.id("alpha")])
        }
    }

    func testSearchShowsDocumentsAlreadyLinkedAndIsCapped() throws {
        let documentId = try db.write { db -> Int64 in
            let documentId = try FiledYearGuard.placeholderDocument(db: db, item: self.receiptItem())
            try EvidenceLinks.link(db: db, documentId: documentId, to: .transaction(self.id("alpha")))
            return documentId
        }
        let name = try db.read { db in try EvidenceDocument.fetchOne(db, key: documentId)!.displayName }
        let found = try db.read { db in try ImportTransactionSearch.candidates(db: db, ids: [self.id("alpha")]) }
        XCTAssertEqual(found.first?.documentNames, [name])
        let capped = try db.read { db in
            try ImportTransactionSearch.search(db: db, query: ImportTransactionQuery(from: Self.date(2025, 1, 1)), limit: 2)
        }
        XCTAssertEqual(capped.count, 2)
        // Nothing to search by: nothing read.
        let unfiltered = try db.read { db in
            try ImportTransactionSearch.search(db: db, query: ImportTransactionQuery(accountId: self.id("bank")))
        }
        XCTAssertEqual(unfiltered, [])
    }

    func testSuggestedQueryComesFromTheItemsFigures() {
        let query = ImportTransactionQuery.suggested(for: receiptItem())
        XCTAssertEqual(query.text, "")
        XCTAssertEqual(query.amountMinorUnits, 1_200)
        XCTAssertEqual(query.from, Self.date(2025, 2, 1))
        XCTAssertEqual(query.to, Self.date(2025, 5, 1))
    }
}

/// Reads every file as a P60 item (its effect from `p60`) when its kind is a P60, else as a document.
private struct KindReader: ImportReader {
    let p60: ImportItem

    func handles(_ kind: ImportKind) -> Bool { true }

    func propose(_ files: [(file: ImportFile, recognition: ImportRecognition)], context: ImportContext, db: Database) throws -> [ImportItem] {
        files.map { file in
            guard file.recognition.kind == .payrollForm(.p60) else {
                return ImportItem(file: file.file, recognition: file.recognition, title: file.file.fileName)
            }
            var item = p60
            item.id = UUID()
            item.file = file.file
            item.recognition = file.recognition
            return item
        }
    }
}

private func XCTAssertThrowsAsync<T>(_ body: @autoclosure () async throws -> T, file: StaticString = #filePath, line: UInt = #line) async {
    do {
        _ = try await body()
        XCTFail("no error thrown", file: file, line: line)
    } catch {}
}
