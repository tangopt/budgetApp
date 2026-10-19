import XCTest
import GRDB
@testable import BudgetCore

/// Linking the portal's rent-receipt PDFs to imported receipts (`RentReceiptPDFs`): reading,
/// matching, validating and adding them to the library. Synthetic receipts, names and NIFs only.
final class RentReceiptPDFsTests: XCTestCase {
    private var manager: DatabaseManager!
    private var db: DatabaseQueue { manager.dbQueue }
    private var root: URL!
    private var library: EvidenceLibrary!
    private var tenancyId: Int64!
    private var created: [URL] = []

    /// Valid synthetic NIFs (check digit right), and one that fails it.
    static let landlordNIF = "123456789"
    static let tenantNIF = "234567899"
    static let badNIF = "123456780"

    override func setUpWithError() throws {
        manager = try DatabaseManager(path: nil)
        try manager.migrate()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("RentReceiptPDFsTests-\(UUID().uuidString)/Evidence", isDirectory: true)
        library = EvidenceLibrary(root: root, database: manager.dbQueue)
        tenancyId = try db.write { db in
            var property = Property(name: "Property A", country: "PT")
            try Properties.save(db: db, &property)
            var tenancy = Tenancy(propertyId: property.id!, referenceLabel: "Room Contract AB", contractNumber: "1001",
                                  tenantName: "TENANT B", startDate: Self.date(2024, 1, 1))
            try Tenancies.save(db: db, &tenancy)
            for (number, month, status) in [("1", 1, RentReceiptStatus.issued), ("2", 2, .issued), ("3", 2, .cancelled), ("4", 3, .issued)] {
                var receipt = RentReceipt(tenancyId: tenancy.id!, receiptNumber: number, periodStart: Self.date(2024, month, 1),
                                          periodEnd: Self.date(2024, month, month == 2 ? 29 : 31), receiptDate: Self.date(2024, month, 3),
                                          amountMinorUnits: 110_000, status: status)
                try RentReceipts.save(db: db, &receipt)
            }
            return tenancy.id!
        }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
        for url in created { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    }

    private static func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        MonthRange.calendar.date(from: DateComponents(year: y, month: m, day: d))!
    }

    /// The portal's layout, line by line (one copy).
    static func lines(contract: String = "1001", receipt: String, issued: String = "2024-01-05", start: String, end: String,
                      amount: String = "1.100,00", withholding: String = "0,00", received: String = "1.100,00",
                      receivedOn: String, tenant: String = "TENANT B", tenantNIF: String = tenantNIF,
                      landlordNIF: String = landlordNIF) -> [String] {
        ["RECIBO DE RENDA ELETRÓNICO", "Original", "RECIBO DE RENDA N.º", "\(contract)/\(receipt)", "DATA DE EMISSÃO", issued,
         "EMITENTE", "NOME", "LANDLORD A", "NIF", landlordNIF, "LOCADOR/SUBLOCADOR (SENHORIO)/CEDENTE", "NOME NIF",
         "LANDLORD A \(landlordNIF)", "LOCATARIO/SUBLOCATÁRIO (INQUILINO)/CESSIONÁRIO", "NOME NIF NIF Estrangeiro / Outro Doc.",
         "Identificação", "PAÍS", "\(tenant) \(tenantNIF)", "TIPO DE CONTRATO", "Arrendamento", "RENDA",
         "Período a que respeita a renda", start, "a", "\(end) Valor \(amount)",
         "Retenção de IRS (Sem retenção - artigo 101.º, n.º 1, do CIRS)", withholding, "€", "€", "Renda €", "Caução",
         "Adiantamento", "Importância Recebida", received, "IMPORTÂNCIA RECEBIDA A TÍTULO DE: Data de recebimento: \(receivedOn)",
         "INFORMAÇÕES COMPLEMENTARES"]
    }

    private func pdf(_ name: String, _ lines: [String]) -> URL {
        let url = EvidenceTestPDFs.textPDF(lines, name: name)
        created.append(url)
        return url
    }

    // MARK: Reading

