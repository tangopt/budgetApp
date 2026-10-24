import XCTest
import GRDB
@testable import BudgetCore

/// The Kinds sheet (spec 2026-10-24 §2): custom kinds listed with their document counts, renames
/// and merges staged in a draft (nothing written) and checked as Save will check them, then
/// applied together by `CustomDocumentKinds.save`. Synthetic data only.
final class CustomKindsDraftTests: XCTestCase {
    private var manager: DatabaseManager!
    private var db: DatabaseQueue { manager.dbQueue }
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUpWithError() throws {
        manager = try DatabaseManager(path: nil)
        try manager.migrate()
    }

    private func create(_ name: String, _ area: DocumentArea) throws -> Int64 {
        try XCTUnwrap(try db.write { db in try CustomDocumentKinds.create(db: db, name: name, area: area, now: now) }.id)
    }

    private func document(_ sha: String, customKindId: Int64?) throws {
        try db.write { db in
            var document = EvidenceDocument(sha256: sha, storedRelativePath: "\(sha)/\(sha).pdf", originalFileName: "\(sha).pdf", byteCount: 1,
                                            canonicalName: nil, kind: .other, addedAt: now, customKindId: customKindId)
            try document.insert(db)
        }
    }

    private func draft() throws -> CustomKindsDraft {
        CustomKindsDraft(rows: try db.read { db in try CustomDocumentKinds.rows(db: db) })
    }

    func testRowsListCustomKindsByNameWithTheirDocumentCounts() throws {
        let lift = try create("Lift service", .property)
        let boiler = try create("Boiler service", .property)
        let fees = try create("Club fees", .other)
        try document("a", customKindId: boiler)
        try document("b", customKindId: boiler)
        try document("c", customKindId: lift)
        try document("d", customKindId: nil)
        // A kind merged into a built-in (retired) isn't listed.
        _ = try db.write { db in try CustomDocumentKinds.save(db: db, edits: [KindEdit(kindId: fees, change: .merge(into: .builtIn(.other)))]) }

        let rows = try db.read { db in try CustomDocumentKinds.rows(db: db) }
        XCTAssertEqual(rows, [CustomKindRow(id: boiler, name: "Boiler service", area: .property, documents: 2),
                              CustomKindRow(id: lift, name: "Lift service", area: .property, documents: 1)])
    }

    func testRenamesAndMergesAreStagedAndCheckedLikeSave() throws {
        let boiler = try create("Boiler service", .property)
        let lift = try create("Lift service", .property)
        var draft = try draft()
        XCTAssertFalse(draft.hasChanges)
        XCTAssertNil(draft.problem)

        // A rename back to what it was is no change.
        draft.rename(boiler, name: "Boiler check", area: .property)
        XCTAssertTrue(draft.hasChanges)
        draft.rename(boiler, name: " Boiler service ", area: .property)
        XCTAssertFalse(draft.hasChanges)

        // Taken names are said before Save, as Save says them.
        draft.rename(boiler, name: "repair bill", area: .property)
        XCTAssertEqual(draft.problem, "There's already a kind called \u{201C}Repair bill\u{201D}.")
        XCTAssertFalse(draft.canSave)
        draft.rename(boiler, name: "lift SERVICE", area: .property)
        XCTAssertEqual(draft.problem, "There's already a kind called \u{201C}Lift service\u{201D}.")
        draft.rename(boiler, name: "  ", area: .property)
        XCTAssertEqual(draft.problem, "Give the kind a name.")
        // A swap is fine.
        draft.rename(boiler, name: "Lift service", area: .property)
        draft.rename(lift, name: "Boiler service", area: .tax)
        XCTAssertNil(draft.problem)
        XCTAssertTrue(draft.canSave)
        XCTAssertEqual(draft.name(of: lift), "Boiler service")
        XCTAssertEqual(draft.area(of: lift), .tax)

        // A merge replaces the kind's rename; its name is free again.
        draft.merge(boiler, into: .builtIn(.repairInvoice))
        XCTAssertEqual(draft.mergeTarget(of: boiler), .builtIn(.repairInvoice))
        XCTAssertEqual(draft.name(of: boiler), "Boiler service", "a merged kind shows its own name")
        XCTAssertEqual(draft.status(of: boiler), "Merges into Repair bill")
        XCTAssertEqual(draft.status(of: lift), "Renamed from Lift service")
        XCTAssertEqual(draft.edits, [KindEdit(kindId: boiler, change: .merge(into: .builtIn(.repairInvoice))),
                                     KindEdit(kindId: lift, change: .rename(name: "Boiler service", area: .tax))])

        // Merge targets: built-ins by name, then the other custom kinds not merged away (by their staged name).
        let targets = draft.mergeTargets(for: lift)
        XCTAssertEqual(targets.first?.label, DocumentKind.allCases.map(\.displayName).sorted { $0.localizedStandardCompare($1) == .orderedAscending }.first)
        XCTAssertFalse(targets.contains { $0.ref == .custom(lift) }, "never itself")
        XCTAssertFalse(targets.contains { $0.ref == .custom(boiler) }, "nor a kind merged away")
        XCTAssertTrue(draft.mergeTargets(for: boiler).contains { $0.ref == .custom(lift) && $0.label == "Boiler service" })

        // Revert drops a kind's change.
        draft.revert(boiler)
        XCTAssertNil(draft.mergeTarget(of: boiler))
        XCTAssertEqual(draft.edits.map(\.kindId), [lift])
        // Merging into each other is refused as Save refuses it.
        draft.revert(lift)
        draft.merge(boiler, into: .custom(lift))
        draft.merge(lift, into: .custom(boiler))
        XCTAssertEqual(draft.problem, "A kind can't be merged into itself.")
    }

    func testTheDraftSavesInOneWrite() throws {
        let boiler = try create("Boiler service", .property)
        let lift = try create("Lift service", .property)
        try document("a", customKindId: boiler)
        var draft = try draft()
        draft.rename(lift, name: "Lift check", area: .property)
        draft.merge(boiler, into: .custom(lift))
        let result = try db.write { db in try CustomDocumentKinds.save(db: db, edits: draft.edits) }
        XCTAssertEqual(try db.read { db in try CustomDocumentKinds.rows(db: db) },
                       [CustomKindRow(id: lift, name: "Lift check", area: .property, documents: 1)])
        XCTAssertEqual(CustomKindsDraft.savedMessage(result), "Saved. 1 document changed.")
        XCTAssertEqual(CustomKindsDraft.savedMessage(KindSaveResult(documentsChanged: 3, rulesChanged: 1, requirementsChanged: 2)),
                       "Saved. 3 documents, 1 learnt rule and 2 evidence rules changed.")
        XCTAssertEqual(CustomKindsDraft.savedMessage(KindSaveResult()), "Saved.")
    }
}
