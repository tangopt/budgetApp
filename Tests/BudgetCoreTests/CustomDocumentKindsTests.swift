import XCTest
import GRDB
@testable import BudgetCore

/// Creating, renaming and merging custom kinds (spec 2026-10-24 §2): names unique against
/// built-ins and other custom kinds, and a Save that carries documents' canonical names,
/// learnt rules and evidence rules along, in one write.
final class CustomDocumentKindsTests: XCTestCase {
    private var manager: DatabaseManager!
    private var db: DatabaseQueue { manager.dbQueue }
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUpWithError() throws {
        manager = try DatabaseManager(path: nil)
        try manager.migrate()
    }

    private func create(_ name: String, _ area: DocumentArea) throws -> Int64 {
        let kind = try db.write { db in try CustomDocumentKinds.create(db: db, name: name, area: area, now: now) }
        return try XCTUnwrap(kind.id)
    }

    private func document(_ sha: String, name: String, kind: DocumentKind = .other, customKindId: Int64?) throws -> Int64 {
        try db.write { db in
            var document = EvidenceDocument(sha256: sha, storedRelativePath: "\(sha)/\(sha).pdf", originalFileName: "\(sha).pdf", byteCount: 1,
                                            canonicalName: name, kind: kind, addedAt: now, customKindId: customKindId)
            try document.insert(db)
            return try XCTUnwrap(document.id)
        }
    }

    private func kindRule(_ key: String, _ action: DocumentKindAction, label: String) throws -> Int64 {
        try db.write { db in
            var rule = ImportRule(kind: .documentKind, matchKey: key, matchLabel: "Issuer \(key)",
                                  actionJSON: try XCTUnwrap(ImportLearning.encode(action)), actionLabel: label, createdAt: now)
            try rule.insert(db)
            return try XCTUnwrap(rule.id)
        }
    }

    private func requirement(_ name: String, kinds: [DocumentKind], customKindIds: [Int64]) throws -> Int64 {
        try db.write { db in
            var requirement = EvidenceRequirement(name: name, scope: .transactionsMatching(categoryIds: [], accountIds: [], descriptionContains: name),
                                                  kinds: kinds, customKindIds: customKindIds, createdAt: now)
            try EvidenceRequirements.save(db: db, &requirement)
            return try XCTUnwrap(requirement.id)
        }
    }

    private func save(_ edits: [KindEdit]) throws -> KindSaveResult {
        try db.write { db in try CustomDocumentKinds.save(db: db, edits: edits) }
    }

    private func storedDocument(_ id: Int64) throws -> EvidenceDocument {
        try XCTUnwrap(try db.read { try EvidenceDocument.fetchOne($0, key: id) })
    }

    private func storedRule(_ id: Int64) throws -> (action: DocumentKindAction, label: String) {
        let rule = try XCTUnwrap(try db.read { try ImportRule.fetchOne($0, key: id) })
        return (try XCTUnwrap(ImportLearning.decode(DocumentKindAction.self, rule.actionJSON)), rule.actionLabel)
    }

    private func storedRequirement(_ id: Int64) throws -> EvidenceRequirement {
        try XCTUnwrap(try db.read { try EvidenceRequirement.fetchOne($0, key: id) })
    }

    // MARK: Create

    func testCreateRefusesBuiltInAndCustomNames() throws {
        let boiler = try create("  Boiler service ", .property)
        XCTAssertEqual(try db.read { try CustomDocumentKind.fetchOne($0, key: boiler)?.name }, "Boiler service", "trimmed")
        XCTAssertThrowsError(try create("repair bill", .property)) { XCTAssertEqual($0 as? CustomDocumentKinds.Failure, .nameTaken("Repair bill")) }
        XCTAssertThrowsError(try create("Bóiler SERVICE", .other)) { XCTAssertEqual($0 as? CustomDocumentKinds.Failure, .nameTaken("Boiler service")) }
        XCTAssertThrowsError(try create("   ", .other)) { XCTAssertEqual($0 as? CustomDocumentKinds.Failure, .emptyName) }
        XCTAssertEqual(try db.read { try CustomDocumentKind.fetchCount($0) }, 1)
    }

    // MARK: Rename

