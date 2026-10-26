import XCTest
import GRDB
@testable import BudgetCore
import TestSupport

/// Step 7a Task 5: a device drops a zone's data, locally only, when its iCloud user changes (the private zones) or when
/// the member is removed from the household (the household). Never on an undetermined account, never on the server.
/// Runs over `TwoPersonHousehold` (the FakeCloud share). Synthetic data only.
final class SyncLocalDataTests: XCTestCase {
    private typealias Device = TwoPersonHousehold.Device

    private func read<T>(_ queue: DatabaseQueue, _ body: (Database) throws -> T) throws -> T { try queue.read(body) }
    private func write<T>(_ queue: DatabaseQueue, _ body: (Database) throws -> T) throws -> T { try queue.write(body) }

    private func count(_ device: Device, _ sql: String, _ arguments: StatementArguments = []) throws -> Int {
        try read(device.db) { db in try Int.fetchOne(db, sql: sql, arguments: arguments) ?? 0 }
    }

    private func uuids(_ device: Device, zone: String) throws -> Set<String> {
        Set(try read(device.db) { db in try String.fetchAll(db, sql: "SELECT uuid FROM syncRecord WHERE zone = ?", arguments: [zone]) })
    }

    /// Every record (and marker) the server holds in `zone`, by name, with its change tag.
    private func server(_ h: TwoPersonHousehold, zone: String) async throws -> [String: String] {
        var token: Data?
        var held: [String: String] = [:]
        while true {
            let page = try await h.cloud.changes(since: token, zone: zone)
            for record in page.records { held[record.wire.recordName] = record.stamp.changeTag }
            for deletion in page.deletions { held[deletion.recordName] = nil }
            token = page.token
            if !page.moreComing { return held }
        }
    }

    /// The household synced: the Mac pushes, the admin's phone pulls both zones it follows, the member pulls hers.
    private func synced() async throws -> TwoPersonHousehold {
        let h = try TwoPersonHousehold.make()
        _ = try await h.adminMac.engine.syncNow()
        try await h.syncAll()
        return h
    }

    /// The member's device as 7a runs it: read-only, the household through her shared database.
    private func memberEngine(_ h: TwoPersonHousehold) -> SyncEngineCore {
        SyncEngineCore(db: h.memberDevice.db, transport: h.memberAudit, device: SyncDevice(id: "member-device", name: "iPad"),
                       keyStore: h.memberKeys, readOnly: true, viewer: SyncViewer(personUuid: h.personBUuid), householdIsShared: true)
    }

    // MARK: Dropping

    func testDropZoneRemovesRowsAndQueuesNothing() async throws {
        let h = try await synced()
        let phone = h.adminPhone
        let zone = h.fixture.privateZone
        let dropped = try uuids(phone, zone: zone)
        XCTAssertFalse(dropped.isEmpty, "precondition: the phone holds A's zone")
        let onServer = try await server(h, zone: zone)
        // Something staged from the zone, and one from the household.
        try write(phone.db) { db in
            for (uuid, stagedZone) in [("staged-private", zone), ("staged-household", SyncZones.household)] {
                try db.execute(sql: """
                    INSERT INTO syncStaging(tableName, uuid, payloadJSON, reason, receivedAt) VALUES ('transaction_', ?, ?, 'test', ?)
                    """, arguments: [uuid, "{\"zone\":\"\(stagedZone)\"}", Date()])
            }
        }
        XCTAssertNotNil(try read(phone.db) { db in try SyncEngineCore.token(zone: zone, db: db) }, "precondition: a token")

        let count = try write(phone.db) { db in try SyncLocalData.dropZone(zone, db: db) }

        XCTAssertEqual(count, dropped.count)
        XCTAssertEqual(try uuids(phone, zone: zone), [], "no identity left in the zone")
        for uuid in dropped {
            XCTAssertEqual(try self.count(phone, "SELECT COUNT(*) FROM syncFieldClock c JOIN syncRecord s ON s.localId = c.localId AND s.tableName = c.tableName WHERE s.uuid = ?", [uuid]), 0)
            XCTAssertEqual(try self.count(phone, "SELECT COUNT(*) FROM syncPresence WHERE uuid = ?", [uuid]), 0)
        }
        XCTAssertNil(try h.localId("transaction_", uuid: try h.uuid("transaction_", h.fixture.privateTransaction), on: phone))
        XCTAssertEqual(try self.count(phone, "SELECT COUNT(*) FROM syncPending"), 0, "nothing queued")
        XCTAssertEqual(try self.count(phone, "SELECT COUNT(*) FROM syncTombstone"), 0, "no tombstones")
        XCTAssertEqual(try self.count(phone, "SELECT COUNT(*) FROM syncStaging WHERE uuid = 'staged-private'"), 0)
        XCTAssertEqual(try self.count(phone, "SELECT COUNT(*) FROM syncStaging WHERE uuid = 'staged-household'"), 1, "another zone's stays")
        XCTAssertEqual(try self.count(phone, "SELECT COUNT(*) FROM syncPresence WHERE zone = ?", [zone]), 0)
        XCTAssertEqual(try self.count(phone, "SELECT COUNT(*) FROM syncCompanion WHERE zone = ?", [zone]), 0)
        XCTAssertNil(try read(phone.db) { db in try SyncEngineCore.token(zone: zone, db: db) }, "the zone's token is gone")
        let serverAfter = try await server(h, zone: zone)
        XCTAssertEqual(serverAfter, onServer, "the server is untouched")
        XCTAssertEqual(h.audit.householdViolations(router: h.adminRouter()), [])
    }

