import XCTest
import GRDB
@testable import BudgetCore
import BudgetDemo
import struct BudgetCore.Transaction
@testable import MangoUI

/// Step 8 Task 8 (Bills and Recharges merged in step 10 Task 11): the iPad's Bills & recharges and Rent receipts actions, each one of the Mac's BudgetCore writes
/// through the device writer (filed years checked), a refusal shown under the row it was made on. Demo data (the admin,
/// `.demoAdmin`), plus a member bound to an iCloud user.
@MainActor
final class PadPropertyActionsTests: XCTestCase {
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
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("pad-actions-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("demo.sqlite").path
        try DemoDatabase.build(at: path, evidenceRoot: folder.appendingPathComponent("Evidence"))
        db = try DatabaseQueue(path: path)
        after = Counter()
    }

    private func writer(_ viewer: PhoneViewer = .demoAdmin) -> DeviceWriter {
        let after = after!
        return DeviceWriter(db: db, viewer: { viewer }, afterWrite: { after.bump() })
    }

    /// The tabs' models over the demo, loaded, the user's Edit read.
    private func tabs(_ viewer: PhoneViewer = .demoAdmin) async -> PhoneTabsModel {
        let today = today
        let tabs = PhoneTabsModel(dbQueue: db, today: { today }, hasProperty: true, viewer: .demoAdmin, writer: writer(viewer))
        await tabs.padProperty.reload()
        await tabs.padWrite.refresh()
        await tabs.padBills.reload()
        await tabs.padTenancies.reload()
        return tabs
    }

    private func bill(_ id: String, _ tabs: PhoneTabsModel) throws -> UtilityBill {
        try XCTUnwrap(tabs.padProperty.bills?.bills.first { $0.id == id }, "bill \(id)")
    }

    /// A demo invoice taken back to an earlier stage by the Mac: September 2026's power bill (invoice 54, on the
    /// draft statement) off the statement, and, for `.invoiceIn`, its payment unlinked.
    private func takeBack(to stage: UtilityBillStage) throws {
        try db.write { db in
            let invoiceId: Int64 = 54
            let statement = try XCTUnwrap(RechargeLine.filter(Column("invoiceId") == invoiceId).fetchOne(db)).statementId
            _ = try Recharges.removeLine(db: db, statementId: statement, invoiceId: invoiceId)
            if stage == .invoiceIn {
                var invoice = try XCTUnwrap(UtilityInvoice.fetchOne(db, key: invoiceId))
                invoice.transactionId = nil
                try Recharges.saveInvoice(db: db, &invoice)
            }
        }
    }

    // MARK: Stages

    func testMarkSentMovesStageToSentToTenant() async throws {
        let tabs = await tabs()
        let bill = try bill("invoice54", tabs)
        XCTAssertEqual(bill.stage, .inRecharge)
        XCTAssertEqual(tabs.padBills.actions(for: bill), [.linkDocument, .markSent, .correctTotal, .openStatement])
        let saved = await tabs.padBills.markSent(bill)
        XCTAssertTrue(saved)
        XCTAssertEqual(try self.bill("invoice54", tabs).stage, .sentToTenant)
        let statement = try await db.read { db in try RechargeStatement.fetchOne(db, key: bill.statement!.id!) }
        XCTAssertEqual(statement?.sentAt, today)
        let origin = try await self.origin("rechargeStatement", bill.statement!.id!)
        XCTAssertEqual(origin, WriteOrigin.edit.rawValue)
    }

    func testRecordPaymentMovesStageToPaidByTenant() async throws {
        let tabs = await tabs()
        let bill = try bill("invoice52", tabs)
        XCTAssertEqual(bill.stage, .sentToTenant)
        XCTAssertEqual(tabs.padBills.actions(for: bill), [.recordPayment, .openStatement])
        let suggestionChoices = await tabs.padBills.paymentSuggestions(for: bill)
        let suggestion = try XCTUnwrap(suggestionChoices.first)
        let saved = await tabs.padBills.recordPayment(bill, suggestion)
        XCTAssertTrue(saved)
        XCTAssertEqual(try self.bill("invoice52", tabs).stage, .paidByTenant)
        XCTAssertEqual(try self.bill("invoice53", tabs).stage, .paidByTenant, "the statement's other bill too")
        let payment = try await db.read { db in
            try RechargePayment.filter(Column("statementId") == bill.statement!.id! && Column("transactionId") == suggestion.transaction.id!).fetchOne(db)
        }
        let paymentOrigin = try await origin("rechargePayment", try XCTUnwrap(payment?.id))
        XCTAssertEqual(paymentOrigin, WriteOrigin.propertyMatching.rawValue)
    }

