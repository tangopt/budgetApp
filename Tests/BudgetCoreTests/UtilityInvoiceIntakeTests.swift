import XCTest
import GRDB
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers
@testable import BudgetCore

/// Utility invoice intake (plan phase 5 Task 2): reading invoices with per-provider rules
/// (stored as data), OCR for image-only files, matching the bank debit, recording the invoice
/// with its document as the debit's evidence. Synthetic providers and documents only.
final class UtilityInvoiceIntakeTests: XCTestCase {
    private var manager: DatabaseManager!
    private var db: DatabaseQueue { manager.dbQueue }
    private var ids: [String: Int64] = [:]
    private var libraryRoot: URL!

    private static func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        MonthRange.calendar.date(from: DateComponents(year: y, month: m, day: d))!
    }

    private func id(_ key: String) -> Int64 { ids[key]! }

    private static let powerRules = UtilityInvoiceRules(
        textMarkers: ["EXAMPLE POWER"], fileNameMarkers: ["LUZ"],
        invoiceNumberPatterns: [#"INVOICE NO\.?\s*([A-Z]{2}\d{4}/\d+)"#],
        issueDateLabels: ["ISSUED ON"], periodLabels: ["BILLING PERIOD:"],
        amountLabels: ["AMOUNT DUE"], refundLabels: ["AMOUNT TO REFUND"])
    private static let waterRules = UtilityInvoiceRules(
        textMarkers: ["EXAMPLE WATER"], fileNameMarkers: ["AGUA"],
        invoiceNumberPatterns: [UtilityInvoiceRules.atcud],
        periodLabels: ["LITROS ("], amountLabels: ["VALOR TOTAL"], refundLabels: ["VALOR A RECEBER"])

    override func setUpWithError() throws {
        manager = try DatabaseManager(path: nil)
        try manager.migrate()
        libraryRoot = FileManager.default.temporaryDirectory.appendingPathComponent("IntakeTests-\(UUID().uuidString)", isDirectory: true)
        try db.write { db in
            var property = Property(name: "Property A", country: "PT")
            try Properties.save(db: db, &property)
            let p = property.id!
            ids["property"] = p
            var account = Account(name: "Bank A", currency: .eur, kind: .cash, trackingMode: .imported)
            try account.insert(db)
            var batch = ImportBatch(accountId: account.id!, sourceFileName: "bank.csv", importedAt: Date())
            try batch.insert(db)
            ids["bank"] = account.id!
            ids["batch"] = batch.id!
            try Properties.setAccount(db: db, propertyId: p, accountId: account.id!, role: .current)
            var group = CategoryGroup(name: "Property A")
            try group.insert(db)
            try Properties.addCategoryGroup(db: db, propertyId: p, categoryGroupId: group.id!)
            var utilities = Category(name: "Electricity", type: .expense, groupId: group.id)
            try utilities.insert(db)
            ids["utilities"] = utilities.id!
            var power = UtilityProvider(propertyId: p, name: "Example Power", kind: .electricity, bankDescriptionPattern: "EXAMPLE PWR|EXPOWER",
                                        invoiceRules: Self.powerRules)
            try Recharges.saveProvider(db: db, &power)
            var water = UtilityProvider(propertyId: p, name: "Example Water", kind: .water, bankDescriptionPattern: "EXAMPLE WTR",
                                        invoiceRules: Self.waterRules)
            try Recharges.saveProvider(db: db, &water)
            ids["power"] = power.id!
            ids["water"] = water.id!
        }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: libraryRoot)
    }

    private var providers: [UtilityProvider] {
        get throws { try db.read { db in try Recharges.providers(db: db, propertyId: id("property")) } }
    }

    @discardableResult
    private func transaction(_ date: Date, _ amount: Int, _ text: String, category: String? = "utilities") throws -> Int64 {
        try db.write { db in
            var transaction = Transaction(importBatchId: id("batch"), accountId: id("bank"), date: date, rawDescription: text,
                                          amountMinorUnits: amount, categoryId: category.flatMap { ids[$0] }, status: .confirmed,
                                          categorizedBy: .manual, fingerprint: UUID().uuidString)
            try transaction.insert(db)
            return transaction.id!
        }
    }

    private static let powerInvoice = [
        "Example Power Ltd - customer copy",
        "Issued on: 5 de março 2021",
        "Billing period: 1 de janeiro a 28 de fevereiro 2021",
        "Amount due 100,00 EUR",
        "Invoice no. AB2021/000001 dated 05/03/2021"
    ]

    // MARK: Reading

    func testRulesReadEveryField() throws {
        let reading = UtilityInvoiceReader.read(text: Self.powerInvoice.joined(separator: "\n"), fileName: "scan.pdf", providers: try providers)
        XCTAssertEqual(reading, UtilityInvoiceReading(providerId: id("power"), invoiceNumber: "AB2021/000001", issueDate: Self.date(2021, 3, 5),
                                                      periodStart: Self.date(2021, 1, 1), periodEnd: Self.date(2021, 2, 28),
                                                      amountMinorUnits: 10_000))
    }

    func testAPeriodStartWithoutYearTakesTheEndsOrTheYearBefore() {
        let reading = UtilityInvoiceReader.read(text: "Billing period: 1 de dezembro a 31 de janeiro 2021", fileName: "x.pdf",
                                                rules: Self.powerRules)
        XCTAssertEqual(reading.periodStart, Self.date(2020, 12, 1))
        XCTAssertEqual(reading.periodEnd, Self.date(2021, 1, 31))
    }

    func testRefundsAreNegativeAndTheATCUDIsTheFallbackNumber() throws {
        let text = """
        EXAMPLE WATER services
        2021-04-05
        ATCUD:ABCD1234-00000001
        TOTAL 20,00€
        Valor a Receber a partir de 2021-04-30 20,00€
        REAL 10 000 Litros (2021-01-01 a 2021-03-31)
        """
        let reading = UtilityInvoiceReader.read(text: text, fileName: "anything.pdf", providers: try providers)
        XCTAssertEqual(reading.providerId, id("water"))
        XCTAssertEqual(reading.invoiceNumber, "ABCD1234-00000001")
        XCTAssertEqual(reading.issueDate, Self.date(2021, 4, 5))
        XCTAssertEqual(reading.periodStart, Self.date(2021, 1, 1))
        XCTAssertEqual(reading.amountMinorUnits, -2_000)
        // A refund label with nothing owed back (0,00) isn't a refund.
        let nothing = UtilityInvoiceReader.read(text: "EXAMPLE WATER 2021-04-05 Valor a Receber 0,00€ VALOR TOTAL 20,00€", fileName: "x.pdf",
                                                providers: try providers)
        XCTAssertEqual(nothing.amountMinorUnits, 2_000)
    }

    func testProviderDetection() throws {
        let all = try providers
        // A portal screenshot naming both: the file name decides.
        XCTAssertEqual(UtilityInvoiceReader.provider(text: "Example Water | Example Power portal", fileName: "20210517 - Luz.png",
                                                     providers: all)?.id, id("power"))
        // No text: the file name.
        XCTAssertEqual(UtilityInvoiceReader.provider(text: nil, fileName: "20210528 - Água.pdf", providers: all)?.id, id("water"))
        XCTAssertNil(UtilityInvoiceReader.provider(text: "Something else", fileName: "receipt.pdf", providers: all))
    }

    func testRulesAreStoredAsData() throws {
        let stored = try db.read { db in try UtilityProvider.fetchOne(db, key: id("power")) }
        XCTAssertEqual(stored?.invoiceRules, Self.powerRules)
        XCTAssertEqual(UtilityInvoiceRules.presets.map(\.kind), [.electricity, .water, .gas])
        XCTAssertTrue(stored?.matchesBankDescription("SEPADD/ExPower ADC/123") ?? false)
    }

    func testGenericRulesForProvidersWithoutTheirOwn() {
        let text = "Fatura nº XY2021 Z9/123 Data: 03/02/2021 Período de faturação: 01/01/2021 a 31/01/2021 Valor a pagar 40,00 €"
        let reading = UtilityInvoiceReader.read(text: text, fileName: "x.pdf", rules: .generic)
        XCTAssertEqual(reading.invoiceNumber, "XY2021 Z9/123")
        XCTAssertEqual(reading.issueDate, Self.date(2021, 2, 3))
        XCTAssertEqual(reading.periodEnd, Self.date(2021, 1, 31))
        XCTAssertEqual(reading.amountMinorUnits, 4_000)
    }

    // MARK: OCR

    /// A PNG with `lines` drawn as black text on white (a screenshot or photo of an invoice).
    private func textImage(_ lines: [String], name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("IntakeOCR-\(UUID().uuidString)-\(name)")
        let width = 1400, height = 120 + lines.count * 70
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let font = CTFontCreateWithName("Helvetica" as CFString, 40, nil)
        for (index, line) in lines.enumerated() {
            let attributed = NSAttributedString(string: line, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(red: 0, green: 0, blue: 0, alpha: 1)
            ])
            context.textPosition = CGPoint(x: 40, y: CGFloat(height - 80 - index * 70))
            CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
        }
        let image = try XCTUnwrap(context.makeImage())
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }

    func testImageOnlyInvoicesAreReadWithOCR() throws {
        let url = try textImage(["EXAMPLE WATER", "2021-06-01", "VALOR TOTAL 50,00 EUR"], name: "20210601 - Agua.png")
        defer { try? FileManager.default.removeItem(at: url) }
        let read = UtilityInvoiceIntake.text(of: url)
        XCTAssertTrue(read.usedOCR)
        XCTAssertEqual(read.status, .image)
        let reading = UtilityInvoiceReader.read(text: read.text, fileName: url.lastPathComponent, providers: try providers)
        XCTAssertEqual(reading.providerId, id("water"))
        XCTAssertEqual(reading.amountMinorUnits, 5_000)
        XCTAssertEqual(reading.issueDate, Self.date(2021, 6, 1))
        XCTAssertFalse(UtilityInvoiceIntake.text(of: url, ocr: false).usedOCR)
    }

    // MARK: Matching and recording

    func testThePaymentIsTheProvidersDebitOfTheAmount() throws {
        let other = try transaction(Self.date(2021, 3, 12), -10_000, "CARD SHOP", category: nil)
        let debit = try transaction(Self.date(2021, 3, 25), -10_000, "SEPADD/EXAMPLE PWR ADC/1")
        try transaction(Self.date(2021, 6, 25), -10_000, "SEPADD/EXAMPLE PWR ADC/1")  // too late
        try db.read { db in
            let power = try XCTUnwrap(try UtilityProvider.fetchOne(db, key: id("power")))
            let candidates = try UtilityInvoiceIntake.paymentCandidates(db: db, propertyId: id("property"), provider: power,
                                                                        amountMinorUnits: 10_000, issueDate: Self.date(2021, 3, 5))
            XCTAssertEqual(candidates.map(\.id), [debit, other])
            XCTAssertEqual(try UtilityInvoiceIntake.bestPayment(db: db, propertyId: id("property"), provider: power, amountMinorUnits: 10_000,
                                                                 issueDate: Self.date(2021, 3, 5))?.id, debit)
        }
        // Refunds come back as credits.
        let credit = try transaction(Self.date(2021, 4, 30), 2_000, "EXAMPLE WATER REFUND", category: nil)
        try db.read { db in
            XCTAssertEqual(try UtilityInvoiceIntake.paymentCandidates(db: db, propertyId: id("property"), provider: nil, amountMinorUnits: -2_000,
                                                                     issueDate: Self.date(2021, 4, 5)).map(\.id), [credit])
        }
    }

    func testRecordingLinksTheInvoiceDocumentToItsDebit() throws {
        let debit = try transaction(Self.date(2021, 3, 25), -10_000, "SEPADD/EXAMPLE PWR ADC/1")
        let pdf = EvidenceTestPDFs.textPDF(Self.powerInvoice, name: "20210325 - Luz.pdf")
        let library = EvidenceLibrary(root: libraryRoot, database: db)
        let added = try library.addAnalyzing(pdf)
        XCTAssertEqual(try db.read { db in try UtilityInvoiceIntake.pendingDocuments(db: db, propertyId: id("property")) }.map(\.id),
                       [added.document.id])

        let proposal = try UtilityInvoiceIntake.propose(document: added.document, library: library, propertyId: id("property"))
        XCTAssertEqual(proposal.missing, [])
        XCTAssertEqual(proposal.transactionId, debit)
        var invoice = try XCTUnwrap(proposal.invoice)
        try db.write { db in try UtilityInvoiceIntake.record(db: db, &invoice) }

        try db.read { db in
            let document = try XCTUnwrap(try EvidenceDocument.fetchOne(db, key: added.document.id!))
            XCTAssertEqual(document.kind, .utilityInvoice)
            XCTAssertEqual(document.docDate, Self.date(2021, 3, 5))
            XCTAssertEqual(document.periodEnd, Self.date(2021, 2, 28))
            XCTAssertEqual(document.amountMinorUnits, 10_000)
            XCTAssertEqual(try EvidenceLinks.links(db: db, for: document.id!).map(\.entity), [.transaction(debit)])
            XCTAssertEqual(try UtilityInvoiceIntake.pendingDocuments(db: db, propertyId: id("property")), [])
            // That debit is now taken.
            XCTAssertEqual(try UtilityInvoiceIntake.paymentCandidates(db: db, propertyId: id("property"), provider: nil, amountMinorUnits: 10_000,
                                                                     issueDate: Self.date(2021, 3, 5)), [])
        }

        // Moving the invoice to another debit moves the evidence link.
        let other = try transaction(Self.date(2021, 3, 26), -10_000, "SEPADD/EXAMPLE PWR ADC/1")
        invoice.transactionId = other
        try db.write { db in try UtilityInvoiceIntake.record(db: db, &invoice) }
        XCTAssertEqual(try db.read { db in try EvidenceLinks.links(db: db, for: added.document.id!).map(\.entity) }, [.transaction(other)])
    }

    func testAProposalNeedsProviderDateAndAmount() throws {
        let proposal = try db.read { db in
            try UtilityInvoiceIntake.propose(db: db, propertyId: id("property"), documentId: nil, text: "Nothing useful here at all, really.",
                                             fileName: "note.pdf", textStatus: .text)
        }
        XCTAssertEqual(proposal.missing, ["provider", "issue date", "amount"])
        XCTAssertNil(proposal.invoice)
    }

    func testEveryUtilityDebitNeedsAUtilityInvoice() {
        for name in ["Utilities", "Electricity", "Água", "Gas"] {
            XCTAssertEqual(EvidenceRequirementDefaults.rule(forCategoryName: name).kinds, [.utilityInvoice], name)
        }
    }

    // MARK: Review fixes

    func testOneInvoicePerDebitAndValidPatterns() throws {
        let debit = try transaction(Self.date(2021, 3, 25), -10_000, "SEPADD/EXAMPLE PWR ADC/1")
        try db.write { db in
            var first = UtilityInvoice(providerId: id("power"), invoiceNumber: "A", issueDate: Self.date(2021, 3, 5), amountMinorUnits: 10_000,
                                       transactionId: debit)
            try Recharges.saveInvoice(db: db, &first)
            var second = UtilityInvoice(providerId: id("power"), invoiceNumber: "B", issueDate: Self.date(2021, 3, 5), amountMinorUnits: 10_000,
                                        transactionId: debit)
            XCTAssertThrowsError(try Recharges.saveInvoice(db: db, &second)) {
                XCTAssertEqual($0 as? RechargeError, .transactionOnAnotherInvoice)
            }
            var broken = UtilityProvider(propertyId: id("property"), name: "Broken", kind: .gas,
                                         invoiceRules: UtilityInvoiceRules(invoiceNumberPatterns: ["(unclosed"]))
            XCTAssertThrowsError(try Recharges.saveProvider(db: db, &broken)) {
                XCTAssertEqual($0 as? RechargeError, .invalidPattern("(unclosed"))
            }
        }
    }

    func testStoredRulesMissingListsReadAsEmpty() throws {
        let rules = try JSONDecoder().decode(UtilityInvoiceRules.self, from: Data(#"{"textMarkers":["X"]}"#.utf8))
        XCTAssertEqual(rules, UtilityInvoiceRules(textMarkers: ["X"]))
    }

    func testChangingTheDocumentMovesTheEvidenceLink() throws {
        let debit = try transaction(Self.date(2021, 3, 25), -10_000, "SEPADD/EXAMPLE PWR ADC/1")
        let (first, second) = try db.write { db -> (Int64, Int64) in
            var a = EvidenceDocument(sha256: "a", storedRelativePath: "a/a.pdf", originalFileName: "A.pdf", byteCount: 1, kind: .other, addedAt: Date())
            try a.insert(db)
            var b = EvidenceDocument(sha256: "b", storedRelativePath: "b/b.pdf", originalFileName: "B.pdf", byteCount: 1, kind: .other, addedAt: Date())
            try b.insert(db)
            return (a.id!, b.id!)
        }
        try db.write { db in
            var invoice = UtilityInvoice(providerId: id("power"), issueDate: Self.date(2021, 3, 5), amountMinorUnits: 10_000,
                                         documentId: first, transactionId: debit)
            try UtilityInvoiceIntake.record(db: db, &invoice)
            invoice.documentId = second
            try UtilityInvoiceIntake.record(db: db, &invoice)
            XCTAssertEqual(try EvidenceLinks.links(db: db, for: first), [])
            XCTAssertEqual(try EvidenceLinks.links(db: db, for: second).map(\.entity), [.transaction(debit)])
        }
    }

    func testLibraryPicksAreThisPropertysOnly() throws {
        try db.write { db in
            var other = Account(name: "Personal", currency: .gbp, kind: .cash, trackingMode: .imported)
            try other.insert(db)
            var batch = ImportBatch(accountId: other.id!, sourceFileName: "p.csv", importedAt: Date())
            try batch.insert(db)
            var personal = Transaction(importBatchId: batch.id!, accountId: other.id!, date: Self.date(2021, 3, 1), rawDescription: "UK POWER",
                                       amountMinorUnits: -5_000, categoryId: nil, status: .confirmed, categorizedBy: .manual, fingerprint: "p")
            try personal.insert(db)
            var home = EvidenceDocument(sha256: "h", storedRelativePath: "h/h.pdf", originalFileName: "UK bill.pdf", byteCount: 1,
                                        kind: .utilityInvoice, addedAt: Date())
            try home.insert(db)
            try EvidenceLinks.link(db: db, documentId: home.id!, to: .transaction(personal.id!))
            var loose = EvidenceDocument(sha256: "l", storedRelativePath: "l/l.pdf", originalFileName: "Bill.pdf", byteCount: 1,
                                         kind: .utilityInvoice, addedAt: Date())
            try loose.insert(db)
            var marked = EvidenceDocument(sha256: "m", storedRelativePath: "m/m.pdf", originalFileName: "Scan.pdf", byteCount: 1,
                                          kind: .other, textStatus: .text, extractedText: "Example Water bill", addedAt: Date())
            try marked.insert(db)
            XCTAssertEqual(try UtilityInvoiceIntake.pendingDocuments(db: db, propertyId: id("property")).map(\.originalFileName),
                           ["Bill.pdf", "Scan.pdf"])
        }
    }

    func testOnlyUtilityWordsMakeAUtilityCategory() {
        XCTAssertFalse(RechargeNetting.isUtilityName("Car charging"))
        XCTAssertFalse(RechargeNetting.isUtilityName("Gasolina"))
        XCTAssertTrue(RechargeNetting.isUtilityName("Electricity"))
        XCTAssertTrue(RechargeNetting.isUtilityName("Electric"))
        XCTAssertEqual(EvidenceRequirementDefaults.rule(forCategoryName: "Car charging").kinds, [])
    }
}
