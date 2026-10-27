import XCTest
import GRDB
@testable import BudgetCore
import TestSupport

/// Step 10 Task 6: the iPad browser's saved sites are household data, the synced `savedSite` table (schema 9). Two
/// people over one `FakeCloud` (`TwoPersonHousehold`, the Mac re-validating), her device as her iPad writing through
/// `DeviceWriter`. Synthetic hosts only (`*.example.test`).
final class SavedSiteSyncTests: XCTestCase {
    private typealias Device = TwoPersonHousehold.Device

    private var memberViewer: PhoneViewer { .iCloudUser(recordName: TwoPersonHousehold.memberICloudUser) }

    /// The household with the member as her iPad, the share read-write, everything synced.
    private func household() async throws -> TwoPersonHousehold {
        let h = try TwoPersonHousehold.make(revalidatesAccess: true, memberMode: TwoPersonHousehold.memberTabletMode)
        _ = try await h.cloud.makeZoneShare(SyncZones.household, title: "Synthetic household")
        try await h.syncAll()
        return h
    }

    /// Her iPad's saved sites.
    private func memberStore(_ h: TwoPersonHousehold) -> GRDBSavedSiteStore {
        let viewer = memberViewer
        return GRDBSavedSiteStore(writer: DeviceWriter(db: h.memberDevice.db, viewer: { viewer }, afterWrite: {}), reader: h.memberDevice.db)
    }

    /// The admin's Mac's sites, read as an iPad would (the Mac shows none, but holds the table).
    private func sites(on device: Device) throws -> [SavedSite] {
        try device.db.read { db in try GRDBSavedSiteStore.read(db: db) }
    }

    /// Synchronous access (async tests would otherwise pick GRDB's async overloads).
    private func read<T>(_ device: Device, _ body: (Database) throws -> T) throws -> T { try device.db.read(body) }
    private func write<T>(_ device: Device, _ body: (Database) throws -> T) throws -> T { try device.db.write(body) }

    private func pendingCount(_ device: Device) throws -> Int {
        try device.db.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM syncPending")! }
    }

    private func thrown(_ body: () async throws -> Void) async -> Error? {
        do {
            try await body()
            return nil
        } catch {
            return error
        }
    }

    private func site(_ name: String, _ host: String, _ kind: SavedSiteKind, order: Int) throws -> SavedSite {
        SavedSite(name: name, url: try SavedSite.validate(host), kind: kind, sortOrder: order)
    }

    /// Her iPad pushes; the Mac pulls (re-validating) and pushes; she pulls. Nothing of hers held back.
    private func round(_ h: TwoPersonHousehold, file: StaticString = #filePath, line: UInt = #line) async throws {
        let pushed = try await h.memberDevice.engine.pushPending()
        XCTAssertEqual(pushed.heldBack, 0, file: file, line: line)
        try await h.adminMac.engine.syncNow()
        try await h.memberDevice.engine.pull()
        try await h.adminPhone.engine.pull()
        XCTAssertEqual(h.audit.householdViolations(router: h.adminRouter()), [], "admin", file: file, line: line)
        XCTAssertEqual(h.memberAudit.householdViolations(router: TwoPersonHousehold.router(h.memberDevice.db)), [], "member",
                       file: file, line: line)
    }

    // MARK: Tests

