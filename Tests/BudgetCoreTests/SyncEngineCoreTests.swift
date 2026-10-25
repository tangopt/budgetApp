import XCTest
import GRDB
@testable import BudgetCore
import TestSupport

/// One simulated device for the engine: its own in-memory database, signed in as `user`, syncing through
/// a shared `FakeCloud`.
final class SyncEngineTestDevice {
    let manager: DatabaseManager
    let user: String
    let device: SyncDevice
    let engine: SyncEngineCore
    /// The zone keys this device holds (ruling R15): devices sharing one model the same iCloud Keychain.
    let keys: any SyncKeyStore
    var queue: DatabaseQueue { manager.dbQueue }

    init(_ user: String, name: String, cloud: FakeCloud, keys: any SyncKeyStore, batchSize: Int = 200, path: String? = nil) throws {
        // A file already there is reopened, as the app opens it; anything else starts as a copy of the migrated template.
        if let path, FileManager.default.fileExists(atPath: path) {
            manager = try DatabaseManager(path: path)
            try manager.migrate()
        } else {
            manager = try TestDatabase.migratedManager(path: path)
        }
        self.user = user
        device = SyncDevice(id: "device-\(user)", name: name)
        try manager.dbQueue.write { db in try SyncChangeTracker.setWriter(user, db: db) }
        self.keys = keys
        engine = SyncEngineCore(db: manager.dbQueue, transport: cloud, device: device, keyStore: keys, batchSize: batchSize)
    }

    /// Synchronous access (async tests would otherwise pick GRDB's async overloads).
    func read<T>(_ body: (Database) throws -> T) throws -> T { try queue.read(body) }
    func write<T>(_ body: (Database) throws -> T) throws -> T { try queue.write(body) }

    func uuid(_ table: String, _ id: Int64) throws -> String {
        try queue.read { db in try XCTUnwrap(SyncRecordStore.existingUUID(table: table, localId: id, db: db)) }
    }

    func localId(_ table: String, _ uuid: String) throws -> Int64? {
        try queue.read { db in try SyncRecordStore.localId(table: table, uuid: uuid, db: db) }
    }

    func count(_ table: String) throws -> Int {
        try queue.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)")! }
    }

    func descriptions() throws -> [String] {
        try queue.read { db in try String.fetchAll(db, sql: "SELECT rawDescription FROM transaction_ ORDER BY rawDescription") }
    }

    /// Every synced record this device holds, as it would send it: by UUID, references as UUIDs.
    func content(excluding: Set<String> = []) throws -> [String: [String: SyncValue]] {
        var result: [String: [String: SyncValue]] = [:]
        try queue.writeWithoutTransaction { db in
            try db.inTransaction {
                for record in try SyncRecordRow.fetchAll(db) where !excluding.contains(record.tableName) {
                    let change = PendingChange(table: record.tableName, localId: record.localId, uuid: record.uuid, kind: .update)
                    if let payload = try SyncTranslator.outgoing(change, db: db) { result[record.uuid] = payload.fields }
                }
                return .rollback
            }
        }
        return result
    }
}

/// The engine core (plan Task 5): two devices, each with its own database and `SyncEngineCore`, sharing
/// one in-memory `FakeCloud` that models CloudKit (zones, change tags, compare-and-set, latest-only change
/// feeds with tombstones, paged tokens, a server clock, the record size limit and assets). Synthetic data.
final class SyncEngineCoreTests: XCTestCase {
    private var cloud: FakeCloud!
    private var keys: InMemorySyncKeyStore!
    private var a: SyncEngineTestDevice!
    private var b: SyncEngineTestDevice!

    override func setUp() async throws {
        cloud = FakeCloud()
        keys = InMemorySyncKeyStore()
        a = try SyncEngineTestDevice("user-a", name: "Mac", cloud: cloud, keys: keys)
        b = try SyncEngineTestDevice("user-b", name: "iPad", cloud: cloud, keys: keys)
    }

    private static let day = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: Fixtures

    /// An account, a batch and one transaction on `device`. Returns (account, batch, transaction).
    @discardableResult
    private func base(_ device: SyncEngineTestDevice, description: String = "Coffee", amount: Int = -1234) throws -> (Int64, Int64, Int64) {
        try device.write { db in
            var account = Account(name: "Current", currency: .gbp, kind: .cash, trackingMode: .imported)
            try account.insert(db)
            var batch = ImportBatch(accountId: account.id!, sourceFileName: "synthetic.csv", importedAt: Self.day)
            try batch.insert(db)
            var transaction = Transaction(importBatchId: batch.id!, accountId: account.id!, date: Self.day, rawDescription: description,
                                          amountMinorUnits: amount, categoryId: nil, status: .pendingReview, categorizedBy: .none,
                                          fingerprint: "fp-\(description)", isManual: true)
            try transaction.insert(db)
            return (account.id!, batch.id!, transaction.id!)
        }
    }

    private func transaction(_ device: SyncEngineTestDevice, uuid: String) throws -> Row? {
        guard let id = try device.localId("transaction_", uuid) else { return nil }
        return try device.read { db in try Row.fetchOne(db, sql: "SELECT * FROM transaction_ WHERE id = ?", arguments: [id]) }
    }

    /// A confirmed import on `device`, written the way `ImportApplier` writes one (see `SyncBatchTests`).
    @discardableResult
    private func importRun(on device: SyncEngineTestDevice, account: Int64, count: Int, removing: Int64? = nil) throws -> Int64 {
        try device.write { db in
            try SyncImportGate.require(db: db)
            let mark = try SyncBatch.mark(db: db)
            var run = ImportRun(confirmedAt: Self.day, entryPoint: "Import…", summary: "")
            try run.insert(db)
            try ImportChangeCapture.begin(db: db)
            var batch = ImportBatch(accountId: account, sourceFileName: "statement.csv", importedAt: Self.day, importRunId: run.id)
            try batch.insert(db)
            for i in 0..<count {
                var t = Transaction(importBatchId: batch.id!, accountId: account, date: Self.day, rawDescription: "Shop \(i)",
                                    amountMinorUnits: -100 * (i + 1), categoryId: nil, status: .pendingReview, categorizedBy: .none,
                                    fingerprint: "fp-shop-\(i)")
                try t.insert(db)
            }
            if let removing { try db.execute(sql: "DELETE FROM transaction_ WHERE id = ?", arguments: [removing]) }
            _ = try ImportChangeCapture.finish(db: db, runId: run.id!)
            var file = ImportRunFile(runId: run.id!, fileName: "statement.csv", sha256: "sha-1", outcome: .transactions, detail: "")
            try file.insert(db)
            run.summary = "\(count) transactions"
            try run.update(db)
            try SyncBatch.open(runId: run.id!, since: mark, db: db)
            return run.id!
        }
    }

    // MARK: Plan tests

    func testEditOnOneDeviceArrivesOnTheOther() async throws {
        let (_, _, coffee) = try base(a)
        let uuid = try a.uuid("transaction_", coffee)
        try await a.engine.syncNow()
        try await b.engine.syncNow()

        let arrived = try XCTUnwrap(transaction(b, uuid: uuid))
        XCTAssertEqual(arrived["rawDescription"] as String, "Coffee")
        XCTAssertEqual(arrived["amountMinorUnits"] as Int, -1234)
        let accountName = try b.read { db in try String.fetchOne(db, sql: "SELECT name FROM account WHERE id = ?", arguments: [arrived["accountId"] as Int64]) }
        XCTAssertEqual(accountName, "Current", "the reference arrives translated to B's own account id")

        try a.write { db in try db.execute(sql: "UPDATE transaction_ SET note = 'Team lunch', amountMinorUnits = -2500 WHERE id = ?", arguments: [coffee]) }
        try await a.engine.syncNow()
        try await b.engine.syncNow()
        let edited = try XCTUnwrap(transaction(b, uuid: uuid))
        XCTAssertEqual(edited["note"] as String?, "Team lunch")
        XCTAssertEqual(edited["amountMinorUnits"] as Int, -2500)

        try a.write { db in try db.execute(sql: "DELETE FROM transaction_ WHERE id = ?", arguments: [coffee]) }
        try await a.engine.syncNow()
        try await b.engine.syncNow()
        XCTAssertNil(try transaction(b, uuid: uuid), "the delete arrives too")
        XCTAssertTrue(try b.read { db in try SyncChangeTracker.pending(db: db) }.isEmpty, "nothing B applied echoes back")
        XCTAssertEqual(try a.content(), try b.content())
    }

