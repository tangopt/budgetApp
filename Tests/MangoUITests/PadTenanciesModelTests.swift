import XCTest
import GRDB
@testable import BudgetCore
import BudgetDemo
@testable import MangoUI
import struct BudgetCore.Transaction

/// Step 10 Task 13: Tenancies: the rent paid line, Change and Link payment, what is offered with and without Edit, the
/// tenant's name kept to this screen, filed years refused inline, and every Mac Tenancies action answered. Demo data.
@MainActor
final class PadTenanciesModelTests: XCTestCase {
    private var db: DatabaseQueue!
    private let today = DemoDatabase.defaultAsOf

    override func setUp() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("pad-tenancies-\(UUID().uuidString)")
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
        await tabs.padTenancies.reload()
        return tabs
    }

    private func paidReceipt(_ tabs: PhoneTabsModel) throws -> PadTenanciesModel.Receipt {
        try XCTUnwrap(tabs.padTenancies.detail.receipts.first { !$0.row.payments.isEmpty })
    }

    func testRentPaidLineCopy() async throws {
        XCTAssertEqual(PadTenanciesModel.paidLine(amountMinorUnits: 120_000, date: Self.day(2026, 10, 12), bank: "BBVA", currency: .eur),
                       "Rent paid: tenant transfer of \(Money.format(120_000, currency: .eur)) on 12 Oct 2026 · BBVA")
        XCTAssertEqual(PadTenanciesModel.paidLine(amountMinorUnits: 120_000, date: Self.day(2026, 10, 12), bank: "", currency: .eur),
                       "Rent paid: tenant transfer of €1,200.00 on 12 Oct 2026", "no bank, no trailing separator")
        // Read off the demo: the line names the credit's own amount, day and bank.
        let tabs = await tabs()
        let receipt = try paidReceipt(tabs)
        let credit = try XCTUnwrap(receipt.row.payments.first).transaction
        let account = try await db.read { try Account.fetchOne($0, key: credit.accountId) }
        let bank = PadTenanciesModel.bankLabel(try XCTUnwrap(account))
        XCTAssertEqual(receipt.paidLines.first?.text,
                       PadTenanciesModel.paidLine(amountMinorUnits: credit.amountMinorUnits, date: credit.date, bank: bank, currency: .eur))
        XCTAssertEqual(receipt.paidLines.first?.transactionId, credit.id)
    }

    func testChangeShowsCandidateCredits() async throws {
        // October 2026's credit is a candidate for an unpaid receipt; the paid one offers Change, which swaps its credit in one write.
        let receiptId = try await newReceipt(number: "R-CHG-1", month: 10)
        let tabs = await tabs()
        let unpaid = try XCTUnwrap(tabs.padTenancies.detail.receipts.first { $0.id == receiptId })
        let candidates = await tabs.padTenancies.candidates(for: unpaid)
        let credit = try XCTUnwrap(candidates.first)
        XCTAssertEqual(credit.date, Self.day(2026, 10, 12))
        let propertyId = try XCTUnwrap(tabs.padProperty.property?.id)
        let allowed = try await db.read { db in try Set(RentReceiptMatching.candidateCredits(db: db, propertyId: propertyId).compactMap(\.id)) }
        XCTAssertTrue(candidates.allSatisfy { allowed.contains($0.id!) }, "only the property's rent credits")
        let linked = await tabs.padTenancies.link(unpaid, transactionId: credit.id!)
        XCTAssertTrue(linked)
        let paid = try XCTUnwrap(tabs.padTenancies.detail.receipts.first { $0.id == receiptId })
        XCTAssertTrue(tabs.padTenancies.actions(for: paid).contains(.changePayment))
        XCTAssertFalse(tabs.padTenancies.actions(for: paid).contains(.linkPayment), "covered")
        let others = await tabs.padTenancies.candidates(for: paid)
        XCTAssertFalse(others.contains { $0.id == credit.id }, "the credit that paid it is not offered again")
    }

    func testNoPaidLineWhenUnmatchedShowsLinkAction() async throws {
        let receiptId = try await newReceipt(number: "R-NONE-1", month: 11)
        let tabs = await tabs()
        let receipt = try XCTUnwrap(tabs.padTenancies.detail.receipts.first { $0.id == receiptId })
        XCTAssertEqual(receipt.paidLines, [])
        XCTAssertEqual(receipt.status, .notMatched)
        let actions = tabs.padTenancies.actions(for: receipt)
        XCTAssertTrue(actions.contains(.linkPayment))
        XCTAssertFalse(actions.contains(.changePayment))
        XCTAssertFalse(actions.contains(.unlinkPayment))
        XCTAssertEqual(PadTenanciesAction.linkPayment.rowAction, .linkPayment, "the shared link icon")
    }

    func testReceiptActionsUseTheSharedVocabulary() {
        XCTAssertEqual(PadTenanciesAction.viewReceipt.rowAction, .view)
        XCTAssertEqual(PadTenanciesAction.addDocument.rowAction, .linkDocument)
        XCTAssertEqual(PadTenanciesAction.fetchFromPortal.rowAction, .openSite)
        XCTAssertEqual(PadTenanciesAction.unlinkPayment.rowAction, .unlink)
        XCTAssertTrue(RowAction.unlink.isDestructive)
        XCTAssertEqual(RowAction.openSite.systemImage, "globe")
    }

    func testTenantNameOnlyOnThisScreen() async throws {
        let tabs = await tabs()
        await tabs.padThisMonth.reload()
        await tabs.padBills.reload()
        let names = tabs.padProperty.tenancies.compactMap(\.tenantName).filter { !$0.isEmpty }
        XCTAssertFalse(names.isEmpty)
        var titles = PadSection.allCases.map(\.title)
        // Tenancies' own picker and receipts go by the reference.
        titles += tabs.padProperty.tenancies.map(PadTenanciesScreen.pickerTitle)
        titles += tabs.padTenancies.detail.receipts.map(PadTenanciesModel.monthTitle)
        // This month: every step's words, its providers and the side items.
        if let checklist = tabs.padThisMonth.checklist {
            titles.append(checklist.tenancyName)
            titles += checklist.steps.flatMap { [$0.headline, $0.detail ?? ""] + $0.providers.map(\.name) }
            titles += checklist.side.map(\.headline)
        }
        // Bills & recharges: the summary's words, the statements, the bills' facts and the stage names.
        let summary = tabs.padBills.summary(year: tabs.padBills.year)
        titles += [summary.outstandingCaption, summary.rechargedCaption, summary.differenceCaption] + summary.reasons.map(\.text)
        titles += tabs.padBills.statements.flatMap { [tabs.padBills.pill(for: $0).text, RechargeEmail.monthName($0.statement.month, language: .english)] }
        for bill in tabs.padProperty.bills?.bills ?? [] {
            titles += tabs.padBills.facts(for: bill).flatMap { [$0.label, $0.value] }
            titles += [bill.providerName, bill.stage.padName]
        }
        titles += PadBillsAction.allCases.map(\.title)
        for name in names {
            XCTAssertFalse(titles.contains { $0.localizedCaseInsensitiveContains(name) }, "\(name) appears off the Tenancies screen")
        }
        // This screen does show them.
        let tenancy = try XCTUnwrap(tabs.padProperty.selectedTenancy)
        XCTAssertNotNil(tenancy.tenantName)
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
        let model = tabs.padTenancies
        XCTAssertEqual(model.screenActions(hasBrowser: true), [.fetchFromPortal, .utilityInvoices])
        XCTAssertEqual(model.screenActions(hasBrowser: false), [])
        XCTAssertEqual(model.tenancyActions().filter(\.edits), [])
        for receipt in model.detail.receipts {
            XCTAssertEqual(model.actions(for: receipt).filter(\.edits), [], "no edit is offered, hidden not disabled")
            XCTAssertTrue(model.actions(for: receipt).contains(.viewReceipt))
        }
        // Nothing is written even if asked.
        let receipt = try XCTUnwrap(model.detail.receipts.first)
        let name = receipt.receipt.receiptNumber
        let matched = await model.matchCredits()
        let deleted = await model.delete(try XCTUnwrap(tabs.padProperty.selectedTenancy))
        XCTAssertFalse(matched)
        XCTAssertFalse(deleted)
        let still = try await db.read { try RentReceipt.filter(Column("receiptNumber") == name).fetchCount($0) }
        XCTAssertGreaterThan(still, 0)
        // With Edit the same screen offers them.
        let admin = await self.tabs()
        XCTAssertTrue(admin.padTenancies.screenActions(hasBrowser: false).contains(.newTenancy))
        XCTAssertTrue(admin.padTenancies.tenancyActions().contains(.editTenancy))
        XCTAssertTrue(admin.padTenancies.tenancyActions().contains(.deleteTenancy))
    }

    func testFiledYearRefusalInline() async throws {
        // As the Mac nets 2024/25's utilities of their recharges, deleting the tenancy (its recharge statements go with it) would
        // move the filed return: refused under the tenancy, nothing deleted.
        try await db.write { db in try RechargeNetting.set(db: db, startYear: 2024, mode: .netOfRecharges) }
        let tabs = await tabs()
        let model = tabs.padTenancies
        let tenancy = try XCTUnwrap(tabs.padProperty.selectedTenancy)
        let before = try await db.read { db in try Row.fetchAll(db, sql: "SELECT * FROM rentReceipt ORDER BY id") }
        let deleted = await model.delete(tenancy)
        XCTAssertFalse(deleted)
        XCTAssertEqual(tabs.padWrite.message(for: PadTenanciesModel.tenancyRow(tenancy.id)), DeviceWriteCopy.filedYear(years: ["2024/25"]))
        XCTAssertNil(tabs.padWrite.message(for: "receipt0"), "only under the acted-on row")
        let after = try await db.read { db in try Row.fetchAll(db, sql: "SELECT * FROM rentReceipt ORDER BY id") }
        XCTAssertEqual(after, before)
        let still = try await db.read { try Tenancy.fetchOne($0, key: tenancy.id!) }
        XCTAssertNotNil(still)
    }

    func testEveryMacTenancyActionIsListed() {
        // The Mac's Tenancies tab, More menu and receipt panel, by name; each is answered here and nothing here is left unanswered.
        let mac = [
            "New tenancy…", "Match credits", "Utility invoices…", "Import receipts…", "Edit…", "Add contract…", "Contract documents…",
            "Delete tenancy…", "Receipt details", "View receipt PDF", "Open in Preview", "Show in Documents", "Show the credit", "Edit transaction",
            "Unlink the credit", "Replace PDF…", "Add the receipt PDF…", "Add another PDF…", "Documents…",
        ]
        XCTAssertEqual(PadTenanciesAction.macActions.map(\.mac), mac)
        let answered = Set(PadTenanciesAction.macActions.map(\.pad))
        // What the iPad adds to the Mac's: linking one credit and swapping it.
        XCTAssertEqual(Set(PadTenanciesAction.allCases).subtracting(answered), [.linkPayment, .changePayment])
    }

    func testSaveTenancyAndRentHistoryThroughWriter() async throws {
        let tabs = await tabs()
        let model = tabs.padTenancies
        var draft = try XCTUnwrap(model.draft(editing: nil))
        XCTAssertFalse(draft.canSave, "a reference is needed")
        draft.reference = "Tenancy 3"
        draft.contract = "CT-0003"
        draft.tenant = "Tenant Three"
        draft.start = Self.day(2026, 11, 1)
        draft.rents = [.init(from: Self.day(2026, 11, 1), amountText: "1250.00")]
        draft.depositMonths = 2
        let saved = await model.save(draft)
        XCTAssertTrue(saved)
        let created = try XCTUnwrap(tabs.padProperty.tenancies.first { $0.contractNumber == "CT-0003" })
        XCTAssertEqual(tabs.padProperty.selectedTenancyId, created.id, "the new tenancy is selected")
        XCTAssertEqual(model.detail.rents.map(\.monthlyAmountMinorUnits), [125_000])
        // Edit: Save only; a duplicate contract number is refused inside the form and nothing changes.
        var edit = try XCTUnwrap(model.draft(editing: created))
        edit.contract = "CT-0002"
        let refused = await model.save(edit)
        XCTAssertFalse(refused)
        XCTAssertEqual(tabs.padWrite.message(for: PadTenanciesModel.formRow), "Another tenancy of this property has that contract number.")
        let contract = try await db.read { try Tenancy.fetchOne($0, key: created.id!)?.contractNumber }
        XCTAssertEqual(contract, "CT-0003")
        var bad = try XCTUnwrap(model.draft(editing: created))
        bad.rents = [.init(from: Self.day(2026, 11, 1), amountText: "abc")]
        let invalid = await model.save(bad)
        XCTAssertFalse(invalid)
        XCTAssertEqual(tabs.padWrite.message(for: PadTenanciesModel.formRow), "“abc” isn't an amount.")
        // Delete: the tenancy goes with its rents.
        let deleted = await model.delete(created)
        XCTAssertTrue(deleted)
        let remaining = try await db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM tenancy WHERE contractNumber = 'CT-0003'") }
        XCTAssertEqual(remaining, 0)
    }

    func testChangeSwapsTheCreditInOneWrite() async throws {
        let receiptId = try await newReceipt(number: "R-SWAP-1", month: 10)
        let tabs = await tabs()
        let model = tabs.padTenancies
        let unpaid = try XCTUnwrap(model.detail.receipts.first { $0.id == receiptId })
        let firstChoices = await model.candidates(for: unpaid)
        let first = try XCTUnwrap(firstChoices.first)
        let linked = await model.link(unpaid, transactionId: first.id!)
        XCTAssertTrue(linked)
        // A second rent credit of the same size: the receipt can change to it.
        let copy = first
        let other = try await db.write { db -> Int64 in
            var credit = copy
            credit.id = nil
            credit.date = Self.day(2026, 10, 15)
            credit.rawDescription = "TRF TENANT TWO RENT AGAIN"
            credit.fingerprint = UUID().uuidString
            try credit.insert(db)
            return credit.id!
        }
        let paid = try XCTUnwrap(model.detail.receipts.first { $0.id == receiptId })
        let changed = await model.change(paid, from: first.id!, to: other)
        XCTAssertTrue(changed)
        let now = try XCTUnwrap(model.detail.receipts.first { $0.id == receiptId })
        XCTAssertEqual(now.row.payments.map(\.transaction.id), [other])
    }

    func testReceiptsAreGroupedByYearLatestFirst() async throws {
        let tabs = await tabs()
        let years = tabs.padTenancies.years
        XCTAssertEqual(years.map(\.year), years.map(\.year).sorted(by: >))
        for year in years {
            let starts = year.receipts.map(\.receipt.periodStart)
            XCTAssertEqual(starts, starts.sorted(by: >))
        }
        XCTAssertEqual(years.flatMap(\.receipts).count, tabs.padTenancies.detail.receipts.count)
    }

    func testSelectingAReceiptOpensItsDocumentInThePanel() async throws {
        let tabs = await tabs()
        let model = tabs.padTenancies
        let receipt = try XCTUnwrap(model.detail.receipts.first { $0.row.documentCount > 0 })
        XCTAssertNil(model.selectedReceipt)
        model.select(receipt)
        XCTAssertEqual(model.selectedDocumentId, receipt.row.documentIds.first)
        model.closePanel()
        XCTAssertNil(model.selectedReceipt)
    }

    func testPortalSiteIsTheSavedTaxSite() {
        let sites = [SavedSite(name: "Example Water", url: URL(string: "https://water.example.test")!, kind: .utility, sortOrder: 0),
                     SavedSite(name: "Tax portal", url: URL(string: "https://tax.example.test")!, kind: .tax, sortOrder: 1)]
        XCTAssertEqual(PadTenanciesModel.portalSite(in: sites)?.name, "Tax portal")
        XCTAssertNil(PadTenanciesModel.portalSite(in: [sites[0]]), "none saved: the browser offers Add site")
    }

    // MARK: Helpers

    /// A receipt for the current tenancy with no credit linked yet, for `month` of 2026.
    private func newReceipt(number: String, month: Int) async throws -> Int64 {
        try await db.write { db in
            let tenancy = try XCTUnwrap(Tenancy.filter(Column("tenantName") == "Tenant Two").fetchOne(db))
            var receipt = RentReceipt(tenancyId: tenancy.id!, receiptNumber: number, periodStart: Self.day(2026, month, 1),
                                      periodEnd: Self.day(2026, month, 28), receiptDate: Self.day(2026, month, 12), amountMinorUnits: 120_000)
            try RentReceipts.save(db: db, &receipt)
            return receipt.id!
        }
    }

    private nonisolated static func day(_ year: Int, _ month: Int, _ day: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }
}