    func testDropPrivateZonesKeepsHousehold() async throws {
        let h = try await synced()
        let phone = h.adminPhone
        let household = try uuids(phone, zone: SyncZones.household)
        let householdRows = try count(phone, """
            SELECT COUNT(*) FROM transaction_ t JOIN syncRecord s ON s.tableName = 'transaction_' AND s.localId = t.id WHERE s.zone = ?
            """, [SyncZones.household])
        // The balance-only account is a household stub whose details came from A's zone.
        let stub = try XCTUnwrap(h.localId("account", uuid: try h.uuid("account", h.fixture.privateAccount), on: phone))
        try write(h.adminMac.db) { db in
            try db.execute(sql: "UPDATE account SET accountNumber = '12345678' WHERE id = ?", arguments: [h.fixture.privateAccount])
        }
        _ = try await h.adminMac.engine.syncNow()
        _ = try await phone.engine.pull()
        XCTAssertEqual(try read(phone.db) { db in try String.fetchOne(db, sql: "SELECT accountNumber FROM account WHERE id = ?", arguments: [stub]) },
                       "12345678", "precondition: the stub's details arrived from A's zone")
        let onServer = try await server(h, zone: SyncZones.household)

        let dropped = try write(phone.db) { db in try SyncLocalData.dropPrivateZones(db: db) }

        XCTAssertGreaterThan(dropped, 0)
        XCTAssertEqual(try uuids(phone, zone: h.fixture.privateZone), [])
        XCTAssertEqual(try uuids(phone, zone: SyncZones.household), household, "every household identity stays")
        for uuid in household {
            let table = try XCTUnwrap(read(phone.db) { db in try String.fetchOne(db, sql: "SELECT tableName FROM syncRecord WHERE uuid = ?", arguments: [uuid]) })
            XCTAssertNotNil(try h.localId(table, uuid: uuid, on: phone), "\(table) \(uuid) is still here")
        }
        XCTAssertEqual(try count(phone, "SELECT COUNT(*) FROM transaction_"), householdRows, "household transactions stay")
        XCTAssertNotNil(try h.localId("account", uuid: try h.uuid("account", h.fixture.privateAccount), on: phone), "the stub stays")
        XCTAssertNil(try read(phone.db) { db in try String.fetchOne(db, sql: "SELECT accountNumber FROM account WHERE id = ?", arguments: [stub]) },
                     "the details A's zone filled in are gone")
        XCTAssertNotNil(try read(phone.db) { db in try SyncEngineCore.token(zone: SyncZones.household, db: db) }, "the household's token stays")
        XCTAssertEqual(try count(phone, "SELECT COUNT(*) FROM syncPending"), 0)
        let serverAfter = try await server(h, zone: SyncZones.household)
        XCTAssertEqual(serverAfter, onServer)
    }

    // MARK: The iCloud account

