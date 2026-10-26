import XCTest
import GRDB
@testable import BudgetCore
import TestSupport

/// Step 6 Task 9 (sync spec §6.2, sharing spec §10; Review Focus 4): the admin's Mac re-validates what it pulls
/// and reverts what the writer had no permission for. Two simulated people (`TwoPersonHousehold`, the Mac
/// re-validating): the member B's device writes through `ActorWrite.perform` with her actor for what she may
/// change, and, as a modified client would, straight to its database (her writer set) for what she may not.
/// Synthetic data only.
final class AccessRevalidationTests: XCTestCase {
    private typealias Device = TwoPersonHousehold.Device

    private func household() async throws -> TwoPersonHousehold {
        let h = try TwoPersonHousehold.make(revalidatesAccess: true)
        try await h.syncAll()
        return h
    }

    // MARK: Helpers

    private func memberUserUuid(_ h: TwoPersonHousehold) throws -> String {
        let id = try h.adminMac.db.read { db in try Int64.fetchOne(db, sql: "SELECT id FROM appUser WHERE personId = ?", arguments: [h.fixture.personB])! }
        return try h.uuid("appUser", id)
    }

    /// B, as her own device knows her.
    private func memberActor(_ h: TwoPersonHousehold, db: Database) throws -> AccessActor {
        let id = try XCTUnwrap(SyncRecordStore.localId(table: "appUser", uuid: try memberUserUuid(h), db: db))
        return try AccessActor.load(appUserId: id, db: db)
    }

    /// The local id on `device` of the Mac's row `table`/`id`.
    private func local(_ h: TwoPersonHousehold, _ table: String, _ id: Int64, on device: Device) throws -> Int64 {
        try XCTUnwrap(h.localId(table, uuid: try h.uuid(table, id), on: device), "\(table) \(id) on the device")
    }

    private func value<T: DatabaseValueConvertible>(_ device: Device, _ sql: String, _ arguments: StatementArguments) throws -> T? {
        try device.db.read { db in try T.fetchOne(db, sql: sql, arguments: arguments) }
    }

    private func read<T>(_ device: Device, _ body: (Database) throws -> T) throws -> T { try device.db.read(body) }
    private func write<T>(_ device: Device, _ body: (Database) throws -> T) throws -> T { try device.db.write(body) }

    private func reverts(_ h: TwoPersonHousehold) throws -> [String] {
        try h.adminMac.db.read { db in try AccessRevalidation.recentReverts(limit: 10, db: db) }
    }

    /// The member's device pushes; the Mac pulls (re-validating) and pushes; every other device pulls.
    private func round(_ h: TwoPersonHousehold) async throws {
        try await h.memberDevice.engine.pushPending()
        try await h.adminMac.engine.syncNow()
        try await h.memberDevice.engine.pull()
        try await h.adminPhone.engine.pull()
    }

    private func amount(_ h: TwoPersonHousehold, _ transaction: Int64, on device: Device) throws -> Int? {
        try value(device, "SELECT amountMinorUnits FROM transaction_ WHERE id = ?", [try local(h, "transaction_", transaction, on: device)])
    }

    private func note(_ h: TwoPersonHousehold, _ transaction: Int64, on device: Device) throws -> String? {
        try value(device, "SELECT note FROM transaction_ WHERE id = ?", [try local(h, "transaction_", transaction, on: device)])
    }

    // MARK: Kept

