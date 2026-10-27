import XCTest
import GRDB
@testable import BudgetCore
import BudgetDemo
import struct BudgetCore.Transaction
@testable import MangoUI

/// Step 8 Task 10: the iPad's Documents edits (Link to…, Unlink, Change kind…) and Missing evidence's Link, each the
/// Mac's BudgetCore write through the device writer in Documents (filed years checked, `EvidenceLinkGuard` inside), a
/// refusal shown under what it was made on. Demo data (the admin, `.demoAdmin`), plus a member bound to an iCloud user.
@MainActor
final class PadDocumentActionsTests: XCTestCase {
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func bump() { lock.withLock { count += 1 } }
        var value: Int { lock.withLock { count } }
    }

    private var db: DatabaseQueue!
    private var after: Counter!
    private let today = DemoDatabase.defaultAsOf

    override func setUp() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("pad-doc-actions-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("demo.sqlite").path
        try DemoDatabase.build(at: path, evidenceRoot: folder.appendingPathComponent("Evidence"))
        db = try DatabaseQueue(path: path)
        after = Counter()
    }

    /// The tabs over the demo, writing as `viewer`, Documents' Edit read.
    private func tabs(_ viewer: PhoneViewer = .demoAdmin) async -> PhoneTabsModel {
        let today = today, after = after!, db = db!
        let writer = DeviceWriter(db: db, viewer: { viewer }, afterWrite: { after.bump() })
        let tabs = PhoneTabsModel(dbQueue: db, today: { today }, hasProperty: true, viewer: .demoAdmin, writer: writer)
        await tabs.padDocumentWrite.refresh()
        await tabs.padDocuments.reload()
        return tabs
    }

    // MARK: Missing evidence

    /// The Mac's checklist, now in BudgetCore: the same items as the Mac's own composition did, for every filter.
    func testChecklistSameAsMac() async throws {
        try await db.read { db in
            let propertyId = try XCTUnwrap(try Property.fetchOne(db)?.id)
            for year in [UKTaxYear(startYear: 2024), UKTaxYear(startYear: 2025), UKTaxYear(startYear: 2026)] {
                let requirements = try EvidenceRequirements.all(db: db)
                let all = try MissingEvidence.items(db: db, period: year.interval, requirements: requirements)
                let related = try PropertyEvidence.relatedRequirementIds(db: db, propertyId: propertyId)
                let property = all.filter { $0.requirement.id.map(related.contains) ?? false }
                XCTAssertFalse(all.isEmpty, year.label)
                XCTAssertEqual(try MissingEvidence.checklist(db: db, period: year.interval), all, year.label)
                XCTAssertEqual(try MissingEvidence.checklist(db: db, period: year.interval, requirements: requirements), all)
                XCTAssertEqual(try MissingEvidence.checklist(db: db, period: year.interval, propertyId: propertyId), property, year.label)
                XCTAssertEqual(try MissingEvidence.checklist(db: db, period: year.interval, taxFiguresOnly: true),
                               MissingEvidence.affectingTaxFigures(all), year.label)
                XCTAssertEqual(try MissingEvidence.checklist(db: db, period: year.interval, propertyId: propertyId, taxFiguresOnly: true),
                               MissingEvidence.affectingTaxFigures(property), year.label)
            }
        }
        // The iPad's model reads it for the selected year.
        let tabs = await tabs()
        let model = tabs.padMissingEvidence
        model.year = UKTaxYear(startYear: 2025)
        await model.reload()
        let expected = try await db.read { db in try MissingEvidence.checklist(db: db, period: UKTaxYear(startYear: 2025).interval) }
        XCTAssertEqual(model.items, expected)
        XCTAssertEqual(model.years.first, UKTaxYear.containing(today))
    }

    /// A missing item's suggested document, linked from the side panel: the item is done, the document counts (no
    /// shortfall), the link is stamped as a document link, and the panel offers it no more.
    func testLinkFromPanelClearsShortfall() async throws {
        let tabs = await tabs()
        let model = tabs.padMissingEvidence
        XCTAssertTrue(model.canLink)
        var found: (item: MissingEvidence.Item, suggestion: PadMissingEvidenceModel.Suggestion)?
        for start in [2025, 2024, 2026] where found == nil {
            model.year = UKTaxYear(startYear: start)
            await model.reload()
            for item in model.items where item.status == .missing && found == nil {
                model.selectedItemId = item.id
                await model.loadPanel()
                let panel = try XCTUnwrap(model.panel)
                XCTAssertEqual(panel.itemId, item.id)
                if let first = panel.suggestions.first(where: { suggestion in
                    MissingEvidence.shortfall(of: Self.details(suggestion.document), for: item) == nil
                }) { found = (item, first) }
            }
        }
        let (item, suggestion) = try XCTUnwrap(found, "a missing demo item with a suggestion that would count")
        model.selectedItemId = item.id
        let saved = await model.link(documentId: suggestion.id, to: item)
        XCTAssertTrue(saved)
        XCTAssertEqual(after.value, 1)
        let now = try XCTUnwrap(model.items.first { $0.id == item.id })
        XCTAssertEqual(now.status, .satisfied)
        let attached = try XCTUnwrap(model.panel?.attached.first { $0.id == suggestion.id })
        XCTAssertTrue(attached.counts)
        XCTAssertNil(attached.explanation)
        XCTAssertFalse(model.panel?.suggestions.contains { $0.id == suggestion.id } ?? true)
        let note = try XCTUnwrap(model.note(for: item.id))
        XCTAssertTrue(note.hasPrefix("Linked “\(suggestion.document.displayName)”."), note)
        XCTAssertFalse(note.contains("doesn't count"), note)
        XCTAssertNil(tabs.padDocumentWrite.message(for: PadMissingEvidenceModel.itemRow(item.id)))
        let origin = try await db.read { db in
            try String.fetchOne(db, sql: """
                SELECT r.origin FROM syncRecord r JOIN documentLink l ON l.id = r.localId
                WHERE r.tableName = 'documentLink' AND l.documentId = ? AND l.entityType = ? AND l.entityId = ?
                """, arguments: [suggestion.id, item.target.entity.type.rawValue, item.target.entity.id])
        }
        XCTAssertEqual(origin, WriteOrigin.documentLink.rawValue)
    }

    // MARK: Documents

    func testLinkUnlinkAndChangeKindSave() async throws {
        let tabs = await tabs()
        let actions = tabs.padDocumentActions
        let documents = tabs.padDocuments
        XCTAssertTrue(actions.canEdit)
        // A document the matcher has a transaction for.
        var picked: (Int64, PadChoice)?
        for document in documents.all where picked == nil {
            if let first = await actions.linkChoices(for: document.id).first { picked = (document.id, first) }
        }
        let (documentId, choice) = try XCTUnwrap(picked)
        documents.selectedId = documentId
        await documents.loadLinks()
        let before = documents.links.count
        let linked = await actions.link(documentId: documentId, transactionId: choice.id)
        XCTAssertTrue(linked)
        XCTAssertEqual(documents.links.count, before + 1)
        let line = try XCTUnwrap(documents.links.first { $0.entity == .transaction(choice.id) })
        // Titled by its date, description and amount (`EvidenceLinkTitles`), never "Transaction #id".
        let transaction = try await db.read { db in try XCTUnwrap(try Transaction.fetchOne(db, key: choice.id)) }
        XCTAssertTrue(line.title.contains(transaction.rawDescription), line.title)
        XCTAssertTrue(line.title.contains(EvidenceLinkTitles.day(transaction.date)), line.title)
        XCTAssertFalse(line.title.contains("#"), line.title)
        XCTAssertNil(line.subtitle)

        let unlinked = await actions.unlink(documentId: documentId, line)
        XCTAssertTrue(unlinked)
        XCTAssertEqual(documents.links.count, before)

        let changed = await actions.changeKind(documentId: documentId, to: .builtIn(.other))
        XCTAssertTrue(changed)
        XCTAssertEqual(documents.selected?.kind, .other)
        XCTAssertEqual(after.value, 3)
    }

    func testUnlinkFromFiledYearTransactionRefusedInline() async throws {
        let (bill, paid) = try filedYearBill()
        let tabs = await tabs()
        let documents = tabs.padDocuments
        documents.selectedId = bill
        await documents.loadLinks()
        let line = try XCTUnwrap(documents.links.first { $0.entity == .transaction(paid) })
        let before = try linkRows()
        let saved = await tabs.padDocumentActions.unlink(documentId: bill, line)
        XCTAssertFalse(saved)
        XCTAssertEqual(tabs.padDocumentWrite.message(for: PadDocumentActions.linkRow(line.id)),
                       "Links not changed: this would change the filed 2024/25 return.")
        XCTAssertNil(tabs.padDocumentWrite.message(for: PadDocumentActions.documentRow(bill)), "only under the link")
        XCTAssertEqual(try linkRows(), before)
        XCTAssertEqual(documents.links.map(\.id), [line.id])
        XCTAssertEqual(after.value, 0)
    }

    func testChangeKindRefusedInlineWhenItMovesFiledYear() async throws {
        let (bill, _) = try filedYearBill()
        let tabs = await tabs()
        let documents = tabs.padDocuments
        documents.selectedId = bill
        await documents.loadLinks()
        let stored = try await db.read { db in try EvidenceDocument.fetchOne(db, key: bill) }
        let saved = await tabs.padDocumentActions.changeKind(documentId: bill, to: .builtIn(.other))
        XCTAssertFalse(saved)
        XCTAssertEqual(tabs.padDocumentWrite.message(for: PadDocumentActions.documentRow(bill)),
                       "Details not saved: this would change the filed 2024/25 return.")
        let now = try await db.read { db in try EvidenceDocument.fetchOne(db, key: bill) }
        XCTAssertEqual(now, stored, "nothing written")
        XCTAssertEqual(after.value, 0)
    }

    /// Change kind… on a document linked to several records warns first: the kind is the document's.
    func testMultiLinkWarningBeforeChangeKind() async throws {
        XCTAssertNil(PadDocumentActions.multiLinkWarning(1))
        XCTAssertEqual(PadDocumentActions.multiLinkWarning(2), "Linked to 2 records — changing its kind affects all of them")
        let (bill, _) = try filedYearBill()
        try await db.write { db in _ = try EvidenceLinks.link(db: db, documentId: bill, to: .property(try XCTUnwrap(try Property.fetchOne(db)?.id))) }
        let tabs = await tabs()
        tabs.padDocuments.selectedId = bill
        await tabs.padDocuments.loadLinks()
        XCTAssertEqual(tabs.padDocumentActions.kindWarning, "Linked to 2 records — changing its kind affects all of them")
    }

    func testMemberWithoutDocumentsEditSeesViewOnly() async throws {
        let (bill, paid) = try filedYearBill()
        let member = try addMember(documentsLevel: .view)
        let tabs = await tabs(.iCloudUser(recordName: member))
        let write = tabs.padDocumentWrite
        XCTAssertFalse(write.canEdit)
        XCTAssertEqual(write.viewOnlyMessage, DeviceWriteCopy.viewOnly(.documents))
        XCTAssertEqual(write.viewOnlyMessage, "View only: you don't have Edit on Documents.")
        XCTAssertFalse(tabs.padDocumentActions.canEdit)
        XCTAssertFalse(tabs.padMissingEvidence.canLink)
        // Nothing is written even if asked.
        let before = try linkRows()
        let linked = await tabs.padDocumentActions.link(documentId: bill, transactionId: paid)
        XCTAssertFalse(linked)
        let kind = await tabs.padDocumentActions.changeKind(documentId: bill, to: .builtIn(.other))
        XCTAssertFalse(kind)
        XCTAssertEqual(try linkRows(), before)
        XCTAssertEqual(after.value, 0)
        // Her Property Edit is not Documents': the Property screens still offer theirs.
        await tabs.padWrite.refresh()
        XCTAssertTrue(tabs.padWrite.canEdit)

        // A member with Edit on Documents gets the edits, and writes as herself.
        let editor = try addMember(documentsLevel: .edit, recordName: "_editor")
        let editing = await self.tabs(.iCloudUser(recordName: editor))
        XCTAssertTrue(editing.padDocumentActions.canEdit)
        XCTAssertNil(editing.padDocumentWrite.viewOnlyMessage)
        let changed = await editing.padDocumentActions.changeKind(documentId: bill, to: .builtIn(.accountantInvoice))
        XCTAssertTrue(changed)
    }

    // MARK: Helpers

    private nonisolated static func day(_ y: Int, _ m: Int, _ d: Int) -> Date {
        MonthRange.calendar.date(from: DateComponents(year: y, month: m, day: d))!
    }

    private nonisolated static func details(_ summary: EvidenceDocumentSummary) -> EvidenceDocumentDetails {
        var details = EvidenceDocumentDetails(kind: summary.kind)
        details.customKindId = summary.customKindId
        details.docDate = summary.docDate
        details.periodStart = summary.periodStart
        details.periodEnd = summary.periodEnd
        return details
    }

    /// A legal bill dated in the filed 2024/25 year, linked to the property's repair paid in 2025/26: the bill dates
    /// that payment into 2024/25, so unlinking it, or filing it as a kind that dates nothing, would move the filed
    /// 2024/25 return. (The brief's 2022/23: the demo's property is held from September 2023, so nothing it pays
    /// reaches 2022/23; a 2023/24 bill would move 2023/24 and the 2024/25 it carries into.)
    private func filedYearBill() throws -> (bill: Int64, paid: Int64) {
        try db.write { db in
            let account = try XCTUnwrap(try Account.filter(Column("name") == "Euro Current").fetchOne(db))
            let repairs = try XCTUnwrap(try Category.filter(Column("name") == "Repairs").fetchOne(db))
            let batch = try XCTUnwrap(try Int64.fetchOne(db, sql: "SELECT importBatchId FROM transaction_ WHERE accountId = ? LIMIT 1",
                                                         arguments: [account.id]))
            var paid = Transaction(importBatchId: batch, accountId: account.id!, date: Self.day(2025, 4, 20),
                                   rawDescription: "PAG ADVOGADOS DEMO 0002", amountMinorUnits: -3_995, categoryId: repairs.id,
                                   status: .confirmed, categorizedBy: .manual, fingerprint: UUID().uuidString)
            try paid.insert(db)
            var bill = EvidenceDocument(sha256: "legal-2024", storedRelativePath: "x/legal.pdf", originalFileName: "legal.pdf", byteCount: 1,
                                        kind: .legalInvoice, docDate: Self.day(2025, 3, 30), amountMinorUnits: 3_995, currency: .eur,
                                        addedAt: Self.day(2025, 4, 21))
            try bill.insert(db)
            try EvidenceLinks.link(db: db, documentId: bill.id!, to: .transaction(paid.id!))
            return (bill.id!, paid.id!)
        }
    }

    private func linkRows() throws -> [Row] {
        try db.read { db in try Row.fetchAll(db, sql: "SELECT * FROM documentLink ORDER BY id") }
    }

    /// A member app user bound to iCloud user `recordName`, with `documentsLevel` on Documents (Edit elsewhere).
    private func addMember(documentsLevel: PermissionLevel, recordName: String = "_member") throws -> String {
        try db.write { db in
            var person = Person(name: "Person \(recordName)", shortName: String(recordName.dropFirst().prefix(1)).uppercased())
            try People.save(db: db, &person)
            var user = AppUser(personId: person.id!, displayName: "B", cloudKitUserRecordName: recordName, isAdmin: false,
                               createdAt: Self.day(2026, 1, 1))
            try user.insert(db)
            _ = try SyncRecordStore.uuid(for: "appUser", localId: user.id!, db: db)
            try MemberPermissions.ensureDefaults(appUserId: user.id!, db: db)
            try db.execute(sql: "UPDATE memberPermission SET level = ? WHERE appUserId = ?", arguments: [PermissionLevel.edit.rawValue, user.id!])
            try db.execute(sql: "UPDATE memberPermission SET level = ? WHERE appUserId = ? AND area = ?",
                           arguments: [documentsLevel.rawValue, user.id!, AccessArea.documents.storageKey])
        }
        return recordName
    }
}
