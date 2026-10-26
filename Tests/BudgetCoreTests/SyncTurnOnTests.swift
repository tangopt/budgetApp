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

    /// An engine of the admin's Mac (its viewer, re-validating) over `transport`.
    private func macEngine(_ queue: DatabaseQueue, _ transport: any SyncTransport, keys: any SyncKeyStore, batchSize: Int = 200) throws -> SyncEngineCore {
        let role = try read(queue) { db in try SyncTurnOn.macEngineRole(signedIn: try AccessActor.admin(db: db), db: db) }
        return SyncEngineCore(db: queue, transport: transport, device: SyncDevice(id: "admin-mac", name: "Mac"), keyStore: keys, batchSize: batchSize,
                              viewer: role.viewer, revalidatesAccess: role.revalidatesAccess)
    }

    func testStagesAdvanceInOrderAndNeverBack() async throws {
        let (manager, path, admin) = try unconfirmed()
        let queue = manager.dbQueue
        XCTAssertEqual(try progress(queue), SyncTurnOn.Progress(stage: .notStarted, backupPath: nil, total: 0, sent: 0))

        // Nothing before the backup.
        assertThrows(.wrongStage(.notStarted)) { try self.write(queue) { db in try SyncTurnOn.markOwnershipConfirmed(db: db, now: self.day) } }
        assertThrows(.wrongStage(.notStarted)) {
            _ = try self.write(queue) { db in try SyncTurnOn.beginUpload(admin: admin, cloudKitUserRecordName: "_user", db: db, now: self.day) }
        }
        assertThrows(.wrongStage(.notStarted)) { try self.write(queue) { db in try SyncTurnOn.markDone(db: db, now: self.day) } }

        let first = try SyncTurnOn.backUp(manager: manager, databasePath: path, now: day)
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
        let second = try SyncTurnOn.backUp(manager: manager, databasePath: path, now: day.addingTimeInterval(60))
        XCTAssertEqual(try progress(queue), SyncTurnOn.Progress(stage: .ownershipConfirmed, backupPath: second.path, total: 0, sent: 0))
        assertThrows(.wrongStage(.ownershipConfirmed)) { try self.write(queue) { db in try SyncTurnOn.markDone(db: db, now: self.day) } }

        let total = try write(queue) { db in try SyncTurnOn.beginUpload(admin: admin, cloudKitUserRecordName: "_user", db: db, now: day) }
        XCTAssertGreaterThan(total, 0)
        XCTAssertEqual(try progress(queue), SyncTurnOn.Progress(stage: .uploading, backupPath: second.path, total: total, sent: 0))
        // Past the upload's start: no new backup, no second start, earlier steps change nothing.
        XCTAssertThrowsError(try SyncTurnOn.backUp(manager: manager, databasePath: path, now: day)) { error in
            XCTAssertEqual(error as? SyncTurnOn.TurnOnError, .wrongStage(.uploading))
        }
        try write(queue) { db in try SyncTurnOn.markOwnershipConfirmed(db: db, now: day) }
        XCTAssertEqual(try progress(queue).stage, .uploading)
        assertThrows(.wrongStage(.uploading)) {
            _ = try self.write(queue) { db in try SyncTurnOn.beginUpload(admin: admin, cloudKitUserRecordName: "_user", db: db, now: self.day) }
        }
        assertThrows(.uploadNotFinished(remaining: total)) { try self.write(queue) { db in try SyncTurnOn.markDone(db: db, now: self.day) } }

        // The upload.
        let cloud = FakeCloud()
        let keys = InMemorySyncKeyStore()
        let audit = ZoneAuditingTransport(wrapping: cloud, keyStore: keys)
        audit.judge(with: TwoPersonHousehold.router(queue))
        try await macEngine(queue, audit, keys: keys).pushPending()
        XCTAssertEqual(try progress(queue), SyncTurnOn.Progress(stage: .uploading, backupPath: second.path, total: total, sent: total))
        try write(queue) { db in try SyncTurnOn.markDone(db: db, now: day) }
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
        let backup = try SyncTurnOn.backUp(manager: manager, databasePath: path, now: day)

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
        let again = try SyncTurnOn.backUp(manager: manager, databasePath: path, now: day)
        XCTAssertEqual(again.lastPathComponent, name + "-2")
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path))
    }

    func testAFailedBackupStopsTheFlowAndLeavesNothing() throws {
        let (manager, path, _) = try household()
        let directory = URL(fileURLWithPath: path).deletingLastPathComponent()
        struct Refused: Error {}
        // The copy fails half-way.
        XCTAssertThrowsError(try SyncTurnOn.backUp(manager: manager, databasePath: path, now: day, writeBackup: { _, partial in
            try Data("half a copy".utf8).write(to: partial)
            throw Refused()
        }))
        // The copy "succeeds" but isn't a database.
        XCTAssertThrowsError(try SyncTurnOn.backUp(manager: manager, databasePath: path, now: day, writeBackup: { _, partial in
            try Data(repeating: 7, count: 8_192).write(to: partial)
        }))
        let left = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasPrefix(SyncTurnOn.backupPrefix) }
        XCTAssertEqual(left, [])
        XCTAssertEqual(try progress(manager.dbQueue), SyncTurnOn.Progress(stage: .notStarted, backupPath: nil, total: 0, sent: 0))
    }

    func testBeginUploadSetsICloudUserAndQueuesEverything() throws {
        let (manager, path, fixture) = try household()
        let queue = manager.dbQueue
        try SyncTurnOn.backUp(manager: manager, databasePath: path, now: day)
        try write(queue) { db in try SyncTurnOn.markOwnershipConfirmed(db: db, now: day) }
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
        XCTAssertEqual(try progress(queue).stage, .ownershipConfirmed)
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

    func testTurnOnRefusesWhenAStrayHouseholdKeyIsHeld() async throws {
        let cloud = FakeCloud()
        let keys = InMemorySyncKeyStore()
        func blockers() async throws -> [SyncTurnOn.Blocker] {
            let facts = try await SyncTurnOn.keyFacts(keyStore: keys, transport: cloud)
            return SyncTurnOn.blockers(isAdmin: true, isProduction: true, hasEntitlement: true, isDemoDatabase: false,
                                       keyStoreHoldsHouseholdKey: facts.keyStoreHoldsHouseholdKey,
                                       serverHasHouseholdMarker: facts.serverHasHouseholdMarker, iCloudAvailable: true)
        }
        // A fresh start: no key, no marker.
        let fresh = try await blockers()
        XCTAssertEqual(fresh, [])

        // A key left by a test, no marker on the server (no zone yet, then an empty zone): refused, with what to do.
        let stray = DocumentCrypto.newZoneKey()
        try keys.store(stray, zone: SyncZones.household)
        let noZone = try await blockers()
        XCTAssertEqual(noZone, [.strayHouseholdKey])
        try await cloud.createZone(SyncZones.household)
        let emptyZone = try await blockers()
        XCTAssertEqual(emptyZone, [.strayHouseholdKey])
        XCTAssertEqual(SyncTurnOn.text(.strayHouseholdKey),
                       "iCloud Keychain already holds a household key from a test. Remove it before turning on sync.")
        // The check never removes a key, nor creates a marker.
        XCTAssertEqual(try keys.allKeys(zone: SyncZones.household).count, 1)
        let stored = await cloud.storedRecords()
        XCTAssertEqual(stored, [])

        // The household's marker on the server: the key held is the household's, not a stray.
        _ = try await cloud.save([SyncZoneKeys.wire(.init(keyId: DocumentCrypto.zoneKeyId(stray), createdAt: day), zone: SyncZones.household)],
                                 ifUnchanged: [:], atomic: false)
        let marked = try await blockers()
        XCTAssertEqual(marked, [])
    }

    func testEveryBlockerHasItsCopyInOrder() {
        XCTAssertEqual(SyncTurnOn.blockers(isAdmin: false, isProduction: false, hasEntitlement: false, isDemoDatabase: true,
                                           keyStoreHoldsHouseholdKey: true, serverHasHouseholdMarker: false, iCloudAvailable: false),
                       [.notAdmin, .wrongEnvironment, .noEntitlement, .demoDatabase, .strayHouseholdKey, .noICloudAccount])
        XCTAssertEqual(SyncTurnOn.blockers(isAdmin: true, isProduction: true, hasEntitlement: true, isDemoDatabase: false,
                                           keyStoreHoldsHouseholdKey: false, serverHasHouseholdMarker: true, iCloudAvailable: true), [])
        XCTAssertEqual(SyncTurnOn.text(.notAdmin), "Only the household's admin can turn on sync.")
        XCTAssertEqual(SyncTurnOn.text(.wrongEnvironment), "This build syncs with iCloud's development environment, not your data's.")
        XCTAssertEqual(SyncTurnOn.text(.noEntitlement), "This build isn't signed for iCloud.")
        XCTAssertEqual(SyncTurnOn.text(.demoDatabase), "This is the demo database.")
        XCTAssertEqual(SyncTurnOn.text(.noICloudAccount), "Sign in to iCloud in System Settings first.")
    }

    func testTurnOnResumesAfterQuit() async throws {
        let (manager, path, _) = try household()
        try SyncTurnOn.backUp(manager: manager, databasePath: path, now: day)
        let total = try write(manager.dbQueue) { db -> Int in
            try SyncTurnOn.markOwnershipConfirmed(db: db, now: day)
            return try SyncTurnOn.beginUpload(admin: try AccessActor.admin(db: db), cloudKitUserRecordName: "_admin", db: db, now: day)
        }
        let cloud = FakeCloud()
        let keys = InMemorySyncKeyStore()
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
