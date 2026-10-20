import XCTest
import GRDB
@testable import BudgetCore

/// Plan "Import documents 1" Task 13: a confirmed plan applied as one undoable run (one write,
/// change capture, files filed, effects and links, follow-on matching, the confirm-time filed
/// return backstop) and the backup before large changes. Synthetic data only: Property A with a
/// tenancy (contract 1001, receipts 1 and 2 of €600.00), its account Bank A with a €120.00 debit,
/// Person A whose 2024/25 return is filed (P60 pay £40,000.00 at Acme Ltd).
final class ImportApplierTests: XCTestCase {
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
        try seed(db)
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("ImportApplierTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        library = EvidenceLibrary(root: folder.appendingPathComponent("Library", isDirectory: true), database: db)
        pipeline = ImportPipeline(dbQueue: db, library: library, categorizationService: CategorizationService(categorizer: FakeCategorizer()))
        applier = ImportApplier(dbQueue: db, databasePath: nil, library: library)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func seed(_ queue: DatabaseQueue) throws {
        try queue.write { db in
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
            ids["bank"] = account.id!
            var batch = ImportBatch(accountId: account.id!, sourceFileName: "earlier.csv", importedAt: Date())
            try batch.insert(db)
            ids["batch"] = batch.id!
            try Properties.setAccount(db: db, propertyId: property.id!, accountId: account.id!, role: .current)
            var group = CategoryGroup(name: "Property A")
            try group.insert(db)
            try Properties.addCategoryGroup(db: db, propertyId: property.id!, categoryGroupId: group.id!)
            var rent = Category(name: "Rental income", type: .income, groupId: group.id)
            try rent.insert(db)
            ids["rent"] = rent.id!
            var debit = Transaction(importBatchId: batch.id!, accountId: account.id!, date: Self.date(2024, 3, 10), rawDescription: "PAYMENT 77",
                                    amountMinorUnits: -12_000, categoryId: nil, status: .confirmed, categorizedBy: .manual,
                                    fingerprint: "fp-debit")
            try debit.insert(db)
            ids["debit"] = debit.id!

            var person = Person(name: "Person A", shortName: "A")
            try People.save(db: db, &person)
            ids["person"] = person.id!
            var year = TaxYear(startYear: 2024, personId: person.id!, status: .filed)
            try year.insert(db)
            var employment = Employment(startYear: 2024, personId: person.id!, employerName: "Acme Ltd")
            try Employments.save(db: db, &employment)
            var income = EmploymentIncome(employmentId: employment.id!, source: .p60, payMinorUnits: 4_000_000, taxDeductedMinorUnits: 600_000)
            try Employments.save(db: db, &income)
            ids["income"] = income.id!
        }
    }

    // MARK: Files

    private func drop(_ url: URL, as name: String) throws -> URL {
        let directory = folder.appendingPathComponent("Drop", isDirectory: true)
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
        return try drop(EvidenceTestPDFs.textPDF(lines, name: "r1.pdf"), as: "r1.pdf")
    }

    /// An insurance receipt of €120.00 paid by the debit.
    private func insurancePDF(_ name: String = "seguro.pdf") throws -> URL {
        try drop(EvidenceTestPDFs.textPDF(["SEGURO MULTI-RISCO HABITACAO", "Data: 10/03/2024", "TOTAL 120,00 €"], name: name), as: name)
    }

    private func plainFile(_ name: String, _ text: String = "Synthetic words only") throws -> URL {
        let directory = folder.appendingPathComponent("Drop", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url
    }

    private func importFile(_ url: URL) throws -> ImportFile {
        try ImportFile.load(url, ocr: false)
    }

    private func storedFiles() -> Set<String> {
        let root = library.root
        guard let enumerator = FileManager.default.enumerator(atPath: root.path) else { return [] }
        var files: Set<String> = []
        for case let path as String in enumerator {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path, isDirectory: &isDirectory), !isDirectory.boolValue {
                files.insert(path)
            }
        }
        return files
    }

    /// A synchronous read (async tests would pick GRDB's async overload).
    private func read<T>(_ body: (Database) throws -> T) throws -> T {
        try db.read(body)
    }

    /// Every tracked table's rows, in rowid order.
    private func trackedDump() throws -> [String: [Row]] {
        try read { db in
            var dump: [String: [Row]] = [:]
            for table in try ImportChangeCapture.trackedTables(db: db) {
                dump[table] = try Row.fetchAll(db, sql: "SELECT rowid AS rowid_, * FROM \"\(table)\" ORDER BY rowid")
            }
            return dump
        }
    }

    private func trackedCounts() throws -> [String: Int] {
        try read { db in
            var counts: [String: Int] = [:]
            for table in try ImportChangeCapture.trackedTables(db: db) {
                counts[table] = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \"\(table)\"")
            }
            return counts
        }
    }

    // MARK: Items built by hand (as the readers make them)

    private func staged(_ day: (Int, Int, Int), _ description: String, _ amount: Int, category: String?) -> StagedTransaction {
        StagedTransaction(parsed: ParsedTransaction(date: Self.date(day.0, day.1, day.2), rawDescription: description, amountMinorUnits: amount),
                          suggestedCategoryId: category.map(id), source: .rule, confidence: 1, fingerprint: "fp-\(description)-\(amount)")
    }

