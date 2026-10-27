import XCTest
import GRDB
@testable import BudgetCore
import TestSupport

/// Step 10 Task 7: a PDF in the iPad's Downloads tray is checked and linked as the Mac's import reads a dropped file,
/// and saved only on Save, through `DeviceWriter.writeCheckingFiledYears`. Synthetic data only: admin Person A
/// (iCloud "_admin") owns Property A with provider Demo Power; member Person B ("_member").
final class CheckAndLinkTests: XCTestCase {
    private var manager: DatabaseManager!
    private var queue: DatabaseQueue { manager.dbQueue }
    private var folder: URL!
    private var library: EvidenceLibrary!
    private var tray: DownloadsTray!
    private var engine: CheckAndLink!
    private var ids: [String: Int64] = [:]

    private static let admin = "_admin"
    private static let member = "_member"

    private static let powerRules = UtilityInvoiceRules(
        textMarkers: ["DEMO POWER"], fileNameMarkers: ["LUZ"],
        invoiceNumberPatterns: [#"INVOICE NO\.?\s*(FT \d+/\d+)"#],
        issueDateLabels: ["ISSUED ON"], periodLabels: ["BILLING PERIOD:"],
        amountLabels: ["AMOUNT DUE"], refundLabels: ["AMOUNT TO REFUND"])

    private static let invoiceLines = [
        "Demo Power - customer copy",
        "Issued on: 5 de março 2023",
        "Billing period: 1 de janeiro a 28 de fevereiro 2023",
        "Amount due 100,00 EUR",
        "Invoice no. FT 1/23"
    ]

    private static func day(_ y: Int, _ m: Int, _ d: Int) -> Date {
        MonthRange.calendar.date(from: DateComponents(year: y, month: m, day: d))!
    }

    override func setUpWithError() throws {
        manager = try TestDatabase.migratedManager()
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("CheckAndLinkTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        library = EvidenceLibrary(root: folder.appendingPathComponent("Library", isDirectory: true), database: queue)
        tray = DownloadsTray(directory: folder.appendingPathComponent("Tray", isDirectory: true))
        engine = CheckAndLink(dbQueue: queue, library: library, stagingRoot: folder.appendingPathComponent("Staging", isDirectory: true))
        ids = try queue.write { db in
            var ids: [String: Int64] = [:]
            var a = Person(name: "Person A", shortName: "A")
            try People.save(db: db, &a)
            var b = Person(name: "Person B", shortName: "B")
            try People.save(db: db, &b)
            ids["A"] = a.id!
            var admin = AppUser(personId: a.id!, displayName: "A", cloudKitUserRecordName: Self.admin, isAdmin: true, createdAt: Self.day(2026, 1, 1))
            try admin.insert(db)
            var member = AppUser(personId: b.id!, displayName: "B", cloudKitUserRecordName: Self.member, isAdmin: false, createdAt: Self.day(2026, 1, 1))
            try member.insert(db)
            ids["memberUser"] = member.id!
            var property = Property(name: "Property A", country: "PT", currency: .gbp)
            try Properties.save(db: db, &property)
            ids["property"] = property.id!
            _ = try Properties.setOwners(db: db, propertyId: property.id!, [
                PropertyOwner(propertyId: property.id!, personId: a.id!, shareBasisPoints: 10_000)
            ])
            var account = Account(name: "Bank A", currency: .gbp, kind: .cash, trackingMode: .imported)
            try account.insert(db)
            ids["account"] = account.id!
            var batch = ImportBatch(accountId: account.id!, sourceFileName: "bank.csv", importedAt: Self.day(2025, 1, 1))
            try batch.insert(db)
            ids["batch"] = batch.id!
            try Properties.setAccount(db: db, propertyId: property.id!, accountId: account.id!, role: .current)
            var group = CategoryGroup(name: "Property A")
            try group.insert(db)
            try Properties.addCategoryGroup(db: db, propertyId: property.id!, categoryGroupId: group.id!)
            var electricity = Category(name: "Electricity", type: .expense, groupId: group.id)
            try electricity.insert(db)
            ids["electricity"] = electricity.id!
            try TaxExpenseTypeMap.seed(db: db, propertyId: property.id!)
            // Utilities claimed as a cost, so an invoice's date shows on the return.
            try TaxExpenseTypeMap.set(db: db, categoryId: electricity.id!, expenseType: .utilities)
            var power = UtilityProvider(propertyId: property.id!, name: "Demo Power", kind: .electricity,
                                        bankDescriptionPattern: "DEMO PWR", invoiceRules: Self.powerRules)
            try Recharges.saveProvider(db: db, &power)
            ids["provider"] = power.id!
            return ids
        }
    }

    override func tearDownWithError() throws {
        engine.discard()
        try? FileManager.default.removeItem(at: folder)
    }

    // MARK: Helpers

    private func id(_ key: String) -> Int64 { ids[key]! }

    private func writer(_ recordName: String = CheckAndLinkTests.admin) -> DeviceWriter {
        DeviceWriter(db: queue, viewer: { .iCloudUser(recordName: recordName) }, afterWrite: {})
    }

    /// A synthetic PDF of `lines` in the tray, as a download named `name`.
    private func download(_ lines: [String], name: String) throws -> TrayItem {
        let url = EvidenceTestPDFs.textPDF(lines, name: name)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        return try tray.ingest(fileAt: url, suggestedName: name, sourceHost: "power.example.test")
    }

    private func invoice() throws -> TrayItem { try download(Self.invoiceLines, name: "fatura-luz.pdf") }

    @discardableResult
    private func debit(_ date: Date, _ amount: Int, _ text: String, category: String? = "electricity") throws -> Int64 {
        try queue.write { db in
            var transaction = Transaction(importBatchId: id("batch"), accountId: id("account"), date: date, rawDescription: text,
                                          amountMinorUnits: amount, categoryId: category.map(id), status: .confirmed,
                                          categorizedBy: .manual, fingerprint: UUID().uuidString)
            try transaction.insert(db)
            return transaction.id!
        }
    }

    /// Rows of every table Save can write, and the changes waiting to sync.
    private func counts() throws -> [String: Int] {
        try queue.read { db in
            var counts: [String: Int] = [:]
            for table in ["document", "documentLink", "utilityInvoice", "transaction_", "importBatch", "importRun", "rechargeLine"] {
                counts[table] = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)")!
            }
            counts["pending"] = try SyncChangeTracker.pending(db: db).count
            return counts
        }
    }

    private func storedFiles() -> [String] {
        let root = folder.appendingPathComponent("Library", isDirectory: true)
        let found = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL } ?? []
        return found.filter { !$0.hasDirectoryPath && !$0.lastPathComponent.hasPrefix(".") }.map(\.lastPathComponent)
    }

