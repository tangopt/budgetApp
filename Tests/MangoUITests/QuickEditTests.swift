import XCTest
import GRDB
@testable import BudgetCore
import BudgetDemo
import struct BudgetCore.Category
import struct BudgetCore.Transaction
@testable import MangoUI

/// Step 7b Task 5: the iPhone's quick-edit model over the demo database: the sheet's draft saved only on Save, no
/// controls for a view-only member, a filed year refused inline, Quick sort with its Undo toast, Update balance only on
/// manual accounts, and nothing at all on demo data (no writer).
@MainActor
final class QuickEditTests: XCTestCase {
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
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("quick-edit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("demo.sqlite").path
        try DemoDatabase.build(at: path, evidenceRoot: folder.appendingPathComponent("Evidence"))
        db = try DatabaseQueue(path: path)
        after = Counter()
    }

    private func model(_ viewer: PhoneViewer? = .demoAdmin) -> QuickEditModel {
        let after = after!
        let writer = viewer.map { viewer in DeviceWriter(db: db, viewer: { viewer }, afterWrite: { after.bump() }) }
        let today = today
        let model = QuickEditModel(writer: writer, dbQueue: db, today: { today })
        model.viewer = viewer ?? .everyone
        return model
    }

    private func transaction(_ description: String) throws -> Transaction {
        try db.read { db in try XCTUnwrap(Transaction.filter(Column("rawDescription") == description).fetchOne(db), description) }
    }

    private func categoryId(_ name: String) throws -> Int64 {
        try db.read { db in try XCTUnwrap(Category.filter(Column("name") == name).fetchOne(db)?.id, name) }
    }

    /// A member of Person B's with `level` on Budget & accounts and Property.
    private func addMember(level: PermissionLevel) throws -> PhoneViewer {
        try db.write { db in
            var person = Person(name: "Person M", shortName: "M")
            try People.save(db: db, &person)
            var user = AppUser(personId: person.id!, displayName: "M", cloudKitUserRecordName: "_member", isAdmin: false,
                               createdAt: DemoDatabase.defaultAsOf)
            try user.insert(db)
            _ = try SyncRecordStore.uuid(for: "appUser", localId: user.id!, db: db)
            try MemberPermissions.ensureDefaults(appUserId: user.id!, db: db)
            for area in [AccessArea.property, .budgetAndAccounts] {
                try db.execute(sql: "UPDATE memberPermission SET level = ? WHERE appUserId = ? AND area = ?",
                               arguments: [level.rawValue, user.id!, area.storageKey])
            }
        }
        return .iCloudUser(recordName: "_member")
    }

    func testSheetDraftWritesNothingUntilSave() async throws {
        let model = model()
        let target = try transaction("AMZN MKTPLACE 2Q4X")
        let groceries = try categoryId("Groceries")
        let fetched = await model.row(transactionId: target.id!)
        let row = try XCTUnwrap(fetched)
        let canEdit = await model.canEdit(transactionId: target.id!)
        XCTAssertTrue(canEdit)
        // The sheet holds its draft in its own state: building it (and loading the choices) writes nothing.
        model.preload(lists: QuickEditModel.readListsNow(db))
        var draft = TransactionDraft(row: row)
        XCTAssertFalse(draft.differs(from: row))
        draft.note = "  weekly shop "
        XCTAssertTrue(draft.differs(from: row))
        draft = TransactionDraft(row: row)
        draft.categoryId = groceries
        XCTAssertEqual(draft.differs(from: row), row.transaction.categoryId != groceries)
        draft = TransactionDraft(row: row)
        draft.note += "   "
        XCTAssertFalse(draft.differs(from: row), "spaces are no change")
        _ = TransactionDetailSheet(row: row)
        XCTAssertEqual(after.value, 0)
        XCTAssertEqual(try transaction("AMZN MKTPLACE 2Q4X"), target)

        let saved = await model.save(transactionId: target.id!, categoryId: groceries, note: "  weekly shop ")
        XCTAssertTrue(saved)
        XCTAssertEqual(after.value, 1)
        let after = try transaction("AMZN MKTPLACE 2Q4X")
        XCTAssertEqual(after.categoryId, groceries)
        XCTAssertEqual(after.note, "weekly shop")
        XCTAssertNil(model.refusal)
    }

    func testViewOnlyMemberSeesNoEditControls() async throws {
        let viewer = try addMember(level: .view)
        let model = model(viewer)
        let target = try transaction("AMZN MKTPLACE 2Q4X")
        let canEdit = await model.canEdit(transactionId: target.id!)
        XCTAssertFalse(canEdit)
        let manual = try await db.read { db in try XCTUnwrap(Account.filter(Column("trackingMode") == AccountTrackingMode.manual.rawValue).fetchOne(db)?.id) }
        let canUpdate = await model.canUpdateBalance(accountId: manual)
        XCTAssertFalse(canUpdate)
        await model.load()
        XCTAssertTrue(model.queue.isEmpty, "no Quick sort without Edit")
    }

