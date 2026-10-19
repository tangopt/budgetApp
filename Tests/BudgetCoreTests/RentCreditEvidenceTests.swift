import XCTest
import GRDB
@testable import BudgetCore

/// Rent credits and their evidence (`RentCreditEvidence`): the date pass of the rent matching,
/// receipt PDFs linked to the credits that paid them, and bank advices of transfers received
/// linked to their credits. Synthetic names, references and amounts only.
final class RentCreditEvidenceTests: XCTestCase {
    private var manager: DatabaseManager!
    private var db: DatabaseQueue { manager.dbQueue }
    private var root: URL!
    private var library: EvidenceLibrary!
    private var propertyId: Int64!
    private var tenancyId: Int64!
    private var accountId: Int64!
    private var batchId: Int64!
    private var rentCategoryId: Int64!
    private var otherCategoryId: Int64!
    private var created: [URL] = []

    override func setUpWithError() throws {
        manager = try DatabaseManager(path: nil)
        try manager.migrate()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("RentCreditEvidenceTests-\(UUID().uuidString)/Evidence", isDirectory: true)
        library = EvidenceLibrary(root: root, database: manager.dbQueue)
        try db.write { db in
            var property = Property(name: "Property A", country: "PT")
            try Properties.save(db: db, &property)
            propertyId = property.id!
            var tenancy = Tenancy(propertyId: propertyId, referenceLabel: "Room Contract AB", contractNumber: "1001",
                                  tenantName: "TENANT B", startDate: Self.date(2024, 1, 1))
            try Tenancies.save(db: db, &tenancy)
            tenancyId = tenancy.id!
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
            var other = Category(name: "Other income", type: .income)
            try other.insert(db)
            otherCategoryId = other.id!
            try Properties.addCategoryGroup(db: db, propertyId: propertyId, categoryGroupId: group.id!)
            try Properties.setAccount(db: db, propertyId: propertyId, accountId: accountId, role: .current)
        }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
        for url in created { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    }

    private static func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        MonthRange.calendar.date(from: DateComponents(year: y, month: m, day: d))!
    }

    @discardableResult
    private func receipt(_ number: String, _ month: Int, amount: Int = 110_000) throws -> Int64 {
        try db.write { db in
            let (start, _) = MonthRange.of(year: 2024, month: month)
            let end = MonthRange.calendar.date(byAdding: .day, value: -1, to: MonthRange.calendar.date(byAdding: .month, value: 1, to: start)!)!
            var receipt = RentReceipt(tenancyId: tenancyId, receiptNumber: number, periodStart: start, periodEnd: end,
                                      receiptDate: Self.date(2024, month, 3), amountMinorUnits: amount)
            try RentReceipts.save(db: db, &receipt)
            return receipt.id!
        }
    }

    @discardableResult
    private func credit(_ date: Date, _ amount: Int, _ description: String, rent: Bool = true) throws -> Int64 {
        try db.write { db in
            var transaction = Transaction(importBatchId: batchId, accountId: accountId, date: date, rawDescription: description,
                                          amountMinorUnits: amount, categoryId: rent ? rentCategoryId : otherCategoryId,
                                          status: .confirmed, categorizedBy: .manual, fingerprint: UUID().uuidString)
            try transaction.insert(db)
            return transaction.id!
        }
    }

    private func match(_ options: RentReceiptMatching.Options = .init()) throws -> RentReceiptMatching.Result {
        try db.write { db in try RentReceiptMatching.match(db: db, propertyId: propertyId, options: options) }
    }

    private func links(_ receiptId: Int64) throws -> [[Int]] {
        try db.read { db in
            try RentReceiptMatching.payments(db: db, receiptId: receiptId).map { [Int($0.transactionId), $0.rentMinorUnits, $0.otherMinorUnits] }
        }
    }

    // MARK: Matching by date