    private func statementItem(_ rows: [StagedTransaction], statement: StatementFinish? = nil, accountId: Int64? = nil,
                               name: String = "bank-a.csv") throws -> ImportItem {
        let file = try importFile(try plainFile(name, "Date,Description,Amount\n" + rows.map { "\($0.parsed.rawDescription)" }.joined(separator: "\n")))
        let effect = UKStatementEffect(accountId: accountId ?? id("bank"), sourceFileName: name, staged: rows, statement: statement, accountFill: nil)
        return ImportItem(file: file, recognition: ImportRecognition(kind: .bankStatementCSV, confidence: .certain, reason: "Saved profile"),
                          title: "Bank A statement", placement: ImportPlacement(metadata: EvidenceMetadata(kind: .bankStatement), canonicalName: name),
                          effect: .ukStatement(effect), groupKey: "Bank statements")
    }

    private func documentItem(_ name: String, text: String = "Synthetic words only") throws -> ImportItem {
        let file = try importFile(try plainFile(name, text))
        return ImportItem(file: file, recognition: ImportRecognition(kind: .evidence(.other), confidence: .certain, reason: "test"),
                          title: name, placement: ImportPlacement(metadata: EvidenceMetadata(kind: .other), canonicalName: name),
                          effect: .file, groupKey: "Other documents")
    }

    private func p60Item(pay: Int) throws -> ImportItem {
        let file = try importFile(try plainFile("p60.txt", "P60 synthetic"))
        let confirmed = PayrollFormImport.Confirmed(kind: .p60, personId: id("person"), startYear: 2024, employerName: "Acme Ltd",
                                                    payMinorUnits: pay, taxDeductedMinorUnits: 600_000)
        return ImportItem(file: file, recognition: ImportRecognition(kind: .payrollForm(.p60), confidence: .certain, reason: "P60 layout"),
                          title: "P60 2024/25 Acme Ltd",
                          placement: ImportPlacement(metadata: EvidenceMetadata(kind: .p60), canonicalName: "p60.txt"),
                          effect: .payrollForm(confirmed), groupKey: "Payroll forms")
    }

    // MARK: Applying

    func testApplyFilesLinksAndRecordsRun() async throws {
        let plan = try await pipeline.plan([try receiptPDF(), try insurancePDF()])
        XCTAssertEqual(plan.items(in: .ready).map(\.file.fileName), ["r1.pdf", "seguro.pdf"],
                       "\(plan.items.map { ($0.file.fileName, $0.needsYouReasons) })")
        XCTAssertTrue(plan.canConfirm)
        let summary = try applier.apply(plan, entryPoint: "Import…")
        XCTAssertEqual(summary.filed, 2)
        XCTAssertEqual(summary.linked, 2)
        XCTAssertEqual(summary.transactions, 0)
        XCTAssertNil(summary.backupPath)
        XCTAssertEqual(summary.text, "2 documents filed, 2 linked")
        try read { db in
            let files = try ImportRunFile.filter(Column("runId") == summary.runId).order(Column("id")).fetchAll(db)
            XCTAssertEqual(files.map(\.outcome), [.linked, .linked])
            XCTAssertEqual(files.map(\.fileName), ["r1.pdf", "seguro.pdf"])
            XCTAssertTrue(files.allSatisfy { $0.documentId != nil })
            XCTAssertGreaterThan(try ImportChange.filter(Column("runId") == summary.runId).fetchCount(db), 0)
            let run = try XCTUnwrap(ImportRun.fetchOne(db, key: summary.runId))
            XCTAssertEqual(run.summary, summary.text)
            XCTAssertEqual(run.entryPoint, "Import…")
            XCTAssertEqual(try EvidenceDocument.fetchCount(db), 2)
            let insurance = try XCTUnwrap(files.last?.documentId)
            XCTAssertTrue(try DocumentLink.filter(Column("documentId") == insurance).fetchAll(db).contains { $0.entity == .transaction(self.id("debit")) })
            let receipt = try XCTUnwrap(files.first?.documentId)
            XCTAssertTrue(try DocumentLink.filter(Column("documentId") == receipt).fetchAll(db).contains { $0.entity == .rentReceipt(self.id("receipt1")) })
        }
        XCTAssertEqual(storedFiles().count, 2)
    }

    // MARK: Corrected versions of recorded invoices and receipts

    /// A library document `name` (text `text`) linked to `entity`.
    private func linkedLibraryDocument(_ name: String, text: String, kind: DocumentKind, amount: Int, to entity: EvidenceEntity) throws -> Int64 {
        let added = try library.add(try plainFile(name, text), metadata: EvidenceMetadata(kind: kind, amountMinorUnits: amount, currency: .eur,
                                                                                         textStatus: .text, extractedText: text))
        let documentId = try XCTUnwrap(added.document.id)
        try db.write { db in _ = try EvidenceLinks.link(db: db, documentId: documentId, to: entity) }
        return documentId
    }

