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
        XCTAssertEqual(try db.read { try DocumentKindCatalog.load(db: $0).customKinds.map(\.name) }, ["Boiler service"])
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
        // Merged into a built-in, the kind stays as a retired row (so other devices re-file what names it), its name freed.
        let retired = try XCTUnwrap(try db.read { try CustomDocumentKind.fetchOne($0, key: boiler) })
        XCTAssertEqual(retired.mergedIntoKind, .repairInvoice)
        XCTAssertEqual(retired.retiredFromName, "Boiler service")
        let catalog = try db.read { try DocumentKindCatalog.load(db: $0) }
        XCTAssertEqual(catalog.customKinds, [], "no longer offered")
        XCTAssertNil(catalog.custom(id: boiler))
        XCTAssertEqual(catalog.displayName(.custom(boiler)), "Repair bill")
        XCTAssertEqual(catalog.libraryArea(.custom(boiler)), "Property")
        XCTAssertNotNil(try create("Boiler service", .other), "its name can be used again")
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

    func testMergeIntoOtherNamesDocumentsLikeImports() throws {
        let boiler = try create("Boiler service", .property)
        let filed = try document("aa", name: "20230305 - Property - Boiler service - Caldeiras Lda", customKindId: boiler)
        let rule = try kindRule("issuer-1", DocumentKindAction(kind: .other, customKindId: boiler), label: "Kind: Boiler service")
        _ = try save([KindEdit(kindId: boiler, change: .merge(into: .builtIn(.other)))])
        XCTAssertEqual(try storedDocument(filed).canonicalName, "20230305 - Other - Document - Caldeiras Lda")
        XCTAssertEqual(try storedDocument(filed).kindRef, .builtIn(.other))
        XCTAssertEqual(try storedRule(rule).label, "Kind: Other")
    }

    /// A Save that fails after it has started writing (here a rule update the database refuses) leaves nothing written.
    func testASaveFailingPartWayLeavesNothing() throws {
        let boiler = try create("Boiler service", .property)
        let filed = try document("aa", name: "20230305 - Property - Boiler service", customKindId: boiler)
        let rule = try kindRule("issuer-1", DocumentKindAction(kind: .other, customKindId: boiler), label: "Kind: Boiler service")
        let requirementId = try requirement("Boiler", kinds: [], customKindIds: [boiler])
        try db.write { db in
            try db.execute(sql: "CREATE TEMP TRIGGER refuseRuleUpdate BEFORE UPDATE ON importRule BEGIN SELECT RAISE(ABORT, 'refused'); END")
        }
        XCTAssertThrowsError(try save([KindEdit(kindId: boiler, change: .merge(into: .builtIn(.repairInvoice)))]))
        let document = try storedDocument(filed)
        XCTAssertEqual(document.kindRef, .custom(boiler), "the document re-filed before the failure is back")
        XCTAssertEqual(document.canonicalName, "20230305 - Property - Boiler service")
        XCTAssertEqual(try storedRule(rule).action, DocumentKindAction(kind: .other, customKindId: boiler))
        XCTAssertEqual(try storedRequirement(requirementId).customKindIds, [boiler])
        XCTAssertEqual(try db.read { try CustomDocumentKind.fetchOne($0, key: boiler) }?.mergedIntoKind, nil)
    }

    /// Re-filing a document as an invoice dates its expense by the invoice: a Save that would move a filed
    /// year's figures is refused, naming the year and the document, and writes nothing.
    func testASaveThatWouldChangeAFiledYearIsRefused() throws {
        let (boiler, filed) = try db.write { db -> (Int64, Int64) in
            var person = Person(name: "Person A", shortName: "A")
            try People.save(db: db, &person)
            var year = TaxYear(startYear: 2024, personId: person.id!, status: .filed)
            try year.insert(db)
            var property = Property(name: "Property A", country: "PT", currency: .gbp)
            try Properties.save(db: db, &property)
            _ = try Properties.setOwners(db: db, propertyId: property.id!, [PropertyOwner(propertyId: property.id!, personId: person.id!, shareBasisPoints: 10_000)])
            var account = Account(name: "Bank A", currency: .gbp, kind: .cash, trackingMode: .imported)
            try account.insert(db)
            var batch = ImportBatch(accountId: account.id!, sourceFileName: "synthetic.csv", importedAt: now)
            try batch.insert(db)
            try Properties.setAccount(db: db, propertyId: property.id!, accountId: account.id!, role: .current)
            var group = CategoryGroup(name: "Property A")
            try group.insert(db)
            try Properties.addCategoryGroup(db: db, propertyId: property.id!, categoryGroupId: group.id!)
            var utilities = Category(name: "Utilities", type: .expense, groupId: group.id)
            try utilities.insert(db)
            try TaxExpenseTypeMap.seed(db: db, propertyId: property.id!)
            try TaxExpenseTypeMap.set(db: db, categoryId: utilities.id!, expenseType: .utilities)
            // Paid in 2025/26 (not filed); the bill is dated in the filed 2024/25.
            var payment = Transaction(importBatchId: batch.id!, accountId: account.id!, date: MonthRange.calendar.date(from: DateComponents(year: 2025, month: 4, day: 10))!,
                                      rawDescription: "POWER CO", amountMinorUnits: -4_000, categoryId: utilities.id, status: .confirmed,
                                      categorizedBy: .manual, fingerprint: "fp-power")
            try payment.insert(db)
            let boiler = try CustomDocumentKinds.create(db: db, name: "Power bill", area: .property, now: now).id!
            var document = EvidenceDocument(sha256: "aa", storedRelativePath: "aa/aa.pdf", originalFileName: "aa.pdf", byteCount: 1,
                                            canonicalName: "20250315 - Property - Power bill - Power Co", kind: .other,
                                            docDate: MonthRange.calendar.date(from: DateComponents(year: 2025, month: 3, day: 15))!,
                                            addedAt: now, customKindId: boiler)
            try document.insert(db)
            try EvidenceLinks.link(db: db, documentId: document.id!, to: .transaction(payment.id!))
            return (boiler, document.id!)
        }
        XCTAssertThrowsError(try save([KindEdit(kindId: boiler, change: .merge(into: .builtIn(.utilityInvoice)))])) {
            XCTAssertEqual($0 as? CustomDocumentKinds.Failure,
                           .changesFiledYear(years: ["2024/25"], documents: ["20250315 - Property - Utility invoice - Power Co"]))
            XCTAssertEqual(($0 as? LocalizedError)?.errorDescription,
                           "Not saved: this would change the filed 2024/25 return. Documents involved: 20250315 - Property - Utility invoice - Power Co.")
        }
        XCTAssertEqual(try storedDocument(filed).kindRef, .custom(boiler))
        XCTAssertEqual(try storedDocument(filed).canonicalName, "20250315 - Property - Power bill - Power Co")
        XCTAssertNotNil(try db.read { try DocumentKindCatalog.load(db: $0).custom(id: boiler) })
        // A kind that doesn't date expenses moves nothing: saved.
        XCTAssertEqual(try save([KindEdit(kindId: boiler, change: .merge(into: .builtIn(.repairInvoice)))]).documentsChanged, 1)
    }

    /// A kind merged into a built-in keeps a reserved name (never one a person can type), even when a rename from
    /// another device put its old name back: making that name again works.
    func testARetiredKindNeverBlocksItsName() throws {
        let boiler = try create("Boiler service", .property)
        _ = try save([KindEdit(kindId: boiler, change: .merge(into: .builtIn(.repairInvoice)))])
        // Another device's rename won the name field over the retirement.
        try db.write { db in try db.execute(sql: "UPDATE customDocumentKind SET name = 'Boiler service' WHERE id = ?", arguments: [boiler]) }
        let again = try create("boiler SERVICE", .other)
        XCTAssertNotEqual(again, boiler)
        let retired = try XCTUnwrap(try db.read { try CustomDocumentKind.fetchOne($0, key: boiler) })
        XCTAssertTrue(retired.name.contains(CustomDocumentKind.retiredMarker), retired.name)
        XCTAssertEqual(retired.retiredFromName, "Boiler service")
        // After a sync apply, a retired kind holding a plain name is given its reserved name again.
        try db.write { db in try db.execute(sql: "UPDATE customDocumentKind SET name = 'Gas check' WHERE id = ?", arguments: [boiler]) }
        try db.write { db in _ = try CustomDocumentKinds.settleRetired(db: db) }
        let settled = try XCTUnwrap(try db.read { try CustomDocumentKind.fetchOne($0, key: boiler) })
        XCTAssertTrue(settled.name.contains(CustomDocumentKind.retiredMarker), settled.name)
        XCTAssertEqual(settled.retiredFromName, "Gas check")
    }

    /// A name the database refuses (whatever the reason the checks above it missed) is a friendly error, not SQLite's.
    func testANameTheDatabaseRefusesIsAFriendlyError() throws {
        try db.write { db in
            try db.execute(sql: """
                CREATE TEMP TRIGGER refuseKind BEFORE INSERT ON customDocumentKind WHEN NEW.name = 'Heating'
                BEGIN SELECT RAISE(ABORT, 'UNIQUE constraint failed: customDocumentKind.name'); END
                """)
        }
        XCTAssertThrowsError(try create("Heating", .property)) { XCTAssertEqual($0 as? CustomDocumentKinds.Failure, .nameTaken("Heating")) }
        let boiler = try create("Boiler service", .property)
        try db.write { db in
            try db.execute(sql: """
                CREATE TEMP TRIGGER refuseRename BEFORE UPDATE OF name ON customDocumentKind WHEN NEW.name = 'Heating'
                BEGIN SELECT RAISE(ABORT, 'UNIQUE constraint failed: customDocumentKind.name'); END
                """)
        }
        XCTAssertThrowsError(try save([KindEdit(kindId: boiler, change: .rename(name: "Heating", area: .property))])) {
            XCTAssertEqual($0 as? CustomDocumentKinds.Failure, .nameTaken("Heating"))
        }
    }

    func testSaveRefusesBeforeWriting() throws {
        let boiler = try create("Boiler service", .property)
        let filed = try document("aa", name: "20230305 - Property - Boiler service", customKindId: boiler)
        XCTAssertThrowsError(try save([KindEdit(kindId: boiler, change: .rename(name: "Heating", area: .property)),
                                       KindEdit(kindId: 999, change: .merge(into: .builtIn(.other)))]))
        XCTAssertEqual(try storedDocument(filed).canonicalName, "20230305 - Property - Boiler service")
        XCTAssertEqual(try db.read { try CustomDocumentKind.fetchOne($0, key: boiler)?.name }, "Boiler service")
    }

    // MARK: Sync

    /// A late save of a kind redirected here: an identity merge (the same name made on two devices) is the same
    /// kind, so its edits merge into the survivor; a kind merged into another from the Kinds sheet is not, so its
    /// name and area don't overwrite the target's.
    func testALateSaveOfARedirectedKindMergesOnlyWhenItIsTheSameKind() throws {
        let a = try SyncTestDevice("user-a"), b = try SyncTestDevice("user-b")
        let survivor = try b.queue.write { db in try XCTUnwrap(try CustomDocumentKinds.create(db: db, name: "Boiler service", area: .property, now: now).id) }
        let survivorUUID = try b.uuid("customDocumentKind", survivor)
        func lateSave(name: String) throws -> [SyncIncomingChange] {
            let id = try a.queue.write { db -> Int64 in
                try db.execute(sql: "DELETE FROM customDocumentKind")
                var kind = CustomDocumentKind(name: name, area: .other, createdAt: now.addingTimeInterval(60))
                try kind.insert(db)
                return kind.id!
            }
            let uuid = try a.uuid("customDocumentKind", id)
            try b.queue.write { db in
                try SyncMerge.redirect(uuid, to: survivorUUID, table: "customDocumentKind", localId: 0, zone: SyncRecordStore.householdZone,
                                       by: nil, now: now, db: db)
            }
            return try a.push().filter { if case .save(let p) = $0 { return p.recordName == uuid } else { return false } }
        }
        // Merged from the Kinds sheet: discarded.
        let merged = try lateSave(name: "Gas check")
        XCTAssertEqual(merged.count, 1)
        try b.receive(merged)
        var stored = try XCTUnwrap(try b.queue.read { try CustomDocumentKind.fetchOne($0, key: survivor) })
        XCTAssertEqual(stored.name, "Boiler service")
        XCTAssertEqual(stored.area, .property)
        // Merged by identity: its area edit is kept.
        try b.receive(try lateSave(name: "BOILER SERVICE"))
        stored = try XCTUnwrap(try b.queue.read { try CustomDocumentKind.fetchOne($0, key: survivor) })
        XCTAssertEqual(stored.area, .other, "the identity merge keeps the edit")
        XCTAssertEqual(try b.queue.read { try CustomDocumentKind.fetchCount($0) }, 1)
    }

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

