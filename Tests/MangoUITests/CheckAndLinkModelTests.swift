import XCTest
@testable import MangoUI
import BudgetCore
import TestSupport

/// Step 10 Task 8: the Check and link sheet's state. The engine is a fake (its own behaviour is `CheckAndLinkTests`'s):
/// these prove what the sheet shows, when Save is offered, how a refusal reads, and that Cancel changes nothing.
@MainActor
final class CheckAndLinkModelTests: XCTestCase {
    private var folder: URL!
    private var tray: DownloadsTray!
    private var item: TrayItem!
    private var writer: DeviceWriter!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("check-sheet-tests-" + UUID().uuidString, isDirectory: true)
        tray = DownloadsTray(directory: folder.appendingPathComponent("Tray", isDirectory: true))
        item = try tray.ingest(fileAt: try WebFixtures.copy("bill.pdf"), suggestedName: "bill.pdf", sourceHost: "power.example.test")
        let manager = try TestDatabase.migratedManager()
        writer = DeviceWriter(db: manager.dbQueue, viewer: { .demoAdmin }, afterWrite: {})
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    // MARK: Fake engine

    private final class FakeEngine: CheckAndLinking, @unchecked Sendable {
        var proposal: CheckAndLinkProposal
        var saveError: Error?
        var saves = 0
        var discards = 0
        var payments: [Int64?] = []
        /// What the proposal becomes once the payment is chosen.
        var afterPayment: CheckAndLinkProposal?

        init(_ proposal: CheckAndLinkProposal) { self.proposal = proposal }

        func propose(_ item: TrayItem, in tray: DownloadsTray, propertyId: Int64?) async throws -> CheckAndLinkProposal { proposal }
        func choosePayment(_ transactionId: Int64?, in proposal: CheckAndLinkProposal) async throws -> CheckAndLinkProposal {
            payments.append(transactionId)
            return afterPayment ?? proposal
        }
        func chooseKind(_ choice: ImportKindChoice, in proposal: CheckAndLinkProposal) async throws -> CheckAndLinkProposal { proposal }
        func save(_ proposal: CheckAndLinkProposal, item: TrayItem, tray: DownloadsTray, writer: DeviceWriter,
                  now: Date) async throws -> CheckAndLinkResult {
            saves += 1
            if let saveError { throw saveError }
            if case .statement = proposal { return CheckAndLinkResult(documentId: nil, sentToMac: true, summary: CheckAndLinkCopy.sentToMac) }
            return CheckAndLinkResult(documentId: 1, summary: CheckAndLinkCopy.saved(proposal.check.title))
        }
        func discard(_ item: TrayItem?) { discards += 1 }
        var imports = 0
        var importError: Error?
        func importStatement(_ proposal: CheckAndLinkProposal, item: TrayItem, tray: DownloadsTray, writer: DeviceWriter,
                             importer: PadStatementImport, now: Date) async throws -> CheckAndLinkResult {
            imports += 1
            if let importError { throw importError }
            return CheckAndLinkResult(documentId: nil, importRunId: 9, summary: "1 statement imported")
        }
    }

    /// The lease as another device or the server leaves it (step 19).
    private struct FakeLeases: ImportLeasing {
        var holder: ImportLeaseRecord?
        var offline = false
        var leaseDevice: SyncDevice { SyncDevice(id: "ipad", name: "iPad") }
        func importZones() async -> [String]? { nil }
        func importLeaseHolder() async throws -> ImportLeaseRecord? {
            if offline { throw LeaseStoreError.unavailable("offline") }
            return holder
        }
        func acquireImportLease() async throws {}
        func releaseImportLease() async throws {}
        func catchUp() async throws {}
    }

    private struct FiledYear: LocalizedError {
        var errorDescription: String? { DeviceWriteCopy.filedYear(years: ["2024/25"]) }
    }

    private static func day(_ y: Int, _ m: Int, _ d: Int) -> Date {
        MonthRange.calendar.date(from: DateComponents(year: y, month: m, day: d))!
    }

