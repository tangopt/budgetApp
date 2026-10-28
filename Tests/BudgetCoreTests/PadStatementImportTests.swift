import XCTest
import GRDB
@testable import BudgetCore
import TestSupport

/// Step 19: a bank statement imported on the iPad with the Mac's import engine, under the household's import lease.
/// Synthetic data only: admin Person A (iCloud "_admin") and member Person B ("_member"); a BBVA account; February
/// 2026's statement of three rows. Sync is on, so `ImportApplier` requires the lease (`SyncImportGate`).
final class PadStatementImportTests: XCTestCase {
    private var manager: DatabaseManager!
    private var queue: DatabaseQueue { manager.dbQueue }
    private var folder: URL!
    private var library: EvidenceLibrary!
    private var tray: DownloadsTray!
    private var engine: CheckAndLink!
    private var store: InMemoryLeaseStore!
    private var leases: StoreLeasing!
    private var ids: [String: Int64] = [:]

    private static let admin = "_admin"
    private static let member = "_member"
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private let mac = SyncDevice(id: "device-mac", name: "Mac")

    private static func day(_ y: Int, _ m: Int, _ d: Int) -> Date {
        MonthRange.calendar.date(from: DateComponents(year: y, month: m, day: d))!
    }

    override func setUpWithError() throws {
        manager = try TestDatabase.migratedManager()
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("PadStatementImportTests-\(UUID().uuidString)", isDirectory: true)
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
            ids["adminUser"] = admin.id!
            var member = AppUser(personId: b.id!, displayName: "B", cloudKitUserRecordName: Self.member, isAdmin: false, createdAt: Self.day(2026, 1, 1))
            try member.insert(db)
            ids["memberUser"] = member.id!
            ids["bbva"] = try AccountEditing.add(db: db, name: BBVAHistoryImport.accountName, currency: .eur, kind: .cash,
                                                 openingBalanceEntered: 250_000, asOf: Self.day(2026, 1, 31)).id!
            try SyncImportGate.setSyncOn(true, db: db)
            return ids
        }
        store = InMemoryLeaseStore()
        leases = StoreLeasing(device: SyncDevice(id: "device-ipad", name: "Test iPad"), store: store, db: queue, now: start)
    }

    override func tearDownWithError() throws {
        engine.discard()
        try? FileManager.default.removeItem(at: folder)
    }

    // MARK: Helpers

    private func id(_ key: String) -> Int64 { ids[key]! }

    private func writer(_ recordName: String = PadStatementImportTests.admin) -> DeviceWriter {
        DeviceWriter(db: queue, viewer: { .iCloudUser(recordName: recordName) }, afterWrite: {})
    }

    private func importer(zones: [String]? = nil) -> PadStatementImport {
        leases.setZones(zones)
        return PadStatementImport(dbQueue: queue, library: library, leases: leases)
    }

    /// February 2026: rent and two shop payments; the account holds €2,500.00. `extra`: a line that changes the file only.
    private func february(extra: String? = nil) -> [String] {
        var lines = """
        EXTRATO GLOBAL
        PERÍODO DE 2026/02/01 A 2026/02/28
        DEPÓSITOS À ORDEM 3.470,00
        Conta Nº: 000/123456789   EUR   CONTA BBVA
        Saldo inicial 2.500,00
        02/02 02/02 TRF TENANT ONE 1.000,00 3.500,00
        02/27 02/27 PAGAMENTO LOJA EXEMPLO -10,00 3.490,00
        02/28 02/28 PAGAMENTO LOJA DOIS -20,00 3.470,00
        Saldo final 3.470,00
        """.components(separatedBy: "\n")
        if let extra { lines.append(extra) }
        return lines
    }

    private func download(_ lines: [String], name: String = "extrato-2026-02.pdf") throws -> TrayItem {
        let url = EvidenceTestPDFs.textPDF(lines, name: name)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        return try tray.ingest(fileAt: url, suggestedName: name, sourceHost: "bank.example.test")
    }

    private func counts() throws -> [String: Int] {
        try queue.read { db in
            var counts: [String: Int] = [:]
            for table in ["document", "transaction_", "importBatch", "importRun", "importWaitingFile", "syncBatch"] {
                counts[table] = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)")!
            }
            return counts
        }
    }

    private func thrown(_ body: () async throws -> Void) async -> Error? {
        do {
            try await body()
            return nil
        } catch {
            return error
        }
    }

    private func importFebruary(_ item: TrayItem, writer: DeviceWriter? = nil, importer: PadStatementImport? = nil) async throws -> CheckAndLinkResult {
        let proposal = try await engine.propose(item, in: tray)
        return try await engine.importStatement(proposal, item: item, tray: tray, writer: writer ?? self.writer(),
                                                importer: importer ?? self.importer(), now: start)
    }

    // MARK: Importing

    func testStatementImportedOnTheIPadIsOneRunUnderTheLease() async throws {
        let item = try download(february())
        let proposal = try await engine.propose(item, in: tray)
        guard case .statement(let summary) = proposal else { return XCTFail("not a statement: \(proposal)") }
        XCTAssertEqual(summary.rowsToAdd, 3)
        let route = await importer().route(accountId: summary.accountId, writer: writer())
        XCTAssertEqual(route, .importHere)
        let reads = await leases.acquired
        XCTAssertEqual(reads, 0, "reading the route takes no lease")

        let result = try await engine.importStatement(proposal, item: item, tray: tray, writer: writer(), importer: importer(), now: start)

        XCTAssertFalse(result.sentToMac)
        let runId = try XCTUnwrap(result.importRunId)
        try await queue.read { db in
            let run = try XCTUnwrap(ImportRun.fetchOne(db, key: runId))
            XCTAssertEqual(run.entryPoint, "Imported on Test iPad", "the Mac's history names the device")
            XCTAssertEqual(run.appUserId, self.id("adminUser"))
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM transaction_ WHERE accountId = ?", arguments: [self.id("bbva")]), 3)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM syncBatch WHERE runUuid = (SELECT uuid FROM syncRecord WHERE tableName = 'importRun' AND localId = ?)",
                                            arguments: [runId]), 1, "one sync batch, as on the Mac")
            XCTAssertEqual(try SyncImportGate.heldLease(db: db)?.used, true, "held until the batch is uploaded")
        }
        XCTAssertTrue(result.summary.contains("3"), result.summary)
        let holder = try await ImportLease.holder(now: start, transport: store)
        XCTAssertEqual(holder?.holderName, "Test iPad")
        XCTAssertTrue(tray.items().isEmpty, "gone from the tray once imported")

        // Undo from the iPad: the rows go, under the lease it still holds.
        let undone = try await importer().undo(runId: runId, writer: writer(), now: start.addingTimeInterval(60))
        XCTAssertEqual(undone.rowsRemoved > 0, true)
        try await queue.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM transaction_ WHERE accountId = ?", arguments: [self.id("bbva")]), 0)
        }
    }

    func testRowsAlreadyInMangoAreSkipped() async throws {
        _ = try await importFebruary(try download(february()))
        // The same file again: refused whole, as on the Mac.
        let same = try download(february(extra: "Página 2"), name: "extrato-2026-02 (1).pdf")
        let copy = try await engine.propose(same, in: tray)
        XCTAssertEqual(copy.check.duplicateOf, "Already imported: 3 rows")
        engine.discard(same)

        // February to 5 March: the three February rows are in Mango already (skipped), one new row is added.
        let overlapping = """
        EXTRATO GLOBAL
        PERÍODO DE 2026/02/01 A 2026/03/05
        DEPÓSITOS À ORDEM 3.465,00
        Conta Nº: 000/123456789   EUR   CONTA BBVA
        Saldo inicial 2.500,00
        02/02 02/02 TRF TENANT ONE 1.000,00 3.500,00
        02/27 02/27 PAGAMENTO LOJA EXEMPLO -10,00 3.490,00
        02/28 02/28 PAGAMENTO LOJA DOIS -20,00 3.470,00
        03/02 03/02 PAGAMENTO LOJA TRES -5,00 3.465,00
        Saldo final 3.465,00
        """.components(separatedBy: "\n")
        let item = try download(overlapping, name: "extrato-2026-03.pdf")
        let proposal = try await engine.propose(item, in: tray)
        guard case .statement(let summary) = proposal else { return XCTFail("not a statement: \(proposal)") }
        XCTAssertEqual(summary.rowsToAdd, 1)
        XCTAssertEqual(summary.alreadyImported, 3)
        XCTAssertTrue(proposal.check.canSave, "\(proposal.check.blockers)")
        _ = try await engine.importStatement(proposal, item: item, tray: tray, writer: writer(), importer: importer(),
                                             now: start.addingTimeInterval(60))
        let rows = try await queue.read { db in
            try String.fetchAll(db, sql: "SELECT rawDescription FROM transaction_ WHERE accountId = ? ORDER BY date", arguments: [self.id("bbva")])
        }
        XCTAssertEqual(rows.count, 4, "no row added twice: \(rows)")
        XCTAssertEqual(rows.filter { $0.contains("LOJA EXEMPLO") }.count, 1)
    }

    // MARK: The lease

    func testImportWaitsWhileTheMacHoldsTheLease() async throws {
        _ = try await ImportLease.acquire(device: mac, now: start.addingTimeInterval(-5 * 60), transport: store)
        let item = try download(february())
        let proposal = try await engine.propose(item, in: tray)
        let route = await importer().route(accountId: id("bbva"), writer: writer())
        XCTAssertEqual(route, .heldBy(deviceName: "Mac", since: start.addingTimeInterval(-5 * 60)))
        let before = try counts()

        let error = await thrown {
            _ = try await self.engine.importStatement(proposal, item: item, tray: self.tray, writer: self.writer(), importer: self.importer(),
                                                      now: self.start)
        }

        XCTAssertEqual(error as? PadImportRefusal, .heldBy(deviceName: "Mac", since: start.addingTimeInterval(-5 * 60)))
        let utc = TimeZone(identifier: "UTC")!
        XCTAssertEqual(PadStatementImportCopy.heldBy("Mac", since: Self.day(2026, 2, 1).addingTimeInterval(10 * 3600 + 42 * 60), timeZone: utc),
                       "Mac is importing (started 10:42). Try again when it finishes.")
        XCTAssertEqual(try counts(), before, "nothing written")
        XCTAssertEqual(tray.items().map(\.id), [item.id], "the file stays in the tray")
        let holder = try await ImportLease.holder(now: start, transport: store)
        XCTAssertEqual(holder?.holderName, "Mac", "the Mac's lease is left alone")
    }

    func testAnExpiredLeaseNeverBlocksTheHousehold() async throws {
        // The Mac took it 40 minutes ago and stopped (no renewal): expired, so the iPad imports.
        _ = try await ImportLease.acquire(device: mac, now: start.addingTimeInterval(-40 * 60), transport: store)
        let route = await importer().route(accountId: id("bbva"), writer: writer())
        XCTAssertEqual(route, .importHere)
        let result = try await importFebruary(try download(february()))
        XCTAssertNotNil(result.importRunId)
        let holder = try await ImportLease.holder(now: start, transport: store)
        XCTAssertEqual(holder?.holderName, "Test iPad")

        // A renewed lease is still held: renewed at 25 minutes, it holds past the first 30.
        let other = InMemoryLeaseStore()
        let lease = try await ImportLease.acquire(device: mac, now: start, transport: other)
        _ = try await ImportLease.renew(lease, now: start.addingTimeInterval(25 * 60), transport: other)
        let renewed = try await ImportLease.holder(now: start.addingTimeInterval(45 * 60), transport: other)
        XCTAssertEqual(renewed?.holderName, "Mac")
    }

    func testALeaseStillHeldHereStaysUsedWhenTakenAgain() async throws {
        _ = try await importFebruary(try download(february()))
        // Its batch still uploading (the lease used): the Undo takes it again through the engine (review M1), and it
        // stays marked used, so the push keeps renewing it until that batch is up.
        let runId = try await queue.read { db in try Int64.fetchOne(db, sql: "SELECT MAX(id) FROM importRun")! }
        _ = try await importer().undo(runId: runId, writer: writer(), now: start.addingTimeInterval(60))
        let taken = await leases.acquired
        XCTAssertEqual(taken, 2, "always through the engine")
        try await queue.read { db in XCTAssertEqual(try SyncImportGate.heldLease(db: db)?.used, true) }
    }

    // MARK: Catching up (review I2)

    /// The Mac's import of the same month is still arriving (its batch waits in staging): Import refuses, nothing is
    /// written, and the lease taken for it goes back.
    func testImportWaitsWhileAnotherDevicesBatchIsArriving() async throws {
        let item = try download(february())
        try await queue.write { db in
            try db.execute(sql: """
                INSERT INTO syncStaging(tableName, uuid, payloadJSON, reason, importRunUuid, receivedAt)
                VALUES ('transaction_', 'staged-row', '{}', 'batch', 'mac-run', ?)
                """, arguments: [self.start])
        }
        let before = try counts()
        let error = await thrown { _ = try await self.importFebruary(item) }
        XCTAssertEqual(error as? PadImportRefusal, .stillSyncing)
        XCTAssertEqual((error as? LocalizedError)?.errorDescription, "Mango is still syncing — try again in a moment")
        let pulled = await leases.catchUps
        XCTAssertEqual(pulled, 1, "it pulled first")
        XCTAssertEqual(try counts(), before)
        let holder = try await ImportLease.holder(now: start, transport: store)
        XCTAssertNil(holder, "the lease goes back")
        XCTAssertEqual(tray.items().map(\.id), [item.id])
    }

    /// The Mac imported the same statement; the pull under the lease brings its rows in after the sheet counted them as
    /// new: the write refuses ("Mango found changes"), nothing of the iPad's is written.
    func testRowsArrivingBeforeTheWriteRefuseTheImport() async throws {
        let item = try download(february())
        let proposal = try await engine.propose(item, in: tray)
        let staged = try XCTUnwrap(Self.staged(proposal))
        XCTAssertEqual(staged.count, 3)
        let account = id("bbva")
        await leases.onCatchUp { db in try Self.insertRows(staged, account: account, db: db) }
        let error = await thrown {
            _ = try await self.engine.importStatement(proposal, item: item, tray: self.tray, writer: self.writer(), importer: self.importer(),
                                                      now: self.start)
        }
        XCTAssertEqual(error as? PadImportRefusal, .foundChanges)
        let rows = try await queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM transaction_ WHERE accountId = ?", arguments: [account])!
        }
        XCTAssertEqual(rows, 3, "only the Mac's rows, none twice")
        XCTAssertEqual(try counts()["importRun"], 0)
        let holder = try await ImportLease.holder(now: start, transport: store)
        XCTAssertNil(holder)
        // Read again, the statement is in Mango already.
        engine.discard(item)
        let again = try await engine.propose(item, in: tray)
        XCTAssertEqual(again.check.duplicateOf, "Already imported: 3 rows")
    }

    /// The other direction: the Mac's review was read before the iPad's import arrived; the Mac's write refuses too.
    func testMacWriteRefusesRowsAnIPadImportBrought() async throws {
        let item = try download(february())
        let proposal = try await engine.propose(item, in: tray)
        let staged = try XCTUnwrap(Self.staged(proposal))
        try await queue.write { db in
            try SyncImportGate.setSyncOn(false, db: db)
            try Self.insertRows(staged, account: self.id("bbva"), db: db)
        }
        var plan = proposal.check.plan
        plan.items = plan.items.map(CheckAndLink.confirmed)
        let applier = ImportApplier(dbQueue: queue, databasePath: nil, library: library)
        XCTAssertThrowsError(try applier.apply(plan, entryPoint: "Import…")) { error in
            XCTAssertEqual(error as? ImportApplyError, .planOutdated(ImportApplier.rowsChangedDetail))
        }
        XCTAssertEqual(try counts()["importRun"], 0)
    }

    private static func staged(_ proposal: CheckAndLinkProposal) -> [StagedTransaction]? {
        for item in proposal.check.plan.items {
            if case .bbvaStatement(let effect) = item.effect { return effect.staged }
        }
        return nil
    }

    /// Rows as another device's import brings them (same fingerprints).
    private static func insertRows(_ staged: [StagedTransaction], account: Int64, db: Database) throws {
        var batch = ImportBatch(accountId: account, sourceFileName: "mac.pdf", importedAt: Date(timeIntervalSince1970: 1_800_000_000))
        try batch.insert(db)
        for row in staged {
            var transaction = Transaction(importBatchId: batch.id!, accountId: account, date: row.parsed.date, rawDescription: row.parsed.rawDescription,
                                          amountMinorUnits: row.parsed.amountMinorUnits, categoryId: nil, status: .confirmed,
                                          categorizedBy: .manual, fingerprint: row.fingerprint)
            try transaction.insert(db)
        }
    }

    func testOfflineSaysConnectAndWritesNothing() async throws {
        await leases.setOffline(true)
        let item = try download(february())
        let route = await importer().route(accountId: id("bbva"), writer: writer())
        XCTAssertEqual(route, .offline)
        let before = try counts()
        let error = await thrown { _ = try await self.importFebruary(item) }
        XCTAssertEqual(error as? PadImportRefusal, .offline)
        XCTAssertEqual((error as? LocalizedError)?.errorDescription, "Connect to the internet to import")
        XCTAssertEqual(try counts(), before)
        XCTAssertEqual(tray.items().map(\.id), [item.id])
    }

    /// The app's lease forwards to the engine running now; with none (sync not started), nothing is leased.
    func testWithoutARunningEngineImportSaysOffline() async throws {
        let none = PadStatementImport(dbQueue: queue, library: library,
                                      leases: CurrentEngineLeasing(device: SyncDevice(id: "ipad", name: "iPad"), current: { nil }))
        let offline = await none.route(accountId: id("bbva"), writer: writer())
        XCTAssertEqual(offline, .offline, "no engine running: Connect to the internet (review M6)")
        let forwarding = CurrentEngineLeasing(device: SyncDevice(id: "ipad", name: "iPad"), current: { [leases] in leases })
        let through = PadStatementImport(dbQueue: queue, library: library, leases: forwarding)
        let route = await through.route(accountId: id("bbva"), writer: writer())
        XCTAssertEqual(route, .importHere)
        let error = await thrown { try await CurrentEngineLeasing(device: SyncDevice(id: "ipad", name: "iPad"), current: { nil }).acquireImportLease() }
        XCTAssertTrue(PadStatementImport.isOffline(try XCTUnwrap(error)))
    }

    func testLeaseGivenBackWhenTheImportIsRefused() async throws {
        // The account is gone since the review: the plan is outdated, nothing is written, the lease goes back at once.
        let item = try download(february())
        let proposal = try await engine.propose(item, in: tray)
        try await queue.write { db in
            try db.execute(sql: "UPDATE account SET name = 'Renamed' WHERE id = ?", arguments: [self.id("bbva")])
            try db.execute(sql: "DELETE FROM balanceSnapshot WHERE accountId = ?", arguments: [self.id("bbva")])
            try db.execute(sql: "DELETE FROM account WHERE id = ?", arguments: [self.id("bbva")])
        }
        let before = try counts()
        let error = await thrown {
            _ = try await self.engine.importStatement(proposal, item: item, tray: self.tray, writer: self.writer(), importer: self.importer(),
                                                      now: self.start)
        }
        XCTAssertNotNil(error)
        XCTAssertEqual(try counts(), before)
        try await queue.read { db in XCTAssertNil(try SyncImportGate.heldLease(db: db)) }
        let holder = try await ImportLease.holder(now: start, transport: store)
        XCTAssertNil(holder, "released on the server too")
        XCTAssertEqual(tray.items().map(\.id), [item.id])
    }

    // MARK: Who may import

    /// Review I1: a member's iPad doesn't import statements for now (her run's records naming no account would wait for
    /// the admin's zone, her batch never closing): she sees a note, with or without Import, and nothing is written.
    func testMemberSeesTheOwnerImportsNoteAndNothingIsWritten() async throws {
        XCTAssertFalse(PadStatementImport.membersImport)
        try await queue.write { db in try MemberPermissions.ensureDefaults(appUserId: self.id("memberUser"), db: db) }
        let item = try download(february())
        let proposal = try await engine.propose(item, in: tray)
        let route = await importer(zones: [SyncZones.household]).route(accountId: id("bbva"), writer: writer(Self.member))
        XCTAssertEqual(route, .ownerImports)
        XCTAssertEqual(PadStatementImportCopy.ownerImports, "Statements are imported on the Mac or on the owner’s iPad.")
        let before = try counts()
        let error = await thrown {
            _ = try await self.engine.importStatement(proposal, item: item, tray: self.tray, writer: self.writer(Self.member),
                                                      importer: self.importer(zones: [SyncZones.household]), now: self.start)
        }
        XCTAssertEqual(error as? PadImportRefusal, .noImportAccess)
        XCTAssertEqual(try counts(), before)
        XCTAssertEqual(tray.items().map(\.id), [item.id])
        let taken = await leases.acquired
        XCTAssertEqual(taken, 0, "no lease taken")

        // Nor may she undo a run on the iPad (review M3: the same access as an import).
        let result = try await engine.importStatement(proposal, item: item, tray: tray, writer: writer(), importer: importer(), now: start)
        let runId = try XCTUnwrap(result.importRunId)
        let undo = await thrown { _ = try await self.importer(zones: [SyncZones.household]).undo(runId: runId, writer: self.writer(Self.member)) }
        XCTAssertEqual(undo as? PadImportRefusal, .noImportAccess)
    }

    /// With ownership confirmed, an import goes where its account's records go: A's iPad imports his private account only
    /// when it pushes his zone; a member's iPad imports nothing while `membersImport` is off.
    func testImportZoneDecidesWhoMayImport() throws {
        let db = try TestDatabase.migrated()
        try db.write { db in
            let fixture = try SharingFixture.build(db)
            let memberId = try XCTUnwrap(Int64.fetchOne(db, sql: "SELECT id FROM appUser WHERE isAdmin = 0"))
            let member = try AccessActor.load(appUserId: memberId, db: db)
            let household = [SyncZones.household]
            XCTAssertFalse(try PadStatementImport.canImport(member, accountId: fixture.shared, zones: household, db: db), "members don't import yet")
            XCTAssertFalse(try PadStatementImport.canImport(member, accountId: fixture.privateAccount, zones: household, db: db))
            XCTAssertTrue(try PadStatementImport.canImport(fixture.admin, accountId: fixture.shared, zones: household, db: db))
            XCTAssertFalse(try PadStatementImport.canImport(fixture.admin, accountId: fixture.privateAccount, zones: household, db: db),
                           "his private account's import goes to a zone this device doesn't push")
            XCTAssertTrue(try PadStatementImport.canImport(fixture.admin, accountId: fixture.privateAccount,
                                                           zones: [SyncZones.household, fixture.privateZone], db: db))
            XCTAssertTrue(try PadStatementImport.canImport(fixture.admin, accountId: fixture.privateAccount, zones: nil, db: db), "no sync: no zones")
        }
    }

    func testFiledYearsUnchangedByAnIPadImport() async throws {
        try await queue.write { db in
            for start in 2020...2024 {
                var year = TaxYear(startYear: start, personId: self.id("A"), status: .filed)
                try year.insert(db)
            }
        }
        let before = try await queue.read { db in try TaxFigures.snapshot(db: db) }
        _ = try await importFebruary(try download(february()))
        let impacts = try await queue.read { db in try FiledYearGuard.filedChanges(db: db, from: before) }
        XCTAssertTrue(impacts.isEmpty, "\(impacts)")
    }
}

