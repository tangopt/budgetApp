import XCTest
@testable import BudgetCore

final class DocumentModelReaderTests: XCTestCase {
    private func schema(kind: String = "Insurance receipt", issuer: String = "Acme Seguros", date: String = "2026-03-14",
                        amount: String = "1234.56", currency: String = "EUR", reference: String = "R-1") -> DocumentGuessSchema {
        DocumentGuessSchema(kind: kind, issuer: issuer, documentDate: date, amount: amount, currency: currency, reference: reference)
    }
    private let kinds: [DocumentKind] = [.insuranceReceipt, .p60, .utilityInvoice]

    func testKnownKindNameBecomesKind() {
        XCTAssertEqual(FoundationModelsDocumentReader.guess(from: schema(), kinds: kinds).kind, .insuranceReceipt)
        XCTAssertEqual(FoundationModelsDocumentReader.guess(from: schema(kind: "insurance receipt"), kinds: kinds).kind, .insuranceReceipt)
    }

    func testUnknownKindIsNilAndOtherFieldsSurvive() {
        let g = FoundationModelsDocumentReader.guess(from: schema(kind: "Holiday photo"), kinds: kinds)
        XCTAssertNil(g.kind)
        XCTAssertEqual(g.issuer, "Acme Seguros")
        XCTAssertEqual(g.amountMinorUnits, 123456)
        let other = FoundationModelsDocumentReader.guess(from: schema(kind: "other"), kinds: kinds)
        XCTAssertNil(other.kind)
    }

    func testDates() {
        XCTAssertNotNil(FoundationModelsDocumentReader.guess(from: schema(), kinds: kinds).docDate)
        XCTAssertNil(FoundationModelsDocumentReader.guess(from: schema(date: "2026-02-30"), kinds: kinds).docDate)
        XCTAssertNil(FoundationModelsDocumentReader.guess(from: schema(date: ""), kinds: kinds).docDate)
        XCTAssertNil(FoundationModelsDocumentReader.guess(from: schema(date: "14/03/2026"), kinds: kinds).docDate)
    }

    func testAmounts() {
        XCTAssertEqual(FoundationModelsDocumentReader.guess(from: schema(amount: "1.234,56"), kinds: kinds).amountMinorUnits, 123456)
        XCTAssertEqual(FoundationModelsDocumentReader.guess(from: schema(amount: "1234.56"), kinds: kinds).amountMinorUnits, 123456)
        XCTAssertEqual(FoundationModelsDocumentReader.guess(from: schema(amount: "1,234.56"), kinds: kinds).amountMinorUnits, 123456)
        XCTAssertEqual(FoundationModelsDocumentReader.guess(from: schema(amount: "12"), kinds: kinds).amountMinorUnits, 1200)
        XCTAssertNil(FoundationModelsDocumentReader.guess(from: schema(amount: ""), kinds: kinds).amountMinorUnits)
        XCTAssertNil(FoundationModelsDocumentReader.guess(from: schema(amount: "about 50"), kinds: kinds).amountMinorUnits)
    }

    func testCurrencyOnlyEurOrGbp() {
        XCTAssertEqual(FoundationModelsDocumentReader.guess(from: schema(currency: "EUR"), kinds: kinds).currency, .eur)
        XCTAssertEqual(FoundationModelsDocumentReader.guess(from: schema(currency: "gbp"), kinds: kinds).currency, .gbp)
        XCTAssertNil(FoundationModelsDocumentReader.guess(from: schema(currency: "USD"), kinds: kinds).currency)
        XCTAssertNil(FoundationModelsDocumentReader.guess(from: schema(currency: ""), kinds: kinds).currency)
    }

    func testEmptyIssuerAndReferenceAreNil() {
        let g = FoundationModelsDocumentReader.guess(from: schema(issuer: " ", reference: ""), kinds: kinds)
        XCTAssertNil(g.issuer)
        XCTAssertNil(g.reference)
    }

    func testAvailabilityMessages() {
        XCTAssertEqual(FoundationModelsDocumentReader.message(forReason: .appleIntelligenceNotEnabled), "On-device model unavailable: Apple Intelligence is turned off")
        XCTAssertEqual(FoundationModelsDocumentReader.message(forReason: .deviceNotEligible), "On-device model unavailable on this Mac")
        XCTAssertEqual(FoundationModelsDocumentReader.message(forReason: .modelNotReady), "On-device model is still downloading")
        XCTAssertEqual(FoundationModelsDocumentReader.message(forReason: nil), "On-device model unavailable")
    }

