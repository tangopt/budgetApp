import XCTest
import GRDB
@testable import BudgetCore

/// Custom document kinds (spec 2026-10-24 §2): a synced table of user kinds, a document's
/// `customKindId`, evidence rules that accept them, and the catalog code reads names from.
final class CustomDocumentKindTests: XCTestCase {
    private var manager: DatabaseManager!
    private var db: DatabaseQueue { manager.dbQueue }

    override func setUpWithError() throws {
        manager = try DatabaseManager(path: nil)
        try manager.migrate()
    }

    private func insertKind(_ name: String, _ area: DocumentArea, _ db: Database) throws -> Int64 {
        var kind = CustomDocumentKind(name: name, area: area, createdAt: Date(timeIntervalSince1970: 1_800_000_000))
        try kind.insert(db)
        return try XCTUnwrap(kind.id)
    }

    private func insertDocument(_ sha: String, customKindId: Int64?, _ db: Database) throws -> Int64 {
        var document = EvidenceDocument(sha256: sha, storedRelativePath: "\(sha)/\(sha).pdf", originalFileName: "\(sha).pdf", byteCount: 1,
                                        addedAt: Date(timeIntervalSince1970: 1_800_000_000))
        document.customKindId = customKindId
        try document.insert(db)
        return try XCTUnwrap(document.id)
    }

    func testAreasNameTheirLibraryFolders() {
        XCTAssertEqual(DocumentArea.allCases.map(\.libraryArea), ["Property", "Tax", "Bank", "Other"])
    }

    func testCatalogListsBuiltInsThenCustomByName() throws {
        let (boiler, alarm) = try db.write { db in
            (try insertKind("Boiler service", .property, db), try insertKind("Alarm contract", .other, db))
        }
        let catalog = try db.read { try DocumentKindCatalog.load(db: $0) }
        let builtIns = DocumentKind.allCases.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        XCTAssertEqual(catalog.all, builtIns.map(DocumentKindRef.builtIn) + [.custom(alarm), .custom(boiler)])
        XCTAssertEqual(catalog.displayName(.custom(boiler)), "Boiler service")
        XCTAssertEqual(catalog.displayName(.builtIn(.repairInvoice)), "Repair bill")
        XCTAssertEqual(catalog.libraryArea(.custom(boiler)), "Property")
        XCTAssertEqual(catalog.libraryArea(.custom(alarm)), "Other")
        XCTAssertEqual(catalog.libraryArea(.builtIn(.stampDuty)), "Tax PT")
        XCTAssertEqual(catalog.libraryArea(.builtIn(.bankStatement)), "Bank")
        // A kind that's gone reads as Other.
        XCTAssertEqual(catalog.displayName(.custom(9999)), "Other")
        XCTAssertEqual(catalog.libraryArea(.custom(9999)), "Other")
        // Found by name ignoring case and accents.
        XCTAssertEqual(catalog.custom(named: "BOILER SERVICE")?.id, boiler)
        XCTAssertEqual(catalog.custom(named: " Bóiler service ")?.id, boiler)
        XCTAssertNil(catalog.custom(named: "Boiler"))
    }

    func testDocumentKindRefOfADocument() throws {
        let (boiler, custom, plain) = try db.write { db -> (Int64, Int64, Int64) in
            let boiler = try insertKind("Boiler service", .property, db)
            return (boiler, try insertDocument("aa", customKindId: boiler, db), try insertDocument("bb", customKindId: nil, db))
        }
        try db.read { db in
            let document = try XCTUnwrap(try EvidenceDocument.fetchOne(db, key: custom))
            XCTAssertEqual(document.customKindId, boiler)
            XCTAssertEqual(document.kind, .other)
            XCTAssertEqual(document.kindRef, .custom(boiler))
            XCTAssertEqual(try EvidenceDocument.fetchOne(db, key: plain)?.kindRef, .builtIn(.other))
            let summary = try XCTUnwrap(try EvidenceDocumentSummary.fetchOne(db, key: custom))
            XCTAssertEqual(summary.customKindId, boiler)
            XCTAssertEqual(summary.kindRef, .custom(boiler))
            XCTAssertEqual(try EvidenceDocumentSummary.fetchOne(db, key: plain)?.kindRef, .builtIn(.other))
        }
    }