    func testMemberImportIsKept() async throws {
        let h = try await household()
        let shared = try local(h, "account", h.fixture.shared, on: h.memberDevice)
        let transactionUuid = try write(h.memberDevice) { db -> String in
            let actor = try self.memberActor(h, db: db)
            return try ActorWrite.perform(actor, area: .import, origin: .import, db: db) {
                let mark = try SyncBatch.mark(db: db)
                try db.execute(sql: "INSERT INTO importRun(confirmedAt, entryPoint, summary) VALUES (?, 'documents', 'Member run')", arguments: [Date()])
                let run = db.lastInsertedRowID
                try db.execute(sql: "INSERT INTO importBatch(accountId, sourceFileName, importedAt, importRunId) VALUES (?, 'member.csv', ?, ?)",
                               arguments: [shared, Date(), run])
                let batch = db.lastInsertedRowID
                try db.execute(sql: """
                    INSERT INTO transaction_(importBatchId, accountId, date, rawDescription, amountMinorUnits, status, categorizedBy, fingerprint)
                    VALUES (?, ?, ?, 'Member import', -777, 'confirmed', 'none', 'member-import-1')
                    """, arguments: [batch, shared, Date()])
                let transaction = db.lastInsertedRowID
                try SyncBatch.open(runId: run, since: mark, db: db)
                return try SyncRecordStore.uuid(for: "transaction_", localId: transaction, db: db)
            }
        }
        try await round(h)
        let onMac = try XCTUnwrap(h.localId("transaction_", uuid: transactionUuid, on: h.adminMac), "the member's import arrived")
        XCTAssertEqual(try value(h.adminMac, "SELECT amountMinorUnits FROM transaction_ WHERE id = ?", [onMac]) as Int?, -777)
        XCTAssertEqual(try reverts(h), [])
        XCTAssertNotNil(try h.localId("transaction_", uuid: transactionUuid, on: h.memberDevice), "and stays on her device")
    }

    /// An import origin with no import batch is a hand edit (a modified client stamping "import" on an amount).
    func testImportOriginWithoutABatchIsAHandEdit() async throws {
        let h = try await household()
        let member = try memberUserUuid(h)
        let shared = try local(h, "transaction_", h.fixture.sharedTransaction, on: h.memberDevice)
        try write(h.memberDevice) { db in
            try SyncChangeTracker.setWriter(member, origin: WriteOrigin.import.rawValue, db: db)
            try db.execute(sql: "UPDATE transaction_ SET amountMinorUnits = -1 WHERE id = ?", arguments: [shared])
            try SyncChangeTracker.setWriter(member, db: db)
        }
        try await round(h)
        XCTAssertEqual(try amount(h, h.fixture.sharedTransaction, on: h.adminMac), -1_000)
        XCTAssertEqual(try amount(h, h.fixture.sharedTransaction, on: h.memberDevice), -1_000)
        XCTAssertEqual(try reverts(h), ["Reverted a change by B: no permission for Budget & accounts"])
    }

    func testMemberRechargeMatchIsKept() async throws {
        let h0 = try TwoPersonHousehold.make(revalidatesAccess: true)
        let statement = try write(h0.adminMac) { db -> Int64 in
            let tenancy = try Int64.fetchOne(db, sql: "SELECT id FROM tenancy LIMIT 1")!
            try db.execute(sql: "INSERT INTO rechargeStatement(tenancyId, month, totalMinorUnits) VALUES (?, ?, 1234)", arguments: [tenancy, Date()])
            return db.lastInsertedRowID
        }
        try await h0.syncAll()
        let h = h0
        let statementHere = try local(h, "rechargeStatement", statement, on: h.memberDevice)
        let lisbon = try local(h, "transaction_", h.fixture.lisbonTransaction, on: h.memberDevice)
        let payment = try write(h.memberDevice) { db -> String in
            try ActorWrite.perform(try self.memberActor(h, db: db), area: .property, origin: .propertyMatching, db: db) {
                try db.execute(sql: "INSERT INTO rechargePayment(statementId, transactionId, amountMinorUnits, origin) VALUES (?, ?, 1234, 'auto')",
                               arguments: [statementHere, lisbon])
                return try SyncRecordStore.uuid(for: "rechargePayment", localId: db.lastInsertedRowID, db: db)
            }
        }
        try await round(h)
        XCTAssertNotNil(try h.localId("rechargePayment", uuid: payment, on: h.adminMac), "the match arrived and stays")
        XCTAssertEqual(try reverts(h), [])
    }

    func testMemberNoteOnPropertyCategoryTransactionIsKept() async throws {
        let h = try await household()
        let lisbon = try local(h, "transaction_", h.fixture.lisbonTransaction, on: h.memberDevice)
        try write(h.memberDevice) { db in
            try ActorWrite.perform(try self.memberActor(h, db: db), area: .property, db: db) {
                try db.execute(sql: "UPDATE transaction_ SET note = 'Paid by the tenant' WHERE id = ?", arguments: [lisbon])
            }
        }
        try await round(h)
        XCTAssertEqual(try note(h, h.fixture.lisbonTransaction, on: h.adminMac), "Paid by the tenant")
        XCTAssertEqual(try note(h, h.fixture.lisbonTransaction, on: h.adminPhone), "Paid by the tenant")
        XCTAssertEqual(try reverts(h), [])
    }

