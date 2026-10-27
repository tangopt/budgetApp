import XCTest
import GRDB
@testable import BudgetCore
import BudgetDemo
import struct BudgetCore.Transaction
@testable import MangoUI

/// Step 10 Task 10: the This-month screen's model over the demo database: where each action goes, Confirm match through the
/// device writer, which actions need Edit, the tenancy picker and the downloads beside the steps.
@MainActor
final class PadThisMonthModelTests: XCTestCase {
    private var db: DatabaseQueue!
    private let today = DemoDatabase.defaultAsOf

    override func setUp() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("pad-this-month-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("demo.sqlite").path
        try DemoDatabase.build(at: path, evidenceRoot: folder.appendingPathComponent("Evidence"))
        db = try DatabaseQueue(path: path)
    }

    private func tabs(_ viewer: PhoneViewer = .demoAdmin) async -> PhoneTabsModel {
        let today = today
        let writer = DeviceWriter(db: db, viewer: { viewer }, afterWrite: {})
        let tabs = PhoneTabsModel(dbQueue: db, today: { today }, hasProperty: true, viewer: .demoAdmin, writer: writer)
        await tabs.padProperty.reload()
        await tabs.padWrite.refresh()
        await tabs.padThisMonth.reload()
        return tabs
    }

    private func item(_ name: String, host: String? = nil) -> TrayItem {
        TrayItem(id: UUID(), fileName: name, sha256: "00", byteCount: 10, receivedAt: today, sourceHost: host)
    }

    func testActionsRouteToBrowserCheckAndEmail() async throws {
        let model = await tabs().padThisMonth
        let trayId = UUID()
        XCTAssertEqual(model.destination(for: .fetchStatement(.bank)), .site(.bank, name: nil))
        XCTAssertEqual(model.destination(for: .fetchStatement(.tax)), .site(.tax, name: nil))
        XCTAssertEqual(model.destination(for: .check(trayItemId: trayId)), .check(trayId))
        XCTAssertEqual(model.destination(for: .prepareEmail(statementId: 1)), .prepareEmail(statementId: 1))
        XCTAssertEqual(model.destination(for: .markReceived), .recharges)
        XCTAssertNil(model.destination(for: .confirmMatch(transactionId: 1)))
        // An open-site action names the provider so its own saved site opens.
        let provider = try XCTUnwrap(model.checklist?.step(.billsIn)?.providers.compactMap { p in p.providerId.map { (p, $0) } }.first)
        XCTAssertEqual(model.destination(for: .openSite(providerId: provider.1)), .site(.utility, name: provider.0.name))
        // The saved site is the one named like the provider, else the first of that kind.
        let sites = [SavedSite(name: "Bank", url: URL(string: "https://bank.example.test")!, kind: .bank, sortOrder: 0),
                     SavedSite(name: "Example Water", url: URL(string: "https://water.example.test")!, kind: .utility, sortOrder: 1),
                     SavedSite(name: "Example Energy", url: URL(string: "https://energy.example.test")!, kind: .utility, sortOrder: 2)]
        XCTAssertEqual(PadThisMonthModel.site(in: sites, kind: .utility, name: "energy")?.name, "Example Energy")
        XCTAssertEqual(PadThisMonthModel.site(in: sites, kind: .utility, name: "Gas")?.name, "Example Water")
        XCTAssertNil(PadThisMonthModel.site(in: sites, kind: .tax, name: nil))
    }

    func testConfirmMatchWritesThroughDeviceWriterWithFiledYearRefusal() async throws {
        let tabs = await tabs()
        let model = tabs.padThisMonth
        // A sent September statement of 80.00 and a 75.00 tenant credit in its window: not an exact match.
        let tenancyId = try XCTUnwrap(tabs.padProperty.selectedTenancyId)
        let (statementId, creditId) = try await db.write { db -> (Int64, Int64) in
            let tenancy = try XCTUnwrap(Tenancy.fetchOne(db, key: tenancyId))
            let september = MonthRange.of(year: 2026, month: 9).start
            try db.execute(sql: "DELETE FROM rechargeStatement WHERE tenancyId = ? AND month = ?", arguments: [tenancy.id, september])
            var statement = RechargeStatement(tenancyId: tenancy.id!, month: september, totalMinorUnits: 8_000, status: .sent,
                                              sentAt: PropertyDates.day(MonthRange.of(year: 2026, month: 10).start))
            try statement.insert(db)
            let account = try XCTUnwrap(Properties.accounts(db: db, propertyId: tenancy.propertyId, role: .current).first).accountId
            let batch = try XCTUnwrap(Int64.fetchOne(db, sql: "SELECT id FROM importBatch LIMIT 1"))
            let income = try XCTUnwrap(Int64.fetchOne(db, sql: """
                SELECT category.id FROM category JOIN propertyCategoryGroup ON propertyCategoryGroup.categoryGroupId = category.groupId
                WHERE propertyCategoryGroup.propertyId = ? AND category.type = 'income' LIMIT 1
                """, arguments: [tenancy.propertyId]))
            var credit = Transaction(importBatchId: batch, accountId: account,
                                     date: PropertyDates.day(MonthRange.of(year: 2026, month: 10).start).addingTimeInterval(86_400 * 3),
                                     rawDescription: "Transfer from tenant", amountMinorUnits: 7_500, categoryId: income,
                                     status: .confirmed, categorizedBy: .rule, fingerprint: "pad-this-month-credit")
            try credit.insert(db)
            return (statement.id!, credit.id!)
        }
        await model.reload()
        let step = try XCTUnwrap(model.checklist?.step(.lastRechargePaid))
        XCTAssertEqual(step.actions, [.confirmMatch(transactionId: creditId)])
        XCTAssertEqual(model.checklist?.lastStatementId, statementId)

        let saved = await model.confirmMatch(transactionId: creditId)
        XCTAssertTrue(saved)
        let linked = try await db.read { try RechargePayment.filter(Column("statementId") == statementId && Column("transactionId") == creditId).fetchOne($0) }
        XCTAssertEqual(linked?.amountMinorUnits, 7_500)
        XCTAssertNil(tabs.padWrite.message(for: PadThisMonthModel.confirmRow))

        // A filed tax year refuses it, and the refusal is kept under step 1.
        tabs.padWrite.preload(canEdit: true, refusal: PadWriteModel.Refusal(rowId: PadThisMonthModel.confirmRow,
                                                                           message: DeviceWriteCopy.filedYear(years: ["2024/25"])))
        XCTAssertEqual(tabs.padWrite.message(for: PadThisMonthModel.confirmRow), DeviceWriteCopy.filedYear(years: ["2024/25"]))
    }