    private func bill(_ proposal: CheckAndLinkProposal, file: StaticString = #filePath, line: UInt = #line) throws -> UtilityBillFields {
        guard case .utilityBill(let fields) = proposal else {
            XCTFail("not a utility bill: \(proposal)", file: file, line: line)
            throw CancellationError()
        }
        return fields
    }

    private func thrown(_ body: () async throws -> Void) async -> Error? {
        do {
            try await body()
            return nil
        } catch {
            return error
        }
    }

    // MARK: Utility bills

    func testUtilityInvoiceProposalMatchesMacIntake() async throws {
        let paid = try debit(Self.day(2023, 3, 20), -10_000, "DEMO PWR DD 123")
        let item = try invoice()
        let fields = try bill(try await engine.propose(item, in: tray))

        // The Mac's intake, on the same file.
        let text = UtilityInvoiceIntake.text(of: tray.fileURL(for: item), ocr: false).text
        let mac = try await queue.read { db in
            try UtilityInvoiceIntake.propose(db: db, propertyId: self.id("property"), documentId: nil, text: text, fileName: item.fileName,
                                             textStatus: .text)
        }
        XCTAssertEqual(fields.provider?.value, mac.reading.providerId)
        XCTAssertEqual(fields.provider?.value, id("provider"))
        XCTAssertEqual(fields.providerName, "Demo Power")
        XCTAssertEqual(fields.propertyId, id("property"))
        XCTAssertEqual(fields.invoiceNumber?.value, mac.reading.invoiceNumber)
        XCTAssertEqual(fields.issueDate?.value, mac.reading.issueDate)
        XCTAssertEqual(fields.periodStart?.value, mac.reading.periodStart)
        XCTAssertEqual(fields.periodEnd?.value, mac.reading.periodEnd)
        XCTAssertEqual(fields.amount?.value, mac.reading.amountMinorUnits)
        XCTAssertEqual(fields.amount?.value, 10_000)
        XCTAssertEqual(fields.paidBy?.transactionId, mac.transactionId)
        XCTAssertEqual(fields.paidBy?.transactionId, paid)
        XCTAssertEqual(fields.kind, .utilityInvoice)
        XCTAssertTrue(fields.check.canSave, "\(fields.check.blockers)")
        XCTAssertEqual(fields.check.fileName, "fatura-luz.pdf")
    }

