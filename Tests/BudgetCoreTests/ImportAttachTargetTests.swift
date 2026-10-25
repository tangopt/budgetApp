import XCTest
import GRDB
@testable import BudgetCore

/// Plan "Import documents 4" Task 2: a file brought in from a record is linked to it with a
/// certain link "You added it from <entry point>", Replace PDF swaps the old document only when
/// the new one was linked, and a receipt PDF of another receipt never gets the target link.
/// Synthetic data only.
final class ImportAttachTargetTests: XCTestCase {
    private var manager: DatabaseManager!
    private var db: DatabaseQueue { manager.dbQueue }
    private var folder: URL!
    private var library: EvidenceLibrary!
    private var pipeline: ImportPipeline!
    private var applier: ImportApplier!
    private var ids: [String: Int64] = [:]

    private func id(_ key: String) -> Int64 { ids[key]! }

    private static func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        MonthRange.calendar.date(from: DateComponents(year: y, month: m, day: d))!
    }

    override func setUpWithError() throws {
        manager = try DatabaseManager(path: nil)
        try manager.migrate()
        try db.write { db in
            var property = Property(name: "Property A", country: "PT")
            try Properties.save(db: db, &property)
            ids["property"] = property.id!
            var tenancy = Tenancy(propertyId: property.id!, referenceLabel: "Room Contract AB", contractNumber: "1001",
                                  tenantName: "TENANT B", startDate: Self.date(2024, 1, 1))
            try Tenancies.save(db: db, &tenancy)
            ids["tenancy"] = tenancy.id!
            for (number, month) in [("1", 1), ("2", 2)] {
                var receipt = RentReceipt(tenancyId: tenancy.id!, receiptNumber: number, periodStart: Self.date(2024, month, 1),
                                          periodEnd: Self.date(2024, month, month == 2 ? 29 : 31), receiptDate: Self.date(2024, month, 3),
                                          amountMinorUnits: 60_000, status: .issued)
                try RentReceipts.save(db: db, &receipt)
                ids["receipt\(number)"] = receipt.id!
            }
            var account = Account(name: "Bank A", currency: .eur, kind: .cash, trackingMode: .imported)
            try account.insert(db)
            var batch = ImportBatch(accountId: account.id!, sourceFileName: "earlier.csv", importedAt: Date())
            try batch.insert(db)
            var debit = Transaction(importBatchId: batch.id!, accountId: account.id!, date: Self.date(2024, 3, 10), rawDescription: "PAYMENT 77",
                                    amountMinorUnits: -12_000, categoryId: nil, status: .confirmed, categorizedBy: .manual,
                                    fingerprint: "fp-debit")
            try debit.insert(db)
            ids["debit"] = debit.id!
            var other = Transaction(importBatchId: batch.id!, accountId: account.id!, date: Self.date(2024, 5, 2), rawDescription: "OTHER 88",
                                    amountMinorUnits: -5_000, categoryId: nil, status: .confirmed, categorizedBy: .manual,
                                    fingerprint: "fp-other")
            try other.insert(db)
            ids["other"] = other.id!
        }
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("ImportAttachTargetTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        library = EvidenceLibrary(root: folder.appendingPathComponent("Library", isDirectory: true), database: db)
        pipeline = ImportPipeline(dbQueue: db, library: library, categorizationService: CategorizationService(categorizer: FakeCategorizer()))
        applier = ImportApplier(dbQueue: db, databasePath: nil, library: library)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    // MARK: Files

    private func drop(_ url: URL, as name: String) throws -> URL {
        let directory = folder.appendingPathComponent("Drop-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = directory.appendingPathComponent(name)
        try FileManager.default.copyItem(at: url, to: target)
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        return target
    }

    /// Rent receipt nº `number` of contract 1001, matching the stored receipt.
    private func receiptPDF(_ number: String, contract: String = "1001", amount: String = "600,00") throws -> URL {
        let month = number == "2" ? "02" : "01", last = number == "2" ? "29" : "31"
        let lines = RentReceiptPDFsTests.lines(contract: contract, receipt: number, start: "2024-\(month)-01", end: "2024-\(month)-\(last)",
                                               amount: amount, received: amount, receivedOn: "2024-\(month)-03")
        return try drop(EvidenceTestPDFs.textPDF(lines, name: "r\(number).pdf"), as: "r\(number).pdf")
    }

    /// An insurance receipt of €120.00 (paid by the debit).
    private func insurancePDF(_ name: String = "seguro.pdf") throws -> URL {
        try drop(EvidenceTestPDFs.textPDF(["SEGURO MULTI-RISCO HABITACAO", "Data: 10/03/2024", "TOTAL 120,00 €"], name: name), as: name)
    }

    /// A synthetic P60 for 2024/25.
    private func p60() throws -> URL {
        try drop(PayrollFormTestPDFs.textPDF(PayrollFormTestPDFs.p60RowLayout, name: "p60.pdf"), as: "p60.pdf")
    }

    private func plainFile(_ name: String, _ text: String) throws -> URL {
        let directory = folder.appendingPathComponent("Old-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url
    }

    /// An earlier PDF on `receipt` (role "Receipt").
    private func oldReceiptDocument(on receipt: Int64) throws -> Int64 {
        let old = try library.add(try plainFile("old receipt.txt", "Older synthetic receipt")).document.id!
        _ = try library.link(old, to: .rentReceipt(receipt), role: "Receipt")
        return old
    }

    private func links(_ entity: EvidenceEntity) throws -> [DocumentLink] {
        try db.read { db in
            try DocumentLink.filter(Column("entityType") == entity.type.rawValue && Column("entityId") == entity.id).fetchAll(db)
        }
    }

    // MARK: Tests

    func testAttachToTransactionLinksWithReason() async throws {
        let shortcut = ImportShortcut.attach(.transaction(id("other")), role: nil, from: .transaction)
        let plan = try await pipeline.plan([try insurancePDF(), try p60()], intent: shortcut.intent)
        // Evidence read by the evidence reader, and a P60 read by the payroll reader: both get the target.
        for item in plan.items where item.parentId == nil {
            let link = try XCTUnwrap(item.links.first { $0.entity == .transaction(id("other")) }, "\(item.file.fileName): \(item.links)")
            XCTAssertEqual(link.confidence, .certain)
            XCTAssertEqual(link.reasons, ["You added it from Transaction ▸ Add document"])
            XCTAssertFalse(link.madeByEffect)
            XCTAssertEqual(link.replacing, [])
        }
        let insurance = try XCTUnwrap(plan.items.first { $0.file.fileName == "seguro.pdf" })
        XCTAssertEqual(insurance.section, .ready, "\(insurance.needsYouReasons)")
        // Not also linked to the debit the matcher would have chosen: the user said where it goes.
        XCTAssertFalse(insurance.links.contains { $0.entity == .transaction(id("debit")) })

        // Without an entry point (an intent built by hand), the old wording.
        let plain = try await pipeline.plan([try insurancePDF("seguro2.pdf")],
                                            intent: ImportIntent(target: .init(entity: .transaction(id("other")))))
        let item = try XCTUnwrap(plain.items.first)
        XCTAssertEqual(item.links.first?.reasons, ["You added it to OTHER 88 -€50.00"])

        // The P60 names nobody in the app: Needs you for its person, still linked to the transaction.
        let p60 = try XCTUnwrap(plan.items.first { $0.file.fileName == "p60.pdf" })
        XCTAssertEqual(p60.section, .needsYou, "\(p60.needsYouReasons)")
        let ready = try await pipeline.resolve(plan, itemId: p60.id, .leaveOut)
        XCTAssertTrue(ready.canConfirm, "\(ready.items.map(\.needsYouReasons))")
        let summary = try applier.apply(ready, entryPoint: shortcut.entryPoint)
        let document = try await db.read { db in
            try XCTUnwrap(ImportRunFile.filter(Column("runId") == summary.runId).fetchAll(db).first { $0.documentId != nil }?.documentId)
        }
        XCTAssertTrue(try links(.transaction(id("other"))).contains { $0.documentId == document })
    }

    func testReplacePDFUnlinksOldAndLinksNew() async throws {
        let old = try oldReceiptDocument(on: id("receipt1"))
        let shortcut = ImportShortcut.receiptPDF(receiptId: id("receipt1"), replacing: [old])
        let plan = try await pipeline.plan([try receiptPDF("1")], intent: shortcut.intent)
        let item = try XCTUnwrap(plan.items.first)
        XCTAssertEqual(item.section, .ready, "\(item.needsYouReasons) \(String(describing: item.duplicate))")
        let link = try XCTUnwrap(item.links.first { $0.entity == .rentReceipt(id("receipt1")) }, "\(item.links)")
        XCTAssertEqual(link.role, "Receipt")
        XCTAssertEqual(link.confidence, .certain)
        XCTAssertEqual(link.replacing, [old])
        XCTAssertEqual(link.reasons.last, "You added it from Receipt ▸ Replace PDF…")
        XCTAssertEqual(item.links.filter { $0.entity == .rentReceipt(id("receipt1")) }.count, 1, "one link to the receipt: \(item.links)")

        let summary = try applier.apply(plan, entryPoint: shortcut.entryPoint)
        let document = try await db.read { db in
            try XCTUnwrap(ImportRunFile.filter(Column("runId") == summary.runId).fetchOne(db)?.documentId)
        }
        let receiptLinks = try links(.rentReceipt(id("receipt1")))
        XCTAssertEqual(receiptLinks.map(\.documentId), [document])
        XCTAssertEqual(receiptLinks.first?.role, "Receipt")
        try await db.read { db in
            XCTAssertTrue(try EvidenceDocument.exists(db, key: old), "an import never deletes existing documents")
        }
    }

    func testReplaceWithWrongReceiptKeepsOldLink() async throws {
        let old = try oldReceiptDocument(on: id("receipt1"))
        let shortcut = ImportShortcut.receiptPDF(receiptId: id("receipt1"), replacing: [old])
        // The new PDF is receipt nº 2's.
        let first = try await pipeline.plan([try receiptPDF("2")], intent: shortcut.intent)
        let plan = try await pipeline.plan(adding: [try insurancePDF()], to: first, intent: ImportShortcut.documents(dropped: false).intent)
        let wrong = try XCTUnwrap(plan.items.first { $0.file.fileName == "r2.pdf" })
        XCTAssertEqual(wrong.section, .needsYou)
        XCTAssertFalse(wrong.links.contains { $0.entity == .rentReceipt(id("receipt1")) }, "\(wrong.links)")
        XCTAssertTrue(wrong.links.allSatisfy { $0.replacing.isEmpty }, "\(wrong.links)")
        XCTAssertEqual(wrong.needsYouReasons,
                       ["This PDF is receipt nº 2 of contract 1001, not receipt nº 1 of contract 1001 that you added it to"])
        XCTAssertFalse(plan.canConfirm)

        let resolved = try await pipeline.resolve(plan, itemId: wrong.id, .leaveOut)
        XCTAssertTrue(resolved.canConfirm, "\(resolved.items.map(\.needsYouReasons))")
        _ = try applier.apply(resolved, entryPoint: "Import…")
        XCTAssertEqual(try links(.rentReceipt(id("receipt1"))).map(\.documentId), [old], "the old PDF stays linked")
        XCTAssertEqual(try links(.rentReceipt(id("receipt2"))), [], "the left-out PDF is linked nowhere")
    }

    func testTenancyContractGetsRoleContract() async throws {
        let shortcut = ImportShortcut.tenancyContract(tenancyId: id("tenancy"))
        let url = try drop(EvidenceTestPDFs.textPDF(["CONTRATO DE ARRENDAMENTO", "Synthetic contract words"], name: "contrato.pdf"),
                           as: "contrato.pdf")
        let plan = try await pipeline.plan([url], intent: shortcut.intent)
        let item = try XCTUnwrap(plan.items.first)
        let link = try XCTUnwrap(item.links.first { $0.entity == .tenancy(id("tenancy")) }, "\(item.links)")
        XCTAssertEqual(link.role, "Contract")
        XCTAssertEqual(link.reasons, ["You added it from Tenancy ▸ Add contract…"])
        XCTAssertEqual(item.section, .ready, "\(item.needsYouReasons)")
        _ = try applier.apply(plan, entryPoint: shortcut.entryPoint)
        XCTAssertEqual(try links(.tenancy(id("tenancy"))).map(\.role), ["Contract"])
    }

    // MARK: Declared kind (fix round 1)

    func testUnrecognisedContractViaAddContractIsReadyAndLinked() async throws {
        let shortcut = ImportShortcut.tenancyContract(tenancyId: id("tenancy"))
        let url = try drop(EvidenceTestPDFs.textPDF(["Clause one and clause two", "Synthetic words only"], name: "scan 7.pdf"),
                           as: "scan 7.pdf")
        let plan = try await pipeline.plan([url], intent: shortcut.intent)
        let item = try XCTUnwrap(plan.items.first)
        XCTAssertEqual(item.recognition.kind, .evidence(.rentContract))
        XCTAssertEqual(item.recognition.confidence, .certain)
        XCTAssertEqual(item.recognition.reason, "You added it as a Rent contract from Tenancy ▸ Add contract…")
        XCTAssertEqual(item.section, .ready, "\(item.needsYouReasons)")
        let link = try XCTUnwrap(item.links.first { $0.entity == .tenancy(id("tenancy")) }, "\(item.links)")
        XCTAssertEqual(link.role, "Contract")
        XCTAssertEqual(link.reasons, ["You added it from Tenancy ▸ Add contract…"])
        _ = try applier.apply(plan, entryPoint: shortcut.entryPoint)
        XCTAssertEqual(try links(.tenancy(id("tenancy"))).map(\.role), ["Contract"])
    }

    func testP60ViaAddContractIsKindMismatch() async throws {
        let plan = try await pipeline.plan([try p60()], intent: ImportShortcut.tenancyContract(tenancyId: id("tenancy")).intent)
        let item = try XCTUnwrap(plan.items.first { $0.parentId == nil })
        XCTAssertEqual(item.recognition.kind, .payrollForm(.p60))
        XCTAssertEqual(item.section, .needsYou)
        XCTAssertTrue(item.issues.contains { $0.kind == .kindMismatch(expected: .evidence(.rentContract), found: .payrollForm(.p60)) },
                      "\(item.issues)")
        XCTAssertFalse(item.links.contains { $0.entity == .tenancy(id("tenancy")) })
    }

    func testDeclaredKindOnlyForEvidenceAndUnrecognisedFiles() {
        let unknown = ImportRecognition(kind: .unknown, confidence: .needsReview, reason: "Not recognised")
        let byName = ImportRecognition(kind: .evidence(.insuranceReceipt), confidence: .needsReview, reason: "Recognised from the file name only")
        let insurance = ImportRecognition(kind: .evidence(.insuranceReceipt), confidence: .certain, reason: "Insurance receipt wording")
        let contract = ImportShortcut.tenancyContract(tenancyId: 1).intent
        XCTAssertEqual(ImportDetector.declared(unknown, intent: contract)?.kind, .evidence(.rentContract))
        XCTAssertEqual(ImportDetector.declared(byName, intent: contract)?.kind, .evidence(.rentContract))
        XCTAssertNil(ImportDetector.declared(insurance, intent: contract), "recognised as something else: a mismatch")
        for intent in [ImportShortcut.payrollForms(personId: nil, taxYear: nil).intent, ImportShortcut.utilityInvoices(propertyId: 1).intent,
                       ImportShortcut.receiptPDF(receiptId: 1, replacing: []).intent, ImportShortcut.rentReceiptsExport(propertyId: 1).intent,
                       ImportShortcut.statement(accountId: 1, format: .pdf, from: .accounts).intent,
                       ImportIntent(expected: .evidence(.p60)), ImportIntent(expected: .evidence(.utilityInvoice)),
                       ImportIntent(expected: .evidence(.bankStatement)), ImportIntent(expected: .evidence(.other))] {
            XCTAssertNil(ImportDetector.declared(unknown, intent: intent), "\(String(describing: intent.expected))")
        }
    }

    // MARK: Fix round 2

    /// Replace PDF on receipt 1 with `pdf`: Needs you for `reason` only (Leave out), and after
    /// leaving it out and confirming another file, receipt 1 still has only its old PDF.
    private func assertWrongReplacementKeepsOldLink(_ pdf: URL, reason: String, file: StaticString = #filePath, line: UInt = #line) async throws {
        let old = try oldReceiptDocument(on: id("receipt1"))
        let shortcut = ImportShortcut.receiptPDF(receiptId: id("receipt1"), replacing: [old])
        let first = try await pipeline.plan([pdf], intent: shortcut.intent)
        let plan = try await pipeline.plan(adding: [try insurancePDF()], to: first, intent: ImportShortcut.documents(dropped: false).intent)
        let wrong = try XCTUnwrap(plan.items.first { $0.file.url == pdf }, file: file, line: line)
        XCTAssertEqual(wrong.section, .needsYou, file: file, line: line)
        XCTAssertEqual(wrong.needsYouReasons, [reason], file: file, line: line)
        XCTAssertEqual(wrong.issues.map(\.id), ["receiptMismatch"], file: file, line: line)
        XCTAssertEqual(wrong.issues.first?.offers, [], "Leave out only", file: file, line: line)
        XCTAssertFalse(wrong.links.contains { $0.entity == .rentReceipt(id("receipt1")) }, file: file, line: line)
        let resolved = try await pipeline.resolve(plan, itemId: wrong.id, .leaveOut)
        XCTAssertTrue(resolved.canConfirm, "\(resolved.items.map(\.needsYouReasons))", file: file, line: line)
        _ = try applier.apply(resolved, entryPoint: "Import…")
        XCTAssertEqual(try links(.rentReceipt(id("receipt1"))).map(\.documentId), [old], "the old PDF stays linked", file: file, line: line)
    }

    func testReplaceWithOtherTenanciesContractNeverAsksForATenancy() async throws {
        try await db.write { db in
            // One contract number on two other properties' tenancies (unique per property).
            for label in ["Room C", "Room D"] {
                var property = Property(name: "Property \(label)", country: "PT")
                try Properties.save(db: db, &property)
                var tenancy = Tenancy(propertyId: property.id!, referenceLabel: label, contractNumber: "2002",
                                      tenantName: "TENANT C", startDate: Self.date(2024, 1, 1))
                try Tenancies.save(db: db, &tenancy)
            }
        }
        try await assertWrongReplacementKeepsOldLink(try receiptPDF("1", contract: "2002"),
            reason: "This PDF is receipt nº 1 of contract 2002, not receipt nº 1 of contract 1001 that you added it to")
    }

    func testReplaceWithReceiptNotImportedKeepsOldLink() async throws {
        try await assertWrongReplacementKeepsOldLink(try receiptPDF("9"),
            reason: "This PDF is receipt nº 9 of contract 1001, not receipt nº 1 of contract 1001 that you added it to")
    }

    func testReplaceWithAnotherReceiptsDisagreeingPDFKeepsOldLink() async throws {
        // Receipt nº 2's PDF with another amount: the matcher's field mismatch, and not the target.
        let old = try oldReceiptDocument(on: id("receipt1"))
        let shortcut = ImportShortcut.receiptPDF(receiptId: id("receipt1"), replacing: [old])
        let plan = try await pipeline.plan([try receiptPDF("2", amount: "700,00")], intent: shortcut.intent)
        let item = try XCTUnwrap(plan.items.first)
        XCTAssertEqual(item.section, .needsYou)
        XCTAssertTrue(item.issues.contains { $0.id == "receiptMismatch" }, "\(item.issues)")
        XCTAssertTrue(item.links.allSatisfy { $0.replacing.isEmpty })
        let resolved = try await pipeline.resolve(plan, itemId: item.id, .leaveOut)
        XCTAssertEqual(resolved.items.first?.section, .leftOut)
        XCTAssertEqual(try links(.rentReceipt(id("receipt1"))).map(\.documentId), [old])
    }

    func testReplaceWithTheSameBytesIsADuplicate() async throws {
        let url = try receiptPDF("1")
        let old = try library.add(url).document.id!
        _ = try library.link(old, to: .rentReceipt(id("receipt1")), role: "Receipt")
        let plan = try await pipeline.plan([url], intent: ImportShortcut.receiptPDF(receiptId: id("receipt1"), replacing: [old]).intent)
        let item = try XCTUnwrap(plan.items.first)
        XCTAssertEqual(item.section, .duplicates)
        XCTAssertEqual(item.duplicate?.existingDocumentId, old)
        XCTAssertEqual(try links(.rentReceipt(id("receipt1"))).map(\.documentId), [old])
    }

    func testFiledYearCheckSeesTheReplaceUnlink() async throws {
        // What the filed-year guard does: a placeholder document, applyRecords, rolled back.
        let old = try oldReceiptDocument(on: id("receipt1"))
        let plan = try await pipeline.plan([try receiptPDF("1")],
                                           intent: ImportShortcut.receiptPDF(receiptId: id("receipt1"), replacing: [old]).intent)
        let item = try XCTUnwrap(plan.items.first)
        let linkedInCheck = try await db.write { db -> [Int64] in
            var linked: [Int64] = []
            try db.inSavepoint {
                let placeholder = try FiledYearGuard.placeholderDocument(db: db, item: item)
                try ImportEffects.applyRecords(db: db, item: item, documentId: placeholder, importRunId: nil)
                linked = try EvidenceLinks.documents(db: db, for: .rentReceipt(self.id("receipt1"))).compactMap(\.id)
                XCTAssertEqual(linked, [placeholder])
                return .rollback
            }
            return linked
        }
        XCTAssertFalse(linkedInCheck.contains(old), "the check sees the old PDF unlinked")
        XCTAssertEqual(try links(.rentReceipt(id("receipt1"))).map(\.documentId), [old], "and rolls it back")
    }

    func testUnreadFileViaAddContractIsToCheck() async throws {
        let url = try drop(EvidenceTestPDFs.textPDF([], name: "blank.pdf"), as: "blank.pdf")
        let plan = try await pipeline.plan([url], intent: ImportShortcut.tenancyContract(tenancyId: id("tenancy")).intent)
        let item = try XCTUnwrap(plan.items.first)
        XCTAssertEqual(item.recognition.kind, .evidence(.rentContract))
        XCTAssertEqual(item.recognition.confidence, .needsReview)
        XCTAssertEqual(item.section, .needsYou)
        XCTAssertTrue(item.needsYouReasons.contains("Not read: check it's the Rent contract"), "\(item.needsYouReasons)")
        let unknown = ImportRecognition(kind: .unknown, confidence: .needsReview, reason: "Not recognised")
        XCTAssertEqual(ImportDetector.declared(unknown, intent: ImportShortcut.tenancyContract(tenancyId: 1).intent, read: false)?.confidence,
                       .needsReview)
    }

    func testLearntRuleIsNotOverriddenByDeclaredKind() {
        let learnt = ImportRecognition(kind: .evidence(.other), confidence: .certain, reason: "Your rule", ruleId: 5)
        XCTAssertNil(ImportDetector.declared(learnt, intent: ImportShortcut.tenancyContract(tenancyId: 1).intent))
    }

    func testTargetUpgradesTheReadersUnsureLink() throws {
        let file = ImportFile(url: folder.appendingPathComponent("x.pdf"), fileName: "x.pdf", sha256: "x", byteCount: 1, fileExtension: "pdf",
                              text: nil, textStatus: .noText, usedOCR: false)
        let recognition = ImportRecognition(kind: .evidence(.insuranceReceipt), confidence: .certain, reason: "test")
        let unsure = ProposedLink(entity: .transaction(id("other")), label: "OTHER 88", confidence: .needsReview, reasons: ["Amount only"])
        let item = ImportItem(file: file, recognition: recognition, title: "x", links: [unsure], groupKey: "Other documents")
        let intent = ImportShortcut.attach(.transaction(id("other")), role: "payment proof", from: .transaction).intent
        let linked = try db.read { try ImportPipeline.withTarget(item, intent: intent, db: $0) }
        XCTAssertEqual(linked.links.count, 1)
        XCTAssertEqual(linked.links[0].confidence, .certain)
        XCTAssertEqual(linked.links[0].role, "payment proof")
        XCTAssertEqual(linked.links[0].reasons, ["Amount only", "You added it from Transaction ▸ Add document"])
    }

    // MARK: Task 6 fix round 1: a rent receipt not in the portal's layout

    /// A landlord's own rent receipt for receipt nº 1's month (not the portal's PDF).
    private func plainReceipt(_ name: String = "recibo janeiro.pdf", amount: String = "600,00", date: String = "03/01/2024") throws -> URL {
        try drop(EvidenceTestPDFs.textPDF(["RECIBO DE RENDA", "Synthetic landlord receipt", "Valor da renda \(amount) €", "Data: \(date)"],
                                          name: name), as: name)
    }

    /// The rent credit that paid receipt nº 1 (a manual payment link).
    private func payReceipt1() throws -> Int64 {
        try db.write { db in
            let account = try XCTUnwrap(Account.fetchOne(db))
            let batch = try XCTUnwrap(ImportBatch.fetchOne(db))
            var credit = Transaction(importBatchId: batch.id!, accountId: account.id!, date: Self.date(2024, 1, 3), rawDescription: "RENT TENANT B",
                                     amountMinorUnits: 60_000, categoryId: nil, status: .confirmed, categorizedBy: .manual,
                                     fingerprint: "fp-rent-1")
            try credit.insert(db)
            try RentReceiptMatching.link(db: db, receiptId: self.id("receipt1"), transactionId: credit.id!)
            return credit.id!
        }
    }

    func testNonPortalReceiptViaAddPDFIsReadyAndLinked() async throws {
        let credit = try payReceipt1()
        let shortcut = ImportShortcut.receiptPDF(receiptId: id("receipt1"), replacing: [])
        let plan = try await pipeline.plan([try plainReceipt()], intent: shortcut.intent)
        let item = try XCTUnwrap(plan.items.first)
        XCTAssertEqual(item.recognition.kind, .evidence(.rentReceipt))
        XCTAssertFalse(item.issues.contains { $0.id == "kindMismatch" }, "\(item.issues)")
        XCTAssertEqual(item.section, .ready, "\(item.needsYouReasons)")
        let link = try XCTUnwrap(item.links.first { $0.entity == .rentReceipt(id("receipt1")) }, "\(item.links)")
        XCTAssertEqual(link.role, "Receipt")
        XCTAssertEqual(link.confidence, .certain)
        XCTAssertEqual(link.reasons, ["You added it from Receipt ▸ Add PDF…"])
        let summary = try applier.apply(plan, entryPoint: shortcut.entryPoint)
        let document = try await db.read { db in
            try XCTUnwrap(ImportRunFile.filter(Column("runId") == summary.runId).fetchOne(db)?.documentId)
        }
        let receiptLinks = try links(.rentReceipt(id("receipt1")))
        XCTAssertEqual(receiptLinks.map(\.documentId), [document])
        XCTAssertEqual(receiptLinks.first?.role, "Receipt")
        try await db.read { db in
            XCTAssertEqual(try EvidenceDocument.fetchOne(db, key: document)?.kind, .rentReceipt)
        }
        // The credit that paid the receipt carries its document too (the importer's follow-on matching).
        let creditLinks = try links(.transaction(credit))
        XCTAssertTrue(creditLinks.contains { $0.documentId == document && $0.role == RentCreditEvidence.receiptRole }, "\(creditLinks)")
    }

    func testNonPortalReceiptOfAnotherAmountIsALinkToCheck() async throws {
        let plan = try await pipeline.plan([try plainReceipt(amount: "700,00")],
                                           intent: ImportShortcut.receiptPDF(receiptId: id("receipt1"), replacing: []).intent)
        let item = try XCTUnwrap(plan.items.first)
        XCTAssertEqual(item.section, .needsYou)
        let link = try XCTUnwrap(item.links.first { $0.entity == .rentReceipt(id("receipt1")) }, "\(item.links)")
        XCTAssertEqual(link.confidence, .needsReview)
        XCTAssertEqual(link.reasons.first, "This receipt's amount differs from receipt nº 1")
        // Chosen by the user: Ready.
        let chosen = try await pipeline.resolve(plan, itemId: item.id, .chooseLink(.rentReceipt(id("receipt1"))))
        XCTAssertTrue(chosen.canConfirm, "\(chosen.items.map(\.needsYouReasons))")
    }

    func testNonPortalReceiptAgreementChecks() throws {
        let file = ImportFile(url: folder.appendingPathComponent("x.pdf"), fileName: "x.pdf", sha256: "x", byteCount: 1, fileExtension: "pdf",
                              text: "RECIBO DE RENDA", textStatus: .text, usedOCR: false)
        let intent = ImportShortcut.receiptPDF(receiptId: id("receipt1"), replacing: []).intent
        func item(_ facts: [ImportFact], ocr: Bool = false) -> ImportItem {
            var file = file
            file.usedOCR = ocr
            var item = ImportItem(file: file, recognition: ImportRecognition(kind: .evidence(.rentReceipt), confidence: .certain, reason: "wording"),
                                  title: "x", groupKey: "Other documents")
            item.facts = facts
            return item
        }
        func fact(_ field: ImportFigureField, _ value: ImportFactValue) -> ImportFact {
            ImportFact(field: field, value: value, source: .textLayer, confidence: .certain, reason: "test")
        }
        func linked(_ item: ImportItem) throws -> ImportItem { try db.read { try ImportPipeline.withTarget(item, intent: intent, db: $0) } }

        let agreeing = try linked(item([fact(.periodStart, .date(Self.date(2024, 1, 1))), fact(.periodEnd, .date(Self.date(2024, 1, 31))),
                                        fact(.amount, .money(60_000, .eur))]))
        XCTAssertEqual(agreeing.links.map(\.confidence), [.certain])
        XCTAssertEqual(agreeing.recognition.confidence, .certain)

        let otherMonth = try linked(item([fact(.periodStart, .date(Self.date(2024, 2, 1))), fact(.periodEnd, .date(Self.date(2024, 2, 29))),
                                          fact(.amount, .money(70_000, .eur))]))
        XCTAssertEqual(otherMonth.links.map(\.confidence), [.needsReview])
        XCTAssertEqual(otherMonth.links.first?.reasons, ["This receipt's period and amount differ from receipt nº 1",
                                                        "You added it from Receipt ▸ Add PDF…"])

        let lateDate = try linked(item([fact(.docDate, .date(Self.date(2024, 6, 3)))]))
        XCTAssertEqual(lateDate.links.first?.reasons.first, "This receipt's date differs from receipt nº 1")
        XCTAssertEqual(try linked(item([fact(.docDate, .date(Self.date(2024, 2, 5)))])).links.map(\.confidence), [.certain])

        let scanned = try linked(item([], ocr: true))
        XCTAssertEqual(scanned.recognition.confidence, .needsReview)
        XCTAssertEqual(scanned.recognition.reason, "Read by text recognition: check it's a rent receipt")
        XCTAssertEqual(scanned.section, .needsYou)
    }

    func testNonPortalReceiptViaReplacePDFUnlinksOld() async throws {
        let old = try oldReceiptDocument(on: id("receipt1"))
        let shortcut = ImportShortcut.receiptPDF(receiptId: id("receipt1"), replacing: [old])
        let plan = try await pipeline.plan([try plainReceipt()], intent: shortcut.intent)
        let item = try XCTUnwrap(plan.items.first)
        XCTAssertEqual(item.section, .ready, "\(item.needsYouReasons)")
        let link = try XCTUnwrap(item.links.first { $0.entity == .rentReceipt(id("receipt1")) }, "\(item.links)")
        XCTAssertEqual(link.replacing, [old])
        XCTAssertEqual(link.reasons, ["You added it from Receipt ▸ Replace PDF…"])
        let summary = try applier.apply(plan, entryPoint: shortcut.entryPoint)
        let document = try await db.read { db in
            try XCTUnwrap(ImportRunFile.filter(Column("runId") == summary.runId).fetchOne(db)?.documentId)
        }
        XCTAssertEqual(try links(.rentReceipt(id("receipt1"))).map(\.documentId), [document], "the old PDF unlinked, the new linked")
        try await db.read { db in
            XCTAssertTrue(try EvidenceDocument.exists(db, key: old), "an import never deletes existing documents")
        }
    }

    func testP60ViaAddPDFIsStillKindMismatch() async throws {
        let plan = try await pipeline.plan([try p60()], intent: ImportShortcut.receiptPDF(receiptId: id("receipt1"), replacing: []).intent)
        let item = try XCTUnwrap(plan.items.first { $0.parentId == nil })
        XCTAssertEqual(item.section, .needsYou)
        XCTAssertTrue(item.issues.contains { $0.kind == .kindMismatch(expected: .rentReceiptPDF, found: .payrollForm(.p60)) }, "\(item.issues)")
        XCTAssertFalse(item.links.contains { $0.entity == .rentReceipt(id("receipt1")) })
    }

    func testKindMismatchNeverNamesTheSameKindTwice() throws {
        // Every pair of different kinds that share a display name, both ways round (and one plain pair).
        let pairs: [(ImportKind, ImportKind)] = [
            (.utilityInvoice, .evidence(.utilityInvoice)), (.evidence(.utilityInvoice), .utilityInvoice),
            (.payrollForm(.p60), .evidence(.p60)), (.evidence(.p60), .payrollForm(.p60)),
            (.payrollForm(.p45), .evidence(.p45)), (.payrollForm(.p11d), .evidence(.p11d)),
            (.rentReceiptsExport, .utilityInvoice)
        ]
        for (expected, found) in pairs {
            let recognition = ImportRecognition(kind: found, confidence: .certain, reason: "test")
            let issue = try XCTUnwrap(ImportDetector.intentIssue(recognition, intent: ImportIntent(expected: expected)), "\(expected) / \(found)")
            let names = issue.reason.components(separatedBy: ", this looks like ")
            XCTAssertEqual(names.count, 2, issue.reason)
            XCTAssertTrue(names[0].hasPrefix("Expected "), issue.reason)
            let expectedName = String(names[0].dropFirst("Expected ".count)), foundName = names[1]
            XCTAssertNotEqual(expectedName.lowercased(), foundName.lowercased(), issue.reason)
        }
        XCTAssertEqual(ImportDetector.mismatchReason(expected: .payrollForm(.p60), found: .evidence(.p60)),
                       "Expected a P60 the payroll reader can read, this looks like another P60")
        XCTAssertEqual(ImportDetector.mismatchReason(expected: .evidence(.p60), found: .payrollForm(.p60)),
                       "Expected a P60 document for the library, this looks like another P60")
        XCTAssertEqual(ImportDetector.mismatchReason(expected: .rentReceiptsExport, found: .utilityInvoice),
                       "Expected a Rent receipts export, this looks like a Utility invoice")
        let same = ImportDetector.intentIssue(ImportRecognition(kind: .evidence(.utilityInvoice), confidence: .certain, reason: "test"),
                                              intent: ImportIntent(expected: .utilityInvoice))
        XCTAssertEqual(same?.reason, "Expected a utility invoice the importer can read, this looks like another utility invoice")
        XCTAssertEqual(ImportDetector.mismatchReason(expected: .rentReceiptPDF, found: .evidence(.rentReceipt)),
                       "Expected the portal's rent receipt, this looks like another rent receipt")
        XCTAssertNil(ImportDetector.intentIssue(ImportRecognition(kind: .evidence(.rentReceipt), confidence: .certain, reason: "test"),
                                                intent: ImportShortcut.receiptPDF(receiptId: 1, replacing: []).intent))
    }

    // MARK: Missing evidence ▸ Add (Task 7 fix round 1)

    /// The item's evidence kind is the expected kind: a file nothing recognises is filed as it
    /// (the declared-kind rule), linked to the item's record.
    func testMissingEvidenceUnrecognisedFileIsFiledAsTheItemsKind() async throws {
        let shortcut = ImportShortcut.attach(.transaction(id("debit")), role: nil, from: .missingEvidence, expected: .builtIn(.insuranceReceipt))
        XCTAssertEqual(shortcut.entryPoint, "Missing evidence ▸ Add")
        XCTAssertEqual(shortcut.intent.expected, .evidence(.insuranceReceipt))
        let url = try drop(EvidenceTestPDFs.textPDF(["Clause one and clause two", "Synthetic words only"], name: "scan 9.pdf"), as: "scan 9.pdf")
        let plan = try await pipeline.plan([url], intent: shortcut.intent)
        let item = try XCTUnwrap(plan.items.first)
        XCTAssertEqual(item.recognition.kind, .evidence(.insuranceReceipt))
        XCTAssertEqual(item.recognition.confidence, .certain)
        XCTAssertEqual(item.recognition.reason, "You added it as a \(DocumentKind.insuranceReceipt.displayName) from Missing evidence ▸ Add")
        let link = try XCTUnwrap(item.links.first { $0.entity == .transaction(id("debit")) }, "\(item.links)")
        XCTAssertEqual(link.reasons, ["You added it from Missing evidence ▸ Add"])
        XCTAssertEqual(item.section, .ready, "\(item.needsYouReasons)")
    }

    /// A file recognised as another kind than the item asks for stays a kind mismatch.
    func testMissingEvidenceContradictingFileIsKindMismatch() async throws {
        let shortcut = ImportShortcut.attach(.transaction(id("debit")), role: nil, from: .missingEvidence, expected: .builtIn(.bankStatement))
        let plan = try await pipeline.plan([try p60()], intent: shortcut.intent)
        let item = try XCTUnwrap(plan.items.first { $0.parentId == nil })
        XCTAssertEqual(item.section, .needsYou)
        XCTAssertTrue(item.issues.contains { $0.kind == .kindMismatch(expected: .evidence(.bankStatement), found: .payrollForm(.p60)) },
                      "\(item.issues)")
        XCTAssertFalse(item.links.contains { $0.entity == .transaction(id("debit")) })
    }

    /// The item asks for a document kind, whichever reader reads it: a P60 read by the payroll
    /// reader, a statement read as BBVA's or a CSV, a utility invoice the invoice reader reads.
    func testMissingEvidenceKindMatchesWhicheverReaderReadsIt() {
        func issue(_ expected: DocumentKind, _ found: ImportKind) -> ImportIssue? {
            let intent = ImportShortcut.attach(.transaction(1), role: nil, from: .missingEvidence, expected: .builtIn(expected)).intent
            return ImportDetector.intentIssue(ImportRecognition(kind: found, confidence: .certain, reason: "test"), intent: intent)
        }
        XCTAssertNil(issue(.p60, .payrollForm(.p60)))
        XCTAssertNil(issue(.bankStatement, .bbvaStatement))
        XCTAssertNil(issue(.bankStatement, .bankStatementCSV))
        XCTAssertNil(issue(.utilityInvoice, .utilityInvoice))
        XCTAssertNil(issue(.insuranceReceipt, .evidence(.insuranceReceipt)))
        XCTAssertNotNil(issue(.p60, .payrollForm(.p45)), "another form is another document kind")
        XCTAssertNotNil(issue(.insuranceReceipt, .evidence(.utilityInvoice)))
        // Without an expected kind, nothing is expected (any file).
        XCTAssertNil(ImportShortcut.attach(.transaction(1), role: nil, from: .missingEvidence).intent.expected)
        // Other shortcuts keep their strict kinds (Utility invoices… still wants the invoice reader's kind).
        XCTAssertNotNil(ImportDetector.intentIssue(ImportRecognition(kind: .evidence(.utilityInvoice), confidence: .certain, reason: "test"),
                                                   intent: ImportShortcut.utilityInvoices(propertyId: 1).intent))
    }


    // MARK: Missing evidence ▸ Add, the item's period (Task 7 fix round 2)

    private static let january = DateInterval(start: date(2024, 1, 1), end: date(2024, 2, 1))

    /// A document with no period of its own gets the item's (its last day the slot's end − 1).
    func testMissingEvidencePeriodFillsADocumentWithoutOne() async throws {
        let shortcut = ImportShortcut.attach(.transaction(id("debit")), role: nil, from: .missingEvidence, expected: .builtIn(.insuranceReceipt),
                                             period: Self.january)
        XCTAssertEqual(shortcut.intent.period, Self.january)
        let plan = try await pipeline.plan([try insurancePDF()], intent: shortcut.intent)
        let item = try XCTUnwrap(plan.items.first)
        let start = try XCTUnwrap(item.facts.first { $0.field == .periodStart })
        let end = try XCTUnwrap(item.facts.first { $0.field == .periodEnd })
        XCTAssertEqual(start.value, .date(Self.date(2024, 1, 1)))
        XCTAssertEqual(end.value, .date(Self.date(2024, 1, 31)))
        XCTAssertEqual([start.source, end.source], [.intent, .intent])
        XCTAssertEqual([start.confidence, end.confidence], [.certain, .certain])
        XCTAssertEqual(item.placement?.metadata.periodStart, Self.date(2024, 1, 1))
        XCTAssertEqual(item.placement?.metadata.periodEnd, Self.date(2024, 1, 31))
        XCTAssertEqual(item.section, .ready, "\(item.needsYouReasons)")
    }

    /// A document that has its own period keeps it.
    func testMissingEvidencePeriodNeverReplacesTheDocumentsOwn() async throws {
        let shortcut = ImportShortcut.attach(.transaction(id("debit")), role: nil, from: .missingEvidence, expected: .builtIn(.rentReceipt),
                                             period: DateInterval(start: Self.date(2024, 3, 1), end: Self.date(2024, 4, 1)))
        let plan = try await pipeline.plan([try receiptPDF("1")], intent: shortcut.intent)
        let item = try XCTUnwrap(plan.items.first { $0.parentId == nil })
        let periods = item.facts.filter { [.periodStart, .periodEnd].contains($0.field) }
        XCTAssertFalse(periods.isEmpty)
        XCTAssertFalse(periods.contains { $0.source == .intent }, "\(periods)")
        XCTAssertEqual(periods.first { $0.field == .periodStart }?.value, .date(Self.date(2024, 1, 1)))
    }

    /// A shortcut expecting a kind, given a file nothing recognises that isn't declared as it.
    func testKindMismatchForAnUnrecognisedFile() {
        let unknown = ImportRecognition(kind: .unknown, confidence: .needsReview, reason: "Not recognised")
        let issue = ImportDetector.intentIssue(unknown, intent: ImportShortcut.payrollForms(personId: nil, taxYear: nil).intent)
        XCTAssertEqual(issue?.reason, "Expected a P60, but this file isn't recognised")
    }

}