    /// The admin's own changes, from another of their devices, are never judged again.
    func testAdminsOwnChangesAreNotJudged() async throws {
        let h = try await household()
        try await h.adminMac2.engine.pull()
        let shared = try local(h, "transaction_", h.fixture.sharedTransaction, on: h.adminMac2)
        try write(h.adminMac2) { db in try db.execute(sql: "UPDATE transaction_ SET amountMinorUnits = -1234 WHERE id = ?", arguments: [shared]) }
        try await h.adminMac2.engine.pushPending()
        try await h.adminMac.engine.syncNow()
        XCTAssertEqual(try amount(h, h.fixture.sharedTransaction, on: h.adminMac), -1_234)
        XCTAssertEqual(try reverts(h), [])
    }

    // MARK: Reverted

    func testMemberAmountEditIsRevertedAndLogged() async throws {
        let h = try await household()
        let shared = try local(h, "transaction_", h.fixture.sharedTransaction, on: h.memberDevice)
        try write(h.memberDevice) { db in
            try db.execute(sql: "UPDATE transaction_ SET amountMinorUnits = -1 WHERE id = ?", arguments: [shared])
        }
        try await h.memberDevice.engine.pushPending()
        let report = try await h.adminMac.engine.pull()
        XCTAssertEqual(try amount(h, h.fixture.sharedTransaction, on: h.adminMac), -1_000, "the Mac keeps its value")
        XCTAssertEqual(report.held, 0)
        try await h.adminMac.engine.pushPending()
        try await h.memberDevice.engine.pull()
        try await h.adminPhone.engine.pull()
        for device in [h.adminMac, h.memberDevice, h.adminPhone] {
            XCTAssertEqual(try amount(h, h.fixture.sharedTransaction, on: device), -1_000, "the Mac's value on every device")
        }
        XCTAssertEqual(try reverts(h), ["Reverted a change by B: no permission for Budget & accounts"])
        let fields: String? = try value(h.adminMac, "SELECT fields FROM syncAccessRevert", [])
        let writer: String? = try value(h.adminMac, "SELECT writerAppUserUuid FROM syncAccessRevert", [])
        XCTAssertEqual(fields, "amountMinorUnits")
        XCTAssertEqual(writer, try memberUserUuid(h))
        // Settled: another round changes nothing and logs nothing more.
        try await round(h)
        XCTAssertEqual(try reverts(h).count, 1)
        XCTAssertEqual(try amount(h, h.fixture.sharedTransaction, on: h.memberDevice), -1_000)
    }

    /// Review Focus 4.
    func testMixedEditKeepsPermittedFieldAndRevertsTheOther() async throws {
        let h = try await household()
        let lisbon = try local(h, "transaction_", h.fixture.lisbonTransaction, on: h.memberDevice)
        try write(h.memberDevice) { db in
            try db.execute(sql: "UPDATE transaction_ SET note = 'Water, March', amountMinorUnits = 1 WHERE id = ?", arguments: [lisbon])
        }
        try await round(h)
        for device in [h.adminMac, h.memberDevice, h.adminPhone] {
            XCTAssertEqual(try note(h, h.fixture.lisbonTransaction, on: device), "Water, March", "the note is kept")
            XCTAssertEqual(try amount(h, h.fixture.lisbonTransaction, on: device), 50_000, "the amount is the Mac's")
        }
        XCTAssertEqual(try reverts(h), ["Reverted a change by B: no permission for Budget & accounts"])
        let fields: String? = try value(h.adminMac, "SELECT group_concat(fields) FROM syncAccessRevert", [])
        XCTAssertEqual(fields, "amountMinorUnits")
    }

    func testMemberCannotChangeTheAdminsLevel() async throws {
        let h = try await household()
        let shared = try local(h, "account", h.fixture.shared, on: h.memberDevice)
        try write(h.memberDevice) { db in
            try db.execute(sql: "UPDATE account SET sharingLevel = ? WHERE id = ?", arguments: [SharingLevel.categoryTotals.rawValue, shared])
        }
        try await round(h)
        for device in [h.adminMac, h.memberDevice] {
            let level: String? = try value(device, "SELECT sharingLevel FROM account WHERE id = ?", [try local(h, "account", h.fixture.shared, on: device)])
            XCTAssertEqual(level, SharingLevel.everything.rawValue)
        }
        XCTAssertEqual(try reverts(h), ["Reverted a change by B: no permission for Budget & accounts"])
    }