    func testFieldsReadFromPDFAreMarkedRead() async throws {
        let fields = try bill(try await engine.propose(try invoice(), in: tray))
        for origin in [fields.provider?.origin, fields.amount?.origin, fields.issueDate?.origin, fields.periodStart?.origin,
                       fields.periodEnd?.origin, fields.invoiceNumber?.origin] {
            XCTAssertEqual(origin, .read)
        }
        XCTAssertEqual(fields.amount?.needsCheck, false)

        // A figure the user types is theirs.
        let typed = try bill(try await engine.answer(.confirmFigure(.amount, .money(9_000, .gbp)), in: .utilityBill(fields)))
        XCTAssertEqual(typed.amount?.value, 9_000)
        XCTAssertEqual(typed.amount?.origin, .typed)
        XCTAssertEqual(typed.issueDate?.origin, .read)
    }

    func testPaidBySuggestedAndChangeable() async throws {
        let provider = try debit(Self.day(2023, 3, 20), -10_000, "DEMO PWR DD 123")
        let other = try debit(Self.day(2023, 3, 25), -10_000, "SHOP PAYMENT", category: nil)
        let item = try invoice()
        let fields = try bill(try await engine.propose(item, in: tray))
        XCTAssertEqual(fields.paidBy?.transactionId, provider, "the provider's debit is suggested")
        XCTAssertEqual(Set(fields.paymentChoices.map(\.transactionId)), [provider, other])

        let changed = try bill(try await engine.choosePayment(other, in: .utilityBill(fields)))
        XCTAssertEqual(changed.paidBy?.transactionId, other)
        XCTAssertTrue(changed.check.canSave, "\(changed.check.blockers)")

        let saved = try await engine.save(.utilityBill(changed), item: item, tray: tray, writer: writer())
        let recorded = try await queue.read { db in try UtilityInvoice.fetchOne(db, key: saved.invoiceId ?? -1) }
        XCTAssertEqual(recorded?.transactionId, other)
    }

    func testTenantShareAndStatementJoin() async throws {
        try debit(Self.day(2023, 3, 20), -10_000, "DEMO PWR DD 123")
        let statementId = try await queue.write { db -> Int64 in
            var tenancy = Tenancy(propertyId: self.id("property"), referenceLabel: "Flat A", tenantName: "Synthetic Tenant",
                                  startDate: Self.day(2023, 1, 15))
            try tenancy.insert(db)
            self.ids["tenancy"] = tenancy.id!
            return try Recharges.draftStatement(db: db, tenancyId: tenancy.id!, month: Self.day(2023, 3, 1)).id!
        }
        let fields = try bill(try await engine.propose(try invoice(), in: tray))
        let share = try XCTUnwrap(fields.tenantShare)
        XCTAssertEqual(share.tenancyId, id("tenancy"))
        XCTAssertEqual(share.tenancyName, "Flat A", "the tenancy's name, never the tenant's")
        // 15 Jan – 28 Feb of 1 Jan – 28 Feb: 45 of 59 days.
        XCTAssertEqual(share.amountMinorUnits, 10_000 - Int((10_000.0 * 14 / 59).rounded()))
        XCTAssertEqual(share.note, "45 of 59 days in the tenancy")
        XCTAssertEqual(share.month, Self.day(2023, 3, 1), "the month of its payment")
        XCTAssertEqual(fields.joinsStatement, statementId)
        XCTAssertFalse(share.alreadyOnStatement)

        // A tenancy whose latest statement is sent: a new statement for the bill's month.
        try await queue.write { db in _ = try Recharges.markSent(db: db, statementId: statementId, at: Self.day(2023, 4, 2)) }
        let again = try bill(try await engine.answer(.confirmFigure(.amount, .money(10_000, .gbp)), in: .utilityBill(fields)))
        XCTAssertNil(again.joinsStatement)
        XCTAssertEqual(again.tenantShare?.statementMonth, Self.day(2023, 3, 1))
    }