/// The lease over an in-memory store (as `SyncEngineCore` does over CloudKit): taken, it is stored in `SyncImportGate`.
final actor StoreLeasing: ImportLeasing {
    nonisolated let leaseDevice: SyncDevice
    private nonisolated let zones = Zones()
    nonisolated func importZones() async -> [String]? { zones.value }
    nonisolated func setZones(_ value: [String]?) { zones.value = value }
    private let store: InMemoryLeaseStore
    private let db: DatabaseQueue
    private let now: Date
    private var offline = false
    private(set) var acquired = 0

    init(device: SyncDevice, store: InMemoryLeaseStore, db: DatabaseQueue, now: Date) {
        leaseDevice = device
        self.store = store
        self.db = db
        self.now = now
    }

    func setOffline(_ value: Bool) { offline = value }

    func importLeaseHolder() async throws -> ImportLeaseRecord? {
        if offline { throw LeaseStoreError.unavailable("offline") }
        return try await ImportLease.holder(now: now, transport: store)
    }

    func acquireImportLease() async throws {
        if offline { throw LeaseStoreError.unavailable("offline") }
        let lease = try await ImportLease.acquire(device: leaseDevice, now: now, transport: store)
        acquired += 1
        let now = now
        try await db.write { db in
            let used = try SyncImportGate.heldLease(db: db).map { $0.used && $0.record.holderId == lease.record.holderId } ?? false
            try SyncImportGate.setHeldLease(HeldImportLease(record: lease.record, tag: lease.tag, used: used), db: db, now: now)
        }
    }

    /// What a pull brings in (another device's import arriving), run on `catchUp`.
    private var arriving: (@Sendable (Database) throws -> Void)?
    private(set) var catchUps = 0
    func onCatchUp(_ body: @escaping @Sendable (Database) throws -> Void) { arriving = body }

    func catchUp() async throws {
        if offline { throw LeaseStoreError.unavailable("offline") }
        catchUps += 1
        if let arriving { try await db.write { db in try arriving(db) } }
    }

    func releaseImportLease() async throws {
        guard let held = try await db.read({ db in try SyncImportGate.heldLease(db: db) }) else { return }
        try await ImportLease.release(ImportLease.Lease(record: held.record, tag: held.tag), transport: store)
        let now = now
        try await db.write { db in try SyncImportGate.setHeldLease(nil, db: db, now: now) }
    }

    final class Zones: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [String]?
        var value: [String]? {
            get { lock.withLock { stored } }
            set { lock.withLock { stored = newValue } }
        }
    }
}