    private func bill(blockers: [String] = [], toCheck: [String] = [], amountNeedsCheck: Bool = false) -> CheckAndLinkProposal {
        let check = CheckAndLinkCheck(title: "Invoice FT 1/23 of Demo Power", fileName: "bill.pdf", blockers: blockers, toCheck: toCheck)
        let payment = PaymentSuggestion(transactionId: 7, description: "DEMO PWR DD 123", date: Self.day(2023, 3, 20),
                                        amountMinorUnits: 10_000, currency: .eur, reasons: [])
        return .utilityBill(UtilityBillFields(
            check: check, provider: CheckedValue(value: 1, origin: .read), providerName: "Demo Power", propertyId: 1, propertyName: "Property A",
            currency: .eur, periodStart: CheckedValue(value: Self.day(2023, 1, 1), origin: .read),
            periodEnd: CheckedValue(value: Self.day(2023, 2, 28), origin: .read),
            amount: CheckedValue(value: 10_000, origin: .read, needsCheck: amountNeedsCheck),
            issueDate: CheckedValue(value: Self.day(2023, 3, 5), origin: .typed),
            paidBy: payment, paymentChoices: [payment],
            tenantShares: [TenantShare(tenancyId: 1, tenancyName: "Flat A", amountMinorUnits: 4_210, month: Self.day(2023, 3, 1),
                                       joinsStatement: 5, statementMonth: Self.day(2023, 3, 1))]))
    }

    private func statement(blockers: [String] = [], checks: [String] = []) -> CheckAndLinkProposal {
        .statement(StatementImportSummary(
            check: CheckAndLinkCheck(title: "BBVA statement 2023-03", fileName: "statement.pdf", blockers: blockers),
            accountId: 1, accountName: CheckedValue(value: "Bank A", origin: .known), currency: .eur,
            openingBalance: CheckedValue(value: 100_000, origin: .read), closingBalance: CheckedValue(value: 90_000, origin: .read),
            rowsToAdd: 12, alreadyImported: 0, checks: checks, balanceMatches: checks.isEmpty))
    }

    private func model(_ engine: FakeEngine) -> CheckAndLinkModel {
        CheckAndLinkModel(item: item, tray: tray, engine: engine, writer: writer)
    }

    // MARK: Tests

    /// Step 19: with statement import on, the sheet offers Import (the lease free), waits while another device holds it
    /// or offline, and Send to the Mac stays Save's.
    func testStatementRouteDecidesImport() async throws {
        let manager = try TestDatabase.migratedManager()
        let created = Self.day(2026, 1, 1)
        try await manager.dbQueue.write { db in
            var person = Person(name: "Person A", shortName: "A")
            try People.save(db: db, &person)
            var admin = AppUser(personId: person.id!, displayName: "A", isAdmin: true, createdAt: created)
            try admin.insert(db)
        }
        let writer = DeviceWriter(db: manager.dbQueue, viewer: { .demoAdmin }, afterWrite: {})
        let library = EvidenceLibrary(root: folder.appendingPathComponent("Library", isDirectory: true), database: manager.dbQueue)
        func make(_ leases: FakeLeases) -> (CheckAndLinkModel, FakeEngine) {
            let engine = FakeEngine(statement())
            let statements = PadStatementImport(dbQueue: manager.dbQueue, library: library, leases: leases)
            return (CheckAndLinkModel(item: item, tray: tray, engine: engine, writer: writer, statements: statements), engine)
        }

        let (free, freeEngine) = make(FakeLeases())
        await free.start()
        XCTAssertEqual(free.route, .importHere)
        XCTAssertTrue(free.canImport)
        XCTAssertTrue(free.canFinishOnMac, "the admin may hand it to the Mac")
        XCTAssertNil(free.importWaitMessage)
        let imported = await free.importStatement()
        XCTAssertTrue(imported)
        XCTAssertEqual(freeEngine.imports, 1)
        XCTAssertEqual(freeEngine.saves, 0, "not sent to the Mac")
        XCTAssertEqual(free.importedRunId, 9)
        XCTAssertEqual(free.phase, .saved("1 statement imported"))

        let since = Self.day(2026, 10, 28)
        let (held, heldEngine) = make(FakeLeases(holder: ImportLeaseRecord(holderId: "mac", holderName: "Mac", takenAt: since,
                                                                           expiresAt: since.addingTimeInterval(1800))))
        await held.start()
        XCTAssertEqual(held.route, .heldBy(deviceName: "Mac", since: since))
        XCTAssertFalse(held.canImport)
        XCTAssertEqual(held.importWaitMessage, PadStatementImportCopy.heldBy("Mac", since: since))
        let refused = await held.importStatement()
        XCTAssertFalse(refused)
        XCTAssertEqual(heldEngine.imports, 0)

        let (offline, _) = make(FakeLeases(offline: true))
        await offline.start()
        XCTAssertEqual(offline.route, .offline)
        XCTAssertEqual(offline.importWaitMessage, "Connect to the internet to import")

        // Another device took the lease between reading and Import: the refusal updates the route.
        let (raced, racedEngine) = make(FakeLeases())
        racedEngine.importError = PadImportRefusal.heldBy(deviceName: "Mac", since: since)
        await raced.start()
        _ = await raced.importStatement()
        XCTAssertEqual(raced.route, .heldBy(deviceName: "Mac", since: since))
        XCTAssertEqual(raced.refusal, PadStatementImportCopy.heldBy("Mac", since: since))

        // Without statement import (no importer), Save still sends it to the Mac.
        let plain = model(FakeEngine(statement()))
        await plain.start()
        XCTAssertNil(plain.route)
        XCTAssertFalse(plain.canImport)
    }