    func testBothOfflineThenSyncConverges() async throws {
        let (account, batch, coffee) = try base(a)
        let uuid = try a.uuid("transaction_", coffee)
        let accountUuid = try a.uuid("account", account)
        let batchUuid = try a.uuid("importBatch", batch)
        let doomed = try a.write { db -> Int64 in
            var t = Transaction(importBatchId: batch, accountId: account, date: Self.day, rawDescription: "Doomed", amountMinorUnits: -1,
                                categoryId: nil, status: .pendingReview, categorizedBy: .none, fingerprint: "fp-doomed", isManual: true)
            try t.insert(db)
            return t.id!
        }
        let doomedUuid = try a.uuid("transaction_", doomed)
        try await a.engine.syncNow()
        try await b.engine.syncNow()
        let bCoffee = try XCTUnwrap(b.localId("transaction_", uuid))
        let bDoomed = try XCTUnwrap(b.localId("transaction_", doomedUuid))
        let bAccount = try XCTUnwrap(b.localId("account", accountUuid))
        let bBatch = try XCTUnwrap(b.localId("importBatch", batchUuid))

        // Both offline: different fields, one field on both (B later), a delete against an edit, new rows.
        try a.write { db in
            try db.execute(sql: "UPDATE transaction_ SET note = 'From the Mac', amountMinorUnits = -2000 WHERE id = ?", arguments: [coffee])
            try db.execute(sql: "DELETE FROM transaction_ WHERE id = ?", arguments: [doomed])
            var savings = Account(name: "Savings", currency: .gbp, kind: .cash, trackingMode: .imported)
            try savings.insert(db)
        }
        usleep(20_000)
        try b.write { db in
            try db.execute(sql: "UPDATE transaction_ SET status = 'confirmed', amountMinorUnits = -3000 WHERE id = ?", arguments: [bCoffee])
            try db.execute(sql: "UPDATE transaction_ SET note = 'Edited offline' WHERE id = ?", arguments: [bDoomed])
            var t = Transaction(importBatchId: bBatch, accountId: bAccount, date: Self.day, rawDescription: "Bakery", amountMinorUnits: -450,
                                categoryId: nil, status: .pendingReview, categorizedBy: .none, fingerprint: "fp-bakery", isManual: true)
            try t.insert(db)
        }

        try await a.engine.syncNow()
        try await b.engine.syncNow()
        try await a.engine.syncNow()

        XCTAssertEqual(try a.content(), try b.content(), "both devices hold the same records")
        for device in [a!, b!] {
            let row = try XCTUnwrap(transaction(device, uuid: uuid))
            XCTAssertEqual(row["note"] as String?, "From the Mac", "a field only the Mac changed keeps its change")
            XCTAssertEqual(row["status"] as String, "confirmed", "a field only the iPad changed keeps its change")
            XCTAssertEqual(row["amountMinorUnits"] as Int, -3000, "the later writer wins the field both changed")
            XCTAssertNil(try transaction(device, uuid: doomedUuid), "a delete wins over an offline edit")
            XCTAssertEqual(try device.descriptions(), ["Bakery", "Coffee"])
            XCTAssertEqual(try device.count("account"), 2)
        }
        let conflicts = try a.read { db in try SyncConflictRow.filter(Column("uuid") == uuid).fetchAll(db) }
            + (try b.read { db in try SyncConflictRow.filter(Column("uuid") == uuid).fetchAll(db) })
        XCTAssertTrue(conflicts.contains { $0.field == "amountMinorUnits" }, "the earlier amount is kept in the conflict log")
        XCTAssertTrue(try a.read { db in try SyncChangeTracker.pending(db: db) }.isEmpty)
        XCTAssertTrue(try b.read { db in try SyncChangeTracker.pending(db: db) }.isEmpty)
    }

    func testAStaleSaveIsMergedNotOverwritten() async throws {
        let (_, _, coffee) = try base(a)
        let uuid = try a.uuid("transaction_", coffee)
        try await a.engine.syncNow()
        try await b.engine.syncNow()
        let bCoffee = try XCTUnwrap(b.localId("transaction_", uuid))

        try a.write { db in try db.execute(sql: "UPDATE transaction_ SET note = 'Mac note' WHERE id = ?", arguments: [coffee]) }
        try await a.engine.pushPending()
        usleep(20_000)
        // B pushes without pulling first: its change tag is stale, so the server refuses the save
        // (ifServerRecordUnchanged); B merges the server's record and saves again.
        try b.write { db in try db.execute(sql: "UPDATE transaction_ SET status = 'confirmed' WHERE id = ?", arguments: [bCoffee]) }
        let report = try await b.engine.pushPending()
        XCTAssertGreaterThanOrEqual(report.merged, 1, "the refused save was merged with the server's record")

        try await a.engine.pull()
        for device in [a!, b!] {
            let row = try XCTUnwrap(transaction(device, uuid: uuid))
            XCTAssertEqual(row["note"] as String?, "Mac note")
            XCTAssertEqual(row["status"] as String, "confirmed")
        }
        let server = try await cloud.payload(named: uuid, keys: keys)
        XCTAssertEqual(server?.fields["note"], .string("Mac note"))
        XCTAssertEqual(server?.fields["status"], .string("confirmed"))
    }

    func testImportBatchArrivesAtomically() async throws {
        a = try SyncEngineTestDevice("user-a", name: "Mac", cloud: cloud, keys: keys, batchSize: 2)
        let (account, _, manual) = try base(a)
        let manualUuid = try a.uuid("transaction_", manual)
        try await a.engine.syncNow()
        try await b.engine.syncNow()
        XCTAssertNotNil(try b.localId("transaction_", manualUuid))

        try await a.engine.acquireImportLease()
        let holder = try await b.engine.importLeaseHolder()
        XCTAssertEqual(holder?.holderName, "Mac", "B sees \"Importing on Mac\"")
        do {
            try await b.engine.acquireImportLease()
            XCTFail("B can't take the lease while the Mac holds it")
        } catch let error as ImportLeaseError {
            XCTAssertEqual(error.message, "Importing on Mac")
        }
        try importRun(on: a, account: account, count: 6, removing: manual)

        // The upload drops after each save operation in turn; B pulls in between and always holds none or
        // all of the batch.
        var allowed = 0
        var finished = false
        while !finished {
            await cloud.failSaveOperations(after: allowed)
            do {
                try await a.engine.pushPending()
                finished = true
            } catch SyncTransportError.networkUnavailable {
                allowed += 1
            }
            await cloud.restoreConnection()
            try await b.engine.pull()
            let shops = try b.descriptions().filter { $0.hasPrefix("Shop") }.count
            let manualGone = try b.localId("transaction_", manualUuid) == nil
            XCTAssertTrue((shops == 0 && !manualGone) || (shops == 6 && manualGone),
                          "after \(allowed) save operations B holds \(shops) of 6 and the removal \(manualGone ? "applied" : "not applied")")
            XCTAssertLessThan(allowed, 50, "the upload finishes")
            if allowed >= 50 { break }
        }
        XCTAssertGreaterThan(allowed, 3, "the batch took several save operations")
        // The last allowance may have run out on the lease's release, which the next push tries again.
        try await a.engine.pushPending()
        try await b.engine.pull()
        XCTAssertEqual(try b.descriptions().filter { $0.hasPrefix("Shop") }.count, 6)
        XCTAssertEqual(try b.count("importRun"), 1)
        XCTAssertEqual(try b.count("importRunFile"), 1)
        XCTAssertEqual(try b.count("importChange"), try a.count("importChange"))

        // The lease went once the batch's close was uploaded: B may import now.
        let held = try await b.engine.importLeaseHolder()
        XCTAssertNil(held, "the lease is released after the close is uploaded")
        let marker = try a.read { db in try SyncImportGate.heldLease(db: db) }
        XCTAssertNil(marker)
        try await b.engine.acquireImportLease()

        // A device offline for the whole upload sees only the closed batch, over small fetch pages, and
        // gets it all at once.
        await cloud.setPageSize(3)
        let c = try SyncEngineTestDevice("user-c", name: "iPhone", cloud: cloud, keys: keys)
        try await c.engine.pull()
        XCTAssertEqual(try c.descriptions().filter { $0.hasPrefix("Shop") }.count, 6)
        XCTAssertNil(try c.localId("transaction_", manualUuid))
        XCTAssertEqual(try c.count("importChange"), try a.count("importChange"))
        XCTAssertEqual(try c.count("syncStaging"), 0)
    }

    func testABatchsDeletesWaitUntilItsRunIsOnTheServer() async throws {
        let (account, _, manual) = try base(a)
        let manualUuid = try a.uuid("transaction_", manual)
        try await a.engine.syncNow()
        try await b.engine.syncNow()
        try await a.engine.acquireImportLease()
        let runId = try importRun(on: a, account: account, count: 2, removing: manual)
        let run = try a.uuid("importRun", runId)

        // The run's record can't be saved during this push: its members go (tagged, so receivers hold
        // them), but the batch's delete must wait, or a receiver would apply it on its own.
        await cloud.failSaves(of: [run], times: 10)
        let report = try await a.engine.pushPending()
        XCTAssertGreaterThan(report.refused, 0)
        let manualOnServer = await cloud.record(named: manualUuid)
        XCTAssertNotNil(manualOnServer, "the delete waits for its run")
        try await b.engine.pull()
        XCTAssertNotNil(try b.localId("transaction_", manualUuid))
        XCTAssertEqual(try b.descriptions().filter { $0.hasPrefix("Shop") }.count, 0)

        await cloud.failSaves(of: [run], times: 0)
        try await a.engine.pushPending()
        try await b.engine.pull()
        XCTAssertNil(try b.localId("transaction_", manualUuid))
        XCTAssertEqual(try b.descriptions().filter { $0.hasPrefix("Shop") }.count, 2)
    }