    func testUnpaidReceiptsTakeTheKnownPayersClosestCreditByDate() throws {
        let january = try receipt("1", 1)
        let february = try receipt("2", 2)
        let march = try receipt("3", 3)
        let april = try receipt("4", 4)
        let paidJanuary = try credit(Self.date(2024, 1, 2), 110_000, "0099REF0001 TENANTXYZ")
        // February: rent plus a large recharge (over the amount pass's half), from the same payer.
        let recharged = try credit(Self.date(2024, 2, 5), 180_000, "0099REF0002 TENANTXYZ")
        // Nearer March's start than February's receipt: never February's, March's by date.
        let farther = try credit(Self.date(2024, 2, 25), 180_000, "0099REF0003 TENANTXYZ")
        // March: the same kind of credit from someone else isn't taken by date.
        let stranger = try credit(Self.date(2024, 3, 4), 180_000, "0099REF0004 SOMEONEELSE")
        // April: rent plus more than three quarters of it is past the date pass's cap.
        let huge = try credit(Self.date(2024, 4, 3), 230_000, "0099REF0005 TENANTXYZ")

        // The pass off: only the exact amount.
        let off = try match(.init(dateFallbackMaxOtherFraction: nil))
        XCTAssertEqual(off.created.map(\.rentReceiptId), [january])
        XCTAssertEqual(off.byDate, [])

        let result = try match()
        XCTAssertEqual(try links(january), [[Int(paidJanuary), 110_000, 0]])
        XCTAssertEqual(try links(february), [[Int(recharged), 110_000, 70_000]])
        // 25 Feb is in both windows but closer to March's receipt; the stranger isn't the payer.
        XCTAssertEqual(try links(march), [[Int(farther), 110_000, 70_000]])
        XCTAssertEqual(try links(april), [])
        XCTAssertEqual(result.byDate.map(\.rentReceiptId), [february, march])
        XCTAssertEqual(Set(result.unmatchedCredits.map(\.id)), [stranger, huge])

        XCTAssertEqual(try match().created, []) // idempotent
    }

    func testWithoutAKnownPayerTheDatePassLeavesLargeCreditsForReview() throws {
        let january = try receipt("1", 1)
        let big = try credit(Self.date(2024, 1, 2), 170_000, "0099REF0001 TENANTXYZ")
        let result = try match()
        XCTAssertEqual(try links(january), [])
        XCTAssertEqual(result.unmatchedCredits.map(\.id), [big])
    }

    func testPayerWordsIgnoreReferencesAndMatchCutNames() {
        XCTAssertEqual(RentCreditEvidence.payerWords("0099REF0001 TENANTXYZ"), ["TENANTXYZ"])
        XCTAssertEqual(RentCreditEvidence.payerWords("TENANTXYZ ABCDEF ABCDE 240108SCRQ560"), ["TENANTXYZ", "ABCDEF"])
        // Banking words, bank names and months never name a payer.
        XCTAssertEqual(RentCreditEvidence.payerWords("TRANSFERENCIA RECEBIDA RENDA BANKINTER SETEMBRO"), [])
        XCTAssertEqual(RentCreditEvidence.payerWords("Transfer from tenant"), [])
        // Exact words, or a name the bank cut at eight letters.
        XCTAssertTrue(RentCreditEvidence.samePayer(["TENANTXY"], ["TENANTXYZ"]))
        XCTAssertFalse(RentCreditEvidence.samePayer(["TENANT"], ["TENANTXYZ"]))
        XCTAssertFalse(RentCreditEvidence.samePayer(["TENANTX"], ["TENANTXYZ"]))
        XCTAssertFalse(RentCreditEvidence.samePayer(["OTHERS"], ["TENANTXYZ"]))
    }

    // MARK: Receipt PDFs on credits

    private func receiptDocument(_ receiptId: Int64, name: String) throws -> Int64 {
        let url = EvidenceTestPDFs.textPDF(["RECIBO DE RENDA", name], name: "\(name).pdf")
        created.append(url)
        let added = try library.add(url, metadata: EvidenceMetadata(kind: .rentReceipt))
        _ = try library.link(added.document.id!, to: .rentReceipt(receiptId), role: "Receipt")
        return added.document.id!
    }

    private func documents(_ transactionId: Int64) throws -> [Int64] {
        try db.read { db in try EvidenceLinks.documents(db: db, for: .transaction(transactionId)).map { $0.id! } }
    }

