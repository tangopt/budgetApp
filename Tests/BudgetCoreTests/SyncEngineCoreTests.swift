import XCTest
import GRDB
@testable import BudgetCore

/// One simulated device for the engine: its own in-memory database, signed in as `user`, syncing through
/// a shared `FakeCloud`.
final class SyncEngineTestDevice {
    let manager: DatabaseManager
    let user: String
    let device: SyncDevice
    let engine: SyncEngineCore
    var queue: DatabaseQueue { manager.dbQueue }

    init(_ user: String, name: String, cloud: FakeCloud, batchSize: Int = 200, path: String? = nil) throws {
        manager = try DatabaseManager(path: path)
        try manager.migrate()
        self.user = user
        device = SyncDevice(id: "device-\(user)", name: name)
        try manager.dbQueue.write { db in try SyncChangeTracker.setWriter(user, db: db) }
        engine = SyncEngineCore(db: manager.dbQueue, transport: cloud, device: device, batchSize: batchSize)
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
    private var a: SyncEngineTestDevice!
    private var b: SyncEngineTestDevice!

    override func setUp() async throws {
        cloud = FakeCloud()
        a = try SyncEngineTestDevice("user-a", name: "Mac", cloud: cloud)
        b = try SyncEngineTestDevice("user-b", name: "iPad", cloud: cloud)
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
        let server = try await cloud.record(named: uuid)
        XCTAssertEqual(server?.payload.fields["note"], .string("Mac note"))
        XCTAssertEqual(server?.payload.fields["status"], .string("confirmed"))
    }

    func testImportBatchArrivesAtomically() async throws {
        a = try SyncEngineTestDevice("user-a", name: "Mac", cloud: cloud, batchSize: 2)
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
            } catch FakeCloudError.networkUnavailable {
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
        let c = try SyncEngineTestDevice("user-c", name: "iPhone", cloud: cloud)
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
        let c = try SyncEngineTestDevice("user-c", name: "iPhone", cloud: cloud)
        try await c.engine.pull()
        XCTAssertEqual(try c.descriptions().filter { $0.hasPrefix("Shop") }.sorted(), ["Shop 1", "Shop 2"])
        XCTAssertEqual(try c.count("syncStaging"), 0)
        // The change log names the deleted row by its tombstone on B, and by 0 on C, which never had it (R7).
        XCTAssertEqual(try c.content(excluding: ["importChange"]), try b.content(excluding: ["importChange"]))
    }

    func testUploadedPayloadsContainNoPlaintextAmountsOutsideEncryptedFields() async throws {
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
        var foundEncrypted = Set<String>()
        for record in records {
            XCTAssertTrue(record.unencryptedFields.isEmpty, record.recordType)
            let plaintext = [record.recordType, record.recordName, record.zone].joined(separator: "|")
            for probe in probes { XCTAssertFalse(plaintext.contains(probe), "\(probe) outside encrypted fields") }
            for value in record.encryptedFields.values {
                let text = String(decoding: value, as: UTF8.self)
                for probe in probes where text.contains(probe) { foundEncrypted.insert(probe) }
            }
        }
        XCTAssertTrue(foundEncrypted.isSuperset(of: ["987654", "Probe Shop Omega", "Probe Account Zeta", "probe-file"]),
                      "the scan sees the values where they are: in encrypted fields (\(foundEncrypted))")
        let assets = await cloud.storedAssets()
        XCTAssertFalse(assets.isEmpty, "the large record went as an asset")
        for asset in assets.values {
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
        let direct = try await cloud.save([payload], ifUnchanged: [:])
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

    func testTheLeaseOverTheTransportIsCompareAndSetOnTheServersClock() async throws {
        let store = TransportLeaseStore(transport: cloud)
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

    func testAPushRenewsTheLeaseOnceItIsTenMinutesOld() async throws {
        final class Clock: @unchecked Sendable {
            private let lock = NSLock()
            private var value = Date(timeIntervalSinceReferenceDate: 800_000_000)
            var now: Date { lock.withLock { value } }
            func advance(_ seconds: TimeInterval) { lock.withLock { value = value.addingTimeInterval(seconds) } }
        }
        let clock = Clock()
        let engine = SyncEngineCore(db: a.queue, transport: cloud, device: a.device, clock: { clock.now })
        try await engine.acquireImportLease()
        let taken = try XCTUnwrap(a.read { db in try SyncImportGate.heldLease(db: db) })
        clock.advance(5 * 60)
        try await engine.pushPending()
        XCTAssertEqual(try a.read { db in try SyncImportGate.heldLease(db: db) }?.record.expiresAt, taken.record.expiresAt, "not yet")
        clock.advance(6 * 60)
        try await engine.pushPending()
        let renewed = try XCTUnwrap(a.read { db in try SyncImportGate.heldLease(db: db) })
        XCTAssertEqual(renewed.record.expiresAt, clock.now.addingTimeInterval(ImportLease.duration))
        let server = try await TransportLeaseStore(transport: cloud).currentLease()
        XCTAssertEqual(server?.tag, renewed.tag)
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

/// `FakeCloud` on its own: the parts of CloudKit's behaviour the engine relies on.
final class FakeCloudTests: XCTestCase {
    private func payload(_ name: String, _ value: Int64, type: String = "account") -> SyncPayload {
        SyncPayload(recordType: type, recordName: name, zone: "household", fields: ["value": .int(value)])
    }

    private func tag(_ results: [SaveResult], _ name: String) -> String? {
        for result in results where result.recordName == name {
            if case .saved(let tag, _) = result.outcome { return tag }
        }
        return nil
    }

    func testCompareAndSetOnChangeTags() async throws {
        let cloud = FakeCloud()
        let first = try await cloud.save([payload("r1", 1)], ifUnchanged: [:])
        let tag1 = try XCTUnwrap(tag(first, "r1"))
        // A save without the tag of a record the server has is refused, with the server's record.
        let blind = try await cloud.save([payload("r1", 2)], ifUnchanged: [:])
        guard case .changed(let server) = blind.first?.outcome else { return XCTFail("\(blind)") }
        XCTAssertEqual(server.payload.fields["value"], .int(1))
        XCTAssertEqual(server.changeTag, tag1)
        let second = try await cloud.save([payload("r1", 3)], ifUnchanged: ["r1": tag1])
        let tag2 = try XCTUnwrap(tag(second, "r1"))
        XCTAssertNotEqual(tag1, tag2)
        let stale = try await cloud.save([payload("r1", 4)], ifUnchanged: ["r1": tag1])
        guard case .changed = stale.first?.outcome else { return XCTFail("a stale tag loses") }
        try await cloud.delete(["r1"], zone: "household")
        let afterDelete = try await cloud.save([payload("r1", 5)], ifUnchanged: ["r1": tag2])
        guard case .deleted = afterDelete.first?.outcome else { return XCTFail("a save against a deleted record: \(afterDelete)") }
        let recreated = try await cloud.save([payload("r1", 6)], ifUnchanged: [:])
        XCTAssertNotNil(tag(recreated, "r1"), "a record deleted on the server can be created again")
    }

    func testFeedsCarryOnlyLatestVersionsAndTombstonesInPages() async throws {
        let cloud = FakeCloud(pageSize: 2)
        var tags: [String: String] = [:]
        for name in ["r1", "r2", "r3"] { tags[name] = tag(try await cloud.save([payload(name, 1)], ifUnchanged: [:]), name) }
        let full = try await cloud.changes(since: nil, zone: "household")
        XCTAssertEqual(full.records.map(\.payload.recordName), ["r1", "r2"])
        XCTAssertTrue(full.moreComing)
        let rest = try await cloud.changes(since: full.token, zone: "household")
        XCTAssertEqual(rest.records.map(\.payload.recordName), ["r3"])
        XCTAssertFalse(rest.moreComing)

        for value in [2, 3] as [Int64] {
            let saved = try await cloud.save([payload("r1", value)], ifUnchanged: ["r1": tags["r1"]!])
            tags["r1"] = tag(saved, "r1")
        }
        try await cloud.delete(["r2"], zone: "household")
        let delta = try await cloud.changes(since: rest.token, zone: "household")
        XCTAssertEqual(delta.records.map(\.payload.recordName), ["r1"], "one entry per record")
        XCTAssertEqual(delta.records.first?.payload.fields["value"], .int(3), "its latest version only")
        XCTAssertEqual(delta.deletions.map(\.recordName), ["r2"])
        XCTAssertEqual(delta.deletions.first?.recordType, "account")
        let fresh = try await cloud.changes(since: nil, zone: "household")
        let names = fresh.records.map(\.payload.recordName)
        XCTAssertEqual(Set(names), ["r1", "r3"], "a fetch from scratch sees what exists")
        let empty = try await cloud.changes(since: nil, zone: "private-other")
        XCTAssertTrue(empty.records.isEmpty, "zones are separate")
    }

    func testRecordSizeLimitAndServerClock() async throws {
        let cloud = FakeCloud()
        let big = SyncPayload(recordType: "document", recordName: "big", zone: "household",
                              fields: ["text": .string(String(repeating: "x", count: 1_100_000))])
        let refused = try await cloud.save([big], ifUnchanged: [:])
        guard case .tooLarge = refused.first?.outcome else { return XCTFail("\(refused)") }
        let before = await cloud.now
        await cloud.advanceClock(by: 60)
        let saved = try await cloud.save([payload("r1", 1)], ifUnchanged: [:])
        guard case .saved(_, let at) = saved.first?.outcome else { return XCTFail() }
        XCTAssertGreaterThanOrEqual(at.timeIntervalSince(before), 60)
        let serverNow = try await cloud.serverTime()
        XCTAssertNotNil(serverNow)
    }

    func testAPlaintextFieldIsRecordedAsUnencrypted() async throws {
        let cloud = FakeCloud()
        var wire = try SyncWireRecord(payload("r1", 1))
        XCTAssertTrue(wire.unencryptedFields.isEmpty, "BudgetCore puts every value in encryptedFields")
        wire.unencryptedFields["amount"] = Data("12".utf8)
        _ = await cloud.save(wire: wire, ifUnchanged: nil)
        let names = await cloud.unencryptedFieldNames
        XCTAssertEqual(names, ["account.amount"])
    }

    func testWireRecordsRoundTripEveryPart() throws {
        var original = payload("r1", 7)
        original.clocks = ["*": SyncClock(at: Date(timeIntervalSince1970: 5), by: "u")]
        original.modifiedBy = "u"
        original.importRunUuid = "run"
        original.batchGeneration = 1
        original.deletedReferences = ["gone"]
        let wire = try SyncWireRecord(original)
        XCTAssertEqual(try wire.payload(), original)
    }
}

extension SyncTestDevice {
    func read<T>(_ body: (Database) throws -> T) throws -> T { try queue.read(body) }
    func write<T>(_ body: (Database) throws -> T) throws -> T { try queue.write(body) }
}