/// A merge reaches every device (review I1): two devices syncing through `FakeCloud`; device A merges kind X
/// while device B files a new document under X and an evidence rule names it. Both end with everything under
/// the target, whichever reaches the cloud first. Synthetic data.
final class CustomDocumentKindMergeSyncTests: XCTestCase {
    private var cloud: FakeCloud!
    private var a: SyncEngineTestDevice!
    private var b: SyncEngineTestDevice!
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUp() async throws {
        cloud = FakeCloud()
        let keys = InMemorySyncKeyStore()
        a = try SyncEngineTestDevice("user-a", name: "Mac", cloud: cloud, keys: keys)
        b = try SyncEngineTestDevice("user-b", name: "iPad", cloud: cloud, keys: keys)
    }

    private struct Shared {
        var boiler: String, heating: String, documentA: String, rule: String, requirement: String
    }

    /// Kinds "Boiler service" and "Heating", a document of Boiler service, a learnt rule and an evidence rule naming it, on both devices.
    private func shared() async throws -> Shared {
        let ids = try a.write { db -> (Int64, Int64, Int64, Int64, Int64) in
            let boiler = try CustomDocumentKinds.create(db: db, name: "Boiler service", area: .property, now: now).id!
            let heating = try CustomDocumentKinds.create(db: db, name: "Heating", area: .property, now: now).id!
            var document = EvidenceDocument(sha256: "aa", storedRelativePath: "aa/aa.pdf", originalFileName: "aa.pdf", byteCount: 1,
                                            canonicalName: "20250301 - Property - Boiler service - Caldeiras Lda", addedAt: now, customKindId: boiler)
            try document.insert(db)
            var rule = ImportRule(kind: .documentKind, matchKey: "issuer-caldeiras", matchLabel: "Caldeiras Lda",
                                  actionJSON: ImportLearning.encode(DocumentKindAction(kind: .other, customKindId: boiler))!,
                                  actionLabel: "Kind: Boiler service", createdAt: now)
            try rule.insert(db)
            var requirement = EvidenceRequirement(name: "Boiler", scope: .transactionsMatching(categoryIds: [], accountIds: [], descriptionContains: "boiler"),
                                                  kinds: [], customKindIds: [boiler], createdAt: now)
            try requirement.insert(db)
            return (boiler, heating, document.id!, rule.id!, requirement.id!)
        }
        try await a.engine.syncNow()
        try await b.engine.syncNow()
        return Shared(boiler: try a.uuid("customDocumentKind", ids.0), heating: try a.uuid("customDocumentKind", ids.1),
                      documentA: try a.uuid("document", ids.2), rule: try a.uuid("importRule", ids.3), requirement: try a.uuid("evidenceRequirement", ids.4))
    }

