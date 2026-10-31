import XCTest
import GRDB
@testable import BudgetCore
import BudgetDemo
@testable import MangoUI

/// Step 10 Task 11: Bills & recharges as one screen: the stage names, the panel's selection and facts, the summary's
/// figures, the actions per bill and statement, and the writes through the device writer. Demo data (the admin).
@MainActor
final class PadBillsAndRechargesModelTests: XCTestCase {
    private var db: DatabaseQueue!
    private let today = DemoDatabase.defaultAsOf

    override func setUp() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("pad-bills-\(UUID().uuidString)")
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
        await tabs.padBills.reload()
        return tabs
    }

    func testGridStageNamesAndOrder() {
        XCTAssertEqual(UtilityBillStage.padLegend.map(\.padName),
                       ["Expected", "Invoice in", "Linked to payment", "In a statement", "Sent", "Paid by tenant"])
        XCTAssertEqual(UtilityBillStage.padLegend, UtilityBillStage.allCases.sorted())
        XCTAssertEqual(Set(UtilityBillStage.allCases.map(\.padSymbol)).count, UtilityBillStage.allCases.count, "never colour alone")
    }

    func testTappingABillSelectsItsDocumentForThePanel() async throws {
        let tabs = await tabs()
        let grid = try XCTUnwrap(tabs.padProperty.bills)
        let cell = try XCTUnwrap(grid.rows.compactMap { row in
            Set(grid.bills.map(\.month)).sorted().compactMap { grid.cell(row: row, month: $0) }.first { $0.bills.first?.invoice?.documentId != nil }
        }.first)
        XCTAssertNil(tabs.padBills.selectedBillId)
        tabs.padBills.select(cell)
        XCTAssertEqual(tabs.padBills.selectedBillId, cell.bills.first?.id)
        XCTAssertEqual(tabs.padBills.selectedDocumentId, cell.bills.first?.invoice?.documentId)
        XCTAssertEqual(tabs.padBills.selectedCell?.id, cell.id)
        tabs.padBills.closePanel()
        XCTAssertNil(tabs.padBills.selectedBill)
    }

    /// One panel for the page: a bill and a statement replace each other, whichever was open first.
    func testABillAndAStatementReplaceEachOtherInThePanel() async throws {
        let tabs = await tabs()
        let grid = try XCTUnwrap(tabs.padProperty.bills)
        let cell = try XCTUnwrap(grid.rows.compactMap { row in
            Set(grid.bills.map(\.month)).sorted().compactMap { grid.cell(row: row, month: $0) }.first { !$0.bills.isEmpty }
        }.first)
        let statement = try XCTUnwrap(tabs.padBills.statements.first)
        tabs.padBills.select(cell)
        XCTAssertNotNil(tabs.padBills.selectedBillId)
        tabs.padBills.openStatementId = statement.id
        XCTAssertNil(tabs.padBills.selectedBillId)
        XCTAssertEqual(tabs.padBills.openStatementId, statement.id)
        tabs.padBills.select(cell)
        XCTAssertNil(tabs.padBills.openStatementId)
        XCTAssertNotNil(tabs.padBills.selectedBillId)
    }

    func testPanelExtraShowsPaidByAndStatement() async throws {
        let tabs = await tabs()
        let bill = try XCTUnwrap(tabs.padProperty.bills?.bills.first { $0.id == "invoice52" })
        XCTAssertEqual(bill.stage, .sentToTenant)
        let facts = Dictionary(uniqueKeysWithValues: tabs.padBills.facts(for: bill).map { ($0.label, $0.value) })
        XCTAssertEqual(facts["Stage"], bill.isPartiallyPaid ? "Sent, part paid" : "Sent")
        XCTAssertTrue(try XCTUnwrap(facts["In statement"]).contains("Sent"))
        XCTAssertTrue(try XCTUnwrap(facts["Paid by"]).hasPrefix("Tenant"))
        XCTAssertNotNil(facts["Sent"])
        let draft = try XCTUnwrap(tabs.padProperty.bills?.bills.first { $0.id == "invoice54" })
        let draftFacts = tabs.padBills.facts(for: draft).map(\.label)
        XCTAssertEqual(draftFacts, ["Stage", "In statement"], "a draft has no payer yet")
    }

    func testEditsHiddenWithoutPropertyEdit() async throws {
        let member = try await db.write { db -> String in
            var person = Person(name: "Person V", shortName: "V")
            try People.save(db: db, &person)
            var user = AppUser(personId: person.id!, displayName: "V", cloudKitUserRecordName: "_viewer", isAdmin: false,
                               createdAt: Date(timeIntervalSince1970: 0))
            try user.insert(db)
            _ = try SyncRecordStore.uuid(for: "appUser", localId: user.id!, db: db)
            try MemberPermissions.ensureDefaults(appUserId: user.id!, db: db)
            try db.execute(sql: "UPDATE memberPermission SET level = ? WHERE appUserId = ? AND area = ?",
                           arguments: [PermissionLevel.view.rawValue, user.id!, AccessArea.property.storageKey])
            return "_viewer"
        }
        let tabs = await tabs(.iCloudUser(recordName: member))
        XCTAssertFalse(tabs.padWrite.canEdit)
        for bill in tabs.padProperty.bills?.bills ?? [] { XCTAssertEqual(tabs.padBills.actions(for: bill), []) }
        for statement in tabs.padBills.statements {
            XCTAssertEqual(tabs.padBills.actions(for: statement), [])
            XCTAssertNil(tabs.padBills.listAction(for: statement))
        }
        let bill = try XCTUnwrap(tabs.padProperty.bills?.bills.first { $0.id == "invoice54" })
        let totalSaved = await tabs.padBills.correctTotal(bill, to: 1_234)
        let matched = await tabs.padBills.matchCredits()
        XCTAssertFalse(totalSaved)
        XCTAssertFalse(matched)
        XCTAssertEqual(tabs.padBills.matchMessage, "This iPad can only view Property, so it cannot match payments")
        let amount = try await db.read { try UtilityInvoice.fetchOne($0, key: 54)?.amountMinorUnits }
        XCTAssertEqual(amount, bill.invoice?.amountMinorUnits)
    }

    func testFiledYearEditRefusedInline() async throws {
        // As the Mac nets 2024/25's utilities of their recharges, taking back August 2024's tenant payment would move the filed return.
        let statementId: Int64 = 1
        try await db.write { db in try RechargeNetting.set(db: db, startYear: 2024, mode: .netOfRecharges) }
        let tabs = await tabs()
        let statement = try XCTUnwrap(tabs.padBills.statements.first { $0.id == statementId })
        let payment = try XCTUnwrap(statement.row.payments.first)
        let before = try await db.read { db in try Row.fetchAll(db, sql: "SELECT * FROM rechargePayment ORDER BY id") }
        let saved = await tabs.padBills.unlink(statement, payment: payment)
        XCTAssertFalse(saved)
        XCTAssertEqual(tabs.padWrite.message(for: "statement1"), DeviceWriteCopy.filedYear(years: ["2024/25"]))
        XCTAssertNil(tabs.padWrite.message(for: "statement2"), "only under the acted-on statement")
        let after = try await db.read { db in try Row.fetchAll(db, sql: "SELECT * FROM rechargePayment ORDER BY id") }
        XCTAssertEqual(after, before)
    }

    func testCorrectInvoiceTotalThroughWriter() async throws {
        let tabs = await tabs()
        let bill = try XCTUnwrap(tabs.padProperty.bills?.bills.first { $0.id == "invoice54" })
        XCTAssertTrue(tabs.padBills.actions(for: bill).contains(.correctTotal))
        let saved = await tabs.padBills.correctTotal(bill, to: 12_345)
        XCTAssertTrue(saved)
        let invoice = try await db.read { try UtilityInvoice.fetchOne($0, key: 54) }
        XCTAssertEqual(invoice?.amountMinorUnits, 12_345)
        let origin = try await db.read { db in
            try String.fetchOne(db, sql: "SELECT origin FROM syncRecord WHERE tableName = 'utilityInvoice' AND localId = 54")
        }
        XCTAssertEqual(origin, WriteOrigin.edit.rawValue)
        // A bill on a sent statement offers no correction, and the Mac's rule refuses it if asked.
        let sent = try XCTUnwrap(tabs.padProperty.bills?.bills.first { $0.id == "invoice52" })
        XCTAssertFalse(tabs.padBills.actions(for: sent).contains(.correctTotal))
        let refused = await tabs.padBills.correctTotal(sent, to: 1)
        XCTAssertFalse(refused)
        XCTAssertNotNil(tabs.padWrite.message(for: "invoice52"))
        let none = await tabs.padBills.correctTotal(bill, to: 0)
        XCTAssertFalse(none, "a total is positive")
    }

    func testEveryMacBillAndRechargeActionIsListed() {
        // The Mac's Bills panel and Recharges tab, by name; each must be answered here and nothing here left unanswered.
        let mac = [
            "Add the invoice…", "Match to a payment…", "Add to a recharge…", "Open statement… to send", "Mark sent",
            "Record tenant payment", "Accept (suggested payment)", "Open statement…", "Unlink payment", "Reopen statement",
            "Delete statement", "Match payments", "Utility invoices…", "Prepare <month>…", "Correct invoice total",
        ]
        XCTAssertEqual(Set(PadBillsAction.macActions.map(\.mac)), Set(mac), "the table is the Mac's list")
        XCTAssertEqual(Set(PadBillsAction.macActions.map(\.pad)), Set(PadBillsAction.allCases), "an action missing on the iPad")
        for action in PadBillsAction.allCases {
            XCTAssertFalse(action.title.isEmpty)
            if let row = action.rowAction { XCTAssertFalse(row.accessibilityLabel.isEmpty) }
        }
    }

    func testSummaryReadsTheYearFigures() async throws {
        let tabs = await tabs()
        let model = tabs.padBills
        XCTAssertEqual(model.year, 2026)
        XCTAssertTrue(model.years.contains(2026))
        let year = model.years.first { (model.figures[$0]?.statements ?? 0) > 0 } ?? 2026
        let figure = try XCTUnwrap(model.figures[year])
        let summary = model.summary(year: year)
        XCTAssertEqual(summary.rechargedMinorUnits, figure.recharged)
        XCTAssertEqual(summary.billsPaidMinorUnits, figure.billsPaid)
        XCTAssertEqual(summary.differenceMinorUnits, figure.difference)
        XCTAssertEqual(summary.outstandingMinorUnits, model.awaiting.reduce(0) { $0 + $1.row.outstandingMinorUnits })
        XCTAssertEqual(summary.reasons.isEmpty, figure.gaps.isEmpty)
        for reason in summary.reasons { XCTAssertEqual(reason.statementIds.count, reason.statementNames.count) }
        model.chosenYear = 2024
        XCTAssertEqual(model.year, 2024)
    }

    func testStatementActionsFollowTheStatus() async throws {
        let tabs = await tabs()
        let model = tabs.padBills
        let draft = try XCTUnwrap(model.statements.first { $0.statement.status == .draft })
        XCTAssertEqual(model.actions(for: draft), [.prepareEmail, .markSent, .deleteStatement])
        let paid = try XCTUnwrap(model.statements.first { $0.statement.status == .paid })
        XCTAssertEqual(model.actions(for: paid), [])
        let sent = try XCTUnwrap(model.statements.first { $0.statement.status == .sent })
        XCTAssertTrue(model.actions(for: sent).contains(.recordPayment))
        XCTAssertEqual(model.pill(for: paid).text, "Paid")
        XCTAssertEqual(model.pill(for: draft).text, "Draft")
    }

    func testUnlinkThenReopenAndMatchCredits() async throws {
        let tabs = await tabs()
        let model = tabs.padBills
        let sent = try XCTUnwrap(model.statements.first { $0.statement.status == .sent })
        let suggestion = try XCTUnwrap(sent.suggestions.first)
        let recorded = await model.recordPayment(sent, suggestion)
        XCTAssertTrue(recorded)
        let paid = try XCTUnwrap(model.statements.first { $0.id == sent.id })
        let payment = try XCTUnwrap(paid.row.payments.last)
        let unlinked = await model.unlink(paid, payment: payment)
        XCTAssertTrue(unlinked)
        let after = try XCTUnwrap(model.statements.first { $0.id == sent.id })
        XCTAssertFalse(after.row.payments.contains { $0.transactionId == payment.transactionId })
        let matched = await model.matchCredits()
        XCTAssertTrue(matched)
        XCTAssertNotNil(model.matchMessage)
        // Run again: nothing is left to match, and it says so.
        _ = await model.matchCredits()
        XCTAssertEqual(model.matchMessage, "Nothing new to match")
    }

    func testMatchMessages() {
        XCTAssertEqual(PadBillsAndRechargesModel.matchMessage(rentLinks: 0, rechargePayments: 0), "Nothing new to match")
        XCTAssertEqual(PadBillsAndRechargesModel.matchMessage(rentLinks: 1, rechargePayments: 0), "Matched 1 payment")
        XCTAssertEqual(PadBillsAndRechargesModel.matchMessage(rentLinks: 1, rechargePayments: 1), "Matched 2 payments")
    }

    func testChargesLineKeepsTheSoFarFigureWhenStepThreeIsDone() {
        let currency = Currency.eur
        var step = ThisMonthChecklist.Step(id: .chargesInGrid, state: .done, headline: "Charges in the grid", detail: nil, actions: [])
        step.detail = "All 3 charges are in the grid."
        XCTAssertEqual(PadThisMonthModel.chargesText(step, soFarMinorUnits: 12_345, currency: currency),
                       "All 3 charges are in the grid. \(Money.format(12_345, currency: currency)) to recharge so far.")
        step.state = .needsYou
        XCTAssertTrue(PadThisMonthModel.chargesText(step, soFarMinorUnits: 0, currency: currency).hasSuffix("to recharge so far."))
    }
}