    func testRenameRewritesCanonicalNamesAndRuleLabels() throws {
        let boiler = try create("Boiler service", .property)
        let other = try create("Alarm contract", .other)
        let named = try document("aa", name: "20230305 - Property - Boiler service - Caldeiras Lda - €80.00", customKindId: boiler)
        let edited = try document("bb", name: "My own name for it", customKindId: boiler)
        let untouched = try document("cc", name: "20230306 - Other - Alarm contract", customKindId: other)
        let rule = try kindRule("issuer-1", DocumentKindAction(kind: .other, customKindId: boiler), label: "Kind: Boiler service")
        let otherRule = try kindRule("issuer-2", DocumentKindAction(kind: .p60), label: "Kind: P60")

        let result = try save([KindEdit(kindId: boiler, change: .rename(name: "Boiler check", area: .other))])
        XCTAssertEqual(result, KindSaveResult(documentsChanged: 1, rulesChanged: 1, requirementsChanged: 0))
        let kind = try XCTUnwrap(try db.read { try CustomDocumentKind.fetchOne($0, key: boiler) })
        XCTAssertEqual(kind.name, "Boiler check")
        XCTAssertEqual(kind.area, .other)
        XCTAssertEqual(try storedDocument(named).canonicalName, "20230305 - Other - Boiler check - Caldeiras Lda - €80.00")
        XCTAssertEqual(try storedDocument(named).kindRef, .custom(boiler))
        XCTAssertEqual(try storedDocument(edited).canonicalName, "My own name for it", "a name the user changed is left alone")
        XCTAssertEqual(try storedDocument(untouched).canonicalName, "20230306 - Other - Alarm contract")
        XCTAssertEqual(try storedRule(rule).label, "Kind: Boiler check")
        XCTAssertEqual(try storedRule(rule).action, DocumentKindAction(kind: .other, customKindId: boiler))
        XCTAssertEqual(try storedRule(otherRule).label, "Kind: P60")
    }

    func testRenameRefusesTakenNamesButAllowsASwapAndACaseChange() throws {
        let boiler = try create("Boiler service", .property)
        let alarm = try create("Alarm contract", .other)
        XCTAssertThrowsError(try save([KindEdit(kindId: boiler, change: .rename(name: "Stamp DUTY", area: .tax))])) {
            XCTAssertEqual($0 as? CustomDocumentKinds.Failure, .nameTaken("Stamp duty"))
        }
        XCTAssertThrowsError(try save([KindEdit(kindId: boiler, change: .rename(name: "alarm contract", area: .tax))])) {
            XCTAssertEqual($0 as? CustomDocumentKinds.Failure, .nameTaken("Alarm contract"))
        }
        XCTAssertThrowsError(try save([KindEdit(kindId: boiler, change: .rename(name: " ", area: .tax))])) {
            XCTAssertEqual($0 as? CustomDocumentKinds.Failure, .emptyName)
        }
        XCTAssertThrowsError(try save([KindEdit(kindId: 999, change: .rename(name: "Gone", area: .tax))])) {
            XCTAssertEqual($0 as? CustomDocumentKinds.Failure, .notFound(999))
        }
        // Two names swapped in one Save, and a change of case only.
        _ = try save([KindEdit(kindId: boiler, change: .rename(name: "Alarm contract", area: .other)),
                      KindEdit(kindId: alarm, change: .rename(name: "Boiler service", area: .property))])
        _ = try save([KindEdit(kindId: boiler, change: .rename(name: "ALARM contract", area: .other))])
        let names = try db.read { db in try CustomDocumentKind.fetchAll(db).map { "\($0.id!) \($0.name)" } }
        XCTAssertEqual(Set(names), ["\(boiler) ALARM contract", "\(alarm) Boiler service"])
        // A name freed by a kind merged in the same Save can be taken.
        _ = try save([KindEdit(kindId: alarm, change: .merge(into: .builtIn(.repairInvoice))),
                      KindEdit(kindId: boiler, change: .rename(name: "Boiler service", area: .property))])
        XCTAssertEqual(try db.read { try CustomDocumentKind.fetchAll($0).map(\.name) }, ["Boiler service"])
    }

    // MARK: Merge