    func testAClosedBatchMissingAMemberAppliesOnceTheFetchHasCaughtUp() async throws {
        let (account, _, _) = try base(a)
        try await a.engine.syncNow()
        try await a.engine.acquireImportLease()
        try importRun(on: a, account: account, count: 3)
        try await a.engine.syncNow()
        try await b.engine.syncNow()
        // B deletes one of the batch's transactions: the server's closed run still counts three.
        let shop = try XCTUnwrap(b.read { db in try Int64.fetchOne(db, sql: "SELECT id FROM transaction_ WHERE rawDescription = 'Shop 0'") })
        try b.write { db in try db.execute(sql: "DELETE FROM transaction_ WHERE id = ?", arguments: [shop]) }
        try await b.engine.syncNow()

        // A device that joins now can never meet the counts: once its fetch has caught up, the batch applies.
        await cloud.setPageSize(2)
        let c = try SyncEngineTestDevice("user-c", name: "iPhone", cloud: cloud, keys: keys)
        try await c.engine.pull()
        XCTAssertEqual(try c.descriptions().filter { $0.hasPrefix("Shop") }.sorted(), ["Shop 1", "Shop 2"])
        XCTAssertEqual(try c.count("syncStaging"), 0)
        // The change log names the deleted row by its tombstone on B, and by 0 on C, which never had it (R7).
        XCTAssertEqual(try c.content(excluding: ["importChange"]), try b.content(excluding: ["importChange"]))
    }

    // MARK: Fix round 1

    func testConcurrentSyncsRunOneAtATime() async throws {
        let (account, _, _) = try base(a)
        try await a.engine.acquireImportLease()
        let runId = try importRun(on: a, account: account, count: 4)
        let run = try a.uuid("importRun", runId)
        async let first = a.engine.syncNow()
        async let second = a.engine.syncNow()
        async let third = a.engine.pushPending()
        _ = try await (first, second, third)

        var saves: [String: Int] = [:]
        var since: [Int] = []
        for call in await cloud.calls {
            switch call {
            case .save(let names, let atomic):
                XCTAssertFalse(atomic, "the engine asks for non-atomic saves")
                for name in names where name != TransportLeaseStore.recordName { saves[name, default: 0] += 1 }
            case .changes(_, let position):
                since.append(position ?? 0)
            default:
                break
            }
        }
        XCTAssertEqual(saves[run], 2, "the run goes open, then closed")
        for (name, count) in saves where name != run { XCTAssertEqual(count, 1, "\(name) was sent \(count) times") }
        XCTAssertEqual(since, since.sorted(), "the change token never goes back")
        XCTAssertNil(try a.read { db in try SyncImportGate.heldLease(db: db) }, "released, not lost")
        let holder = try await b.engine.importLeaseHolder()
        XCTAssertNil(holder)
    }

    /// Damages the asset of a large record on the server.
    private func largeNoteOnTheServer(_ coffee: Int64) async throws -> String {
        let uuid = try a.uuid("transaction_", coffee)
        try a.write { db in try db.execute(sql: "UPDATE transaction_ SET note = ? WHERE id = ?",
                                           arguments: [String(repeating: "Synthetic long note. ", count: 60_000), coffee]) }
        try await a.engine.syncNow()
        await cloud.corruptAsset(of: uuid, field: "payload")
        return uuid
    }

    func testAnUnreadableRecordIsStagedForAttentionAndThePullGoesOn() async throws {
        let (_, _, coffee) = try base(a)
        let uuid = try await largeNoteOnTheServer(coffee)
        let report = try await b.engine.pull()
        XCTAssertEqual(report.unreadable, 1)
        XCTAssertEqual(try b.count("account"), 1, "the rest of the pull applied")
        XCTAssertNil(try b.localId("transaction_", uuid))
        let staged = try XCTUnwrap(b.read { db in try SyncStagingRow.filter(Column("uuid") == uuid).fetchOne(db) })
        XCTAssertEqual(staged.reason, "needs attention: unreadable payload")
        XCTAssertEqual(try b.read { db in try SyncTranslator.stagingAttention(db: db) }.map(\.uuid), [uuid])
        let again = try await b.engine.pull()
        XCTAssertEqual(again.received, 0, "the token moved past it")

        // A readable version replaces it.
        try a.write { db in try db.execute(sql: "UPDATE transaction_ SET note = 'short' WHERE id = ?", arguments: [coffee]) }
        try await a.engine.syncNow()
        try await b.engine.pull()
        XCTAssertNotNil(try transaction(b, uuid: uuid))
        XCTAssertEqual(try b.count("syncStaging"), 0)
    }

    func testALocalEditWaitsWhileTheServersVersionIsStaged() async throws {
        let (_, _, coffee) = try base(a)
        try await a.engine.syncNow()
        try await b.engine.syncNow()
        let uuid = try await largeNoteOnTheServer(coffee)
        try await b.engine.pull()
        let bCoffee = try XCTUnwrap(b.localId("transaction_", uuid))
        try b.write { db in try db.execute(sql: "UPDATE transaction_ SET status = 'confirmed' WHERE id = ?", arguments: [bCoffee]) }
        let before = await cloud.calls.count
        let report = try await b.engine.pushPending()
        XCTAssertEqual(report.heldBack, 1, "not sent while the server's version waits here")
        let sent = await cloud.calls.dropFirst(before).contains { if case .save(let names, _) = $0 { return names.contains(uuid) } else { return false } }
        XCTAssertFalse(sent)
        XCTAssertEqual(try b.read { db in try SyncTranslator.stagingAttention(db: db) }.map(\.uuid), [uuid])

        try a.write { db in try db.execute(sql: "UPDATE transaction_ SET note = 'short' WHERE id = ?", arguments: [coffee]) }
        try await a.engine.syncNow()
        try await b.engine.syncNow()
        try await a.engine.pull()
        for device in [a!, b!] {
            let row = try XCTUnwrap(transaction(device, uuid: uuid))
            XCTAssertEqual(row["note"] as String?, "short")
            XCTAssertEqual(row["status"] as String, "confirmed")
        }
    }

    func testOneConflictDoesNotFailItsChunk() async throws {
        let (account, batch, coffee) = try base(a)
        try await a.engine.syncNow()
        try await b.engine.syncNow()
        let accountUuid = try a.uuid("account", account)
        let batchUuid = try a.uuid("importBatch", batch)
        let uuid = try a.uuid("transaction_", coffee)
        try a.write { db in try db.execute(sql: "UPDATE transaction_ SET note = 'Mac note' WHERE id = ?", arguments: [coffee]) }
        try await a.engine.pushPending()
        let ids = (try XCTUnwrap(b.localId("transaction_", uuid)), try XCTUnwrap(b.localId("account", accountUuid)),
                   try XCTUnwrap(b.localId("importBatch", batchUuid)))
        try b.write { db in
            try db.execute(sql: "UPDATE transaction_ SET status = 'confirmed' WHERE id = ?", arguments: [ids.0])
            try db.execute(sql: "UPDATE account SET name = 'Renamed' WHERE id = ?", arguments: [ids.1])
            try db.execute(sql: "UPDATE importBatch SET sourceFileName = 'renamed.csv' WHERE id = ?", arguments: [ids.2])
        }
        // Only B's first operation goes through: the conflicting record fails alone in it.
        await cloud.failSaveOperations(after: 1)
        do {
            try await b.engine.pushPending()
            XCTFail("the second operation can't go")
        } catch SyncTransportError.networkUnavailable {}
        await cloud.restoreConnection()
        let server = try await cloud.payload(named: accountUuid, keys: keys)
        XCTAssertEqual(server?.fields["name"], .string("Renamed"))
        let batchOnServer = try await cloud.payload(named: batchUuid, keys: keys)
        XCTAssertEqual(batchOnServer?.fields["sourceFileName"], .string("renamed.csv"))
    }

