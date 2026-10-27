import XCTest
import GRDB
@testable import BudgetCore
import TestSupport

/// Step 8 Task 4: the member's iPad tenancy work reaches the admin's Mac, end to end. Two people over one
/// `FakeCloud` (`TwoPersonHousehold`, the Mac re-validating), the household share made read-write by `makeZoneShare`,
/// her device in writer mode (`memberTabletMode`), every write of hers through `DeviceWriter` calling the Mac's own
/// APIs. Each test: she writes, her iPad pushes, the Mac pulls (re-validating) and pushes, she pulls, and the admin's
/// read-only iPhone pulls too. Every save is audited (`ZoneAuditingTransport`): nothing below Everything reaches the
/// household. Synthetic data only.
final class MemberTabletEndToEndTests: XCTestCase {
    private typealias Device = TwoPersonHousehold.Device

    /// The Mac's ids of what the tenancy work needs, beside `SharingFixture`'s.
    private struct Tenancy {
        var tenancy: Int64
        var invoice: Int64
        /// The flat account's debit that paid the invoice.
        var debit: Int64
        /// The tenant's credit paying the recharge.
        var rechargeCredit: Int64
        /// The tenant's rent credit, and the receipt it pays.
        var rentCredit: Int64
        var receipt: Int64
        /// The invoice's document, in the library (a utility invoice: the household's) and linked to nothing yet.
        var document: Int64
        /// October's draft statement, with no line yet.
        var statement: Int64
    }

    private static func day(_ y: Int, _ m: Int, _ d: Int) -> Date {
        UKTaxYear.utcCalendar.date(from: DateComponents(year: y, month: m, day: d))!
    }

    private static let invoiceAmount = 4_200

    // MARK: Household

    /// The household with the member as her iPad and the share read-write, the tenancy's provider, invoice, payments,
    /// receipt and draft statement made on the Mac, everything synced to every device (the admin's iPad too).
    private func household() async throws -> (TwoPersonHousehold, Tenancy) {
        let h = try TwoPersonHousehold.make(revalidatesAccess: true, memberMode: TwoPersonHousehold.memberTabletMode)
        let share = try await h.cloud.makeZoneShare(SyncZones.household, title: "Synthetic household")
        XCTAssertEqual(share.participants.map(\.canWrite), [true], "the share lets her write")
        let f = h.fixture
        let t = try write(h.adminMac) { db -> Tenancy in
            let tenancy = try Int64.fetchOne(db, sql: "SELECT id FROM tenancy WHERE propertyId = ?", arguments: [f.propertyId])!
            var provider = UtilityProvider(propertyId: f.propertyId, name: "Synthetic Power", kind: .electricity)
            try Recharges.saveProvider(db: db, &provider)
            let batch = try Int64.fetchOne(db, sql: "SELECT id FROM importBatch WHERE accountId = ?", arguments: [f.lisbon])!
            func transaction(_ date: Date, _ amount: Int, _ description: String, category: Int64?) throws -> Int64 {
                try db.execute(sql: """
                    INSERT INTO transaction_(importBatchId, accountId, date, rawDescription, amountMinorUnits, categoryId, status, categorizedBy, fingerprint)
                    VALUES (?, ?, ?, ?, ?, ?, 'confirmed', 'rule', ?)
                    """, arguments: [batch, f.lisbon, date, description, amount, category, "e2e-\(description)"])
                return db.lastInsertedRowID
            }
            let debit = try transaction(Self.day(2026, 10, 3), -Self.invoiceAmount, "SYNTHETIC POWER DD", category: nil)
            let rechargeCredit = try transaction(Self.day(2026, 10, 20), Self.invoiceAmount, "TENANT UTILITIES", category: f.propertyCategory)
            let rentCredit = try transaction(Self.day(2026, 10, 1), 70_000, "TENANT RENT", category: f.propertyCategory)
            var invoice = UtilityInvoice(providerId: provider.id!, invoiceNumber: "INV-7", issueDate: Self.day(2026, 10, 1),
                                         amountMinorUnits: Self.invoiceAmount)
            try Recharges.saveInvoice(db: db, &invoice)
            try db.execute(sql: """
                INSERT INTO rentReceipt(tenancyId, receiptNumber, periodStart, periodEnd, amountMinorUnits, amountReceivedMinorUnits)
                VALUES (?, 'R-2', ?, ?, 70000, 70000)
                """, arguments: [tenancy, Self.day(2026, 10, 1), Self.day(2026, 10, 31)])
            let receipt = db.lastInsertedRowID
            try db.execute(sql: """
                INSERT INTO document(sha256, storedRelativePath, originalFileName, byteCount, addedAt, kind) VALUES (?, ?, 'power.pdf', 1, ?, ?)
                """, arguments: [String(repeating: "7", count: 64), "77/power.pdf", Self.day(2026, 10, 2), DocumentKind.utilityInvoice.rawValue])
            let document = db.lastInsertedRowID
            let statement = try Recharges.draftStatement(db: db, tenancyId: tenancy, month: Self.day(2026, 10, 1), addPending: false)
            return Tenancy(tenancy: tenancy, invoice: invoice.id!, debit: debit, rechargeCredit: rechargeCredit, rentCredit: rentCredit,
                           receipt: receipt, document: document, statement: statement.id!)
        }
        try await h.syncAll()
        try await h.adminTablet.engine.pull()
        assertAuditsClean(h)
        return (h, t)
    }

