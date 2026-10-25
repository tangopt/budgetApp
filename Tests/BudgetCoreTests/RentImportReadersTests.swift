import XCTest
import GRDB
@testable import BudgetCore
import TestSupport

/// The readers for rent-receipt exports, rent-receipt PDFs and transfer advices: they propose
/// review items from the planners and never write. Synthetic data only.
final class RentImportReadersTests: XCTestCase {
    private var manager: DatabaseManager!
    private var db: DatabaseQueue { manager.dbQueue }
    private var propertyId: Int64!
    private var accountId: Int64!
    private var batchId: Int64!
    private var rentCategoryId: Int64!
    private var tenancyId: Int64!
    private var created: [URL] = []

    override func setUpWithError() throws {
        manager = try TestDatabase.migratedManager()
        try db.write { db in
            var property = Property(name: "Property A", country: "PT")
            try Properties.save(db: db, &property)
            propertyId = property.id!
            var tenancy = Tenancy(propertyId: propertyId, referenceLabel: "Room Contract AB", contractNumber: "1001",
                                  tenantName: "TENANT B", startDate: Self.date(2024, 1, 1))
            try Tenancies.save(db: db, &tenancy)
            tenancyId = tenancy.id!
            for (number, month) in [("1", 1), ("2", 2)] {
                var receipt = RentReceipt(tenancyId: tenancy.id!, receiptNumber: number, periodStart: Self.date(2024, month, 1),
                                          periodEnd: Self.date(2024, month, month == 2 ? 29 : 31), receiptDate: Self.date(2024, month, 3),
                                          amountMinorUnits: 60_000, status: .issued)
                try RentReceipts.save(db: db, &receipt)
            }
            var account = Account(name: "Bank A", currency: .eur, kind: .cash, trackingMode: .imported)
            try account.insert(db)
            accountId = account.id!
            var batch = ImportBatch(accountId: accountId, sourceFileName: "bank.xlsx", importedAt: Date())
            try batch.insert(db)
            batchId = batch.id!
            var group = CategoryGroup(name: "Property A")
            try group.insert(db)
            var rent = Category(name: "Rental income", type: .income, groupId: group.id)
            try rent.insert(db)
            rentCategoryId = rent.id!
            try Properties.addCategoryGroup(db: db, propertyId: propertyId, categoryGroupId: group.id!)
            try Properties.setAccount(db: db, propertyId: propertyId, accountId: accountId, role: .current)
        }
    }

    override func tearDownWithError() throws {
        for url in created { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    }

    private static func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        MonthRange.calendar.date(from: DateComponents(year: y, month: m, day: d))!
    }

    private func file(_ name: String, lines: [String]) throws -> ImportFile {
        let url = EvidenceTestPDFs.textPDF(lines, name: name)
        created.append(url)
        return try ImportFile.load(url, ocr: false)
    }

    private func recognised(_ file: ImportFile, _ kind: ImportKind) -> (file: ImportFile, recognition: ImportRecognition) {
        (file, ImportRecognition(kind: kind, confidence: .certain, reason: "test"))
    }

    private func context(intent: ImportIntent = .none) throws -> ImportContext {
        try db.read { try ImportContext.load(db: $0, intent: intent, now: Self.date(2024, 6, 1)) }
    }

    private func receiptPDF(_ name: String, receipt: String, start: String, end: String, amount: String = "600,00",
                            receivedOn: String) throws -> (file: ImportFile, recognition: ImportRecognition) {
        let lines = RentReceiptPDFsTests.lines(receipt: receipt, start: start, end: end, amount: amount, received: amount,
                                               receivedOn: receivedOn)
        return recognised(try file(name, lines: lines), .rentReceiptPDF)
    }

    // MARK: Receipt PDFs