    func testMemberNewCategoryIsRemoved() async throws {
        let h = try await household()
        let uuid = try write(h.memberDevice) { db -> String in
            try db.execute(sql: "INSERT INTO category(name, type) VALUES ('Synthetic member category', 'expense')")
            return try SyncRecordStore.uuid(for: "category", localId: db.lastInsertedRowID, db: db)
        }
        try await round(h)
        XCTAssertNil(try h.localId("category", uuid: uuid, on: h.adminMac), "never written on the Mac")
        XCTAssertNil(try h.localId("category", uuid: uuid, on: h.memberDevice), "and its delete removed it from her device")
        XCTAssertNil(try h.localId("category", uuid: uuid, on: h.adminPhone))
        let onServer = try await h.cloud.fetch(uuid, zone: SyncZones.household)
        XCTAssertNil(onServer, "deleted on the server")
        XCTAssertEqual(try reverts(h), ["Reverted a change by B: no permission for Rules & categories"])
        // Sent again (a stale copy): it stays out.
        try await round(h)
        XCTAssertNil(try h.localId("category", uuid: uuid, on: h.adminMac))
    }

    /// A reverted field of a transaction in a filed year: the Mac's figures don't move, the check sees nothing to
    /// hold, and the Mac's value is what the other devices get.
    func testRevalidationNeverTouchesFiledYears() async throws {
        let h = try TwoPersonHousehold.make(revalidatesAccess: true)
        let f = h.fixture
        let repair = try write(h.adminMac) { db -> Int64 in
            try db.execute(sql: "UPDATE property SET currency = ? WHERE id = ?", arguments: [Currency.gbp.rawValue, f.propertyId])
            _ = try Properties.setOwners(db: db, propertyId: f.propertyId, [PropertyOwner(propertyId: f.propertyId, personId: f.personA, shareBasisPoints: 10_000)])
            let group = try Int64.fetchOne(db, sql: "SELECT groupId FROM category WHERE id = ?", arguments: [f.propertyCategory])
            var repairs = Category(name: "Repairs", type: .expense, groupId: group)
            try repairs.insert(db)
            _ = try TaxExpenseTypeMap.seed(db: db, propertyId: f.propertyId)
            var year = TaxYear(startYear: 2023, personId: f.personA, status: .filed)
            try year.insert(db)
            let batch = try Int64.fetchOne(db, sql: "SELECT importBatchId FROM transaction_ WHERE id = ?", arguments: [f.lisbonTransaction])!
            var repair = Transaction(importBatchId: batch, accountId: f.lisbon,
                                     date: MonthRange.calendar.date(from: DateComponents(year: 2023, month: 7, day: 1))!,
                                     rawDescription: "PLUMBER", amountMinorUnits: -10_000, categoryId: repairs.id, status: .confirmed,
                                     categorizedBy: .manual, fingerprint: "fp-plumber")
            try repair.insert(db)
            return repair.id!
        }
        try await h.syncAll()
        let figures = { () throws -> TaxFigures.Snapshot in try self.read(h.adminMac) { db in try TaxFigures.snapshot(db: db) } }
        let before = try figures()
        // Precondition: the repair is on the filed 2023/24 return.
        let moves = try write(h.adminMac) { db -> Bool in
            var impacts: [FiledYearImpact] = []
            try db.inSavepoint {
                let raw = try TaxFigures.snapshot(db: db)
                try db.execute(sql: "UPDATE transaction_ SET amountMinorUnits = -20000 WHERE id = ?", arguments: [repair])
                impacts = try FiledYearGuard.filedChanges(db: db, from: raw)
                return .rollback
            }
            return !impacts.isEmpty
        }
        XCTAssertTrue(moves)

        let onMember = try local(h, "transaction_", repair, on: h.memberDevice)
        try write(h.memberDevice) { db in try db.execute(sql: "UPDATE transaction_ SET amountMinorUnits = -20000 WHERE id = ?", arguments: [onMember]) }
        try await h.memberDevice.engine.pushPending()
        let report = try await h.adminMac.engine.pull()
        XCTAssertNil(report.filedYearAlert, "nothing on a filed return moved: nothing to hold")
        XCTAssertEqual(report.held, 0)
        XCTAssertEqual(try figures(), before, "the Mac's filed figures are as they were")
        XCTAssertEqual(try amount(h, repair, on: h.adminMac), -10_000)
        XCTAssertEqual(try reverts(h), ["Reverted a change by B: no permission for Budget & accounts"])
        try await h.adminMac.engine.pushPending()
        try await h.adminPhone.engine.pull()
        XCTAssertEqual(try amount(h, repair, on: h.adminPhone), -10_000, "the admin's phone has the Mac's value")
        let phoneFigures = try read(h.adminPhone) { db in try TaxFigures.snapshot(db: db) }
        XCTAssertEqual(phoneFigures, before)
        // Her device still runs its own check: taking the Mac's value back would move the figures it holds now,
        // so it is held there for attention, as any incoming change to a filed year is.
        let memberReport = try await h.memberDevice.engine.pull()
        XCTAssertEqual(memberReport.held, 1)
    }