    /// B files a document under Boiler service (not yet sent).
    private func fileOnB(_ shared: Shared, kindName: String = "Boiler service") throws -> String {
        let boiler = try XCTUnwrap(try b.localId("customDocumentKind", shared.boiler))
        let id = try b.write { db -> Int64 in
            var document = EvidenceDocument(sha256: "bb", storedRelativePath: "bb/bb.pdf", originalFileName: "bb.pdf", byteCount: 1,
                                            canonicalName: "20250402 - Property - \(kindName) - Caldeiras Lda", addedAt: now, customKindId: boiler)
            try document.insert(db)
            return document.id!
        }
        return try b.uuid("document", id)
    }

    private func document(_ device: SyncEngineTestDevice, _ uuid: String) throws -> EvidenceDocument {
        let id = try XCTUnwrap(try device.localId("document", uuid))
        return try XCTUnwrap(try device.read { try EvidenceDocument.fetchOne($0, key: id) })
    }

    /// Both devices: the documents, the learnt rule and the evidence rule under `target`; the merged kind no longer offered.
    private func assertConverged(_ shared: Shared, documentB: String, target: (SyncEngineTestDevice) throws -> DocumentKindRef, name: String,
                                 conflicts expected: [String: Set<String>] = [:], file: StaticString = #filePath, line: UInt = #line) throws {
        for device in [a!, b!] {
            let ref = try target(device)
            for (uuid, date) in [(shared.documentA, "20250301"), (documentB, "20250402")] {
                let stored = try document(device, uuid)
                XCTAssertEqual(stored.kindRef, ref, "\(device.user) \(uuid)", file: file, line: line)
                XCTAssertEqual(stored.canonicalName, "\(date) - Property - \(name) - Caldeiras Lda", device.user, file: file, line: line)
            }
            let ruleId = try XCTUnwrap(try device.localId("importRule", shared.rule))
            let rule = try XCTUnwrap(try device.read { try ImportRule.fetchOne($0, key: ruleId) })
            XCTAssertEqual(ImportLearning.decode(DocumentKindAction.self, rule.actionJSON)?.kindRef, ref, device.user, file: file, line: line)
            XCTAssertEqual(rule.actionLabel, "Kind: \(name)", device.user, file: file, line: line)
            let requirementId = try XCTUnwrap(try device.localId("evidenceRequirement", shared.requirement))
            let requirement = try XCTUnwrap(try device.read { try EvidenceRequirement.fetchOne($0, key: requirementId) })
            XCTAssertEqual(requirement.kindRefs, [ref], device.user, file: file, line: line)
            let names = try device.read { try DocumentKindCatalog.load(db: $0).customKinds.map(\.name) }
            XCTAssertFalse(names.contains("Boiler service"), "\(device.user) \(names)", file: file, line: line)
            XCTAssertEqual(try device.count("syncStaging"), 0, device.user, file: file, line: line)
            let conflicts = try device.read { try String.fetchAll($0, sql: "SELECT tableName || '.' || field FROM syncConflict") }
            XCTAssertEqual(Set(conflicts), expected[device.user] ?? [], device.user, file: file, line: line)
            XCTAssertEqual(try device.read { try SyncChangeTracker.pending(db: $0) }.count, 0, "\(device.user) has nothing left to send", file: file, line: line)
        }
    }