    func testReceiptPDFMatchingStoredReceiptIsReadyWithReceiptLink() throws {
        let entry = try receiptPDF("r1.pdf", receipt: "1", start: "2024-01-01", end: "2024-01-31", receivedOn: "2024-01-03")
        let context = try context()
        let items = try db.read { try RentReceiptPDFReader().propose([entry], context: context, db: $0) }
        let receiptId = try db.read { try RentReceipts.receipt(db: $0, tenancyId: tenancyId, receiptNumber: "1")!.id! }
        let item = try XCTUnwrap(items.first)
        XCTAssertEqual(item.section, .ready)
        XCTAssertEqual(item.links.count, 1)
        XCTAssertEqual(item.links[0].entity, .rentReceipt(receiptId))
        XCTAssertEqual(item.links[0].role, "Receipt")
        XCTAssertEqual(item.links[0].confidence, .certain)
        XCTAssertEqual(item.links[0].reasons, ["Contract 1001, receipt nº 1, amounts agree"])
        if case .rentReceiptPDF = item.effect {} else { XCTFail("effect \(item.effect)") }
        XCTAssertEqual(item.placement?.canonicalName, "20240105 - Rent - Receipt - 1001/1 - 2024-01 - €600.00")
    }

    func testReceiptPDFWithDifferentAmountIsNeedsYouWithMismatch() throws {
        let entry = try receiptPDF("r1.pdf", receipt: "1", start: "2024-01-01", end: "2024-01-31", amount: "650,00",
                                   receivedOn: "2024-01-03")
        let context = try context()
        let item = try XCTUnwrap(try db.read { try RentReceiptPDFReader().propose([entry], context: context, db: $0) }.first)
        XCTAssertEqual(item.section, .needsYou)
        XCTAssertTrue(item.issues.contains { $0.kind == .readerProblem("Amount: PDF €650.00, stored €600.00") }, "\(item.issues)")
        XCTAssertEqual(item.links, [])
    }

    func testReceiptPDFWithoutStoredReceiptExplainsImportExportFirst() throws {
        let entry = try receiptPDF("r9.pdf", receipt: "9", start: "2024-09-01", end: "2024-09-30", receivedOn: "2024-09-03")
        let context = try context()
        let item = try XCTUnwrap(try db.read { try RentReceiptPDFReader().propose([entry], context: context, db: $0) }.first)
        XCTAssertEqual(item.section, .needsYou)
        XCTAssertEqual(item.issues.map(\.kind), [.readerProblem("No receipt nº 9 for contract 1001: import the portal export first")])
    }

    func testSameReceiptPDFTwiceIsDuplicateFile() throws {
        let entry = try receiptPDF("r1.pdf", receipt: "1", start: "2024-01-01", end: "2024-01-31", receivedOn: "2024-01-03")
        let copy = (file: entry.file, recognition: entry.recognition)
        let context = try context()
        let items = try db.read { try RentReceiptPDFReader().propose([entry, copy], context: context, db: $0) }
        XCTAssertEqual(items[0].section, .ready)
        XCTAssertEqual(items[1].section, .duplicates)
        XCTAssertEqual(items[1].duplicate?.level, .file)
    }

    private func library() -> EvidenceLibrary {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("RentImportReadersTests-\(UUID().uuidString)/Evidence", isDirectory: true)
        created.append(root.appendingPathComponent("x"))
        return EvidenceLibrary(root: root, database: manager.dbQueue)
    }

    func testReceiptPDFAlreadyInLibraryAndLinkedIsDuplicateDocument() throws {
        let entry = try receiptPDF("r1.pdf", receipt: "1", start: "2024-01-01", end: "2024-01-31", receivedOn: "2024-01-03")
        let documentId = try library().add(entry.file.url, metadata: EvidenceMetadata(kind: .rentReceipt)).document.id!
        let receiptId = try db.read { try RentReceipts.receipt(db: $0, tenancyId: tenancyId, receiptNumber: "1")!.id! }
        try db.write { try EvidenceLinks.link(db: $0, documentId: documentId, to: .rentReceipt(receiptId), role: "Receipt") }
        let context = try context()
        let item = try XCTUnwrap(try db.read { try RentReceiptPDFReader().propose([entry], context: context, db: $0) }.first)
        XCTAssertEqual(item.section, .duplicates)
        XCTAssertEqual(item.duplicate?.level, .document)
        XCTAssertEqual(item.duplicate?.existingDocumentId, documentId)
    }

