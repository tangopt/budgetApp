import XCTest
import GRDB
@testable import BudgetCore
import BudgetDemo
@testable import MangoUI
import TestSupport

@MainActor
final class PadDocumentsTests: XCTestCase {
    private func demo() throws -> DatabaseQueue {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("pad-docs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("demo.sqlite").path
        try DemoDatabase.build(at: path, evidenceRoot: folder.appendingPathComponent("Evidence"))
        return try DatabaseQueue(path: path)
    }

    func testUnlinkedFilterMatchesEvidenceLinks() async throws {
        let db = try demo()
        let model = PadDocumentsModel(dbQueue: db)
        await model.reload()
        model.filter = .unlinked
        // Unlinked leaves out the documents waiting for their payment (they have their own chip).
        let now = Date()
        let (unlinked, waiting) = try await db.read { db in
            (Set(try EvidenceLinks.unlinkedDocuments(db: db).compactMap(\.id)),
             Set(try WaitingDocuments.states(db: db, now: now).filter { $0.value == .waiting }.keys))
        }
        let expected = unlinked.subtracting(waiting)
        XCTAssertEqual(Set(model.groups.flatMap(\.documents).map(\.id)), expected)
        model.filter = .all
        XCTAssertEqual(model.groups.flatMap(\.documents).count, model.all.count)
        XCTAssertFalse(model.all.isEmpty)
    }

    func testWaitingChipListsOnlyWaiting() async throws {
        let db = try demo()
        let day = Calendar.current.date(byAdding: .day, value: -3, to: Date())!
        let waiting = try await db.write { db -> Int64 in
            var bill = EvidenceDocument(sha256: UUID().uuidString, storedRelativePath: "x/w.pdf", originalFileName: "Example Power.pdf",
                                        byteCount: 1, kind: .utilityInvoice, docDate: day, amountMinorUnits: 6_000, currency: .eur, addedAt: day)
            try bill.insert(db)
            return bill.id!
        }
        let model = PadDocumentsModel(dbQueue: db)
        await model.reload()
        model.filter = .waiting
        let listed = model.groups.flatMap(\.documents).map(\.id)
        XCTAssertTrue(listed.contains(waiting))
        let now = Date()
        let states = try await db.read { try WaitingDocuments.states(db: $0, now: now) }
        XCTAssertTrue(listed.allSatisfy { states[$0] == .waiting }, "only waiting documents")
        model.filter = .unlinked
        XCTAssertFalse(model.groups.flatMap(\.documents).map(\.id).contains(waiting), "Unlinked leaves the waiting ones out")
        XCTAssertEqual(PadDocumentsModel.Filter.waiting.rawValue, "Waiting")
    }

    func testGroupsByCatalogKindTitle() async throws {
        let db = try demo()
        let model = PadDocumentsModel(dbQueue: db)
        await model.reload()
        let catalog = model.catalog
        for group in model.groups {
            XCTAssertTrue(group.documents.allSatisfy { catalog.displayName(of: $0) == group.title })
        }
        let titles = model.groups.map(\.title)
        XCTAssertEqual(titles, titles.sorted { $0.localizedStandardCompare($1) == .orderedAscending })
    }

    func testOpenFailureShowsCopy() async throws {
        struct Offline: Error {}
        let db = try demo()
        let model = PadDocumentsModel(dbQueue: db, open: { _ in throw Offline() })
        await model.reload()
        model.selectedId = model.all.first?.id
        await model.openPreview()
        XCTAssertEqual(model.preview, .failed("Couldn't download this document. Try again when you're online."))
        XCTAssertEqual(PadDocumentsModel.downloadingCopy, "Downloading…")
        // The default hook: not downloaded here yet.
        let bare = PadDocumentsModel(dbQueue: db)
        await bare.reload()
        bare.selectedId = bare.all.first?.id
        await bare.openPreview()
        XCTAssertEqual(bare.preview, .failed("Not on this iPad yet"))
    }
}