    func testSameICloudUserAfterRelaunchKeepsData() async throws {
        let h = try await synced()
        let phone = h.adminPhone
        let before = try count(phone, "SELECT COUNT(*) FROM syncRecord")
        XCTAssertEqual(try write(phone.db) { db in try SyncAccountSwitch.apply(current: TwoPersonHousehold.adminICloudUser, db: db) }, .remember)
        // Relaunch: the same iCloud user, again and again.
        for _ in 1...3 {
            XCTAssertEqual(try write(phone.db) { db in try SyncAccountSwitch.apply(current: TwoPersonHousehold.adminICloudUser, db: db) }, .keep)
        }
        _ = try await phone.engine.pull()
        XCTAssertEqual(try count(phone, "SELECT COUNT(*) FROM syncRecord"), before, "nothing dropped")
        XCTAssertFalse(try uuids(phone, zone: h.fixture.privateZone).isEmpty)
        XCTAssertEqual(try read(phone.db) { db in try SyncAccountSwitch.stored(db: db) }, TwoPersonHousehold.adminICloudUser)
    }

    func testUndeterminedAccountDropsNothing() async throws {
        let h = try await synced()
        let phone = h.adminPhone
        try write(phone.db) { db in _ = try SyncAccountSwitch.apply(current: TwoPersonHousehold.adminICloudUser, db: db) }
        let before = try count(phone, "SELECT COUNT(*) FROM syncRecord")
        // No account, offline, an account-status blip: no record name.
        for undetermined in [nil, ""] as [String?] {
            XCTAssertEqual(try write(phone.db) { db in try SyncAccountSwitch.apply(current: undetermined, db: db) }, .keep)
        }
        XCTAssertEqual(try count(phone, "SELECT COUNT(*) FROM syncRecord"), before, "nothing dropped")
        XCTAssertEqual(try read(phone.db) { db in try SyncAccountSwitch.stored(db: db) }, TwoPersonHousehold.adminICloudUser, "the user stays known")
        // The same user back afterwards: still nothing dropped.
        XCTAssertEqual(try write(phone.db) { db in try SyncAccountSwitch.apply(current: TwoPersonHousehold.adminICloudUser, db: db) }, .keep)
        XCTAssertEqual(try count(phone, "SELECT COUNT(*) FROM syncRecord"), before)
        // A device that never knew its user doesn't drop on the first one it learns.
        let fresh = try TestDatabase.migrated()
        XCTAssertEqual(try write(fresh) { db in try SyncAccountSwitch.apply(current: nil, db: db) }, .keep)
        XCTAssertNil(try read(fresh) { db in try SyncAccountSwitch.stored(db: db) })
    }

    func testDifferentICloudUserDropsPrivateData() async throws {
        let h = try await synced()
        let phone = h.adminPhone
        try write(phone.db) { db in _ = try SyncAccountSwitch.apply(current: TwoPersonHousehold.adminICloudUser, db: db) }
        let household = try uuids(phone, zone: SyncZones.household)
        let onServer = try await server(h, zone: h.fixture.privateZone)
        XCTAssertFalse(try uuids(phone, zone: h.fixture.privateZone).isEmpty, "precondition")

        XCTAssertEqual(try write(phone.db) { db in try SyncAccountSwitch.apply(current: "someone-else", db: db) }, .dropPrivate)

        XCTAssertEqual(try uuids(phone, zone: h.fixture.privateZone), [], "A's private data is gone")
        XCTAssertEqual(try uuids(phone, zone: SyncZones.household), household, "the household's stays")
        XCTAssertEqual(try count(phone, "SELECT COUNT(*) FROM syncPending"), 0, "nothing queued")
        XCTAssertEqual(try read(phone.db) { db in try SyncAccountSwitch.stored(db: db) }, "someone-else")
        let serverAfter = try await server(h, zone: h.fixture.privateZone)
        XCTAssertEqual(serverAfter, onServer, "nothing deleted on the server")
        // The new user, again: nothing more happens.
        XCTAssertEqual(try write(phone.db) { db in try SyncAccountSwitch.apply(current: "someone-else", db: db) }, .keep)
        // The engine restarted for the new user (household only, until the household names its person) brings no
        // private data back.
        let restarted = SyncEngineCore(db: phone.db, transport: h.audit, device: SyncDevice(id: "admin-phone", name: "iPhone"),
                                       keyStore: h.adminKeys, readOnly: true, viewer: .none)
        _ = try await restarted.pull()
        XCTAssertEqual(try uuids(phone, zone: h.fixture.privateZone), [])
        // The Mac still holds and serves it.
        XCTAssertFalse(try uuids(h.adminMac, zone: h.fixture.privateZone).isEmpty)
    }