    // MARK: Helpers

    private var memberViewer: PhoneViewer { .iCloudUser(recordName: TwoPersonHousehold.memberICloudUser) }

    /// Her iPad's writer.
    private func writer(_ h: TwoPersonHousehold) -> DeviceWriter {
        let viewer = memberViewer
        return DeviceWriter(db: h.memberDevice.db, viewer: { viewer }, afterWrite: {})
    }

    private func adminTabletWriter(_ h: TwoPersonHousehold) -> DeviceWriter {
        DeviceWriter(db: h.adminTablet.db, viewer: { .iCloudUser(recordName: TwoPersonHousehold.adminICloudUser) }, afterWrite: {})
    }

    /// The local id on `device` of the Mac's row `table`/`id`.
    private func local(_ h: TwoPersonHousehold, _ table: String, _ id: Int64, on device: Device) throws -> Int64 {
        try XCTUnwrap(h.localId(table, uuid: try h.uuid(table, id), on: device), "\(table) \(id) on the device")
    }

    /// Synchronous access (async tests would otherwise pick GRDB's async overloads).
    private func read<T>(_ device: Device, _ body: (Database) throws -> T) throws -> T { try device.db.read(body) }
    private func write<T>(_ device: Device, _ body: (Database) throws -> T) throws -> T { try device.db.write(body) }

    private func value<T: DatabaseValueConvertible>(_ device: Device, _ sql: String, _ arguments: StatementArguments = []) throws -> T? {
        try device.db.read { db in try T.fetchOne(db, sql: sql, arguments: arguments) }
    }

    private func pendingCount(_ device: Device) throws -> Int {
        try value(device, "SELECT COUNT(*) FROM syncPending")!
    }

    private func reverts(_ h: TwoPersonHousehold) throws -> [String] {
        try read(h.adminMac) { db in try AccessRevalidation.recentReverts(limit: 10, db: db) }
    }

    private func assertAuditsClean(_ h: TwoPersonHousehold, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(h.audit.householdViolations(router: h.adminRouter()), [], "admin", file: file, line: line)
        XCTAssertEqual(h.memberAudit.householdViolations(router: TwoPersonHousehold.router(h.memberDevice.db)), [], "member",
                       file: file, line: line)
    }

    /// Her iPad pushes; the Mac pulls (re-validating) and pushes; she pulls, then the admin's iPhone. The audits stay clean.
    private func round(_ h: TwoPersonHousehold, file: StaticString = #filePath, line: UInt = #line) async throws {
        let pushed = try await h.memberDevice.engine.pushPending()
        XCTAssertEqual(pushed.heldBack, 0, "nothing of hers placed outside the household", file: file, line: line)
        try await h.adminMac.engine.syncNow()
        try await h.memberDevice.engine.pull()
        try await h.adminPhone.engine.pull()
        assertAuditsClean(h, file: file, line: line)
    }

    /// The invoice's stage on `device` (as the Mac's tracker reads it there).
    private func stage(_ h: TwoPersonHousehold, _ t: Tenancy, on device: Device) throws -> UtilityBillStage? {
        let property = try local(h, "property", h.fixture.propertyId, on: device)
        let tenancy = try local(h, "tenancy", t.tenancy, on: device)
        let invoice = try local(h, "utilityInvoice", t.invoice, on: device)
        let grid = try device.db.read { db in try UtilityBills.read(db: db, propertyId: property, tenancyId: tenancy) }
        return grid.bills.first { $0.id == "invoice\(invoice)" }?.stage
    }

    private func statementStatus(_ h: TwoPersonHousehold, _ t: Tenancy, on device: Device) throws -> String? {
        try value(device, "SELECT status FROM rechargeStatement WHERE id = ?", [try local(h, "rechargeStatement", t.statement, on: device)])
    }

    private func total(_ h: TwoPersonHousehold, _ t: Tenancy, on device: Device) throws -> Int? {
        try value(device, "SELECT totalMinorUnits FROM rechargeStatement WHERE id = ?", [try local(h, "rechargeStatement", t.statement, on: device)])
    }

    private func lineCount(_ h: TwoPersonHousehold, _ t: Tenancy, on device: Device) throws -> Int {
        try value(device, "SELECT COUNT(*) FROM rechargeLine WHERE statementId = ?", [try local(h, "rechargeStatement", t.statement, on: device)])!
    }

    private func thrown(_ body: () async throws -> Void) async -> Error? {
        do {
            try await body()
            return nil
        } catch {
            return error
        }
    }

    // MARK: Her steps (each through `DeviceWriter`, as the iPad's screens make them)