    /// The plan of `items` as the pipeline reads it (duplicate pass and guard), then the
    /// corrected-version issue answered with "File the document only".
    private func filedAsDocumentOnly(_ items: [ImportItem]) async throws -> ImportPlan {
        let annotated = try read { db in try ImportPipeline.annotate(ImportPlan(items: items), checking: nil, db: db) }
        let item = try XCTUnwrap(annotated.items.first { $0.issues.contains { $0.id == ImportDuplicates.correctedVersionIssueId } },
                                 "\(annotated.items.map(\.needsYouReasons))")
        return try await pipeline.resolve(annotated, itemId: item.id, issueId: ImportDuplicates.correctedVersionIssueId, .fileWithoutLink)
    }

    private func invoiceItem(_ name: String, amount: Int, providerId: Int64, copy: String = "") throws -> ImportItem {
        let file = try importFile(try plainFile(name, "Demo Power invoice FT 1/23, corrected: total \(amount / 100),00\(copy)"))
        let day = Self.date(2024, 3, 5)
        return ImportItem(file: file, recognition: ImportRecognition(kind: .utilityInvoice, confidence: .certain, reason: "Demo Power layout"),
                          title: "Invoice FT 1/23 of Demo Power",
                          facts: [ImportFact(field: .invoiceNumber, value: .text("FT 1/23"), source: .textLayer, confidence: .certain, reason: "test"),
                                  ImportFact(field: .docDate, value: .date(day), source: .textLayer, confidence: .certain, reason: "test"),
                                  ImportFact(field: .amount, value: .money(amount, .eur), source: .textLayer, confidence: .certain, reason: "test")],
                          placement: ImportPlacement(metadata: EvidenceMetadata(kind: .utilityInvoice, docDate: day, amountMinorUnits: amount, currency: .eur),
                                                     canonicalName: name),
                          effect: .utilityInvoice(UtilityInvoice(providerId: providerId, invoiceNumber: "FT 1/23", issueDate: day, amountMinorUnits: amount)),
                          groupKey: "Utility invoices")
    }

    func testCorrectedUtilityInvoiceIsFiledAsADocumentOnly() async throws {
        let original = try linkedLibraryDocument("invoice.txt", text: "Demo Power invoice FT 1/23 total 120,00", kind: .utilityInvoice,
                                                 amount: 12_000, to: .transaction(id("debit")))
        let providerId = try await db.write { db -> Int64 in
            var provider = UtilityProvider(propertyId: self.id("property"), name: "Demo Power", kind: .electricity)
            try Recharges.saveProvider(db: db, &provider)
            var invoice = UtilityInvoice(providerId: provider.id!, invoiceNumber: "FT 1/23", issueDate: Self.date(2024, 3, 5),
                                         amountMinorUnits: 12_000, documentId: original, transactionId: self.id("debit"))
            try invoice.insert(db)
            return provider.id!
        }
        let plan = try await filedAsDocumentOnly([try invoiceItem("invoice-corrected.txt", amount: 13_000, providerId: providerId)])
        let item = try XCTUnwrap(plan.items.first)
        XCTAssertEqual(item.effect, .file)
        XCTAssertTrue(item.notes.contains("Recorded figures unchanged: correct the invoice on its screen if needed"))
        XCTAssertTrue(plan.canConfirm, "\(item.needsYouReasons)")
        let summary = try applier.apply(plan, entryPoint: "Import…")
        try read { db in
            XCTAssertEqual(try UtilityInvoice.fetchCount(db), 1)
            XCTAssertEqual(try UtilityInvoice.fetchOne(db)?.amountMinorUnits, 12_000)
            let filed = try XCTUnwrap(ImportRunFile.filter(Column("runId") == summary.runId).fetchOne(db)?.documentId)
            XCTAssertNotEqual(filed, original)
            XCTAssertTrue(try DocumentLink.filter(Column("documentId") == filed).fetchAll(db).contains { $0.entity == .transaction(self.id("debit")) })
        }
        // Imported again — the same file, or another copy of the corrected invoice — it is a copy.
        let again = try await pipeline.plan([item.file.url])
        XCTAssertEqual(again.items.first?.section, .duplicates)
        let copyItem = try invoiceItem("invoice-corrected copy.txt", amount: 13_000, providerId: providerId, copy: "\nDownloaded again")
        let copy = try read { db in try ImportDuplicates.annotate([copyItem], db: db) }
        XCTAssertEqual(copy.first?.duplicate?.level, .document, "\(copy.first?.needsYouReasons ?? [])")
    }