    func testOperationsAreSplitByCountAndBytes() async throws {
        for advertised in [true, false] {
            let cloud = FakeCloud(limits: SyncOperationLimits(maxRecords: 3, maxBytes: 4_000), advertisesLimits: advertised)
            let mac = try SyncEngineTestDevice("user-a", name: "Mac", cloud: cloud, keys: keys)
            let ipad = try SyncEngineTestDevice("user-b", name: "iPad", cloud: cloud, keys: keys)
            let (account, batch, _) = try base(mac)
            try mac.write { db in
                for i in 0..<9 {
                    var t = Transaction(importBatchId: batch, accountId: account, date: Self.day, rawDescription: "Item \(i)",
                                        amountMinorUnits: -i, categoryId: nil, status: .pendingReview, categorizedBy: .none,
                                        fingerprint: "fp-item-\(i)", note: String(repeating: "n", count: 1_200), isManual: true)
                    try t.insert(db)
                }
            }
            try await mac.engine.syncNow()
            try await ipad.engine.syncNow()
            XCTAssertEqual(try ipad.count("transaction_"), 10)
            let refusedWhole = await cloud.limitExceededCount
            if advertised {
                XCTAssertEqual(refusedWhole, 0, "split before sending: at most 3 records and 4,000 bytes")
            } else {
                XCTAssertGreaterThan(refusedWhole, 0, "split on limitExceeded")
            }
        }
    }

    func testALostReplyIsHarmless() async throws {
        let (_, _, coffee) = try base(a)
        let uuid = try a.uuid("transaction_", coffee)
        try await a.engine.syncNow()
        try a.write { db in try db.execute(sql: "UPDATE transaction_ SET note = 'Edited' WHERE id = ?", arguments: [coffee]) }
        await cloud.loseTheNextReply()
        do {
            try await a.engine.pushPending()
            XCTFail("the reply was lost")
        } catch SyncTransportError.networkUnavailable {}
        try await a.engine.syncNow()
        XCTAssertTrue(try a.read { db in try SyncChangeTracker.pending(db: db) }.isEmpty)
        XCTAssertEqual(try a.count("syncConflict"), 0, "its own version coming back is no conflict")
        try await b.engine.syncNow()
        XCTAssertEqual(try transaction(b, uuid: uuid)?["note"] as String?, "Edited")
    }

    func testAnExpiredTokenFetchesTheZoneAgain() async throws {
        try base(a)
        try await a.engine.syncNow()
        try await b.engine.syncNow()
        try a.write { db in try db.execute(sql: "UPDATE account SET name = 'Later' WHERE id = 1") }
        try await a.engine.syncNow()
        await cloud.expireChangeTokens()
        try await b.engine.pull()
        XCTAssertEqual(try b.read { db in try String.fetchOne(db, sql: "SELECT name FROM account") }, "Later")
        XCTAssertEqual(try a.content(), try b.content())
    }

    func testAMissingZoneIsCreatedAgainAndEverythingGoesUpAgain() async throws {
        let (_, _, coffee) = try base(a)
        let uuid = try a.uuid("transaction_", coffee)
        try await a.engine.syncNow()
        try await b.engine.syncNow()
        await cloud.deleteZone("household")
        try await a.engine.syncNow()
        let back = try await cloud.payload(named: uuid, keys: keys)
        XCTAssertEqual(back?.fields["rawDescription"], .string("Coffee"), "re-uploaded")
        try await b.engine.syncNow()
        XCTAssertEqual(try b.descriptions(), ["Coffee"], "no duplicates")
        XCTAssertEqual(try a.content(), try b.content())
        let stamps = try a.read { db in try Row.fetchOne(db, sql: "SELECT systemFields, changeTag FROM syncRecord WHERE uuid = ?", arguments: [uuid]) }
        let fields: Data? = stamps?["systemFields"]
        let tag: String? = stamps?["changeTag"]
        XCTAssertNotNil(tag)
        XCTAssertNotEqual(fields, tag.map { Data($0.utf8) }, "the opaque blob and the compared tag are both kept")
    }

    // MARK: R12: reconciliation after a full fetch

    private func conflictLog(_ device: SyncEngineTestDevice, _ uuid: String) throws -> [String] {
        try device.read { db in try SyncConflictRow.filter(Column("uuid") == uuid).fetchAll(db).map(\.losingValueJSON) }
    }

    func testADeleteMissedWhileTheTokenExpiredComesBackVisibly() async throws {
        let (_, _, coffee) = try base(a)
        let uuid = try a.uuid("transaction_", coffee)
        try await a.engine.syncNow()
        try await b.engine.syncNow()
        await cloud.expireChangeTokens()
        try a.write { db in try db.execute(sql: "DELETE FROM transaction_ WHERE id = ?", arguments: [coffee]) }
        try await a.engine.syncNow()
        let deletedOnServer = await cloud.record(named: uuid)
        XCTAssertNil(deletedOnServer)

        let report = try await b.engine.syncNow()
        XCTAssertEqual(report.pull.reconciled, 1, "B never saw the delete: its row is sent again")
        XCTAssertTrue(try conflictLog(b, uuid).contains { $0.contains("was missing on iCloud; sent again") })
        try await a.engine.syncNow()
        XCTAssertNotNil(try transaction(a, uuid: uuid), "the row is back on the Mac")
        XCTAssertTrue(try conflictLog(a, uuid).contains { $0.contains("brought back") })
        XCTAssertNotNil(try transaction(b, uuid: uuid))
        XCTAssertEqual(try a.content(), try b.content())
        XCTAssertTrue(try a.read { db in try SyncChangeTracker.pending(db: db) }.isEmpty)
    }

    func testAZoneResetOnOneDeviceGetsTheOthersRowsBack() async throws {
        let (account, batch, _) = try base(a)
        try await a.engine.syncNow()
        try await b.engine.syncNow()
        let bAccount = try XCTUnwrap(b.localId("account", try a.uuid("account", account)))
        let bBatch = try XCTUnwrap(b.localId("importBatch", try a.uuid("importBatch", batch)))
        let bakery = try b.write { db -> Int64 in
            var t = Transaction(importBatchId: bBatch, accountId: bAccount, date: Self.day, rawDescription: "Bakery", amountMinorUnits: -450,
                                categoryId: nil, status: .pendingReview, categorizedBy: .none, fingerprint: "fp-bakery", isManual: true)
            try t.insert(db)
            return t.id!
        }
        let bakeryUuid = try b.uuid("transaction_", bakery)
        try await b.engine.syncNow()
        // The zone goes before the Mac fetched the Bakery: it re-sends only what it has.
        await cloud.deleteZone("household")
        try await a.engine.syncNow()
        let missingOnServer = await cloud.record(named: bakeryUuid)
        XCTAssertNil(missingOnServer)

        let report = try await b.engine.syncNow()
        XCTAssertEqual(report.pull.reconciled, 1, "B re-sends what the Mac lacked")
        try await a.engine.syncNow()
        XCTAssertEqual(try a.descriptions(), ["Bakery", "Coffee"])
        XCTAssertEqual(try a.content(), try b.content())
    }

    func testAResentChildWhoseParentWasDeletedHereWaitsForIt() async throws {
        let (account, batch, coffee) = try base(a)
        let uuids = (try a.uuid("account", account), try a.uuid("importBatch", batch), try a.uuid("transaction_", coffee))
        try await a.engine.syncNow()
        try await b.engine.syncNow()
        await cloud.expireChangeTokens()
        try a.write { db in
            try db.execute(sql: "DELETE FROM transaction_")
            try db.execute(sql: "DELETE FROM importBatch")
            try db.execute(sql: "DELETE FROM account")
        }
        try await a.engine.syncNow()
        try await b.engine.syncNow()   // B never saw the deletes: all three go up again, resent
        let childOnServer = try await cloud.payload(named: uuids.2, keys: keys)
        let accountOnServer = try await cloud.payload(named: uuids.0, keys: keys)
        let batchOnServer = try await cloud.payload(named: uuids.1, keys: keys)
        let child = try XCTUnwrap(childOnServer)
        let parents = [try XCTUnwrap(accountOnServer), try XCTUnwrap(batchOnServer)]
        XCTAssertEqual(child.resent, true)

        // The child first: its parents were deleted here, so it waits for them; nothing is taken back yet.
        let first = try a.write { db in try SyncTranslator.apply([.save(child)], db: db, deviceUser: "user-a") }
        guard case .staged(let reason) = first[uuids.2] else { return XCTFail("\(first)") }
        XCTAssertTrue(reason.hasPrefix("waiting for "), reason)
        XCTAssertNotNil(try a.read { db in try SyncTombstoneRow.fetchOne(db, key: uuids.2) }, "the delete still stands")
        XCTAssertFalse(try conflictLog(a, uuids.2).contains { $0.contains("brought back") }, "nothing claimed yet")

        // Then the parents: all three come back, each logged.
        try a.write { db in _ = try SyncTranslator.apply(parents.map { .save($0) }, db: db, deviceUser: "user-a") }
        XCTAssertNotNil(try transaction(a, uuid: uuids.2))
        for uuid in [uuids.0, uuids.1, uuids.2] {
            XCTAssertTrue(try conflictLog(a, uuid).contains { $0.contains("brought back") }, uuid)
            XCTAssertNil(try a.read { db in try SyncTombstoneRow.fetchOne(db, key: uuid) })
        }
        try await a.engine.syncNow()
        try await b.engine.syncNow()
        XCTAssertEqual(try a.content(), try b.content())
    }