    /// Attaches the invoice's document and links the invoice to the debit that paid it.
    private func memberRecordsInvoice(_ h: TwoPersonHousehold, _ t: Tenancy) async throws {
        let m = h.memberDevice
        let invoice = try local(h, "utilityInvoice", t.invoice, on: m)
        let document = try local(h, "document", t.document, on: m)
        let debit = try local(h, "transaction_", t.debit, on: m)
        try await writer(h).write(.property, origin: .propertyMatching) { db in
            try UtilityInvoiceIntake.attach(db: db, documentId: document, toInvoice: invoice)
            var row = try XCTUnwrap(UtilityInvoice.fetchOne(db, key: invoice))
            row.transactionId = debit
            try Recharges.saveInvoice(db: db, &row)
        }
    }

    private func memberAddsLine(_ h: TwoPersonHousehold, _ t: Tenancy) async throws {
        let statement = try local(h, "rechargeStatement", t.statement, on: h.memberDevice)
        let invoice = try local(h, "utilityInvoice", t.invoice, on: h.memberDevice)
        try await writer(h).write(.property) { db in _ = try Recharges.setLine(db: db, statementId: statement, invoiceId: invoice) }
    }

    private func memberMarksSent(_ h: TwoPersonHousehold, _ t: Tenancy) async throws {
        let statement = try local(h, "rechargeStatement", t.statement, on: h.memberDevice)
        try await writer(h).write(.property) { db in _ = try Recharges.markSent(db: db, statementId: statement, at: Self.day(2026, 10, 15)) }
    }

    // MARK: Kept

    func testMemberLinksInvoiceDocumentKept() async throws {
        let (h, t) = try await household()
        XCTAssertEqual(try stage(h, t, on: h.adminMac), .invoiceIn)

        try await memberRecordsInvoice(h, t)
        try await round(h)

        let invoice = try XCTUnwrap(try read(h.adminMac) { db in try UtilityInvoice.fetchOne(db, key: t.invoice) })
        XCTAssertEqual(invoice.documentId, t.document, "the Mac keeps the document")
        XCTAssertEqual(invoice.transactionId, t.debit)
        XCTAssertEqual(try stage(h, t, on: h.adminMac), .linkedToPayment)
        XCTAssertEqual(try stage(h, t, on: h.adminPhone), .linkedToPayment, "and the admin's iPhone pulls it")
        XCTAssertEqual(try stage(h, t, on: h.memberDevice), .linkedToPayment)
        XCTAssertEqual(try reverts(h), [])
        XCTAssertEqual(try pendingCount(h.memberDevice), 0)
    }

    func testMemberAddsToRechargeKept() async throws {
        let (h, t) = try await household()
        try await memberRecordsInvoice(h, t)
        try await memberAddsLine(h, t)
        try await round(h)

        XCTAssertEqual(try lineCount(h, t, on: h.adminMac), 1)
        XCTAssertEqual(try value(h.adminMac, "SELECT totalMinorUnits FROM rechargeStatement WHERE id = ?", [t.statement]) as Int?, Self.invoiceAmount)
        XCTAssertEqual(try stage(h, t, on: h.adminMac), .inRecharge)
        XCTAssertEqual(try stage(h, t, on: h.adminPhone), .inRecharge)
        XCTAssertEqual(try reverts(h), [])
    }

    func testMemberMarksSentKept() async throws {
        let (h, t) = try await household()
        try await memberRecordsInvoice(h, t)
        try await memberAddsLine(h, t)
        try await memberMarksSent(h, t)
        try await round(h)

        XCTAssertEqual(try statementStatus(h, t, on: h.adminMac), RechargeStatementStatus.sent.rawValue)
        XCTAssertEqual(try stage(h, t, on: h.adminMac), .sentToTenant)
        XCTAssertEqual(try stage(h, t, on: h.adminPhone), .sentToTenant)
        XCTAssertEqual(try stage(h, t, on: h.memberDevice), .sentToTenant)
        XCTAssertEqual(try reverts(h), [])
    }

    func testMemberRecordsTenantPaymentKept() async throws {
        let (h, t) = try await household()
        try await memberRecordsInvoice(h, t)
        try await memberAddsLine(h, t)
        try await memberMarksSent(h, t)
        try await round(h)
        let statement = try local(h, "rechargeStatement", t.statement, on: h.memberDevice)
        let credit = try local(h, "transaction_", t.rechargeCredit, on: h.memberDevice)
        let paymentUuid = try await writer(h).write(.property, origin: .propertyMatching) { db -> String in
            let payment = try Recharges.linkPayment(db: db, statementId: statement, transactionId: credit)
            return try SyncRecordStore.uuid(for: "rechargePayment", localId: payment.id!, db: db)
        }
        try await round(h)

        let onMac = try XCTUnwrap(h.localId("rechargePayment", uuid: paymentUuid, on: h.adminMac), "the payment arrived and stays")
        XCTAssertEqual(try value(h.adminMac, "SELECT amountMinorUnits FROM rechargePayment WHERE id = ?", [onMac]) as Int?, Self.invoiceAmount)
        XCTAssertEqual(try statementStatus(h, t, on: h.adminMac), RechargeStatementStatus.paid.rawValue)
        XCTAssertEqual(try stage(h, t, on: h.adminMac), .paidByTenant)
        XCTAssertEqual(try stage(h, t, on: h.adminPhone), .paidByTenant)
        XCTAssertEqual(try reverts(h), [])
    }