    func testSavedSiteSyncsBetweenAdminAndMember() async throws {
        let h = try await household()
        let store = memberStore(h)
        let canEdit = await store.canEdit()
        XCTAssertTrue(canEdit, "a member edits Property by default")

        let bank = try site("Synthetic bank", "bank.example.test/login", .bank, order: 0)
        let water = try site("Synthetic water", "water.example.test", .utility, order: 1)
        try await store.save(water)
        try await store.save(bank)
        let saved = try await store.all()
        XCTAssertEqual(saved, [bank, water], "kept under the ids she gave, in strip order")
        try await round(h)

        for device in [h.adminMac, h.adminPhone] {
            XCTAssertEqual(try sites(on: device).map(\.id), [bank.id, water.id])
            XCTAssertEqual(try sites(on: device).map(\.url.absoluteString), ["https://bank.example.test/login", "https://water.example.test"])
        }
        XCTAssertEqual(try read(h.adminMac) { db in try AccessRevalidation.recentReverts(limit: 10, db: db) }, [], "nothing reverted")

        // The admin renames one on his Mac and removes the other; her iPad follows.
        try write(h.adminMac) { db in
            let renamed = try XCTUnwrap(SyncRecordStore.localId(table: "savedSite", uuid: GRDBSavedSiteStore.recordName(water.id), db: db))
            try db.execute(sql: "UPDATE savedSite SET name = 'Synthetic water company' WHERE id = ?", arguments: [renamed])
            let removed = try XCTUnwrap(SyncRecordStore.localId(table: "savedSite", uuid: GRDBSavedSiteStore.recordName(bank.id), db: db))
            try db.execute(sql: "DELETE FROM savedSite WHERE id = ?", arguments: [removed])
        }
        try await h.syncAll()
        let after = try await store.all()
        XCTAssertEqual(after.map(\.name), ["Synthetic water company"])
        XCTAssertEqual(after.map(\.id), [water.id])

        // She removes the last one.
        try await store.remove(id: water.id)
        try await round(h)
        XCTAssertEqual(try sites(on: h.adminMac), [])

        // The same address saved twice on her iPad is refused.
        try await store.save(bank)
        let again = try site("Bank again", "bank.example.test/login", .other, order: 5)
        let error = await thrown { try await store.save(again) }
        XCTAssertEqual(error as? SavedSiteError, .alreadySaved)
    }

    func testViewOnlyMemberCannotAddOrRemove() async throws {
        let h = try await household()
        let store = memberStore(h)
        let kept = try site("Synthetic tax portal", "tax.example.test", .tax, order: 0)
        try await store.save(kept)
        try await round(h)

        let memberUser = try read(h.adminMac) { db in
            try Int64.fetchOne(db, sql: "SELECT id FROM appUser WHERE personId = ?", arguments: [h.fixture.personB])!
        }
        try write(h.adminMac) { db in
            try db.execute(sql: """
                INSERT INTO memberPermission(appUserId, area, level) VALUES (?, 'property', 'view')
                ON CONFLICT(appUserId, area) DO UPDATE SET level = 'view'
                """, arguments: [memberUser])
        }
        try await h.syncAll()
        XCTAssertEqual(try pendingCount(h.memberDevice), 0)

        let canEdit = await store.canEdit()
        XCTAssertFalse(canEdit, "the strip hides Add and Remove")
        let added = await thrown { try await store.save(try self.site("Synthetic gas", "gas.example.test", .utility, order: 1)) }
        XCTAssertEqual(added as? AccessDenied, AccessDenied(area: .property))
        let removed = await thrown { try await store.remove(id: kept.id) }
        XCTAssertEqual(removed as? AccessDenied, AccessDenied(area: .property))
        XCTAssertEqual(try pendingCount(h.memberDevice), 0, "nothing queued")
        let still = try await store.all()
        XCTAssertEqual(still, [kept])
    }