    func testMergeRepointsDocumentsRulesAndRequirements() throws {
        let boiler = try create("Boiler service", .property)
        let filed = try document("aa", name: "20230305 - Property - Boiler service - Caldeiras Lda", customKindId: boiler)
        let rule = try kindRule("issuer-1", DocumentKindAction(kind: .other, customKindId: boiler), label: "Kind: Boiler service")
        let onlyCustom = try requirement("Boiler", kinds: [], customKindIds: [boiler])
        let alreadyHasTarget = try requirement("Repairs", kinds: [.repairInvoice, .other], customKindIds: [boiler])
        let unrelated = try requirement("IMI", kinds: [.imiNotice], customKindIds: [])

        let result = try save([KindEdit(kindId: boiler, change: .merge(into: .builtIn(.repairInvoice)))])
        XCTAssertEqual(result, KindSaveResult(documentsChanged: 1, rulesChanged: 1, requirementsChanged: 2))
        let document = try storedDocument(filed)
        XCTAssertEqual(document.kind, .repairInvoice)
        XCTAssertNil(document.customKindId)
        XCTAssertEqual(document.canonicalName, "20230305 - Property - Repair bill - Caldeiras Lda")
        XCTAssertEqual(try storedRule(rule).action, DocumentKindAction(kind: .repairInvoice))
        XCTAssertEqual(try storedRule(rule).label, "Kind: Repair bill")
        XCTAssertEqual(try storedRequirement(onlyCustom).kinds, [.repairInvoice])
        XCTAssertEqual(try storedRequirement(onlyCustom).customKindIds, [])
        XCTAssertEqual(try storedRequirement(alreadyHasTarget).kinds, [.repairInvoice, .other], "no duplicates")
        XCTAssertEqual(try storedRequirement(alreadyHasTarget).customKindIds, [])
        XCTAssertEqual(try storedRequirement(unrelated).kinds, [.imiNotice])
        XCTAssertNil(try db.read { try CustomDocumentKind.fetchOne($0, key: boiler) }, "the merged kind is gone")
        // The learnt rule's action no longer names the custom kind at all.
        let json = try XCTUnwrap(try db.read { try ImportRule.fetchOne($0, key: rule)?.actionJSON })
        XCTAssertFalse(json.contains("customKindId"), json)
    }

    func testMergeIntoAnotherCustomKind() throws {
        let boiler = try create("Boiler service", .property)
        let check = try create("Gas check", .property)
        let alarm = try create("Alarm contract", .other)
        let filed = try document("aa", name: "20230305 - Property - Boiler service", customKindId: boiler)
        let rule = try kindRule("issuer-1", DocumentKindAction(kind: .other, customKindId: boiler), label: "Kind: Boiler service")
        let both = try requirement("Boiler", kinds: [.repairInvoice], customKindIds: [boiler, check])
        let one = try requirement("Boiler 2", kinds: [], customKindIds: [boiler])

        // Merged into a kind renamed in the same Save: the new name is used everywhere.
        let result = try save([KindEdit(kindId: boiler, change: .merge(into: .custom(check))),
                               KindEdit(kindId: check, change: .rename(name: "Heating", area: .property))])
        XCTAssertEqual(result, KindSaveResult(documentsChanged: 1, rulesChanged: 1, requirementsChanged: 2))
        XCTAssertEqual(try storedDocument(filed).kindRef, .custom(check))
        XCTAssertEqual(try storedDocument(filed).kind, .other)
        XCTAssertEqual(try storedDocument(filed).canonicalName, "20230305 - Property - Heating")
        XCTAssertEqual(try storedRule(rule).action, DocumentKindAction(kind: .other, customKindId: check))
        XCTAssertEqual(try storedRule(rule).label, "Kind: Heating")
        XCTAssertEqual(try storedRequirement(both).kinds, [.repairInvoice])
        XCTAssertEqual(try storedRequirement(both).customKindIds, [check])
        XCTAssertEqual(try storedRequirement(one).customKindIds, [check])
        XCTAssertEqual(try db.read { try CustomDocumentKind.fetchAll($0).compactMap(\.id) }.sorted(), [check, alarm].sorted())

        // A chain follows to the end; a merge into itself, directly or round a loop, is refused.
        let a = try create("A kind", .other), b = try create("B kind", .other)
        let chained = try document("bb", name: "20230305 - Other - A kind", customKindId: a)
        XCTAssertThrowsError(try save([KindEdit(kindId: a, change: .merge(into: .custom(a)))])) {
            XCTAssertEqual($0 as? CustomDocumentKinds.Failure, .mergeIntoItself)
        }
        XCTAssertThrowsError(try save([KindEdit(kindId: a, change: .merge(into: .custom(b))), KindEdit(kindId: b, change: .merge(into: .custom(a)))])) {
            XCTAssertEqual($0 as? CustomDocumentKinds.Failure, .mergeIntoItself)
        }
        XCTAssertThrowsError(try save([KindEdit(kindId: a, change: .merge(into: .custom(999)))])) {
            XCTAssertEqual($0 as? CustomDocumentKinds.Failure, .notFound(999))
        }
        _ = try save([KindEdit(kindId: a, change: .merge(into: .custom(b))), KindEdit(kindId: b, change: .merge(into: .custom(alarm)))])
        XCTAssertEqual(try storedDocument(chained).kindRef, .custom(alarm))
        XCTAssertEqual(try storedDocument(chained).canonicalName, "20230305 - Other - Alarm contract")
        XCTAssertEqual(try db.read { try CustomDocumentKind.fetchCount($0) }, 2)
    }