    func testMemberLinksDocumentKept() async throws {
        let (h, t) = try await household()
        let document = try local(h, "document", t.document, on: h.memberDevice)
        let debit = try local(h, "transaction_", t.debit, on: h.memberDevice)
        let linkUuid = try await writer(h).write(.documents, origin: .documentLink) { db -> String in
            let link = try EvidenceLinks.link(db: db, documentId: document, to: .transaction(debit))
            return try SyncRecordStore.uuid(for: "documentLink", localId: link.id!, db: db)
        }
        let origin: String? = try value(h.memberDevice, "SELECT origin FROM syncRecord WHERE uuid = ?", [linkUuid])
        XCTAssertEqual(origin, WriteOrigin.documentLink.rawValue)
        try await round(h)

        let onMac = try XCTUnwrap(h.localId("documentLink", uuid: linkUuid, on: h.adminMac), "the link arrived and stays")
        XCTAssertEqual(try value(h.adminMac, "SELECT documentId FROM documentLink WHERE id = ?", [onMac]) as Int64?, t.document)
        XCTAssertEqual(try value(h.adminMac, "SELECT entityId FROM documentLink WHERE id = ?", [onMac]) as Int64?, t.debit)
        XCTAssertNotNil(try h.localId("documentLink", uuid: linkUuid, on: h.adminPhone))
        XCTAssertEqual(try reverts(h), [])
    }

    func testMemberLinksRentReceiptPaymentKept() async throws {
        let (h, t) = try await household()
        let receipt = try local(h, "rentReceipt", t.receipt, on: h.memberDevice)
        let credit = try local(h, "transaction_", t.rentCredit, on: h.memberDevice)
        let paymentUuid = try await writer(h).write(.property, origin: .propertyMatching) { db -> String in
            let payment = try RentReceiptMatching.link(db: db, receiptId: receipt, transactionId: credit)
            return try SyncRecordStore.uuid(for: "rentReceiptPayment", localId: payment.id!, db: db)
        }
        try await round(h)

        let onMac = try XCTUnwrap(h.localId("rentReceiptPayment", uuid: paymentUuid, on: h.adminMac), "the link arrived and stays")
        XCTAssertEqual(try value(h.adminMac, "SELECT rentMinorUnits FROM rentReceiptPayment WHERE id = ?", [onMac]) as Int?, 70_000)
        XCTAssertEqual(try value(h.adminMac, "SELECT transactionId FROM rentReceiptPayment WHERE id = ?", [onMac]) as Int64?, t.rentCredit)
        XCTAssertNotNil(try h.localId("rentReceiptPayment", uuid: paymentUuid, on: h.adminPhone))
        XCTAssertEqual(try reverts(h), [])
    }

    // MARK: Reverted

    /// A modified iPad writes past `DeviceWriter` (stamped as her, as every write on her device is): a household
    /// transaction's category, made property money to look like hers to change. The Mac reverts it; every device
    /// converges on the original.
    func testMemberBudgetCategoryChangeRevertedByMac() async throws {
        let (h, _) = try await household()
        let f = h.fixture
        let shared = try local(h, "transaction_", f.sharedTransaction, on: h.memberDevice)
        let propertyCategory = try local(h, "category", f.propertyCategory, on: h.memberDevice)
        try write(h.memberDevice) { db in
            try db.execute(sql: "UPDATE transaction_ SET categoryId = ? WHERE id = ?", arguments: [propertyCategory, shared])
        }
        try await round(h)

        XCTAssertEqual(try value(h.adminMac, "SELECT categoryId FROM transaction_ WHERE id = ?", [f.sharedTransaction]) as Int64?, f.plainCategory)
        for device in [h.memberDevice, h.adminPhone] {
            let here = try local(h, "transaction_", f.sharedTransaction, on: device)
            let plain = try local(h, "category", f.plainCategory, on: device)
            XCTAssertEqual(try value(device, "SELECT categoryId FROM transaction_ WHERE id = ?", [here]) as Int64?, plain, "converged")
        }
        XCTAssertEqual(try reverts(h), ["Reverted a change by B: no permission for Budget & accounts"])
        XCTAssertEqual(try pendingCount(h.memberDevice), 0)
    }

    /// `DeviceWriter` trusts the area its caller names: a write declared Property that changes an amount commits on
    /// her iPad, and the Mac is the gate.
    func testWriteDeclaredPropertyThatChangesAnAmountIsRevertedByMac() async throws {
        let (h, _) = try await household()
        let f = h.fixture
        let lisbon = try local(h, "transaction_", f.lisbonTransaction, on: h.memberDevice)
        try await writer(h).write(.property) { db in
            try db.execute(sql: "UPDATE transaction_ SET amountMinorUnits = 1, note = 'Rent, October' WHERE id = ?", arguments: [lisbon])
        }
        try await round(h)

        for device in [h.adminMac, h.memberDevice, h.adminPhone] {
            let here = try local(h, "transaction_", f.lisbonTransaction, on: device)
            XCTAssertEqual(try value(device, "SELECT amountMinorUnits FROM transaction_ WHERE id = ?", [here]) as Int?, 50_000, "the amount is the Mac's")
            XCTAssertEqual(try value(device, "SELECT note FROM transaction_ WHERE id = ?", [here]) as String?, "Rent, October", "the note is hers")
        }
        XCTAssertEqual(try reverts(h), ["Reverted a change by B: no permission for Budget & accounts"])
    }