    /// Filed as a document only, the corrected invoice is still invoice FT 1/23 for the
    /// duplicate pass: another copy of it in the batch is a copy, not a second correction.
    func testCopyOfACorrectedInvoiceFiledOnlyIsACopyOfIt() async throws {
        let original = try linkedLibraryDocument("invoice.txt", text: "Demo Power invoice FT 1/23 total 120,00", kind: .utilityInvoice,
                                                 amount: 12_000, to: .transaction(id("debit")))
        let providerId = try await db.write { db -> Int64 in
            var provider = UtilityProvider(propertyId: self.id("property"), name: "Demo Power", kind: .electricity)
            try Recharges.saveProvider(db: db, &provider)
            var invoice = UtilityInvoice(providerId: provider.id!, invoiceNumber: "FT 1/23", issueDate: Self.date(2024, 3, 5),
                                         amountMinorUnits: 12_000, documentId: original, transactionId: self.id("debit"))
            try invoice.insert(db)
            return provider.id!
        }
        let plan = try await filedAsDocumentOnly([try invoiceItem("invoice-corrected.txt", amount: 13_000, providerId: providerId),
                                                  try invoiceItem("invoice-corrected copy.txt", amount: 13_000, providerId: providerId,
                                                                  copy: "\nDownloaded again")])
        XCTAssertEqual(plan.items[0].effect, .file)
        XCTAssertEqual(plan.items[1].duplicate?.of, "Same document as invoice-corrected.txt", "\(plan.items[1].needsYouReasons)")
    }

    func testCorrectedRentReceiptIsFiledAsADocumentOnly() async throws {
        _ = try linkedLibraryDocument("recibo.txt", text: "Recibo 1001/1 600,00", kind: .rentReceipt, amount: 60_000, to: .rentReceipt(id("receipt1")))
        let file = try importFile(try plainFile("recibo-corrigido.txt", "Recibo 1001/1 620,00"))
        let facts = [ImportFact(field: .reference, value: .text("1001"), source: .textLayer, confidence: .certain, reason: "test"),
                     ImportFact(field: .receiptNumber, value: .text("1"), source: .textLayer, confidence: .certain, reason: "test"),
                     ImportFact(field: .amount, value: .money(62_000, .eur), source: .textLayer, confidence: .certain, reason: "test")]
        let receipt = ImportItem(file: file, recognition: ImportRecognition(kind: .rentReceiptPDF, confidence: .certain, reason: "Portal receipt"),
                                 title: "Rent receipt nº 1, contract 1001", facts: facts,
                                 placement: ImportPlacement(metadata: EvidenceMetadata(kind: .rentReceipt), canonicalName: "recibo-corrigido.txt"),
                                 groupKey: "Rent receipt PDFs")
        let plan = try await filedAsDocumentOnly([receipt])
        XCTAssertTrue(plan.items[0].notes.contains("Recorded figures unchanged: correct the receipt on its screen if needed"))
        XCTAssertTrue(plan.canConfirm, "\(plan.items[0].needsYouReasons)")
        let summary = try applier.apply(plan, entryPoint: "Import…")
        try read { db in
            let filed = try XCTUnwrap(ImportRunFile.filter(Column("runId") == summary.runId).fetchOne(db)?.documentId)
            XCTAssertTrue(try DocumentLink.filter(Column("documentId") == filed).fetchAll(db).contains { $0.entity == .rentReceipt(self.id("receipt1")) })
            XCTAssertEqual(try RentReceipt.fetchOne(db, key: self.id("receipt1"))?.amountMinorUnits, 60_000)
        }
    }

    func testApplyRefusesPlanWithNeedsYou() async throws {
        let plan = try await pipeline.plan([try receiptPDF(), try plainFile("note.txt", "Hello there. Nothing to recognise.")])
        XCTAssertFalse(plan.items(in: .needsYou).isEmpty)
        let before = try trackedCounts()
        XCTAssertThrowsError(try applier.apply(plan, entryPoint: "Import…")) { error in
            XCTAssertEqual(error as? ImportApplyError, .notConfirmable)
        }
        XCTAssertEqual(try trackedCounts(), before)
        XCTAssertEqual(try read { try ImportRun.fetchCount($0) }, 0)
        XCTAssertTrue(storedFiles().isEmpty)
    }