    func testAddToRechargeMovesStageToInRecharge() async throws {
        try takeBack(to: .linkedToPayment)
        let tabs = await tabs()
        let bill = try bill("invoice54", tabs)
        XCTAssertEqual(bill.stage, .linkedToPayment)
        XCTAssertEqual(tabs.padBills.actions(for: bill), [.linkDocument, .addToRecharge, .correctTotal])
        let saved = await tabs.padBills.addToRecharge(bill)
        XCTAssertTrue(saved)
        let now = try self.bill("invoice54", tabs)
        XCTAssertEqual(now.stage, .inRecharge)
        XCTAssertEqual(now.statement?.status, .draft)
        XCTAssertEqual(now.statement?.month, bill.month, "onto September's draft")
    }

    func testLinkPaymentMovesStageToLinkedToPayment() async throws {
        try takeBack(to: .invoiceIn)
        let tabs = await tabs()
        let bill = try bill("invoice54", tabs)
        XCTAssertEqual(bill.stage, .invoiceIn)
        XCTAssertEqual(tabs.padBills.actions(for: bill), [.linkDocument, .linkPayment, .correctTotal])
        let candidateChoices = await tabs.padBills.paymentCandidates(for: bill)
        let candidate = try XCTUnwrap(candidateChoices.first)
        let saved = await tabs.padBills.linkPayment(bill, transactionId: candidate.id!)
        XCTAssertTrue(saved)
        XCTAssertEqual(try self.bill("invoice54", tabs).stage, .linkedToPayment)
        let origin = try await self.origin("utilityInvoice", 54)
        XCTAssertEqual(origin, WriteOrigin.propertyMatching.rawValue)
    }

    func testLinkInvoiceAttachesTheLibraryDocument() async throws {
        let tabs = await tabs()
        let bill = try bill("invoice54", tabs)
        let documentChoices = await tabs.padBills.invoiceDocuments()
        let document = try XCTUnwrap(documentChoices.first)
        let saved = await tabs.padBills.linkInvoice(bill, documentId: document.id!)
        XCTAssertTrue(saved)
        XCTAssertEqual(try self.bill("invoice54", tabs).invoice?.documentId, document.id)
        let origin = try await self.origin("utilityInvoice", 54)
        XCTAssertEqual(origin, WriteOrigin.documentLink.rawValue)
    }

    func testRechargesScreenMarksSentAndRecordsPayment() async throws {
        let tabs = await tabs()
        let recharges = tabs.padBills
        let draft = try XCTUnwrap(recharges.statements.first { $0.statement.status == .draft })
        XCTAssertEqual(recharges.listAction(for: draft), .prepareEmail)
        XCTAssertTrue(recharges.actions(for: draft).contains(.markSent))
        let sent = try XCTUnwrap(recharges.statements.first { $0.statement.status == .sent })
        XCTAssertEqual(recharges.listAction(for: sent), .recordPayment)
        XCTAssertNil(recharges.listAction(for: try XCTUnwrap(recharges.statements.first { $0.statement.status == .paid })))
        let suggestion = try XCTUnwrap(sent.suggestions.first)
        let paid = await recharges.recordPayment(sent, suggestion)
        XCTAssertTrue(paid)
        XCTAssertEqual(recharges.statements.first { $0.id == sent.id }?.statement.status, .paid)
        let markedSent = await recharges.markSent(draft)
        XCTAssertTrue(markedSent)
        XCTAssertEqual(recharges.statements.first { $0.id == draft.id }?.statement.status, .sent)
        XCTAssertEqual(try self.bill("invoice54", tabs).stage, .sentToTenant, "Bills reads again")
    }

    func testRentReceiptLinkPayment() async throws {
        // October 2026's rent credit has no receipt yet: the Mac issues one; the iPad links the credit.
        let receiptId = try await db.write { db -> Int64 in
            let tenancy = try XCTUnwrap(Tenancy.filter(Column("tenantName") == "Tenant Two").fetchOne(db))
            var receipt = RentReceipt(tenancyId: tenancy.id!, receiptNumber: "R-SYN-1", periodStart: Self.day(2026, 10, 1),
                                      periodEnd: Self.day(2026, 10, 31), receiptDate: Self.day(2026, 10, 12), amountMinorUnits: 120_000)
            try RentReceipts.save(db: db, &receipt)
            return receipt.id!
        }
        let tabs = await tabs()
        let receipt = try XCTUnwrap(tabs.padTenancies.detail.receipts.first { $0.id == receiptId })
        XCTAssertTrue(tabs.padTenancies.actions(for: receipt).contains(.linkPayment))
        let creditChoices = await tabs.padTenancies.candidates(for: receipt)
        let credit = try XCTUnwrap(creditChoices.first)
        XCTAssertEqual(credit.date, Self.day(2026, 10, 12))
        let saved = await tabs.padTenancies.link(receipt, transactionId: credit.id!)
        XCTAssertTrue(saved)
        let now = try XCTUnwrap(tabs.padTenancies.detail.receipts.first { $0.id == receiptId })
        XCTAssertTrue(now.isCovered)
        XCTAssertFalse(tabs.padTenancies.actions(for: now).contains(.linkPayment))
        XCTAssertEqual(after.value, 1)
    }