    func testRequirementAcceptsCustomKinds() throws {
        let customOnly = EvidenceRequirement(name: "Boiler", scope: .transactionsInCategory(categoryId: 1), kinds: [], customKindIds: [7])
        XCTAssertTrue(customOnly.accepts(.custom(7)))
        XCTAssertFalse(customOnly.accepts(.custom(8)))
        XCTAssertFalse(customOnly.accepts(.builtIn(.other)))
        XCTAssertFalse(customOnly.accepts(.builtIn(.repairInvoice)))
        let mixed = EvidenceRequirement(name: "Repairs", scope: .transactionsInCategory(categoryId: 1), kinds: [.repairInvoice], customKindIds: [7])
        XCTAssertTrue(mixed.accepts(.builtIn(.repairInvoice)))
        XCTAssertTrue(mixed.accepts(.custom(7)))
        XCTAssertFalse(mixed.accepts(.builtIn(.utilityInvoice)))
        let any = EvidenceRequirement(name: "Any", scope: .transactionsInCategory(categoryId: 1), kinds: [])
        XCTAssertEqual(any.customKindIds, [])
        XCTAssertTrue(any.accepts(.custom(7)))
        XCTAssertTrue(any.accepts(.builtIn(.other)))
        XCTAssertTrue(any.accepts(.p60))
        // Stored and read back.
        let id = try db.write { db -> Int64 in
            var stored = mixed
            try stored.insert(db)
            return try XCTUnwrap(stored.id)
        }
        try db.read { db in
            XCTAssertEqual(try EvidenceRequirement.fetchOne(db, key: id)?.customKindIds, [7])
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT customKindIds FROM evidenceRequirement WHERE id = ?", arguments: [id]), "[7]")
        }
    }

    func testNameIsUniqueIgnoringCase() throws {
        try db.write { db in _ = try insertKind("Boiler service", .property, db) }
        XCTAssertThrowsError(try db.write { db in _ = try insertKind("boiler service", .other, db) })
    }

    /// A document's custom kind and an evidence rule's custom kinds name the kind on the other device by its
    /// UUID; the same name made on both devices is one kind.
    func testCustomKindsSyncByIdentity() throws {
        let a = try SyncTestDevice("user-a"), b = try SyncTestDevice("user-b")
        let (boilerA, documentA, requirementA) = try a.queue.write { db -> (Int64, Int64, Int64) in
            let boiler = try insertKind("Boiler service", .property, db)
            let document = try insertDocument("aa", customKindId: boiler, db)
            var requirement = EvidenceRequirement(name: "Boiler", scope: .transactionsMatching(categoryIds: [], accountIds: [], descriptionContains: "boiler"),
                                                  kinds: [], customKindIds: [boiler],
                                                  createdAt: Date(timeIntervalSince1970: 1_800_000_000))
            try requirement.insert(db)
            return (boiler, document, requirement.id!)
        }
        // B already has other kinds, and the same one under another case: its local ids differ.
        let boilerB = try b.queue.write { db -> Int64 in
            _ = try insertKind("Alarm contract", .other, db)
            _ = try insertKind("Gas check", .property, db)
            return try insertKind("BOILER SERVICE", .property, db)
        }
        XCTAssertNotEqual(boilerA, boilerB)
        try b.receive(try a.push())
        let documentB = try XCTUnwrap(try b.localId("document", try a.uuid("document", documentA)))
        let requirementB = try XCTUnwrap(try b.localId("evidenceRequirement", try a.uuid("evidenceRequirement", requirementA)))
        try b.queue.read { db in
            XCTAssertEqual(try CustomDocumentKind.fetchCount(db), 3, "the same name is the same kind")
            XCTAssertEqual(try EvidenceDocument.fetchOne(db, key: documentB)?.kindRef, .custom(boilerB))
            XCTAssertEqual(try EvidenceRequirement.fetchOne(db, key: requirementB)?.customKindIds, [boilerB])
        }
    }

    func testMergedOrDeletedKindLeavesDocumentsAsOther() throws {
        let document = try db.write { db -> Int64 in
            let boiler = try insertKind("Boiler service", .property, db)
            let document = try insertDocument("aa", customKindId: boiler, db)
            _ = try CustomDocumentKind.deleteOne(db, key: boiler)
            return document
        }
        try db.read { db in
            let stored = try XCTUnwrap(try EvidenceDocument.fetchOne(db, key: document))
            XCTAssertNil(stored.customKindId)
            XCTAssertEqual(stored.kindRef, .builtIn(.other))
        }
    }
}