    func testDuplicateOfExistingDocumentSaysSo() async throws {
        try debit(Self.day(2023, 3, 20), -10_000, "DEMO PWR DD 123")
        let first = try invoice()
        let copy = folder.appendingPathComponent("again.pdf")
        try FileManager.default.copyItem(at: tray.fileURL(for: first), to: copy)
        _ = try await engine.save(try await engine.propose(first, in: tray), item: first, tray: tray, writer: writer())

        // The same file downloaded again: already in Mango.
        let item = try tray.ingest(fileAt: copy, suggestedName: "fatura-luz.pdf", sourceHost: nil)
        let proposal = try await engine.propose(item, in: tray)
        let of = try XCTUnwrap(proposal.check.duplicateOf)
        XCTAssertEqual(of, "Invoice FT 1/23 of Demo Power already recorded", "the Mac's wording")
        XCTAssertFalse(proposal.check.canSave)
        let before = try counts()
        let error = await thrown { _ = try await self.engine.save(proposal, item: item, tray: self.tray, writer: self.writer()) }
        XCTAssertEqual(error as? CheckAndLinkRefusal, .alreadyInMango(of))
        XCTAssertEqual((error as? LocalizedError)?.errorDescription, CheckAndLinkCopy.alreadyInMango(of))
        XCTAssertEqual(try counts(), before)
        XCTAssertEqual(tray.items().map(\.id), [item.id])
    }

    // MARK: Statements

    private func makeBBVA() throws {
        try queue.write { db in
            ids["bbva"] = try AccountEditing.add(db: db, name: BBVAHistoryImport.accountName, currency: .eur, kind: .cash,
                                                 openingBalanceEntered: 250_000, asOf: Self.day(2026, 1, 31)).id!
        }
    }

    /// February 2026: rent and two shop payments; `opening` the statement's Saldo inicial (the account holds €2,500.00).
    private func february(opening: Int = 250_000) -> [String] {
        func euros(_ minor: Int) -> String {
            let whole = minor / 100, cents = minor % 100
            let thousands = whole >= 1_000 ? "\(whole / 1_000)." + String(format: "%03d", whole % 1_000) : "\(whole)"
            return thousands + "," + String(format: "%02d", cents)
        }
        return """
        EXTRATO GLOBAL
        PERÍODO DE 2026/02/01 A 2026/02/28
        DEPÓSITOS À ORDEM \(euros(opening + 97_000))
        Conta Nº: 000/123456789   EUR   CONTA BBVA
        Saldo inicial \(euros(opening))
        02/02 02/02 TRF TENANT ONE 1.000,00 \(euros(opening + 100_000))
        02/27 02/27 PAGAMENTO LOJA EXEMPLO -10,00 \(euros(opening + 99_000))
        02/28 02/28 PAGAMENTO LOJA DOIS -20,00 \(euros(opening + 97_000))
        Saldo final \(euros(opening + 97_000))
        """.components(separatedBy: "\n")
    }

    func testBBVAStatementRoutesToStatementImport() async throws {
        try makeBBVA()
        let item = try download(february(), name: "extrato-2026-02.pdf")
        let proposal = try await engine.propose(item, in: tray)
        guard case .statement(let summary) = proposal else { return XCTFail("not a statement: \(proposal)") }
        XCTAssertEqual(summary.accountId, id("bbva"))
        XCTAssertEqual(summary.rowsToAdd, 3)
        XCTAssertEqual(summary.alreadyImported, 0)
        XCTAssertEqual(summary.openingBalance?.value, 250_000)
        XCTAssertEqual(summary.closingBalance?.value, 347_000)
        XCTAssertEqual(summary.closingBalance?.origin, .read)
        XCTAssertEqual(summary.periodStart?.value, Self.day(2026, 2, 1))
        XCTAssertTrue(summary.balanceMatches, "\(summary.checks)")
        XCTAssertTrue(summary.check.canSave, "\(summary.check.blockers)")

        // Never imported on the iPad: kept on the waiting list for the Mac (its lease, its import run).
        let before = try counts()
        let saved = try await engine.save(proposal, item: item, tray: tray, writer: writer())
        XCTAssertTrue(saved.sentToMac)
        XCTAssertNil(saved.documentId)
        XCTAssertEqual(saved.summary, "Sent to the Mac to import")
        XCTAssertEqual(try counts()["transaction_"], before["transaction_"])
        XCTAssertEqual(try counts()["importBatch"], before["importBatch"])
        XCTAssertEqual(try counts()["importRun"], 0)
        XCTAssertEqual(try counts()["document"], before["document"])
        let waiting = ImportWaitingList(root: folder.appendingPathComponent("Waiting", isDirectory: true), database: queue)
        let kept = try waiting.waiting()
        XCTAssertEqual(kept.map(\.id), [saved.waitingFileId])
        XCTAssertEqual(kept.first?.originalFileName, "extrato-2026-02.pdf")
        XCTAssertEqual(kept.first?.sha256, item.sha256)
        XCTAssertEqual(kept.first?.reason, CheckAndLinkCopy.sentReason)
        XCTAssertNotNil(kept.first?.keptByAppUserId)
        XCTAssertNotNil(try kept.first.flatMap(waiting.fileURL).map { try EvidenceLibrary.sha256(of: $0) })
        try await queue.read { db in
            XCTAssertTrue(try SyncChangeTracker.pending(db: db).contains { $0.table == "importWaitingFile" }, "synced to the Mac")
        }
        XCTAssertTrue(tray.items().isEmpty, "gone from the tray once kept")
    }

