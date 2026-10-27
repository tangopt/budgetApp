import XCTest
import GRDB
@testable import BudgetCore
import BudgetDemo
@testable import MangoUI
import TestSupport

@MainActor
final class DocumentPanelModelTests: XCTestCase {
    private func demo() throws -> DatabaseQueue { try TestDatabase.demo() }

    private func utc(_ y: Int, _ m: Int, _ d: Int) -> Date {
        UKTaxYear.utcCalendar.date(from: DateComponents(year: y, month: m, day: d))!
    }

    private func insert(_ db: Database, name: String, kind: DocumentKind = .other, docDate: Date? = nil, periodStart: Date? = nil,
                        periodEnd: Date? = nil, amount: Int? = nil, currency: Currency? = nil, persons: [String] = []) throws -> Int64 {
        var document = EvidenceDocument(sha256: UUID().uuidString, storedRelativePath: "ab/\(name).pdf", originalFileName: "\(name).pdf",
                                        byteCount: 10, kind: kind, docDate: docDate, periodStart: periodStart, periodEnd: periodEnd,
                                        amountMinorUnits: amount, currency: currency, persons: persons, addedAt: utc(2026, 1, 1))
        try document.insert(db)
        return document.id!
    }

    func testDetailsOmitMissingFields() throws {
        let db = try TestDatabase.migrated()
        let id = try db.write { try self.insert($0, name: "bare") }
        let details = try db.read { try DocumentPanelDetails.load(db: $0, documentId: id) }
        XCTAssertEqual(details, DocumentPanelDetails(kind: DocumentKind.other.displayName, from: nil, period: nil, amount: nil, date: nil, linkedTo: nil))
        XCTAssertEqual(details.rows.map(\.label), ["Kind"])
    }

    func testAmountAndDateFormatted() throws {
        let db = try TestDatabase.migrated()
        let id = try db.write {
            try self.insert($0, name: "full", docDate: self.utc(2026, 3, 5), periodStart: self.utc(2026, 4, 6), periodEnd: self.utc(2026, 5, 5),
                            amount: 123_456, currency: .gbp, persons: ["Ana", "Rui"])
        }
        let eur = try db.write { try self.insert($0, name: "eur", amount: 5_000, currency: .eur) }
        let details = try db.read { try DocumentPanelDetails.load(db: $0, documentId: id) }
        XCTAssertEqual(details.amount, "£1,234.56")
        XCTAssertEqual(details.date, "5 Mar 2026".unbroken)
        XCTAssertEqual(details.period, "6 Apr 2026 – 5 May 2026".unbroken)
        XCTAssertEqual(details.from, "Ana, Rui")
        XCTAssertFalse(details.date!.contains(" "))
        XCTAssertFalse(details.period!.contains(" "))
        XCTAssertEqual(try db.read { try DocumentPanelDetails.load(db: $0, documentId: eur) }.amount, "€50.00")
        XCTAssertEqual(details.rows.map(\.label), ["Kind", "From", "Period", "Amount", "Date"])
    }

    func testLinkedToNamesTheOwner() async throws {
        let db = try demo()
        let (id, expected) = try await db.read { db -> (Int64, [String]) in
            for document in try EvidenceDocumentSummary.newestFirst.fetchAll(db) {
                let links = try EvidenceLinks.links(db: db, for: document.id)
                if !links.isEmpty {
                    return (document.id, try links.map { try EvidenceLinkTitles.line(db: db, entity: $0.entity).title })
                }
            }
            return (0, [])
        }
        XCTAssertNotEqual(id, 0, "the demo has a linked document")
        let details = try await db.read { try DocumentPanelDetails.load(db: $0, documentId: id) }
        XCTAssertEqual(details.linkedTo, expected.joined(separator: "\n"))
        let unlinked = try await db.read { try EvidenceLinks.unlinkedDocuments(db: $0) }.compactMap(\.id).first
        if let unlinked {
            let other = try await db.read { try DocumentPanelDetails.load(db: $0, documentId: unlinked) }
            XCTAssertNil(other.linkedTo)
        }
    }

    func testPanelWidthIs380InLandscapeAndPortrait() {
        // Detail-column widths: portrait without and with the sidebar, landscape on the 11" and the 13".
        for width in [514.0, 834.0, 874.0, 1056.0] {
            XCTAssertEqual(DocumentPanelLayout.panelWidth(containerWidth: width), 380)
            XCTAssertGreaterThanOrEqual(DocumentPanelLayout.contentWidth(containerWidth: width), 420)
        }
        XCTAssertEqual(DocumentPanelLayout.placement(containerWidth: 874), .beside)
        XCTAssertEqual(DocumentPanelLayout.placement(containerWidth: 834), .beside)
        XCTAssertEqual(DocumentPanelLayout.placement(containerWidth: 514), .overlay)
        XCTAssertEqual(DocumentPanelLayout.contentWidth(containerWidth: 874), 494)
    }
}