    private func merge(into target: (Int64) -> DocumentKindRef, _ shared: Shared) throws {
        let boiler = try XCTUnwrap(try a.localId("customDocumentKind", shared.boiler))
        let heating = try XCTUnwrap(try a.localId("customDocumentKind", shared.heating))
        _ = try a.write { db in try CustomDocumentKinds.save(db: db, edits: [KindEdit(kindId: boiler, change: .merge(into: target(heating)))], now: now) }
    }

    private func heating(_ shared: Shared) -> (SyncEngineTestDevice) throws -> DocumentKindRef {
        { device in .custom(try XCTUnwrap(try device.localId("customDocumentKind", shared.heating))) }
    }

    func testMergeIntoACustomKindReachesADocumentFiledElsewhereAfterIt() async throws {
        let shared = try await shared()
        let documentB = try fileOnB(shared)
        try merge(into: { .custom($0) }, shared)
        try await a.engine.syncNow()   // the merge reaches the cloud first
        try await b.engine.syncNow()   // B re-files its own document, and sends it
        try await a.engine.syncNow()
        try assertConverged(shared, documentB: documentB, target: heating(shared), name: "Heating")
    }

    func testMergeIntoACustomKindReachesADocumentFiledElsewhereBeforeIt() async throws {
        let shared = try await shared()
        let documentB = try fileOnB(shared)
        try await b.engine.syncNow()   // B's document reaches the cloud first
        try merge(into: { .custom($0) }, shared)
        try await a.engine.syncNow()   // A pulls it under the redirect, then sends the merge
        try await b.engine.syncNow()
        try await a.engine.syncNow()
        try assertConverged(shared, documentB: documentB, target: heating(shared), name: "Heating")
    }