    /// The provider is checked before anything is written (`planOutdated`), so this stops
    /// before the first file is placed; `testEffectFailingMidApplyRemovesFilesAlreadyPlaced`
    /// covers a failure after files were placed.
    func testFailedApplyLeavesNoRowsAndNoOrphanFiles() async throws {
        var plan = try await pipeline.plan([try insurancePDF()])
        XCTAssertTrue(plan.canConfirm)
        // A utility invoice whose provider no longer exists.
        var invoice = try documentItem("invoice.txt", text: "Synthetic invoice")
        invoice.recognition = ImportRecognition(kind: .utilityInvoice, confidence: .certain, reason: "test")
        invoice.effect = .utilityInvoice(UtilityInvoice(providerId: 999, invoiceNumber: "FT 9/24", periodStart: Self.date(2024, 1, 1),
                                                        periodEnd: Self.date(2024, 1, 31), issueDate: Self.date(2024, 2, 5), amountMinorUnits: 5_000))
        plan.items.append(invoice)
        let documents = try read { try EvidenceDocument.fetchCount($0) }
        XCTAssertThrowsError(try applier.apply(plan, entryPoint: "Import…")) { error in
            guard case .planOutdated? = error as? ImportApplyError else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(try read { try EvidenceDocument.fetchCount($0) }, documents)
        XCTAssertEqual(try read { try ImportRun.fetchCount($0) }, 0)
        XCTAssertTrue(storedFiles().isEmpty, "\(storedFiles())")
    }

    func testEffectFailingMidApplyRemovesFilesAlreadyPlaced() async throws {
        let plan = try await pipeline.plan([try insurancePDF(), try receiptPDF()])
        var broken = plan
        // The receipt PDF's effect fails after the insurance receipt was filed and linked.
        let index = try XCTUnwrap(broken.items.firstIndex { $0.file.fileName == "r1.pdf" })
        guard case .rentReceiptPDF(var planned) = broken.items[index].effect else { return XCTFail("\(broken.items[index].effect)") }
        planned.receipt = nil
        broken.items[index].effect = .rentReceiptPDF(planned)
        let before = try trackedCounts()
        XCTAssertThrowsError(try applier.apply(broken, entryPoint: "Import…")) { error in
            XCTAssertEqual(error as? ImportEffectsError, .incompleteEffect("Rent receipt PDF without its receipt"))
        }
        XCTAssertEqual(try trackedCounts(), before)
        XCTAssertEqual(try read { try ImportRun.fetchCount($0) }, 0)
        XCTAssertTrue(storedFiles().isEmpty, "\(storedFiles())")
        // The capture triggers went with the rollback: a later write isn't logged.
        XCTAssertEqual(try read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM sqlite_temp_master WHERE name LIKE 'importCapture%'") }, 0)
    }

    func testOutdatedPlanIsRefusedWithoutWrites() async throws {
        let plan = try await pipeline.plan([try insurancePDF()])
        XCTAssertTrue(plan.canConfirm)
        try await db.write { db in _ = try Transaction.deleteOne(db, key: self.id("debit")) }
        let before = try trackedCounts()
        XCTAssertThrowsError(try applier.apply(plan, entryPoint: "Import…")) { error in
            guard case .planOutdated(let why)? = error as? ImportApplyError else { return XCTFail("\(error)") }
            XCTAssertTrue(why.contains("no longer exists"), why)
        }
        XCTAssertEqual(try trackedCounts(), before)
        XCTAssertTrue(storedFiles().isEmpty)
    }

    func testUnreadablePlaceholderIsNeverFiled() throws {
        var item = try documentItem("broken.pdf")
        item.file.sha256 = ImportResolutions.unreadableHashPrefix + UUID().uuidString
        XCTAssertThrowsError(try applier.apply(ImportPlan(items: [item]), entryPoint: "Import…")) { error in
            XCTAssertEqual(error as? ImportApplyError, .notConfirmable)
        }
        XCTAssertEqual(try read { try EvidenceDocument.fetchCount($0) }, 0)
    }

    /// The confirm-time backstop. Not an additive pair (two items harmless alone): the plan is
    /// built without the guard's annotations, so a P60 that moves the filed pay reaches the
    /// apply as Ready; the backstop compares the whole batch with the figures as stored.
    func testConfirmBackstopRollsBackAFiledChangeTheGuardDidNotHold() throws {
        let plan = ImportPlan(items: [try documentItem("letter.txt"), try p60Item(pay: 4_100_000)])
        XCTAssertTrue(plan.canConfirm)
        let before = try trackedCounts()
        XCTAssertThrowsError(try applier.apply(plan, entryPoint: "Import…")) { error in
            guard case .filedYearChanged(let impacts)? = error as? ImportApplyError else { return XCTFail("\(error)") }
            XCTAssertEqual(impacts.first?.headline, "Would change the filed 2024/25 return of Person A")
        }
        XCTAssertEqual(try trackedCounts(), before)
        XCTAssertEqual(try read { try Int.fetchOne($0, sql: "SELECT payMinorUnits FROM employmentIncome WHERE id = ?", arguments: [self.id("income")]) },
                       4_000_000)
        XCTAssertEqual(try read { try ImportRun.fetchCount($0) }, 0)
        XCTAssertTrue(storedFiles().isEmpty, "\(storedFiles())")
    }

    /// After the backstop refused the batch, every item is checked again: the hold lands on the
    /// item that causes it.
    func testRecheckAfterTheBackstopHoldsTheItemThatCausesIt() async throws {
        let letter = try documentItem("letter.txt"), p60 = try p60Item(pay: 4_100_000)
        let plan = ImportPlan(items: [letter, p60])
        XCTAssertThrowsError(try applier.apply(plan, entryPoint: "Import…"))
        let rechecked = try await pipeline.recheckFiledYears(plan)
        XCTAssertEqual(rechecked.items(in: .needsYou).map(\.id), [p60.id])
        XCTAssertEqual(rechecked.items.first { $0.id == p60.id }?.needsYouReasons, ["Would change the filed 2024/25 return of Person A"])
        XCTAssertFalse(rechecked.canConfirm)
    }

    func testUndoAfterApplyRestoresTheDatabase() async throws {
        var plan = try await pipeline.plan([try receiptPDF(), try insurancePDF()])
        plan.items.append(try statementItem([staged((2024, 2, 3), "TENANT B RENT FEB", 60_000, category: "rent"),
                                             staged((2024, 2, 9), "SHOP A", -1_250, category: nil)]))
        let before = try trackedDump()
        let summary = try applier.apply(plan, entryPoint: "Import…")
        XCTAssertEqual(summary.transactions, 2)
        XCTAssertNotEqual(try trackedDump(), before)
        let undone = try ImportUndo.undo(dbQueue: db, library: library, runId: summary.runId)
        XCTAssertEqual(undone.filesRemoved, 3)
        let after = try trackedDump()
        for table in before.keys.sorted() {
            XCTAssertEqual(after[table], before[table], "\(table) differs after the undo")
        }
        XCTAssertEqual(Set(after.keys), Set(before.keys))
        XCTAssertTrue(storedFiles().isEmpty, "\(storedFiles())")
    }

    func testAllDuplicateStatementAdjustmentIsUndone() throws {
        // Every row already imported: only the closing balance is checked, adjusted on request.
        let closing = StatementClosing(date: Self.date(2024, 3, 31), balanceMinorUnits: 50_000)
        let item = try statementItem([], statement: StatementFinish(closing: closing, addAdjustment: true))
        let plan = ImportPlan(items: [item])
        let batches = try read { try ImportBatch.fetchCount($0) }
        let transactions = try read { try Transaction.fetchCount($0) }
        let summary = try applier.apply(plan, entryPoint: "Import…")
        try read { db in
            XCTAssertEqual(try ImportBatch.filter(Column("importRunId") == summary.runId).fetchCount(db), 0)
            XCTAssertEqual(try Transaction.fetchCount(db), transactions + 1, "the adjustment")
            XCTAssertTrue(try ImportChange.filter(Column("runId") == summary.runId && Column("tableName") == Transaction.databaseTableName)
                .fetchCount(db) > 0)
        }
        _ = try ImportUndo.undo(dbQueue: db, library: library, runId: summary.runId)
        XCTAssertEqual(try read { try Transaction.fetchCount($0) }, transactions)
        XCTAssertEqual(try read { try ImportBatch.fetchCount($0) }, batches)
    }

    func testApplyRunsFollowOnRentMatching() throws {
        let plan = ImportPlan(items: [try statementItem([staged((2024, 1, 3), "TENANT B RENT JAN", 60_000, category: "rent")])])
        let summary = try applier.apply(plan, entryPoint: "Import…")
        XCTAssertEqual(summary.text, "1 document filed, 1 transaction")
        try read { db in
            let credit = try XCTUnwrap(Transaction.filter(Column("rawDescription") == "TENANT B RENT JAN").fetchOne(db))
            let payments = try RentReceiptPayment.filter(Column("transactionId") == credit.id!).fetchAll(db)
            XCTAssertEqual(payments.map(\.rentReceiptId), [self.id("receipt1")])
            let file = try XCTUnwrap(ImportRunFile.filter(Column("runId") == summary.runId).fetchOne(db))
            XCTAssertEqual(file.outcome, .transactions)
            XCTAssertEqual(file.detail, "1 transaction")
        }
    }

    func testFollowOnsLinkLibraryAdvicesToNewCredits() throws {
        // A received-transfer advice already in the library, for a credit not imported yet.
        let text = RentCreditEvidenceTests.adviceLines(date: "2024-01-03", amount: "600,00", reference: "0099REF0001").joined(separator: "\n")
        let advice = try library.add(try plainFile("advice.txt", text),
                                     metadata: EvidenceMetadata(kind: .bankTransferProof, textStatus: .text, extractedText: text)).document.id!
        let plan = ImportPlan(items: [try statementItem([staged((2024, 1, 3), "0099REF0001 TENANTXYZ", 60_000, category: "rent")])])
        let summary = try applier.apply(plan, entryPoint: "Import…")
        try read { db in
            let credit = try XCTUnwrap(Transaction.filter(Column("rawDescription") == "0099REF0001 TENANTXYZ").fetchOne(db))
            let links = try DocumentLink.filter(Column("documentId") == advice).fetchAll(db)
            XCTAssertEqual(links.map(\.entity), [.transaction(credit.id!)])
            XCTAssertEqual(links.first?.role, RentCreditEvidence.adviceRole)
        }
        _ = try ImportUndo.undo(dbQueue: db, library: library, runId: summary.runId)
        XCTAssertEqual(try read { try DocumentLink.filter(Column("documentId") == advice).fetchCount($0) }, 0)
    }

    func testLeftOutAndDuplicateItemsAreRecordedButNotApplied() async throws {
        var plan = try await pipeline.plan([try insurancePDF()])
        var parent = try statementItem([staged((2024, 2, 9), "SHOP A", -1_250, category: nil)])
        parent.isLeftOut = true
        let child = ImportItem(file: parent.file, recognition: parent.recognition, title: "Bank A statement: 1 row already imported",
                               effect: .none, duplicate: ImportDuplicate(level: .transactions, of: "1 row already imported"),
                               parentId: parent.id, groupKey: parent.groupKey)
        var duplicate = try documentItem("again.txt")
        duplicate.duplicate = ImportDuplicate(level: .file, of: "Same file as seguro.pdf")
        plan.items += [parent, child, duplicate]
        let transactions = try read { try Transaction.fetchCount($0) }
        let summary = try applier.apply(plan, entryPoint: "Import…")
        XCTAssertEqual(summary.filed, 1)
        XCTAssertEqual(summary.leftOut, 2)
        XCTAssertEqual(summary.duplicates, 1)
        XCTAssertEqual(summary.text, "1 document filed, 1 linked, 1 duplicate skipped, 2 left out")
        try read { db in
            XCTAssertEqual(try Transaction.fetchCount(db), transactions)
            XCTAssertEqual(try EvidenceDocument.fetchCount(db), 1)
            let files = try ImportRunFile.filter(Column("runId") == summary.runId).order(Column("id")).fetchAll(db)
            XCTAssertEqual(files.map(\.outcome), [.linked, .leftOut, .leftOut, .duplicate])
            XCTAssertEqual(files.last?.detail, "Same file as seguro.pdf")
        }
    }

    /// The user's reasons are kept by item (two items may share a title).
    func testReasonsAreKeptByItem() async throws {
        var plan = try await pipeline.plan([try insurancePDF()])
        var first = try documentItem("one.txt")
        first.title = "Same title"
        first.isLeftOut = true
        var second = try documentItem("two.txt")
        second.title = "Same title"
        second.isLeftOut = true
        plan.items += [first, second]
        let summary = try applier.apply(plan, entryPoint: "Import…", reasons: [first.id: "Not mine", second.id: "Wrong year"])
        try read { db in
            let files = try ImportRunFile.filter(Column("runId") == summary.runId).order(Column("id")).fetchAll(db)
            XCTAssertEqual(files.suffix(2).map(\.detail), ["Not mine", "Wrong year"])
            let json = try XCTUnwrap(try ImportRun.fetchOne(db, key: summary.runId)?.reasonsJSON)
            let stored = try JSONDecoder().decode([String: String].self, from: Data(json.utf8))
            XCTAssertEqual(stored, [first.id.uuidString: "Not mine", second.id.uuidString: "Wrong year"])
        }
    }

    func testReplacingIntentUnlinksTheOldDocumentAndSourceFileGetsItsDocument() async throws {
        // An older policy document on the property, and a source folder holding the new one.
        let old = try library.add(try plainFile("old policy.txt", "Old synthetic policy")).document.id!
        _ = try library.link(old, to: .property(id("property")), role: "policy")
        let url = try insurancePDF()
        let sha = try EvidenceLibrary.sha256(of: url)
        let folderId = try await db.write { db -> Int64 in
            var source = SourceFolder(path: self.folder.appendingPathComponent("Drop").path, bookmark: nil, name: "Drop")
            try source.insert(db)
            var file = SourceFile(folderId: source.id!, relativePath: "seguro.pdf", size: 1, modifiedAt: Date(), sha256: sha, lastSeenAt: Date())
            try file.insert(db)
            return source.id!
        }
        let intent = ImportIntent(target: .init(entity: .property(id("property")), role: "policy", replacing: [old]))
        let plan = try await pipeline.plan([url], intent: intent)
        XCTAssertTrue(plan.canConfirm, "\(plan.items.map(\.needsYouReasons))")
        let summary = try applier.apply(plan, entryPoint: "Import…")
        try read { db in
            let document = try XCTUnwrap(ImportRunFile.filter(Column("runId") == summary.runId).fetchOne(db)?.documentId)
            XCTAssertTrue(try EvidenceDocument.exists(db, key: old), "an import never deletes existing documents")
            XCTAssertEqual(try EvidenceLinks.documents(db: db, for: .property(self.id("property"))).map(\.id), [document])
            XCTAssertEqual(try SourceFile.filter(Column("folderId") == folderId).fetchOne(db)?.documentId, document)
            XCTAssertEqual(try EvidenceDocument.fetchOne(db, key: document)?.sourceFolderId, folderId)
        }
    }

    // MARK: Library

    func testRemoveOrphanedFilesRemovesOnlyThePlacedUnreferencedFiles() throws {
        let kept = try library.add(try plainFile("kept.txt", "Kept synthetic")).document
        let orphan = "ab" + String(repeating: "0", count: 62)
        let orphanURL = library.root.appendingPathComponent("ab/\(orphan).pdf")
        let sibling = library.root.appendingPathComponent("ab/\(orphan).txt")
        try FileManager.default.createDirectory(at: orphanURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: orphanURL)
        try Data("y".utf8).write(to: sibling)
        XCTAssertEqual(try library.removeOrphanedFiles(placedFiles: [library.fileURL(for: kept), orphanURL]), 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: library.fileURL(for: kept).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphanURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sibling.path), "only the files placed")
    }

    func testLibraryAdvicesAreParsedOncePerCache() throws {
        let text = RentCreditEvidenceTests.adviceLines(date: "2024-01-03", amount: "600,00", reference: "0099REF0001").joined(separator: "\n")
        _ = try library.add(try plainFile("advice.txt", text), metadata: EvidenceMetadata(kind: .bankTransferProof, textStatus: .text, extractedText: text))
        _ = try library.add(try plainFile("other.txt", "Other"), metadata: EvidenceMetadata(kind: .other, textStatus: .text, extractedText: "Other words"))
        let cache = RentCreditEvidence.AdviceCache()
        let first = try read { try RentCreditEvidence.libraryAdvices(db: $0, cache: cache) }
        let second = try read { try RentCreditEvidence.libraryAdvices(db: $0, cache: cache) }
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.map(\.name), ["advice.txt"])
        XCTAssertEqual(first, try read { try RentCreditEvidence.libraryAdvices(db: $0) })
        XCTAssertEqual(cache.parses, 2, "each document read once")
    }