    /// Review Focus 2: she queues "mark sent" offline; meanwhile the Mac sets her Property to View. Her push is
    /// reverted by the Mac (whose reply to the first revert push is lost: it converges anyway), her iPad converges,
    /// and once the permission has arrived it refuses the next edit inline.
    func testQueuedEditAfterEditRemovedIsReverted() async throws {
        let (h, t) = try await household()
        try await memberRecordsInvoice(h, t)
        try await memberAddsLine(h, t)
        try await round(h)
        try await memberMarksSent(h, t)  // queued: her iPad is offline

        let memberUser = try read(h.adminMac) { db in
            try Int64.fetchOne(db, sql: "SELECT id FROM appUser WHERE personId = ?", arguments: [h.fixture.personB])!
        }
        try write(h.adminMac) { db in
            try db.execute(sql: """
                INSERT INTO memberPermission(appUserId, area, level) VALUES (?, 'property', 'view')
                ON CONFLICT(appUserId, area) DO UPDATE SET level = 'view'
                """, arguments: [memberUser])
        }
        try await h.adminMac.engine.pushPending()

        // Back online: her queued edit goes out before she has pulled the change.
        try await h.memberDevice.engine.pushPending()
        h.macTransport.loseReply(to: try h.uuid("rechargeStatement", t.statement), in: SyncZones.household)
        _ = try? await h.adminMac.engine.syncNow()  // the revert's save reply is lost
        h.macTransport.restore()
        try await h.adminMac.engine.syncNow()
        try await h.memberDevice.engine.pull()
        try await h.adminPhone.engine.pull()
        assertAuditsClean(h)

        for device in [h.adminMac, h.memberDevice, h.adminPhone] {
            XCTAssertEqual(try statementStatus(h, t, on: device), RechargeStatementStatus.draft.rawValue, "still a draft")
            XCTAssertEqual(try stage(h, t, on: device), .inRecharge)
        }
        XCTAssertEqual(try reverts(h), ["Reverted a change by B: no permission for Property"])
        let canEdit = await writer(h).canEdit(.property)
        XCTAssertFalse(canEdit, "her iPad stops offering edits")
        let error = await thrown { try await self.memberMarksSent(h, t) }
        XCTAssertEqual(error as? AccessDenied, AccessDenied(area: .property))
        XCTAssertEqual(try pendingCount(h.memberDevice), 0)
    }

    // MARK: Both writers

    /// Review Focus 4, as ruled in step 8 Task 8: the Mac marks the statement sent while her iPad, offline, adds a
    /// line to it. A sent statement's lines are fixed: her line is reverted ("Statement already sent"), and the
    /// statement's total, which her line had raised by field merge, is re-derived from its lines on the Mac. Every
    /// device converges on the Mac's sent statement.
    func testMemberLineOnStatementTheMacSentIsReverted() async throws {
        let (h, t) = try await household()
        try await memberRecordsInvoice(h, t)
        try await memberAddsLine(h, t)
        try await round(h)

        try write(h.adminMac) { db in _ = try Recharges.markSent(db: db, statementId: t.statement, at: Self.day(2026, 10, 16)) }
        try await h.adminMac.engine.pushPending()
        let statement = try local(h, "rechargeStatement", t.statement, on: h.memberDevice)
        let lineUuid = try await writer(h).write(.property) { db -> String in  // offline: still a draft on her iPad
            let line = try Recharges.saveManualLine(db: db, statementId: statement, description: "Synthetic cleaning", amountMinorUnits: 1_000)
            return try SyncRecordStore.uuid(for: "rechargeLine", localId: line.id!, db: db)
        }
        try await round(h)
        try await h.memberDevice.engine.pull()  // the Mac's re-derived total, pushed in its round

        for device in [h.adminMac, h.memberDevice, h.adminPhone] {
            XCTAssertEqual(try statementStatus(h, t, on: device), RechargeStatementStatus.sent.rawValue, "the Mac's sent")
            XCTAssertEqual(try lineCount(h, t, on: device), 1, "her line reverted")
            XCTAssertNil(try h.localId("rechargeLine", uuid: lineUuid, on: device))
            XCTAssertEqual(try total(h, t, on: device), Self.invoiceAmount, "the total from the lines again")
            XCTAssertEqual(try stage(h, t, on: device), .sentToTenant)
        }
        XCTAssertEqual(try reverts(h), ["Reverted a change by B: Statement already sent"])
        XCTAssertEqual(try pendingCount(h.memberDevice), 0)
    }

