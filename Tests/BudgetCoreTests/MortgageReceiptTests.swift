import XCTest
import GRDB
@testable import BudgetCore

/// A bank's two documents per mortgage instalment: the notice before the debit (issued
/// mid-month, the instalment's breakdown) and the receipt after it (the payment receipt for the
/// debit on its date). Both are evidence of the same debit. Synthetic layouts only: they mimic
/// the order a glyph-font PDF's text comes out in (labels and values apart), with invented
/// numbers and no real names.
final class MortgageReceiptTests: XCTestCase {
    static func day(_ string: String) -> Date {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.date(from: string)!
    }

    /// The receipt of instalment 25 of 480, debited 2025-03-31.
    static let receiptLines = [
        "Exmo(a). Senhor(a)",
        "Com os nossos melhores cumprimentos Produzido por computador",
        "EXMO(S) SENHOR(ES):",
        "0000001PERSON A",
        "AVISO DE DÉBITO",
        "RECIBO DE EMPRÉSTIMO",
        "DATA: 2025-03-31",
        "CONTA N.º: 900000001",
        "N.º RECIBO :",
        "IMPOSTOS : 0,00",
        "0,00",
        "1.000,00",
        "234,56",
        "JUROS :",
        "CAPITAL :",
        "DADOS DA COBRANÇA",
        "TOTAL DO RECIBO : 1.234,56",
        "DATA FIM LIQUIDAÇÃO :",
        "DATA INÍCIO LIQUIDAÇÃO :",
        "CAPITAL VINCENDO :",
        "CAPITAL CONCEDIDO :",
        "480/",
        "25",
        "2025-03-31",
        "2025-02-28",
        "190.000,00",
        "200.000,00",
        "900000002",
        "CONTA EMPRÉSTIMO :",
        "QUEIRA(M) NOTAR QUE, NESTA DATA, EFETUÁMOS NA CONTA DE V.EXA(S), O SEGUINTE MOVIMENTO:",
        "TOTAL :",
        "DATA VALOR: 2025-03-31 1.234,56",
        "EUR"
    ]

    /// The notice of the same instalment, issued 2025-03-14.
    static let noticeLines = [
        "Exmo(a). Senhor(a)",
        "Empréstimos AVISO DÉBITO PRESTAÇÃO",
        "PERSON A",
        "CONTA N : 076 900000001",
        "QUEIRA(M) NOTAR QUE, NA DATA MENCIONADA, EFETUAREMOS NA CONTA DE V.EXA(S) O(S) SEGUINTE(S) MOVIMENTO(S):",
        "CONTA EMPRÉSTIMO : CREDITO HABITAÇAO C/ GARANTIA HIPOTECARIA",
        "076 900000002",
        "2025-03-31",
        "TOTAL EUR:",
        "2025-03-31DATA FIM LIQUIDAÇÃO :",
        "1.234,56",
        "DATA:",
        "2025-03-14",
        "DATA VENC.:",
        "2025-02-28",
        "190.234,56",
        "200.000,00",
        "PRESTAÇÃO Nº",
        "25",
        "1.000,00 EUR",
        "234,56 EUR"
    ]

    static var receiptText: String { receiptLines.joined(separator: "\n") }
    static var noticeText: String { noticeLines.joined(separator: "\n") }

    // MARK: Kind

    func testKindIsSupported() {
        XCTAssertEqual(DocumentKind.mortgageReceipt.displayName, "Mortgage receipt")
        XCTAssertEqual(DocumentKind(rawValue: "mortgageReceipt"), .mortgageReceipt)
        XCTAssertEqual(ImportNaming.area(of: .mortgageReceipt), "Property")
        XCTAssertTrue(EvidenceInitialImport.relevantKinds.contains(.mortgageReceipt))
    }

    // MARK: Detection

    func testReceiptAndNoticeAreToldApartByTheirText() {
        XCTAssertEqual(DocumentClassifier.classify(text: Self.receiptText, fileName: "scan.pdf"), .mortgageReceipt)
        XCTAssertEqual(DocumentClassifier.classify(text: Self.noticeText, fileName: "scan.pdf"), .mortgageNotice)
        // The text wins over a misleading file name, either way round.
        XCTAssertEqual(DocumentClassifier.classify(text: Self.noticeText, fileName: "20250331 - Prestacao - Recibo 25:480.pdf"), .mortgageNotice)
        XCTAssertEqual(DocumentClassifier.classify(text: Self.receiptText, fileName: "20250314 - Prestacao.pdf"), .mortgageReceipt)
        // A receipt without its heading: the receipt's total on a loan account.
        XCTAssertEqual(DocumentClassifier.classify(text: "CONTA EMPRÉSTIMO : 076 TOTAL DO RECIBO : 900,00 DATA: 2025-01-31", fileName: "x.pdf"),
                       .mortgageReceipt)
    }

