import XCTest
@testable import BudgetCore

final class ImportDetectorTests: XCTestCase {
    private let provider = UtilityProvider(propertyId: 1, name: "Example Power", kind: .electricity,
                                           invoiceRules: UtilityInvoiceRules(textMarkers: ["EXAMPLE POWER"], fileNameMarkers: ["LUZ"],
                                                                             invoiceNumberPatterns: [], amountLabels: ["AMOUNT DUE"]))
    private var detector: ImportDetector { ImportDetector(providers: [provider]) }

    private func file(_ name: String, text: String? = nil, url: URL? = nil) -> ImportFile {
        ImportFile(url: url ?? URL(fileURLWithPath: "/tmp/\(name)"), fileName: name, sha256: "abc", byteCount: 1,
                   fileExtension: (name as NSString).pathExtension.lowercased(), text: text,
                   textStatus: text == nil ? .noText : .text, usedOCR: false)
    }

    private func expect(_ file: ImportFile, _ kind: ImportKind, _ confidence: ImportConfidence, _ reason: String,
                        line: UInt = #line) {
        XCTAssertEqual(detector.detect(file), ImportRecognition(kind: kind, confidence: confidence, reason: reason), line: line)
    }

    func testRentReceiptsExport() throws {
        let rows = [RentReceiptImportTests.ExportRow(receipt: "1", start: "2025-01-01", end: "2025-01-31"),
                    RentReceiptImportTests.ExportRow(receipt: "2", start: "2025-02-01", end: "2025-02-28")]
        let url = EvidenceTestPDFs.temporaryURL("export.xlsx")
        try RentReceiptImportTests.export(rows).write(to: url)
        expect(file("export.xlsx", url: url), .rentReceiptsExport, .certain, "Portal das Finanças receipts export (2 rows)")
    }

    func testOtherSpreadsheetIsNotAnExport() throws {
        let url = EvidenceTestPDFs.temporaryURL("other.xlsx")
        try Data("x".utf8).write(to: url)
        expect(file("other.xlsx", url: url), .unknown, .needsReview, "Not recognised")
    }

    func testRentReceiptPDF() {
        expect(file("r.pdf", text: "RECIBO DE RENDA N.º 1001/5\nDATA DE EMISSAO 2025-01-03"),
               .rentReceiptPDF, .certain, "Rent receipt nº 5 of contract 1001")
    }

    func testTransferAdvice() {
        expect(file("a.pdf", text: "TRANSFERENCIA RECEBIDA\nDATA: 2024-01-16\nVALOR 1.100,00"),
               .transferAdvice, .certain, "BBVA received-transfer advice of 2024-01-16")
    }

    func testPayrollForm() {
        expect(file("p.pdf", text: "P60 End of Year Certificate\nTax year to 5 April 2025"),
               .payrollForm(.p60), .certain, "P60 wording")
    }

    func testUtilityInvoice() {
        expect(file("i.pdf", text: "EXAMPLE POWER\nAMOUNT DUE 50,00"), .utilityInvoice, .certain, "Invoice of Example Power")
    }

    func testBankStatementCSVAndPDF() {
        expect(file("s.csv", text: "Date,Amount\n2025-01-01,5"), .bankStatementCSV, .certain, "CSV file")
        expect(file("s.pdf", text: "EXTRATO DE CONTA\nSALDO INICIAL 10,00"), .bankStatementPDF, .certain, "Bank statement wording")
    }

    func testCSVWithByteOrderMarkStillCSV() {
        expect(file("s.csv", text: "\u{FEFF}Date,Amount"), .bankStatementCSV, .certain, "CSV file")
    }

    func testUnreadableCSVEndsUnknownWithReason() {
        expect(file("s.csv", text: nil), .unknown, .needsReview, "The file could not be read as text")
    }

    func testEvidenceFromText() {
        expect(file("t.pdf", text: "TAX CODE NOTICE\nThis is to tell you your tax code"),
               .evidence(.taxCodeNotice), .certain, "\(DocumentKind.taxCodeNotice.displayName) wording")
    }

    func testFileNameOnlyIsNeedsReview() {
        expect(file("SA302 2024.pdf", text: nil), .evidence(.sa302), .needsReview, "Recognised from the file name only")
    }

    func testNothingRecognised() {
        expect(file("notes.pdf", text: "hello"), .unknown, .needsReview, "Not recognised")
    }

    func testIntentMismatchIssue() {
        let found = ImportRecognition(kind: .utilityInvoice, confidence: .certain, reason: "x")
        let issue = ImportDetector.intentIssue(found, intent: ImportIntent(expected: .rentReceiptsExport))
        XCTAssertEqual(issue?.reason, "Expected a Rent receipts export, this looks like a Utility invoice")
        XCTAssertEqual(issue?.kind, .kindMismatch(expected: .rentReceiptsExport, found: .utilityInvoice))
        XCTAssertNil(ImportDetector.intentIssue(found, intent: .none))
        XCTAssertNil(ImportDetector.intentIssue(found, intent: ImportIntent(expected: .utilityInvoice)))
        let p45 = ImportRecognition(kind: .payrollForm(.p45), confidence: .certain, reason: "x")
        XCTAssertNil(ImportDetector.intentIssue(p45, intent: ImportIntent(expected: .payrollForm(.p60))))
    }

    func testRecognisersAreExtensible() {
        var custom = detector
        custom.recognisers.insert({ _ in ImportRecognition(kind: .bbvaStatement, confidence: .certain, reason: "first") }, at: 0)
        XCTAssertEqual(custom.detect(file("a.pdf")).reason, "first")
    }
}