    /// Her own line, then her own "sent", on one device: the Mac keeps both (the statement was hers to send).
    func testMemberLineThenHerOwnSentKept() async throws {
        let (h, t) = try await household()
        try await memberRecordsInvoice(h, t)
        try await memberAddsLine(h, t)
        try await memberMarksSent(h, t)
        try await round(h)
        for device in [h.adminMac, h.memberDevice, h.adminPhone] {
            XCTAssertEqual(try statementStatus(h, t, on: device), RechargeStatementStatus.sent.rawValue)
            XCTAssertEqual(try lineCount(h, t, on: device), 1)
            XCTAssertEqual(try total(h, t, on: device), Self.invoiceAmount)
        }
        XCTAssertEqual(try reverts(h), [])
    }

    /// The Mac reopens the sent statement and adds a line while her iPad, offline, records the tenant's payment of the
    /// old total: field merge keeps her "paid", the Mac's line and the payment. The Mac re-derives the status from what
    /// is owed (still the line's amount): sent, on every device.
    func testStatementStatusRederivedAfterMerge() async throws {
        let (h, t) = try await household()
        try await memberRecordsInvoice(h, t)
        try await memberAddsLine(h, t)
        try await memberMarksSent(h, t)
        try await round(h)

        try write(h.adminMac) { db in
            _ = try Recharges.reopen(db: db, statementId: t.statement)
            _ = try Recharges.saveManualLine(db: db, statementId: t.statement, description: "Synthetic water", amountMinorUnits: 1_000)
        }
        try await h.adminMac.engine.pushPending()
        let statement = try local(h, "rechargeStatement", t.statement, on: h.memberDevice)
        let credit = try local(h, "transaction_", t.rechargeCredit, on: h.memberDevice)
        try await writer(h).write(.property, origin: .propertyMatching) { db in  // offline: sent, 4200 owed, on her iPad
            _ = try Recharges.linkPayment(db: db, statementId: statement, transactionId: credit)
        }
        try await round(h)
        try await h.memberDevice.engine.pull()

        for device in [h.adminMac, h.memberDevice, h.adminPhone] {
            XCTAssertEqual(try total(h, t, on: device), Self.invoiceAmount + 1_000)
            XCTAssertEqual(try statementStatus(h, t, on: device), RechargeStatementStatus.sent.rawValue, "1,000 still owed")
        }
        XCTAssertEqual(try reverts(h), [])
    }

    // MARK: Refused on the iPad

    /// The household with a filed-year shape on the flat: Person A owns it, a 2024/25 rent and a 2024/25 repair on
    /// the flat's account, synced to her iPad. Returns the Mac's repair transaction and the Repairs category.
    private func filedYearHousehold() async throws -> (TwoPersonHousehold, repair: Int64, repairs: Int64) {
        let h = try TwoPersonHousehold.make(revalidatesAccess: true, memberMode: TwoPersonHousehold.memberTabletMode)
        _ = try await h.cloud.makeZoneShare(SyncZones.household, title: "Synthetic household")
        let f = h.fixture
        let (repair, repairs) = try write(h.adminMac) { db -> (Int64, Int64) in
            _ = try Properties.setOwners(db: db, propertyId: f.propertyId, [
                PropertyOwner(propertyId: f.propertyId, personId: f.personA, shareBasisPoints: 10_000),
            ])
            let group = try Int64.fetchOne(db, sql: "SELECT groupId FROM category WHERE id = ?", arguments: [f.propertyCategory])!
            try db.execute(sql: "INSERT INTO category(name, type, groupId) VALUES ('Repairs', 'expense', ?)", arguments: [group])
            let repairs = db.lastInsertedRowID
            try TaxExpenseTypeMap.seed(db: db, propertyId: f.propertyId)
            let batch = try Int64.fetchOne(db, sql: "SELECT id FROM importBatch WHERE accountId = ?", arguments: [f.lisbon])!
            for (date, amount, description, category) in [(Self.day(2024, 6, 1), 500_000, "TENANT RENT 2024", f.propertyCategory),
                                                          (Self.day(2024, 11, 1), -40_000, "PLUMBER 2024", repairs)] {
                try db.execute(sql: """
                    INSERT INTO transaction_(importBatchId, accountId, date, rawDescription, amountMinorUnits, categoryId, status, categorizedBy, fingerprint)
                    VALUES (?, ?, ?, ?, ?, ?, 'confirmed', 'rule', ?)
                    """, arguments: [batch, f.lisbon, date, description, amount, category, "e2e-\(description)"])
            }
            return (db.lastInsertedRowID, repairs)
        }
        try await h.syncAll()
        XCTAssertEqual(try pendingCount(h.memberDevice), 0)
        return (h, repair, repairs)
    }