    func testParsesTheReceiptText() throws {
        let text = Self.lines(receipt: "7", start: "2024-01-01", end: "2024-01-31", amount: "2.345,67", withholding: "586,42",
                              received: "1.759,25", receivedOn: "2024-01-03").joined(separator: "\n")
        let parsed = try XCTUnwrap(RentReceiptPDFs.parse(text))
        XCTAssertEqual(parsed.contractNumber, "1001")
        XCTAssertEqual(parsed.receiptNumber, "7")
        XCTAssertEqual(parsed.issueDate, Self.date(2024, 1, 5))
        XCTAssertEqual(parsed.periodStart, Self.date(2024, 1, 1))
        XCTAssertEqual(parsed.periodEnd, Self.date(2024, 1, 31))
        XCTAssertEqual(parsed.receiptDate, Self.date(2024, 1, 3))
        XCTAssertEqual(parsed.amountMinorUnits, 234_567)
        XCTAssertEqual(parsed.withholdingMinorUnits, 58_642)
        XCTAssertEqual(parsed.amountReceivedMinorUnits, 175_925)
        XCTAssertEqual(parsed.landlordName, "LANDLORD A")
        XCTAssertEqual(parsed.landlordNIF, Self.landlordNIF)
        XCTAssertEqual(parsed.tenantName, "TENANT B")
        XCTAssertEqual(parsed.tenantNIF, Self.tenantNIF)
    }

    func testReadsAPDFsTextLayer() throws {
        let url = pdf("recibo1001_1.pdf", Self.lines(receipt: "1", start: "2024-01-01", end: "2024-01-31", receivedOn: "2024-01-03"))
        let input = try RentReceiptPDFs.read(url, ocr: false)
        XCTAssertEqual(input.textStatus, .text)
        XCTAssertEqual(input.sha256, try EvidenceLibrary.sha256(of: url))
        let parsed = try XCTUnwrap(input.text.flatMap(RentReceiptPDFs.parse))
        XCTAssertEqual(parsed.receiptNumber, "1")
        XCTAssertEqual(parsed.amountMinorUnits, 110_000)
        XCTAssertEqual(parsed.tenantNIF, Self.tenantNIF)
    }

    func testOtherTextIsNotAReceipt() {
        XCTAssertNil(RentReceiptPDFs.parse("Fatura n.º 12 de 2024-01-01 Total 10,00 €"))
    }

    func testNIFCheckDigit() {
        XCTAssertTrue(RentReceiptPDFs.isValidNIF(Self.landlordNIF))
        XCTAssertTrue(RentReceiptPDFs.isValidNIF(Self.tenantNIF))
        XCTAssertFalse(RentReceiptPDFs.isValidNIF(Self.badNIF))
        XCTAssertFalse(RentReceiptPDFs.isValidNIF("12345678"))
    }

    // MARK: Matching and linking

    private func inputs(_ files: [(String, [String])]) throws -> [RentReceiptPDFs.Input] {
        try files.map { try RentReceiptPDFs.read(pdf($0.0, $0.1), ocr: false) }
    }

    private func receiptId(_ number: String) throws -> Int64 {
        try db.read { db in try RentReceipts.receipt(db: db, tenancyId: tenancyId, receiptNumber: number)!.id! }
    }

