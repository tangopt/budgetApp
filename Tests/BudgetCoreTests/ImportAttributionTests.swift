import XCTest
import GRDB
@testable import BudgetCore

/// Step 1 Task 4: an import run records who confirmed it, a learnt import rule who taught it and
/// who last re-taught it. Synthetic users only.
final class ImportAttributionTests: XCTestCase {
    private var manager: DatabaseManager!
    private var db: DatabaseQueue { manager.dbQueue }
    private var folder: URL!
    private var library: EvidenceLibrary!
    private var applier: ImportApplier!
    private var userA: Int64!
    private var userB: Int64!

    override func setUpWithError() throws {
        manager = try DatabaseManager(path: nil)
        try manager.migrate()
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("ImportAttributionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        library = EvidenceLibrary(root: folder.appendingPathComponent("Library", isDirectory: true), database: db)
        applier = ImportApplier(dbQueue: db, databasePath: nil, library: library)
        (userA, userB) = try db.write { db in
            var ids: [Int64] = []
            for name in ["User A", "User B"] {
                var person = Person(name: name, shortName: String(name.suffix(1)))
                try People.save(db: db, &person)
                var user = AppUser(personId: person.id!, displayName: name, createdAt: Date())
                try user.insert(db)
                ids.append(user.id!)
            }
            return (ids[0], ids[1])
        }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func documentItem(_ name: String, drafts: [ImportRuleDraft] = []) throws -> ImportItem {
        let directory = folder.appendingPathComponent("Drop", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try Data("Synthetic words only \(name)".utf8).write(to: url)
        var item = ImportItem(file: try ImportFile.load(url, ocr: false),
                              recognition: ImportRecognition(kind: .evidence(.other), confidence: .certain, reason: "test"),
                              title: name, placement: ImportPlacement(metadata: EvidenceMetadata(kind: .other), canonicalName: name),
                              effect: .file, groupKey: "Other documents")
        item.ruleDrafts = drafts
        return item
    }

    private func plan(_ items: [ImportItem]) -> ImportPlan {
        ImportPlan(items: items)
    }

    private func draft(_ kind: DocumentKind = .insuranceReceipt) -> ImportRuleDraft {
        ImportRuleDraft(kind: .documentKind, key: "nif:503504564", matchLabel: "Example Seguros",
                        actionJSON: "{\"kind\":\"\(kind.rawValue)\"}", actionLabel: "Kind: \(kind.displayName)")
    }

    private func run(_ id: Int64) throws -> ImportRun {
        try XCTUnwrap(try db.read { db in try ImportRun.fetchOne(db, key: id) })
    }

    private func onlyRule() throws -> ImportRule {
        try XCTUnwrap(try db.read { db in try ImportRule.fetchAll(db).first })
    }

    func testRunRecordsConfirmingUser() throws {
        let summary = try applier.apply(plan([try documentItem("a.txt")]), entryPoint: "Import…", confirmedBy: userA)
        XCTAssertEqual(try run(summary.runId).appUserId, userA)
    }

    func testConfirmRecordsUserAtConfirmTime() throws {
        // One review, planned once; whoever is signed in when Confirm is pressed is recorded.
        let reviewed = plan([try documentItem("a.txt")])
        let first = try applier.apply(reviewed, entryPoint: "Import…", confirmedBy: userA)
        try db.write { db in try db.execute(sql: "DELETE FROM document") }
        let second = try applier.apply(reviewed, entryPoint: "Import…", confirmedBy: userB)
        XCTAssertEqual(try run(first.runId).appUserId, userA)
        XCTAssertEqual(try run(second.runId).appUserId, userB)
    }

    func testRuleCreatedAndRelearntBy() throws {
        try db.write { db in
            try ImportRuleStore.learn(db: db, kind: .documentKind, key: "k", matchLabel: "L",
                                      action: DocumentKindAction(kind: .insuranceReceipt), actionLabel: "Kind", now: Date(), by: userA)
        }
        var rule = try onlyRule()
        XCTAssertEqual(rule.createdByAppUserId, userA)
        XCTAssertEqual(rule.lastLearntByAppUserId, userA)
        try db.write { db in
            try ImportRuleStore.learn(db: db, kind: .documentKind, key: "k", matchLabel: "L",
                                      action: DocumentKindAction(kind: .insurancePolicy), actionLabel: "Kind 2", now: Date(), by: userB)
        }
        rule = try onlyRule()
        XCTAssertEqual(rule.createdByAppUserId, userA, "the teacher stays")
        XCTAssertEqual(rule.lastLearntByAppUserId, userB)
        XCTAssertEqual(try db.read { try ImportRule.fetchCount($0) }, 1)
    }

    func testRulesLearntInARunCarryTheConfirmingUser() throws {
        _ = try applier.apply(plan([try documentItem("a.txt", drafts: [draft()])]), entryPoint: "Import…", confirmedBy: userB)
        let rule = try onlyRule()
        XCTAssertEqual(rule.createdByAppUserId, userB)
        XCTAssertEqual(rule.lastLearntByAppUserId, userB)
    }

    func testUndoOfRunThatLearntRuleStillWorks() throws {
        let summary = try applier.apply(plan([try documentItem("a.txt", drafts: [draft()])]), entryPoint: "Import…", confirmedBy: userA)
        // Someone else re-teaches the same action: only the attribution changes.
        try db.write { db in
            try ImportRuleStore.learn(db: db, kind: .documentKind, key: "nif:503504564", matchLabel: "Example Seguros",
                                      actionJSON: "{\"kind\":\"\(DocumentKind.insuranceReceipt.rawValue)\"}",
                                      actionLabel: "Kind: \(DocumentKind.insuranceReceipt.displayName)", now: Date(), by: userB)
        }
        XCTAssertEqual(try onlyRule().lastLearntByAppUserId, userB)
        let result = try ImportUndo.undo(dbQueue: db, library: library, runId: summary.runId)
        XCTAssertEqual(result.notes, [])
        XCTAssertEqual(try db.read { try ImportRule.fetchCount($0) }, 0, "removed: attribution is not content")
    }

    func testUndoKeepsARuleWhoseContentChangedSince() throws {
        let summary = try applier.apply(plan([try documentItem("a.txt", drafts: [draft()])]), entryPoint: "Import…", confirmedBy: userA)
        try db.write { db in
            try ImportRuleStore.learn(db: db, kind: .documentKind, key: "nif:503504564", matchLabel: "Example Seguros",
                                      actionJSON: "{\"kind\":\"\(DocumentKind.utilityInvoice.rawValue)\"}",
                                      actionLabel: "Kind: \(DocumentKind.utilityInvoice.displayName)", now: Date(), by: userB)
        }
        let result = try ImportUndo.undo(dbQueue: db, library: library, runId: summary.runId)
        XCTAssertEqual(result.notes.count, 1)
        XCTAssertTrue(result.notes[0].contains("changed since this import"))
        XCTAssertEqual(try db.read { try ImportRule.fetchCount($0) }, 1)
    }

    func testNilAttributionForTools() throws {
        let summary = try applier.apply(plan([try documentItem("a.txt", drafts: [draft()])]), entryPoint: "Import…")
        XCTAssertNil(try run(summary.runId).appUserId)
        let rule = try onlyRule()
        XCTAssertNil(rule.createdByAppUserId)
        XCTAssertNil(rule.lastLearntByAppUserId)
    }

    func testMarkUsedSetsNoAttribution() throws {
        let rule = try db.write { db in
            try ImportRuleStore.learn(db: db, kind: .documentKind, key: "k", matchLabel: "L",
                                      action: DocumentKindAction(kind: .insuranceReceipt), actionLabel: "Kind", now: Date(), by: userA)
        }
        try db.write { db in try ImportRuleStore.markUsed(db: db, ids: [rule.id!], now: Date()) }
        let used = try onlyRule()
        XCTAssertEqual(used.useCount, 1)
        XCTAssertEqual(used.createdByAppUserId, userA)
        XCTAssertEqual(used.lastLearntByAppUserId, userA)
    }

    func testRuleRowsNameTheUsers() throws {
        try db.write { db in
            try ImportRuleStore.learn(db: db, kind: .documentKind, key: "k", matchLabel: "L",
                                      action: DocumentKindAction(kind: .insuranceReceipt), actionLabel: "Kind", now: Date(), by: userA)
            try ImportRuleStore.learn(db: db, kind: .documentKind, key: "k", matchLabel: "L",
                                      action: DocumentKindAction(kind: .insurancePolicy), actionLabel: "Kind 2", now: Date(), by: userB)
        }
        let row = try XCTUnwrap(try db.read { try ImportRuleEditing.rows(db: $0) }.first)
        XCTAssertEqual(row.createdByName, "User A")
        XCTAssertEqual(row.lastLearntByName, "User B")
    }

    func testReLearnWithNoUserKeepsTheLastLearner() throws {
        try db.write { db in
            try ImportRuleStore.learn(db: db, kind: .documentKind, key: "k", matchLabel: "L",
                                      action: DocumentKindAction(kind: .insuranceReceipt), actionLabel: "Kind", now: Date(), by: userA)
            try ImportRuleStore.learn(db: db, kind: .documentKind, key: "k", matchLabel: "L",
                                      action: DocumentKindAction(kind: .insurancePolicy), actionLabel: "Kind 2", now: Date())
        }
        let rule = try onlyRule()
        XCTAssertEqual(rule.actionLabel, "Kind 2")
        XCTAssertEqual(rule.lastLearntByAppUserId, userA)
    }

    func testAttributionLabelComparesIdsNotNames() {
        func row(_ c: (String, Int64)?, _ l: (String, Int64)?) -> ImportRuleRow {
            ImportRuleRow(id: 1, kind: .documentKind, kindLabel: "", when: "", then: "", useCount: 0, lastUsedAt: nil,
                          isEnabled: true, targetMissing: false, createdByName: c?.0, lastLearntByName: l?.0,
                          createdByAppUserId: c?.1, lastLearntByAppUserId: l?.1)
        }
        XCTAssertEqual(row(("Sam", 1), ("Sam", 1)).attributionLabel, "Learnt from Sam's correction")
        XCTAssertEqual(row(("Sam", 1), ("Sam", 2)).attributionLabel, "Learnt from Sam's correction · updated by Sam",
                       "same name, different users")
        XCTAssertEqual(row(("Sam", 1), ("Kim", 2)).attributionLabel, "Learnt from Sam's correction · updated by Kim")
        XCTAssertEqual(row(nil, ("Kim", 2)).attributionLabel, "Updated by Kim")
        XCTAssertNil(row(nil, nil).attributionLabel)
    }
}