    func testFileNameHintWithoutText() {
        for name in ["20250331 - Prestacao - Recibo 25:480.pdf", "20250331 - Prestacao - Recibo 25/480.pdf", "Prestação recibo 25-480.pdf"] {
            XCTAssertEqual(DocumentClassifier.classify(text: nil, fileName: name), .mortgageReceipt, name)
        }
        XCTAssertEqual(DocumentClassifier.classify(text: nil, fileName: "20250314 - Prestacao.pdf"), .mortgageNotice)
    }

    func testReceiptIsNotABankDebitAdvice() {
        XCTAssertNil(BBVADebitAdvice.parse(Self.receiptText))
    }

    func testInstalmentNumber() {
        XCTAssertEqual(MortgageReceipt.instalment(text: Self.receiptText, fileName: "scan.pdf"), .init(number: 25, total: 480))
        XCTAssertEqual(MortgageReceipt.instalment(text: nil, fileName: "20250331 - Prestacao - Recibo 25:480.pdf"), .init(number: 25, total: 480))
        XCTAssertEqual(MortgageReceipt.instalment(text: "TOTAL DO RECIBO 1/480 ", fileName: "x.pdf"), .init(number: 1, total: 480))
        XCTAssertNil(MortgageReceipt.instalment(text: "TOTAL DO RECIBO : 900,00 2025-01-31", fileName: "x.pdf"))
        XCTAssertEqual(MortgageReceipt.Instalment(number: 25, total: 480).label, "25/480")
    }

    func testInstalmentIsNeverAPageMarker() {
        // A page marker before the instalment: the pair near "RECIBO", or with a loan's total, wins.
        XCTAssertEqual(MortgageReceipt.instalment(text: "Pág. 1/2\nRECIBO DE EMPRÉSTIMO\n480/\n25", fileName: "x.pdf"), .init(number: 25, total: 480))
        XCTAssertEqual(MortgageReceipt.instalment(text: "Pag 1/2\nN.º RECIBO : 7/36\nTOTAL DO RECIBO : 900,00", fileName: "x.pdf"),
                       .init(number: 7, total: 36))
        XCTAssertEqual(MortgageReceipt.instalment(text: (["Pág. 1/2"] + Self.receiptLines).joined(separator: "\n"), fileName: "scan.pdf"),
                       .init(number: 25, total: 480))
        // Only a page marker in the text: the file name's instalment, else none.
        XCTAssertEqual(MortgageReceipt.instalment(text: "RECIBO DE EMPRÉSTIMO Pág. 1/2 TOTAL DO RECIBO : 900,00",
                                                  fileName: "20250331 - Prestacao - Recibo 25:480.pdf"), .init(number: 25, total: 480))
        XCTAssertNil(MortgageReceipt.instalment(text: "Página 1/2\nTOTAL DO RECIBO : 900,00", fileName: "x.pdf"))
    }

    func testAnalyzerReadsTheReceipt() {
        let metadata = EvidenceAnalyzer.analyze(text: Self.receiptText, textStatus: .glyph, fileName: "scan.pdf").metadata
        XCTAssertEqual(metadata.kind, .mortgageReceipt)
        XCTAssertEqual(metadata.amountMinorUnits, 123_456)
        XCTAssertEqual(metadata.currency, .eur)
        XCTAssertEqual(metadata.docDate, Self.day("2025-03-31"))
        XCTAssertEqual(metadata.periodStart, Self.day("2025-02-28"))
        XCTAssertEqual(metadata.periodEnd, Self.day("2025-03-31"))
    }

    // MARK: Naming

    func testCanonicalName() {
        XCTAssertEqual(MortgageReceipt.canonicalName(date: Self.day("2025-03-31"), instalment: .init(number: 25, total: 480),
                                                    amountMinorUnits: 123_456, currency: .eur),
                       "20250331 - Property - Mortgage receipt - 25/480 - €1234.56")
        XCTAssertEqual(MortgageReceipt.canonicalName(date: Self.day("2025-03-31"), instalment: nil, amountMinorUnits: nil, currency: nil),
                       "20250331 - Property - Mortgage receipt")
        let facts = [ImportFact(field: .docDate, value: .date(Self.day("2025-03-31")), source: .textLayer, confidence: .certain, reason: "Read"),
                     ImportFact(field: .amount, value: .money(123_456, .eur), source: .textLayer, confidence: .certain, reason: "Read"),
                     ImportFact(field: .receiptNumber, value: .text("25/480"), source: .textLayer, confidence: .certain, reason: "Read"),
                     ImportFact(field: .periodStart, value: .date(Self.day("2025-02-28")), source: .textLayer, confidence: .certain, reason: "Read")]
        let file = ImportFile(url: URL(fileURLWithPath: "/synthetic/r.pdf"), fileName: "r.pdf", sha256: "s", byteCount: 1, fileExtension: "pdf",
                              text: nil, textStatus: .noText, usedOCR: false)
        let placement = ImportNaming.placement(kind: .evidence(.mortgageReceipt), facts: facts, file: file, persons: [])
        XCTAssertEqual(placement.canonicalName, "20250331 - Property - Mortgage receipt - 25/480 - €1234.56")
        XCTAssertEqual(placement.metadata.kind, .mortgageReceipt)
    }