    func testEditActionsHiddenWithoutPropertyEdit() async throws {
        let editing = await tabs().padThisMonth
        XCTAssertTrue(editing.offers(.confirmMatch(transactionId: 1)))
        XCTAssertTrue(editing.offers(.check(trayItemId: UUID())))
        XCTAssertFalse(editing.offers(.check(trayItemId: UUID()), checkAllowed: false))
        XCTAssertTrue(editing.offers(.prepareEmail(statementId: 1)))
        XCTAssertTrue(editing.offers(.markReceived))

        let viewing = (await tabs()).padThisMonth
        viewing.write.preload(canEdit: false)
        for action: ThisMonthChecklist.ChecklistAction in [.confirmMatch(transactionId: 1), .check(trayItemId: UUID()),
                                                          .prepareEmail(statementId: 1), .markReceived] {
            XCTAssertFalse(viewing.offers(action), "\(action)")
        }
        // Browsing a site changes nothing.
        XCTAssertTrue(viewing.offers(.openSite(providerId: 1)))
        XCTAssertTrue(viewing.offers(.fetchStatement(.bank)))
    }

    /// Before this device's iCloud user is bound to an app user, and when who she is can't be read, the checklist is
    /// hidden: never everything.
    func testUnknownViewerSeesHiddenChecklist() async throws {
        let shown = await tabs().padThisMonth
        XCTAssertEqual(shown.checklist?.isHidden, false)
        for viewer in [PhoneViewer.iCloudUser(recordName: nil), .iCloudUser(recordName: "_stranger")] {
            let model = await tabs(viewer).padThisMonth
            XCTAssertEqual(model.checklist?.isHidden, true, "\(viewer)")
            XCTAssertEqual(model.checklist?.evidenceCount, 0)
        }
        let today = today, db = db!
        let broken = DeviceWriter(db: try DatabaseQueue(), viewer: { .demoAdmin }, afterWrite: {})
        let tabs = PhoneTabsModel(dbQueue: db, today: { today }, hasProperty: true, viewer: .demoAdmin, writer: broken)
        await tabs.padProperty.reload()
        await tabs.padThisMonth.reload()
        XCTAssertEqual(tabs.padThisMonth.checklist?.isHidden, true, "a read error shows nothing")
    }

    func testTenancyPickerChangesChecklist() async throws {
        let tabs = await tabs()
        let model = tabs.padThisMonth
        let ids = tabs.padProperty.tenancies.compactMap(\.id)
        try XCTSkipIf(ids.count < 2, "the demo has one tenancy")
        let first = try XCTUnwrap(model.checklist?.tenancyId)
        let other = try XCTUnwrap(ids.first { $0 != first })
        await model.select(other)
        XCTAssertEqual(model.checklist?.tenancyId, other)
        XCTAssertEqual(model.selectedTenancyId, other)
        XCTAssertNotEqual(model.checklist?.tenancyName, tabs.padProperty.tenancies.first { $0.id == first }?.referenceLabel)
    }

    func testSideColumnShowsDownloadsWaiting() async throws {
        let model = await tabs().padThisMonth
        XCTAssertEqual(model.checklist?.downloadsWaiting, 0)
        let items = [item("Water bill October 2026.pdf", host: "water.example.test"), item("Other.pdf")]
        model.trayItems = { items }
        await model.reload()
        XCTAssertEqual(model.checklist?.downloadsWaiting, 2)
        XCTAssertEqual(model.snapshot?.checklist.tenancyName, model.tenancies.first { $0.id == model.selectedTenancyId }?.referenceLabel)
        // The header's count.
        let checklist = try XCTUnwrap(model.checklist)
        XCTAssertEqual(PadThisMonthView.progressText(checklist), "\(PadThisMonthView.doneCount(checklist)) of 4 done")
    }
}