    func testAFailedSaveWritesNothing() throws {
        let boiler = try create("Boiler service", .property)
        let filed = try document("aa", name: "20230305 - Property - Boiler service", customKindId: boiler)
        XCTAssertThrowsError(try save([KindEdit(kindId: boiler, change: .rename(name: "Heating", area: .property)),
                                       KindEdit(kindId: 999, change: .merge(into: .builtIn(.other)))]))
        XCTAssertEqual(try storedDocument(filed).canonicalName, "20230305 - Property - Boiler service")
        XCTAssertEqual(try db.read { try CustomDocumentKind.fetchOne($0, key: boiler)?.name }, "Boiler service")
    }

    // MARK: Sync

    /// A document and an evidence rule that arrive before their custom kind wait for it, then apply naming it.
    func testDocumentAndRuleArrivingBeforeTheirKindWaitThenApply() throws {
        let a = try SyncTestDevice("user-a"), b = try SyncTestDevice("user-b")
        let (boilerA, documentA, requirementA) = try a.queue.write { db -> (Int64, Int64, Int64) in
            let boiler = try XCTUnwrap(try CustomDocumentKinds.create(db: db, name: "Boiler service", area: .property, now: now).id)
            var document = EvidenceDocument(sha256: "aa", storedRelativePath: "aa/aa.pdf", originalFileName: "aa.pdf", byteCount: 1,
                                            addedAt: now, customKindId: boiler)
            try document.insert(db)
            var requirement = EvidenceRequirement(name: "Boiler", scope: .transactionsMatching(categoryIds: [], accountIds: [], descriptionContains: "boiler"),
                                                  kinds: [], customKindIds: [boiler], createdAt: now)
            try requirement.insert(db)
            return (boiler, document.id!, requirement.id!)
        }
        _ = try b.queue.write { db in try CustomDocumentKinds.create(db: db, name: "Alarm contract", area: .other, now: now) }
        let changes = try a.push()
        func isKind(_ change: SyncIncomingChange) -> Bool {
            if case .save(let payload) = change { return payload.recordType == CustomDocumentKind.databaseTableName }
            return false
        }
        let documentUUID = try a.uuid("document", documentA), requirementUUID = try a.uuid("evidenceRequirement", requirementA)
        let first = try b.receive(changes.filter { !isKind($0) })
        XCTAssertEqual(first[documentUUID], .staged("waiting for customDocumentKind"))
        guard case .staged = try XCTUnwrap(first[requirementUUID]) else { return XCTFail("the rule waits for its kind") }
        try b.queue.read { db in
            XCTAssertEqual(try EvidenceDocument.fetchCount(db), 0)
            XCTAssertEqual(try EvidenceRequirement.fetchCount(db), 0)
        }
        let second = try b.receive(changes.filter(isKind))
        XCTAssertEqual(second[documentUUID], .applied)
        XCTAssertEqual(second[requirementUUID], .applied)
        let boilerB = try XCTUnwrap(try b.localId(CustomDocumentKind.databaseTableName, try a.uuid(CustomDocumentKind.databaseTableName, boilerA)))
        XCTAssertNotEqual(boilerA, boilerB)
        try b.queue.read { db in
            let document = try XCTUnwrap(try EvidenceDocument.fetchOne(db, key: try XCTUnwrap(try SyncRecordStore.localId(table: "document", uuid: documentUUID, db: db))))
            XCTAssertEqual(document.kindRef, .custom(boilerB))
            let requirement = try XCTUnwrap(try EvidenceRequirement.fetchOne(db, key: try XCTUnwrap(try SyncRecordStore.localId(table: "evidenceRequirement", uuid: requirementUUID, db: db))))
            XCTAssertEqual(requirement.customKindIds, [boilerB])
            XCTAssertTrue(requirement.accepts(document.kindRef))
        }
    }
}