    // MARK: Permission and refusals

    func testViewOnlyHidesActionsAndShowsCopy() async throws {
        let member = try addMember(propertyLevel: .view)
        let tabs = await tabs(.iCloudUser(recordName: member))
        XCTAssertFalse(tabs.padWrite.canEdit)
        XCTAssertEqual(tabs.padWrite.viewOnlyMessage, DeviceWriteCopy.viewOnly(.property))
        XCTAssertEqual(tabs.padWrite.viewOnlyMessage, "View only: you don't have Edit on Property.")
        for bill in tabs.padProperty.bills?.bills ?? [] { XCTAssertEqual(tabs.padBills.actions(for: bill), []) }
        for statement in tabs.padBills.statements {
            XCTAssertNil(tabs.padBills.listAction(for: statement))
            XCTAssertEqual(tabs.padBills.actions(for: statement), [])
        }
        for receipt in tabs.padTenancies.detail.receipts { XCTAssertEqual(tabs.padTenancies.actions(for: receipt).filter(\.edits), []) }
        // Nothing is written even if asked.
        let saved = await tabs.padBills.markSent(try bill("invoice54", tabs))
        XCTAssertFalse(saved)
        XCTAssertEqual(try self.bill("invoice54", tabs).stage, .inRecharge)
        XCTAssertNil(tabs.padWrite.unsentMessage, "nothing waits to go up")

        // A member with Edit (the default) gets the actions, and writes as herself.
        let editor = try addMember(propertyLevel: .edit, recordName: "_editor")
        let editing = await self.tabs(.iCloudUser(recordName: editor))
        XCTAssertTrue(editing.padWrite.canEdit)
        XCTAssertNil(editing.padWrite.viewOnlyMessage)
        let bill = try self.bill("invoice54", editing)
        XCTAssertEqual(editing.padBills.actions(for: bill), [.linkDocument, .markSent, .correctTotal, .openStatement])
        let marked = await editing.padBills.markSent(bill)
        XCTAssertTrue(marked)
        XCTAssertEqual(try self.bill("invoice54", editing).stage, .sentToTenant)
    }

    /// A member who lost Edit with changes still waiting: they can't go up any more, and the screen says so.
    func testUnsentChangesAfterLosingEditAreShown() async throws {
        let member = try addMember(propertyLevel: .edit)
        let tabs = await tabs(.iCloudUser(recordName: member))
        let bill = try bill("invoice54", tabs)
        let marked = await tabs.padBills.markSent(bill)
        XCTAssertTrue(marked)
        try await db.write { db in
            try db.execute(sql: "UPDATE memberPermission SET level = ? WHERE area = ? AND appUserId = (SELECT id FROM appUser WHERE cloudKitUserRecordName = ?)",
                           arguments: [PermissionLevel.view.rawValue, AccessArea.property.storageKey, member])
        }
        await tabs.padWrite.refresh()
        // Her one change (the statement); the demo's own unsynced rows aren't hers.
        XCTAssertEqual(tabs.padWrite.unsent, 1)
        XCTAssertEqual(tabs.padWrite.unsentMessage, DeviceWriteCopy.notSent(1))
        XCTAssertEqual(DeviceWriteCopy.notSent(1), "1 change not sent — you can no longer change this")
        XCTAssertEqual(DeviceWriteCopy.notSent(3), "3 changes not sent — you can no longer change this")
        XCTAssertEqual(tabs.padBills.actions(for: try self.bill("invoice54", tabs)), [])
    }