    func testMatchesValidatesAddsAndLinks() throws {
        let batch = try inputs([
            ("r1.pdf", Self.lines(receipt: "1", start: "2024-01-01", end: "2024-01-31", receivedOn: "2024-01-03")),
            // Amount and receipt date disagree with the stored receipt.
            ("r2.pdf", Self.lines(receipt: "2", start: "2024-02-01", end: "2024-02-29", amount: "1.200,00", received: "1.200,00",
                                  receivedOn: "2024-02-04")),
            // The cancelled receipt's PDF: agrees, linked, reported.
            ("r3.pdf", Self.lines(receipt: "3", start: "2024-02-01", end: "2024-02-29", receivedOn: "2024-02-03")),
            // No such receipt.
            ("r9.pdf", Self.lines(receipt: "9", start: "2024-09-01", end: "2024-09-30", receivedOn: "2024-09-03")),
            ("notes.pdf", ["Some other document with enough letters to have a text layer"])
        ])
        let plan = try db.read { db in try RentReceiptPDFs.plan(db: db, inputs: batch) }
        XCTAssertEqual(plan.items.map(\.outcome), [.link, .mismatch, .link, .noReceipt, .unreadable])
        XCTAssertEqual(plan.items[1].mismatches, [
            .init(field: "receipt date", pdf: "2024-02-04", stored: "2024-02-03"),
            .init(field: "amount", pdf: "€1,200.00", stored: "€1,100.00"),
            .init(field: "amount received", pdf: "€1,200.00", stored: "€1,100.00")
        ])
        XCTAssertEqual(plan.receiptsWithoutPDF.map(\.receipt.receiptNumber), ["4"])
        XCTAssertEqual(plan.cancelledReceipts.map(\.receiptNumber), ["3"])
        XCTAssertEqual(plan.nifIssues, [])

        let applied = try db.write { db in try RentReceiptPDFs.apply(db: db, plan: plan, inputs: batch, library: library) }
        XCTAssertEqual(applied.added, 2)
        XCTAssertEqual(applied.linked, 2)
        XCTAssertEqual(applied.placedFiles.count, 2)
        let documents = try library.documents(for: .rentReceipt(try receiptId("1")))
        XCTAssertEqual(documents.count, 1)
        XCTAssertEqual(documents[0].kind, .rentReceipt)
        XCTAssertEqual(documents[0].docDate, Self.date(2024, 1, 5))
        XCTAssertEqual(documents[0].amountMinorUnits, 110_000)
        XCTAssertEqual(documents[0].canonicalName, "20240105 - Rent - Receipt - 1001/1 - 2024-01 - €1100.00")
        XCTAssertTrue(FileManager.default.fileExists(atPath: library.fileURL(for: documents[0]).path))
        XCTAssertEqual(try library.entities(for: documents[0].id!).map(\.role), ["Receipt"])
        XCTAssertTrue(try library.documents(for: .rentReceipt(try receiptId("2"))).isEmpty, "a mismatch isn't linked")

        // Again: nothing new.
        let again = try db.read { db in try RentReceiptPDFs.plan(db: db, inputs: batch) }
        XCTAssertEqual(again.items.map(\.outcome), [.alreadyLinked, .mismatch, .alreadyLinked, .noReceipt, .unreadable])
        let second = try db.write { db in try RentReceiptPDFs.apply(db: db, plan: again, inputs: batch, library: library) }
        XCTAssertEqual(second, RentReceiptPDFs.Applied())
        XCTAssertEqual(try db.read { db in try EvidenceDocument.fetchCount(db) }, 2)

        let report = RentReceiptPDFs.report(plan, applied: applied)
        XCTAssertTrue(report.contains("amount: PDF €1,200.00 vs stored €1,100.00"))
        XCTAssertTrue(report.contains("r9.pdf: receipt 1001/9"))
        XCTAssertTrue(report.contains("receipt 4 2024-03-01…2024-03-31"))
        XCTAssertTrue(report.contains("receipt 3 2024-02-01…2024-02-29 €1,100.00 — PDF r3.pdf (link)"))
    }

    func testReusesALibraryDocumentAndSetsItsKind() throws {
        let url = pdf("r1.pdf", Self.lines(receipt: "1", start: "2024-01-01", end: "2024-01-31", receivedOn: "2024-01-03"))
        let existing = try library.add(url, metadata: EvidenceMetadata(kind: .other)).document
        let batch = [try RentReceiptPDFs.read(url, ocr: false)]
        let plan = try db.read { db in try RentReceiptPDFs.plan(db: db, inputs: batch) }
        XCTAssertEqual(plan.items[0].existingDocumentId, existing.id)
        let applied = try db.write { db in try RentReceiptPDFs.apply(db: db, plan: plan, inputs: batch, library: library) }
        XCTAssertEqual(applied.added, 0)
        XCTAssertEqual(applied.reused, 1)
        XCTAssertEqual(applied.kindsSet, 1)
        XCTAssertEqual(applied.placedFiles, [])
        XCTAssertEqual(try library.documents(for: .rentReceipt(try receiptId("1"))).map(\.id), [existing.id])
        XCTAssertEqual(try library.documents(for: .rentReceipt(try receiptId("1")))[0].kind, .rentReceipt)
    }