    // MARK: At the source

    @MainActor
    func testPerformDeniesAtTheSource() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("AccessRevalidationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let manager = try TestDatabase.migratedManager()
        let db = manager.dbQueue
        let evidence = folder.appendingPathComponent("Evidence", isDirectory: true)
        try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)
        let member = try await db.write { db -> AccessActor in
            try CategorySeeder.seedDefaults(db)
            var admin = Person(name: "Synthetic A", shortName: "A")
            try People.save(db: db, &admin)
            var adminUser = AppUser(personId: admin.id!, displayName: "A", isAdmin: true, createdAt: Date())
            try adminUser.insert(db)
            var person = Person(name: "Synthetic B", shortName: "B")
            try People.save(db: db, &person)
            var user = AppUser(personId: person.id!, displayName: "B", createdAt: Date())
            try user.insert(db)
            try MemberPermissions.ensureDefaults(appUserId: user.id!, db: db)
            try db.execute(sql: "UPDATE memberPermission SET level = 'view' WHERE appUserId = ? AND area = 'import'", arguments: [user.id!])
            return try AccessActor.load(appUserId: user.id!, db: db)
        }
        let session = ImportSession(dbQueue: db, databasePath: nil, library: EvidenceLibrary(root: evidence, database: db),
                                    categorizationService: CategorizationService(categorizer: FakeCategorizer()), modelReader: nil,
                                    now: { Date(timeIntervalSince1970: 1_790_000_000) })
        defer { session.discard() }
        let made = EvidenceTestPDFs.textPDF(["Example Seguros, S.A. NIF 503504564", "Rua Exemplo 1, Lisboa", "Assunto: comunicacao 1",
                                             "Caro senhor, segue a informacao pedida."], name: "a.pdf")
        let url = folder.appendingPathComponent("a.pdf")
        try FileManager.default.moveItem(at: made, to: url)
        session.start([url], entryPoint: "Test")
        await session.settled()
        let item = try XCTUnwrap(session.plan?.items.first)
        session.resolve(item.id, .chooseKind(.other))
        await session.settled()
        XCTAssertTrue(try XCTUnwrap(session.plan).canConfirm)
        let before = try await db.read { db in try SyncChangeTracker.pending(db: db).count }
        session.confirm(actor: member)
        await session.settled()
        XCTAssertEqual(session.phase, .review, "nothing was imported")
        XCTAssertNotNil(session.problem)
        let runs = try await db.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM importRun") }
        XCTAssertEqual(runs, 0, "nothing written")
        let documents = try await db.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM document") }
        XCTAssertEqual(documents, 0)
        let after = try await db.read { db in try SyncChangeTracker.pending(db: db).count }
        XCTAssertEqual(after, before)
        await session.settled()
        session.pipeline.discardPlanningCopy()
        // The refusal itself, as the applier throws it.
        do {
            try await db.write { db in try ActorWrite.perform(member, area: .import, origin: .import, db: db) {} }
            XCTFail("refused")
        } catch {
            XCTAssertEqual(error as? AccessDenied, AccessDenied(area: .import))
        }
    }
}