    // MARK: Removed from the household

    func testRemovedParticipantPullReportsLeftHousehold() async throws {
        let h = try await synced()
        let member = memberEngine(h)
        try write(h.memberDevice.db) { db in try SyncHouseholdMembership.record(ownerRecordName: TwoPersonHousehold.adminICloudUser, db: db) }
        let first = try await member.pull()
        XCTAssertFalse(first.leftHousehold, "still in the household")
        let held = try uuids(h.memberDevice, zone: SyncZones.household)
        XCTAssertFalse(held.isEmpty, "precondition: she holds the household")
        let onServer = try await server(h, zone: SyncZones.household)

        // A transient failure is not a removal.
        let offline = SyncEngineCore(db: h.memberDevice.db, transport: OfflineTransport(), device: SyncDevice(id: "member-device", name: "iPad"),
                                     keyStore: h.memberKeys, readOnly: true, viewer: SyncViewer(personUuid: h.personBUuid), householdIsShared: true)
        do {
            _ = try await offline.pull()
            XCTFail("offline")
        } catch {}
        XCTAssertEqual(try uuids(h.memberDevice, zone: SyncZones.household), held, "offline: nothing dropped")
        // The admin's own phone (household in its private database) never reads a missing household as leaving.
        let ownHousehold = SyncEngineCore(db: try TestDatabase.migrated(), transport: FakeCloud(), device: SyncDevice(id: "x", name: "x"),
                                          keyStore: InMemorySyncKeyStore(), readOnly: true)
        let own = try await ownHousehold.pull()
        XCTAssertFalse(own.leftHousehold)

        try await h.cloud.removeParticipant(userRecordName: TwoPersonHousehold.memberICloudUser, zone: SyncZones.household)
        let report = try await member.pull()

        XCTAssertTrue(report.leftHousehold)
        XCTAssertEqual(try uuids(h.memberDevice, zone: SyncZones.household), held, "the pull itself changes nothing here")
        XCTAssertEqual(try count(h.memberDevice, "SELECT COUNT(*) FROM syncPending"), 0, "nothing queued")
        XCTAssertEqual(h.memberAudit.savesByZone[SyncZones.household] ?? [], [], "she sent nothing")
        let serverAfter = try await server(h, zone: SyncZones.household)
        XCTAssertEqual(serverAfter, onServer, "nothing made or deleted on the server")

        // What her device then does (the phone controller): drops the household, forgets the membership.
        let dropped = try write(h.memberDevice.db) { db in try SyncHouseholdMembership.left(db: db) }
        XCTAssertEqual(dropped, held.count)
        XCTAssertEqual(try uuids(h.memberDevice, zone: SyncZones.household), [])
        XCTAssertEqual(try count(h.memberDevice, "SELECT COUNT(*) FROM transaction_"), 0, "no household transaction left")
        XCTAssertEqual(try count(h.memberDevice, "SELECT COUNT(*) FROM account"), 0, "no account left")
        XCTAssertEqual(try count(h.memberDevice, "SELECT COUNT(*) FROM syncConflict"), 0, "nothing kept back")
        XCTAssertNil(try read(h.memberDevice.db) { db in try SyncHouseholdMembership.current(db: db) })
        XCTAssertEqual(try count(h.memberDevice, "SELECT COUNT(*) FROM syncPending"), 0)
        let serverAtEnd = try await server(h, zone: SyncZones.household)
        XCTAssertEqual(serverAtEnd, onServer)
    }