    func testMergeIntoABuiltInKindReachesADocumentFiledElsewhereAfterIt() async throws {
        let shared = try await shared()
        let documentB = try fileOnB(shared)
        try merge(into: { _ in .builtIn(.repairInvoice) }, shared)
        try await a.engine.syncNow()
        try await b.engine.syncNow()
        try await a.engine.syncNow()
        try assertConverged(shared, documentB: documentB, target: { _ in .builtIn(.repairInvoice) }, name: "Repair bill")
    }

    func testMergeIntoABuiltInKindReachesADocumentFiledElsewhereBeforeIt() async throws {
        let shared = try await shared()
        let documentB = try fileOnB(shared)
        try await b.engine.syncNow()
        try merge(into: { _ in .builtIn(.repairInvoice) }, shared)
        try await a.engine.syncNow()
        try await b.engine.syncNow()
        try await a.engine.syncNow()
        try assertConverged(shared, documentB: documentB, target: { _ in .builtIn(.repairInvoice) }, name: "Repair bill")
    }

    // MARK: Redirects refused or gone on the server (fix round 2)

    private func pending(_ device: SyncEngineTestDevice) throws -> Int {
        try device.read { try SyncChangeTracker.pending(db: $0).count }
    }

    private func conflicts(_ device: SyncEngineTestDevice) throws -> [String] {
        try device.read { try String.fetchAll($0, sql: "SELECT tableName || '.' || field FROM syncConflict") }
    }