    func testPromptTextIsCutAtSixThousandCharacters() {
        let long = String(repeating: "a", count: 9000)
        XCTAssertEqual(FoundationModelsDocumentReader.clipped(long).count, 6000)
        XCTAssertEqual(FoundationModelsDocumentReader.clipped("short"), "short")
    }

    // MARK: Fix round 1

    private func reader(timeoutMs: UInt64 = 50, available: Bool = true,
                        call: @escaping @Sendable (String) async throws -> DocumentGuessSchema) -> FoundationModelsDocumentReader {
        FoundationModelsDocumentReader(availability: { available ? .available : .unavailable("nope") },
                                       timeoutNanoseconds: timeoutMs * 1_000_000, call: call)
    }

    func testCancellableStuckCallTimesOut() async {
        let r = reader { _ in try await Task.sleep(nanoseconds: 60_000_000_000); fatalError() }
        let start = Date()
        do { _ = try await r.read(text: "x", fileName: "f.pdf", kinds: kinds); XCTFail("should time out") }
        catch { XCTAssertEqual(error as? DocumentModelReadError, .timedOut) }
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
    }

    func testCallIgnoringCancellationStillTimesOutPromptly() async {
        let r = reader { _ in
            // Blocks a thread-free spin that never checks cancellation.
            await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }
            fatalError()
        }
        let start = Date()
        do { _ = try await r.read(text: "x", fileName: "f.pdf", kinds: kinds); XCTFail("should time out") }
        catch { XCTAssertEqual(error as? DocumentModelReadError, .timedOut) }
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
    }

    func testFastCallReturnsGuess() async throws {
        let r = reader(timeoutMs: 5_000) { _ in self.schema() }
        let g = try await r.read(text: "x", fileName: "f.pdf", kinds: kinds)
        XCTAssertEqual(g?.kind, .insuranceReceipt)
    }

    func testReadWhileUnavailableThrowsDistinctError() async {
        let r = reader(available: false) { _ in self.schema() }
        do { _ = try await r.read(text: "x", fileName: "f.pdf", kinds: kinds); XCTFail() }
        catch { XCTAssertEqual(error as? DocumentModelReadError, .unavailable("nope")) }
    }

    func testMalformedAmountsRejectedAndAmbiguousThousandsPinned() {
        for bad in ["1.2.3", "1,2,3,4", "1234.567", "1.234.5", "1,234,56.7"] {
            XCTAssertNil(FoundationModelsDocumentReader.guess(from: schema(amount: bad), kinds: kinds).amountMinorUnits, bad)
        }
        XCTAssertEqual(FoundationModelsDocumentReader.guess(from: schema(amount: "1.234"), kinds: kinds).amountMinorUnits, 123400)
        XCTAssertEqual(FoundationModelsDocumentReader.guess(from: schema(amount: "1.234.567,89"), kinds: kinds).amountMinorUnits, 123456789)
    }

    func testKindNameTolerance() {
        for name in ["Insurance receipts", "Insurance receipt.", " INSURANCE RECEIPT, "] {
            XCTAssertEqual(FoundationModelsDocumentReader.guess(from: schema(kind: name), kinds: kinds).kind, .insuranceReceipt, name)
        }
    }

    func testOtherKindExcludedEvenWhenOffered() {
        let g = FoundationModelsDocumentReader.guess(from: schema(kind: "Other"), kinds: kinds + [.other])
        XCTAssertNil(g.kind)
    }

    func testIssuerAndReferenceCollapsedAndCapped() {
        let g = FoundationModelsDocumentReader.guess(from: schema(issuer: "Acme \n  Seguros", reference: String(repeating: "x", count: 500)), kinds: kinds)
        XCTAssertEqual(g.issuer, "Acme Seguros")
        XCTAssertEqual(g.reference?.count, 100)
    }

    func testPromptDelimitsDocumentAndCapsFileName() {
        let p = FoundationModelsDocumentReader.prompt(text: "body", fileName: String(repeating: "n", count: 500), kinds: kinds)
        XCTAssertTrue(p.contains("===== DOCUMENT START =====\nbody\n===== DOCUMENT END ====="))
        XCTAssertFalse(p.contains(String(repeating: "n", count: 101)))
    }
}