    func testAnEditDuringTheResendKeepsResentSoADeviceSeeingOnlyTheLatestVersionTakesItBack() async throws {
        let (_, _, coffee) = try base(a)
        let uuid = try a.uuid("transaction_", coffee)
        try await a.engine.syncNow()
        try await b.engine.syncNow()
        await cloud.expireChangeTokens()
        try a.write { db in try db.execute(sql: "DELETE FROM transaction_ WHERE id = ?", arguments: [coffee]) }
        try await a.engine.syncNow()

        // B's re-send of the coffee: while its save is on the way, B edits the row.
        let bCoffee = try XCTUnwrap(b.localId("transaction_", uuid))
        let device = b!
        let spy = SaveSpy(watching: uuid, keys: keys) {
            try? device.write { db in try db.execute(sql: "UPDATE transaction_ SET note = 'During the resend' WHERE id = ?", arguments: [bCoffee]) }
        }
        let engine = SyncEngineCore(db: b.queue, transport: SpyTransport(cloud: cloud, spy: spy), device: b.device, keyStore: keys)
        try await engine.syncNow()
        // The Mac only ever sees the latest version (the edit): it must still say "resent", or the Mac,
        // which deleted the coffee, would discard it and the two would diverge.
        XCTAssertEqual(spy.resentFlags, [true, true])
        try await a.engine.syncNow()
        XCTAssertEqual(try transaction(a, uuid: uuid)?["note"] as String?, "During the resend")
        XCTAssertEqual(try a.content(), try b.content())
        // Once taken, the record's later edits are ordinary updates.
        try b.write { db in try db.execute(sql: "UPDATE transaction_ SET note = 'Later' WHERE id = ?", arguments: [bCoffee]) }
        try await engine.syncNow()
        XCTAssertEqual(spy.resentFlags, [true, true, false])
    }

    func testAnEditThatFindsItsRecordDeletedOnICloudBringsItBackVisibly() async throws {
        let (_, _, coffee) = try base(a)
        let uuid = try a.uuid("transaction_", coffee)
        try await a.engine.syncNow()
        try await b.engine.syncNow()
        try a.write { db in try db.execute(sql: "DELETE FROM transaction_ WHERE id = ?", arguments: [coffee]) }
        try await a.engine.syncNow()
        await cloud.expireChangeTokens()
        let bCoffee = try XCTUnwrap(b.localId("transaction_", uuid))
        try b.write { db in try db.execute(sql: "UPDATE transaction_ SET status = 'confirmed' WHERE id = ?", arguments: [bCoffee]) }
        // The save finds the record deleted; the pull that follows is a full fetch, which lists no deletions.
        try await b.engine.pushPending()
        XCTAssertTrue(try conflictLog(b, uuid).contains { $0.contains("deleted on iCloud; your edit brought it back") })
        try await a.engine.syncNow()
        XCTAssertEqual(try transaction(a, uuid: uuid)?["status"] as String?, "confirmed")
        XCTAssertTrue(try conflictLog(a, uuid).contains { $0.contains("brought back") })
        XCTAssertEqual(try a.content(), try b.content())
    }

    func testAFirstFetchOnANewDeviceReconcilesNothing() async throws {
        try base(a)
        try await a.engine.syncNow()
        let report = try await b.engine.syncNow()
        XCTAssertEqual(report.pull.reconciled, 0)
        XCTAssertEqual(try b.count("syncConflict"), 0)
    }

    func testTheLeaseStoreReportsPassingFailuresAsUnavailable() async throws {
        try await cloud.createZone("household")
        let store = try leaseStore()
        await cloud.failSaveOperations(after: 0)
        do {
            _ = try await ImportLease.acquire(device: a.device, now: Date(), transport: store)
            XCTFail("no connection")
        } catch LeaseStoreError.unavailable {}
    }

    /// Final review M3: signed out of iCloud, or out of space, isn't "try again later": it reaches the caller as it is.
    func testTheLeaseStorePassesAccountFailuresThrough() async throws {
        try await cloud.createZone("household")
        let store = try leaseStore()
        for failure in [SyncTransportError.notAuthenticated, .quotaExceeded] {
            await cloud.failSaveOperations(after: 0, with: failure)
            do {
                _ = try await ImportLease.acquire(device: a.device, now: Date(), transport: store)
                XCTFail("refused")
            } catch let error as SyncTransportError {
                XCTAssertEqual(error, failure)
            }
        }
        await cloud.failSaveOperations(after: 0, with: .unavailable(retryAfter: 5))
        do {
            _ = try await ImportLease.acquire(device: a.device, now: Date(), transport: store)
            XCTFail("busy")
        } catch LeaseStoreError.unavailable {}
    }

    func testUploadedRecordsHoldNoReadableValueAnywhere() async throws {
        try a.write { db in
            var account = Account(name: "Probe Account Zeta", currency: .gbp, kind: .cash, trackingMode: .imported)
            try account.insert(db)
            var batch = ImportBatch(accountId: account.id!, sourceFileName: "probe-file.csv", importedAt: Self.day)
            try batch.insert(db)
            var t = Transaction(importBatchId: batch.id!, accountId: account.id!, date: Self.day, rawDescription: "Probe Shop Omega",
                                amountMinorUnits: -987_654, categoryId: nil, status: .pendingReview, categorizedBy: .none,
                                fingerprint: "fp-probe", note: "Probe note Kappa", isManual: true)
            try t.insert(db)
        }
        // A large record too, which travels as an encrypted asset.
        let large = String(repeating: "Probe large Sigma ", count: 70_000)
        try a.write { db in
            try db.execute(sql: """
                INSERT INTO transaction_(importBatchId, accountId, date, rawDescription, amountMinorUnits, status, categorizedBy, fingerprint, note, isManual)
                SELECT importBatchId, accountId, date, 'Long one', -1, status, categorizedBy, 'fp-long', ?, 1 FROM transaction_
                """, arguments: [large])
        }
        try await a.engine.syncNow()

        let unencrypted = await cloud.unencryptedFieldNames
        XCTAssertEqual(unencrypted, [], "the fake saw no field outside encryptedFields")
        let records = await cloud.storedRecords()
        XCTAssertGreaterThanOrEqual(records.count, 3)
        let probes = ["987654", "Probe Shop Omega", "Probe Account Zeta", "Probe note Kappa", "Probe large Sigma", "probe-file"]
        // Ruling R15: not even the encrypted fields hold a readable value (they were readable in the CloudKit
        // Console); each data record is exactly `sealed` + `keyId`, and the values are only inside the box.
        var readable = Set<String>()
        var opened = Set<String>()
        let held = try keys.allKeys(zone: "household")
        for record in records {
            XCTAssertTrue(record.unencryptedFields.isEmpty, record.recordType)
            let plaintext = [record.recordType, record.recordName, record.zone].joined(separator: "|")
            for probe in probes { XCTAssertFalse(plaintext.contains(probe), "\(probe) outside encrypted fields") }
            for value in record.encryptedFields.values {
                let text = String(decoding: value, as: UTF8.self)
                for probe in probes where text.contains(probe) { readable.insert(probe) }
            }
            guard !SyncEngineCore.reservedRecordTypes.contains(record.recordType) else { continue }
            XCTAssertEqual(Set(record.encryptedFields.keys), [FieldSealing.sealedField, FieldSealing.keyIdField], record.recordType)
            let inner = try FieldSealing.open(record, keys: held)
            for value in inner.encryptedFields.values {
                let text = String(decoding: value, as: UTF8.self)
                for probe in probes where text.contains(probe) { opened.insert(probe) }
            }
        }
        XCTAssertEqual(readable, [], "no value readable in the encrypted fields")
        XCTAssertTrue(opened.isSuperset(of: ["987654", "Probe Shop Omega", "Probe Account Zeta", "probe-file"]),
                      "the scan finds the values where they are: inside the sealed box (\(opened))")
        let assets = records.flatMap(\.assets.values)
        XCTAssertFalse(assets.isEmpty, "the large record went as an asset")
        for asset in assets {
            let text = String(decoding: asset, as: UTF8.self)
            for probe in probes { XCTAssertFalse(text.contains(probe), "an asset holds only ciphertext") }
        }
    }

    // MARK: R4: large payloads