    func testStatementOnMemberIPadIsNotSent() async throws {
        try makeBBVA()
        let item = try download(february(), name: "extrato-2026-02.pdf")
        let proposal = try await engine.propose(item, in: tray)
        let before = try counts()
        let error = await thrown { _ = try await self.engine.save(proposal, item: item, tray: self.tray, writer: self.writer(Self.member)) }
        XCTAssertEqual(error as? CheckAndLinkRefusal, .statementNeedsAdmin)
        XCTAssertEqual(try counts(), before)
        XCTAssertEqual(tray.items().map(\.id), [item.id])
    }

    func testStatementMismatchBlocksSaveWithReason() async throws {
        try makeBBVA()
        let item = try download(february(opening: 240_000), name: "extrato-2026-02.pdf")
        let proposal = try await engine.propose(item, in: tray)
        guard case .statement(let summary) = proposal else { return XCTFail("not a statement: \(proposal)") }
        XCTAssertFalse(summary.balanceMatches)
        XCTAssertFalse(summary.checks.isEmpty)
        XCTAssertFalse(summary.check.canSave)
        let before = try counts()
        let error = await thrown { _ = try await self.engine.save(proposal, item: item, tray: self.tray, writer: self.writer()) }
        guard case .needsAnswer(let reasons)? = error as? CheckAndLinkRefusal else { return XCTFail("\(String(describing: error))") }
        XCTAssertEqual(reasons, summary.check.blockers)
        XCTAssertTrue(reasons.contains(where: summary.checks.contains), "\(reasons)")
        XCTAssertEqual(try counts(), before)
        XCTAssertEqual(tray.items().count, 1)
    }

    // MARK: Other documents

    func testUnknownDocumentFallsBackToDocumentKindPicker() async throws {
        let item = try download(["Zxq note", "Nothing to recognise here"], name: "scan-0001.pdf")
        let proposal = try await engine.propose(item, in: tray)
        guard case .document(let fields) = proposal else { return XCTFail("not a document: \(proposal)") }
        XCTAssertTrue(fields.needsKind)
        XCTAssertFalse(fields.check.canSave)
        XCTAssertTrue(fields.kindChoices.contains { $0.kind == .evidence(.certificate) })

        let choice = try XCTUnwrap(fields.kindChoices.first { $0.kind == .evidence(.certificate) })
        guard case .document(let chosen) = try await engine.chooseKind(choice, in: proposal) else { return XCTFail("not a document") }
        XCTAssertFalse(chosen.needsKind)
        XCTAssertEqual(chosen.kind, .evidence(.certificate))
        XCTAssertEqual(chosen.kindOrigin, .typed)
    }

    // MARK: Save

    func testSaveWritesNothingUntilCalled() async throws {
        try debit(Self.day(2023, 3, 20), -10_000, "DEMO PWR DD 123")
        let other = try debit(Self.day(2023, 3, 25), -10_000, "SHOP PAYMENT", category: nil)
        let before = try counts()
        let proposal = try await engine.propose(try invoice(), in: tray)
        _ = try await engine.choosePayment(other, in: proposal)
        _ = try await engine.choosePayment(nil, in: proposal)
        XCTAssertEqual(try counts(), before)
        XCTAssertTrue(storedFiles().isEmpty)
    }