    func testReceiptPDFsFollowThePaymentLinks() throws {
        let january = try receipt("1", 1)
        let february = try receipt("2", 2)
        let januaryPDF = try receiptDocument(january, name: "receipt-1")
        let paid = try credit(Self.date(2024, 1, 2), 110_000, "0099REF0001 TENANTXYZ")
        let late = try credit(Self.date(2024, 2, 4), 110_000, "0099REF0002 TENANTXYZ")

        // Matching links the receipt's PDF to its credit.
        let result = try match()
        XCTAssertEqual(result.receiptDocumentLinks.map(\.documentId), [januaryPDF])
        XCTAssertEqual(try documents(paid), [januaryPDF])
        try db.read { db in
            XCTAssertEqual(try DocumentLink.filter(Column("entityType") == "transaction").fetchOne(db)?.role, RentCreditEvidence.receiptRole)
        }

        // A PDF added to a receipt that's already paid: the one-off pass (and the app) link it.
        let februaryPDF = try receiptDocument(february, name: "receipt-2")
        let made = try db.write { db in try RentCreditEvidence.linkReceiptDocuments(db: db) }
        XCTAssertEqual(made.map(\.transactionId), [late])
        XCTAssertEqual(try documents(late), [februaryPDF])
        XCTAssertEqual(try db.write { db in try RentCreditEvidence.linkReceiptDocuments(db: db) }, []) // idempotent

        // The payment link goes: so does the PDF from the credit. A hand-made link stays.
        try db.write { db in
            try EvidenceLinks.link(db: db, documentId: februaryPDF, to: .transaction(paid), role: "Mine")
            XCTAssertTrue(try RentReceiptMatching.unlink(db: db, receiptId: january, transactionId: paid))
            XCTAssertTrue(try RentReceiptMatching.unlink(db: db, receiptId: february, transactionId: late))
        }
        XCTAssertEqual(try documents(paid), [februaryPDF])
        XCTAssertEqual(try documents(late), [])

        // Linked by hand: the PDF comes back.
        try db.write { db in _ = try RentReceiptMatching.link(db: db, receiptId: january, transactionId: paid) }
        XCTAssertEqual(Set(try documents(paid)), [januaryPDF, februaryPDF])
    }

    // MARK: Bank advices

    /// A received-transfer advice, its labels and values scattered as BBVA's text layer has them.
    static func adviceLines(date: String, amount: String, reference: String, payer: String = "TENANTXYZ") -> [String] {
        ["Exmo(a). Senhor(a)", "DATA: \(date)", "TRANSFERÊNCIA RECEBIDA", "LANDLORD A", "CONTA N : 076",
         "QUEIRA(M) NOTAR QUE, NESTA DATA, EFETUÁMOS NA CONTA DE V.EXA(S) O(S) SEGUINTE(S) MOVIMENTO(S):",
         "REFERÊNCIA EM EXTRACTO :", "DESPESAS DE EXPEDIENTE :", "IMPORTÂNCIA DA TRANSFERÊNCIA:", payer,
         "NOSSA REFERÊNCIA :", amount, "\(reference) \(payer.prefix(8))", date, "EUR 0,00", "0,00 DESPESAS DE TRANSFERÊNCIA:"]
    }

    func testParsesAReceivedTransferAdviceOnly() throws {
        let text = Self.adviceLines(date: "2024-01-02", amount: "1.234,56", reference: "0099REF0001").joined(separator: "\n")
        let advice = try XCTUnwrap(RentCreditEvidence.parseAdvice(text))
        XCTAssertEqual(advice.date, Self.date(2024, 1, 2))
        XCTAssertEqual(advice.amounts, [123_456])
        XCTAssertTrue(advice.compactText.contains("0099REF0001"))
        let sent = text.replacingOccurrences(of: "TRANSFERÊNCIA RECEBIDA", with: "TRANSFERÊNCIA EMITIDA")
        XCTAssertNil(RentCreditEvidence.parseAdvice(sent))
        XCTAssertNil(RentCreditEvidence.parseAdvice("TRANSFERÊNCIA RECEBIDA without a date 1,00"))
    }