    func testContractOfTwoTenanciesAsksWhichTenancy() throws {
        let other = try db.write { db -> Int64 in
            var property = Property(name: "Property B", country: "PT")
            try Properties.save(db: db, &property)
            var tenancy = Tenancy(propertyId: property.id!, referenceLabel: "Other", contractNumber: "1001", tenantName: "TENANT B",
                                  startDate: Self.date(2024, 1, 1))
            try Tenancies.save(db: db, &tenancy)
            return tenancy.id!
        }
        let entry = try receiptPDF("r1.pdf", receipt: "1", start: "2024-01-01", end: "2024-01-31", receivedOn: "2024-01-03")
        let context = try context()
        let item = try XCTUnwrap(try db.read { try RentReceiptPDFReader().propose([entry], context: context, db: $0) }.first)
        XCTAssertEqual(item.section, .needsYou)
        XCTAssertEqual(item.issues.map(\.kind), [.chooseTarget(.tenancy, options: [tenancyId, other])])
    }

    func testReceiptPDFWithInvalidTenantNIFIsNeedsYouAndCanBeAcknowledged() throws {
        let lines = RentReceiptPDFsTests.lines(receipt: "1", start: "2024-01-01", end: "2024-01-31", amount: "600,00", received: "600,00",
                                               receivedOn: "2024-01-03", tenantNIF: RentReceiptPDFsTests.badNIF)
        let entry = recognised(try file("r1.pdf", lines: lines), .rentReceiptPDF)
        let context = try context()
        let item = try XCTUnwrap(try db.read { try RentReceiptPDFReader().propose([entry], context: context, db: $0) }.first)
        XCTAssertEqual(item.section, .needsYou)
        let issue = try XCTUnwrap(item.issues.first)
        XCTAssertEqual(issue.kind, .readerProblem("Tenant NIF \(RentReceiptPDFsTests.badNIF) fails the check digit"))
        XCTAssertEqual(issue.offers, [.acknowledge])
    }

    func testSameNamedPDFsInDifferentFoldersKeepTheirOwnNIFProblems() throws {
        let bad = recognised(try file("r.pdf", lines: RentReceiptPDFsTests.lines(
            receipt: "1", start: "2024-01-01", end: "2024-01-31", amount: "600,00", received: "600,00", receivedOn: "2024-01-03",
            tenantNIF: RentReceiptPDFsTests.badNIF)), .rentReceiptPDF)
        let good = try receiptPDF("r.pdf", receipt: "2", start: "2024-02-01", end: "2024-02-29", receivedOn: "2024-02-03")
        XCTAssertEqual(bad.file.fileName, good.file.fileName)
        let context = try context()
        let items = try db.read { try RentReceiptPDFReader().propose([bad, good], context: context, db: $0) }
        let badText = "Tenant NIF \(RentReceiptPDFsTests.badNIF) fails the check digit"
        XCTAssertTrue(items[0].issues.contains { $0.kind == .readerProblem(badText) })
        XCTAssertFalse(items[1].issues.contains { $0.kind == .readerProblem(badText) }, "\(items[1].issues)")
    }

    func testReceiptsOfOneContractWithDifferentTenantNIFsAreNeedsYou() throws {
        let one = try receiptPDF("r1.pdf", receipt: "1", start: "2024-01-01", end: "2024-01-31", receivedOn: "2024-01-03")
        let lines = RentReceiptPDFsTests.lines(receipt: "2", start: "2024-02-01", end: "2024-02-29", amount: "600,00", received: "600,00",
                                               receivedOn: "2024-02-03", tenantNIF: RentReceiptPDFsTests.landlordNIF)
        let two = recognised(try file("r2.pdf", lines: lines), .rentReceiptPDF)
        let context = try context()
        let items = try db.read { try RentReceiptPDFReader().propose([one, two], context: context, db: $0) }
        for item in items {
            XCTAssertEqual(item.section, .needsYou)
            XCTAssertTrue(item.issues.contains { $0.kind == .readerProblem("Contract 1001 has 2 different tenant NIFs") }, "\(item.issues)")
        }
    }

    func testUnreadableReceiptPDFIsUnknownKind() throws {
        let entry = recognised(try file("n.pdf", lines: ["Some other document with enough letters to have a text layer"]), .rentReceiptPDF)
        let context = try context()
        let item = try XCTUnwrap(try db.read { try RentReceiptPDFReader().propose([entry], context: context, db: $0) }.first)
        XCTAssertEqual(item.issues.map(\.kind), [.unknownKind(proposed: nil)])
    }

    // MARK: Export

