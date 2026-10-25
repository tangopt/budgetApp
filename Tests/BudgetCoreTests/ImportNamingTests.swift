import XCTest
@testable import BudgetCore

final class ImportNamingTests: XCTestCase {
    private func day(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c.date(from: DateComponents(year: y, month: m, day: d))!
    }

    private func file(modified: Date? = nil) -> ImportFile {
        ImportFile(url: URL(fileURLWithPath: "/tmp/doc.pdf"), fileName: "doc.pdf", sha256: "abc", byteCount: 1,
                   fileExtension: "pdf", text: "some text", textStatus: .text, usedOCR: false,
                   sourceFolderId: 7, sourceRelativePath: "a/doc.pdf", sourceModifiedAt: modified)
    }

    private func fact(_ field: ImportFigureField, _ value: ImportFactValue) -> ImportFact {
        ImportFact(field: field, value: value, source: .textLayer, confidence: .certain, reason: "test")
    }

    private func place(_ kind: ImportKind, _ facts: [ImportFact], modified: Date? = nil) -> ImportPlacement {
        ImportNaming.placement(kind: kind, facts: facts, file: file(modified: modified), persons: ["Sam"])
    }

    func testUtilityInvoice() {
        let p = place(.utilityInvoice, [fact(.docDate, .date(day(2026, 9, 14))), fact(.issuer, .text("Demo Power")),
                                        fact(.amount, .money(4210, .eur))])
        XCTAssertEqual(p.canonicalName, "20260914 - Utilities - Invoice - Demo Power - €42.10")
        XCTAssertEqual(p.metadata.canonicalName, p.canonicalName)
        XCTAssertEqual(p.metadata.kind, .utilityInvoice)
        XCTAssertEqual(p.metadata.docDate, day(2026, 9, 14))
        XCTAssertEqual(p.metadata.amountMinorUnits, 4210)
        XCTAssertEqual(p.metadata.currency, .eur)
        XCTAssertEqual(p.metadata.persons, ["Sam"])
        XCTAssertEqual(p.metadata.textStatus, .text)
        XCTAssertEqual(p.metadata.extractedText, "some text")
        XCTAssertEqual(p.metadata.sourceFolderId, 7)
        XCTAssertEqual(p.metadata.sourceRelativePath, "a/doc.pdf")
    }

    func testCreditNote() {
        let p = place(.utilityInvoice, [fact(.docDate, .date(day(2026, 9, 14))), fact(.issuer, .text("Demo Power")),
                                        fact(.amount, .money(-1000, .eur))])
        XCTAssertEqual(p.canonicalName, "20260914 - Utilities - Credit note - Demo Power - €10.00")
    }

    func testP60() {
        let p = place(.payrollForm(.p60), [fact(.docDate, .date(day(2025, 4, 5))), fact(.issuer, .text("Acme Ltd")),
                                           fact(.taxYear, .year(2024))])
        XCTAssertEqual(p.canonicalName, "2025 - Tax - P60 - Acme Ltd 2024/25")
        XCTAssertEqual(p.metadata.kind, .p60)
    }

    func testTransferAdviceAmountAppended() {
        let p = place(.transferAdvice, [fact(.docDate, .date(day(2026, 1, 2))), fact(.amount, .money(95000, .eur))])
        XCTAssertEqual(p.canonicalName, "20260102 - Bank - Transfer received - €950.00")
        XCTAssertEqual(p.metadata.kind, .bankTransferProof)
    }

    func testRentReceiptsExport() {
        let p = place(.rentReceiptsExport, [fact(.docDate, .date(day(2026, 2, 3))), fact(.reference, .text("Demo Flat"))])
        XCTAssertEqual(p.canonicalName, "20260203 - Rent - Receipts export - Demo Flat")
    }