    // MARK: Matching

    private let bbva = Account(id: 1, name: "BBVA", currency: .eur, kind: .cash, trackingMode: .imported)

    private func transaction(_ id: Int64, _ date: String, _ amount: Int) -> Transaction {
        Transaction(id: id, importBatchId: 1, accountId: 1, date: Self.day(date), rawDescription: "COBR. REC. TOT 076 90-000000-2",
                    amountMinorUnits: amount, categoryId: nil, status: .confirmed, categorizedBy: .none, fingerprint: "\(id)")
    }

    func testReceiptMatchesTheDebitOnItsOwnDate() {
        let receipt = EvidenceDocument(sha256: "x", storedRelativePath: "x/x.pdf", originalFileName: "x.pdf", byteCount: 1, kind: .mortgageReceipt,
                                       docDate: Self.day("2025-03-31"), periodStart: Self.day("2025-02-28"), periodEnd: Self.day("2025-03-31"),
                                       amountMinorUnits: 123_456, currency: .eur, addedAt: Date())
        let transactions = [transaction(1, "2025-02-28", -123_456), transaction(2, "2025-03-31", -123_456), transaction(3, "2025-04-30", -123_456)]
        let suggestions = EvidenceMatcher.suggestions(document: receipt, transactions: transactions, accounts: [bbva], categories: [])
        XCTAssertEqual(EvidenceMatcher.confidentMatch(suggestions)?.transactionId, 2)
        XCTAssertEqual(suggestions.filter(\.dateInWindow).map(\.transactionId), [2])
        // Dated a week off the debit: not the receipt of it.
        var late = receipt
        late.docDate = Self.day("2025-03-24")
        let lateSuggestions = EvidenceMatcher.suggestions(document: late, transactions: transactions, accounts: [bbva], categories: [])
        XCTAssertTrue(lateSuggestions.allSatisfy { !$0.dateInWindow })
    }

    func testAMondayReceiptMatchesTheFridayDebit() {
        // The debit's day fell on a weekend: debited Friday 2025-02-28, the receipt dated Monday 2025-03-03.
        let receipt = EvidenceDocument(sha256: "x", storedRelativePath: "x/x.pdf", originalFileName: "x.pdf", byteCount: 1, kind: .mortgageReceipt,
                                       docDate: Self.day("2025-03-03"), amountMinorUnits: 123_456, currency: .eur, addedAt: Date())
        let transactions = [transaction(1, "2025-01-31", -123_456), transaction(2, "2025-02-28", -123_456), transaction(3, "2025-03-31", -123_456)]
        let suggestions = EvidenceMatcher.suggestions(document: receipt, transactions: transactions, accounts: [bbva], categories: [])
        XCTAssertEqual(EvidenceMatcher.confidentMatch(suggestions)?.transactionId, 2)
        XCTAssertEqual(suggestions.filter(\.dateInWindow).map(\.transactionId), [2])
        // Consecutive months of the same amount never cross: each receipt its own month's debit.
        for (date, expected) in [("2025-01-31", Int64(1)), ("2025-03-31", Int64(3)), ("2025-04-01", Int64(3))] {
            var other = receipt
            other.docDate = Self.day(date)
            let found = EvidenceMatcher.suggestions(document: other, transactions: transactions, accounts: [bbva], categories: [])
            XCTAssertEqual(found.filter(\.dateInWindow).map(\.transactionId), [expected], date)
            XCTAssertEqual(EvidenceMatcher.confidentMatch(found)?.transactionId, expected, date)
        }
    }

    // MARK: Claims

    func testANoticeAndAReceiptOfOneDebitAreAPairNotAClaimConflict() {
        XCTAssertEqual(ImportDuplicates.claimRole(kind: .mortgageNotice, text: Self.noticeText), .mortgageNotice)
        XCTAssertEqual(ImportDuplicates.claimRole(kind: .mortgageReceipt, text: Self.receiptText), .mortgageReceipt)
    }
}

/// The pair through the whole planning pipeline (detect, read, match, duplicates).
final class MortgageReceiptImportTests: XCTestCase {
    private var manager: DatabaseManager!
    private var db: DatabaseQueue { manager.dbQueue }
    private var pipeline: ImportPipeline!
    private var folder: URL!
    private var debitId: Int64!