    private func exportFile(contract: String) throws -> (file: ImportFile, recognition: ImportRecognition) {
        let rows = [RentReceiptImportTests.ExportRow(contract: contract, receipt: "1", start: "2025-01-01", end: "2025-01-31"),
                    RentReceiptImportTests.ExportRow(contract: contract, receipt: "2", start: "2025-02-01", end: "2025-02-28",
                                                     status: "Anulado")]
        let url = EvidenceTestPDFs.temporaryURL("export.xlsx")
        created.append(url)
        try RentReceiptImportTests.export(rows).write(to: url)
        let file = ImportFile(url: url, fileName: "export.xlsx", sha256: "x", byteCount: 1, fileExtension: "xlsx", text: nil,
                              textStatus: .noText, usedOCR: false)
        return recognised(file, .rentReceiptsExport)
    }

    func testExportForOnlyPropertyIsReadyWithSummary() throws {
        let entry = try exportFile(contract: "2002")
        let context = try context()
        let item = try XCTUnwrap(try db.write { try RentReceiptsExportReader().propose([entry], context: context, db: $0) }.first)
        XCTAssertEqual(item.section, .ready)
        XCTAssertEqual(item.title, "Receipts export: 1 tenancy, 2 receipts (2 new, 1 cancelled)")
        XCTAssertEqual(item.links.map(\.entity), [.property(propertyId)])
        XCTAssertEqual(item.links[0].label, "Export for Property A")
        XCTAssertEqual(item.placement?.canonicalName, "20250101 - Rent - Receipts export - Property A")
        if case .rentReceiptsExport(let id, let rows) = item.effect { XCTAssertEqual(id, propertyId); XCTAssertEqual(rows.count, 2) }
        else { XCTFail() }
        // Read-only: the preview rolled back.
        XCTAssertEqual(try db.read { try Tenancy.fetchCount($0) }, 1)
    }

    func testExportReaderInsideARolledBackSavepointLeavesTheDatabaseUnchanged() throws {
        let entry = try exportFile(contract: "2002")
        let context = try context()
        func counts(_ db: Database) throws -> [Int] {
            [try Tenancy.fetchCount(db), try RentReceipt.fetchCount(db), try EvidenceDocument.fetchCount(db)]
        }
        let before = try db.read { try counts($0) }
        var items: [ImportItem] = []
        try db.write { db in
            try db.inSavepoint {
                items = try RentReceiptsExportReader().propose([entry], context: context, db: db)
                return .rollback
            }
        }
        XCTAssertEqual(items.first?.section, .ready)
        XCTAssertEqual(try db.read { try counts($0) }, before)
    }

    func testUnreadableExportIsAReaderProblemNotAThrow() throws {
        let url = EvidenceTestPDFs.temporaryURL("bad.xlsx")
        created.append(url)
        try Data("x".utf8).write(to: url)
        let file = ImportFile(url: url, fileName: "bad.xlsx", sha256: "y", byteCount: 1, fileExtension: "xlsx", text: nil, textStatus: .noText, usedOCR: false)
        let good = try exportFile(contract: "2002")
        let context = try context()
        let items = try db.write { try RentReceiptsExportReader().propose([recognised(file, .rentReceiptsExport), good], context: context, db: $0) }
        XCTAssertEqual(items[0].section, .needsYou)
        XCTAssertEqual(items[1].section, .ready)
    }

    func testIntentPropertyDifferentFromContractOwnerIsNeedsYou() throws {
        let second = try db.write { db -> Int64 in
            var property = Property(name: "Property B", country: "PT")
            try Properties.save(db: db, &property)
            return property.id!
        }
        let entry = try exportFile(contract: "1001")
        let context = try context(intent: ImportIntent(propertyId: second))
        let item = try XCTUnwrap(try db.write { try RentReceiptsExportReader().propose([entry], context: context, db: $0) }.first)
        XCTAssertEqual(item.section, .needsYou)
        XCTAssertEqual(item.issues.map(\.kind), [.chooseTarget(.property, options: [second, propertyId])])
        XCTAssertEqual(item.facts.first { $0.field == .reference }?.source, .intent)
    }

    func testExportReferenceFromContractIsNotAnIntentFact() throws {
        let entry = try exportFile(contract: "1001")
        let context = try context()
        let item = try XCTUnwrap(try db.write { try RentReceiptsExportReader().propose([entry], context: context, db: $0) }.first)
        XCTAssertEqual(item.facts.first { $0.field == .reference }?.source, .textLayer)
    }