    private func advicePDF(_ name: String, date: String, amount: String, reference: String, payer: String = "TENANTXYZ") throws
        -> RentCreditEvidence.AdviceInput {
        let url = EvidenceTestPDFs.textPDF(Self.adviceLines(date: date, amount: amount, reference: reference, payer: payer), name: name)
        created.append(url)
        let input = try RentReceiptPDFs.read(url, ocr: false)
        let advice = try XCTUnwrap(input.text.flatMap(RentCreditEvidence.parseAdvice))
        return .init(source: .file(url), name: name, sha256: input.sha256, advice: advice, text: input.text, textStatus: input.textStatus)
    }

    func testAdvicesLinkToTheirTenantCreditsOnly() throws {
        let january = try receipt("1", 1)
        _ = try receiptDocument(january, name: "receipt-1")
        let rent = try credit(Self.date(2024, 1, 2), 110_000, "0099REF0001 TENANTXYZ")
        // The same day and amount, another reference: the referenced one wins.
        _ = try credit(Self.date(2024, 1, 2), 110_000, "0099REF0009 SOMEONEELSE", rent: false)
        // One transfer the import split in two (rent and something else), booked a day later.
        let partA = try credit(Self.date(2024, 2, 3), 110_000, "0099REF0002 TENANTXYZ")
        let partB = try credit(Self.date(2024, 2, 3), 50_000, "0099REF0002 TENANTXYZ", rent: false)
        _ = try receipt("2", 2)
        // A credit from someone who isn't a tenant.
        let stranger = try credit(Self.date(2024, 3, 10), 5_000, "0099REF0003 SOMEONEELSE", rent: false)

        // One advice already in the library (its text kept), the rest as files.
        let inLibrary = try advicePDF("lib.pdf", date: "2024-01-02", amount: "1.100,00", reference: "0099REF0001")
        guard case .file(let libraryURL) = inLibrary.source else { return XCTFail() }
        let libraryDocument = try library.add(libraryURL, metadata: EvidenceMetadata(kind: .bankTransferProof, amountMinorUnits: 0,
                                                                                     extractedText: inLibrary.text)).document.id!
        let files = [
            try advicePDF("split.pdf", date: "2024-02-02", amount: "1.600,00", reference: "0099REF0002"),
            try advicePDF("stranger.pdf", date: "2024-03-10", amount: "50,00", reference: "0099REF0003", payer: "SOMEONEELSE"),
            try advicePDF("missing.pdf", date: "2023-06-01", amount: "1.100,00", reference: "0099REF0000"),
            inLibrary
        ]

        let run = try db.write { db in try RentCreditEvidence.run(db: db, library: library, files: files) }
        let advices = try XCTUnwrap(run.properties.first?.advices)
        func outcome(_ name: String) -> RentCreditEvidence.AdviceOutcome? { advices.first { $0.input.name.hasSuffix(name) }?.outcome }
        XCTAssertEqual(advices.first { $0.input.source == .document(libraryDocument) }?.outcome, .link)
        XCTAssertEqual(outcome("split.pdf"), .link)
        XCTAssertEqual(outcome("stranger.pdf"), .notRent)
        XCTAssertEqual(outcome("missing.pdf"), .noCredit)
        XCTAssertEqual(advices.filter { $0.outcome == .duplicate }.count, 1)
        XCTAssertEqual(run.properties.first?.applied.added, 1) // split.pdf; the library's is reused
        XCTAssertEqual(run.properties.first?.applied.amountsSet, 1) // the library document's zero amount

        XCTAssertTrue(try documents(rent).contains(libraryDocument))
        XCTAssertEqual(try documents(rent).count, 2) // the advice and the receipt PDF
        let splitDocument = try XCTUnwrap(try documents(partA).first)
        XCTAssertEqual(try documents(partB), [splitDocument])
        XCTAssertEqual(try documents(stranger), [])
        try db.read { db in
            let added = try XCTUnwrap(try EvidenceDocument.fetchOne(db, key: splitDocument))
            XCTAssertEqual(added.kind, .bankTransferProof)
            XCTAssertEqual(added.amountMinorUnits, 160_000)
            XCTAssertEqual(try EvidenceDocument.fetchOne(db, key: libraryDocument)?.amountMinorUnits, 110_000)
            let report = try RentCreditEvidence.report(db: db, run)
            XCTAssertTrue(report.contains("linked now: 2"), report)
        }

        // Idempotent: nothing new on a second run.
        let again = try db.write { db in try RentCreditEvidence.run(db: db, library: library, files: files) }
        XCTAssertEqual(again.properties.first?.applied.linked, 0)
        XCTAssertEqual(again.properties.first?.applied.added, 0)
        XCTAssertEqual(again.properties.first?.receiptDocuments, [])
        XCTAssertEqual(again.properties.first?.advices.filter { $0.outcome == .alreadyLinked }.count, 2)
    }

