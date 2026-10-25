import XCTest
import GRDB
@testable import BudgetCore
import TestSupport

/// The one-off pass that files the mortgage receipts filed as notices under their own kind, and
/// lets the rules that accept a notice accept a receipt too. Synthetic database only.
final class MortgageReceiptReclassificationTests: XCTestCase {
    private var manager: DatabaseManager!
    private var db: DatabaseQueue { manager.dbQueue }

    override func setUpWithError() throws {
        manager = try TestDatabase.migratedManager()
    }

    private func day(_ string: String) -> Date { MortgageReceiptTests.day(string) }

    @discardableResult
    private func document(_ name: String, kind: DocumentKind = .mortgageNotice, text: String?, date: String?, amount: Int? = 123_456,
                          canonical: String? = nil) throws -> Int64 {
        try db.write { db in
            var document = EvidenceDocument(sha256: "sha-\(name)", storedRelativePath: "sh/sha-\(name).pdf", originalFileName: name, byteCount: 1,
                                            canonicalName: canonical, kind: kind, docDate: date.map(day), amountMinorUnits: amount,
                                            currency: amount == nil ? nil : .eur, textStatus: text == nil ? .image : .glyph, extractedText: text,
                                            addedAt: Date())
            try document.insert(db)
            return document.id!
        }
    }

    private func requirement(_ name: String, kinds: [DocumentKind]) throws -> Int64 {
        try db.write { db in
            var requirement = EvidenceRequirement(name: name, scope: .transactionsMatching(categoryIds: [], accountIds: [], descriptionContains: "prest"),
                                                  kinds: kinds)
            try EvidenceRequirements.save(db: db, &requirement)
            return requirement.id!
        }
    }

    func testPlansReceiptsFiledAsNoticesAndTheRulesThatAcceptNotices() throws {
        let byText = try document("scan-1.pdf", text: MortgageReceiptTests.receiptText, date: "2025-03-31",
                                  canonical: "20250331 - Property - Mortgage notice - 2025-02 to 2025-03 - €1234.56")
        let byName = try document("20250430 - Prestacao - Recibo 26:480.pdf", text: nil, date: "2025-04-30", amount: nil)
        try document("20250314 - Prestacao.pdf", text: MortgageReceiptTests.noticeText, date: "2025-03-14")
        // The text says notice, whatever the name.
        try document("20250414 - Prestacao - Recibo 26:480.pdf", text: MortgageReceiptTests.noticeText, date: "2025-04-14")
        // Not a notice: left alone.
        try document("other.pdf", kind: .other, text: MortgageReceiptTests.receiptText, date: "2025-03-31")

        let instalments = try requirement("Mortgage instalments", kinds: [.mortgageNotice])
        let interest = try requirement("Mortgage interest", kinds: [.mortgageNotice, .mortgageInterestStatement])
        _ = try requirement("Already", kinds: [.mortgageNotice, .mortgageReceipt])
        _ = try requirement("IMI", kinds: [.imiNotice])

        let plan = try db.read { try MortgageReceiptReclassification.plan(db: $0) }
        XCTAssertEqual(plan.documents.map(\.documentId), [byText, byName])
        XCTAssertEqual(plan.documents.map(\.newCanonicalName), ["20250331 - Property - Mortgage receipt - 25/480 - €1234.56",
                                                               "20250430 - Property - Mortgage receipt - 26/480"])
        XCTAssertEqual(plan.documents.map(\.reason), [.text, .fileName])
        XCTAssertEqual(plan.documents.first?.oldCanonicalName, "20250331 - Property - Mortgage notice - 2025-02 to 2025-03 - €1234.56")
        XCTAssertEqual(plan.requirements.map(\.requirementId), [instalments, interest])
        XCTAssertEqual(plan.requirements.map(\.newKinds), [[.mortgageNotice, .mortgageReceipt],
                                                           [.mortgageNotice, .mortgageReceipt, .mortgageInterestStatement]])
    }

    func testApplyWritesThroughTheSavesAndIsTrackedForSync() throws {
        let receipt = try document("scan-1.pdf", text: MortgageReceiptTests.receiptText, date: "2025-03-31")
        let rule = try requirement("Mortgage instalments", kinds: [.mortgageNotice])
        try db.write { db in try db.execute(sql: "DELETE FROM syncPending") }

        let plan = try db.read { try MortgageReceiptReclassification.plan(db: $0) }
        try db.write { try MortgageReceiptReclassification.apply(db: $0, plan) }

        try db.read { db in
            let document = try XCTUnwrap(try EvidenceDocument.fetchOne(db, key: receipt))
            XCTAssertEqual(document.kind, .mortgageReceipt)
            XCTAssertEqual(document.canonicalName, "20250331 - Property - Mortgage receipt - 25/480 - €1234.56")
            XCTAssertEqual(try EvidenceRequirement.fetchOne(db, key: rule)?.kinds, [.mortgageNotice, .mortgageReceipt])
            let pending = try SyncChangeTracker.pending(db: db)
            XCTAssertTrue(pending.contains { $0.table == EvidenceDocument.databaseTableName && $0.localId == receipt }, "\(pending)")
            XCTAssertTrue(pending.contains { $0.table == EvidenceRequirement.databaseTableName && $0.localId == rule }, "\(pending)")
        }
        // Run again: nothing left.
        let again = try db.read { try MortgageReceiptReclassification.plan(db: $0) }
        XCTAssertTrue(again.isEmpty)
    }

    func testApplyRefusesAPlanTheDatabaseNoLongerMatches() throws {
        let receipt = try document("scan-1.pdf", text: MortgageReceiptTests.receiptText, date: "2025-03-31")
        let plan = try db.read { try MortgageReceiptReclassification.plan(db: $0) }
        try db.write { db in try db.execute(sql: "UPDATE document SET kind = 'other' WHERE id = ?", arguments: [receipt]) }
        XCTAssertThrowsError(try db.write { try MortgageReceiptReclassification.apply(db: $0, plan) })
        XCTAssertEqual(try db.read { try EvidenceDocument.fetchOne($0, key: receipt)?.kind }, .other)
    }
}