    func testALargePayloadTravelsAsAnEncryptedAssetAndIsReassembled() async throws {
        let (_, _, coffee) = try base(a)
        let uuid = try a.uuid("transaction_", coffee)
        let large = String(repeating: "Synthetic long note. ", count: 60_000)   // ~1.26 MB
        try a.write { db in try db.execute(sql: "UPDATE transaction_ SET note = ? WHERE id = ?", arguments: [large, coffee]) }

        // The fake enforces CloudKit's record size limit: the payload as a plain record is refused.
        let payload = try a.write { db in
            try XCTUnwrap(SyncTranslator.outgoing(PendingChange(table: "transaction_", localId: coffee, uuid: uuid, kind: .insert), db: db))
        }
        try await cloud.createZone("household")
        let direct = try await cloud.save([try SyncWireRecord(payload)], ifUnchanged: [:], atomic: false)
        guard case .tooLarge = direct.first?.outcome else { return XCTFail("a record over 1 MB is refused: \(direct)") }

        try await a.engine.syncNow()
        let stored = try await cloud.record(named: uuid)
        XCTAssertNotNil(stored)
        let wire = await cloud.storedRecords().first { $0.recordName == uuid }
        XCTAssertLessThan(try XCTUnwrap(wire).size, 900_000, "what the server holds as the record is small")
        try await b.engine.syncNow()
        let arrived = try XCTUnwrap(transaction(b, uuid: uuid))
        XCTAssertEqual(arrived["note"] as String?, large, "reassembled on arrival")
        XCTAssertTrue(try b.read { db in try SyncChangeTracker.pending(db: db) }.isEmpty)
    }

    // MARK: Lease

    /// The lease store over the fake, sealing under a zone key held in the devices' shared key store (ruling R15).
    private func leaseStore() throws -> TransportLeaseStore {
        let key = DocumentCrypto.newZoneKey()
        try keys.store(key, zone: "household")
        return TransportLeaseStore(transport: cloud, sealingKey: key, keys: try keys.allKeys(zone: "household"))
    }

    /// Security review finding 2: a lease record that isn't sealed, is sealed under a key not held here, carries
    /// an unknown wire version or doesn't authenticate is `LeaseStoreError.unavailable` (the device waits or the
    /// zone is reset), never a raw `FieldSealing.SealingError` callers don't expect.
    func testAnyUnreadableLeaseRecordIsUnavailableToTheLeaseStore() async throws {
        try await cloud.createZone("household")
        let store = try leaseStore()
        let name = TransportLeaseStore.recordName
        let payload = SyncPayload(recordType: TransportLeaseStore.recordType, recordName: name, zone: "household", fields: [
            "holderId": .string("other"), "holderName": .string("Other"), "takenAt": .date(Date()), "expiresAt": .date(Date().addingTimeInterval(600)),
        ])
        let held = try XCTUnwrap(keys.key(zone: "household"))
        let (sealed, _) = try SyncLargePayload.wire(for: payload, key: held)
        var tampered = sealed
        var box = try XCTUnwrap(tampered.encryptedFields[FieldSealing.sealedField])
        box[box.count - 1] ^= 0xff
        tampered.encryptedFields[FieldSealing.sealedField] = box
        var unknownVersion = sealed
        var versioned = try XCTUnwrap(unknownVersion.encryptedFields[FieldSealing.sealedField])
        versioned[3] = 9
        unknownVersion.encryptedFields[FieldSealing.sealedField] = versioned
        let (foreign, _) = try SyncLargePayload.wire(for: payload, key: DocumentCrypto.newZoneKey())
        let notSealed = SyncWireRecord(recordType: TransportLeaseStore.recordType, recordName: name, zone: "household",
                                       encryptedFields: ["holderId": Data("other".utf8)])
        for (label, wire) in [("not sealed", notSealed), ("tampered", tampered), ("unknown version", unknownVersion), ("foreign key", foreign)] {
            let current = await cloud.record(named: name)
            let saved = try await cloud.save([wire], ifUnchanged: current.map { [name: $0.stamp.systemFields] } ?? [:], atomic: false)
            guard case .saved = saved.first?.outcome else { return XCTFail("\(label): not saved") }
            do {
                _ = try await store.currentLease()
                XCTFail("\(label): read")
            } catch LeaseStoreError.unavailable {
            } catch {
                XCTFail("\(label): \(error)")
            }
        }
    }

    func testTheLeaseOverTheTransportIsCompareAndSetOnTheServersClock() async throws {
        try await cloud.createZone("household")
        let store = try leaseStore()
        let mac = SyncDevice(id: "mac", name: "Mac")
        let ipad = SyncDevice(id: "ipad", name: "iPad")
        let start = await cloud.now
        let lease = try await ImportLease.acquire(device: mac, now: start, transport: store)
        let stored = try await store.currentLease()
        XCTAssertNotNil(stored?.serverModifiedAt, "the server's modification time comes with the lease")
        // The iPad's clock is 40 minutes fast: the server's clock still says the lease is held.
        do {
            _ = try await ImportLease.acquire(device: ipad, now: start.addingTimeInterval(40 * 60), transport: store)
            XCTFail("held by the server's clock")
        } catch ImportLeaseError.heldBy(let name, _) {
            XCTAssertEqual(name, "Mac")
        }
        // A write against a stale tag loses.
        do {
            _ = try await store.saveLease(lease.record, ifTag: "stale")
            XCTFail("compare-and-set")
        } catch LeaseStoreError.changed {}
        try await ImportLease.release(lease, transport: store)
        let free = try await ImportLease.holder(now: start, transport: store)
        XCTAssertNil(free)
        _ = try await ImportLease.acquire(device: ipad, now: start, transport: store)
        // 31 minutes later by the server's clock, the iPad's lease has expired for the Mac.
        await cloud.advanceClock(by: 31 * 60)
        _ = try await ImportLease.acquire(device: mac, now: start, transport: store)
        // The lease record never reaches the translator as data.
        try await b.engine.pull()
        XCTAssertEqual(try b.count("syncStaging"), 0)
    }

    private final class TestClock: @unchecked Sendable {
        private let lock = NSLock()
        private var value = Date()
        var now: Date { lock.withLock { value } }
        func advance(_ seconds: TimeInterval) { lock.withLock { value = value.addingTimeInterval(seconds) } }
    }

    func testAPushRenewsAUsedLeaseOnceItIsTenMinutesOld() async throws {
        let clock = TestClock()
        let engine = SyncEngineCore(db: a.queue, transport: cloud, device: a.device, keyStore: keys, clock: { clock.now })
        let (account, _, _) = try base(a)
        try await engine.syncNow()
        try await engine.acquireImportLease()
        let runId = try importRun(on: a, account: account, count: 1)
        // The run's record can't go yet, so the batch is still uploading.
        await cloud.failSaves(of: [try a.uuid("importRun", runId)], times: 100)
        let taken = try XCTUnwrap(a.read { db in try SyncImportGate.heldLease(db: db) })
        XCTAssertTrue(taken.used)
        clock.advance(5 * 60)
        try await engine.pushPending()
        XCTAssertEqual(try a.read { db in try SyncImportGate.heldLease(db: db) }?.record.expiresAt, taken.record.expiresAt, "not yet")
        clock.advance(6 * 60)
        try await engine.pushPending()
        let renewed = try XCTUnwrap(a.read { db in try SyncImportGate.heldLease(db: db) })
        XCTAssertEqual(renewed.record.expiresAt, clock.now.addingTimeInterval(ImportLease.duration))
        let server = try await TransportLeaseStore(transport: cloud, sealingKey: nil, keys: keys.allKeys(zone: "household")).currentLease()
        XCTAssertEqual(server?.record.expiresAt, renewed.record.expiresAt)
    }

    func testAnUnusedLeaseIsNeverRenewedAndIsDroppedOnceExpired() async throws {
        let clock = TestClock()
        let engine = SyncEngineCore(db: a.queue, transport: cloud, device: a.device, keyStore: keys, clock: { clock.now })
        try await engine.acquireImportLease()
        let taken = try XCTUnwrap(a.read { db in try SyncImportGate.heldLease(db: db) })
        func updatedAt(_ key: String) throws -> Date? {
            try a.read { db in try Date.fetchOne(db, sql: "SELECT updatedAt FROM syncState WHERE key = ?", arguments: [key]) }
        }
        XCTAssertEqual(try XCTUnwrap(updatedAt("importLease")).timeIntervalSince(clock.now), 0, accuracy: 0.002, "stamped with the engine's clock")
        let syncOn = try updatedAt("syncOn")
        clock.advance(11 * 60)
        try await engine.pushPending()
        XCTAssertEqual(try updatedAt("syncOn"), syncOn, "not written again when nothing changed")
        XCTAssertEqual(try a.read { db in try SyncImportGate.heldLease(db: db) }?.record.expiresAt, taken.record.expiresAt,
                       "a lease nobody imported under isn't kept alive")
        clock.advance(20 * 60)
        try await engine.pushPending()
        XCTAssertNil(try a.read { db in try SyncImportGate.heldLease(db: db) }, "dropped once expired")
    }