    // MARK: Review fixes

    func testTheDatePassLeavesTheNextMonthsCreditAlone() throws {
        _ = try receipt("1", 1)
        let february = try receipt("2", 2)
        _ = try credit(Self.date(2024, 1, 2), 110_000, "0099REF0001 TENANTXYZ")
        // 26 Feb: 23 days after February's receipt date, 4 before March starts.
        let early = try credit(Self.date(2024, 2, 26), 180_000, "0099REF0002 TENANTXYZ")
        let result = try match()
        XCTAssertEqual(try links(february), [])
        XCTAssertEqual(result.unmatchedCredits.map(\.id), [early])
    }

    /// Paid January with a receipt PDF on its credit (via matching); returns (receipt, PDF, credit).
    private func paidJanuaryWithPDF() throws -> (Int64, Int64, Int64) {
        let january = try receipt("1", 1)
        let pdf = try receiptDocument(january, name: "receipt-1")
        let paid = try credit(Self.date(2024, 1, 2), 110_000, "0099REF0001 TENANTXYZ")
        _ = try match()
        XCTAssertEqual(try documents(paid), [pdf])
        return (january, pdf, paid)
    }

    func testTriggersDropTheReceiptPDFWhenItsSupportGoes() throws {
        // Replace PDF / unlinking it from the receipt (Documents, Missing evidence).
        let (january, pdf, paid) = try paidJanuaryWithPDF()
        _ = try library.unlink(pdf, from: .rentReceipt(january))
        XCTAssertEqual(try documents(paid), [])

        // The payment's rent cut to nothing (a clamp), then the payment deleted.
        try db.write { db in try EvidenceLinks.link(db: db, documentId: pdf, to: .rentReceipt(january), role: "Receipt") }
        try db.write { db in _ = try RentCreditEvidence.linkReceiptDocuments(db: db) }
        XCTAssertEqual(try documents(paid), [pdf])
        try db.write { db in try db.execute(sql: "UPDATE rentReceiptPayment SET rentMinorUnits = 0, otherMinorUnits = 110000") }
        XCTAssertEqual(try documents(paid), [])
        try db.write { db in try db.execute(sql: "UPDATE rentReceiptPayment SET rentMinorUnits = 110000, otherMinorUnits = 0") }
        try db.write { db in _ = try RentCreditEvidence.linkReceiptDocuments(db: db) }
        XCTAssertEqual(try documents(paid), [pdf])
        try db.write { db in _ = try RentReceiptPayment.deleteAll(db) }
        XCTAssertEqual(try documents(paid), [])
    }

    func testDeletingTheReceiptOrTenancyDropsItsPDFFromTheCredit() throws {
        let (january, pdf, paid) = try paidJanuaryWithPDF()
        try db.write { db in _ = try RentReceipts.delete(db: db, id: january) }
        XCTAssertEqual(try documents(paid), [])

        let february = try receipt("2", 2)
        let februaryPDF = try receiptDocument(february, name: "receipt-2")
        let late = try credit(Self.date(2024, 2, 2), 110_000, "0099REF0002 TENANTXYZ")
        _ = try match()
        XCTAssertEqual(try documents(late), [februaryPDF])
        try db.write { db in _ = try Tenancies.delete(db: db, id: tenancyId) }
        XCTAssertEqual(try documents(late), [])
        XCTAssertNotEqual(pdf, februaryPDF)
    }