    func testFiledYearRefusalShownInline() async throws {
        let repair = try transaction("BOILER REPAIR LDA")
        let before = repair
        let groceries = try categoryId("Groceries")
        // What the writer refuses with, for the copy the banner must show.
        let writer = DeviceWriter(db: db, viewer: { .demoAdmin }, afterWrite: {})
        var refusal: DeviceWriteRefusal?
        do {
            try await PhoneQuickEdits.categorise(writer: writer, transactionId: repair.id!, categoryId: groceries, note: nil)
        } catch let error as DeviceWriteRefusal {
            refusal = error
        }
        guard case .filedYear(let question)? = refusal else { return XCTFail("expected a filed-year refusal") }

        let model = model()
        let saved = await model.save(transactionId: repair.id!, categoryId: groceries, note: nil)
        XCTAssertFalse(saved)
        XCTAssertEqual(model.refusal, DeviceWriteCopy.filedYear(years: question.years.map(\.label)))
        XCTAssertEqual(try transaction("BOILER REPAIR LDA"), before, "the row unchanged")
        XCTAssertEqual(after.value, 0)
    }

    func testQuickSortPickRemovesCardAndShowsToast() async throws {
        let model = model()
        await model.load()
        let first = try XCTUnwrap(model.queue.first)
        let count = model.queue.count
        let groceries = try categoryId("Groceries")
        await model.pick(card: first, categoryId: groceries)
        XCTAssertEqual(model.queue.count, count - 1)
        XCTAssertFalse(model.queue.contains { $0.id == first.id })
        XCTAssertEqual(model.toast?.message, DeviceWriteCopy.categorisedToast("Groceries"))
        XCTAssertEqual(model.toast?.canUndo, true)
        let saved = try await db.read { db in try XCTUnwrap(Transaction.fetchOne(db, key: first.id)) }
        XCTAssertEqual(saved.categoryId, groceries)
    }

    func testUndoPutsCardBack() async throws {
        let model = model()
        await model.load()
        let first = try XCTUnwrap(model.queue.first)
        let count = model.queue.count
        let before = try await db.read { db in try XCTUnwrap(Transaction.fetchOne(db, key: first.id)) }
        let groceries = try categoryId("Groceries")
        await model.pick(card: first, categoryId: groceries)
        await model.undo()
        XCTAssertEqual(model.queue.count, count)
        XCTAssertTrue(model.queue.contains { $0.id == first.id })
        XCTAssertEqual(model.toast?.message, DeviceWriteCopy.undoneToast)
        XCTAssertEqual(model.toast?.canUndo, false)
        let restored = try await db.read { db in try XCTUnwrap(Transaction.fetchOne(db, key: first.id)) }
        XCTAssertNil(restored.categoryId)
        XCTAssertEqual(restored.status, before.status)
    }

    func testToastGoesByItself() async throws {
        let model = model()
        model.toastDuration = .milliseconds(60)
        await model.load()
        let first = try XCTUnwrap(model.queue.first)
        let groceries = try categoryId("Groceries")
        await model.pick(card: first, categoryId: groceries)
        XCTAssertNotNil(model.toast)
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertNil(model.toast)
    }

    func testSuggestionComesFirst() async throws {
        let model = model()
        await model.load()
        let groceries = try categoryId("Groceries")
        let card = PhoneQuickEdits.QuickSortCard(id: 1, description: "X", accountName: "A", date: today, amountMinorUnits: -500, currency: .gbp,
                                                 suggestedCategoryId: groceries)
        let choices = QuickSortChoices(card: card, lists: model.lists)
        XCTAssertEqual(choices.top.first?.id, groceries)
        XCTAssertLessThanOrEqual(choices.top.count, QuickSortChoices.topCount)
        let shown = Set(choices.top.compactMap(\.id))
        XCTAssertTrue(choices.more.flatMap(\.categories).allSatisfy { !shown.contains($0.id!) }, "More… holds the rest")
    }

    func testBalanceSheetOnlyForManualAccounts() async throws {
        let model = model()
        let (manual, imported) = try await db.read { db -> (Int64, Int64) in
            (try XCTUnwrap(Account.filter(Column("trackingMode") == AccountTrackingMode.manual.rawValue).fetchOne(db)?.id),
             try XCTUnwrap(Account.filter(Column("trackingMode") == AccountTrackingMode.imported.rawValue).fetchOne(db)?.id))
        }
        let manualOffered = await model.canUpdateBalance(accountId: manual)
        let importedOffered = await model.canUpdateBalance(accountId: imported)
        XCTAssertTrue(manualOffered)
        XCTAssertFalse(importedOffered)
        let saved = await model.updateBalance(accountId: imported, enteredMinorUnits: 100, asOf: today, note: nil)
        XCTAssertFalse(saved)
        XCTAssertEqual(model.refusal, QuickEditError.notManual.errorDescription)
    }

    func testDemoDataOffersNoEditing() async throws {
        let model = model(nil)
        XCTAssertFalse(model.isAvailable)
        let target = try transaction("AMZN MKTPLACE 2Q4X")
        let canEdit = await model.canEdit(transactionId: target.id!)
        XCTAssertFalse(canEdit)
        await model.load()
        XCTAssertTrue(model.queue.isEmpty)
        let saved = await model.save(transactionId: target.id!, categoryId: nil, note: "x")
        XCTAssertFalse(saved)
        XCTAssertEqual(try transaction("AMZN MKTPLACE 2Q4X"), target)
    }
}