    func testReadyChildOfAStatementIsNotFiledTwice() throws {
        let parent = try statementItem([staged((2024, 2, 9), "SHOP A", -1_250, category: nil)])
        let child = ImportItem(file: parent.file, recognition: parent.recognition, title: "Bank A statement: part", effect: .none,
                               parentId: parent.id, groupKey: parent.groupKey)
        let summary = try applier.apply(ImportPlan(items: [parent, child]), entryPoint: "Import…")
        XCTAssertEqual(summary.filed, 1)
        XCTAssertEqual(summary.text, "1 document filed, 1 transaction")
        try read { db in
            let files = try ImportRunFile.filter(Column("runId") == summary.runId).order(Column("id")).fetchAll(db)
            XCTAssertEqual(files.map(\.outcome), [.transactions, .transactions])
            XCTAssertEqual(files.last?.detail, "Part of Bank A statement")
            XCTAssertEqual(Set(files.map(\.documentId)).count, 1)
            XCTAssertEqual(try EvidenceDocument.fetchCount(db), 1)
        }
    }

    // MARK: Backups

    private func fileDatabase() throws -> (manager: DatabaseManager, path: String) {
        let path = folder.appendingPathComponent("budget.sqlite").path
        let manager = try DatabaseManager(path: path)
        try manager.migrate()
        try seed(manager.dbQueue)
        return (manager, path)
    }

