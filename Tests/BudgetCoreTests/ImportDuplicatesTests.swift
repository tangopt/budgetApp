import XCTest
import GRDB
@testable import BudgetCore

/// The batch-level duplicate pass: same file (hash) and same document in a different file
/// (ATCUD, invoice number, receipt number, payment reference, issuer + date + amount), against
/// the library and within the batch; plus transactions claimed twice. Synthetic data only.
final class ImportDuplicatesTests: XCTestCase {
    private var manager: DatabaseManager!
    private var db: DatabaseQueue { manager.dbQueue }
    private var propertyId: Int64!
    private var accountId: Int64!
    private var batchId: Int64!

    override func setUpWithError() throws {
        manager = try DatabaseManager(path: nil)
        try manager.migrate()
        try db.write { db in
            var property = Property(name: "Property A", country: "PT")
            try Properties.save(db: db, &property)
            propertyId = property.id!
            var account = Account(name: "Bank A", currency: .eur, kind: .cash, trackingMode: .imported)
            try account.insert(db)
            accountId = account.id!
            var batch = ImportBatch(accountId: accountId, sourceFileName: "bank.csv", importedAt: Date())
            try batch.insert(db)
            batchId = batch.id!
        }
    }

    private static func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        MonthRange.calendar.date(from: DateComponents(year: y, month: m, day: d))!
    }

    private func file(_ name: String, sha: String, text: String? = nil) -> ImportFile {
        ImportFile(url: URL(fileURLWithPath: "/nonexistent/\(name)"), fileName: name, sha256: sha, byteCount: 100,
                   fileExtension: "pdf", text: text, textStatus: text == nil ? .noText : .text, usedOCR: false)
    }

    private func item(_ name: String, sha: String, kind: ImportKind = .evidence(.insuranceReceipt), text: String? = nil,
                      facts: [ImportFact] = [], links: [ProposedLink] = [], effect: ImportEffect = .file) -> ImportItem {
        ImportItem(file: file(name, sha: sha, text: text), recognition: ImportRecognition(kind: kind, confidence: .certain, reason: "test"),
                   title: name, facts: facts, links: links, effect: effect)
    }

    private func fact(_ field: ImportFigureField, _ value: ImportFactValue) -> ImportFact {
        ImportFact(field: field, value: value, source: .textLayer, confidence: .certain, reason: "test")
    }

    @discardableResult
    private func libraryDocument(sha: String, name: String, kind: DocumentKind = .insuranceReceipt, docDate: Date? = nil,
                                 amount: Int? = nil, text: String? = nil) throws -> Int64 {
        try db.write { db in
            var document = EvidenceDocument(sha256: sha, storedRelativePath: "\(sha.prefix(2))/\(sha).pdf", originalFileName: "\(name).pdf",
                                            byteCount: 100, canonicalName: name, kind: kind, docDate: docDate,
                                            amountMinorUnits: amount, currency: amount == nil ? nil : .eur,
                                            textStatus: text == nil ? .noText : .text, extractedText: text, addedAt: Date())
            try document.insert(db)
            return document.id!
        }
    }

    private func transaction(_ amount: Int, _ text: String) throws -> Int64 {
        try db.write { db in
            var transaction = Transaction(importBatchId: batchId, accountId: accountId, date: Self.date(2023, 3, 6), rawDescription: text,
                                          amountMinorUnits: amount, categoryId: nil, status: .confirmed, categorizedBy: .manual,
                                          fingerprint: UUID().uuidString)
            try transaction.insert(db)
            return transaction.id!
        }
    }

    private func annotate(_ items: [ImportItem]) throws -> [ImportItem] {
        try db.read { db in try ImportDuplicates.annotate(items, db: db) }
    }

    // MARK: Identity keys

    func testIdentityKeys() {
        let keys = DocumentIdentity.keys(kind: .utilityInvoice,
                                         text: "Demo Power\nATCUD:ABCD1234-77\nPay with reference 123 456 789 012",
                                         facts: [fact(.issuer, .text("Démo Power")), fact(.invoiceNumber, .text("FT 1/23")),
                                                 fact(.docDate, .date(Self.date(2023, 3, 5))), fact(.amount, .money(-10000, .eur))],
                                         providerId: 7)
        // The issuer-based key keeps the sign (a credit note is not the invoice); the kind-based one is sign-free.
        XCTAssertEqual(keys, ["atcud:ABCD1234-77", "invoice:7:FT1/23", "ref:123456789012", "ida:demopower:20230305:-10000",
                              "ida:utilityInvoice:20230305:10000"])
        let receipt = DocumentIdentity.keys(kind: .rentReceiptPDF, text: nil,
                                            facts: [fact(.reference, .text("998877")), fact(.receiptNumber, .text("12")),
                                                    fact(.docDate, .date(Self.date(2023, 3, 5))), fact(.amount, .money(80000, .eur))],
                                            providerId: nil)
        XCTAssertEqual(receipt, ["receipt:998877:12", "ida:rentReceipt:20230305:80000"])
        // Statements are checked at the transaction level, not as documents.
        XCTAssertEqual(DocumentIdentity.keys(kind: .bankStatementPDF, text: "ATCUD:ABCD1234-77", facts: [], providerId: nil), [])
        let p60 = DocumentIdentity.keys(kind: .payrollForm(.p60), text: nil,
                                        facts: [fact(.issuer, .text("Demo Employer Ltd")), fact(.taxYear, .year(2022))],
                                        providerId: nil, personId: 3)
        XCTAssertEqual(p60, ["payroll:p60:2022:demoemployerltd:3"])
    }

    // MARK: Same file

    func testSameHashAsLibraryDocumentIsFileDuplicate() throws {
        let id = try libraryDocument(sha: "aaa", name: "20230305 - Property - Insurance receipt")
        let annotated = try annotate([item("receipt.pdf", sha: "aaa")])
        XCTAssertEqual(annotated[0].section, .duplicates)
        XCTAssertEqual(annotated[0].duplicate, ImportDuplicate(level: .file, of: "Already in the library as 20230305 - Property - Insurance receipt",
                                                               existingDocumentId: id))
    }

    func testSameFileTwiceInOneBatchIsOneReadyOneDuplicate() throws {
        let annotated = try annotate([item("a.pdf", sha: "bbb"), item("copy of a.pdf", sha: "bbb")])
        XCTAssertEqual(annotated.map(\.section), [.ready, .duplicates])
        XCTAssertEqual(annotated[1].duplicate, ImportDuplicate(level: .file, of: "Same file as a.pdf"))
    }

    // MARK: Same document

    func testSameDocumentTwiceInOneBatchIsOneReadyOneDuplicate() throws {
        let annotated = try annotate([
            item("invoice-a.pdf", sha: "c1", text: "Demo Insurer\nATCUD:ABCD1234-77\nTotal 120,00"),
            item("invoice-b.pdf", sha: "c2", text: "DEMO INSURER copy\nATCUD: ABCD1234-77")
        ])
        XCTAssertEqual(annotated.map(\.section), [.ready, .duplicates])
        XCTAssertEqual(annotated[1].duplicate?.level, .document)
        XCTAssertEqual(annotated[1].duplicate?.of, "Same document as invoice-a.pdf")
    }

    func testATCUDInLibraryTextIsDocumentDuplicate() throws {
        let id = try libraryDocument(sha: "d0", name: "Insurance receipt March", text: "Demo Insurer ATCUD:ABCD1234-77")
        let annotated = try annotate([item("scan.pdf", sha: "d1", text: "ATCUD:ABCD1234-77")])
        XCTAssertEqual(annotated[0].duplicate, ImportDuplicate(level: .document, of: "Same document as Insurance receipt March",
                                                               existingDocumentId: id))
    }

    func testInvoiceNumberPerProviderMatchesRecordedInvoice() throws {
        let documentId = try libraryDocument(sha: "e0", name: "20230305 - Utilities - Invoice - Demo Power", kind: .utilityInvoice)
        let (providerId, otherProviderId) = try db.write { db -> (Int64, Int64) in
            var power = UtilityProvider(propertyId: propertyId, name: "Demo Power", kind: .electricity)
            try Recharges.saveProvider(db: db, &power)
            var water = UtilityProvider(propertyId: propertyId, name: "Demo Water", kind: .water)
            try Recharges.saveProvider(db: db, &water)
            var invoice = UtilityInvoice(providerId: power.id!, invoiceNumber: "FT 1/23", issueDate: Self.date(2023, 3, 5),
                                         amountMinorUnits: 10000, documentId: documentId)
            try invoice.insert(db)
            return (power.id!, water.id!)
        }
        func invoiceItem(_ name: String, sha: String, provider: Int64) -> ImportItem {
            item(name, sha: sha, kind: .utilityInvoice, facts: [fact(.invoiceNumber, .text("FT 1/23"))],
                 effect: .utilityInvoice(UtilityInvoice(providerId: provider, invoiceNumber: "FT 1/23", issueDate: Self.date(2023, 3, 9),
                                                        amountMinorUnits: 4500)))
        }
        let annotated = try annotate([invoiceItem("power.pdf", sha: "e1", provider: providerId),
                                      invoiceItem("water.pdf", sha: "e2", provider: otherProviderId)])
        XCTAssertEqual(annotated[0].duplicate, ImportDuplicate(level: .document, of: "Same document as 20230305 - Utilities - Invoice - Demo Power",
                                                               existingDocumentId: documentId))
        XCTAssertNil(annotated[1].duplicate, "the same number of another provider is another invoice")
    }

    func testReceiptNumberPerContractMatchesLinkedReceipt() throws {
        let documentId = try libraryDocument(sha: "f0", name: "Rent receipt 12", kind: .rentReceipt)
        try db.write { db in
            var tenancy = Tenancy(propertyId: propertyId, referenceLabel: "Flat", contractNumber: "998877", startDate: Self.date(2022, 1, 1))
            try Tenancies.save(db: db, &tenancy)
            var receipt = RentReceipt(tenancyId: tenancy.id!, receiptNumber: "12", periodStart: Self.date(2023, 3, 1),
                                      periodEnd: Self.date(2023, 3, 31), receiptDate: nil, amountMinorUnits: 80000)
            try RentReceipts.save(db: db, &receipt)
            try EvidenceLinks.link(db: db, documentId: documentId, to: EvidenceEntity(type: .rentReceipt, id: receipt.id!))
        }
        let annotated = try annotate([item("recibo.pdf", sha: "f1", kind: .rentReceiptPDF,
                                           facts: [fact(.reference, .text("998877")), fact(.receiptNumber, .text("12"))])])
        XCTAssertEqual(annotated[0].duplicate?.of, "Same document as Rent receipt 12")
        XCTAssertEqual(annotated[0].duplicate?.existingDocumentId, documentId)
    }

    func testIssuerDateAmountMatchesLibraryDocument() throws {
        try libraryDocument(sha: "g0", name: "Insurance March", docDate: Self.date(2023, 3, 5), amount: 12000)
        let annotated = try annotate([item("insurance.pdf", sha: "g1", facts: [fact(.docDate, .date(Self.date(2023, 3, 5))),
                                                                                fact(.amount, .money(12000, .eur))])])
        // Issuer + date + amount is a weak identity: it asks, it never skips.
        XCTAssertNil(annotated[0].duplicate)
        XCTAssertEqual(annotated[0].needsYouReasons, ["Possibly the same document as Insurance March"])
        XCTAssertEqual(annotated[0].issues[0].kind, .readerProblem("Possibly the same document as Insurance March"))
    }

    func testSameAmountDifferentDateIsNotADuplicate() throws {
        try libraryDocument(sha: "h0", name: "Insurance March", docDate: Self.date(2023, 3, 5), amount: 12000)
        let annotated = try annotate([item("insurance-april.pdf", sha: "h1", facts: [fact(.docDate, .date(Self.date(2023, 4, 5))),
                                                                                      fact(.amount, .money(12000, .eur))])])
        XCTAssertNil(annotated[0].duplicate)
        XCTAssertEqual(annotated[0].section, .ready)
    }

    func testPaymentReferenceAloneNeverMatches() throws {
        // The invoice and the proof of its payment print the same reference: different documents.
        try libraryDocument(sha: "i0", name: "Transfer proof", kind: .bankTransferProof, text: "Reference 123 456 789 012")
        // A recurring number (policy number) on last month's receipt of the same amount: another date, another receipt.
        try libraryDocument(sha: "i1", name: "Insurance February", docDate: Self.date(2023, 2, 5), amount: 12000,
                            text: "Policy 987654321098")
        // A reference with no date or amount to corroborate it.
        try libraryDocument(sha: "i2", name: "Insurance March", text: "Reference 555 666 777 888")
        let annotated = try annotate([
            item("a.pdf", sha: "j1", text: "Pay with reference 123456789012"),
            item("b.pdf", sha: "j2", text: "Policy 987654321098",
                 facts: [fact(.docDate, .date(Self.date(2023, 3, 5))), fact(.amount, .money(12000, .eur))]),
            item("c.pdf", sha: "j3", text: "Ref. 555666777888")
        ])
        XCTAssertEqual(annotated.map(\.section), [.ready, .ready, .ready])
    }

    func testReferenceSharedInsideTheBatchIdentifiesNone() {
        // With kind, date and amount required on both sides, the kind-based ida key already
        // matches whatever a reference would: the drop is checked on the index itself.
        func entry(_ label: String, day: String) -> DocumentIdentityIndex.Entry {
            var identity = DocumentIdentity.Identity()
            identity.weak = ["ref:987654321098"]
            identity.kind = .insuranceReceipt
            identity.day = day
            identity.amount = 12000
            return DocumentIdentityIndex.Entry(documentId: nil, label: label, identity: identity)
        }
        var index = DocumentIdentityIndex()
        index.add(entry("mar.pdf", day: "20230305"))
        XCTAssertNotNil(index.match(entry("mar-copy.pdf", day: "20230305").identity), "one document printing it: corroborates")
        index.add(entry("feb.pdf", day: "20230205"))
        XCTAssertNil(index.match(entry("mar-copy.pdf", day: "20230305").identity), "printed by two documents: identifies neither")
    }

    func testKindKeyMatchesWhicheverSideNamesNoIssuer() throws {
        let issuer = fact(.issuer, .text("Demo Insurer"))
        func receipt(_ name: String, issuer: ImportFact?) -> ImportItem {
            item(name, sha: name, facts: [issuer, fact(.docDate, .date(Self.date(2023, 3, 5))), fact(.amount, .money(12000, .eur))].compactMap { $0 })
        }
        let named = try annotate([receipt("named.pdf", issuer: issuer), receipt("unnamed.pdf", issuer: nil)])
        XCTAssertEqual(named[1].needsYouReasons, ["Possibly the same document as named.pdf"])
        let unnamed = try annotate([receipt("unnamed.pdf", issuer: nil), receipt("named.pdf", issuer: issuer)])
        XCTAssertEqual(unnamed[1].needsYouReasons, ["Possibly the same document as unnamed.pdf"])
    }

    func testStrongBatchMatchWinsOverWeakLibraryMatch() throws {
        try libraryDocument(sha: "u0", name: "Insurance March", docDate: Self.date(2023, 3, 5), amount: 12000)
        let facts = [fact(.docDate, .date(Self.date(2023, 3, 5))), fact(.amount, .money(12000, .eur))]
        let annotated = try annotate([item("invoice-a.pdf", sha: "u1", text: "ATCUD:ABCD1234-77", facts: facts),
                                      item("invoice-b.pdf", sha: "u2", text: "ATCUD:ABCD1234-77", facts: facts)])
        XCTAssertEqual(annotated[0].needsYouReasons, ["Possibly the same document as Insurance March"])
        XCTAssertEqual(annotated[1].duplicate, ImportDuplicate(level: .document, of: "Same document as invoice-a.pdf"))
    }

    // MARK: Weak matches never skip

    func testSameDayReceiptsOfOneContractAreNotDuplicates() throws {
        func receipt(_ number: String) -> ImportItem {
            item("recibo-\(number).pdf", sha: number, kind: .rentReceiptPDF,
                 facts: [fact(.reference, .text("998877")), fact(.receiptNumber, .text(number)),
                         fact(.docDate, .date(Self.date(2023, 3, 1))), fact(.amount, .money(80000, .eur))])
        }
        let annotated = try annotate([receipt("12"), receipt("13")])
        XCTAssertEqual(annotated.map(\.section), [.ready, .ready])
    }

    func testDifferentATCUDsSharingAReferenceAreNotDuplicates() throws {
        let facts = [fact(.docDate, .date(Self.date(2023, 3, 5))), fact(.amount, .money(12000, .eur))]
        let annotated = try annotate([item("a.pdf", sha: "o1", text: "ATCUD:AAAA1111-1 Ref 123456789012", facts: facts),
                                      item("b.pdf", sha: "o2", text: "ATCUD:BBBB2222-2 Ref 123456789012", facts: facts)])
        XCTAssertEqual(annotated.map(\.section), [.ready, .ready])
    }

    func testInvoiceAndCreditNoteOfTheSameDayAndAmountAreNotDuplicates() throws {
        func invoice(_ name: String, _ amount: Int) -> ImportItem {
            item(name, sha: name, kind: .utilityInvoice,
                 facts: [fact(.issuer, .text("Demo Power")), fact(.docDate, .date(Self.date(2023, 3, 5))), fact(.amount, .money(amount, .eur))])
        }
        let annotated = try annotate([invoice("invoice.pdf", 10000), invoice("credit.pdf", -10000)])
        XCTAssertEqual(annotated.map(\.section), [.ready, .ready])
    }

    func testUtilityInvoiceDocumentWithoutRecordedInvoiceIsPossiblySameDocument() throws {
        try libraryDocument(sha: "q0", name: "20230305 - Utilities - Invoice", kind: .utilityInvoice, docDate: Self.date(2023, 3, 5), amount: 10000)
        let annotated = try annotate([item("power.pdf", sha: "q1", kind: .utilityInvoice,
                                           facts: [fact(.issuer, .text("Demo Power")), fact(.docDate, .date(Self.date(2023, 3, 5))),
                                                   fact(.amount, .money(10000, .eur))])])
        XCTAssertNil(annotated[0].duplicate)
        XCTAssertEqual(annotated[0].needsYouReasons, ["Possibly the same document as 20230305 - Utilities - Invoice"])
        XCTAssertEqual(annotated[0].issues[0].offers, [.acknowledge, .leaveOut])
    }

    func testRedownloadedP60IsADuplicate() throws {
        let (personId, documentId) = try db.write { db -> (Int64, Int64) in
            var person = Person(name: "Person A")
            try People.save(db: db, &person)
            var document = EvidenceDocument(sha256: "p0", storedRelativePath: "p0/p0.pdf", originalFileName: "p60.pdf", byteCount: 100,
                                            canonicalName: "Tax - P60 Demo Employer Ltd 2022-23", kind: .p60, addedAt: Date())
            try document.insert(db)
            try PayrollFormImport.apply(db: db, PayrollFormImport.Confirmed(kind: .p60, personId: person.id!, startYear: 2022,
                                                                             employerName: "Demo Employer Ltd", payMinorUnits: 3_000_000,
                                                                             taxDeductedMinorUnits: 400_000),
                                        documentId: document.id!)
            return (person.id!, document.id!)
        }
        let confirmed = PayrollFormImport.Confirmed(kind: .p60, personId: personId, startYear: 2022, employerName: "DEMO EMPLOYER LTD",
                                                    payMinorUnits: 3_000_000, taxDeductedMinorUnits: 400_000)
        let annotated = try annotate([item("P60 again.pdf", sha: "p1", kind: .payrollForm(.p60),
                                           facts: [fact(.issuer, .text("DEMO EMPLOYER LTD")), fact(.taxYear, .year(2022))],
                                           effect: .payrollForm(confirmed))])
        XCTAssertEqual(annotated[0].duplicate, ImportDuplicate(level: .document, of: "Same document as Tax - P60 Demo Employer Ltd 2022-23",
                                                               existingDocumentId: documentId))
    }

    // MARK: Corrected versions

    /// A P60 of the same person, year and employer whose pay differs from the stored figure is
    /// a corrected P60, not a copy: the user decides (and the filed-year guard still sees it).
    func testCorrectedP60IsPossiblyACorrectedVersion() throws {
        let personId = try db.write { db -> Int64 in
            var person = Person(name: "Person A")
            try People.save(db: db, &person)
            var document = EvidenceDocument(sha256: "p0", storedRelativePath: "p0/p0.pdf", originalFileName: "p60.pdf", byteCount: 100,
                                            canonicalName: "Tax - P60 Demo Employer Ltd 2022-23", kind: .p60, addedAt: Date())
            try document.insert(db)
            try PayrollFormImport.apply(db: db, PayrollFormImport.Confirmed(kind: .p60, personId: person.id!, startYear: 2022,
                                                                             employerName: "Demo Employer Ltd", payMinorUnits: 3_000_000,
                                                                             taxDeductedMinorUnits: 400_000),
                                        documentId: document.id!)
            return person.id!
        }
        func p60(_ name: String, sha: String, pay: Int) -> ImportItem {
            let confirmed = PayrollFormImport.Confirmed(kind: .p60, personId: personId, startYear: 2022, employerName: "Demo Employer Ltd",
                                                        payMinorUnits: pay, taxDeductedMinorUnits: 400_000)
            return item(name, sha: sha, kind: .payrollForm(.p60),
                        facts: [fact(.issuer, .text("Demo Employer Ltd")), fact(.taxYear, .year(2022)),
                                fact(.pay, .money(pay, .gbp)), fact(.taxDeducted, .money(400_000, .gbp))],
                        effect: .payrollForm(confirmed))
        }
        let annotated = try annotate([p60("P60 corrected.pdf", sha: "p2", pay: 3_100_000), p60("P60 again.pdf", sha: "p3", pay: 3_000_000)])
        XCTAssertNil(annotated[0].duplicate)
        XCTAssertEqual(annotated[0].section, .needsYou)
        let issue = try XCTUnwrap(annotated[0].issues.first { $0.id == "correctedVersion" })
        XCTAssertEqual(issue.reason, "Possibly a corrected version of Tax - P60 Demo Employer Ltd 2022-23: Pay £30,000.00 → £31,000.00")
        XCTAssertEqual(issue.offers, [.acknowledge, .leaveOut])
        // The same figures as stored: a copy, as before.
        XCTAssertEqual(annotated[1].duplicate?.level, .document)
    }

    private func recordedInvoice(amount: Int) throws -> (providerId: Int64, documentId: Int64) {
        let documentId = try libraryDocument(sha: "i0", name: "20230305 - Utilities - Invoice - Demo Power", kind: .utilityInvoice,
                                             docDate: Self.date(2023, 3, 5), amount: amount)
        let providerId = try db.write { db -> Int64 in
            var power = UtilityProvider(propertyId: propertyId, name: "Demo Power", kind: .electricity)
            try Recharges.saveProvider(db: db, &power)
            var invoice = UtilityInvoice(providerId: power.id!, invoiceNumber: "FT 1/23", issueDate: Self.date(2023, 3, 5),
                                         amountMinorUnits: amount, documentId: documentId)
            try invoice.insert(db)
            return power.id!
        }
        return (providerId, documentId)
    }

    private func reissuedInvoice(providerId: Int64, amount: Int) -> ImportItem {
        item("reissued.pdf", sha: "i1", kind: .utilityInvoice,
             facts: [fact(.invoiceNumber, .text("FT 1/23")), fact(.docDate, .date(Self.date(2023, 4, 5))), fact(.amount, .money(amount, .eur))],
             effect: .utilityInvoice(UtilityInvoice(providerId: providerId, invoiceNumber: "FT 1/23", issueDate: Self.date(2023, 4, 5),
                                                    amountMinorUnits: amount)))
    }

    func testReissuedInvoiceWithTheSameAmountIsStillADuplicate() throws {
        let (providerId, documentId) = try recordedInvoice(amount: 10_000)
        let annotated = try annotate([reissuedInvoice(providerId: providerId, amount: 10_000)])
        XCTAssertEqual(annotated[0].duplicate, ImportDuplicate(level: .document, of: "Same document as 20230305 - Utilities - Invoice - Demo Power",
                                                               existingDocumentId: documentId))
    }

    func testInvoiceWithTheSameNumberAndAnotherAmountIsPossiblyACorrectedVersion() throws {
        let (providerId, _) = try recordedInvoice(amount: 10_000)
        let annotated = try annotate([reissuedInvoice(providerId: providerId, amount: 12_000)])
        XCTAssertNil(annotated[0].duplicate)
        let issue = try XCTUnwrap(annotated[0].issues.first { $0.id == "correctedVersion" })
        XCTAssertEqual(issue.reason, "Possibly a corrected version of 20230305 - Utilities - Invoice - Demo Power: Amount €100.00 → €120.00")
        // Not recorded again (the number is the recorded invoice's): only its document is filed.
        XCTAssertEqual(issue.offers, [.fileWithoutLink, .leaveOut])
    }

    /// Two different files of the same corrected P60: the first is the corrected version, the
    /// second a copy of it (not a second correction).
    /// A recorded invoice FT 1/23 (€100.00, its own document) paid by a debit that `other`
    /// (a document of `text` for `amount`) is linked to as well, optionally another invoice's own document.
    private func invoiceOnDebit(otherText text: String, amount: Int, otherIsInvoice number: String? = nil) throws -> Int64 {
        let own = try libraryDocument(sha: "t0", name: "Invoice FT 1-23", kind: .utilityInvoice, amount: 10_000, text: "Demo Power invoice FT 1/23")
        let other = try libraryDocument(sha: "t1", name: "Other invoice document", kind: .utilityInvoice, amount: amount, text: text)
        let debit = try transaction(-10_000, "DEMO POWER DD")
        return try db.write { db -> Int64 in
            var power = UtilityProvider(propertyId: propertyId, name: "Demo Power", kind: .electricity)
            try Recharges.saveProvider(db: db, &power)
            var invoice = UtilityInvoice(providerId: power.id!, invoiceNumber: "FT 1/23", issueDate: Self.date(2023, 3, 5),
                                         amountMinorUnits: 10_000, documentId: own, transactionId: debit)
            try invoice.insert(db)
            if let number {
                var second = UtilityInvoice(providerId: power.id!, invoiceNumber: number, issueDate: Self.date(2023, 3, 6),
                                            amountMinorUnits: amount, documentId: other, transactionId: debit)
                try second.insert(db)
            }
            for document in [own, other] { _ = try EvidenceLinks.link(db: db, documentId: document, to: .transaction(debit)) }
            return power.id!
        }
    }

    private func invoiceFT123(providerId: Int64, amount: Int) -> ImportItem {
        item("ft-1-23.pdf", sha: "t2", kind: .utilityInvoice,
             facts: [fact(.invoiceNumber, .text("FT 1/23")), fact(.amount, .money(amount, .eur))],
             effect: .utilityInvoice(UtilityInvoice(providerId: providerId, invoiceNumber: "FT 1/23", issueDate: Self.date(2023, 3, 5),
                                                    amountMinorUnits: amount)))
    }

    /// "FT 1/234" on a document of the same debit isn't invoice FT 1/23.
    func testInvoiceNumberOnTheSameDebitMatchesOnlyAsAWholeNumber() throws {
        let providerId = try invoiceOnDebit(otherText: "Demo Power invoice FT 1/234", amount: 15_000)
        let annotated = try annotate([invoiceFT123(providerId: providerId, amount: 15_000)])
        XCTAssertNil(annotated[0].duplicate)
        XCTAssertTrue(annotated[0].issues.contains { $0.id == "correctedVersion" })
    }

    /// Another recorded invoice's own document on the same debit, mentioning FT 1/23, is that invoice, not FT 1/23.
    func testAnotherRecordedInvoicesDocumentOnTheSameDebitIsNotThisInvoice() throws {
        let providerId = try invoiceOnDebit(otherText: "Demo Power invoice FT 2/23 (replaces FT 1/23)", amount: 15_000, otherIsInvoice: "FT 2/23")
        let annotated = try annotate([invoiceFT123(providerId: providerId, amount: 15_000)])
        XCTAssertNil(annotated[0].duplicate)
        XCTAssertTrue(annotated[0].issues.contains { $0.id == "correctedVersion" })
    }

    func testTwoCopiesOfACorrectedP60AreOneCorrectionAndOneCopy() throws {
        let personId = try db.write { db -> Int64 in
            var person = Person(name: "Person A")
            try People.save(db: db, &person)
            var document = EvidenceDocument(sha256: "q0", storedRelativePath: "q0/q0.pdf", originalFileName: "p60.pdf", byteCount: 100,
                                            canonicalName: "Tax - P60 Demo Employer Ltd 2022-23", kind: .p60, addedAt: Date())
            try document.insert(db)
            try PayrollFormImport.apply(db: db, PayrollFormImport.Confirmed(kind: .p60, personId: person.id!, startYear: 2022,
                                                                             employerName: "Demo Employer Ltd", payMinorUnits: 3_000_000,
                                                                             taxDeductedMinorUnits: 400_000),
                                        documentId: document.id!)
            return person.id!
        }
        func p60(_ name: String, sha: String) -> ImportItem {
            let confirmed = PayrollFormImport.Confirmed(kind: .p60, personId: personId, startYear: 2022, employerName: "Demo Employer Ltd",
                                                        payMinorUnits: 3_100_000, taxDeductedMinorUnits: 400_000)
            return item(name, sha: sha, kind: .payrollForm(.p60),
                        facts: [fact(.issuer, .text("Demo Employer Ltd")), fact(.taxYear, .year(2022)),
                                fact(.pay, .money(3_100_000, .gbp)), fact(.taxDeducted, .money(400_000, .gbp))],
                        effect: .payrollForm(confirmed))
        }
        let annotated = try annotate([p60("P60 corrected.pdf", sha: "q1"), p60("P60 corrected scan.pdf", sha: "q2")])
        XCTAssertTrue(annotated[0].issues.contains { $0.id == "correctedVersion" })
        XCTAssertEqual(annotated[1].duplicate, ImportDuplicate(level: .document, of: "Same document as P60 corrected.pdf"))
        XCTAssertFalse(annotated[1].issues.contains { $0.id == "correctedVersion" })
    }

    func testCorrectedRentReceiptOffersFilingTheDocumentOnly() throws {
        let documentId = try libraryDocument(sha: "g0", name: "Rent receipt 12", kind: .rentReceipt, amount: 80_000)
        let receiptId = try db.write { db -> Int64 in
            var tenancy = Tenancy(propertyId: propertyId, referenceLabel: "Flat", contractNumber: "998877", startDate: Self.date(2022, 1, 1))
            try Tenancies.save(db: db, &tenancy)
            var receipt = RentReceipt(tenancyId: tenancy.id!, receiptNumber: "12", periodStart: Self.date(2023, 3, 1),
                                      periodEnd: Self.date(2023, 3, 31), receiptDate: nil, amountMinorUnits: 80_000)
            try RentReceipts.save(db: db, &receipt)
            try EvidenceLinks.link(db: db, documentId: documentId, to: EvidenceEntity(type: .rentReceipt, id: receipt.id!))
            return receipt.id!
        }
        let annotated = try annotate([item("recibo.pdf", sha: "g1", kind: .rentReceiptPDF,
                                           facts: [fact(.reference, .text("998877")), fact(.receiptNumber, .text("12")),
                                                   fact(.amount, .money(82_000, .eur))])])
        XCTAssertNil(annotated[0].duplicate)
        let issue = try XCTUnwrap(annotated[0].issues.first { $0.id == "correctedVersion" })
        XCTAssertEqual(issue.reason, "Possibly a corrected version of Rent receipt 12: Amount €800.00 → €820.00")
        XCTAssertEqual(issue.offers, [.fileWithoutLink, .leaveOut])
        XCTAssertEqual(issue.documentOnlyLinks.map(\.entity), [.rentReceipt(receiptId)])
    }

    func testCorrectedATCUDDocumentLinksWhereTheOriginalIs() throws {
        let documentId = try libraryDocument(sha: "j0", name: "Insurance receipt March", amount: 12_000, text: "Demo Insurer ATCUD:ABCD1234-77")
        let debit = try transaction(-12_000, "DEMO INSURER")
        try db.write { db in _ = try EvidenceLinks.link(db: db, documentId: documentId, to: .transaction(debit)) }
        let annotated = try annotate([item("receipt.pdf", sha: "j1", text: "ATCUD:ABCD1234-77", facts: [fact(.amount, .money(15_000, .eur))])])
        let issue = try XCTUnwrap(annotated[0].issues.first { $0.id == "correctedVersion" })
        XCTAssertEqual(issue.reason, "Possibly a corrected version of Insurance receipt March: Amount €120.00 → €150.00")
        XCTAssertEqual(issue.documentOnlyLinks.map(\.entity), [.transaction(debit)])
    }

    func testCorrectedVersionWithinTheBatch() throws {
        let annotated = try annotate([
            item("invoice-a.pdf", sha: "m1", text: "ATCUD:ABCD1234-77", facts: [fact(.amount, .money(10_000, .eur))]),
            item("invoice-b.pdf", sha: "m2", text: "ATCUD:ABCD1234-77", facts: [fact(.amount, .money(11_000, .eur))])
        ])
        XCTAssertEqual(annotated[0].section, .ready)
        XCTAssertNil(annotated[1].duplicate)
        XCTAssertEqual(annotated[1].issues.first { $0.id == "correctedVersion" }?.reason,
                       "Possibly a corrected version of invoice-a.pdf: Amount €100.00 → €110.00")
    }

    func testAnotherCurrencyIsAnotherFigure() throws {
        try libraryDocument(sha: "n0", name: "Insurance receipt March", amount: 10_000, text: "ATCUD:ABCD1234-77")
        let annotated = try annotate([item("receipt.pdf", sha: "n1", text: "ATCUD:ABCD1234-77", facts: [fact(.amount, .money(10_000, .gbp))])])
        XCTAssertNil(annotated[0].duplicate)
        XCTAssertEqual(annotated[0].issues.first { $0.id == "correctedVersion" }?.reason,
                       "Possibly a corrected version of Insurance receipt March: Amount €100.00 → £100.00")
    }

    func testSameFileIsADuplicateWhateverItsFigures() throws {
        try libraryDocument(sha: "h0", name: "Insurance receipt", docDate: Self.date(2023, 3, 5), amount: 10_000)
        let annotated = try annotate([item("receipt.pdf", sha: "h0", facts: [fact(.amount, .money(99_999, .eur))])])
        XCTAssertEqual(annotated[0].duplicate?.level, .file)
    }

    func testCopyOfACopyNamesTheOriginal() throws {
        let annotated = try annotate([item("invoice-a.pdf", sha: "r1", text: "ATCUD:ABCD1234-77"),
                                      item("invoice-b.pdf", sha: "r2", text: "ATCUD:ABCD1234-77"),
                                      item("invoice-b copy.pdf", sha: "r2")])
        XCTAssertEqual(annotated[2].duplicate?.of, "Same file as invoice-a.pdf")
    }

    func testReaderMarkedDuplicatesAndChildrenAreLeftAsTheyAre() throws {
        try libraryDocument(sha: "k0", name: "Library copy")
        var marked = item("marked.pdf", sha: "k0")
        marked.duplicate = ImportDuplicate(level: .document, of: "Receipt nº 1 already has this PDF")
        var child = item("row", sha: "k0")
        child.parentId = marked.id
        let annotated = try annotate([marked, child])
        XCTAssertEqual(annotated[0].duplicate?.of, "Receipt nº 1 already has this PDF")
        XCTAssertNil(annotated[1].duplicate)
    }

    func testReaderMarkedDuplicateWithoutLibraryIdIsNotNamedAsAnOriginal() throws {
        var marked = item("marked.pdf", sha: "v1", text: "ATCUD:ABCD1234-77")
        marked.duplicate = ImportDuplicate(level: .document, of: "Invoice FT 1/23 of Demo Power already recorded")
        let annotated = try annotate([marked, item("later.pdf", sha: "v2", text: "ATCUD:ABCD1234-77")])
        XCTAssertNil(annotated[1].duplicate, "not \"Same document as marked.pdf\": that is a copy, not the original")
    }

    // MARK: Transactions claimed twice

    func testTwoDocumentsClaimingTheSameTransactionBothNeedYou() throws {
        let transactionId = try transaction(-12000, "DEMO INSURER")
        func claiming(_ name: String, sha: String, date: Date) -> ImportItem {
            item(name, sha: sha, facts: [fact(.docDate, .date(date))],
                 links: [ProposedLink(entity: .transaction(transactionId), label: "DEMO INSURER −€120.00", confidence: .certain,
                                      reasons: ["test"])])
        }
        let annotated = try annotate([claiming("a.pdf", sha: "l1", date: Self.date(2023, 3, 5)),
                                      claiming("b.pdf", sha: "l2", date: Self.date(2023, 3, 6))])
        XCTAssertEqual(annotated.map(\.section), [.needsYou, .needsYou])
        for annotatedItem in annotated {
            XCTAssertEqual(annotatedItem.links.map(\.confidence), [.needsReview])
            XCTAssertEqual(annotatedItem.needsYouReasons, ["2 documents in this import claim the same transaction"])
        }
    }

    func testAnInvoiceAndItsTransferProofMayShareADebit() throws {
        let transactionId = try transaction(-12000, "DEMO INSURER")
        let link = ProposedLink(entity: .transaction(transactionId), label: "DEMO INSURER −€120.00", confidence: .certain, reasons: ["test"])
        let annotated = try annotate([item("insurance.pdf", sha: "s1", links: [link]),
                                      item("proof.pdf", sha: "s2", kind: .transferAdvice, links: [link])])
        XCTAssertEqual(annotated.map(\.section), [.ready, .ready])
    }

    func testTransactionWithADocumentOfTheSameKindInThisImportNeedsYou() throws {
        let transactionId = try transaction(-12000, "DEMO INSURER")
        var unsure = ProposedLink(entity: .transaction(transactionId), label: "DEMO INSURER −€120.00", confidence: .certain, reasons: ["test"])
        let sure = unsure
        unsure.confidence = .needsReview
        let annotated = try annotate([item("a.pdf", sha: "t1", facts: [fact(.docDate, .date(Self.date(2023, 3, 1)))], links: [unsure]),
                                      item("b.pdf", sha: "t2", facts: [fact(.docDate, .date(Self.date(2023, 3, 2)))], links: [sure])])
        XCTAssertTrue(annotated[1].needsYouReasons.contains("That transaction already has an insurance receipt (a.pdf)"))
    }

    func testTransactionWithADocumentOfTheSameKindNeedsYou() throws {
        let transactionId = try transaction(-12000, "DEMO INSURER")
        let existing = try libraryDocument(sha: "m0", name: "Insurance March", text: "")
        let proof = try libraryDocument(sha: "m1", name: "Transfer proof", kind: .bankTransferProof)
        try db.write { db in
            try EvidenceLinks.link(db: db, documentId: existing, to: .transaction(transactionId))
            try EvidenceLinks.link(db: db, documentId: proof, to: .transaction(transactionId))
        }
        let link = ProposedLink(entity: .transaction(transactionId), label: "DEMO INSURER −€120.00", confidence: .certain, reasons: ["test"])
        let annotated = try annotate([item("insurance.pdf", sha: "m2", links: [link])])
        XCTAssertEqual(annotated[0].section, .needsYou)
        XCTAssertEqual(annotated[0].needsYouReasons, ["That transaction already has an insurance receipt (Insurance March)"])
        XCTAssertTrue(annotated[0].issues[0].offers.contains(.acknowledge))
        XCTAssertEqual(annotated[0].links.map(\.confidence), [.certain], "linked anyway if the user confirms")
    }

    func testTransactionWithADocumentOfAnotherKindIsFine() throws {
        let transactionId = try transaction(-12000, "DEMO INSURER")
        let proof = try libraryDocument(sha: "n1", name: "Transfer proof", kind: .bankTransferProof)
        try db.write { db in _ = try EvidenceLinks.link(db: db, documentId: proof, to: .transaction(transactionId)) }
        let link = ProposedLink(entity: .transaction(transactionId), label: "DEMO INSURER −€120.00", confidence: .certain, reasons: ["test"])
        let annotated = try annotate([item("insurance.pdf", sha: "n2", links: [link])])
        XCTAssertEqual(annotated[0].section, .ready)
    }
}