    override func setUpWithError() throws {
        manager = try DatabaseManager(path: nil)
        try manager.migrate()
        try db.write { db in
            var account = Account(name: "BBVA", currency: .eur, kind: .cash, trackingMode: .imported)
            try account.insert(db)
            var batch = ImportBatch(accountId: account.id!, sourceFileName: "bbva.csv", importedAt: Date())
            try batch.insert(db)
            for (date, key) in [("2025-02-28", false), ("2025-03-31", true), ("2025-04-30", false)] {
                var row = Transaction(importBatchId: batch.id!, accountId: account.id!, date: MortgageReceiptTests.day(date),
                                      rawDescription: "COBR. REC. TOT 076 90-000000-2", amountMinorUnits: -123_456, categoryId: nil, status: .confirmed,
                                      categorizedBy: .manual, fingerprint: UUID().uuidString)
                try row.insert(db)
                if key { debitId = row.id! }
            }
        }
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("MortgageReceiptImportTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("Drop"), withIntermediateDirectories: true)
        let library = EvidenceLibrary(root: folder.appendingPathComponent("Library", isDirectory: true), database: db)
        pipeline = ImportPipeline(dbQueue: db, library: library, categorizationService: CategorizationService(categorizer: FakeCategorizer()))
    }

    override func tearDownWithError() throws {
        pipeline?.discardPlanningCopy()
        try? FileManager.default.removeItem(at: folder)
    }

    private func place(_ lines: [String], as name: String) throws -> URL {
        let url = EvidenceTestPDFs.textPDF(lines, name: "source.pdf")
        let target = folder.appendingPathComponent("Drop").appendingPathComponent(name)
        try FileManager.default.copyItem(at: url, to: target)
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        return target
    }

    func testTheNoticeAndTheReceiptOfOneDebitAreBothReadyAndLinked() async throws {
        let notice = try place(MortgageReceiptTests.noticeLines, as: "20250314 - Prestacao.pdf")
        let receipt = try place(MortgageReceiptTests.receiptLines, as: "20250331 - Prestacao - Recibo 25:480.pdf")
        let plan = try await pipeline.plan([notice, receipt])
        XCTAssertEqual(plan.items.count, 2)
        for item in plan.items {
            XCTAssertEqual(item.links.map(\.entity), [.transaction(debitId)], item.file.fileName)
            XCTAssertEqual(item.links.map(\.confidence), [.certain], item.file.fileName)
            XCTAssertEqual(item.issues.map(\.reason), [], item.file.fileName)
            XCTAssertNotEqual(item.section, .needsYou, item.file.fileName)
        }
        let receiptItem = try XCTUnwrap(plan.items.first { $0.file.fileName.contains("Recibo") })
        XCTAssertEqual(receiptItem.recognition.kind, .evidence(.mortgageReceipt))
        XCTAssertEqual(receiptItem.recognition.confidence, .certain)
        XCTAssertEqual(receiptItem.placement?.canonicalName, "20250331 - Property - Mortgage receipt - 25/480 - €1234.56")
        let noticeItem = try XCTUnwrap(plan.items.first { !$0.file.fileName.contains("Recibo") })
        XCTAssertEqual(noticeItem.recognition.kind, .evidence(.mortgageNotice))
    }

    func testTwoReceiptsOfOneDebitStillAsk() async throws {
        var other = MortgageReceiptTests.receiptLines
        other[3] = "0000001PERSON B"   // another file, same debit
        let first = try place(MortgageReceiptTests.receiptLines, as: "20250331 - Prestacao - Recibo 25:480.pdf")
        let second = try place(other, as: "20250331 - Prestacao - Recibo 25:480 (2).pdf")
        let plan = try await pipeline.plan([first, second])
        let claimed = plan.items.filter { $0.issues.contains { $0.id == "sharedTransaction.\(self.debitId!)" } }
            + plan.items.filter { $0.duplicate != nil }
        XCTAssertFalse(claimed.isEmpty, "\(plan.items.map(\.issues))")
    }

    func testTwoNoticesOfOneDebitStillAsk() async throws {
        var other = MortgageReceiptTests.noticeLines
        other[2] = "PERSON B"
        let first = try place(MortgageReceiptTests.noticeLines, as: "20250314 - Prestacao.pdf")
        let second = try place(other, as: "20250314 - Prestacao (2).pdf")
        let plan = try await pipeline.plan([first, second])
        let flagged = plan.items.filter { item in
            item.duplicate != nil || item.issues.contains { $0.id == "sharedTransaction.\(self.debitId!)" }
        }
        XCTAssertFalse(flagged.isEmpty, "\(plan.items.map(\.issues))")
    }
}
