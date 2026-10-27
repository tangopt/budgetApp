import XCTest
import GRDB
@testable import BudgetCore
import BudgetDemo
import struct BudgetCore.Transaction
@testable import MangoUI

/// Step 10, Task 14: the iPad's Evidence over the demo: links through the device writer in Documents (filed years checked,
/// a refusal shown under the item, nothing saved), "Open site" at the matching saved site, and no edits without Edit on
/// Documents. A member is bound to an iCloud user.
@MainActor
final class PadEvidenceModelTests: XCTestCase {
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
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("pad-evidence-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("demo.sqlite").path
        try DemoDatabase.build(at: path, evidenceRoot: folder.appendingPathComponent("Evidence"))
        db = try DatabaseQueue(path: path)
        after = Counter()
    }

    private func model(_ viewer: PhoneViewer = .demoAdmin, year: Int = 2025) async -> PadEvidenceModel {
        let today = today, after = after!, db = db!
        let writer = DeviceWriter(db: db, viewer: { viewer }, afterWrite: { after.bump() })
        let tabs = PhoneTabsModel(dbQueue: db, today: { today }, hasProperty: true, viewer: .demoAdmin, writer: writer)
        let model = tabs.padEvidence
        model.year = UKTaxYear(startYear: year)
        await model.reload()
        return model
    }

    func testDemoYearsAndAreas() async throws {
        let model = await model()
        XCTAssertEqual(model.years, [UKTaxYear(startYear: 2025), UKTaxYear(startYear: 2026)], "last year and this one")
        XCTAssertFalse(model.items.isEmpty)
        XCTAssertFalse(model.items.contains { TaxYearEvidence.isUtilityBill($0.item) })
        XCTAssertEqual(model.areas.map(\.area), EvidenceAreaKind.allCases.filter { kind in model.areas.contains { $0.area == kind } })
        XCTAssertTrue(model.areas.contains { $0.area == .lisbonFlat })
        // Missing only by default: the shown areas hold missing items only.
        XCTAssertTrue(model.missingOnly)
        XCTAssertTrue(model.shownAreas.flatMap(\.items).allSatisfy { $0.state == .missing })
        model.missingOnly = false
        XCTAssertEqual(model.shownAreas.flatMap(\.items).count, model.items.count)
    }

    func testLinkExistingDocumentThroughWriter() async throws {
        let model = await model()
        XCTAssertTrue(model.canLink)
        var found: (EvidenceItem, EvidenceDocumentSummary)?
        for item in model.items where item.state == .missing && found == nil {
            if let first = await model.libraryChoices(for: item).first { found = (item, first) }
        }
        let (item, document) = try XCTUnwrap(found, "a missing demo item with a library document of its kind")
        model.selectedItemId = item.id
        let saved = await model.link(documentId: document.id, to: item)
        XCTAssertTrue(saved)
        XCTAssertEqual(after.value, 1)
        XCTAssertTrue(try XCTUnwrap(model.note(for: item.id)).hasPrefix("Linked “\(document.displayName)”."))
        XCTAssertNil(model.refusal(for: item.id))
        let origin = try await db.read { db in
            try String.fetchOne(db, sql: """
                SELECT r.origin FROM syncRecord r JOIN documentLink l ON l.id = r.localId
                WHERE r.tableName = 'documentLink' AND l.documentId = ? AND l.entityType = ? AND l.entityId = ?
                """, arguments: [document.id, item.item.target.entity.type.rawValue, item.item.target.entity.id])
        }
        XCTAssertEqual(origin, WriteOrigin.documentLink.rawValue)
        // No longer offered for it.
        let again = try XCTUnwrap(model.items.first { $0.id == item.id })
        let choices = await model.libraryChoices(for: again)
        XCTAssertFalse(choices.contains { $0.id == document.id })
    }

    /// A legal bill dated in the filed 2024/25 year (an invoice dates the payments it is linked to), linked to a repair paid
    /// in 2025/26, would date that payment into 2024/25: refused under the item, nothing written.
    func testLinkInFiledYearRefusedInline() async throws {
        let (bill, paid) = try filedYearBill()
        let model = await model()
        let item = try XCTUnwrap(model.items.first { $0.item.target.entity == .transaction(paid) }, "the repair asks for its bill")
        let before = try linkRows()
        let saved = await model.link(documentId: bill, to: item)
        XCTAssertFalse(saved)
        XCTAssertEqual(model.refusal(for: item.id), "Links not changed: this would change the filed 2024/25 return.")
        XCTAssertNil(model.note(for: item.id))
        XCTAssertEqual(try linkRows(), before)
        XCTAssertEqual(after.value, 0)
        XCTAssertEqual(model.items.first { $0.id == item.id }?.state, .missing)
    }

