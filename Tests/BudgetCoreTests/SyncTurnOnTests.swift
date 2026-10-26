import XCTest
import GRDB
@testable import BudgetCore
import TestSupport

/// Step 6 Task 12: turning on sync for the real database (`SyncTurnOn`): a timestamped backup, then the ownership sheet
/// confirmed, then the first upload (resumable), then done; the blockers and their copy; the Mac engine's role.
/// Synthetic data only, in files under a temporary folder; every push goes through `ZoneAuditingTransport`.
final class SyncTurnOnTests: XCTestCase {
    private var folder: URL!
    private let day = Date(timeIntervalSince1970: 1_790_000_000)

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("SyncTurnOnTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    /// Synchronous access (async tests would otherwise pick GRDB's async overloads).
    private func read<T>(_ queue: DatabaseQueue, _ body: (Database) throws -> T) throws -> T { try queue.read(body) }
    private func write<T>(_ queue: DatabaseQueue, _ body: (Database) throws -> T) throws -> T { try queue.write(body) }

    private func path(_ name: String) throws -> String {
        let directory = folder.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(name).path
    }

    /// A migrated database file with an admin (Synthetic Person A) and two accounts, ownership not confirmed yet.
    private func unconfirmed() throws -> (manager: DatabaseManager, path: String, admin: AccessActor) {
        let path = try path("budget.sqlite")
        let manager = try TestDatabase.migratedManager(path: path)
        let admin = try write(manager.dbQueue) { db -> AccessActor in
            try db.execute(sql: "INSERT INTO person(name) VALUES ('Synthetic Person A')")
            var user = AppUser(personId: db.lastInsertedRowID, displayName: "A", isAdmin: true, createdAt: day)
            try user.insert(db)
            for name in ["Synthetic shared", "Synthetic private"] {
                _ = try AccountEditing.add(db: db, name: name, currency: .gbp, kind: .cash, openingBalanceEntered: nil, asOf: day)
            }
            try ActorWrite.useDefaultWriter(appUserId: nil, db: db)
            return try AccessActor.load(appUserId: user.id!, db: db)
        }
        return (manager, path, admin)
    }

    /// The `SharingFixture` household (ownership confirmed) in a database file.
    private func household() throws -> (manager: DatabaseManager, path: String, fixture: SharingFixture) {
        let path = try path("budget.sqlite")
        let manager = try TestDatabase.migratedManager(path: path)
        let fixture = try write(manager.dbQueue) { db -> SharingFixture in
            let fixture = try SharingFixture.build(db)
            try ActorWrite.useDefaultWriter(appUserId: nil, db: db)
            return fixture
        }
        return (manager, path, fixture)
    }

    private func progress(_ queue: DatabaseQueue) throws -> SyncTurnOn.Progress {
        try read(queue) { db in try SyncTurnOn.progress(db: db) }
    }

    private func assertThrows(_ expected: SyncTurnOn.TurnOnError, file: StaticString = #filePath, line: UInt = #line, _ body: () throws -> Void) {
        XCTAssertThrowsError(try body(), file: file, line: line) { error in
            XCTAssertEqual(error as? SyncTurnOn.TurnOnError, expected, file: file, line: line)
        }
    }

    /// Backup, ownership (already confirmed by the fixture), keys in `keys`, upload begun: the total.
    @discardableResult
    private func begin(_ manager: DatabaseManager, _ keys: any SyncKeyStore) throws -> Int {
        try SyncTurnOn.backUp(manager: manager, now: day)
        try write(manager.dbQueue) { db in try SyncTurnOn.markOwnershipConfirmed(db: db, now: day) }
        try prepareKeys(manager.dbQueue, keys)
        return try write(manager.dbQueue) { db in
            try SyncTurnOn.beginUpload(admin: try AccessActor.admin(db: db), cloudKitUserRecordName: "_admin", db: db, now: day)
        }
    }

    /// An engine of the admin's Mac (its viewer, re-validating) over `transport`.
    private func macEngine(_ queue: DatabaseQueue, _ transport: any SyncTransport, keys: any SyncKeyStore, batchSize: Int = 200) throws -> SyncEngineCore {
        let role = try read(queue) { db in try SyncTurnOn.macEngineRole(signedIn: try AccessActor.admin(db: db), db: db) }
        return SyncEngineCore(db: queue, transport: transport, device: SyncDevice(id: "admin-mac", name: "Mac"), keyStore: keys, batchSize: batchSize,
                              viewer: role.viewer, revalidatesAccess: role.revalidatesAccess)
    }

    /// The turn-on's keys for the household and the admin's private zone, made in `keys` (stage `keysReady`).
    private func prepareKeys(_ queue: DatabaseQueue, _ keys: any SyncKeyStore) throws {
        try write(queue) { db in
            try SyncTurnOn.prepareKeys(zones: try SyncTurnOn.turnOnZones(admin: try AccessActor.admin(db: db), db: db), keyStore: keys, db: db, now: day)
        }
    }

    func testStagesAdvanceInOrderAndNeverBack() async throws {
        let (manager, _, admin) = try unconfirmed()
        let queue = manager.dbQueue
        XCTAssertEqual(try progress(queue), SyncTurnOn.Progress(stage: .notStarted, backupPath: nil, total: 0, sent: 0))

        // Nothing before the backup.
        assertThrows(.wrongStage(.notStarted)) { try self.write(queue) { db in try SyncTurnOn.markOwnershipConfirmed(db: db, now: self.day) } }
        assertThrows(.wrongStage(.notStarted)) {
            _ = try self.write(queue) { db in try SyncTurnOn.beginUpload(admin: admin, cloudKitUserRecordName: "_user", db: db, now: self.day) }
        }
        assertThrows(.wrongStage(.notStarted)) { try self.write(queue) { db in try SyncTurnOn.markDone(db: db, now: self.day) } }

        let first = try SyncTurnOn.backUp(manager: manager, now: day)
        XCTAssertEqual(try progress(queue), SyncTurnOn.Progress(stage: .backedUp, backupPath: first.path, total: 0, sent: 0))
        // Ownership not saved yet: refused, the stage stays.
        assertThrows(.ownershipNotConfirmed) { try self.write(queue) { db in try SyncTurnOn.markOwnershipConfirmed(db: db, now: self.day) } }
        XCTAssertEqual(try progress(queue).stage, .backedUp)
        assertThrows(.wrongStage(.backedUp)) {
            _ = try self.write(queue) { db in try SyncTurnOn.beginUpload(admin: admin, cloudKitUserRecordName: "_user", db: db, now: self.day) }
        }

        try write(queue) { db in
            try SharingSetup.save(try SharingSetup.proposal(admin: admin, db: db), admin: admin, db: db, now: day)
            try SyncTurnOn.markOwnershipConfirmed(db: db, now: day)
        }
        XCTAssertEqual(try progress(queue).stage, .ownershipConfirmed)
        // A fresh backup before the upload: recorded, the stage doesn't go back.
        let second = try SyncTurnOn.backUp(manager: manager, now: day.addingTimeInterval(60))
        XCTAssertEqual(try progress(queue), SyncTurnOn.Progress(stage: .ownershipConfirmed, backupPath: second.path, total: 0, sent: 0))
        assertThrows(.wrongStage(.ownershipConfirmed)) { try self.write(queue) { db in try SyncTurnOn.markDone(db: db, now: self.day) } }

        // The keys come before the upload.
        assertThrows(.wrongStage(.ownershipConfirmed)) {
            _ = try self.write(queue) { db in try SyncTurnOn.beginUpload(admin: admin, cloudKitUserRecordName: "_user", db: db, now: self.day) }
        }
        let keys = InMemorySyncKeyStore()
        try prepareKeys(queue, keys)
        XCTAssertEqual(try progress(queue).stage, .keysReady)
        try prepareKeys(queue, keys)
        XCTAssertEqual(try progress(queue).stage, .keysReady, "making the keys again keeps the turn-on's own")
        XCTAssertEqual(try keys.allKeys(zone: SyncZones.household).count, 1)
        let total = try write(queue) { db in try SyncTurnOn.beginUpload(admin: admin, cloudKitUserRecordName: "_user", db: db, now: day) }
        XCTAssertGreaterThan(total, 0)
        XCTAssertEqual(try progress(queue), SyncTurnOn.Progress(stage: .uploading, backupPath: second.path, total: total, sent: 0))
        // Past the upload's start: no new backup, no second start, earlier steps change nothing.
        XCTAssertThrowsError(try SyncTurnOn.backUp(manager: manager, now: day)) { error in
            XCTAssertEqual(error as? SyncTurnOn.TurnOnError, .wrongStage(.uploading))
        }
        try write(queue) { db in try SyncTurnOn.markOwnershipConfirmed(db: db, now: day) }
        XCTAssertEqual(try progress(queue).stage, .uploading)
        assertThrows(.wrongStage(.uploading)) {
            _ = try self.write(queue) { db in try SyncTurnOn.beginUpload(admin: admin, cloudKitUserRecordName: "_user", db: db, now: self.day) }
        }
        assertThrows(.uploadNotFinished(remaining: total)) { try self.write(queue) { db in try SyncTurnOn.markDone(db: db, now: self.day) } }
        XCTAssertFalse(try read(queue) { db in try SyncTurnOn.isUploadFinished(db: db) })

        // The upload.
        let cloud = FakeCloud()
        let audit = ZoneAuditingTransport(wrapping: cloud, keyStore: keys)
        audit.judge(with: TwoPersonHousehold.router(queue))
        try await macEngine(queue, audit, keys: keys).pushPending()
        XCTAssertEqual(try progress(queue), SyncTurnOn.Progress(stage: .uploading, backupPath: second.path, total: total, sent: total))
        XCTAssertTrue(try read(queue) { db in try SyncTurnOn.isUploadFinished(db: db) })
        try write(queue) { db in try SyncTurnOn.markDone(db: db, now: day) }
        XCTAssertFalse(try read(queue) { db in try SyncTurnOn.isUploadFinished(db: db) }, "done: nothing more to mark")
        XCTAssertEqual(try progress(queue), SyncTurnOn.Progress(stage: .done, backupPath: second.path, total: total, sent: total))
        // Done stays done.
        try write(queue) { db in
            try SyncTurnOn.markDone(db: db, now: day)
            try SyncTurnOn.markOwnershipConfirmed(db: db, now: day)
        }
        XCTAssertEqual(try progress(queue).stage, .done)
        XCTAssertEqual(audit.householdViolations(router: TwoPersonHousehold.router(queue)), [])
    }

    func testBackupIsTimestampedBesideTheDatabase() throws {
        let (manager, path, _) = try household()
        let directory = URL(fileURLWithPath: path).deletingLastPathComponent()
        let backup = try SyncTurnOn.backUp(manager: manager, now: day)

        XCTAssertEqual(backup.deletingLastPathComponent().standardizedFileURL.path, directory.standardizedFileURL.path)
        let name = backup.lastPathComponent
        XCTAssertNotNil(name.range(of: #"^budget\.sqlite\.pre-sync-backup-\d{8}-\d{6}$"#, options: .regularExpression), name)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        XCTAssertEqual(name, SyncTurnOn.backupPrefix + formatter.string(from: day), "local time, as the pre-migration backup")
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path + ".partial"))

        // It opens, with the same rows in every table; it was taken before the stage was written, so restoring it
        // goes back to before the turn-on.
        let copy = try DatabaseQueue(path: backup.path)
        defer { try? copy.close() }
        let tables = try read(manager.dbQueue) { db in
            try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY name")
        }
        XCTAssertGreaterThan(tables.count, 40)
        for table in tables where table != "syncState" {
            let sql = "SELECT COUNT(*) FROM \"\(table)\""
            XCTAssertEqual(try read(copy) { db in try Int.fetchOne(db, sql: sql) }, try read(manager.dbQueue) { db in try Int.fetchOne(db, sql: sql) }, table)
        }
        XCTAssertEqual(try read(copy) { db in try SyncTurnOn.stage(db: db) }, .notStarted)
        XCTAssertEqual(try read(manager.dbQueue) { db in try SyncTurnOn.stage(db: db) }, .backedUp)

        // A second in the same second gets a suffix, never overwrites.
        let again = try SyncTurnOn.backUp(manager: manager, now: day)
        XCTAssertEqual(again.lastPathComponent, name + "-2")
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path))
    }

    func testAFailedBackupStopsTheFlowAndLeavesNothing() throws {
        let (manager, path, _) = try household()
        // The backup goes beside the database the manager opened; an in-memory database has no such place.
        XCTAssertThrowsError(try SyncTurnOn.backUp(manager: try TestDatabase.migratedManager(), now: day)) { error in
            XCTAssertEqual(error as? SyncTurnOn.TurnOnError, .notAFileDatabase)
        }
        let directory = URL(fileURLWithPath: path).deletingLastPathComponent()
        struct Refused: Error {}
        // The copy fails half-way.
        XCTAssertThrowsError(try SyncTurnOn.backUp(manager: manager, now: day, writeBackup: { _, partial in
            try Data("half a copy".utf8).write(to: partial)
            throw Refused()
        }))
        // The copy "succeeds" but isn't a database.
        XCTAssertThrowsError(try SyncTurnOn.backUp(manager: manager, now: day, writeBackup: { _, partial in
            try Data(repeating: 7, count: 8_192).write(to: partial)
        }))
        // The copy is a sound database but misses rows (review M-3): every table's rows are counted against the source.
        XCTAssertThrowsError(try SyncTurnOn.backUp(manager: manager, now: day, writeBackup: { manager, partial in
            try MigrationBackup.copyDatabase(manager, partial)
            let copy = try DatabaseQueue(path: partial.path)
            try copy.write { db in try db.execute(sql: "DELETE FROM documentLink") }
            try copy.close()
        })) { error in
            guard case .backupIncomplete(let tables)? = error as? SyncTurnOn.TurnOnError else { return XCTFail("\(error)") }
            XCTAssertGreaterThan(tables, 0)
        }
        let left = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasPrefix(SyncTurnOn.backupPrefix) }
        XCTAssertEqual(left, [])
        XCTAssertEqual(try progress(manager.dbQueue), SyncTurnOn.Progress(stage: .notStarted, backupPath: nil, total: 0, sent: 0))
    }

    func testBeginUploadSetsICloudUserAndQueuesEverything() throws {
        let (manager, _, fixture) = try household()
        let queue = manager.dbQueue
        try SyncTurnOn.backUp(manager: manager, now: day)
        try write(queue) { db in try SyncTurnOn.markOwnershipConfirmed(db: db, now: day) }
        try prepareKeys(queue, InMemorySyncKeyStore())
        let member = try read(queue) { db in
            try AccessActor.load(appUserId: try Int64.fetchOne(db, sql: "SELECT id FROM appUser WHERE isAdmin = 0")!, db: db)
        }
        func recordName(_ appUserId: Int64) throws -> String? {
            try read(queue) { db in try String.fetchOne(db, sql: "SELECT cloudKitUserRecordName FROM appUser WHERE id = ?", arguments: [appUserId]) }
        }

        // Only the admin; nothing written by a refusal.
        assertThrows(.notAdmin) {
            _ = try self.write(queue) { db in try SyncTurnOn.beginUpload(admin: member, cloudKitUserRecordName: "_member", db: db, now: self.day) }
        }
        // The admin's app user already belongs to another iCloud user.
        try write(queue) { db in try db.execute(sql: "UPDATE appUser SET cloudKitUserRecordName = '_other' WHERE id = ?", arguments: [fixture.admin.appUserId]) }
        assertThrows(.differentICloudUser) {
            _ = try self.write(queue) { db in try SyncTurnOn.beginUpload(admin: fixture.admin, cloudKitUserRecordName: "_admin", db: db, now: self.day) }
        }
        XCTAssertEqual(try progress(queue).stage, .keysReady)
        XCTAssertFalse(try read(queue) { db in try SyncImportGate.isSyncOn(db: db) })
        try write(queue) { db in try db.execute(sql: "UPDATE appUser SET cloudKitUserRecordName = NULL WHERE id = ?", arguments: [fixture.admin.appUserId]) }
        // Identities whose queue entries are gone (records never uploaded, not waiting): the first upload still sends them.
        try write(queue) { db in try db.execute(sql: "DELETE FROM syncPending") }

        let total = try write(queue) { db in
            try SyncTurnOn.beginUpload(admin: fixture.admin, cloudKitUserRecordName: "_admin", db: db, now: day)
        }

        XCTAssertEqual(try recordName(fixture.admin.appUserId), "_admin")
        XCTAssertNil(try recordName(member.appUserId))
        XCTAssertTrue(try read(queue) { db in try SyncImportGate.isSyncOn(db: db) })
        XCTAssertEqual(try progress(queue), SyncTurnOn.Progress(stage: .uploading, backupPath: try progress(queue).backupPath, total: total, sent: 0))
        // Every synced row has its identity and is queued.
        try read(queue) { db in
            XCTAssertEqual(total, try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM syncPending"))
            var rows = 0
            for table in SyncSchema.tables {
                let key = "\"\(table.localIdColumn)\""
                rows += try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \"\(table.name)\"") ?? 0
                let unqueued = try Int.fetchOne(db, sql: """
                    SELECT COUNT(*) FROM "\(table.name)" t WHERE NOT EXISTS (
                        SELECT 1 FROM syncRecord s JOIN syncPending p ON p.uuid = s.uuid WHERE s.tableName = ? AND s.localId = t.\(key))
                    """, arguments: [table.name])
                XCTAssertEqual(unqueued, 0, table.name)
            }
            XCTAssertEqual(total, rows)
            // The admin's summaries are built (the Balance only and Category totals accounts publish balances).
            XCTAssertGreaterThan(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM accountBalancePoint WHERE accountId IN (?, ?)",
                                                  arguments: [fixture.privateAccount, fixture.totals]) ?? 0, 0)
        }
    }

    /// The blockers for `zones` now, everything else fine.
    private func keyBlockers(stage: SyncTurnOn.Stage, zones: [String], keys: any SyncKeyStore, cloud: FakeCloud,
                             ours: [String: String] = [:]) async throws -> [SyncTurnOn.Blocker] {
        let facts = try await SyncTurnOn.keyFacts(zones: zones, keyStore: keys, transport: cloud)
        return SyncTurnOn.blockers(isAdmin: true, isAppDatabase: true, isProduction: true, hasEntitlement: true, isDemoDatabase: false,
                                   iCloudAvailable: true, iCloudUser: .notRecordedYet, stage: stage, turnOnKeyIds: ours, keys: facts)
    }

    private let privateZone = SyncZones.privateZone(personUuid: "6c1e0e0a-3f4b-4c2d-9a1b-2c3d4e5f6a7b")

    func testTurnOnRefusesWhenAStrayHouseholdKeyIsHeld() async throws {
        let cloud = FakeCloud()
        let keys = InMemorySyncKeyStore()
        let zones = [SyncZones.household, privateZone]
        // A fresh start: no key, no marker.
        let fresh = try await keyBlockers(stage: .notStarted, zones: zones, keys: keys, cloud: cloud)
        XCTAssertEqual(fresh, [])

        // A key left by a test, no marker on the server (no zone yet, then an empty zone): refused, with what to do.
        try keys.store(DocumentCrypto.newZoneKey(), zone: SyncZones.household)
        let noZone = try await keyBlockers(stage: .notStarted, zones: zones, keys: keys, cloud: cloud)
        XCTAssertEqual(noZone, [.strayHouseholdKey])
        try await cloud.createZone(SyncZones.household)
        let emptyZone = try await keyBlockers(stage: .ownershipConfirmed, zones: zones, keys: keys, cloud: cloud)
        XCTAssertEqual(emptyZone, [.strayHouseholdKey])
        XCTAssertEqual(SyncTurnOn.text(.strayHouseholdKey),
                       "iCloud Keychain already holds a household key from a test. Remove it before turning on sync.")
        // Making the turn-on's keys is refused too, and the key is left as it is.
        let (manager, _, _) = try household()
        try SyncTurnOn.backUp(manager: manager, now: day)
        try write(manager.dbQueue) { db in try SyncTurnOn.markOwnershipConfirmed(db: db, now: day) }
        XCTAssertThrowsError(try prepareKeys(manager.dbQueue, keys)) { error in
            XCTAssertEqual(error as? SyncTurnOn.TurnOnError, .blocked(.strayHouseholdKey))
        }
        XCTAssertEqual(try progress(manager.dbQueue).stage, .ownershipConfirmed)
        // The check never removes a key, nor creates a marker.
        XCTAssertEqual(try keys.allKeys(zone: SyncZones.household).count, 1)
        let stored = await cloud.storedRecords()
        XCTAssertEqual(stored, [])
    }

    func testTurnOnRefusesAStrayKeyForTheAdminsPrivateZone() async throws {
        let (manager, _, _) = try household()
        let queue = manager.dbQueue
        let zones = try read(queue) { db in try SyncTurnOn.turnOnZones(admin: try AccessActor.admin(db: db), db: db) }
        XCTAssertEqual(zones.count, 2)
        XCTAssertEqual(zones.first, SyncZones.household)
        let adminZone = zones[1]
        let cloud = FakeCloud()
        let keys = InMemorySyncKeyStore()
        // A key under the admin's private zone (a copy of this database tested with sync): refused, with what to do.
        try keys.store(DocumentCrypto.newZoneKey(), zone: adminZone)
        let found = try await keyBlockers(stage: .notStarted, zones: zones, keys: keys, cloud: cloud)
        XCTAssertEqual(found, [.strayPrivateKey])
        XCTAssertEqual(SyncTurnOn.text(.strayPrivateKey),
                       "iCloud Keychain already holds a key for your private data from a test. Remove it before turning on sync.")
        try SyncTurnOn.backUp(manager: manager, now: day)
        try write(queue) { db in try SyncTurnOn.markOwnershipConfirmed(db: db, now: day) }
        XCTAssertThrowsError(try prepareKeys(queue, keys)) { error in
            XCTAssertEqual(error as? SyncTurnOn.TurnOnError, .blocked(.strayPrivateKey))
        }
        XCTAssertEqual(try keys.allKeys(zone: adminZone).count, 1)
        XCTAssertEqual(try keys.allKeys(zone: SyncZones.household).count, 0, "nothing made while refused")
        XCTAssertEqual(try progress(queue).stage, .ownershipConfirmed)
    }

    func testAMarkerAlreadyOnTheServerBlocks() async throws {
        let cloud = FakeCloud()
        let keys = InMemorySyncKeyStore()
        let zones = [SyncZones.household, privateZone]
        let other = DocumentCrypto.newZoneKey()
        try await cloud.createZone(SyncZones.household)
        _ = try await cloud.save([SyncZoneKeys.wire(.init(keyId: DocumentCrypto.zoneKeyId(other), createdAt: day), zone: SyncZones.household)],
                                 ifUnchanged: [:], atomic: false)
        // Before this turn-on made its keys, any marker means sync was turned on before: never merged into silently.
        let before = try await keyBlockers(stage: .notStarted, zones: zones, keys: keys, cloud: cloud)
        XCTAssertEqual(before, [.syncedBefore])
        XCTAssertEqual(SyncTurnOn.text(.syncedBefore), "Sync was turned on before from another Mac or an earlier attempt.")
        // Even with that marker's key held here.
        try keys.store(other, zone: SyncZones.household)
        let held = try await keyBlockers(stage: .backedUp, zones: zones, keys: keys, cloud: cloud)
        XCTAssertEqual(held, [.strayHouseholdKey, .syncedBefore])
        // After this turn-on made its keys: a marker naming its own key is its own; any other is still refused.
        let ours = DocumentCrypto.newZoneKey()
        let mine = [SyncZones.household: DocumentCrypto.zoneKeyId(ours)]
        let foreign = try await keyBlockers(stage: .uploading, zones: [SyncZones.household], keys: InMemorySyncKeyStore(), cloud: cloud, ours: mine)
        XCTAssertEqual(foreign, [.syncedBefore])
        let record = await cloud.record(named: SyncZoneKeys.recordName(zone: SyncZones.household))
        _ = try await cloud.save([SyncZoneKeys.wire(.init(keyId: DocumentCrypto.zoneKeyId(ours), createdAt: day), zone: SyncZones.household)],
                                 ifUnchanged: [SyncZoneKeys.recordName(zone: SyncZones.household): try XCTUnwrap(record).stamp.systemFields], atomic: false)
        let ownKeys = InMemorySyncKeyStore()
        try ownKeys.store(ours, zone: SyncZones.household)
        let own = try await keyBlockers(stage: .uploading, zones: [SyncZones.household], keys: ownKeys, cloud: cloud, ours: mine)
        XCTAssertEqual(own, [])
    }

    /// Review M-1: the app quits while the first marker save fails. The keys are in the key store, no marker on the
    /// server: they are the turn-on's own, never a stray, and the upload resumes with them.
    func testTheTurnOnsOwnKeysAreNeverStrayWhenTheMarkerSaveFails() async throws {
        let (manager, _, _) = try household()
        let queue = manager.dbQueue
        let keys = InMemorySyncKeyStore()
        let total = try begin(manager, keys)
        let zones = try read(queue) { db in try SyncTurnOn.turnOnZones(admin: try AccessActor.admin(db: db), db: db) }
        let ours = try read(queue) { db in try SyncTurnOn.turnOnKeyIds(db: db) }
        XCTAssertEqual(Set(ours.keys), Set(zones))
        let cloud = FakeCloud()
        let audit = ZoneAuditingTransport(wrapping: cloud, keyStore: keys)
        audit.judge(with: TwoPersonHousehold.router(queue))
        await cloud.failSaveOperations(after: 0)
        // The marker can't be published: the push waits for it, sending nothing.
        let halted = try await macEngine(queue, audit, keys: keys).pushPending()
        XCTAssertEqual(halted.keyWait, .unavailable)
        XCTAssertEqual(halted.saved, 0)
        let markers = await cloud.storedRecords().filter { $0.recordType == SyncZoneKeys.recordType }
        XCTAssertEqual(markers, [], "the marker save was the operation that failed")
        // Read as the turn-on's own keys at its stage; the same keys before the turn-on made them would be strays.
        let after = try await keyBlockers(stage: try progress(queue).stage, zones: zones, keys: keys, cloud: cloud, ours: ours)
        XCTAssertEqual(after, [])
        let early = try await keyBlockers(stage: .ownershipConfirmed, zones: zones, keys: keys, cloud: cloud, ours: ours)
        XCTAssertEqual(early, [.strayHouseholdKey, .strayPrivateKey])

        await cloud.restoreConnection()
        try await macEngine(queue, audit, keys: keys).pushPending()
        XCTAssertEqual(try progress(queue).sent, total)
        for zone in zones {
            XCTAssertEqual(Array(try keys.allKeys(zone: zone).keys), [ours[zone]!], "one key per zone, the turn-on's")
            let marker = await cloud.record(named: SyncZoneKeys.recordName(zone: zone))
            XCTAssertEqual(try SyncZoneKeys.marker(from: try XCTUnwrap(marker).wire).keyId, ours[zone])
        }
        XCTAssertEqual(audit.householdViolations(router: TwoPersonHousehold.router(queue)), [])
    }

    func testEveryBlockerHasItsCopyInOrder() {
        let stray = SyncTurnOn.ZoneKeyFacts(zone: SyncZones.household, heldKeyIds: ["k"], serverHasMarker: false, serverMarkerKeyId: nil)
        let marked = SyncTurnOn.ZoneKeyFacts(zone: privateZone, heldKeyIds: ["p"], serverHasMarker: true, serverMarkerKeyId: nil)
        XCTAssertEqual(SyncTurnOn.blockers(isAdmin: false, isAppDatabase: false, isProduction: false, hasEntitlement: false, isDemoDatabase: true,
                                           iCloudAvailable: false, iCloudUser: .different, stage: .notStarted, turnOnKeyIds: [:], keys: [stray, marked]),
                       [.notAdmin, .notAppDatabase, .wrongEnvironment, .noEntitlement, .demoDatabase, .strayHouseholdKey, .strayPrivateKey,
                        .syncedBefore, .noICloudAccount, .differentICloudUser])
        for check in [SyncTurnOn.ICloudUserCheck.matches, .notRecordedYet, .unknown] {
            XCTAssertEqual(SyncTurnOn.blockers(isAdmin: true, isAppDatabase: true, isProduction: true, hasEntitlement: true, isDemoDatabase: false,
                                               iCloudAvailable: true, iCloudUser: check, stage: .notStarted, turnOnKeyIds: [:], keys: []), [])
        }
        XCTAssertEqual(SyncTurnOn.text(.notAppDatabase), "This window opened a copy of your data, not Mango's own database.")
        XCTAssertEqual(SyncTurnOn.text(.differentICloudUser),
                       "This household's admin is signed in to a different iCloud account. Sign in to that account first.")
        XCTAssertEqual(SyncTurnOn.text(.notAdmin), "Only the household's admin can turn on sync.")
        XCTAssertEqual(SyncTurnOn.text(.wrongEnvironment), "This build syncs with iCloud's development environment, not your data's.")
        XCTAssertEqual(SyncTurnOn.text(.noEntitlement), "This build isn't signed for iCloud.")
        XCTAssertEqual(SyncTurnOn.text(.demoDatabase), "This is the demo database.")
        XCTAssertEqual(SyncTurnOn.text(.noICloudAccount), "Sign in to iCloud in System Settings first.")
    }

    /// Review M-5: what the sheet shows never goes back, whatever is edited or added during the upload.
    func testProgressNeverGoesBack() async throws {
        let (manager, _, fixture) = try household()
        let queue = manager.dbQueue
        let keys = InMemorySyncKeyStore()
        let total = try begin(manager, keys)
        let cloud = FakeCloud()
        let audit = ZoneAuditingTransport(wrapping: cloud, keyStore: keys)
        audit.judge(with: TwoPersonHousehold.router(queue))
        await cloud.failSaveOperations(after: 4)
        _ = try? await macEngine(queue, audit, keys: keys, batchSize: 10).pushPending()
        let halfway = try progress(queue)
        XCTAssertGreaterThan(halfway.sent, 0)
        XCTAssertLessThan(halfway.sent, total)
        // Edits to what already went (queued again) and a new record (queued for the first time).
        let sentAccount = try read(queue) { db in
            try Int64.fetchOne(db, sql: """
                SELECT s.localId FROM syncRecord s WHERE s.tableName = 'account' AND s.systemFields IS NOT NULL ORDER BY s.localId LIMIT 1
                """)
        }
        try write(queue) { db in
            if let sentAccount { try db.execute(sql: "UPDATE account SET name = name || ' (edited)' WHERE id = ?", arguments: [sentAccount]) }
            try db.execute(sql: "UPDATE account SET name = name || ' (edited)' WHERE id = ?", arguments: [fixture.shared])
            try db.execute(sql: "INSERT INTO categoryGroup(name, type) VALUES ('Synthetic added', 'expense')")
        }
        XCTAssertNotNil(sentAccount, "an account went up before the halt")
        let edited = try progress(queue)
        XCTAssertEqual(edited.total, total)
        XCTAssertGreaterThanOrEqual(edited.sent, halfway.sent)
        await cloud.restoreConnection()
        try await macEngine(queue, audit, keys: keys, batchSize: 10).pushPending()
        XCTAssertEqual(try progress(queue).sent, total)
    }

    /// Review M-7: the server takes a private zone's save but the reply is lost; the next push finishes, with every
    /// record once in its zone and nothing private in the household.
    func testTurnOnResumesAfterALostReplyWithZones() async throws {
        let (manager, _, fixture) = try household()
        let queue = manager.dbQueue
        let keys = InMemorySyncKeyStore()
        let total = try begin(manager, keys)
        let cloud = FakeCloud()
        let audit = ZoneAuditingTransport(wrapping: cloud, keyStore: keys)
        audit.judge(with: TwoPersonHousehold.router(queue))
        let lossy = LossyTransport(audit)
        let privateName = try read(queue) { db in
            try XCTUnwrap(try SyncRecordStore.existingUUID(table: "transaction_", localId: fixture.privateTransaction, db: db))
        }
        lossy.loseReply(to: privateName, in: fixture.privateZone)
        do {
            try await macEngine(queue, lossy, keys: keys, batchSize: 5).pushPending()
            XCTFail("the lost reply should have stopped the push")
        } catch let error as SyncTransportError {
            XCTAssertEqual(error, .networkUnavailable)
        }
        let landed = await cloud.record(named: privateName)
        XCTAssertNotNil(landed, "the server took it")
        XCTAssertEqual(try progress(queue).stage, .uploading)

        try await macEngine(queue, lossy, keys: keys, batchSize: 5).pushPending()
        XCTAssertEqual(try progress(queue).sent, total)
        try write(queue) { db in try SyncTurnOn.markDone(db: db, now: day) }
        let stored = await cloud.storedRecords().filter {
            ![SyncZoneKeys.recordType, SyncDocumentFile.recordType, SyncZoneRouter.companionRecordType].contains($0.recordType)
        }
        XCTAssertEqual(stored.count, total, "every record once")
        XCTAssertEqual(Set(stored.map(\.recordName)).count, total)
        XCTAssertEqual(stored.first { $0.recordName == privateName }?.zone, fixture.privateZone)
        XCTAssertEqual(audit.householdViolations(router: TwoPersonHousehold.router(queue)), [])
    }

    func testTurnOnResumesAfterQuit() async throws {
        let (manager, path, _) = try household()
        let keys = InMemorySyncKeyStore()
        let total = try begin(manager, keys)
        let cloud = FakeCloud()
        let audit = ZoneAuditingTransport(wrapping: cloud, keyStore: keys)
        audit.judge(with: TwoPersonHousehold.router(manager.dbQueue))
        // The connection drops part-way through the upload; the app quits.
        await cloud.failSaveOperations(after: 4)
        do {
            try await macEngine(manager.dbQueue, audit, keys: keys, batchSize: 10).pushPending()
            XCTFail("the upload should have stopped")
        } catch let error as SyncTransportError {
            XCTAssertEqual(error, .networkUnavailable)
        }
        try manager.dbQueue.close()
        let householdKeyId = try XCTUnwrap(try keys.allKeys(zone: SyncZones.household).keys.first)

        // Relaunch: the same file, migrated as at every launch.
        let reopened = try DatabaseManager(path: path)
        try reopened.migrate()
        let queue = reopened.dbQueue
        defer { try? queue.close() }
        let landed = await cloud.storedRecords().filter {
            ![SyncZoneKeys.recordType, SyncDocumentFile.recordType, SyncZoneRouter.companionRecordType].contains($0.recordType)
        }.count
        let halted = try progress(queue)
        XCTAssertEqual(halted.stage, .uploading)
        XCTAssertEqual(halted.total, total)
        XCTAssertGreaterThan(halted.sent, 0)
        XCTAssertLessThan(halted.sent, total)
        XCTAssertEqual(halted.sent, landed, "sent counts what the server took")
        XCTAssertEqual(try read(queue) { db in
            SyncActivation.realDecision(isAppDatabase: true, isDemoDatabase: false, stage: try SyncTurnOn.stage(db: db), hasCloudKitEntitlement: true,
                                        isProduction: true, isDebug: false, arguments: ["Mango"]).allowed
        }, true, "a relaunch in uploading syncs again")

        // The rest goes, with the same household key.
        await cloud.restoreConnection()
        audit.judge(with: TwoPersonHousehold.router(queue))
        try await macEngine(queue, audit, keys: keys, batchSize: 10).pushPending()
        let finished = try progress(queue)
        XCTAssertEqual(finished.sent, total)
        try write(queue) { db in try SyncTurnOn.markDone(db: db, now: day) }
        XCTAssertEqual(try progress(queue).stage, .done)
        XCTAssertEqual(Array(try keys.allKeys(zone: SyncZones.household).keys), [householdKeyId], "no second household key")
        let markerRecord = await cloud.record(named: SyncZoneKeys.recordName(zone: SyncZones.household))
        let marker = try XCTUnwrap(markerRecord)
        XCTAssertEqual(try SyncZoneKeys.marker(from: marker.wire).keyId, householdKeyId)
        let everything = await cloud.storedRecords()
        XCTAssertEqual(everything.filter { $0.recordType == SyncZoneKeys.recordType && $0.zone == SyncZones.household }.count, 1)
        let all = everything.filter {
            ![SyncZoneKeys.recordType, SyncDocumentFile.recordType, SyncZoneRouter.companionRecordType].contains($0.recordType)
        }
        XCTAssertEqual(all.count, total, "every record once")
        XCTAssertEqual(audit.householdViolations(router: TwoPersonHousehold.router(queue)), [])
    }

    func testOnlyTheAdminsMacRevalidates() throws {
        let queue = try TestDatabase.migrated()
        let fixture = try write(queue) { db in try SharingFixture.build(db) }
        try read(queue) { db in
            let adminRole = try SyncTurnOn.macEngineRole(signedIn: fixture.admin, db: db)
            XCTAssertEqual(adminRole, SyncTurnOn.MacEngineRole(viewer: SyncViewer(personUuid: fixture.personAUuid), revalidatesAccess: true))
            let member = try AccessActor.load(appUserId: try Int64.fetchOne(db, sql: "SELECT id FROM appUser WHERE isAdmin = 0")!, db: db)
            let memberRole = try SyncTurnOn.macEngineRole(signedIn: member, db: db)
            XCTAssertEqual(memberRole.viewer.personUuid, try SyncRecordStore.existingUUID(table: "person", localId: fixture.personB, db: db))
            XCTAssertFalse(memberRole.revalidatesAccess)
        }
    }
}
