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
        let expected = Set(try await db.read { try EvidenceLinks.unlinkedDocuments(db: $0) }.compactMap(\.id))
        XCTAssertEqual(Set(model.groups.flatMap(\.documents).map(\.id)), expected)
        model.filter = .all
        XCTAssertEqual(model.groups.flatMap(\.documents).count, model.all.count)
        XCTAssertFalse(model.all.isEmpty)
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
