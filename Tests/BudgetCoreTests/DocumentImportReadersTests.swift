import XCTest
import GRDB
@testable import BudgetCore

/// The readers for utility invoices, payroll forms (P60/P45/P11D) and other evidence documents:
/// they propose review items and never write. Synthetic data only.
final class DocumentImportReadersTests: XCTestCase {
    private var manager: DatabaseManager!
    private var db: DatabaseQueue { manager.dbQueue }
    private var propertyId: Int64!
    private var accountId: Int64!
    private var batchId: Int64!
    private var utilitiesId: Int64!
    private var providerId: Int64!
    private var personId: Int64!
    private var created: [URL] = []

    private static let powerRules = UtilityInvoiceRules(
        textMarkers: ["DEMO POWER"], fileNameMarkers: ["LUZ"],
        invoiceNumberPatterns: [#"INVOICE NO\.?\s*(FT \d+/\d+)"#],
        issueDateLabels: ["ISSUED ON"], periodLabels: ["BILLING PERIOD:"],
        amountLabels: ["AMOUNT DUE"], refundLabels: ["AMOUNT TO REFUND"])

    private static let invoiceLines = [
        "Demo Power - customer copy",
        "Issued on: 5 de março 2023",
        "Billing period: 1 de janeiro a 28 de fevereiro 2023",
        "Amount due 100,00 EUR",
        "Invoice no. FT 1/23"
    ]

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
            providerId = power.id!
            var person = Person(name: "Person A", ukNino: "QQ 12 34 56 C")
            try People.save(db: db, &person)
            personId = person.id!
        }
    }

    override func tearDownWithError() throws {
        for url in created { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    }

    private static func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        MonthRange.calendar.date(from: DateComponents(year: y, month: m, day: d))!
    }

    @discardableResult
    private func transaction(_ date: Date, _ amount: Int, _ text: String, categoryId: Int64? = nil) throws -> Int64 {
        try db.write { db in
            var transaction = Transaction(importBatchId: batchId, accountId: accountId, date: date, rawDescription: text,
                                          amountMinorUnits: amount, categoryId: categoryId, status: .confirmed,
                                          categorizedBy: .manual, fingerprint: UUID().uuidString)
            try transaction.insert(db)
            return transaction.id!
        }
    }

    private func textFile(_ name: String, lines: [String]) throws -> ImportFile {
        let url = EvidenceTestPDFs.textPDF(lines, name: name)
        created.append(url)
        return try ImportFile.load(url, ocr: false)
    }

    private func recognised(_ file: ImportFile, _ kind: ImportKind,
                            confidence: ImportConfidence = .certain) -> (file: ImportFile, recognition: ImportRecognition) {
        (file, ImportRecognition(kind: kind, confidence: confidence, reason: "test"))
    }

    private func context(intent: ImportIntent = .none) throws -> ImportContext {
        try db.read { try ImportContext.load(db: $0, intent: intent, now: Self.date(2024, 6, 1)) }
    }

    private func propose(_ reader: some ImportReader, _ entry: (file: ImportFile, recognition: ImportRecognition),
                         intent: ImportIntent = .none) throws -> ImportItem {
        let context = try context(intent: intent)
        return try XCTUnwrap(try db.read { try reader.propose([entry], context: context, db: $0) }.first)
    }

    // MARK: Utility invoices

    func testInvoiceWithExactDebitIsReadyAndLinked() throws {
        let debit = try transaction(Self.date(2023, 3, 20), -10_000, "DEMO PWR DD 123", categoryId: utilitiesId)
        let entry = recognised(try textFile("invoice.pdf", lines: Self.invoiceLines), .utilityInvoice)
        let item = try propose(UtilityInvoiceImportReader(), entry)
        XCTAssertEqual(item.section, .ready, "\(item.needsYouReasons)")
        XCTAssertEqual(item.links.count, 1)
        XCTAssertEqual(item.links.first?.entity, .transaction(debit))
        XCTAssertEqual(item.links.first?.confidence, .certain)
        XCTAssertEqual(item.links.first?.madeByEffect, true)
        XCTAssertFalse(item.links.first?.reasons.isEmpty ?? true)
        guard case .utilityInvoice(let invoice) = item.effect else { return XCTFail("effect \(item.effect)") }
        XCTAssertEqual(invoice.providerId, providerId)
        XCTAssertEqual(invoice.invoiceNumber, "FT 1/23")
        XCTAssertEqual(invoice.amountMinorUnits, 10_000)
        XCTAssertEqual(invoice.transactionId, debit)
        XCTAssertEqual(item.placement?.metadata.kind, .utilityInvoice)
        // Read-only: nothing recorded.
        XCTAssertEqual(try db.read { try UtilityInvoice.fetchCount($0) }, 0)
    }

    func testInvoiceAlreadyRecordedIsDuplicate() throws {
        try db.write { db in
            var invoice = UtilityInvoice(providerId: providerId, invoiceNumber: "FT 1/23", periodStart: Self.date(2023, 1, 1),
                                         periodEnd: Self.date(2023, 2, 28), issueDate: Self.date(2023, 3, 5), amountMinorUnits: 10_000)
            try Recharges.saveInvoice(db: db, &invoice)
        }
        let entry = recognised(try textFile("invoice.pdf", lines: Self.invoiceLines), .utilityInvoice)
        let item = try propose(UtilityInvoiceImportReader(), entry)
        XCTAssertEqual(item.section, .duplicates)
        XCTAssertEqual(item.duplicate?.level, .document)
        XCTAssertEqual(item.duplicate?.of, "Invoice FT 1/23 of Demo Power already recorded")
    }

    func testInvoiceWithAnotherAmountDebitedIsNeedsYouWithWarning() throws {
        try transaction(Self.date(2023, 3, 20), -12_000, "DEMO PWR DD 123", categoryId: utilitiesId)
        let entry = recognised(try textFile("invoice.pdf", lines: Self.invoiceLines), .utilityInvoice)
        let item = try propose(UtilityInvoiceImportReader(), entry)
        XCTAssertEqual(item.section, .needsYou)
        XCTAssertTrue(item.issues.contains {
            if case .readerProblem(let text) = $0.kind { return text.contains("check the amount") }
            return false
        }, "\(item.issues)")
        XCTAssertEqual(item.links, [])
    }

    // MARK: Payroll forms

    private func p60File(scanned: Bool) throws -> ImportFile {
        let url: URL
        if scanned {
            url = PayrollFormTestPDFs.scannedPDF(PayrollFormTestPDFs.p60RowLayout.map {
                var item = $0
                item.size = max(item.size, 11)
                return item
            })
        } else {
            url = PayrollFormTestPDFs.textPDF(PayrollFormTestPDFs.p60RowLayout, name: "p60.pdf")
        }
        created.append(url)
        return try ImportFile.load(url, ocr: false)
    }

    private func preparedP60() throws -> (file: ImportFile, recognition: ImportRecognition) {
        let entry = recognised(try p60File(scanned: false), .payrollForm(.p60))
        return (PayrollFormImportReader().prepare(entry.file, recognition: entry.recognition), entry.recognition)
    }

    func testP60WithKnownNINumberIsReadyForThatPerson() throws {
        let employmentId = try db.write { db -> Int64 in
            var employment = Employment(startYear: 2024, personId: personId, employerName: "Example Ltd", payeReference: "123/AB456")
            try Employments.save(db: db, &employment)
            return employment.id!
        }
        let entry = try preparedP60()
        let item = try propose(PayrollFormImportReader(), entry)
        XCTAssertEqual(item.section, .ready, "\(item.needsYouReasons)")
        XCTAssertEqual(item.facts.first { $0.field == .person }?.source, .textLayer)
        guard case .payrollForm(let confirmed) = item.effect else { return XCTFail("effect \(item.effect)") }
        XCTAssertEqual(confirmed.personId, personId)
        XCTAssertEqual(confirmed.startYear, 2024)
        XCTAssertEqual(confirmed.payMinorUnits, 4_567_890)
        XCTAssertEqual(confirmed.taxDeductedMinorUnits, 654_321)
        XCTAssertTrue(item.facts.contains { $0.field == .person && $0.value == .text("Person A") })
        XCTAssertTrue(item.facts.contains { $0.field == .taxYear && $0.value == .year(2024) })
        XCTAssertEqual(item.links.map(\.entity), [.employment(employmentId)])
        XCTAssertEqual(item.links.first?.madeByEffect, true)
        XCTAssertEqual(try db.read { try EmploymentIncome.fetchCount($0) }, 0)
    }

    func testP60WithUnknownNINumberAsksForThePerson() throws {
        try db.write { db in
            try db.execute(sql: "UPDATE person SET ukNino = NULL")
            var other = Person(name: "Person B")
            try People.save(db: db, &other)
        }
        let entry = try preparedP60()
        let item = try propose(PayrollFormImportReader(), entry)
        XCTAssertEqual(item.section, .needsYou)
        XCTAssertTrue(item.issues.contains {
            if case .chooseTarget(.person, let options) = $0.kind { return options.count == 2 }
            return false
        }, "\(item.issues)")
    }

    func testScannedP60IsNeedsYou() throws {
        let reader = PayrollFormImportReader(accurateOCR: false)
        let scanned = recognised(try p60File(scanned: true), .payrollForm(.p60))
        // Reading the form (OCR) happens in `prepare`, outside the write transaction; propose only parses.
        let unprepared = try propose(reader, scanned)
        XCTAssertTrue(unprepared.facts.filter { $0.field == .pay }.isEmpty, "\(unprepared.facts)")
        XCTAssertEqual(unprepared.section, .needsYou)
        let entry = (file: reader.prepare(scanned.file, recognition: scanned.recognition), recognition: scanned.recognition)
        XCTAssertEqual(entry.file.payrollExtraction?.entryMethod, .ocr)
        let item = try propose(reader, entry)
        XCTAssertEqual(item.section, .needsYou)
        let money = item.facts.filter { if case .money = $0.value { return true } else { return false } }
        XCTAssertFalse(money.isEmpty)
        XCTAssertTrue(money.allSatisfy { $0.source == .ocr }, "\(money)")
        XCTAssertTrue(item.needsYouReasons.contains("Pay read by text recognition: check it"), "\(item.needsYouReasons)")
    }

    // MARK: Evidence documents

    private static let insuranceLines = ["SEGURO MULTI-RISCO HABITACAO", "Data: 10/03/2024", "TOTAL 120,00 €"]

    func testAmountOnlySingleCandidateIsNeedsYou() throws {
        let debit = try transaction(Self.date(2024, 4, 5), -12_000, "PAYMENT 77")
        let entry = recognised(try textFile("seguro.pdf", lines: Self.insuranceLines), .evidence(.insuranceReceipt))
        let item = try propose(EvidenceDocumentReader(), entry)
        XCTAssertEqual(item.section, .needsYou)
        let issue = try XCTUnwrap(item.issues.first { if case .chooseLink = $0.kind { return true } else { return false } })
        XCTAssertEqual(issue.reason, "Matched on amount only")
        guard case .chooseLink(let candidates) = issue.kind else { return XCTFail() }
        XCTAssertEqual(candidates.map(\.entity), [.transaction(debit)])
        XCTAssertEqual(item.links, [])
    }

    func testTwoEqualCandidatesAskToChoose() throws {
        try transaction(Self.date(2024, 3, 10), -12_000, "PAYMENT 77")
        try transaction(Self.date(2024, 3, 10), -12_000, "PAYMENT 78")
        let entry = recognised(try textFile("seguro.pdf", lines: Self.insuranceLines), .evidence(.insuranceReceipt))
        let item = try propose(EvidenceDocumentReader(), entry)
        XCTAssertEqual(item.section, .needsYou)
        let candidates = item.issues.compactMap { issue -> [LinkCandidate]? in
            if case .chooseLink(let candidates) = issue.kind { return candidates }
            return nil
        }.first
        XCTAssertEqual(candidates?.count, 2)
    }

    func testConfidentMatchIsReadyAndLinked() throws {
        let debit = try transaction(Self.date(2024, 3, 10), -12_000, "PAYMENT 77")
        let entry = recognised(try textFile("seguro.pdf", lines: Self.insuranceLines), .evidence(.insuranceReceipt))
        let item = try propose(EvidenceDocumentReader(), entry)
        XCTAssertEqual(item.section, .ready, "\(item.needsYouReasons)")
        XCTAssertEqual(item.links.map(\.entity), [.transaction(debit)])
        XCTAssertEqual(item.links.first?.confidence, .certain)
        XCTAssertEqual(item.links.first?.madeByEffect, false)
        XCTAssertTrue(item.links.first?.reasons.contains("Amount €120.00") ?? false, "\(item.links)")
    }

    func testOCRAmountIsNeedsYouEvenWithConfidentMatch() throws {
        try transaction(Self.date(2024, 3, 10), -12_000, "PAYMENT 77")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ocr-\(UUID().uuidString).pdf")
        let file = ImportFile(url: url, fileName: "scan.pdf", sha256: "abc", byteCount: 10, fileExtension: "pdf",
                              text: Self.insuranceLines.joined(separator: "\n"), textStatus: .image, usedOCR: true)
        let item = try propose(EvidenceDocumentReader(), recognised(file, .evidence(.insuranceReceipt)))
        XCTAssertEqual(item.section, .needsYou)
        XCTAssertTrue(item.needsYouReasons.contains("Amount read by text recognition: check it"), "\(item.needsYouReasons)")
    }

    func testNoMatchIsReadyUnlinkedWithNote() throws {
        let entry = recognised(try textFile("seguro.pdf", lines: Self.insuranceLines), .evidence(.insuranceReceipt))
        let item = try propose(EvidenceDocumentReader(), entry)
        XCTAssertEqual(item.section, .ready, "\(item.needsYouReasons)")
        XCTAssertEqual(item.links, [])
        XCTAssertEqual(item.notes, ["Not linked: no matching transaction yet"])
        XCTAssertEqual(item.placement?.metadata.kind, .insuranceReceipt)
    }

    func testIntentTargetLinksWithReason() throws {
        let entry = recognised(try textFile("seguro.pdf", lines: Self.insuranceLines), .evidence(.insuranceReceipt))
        let intent = ImportIntent(target: .init(entity: .property(propertyId), role: "policy"))
        let item = try propose(EvidenceDocumentReader(), entry, intent: intent)
        XCTAssertEqual(item.section, .ready, "\(item.needsYouReasons)")
        XCTAssertEqual(item.links.map(\.entity), [.property(propertyId)])
        XCTAssertEqual(item.links.first?.role, "policy")
        XCTAssertEqual(item.links.first?.reasons, ["You added it to Property A"])
    }

    func testUnknownDocumentAsksForKind() throws {
        let file = try textFile("notes.pdf", lines: ["Nothing to see here"])
        let item = try propose(EvidenceDocumentReader(), recognised(file, .unknown, confidence: .needsReview))
        XCTAssertEqual(item.section, .needsYou)
        XCTAssertTrue(item.issues.contains { $0.kind == .unknownKind(proposed: nil) }, "\(item.issues)")
    }

    // MARK: Fix round 1

    func testNearTieEvidenceAsksToChoose() throws {
        try transaction(Self.date(2024, 3, 10), -12_000, "PAYMENT 77")
        try transaction(Self.date(2024, 3, 11), -12_000, "PAYMENT 78")
        let entry = recognised(try textFile("seguro.pdf", lines: Self.insuranceLines), .evidence(.insuranceReceipt))
        let item = try propose(EvidenceDocumentReader(), entry)
        XCTAssertEqual(item.section, .needsYou)
        XCTAssertEqual(item.links, [])
        let candidates = item.issues.compactMap { issue -> [LinkCandidate]? in
            if case .chooseLink(let candidates) = issue.kind { return candidates }
            return nil
        }.first
        XCTAssertEqual(candidates?.count, 2)
    }

    func testRepeatedProviderDebitsAskToChoose() throws {
        try transaction(Self.date(2023, 3, 20), -10_000, "DEMO PWR DD 123", categoryId: utilitiesId)
        try transaction(Self.date(2023, 3, 25), -10_000, "DEMO PWR DD 124", categoryId: utilitiesId)
        let entry = recognised(try textFile("invoice.pdf", lines: Self.invoiceLines), .utilityInvoice)
        let item = try propose(UtilityInvoiceImportReader(), entry)
        XCTAssertEqual(item.section, .needsYou)
        XCTAssertEqual(item.links, [])
        let candidates = item.issues.compactMap { issue -> [LinkCandidate]? in
            if case .chooseLink(let candidates) = issue.kind { return candidates }
            return nil
        }.first
        XCTAssertEqual(candidates?.count, 2)
        guard case .utilityInvoice(let invoice) = item.effect else { return XCTFail("effect \(item.effect)") }
        XCTAssertNil(invoice.transactionId)
    }

    func testUtilityInvoiceReadByOCRIsNeedsYou() throws {
        try transaction(Self.date(2023, 3, 20), -10_000, "DEMO PWR DD 123", categoryId: utilitiesId)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ocr-\(UUID().uuidString).pdf")
        let file = ImportFile(url: url, fileName: "scan.pdf", sha256: "abc", byteCount: 10, fileExtension: "pdf",
                              text: Self.invoiceLines.joined(separator: "\n"), textStatus: .image, usedOCR: true)
        let item = try propose(UtilityInvoiceImportReader(), recognised(file, .utilityInvoice))
        XCTAssertEqual(item.section, .needsYou)
        XCTAssertTrue(item.needsYouReasons.contains("Amount read by text recognition: check it"), "\(item.needsYouReasons)")
    }

    func testInvoiceDateFromFileNameIsMarked() throws {
        let lines = ["Demo Power - customer copy", "Amount due 100,00 EUR", "Invoice no. FT 1/23"]
        let entry = recognised(try textFile("20230305 - Luz.pdf", lines: lines), .utilityInvoice)
        let item = try propose(UtilityInvoiceImportReader(), entry)
        XCTAssertEqual(item.facts.first { $0.field == .docDate }?.source, .fileName)
        XCTAssertEqual(item.section, .needsYou)
    }

    func testInvoiceTitleUsesTheAppDateStyle() throws {
        let entry = recognised(try textFile("invoice.pdf", lines: Self.invoiceLines), .utilityInvoice)
        let item = try propose(UtilityInvoiceImportReader(), entry)
        XCTAssertEqual(item.title, "Invoice FT 1/23 of Demo Power, 5 Mar 2023")
    }

    func testIntentPropertyOtherThanProvidersAsksForTheProperty() throws {
        let otherId = try db.write { db -> Int64 in
            var other = Property(name: "Property B", country: "PT")
            try Properties.save(db: db, &other)
            return other.id!
        }
        let entry = recognised(try textFile("invoice.pdf", lines: Self.invoiceLines), .utilityInvoice)
        let item = try propose(UtilityInvoiceImportReader(), entry, intent: ImportIntent(propertyId: otherId))
        XCTAssertEqual(item.section, .needsYou)
        XCTAssertTrue(item.issues.contains { $0.kind == .chooseTarget(.property, options: [otherId, propertyId]) }, "\(item.issues)")
    }

    func testIntentPersonOtherThanNIOwnerAsksForThePerson() throws {
        let otherId = try db.write { db -> Int64 in
            var other = Person(name: "Person B")
            try People.save(db: db, &other)
            return other.id!
        }
        let item = try propose(PayrollFormImportReader(), try preparedP60(), intent: ImportIntent(personId: otherId))
        XCTAssertEqual(item.section, .needsYou)
        XCTAssertTrue(item.issues.contains { $0.kind == .chooseTarget(.person, options: [otherId, personId]) }, "\(item.issues)")
    }

    func testPayrollPersonPickedByIntent() throws {
        try db.write { try $0.execute(sql: "UPDATE person SET ukNino = NULL") }
        let item = try propose(PayrollFormImportReader(), try preparedP60(), intent: ImportIntent(personId: personId))
        XCTAssertEqual(item.section, .ready, "\(item.needsYouReasons)")
        XCTAssertEqual(item.facts.first { $0.field == .person }?.source, .intent)
        guard case .payrollForm(let confirmed) = item.effect else { return XCTFail("effect \(item.effect)") }
        XCTAssertEqual(confirmed.personId, personId)
    }

    func testNoPeopleSaysSo() throws {
        try db.write { try $0.execute(sql: "DELETE FROM person") }
        let item = try propose(PayrollFormImportReader(), try preparedP60())
        let issue = try XCTUnwrap(item.issues.first { $0.id == "chooseTarget" })
        XCTAssertEqual(issue.kind, .chooseTarget(.person, options: []))
        XCTAssertTrue(issue.reason.contains("No people on record"), issue.reason)
    }

    func testMissingIntentTargetIsNotLinked() throws {
        let entry = recognised(try textFile("seguro.pdf", lines: Self.insuranceLines), .evidence(.insuranceReceipt))
        let intent = ImportIntent(target: .init(entity: .property(9_999)))
        let item = try propose(EvidenceDocumentReader(), entry, intent: intent)
        XCTAssertEqual(item.section, .needsYou)
        XCTAssertEqual(item.links, [])
    }

    // MARK: Default readers

    func testDefaultReadersCoverEveryDocumentKindInOrder() {
        let readers = ImportReaders.defaultReaders(providers: [])
        XCTAssertTrue(readers[0] is RentReceiptsExportReader)
        XCTAssertTrue(readers[1] is RentReceiptPDFReader)
        XCTAssertTrue(readers[2] is TransferAdviceReader)
        XCTAssertTrue(readers[3] is UtilityInvoiceImportReader)
        XCTAssertTrue(readers[4] is PayrollFormImportReader)
        XCTAssertTrue(readers.last is EvidenceDocumentReader)
        for kind: ImportKind in [.utilityInvoice, .payrollForm(.p45), .evidence(.insuranceReceipt), .unknown] {
            XCTAssertEqual(readers.filter { $0.handles(kind) }.count, 1, "\(kind)")
        }
    }
}
