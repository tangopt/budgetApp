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


    // MARK: Reading fixes (recharges audit)

    private static func preset(_ name: String) -> UtilityInvoiceRules {
        UtilityInvoiceRules.presets.first { $0.name == name }!.rules
    }

    /// The water rules as first stored (before "VALOR DA FATURA" and the due date).
    private static let storedWaterRules = UtilityInvoiceRules(
        textMarkers: ["SIMAR"], fileNameMarkers: ["AGUA"], invoiceNumberPatterns: [UtilityInvoiceRules.atcud],
        periodLabels: ["LITROS (", "PERIODO DE CONSUMO"], amountLabels: ["VALOR TOTAL", "TOTAL"], refundLabels: ["VALOR A RECEBER"])

    /// The old layout prints the column headings ("QUANTIDADE VALOR TOTAL VALOR A PAGAR") before
    /// the line items; the new one repeats "VALOR TOTAL" over its columns and has 4-decimal items.
    private static let oldWaterLayout = """
        SIMAR services · Resumo da Fatura
        Data limite de pagamento da fatura: 2022.11.28
        Documentos Valor Data limite de pagamento
        2022.11.07 11.23+ 2022.11.28
        €
        4.44
        3.38
        IVA 0.25
        TOTAL 11.23
        QUANTIDADE VALOR TOTAL VALOR A PAGAR IVA%
        4.44
        1.00 m3 0.5111 0.51 6.00
        34 dias 0.1111 3.78 6.00
        IVA( 6% x 4.29) 0.25
        Valor da Fatura 11.23
        Total Residuos Urbanos Recolhidos: 100.000
        """
    private static let newWaterLayout = """
        SIMAR services
        2026-01-08
        ATCUD:ABCD1234-1
        Data-limite de pagamento da Fatura: 2026-01-28
        SUB TOTAL 41,2345
        IVA 0,9100
        TOTAL 44,56€
        A FATURAR A DEDUZIR A PAGAR
        QUANT. VALOR VALOR
        TOTAL
        QUANT. VALOR VALOR
        TOTAL
        VALOR A
        PAGAR
        5,2 m3 1) 0,5000 2,6000 2,6000 6,8 m3 1) 1,2000 8,1600 8,1600
        VALOR TOTAL 44,56€
        """

    func testWaterTotalsAreTheInvoiceTotalOnBothLayouts() {
        for rules in [Self.preset("Municipal water (SIMAR)"), Self.storedWaterRules] {
            let old = UtilityInvoiceReader.read(text: Self.oldWaterLayout, fileName: "x.pdf", rules: rules)
            XCTAssertEqual(old.amountMinorUnits, 1_123)
            let new = UtilityInvoiceReader.read(text: Self.newWaterLayout, fileName: "x.pdf", rules: rules)
            XCTAssertEqual(new.amountMinorUnits, 4_456)
        }
        let rules = Self.preset("Municipal water (SIMAR)")
        XCTAssertEqual(UtilityInvoiceReader.read(text: Self.oldWaterLayout, fileName: "x.pdf", rules: rules).dueDate, Self.date(2022, 11, 28))
        XCTAssertEqual(UtilityInvoiceReader.read(text: Self.newWaterLayout, fileName: "x.pdf", rules: rules).dueDate, Self.date(2026, 1, 28))
    }

    func testGasCreditNotesAreRefunds() {
        let rules = Self.preset("Natural gas (CUR)")
        let older = """
            CURGASNATURAL customer copy
            Valor a creditar: 12,34 €
            Período facturado:
            Nota de Crédito
            NC 1234/5678 de 2025-09-17 - Original
            2025-08-17 a 2025-09-16
            Outros créd./déb. € 0,00
            Total sem IVA € -9,99
            TOTAL EM CRÉDITO €
            """
        let olderReading = UtilityInvoiceReader.read(text: older, fileName: "x.pdf", rules: rules)
        XCTAssertEqual(olderReading.amountMinorUnits, -1_234)
        XCTAssertEqual(olderReading.issueDate, Self.date(2025, 9, 17))
        let newer = """
            BALCAO DIGITAL CUR
            Data: 27 AGO 2026
            Período de Faturação: 18 JUL 2026 a 17 AGO 2026
            VALOR A CREDITAR
            21,50€Total c/IVA
            11,11€
            Total 21,50€
            """
        XCTAssertEqual(UtilityInvoiceReader.read(text: newer, fileName: "x.pdf", rules: rules).amountMinorUnits, -2_150)
        // A minus sign right before a labelled total makes it a credit.
        XCTAssertEqual(UtilityInvoiceReader.read(text: "CURGASNATURAL 2025-01-02 TOTAL: -5,00 €", fileName: "x.pdf", rules: rules).amountMinorUnits,
                       -500)
        // An invoice is still a charge.
        XCTAssertEqual(UtilityInvoiceReader.read(text: "CURGASNATURAL Data: 2025-01-02 Valor a pagar 30,00 €", fileName: "x.pdf",
                                                 rules: rules).amountMinorUnits, 3_000)
    }

    func testStoredRulesTakeANewerPresetsLabelsWithoutLosingEdits() {
        let stored = UtilityInvoiceRules(textMarkers: ["MINE"], amountLabels: ["TOTAL", "MY TOTAL"], refundLabels: ["VALOR A RECEBER"])
        let merged = stored.merging(Self.preset("Natural gas (CUR)"))
        XCTAssertEqual(merged.textMarkers.first, "MINE")
        XCTAssertEqual(merged.amountLabels, ["TOTAL", "MY TOTAL", "VALOR A PAGAR"])
        XCTAssertEqual(merged.refundLabels, ["VALOR A RECEBER", "A SEU FAVOR", "VALOR A CREDITAR", "TOTAL EM CREDITO"])
        XCTAssertEqual(merged.merging(Self.preset("Natural gas (CUR)")), merged)
    }

    func testADebitOfAnotherAmountNearTheDueDateIsFlagged() throws {
        let debit = try transaction(Self.date(2026, 1, 28), -4_456, "SEPADD/EXAMPLE WTR ADC/1")
        try transaction(Self.date(2026, 3, 28), -1_000, "SEPADD/EXAMPLE WTR ADC/1")  // far from the due date
        let misread = "EXAMPLE WATER 2026-01-08 ATCUD:ABCD1234-1 VALOR TOTAL 3,03€"
        let proposal = try db.read { db in
            try UtilityInvoiceIntake.propose(db: db, propertyId: id("property"), documentId: nil, text: misread, fileName: "x.pdf", textStatus: .text)
        }
        XCTAssertNil(proposal.transactionId)
        XCTAssertEqual(proposal.warnings, ["Example Water debited €44.56 on 2026-01-28, not the €3.03 read: check the amount"])
        // Read right, it matches and nothing is flagged.
        let right = try db.read { db in
            try UtilityInvoiceIntake.propose(db: db, propertyId: id("property"), documentId: nil, text: misread.replacingOccurrences(of: "3,03", with: "44,56"),
                                             fileName: "x.pdf", textStatus: .text)
        }
        XCTAssertEqual(right.transactionId, debit)
        XCTAssertEqual(right.warnings, [])
        // With a due date, only debits within 10 days of it count.
        try db.read { db in
            let water = try XCTUnwrap(try UtilityProvider.fetchOne(db, key: id("water")))
            XCTAssertEqual(try UtilityInvoiceIntake.debitsForAnotherAmount(db: db, propertyId: id("property"), provider: water, amountMinorUnits: 303,
                                                                            issueDate: Self.date(2026, 1, 8), dueDate: Self.date(2026, 3, 25)).map(\.amountMinorUnits),
                           [-1_000])
            XCTAssertEqual(try UtilityInvoiceIntake.debitsForAnotherAmount(db: db, propertyId: id("property"), provider: water, amountMinorUnits: 303,
                                                                            issueDate: Self.date(2026, 1, 8), dueDate: Self.date(2026, 5, 1)), [])
        }
    }

    private func document(_ name: String, text: String) throws -> Int64 {
        try db.write { db in
            var document = EvidenceDocument(sha256: UUID().uuidString, storedRelativePath: "x/\(name)", originalFileName: name, byteCount: 1,
                                            kind: .other, addedAt: Date())
            document.extractedText = text
            try document.insert(db)
            return document.id!
        }
    }

    func testCopiesOfBillsWithoutANumberAreDuplicates() throws {
        let text = "EXAMPLE WATER bill of 2021-11-23\nTOTAL 8,64"
        let original = try document("20211123 - Agua.pdf", text: text)
        let copy = try document("20221123 - Agua .pdf", text: text + "\n")
        try db.write { db in
            var first = UtilityInvoice(providerId: id("water"), issueDate: Self.date(2021, 11, 23), amountMinorUnits: 864, documentId: original)
            try UtilityInvoiceIntake.record(db: db, &first)
            // The same text in another file (misread differently, even), or the same date, period and amount.
            var sameText = UtilityInvoice(providerId: id("water"), issueDate: Self.date(2022, 11, 23), amountMinorUnits: 211, documentId: copy)
            XCTAssertEqual(try Recharges.duplicate(db: db, of: sameText)?.id, first.id)
            XCTAssertThrowsError(try Recharges.saveInvoice(db: db, &sameText)) { XCTAssertEqual($0 as? RechargeError, .duplicateInvoice) }
            var sameBill = UtilityInvoice(providerId: id("water"), issueDate: Self.date(2021, 11, 23), amountMinorUnits: 864)
            XCTAssertThrowsError(try Recharges.saveInvoice(db: db, &sameBill)) { XCTAssertEqual($0 as? RechargeError, .duplicateInvoice) }
            // Another month's bill, another provider's, or another number isn't a copy.
            var next = UtilityInvoice(providerId: id("water"), issueDate: Self.date(2021, 12, 18), amountMinorUnits: 864)
            try Recharges.saveInvoice(db: db, &next)
            var power = UtilityInvoice(providerId: id("power"), issueDate: Self.date(2021, 11, 23), amountMinorUnits: 864)
            try Recharges.saveInvoice(db: db, &power)
            var numbered = UtilityInvoice(providerId: id("water"), invoiceNumber: "N-1", issueDate: Self.date(2024, 1, 1), amountMinorUnits: 100)
            try Recharges.saveInvoice(db: db, &numbered)
            var otherNumber = UtilityInvoice(providerId: id("water"), invoiceNumber: "N-2", issueDate: Self.date(2024, 1, 1), amountMinorUnits: 100)
            try Recharges.saveInvoice(db: db, &otherNumber)
            // Editing an invoice isn't refused as a copy of itself.
            first.notes = "checked"
            try Recharges.saveInvoice(db: db, &first)
            // The copy isn't offered as a pending invoice either.
            XCTAssertFalse(try UtilityInvoiceIntake.pendingDocuments(db: db, propertyId: id("property")).contains { $0.id == copy })
        }
        // The same ATCUD in another text.
        let atcudText = "EXAMPLE WATER 2024-02-01 ATCUD:ABCD1234-77 VALOR TOTAL 12,00"
        let withATCUD = try document("a.pdf", text: atcudText)
        let reprint = try document("b.pdf", text: atcudText + " 2.ª via")
        try db.write { db in
            var first = UtilityInvoice(providerId: id("water"), issueDate: Self.date(2024, 2, 1), amountMinorUnits: 1_200, documentId: withATCUD)
            try Recharges.saveInvoice(db: db, &first)
            let second = UtilityInvoice(providerId: id("water"), issueDate: Self.date(2024, 2, 2), amountMinorUnits: 1_200, documentId: reprint)
            XCTAssertEqual(try Recharges.duplicate(db: db, of: second)?.id, first.id)
        }
        let proposal = try db.read { db in
            try UtilityInvoiceIntake.propose(db: db, propertyId: id("property"), documentId: reprint, text: atcudText + " 2.ª via", fileName: "b.pdf",
                                             textStatus: .text)
        }
        XCTAssertNotNil(proposal.duplicateOf)
        XCTAssertEqual(proposal.warnings, ["A copy of the invoice of 2024-02-01 for €12.00 already recorded"])
    }

    /// Old bills recorded without an invoice number (their document deleted, or a copy saved
    /// again): the same provider and period and amount, or issue date and amount, is the same
    /// bill; the same period for another amount is never a second record (import-5 Task 1).
    func testBillsWithoutANumberAreTheSameByPeriodOrIssueDate() throws {
        try db.write { db in
            var recorded = UtilityInvoice(providerId: id("water"), periodStart: Self.date(2019, 1, 1), periodEnd: Self.date(2019, 1, 31),
                                          issueDate: Self.date(2019, 2, 5), amountMinorUnits: 2_345)
            try Recharges.saveInvoice(db: db, &recorded)
            // The same period and amount, issued (or typed) on another day: a copy.
            var resaved = UtilityInvoice(providerId: id("water"), periodStart: Self.date(2019, 1, 1), periodEnd: Self.date(2019, 1, 31),
                                         issueDate: Self.date(2019, 2, 7), amountMinorUnits: 2_345)
            XCTAssertEqual(try Recharges.duplicate(db: db, of: resaved)?.id, recorded.id)
            XCTAssertThrowsError(try Recharges.saveInvoice(db: db, &resaved)) { XCTAssertEqual($0 as? RechargeError, .duplicateInvoice) }
            // A number read now that the record never had: still the same bill.
            var numbered = resaved
            numbered.invoiceNumber = "FT 9/19"
            XCTAssertEqual(try Recharges.duplicate(db: db, of: numbered)?.id, recorded.id)
            // The same issue date and amount, no period read: a copy.
            let noPeriod = UtilityInvoice(providerId: id("water"), issueDate: Self.date(2019, 2, 5), amountMinorUnits: 2_345)
            XCTAssertEqual(try Recharges.duplicate(db: db, of: noPeriod)?.id, recorded.id)
            // The same period for another amount: not a copy, but never a second record.
            var corrected = UtilityInvoice(providerId: id("water"), periodStart: Self.date(2019, 1, 1), periodEnd: Self.date(2019, 1, 31),
                                           issueDate: Self.date(2019, 2, 20), amountMinorUnits: 2_400)
            XCTAssertNil(try Recharges.duplicate(db: db, of: corrected))
            XCTAssertEqual(try Recharges.recordedForPeriod(db: db, of: corrected)?.id, recorded.id)
            XCTAssertThrowsError(try Recharges.saveInvoice(db: db, &corrected)) {
                XCTAssertEqual($0 as? RechargeError, .invoiceForPeriodRecorded)
            }
            // Another month (the same amount), a credit note for the period, another provider: recorded.
            var february = UtilityInvoice(providerId: id("water"), periodStart: Self.date(2019, 2, 1), periodEnd: Self.date(2019, 2, 28),
                                          issueDate: Self.date(2019, 3, 5), amountMinorUnits: 2_345)
            try Recharges.saveInvoice(db: db, &february)
            var refund = UtilityInvoice(providerId: id("water"), periodStart: Self.date(2019, 1, 1), periodEnd: Self.date(2019, 1, 31),
                                        issueDate: Self.date(2019, 4, 1), amountMinorUnits: -500)
            try Recharges.saveInvoice(db: db, &refund)
            var power = UtilityInvoice(providerId: id("power"), periodStart: Self.date(2019, 1, 1), periodEnd: Self.date(2019, 1, 31),
                                       issueDate: Self.date(2019, 2, 5), amountMinorUnits: 2_400)
            try Recharges.saveInvoice(db: db, &power)
            // Two numbered invoices of one period (a re-billing) are two invoices.
            var first = UtilityInvoice(providerId: id("water"), invoiceNumber: "N-10", periodStart: Self.date(2019, 5, 1),
                                       periodEnd: Self.date(2019, 5, 31), issueDate: Self.date(2019, 6, 5), amountMinorUnits: 1_000)
            try Recharges.saveInvoice(db: db, &first)
            var second = UtilityInvoice(providerId: id("water"), invoiceNumber: "N-11", periodStart: Self.date(2019, 5, 1),
                                        periodEnd: Self.date(2019, 5, 31), issueDate: Self.date(2019, 6, 20), amountMinorUnits: 1_200)
            try Recharges.saveInvoice(db: db, &second)
            // Editing the recorded one isn't refused against itself.
            recorded.notes = "checked"
            try Recharges.saveInvoice(db: db, &recorded)
            XCTAssertEqual(try UtilityInvoice.filter(Column("providerId") == id("water")).fetchCount(db), 5)
        }
    }

    // MARK: Review fixes (recharges audit)

    func testALabelInsideAnotherWordIsNotTheTotal() {
        let rules = UtilityInvoiceRules(textMarkers: ["X"], amountLabels: ["TOTAL"])
        XCTAssertEqual(UtilityInvoiceReader.read(text: "X 2025-01-02 SUBTOTAL 40,00 € IVA 5,00 € TOTAL 45,00 €", fileName: "x.pdf", rules: rules)
                        .amountMinorUnits, 4_500)
    }

    func testElectricityInvoicesReadAsBefore() {
        let text = """
            EDP COMERCIAL customer copy
            Documento emitido a: 14 de março 2026
            Período de faturação: 12 de janeiro a 11 de março 2026
            Eletricidade Gás Natural Serviços Taxas, Impostos e
            Outros Encargos
            300,00 € Aderir Aderir 75,00 €
            Quanto tenho
            a pagar?
            375,00 €
            Débito na minha conta a partir de: 6 abr 2026
            Descrição Quantidade x Preço = Valor Desconto Total s/IVA IVA
            Total 300,00 € sem IVA
            Total 70,00 €
            """
        let reading = UtilityInvoiceReader.read(text: text, fileName: "x.pdf", rules: Self.preset("EDP"))
        XCTAssertEqual(reading.amountMinorUnits, 37_500)
        XCTAssertEqual(reading.issueDate, Self.date(2026, 3, 14))
        XCTAssertEqual(reading.periodStart, Self.date(2026, 1, 12))
        XCTAssertEqual(reading.periodEnd, Self.date(2026, 3, 11))
    }

    /// The 2017–2021 water layout: the summary's first figure and the "VALOR TOTAL" column's
    /// first one are the water charge (one line); the invoice's total is "TOTAL", here also the
    /// account balance that gets debited.
    static let accountBalanceWaterLayout = """
        SIMAR services · Fatura
        2016.03.01
        Nº Ident. Fiscal
        500000000
        €
        21.37
        40.18
        QUANTIDADE VALOR UNITÁRIO VALOR TOTAL VALOR A PAGAR IVA%
        21.37
        1.00 m3 0.4321 0.43 6.00
        TOTAL 61.55
        61.55+
        Valor da Conta Cliente em 10.03.2016 61.55
        Sr. Cliente, o valor de 61.55€ será debitado na conta bancária
        """

    /// The same layout when the account holds an earlier unpaid invoice: the balance differs
    /// from the invoice's total.
    static let earlierInvoiceWaterLayout = accountBalanceWaterLayout
        .replacingOccurrences(of: "Valor da Conta Cliente em 10.03.2016 61.55", with: "Valor da Conta Cliente em 10.03.2016 88.00")
        .replacingOccurrences(of: "o valor de 61.55€", with: "o valor de 88.00€")

    func testTheOldWaterLayoutRecordsTheInvoiceTotalNotItsWaterCharge() {
        for rules in [Self.preset("Municipal water (SIMAR)"), Self.storedWaterRules, .generic] {
            let reading = UtilityInvoiceReader.read(text: Self.accountBalanceWaterLayout, fileName: "x.pdf", rules: rules)
            XCTAssertEqual(reading.amountMinorUnits, 6_155)
            XCTAssertNil(reading.accountTotalMinorUnits)
            XCTAssertNil(reading.amountReviewNote)
        }
    }

    func testAnAccountBalanceOtherThanTheTotalIsKeptApartToBeChecked() {
        for rules in [Self.preset("Municipal water (SIMAR)"), Self.storedWaterRules, .generic] {
            let reading = UtilityInvoiceReader.read(text: Self.earlierInvoiceWaterLayout, fileName: "x.pdf", rules: rules)
            XCTAssertEqual(reading.amountMinorUnits, 6_155)
            XCTAssertEqual(reading.accountTotalMinorUnits, 8_800)
            XCTAssertEqual(reading.amountReviewNote, UtilityInvoiceReader.amountReviewNote)
        }
        // Only the debit wording is enough to know the account total.
        let debitOnly = Self.earlierInvoiceWaterLayout.replacingOccurrences(of: "Valor da Conta Cliente em 10.03.2016 88.00\n", with: "")
        XCTAssertEqual(UtilityInvoiceReader.read(text: debitOnly, fileName: "x.pdf", rules: Self.preset("Municipal water (SIMAR)")).accountTotalMinorUnits,
                       8_800)
        // A generic "saldo da conta" is no account total.
        XCTAssertNil(UtilityInvoiceReader.read(text: "SIMAR 2016.03.01 VALOR TOTAL 21.37 Saldo da conta 61.55", fileName: "x.pdf",
                                               rules: Self.preset("Municipal water (SIMAR)")).accountTotalMinorUnits)
    }

    /// A paid-up bill in the 2022 layout: its "VALOR TOTAL" column starts with a sub-line
    /// (4.44) and its total 11.23 is the account balance.
    func testAPaidUpBillWhoseColumnStartsWithASubLineKeepsItsTotal() {
        let paidUp = Self.oldWaterLayout + "\nValor da Conta Cliente em 28.11.2022 11.23"
        for rules in [Self.preset("Municipal water (SIMAR)"), Self.storedWaterRules] {
            for text in [paidUp, paidUp.replacingOccurrences(of: "Valor da Fatura 11.23\n", with: "")] {
                let reading = UtilityInvoiceReader.read(text: text, fileName: "x.pdf", rules: rules)
                XCTAssertEqual(reading.amountMinorUnits, 1_123)
                XCTAssertNil(reading.accountTotalMinorUnits)
                XCTAssertNil(reading.amountReviewNote)
            }
        }
    }

    func testCurrentLayoutsHaveNoAccountTotal() {
        for rules in [Self.preset("Municipal water (SIMAR)"), Self.storedWaterRules] {
            XCTAssertNil(UtilityInvoiceReader.read(text: Self.oldWaterLayout, fileName: "x.pdf", rules: rules).accountTotalMinorUnits)
            XCTAssertNil(UtilityInvoiceReader.read(text: Self.newWaterLayout, fileName: "x.pdf", rules: rules).accountTotalMinorUnits)
        }
    }

    func testTheAccountTotalsDebitIsNotAMisreadAmount() throws {
        try transaction(Self.date(2016, 3, 10), -8_800, "SEPADD/EXAMPLE WTR ADC/1")
        // (This provider's rules know only "VALOR TOTAL".)
        let text = Self.earlierInvoiceWaterLayout.replacingOccurrences(of: "SIMAR services", with: "EXAMPLE WATER")
            .replacingOccurrences(of: "\nTOTAL 61.55", with: "\nVALOR TOTAL 61.55")
        let proposal = try db.read { db in
            try UtilityInvoiceIntake.propose(db: db, propertyId: id("property"), documentId: nil, text: text, fileName: "x.pdf", textStatus: .text)
        }
        XCTAssertEqual(proposal.reading.amountMinorUnits, 6_155)
        XCTAssertEqual(proposal.reading.accountTotalMinorUnits, 8_800)
        XCTAssertNil(proposal.transactionId)
        XCTAssertEqual(proposal.warnings, [])
    }

    func testBillsWithDifferentATCUDsAreNotCopies() throws {
        let first = try document("a.pdf", text: "EXAMPLE WATER 2024-02-01 ATCUD:ABCD1234-1 VALOR TOTAL 12,00")
        let second = try document("b.pdf", text: "EXAMPLE WATER 2024-02-01 ATCUD:ABCD1234-2 VALOR TOTAL 12,00 (second meter)")
        try db.write { db in
            var a = UtilityInvoice(providerId: id("water"), issueDate: Self.date(2024, 2, 1), amountMinorUnits: 1_200, documentId: first)
            try Recharges.saveInvoice(db: db, &a)
            var b = UtilityInvoice(providerId: id("water"), issueDate: Self.date(2024, 2, 1), amountMinorUnits: 1_200, documentId: second)
            try Recharges.saveInvoice(db: db, &b)
            XCTAssertEqual(try UtilityInvoice.filter(Column("providerId") == id("water")).fetchCount(db), 2)
        }
    }
}