    func testExportWithUnknownContractAndTwoPropertiesAsksForProperty() throws {
        let second = try db.write { db -> Int64 in
            var property = Property(name: "Property B", country: "PT")
            try Properties.save(db: db, &property)
            return property.id!
        }
        let entry = try exportFile(contract: "2002")
        let context = try context()
        let item = try XCTUnwrap(try db.write { try RentReceiptsExportReader().propose([entry], context: context, db: $0) }.first)
        XCTAssertEqual(item.section, .needsYou)
        XCTAssertEqual(item.issues.map(\.kind), [.chooseTarget(.property, options: [propertyId, second])])
    }

    func testExportWithKnownContractTakesItsProperty() throws {
        _ = try db.write { db in
            var property = Property(name: "Property B", country: "PT")
            try Properties.save(db: db, &property)
        }
        let entry = try exportFile(contract: "1001")
        let context = try context()
        let item = try XCTUnwrap(try db.write { try RentReceiptsExportReader().propose([entry], context: context, db: $0) }.first)
        XCTAssertEqual(item.section, .ready)
        XCTAssertEqual(item.links.map(\.entity), [.property(propertyId)])
    }

    // MARK: Transfer advices

    private func credit(_ date: Date, _ amount: Int, _ description: String) throws -> Int64 {
        try db.write { db in
            var transaction = Transaction(importBatchId: batchId, accountId: accountId, date: date, rawDescription: description,
                                          amountMinorUnits: amount, categoryId: rentCategoryId, status: .confirmed,
                                          categorizedBy: .manual, fingerprint: UUID().uuidString)
            try transaction.insert(db)
            return transaction.id!
        }
    }

    private func advice(_ name: String, date: String, amount: String, reference: String) throws -> (file: ImportFile, recognition: ImportRecognition) {
        recognised(try file(name, lines: RentCreditEvidenceTests.adviceLines(date: date, amount: amount, reference: reference)), .transferAdvice)
    }

    func testAdviceMatchingOneCreditIsReady() throws {
        let id = try credit(Self.date(2024, 1, 2), 110_000, "0099REF0001 TENANTXYZ")
        let entry = try advice("a.pdf", date: "2024-01-02", amount: "1.100,00", reference: "0099REF0001")
        let context = try context()
        let item = try XCTUnwrap(try db.read { try TransferAdviceReader().propose([entry], context: context, db: $0) }.first)
        XCTAssertEqual(item.section, .ready)
        XCTAssertEqual(item.links.map(\.entity), [.transaction(id)])
        XCTAssertEqual(item.links.map(\.confidence), [.certain])
        XCTAssertTrue(item.links[0].reasons[0].contains("reference"), "\(item.links[0].reasons)")
        XCTAssertEqual(item.facts.first { $0.field == .amount }?.source, .matchedRecord)
        XCTAssertEqual(item.placement?.canonicalName, "20240102 - Bank - Transfer received - €1100.00")
        if case .transferAdvice = item.effect {} else { XCTFail() }
    }

    func testAdviceWithNoCreditOffersFileWithoutLink() throws {
        let entry = try advice("a.pdf", date: "2023-06-01", amount: "1.100,00", reference: "0099REF0000")
        let context = try context()
        let item = try XCTUnwrap(try db.read { try TransferAdviceReader().propose([entry], context: context, db: $0) }.first)
        XCTAssertEqual(item.section, .needsYou)
        XCTAssertEqual(item.issues.map(\.kind), [.readerProblem("No credit of €1,100.00 around 2023-06-01 yet")])
        XCTAssertEqual(item.issues.first?.offers, [.fileWithoutLink])
    }

    func testTwoEqualCreditsAreAmbiguousAndSameFileIsDuplicate() throws {
        _ = try credit(Self.date(2024, 1, 2), 110_000, "0099REF0001 TENANTXYZ")
        _ = try credit(Self.date(2024, 1, 2), 110_000, "0099REF0001 TENANTXYZ")
        let entry = try advice("a.pdf", date: "2024-01-02", amount: "1.100,00", reference: "0099REF0001")
        let context = try context()
        let items = try db.read { try TransferAdviceReader().propose([entry, entry], context: context, db: $0) }
        guard case .chooseLink(let candidates) = items[0].issues.first?.kind else { return XCTFail("\(items[0].issues)") }
        XCTAssertEqual(candidates.count, 2)
        XCTAssertTrue(candidates.allSatisfy { $0.reasons.joined().contains("named in the advice") }, "\(candidates)")
        XCTAssertEqual(items[1].section, .duplicates)
    }

