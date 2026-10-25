import XCTest
import GRDB
@testable import BudgetCore

/// A transaction's documents for the budget (spec 2026-10-24): linked documents and a recorded
/// utility invoice's document, in date order, and the counts the paperclips show.
final class TransactionDocumentsTests: XCTestCase {
    private var manager: DatabaseManager!
    private var db: DatabaseQueue { manager.dbQueue }
    private var accountId: Int64 = 0
    private var batchId: Int64 = 0

    override func setUpWithError() throws {
        manager = try DatabaseManager(path: nil)
        try manager.migrate()
        try db.write { db in
            var account = Account(name: "Current", currency: .gbp, kind: .cash, trackingMode: .imported)
            try account.insert(db)
            var batch = ImportBatch(accountId: account.id!, sourceFileName: "demo.csv", importedAt: Date())
            try batch.insert(db)
            accountId = account.id!
            batchId = batch.id!
        }
    }

    private static func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: DateComponents(year: y, month: m, day: d))!
    }

    private func transaction(_ name: String = "Demo") throws -> Int64 {
        try db.write { db in
            var t = Transaction(importBatchId: batchId, accountId: accountId, date: Self.date(2026, 3, 1), rawDescription: name,
                                amountMinorUnits: -5_000, categoryId: nil, status: .confirmed, categorizedBy: .manual,
                                fingerprint: UUID().uuidString)
            try t.insert(db)
            return t.id!
        }
    }

    private func document(_ sha: String, kind: DocumentKind = .other, customKindId: Int64? = nil, date: Date?, name: String? = nil) throws -> Int64 {
        try db.write { db in
            var d = EvidenceDocument(sha256: sha, storedRelativePath: "\(sha.prefix(2))/\(sha).pdf", originalFileName: "\(sha).pdf", byteCount: 1,
                                     canonicalName: name, kind: kind, docDate: date, amountMinorUnits: 1_234, currency: .gbp,
                                     addedAt: Date(timeIntervalSince1970: 1_800_000_000))
            d.customKindId = customKindId
            try d.insert(db)
            return d.id!
        }
    }

    private func link(_ documentId: Int64, _ transactionId: Int64, role: String? = nil) throws {
        try db.write { db in _ = try EvidenceLinks.link(db: db, documentId: documentId, to: .transaction(transactionId), role: role) }
    }

    private func documents(_ transactionId: Int64) throws -> [TransactionDocument] {
        try db.read { db in
            try TransactionDocuments.documents(db: db, transactionId: transactionId, catalog: DocumentKindCatalog.load(db: db))
        }
    }

    func testSeveralDocumentsOnOneTransactionInDateOrder() throws {
        let t = try transaction()
        let late = try document("aa11", kind: .bankTransferProof, date: Self.date(2026, 3, 9))
        let early = try document("bb22", kind: .repairInvoice, date: Self.date(2026, 3, 2), name: "20260302 - Property - Repair - Demo")
        let undated = try document("cc33", date: nil)
        try link(late, t); try link(early, t, role: "Invoice"); try link(undated, t)
        let shown = try documents(t)
        XCTAssertEqual(shown.map(\.id), [early, late, undated])
        XCTAssertEqual(shown[0].kindLabel, "Repair bill")
        XCTAssertEqual(shown[0].displayName, "20260302 - Property - Repair - Demo")
        XCTAssertEqual(shown[0].role, "Invoice")
        XCTAssertEqual(shown[0].storedRelativePath, "bb/bb22.pdf")
        XCTAssertEqual(shown[0].fileExtension, "pdf")
        XCTAssertEqual(shown[0].amountMinorUnits, 1_234)
        XCTAssertEqual(shown[0].currency, .gbp)
        XCTAssertEqual(shown[1].displayName, "aa11.pdf")
        XCTAssertEqual(shown.map(\.otherTransactionCount), [0, 0, 0])
    }

    func testADocumentOnTwoTransactionsShowsOnBothWithTheOtherCount() throws {
        let first = try transaction("One"), second = try transaction("Two"), third = try transaction("Three")
        let shared = try document("dd44", date: Self.date(2026, 3, 5))
        try link(shared, first); try link(shared, second); try link(shared, third)
        XCTAssertEqual(try documents(first).map(\.id), [shared])
        XCTAssertEqual(try documents(first).first?.otherTransactionCount, 2)
        XCTAssertEqual(try documents(second).first?.otherTransactionCount, 2)
        let alone = try document("ee55", date: nil)
        try link(alone, first)
        XCTAssertEqual(try documents(first).first(where: { $0.id == alone })?.otherTransactionCount, 0)
    }

    func testARecordedInvoicesDocumentShowsOnItsDebitOnce() throws {
        let t = try transaction("Power debit")
        let invoiceDocument = try document("ff66", kind: .utilityInvoice, date: Self.date(2026, 2, 20))
        try db.write { db in
            var property = Property(name: "Flat", country: "PT"); try property.insert(db)
            var provider = UtilityProvider(propertyId: property.id!, name: "Demo Power", kind: .electricity); try provider.insert(db)
            var invoice = UtilityInvoice(providerId: provider.id!, invoiceNumber: "1", issueDate: Self.date(2026, 2, 20), amountMinorUnits: 5_000,
                                         documentId: invoiceDocument, transactionId: t)
            try invoice.insert(db)
        }
        XCTAssertEqual(try documents(t).map(\.id), [invoiceDocument])
        XCTAssertEqual(try db.read { try TransactionDocuments.counts(db: $0, transactionIds: [t]) }, [t: 1])
        // Also linked: still once.
        try link(invoiceDocument, t)
        XCTAssertEqual(try documents(t).map(\.id), [invoiceDocument])
        XCTAssertEqual(try db.read { try TransactionDocuments.counts(db: $0, transactionIds: [t]) }, [t: 1])
    }

    func testCountsForManyTransactionsInOneRead() throws {
        let ids: [Int64] = try db.write { db in
            try (0..<1_200).map { index in
                var t = Transaction(importBatchId: batchId, accountId: accountId, date: Self.date(2026, 3, 1), rawDescription: "T\(index)",
                                    amountMinorUnits: -100, categoryId: nil, status: .confirmed, categorizedBy: .manual,
                                    fingerprint: "fp\(index)")
                try t.insert(db)
                return t.id!
            }
        }
        let a = try document("1a1a", date: nil), b = try document("2b2b", date: nil)
        try link(a, ids[0]); try link(b, ids[0]); try link(a, ids[700]); try link(b, ids[1_199])
        let counts = try db.read { try TransactionDocuments.counts(db: $0, transactionIds: ids) }
        XCTAssertEqual(counts, [ids[0]: 2, ids[700]: 1, ids[1_199]: 1])
        XCTAssertEqual(try db.read { try TransactionDocuments.counts(db: $0, transactionIds: []) }, [:])
    }

    func testCustomKindLabelComesFromTheCatalog() throws {
        let t = try transaction()
        let kindId: Int64 = try db.write { db in
            var kind = CustomDocumentKind(name: "Boiler service", area: .property, createdAt: Date(timeIntervalSince1970: 1_800_000_000))
            try kind.insert(db)
            return kind.id!
        }
        let custom = try document("9c9c", customKindId: kindId, date: Self.date(2026, 3, 3))
        try link(custom, t)
        XCTAssertEqual(try documents(t).first?.kindLabel, "Boiler service")
    }

    func testAllCountsCoversLinkedAndRecordedDocuments() throws {
        let first = try transaction("One"), second = try transaction("Two"), none = try transaction("None")
        let a = try document("a1a1", date: nil), b = try document("b2b2", date: nil), c = try document("c3c3", kind: .utilityInvoice, date: nil)
        try link(a, first); try link(b, first); try link(a, second)
        try db.write { db in
            var property = Property(name: "Flat", country: "PT"); try property.insert(db)
            var provider = UtilityProvider(propertyId: property.id!, name: "Demo Power", kind: .electricity); try provider.insert(db)
            var invoice = UtilityInvoice(providerId: provider.id!, issueDate: Self.date(2026, 2, 1), amountMinorUnits: 100, documentId: c, transactionId: second)
            try invoice.insert(db)
        }
        let counts = try db.read { try TransactionDocuments.allCounts(db: $0) }
        XCTAssertEqual(counts, [first: 2, second: 2])
        XCTAssertNil(counts[none])
    }

    func testARecordedInvoicesDocumentAlsoLinkedElsewhereCountsTheOther() throws {
        let debit = try transaction("Debit"), other = try transaction("Other")
        let doc = try document("d4d4", kind: .utilityInvoice, date: nil)
        try db.write { db in
            var property = Property(name: "Flat", country: "PT"); try property.insert(db)
            var provider = UtilityProvider(propertyId: property.id!, name: "Demo Power", kind: .electricity); try provider.insert(db)
            var invoice = UtilityInvoice(providerId: provider.id!, issueDate: Self.date(2026, 2, 1), amountMinorUnits: 100, documentId: doc, transactionId: debit)
            try invoice.insert(db)
        }
        try link(doc, other)
        XCTAssertEqual(try documents(debit).first?.otherTransactionCount, 1)
        XCTAssertEqual(try documents(other).first?.otherTransactionCount, 1)
    }
}