    func testFiledYearRefusalShownInline() async throws {
        // The Mac nets 2024/25's utilities of their recharges, then takes back August 2024's tenant payment: recording
        // it again on the iPad would move the filed 2024/25 return. (The demo's recharges start in August 2024, so a
        // 2023/24 statement isn't there to refuse.)
        let statementId: Int64 = 1
        let taken = try await db.write { db -> RechargePayment in
            try RechargeNetting.set(db: db, startYear: 2024, mode: .netOfRecharges)
            let payment = try XCTUnwrap(RechargePayment.filter(Column("statementId") == statementId).fetchOne(db))
            _ = try Recharges.unlinkPayment(db: db, statementId: statementId, transactionId: payment.transactionId)
            return payment
        }
        let tabs = await tabs()
        let bill = try bill("invoice2", tabs)
        XCTAssertEqual(bill.stage, .sentToTenant)
        XCTAssertEqual(tabs.padBills.actions(for: bill), [.recordPayment, .openStatement])
        let suggestion = try await db.read { db in
            Recharges.PaymentSuggestion(statement: try XCTUnwrap(RechargeStatement.fetchOne(db, key: statementId)),
                                        transaction: try XCTUnwrap(Transaction.fetchOne(db, key: taken.transactionId)),
                                        amountMinorUnits: taken.amountMinorUnits, differenceMinorUnits: 0)
        }
        let before = try await db.read { db in try Row.fetchAll(db, sql: "SELECT * FROM rechargePayment ORDER BY id") }
        let saved = await tabs.padBills.recordPayment(bill, suggestion)
        XCTAssertFalse(saved)
        XCTAssertEqual(tabs.padWrite.message(for: bill.id), DeviceWriteCopy.filedYear(years: ["2024/25"]))
        XCTAssertNil(tabs.padWrite.message(for: "invoice3"), "only under the acted-on row")
        XCTAssertEqual(try self.bill("invoice2", tabs), bill, "the row unchanged")
        let afterRows = try await db.read { db in try Row.fetchAll(db, sql: "SELECT * FROM rechargePayment ORDER BY id") }
        XCTAssertEqual(afterRows, before)
        XCTAssertEqual(after.value, 0)
    }

    func testEachActionCallsAfterWriteOnce() async throws {
        try takeBack(to: .invoiceIn)
        let tabs = await tabs()
        let actions = tabs.padBills
        var expected = 0
        func check(_ saved: Bool, _ name: String) {
            expected += 1
            XCTAssertTrue(saved, name)
            XCTAssertEqual(after.value, expected, name)
        }
        let documentChoices = await actions.invoiceDocuments()
        let document = try XCTUnwrap(documentChoices.first)
        do { let saved = await actions.linkInvoice(try bill("invoice54", tabs), documentId: document.id!); check(saved, "link invoice") }
        let candidateChoices = await actions.paymentCandidates(for: try bill("invoice54", tabs))
        let candidate = try XCTUnwrap(candidateChoices.first)
        do { let saved = await actions.linkPayment(try bill("invoice54", tabs), transactionId: candidate.id!); check(saved, "link payment") }
        do { let saved = await actions.addToRecharge(try bill("invoice54", tabs)); check(saved, "add to recharge") }
        do { let saved = await actions.markSent(try bill("invoice54", tabs)); check(saved, "mark sent") }
        let sent = try bill("invoice52", tabs)
        let suggestionChoices = await actions.paymentSuggestions(for: sent)
        let suggestion = try XCTUnwrap(suggestionChoices.first)
        do { let saved = await actions.recordPayment(sent, suggestion); check(saved, "record payment") }
        // A refusal calls nothing.
        _ = await actions.markSent(try bill("invoice54", tabs))
        XCTAssertEqual(after.value, expected)
        XCTAssertNotNil(tabs.padWrite.message(for: "invoice54"), "a sent statement can't be sent again")
    }

    // MARK: Helpers

    private nonisolated static func day(_ y: Int, _ m: Int, _ d: Int) -> Date {
        MonthRange.calendar.date(from: DateComponents(year: y, month: m, day: d))!
    }

    /// A member app user (Person B's) bound to iCloud user `recordName`, with `propertyLevel` on Property.
    private func addMember(propertyLevel: PermissionLevel, recordName: String = "_member") throws -> String {
        try db.write { db in
            var person = Person(name: "Person \(recordName)", shortName: String(recordName.dropFirst().prefix(1)).uppercased())
            try People.save(db: db, &person)
            var user = AppUser(personId: person.id!, displayName: "B", cloudKitUserRecordName: recordName, isAdmin: false,
                               createdAt: Self.day(2026, 1, 1))
            try user.insert(db)
            _ = try SyncRecordStore.uuid(for: "appUser", localId: user.id!, db: db)
            try MemberPermissions.ensureDefaults(appUserId: user.id!, db: db)
            try db.execute(sql: "UPDATE memberPermission SET level = ? WHERE appUserId = ? AND area = ?",
                           arguments: [propertyLevel.rawValue, user.id!, AccessArea.property.storageKey])
        }
        return recordName
    }

    /// The origin a record's latest write was stamped with.
    private func origin(_ table: String, _ id: Int64) async throws -> String? {
        try await db.read { db in
            try String.fetchOne(db, sql: "SELECT origin FROM syncRecord WHERE tableName = ? AND localId = ?", arguments: [table, id])
        }
    }
}