    func testSaveDisabledUntilRequiredFieldsPresent() async {
        let engine = FakeEngine(bill(blockers: ["Pick the property"]))
        engine.afterPayment = bill()
        let model = model(engine)
        XCTAssertFalse(model.canSave, "nothing read yet")
        await model.start()
        XCTAssertFalse(model.canSave, "a question is still unanswered")
        let saved = await model.save()
        XCTAssertFalse(saved)
        XCTAssertEqual(engine.saves, 0, "Save does nothing while the sheet says it can't")
        await model.choosePayment(7)
        XCTAssertTrue(model.canSave)
        XCTAssertEqual(model.edits, ["Paid by"])
        // A file that is in Mango already can't be saved either.
        let duplicate = FakeEngine(.utilityBill(UtilityBillFields(
            check: CheckAndLinkCheck(title: "Invoice", fileName: "bill.pdf", duplicateOf: "Invoice FT 1/23"), currency: .eur)))
        let other = self.model(duplicate)
        await other.start()
        XCTAssertFalse(other.canSave)
    }

    func testReadFieldsShowReadBadge() async {
        let engine = FakeEngine(bill(toCheck: ["Amount"], amountNeedsCheck: true))
        let model = model(engine)
        await model.start()
        let marks = Dictionary(uniqueKeysWithValues: model.rows.map { ($0.label, $0.mark) })
        XCTAssertEqual(marks["Provider"], .read)
        XCTAssertEqual(marks["Period"], .read)
        XCTAssertEqual(marks["Issued"], CheckRow.Mark.none, "typed by the person: not marked read")
        XCTAssertEqual(marks["Property"], CheckRow.Mark.none, "known from Mango's records")
        // What Save will tick is marked "to check", never silently ticked.
        XCTAssertEqual(marks["Amount"], .toCheck)
        XCTAssertEqual(model.toCheckNames, ["Amount"])
        XCTAssertTrue(model.unshownChecks.isEmpty, "every figure Save ticks has a row marked")
        XCTAssertEqual(model.rows.first { $0.label == "Amount" }?.value, "€100.00")
    }

    func testToCheckWithoutARowIsStillNamed() async {
        let proposal = bill(toCheck: ["Kind", "Reference"])
        let model = model(FakeEngine(proposal))
        await model.start()
        XCTAssertEqual(model.rows.first { $0.label == "Kind" }?.mark, .toCheck)
        XCTAssertEqual(model.unshownChecks, ["Reference"], "the banner names it even where no row shows it")
    }

    func testRechargeLineSaysWhereTheShareGoes() async {
        let model = model(FakeEngine(bill()))
        await model.start()
        let line = try? XCTUnwrap(model.rechargeLines.first)
        XCTAssertEqual(line?.amount, 4_210)
        XCTAssertEqual(line?.who, "Flat A")
        XCTAssertEqual(line?.goes, "Goes into March 2023's recharge statement, still a draft")
    }