    func testUndoNeedsTheLeaseWhenSyncIsOn() async throws {
        let (account, _, _) = try base(a)
        try await a.engine.syncNow()
        try await a.engine.acquireImportLease()
        let runId = try importRun(on: a, account: account, count: 2)
        try await a.engine.syncNow()
        XCTAssertNil(try a.read { db in try SyncImportGate.heldLease(db: db) }, "released after the close went")

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("SyncEngineUndo-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let library = EvidenceLibrary(root: folder, database: a.queue)
        XCTAssertThrowsError(try ImportUndo.undo(dbQueue: a.queue, library: library, runId: runId)) { error in
            XCTAssertEqual(error as? SyncImportGateError, .leaseRequired)
        }
        XCTAssertEqual(try a.descriptions().filter { $0.hasPrefix("Shop") }.count, 2, "nothing was undone")
        try await a.engine.acquireImportLease()
        _ = try ImportUndo.undo(dbQueue: a.queue, library: library, runId: runId)
        XCTAssertEqual(try a.descriptions().filter { $0.hasPrefix("Shop") }.count, 0)
        try await a.engine.syncNow()
        let holder = try await b.engine.importLeaseHolder()
        XCTAssertNil(holder, "the Undo's lease is released once its close is uploaded")
    }

    func testConfirmWithoutSyncOnNeedsNoLease() throws {
        let (account, _, _) = try base(a)
        XCTAssertNoThrow(try importRun(on: a, account: account, count: 1), "a device that never synced confirms as before")
    }

    // MARK: R8: staging is bounded

    func testStagedApplyFailuresStopAfterFiveAttemptsAndNeedAttention() throws {
        let (_, _, coffee) = try base(a)
        let uuid = try a.uuid("transaction_", coffee)
        let device = try SyncTestDevice("user-x")
        let sent = try a.write { db -> [SyncIncomingChange] in
            var changes: [SyncIncomingChange] = []
            for change in try SyncChangeTracker.pending(db: db) {
                if var payload = try SyncTranslator.outgoing(change, db: db) {
                    if payload.recordName == uuid { payload.fields["rawDescription"] = .null }   // NOT NULL: SQLite refuses it
                    changes.append(.save(payload))
                }
            }
            return changes
        }
        let first = Self.day
        // The parents first, then the record SQLite refuses (each apply that tries it is one attempt).
        let parents = sent.filter { if case .save(let p) = $0 { return p.recordName != uuid } else { return true } }
        try device.write { db in _ = try SyncTranslator.apply(parents, db: db, deviceUser: "user-x", now: first) }
        try device.write { db in _ = try SyncTranslator.apply(sent.filter { !parents.contains($0) }, db: db, deviceUser: "user-x", now: first) }
        func staged() throws -> SyncStagingRow? {
            try device.read { db in try SyncStagingRow.filter(Column("uuid") == uuid).fetchOne(db) }
        }
        var row = try XCTUnwrap(staged())
        XCTAssertTrue(row.reason.hasPrefix("apply failed"), row.reason)
        XCTAssertEqual(row.attempts, 1)
        XCTAssertEqual(row.firstSeenAt, first)
        for i in 1...6 {
            try device.write { db in _ = try SyncTranslator.retryStaged(db: db, deviceUser: "user-x", now: first.addingTimeInterval(Double(i) * 60)) }
        }
        row = try XCTUnwrap(staged())
        XCTAssertEqual(row.attempts, 5, "retries stop after five")
        XCTAssertTrue(row.reason.hasPrefix("needs attention: "), row.reason)
        XCTAssertEqual(row.firstSeenAt, first, "the first-seen time stays")
        let attention = try device.read { db in try SyncTranslator.stagingAttention(db: db, now: first.addingTimeInterval(3600)) }
        XCTAssertEqual(attention.map(\.uuid), [uuid])
        // A record that only waits is listed once it has waited too long.
        let waiting = try device.read { db in try SyncTranslator.stagingAttention(db: db, now: first.addingTimeInterval(8 * 86_400)) }
        XCTAssertEqual(waiting.map(\.uuid), [uuid])
    }
}

/// `FakeCloud` on its own: the parts of `CKDatabase`'s behaviour the engine relies on (ruling R11).
final class FakeCloudTests: XCTestCase {
    private let zone = "household"

    private func record(_ name: String, _ value: Int64, type: String = "account") throws -> SyncWireRecord {
        try SyncWireRecord(SyncPayload(recordType: type, recordName: name, zone: "household", fields: ["value": .int(value)]))
    }

    private func stamp(_ results: [SaveResult], _ name: String) -> SyncServerStamp? {
        for result in results where result.recordName == name {
            if case .saved(let stamp) = result.outcome { return stamp }
        }
        return nil
    }

    private func value(_ record: SyncServerRecord?) throws -> SyncValue? { try record?.wire.payload().fields["value"] }

    func testZonesMustBeCreatedFirst() async throws {
        let cloud = FakeCloud()
        let early = try await cloud.save([try record("r1", 1)], ifUnchanged: [:], atomic: false)
        XCTAssertEqual(early.first?.outcome, .zoneNotFound)
        do {
            _ = try await cloud.changes(since: nil, zone: zone)
            XCTFail("no zone yet")
        } catch SyncTransportError.zoneNotFound {}
        try await cloud.createZone(zone)
        let saved = try await cloud.save([try record("r1", 1)], ifUnchanged: [:], atomic: false)
        XCTAssertNotNil(stamp(saved, "r1"))
    }

    func testCompareAndSetOnSystemFields() async throws {
        let cloud = FakeCloud(zones: [zone])
        let firstResults = try await cloud.save([try record("r1", 1)], ifUnchanged: [:], atomic: false)
        let first = try XCTUnwrap(stamp(firstResults, "r1"))
        XCTAssertNotEqual(first.systemFields, Data(first.changeTag.utf8), "the system fields blob is not the tag")
        // A save without system fields of a record the server has is refused, with the server's record.
        let blind = try await cloud.save([try record("r1", 2)], ifUnchanged: [:], atomic: false)
        guard case .changed(let server) = blind.first?.outcome else { return XCTFail("\(blind)") }
        XCTAssertEqual(try value(server), .int(1))
        XCTAssertEqual(server.stamp.changeTag, first.changeTag)
        let secondResults = try await cloud.save([try record("r1", 3)], ifUnchanged: ["r1": first.systemFields], atomic: false)
        let second = try XCTUnwrap(stamp(secondResults, "r1"))
        XCTAssertNotEqual(first.changeTag, second.changeTag)
        let stale = try await cloud.save([try record("r1", 4)], ifUnchanged: ["r1": first.systemFields], atomic: false)
        guard case .changed = stale.first?.outcome else { return XCTFail("a stale version loses") }
        try await cloud.delete(["r1"], zone: zone)
        let afterDelete = try await cloud.save([try record("r1", 5)], ifUnchanged: ["r1": second.systemFields], atomic: false)
        XCTAssertEqual(afterDelete.first?.outcome, .deleted)
        let recreated = try await cloud.save([try record("r1", 6)], ifUnchanged: [:], atomic: false)
        XCTAssertNotNil(stamp(recreated, "r1"), "a record deleted on the server can be created again")
    }

    func testAtomicSavesAreAllOrNothingAndNonAtomicOnesAreNot() async throws {
        let cloud = FakeCloud(zones: [zone])
        _ = try await cloud.save([try record("taken", 1)], ifUnchanged: [:], atomic: false)
        let atomic = try await cloud.save([try record("a", 1), try record("taken", 2), try record("b", 1)], ifUnchanged: [:], atomic: true)
        XCTAssertEqual(atomic.map(\.outcome.isBatchFailure), [true, false, true])
        let nothing = await cloud.record(named: "a")
        XCTAssertNil(nothing, "an atomic operation with one failure saves nothing")
        let loose = try await cloud.save([try record("a", 1), try record("taken", 2), try record("b", 1)], ifUnchanged: [:], atomic: false)
        XCTAssertNotNil(stamp(loose, "a"))
        XCTAssertNotNil(stamp(loose, "b"))
    }

    func testOperationLimitsAndTheRecordSizeLimit() async throws {
        let cloud = FakeCloud(limits: SyncOperationLimits(maxRecords: 2, maxBytes: 600), zones: [zone])
        do {
            _ = try await cloud.save([try record("a", 1), try record("b", 1), try record("c", 1)], ifUnchanged: [:], atomic: false)
            XCTFail("three records is over the count")
        } catch SyncTransportError.limitExceeded {}
        let big = SyncWireRecord(recordType: "account", recordName: "big", zone: zone, encryptedFields: ["f_x": Data(count: 500)])
        do {
            _ = try await cloud.save([big, try record("a", 1)], ifUnchanged: [:], atomic: false)
            XCTFail("over the bytes")
        } catch SyncTransportError.limitExceeded {}
        let large = FakeCloud(zones: [zone])
        let huge = SyncWireRecord(recordType: "document", recordName: "huge", zone: zone, encryptedFields: ["f_text": Data(count: 1_100_000)])
        let refused = try await large.save([huge], ifUnchanged: [:], atomic: false)
        guard case .tooLarge = refused.first?.outcome else { return XCTFail("\(refused)") }
    }