    func testTwoAdvicesClaimingOneCreditSaySo() throws {
        _ = try credit(Self.date(2024, 1, 2), 110_000, "0099REF0001 TENANTXYZ")
        let first = try advice("a.pdf", date: "2024-01-02", amount: "1.100,00", reference: "0099REF0001")
        let second = try advice("b.pdf", date: "2024-01-03", amount: "1.100,00", reference: "0099REF0001")
        let context = try context()
        let items = try db.read { try TransferAdviceReader().propose([first, second], context: context, db: $0) }
        for item in items {
            guard case .chooseLink(let candidates) = item.issues.first?.kind else { return XCTFail("\(item.issues)") }
            XCTAssertTrue(candidates.flatMap(\.reasons).joined().contains("also claims"), "\(candidates)")
        }
    }

    func testAdviceForANonTenantCreditIsNotRent() throws {
        _ = try db.write { db in
            var other = Category(name: "Other income", type: .income)
            try other.insert(db)
            var transaction = Transaction(importBatchId: batchId, accountId: accountId, date: Self.date(2024, 3, 10),
                                          rawDescription: "0099REF0003 SOMEONEELSE", amountMinorUnits: 5_000, categoryId: other.id,
                                          status: .confirmed, categorizedBy: .manual, fingerprint: UUID().uuidString)
            try transaction.insert(db)
        }
        let entry = recognised(try file("s.pdf", lines: RentCreditEvidenceTests.adviceLines(date: "2024-03-10", amount: "50,00",
                                                                                              reference: "0099REF0003", payer: "SOMEONEELSE")),
                               .transferAdvice)
        let context = try context()
        let item = try XCTUnwrap(try db.read { try TransferAdviceReader().propose([entry], context: context, db: $0) }.first)
        XCTAssertEqual(item.section, .needsYou)
        guard case .readerProblem(let text)? = item.issues.first?.kind else { return XCTFail() }
        XCTAssertTrue(text.contains("not from a tenant"), text)
    }

    func testAdviceNamingNeitherReferenceNorPayerIsUnconfirmed() throws {
        _ = try credit(Self.date(2024, 1, 2), 110_000, "0099REF0007 NOBODYKNOWN")
        let entry = try advice("a.pdf", date: "2024-01-02", amount: "1.100,00", reference: "0099REF0001")
        let context = try context()
        let item = try XCTUnwrap(try db.read { try TransferAdviceReader().propose([entry], context: context, db: $0) }.first)
        XCTAssertEqual(item.section, .needsYou)
        guard case .readerProblem(let text)? = item.issues.first?.kind else { return XCTFail("\(item.issues)") }
        XCTAssertTrue(text.contains("neither its reference nor its payer"), text)
    }

    func testAdviceAlreadyLinkedToAnotherTransactionIsAConflict() throws {
        _ = try credit(Self.date(2024, 1, 2), 110_000, "0099REF0001 TENANTXYZ")
        let elsewhere = try credit(Self.date(2024, 5, 2), 1_000, "0099REF0099 SOMEONEELSE")
        let entry = try advice("a.pdf", date: "2024-01-02", amount: "1.100,00", reference: "0099REF0001")
        let documentId = try library().add(entry.file.url, metadata: EvidenceMetadata(kind: .bankTransferProof, amountMinorUnits: 0)).document.id!
        try db.write { try EvidenceLinks.link(db: $0, documentId: documentId, to: .transaction(elsewhere), role: RentCreditEvidence.adviceRole) }
        let context = try context()
        let item = try XCTUnwrap(try db.read { try TransferAdviceReader().propose([entry], context: context, db: $0) }.first)
        XCTAssertEqual(item.section, .needsYou)
        guard case .readerProblem(let text)? = item.issues.first?.kind else { return XCTFail("\(item.issues)") }
        XCTAssertTrue(text.contains("already linked to another transaction"), text)
    }
}