    func testDuplicatesAndNIFIssues() throws {
        let first = Self.lines(receipt: "1", start: "2024-01-01", end: "2024-01-31", receivedOn: "2024-01-03")
        let batch = try inputs([
            ("a.pdf", first),
            ("b.pdf", first), // same content
            // Same receipt, other file; and a tenant NIF that fails the check digit.
            ("c.pdf", Self.lines(receipt: "1", issued: "2024-01-06", start: "2024-01-01", end: "2024-01-31", receivedOn: "2024-01-03")),
            ("d.pdf", Self.lines(receipt: "4", start: "2024-03-01", end: "2024-03-31", receivedOn: "2024-03-03", tenantNIF: Self.badNIF))
        ])
        let plan = try db.read { db in try RentReceiptPDFs.plan(db: db, inputs: batch) }
        XCTAssertEqual(plan.items.map(\.outcome), [.link, .duplicate(of: "a.pdf"), .duplicate(of: "a.pdf"), .link])
        XCTAssertEqual(plan.nifIssues, [
            "contract 1001: 2 different tenant NIFs (\(Self.badNIF), \(Self.tenantNIF))",
            "tenant NIF \(Self.badNIF) fails the check digit (1 PDF(s))"
        ])
    }

    func testTenantNameMismatch() throws {
        let batch = try inputs([("r1.pdf", Self.lines(receipt: "1", start: "2024-01-01", end: "2024-01-31", receivedOn: "2024-01-03",
                                                      tenant: "SOMEONE ELSE"))])
        let plan = try db.read { db in try RentReceiptPDFs.plan(db: db, inputs: batch) }
        XCTAssertEqual(plan.items[0].outcome, .mismatch)
        XCTAssertEqual(plan.items[0].mismatches, [.init(field: "tenant", pdf: "SOMEONE ELSE", stored: "TENANT B")])
    }

    func testAFailedTransactionLeavesNoRowsAndTheCallerRemovesThePlacedFiles() throws {
        let batch = try inputs([("r1.pdf", Self.lines(receipt: "1", start: "2024-01-01", end: "2024-01-31", receivedOn: "2024-01-03"))])
        struct Abort: Error {}
        var placed: [URL] = []
        XCTAssertThrowsError(try db.write { db in
            let plan = try RentReceiptPDFs.plan(db: db, inputs: batch)
            placed = try RentReceiptPDFs.apply(db: db, plan: plan, inputs: batch, library: library).placedFiles
            throw Abort()
        })
        XCTAssertEqual(placed.count, 1)
        XCTAssertEqual(try db.read { db in try EvidenceDocument.fetchCount(db) }, 0)
        XCTAssertEqual(try db.read { db in try DocumentLink.fetchCount(db) }, 0)
        for url in placed { try FileManager.default.removeItem(at: url) }
    }

    func testLibraryAddInsideATransaction() throws {
        let url = pdf("r1.pdf", Self.lines(receipt: "1", start: "2024-01-01", end: "2024-01-31", receivedOn: "2024-01-03"))
        let staged = try db.write { db in try library.add(db: db, url, metadata: EvidenceMetadata(kind: .rentReceipt), analysis: nil) }
        XCTAssertTrue(staged.result.isNew)
        XCTAssertNotNil(staged.placedFile)
        XCTAssertEqual(staged.result.document.kind, .rentReceipt)
        let again = try db.write { db in try library.add(db: db, url, metadata: EvidenceMetadata(), analysis: nil) }
        XCTAssertFalse(again.result.isNew)
        XCTAssertNil(again.placedFile)
        XCTAssertEqual(again.result.document.id, staged.result.document.id)
    }
}