    /// B renames Boiler service and sends it; A, without pulling, merges it into Heating: the redirect is refused once
    /// (the server's version moved), sent again over that version, and both devices end under Heating. The re-send
    /// is no error in the report.
    func testARedirectRefusedBecauseTheKindChangedOnTheServerIsSentAgain() async throws {
        let shared = try await shared()
        let boilerB = try XCTUnwrap(try b.localId("customDocumentKind", shared.boiler))
        _ = try b.write { db in try CustomDocumentKinds.save(db: db, edits: [KindEdit(kindId: boilerB, change: .rename(name: "Boiler check", area: .property))]) }
        try await b.engine.syncNow()
        try merge(into: { .custom($0) }, shared)
        let push = try await a.engine.pushPending()
        XCTAssertEqual(push.refused, 0, "\(push)")
        XCTAssertGreaterThanOrEqual(push.merged, 1, "\(push)")
        XCTAssertEqual(try pending(a), 0)
        let redirect = try await cloud.payload(named: shared.boiler, keys: a.keys)
        XCTAssertEqual(redirect?.mergedInto, shared.heating)
        let documentB = try fileOnB(shared, kindName: "Boiler check")
        try await b.engine.syncNow()
        try await a.engine.syncNow()
        // B's rename and A's merge both renamed A's document and relabelled the rule: true concurrent edits, logged
        // where the merge's later edit won.
        try assertConverged(shared, documentB: documentB, target: heating(shared), name: "Heating",
                            conflicts: ["user-a": ["document.canonicalName", "importRule.actionLabel"]])
    }