    func testBadURLFromSyncIsSkipped() async throws {
        let h = try await household()
        // Another device (here the Mac, writing the table directly) sends addresses no iPad may open.
        try write(h.adminMac) { db in
            for (index, url) in ["http://plain.example.test", "javascript:alert(1)", "https://user:pass@sneaky.example.test",
                                 "https://good.example.test/start"].enumerated() {
                try db.execute(sql: "INSERT INTO savedSite(name, url, kind, sortOrder) VALUES (?, ?, 'other', ?)",
                               arguments: ["Synthetic \(index)", url, index])
            }
            // A kind a newer build added.
            try db.execute(sql: "UPDATE savedSite SET kind = 'pension' WHERE url = 'https://good.example.test/start'")
        }
        try await h.syncAll()
        XCTAssertEqual(try read(h.memberDevice) { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM savedSite")! }, 4,
                       "the rows arrive as data")
        let shown = try await memberStore(h).all()
        XCTAssertEqual(shown.map(\.url.absoluteString), ["https://good.example.test/start"], "only the https one is offered")
        XCTAssertEqual(shown.map(\.kind), [.other], "an unknown kind reads as Other")
    }

    func testSavedSiteIsHouseholdNotPrivate() async throws {
        let h = try await household()
        let store = memberStore(h)
        let bank = try site("Synthetic bank", "bank.example.test", .bank, order: 0)
        try await store.save(bank)
        try await round(h)

        let uuid = GRDBSavedSiteStore.recordName(bank.id)
        let assignment = try read(h.adminMac) { db -> ZoneAssignment in
            let localId = try XCTUnwrap(SyncRecordStore.localId(table: "savedSite", uuid: uuid, db: db))
            return try SyncZoneRouter(db: db).assignment(table: "savedSite", localId: localId)
        }
        XCTAssertEqual(assignment, ZoneAssignment(zone: SyncZones.household))
        let stored = await h.cloud.storedRecords().filter { $0.recordName == uuid }
        XCTAssertEqual(stored.map(\.zone), [SyncZones.household])
        XCTAssertEqual(stored.map(\.recordType), ["savedSite"])
        // No account, person or user linkage: nothing for the router to make private.
        let schema = try XCTUnwrap(SyncSchema.table("savedSite"))
        XCTAssertEqual(schema.foreignKeys, [:])
        XCTAssertTrue(SyncSchema.logicalReferences(of: "savedSite").isEmpty)
        // The admin's phone (household and his private zone) and her iPad (household only) both have it.
        XCTAssertNotNil(try h.localId("savedSite", uuid: uuid, on: h.adminPhone))
        XCTAssertNotNil(try h.localId("savedSite", uuid: uuid, on: h.memberDevice))
    }

    func testSchemaVersionIs9AndEveryColumnClassified() throws {
        XCTAssertEqual(SyncSchema.version, 9)
        let schema = try XCTUnwrap(SyncSchema.table("savedSite"))
        XCTAssertEqual(schema.syncedColumns, ["name", "url", "kind", "sortOrder"])
        XCTAssertEqual(schema.localOnlyColumns, [])
        XCTAssertEqual(SyncSchema.uniqueKey(table: "savedSite", columns: ["url"])?.resolution, .identity)
        XCTAssertTrue(SyncSchemaSeed.recordTypes.contains("savedSite"), "the Development schema seed saves one")
        XCTAssertEqual(AccessAreaMap.tableArea("savedSite"), .property)
    }

    func testMigrationAddsTableToExistingDatabase() throws {
        let manager = try DatabaseManager(path: nil)
        try manager.migrate(upTo: SharingMigration.summaryDirtyIdentifier)
        try manager.dbQueue.read { db in
            XCTAssertFalse(try db.tableExists("savedSite"))
            XCTAssertEqual(try SyncChangeTracker.installedSchema(db: db)?.version, 9, "this build stamps its version")
        }
        try manager.dbQueue.write { db in try db.execute(sql: "INSERT INTO person(name) VALUES ('Synthetic person')") }
        try manager.migrate()
        try manager.dbQueue.write { db in
            XCTAssertTrue(try db.tableExists("savedSite"))
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM person"), 1, "nothing else changed")
            try db.execute(sql: "INSERT INTO savedSite(name, url, kind, sortOrder) VALUES ('Synthetic', 'https://a.example.test', 'bank', 0)")
            let id = db.lastInsertedRowID
            XCTAssertNotNil(try SyncRecordStore.existingUUID(table: "savedSite", localId: id, db: db), "tracked from the first write")
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM syncPending WHERE tableName = 'savedSite'"), 1)
        }
    }

    /// A database that hasn't migrated to the table yet (an older build) stages an arriving site as an unknown record
    /// type, and applies it once it has migrated.
    func testOlderDatabaseStagesASiteUntilItMigrates() async throws {
        let cloud = FakeCloud()
        let keys = InMemorySyncKeyStore()
        try keys.store(DocumentCrypto.newZoneKey(), zone: SyncZones.household)
        let mac = try TestDatabase.migrated()
        try await mac.write { db in
            try db.execute(sql: "INSERT INTO savedSite(name, url, kind, sortOrder) VALUES ('Synthetic', 'https://a.example.test', 'bank', 0)")
        }
        let macEngine = SyncEngineCore(db: mac, transport: cloud, device: SyncDevice(id: "mac", name: "Mac"), keyStore: keys)
        try await macEngine.pushPending()

        let older = try DatabaseManager(path: nil)
        try older.migrate(upTo: SharingMigration.summaryDirtyIdentifier)
        let olderEngine = SyncEngineCore(db: older.dbQueue, transport: cloud, device: SyncDevice(id: "old", name: "iPad"), keyStore: keys,
                                         readOnly: true)
        try await olderEngine.pull()
        let staged = try await older.dbQueue.read { db in
            try String.fetchAll(db, sql: "SELECT reason FROM syncStaging WHERE tableName = 'savedSite'")
        }
        XCTAssertEqual(staged, ["unknown record type"])

        try older.migrate()
        try await olderEngine.pull()
        let sites = try await older.dbQueue.read { db in try GRDBSavedSiteStore.read(db: db) }
        XCTAssertEqual(sites.map(\.url.absoluteString), ["https://a.example.test"])
    }

    func testNoCredentialFieldExists() throws {
        let manager = try TestDatabase.migratedManager()
        let columns = try manager.dbQueue.read { db in try db.columns(in: "savedSite").map(\.name) }
        XCTAssertEqual(columns, ["id", "name", "url", "kind", "sortOrder"])
        XCTAssertEqual(Set(Mirror(reflecting: try site("A", "a.example.test", .bank, order: 0)).children.compactMap(\.label)),
                       ["id", "name", "url", "kind", "sortOrder"])
    }

    // MARK: Moving the device's own sites in

    func testLocalSitesAreAdoptedOnce() async throws {
        let h = try await household()
        let store = memberStore(h)
        try await store.save(try site("Synthetic bank", "bank.example.test", .bank, order: 0))
        let suite = "mango.tests.savedSites." + UUID().uuidString
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let local = LocalSavedSiteStore(suiteName: suite)
        try await local.save(try site("Bank (this iPad)", "bank.example.test", .bank, order: 0))
        try await local.save(try site("Synthetic condominium", "condo.example.test", .condominium, order: 1))

        let adopted = await SavedSiteAdoption.adopt(from: local, into: store)
        XCTAssertTrue(adopted)
        let all = try await store.all()
        XCTAssertEqual(all.map(\.name), ["Synthetic bank", "Synthetic condominium"], "a known address is skipped; the rest go after")
        let left = try await local.all()
        XCTAssertEqual(left, [], "forgotten here")
        let again = await SavedSiteAdoption.adopt(from: local, into: store)
        XCTAssertTrue(again)
        let unchanged = try await store.all()
        XCTAssertEqual(unchanged.count, 2)
    }

    func testRefusedAdoptionKeepsLocalSites() async throws {
        let h = try await household()
        // Not linked yet: no app user bound to this iCloud user.
        let store = GRDBSavedSiteStore(writer: DeviceWriter(db: h.memberDevice.db, viewer: { .iCloudUser(recordName: "fake-unknown") },
                                                            afterWrite: {}), reader: h.memberDevice.db)
        let suite = "mango.tests.savedSites." + UUID().uuidString
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let local = LocalSavedSiteStore(suiteName: suite)
        try await local.save(try site("Synthetic bank", "bank.example.test", .bank, order: 0))
        let adopted = await SavedSiteAdoption.adopt(from: local, into: store)
        XCTAssertFalse(adopted)
        let kept = try await local.all()
        XCTAssertEqual(kept.count, 1, "kept for the next try")
        XCTAssertEqual(try pendingCount(h.memberDevice), 0)
    }
}
