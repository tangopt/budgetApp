import XCTest
import GRDB
@testable import BudgetCore

/// Plan "Import documents 1" Task 11: the filed-year guard (an item that would change a filed or
/// paid return is held in Needs you with its impact explained) and `ImportEffects.perform`.
/// Synthetic data: Person A, a filed 2024/25 year, an employment at Acme Ltd with a stored P60
/// (pay £40,000.00), and an overseas property kept in pounds, owned by Person A, with its bank account.
final class FiledYearGuardTests: XCTestCase {
    private var manager: DatabaseManager!
    private var db: DatabaseQueue { manager.dbQueue }
    private var ids: [String: Int64] = [:]

    private func id(_ key: String) -> Int64 { ids[key]! }

    private static func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        MonthRange.calendar.date(from: DateComponents(year: y, month: m, day: d))!
    }

    override func setUpWithError() throws {
        manager = try DatabaseManager(path: nil)
        try manager.migrate()
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
            ids["income"] = income.id!
            // Person B works at Acme Ltd too; B's 2024/25 isn't filed.
            var other = Person(name: "Person B", shortName: "B")
            try People.save(db: db, &other)
            ids["B"] = other.id!
            var employmentB = Employment(startYear: 2024, personId: other.id!, employerName: "Acme Ltd")
            try Employments.save(db: db, &employmentB)
            var incomeB = EmploymentIncome(employmentId: employmentB.id!, source: .p60, payMinorUnits: 4_000_000, taxDeductedMinorUnits: 600_000)
            try Employments.save(db: db, &incomeB)

            var property = Property(name: "Property A", country: "PT", currency: .gbp)
            try Properties.save(db: db, &property)
            ids["property"] = property.id!
            _ = try Properties.setOwners(db: db, propertyId: property.id!, [
                PropertyOwner(propertyId: property.id!, personId: person.id!, shareBasisPoints: 10_000)
            ])
            var account = Account(name: "Bank A", currency: .gbp, kind: .cash, trackingMode: .imported)
            try account.insert(db)
            ids["bank"] = account.id!
            var batch = ImportBatch(accountId: account.id!, sourceFileName: "earlier.csv", importedAt: Date())
            try batch.insert(db)
            ids["batch"] = batch.id!
            try Properties.setAccount(db: db, propertyId: property.id!, accountId: account.id!, role: .current)
            var group = CategoryGroup(name: "Property A")
            try group.insert(db)
            try Properties.addCategoryGroup(db: db, propertyId: property.id!, categoryGroupId: group.id!)
            for (key, name, type) in [("rent", "Rental income", CategoryType.income), ("repairs", "Repairs", .expense),
                                      ("life", "Life insurance", .expense), ("imi", "IMI", .expense),
                                      ("utilities", "Utilities", .expense), ("accountant", "PT accountant", .expense)] {
                var category = Category(name: name, type: type, groupId: group.id)
                try category.insert(db)
                ids[key] = category.id!
            }
            try TaxExpenseTypeMap.seed(db: db, propertyId: property.id!)
            // Utilities claimed as a cost (not recharged) so an invoice's date shows on the return.
            try TaxExpenseTypeMap.set(db: db, categoryId: ids["utilities"]!, expenseType: .utilities)
            // IMI paid in a calendar year is the previous calendar year's.
            try TaxAttributionRules.set(db: db, expenseType: .councilTax, startYear: nil, rule: .previousCalendarYear)
        }
    }

    // MARK: Helpers

    private func file(_ name: String) -> ImportFile {
        ImportFile(url: URL(fileURLWithPath: "/synthetic/\(name)"), fileName: name, sha256: "sha-\(name)", byteCount: 1,
                   fileExtension: (name as NSString).pathExtension, text: nil, textStatus: .noText, usedOCR: false)
    }

    private func p60Item(startYear: Int, pay: Int, tax: Int = 600_000, person: String = "A") -> ImportItem {
        let year = UKTaxYear(startYear: startYear).label
        let confirmed = PayrollFormImport.Confirmed(kind: .p60, personId: id(person), startYear: startYear, employerName: "Acme Ltd",
                                                    payMinorUnits: pay, taxDeductedMinorUnits: tax)
        let facts = [
            ImportFact(field: .issuer, value: .text("Acme Ltd"), source: .textLayer, confidence: .certain, reason: "Employer on the P60"),
            ImportFact(field: .taxYear, value: .year(startYear), source: .textLayer, confidence: .certain, reason: "Tax year on the P60"),
            ImportFact(field: .pay, value: .money(pay, .gbp), source: .textLayer, confidence: .certain, reason: "Pay in this employment")
        ]
        return ImportItem(file: file("p60.pdf"), recognition: ImportRecognition(kind: .payrollForm(.p60), confidence: .certain, reason: "P60 layout"),
                          title: "P60 \(year) Acme Ltd", facts: facts, effect: .payrollForm(confirmed), groupKey: "Payroll forms")
    }

    private func staged(_ day: (Int, Int, Int), _ description: String, _ amount: Int, category: String?) -> StagedTransaction {
        StagedTransaction(parsed: ParsedTransaction(date: Self.date(day.0, day.1, day.2), rawDescription: description, amountMinorUnits: amount),
                          suggestedCategoryId: category.map(id), source: .rule, confidence: 1, fingerprint: "fp-\(description)-\(amount)")
    }

    private func statementItem(_ rows: [StagedTransaction], statement: StatementFinish? = nil,
                               fill: StatementAccountFill? = nil) -> ImportItem {
        let effect = UKStatementEffect(accountId: id("bank"), sourceFileName: "bank-a.csv", staged: rows, statement: statement, accountFill: fill)
        return ImportItem(file: file("bank-a.csv"), recognition: ImportRecognition(kind: .bankStatementCSV, confidence: .certain, reason: "Saved profile"),
                          title: "Bank A statement", effect: .ukStatement(effect), groupKey: "Bank statements")
    }

    /// A saved transaction on the property's bank account.
    private func bankTransaction(_ day: (Int, Int, Int), _ description: String, _ amount: Int, category: String) throws -> Int64 {
        try db.write { db in
            var transaction = Transaction(importBatchId: id("batch"), accountId: id("bank"), date: Self.date(day.0, day.1, day.2),
                                          rawDescription: description, amountMinorUnits: amount, categoryId: id(category), status: .confirmed,
                                          categorizedBy: .manual, fingerprint: UUID().uuidString)
            try transaction.insert(db)
            return transaction.id!
        }
    }

    private func placement(_ kind: DocumentKind, date: Date?, amount: Int? = nil) -> ImportPlacement {
        ImportPlacement(metadata: EvidenceMetadata(kind: kind, docDate: date, amountMinorUnits: amount, currency: amount == nil ? nil : .gbp),
                        canonicalName: "placed.pdf")
    }

    private func filedImpact(_ item: ImportItem) -> FiledYearImpact? {
        item.issues.compactMap { issue -> FiledYearImpact? in
            if case .filedYear(let impact) = issue.kind { return impact }
            return nil
        }.first
    }

    private func counts() throws -> [Int] {
        try db.read { db in
            [try Transaction.fetchCount(db), try ImportBatch.fetchCount(db), try EmploymentIncome.fetchCount(db),
             try Int.fetchOne(db, sql: "SELECT payMinorUnits FROM employmentIncome WHERE id = ?", arguments: [id("income")]) ?? -1]
        }
    }

    // MARK: Guard

    func testP60ChangingAFiledYearIsBlockedWithExplainedImpact() throws {
        let before = try counts()
        // As the pipeline calls it: inside a write transaction that is always rolled back.
        let annotated = try db.write { db -> [ImportItem] in
            var result: [ImportItem] = []
            try db.inSavepoint {
                result = try FiledYearGuard.annotate([p60Item(startYear: 2024, pay: 4_100_000)], db: db)
                return .rollback
            }
            return result
        }
        let item = try XCTUnwrap(annotated.first)
        let impact = try XCTUnwrap(filedImpact(item), "\(item.issues)")
        XCTAssertEqual(impact.headline, "Would change the filed 2024/25 return of Person A")
        XCTAssertTrue(impact.returnChanges.contains {
            $0.label == "SA102 Employment 1: Acme Ltd box 1 Pay from this employment" && $0.before == "£40,000.00" && $0.after == "£41,000.00"
        }, "\(impact.returnChanges)")
        XCTAssertEqual(impact.taxDifferenceMinorUnits, 20_000)
        XCTAssertEqual(impact.explanation.first { $0.hasPrefix("Tax:") }, "Tax: £200.00 more to pay")
        XCTAssertTrue(impact.causes.contains("P60 2024/25 Acme Ltd: pay £41,000.00"), "\(impact.causes)")
        XCTAssertTrue(impact.explanation.contains { $0.contains("£40,000.00 → £41,000.00") }, "\(impact.explanation)")
        let issue = try XCTUnwrap(item.issues.first { if case .filedYear = $0.kind { return true } else { return false } })
        XCTAssertEqual(issue.id, "filed-2024-Person A")
        XCTAssertEqual(issue.reason, impact.headline)
        XCTAssertEqual(issue.offers, [.leaveOut])
        XCTAssertEqual(item.section, .needsYou)
        XCTAssertEqual(try counts(), before)
    }

    func testPaidYearSaysPaid() throws {
        try db.write { db in
            try db.execute(sql: "UPDATE taxYear SET status = ? WHERE startYear = 2024", arguments: [TaxYearStatus.paid.rawValue])
        }
        let item = try db.write { db in try FiledYearGuard.annotate([p60Item(startYear: 2024, pay: 4_100_000)], db: db) }.first!
        XCTAssertEqual(filedImpact(item)?.headline, "Would change the paid 2024/25 return of Person A")
        XCTAssertEqual(filedImpact(item)?.isPaid, true)
    }

    func testOpenYearIsNotGuarded() throws {
        try db.write { db in
            var employment = Employment(startYear: 2025, personId: id("A"), employerName: "Acme Ltd")
            try Employments.save(db: db, &employment)
        }
        let item = p60Item(startYear: 2025, pay: 4_100_000)
        XCTAssertEqual(try db.read { try FiledYearGuard.filedYears(db: $0) }, [2024])
        let annotated = try db.write { db in try FiledYearGuard.annotate([item], db: db) }.first!
        XCTAssertTrue(annotated.issues.isEmpty, "\(annotated.issues)")
        XCTAssertEqual(annotated.section, .ready)
    }

    func testInformationOnlyChangeDoesNotBlock() throws {
        let before = try counts()
        // Life insurance on the property's account: not deductible, so only the rental
        // account's information lines move, never a return box.
        let item = statementItem([staged((2024, 7, 1), "LIFE COVER", -5_000, category: "life")])
        let annotated = try db.write { db in try FiledYearGuard.annotate([item], db: db) }.first!
        XCTAssertTrue(annotated.issues.isEmpty, "\(annotated.issues)")
        XCTAssertEqual(annotated.section, .ready)
        let information = try XCTUnwrap(annotated.informationChanges.first)
        XCTAssertEqual(information.startYear, 2024)
        XCTAssertEqual(information.person, "Person A")
        XCTAssertTrue(information.returnChanges.isEmpty)
        XCTAssertFalse(information.informationChanges.isEmpty)
        XCTAssertEqual(try counts(), before)
    }

    func testStatementInAFiledYearListsTheTransactionsThatCauseIt() throws {
        let before = try counts()
        let item = statementItem([staged((2024, 7, 1), "PLUMBER", -10_000, category: "repairs"),
                                  staged((2024, 7, 2), "COFFEE", -300, category: nil)])
        let annotated = try db.write { db in try FiledYearGuard.annotate([item], db: db) }.first!
        let impact = try XCTUnwrap(filedImpact(annotated), "\(annotated.issues) \(annotated.informationChanges)")
        XCTAssertEqual(impact.startYear, 2024)
        XCTAssertTrue(impact.returnChanges.contains { $0.label.uppercased().hasPrefix("SA106") }, "\(impact.returnChanges)")
        XCTAssertTrue(impact.causes.contains("2024-07-01 PLUMBER -£100.00"), "\(impact.causes)")
        XCTAssertFalse(impact.causes.contains { $0.contains("COFFEE") }, "\(impact.causes)")
        XCTAssertEqual(annotated.section, .needsYou)
        XCTAssertEqual(try counts(), before)
    }

    func testItemsWithoutTaxEffectAreNotEvaluated() throws {
        var snapshots = 0
        let item = ImportItem(file: file("note.pdf"), recognition: ImportRecognition(kind: .evidence(.other), confidence: .certain, reason: "x"),
                              title: "Note", effect: .file)
        try db.write { db in
            let impacts = try FiledYearGuard.impacts(db: db, item: item, filedYears: [2024]) { snapshots += 1 }
            XCTAssertEqual(impacts, [])
        }
        XCTAssertEqual(snapshots, 0)
    }

    func testNoFiledYearsNothingIsEvaluated() throws {
        try db.write { db in try db.execute(sql: "UPDATE taxYear SET status = ?", arguments: [TaxYearStatus.preparing.rawValue]) }
        let item = try db.write { db in try FiledYearGuard.annotate([p60Item(startYear: 2024, pay: 4_100_000)], db: db) }.first!
        XCTAssertTrue(item.issues.isEmpty)
    }

    func testAnnotateReplacesEarlierGuardAnnotations() throws {
        var item = p60Item(startYear: 2024, pay: 4_100_000)
        item = try db.write { db in try FiledYearGuard.annotate([item], db: db) }.first!
        item = try db.write { db in try FiledYearGuard.annotate([item], db: db) }.first!
        XCTAssertEqual(item.issues.filter { if case .filedYear = $0.kind { return true } else { return false } }.count, 1)
        // The figure now agrees with the stored one: nothing to hold.
        item.effect = p60Item(startYear: 2024, pay: 4_000_000).effect
        item = try db.write { db in try FiledYearGuard.annotate([item], db: db) }.first!
        XCTAssertTrue(item.issues.isEmpty, "\(item.issues)")
        XCTAssertEqual(item.section, .ready)
    }

    func testAnEffectThatCannotBeAppliedIsHeld() throws {
        // A P60 for a person who doesn't exist: applying it throws, so the guard can't check it.
        let confirmed = PayrollFormImport.Confirmed(kind: .p60, personId: 999, startYear: 2024, employerName: "Acme Ltd",
                                                    payMinorUnits: 4_100_000, taxDeductedMinorUnits: 600_000)
        var item = p60Item(startYear: 2024, pay: 4_100_000)
        item.effect = .payrollForm(confirmed)
        let annotated = try db.write { db in try FiledYearGuard.annotate([item], db: db) }.first!
        XCTAssertEqual(annotated.section, .needsYou)
        XCTAssertEqual(annotated.issues.first?.id, "filed-check")
        XCTAssertEqual(annotated.issues.first?.offers, [.leaveOut])
        XCTAssertEqual(annotated.issues.first?.reason, "Couldn't check this against the filed returns: leave it out and report it")
        XCTAssertEqual(annotated.issues.first?.kind, .readerProblem("Couldn't check this against the filed returns: leave it out and report it"))
        XCTAssertNotNil(annotated.issues.first?.detail)
    }

    // MARK: Review round 1

    func testBackwardAttributedPaymentInAnOpenYearIsHeld() throws {
        // IMI paid in May 2025 (tax year 2025/26) is 2024's, so it lands in the filed 2024/25.
        let item = statementItem([staged((2025, 5, 19), "PG IMI", -30_000, category: "imi")])
        let annotated = try db.write { db in try FiledYearGuard.annotate([item], db: db) }.first!
        let impact = try XCTUnwrap(filedImpact(annotated), "\(annotated.issues) \(annotated.informationChanges)")
        XCTAssertEqual(impact.startYear, 2024)
        XCTAssertTrue(impact.causes.contains("2025-05-19 PG IMI -£300.00"), "\(impact.causes)")
        XCTAssertEqual(annotated.section, .needsYou)
    }

    func testUtilityInvoiceDatedInAFiledYearPaidAfterIsHeld() throws {
        let paymentId = try bankTransaction((2025, 4, 10), "POWER CO", -4_000, category: "utilities")
        let invoice = try db.write { db -> UtilityInvoice in
            var provider = UtilityProvider(propertyId: id("property"), name: "Power Co", kind: .electricity)
            try provider.insert(db)
            return UtilityInvoice(providerId: provider.id!, invoiceNumber: "INV-1", issueDate: Self.date(2025, 3, 15), amountMinorUnits: 4_000,
                                  transactionId: paymentId)
        }
        let before = try counts()
        let item = ImportItem(file: file("invoice.pdf"), recognition: ImportRecognition(kind: .utilityInvoice, confidence: .certain, reason: "x"),
                              title: "Invoice Power Co", placement: placement(.utilityInvoice, date: Self.date(2025, 3, 15), amount: 4_000),
                              links: [ProposedLink(entity: .transaction(paymentId), label: "POWER CO", confidence: .certain, reasons: ["x"],
                                                   madeByEffect: true)],
                              effect: .utilityInvoice(invoice))
        let annotated = try db.write { db in try FiledYearGuard.annotate([item], db: db) }.first!
        XCTAssertEqual(filedImpact(annotated)?.startYear, 2024, "\(annotated.issues) \(annotated.informationChanges)")
        XCTAssertEqual(annotated.section, .needsYou)
        XCTAssertEqual(try counts(), before)
        XCTAssertEqual(try db.read { try EvidenceDocument.fetchCount($0) }, 0)
    }

    func testFiledInvoiceLinkedToAFiledYearTransactionIsHeld() throws {
        // The accountant's invoice is dated after the year: linking it moves the cost out of 2024/25.
        let paymentId = try bankTransaction((2025, 3, 30), "ACCOUNTANT", -10_000, category: "accountant")
        let item = ImportItem(file: file("accountant.pdf"), recognition: ImportRecognition(kind: .evidence(.accountantInvoice), confidence: .certain, reason: "x"),
                              title: "Accountant invoice", placement: placement(.accountantInvoice, date: Self.date(2025, 4, 20), amount: 10_000),
                              links: [ProposedLink(entity: .transaction(paymentId), label: "ACCOUNTANT", confidence: .certain, reasons: ["x"])],
                              effect: .file)
        let annotated = try db.write { db in try FiledYearGuard.annotate([item], db: db) }.first!
        XCTAssertEqual(filedImpact(annotated)?.startYear, 2024, "\(annotated.issues) \(annotated.informationChanges)")
        XCTAssertEqual(try db.read { try DocumentLink.fetchCount($0) }, 0)
    }

    func testRentReceiptsExportOverAFiledYearIsHeld() throws {
        let rows = [RentReceiptsExport.Row(rowNumber: 2, reference: "Room A", contractNumber: "7001", receiptNumber: "1", tenant: "Tenant A",
                                           periodStart: Self.date(2024, 6, 1), periodEnd: Self.date(2024, 6, 30), receiptDate: Self.date(2024, 6, 1),
                                           amountMinorUnits: 50_000)]
        let item = ImportItem(file: file("export.xlsx"), recognition: ImportRecognition(kind: .rentReceiptsExport, confidence: .certain, reason: "x"),
                              title: "Rent receipts export", effect: .rentReceiptsExport(propertyId: id("property"), rows: rows))
        let annotated = try db.write { db in try FiledYearGuard.annotate([item], db: db) }.first!
        XCTAssertEqual(filedImpact(annotated)?.startYear, 2024, "\(annotated.issues) \(annotated.informationChanges)")
        XCTAssertEqual(try db.read { try RentReceipt.fetchCount($0) }, 0)
    }

    func testFiledStatusIsPerPerson() throws {
        // Person A filed 2024/25; Person B didn't: B's P60 may change B's figures.
        let item = p60Item(startYear: 2024, pay: 4_100_000, person: "B")
        let annotated = try db.write { db in try FiledYearGuard.annotate([item], db: db) }.first!
        XCTAssertTrue(annotated.issues.isEmpty, "\(annotated.issues)")
        XCTAssertTrue(annotated.informationChanges.isEmpty, "\(annotated.informationChanges)")
        XCTAssertEqual(annotated.section, .ready)
    }

    func testLinkEffectsAreEvaluatedWithAPlaceholderDocument() throws {
        let (tenancy, receipt) = try db.write { db -> (Tenancy, RentReceipt) in
            var tenancy = Tenancy(propertyId: id("property"), referenceLabel: "Room A", contractNumber: "9001", startDate: Self.date(2024, 5, 1))
            try Tenancies.save(db: db, &tenancy)
            var receipt = RentReceipt(tenancyId: tenancy.id!, receiptNumber: "1", periodStart: Self.date(2024, 5, 1), periodEnd: Self.date(2024, 5, 31),
                                      receiptDate: Self.date(2024, 5, 1), amountMinorUnits: 50_000, status: .issued)
            try RentReceipts.save(db: db, &receipt)
            return (tenancy, receipt)
        }
        let planned = RentReceiptPDFs.Item(fileName: "receipt.pdf", sha256: "sha-receipt.pdf", textStatus: .text, usedOCR: false, parsed: nil,
                                           receipt: receipt, tenancy: tenancy, outcome: .link, mismatches: [], existingDocumentId: nil,
                                           otherLinkedDocumentIds: [])
        let item = ImportItem(file: file("receipt.pdf"), recognition: ImportRecognition(kind: .rentReceiptPDF, confidence: .certain, reason: "x"),
                              title: "Rent receipt nº 1", placement: placement(.rentReceipt, date: Self.date(2024, 5, 1), amount: 50_000),
                              links: [ProposedLink(entity: .rentReceipt(receipt.id!), role: "Receipt", label: "Receipt nº 1", confidence: .certain,
                                                   reasons: ["x"], madeByEffect: true)],
                              effect: .rentReceiptPDF(planned))
        var snapshots = 0
        let annotated = try db.write { db in try FiledYearGuard.annotate([item, item], db: db) { snapshots += 1 } }
        XCTAssertTrue(annotated[0].issues.isEmpty, "\(annotated[0].issues)")
        // The raw figures and the "before" (after the batch's matching) once, one "after" per item.
        XCTAssertEqual(snapshots, 4)
    }

    func testHeadlineAndTaxLines() {
        func impact(_ difference: Int, paid: Bool = false) -> FiledYearImpact {
            FiledYearImpact(startYear: 2023, person: "Person B", isPaid: paid,
                            returnChanges: [.init(label: "sa105 box 20 Total rents", before: "£1.00", after: "£2.00")],
                            informationChanges: [], taxDifferenceMinorUnits: difference, causes: ["Bank A statement"])
        }
        XCTAssertEqual(impact(23_000).headline, "Would change the filed 2023/24 return of Person B")
        XCTAssertEqual(impact(0, paid: true).headline, "Would change the paid 2023/24 return of Person B")
        XCTAssertEqual(impact(23_000).explanation, ["sa105 box 20 Total rents: £1.00 → £2.00", "Tax: £230.00 more to pay",
                                                    "Caused by Bank A statement"])
        XCTAssertTrue(impact(-23_000).explanation.contains("Tax: £230.00 less to pay"))
        XCTAssertTrue(impact(0).explanation.contains("Tax: no change"))
    }

    // MARK: ImportEffects.perform

    private func document(_ name: String, kind: DocumentKind = .other) throws -> Int64 {
        try db.write { db in
            var document = EvidenceDocument(sha256: "sha-\(name)", storedRelativePath: "in/\(name)", originalFileName: name, byteCount: 1,
                                            kind: kind, addedAt: Date())
            try document.insert(db)
            return document.id!
        }
    }

    private func importRun() throws -> Int64 {
        try db.write { db in
            var run = ImportRun(confirmedAt: Date(), entryPoint: "test", summary: "test")
            try run.insert(db)
            return run.id!
        }
    }

    func testStatementEffectCommitsRowsWithTheRunAndFillsTheAccount() throws {
        let runId = try importRun()
        let item = statementItem([staged((2025, 7, 1), "SHOP", -1_000, category: "repairs")],
                                 fill: StatementAccountFill(sortCode: "112233", accountNumber: "12345678"))
        try db.write { db in try ImportEffects.perform(db: db, item.effect, documentId: nil, importRunId: runId) }
        try db.read { db in
            let batch = try XCTUnwrap(ImportBatch.filter(Column("sourceFileName") == "bank-a.csv").fetchOne(db))
            XCTAssertEqual(batch.importRunId, runId)
            XCTAssertEqual(batch.sourceFileName, "bank-a.csv")
            XCTAssertEqual(try Transaction.fetchCount(db), 1)
            XCTAssertEqual(try Account.fetchOne(db, key: id("bank"))?.accountNumber, "12345678")
        }
    }

    func testStatementEffectWithEveryRowADuplicateOnlyChecksTheBalance() throws {
        let closing = StatementClosing(date: Self.date(2025, 7, 31), balanceMinorUnits: 0)
        let item = statementItem([], statement: StatementFinish(closing: closing, addAdjustment: false))
        try db.write { db in try ImportEffects.perform(db: db, item.effect, documentId: nil, importRunId: nil) }
        try db.read { db in
            XCTAssertEqual(try ImportBatch.fetchCount(db), 1)  // only the fixture's earlier batch
            XCTAssertEqual(try Account.fetchOne(db, key: id("bank"))?.statementLastCheckedDate, closing.date)
        }
    }

    func testPayrollEffectLinksTheDocument() throws {
        let documentId = try document("p60.pdf")
        let item = p60Item(startYear: 2024, pay: 4_100_000)
        try db.write { db in try ImportEffects.perform(db: db, item.effect, documentId: documentId, importRunId: nil) }
        try db.read { db in
            XCTAssertEqual(try EmploymentIncome.fetchOne(db, key: id("income"))?.payMinorUnits, 4_100_000)
            let link = try XCTUnwrap(DocumentLink.filter(Column("documentId") == documentId).fetchOne(db))
            XCTAssertEqual(link.entityId, id("income"))
            XCTAssertEqual(link.role, "P60")
        }
    }

    func testRentReceiptPDFEffectLinksTheReceipt() throws {
        let documentId = try document("receipt.pdf")
        let (tenancy, receipt) = try db.write { db -> (Tenancy, RentReceipt) in
            var tenancy = Tenancy(propertyId: id("property"), referenceLabel: "Room A", contractNumber: "9001", startDate: Self.date(2025, 1, 1))
            try Tenancies.save(db: db, &tenancy)
            var receipt = RentReceipt(tenancyId: tenancy.id!, receiptNumber: "1", periodStart: Self.date(2025, 1, 1), periodEnd: Self.date(2025, 1, 31),
                                      receiptDate: Self.date(2025, 1, 1), amountMinorUnits: 50_000, status: .issued)
            try RentReceipts.save(db: db, &receipt)
            return (tenancy, receipt)
        }
        let planned = RentReceiptPDFs.Item(fileName: "receipt.pdf", sha256: "sha-receipt.pdf", textStatus: .text, usedOCR: false, parsed: nil,
                                           receipt: receipt, tenancy: tenancy, outcome: .link, mismatches: [], existingDocumentId: nil,
                                           otherLinkedDocumentIds: [])
        try db.write { db in try ImportEffects.perform(db: db, .rentReceiptPDF(planned), documentId: documentId, importRunId: nil) }
        try db.read { db in
            let link = try XCTUnwrap(DocumentLink.filter(Column("documentId") == documentId).fetchOne(db))
            XCTAssertEqual(link.entityType, .rentReceipt)
            XCTAssertEqual(link.entityId, receipt.id)
            XCTAssertEqual(link.role, "Receipt")
        }
    }

    func testTransferAdviceEffectLinksEveryCredit() throws {
        let documentId = try document("advice.pdf", kind: .bankTransferProof)
        let credits = try db.write { db -> [Transaction] in
            var batch = ImportBatch(accountId: id("bank"), sourceFileName: "x.csv", importedAt: Date())
            try batch.insert(db)
            return try [30_000, 20_000].map { amount in
                var credit = Transaction(importBatchId: batch.id!, accountId: id("bank"), date: Self.date(2025, 2, 3), rawDescription: "TENANT",
                                         amountMinorUnits: amount, categoryId: id("rent"), status: .confirmed, categorizedBy: .manual,
                                         fingerprint: "c\(amount)")
                try credit.insert(db)
                return credit
            }
        }
        let advice = RentCreditEvidence.AdviceInput(source: .document(documentId), name: "advice.pdf", sha256: "sha-advice.pdf",
                                                    advice: .init(date: Self.date(2025, 2, 3), amounts: [50_000], compactText: "TENANT"))
        let planned = RentCreditEvidence.AdvicePlanItem(input: advice, outcome: .link, credits: credits, documentId: documentId)
        try db.write { db in try ImportEffects.perform(db: db, .transferAdvice(planned), documentId: documentId, importRunId: nil) }
        try db.read { db in
            let links = try DocumentLink.filter(Column("documentId") == documentId).order(Column("entityId")).fetchAll(db)
            XCTAssertEqual(links.map(\.entityId), credits.map(\.id!))
            XCTAssertEqual(Set(links.map(\.role)), [RentCreditEvidence.adviceRole])
        }
    }

    func testUtilityEffectRecordsTheInvoiceWithTheDocument() throws {
        let documentId = try document("invoice.pdf")
        let invoice = try db.write { db -> UtilityInvoice in
            var provider = UtilityProvider(propertyId: id("property"), name: "Power Co", kind: .electricity)
            try provider.insert(db)
            return UtilityInvoice(providerId: provider.id!, issueDate: Self.date(2025, 3, 1), amountMinorUnits: -4_000)
        }
        try db.write { db in try ImportEffects.perform(db: db, .utilityInvoice(invoice), documentId: documentId, importRunId: nil) }
        try db.read { db in
            let saved = try XCTUnwrap(UtilityInvoice.fetchOne(db))
            XCTAssertEqual(saved.documentId, documentId)
            XCTAssertEqual(try EvidenceDocument.fetchOne(db, key: documentId)?.kind, .utilityInvoice)
        }
    }

    func testLinkingEffectsNeedTheirDocument() throws {
        let advice = RentCreditEvidence.AdviceInput(source: .file(URL(fileURLWithPath: "/synthetic/a.pdf")), name: "a.pdf", sha256: "a",
                                                    advice: .init(date: Self.date(2025, 2, 3), amounts: [1], compactText: ""))
        let planned = RentCreditEvidence.AdvicePlanItem(input: advice, outcome: .link)
        XCTAssertThrowsError(try db.write { db in
            try ImportEffects.perform(db: db, .transferAdvice(planned), documentId: nil, importRunId: nil)
        }) { XCTAssertEqual($0 as? ImportEffectsError, .documentRequired) }
    }

    func testLinkEffectsOnlyPerformPlannedLinks() throws {
        let documentId = try document("advice2.pdf")
        let advice = RentCreditEvidence.AdviceInput(source: .document(documentId), name: "a.pdf", sha256: "a",
                                                    advice: .init(date: Self.date(2025, 2, 3), amounts: [1], compactText: ""))
        let planned = RentCreditEvidence.AdvicePlanItem(input: advice, outcome: .alreadyLinked)
        XCTAssertThrowsError(try db.write { db in
            try ImportEffects.perform(db: db, .transferAdvice(planned), documentId: documentId, importRunId: nil)
        }) { XCTAssertEqual($0 as? ImportEffectsError, .incompleteEffect("Transfer advice not planned to link")) }
    }

    func testApplyRecordsMakesTheCertainLinksAndTheEffect() throws {
        let documentId = try document("p60-linked.pdf")
        let sure = try bankTransaction((2025, 1, 2), "SURE", -100, category: "repairs")
        let unsure = try bankTransaction((2025, 1, 3), "UNSURE", -100, category: "repairs")
        let byEffect = try bankTransaction((2025, 1, 4), "BY EFFECT", -100, category: "repairs")
        var item = p60Item(startYear: 2024, pay: 4_100_000)
        item.links = [ProposedLink(entity: .transaction(sure), role: "Proof", label: "SURE", confidence: .certain, reasons: ["x"]),
                      ProposedLink(entity: .transaction(unsure), label: "UNSURE", confidence: .needsReview, reasons: ["x"]),
                      ProposedLink(entity: .transaction(byEffect), label: "BY EFFECT", confidence: .certain, reasons: ["x"], madeByEffect: true)]
        try db.write { db in try ImportEffects.applyRecords(db: db, item: item, documentId: documentId, importRunId: nil) }
        try db.read { db in
            let links = try DocumentLink.filter(Column("documentId") == documentId).fetchAll(db)
            XCTAssertEqual(Set(links.map(\.entity)), [.transaction(sure), .employmentIncome(id("income"))])
            XCTAssertEqual(links.first { $0.entity == .transaction(sure) }?.role, "Proof")
            XCTAssertEqual(try EmploymentIncome.fetchOne(db, key: id("income"))?.payMinorUnits, 4_100_000)
        }
    }

    // MARK: Review round 2

    /// A sent recharge statement and the tenant's credit paying it, not matched yet. Rent is
    /// counted from credits (by date) and recharges are netted in 2024/25, so matching would
    /// take the recharge part off the filed year's rents.
    private func staleRecharge() throws {
        try db.write { db in
            try TaxAttributionRules.set(db: db, expenseType: .rentalIncome, startYear: nil, rule: .byDate)
            try RechargeNetting.set(db: db, startYear: 2024, mode: .netOfRecharges)
            var tenancy = Tenancy(propertyId: id("property"), referenceLabel: "Room A", contractNumber: "8001", startDate: Self.date(2024, 4, 6))
            try Tenancies.save(db: db, &tenancy)
            var statement = RechargeStatement(tenancyId: tenancy.id!, month: Self.date(2024, 7, 1), totalMinorUnits: 5_000, status: .sent,
                                              sentAt: Self.date(2024, 7, 25))
            try statement.insert(db)
            var credit = Transaction(importBatchId: id("batch"), accountId: id("bank"), date: Self.date(2024, 7, 28), rawDescription: "TENANT A",
                                     amountMinorUnits: 5_000, categoryId: id("rent"), status: .confirmed, categorizedBy: .manual,
                                     fingerprint: "stale-credit")
            try credit.insert(db)
            var bill = Transaction(importBatchId: id("batch"), accountId: id("bank"), date: Self.date(2024, 7, 10), rawDescription: "POWER CO",
                                   amountMinorUnits: -8_000, categoryId: id("utilities"), status: .confirmed, categorizedBy: .manual,
                                   fingerprint: "stale-bill")
            try bill.insert(db)
        }
    }

    func testStaleMatchingThatWouldMoveAFiledFigureHoldsItemsThatRunIt() throws {
        try staleRecharge()
        let statement = statementItem([staged((2025, 9, 1), "COFFEE", -300, category: nil)])
        let note = ImportItem(file: file("note.pdf"), recognition: ImportRecognition(kind: .evidence(.other), confidence: .certain, reason: "x"),
                              title: "Note", effect: .file)
        let annotated = try db.write { db in try FiledYearGuard.annotate([statement, note], db: db) }
        let impact = try XCTUnwrap(filedImpact(annotated[0]), "\(annotated[0].issues)")
        XCTAssertEqual(impact.startYear, 2024)
        XCTAssertEqual(impact.causes, ["Re-running matching on Property A would change this return"])
        XCTAssertTrue(annotated[0].issues.contains { $0.id == "filed-2024-Person A-matching" && $0.offers == [.leaveOut] })
        XCTAssertEqual(annotated[0].section, .needsYou)
        XCTAssertTrue(annotated[1].issues.isEmpty, "\(annotated[1].issues)")
        XCTAssertEqual(annotated[1].section, .ready)
        // Nothing was linked for real.
        XCTAssertEqual(try db.read { try RechargePayment.fetchCount($0) }, 0)
    }

    func testFiledChangesSinceARawSnapshot() throws {
        try db.write { db in
            let raw = try TaxFigures.snapshot(db: db)
            XCTAssertEqual(try FiledYearGuard.filedChanges(db: db, from: raw), [])
            try db.execute(sql: "UPDATE employmentIncome SET payMinorUnits = 4100000 WHERE id = ?", arguments: [id("income")])
            let changes = try FiledYearGuard.filedChanges(db: db, from: raw)
            XCTAssertEqual(changes.map(\.startYear), [2024])
            XCTAssertEqual(changes.first?.person, "Person A")
            XCTAssertTrue(changes.first?.returnChanges.contains { $0.label == "SA102 Employment 1: Acme Ltd box 1 Pay from this employment" } == true)
        }
    }

    // MARK: Task 13 fix round 1

    /// The accountant's invoice dated after the year, linked to a payment made in 2024/25:
    /// the cost sits in 2025/26 while that document stays linked.
    private func linkedLateInvoice() throws -> (paymentId: Int64, documentId: Int64) {
        let paymentId = try bankTransaction((2025, 3, 30), "ACCOUNTANT", -10_000, category: "accountant")
        let documentId = try db.write { db -> Int64 in
            var document = EvidenceDocument(sha256: "sha-late-invoice", storedRelativePath: "in/late.pdf", originalFileName: "late.pdf", byteCount: 1,
                                            kind: .accountantInvoice, docDate: Self.date(2025, 4, 20), amountMinorUnits: 10_000, currency: .gbp,
                                            addedAt: Date())
            try document.insert(db)
            try EvidenceLinks.link(db: db, documentId: document.id!, to: .transaction(paymentId))
            return document.id!
        }
        return (paymentId, documentId)
    }

    /// A dateless document replacing `replaced` on the payment.
    private func replacementItem(paymentId: Int64, replaced: Int64) -> ImportItem {
        ImportItem(file: file("replacement.pdf"), recognition: ImportRecognition(kind: .evidence(.other), confidence: .certain, reason: "x"),
                   title: "Replacement", placement: placement(.other, date: nil),
                   links: [ProposedLink(entity: .transaction(paymentId), label: "ACCOUNTANT", confidence: .certain, reasons: ["x"],
                                        replacing: [replaced])],
                   effect: .file)
    }

    func testReplacingALinkedDocumentIsSimulated() throws {
        let (paymentId, old) = try linkedLateInvoice()
        let annotated = try db.write { db in try FiledYearGuard.annotate([replacementItem(paymentId: paymentId, replaced: old)], db: db) }.first!
        // Unlinking the late invoice brings the cost back into the filed 2024/25.
        XCTAssertEqual(filedImpact(annotated)?.startYear, 2024, "\(annotated.issues) \(annotated.informationChanges)")
        XCTAssertEqual(annotated.section, .needsYou)
        XCTAssertEqual(try db.read { try DocumentLink.filter(Column("documentId") == old).fetchCount($0) }, 1)
    }

    func testApplyRecordsUnlinksReplacedDocumentsAfterLinking() throws {
        let (paymentId, old) = try linkedLateInvoice()
        let documentId = try document("replacement.pdf")
        var item = replacementItem(paymentId: paymentId, replaced: old)
        // Replacing itself is never unlinked.
        item.links[0].replacing.append(documentId)
        try db.write { db in try ImportEffects.applyRecords(db: db, item: item, documentId: documentId, importRunId: nil) }
        try db.read { db in
            XCTAssertEqual(try EvidenceLinks.documents(db: db, for: .transaction(paymentId)).map(\.id), [documentId])
            XCTAssertTrue(try EvidenceDocument.exists(db, key: old))
        }
    }

    func testPlaceholderDocumentCarriesTheFileText() throws {
        var item = replacementItem(paymentId: 1, replaced: 2)
        item.file.text = "Synthetic advice text"
        item.file.textStatus = .text
        let document = try db.write { db -> EvidenceDocument? in
            var found: EvidenceDocument?
            try db.inSavepoint {
                let id = try FiledYearGuard.placeholderDocument(db: db, item: item)
                found = try EvidenceDocument.fetchOne(db, key: id)
                return .rollback
            }
            return found
        }
        XCTAssertEqual(document?.extractedText, "Synthetic advice text")
        XCTAssertEqual(document?.textStatus, .text)
    }
}