    func testSaveStoresDocumentLinksAndDiscardsTrayItem() async throws {
        let paid = try debit(Self.day(2023, 3, 20), -10_000, "DEMO PWR DD 123")
        let item = try invoice()
        let proposal = try await engine.propose(item, in: tray)
        let result = try await engine.save(proposal, item: item, tray: tray, writer: writer())
        let documentId = try XCTUnwrap(result.documentId)
        XCTAssertFalse(result.sentToMac)

        try await queue.read { db in
            let document = try XCTUnwrap(try EvidenceDocument.fetchOne(db, key: documentId))
            XCTAssertEqual(document.originalFileName, "fatura-luz.pdf")
            XCTAssertEqual(document.kind, .utilityInvoice)
            XCTAssertEqual(document.amountMinorUnits, 10_000)
            XCTAssertEqual(document.sha256, item.sha256)
            let invoice = try XCTUnwrap(try UtilityInvoice.fetchOne(db, key: result.invoiceId ?? -1))
            XCTAssertEqual(invoice.documentId, result.documentId)
            XCTAssertEqual(invoice.transactionId, paid)
            XCTAssertEqual(invoice.invoiceNumber, "FT 1/23")
            let links = try EvidenceLinks.links(db: db, for: documentId).map(\.entity)
            XCTAssertEqual(links, [.transaction(paid)])
            // A normal document, synced: its row is waiting to go up, written by the admin.
            let record = try XCTUnwrap(try Row.fetchOne(db, sql: "SELECT modifiedBy FROM syncRecord WHERE tableName = 'document' AND localId = ?",
                                                        arguments: [documentId]))
            XCTAssertNotNil(record["modifiedBy"] as String?)
            XCTAssertTrue(try SyncChangeTracker.pending(db: db).contains { $0.table == "document" })
        }
        XCTAssertEqual(storedFiles().count, 1)
        XCTAssertTrue(tray.items().isEmpty, "the tray item is gone once saved")
        XCTAssertEqual(result.summary, CheckAndLinkCopy.saved(proposal.check.title))
    }

    func testSaveInFiledYearRefusedTrayItemKept() async throws {
        // 2022/23 filed: a debit of 20 April 2023 (2023/24) paying an invoice of 5 March 2023 would move into 2022/23.
        try await queue.write { db in
            var year = TaxYear(startYear: 2022, personId: self.id("A"), status: .filed)
            try year.insert(db)
        }
        try debit(Self.day(2023, 4, 20), -10_000, "DEMO PWR DD 123")
        let item = try invoice()
        let proposal = try await engine.propose(item, in: tray)
        XCTAssertEqual(proposal.check.filedYears, ["2022/23"])
        XCTAssertTrue(proposal.check.canSave, "a filed year is the writer's refusal: \(proposal.check.blockers)")
        let before = try counts()
        let error = await thrown { _ = try await self.engine.save(proposal, item: item, tray: self.tray, writer: self.writer()) }
        guard case .filedYear(let question)? = error as? DeviceWriteRefusal else { return XCTFail("\(String(describing: error))") }
        // Its own year, and the later protected ones it carries into.
        XCTAssertEqual(question.years.first?.label, "2022/23")
        XCTAssertEqual((error as? LocalizedError)?.errorDescription, DeviceWriteCopy.filedYear(years: question.years.map(\.label)))
        XCTAssertEqual(try counts(), before, "nothing written, nothing queued")
        XCTAssertTrue(storedFiles().isEmpty, "the library copy is removed")
        XCTAssertEqual(tray.items().map(\.id), [item.id])
    }

    func testMemberWithoutPropertyEditDenied() async throws {
        try debit(Self.day(2023, 3, 20), -10_000, "DEMO PWR DD 123")
        try await queue.write { db in
            try MemberPermissions.ensureDefaults(appUserId: self.id("memberUser"), db: db)
            try db.execute(sql: "UPDATE memberPermission SET level = 'view' WHERE appUserId = ? AND area = 'property'",
                           arguments: [self.id("memberUser")])
        }
        let item = try invoice()
        let proposal = try await engine.propose(item, in: tray)
        let before = try counts()
        let error = await thrown { _ = try await self.engine.save(proposal, item: item, tray: self.tray, writer: self.writer(Self.member)) }
        XCTAssertEqual(error as? AccessDenied, AccessDenied(area: .property))
        XCTAssertEqual(try counts(), before)
        XCTAssertTrue(storedFiles().isEmpty)
        XCTAssertEqual(tray.items().map(\.id), [item.id])

        // With Property, a member saves it.
        try await queue.write { db in
            try db.execute(sql: "UPDATE memberPermission SET level = 'edit' WHERE appUserId = ? AND area = 'property'",
                           arguments: [self.id("memberUser")])
        }
        let saved = try await engine.save(proposal, item: item, tray: tray, writer: writer(Self.member))
        XCTAssertNotNil(saved.invoiceId)
    }