    /// A 2024/25 repair on the flat re-categorised as rent would change the filed 2024/25 return: her iPad refuses
    /// inline, and nothing is queued nor reaches the cloud.
    func testFiledYearMemberEditNeverReachesCloud() async throws {
        let (h, repair, repairs) = try await filedYearHousehold()
        let m = h.memberDevice
        let repairHere = try local(h, "transaction_", repair, on: m)
        let rent = try local(h, "category", h.fixture.propertyCategory, on: m)
        let savesBefore = h.memberAudit.savesByZone.values.reduce(0) { $0 + $1.count }

        let error = await thrown {
            _ = try await self.writer(h).writeCheckingFiledYears(.property, edit: "Edit transaction",
                                                                 scope: FiledYearEditCheck.Scope(transactionIds: [repairHere])) { db in
                try db.execute(sql: "UPDATE transaction_ SET categoryId = ? WHERE id = ?", arguments: [rent, repairHere])
            }
        }
        guard case .filedYear(let question)? = error as? DeviceWriteRefusal else {
            return XCTFail("expected a filed-year refusal, got \(String(describing: error))")
        }
        XCTAssertEqual(question.years.map(\.label), ["2024/25"])
        XCTAssertEqual(try pendingCount(m), 0, "nothing queued")
        let pushed = try await m.engine.pushPending()
        XCTAssertEqual(pushed.saved, 0)
        XCTAssertEqual(h.memberAudit.savesByZone.values.reduce(0) { $0 + $1.count }, savesBefore, "nothing reached the cloud")
        try await h.adminMac.engine.syncNow()
        try await h.adminPhone.engine.pull()
        XCTAssertEqual(try value(h.adminMac, "SELECT categoryId FROM transaction_ WHERE id = ?", [repair]) as Int64?, repairs)
        assertAuditsClean(h)
    }

    /// A screen that forgets the filed-year check (plain `write`): the re-categorised 2024/25 repair commits on her
    /// iPad and goes up, and the Mac's incoming check holds it for attention: the filed figure never moves on the Mac.
    func testFiledYearEditPastTheIPadCheckIsHeldByMac() async throws {
        let (h, repair, repairs) = try await filedYearHousehold()
        let repairHere = try local(h, "transaction_", repair, on: h.memberDevice)
        let rent = try local(h, "category", h.fixture.propertyCategory, on: h.memberDevice)
        try await writer(h).write(.property) { db in
            try db.execute(sql: "UPDATE transaction_ SET categoryId = ? WHERE id = ?", arguments: [rent, repairHere])
        }
        try await h.memberDevice.engine.pushPending()
        let report = try await h.adminMac.engine.syncNow()
        try await h.adminPhone.engine.pull()

        XCTAssertEqual(report.pull.held, 1, "held for attention")
        XCTAssertNotNil(report.pull.filedYearAlert)
        XCTAssertEqual(try value(h.adminMac, "SELECT categoryId FROM transaction_ WHERE id = ?", [repair]) as Int64?, repairs, "the filed figure stays")
        let onPhone = try local(h, "transaction_", repair, on: h.adminPhone)
        XCTAssertEqual(try value(h.adminPhone, "SELECT categoryId FROM transaction_ WHERE id = ?", [onPhone]) as Int64?,
                       try local(h, "category", repairs, on: h.adminPhone))
        assertAuditsClean(h)
    }

    /// No app user is bound to her iCloud user on this iPad (before the household pull names her): nothing is written.
    func testUnboundIPadWritesNothing() async throws {
        let (h, t) = try await household()
        let statement = try local(h, "rechargeStatement", t.statement, on: h.memberDevice)
        for viewer in [PhoneViewer.iCloudUser(recordName: nil), .iCloudUser(recordName: "fake-stranger")] {
            let unbound = DeviceWriter(db: h.memberDevice.db, viewer: { viewer }, afterWrite: {})
            let error = await thrown {
                _ = try await unbound.write(.property) { db in try Recharges.markSent(db: db, statementId: statement, at: Self.day(2026, 10, 15)) }
            }
            XCTAssertEqual(error as? DeviceWriteRefusal, .notLinkedYet)
        }
        // Her own writer, outside her Edit areas.
        let shared = try local(h, "transaction_", h.fixture.sharedTransaction, on: h.memberDevice)
        let error = await thrown {
            _ = try await self.writer(h).write(.budgetAndAccounts) { db in
                try db.execute(sql: "UPDATE transaction_ SET amountMinorUnits = 1 WHERE id = ?", arguments: [shared])
            }
        }
        XCTAssertEqual(error as? AccessDenied, AccessDenied(area: .budgetAndAccounts))
        XCTAssertEqual(try pendingCount(h.memberDevice), 0, "nothing queued")
        XCTAssertEqual(try statementStatus(h, t, on: h.memberDevice), RechargeStatementStatus.draft.rawValue)
    }

    // MARK: The admin's iPad

    func testAdminTabletEditKeptAndPhoneStillPulls() async throws {
        let (h, t) = try await household()
        try await memberRecordsInvoice(h, t)
        try await memberAddsLine(h, t)
        try await round(h)
        try await h.adminTablet.engine.pull()
        let statement = try local(h, "rechargeStatement", t.statement, on: h.adminTablet)
        try await adminTabletWriter(h).write(.property) { db in
            _ = try Recharges.markSent(db: db, statementId: statement, at: Self.day(2026, 10, 17))
        }
        let pushed = try await h.adminTablet.engine.pushPending()
        XCTAssertEqual(pushed.heldBack, 0)
        try await h.adminMac.engine.syncNow()
        try await h.adminPhone.engine.pull()
        try await h.memberDevice.engine.pull()

        for device in [h.adminMac, h.adminPhone, h.memberDevice, h.adminTablet] {
            XCTAssertEqual(try statementStatus(h, t, on: device), RechargeStatementStatus.sent.rawValue)
        }
        XCTAssertEqual(try stage(h, t, on: h.adminPhone), .sentToTenant)
        XCTAssertEqual(try reverts(h), [])
        assertAuditsClean(h)
    }