    func testAdviceWindowEdges() throws {
        _ = try paidJanuaryWithPDF()
        func outcome(on day: Int) throws -> RentCreditEvidence.AdviceOutcome? {
            let input = try advicePDF("edge-\(day).pdf", date: String(format: "2024-01-%02d", day), amount: "1.100,00", reference: "0099REF0001")
            return try db.read { db in try RentCreditEvidence.planAdvices(db: db, propertyId: propertyId, inputs: [input]).first?.outcome }
        }
        // The credit is booked on 2 January: it may be booked a day before the advice's date
        // or up to three after it, so advices of 30 December to 3 January fit.
        XCTAssertEqual(try outcome(on: 3), .link)
        XCTAssertEqual(try outcome(on: 4), .noCredit)
        func december(_ day: Int) throws -> RentCreditEvidence.AdviceOutcome? {
            let input = try advicePDF("edge-dec\(day).pdf", date: "2023-12-\(day)", amount: "1.100,00", reference: "0099REF0001")
            return try db.read { db in try RentCreditEvidence.planAdvices(db: db, propertyId: propertyId, inputs: [input]).first?.outcome }
        }
        XCTAssertEqual(try december(30), .link)
        XCTAssertEqual(try december(29), .noCredit)
    }

    func testAdvicesMustNameTheCreditAndOneCreditPerAdvice() throws {
        _ = try paidJanuaryWithPDF()
        // Two credits of the payer on one day for the same amount, neither referenced: ambiguous.
        _ = try credit(Self.date(2024, 2, 2), 120_000, "0099REFAAAA TENANTXYZ")
        _ = try credit(Self.date(2024, 2, 2), 120_000, "0099REFBBBB TENANTXYZ")
        // The same amount on the day, but the advice names neither its reference nor its payer.
        let quiet = try credit(Self.date(2024, 3, 4), 130_000, "0099REFCCCC TENANTXYZ")
        let ambiguous = try advicePDF("two.pdf", date: "2024-02-02", amount: "1.200,00", reference: "0099REFZZZZ")
        let unnamed = try advicePDF("unnamed.pdf", date: "2024-03-04", amount: "1.300,00", reference: "0099REFYYYY", payer: "SOMEONEELSE")
        try db.read { db in
            let plan = try RentCreditEvidence.planAdvices(db: db, propertyId: propertyId, inputs: [ambiguous, unnamed])
            XCTAssertEqual(plan.map(\.outcome), [.ambiguous, .unconfirmed])
            XCTAssertEqual(plan[1].credit?.id, quiet)
        }
    }

    func testAnAdviceLinkedElsewhereOrACopyIsntLinkedAgain() throws {
        let (_, _, paid) = try paidJanuaryWithPDF()
        let other = try credit(Self.date(2024, 1, 2), 5_000, "0099REF0007 SOMEONEELSE", rent: false)
        // The library's advice was linked by hand to another transaction.
        let advice = try advicePDF("lib.pdf", date: "2024-01-02", amount: "1.100,00", reference: "0099REF0001")
        guard case .file(let url) = advice.source else { return XCTFail() }
        let document = try library.add(url, metadata: EvidenceMetadata(kind: .bankTransferProof, extractedText: advice.text)).document.id!
        _ = try library.link(document, to: .transaction(other), role: "Mine")
        var run = try db.write { db in try RentCreditEvidence.run(db: db, library: library, files: []) }
        XCTAssertEqual(run.properties.first?.advices.map(\.outcome), [.conflict])
        XCTAssertEqual(try documents(paid).contains(document), false)

        // Unlinked from the other one, it links; a re-scanned copy (other bytes) is then a copy, not ambiguous.
        _ = try library.unlink(document, from: .transaction(other))
        run = try db.write { db in try RentCreditEvidence.run(db: db, library: library, files: []) }
        XCTAssertEqual(run.properties.first?.advices.map(\.outcome), [.link])
        let rescan = try advicePDF("rescan.pdf", date: "2024-01-02", amount: "1.100,00", reference: "0099REF0001", payer: "TENANTXYZW")
        run = try db.write { db in try RentCreditEvidence.run(db: db, library: library, files: [rescan]) }
        XCTAssertEqual(run.properties.first?.advices.map(\.outcome), [.alreadyLinked, .copyOfLinked])
        XCTAssertEqual(run.properties.first?.applied.added, 0)
    }
}