    func testDocumentWithPropertyFollowOnsNeedsPropertyEdit() async throws {
        let paid = try debit(Self.day(2023, 3, 20), -12_000, "SOME SHOP", category: nil)
        try await queue.write { db in
            try MemberPermissions.ensureDefaults(appUserId: self.id("memberUser"), db: db)
            try db.execute(sql: "UPDATE memberPermission SET level = 'view' WHERE appUserId = ? AND area = 'property'",
                           arguments: [self.id("memberUser")])
        }
        let item = try download(["Zxq note", "Nothing to recognise here"], name: "scan-0002.pdf")
        var proposal = try await engine.propose(item, in: tray)
        guard case .document(let fields) = proposal else { return XCTFail("not a document: \(proposal)") }
        let certificate = try XCTUnwrap(fields.kindChoices.first { $0.kind == .evidence(.certificate) })
        proposal = try await engine.chooseKind(certificate, in: proposal)
        // Linked to a bank movement: the Mac's follow-ons rerun every property's matching.
        proposal = try await engine.answer(.addTransactionLink(paid), in: proposal)
        XCTAssertTrue(proposal.check.canSave, "\(proposal.check.blockers)")
        let before = try counts()
        let error = await thrown { _ = try await self.engine.save(proposal, item: item, tray: self.tray, writer: self.writer(Self.member)) }
        XCTAssertEqual(error as? AccessDenied, AccessDenied(area: .property), "\(String(describing: error))")
        XCTAssertEqual(try counts(), before)
        XCTAssertTrue(storedFiles().isEmpty)
        XCTAssertEqual(tray.items().map(\.id), [item.id])
        XCTAssertEqual(CheckAndLink.areas(.documents, touched: []), [.documents], "nothing to match: Documents only")
        XCTAssertEqual(CheckAndLink.areas(.property, touched: nil), [.property, .documents])
    }

    func testFiguresToCheckAreReported() async throws {
        let fields = try bill(try await engine.propose(try invoice(), in: tray))
        XCTAssertEqual(fields.check.toCheck, [], "read from the text layer: nothing to check")
        // A figure read by text recognition: reported, and its field says so.
        var plan = fields.check.plan
        let index = try XCTUnwrap(plan.items.firstIndex { $0.id == fields.check.itemId })
        let amount = try XCTUnwrap(plan.items[index].facts.firstIndex { $0.field == .amount })
        plan.items[index].facts[amount].source = .ocr
        plan.items[index].facts[amount].confidence = .needsReview
        let proposal = try await queue.read { db in
            try CheckAndLink.proposal(db: db, plan: plan, root: plan.items[index], itemId: plan.items[index].id, kindChosen: false)
        }
        let checked = try bill(proposal)
        XCTAssertEqual(checked.check.toCheck, ["Amount"])
        XCTAssertEqual(checked.amount?.needsCheck, true)
        XCTAssertEqual(checked.amount?.origin, .read)
        XCTAssertTrue(checked.check.canSave, "Save is the tick: \(checked.check.blockers)")
    }

    func testSaveIsOneTransaction() async throws {
        struct Boom: Error {}
        try debit(Self.day(2023, 3, 20), -10_000, "DEMO PWR DD 123")
        let item = try invoice()
        let proposal = try await engine.propose(item, in: tray)
        let before = try counts()
        var failing = engine!
        failing.afterDocumentFiled = { throw Boom() }
        let error = await thrown { _ = try await failing.save(proposal, item: item, tray: self.tray, writer: self.writer()) }
        XCTAssertTrue(error is Boom, "\(String(describing: error))")
        XCTAssertEqual(try counts(), before, "the document's row is rolled back with the rest")
        XCTAssertTrue(storedFiles().isEmpty)
        XCTAssertEqual(tray.items().map(\.id), [item.id])
    }
}