    func testMarkNotAvailableSavesWaiver() async throws {
        let model = await model()
        XCTAssertTrue(model.canMarkNotAvailable)
        let item = try XCTUnwrap(model.items.first { $0.state == .missing })
        let saved = await model.markNotAvailable(item)
        XCTAssertTrue(saved)
        XCTAssertEqual(model.items.first { $0.id == item.id }?.item.status, .waived)
        XCTAssertEqual(model.note(for: item.id), "Marked not available.")
        XCTAssertEqual(after.value, 1)
    }

    func testOpenSiteUsesMatchingSavedSiteKindOrOffersAdd() async throws {
        let model = await model()
        model.missingOnly = false
        let sites = [SavedSite(name: "Example Bank", url: URL(string: "https://bank.example.test")!, kind: .bank, sortOrder: 0),
                     SavedSite(name: "HMRC online", url: URL(string: "https://hmrc.example.test")!, kind: .tax, sortOrder: 1),
                     SavedSite(name: "Portal das Finanças", url: URL(string: "https://portal.example.test")!, kind: .tax, sortOrder: 2)]
        let tax = try XCTUnwrap(model.items.first { $0.suggestedSiteKind == .tax && $0.source == "Portal das Finanças" })
        XCTAssertEqual(PadEvidenceModel.site(for: tax, in: sites)?.name, "Portal das Finanças", "named like its source")
        XCTAssertEqual(PadEvidenceModel.site(for: tax, in: Array(sites.prefix(2)))?.name, "HMRC online", "else the first of its kind")
        XCTAssertNil(PadEvidenceModel.site(for: tax, in: [sites[0]]), "none of its kind: the browser opens on its strip to add one")
        var hmrc = tax
        hmrc.item.usualSource = "HMRC / bank"
        XCTAssertEqual(PadEvidenceModel.site(for: hmrc, in: sites)?.name, "HMRC online")
        var none = tax
        none.suggestedSiteKind = nil
        XCTAssertNil(PadEvidenceModel.site(for: none, in: sites))

        // The browser opens at the site, or on its strip when there is none.
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("pad-evidence-tray-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let browser = BrowserModel(tray: DownloadsTray(directory: folder), store: FixedSavedSites(sites: sites), websiteData: NoWebsiteData())
        browser.preload(sites: sites, current: nil, items: [])
        browser.present(PadEvidenceModel.site(for: tax, in: browser.sites))
        XCTAssertTrue(browser.isPresented)
        XCTAssertEqual(browser.currentSite?.name, "Portal das Finanças")
        let empty = BrowserModel(tray: DownloadsTray(directory: folder), store: FixedSavedSites(sites: []), websiteData: NoWebsiteData())
        empty.present(PadEvidenceModel.site(for: tax, in: empty.sites))
        XCTAssertTrue(empty.isPresented)
        XCTAssertNil(empty.currentSite)
    }

    func testEditsHiddenWithoutDocumentsEdit() async throws {
        let (bill, paid) = try filedYearBill()
        let member = try addMember(documentsLevel: .view)
        let model = await model(.iCloudUser(recordName: member))
        XCTAssertFalse(model.canLink)
        XCTAssertFalse(model.canMarkNotAvailable)
        XCTAssertEqual(model.write.viewOnlyMessage, "View only: you don't have Edit on Documents.")
        XCTAssertFalse(model.items.isEmpty, "she still sees the evidence")
        XCTAssertTrue(model.items.allSatisfy { !$0.canLink })
        // Nothing is written even if asked.
        let item = try XCTUnwrap(model.items.first { $0.item.target.entity == .transaction(paid) })
        let before = try linkRows()
        let linked = await model.link(documentId: bill, to: item)
        XCTAssertFalse(linked)
        let waived = await model.markNotAvailable(item)
        XCTAssertFalse(waived)
        XCTAssertEqual(try linkRows(), before)
        XCTAssertEqual(after.value, 0)

        // With Edit on Documents the edits are back, as herself.
        let editor = try addMember(documentsLevel: .edit, recordName: "_editor")
        let editing = await self.model(.iCloudUser(recordName: editor))
        XCTAssertTrue(editing.canLink)
        XCTAssertTrue(editing.canMarkNotAvailable)
        XCTAssertTrue(editing.items.allSatisfy(\.canLink))
    }

    /// A member sees only what her levels show: no Tax on the demo's people hides their personal items (P60s, HMRC
    /// payments, pensions); the property's stay.
    func testMemberSeesOnlyHerVisibleEvidence() async throws {
        let admin = await model()
        let member = try addMember(documentsLevel: .edit)
        try await db.write { db in
            let user = try XCTUnwrap(try AppUser.filter(Column("cloudKitUserRecordName") == member).fetchOne(db))
            for personId in try Int64.fetchAll(db, sql: "SELECT id FROM person WHERE id <> ?", arguments: [user.personId]) {
                try db.execute(sql: "UPDATE memberPermission SET level = 'none' WHERE appUserId = ? AND area = ?",
                               arguments: [user.id!, try AccessArea.tax(ofPerson: personId, db: db).storageKey])
            }
        }
        let shown = await model(.iCloudUser(recordName: member))
        let personal = admin.items.filter { [.employment, .hmrcPayment, .pensionContribution].contains($0.item.target.entity.type) }
        XCTAssertFalse(personal.isEmpty, "the demo has personal evidence")
        for item in personal { XCTAssertFalse(shown.items.contains { $0.id == item.id }, item.item.title) }
        XCTAssertTrue(shown.areas.contains { $0.area == .lisbonFlat })
        XCTAssertEqual(shown.areas.first { $0.area == .lisbonFlat }?.items, admin.areas.first { $0.area == .lisbonFlat }?.items)
    }

    /// "Mark not available" writes in Property: without Edit there, it is neither offered nor done.
    func testMarkNotAvailableNeedsPropertyEdit() async throws {
        let model = await model()
        model.propertyWrite.preload(canEdit: false)
        XCTAssertTrue(model.canLink)
        XCTAssertFalse(model.canMarkNotAvailable)
        let item = try XCTUnwrap(model.items.first { $0.state == .missing })
        let saved = await model.markNotAvailable(item)
        XCTAssertFalse(saved)
        XCTAssertEqual(after.value, 0)
        XCTAssertNil(model.note(for: item.id))
    }

    /// Before this device's iCloud user is bound to an app user (or a stranger's), and when who she is can't be read,
    /// nothing is shown: never everything.
    func testUnknownViewerSeesNothing() async throws {
        for viewer in [PhoneViewer.iCloudUser(recordName: nil), .iCloudUser(recordName: "_stranger")] {
            let model = await model(viewer)
            XCTAssertTrue(model.areas.isEmpty, "\(viewer)")
            XCTAssertTrue(model.items.isEmpty)
        }
        let member = try addMember(documentsLevel: .edit)
        let today = today, db = db!
        let broken = DeviceWriter(db: try DatabaseQueue(), viewer: { .iCloudUser(recordName: member) }, afterWrite: {})
        let tabs = PhoneTabsModel(dbQueue: db, today: { today }, hasProperty: true, viewer: .demoAdmin, writer: broken)
        await tabs.padEvidence.reload()
        XCTAssertTrue(tabs.padEvidence.areas.isEmpty, "a read error shows nothing")
        // Bound, she sees her own.
        let bound = await model(.iCloudUser(recordName: member))
        XCTAssertFalse(bound.items.isEmpty)
    }

    // MARK: Helpers

    private nonisolated static func day(_ y: Int, _ m: Int, _ d: Int) -> Date {
        MonthRange.calendar.date(from: DateComponents(year: y, month: m, day: d))!
    }

    /// A repair paid in 2025/26 and an unlinked legal bill dated in the filed 2024/25 year.
    private func filedYearBill() throws -> (bill: Int64, paid: Int64) {
        try db.write { db in
            let account = try XCTUnwrap(try Account.filter(Column("name") == "Euro Current").fetchOne(db))
            let repairs = try XCTUnwrap(try Category.filter(Column("name") == "Repairs").fetchOne(db))
            let batch = try XCTUnwrap(try Int64.fetchOne(db, sql: "SELECT importBatchId FROM transaction_ WHERE accountId = ? LIMIT 1",
                                                         arguments: [account.id]))
            var paid = Transaction(importBatchId: batch, accountId: account.id!, date: Self.day(2025, 4, 20),
                                   rawDescription: "PAG CANALIZADOR DEMO 0003", amountMinorUnits: -3_995, categoryId: repairs.id,
                                   status: .confirmed, categorizedBy: .manual, fingerprint: UUID().uuidString)
            try paid.insert(db)
            var bill = EvidenceDocument(sha256: "legal-2024", storedRelativePath: "x/legal.pdf", originalFileName: "legal.pdf", byteCount: 1,
                                        kind: .legalInvoice, docDate: Self.day(2025, 3, 30), amountMinorUnits: 3_995, currency: .eur,
                                        addedAt: Self.day(2025, 4, 21))
            try bill.insert(db)
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