    func testSaveShowsFiledYearRefusalInlineAndKeepsSheetOpen() async {
        let engine = FakeEngine(bill())
        engine.saveError = FiledYear()
        let model = model(engine)
        await model.start()
        let saved = await model.save()
        XCTAssertFalse(saved)
        XCTAssertEqual(model.refusal, DeviceWriteCopy.filedYear(years: ["2024/25"]))
        XCTAssertEqual(model.phase, .ready, "the sheet stays open on the file")
        XCTAssertTrue(model.canSave, "and the person can try again")
        XCTAssertEqual(tray.items().count, 1, "the tray item stays")

        engine.saveError = AccessDenied(area: .property)
        _ = await model.save()
        XCTAssertEqual(model.refusal, "You can't change Property in this household.")
        engine.saveError = nil
        let again = await model.save()
        XCTAssertTrue(again)
        XCTAssertNil(model.refusal)
        XCTAssertEqual(model.phase, .saved(CheckAndLinkCopy.saved("Invoice FT 1/23 of Demo Power")))
    }

    func testStatementProposalShowsChecksAndBlocksOnMismatch() async {
        let mismatch = "The closing balance doesn't match the account's saved balance"
        let engine = FakeEngine(statement(blockers: [mismatch], checks: [mismatch]))
        let model = model(engine)
        await model.start()
        XCTAssertTrue(model.isStatement)
        XCTAssertFalse(model.canSave)
        XCTAssertEqual(model.proposal?.check.blockers, [mismatch])
        XCTAssertEqual(model.rows.first { $0.label == "Closing balance" }?.value, "€900.00")
        XCTAssertEqual(model.rows.first { $0.label == "New rows" }?.value, "12")
        _ = await model.save()
        XCTAssertEqual(engine.saves, 0)
    }

    func testStatementSaveSaysSentToTheMac() async {
        let engine = FakeEngine(statement())
        let model = model(engine)
        await model.start()
        XCTAssertTrue(model.canSave)
        let saved = await model.save()
        XCTAssertTrue(saved)
        XCTAssertEqual(model.phase, .saved("Sent to the Mac to import"))
    }

    func testStatementOnMembersIPadSaysSoInPlainWords() async {
        let engine = FakeEngine(statement())
        engine.saveError = CheckAndLinkRefusal.statementNeedsAdmin
        let model = model(engine)
        await model.start()
        _ = await model.save()
        XCTAssertEqual(model.refusal, CheckAndLinkSheetCopy.statementsOnTheMac)
        XCTAssertTrue(model.refusal?.hasPrefix("Statements are imported on the Mac for now") == true)
        XCTAssertEqual(model.phase, .ready)
    }

    func testCheckHiddenWithoutPropertyEdit() {
        XCTAssertTrue(CheckAndLinkModel.offersCheck(canEditProperty: true, canEditDocuments: true))
        XCTAssertFalse(CheckAndLinkModel.offersCheck(canEditProperty: false, canEditDocuments: true))
        XCTAssertFalse(CheckAndLinkModel.offersCheck(canEditProperty: true, canEditDocuments: false))
    }

    func testCancelChangesNothing() async {
        let engine = FakeEngine(bill())
        let model = model(engine)
        await model.start()
        model.cancel()
        XCTAssertEqual(engine.saves, 0)
        XCTAssertEqual(engine.discards, 1, "only the planning copy is released")
        XCTAssertEqual(tray.items().count, 1, "the file stays in the tray")
        XCTAssertEqual(model.phase, .ready)
    }

    func testUnreadableFileSaysWhy() async {
        final class Failing: CheckAndLinking, @unchecked Sendable {
            func propose(_ item: TrayItem, in tray: DownloadsTray, propertyId: Int64?) async throws -> CheckAndLinkProposal {
                throw CheckAndLinkRefusal.notInTray
            }
            func choosePayment(_ transactionId: Int64?, in proposal: CheckAndLinkProposal) async throws -> CheckAndLinkProposal { proposal }
            func chooseKind(_ choice: ImportKindChoice, in proposal: CheckAndLinkProposal) async throws -> CheckAndLinkProposal { proposal }
            func save(_ proposal: CheckAndLinkProposal, item: TrayItem, tray: DownloadsTray, writer: DeviceWriter,
                      now: Date) async throws -> CheckAndLinkResult { fatalError() }
            func discard(_ item: TrayItem?) {}
        }
        let model = CheckAndLinkModel(item: item, tray: tray, engine: Failing(), writer: writer)
        await model.start()
        XCTAssertEqual(model.phase, .failed(CheckAndLinkCopy.notInTray))
        XCTAssertFalse(model.canSave)
    }
}