    /// Task 1 review M1: the admin's iPad moves a household transaction into his private account. It saves the
    /// transaction in A's zone and leaves only a marker in the household; the member's iPad drops it, the Mac and the
    /// admin's iPhone keep it.
    func testAdminTabletMovesRecordToPrivateZone() async throws {
        let (h, _) = try await household()
        let f = h.fixture
        let tablet = h.adminTablet
        let uuid = try h.uuid("transaction_", f.sharedTransaction)
        XCTAssertNotNil(try h.localId("transaction_", uuid: uuid, on: h.memberDevice))
        let here = try local(h, "transaction_", f.sharedTransaction, on: tablet)
        let privateAccount = try local(h, "account", f.privateAccount, on: tablet)
        let privateBatch = try XCTUnwrap(h.localId("importBatch", uuid: try h.uuid("importBatch", f.privateBatch), on: tablet))
        try await adminTabletWriter(h).write(.budgetAndAccounts) { db in
            try db.execute(sql: "UPDATE transaction_ SET accountId = ?, importBatchId = ? WHERE id = ?", arguments: [privateAccount, privateBatch, here])
        }
        let pushed = try await tablet.engine.pushPending()
        XCTAssertEqual(pushed.heldBack, 0)

        let markerRecord = try await h.cloud.fetch(uuid, zone: SyncZones.household)
        let marker = try SyncLargePayload.payload(from: try XCTUnwrap(markerRecord).wire, keys: try h.adminKeys.allKeys(zone: SyncZones.household))
        XCTAssertEqual(marker.movedTo, f.privateZone, "only a marker in the household")
        XCTAssertTrue(marker.fields.isEmpty)
        let moved = try await h.cloud.fetch(uuid, zone: f.privateZone)
        XCTAssertNotNil(moved, "saved in A's zone")

        try await h.adminMac.engine.syncNow()
        try await h.adminPhone.engine.pull()
        try await h.memberDevice.engine.pull()
        XCTAssertEqual(try value(h.adminMac, "SELECT accountId FROM transaction_ WHERE id = ?", [f.sharedTransaction]) as Int64?, f.privateAccount)
        let onPhone = try local(h, "transaction_", f.sharedTransaction, on: h.adminPhone)
        XCTAssertEqual(try value(h.adminPhone, "SELECT accountId FROM transaction_ WHERE id = ?", [onPhone]) as Int64?,
                       try local(h, "account", f.privateAccount, on: h.adminPhone))
        XCTAssertNil(try h.localId("transaction_", uuid: uuid, on: h.memberDevice), "gone from her iPad")
        assertAuditsClean(h)
    }

    // MARK: Everything

    /// Every step above in one household, then the audits: nothing below Everything ever reached the household.
    func testNothingBelowEverythingReachesHousehold() async throws {
        let (h, t) = try await household()
        try await memberRecordsInvoice(h, t)
        try await memberAddsLine(h, t)
        try await memberMarksSent(h, t)
        let document = try local(h, "document", t.document, on: h.memberDevice)
        let debit = try local(h, "transaction_", t.debit, on: h.memberDevice)
        _ = try await writer(h).write(.documents, origin: .documentLink) { db in
            try EvidenceLinks.link(db: db, documentId: document, to: .transaction(debit))
        }
        let receipt = try local(h, "rentReceipt", t.receipt, on: h.memberDevice)
        let rentCredit = try local(h, "transaction_", t.rentCredit, on: h.memberDevice)
        _ = try await writer(h).write(.property, origin: .propertyMatching) { db in
            try RentReceiptMatching.link(db: db, receiptId: receipt, transactionId: rentCredit)
        }
        try await round(h)
        let statement = try local(h, "rechargeStatement", t.statement, on: h.memberDevice)
        let credit = try local(h, "transaction_", t.rechargeCredit, on: h.memberDevice)
        _ = try await writer(h).write(.property, origin: .propertyMatching) { db in
            try Recharges.linkPayment(db: db, statementId: statement, transactionId: credit)
        }
        try await round(h)
        try await h.adminTablet.engine.pull()

        XCTAssertEqual(try stage(h, t, on: h.adminMac), .paidByTenant)
        XCTAssertEqual(try stage(h, t, on: h.adminTablet), .paidByTenant)
        XCTAssertEqual(try reverts(h), [])
        XCTAssertEqual(h.audit.householdViolations(router: h.adminRouter()), [])
        XCTAssertEqual(h.memberAudit.householdViolations(router: h.adminRouter()), [], "her saves, judged by the Mac's router too")
        XCTAssertEqual(h.memberAudit.householdViolations(router: TwoPersonHousehold.router(h.memberDevice.db)), [])
    }
}
