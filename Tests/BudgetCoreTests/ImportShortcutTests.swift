import XCTest
import GRDB
@testable import BudgetCore
import TestSupport

/// Plan "Import documents 4" Task 1: every import button is a shortcut that only pre-sets the
/// expected type or target (`ImportShortcut`), and intents are per file. Synthetic data only.
final class ImportShortcutTests: XCTestCase {
    private var manager: DatabaseManager!
    private var db: DatabaseQueue { manager.dbQueue }
    private var folder: URL!
    private var library: EvidenceLibrary!
    private var pipeline: ImportPipeline!
    private var propertyId: Int64!
    private var receiptId: Int64!
    private var personId: Int64!
    private var accountId: Int64!

    override func setUpWithError() throws {
        manager = try TestDatabase.migratedManager()
        try db.write { db in
            var property = Property(name: "Property A", country: "PT")
            try Properties.save(db: db, &property)
            propertyId = property.id!
            var tenancy = Tenancy(propertyId: propertyId, referenceLabel: "Room Contract AB", contractNumber: "1001",
                                  tenantName: "TENANT B", startDate: Self.date(2024, 1, 1))
            try Tenancies.save(db: db, &tenancy)
            var receipt = RentReceipt(tenancyId: tenancy.id!, receiptNumber: "1", periodStart: Self.date(2024, 1, 1),
                                      periodEnd: Self.date(2024, 1, 31), receiptDate: Self.date(2024, 1, 3),
                                      amountMinorUnits: 60_000, status: .issued)
            try RentReceipts.save(db: db, &receipt)
            receiptId = receipt.id!
            var person = Person(name: "Person A", ukNino: "QQ 12 34 56 C")
            try People.save(db: db, &person)
            personId = person.id!
            var account = Account(name: "Bank One", currency: .gbp, kind: .cash, trackingMode: .imported)
            try account.insert(db)
            accountId = account.id!
        }
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("ImportShortcutTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        library = EvidenceLibrary(root: folder.appendingPathComponent("Library", isDirectory: true), database: db)
        pipeline = ImportPipeline(dbQueue: db, library: library, categorizationService: CategorizationService(categorizer: FakeCategorizer()))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private static func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        MonthRange.calendar.date(from: DateComponents(year: y, month: m, day: d))!
    }

    // MARK: Files

    private func place(_ url: URL, as name: String) throws -> URL {
        let directory = folder.appendingPathComponent("Drop-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = directory.appendingPathComponent(name)
        try FileManager.default.copyItem(at: url, to: target)
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        return target
    }

    /// Rent receipt nº 1 of contract 1001, matching the stored receipt.
    private func receiptPDF() throws -> URL {
        let lines = RentReceiptPDFsTests.lines(receipt: "1", start: "2024-01-01", end: "2024-01-31", amount: "600,00", received: "600,00",
                                               receivedOn: "2024-01-03")
        return try place(EvidenceTestPDFs.textPDF(lines, name: "r1.pdf"), as: "r1.pdf")
    }

    /// A synthetic P60 for 2024/25 (Example Ltd, NI number QQ123456C, pay £45,678.90).
    private func p60() throws -> URL {
        try place(PayrollFormTestPDFs.textPDF(PayrollFormTestPDFs.p60RowLayout, name: "p60.pdf"), as: "p60.pdf")
    }

    private func note(_ name: String) throws -> URL {
        let url = folder.appendingPathComponent(name)
        try Data("Hello there. Synthetic words only, nothing to recognise.".utf8).write(to: url)
        return url
    }

    private func csv(_ name: String) throws -> URL {
        let url = folder.appendingPathComponent(name)
        try Data("Date,Description,Amount,Balance\n05/01/2026,SHOP A,-10.00,-10.00\n".utf8).write(to: url)
        return url
    }

    // MARK: Catalogue

    func testEveryShortcutHasItsEntryPointAndIntent() {
        let account: Int64 = 11, property: Int64 = 12, receipt: Int64 = 13, tenancy: Int64 = 14, person: Int64 = 15, folderId: Int64 = 16
        let cases: [(ImportShortcut, String, ImportIntent)] = [
            (.statement(accountId: account, format: .csv, from: .dashboard), "Dashboard ▸ Import CSV…",
             ImportIntent(expected: .bankStatementCSV, accountId: account)),
            (.statement(accountId: account, format: .pdf, from: .dashboard), "Dashboard ▸ Import PDF…",
             ImportIntent(expected: .bankStatementPDF, accountId: account)),
            (.statement(accountId: account, format: .csv, from: .accounts), "Accounts ▸ Import CSV…",
             ImportIntent(expected: .bankStatementCSV, accountId: account)),
            (.statement(accountId: account, format: .pdf, from: .accounts), "Accounts ▸ Import PDF…",
             ImportIntent(expected: .bankStatementPDF, accountId: account)),
            (.editColumnMapping(accountId: account), "Accounts ▸ Edit column mapping…",
             ImportIntent(expected: .bankStatementCSV, accountId: account, remapStatement: true)),
            (.rentReceiptsExport(propertyId: property), "Tenancies ▸ Import receipts…",
             ImportIntent(expected: .rentReceiptsExport, propertyId: property)),
            (.receiptPDF(receiptId: receipt, replacing: []), "Receipt ▸ Add PDF…",
             ImportIntent(expected: .rentReceiptPDF, target: .init(entity: .rentReceipt(receipt), role: "Receipt", replacing: []))),
            (.receiptPDF(receiptId: receipt, replacing: [7]), "Receipt ▸ Replace PDF…",
             ImportIntent(expected: .rentReceiptPDF, target: .init(entity: .rentReceipt(receipt), role: "Receipt", replacing: [7]))),
            (.tenancyContract(tenancyId: tenancy), "Tenancy ▸ Add contract…",
             ImportIntent(expected: .evidence(.rentContract), target: .init(entity: .tenancy(tenancy), role: "Contract", replacing: []))),
            (.utilityInvoices(propertyId: property), "Utility invoices…",
             ImportIntent(expected: .utilityInvoice, propertyId: property)),
            (.documents(dropped: false), "Documents ▸ Add documents…", ImportIntent()),
            (.documents(dropped: true), "Documents ▸ Drop", ImportIntent()),
            (.sourceFolder(folderId: folderId, name: "Scans"), "Source folder ▸ Scans", ImportIntent()),
            (.payrollForms(personId: person, taxYear: 2024), "Income ▸ Import P60, P45 or P11D…",
             ImportIntent(expected: .payrollForm(.p60), personId: person, taxYear: 2024)),
            (.payrollForms(personId: nil, taxYear: nil), "Income ▸ Import P60, P45 or P11D…",
             ImportIntent(expected: .payrollForm(.p60))),
            (.attach(.property(property), role: "policy", from: .property), "Property ▸ Add document…",
             ImportIntent(target: .init(entity: .property(property), role: "policy", replacing: []))),
            (.attach(EvidenceEntity(type: .taxManualItem, id: 3), role: nil, from: .manualItem), "Manual item ▸ Add document…",
             ImportIntent(target: .init(entity: EvidenceEntity(type: .taxManualItem, id: 3)))),
            // The Income tab's record sheets (employment, income, pension, HMRC payment).
            (.attach(.employment(5), role: nil, from: .incomeRecord), "Income ▸ Add document…",
             ImportIntent(target: .init(entity: .employment(5)))),
            (.attach(.hmrcPayment(6), role: nil, from: .taxReturn), "Tax return ▸ Add document…",
             ImportIntent(target: .init(entity: .hmrcPayment(6)))),
            (.attach(.transaction(4), role: nil, from: .missingEvidence), "Missing evidence ▸ Add",
             ImportIntent(target: .init(entity: .transaction(4)))),
            (.attach(.transaction(4), role: nil, from: .transaction), "Transaction ▸ Add document",
             ImportIntent(target: .init(entity: .transaction(4)))),
            (.attach(.transaction(4), role: nil, from: .linkPicker), "Link document ▸ Add file…",
             ImportIntent(target: .init(entity: .transaction(4))))
        ]
        for (shortcut, entryPoint, intent) in cases {
            XCTAssertEqual(shortcut.entryPoint, entryPoint, "\(shortcut)")
            var expected = intent
            expected.entryPoint = entryPoint
            XCTAssertEqual(shortcut.intent, expected, "\(shortcut)")
        }
        // The open panel: statements by format, Tenancies' export as a workbook, documents of any kind.
        XCTAssertEqual(ImportShortcut.statement(accountId: account, format: .csv, from: .dashboard).allowedContentTypes,
                       ["public.comma-separated-values-text"])
        XCTAssertEqual(ImportShortcut.statement(accountId: account, format: .pdf, from: .accounts).allowedContentTypes, ["com.adobe.pdf"])
        XCTAssertEqual(ImportShortcut.editColumnMapping(accountId: account).allowedContentTypes, ["public.comma-separated-values-text"])
        XCTAssertEqual(ImportShortcut.rentReceiptsExport(propertyId: property).allowedContentTypes, ["org.openxmlformats.spreadsheetml.sheet"])
        XCTAssertEqual(ImportShortcut.documents(dropped: false).allowedContentTypes, ["com.adobe.pdf", "public.image", "public.data"])
        XCTAssertEqual(ImportShortcut.payrollForms(personId: nil, taxYear: nil).allowedContentTypes, ["com.adobe.pdf", "public.image"])
        XCTAssertTrue(ImportShortcut.sourceFolder(folderId: folderId, name: "Scans").allowedContentTypes.isEmpty)
        // A replacement is one file; a mapping is set up from one file; adding takes several.
        XCTAssertFalse(ImportShortcut.receiptPDF(receiptId: receipt, replacing: [7]).allowsMultiple)
        XCTAssertTrue(ImportShortcut.receiptPDF(receiptId: receipt, replacing: []).allowsMultiple)
        XCTAssertFalse(ImportShortcut.editColumnMapping(accountId: account).allowsMultiple)
        XCTAssertTrue(ImportShortcut.documents(dropped: false).allowsFolders)
        XCTAssertFalse(ImportShortcut.receiptPDF(receiptId: receipt, replacing: []).allowsFolders)
        XCTAssertFalse(ImportShortcut.editColumnMapping(accountId: account).allowsFolders)
        XCTAssertFalse(ImportShortcut.rentReceiptsExport(propertyId: property).allowsMultiple)
        XCTAssertTrue(ImportShortcut.documents(dropped: true).allowsMultiple)
        XCTAssertTrue(ImportShortcut.statement(accountId: account, format: .csv, from: .dashboard).allowsMultiple)
    }

    func testPayrollShortcutTakesAnyPayrollForm() {
        let intent = ImportShortcut.payrollForms(personId: nil, taxYear: nil).intent
        for form in [PayrollFormKind.p60, .p45, .p11d] {
            XCTAssertNil(ImportDetector.intentIssue(ImportRecognition(kind: .payrollForm(form), confidence: .certain, reason: "test"),
                                                    intent: intent), "\(form)")
        }
        XCTAssertNotNil(ImportDetector.intentIssue(ImportRecognition(kind: .rentReceiptPDF, confidence: .certain, reason: "test"),
                                                   intent: intent))
    }

    // MARK: Pipeline

    func testShortcutKindContradictedByFileIsNeedsYou() async throws {
        let plan = try await pipeline.plan([try p60()], intent: ImportShortcut.receiptPDF(receiptId: receiptId, replacing: []).intent)
        let item = try XCTUnwrap(plan.items.first { $0.parentId == nil })
        XCTAssertEqual(item.recognition.kind, .payrollForm(.p60))
        XCTAssertEqual(item.section, .needsYou)
        let issue = try XCTUnwrap(item.issues.first { $0.id == "kindMismatch" }, "\(item.issues)")
        XCTAssertEqual(issue.kind, .kindMismatch(expected: .rentReceiptPDF, found: .payrollForm(.p60)))
        XCTAssertEqual(issue.reason, "Expected a Rent receipt, this looks like a P60")
        XCTAssertFalse(item.links.contains { $0.entity == .rentReceipt(receiptId) }, "\(item.links)")
        guard case .payrollForm = item.effect else { return XCTFail("never filed as a rent receipt: \(item.effect)") }
    }

    func testAddingFilesKeepsEachIntent() async throws {
        let receiptIntent = ImportShortcut.receiptPDF(receiptId: receiptId, replacing: []).intent
        let invoiceIntent = ImportShortcut.utilityInvoices(propertyId: propertyId).intent
        let first = try await pipeline.plan([try receiptPDF()], intent: receiptIntent)
        let plan = try await pipeline.plan(adding: [try note("invoice.txt")], to: first, intent: invoiceIntent)
        let receipt = try XCTUnwrap(plan.items.first { $0.file.fileName == "r1.pdf" && $0.parentId == nil })
        let other = try XCTUnwrap(plan.items.first { $0.file.fileName == "invoice.txt" })
        XCTAssertEqual(plan.intent(of: receipt.id), receiptIntent)
        XCTAssertEqual(plan.intent(of: other.id), invoiceIntent)
        XCTAssertEqual(plan.intent(of: receipt.id).entryPoint, "Receipt ▸ Add PDF…")
        XCTAssertEqual(plan.intent(of: other.id).entryPoint, "Utility invoices…")
        // Each checked against its own shortcut: the receipt is what it was added as, the note isn't an invoice.
        XCTAssertFalse(receipt.issues.contains { $0.id == "kindMismatch" }, "\(receipt.issues)")
        XCTAssertTrue(other.issues.contains { $0.kind == .kindMismatch(expected: .utilityInvoice, found: other.recognition.kind) },
                      "\(other.issues)")
        // Answering a question on one keeps the other's intent.
        let resolved = try await pipeline.resolve(plan, itemId: other.id, .leaveOut)
        XCTAssertEqual(resolved.intent(of: receipt.id), receiptIntent)
        XCTAssertEqual(resolved.intent(of: other.id), invoiceIntent)
    }

    func testPresetTaxYearDoesNotBypassFiledGuard() async throws {
        let personId = self.personId!
        try await db.write { db in
            var year = TaxYear(startYear: 2024, personId: personId, status: .filed)
            try year.insert(db)
            var employment = Employment(startYear: 2024, personId: personId, employerName: "Example Ltd", payeReference: "123/AB456")
            try Employments.save(db: db, &employment)
            var income = EmploymentIncome(employmentId: employment.id!, source: .p60, payMinorUnits: 4_000_000, taxDeductedMinorUnits: 600_000)
            try Employments.save(db: db, &income)
        }
        let shortcut = ImportShortcut.payrollForms(personId: personId, taxYear: 2024)
        let plan = try await pipeline.plan([try p60()], intent: shortcut.intent)
        let item = try XCTUnwrap(plan.items.first { $0.parentId == nil })
        XCTAssertEqual(item.recognition.kind, .payrollForm(.p60))
        XCTAssertFalse(item.issues.contains { $0.id == "kindMismatch" }, "\(item.issues)")
        XCTAssertTrue(item.issues.contains { if case .filedYear = $0.kind { return true }; return false }, "\(item.issues)")
        XCTAssertTrue(item.isHeldByFiledYear)
        XCTAssertEqual(item.section, .needsYou)
        XCTAssertFalse(plan.canConfirm)
    }

    func testEditColumnMappingAsksToRemap() async throws {
        let saved = try ImportProfileStore(dbQueue: db).save(ImportProfile(accountId: accountId, format: .csv, csvDelimiter: ",",
                                                                           csvDateColumnIndex: 0, csvDescriptionColumnIndex: 1,
                                                                           csvAmountColumnIndex: 2, csvBalanceColumnIndex: 3,
                                                                           csvDateFormat: "dd/MM/yyyy"))
        // Imported with the plain shortcut, the saved mapping reads it.
        let plain = try await pipeline.plan([try csv("plain.csv")], intent: ImportShortcut.statement(accountId: accountId, format: .csv, from: .accounts).intent)
        XCTAssertFalse(plain.items.contains { $0.issues.contains { $0.kind == .statement(.remap(format: .csv, accountId: accountId)) } })

        // Edit column mapping…: the mapping is asked again, prefilled with the saved one.
        let plan = try await pipeline.plan([try csv("remap.csv")], intent: ImportShortcut.editColumnMapping(accountId: accountId).intent)
        let item = try XCTUnwrap(plan.items.first { $0.parentId == nil })
        XCTAssertEqual(item.section, .needsYou)
        let issue = try XCTUnwrap(item.issues.first { $0.kind == .statement(.remap(format: .csv, accountId: accountId)) }, "\(item.issues)")
        XCTAssertEqual(issue.offers, [.saveProfile(saved)])
        XCTAssertFalse(plan.canConfirm)

        // The mapping set up in the review: the statement read with it, saved on Confirm import.
        var edited = saved
        edited.csvDateFormat = "dd/MM/yyyy"
        edited.csvBalanceColumnIndex = nil
        XCTAssertTrue(ImportResolutions.accepts(issue, .saveProfile(edited)))
        XCTAssertFalse(ImportResolutions.accepts(issue, .saveProfile(ImportProfile(accountId: accountId + 1, format: .csv))))
        let resolved = try await pipeline.resolve(plan, itemId: item.id, issueId: issue.id, .saveProfile(edited))
        let read = try XCTUnwrap(resolved.items.first { $0.id == item.id })
        XCTAssertFalse(read.issues.contains { if case .statement(.remap) = $0.kind { return true }; return false }, "\(read.issues)")
        guard case .ukStatement(let effect) = read.effect else { return XCTFail("effect \(read.effect)") }
        XCTAssertEqual(effect.staged.count, 1)
        XCTAssertEqual(effect.profileToSave?.csvBalanceColumnIndex, nil)
        XCTAssertEqual(effect.profileToSave?.accountId, accountId)
        XCTAssertTrue(resolved.canConfirm, "\(resolved.items.map(\.needsYouReasons))")
    }

    /// Ruling 2: Edit column mapping… with the CSV already imported: the item isn't a duplicate,
    /// it is answerable, and Confirm import saves the mapping although it adds no rows.
    func testEditColumnMappingWithTheAlreadyImportedCSVSavesTheProfile() async throws {
        let accountId = self.accountId!
        let saved = try ImportProfileStore(dbQueue: db).save(ImportProfile(accountId: accountId, format: .csv, csvDelimiter: ",",
                                                                           csvDateColumnIndex: 0, csvDescriptionColumnIndex: 1,
                                                                           csvAmountColumnIndex: 2, csvBalanceColumnIndex: 3,
                                                                           csvDateFormat: "dd/MM/yyyy"))
        let applier = ImportApplier(dbQueue: db, databasePath: nil, library: library)
        let first = try await pipeline.plan([try csv("same.csv")], intent: ImportShortcut.statement(accountId: accountId, format: .csv, from: .accounts).intent)
        XCTAssertTrue(first.canConfirm, "\(first.items.map(\.needsYouReasons))")
        _ = try applier.apply(first, entryPoint: "Accounts ▸ Import CSV…")
        let rowsBefore = try await db.read { try Transaction.filter(Column("accountId") == accountId).fetchCount($0) }
        XCTAssertEqual(rowsBefore, 1)
        let documentsBefore = try await db.read { try EvidenceDocument.fetchCount($0) }

        let plan = try await pipeline.plan([try csv("same.csv")], intent: ImportShortcut.editColumnMapping(accountId: accountId).intent)
        let item = try XCTUnwrap(plan.items.first { $0.parentId == nil })
        XCTAssertNil(item.duplicate, "\(item.duplicate.map(\.of) ?? "")")
        XCTAssertEqual(item.section, .needsYou)
        let issue = try XCTUnwrap(item.issues.first { $0.kind == .statement(.remap(format: .csv, accountId: accountId)) }, "\(item.issues)")
        var edited = saved
        edited.csvBalanceColumnIndex = nil
        let resolved = try await pipeline.resolve(plan, itemId: item.id, issueId: issue.id, .saveProfile(edited))
        let read = try XCTUnwrap(resolved.items.first { $0.id == item.id })
        XCTAssertNil(read.duplicate, "\(read.duplicate.map(\.of) ?? "")")
        XCTAssertEqual(read.section, .ready, "\(read.needsYouReasons)")
        XCTAssertTrue(resolved.canConfirm, "\(resolved.items.map(\.needsYouReasons))")
        _ = try applier.apply(resolved, entryPoint: "Accounts ▸ Edit column mapping…")

        let profile = try XCTUnwrap(try ImportProfileStore(dbQueue: db).find(accountId: accountId, format: .csv))
        XCTAssertNil(profile.csvBalanceColumnIndex)
        let rowsAfter = try await db.read { try Transaction.filter(Column("accountId") == accountId).fetchCount($0) }
        XCTAssertEqual(rowsAfter, 1)
        let documentsAfter = try await db.read { try EvidenceDocument.fetchCount($0) }
        XCTAssertEqual(documentsAfter, documentsBefore)
    }

    // MARK: Utility invoices from the library (final review, Ruling 3)

    private func powerProvider() async throws -> Int64 {
        let propertyId = self.propertyId!
        return try await db.write { db in
            let rules = UtilityInvoiceRules(textMarkers: ["DEMO POWER"], invoiceNumberPatterns: [#"INVOICE NO\.?\s*(FT \d+/\d+)"#],
                                            issueDateLabels: ["ISSUED ON"], amountLabels: ["AMOUNT DUE"])
            var power = UtilityProvider(propertyId: propertyId, name: "Demo Power", kind: .electricity, invoiceRules: rules)
            try Recharges.saveProvider(db: db, &power)
            return power.id!
        }
    }

    /// Invoice FT 1/23 of Demo Power, already in the library (not recorded as an invoice).
    private func libraryInvoice() throws -> Int64 {
        let lines = ["DEMO POWER", "Issued on: 5 de março 2023", "Amount due 100,00 EUR", "Invoice no. FT 1/23"]
        let url = try place(EvidenceTestPDFs.textPDF(lines, name: "luz.pdf"), as: "luz.pdf")
        return try XCTUnwrap(try library.addAnalyzing(url).document.id)
    }

    func testUtilityInvoicesBringsPendingLibraryInvoicesAndRecordsThemOnTheSameDocument() async throws {
        _ = try await powerProvider()
        let documentId = try libraryInvoice()
        let shortcut = ImportShortcut.utilityInvoices(propertyId: propertyId)
        let pending = try await db.read { try shortcut.libraryDocumentIds(db: $0) }
        XCTAssertEqual(pending, [documentId])

        let plan = try await pipeline.plan(adding: [], libraryDocuments: pending, to: ImportPlan(items: []), intent: shortcut.intent)
        let item = try XCTUnwrap(plan.items.first { $0.parentId == nil })
        XCTAssertEqual(item.file.fileName, "luz.pdf")
        XCTAssertNil(item.duplicate, "\(item.duplicate.map(\.of) ?? "")")
        XCTAssertTrue(item.notes.contains(ImportDuplicates.libraryInvoiceNote), "\(item.notes)")
        guard case .utilityInvoice = item.effect else { return XCTFail("effect \(item.effect)") }
        XCTAssertTrue(plan.canConfirm, "\(plan.items.map(\.needsYouReasons))")

        _ = try ImportApplier(dbQueue: db, databasePath: nil, library: library).apply(plan, entryPoint: shortcut.entryPoint)
        try await db.read { db in
            XCTAssertEqual(try EvidenceDocument.fetchCount(db), 1)
            let invoice = try XCTUnwrap(try UtilityInvoice.fetchOne(db))
            XCTAssertEqual(invoice.documentId, documentId)
            XCTAssertEqual(invoice.invoiceNumber, "FT 1/23")
        }
        // Recorded now: no longer brought in, and the file added again is a duplicate.
        let after = try await db.read { try shortcut.libraryDocumentIds(db: $0) }
        XCTAssertEqual(after, [])
        let again = try await pipeline.plan(adding: [], libraryDocuments: [documentId], to: ImportPlan(items: []), intent: shortcut.intent)
        XCTAssertNotNil(again.items.first?.duplicate, "\(again.items.first?.needsYouReasons ?? [])")
    }

    func testAnInvoiceAlreadyRecordedOnItsLibraryDocumentStaysADuplicate() async throws {
        let providerId = try await powerProvider()
        let documentId = try libraryInvoice()
        try await db.write { db in
            var invoice = UtilityInvoice(providerId: providerId, invoiceNumber: "FT 9/99", issueDate: Self.date(2023, 3, 5),
                                         amountMinorUnits: 10_000, documentId: documentId)
            try invoice.insert(db)
        }
        let shortcut = ImportShortcut.utilityInvoices(propertyId: propertyId)
        let pending = try await db.read { try shortcut.libraryDocumentIds(db: $0) }
        XCTAssertEqual(pending, [])
        let plan = try await pipeline.plan(adding: [], libraryDocuments: [documentId], to: ImportPlan(items: []), intent: shortcut.intent)
        let item = try XCTUnwrap(plan.items.first { $0.parentId == nil })
        XCTAssertEqual(item.section, .duplicates, "\(item.needsYouReasons)")
        XCTAssertFalse(item.notes.contains(ImportDuplicates.libraryInvoiceNote))
    }

    /// N1: the same pending invoice picked as a file and brought from the library in one go:
    /// one item records it, the other is the same file (no second invoice, Confirm works).
    func testPendingInvoicePickedAndFromLibraryIsRecordedOnce() async throws {
        _ = try await powerProvider()
        let documentId = try libraryInvoice()
        let stored = try await db.read { db in try XCTUnwrap(try EvidenceDocument.fetchOne(db, key: documentId)) }
        let picked = folder.appendingPathComponent("picked-luz.pdf")
        try FileManager.default.copyItem(at: library.fileURL(for: stored), to: picked)
        let shortcut = ImportShortcut.utilityInvoices(propertyId: propertyId)
        let plan = try await pipeline.plan(adding: [picked], libraryDocuments: [documentId], to: ImportPlan(items: []), intent: shortcut.intent)
        let top = plan.items.filter { $0.parentId == nil }
        XCTAssertEqual(top.count, 2)
        XCTAssertEqual(top.filter { $0.duplicate == nil }.count, 1, "\(top.map { $0.duplicate?.of ?? "-" })")
        XCTAssertEqual(top.last?.duplicate?.level, .file)
        XCTAssertTrue(plan.canConfirm, "\(plan.items.map(\.needsYouReasons))")
        _ = try ImportApplier(dbQueue: db, databasePath: nil, library: library).apply(plan, entryPoint: shortcut.entryPoint)
        try await db.read { db in
            XCTAssertEqual(try UtilityInvoice.fetchCount(db), 1)
            XCTAssertEqual(try EvidenceDocument.fetchCount(db), 1)
        }
    }

    /// N1: Utility invoices… from the library again while the review is open: the library
    /// documents already in it aren't added twice (nor one picked as a file before).
    func testLibraryInvoicesAlreadyInTheOpenReviewAreNotAddedAgain() async throws {
        _ = try await powerProvider()
        let documentId = try libraryInvoice()
        let shortcut = ImportShortcut.utilityInvoices(propertyId: propertyId)
        let first = try await pipeline.plan(adding: [], libraryDocuments: [documentId], to: ImportPlan(items: []), intent: shortcut.intent)
        let again = try await pipeline.plan(adding: [], libraryDocuments: [documentId], to: first, intent: shortcut.intent)
        XCTAssertEqual(again.items.filter { $0.parentId == nil }.count, 1)
        XCTAssertTrue(again.canConfirm, "\(again.items.map(\.needsYouReasons))")

        let stored = try await db.read { db in try XCTUnwrap(try EvidenceDocument.fetchOne(db, key: documentId)) }
        let picked = folder.appendingPathComponent("picked-luz.pdf")
        try FileManager.default.copyItem(at: library.fileURL(for: stored), to: picked)
        let pickedFirst = try await pipeline.plan([picked], intent: shortcut.intent)
        let thenLibrary = try await pipeline.plan(adding: [], libraryDocuments: [documentId], to: pickedFirst, intent: shortcut.intent)
        XCTAssertEqual(thenLibrary.items.filter { $0.parentId == nil }.count, 1)
    }

    func testOtherShortcutsBringNothingFromTheLibrary() async throws {
        _ = try await powerProvider()
        _ = try libraryInvoice()
        let ids = try await db.read { try ImportShortcut.documents(dropped: false).libraryDocumentIds(db: $0) }
        XCTAssertEqual(ids, [])
    }
}
