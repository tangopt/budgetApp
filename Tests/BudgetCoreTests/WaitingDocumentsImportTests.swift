import XCTest
import GRDB
@testable import BudgetCore
import TestSupport

/// Documents first, statements later (step 9 Task 2): the waiting documents are linked when a statement import, a
/// CSV commit or a sync pull brings their payment; the import's summary lists them ("1 document linked to its
/// payment"), each with its own Undo, and the run's Undo takes them back too. Synthetic data only.
final class WaitingDocumentsImportTests: XCTestCase {
    private var manager: DatabaseManager!
    private var db: DatabaseQueue { manager.dbQueue }
    private var folder: URL!
    private var library: EvidenceLibrary!
    private var pipeline: ImportPipeline!
    private var applier: ImportApplier!
    private var accountId: Int64!
    private var utilities: Int64!
    private var profile: ImportProfile!

    private let now = WaitingDocumentsImportTests.day(2026, 2, 1)

    override func setUpWithError() throws {
        manager = try TestDatabase.migratedManager()
        (accountId, utilities) = try db.write { db -> (Int64, Int64) in
            var account = Account(name: "Bank Demo", currency: .eur, kind: .cash, trackingMode: .imported)
            try account.insert(db)
            var category = Category(name: "Utilities", type: .expense)
            try category.insert(db)
            var rule = Rule(matchPattern: "EXAMPLE POWER", matchType: .contains, categoryId: category.id!, priority: 10)
            try rule.insert(db)
            return (account.id!, category.id!)
        }
        profile = try ImportProfileStore(dbQueue: db).save(ImportProfile(accountId: accountId, format: .csv, csvDelimiter: ",",
                                                                         csvDateColumnIndex: 0, csvDescriptionColumnIndex: 1,
                                                                         csvAmountColumnIndex: 2, csvDateFormat: "dd/MM/yyyy"))
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("WaitingDocumentsImportTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        library = EvidenceLibrary(root: folder.appendingPathComponent("Library", isDirectory: true), database: db)
        pipeline = ImportPipeline(dbQueue: db, library: library, categorizationService: CategorizationService(categorizer: FakeCategorizer()))
        applier = ImportApplier(dbQueue: db, databasePath: nil, library: library)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    // MARK: Helpers

    private static func day(_ y: Int, _ m: Int, _ d: Int) -> Date {
        UKTaxYear.utcCalendar.date(from: DateComponents(year: y, month: m, day: d))!
    }

    /// A bill filed before its statement: no link.
    private func bill(_ kind: DocumentKind = .utilityInvoice, date: Date, amount: Int) throws -> Int64 {
        try db.write { db in
            let sha = UUID().uuidString
            var document = EvidenceDocument(sha256: sha, storedRelativePath: "x/\(sha).pdf", originalFileName: "Example Power \(sha.prefix(4)).pdf",
                                            byteCount: 1, kind: kind, docDate: date, amountMinorUnits: amount, currency: .eur, addedAt: date)
            try document.insert(db)
            return document.id!
        }
    }

    /// A CSV statement of the account.
    private func statement(_ name: String, _ rows: [(day: String, description: String, amount: String)]) throws -> URL {
        let directory = folder.appendingPathComponent("Drop-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        let text = "Date,Description,Amount\n" + rows.map { "\($0.day),\($0.description),\($0.amount)\n" }.joined()
        try Data(text.utf8).write(to: url)
        return url
    }

    private func importStatement(_ name: String, _ rows: [(day: String, description: String, amount: String)]) async throws -> ImportRunSummary {
        let plan = try await pipeline.plan([try statement(name, rows)], intent: ImportIntent(accountId: accountId))
        XCTAssertTrue(plan.canConfirm, "\(plan.items.map { ($0.title, $0.needsYouReasons) })")
        return try applier.apply(plan, entryPoint: "Test", now: now)
    }

    private func links() throws -> [WaitingDocuments.Pair] {
        try db.read { db in
            try Row.fetchAll(db, sql: "SELECT documentId, entityId FROM documentLink WHERE entityType = ? ORDER BY documentId, entityId",
                             arguments: [EvidenceEntityType.transaction.rawValue])
                .map { WaitingDocuments.Pair(documentId: $0[0], transactionId: $0[1]) }
        }
    }

    private func transaction(_ description: String) throws -> Int64? {
        try db.read { db in
            try Int64.fetchOne(db, sql: "SELECT id FROM \(Transaction.databaseTableName) WHERE rawDescription = ?", arguments: [description])
        }
    }

    private func state(_ id: Int64) throws -> WaitingDocuments.State {
        let now = self.now
        return try db.read { db in try WaitingDocuments.state(db: db, documentId: id, now: now) }
    }

    private func declined() throws -> Int {
        try db.read { db in try AutoLinkDeclined.fetchCount(db) }
    }

    private func suggestions(_ id: Int64) throws -> [Int64] {
        try db.read { db in try WaitingDocuments.suggestions(db: db, documentId: id) }.map(\.transactionId)
    }

    private func describe(_ pair: WaitingDocuments.Pair) throws -> (document: String, payment: String) {
        try db.read { db in try WaitingDocuments.describe(db: db, pair) }
    }

    private func undo(_ pair: WaitingDocuments.Pair) throws {
        let now = self.now
        try db.write { db in try WaitingDocuments.undo(db: db, pair, now: now) }
    }

    private func rerun() throws -> WaitingDocuments.Outcome {
        let now = self.now
        return try db.write { db in
            try WaitingDocuments.run(db: db, newTransactions: Set(try Int64.fetchAll(db, sql: "SELECT id FROM transaction_")), now: now)
        }
    }

    private let powerRow = (day: "25/01/2026", description: "EXAMPLE POWER DD 0001", amount: "-60.00")

    // MARK: Imports

    func testStatementImportLinksWaitingBill() async throws {
        let id = try bill(date: Self.day(2026, 1, 10), amount: 6_000)
        let summary = try await importStatement("january.csv", [powerRow, (day: "26/01/2026", description: "SHOP A", amount: "-12.00")])
        let paid = try XCTUnwrap(try transaction("EXAMPLE POWER DD 0001"))
        let pair = WaitingDocuments.Pair(documentId: id, transactionId: paid)
        XCTAssertEqual(summary.paymentLinks, [pair])
        XCTAssertTrue(summary.text.contains("1 document linked to its payment"), summary.text)
        XCTAssertEqual(try links(), [pair])
        let run = try await db.read { db in try ImportRun.fetchOne(db, key: summary.runId) }
        XCTAssertTrue(run?.summary.contains("1 document linked to its payment") ?? false, "the history's summary too")
    }

    func testSummaryTextCountsSeveral() {
        var summary = ImportRunSummary(runId: 1, filed: 1, linked: 0, recorded: 0, transactions: 2, duplicates: 0, leftOut: 0, backupPath: nil)
        XCTAssertFalse(summary.text.contains("payment"))
        summary.paymentLinks = [WaitingDocuments.Pair(documentId: 1, transactionId: 2), WaitingDocuments.Pair(documentId: 3, transactionId: 4)]
        XCTAssertEqual(summary.text, "1 document filed, 2 transactions, 2 documents linked to their payments")
    }

    func testRunUndoRevertsAutoLinks() async throws {
        let id = try bill(date: Self.day(2026, 1, 10), amount: 6_000)
        let summary = try await importStatement("january.csv", [powerRow])
        XCTAssertEqual(summary.paymentLinks.count, 1)
        _ = try ImportUndo.undo(dbQueue: db, library: library, runId: summary.runId, now: now)
        XCTAssertEqual(try links(), [])
        XCTAssertNil(try transaction("EXAMPLE POWER DD 0001"))
        XCTAssertEqual(try state(id), .waiting)
        XCTAssertEqual(try declined(), 0, "the run's Undo is no refusal of the pair")
    }

    /// A legal bill dated in the filed 2024/25 year, its payment imported 21 days later in 2025/26: the guard refuses
    /// the link (it would move the filed return), the import still succeeds, and the bill keeps waiting.
    func testFiledYearDebitDoesNotFailTheImport() async throws {
        let accountId = self.accountId!
        try await db.write { db in
            var person = Person(name: "Person A", shortName: "A")
            try People.save(db: db, &person)
            var year = TaxYear(startYear: 2024, personId: person.id!, status: .filed)
            try year.insert(db)
            var property = Property(name: "Property A", country: "PT", currency: .eur)
            try Properties.save(db: db, &property)
            _ = try Properties.setOwners(db: db, propertyId: property.id!,
                                         [PropertyOwner(propertyId: property.id!, personId: person.id!, shareBasisPoints: 10_000)])
            try Properties.setAccount(db: db, propertyId: property.id!, accountId: accountId, role: .current)
            var group = CategoryGroup(name: "Property A")
            try group.insert(db)
            try Properties.addCategoryGroup(db: db, propertyId: property.id!, categoryGroupId: group.id!)
            var legal = Category(name: "Legal", type: .expense, groupId: group.id)
            try legal.insert(db)
            try TaxExpenseTypeMap.seed(db: db, propertyId: property.id!)
            try TaxExpenseTypeMap.set(db: db, categoryId: legal.id!, expenseType: .legalFees)
            for year in [2024, 2025] {
                var rate = HMRCRate(startYear: year, currencyCode: "EUR", gbpPerUnit: 0.85, source: .manual)
                try rate.insert(db)
            }
            var rule = Rule(matchPattern: "PAG ADVOGADOS", matchType: .contains, categoryId: legal.id!, priority: 10)
            try rule.insert(db)
        }
        let legalBill = try bill(.legalInvoice, date: Self.day(2025, 3, 30), amount: 7_995)
        let plan = try await pipeline.plan([try statement("april.csv", [(day: "20/04/2025", description: "PAG ADVOGADOS DEMO 0002", amount: "-79.95")])],
                                           intent: ImportIntent(accountId: accountId))
        XCTAssertTrue(plan.canConfirm, "\(plan.items.map { ($0.title, $0.needsYouReasons) })")
        let summary = try applier.apply(plan, entryPoint: "Test", now: Self.day(2025, 5, 1))
        XCTAssertEqual(summary.transactions, 1)
        XCTAssertEqual(summary.paymentLinks, [])
        XCTAssertFalse(summary.text.contains("payment"), summary.text)
        XCTAssertEqual(try links(), [])
        let paid = try XCTUnwrap(try transaction("PAG ADVOGADOS DEMO 0002"))
        XCTAssertEqual(try suggestions(legalBill), [paid],
                       "a suggestion instead")
    }

    func testReimportedStatementLinksNothingNew() async throws {
        let id = try bill(date: Self.day(2026, 1, 10), amount: 6_000)
        let first = try await importStatement("january.csv", [powerRow])
        XCTAssertEqual(first.paymentLinks.count, 1)
        // The same debit again (a longer re-download): a duplicate, skipped; the one new row runs the job, which
        // finds nothing left waiting.
        let again = try await importStatement("january-again.csv", [powerRow, (day: "27/01/2026", description: "SHOP B", amount: "-5.00")])
        XCTAssertEqual(again.transactions, 1)
        XCTAssertEqual(again.paymentLinks, [])
        XCTAssertFalse(again.text.contains("payment"), again.text)
        XCTAssertEqual(try links().map(\.documentId), [id], "no second link")
    }

    func testCSVCommitRunsIt() async throws {
        // `commit` runs the job as of now: a bill of ten days ago, its debit two days ago.
        let today = Date()
        let id = try bill(date: UKTaxYear.utcCalendar.date(byAdding: .day, value: -10, to: today)!, amount: 6_000)
        let paidDay = UKTaxYear.utcCalendar.dateComponents([.year, .month, .day], from: UKTaxYear.utcCalendar.date(byAdding: .day, value: -2, to: today)!)
        let csvDay = String(format: "%02d/%02d/%04d", paidDay.day!, paidDay.month!, paidDay.year!)
        let coordinator = ImportCoordinator(dbQueue: db, categorizationService: CategorizationService(categorizer: FakeCategorizer()))
        let staged = try await coordinator.stageCSVImport(csvText: "Date,Description,Amount\n\(csvDay),EXAMPLE POWER DD 0001,-60.00",
                                                          profile: profile, accountId: accountId)
        XCTAssertEqual(staged.staged.count, 1)
        try coordinator.commit(accountId: accountId, sourceFileName: "january.csv", staged: staged.staged, decisions: [])
        let paid = try XCTUnwrap(try transaction("EXAMPLE POWER DD 0001"))
        XCTAssertEqual(try links(), [WaitingDocuments.Pair(documentId: id, transactionId: paid)])
    }

    func testPairUndoFromSummary() async throws {
        let id = try bill(date: Self.day(2026, 1, 10), amount: 6_000)
        let summary = try await importStatement("january.csv", [powerRow])
        let pair = try XCTUnwrap(summary.paymentLinks.first)
        let names = try describe(pair)
        XCTAssertTrue(names.document.hasPrefix("Example Power"), names.document)
        XCTAssertEqual(names.payment, "25 Jan 2026 · EXAMPLE POWER DD 0001 · " + Money.format(-6_000, currency: .eur))

        try undo(pair)
        XCTAssertEqual(try links(), [])
        XCTAssertEqual(try state(id), .waiting)
        XCTAssertEqual(try rerun().linked, [])
        XCTAssertEqual(try links(), [], "the next run leaves it")
    }

    func testSummaryCountsUndonePairs() {
        var summary = ImportRunSummary(runId: 1, filed: 1, linked: 0, recorded: 0, transactions: 2, duplicates: 0, leftOut: 0, backupPath: nil)
        summary.paymentLinks = [WaitingDocuments.Pair(documentId: 1, transactionId: 2), WaitingDocuments.Pair(documentId: 3, transactionId: 4)]
        XCTAssertEqual(summary.text(paymentLinksUndone: 1), "1 document filed, 2 transactions, 2 documents linked to their payments · 1 undone")
    }

    /// The summary's Undo of one pair, then Undo of the whole import: the link already gone is no conflict.
    func testPairUndoThenRunUndo() async throws {
        _ = try bill(date: Self.day(2026, 1, 10), amount: 6_000)
        let summary = try await importStatement("january.csv", [powerRow])
        try undo(try XCTUnwrap(summary.paymentLinks.first))
        let conflicts = try ImportUndo.conflicts(dbQueue: db, runId: summary.runId)
        XCTAssertEqual(conflicts, [])
        _ = try ImportUndo.undo(dbQueue: db, library: library, runId: summary.runId, now: now)
        XCTAssertNil(try transaction("EXAMPLE POWER DD 0001"))
        XCTAssertEqual(try links(), [])
    }

    // MARK: Sync

    /// A household whose Mac holds a waiting €60 bill (ten days old) and a Utilities category, both on Mac 2 too.
    private struct SyncSetup {
        let h: TwoPersonHousehold
        let document: Int64
        let documentUuid: String
        let accountOn2: Int64
        let utilitiesOn2: Int64
    }

    private func syncSetup() async throws -> SyncSetup {
        let h = try TwoPersonHousehold.make()
        let billDate = UKTaxYear.utcCalendar.date(byAdding: .day, value: -10, to: Date())!
        let (document, utilities) = try await h.adminMac.db.write { db -> (Int64, Int64) in
            var category = Category(name: "Utilities", type: .expense)
            try category.insert(db)
            var document = EvidenceDocument(sha256: UUID().uuidString, storedRelativePath: "x/bill.pdf", originalFileName: "Example Power.pdf",
                                            byteCount: 1, kind: .utilityInvoice, docDate: billDate, amountMinorUnits: 6_000, currency: .gbp,
                                            addedAt: billDate)
            try document.insert(db)
            return (document.id!, category.id!)
        }
        let documentUuid = try h.uuid("document", document)
        let sharedUuid = try h.uuid("account", h.fixture.shared)
        let utilitiesUuid = try h.uuid("category", utilities)
        try await h.adminMac.engine.pushPending()
        try await h.adminMac2.engine.pull()
        _ = try await h.adminMac2.db.write { db in try SyncPulledRows.takeTransactions(db: db) }  // what the first download brought
        let accountOn2 = try XCTUnwrap(try h.localId("account", uuid: sharedUuid, on: h.adminMac2))
        let utilitiesOn2 = try XCTUnwrap(try h.localId("category", uuid: utilitiesUuid, on: h.adminMac2))
        return SyncSetup(h: h, document: document, documentUuid: documentUuid, accountOn2: accountOn2, utilitiesOn2: utilitiesOn2)
    }

    /// A debit added on Mac 2 (two days ago unless `daysAgo`), pushed: its UUID.
    private func addOn2(_ setup: SyncSetup, _ description: String, _ amount: Int, daysAgo: Int = 2) async throws -> (id: Int64, uuid: String) {
        let date = UKTaxYear.utcCalendar.date(byAdding: .day, value: -daysAgo, to: Date())!
        let (account, category) = (setup.accountOn2, setup.utilitiesOn2)
        let id = try await setup.h.adminMac2.db.write { db -> Int64 in
            var batch = ImportBatch(accountId: account, sourceFileName: "synthetic.csv", importedAt: Date())
            try batch.insert(db)
            var transaction = Transaction(importBatchId: batch.id!, accountId: account, date: date, rawDescription: description,
                                          amountMinorUnits: amount, categoryId: category, status: .confirmed, categorizedBy: .manual,
                                          fingerprint: UUID().uuidString)
            try transaction.insert(db)
            return transaction.id!
        }
        let uuid = try await setup.h.adminMac2.db.write { db in try SyncRecordStore.uuid(for: "transaction_", localId: id, db: db) }
        try await setup.h.adminMac2.engine.pushPending()
        return (id, uuid)
    }

    /// A device's pull with the Mac's hook (as `RealSync` sets `afterPull`), then its push.
    private func pullWithHook(_ device: TwoPersonHousehold.Device) async throws -> WaitingDocuments.Outcome {
        try await device.engine.pull()
        let outcome = try await device.db.write { db in
            try ActorWrite.perform(orAdmin: nil, area: .documents, origin: .edit, db: db) { try WaitingDocuments.runAfterPull(db: db) }
        }
        try await device.engine.pushPending()
        return outcome
    }

    private func transactionLinks(_ device: TwoPersonHousehold.Device, document: Int64) async throws -> [Int64] {
        try await device.db.read { db in
            try Int64.fetchAll(db, sql: "SELECT entityId FROM documentLink WHERE documentId = ? AND entityType = ?",
                               arguments: [document, EvidenceEntityType.transaction.rawValue])
        }
    }

    /// The admin's second Mac imports the debit; the Mac (its scheduler's `afterPull` the job, as `RealSync` sets it)
    /// pulls it and links the waiting bill, kept for "Linked automatically"; its push sends the link, an ordinary
    /// document link, back to the second Mac.
    func testPulledRowsAreNotNotedOnADeviceThatDoesNotRunTheJob() throws {
        defer { SyncPulledRows.isRecording = true }
        let id = try db.write { db -> Int64 in
            var account = Account(name: "Pulled", currency: .eur, kind: .cash, trackingMode: .imported)
            try account.insert(db)
            var batch = ImportBatch(accountId: account.id!, sourceFileName: "p.csv", importedAt: Date())
            try batch.insert(db)
            var t = Transaction(importBatchId: batch.id!, accountId: account.id!, date: Date(), rawDescription: "P", amountMinorUnits: -100,
                                categoryId: nil, status: .confirmed, categorizedBy: .manual, fingerprint: UUID().uuidString)
            try t.insert(db)
            return t.id!
        }
        SyncPulledRows.isRecording = false
        try db.write { db in try SyncPulledRows.record(table: Transaction.databaseTableName, localId: id, db: db) }
        let none = try db.write { db in try SyncPulledRows.takeTransactions(db: db) }
        XCTAssertEqual(none, [], "a device that doesn't run the job keeps no notes")
        SyncPulledRows.isRecording = true
        try db.write { db in try SyncPulledRows.record(table: Transaction.databaseTableName, localId: id, db: db) }
        let some = try db.write { db in try SyncPulledRows.takeTransactions(db: db) }
        XCTAssertEqual(some, [id])
    }

    func testSyncMergeLinksWaitingBill() async throws {
        let setup = try await syncSetup()
        let h = setup.h
        let paid = try await addOn2(setup, "EXAMPLE POWER DD 0001", -6_000)

        let macDb = h.adminMac.db
        let scheduler = SyncScheduler(engine: h.adminMac.engine, db: macDb, afterPull: {
            _ = try? await macDb.write { db in
                try ActorWrite.perform(orAdmin: nil, area: .documents, origin: .edit, db: db) { try WaitingDocuments.runAfterPull(db: db) }
            }
        })
        await scheduler.start()
        _ = try await scheduler.syncNowAndWait()
        await scheduler.stop()

        let paidOnMac = try XCTUnwrap(try h.localId("transaction_", uuid: paid.uuid, on: h.adminMac))
        let value1 = try await transactionLinks(h.adminMac, document: setup.document)
        XCTAssertEqual(value1, [paidOnMac])
        let pair = WaitingDocuments.Pair(documentId: setup.document, transactionId: paidOnMac)
        let value2 = try await macDb.read { db in try WaitingDocuments.recentAutoLinks(db: db) }.map(\.pair)
        XCTAssertEqual(value2, [pair])

        try await h.adminMac2.engine.pull()
        let documentOn2 = try XCTUnwrap(try h.localId("document", uuid: setup.documentUuid, on: h.adminMac2))
        let value3 = try await transactionLinks(h.adminMac2, document: documentOn2)
        XCTAssertEqual(value3, [paid.id], "the link synced back as an ordinary document link")

        // Seen: dismissed, the link stays; an undone one leaves the list too.
        try await macDb.write { db in try WaitingDocuments.dismissRecentAutoLinks(db: db, [pair]) }
        let value4 = try await macDb.read { db in try WaitingDocuments.recentAutoLinks(db: db) }
        XCTAssertEqual(value4, [])
        let value5 = try await transactionLinks(h.adminMac, document: setup.document)
        XCTAssertEqual(value5, [paidOnMac])
    }

    /// The Mac links after a pull; the person unlinks it by hand; a later pull bringing another transaction doesn't
    /// link it again (the debit isn't new).
    func testHandUnlinkedPairIsNotRelinkedByALaterPull() async throws {
        let setup = try await syncSetup()
        let h = setup.h
        let paid = try await addOn2(setup, "EXAMPLE POWER DD 0001", -6_000)
        let value6 = try await pullWithHook(h.adminMac).linked.count
        XCTAssertEqual(value6, 1)
        let paidOnMac = try XCTUnwrap(try h.localId("transaction_", uuid: paid.uuid, on: h.adminMac))
        let document = setup.document
        try await h.adminMac.db.write { db in _ = try EvidenceLinks.unlink(db: db, documentId: document, from: .transaction(paidOnMac)) }

        _ = try await addOn2(setup, "SHOP A", -1_250)
        let later = try await pullWithHook(h.adminMac)
        XCTAssertEqual(later.linked, [])
        let value7 = try await transactionLinks(h.adminMac, document: setup.document)
        XCTAssertEqual(value7, [])
        let value8 = try await h.adminMac.db.read { db in try WaitingDocuments.recentAutoLinks(db: db) }
        XCTAssertEqual(value8, [])
    }

    /// The Mac links after a pull and the person undoes it there; Mac 2 pulls the unlink (and a new transaction of
    /// the Mac's) with the hook too: it never had the decline, but the debit isn't new to it, so it isn't relinked.
    func testUndoSyncedToAnotherMacIsNotRelinked() async throws {
        let setup = try await syncSetup()
        let h = setup.h
        let paid = try await addOn2(setup, "EXAMPLE POWER DD 0001", -6_000)
        let first = try await pullWithHook(h.adminMac)
        let pair = try XCTUnwrap(first.linked.first)
        try await h.adminMac.db.write { db in
            try ActorWrite.perform(orAdmin: nil, area: .documents, origin: .documentLink, db: db) { try WaitingDocuments.undo(db: db, pair, now: Date()) }
        }
        try await h.adminMac.db.write { db in
            var batch = ImportBatch(accountId: h.fixture.shared, sourceFileName: "synthetic.csv", importedAt: Date())
            try batch.insert(db)
            var transaction = Transaction(importBatchId: batch.id!, accountId: h.fixture.shared, date: Date(), rawDescription: "SHOP B",
                                          amountMinorUnits: -900, categoryId: nil, status: .pendingReview, categorizedBy: .none,
                                          fingerprint: UUID().uuidString)
            try transaction.insert(db)
        }
        try await h.adminMac.engine.pushPending()

        let documentOn2 = try XCTUnwrap(try h.localId("document", uuid: setup.documentUuid, on: h.adminMac2))
        let onTwo = try await pullWithHook(h.adminMac2)
        XCTAssertEqual(onTwo.linked, [])
        let value9 = try await transactionLinks(h.adminMac2, document: documentOn2)
        XCTAssertEqual(value9, [], "the undo arrived and stays")
        let value10 = try await transactionLinks(h.adminMac, document: setup.document)
        XCTAssertEqual(value10, [])
        _ = paid
    }
}