    func testRentReceiptPDFDelegates() {
        let p = place(.rentReceiptPDF, [fact(.docDate, .date(day(2026, 2, 3))), fact(.reference, .text("123")),
                                        fact(.receiptNumber, .text("4")), fact(.periodStart, .date(day(2026, 2, 1))),
                                        fact(.periodEnd, .date(day(2026, 2, 28))), fact(.amount, .money(80000, .eur))])
        XCTAssertEqual(p.canonicalName, "20260203 - Rent - Receipt - 123/4 - 2026-02 - €800.00")
        XCTAssertEqual(p.metadata.kind, .rentReceipt)
        XCTAssertEqual(p.metadata.periodEnd, day(2026, 2, 28))
    }

    func testEvidenceGroups() {
        let cases: [(DocumentKind, String)] = [(.insurancePolicy, "Property"), (.sa302, "Tax UK"), (.ptIRSAssessment, "Tax PT"),
                                               (.bankStatement, "Bank"), (.other, "Other"),
                                               (.repairInvoice, "Property"), (.stampDuty, "Tax PT")]
        for (kind, area) in cases {
            let p = place(.evidence(kind), [fact(.docDate, .date(day(2026, 3, 4))), fact(.issuer, .text("Demo Co"))])
            XCTAssertEqual(p.canonicalName, "20260304 - \(area) - \(kind.displayName) - Demo Co", "\(kind)")
            XCTAssertEqual(p.metadata.kind, kind)
        }
    }

    func testStatementWithPeriod() {
        let p = place(.bankStatementCSV, [fact(.reference, .text("Demo Current")), fact(.periodStart, .date(day(2026, 3, 1))),
                                          fact(.periodEnd, .date(day(2026, 3, 31)))])
        XCTAssertEqual(p.canonicalName, "202603 - Bank - Statement - Demo Current - 2026-03")
        XCTAssertEqual(p.metadata.kind, .bankStatement)
    }

    func testDateFallsBackToFileModificationDay() {
        let p = place(.evidence(.certificate), [], modified: day(2026, 5, 6))
        XCTAssertEqual(p.canonicalName, "20260506 - Property - Certificate")
        XCTAssertNil(p.metadata.docDate)
    }

    func testUtilityInvoiceAndEvidenceIncludePeriod() {
        let period = [fact(.periodStart, .date(day(2021, 3, 1))), fact(.periodEnd, .date(day(2021, 9, 30)))]
        let u = place(.utilityInvoice, [fact(.docDate, .date(day(2021, 3, 15))), fact(.issuer, .text("Demo Power")),
                                        fact(.amount, .money(12345, .eur))] + period)
        XCTAssertEqual(u.canonicalName, "20210315 - Utilities - Invoice - Demo Power - 2021-03 to 2021-09 - €123.45")
        let e = place(.evidence(.insurancePolicy), [fact(.docDate, .date(day(2021, 3, 15))), fact(.issuer, .text("Demo Seguros"))] + period)
        XCTAssertEqual(e.canonicalName, "20210315 - Property - Insurance policy - Demo Seguros - 2021-03 to 2021-09")
    }

    func testPayrollWithoutDocDateUsesTaxYearEnd() {
        let facts = [fact(.issuer, .text("Acme Ltd")), fact(.taxYear, .year(2024))]
        XCTAssertEqual(place(.payrollForm(.p60), facts, modified: day(2026, 5, 6)).canonicalName, "2025 - Tax - P60 - Acme Ltd 2024/25")
        XCTAssertEqual(place(.payrollForm(.p45), facts).canonicalName, "2025 - Tax - P45 - Acme Ltd 2024/25")
        XCTAssertEqual(place(.payrollForm(.p11d), facts).canonicalName, "2025 - Tax - P11D - Acme Ltd 2024/25")
        XCTAssertEqual(place(.payrollForm(.p45), facts).metadata.kind, .p45)
        XCTAssertEqual(place(.payrollForm(.p11d), facts).metadata.kind, .p11d)
    }
}