    /// The merged kind's record was deleted on the server before the redirect went: its stale stamp is dropped and
    /// the redirect is saved afresh, once, rather than refused on every push.
    func testARedirectWhoseRecordTheServerDeletedSettles() async throws {
        let shared = try await shared()
        try merge(into: { .custom($0) }, shared)
        try await cloud.delete([shared.boiler], zone: SyncRecordStore.householdZone)
        let push = try await a.engine.pushPending()
        XCTAssertEqual(push.refused, 0, "\(push)")
        XCTAssertEqual(try pending(a), 0, "nothing left to send")
        let redirect = try await cloud.payload(named: shared.boiler, keys: a.keys)
        XCTAssertEqual(redirect?.mergedInto, shared.heating)
        XCTAssertEqual(try a.read { try Data.fetchOne($0, sql: "SELECT systemFields FROM syncTombstone WHERE uuid = ?", arguments: [shared.boiler]) }, nil)
        XCTAssertEqual(try conflicts(a), [])
        let again = try await a.engine.pushPending()
        XCTAssertEqual(again.saved + again.refused, 0, "settled: \(again)")
    }

    /// The same name made on both devices, both sent before either pulled: the identity merge redirects one record
    /// that the server already has (refused once, sent again), and the devices converge on one kind with both
    /// documents under it. An area edit made to the redirected record before the merge reached its device is kept.
    func testIdentityMergeOfTwoKindsAlreadyOnTheServerConverges() async throws {
        func make(_ device: SyncEngineTestDevice, _ sha: String) throws -> (kind: String, document: String) {
            let ids = try device.write { db -> (Int64, Int64) in
                let kind = try CustomDocumentKinds.create(db: db, name: "Boiler service", area: .property, now: now).id!
                var document = EvidenceDocument(sha256: sha, storedRelativePath: "\(sha)/\(sha).pdf", originalFileName: "\(sha).pdf", byteCount: 1,
                                                addedAt: now, customKindId: kind)
                try document.insert(db)
                return (kind, document.id!)
            }
            return (try device.uuid("customDocumentKind", ids.0), try device.uuid("document", ids.1))
        }
        let fromA = try make(a, "aa"), fromB = try make(b, "bb")
        _ = try await a.engine.pushPending()
        _ = try await b.engine.pushPending()
        // The record that loses (the larger UUID) is edited on its device before that device hears of the other.
        let (loser, loserDevice) = fromA.kind > fromB.kind ? (fromA.kind, a!) : (fromB.kind, b!)
        let survivor = min(fromA.kind, fromB.kind)
        let loserId = try XCTUnwrap(try loserDevice.localId("customDocumentKind", loser))
        try loserDevice.write { db in
            var kind = try XCTUnwrap(try CustomDocumentKind.fetchOne(db, key: loserId))
            kind.area = .other
            try kind.update(db)
        }
        _ = try await loserDevice.engine.pushPending()
        var refused = 0
        for _ in 0..<3 {
            refused += try await a.engine.syncNow().push.refused
            refused += try await b.engine.syncNow().push.refused
        }
        XCTAssertEqual(refused, 0)
        for device in [a!, b!] {
            let kinds = try device.read { try CustomDocumentKind.fetchAll($0) }
            XCTAssertEqual(kinds.count, 1, device.user)
            XCTAssertEqual(kinds.first?.area, .other, "\(device.user): the edit is kept")
            let id = try XCTUnwrap(try device.localId("customDocumentKind", survivor), device.user)
            for uuid in [fromA.document, fromB.document] {
                XCTAssertEqual(try document(device, uuid).kindRef, .custom(id), device.user)
            }
            XCTAssertEqual(try device.count("syncStaging"), 0, device.user)
            XCTAssertEqual(try pending(device), 0, device.user)
        }
        let redirect = try await cloud.payload(named: loser, keys: a.keys)
        XCTAssertEqual(redirect?.mergedInto, survivor)
    }
}