    func testStatementPlanWritesBackupNextToDatabase() throws {
        let (fileManager, path) = try fileDatabase()
        let plan = ImportPlan(items: [try statementItem([staged((2024, 2, 9), "SHOP A", -1_250, category: nil)], accountId: id("bank"))])
        let applier = ImportApplier(dbQueue: fileManager.dbQueue, databasePath: path,
                                    library: EvidenceLibrary(root: folder.appendingPathComponent("Library2"), database: fileManager.dbQueue))
        let summary = try applier.apply(plan, entryPoint: "Import…", now: Self.date(2026, 10, 20))
        let backup = try XCTUnwrap(summary.backupPath)
        XCTAssertTrue(backup.hasPrefix(path + ".pre-import-backup-"), backup)
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup))
        // The backup is the database before the import.
        let copy = try DatabaseQueue(path: backup)
        XCTAssertEqual(try copy.read { try Transaction.filter(Column("rawDescription") == "SHOP A").fetchCount($0) }, 0)
        XCTAssertEqual(try fileManager.dbQueue.read { try ImportRun.fetchOne($0, key: summary.runId)?.backupPath }, backup)
    }

    func testSmallDocumentPlanNeedsNoBackup() throws {
        let (fileManager, path) = try fileDatabase()
        let plan = ImportPlan(items: [try documentItem("letter.txt")])
        XCTAssertNil(try ImportBackup.backupIfNeeded(dbQueue: fileManager.dbQueue, databasePath: path, plan: plan, now: Date()))
        let many = ImportPlan(items: try (1...25).map { try documentItem("letter \($0).txt", text: "Synthetic \($0)") })
        XCTAssertNotNil(try ImportBackup.backupIfNeeded(dbQueue: fileManager.dbQueue, databasePath: path, plan: many, now: Date()))
        let statement = ImportPlan(items: [try statementItem([])])
        XCTAssertNil(try ImportBackup.backupIfNeeded(dbQueue: db, databasePath: nil, plan: statement, now: Date()), "in memory")
        // A statement under a left-out parent isn't applied: no backup for it.
        var parent = try documentItem("cover.txt")
        parent.isLeftOut = true
        var child = try statementItem([], name: "inner.csv")
        child.parentId = parent.id
        let underLeftOut = ImportPlan(items: [parent, child, try documentItem("letter 2.txt", text: "Synthetic other")])
        XCTAssertNil(try ImportBackup.backupIfNeeded(dbQueue: fileManager.dbQueue, databasePath: path, plan: underLeftOut, now: Date()))
    }

    func testOnlyTheNewestTenBackupsAreKept() throws {
        let (fileManager, path) = try fileDatabase()
        for minute in 0..<11 {
            try Data("old".utf8).write(to: URL(fileURLWithPath: path + ".pre-import-backup-20200101-00\(String(format: "%02d", minute))00"))
        }
        let plan = ImportPlan(items: [try statementItem([])])
        let made = try XCTUnwrap(try ImportBackup.backupIfNeeded(dbQueue: fileManager.dbQueue, databasePath: path, plan: plan,
                                                                 now: Self.date(2026, 10, 20)))
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
            .filter { $0.hasPrefix("budget.sqlite.pre-import-backup-") }.sorted()
        XCTAssertEqual(names.count, ImportBackup.keep)
        XCTAssertEqual(names.last, (made as NSString).lastPathComponent)
        XCTAssertFalse(names.contains("budget.sqlite.pre-import-backup-20200101-000000"))
        XCTAssertFalse(names.contains("budget.sqlite.pre-import-backup-20200101-000100"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: path), "the database itself stays")
    }
}