    func testAssetsLiveWithTheRecordVersion() async throws {
        let cloud = FakeCloud(zones: [zone])
        var withAsset = try record("doc", 1, type: "document")
        withAsset.assets["file"] = Data(count: 2_000_000)
        let firstResults = try await cloud.save([withAsset], ifUnchanged: [:], atomic: false)
        let first = try XCTUnwrap(stamp(firstResults, "doc"),
                                  "assets don't count towards the record size")
        let stored = await cloud.record(named: "doc")
        XCTAssertEqual(stored?.wire.assets["file"]?.count, 2_000_000)
        _ = try await cloud.save([try record("doc", 2, type: "document")], ifUnchanged: ["doc": first.systemFields], atomic: false)
        let replaced = await cloud.record(named: "doc")
        XCTAssertNil(replaced?.wire.assets["file"], "the asset went with its version")
    }

    func testFeedsCarryOnlyLatestVersionsAndTombstonesInFeedOrderAndPages() async throws {
        let cloud = FakeCloud(pageSize: 2, zones: [zone, "private-other"])
        var stamps: [String: SyncServerStamp] = [:]
        for name in ["r1", "r2", "r3"] { stamps[name] = stamp(try await cloud.save([try record(name, 1)], ifUnchanged: [:], atomic: false), name) }
        let full = try await cloud.changes(since: nil, zone: zone)
        XCTAssertEqual(full.records.map(\.wire.recordName), ["r1", "r2"])
        XCTAssertTrue(full.moreComing)
        let rest = try await cloud.changes(since: full.token, zone: zone)
        XCTAssertEqual(rest.records.map(\.wire.recordName), ["r3"])
        XCTAssertFalse(rest.moreComing)

        await cloud.setPageSize(10)
        try await cloud.delete(["r2"], zone: zone)
        for value in [2, 3] as [Int64] {
            stamps["r1"] = stamp(try await cloud.save([try record("r1", value)], ifUnchanged: ["r1": stamps["r1"]!.systemFields], atomic: false), "r1")
        }
        let delta = try await cloud.changes(since: rest.token, zone: zone)
        XCTAssertEqual(delta.changes.count, 2, "one entry per record")
        guard case .deletion(let deletion) = delta.changes.first, case .record(let latest) = delta.changes.last else {
            return XCTFail("feed order: the delete came first: \(delta.changes)")
        }
        XCTAssertEqual(deletion, SyncDeletion(recordName: "r2", recordType: "account"))
        XCTAssertEqual(try value(latest), .int(3), "its latest version only")
        let fresh = try await cloud.changes(since: nil, zone: zone)
        XCTAssertEqual(Set(fresh.records.map(\.wire.recordName)), ["r1", "r3"], "a fetch from scratch sees what exists")
        XCTAssertTrue(fresh.deletions.isEmpty)
        let other = try await cloud.changes(since: nil, zone: "private-other")
        XCTAssertTrue(other.changes.isEmpty, "zones are separate")

        await cloud.expireChangeTokens()
        do {
            _ = try await cloud.changes(since: delta.token, zone: zone)
            XCTFail("expired")
        } catch SyncTransportError.changeTokenExpired {}
    }

    func testServerClockAndALostReply() async throws {
        let cloud = FakeCloud(zones: [zone])
        let before = await cloud.now
        await cloud.advanceClock(by: 60)
        let savedResults = try await cloud.save([try record("r1", 1)], ifUnchanged: [:], atomic: false)
        let saved = try XCTUnwrap(stamp(savedResults, "r1"))
        XCTAssertGreaterThanOrEqual(saved.modifiedAt.timeIntervalSince(before), 60)
        let serverNow = try await cloud.serverTime()
        XCTAssertNotNil(serverNow)
        await cloud.loseTheNextReply()
        do {
            _ = try await cloud.save([try record("r2", 1)], ifUnchanged: [:], atomic: false)
            XCTFail("the reply is lost")
        } catch SyncTransportError.networkUnavailable {}
        let applied = await cloud.record(named: "r2")
        XCTAssertNotNil(applied, "but the save was applied")
    }

    func testAPlaintextFieldIsRecordedAsUnencrypted() async throws {
        let cloud = FakeCloud(zones: [zone])
        var wire = try record("r1", 1)
        XCTAssertTrue(wire.unencryptedFields.isEmpty, "BudgetCore puts every value in encryptedFields")
        wire.unencryptedFields["amount"] = Data("12".utf8)
        _ = await cloud.save(wire: wire, ifUnchanged: nil)
        let names = await cloud.unencryptedFieldNames
        XCTAssertEqual(names, ["account.amount"])
    }

    func testWireRecordsRoundTripEveryPart() throws {
        var original = SyncPayload(recordType: "importRun", recordName: "r1", zone: "household", fields: ["value": .int(7), "note": .null])
        original.clocks = ["*": SyncClock(at: Date(timeIntervalSince1970: 5), by: "u"), "value": SyncClock(at: Date(timeIntervalSince1970: 9), by: nil)]
        original.modifiedBy = "u"
        original.modifiedAt = Date(timeIntervalSince1970: 11)
        original.mergedInto = "other"
        original.importRunUuid = "run"
        original.batchGeneration = 2
        original.manifest = SyncBatchManifest(generation: 2, isOpen: false)
        original.manifest?.counts = ["transaction_": 3]
        original.manifest?.deletes = ["gone"]
        original.manifest?.revives = ["back"]
        original.deletedReferences = ["gone"]
        original.largePayload = SyncLargePayloadReference(assetField: "payload")
        original.resent = true
        original.documentFile = SyncDocumentFileReference(recordName: "r1.file.1", wrappedKey: Data([4, 5, 6]))
        // Every property is set: a property added later without a value here fails this.
        for child in Mirror(reflecting: original).children {
            XCTAssertNotEqual(String(describing: child.value), "nil", "\(child.label ?? "?") is set in this test")
        }
        let wire = try SyncWireRecord(original)
        XCTAssertEqual(Set(wire.encryptedFields.keys), ["f_value", "f_note", "meta"])
        XCTAssertEqual(try wire.payload(), original)
    }
}

/// Records whether each save of one record carried `resent`, and runs `hook` once, after the first such
/// save reached the server (before the engine takes its reply in).
final class SaveSpy: @unchecked Sendable {
    private let lock = NSLock()
    private var flags: [Bool] = []
    private var hook: (() -> Void)?
    let watching: String
    let keys: any SyncKeyStore

    init(watching: String, keys: any SyncKeyStore, hook: @escaping () -> Void) {
        self.watching = watching
        self.keys = keys
        self.hook = hook
    }

    var resentFlags: [Bool] { lock.withLock { flags } }

    func saw(_ records: [SyncWireRecord]) -> Bool {
        lock.withLock {
            var seen = false
            for record in records where record.recordName == watching {
                flags.append((try? SyncLargePayload.payload(from: record, keys: (try? keys.allKeys(zone: record.zone)) ?? [:]))?.resent == true)
                seen = true
            }
            return seen
        }
    }

    func fireOnce() {
        let hook = lock.withLock { () -> (() -> Void)? in
            defer { self.hook = nil }
            return self.hook
        }
        hook?()
    }
}

/// `FakeCloud` with a `SaveSpy` on its saves.
struct SpyTransport: SyncTransport {
    let cloud: FakeCloud
    let spy: SaveSpy

    func operationLimits() async -> SyncOperationLimits { await cloud.operationLimits() }
    func createZone(_ zone: String) async throws { try await cloud.createZone(zone) }
    func save(_ records: [SyncWireRecord], ifUnchanged: [String: Data], atomic: Bool) async throws -> [SaveResult] {
        let watched = spy.saw(records)
        let results = try await cloud.save(records, ifUnchanged: ifUnchanged, atomic: atomic)
        if watched { spy.fireOnce() }
        return results
    }
    func changes(since token: Data?, zone: String) async throws -> SyncChanges { try await cloud.changes(since: token, zone: zone) }
    func delete(_ recordNames: [String], zone: String) async throws { try await cloud.delete(recordNames, zone: zone) }
    func fetch(_ recordName: String, zone: String) async throws -> SyncServerRecord? { try await cloud.fetch(recordName, zone: zone) }
    func serverTime() async throws -> Date? { try await cloud.serverTime() }
}

extension SaveResult.Outcome {
    var isBatchFailure: Bool { self == .batchRequestFailed }
}

extension SyncTestDevice {
    func read<T>(_ body: (Database) throws -> T) throws -> T { try queue.read(body) }
    func write<T>(_ body: (Database) throws -> T) throws -> T { try queue.write(body) }
}