    func testFiledYearFiguresUnchangedAfterDropOnAdminSide() async throws {
        let h = try TwoPersonHousehold.make()
        let f = h.fixture
        try write(h.adminMac.db) { db in
            try db.execute(sql: "UPDATE property SET currency = ? WHERE id = ?", arguments: [Currency.gbp.rawValue, f.propertyId])
            _ = try Properties.setOwners(db: db, propertyId: f.propertyId,
                                         [PropertyOwner(propertyId: f.propertyId, personId: f.personA, shareBasisPoints: 10_000)])
            let group = try Int64.fetchOne(db, sql: "SELECT groupId FROM category WHERE id = ?", arguments: [f.propertyCategory])
            var repairs = Category(name: "Repairs", type: .expense, groupId: group)
            try repairs.insert(db)
            _ = try TaxExpenseTypeMap.seed(db: db, propertyId: f.propertyId)
            var year = TaxYear(startYear: 2024, personId: f.personA, status: .filed)
            try year.insert(db)
            let batch = try Int64.fetchOne(db, sql: "SELECT importBatchId FROM transaction_ WHERE id = ?", arguments: [f.lisbonTransaction])!
            var repair = Transaction(importBatchId: batch, accountId: f.lisbon,
                                     date: MonthRange.calendar.date(from: DateComponents(year: 2024, month: 7, day: 1))!,
                                     rawDescription: "PLUMBER", amountMinorUnits: -10_000, categoryId: repairs.id, status: .confirmed,
                                     categorizedBy: .manual, fingerprint: "fp-plumber")
            try repair.insert(db)
        }
        _ = try await h.adminMac.engine.syncNow()
        try await h.syncAll()
        let member = memberEngine(h)
        _ = try await member.pull()
        let filed = try read(h.adminMac.db) { db in try TaxFigures.snapshot(db: db) }
        XCTAssertFalse(filed.values.filter { $0.key.startYear == 2024 && $0.key.field.hasPrefix("SA ") }.isEmpty, "precondition: a filed return")
        let macRecords = try count(h.adminMac, "SELECT COUNT(*) FROM syncRecord")
        let phoneFiled = try read(h.adminPhone.db) { db in try TaxFigures.snapshot(db: db) }
        XCTAssertFalse(try uuids(h.memberDevice, zone: SyncZones.household).isEmpty, "precondition")

        try await h.cloud.removeParticipant(userRecordName: TwoPersonHousehold.memberICloudUser, zone: SyncZones.household)
        let report = try await member.pull()
        XCTAssertTrue(report.leftHousehold)
        try write(h.memberDevice.db) { db in _ = try SyncHouseholdMembership.left(db: db) }
        // The admin's devices sync on.
        _ = try await h.adminMac.engine.syncNow()
        _ = try await h.adminMac2.engine.syncNow()
        _ = try await h.adminPhone.engine.pull()

        XCTAssertEqual(try read(h.adminMac.db) { db in try TaxFigures.snapshot(db: db) }, filed, "the Mac's filed figures don't move")
        XCTAssertEqual(try read(h.adminPhone.db) { db in try TaxFigures.snapshot(db: db) }, phoneFiled, "nor the phone's")
        XCTAssertEqual(try count(h.adminMac, "SELECT COUNT(*) FROM syncRecord"), macRecords, "the Mac keeps every record")
        XCTAssertEqual(try count(h.adminMac, "SELECT COUNT(*) FROM syncPending"), 0)
        XCTAssertEqual(try count(h.adminMac, "SELECT COUNT(*) FROM syncTombstone"), 0, "no delete reached the Mac")
        XCTAssertEqual(h.audit.householdViolations(router: h.adminRouter()), [])
    }
}

/// Every call fails as offline.
private struct OfflineTransport: SyncTransport {
    func operationLimits() async -> SyncOperationLimits { SyncOperationLimits(maxRecords: 400, maxBytes: 1_000_000) }
    func createZone(_ zone: String) async throws { throw SyncTransportError.networkUnavailable }
    func save(_ records: [SyncWireRecord], ifUnchanged: [String: Data], atomic: Bool) async throws -> [SaveResult] {
        throw SyncTransportError.networkUnavailable
    }
    func changes(since token: Data?, zone: String) async throws -> SyncChanges { throw SyncTransportError.networkUnavailable }
    func delete(_ recordNames: [String], zone: String) async throws { throw SyncTransportError.networkUnavailable }
    func fetch(_ recordName: String, zone: String) async throws -> SyncServerRecord? { throw SyncTransportError.networkUnavailable }
    func serverTime() async throws -> Date? { throw SyncTransportError.networkUnavailable }
}
