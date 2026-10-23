import XCTest
import GRDB
import CryptoKit
@testable import BudgetCore

/// Ruling R15 through the engine: what reaches the server is sealed (`sealed` + `keyId`, the zone key marker, the
/// sealed lease), devices sharing a key store (iCloud Keychain) sync both ways, a device without the key waits and
/// creates nothing, and a step 3 keyring moves into the key store once. Synthetic data; in-memory key stores only.
final class FieldSealingSyncTests: XCTestCase {
    private let zone = SyncRecordStore.householdZone
    private var cloud: FakeCloud!
    private var keys: InMemorySyncKeyStore!
    private var a: SyncEngineTestDevice!

    override func setUp() async throws {
        cloud = FakeCloud()
        keys = InMemorySyncKeyStore()
        a = try SyncEngineTestDevice("user-a", name: "Mac", cloud: cloud, keys: keys)
    }

    @discardableResult
    private func addAccount(_ device: SyncEngineTestDevice, _ name: String) throws -> Int64 {
        try device.write { db in
            var account = Account(name: name, currency: .gbp, kind: .cash, trackingMode: .imported)
            try account.insert(db)
            return account.id!
        }
    }

    private func marker() async throws -> (SyncZoneKeys.Marker, String) {
        let awaited = await cloud.record(named: SyncZoneKeys.recordName(zone: zone))
        let record = try XCTUnwrap(awaited)
        return (try SyncZoneKeys.marker(from: record.wire), record.stamp.changeTag)
    }

    private func saves(since index: Int) async -> [String] {
        await cloud.calls.dropFirst(index).flatMap { call -> [String] in
            if case .save(let names, _) = call { return names } else { return [] }
        }
    }

    private func staged(_ device: SyncEngineTestDevice) throws -> [SyncStagingRow] {
        try device.read { db in try SyncStagingRow.order(Column("id")).fetchAll(db) }
    }

    // MARK: The wire

    func testEveryRecordOnTheServerIsSealedOrAMarkerAndHoldsNoSourceValue() async throws {
        try addAccount(a, "Synthetic Account Theta")
        try await a.engine.syncNow()
        try await a.engine.acquireImportLease()

        let records = await cloud.storedRecords()
        XCTAssertTrue(Set(records.map(\.recordType)).isSuperset(of: ["account", SyncZoneKeys.recordType, TransportLeaseStore.recordType]))
        let (current, _) = try await marker()
        for record in records {
            XCTAssertTrue(record.unencryptedFields.isEmpty)
            XCTAssertTrue(record.assets.isEmpty)
            if record.recordType == SyncZoneKeys.recordType {
                XCTAssertEqual(Set(record.encryptedFields.keys), ["keyId", "createdAt"])
                continue
            }
            XCTAssertEqual(Set(record.encryptedFields.keys), [FieldSealing.sealedField, FieldSealing.keyIdField], record.recordType)
            XCTAssertEqual(FieldSealing.keyId(of: record), current.keyId)
            for needle in ["Synthetic Account Theta", "device-user-a", "user-a", "{\"string\"", "\"fields\""] {
                for data in record.encryptedFields.values {
                    XCTAssertNil(data.range(of: Data(needle.utf8)), "\(record.recordType): \(needle) readable")
                }
            }
            XCTAssertTrue(UUID(uuidString: record.recordName) != nil || record.recordName == TransportLeaseStore.recordName, "opaque name")
        }
        // The lease still reads, through the seal.
        let holder = try await a.engine.importLeaseHolder()
        XCTAssertEqual(holder?.holderId, "device-user-a")
    }

    // MARK: Devices sharing the key store

    func testTwoDevicesSharingOneKeyStoreSyncBothWays() async throws {
        let b = try SyncEngineTestDevice("user-b", name: "iPad", cloud: cloud, keys: keys)
        try addAccount(a, "Synthetic A")
        try await a.engine.syncNow()
        try addAccount(b, "Synthetic B")
        try await b.engine.syncNow()
        try await a.engine.syncNow()
        XCTAssertEqual(try a.count("account"), 2)
        XCTAssertEqual(try a.content(), try b.content())
        XCTAssertEqual(try keys.allKeys(zone: zone).count, 1, "one household key")
    }

    // MARK: Waiting for the household key

    func testADeviceWithoutTheKeyWaitsCreatesNothingAndAppliesOnceTheKeyArrives() async throws {
        let theirs = try addAccount(a, "Synthetic Shared")
        try await a.engine.syncNow()
        let (published, tag) = try await marker()

        // B: another device of the household whose iCloud Keychain hasn't delivered the key yet.
        let bKeys = InMemorySyncKeyStore()
        let b = try SyncEngineTestDevice("user-b", name: "iPad", cloud: cloud, keys: bKeys)
        let pulled = try await b.engine.pull()
        XCTAssertEqual(pulled.waitingForKey, 1)
        XCTAssertEqual(pulled.unreadable, 0)
        XCTAssertEqual(try b.count("account"), 0, "nothing applied")
        let waiting = try staged(b)
        XCTAssertEqual(waiting.map(\.uuid), [try a.uuid("account", theirs)])
        XCTAssertEqual(waiting.first?.reason, SyncTranslator.waitingForHouseholdKey)
        XCTAssertFalse(waiting.first?.payloadJSON.contains("Synthetic Shared") ?? true, "kept sealed")

        // B's own edit waits too: nothing is sent, no key is made, the marker isn't touched.
        try addAccount(b, "Synthetic Offline")
        let mark = await cloud.calls.count
        let report = try await b.engine.syncNow()
        XCTAssertEqual(report.push.keyWait, .waitingForHouseholdKey)
        XCTAssertEqual(report.push.saved, 0)
        let sent = await saves(since: mark)
        XCTAssertEqual(sent, [])
        XCTAssertEqual(try bKeys.allKeys(zone: zone).count, 0, "no second key")
        let (still, stillTag) = try await marker()
        XCTAssertEqual(still, published)
        XCTAssertEqual(stillTag, tag, "the marker isn't overwritten")
        do {
            try await b.engine.acquireImportLease()
            XCTFail("no lease without the key")
        } catch SyncKeyError.waitingForHouseholdKey {}
        // A later pull without the key leaves it waiting.
        let again = try await b.engine.pull()
        XCTAssertEqual(again.received, 0)
        XCTAssertEqual(try staged(b).map(\.reason), [SyncTranslator.waitingForHouseholdKey])

        // iCloud Keychain delivers the key: the next sync opens and applies what waited, then sends B's edit.
        try bKeys.store(try XCTUnwrap(keys.key(zone: zone)), zone: zone)
        let delivered = try await b.engine.syncNow()
        XCTAssertNil(delivered.push.keyWait)
        XCTAssertEqual(delivered.push.saved, 1)
        XCTAssertEqual(try staged(b), [])
        XCTAssertEqual(try b.count("account"), 2)
        try await a.engine.syncNow()
        XCTAssertEqual(try a.content(), try b.content())
        XCTAssertEqual(try bKeys.allKeys(zone: zone).count, 1)

        // The record that waited took its server stamp: B's edit of it goes without a merge.
        let local = try XCTUnwrap(try b.localId("account", try a.uuid("account", theirs)))
        try b.write { db in try db.execute(sql: "UPDATE account SET name = 'Synthetic Renamed' WHERE id = ?", arguments: [local]) }
        let edit = try await b.engine.pushPending()
        XCTAssertEqual(edit.saved, 1)
        XCTAssertEqual(edit.merged, 0)
    }

    func testTheLoserOfACreationRaceWithoutTheWinnersKeyAdoptsItsMarkerAndWaits() async throws {
        try addAccount(a, "Synthetic Winner")
        // B finds no marker; before it publishes its own, A creates the key and the marker.
        let bKeys = InMemorySyncKeyStore()
        let winner = a.engine
        let race = ZoneKeyRaceTransport(cloud: cloud) { _ = try await winner.syncNow() }
        let manager = try DatabaseManager(path: nil)
        try manager.migrate()
        try await manager.dbQueue.write { db in try SyncChangeTracker.setWriter("user-b", db: db) }
        let b = SyncEngineCore(db: manager.dbQueue, transport: race, device: SyncDevice(id: "device-user-b", name: "iPad"), keyStore: bKeys)
        try await manager.dbQueue.write { db in
            var account = Account(name: "Synthetic Loser", currency: .gbp, kind: .cash, trackingMode: .imported)
            try account.insert(db)
        }
        let report = try await b.pushPending()
        XCTAssertEqual(report.keyWait, .waitingForHouseholdKey)
        let (current, _) = try await marker()
        XCTAssertEqual(current.keyId, DocumentCrypto.zoneKeyId(try XCTUnwrap(keys.key(zone: zone))), "the winner's marker stays")
        // B made a key before it lost; nothing was sealed with it.
        let made = try XCTUnwrap(bKeys.key(zone: zone))
        for record in await cloud.storedRecords() {
            XCTAssertNotEqual(FieldSealing.keyId(of: record), DocumentCrypto.zoneKeyId(made))
        }
        let zone = self.zone
        try await manager.dbQueue.read { db in
            XCTAssertEqual(try SyncZoneKeys.local(zone: zone, db: db)?.marker.keyId, current.keyId)
            XCTAssertFalse(try SyncChangeTracker.pending(db: db).isEmpty, "its edit waits")
        }
    }

    // MARK: Step 3 keyrings

    private func legacyKeyring(current: SymmetricKey, retired: [SymmetricKey]) -> SyncZoneKeys.LegacyKeyring {
        func entry(_ key: SymmetricKey) -> SyncZoneKeys.LegacyKeyring.Entry {
            .init(id: DocumentCrypto.zoneKeyId(key), keyData: key.withUnsafeBytes { Data($0) })
        }
        return .init(generation: 1 + retired.count, current: entry(current), retired: retired.map(entry))
    }

    func testAStepThreeLocalKeyringMovesIntoTheKeyStoreOnceAndLeavesSyncState() async throws {
        let old = DocumentCrypto.newZoneKey()
        let current = DocumentCrypto.newZoneKey()
        let legacy = SyncZoneKeys.LegacyLocal(keyring: legacyKeyring(current: current, retired: [old]), systemFields: Data([1, 2, 3]))
        try a.write { db in
            try SyncImportGate.setState(try JSONEncoder().encode(legacy), key: "zoneKeys.\(zone)", db: db, now: Date())
        }

        try await a.engine.pull()
        XCTAssertEqual(Set(try keys.allKeys(zone: zone).keys), [DocumentCrypto.zoneKeyId(old), DocumentCrypto.zoneKeyId(current)])
        XCTAssertEqual(try keys.key(zone: zone).map(DocumentCrypto.zoneKeyId), DocumentCrypto.zoneKeyId(current), "the current key is the newest")
        try a.read { db in
            XCTAssertNil(try Data.fetchOne(db, sql: "SELECT value FROM syncState WHERE key = ?", arguments: ["zoneKeys.\(zone)"]), "no key material left here")
            let local = try XCTUnwrap(try SyncZoneKeys.local(zone: zone, db: db))
            XCTAssertEqual(local.marker.keyId, DocumentCrypto.zoneKeyId(current))
            XCTAssertNil(local.systemFields, "asked of the server before sealing")
            let rows = try Row.fetchAll(db, sql: "SELECT value FROM syncState")
            let keyBytes = current.withUnsafeBytes { Data($0) }
            for row in rows { XCTAssertNil((row["value"] as Data?)?.range(of: keyBytes), "no key bytes in syncState") }
        }
        // Once: a second start finds nothing to move.
        XCTAssertFalse(try SyncZoneKeys.migrateLocalKeyring(zone: zone, db: a.queue, keyStore: keys, now: Date()))

        // The zone (no marker yet) gets the migrated key's marker, and records go sealed under it.
        try addAccount(a, "Synthetic After Migration")
        try await a.engine.syncNow()
        let (published, _) = try await marker()
        XCTAssertEqual(published.keyId, DocumentCrypto.zoneKeyId(current))
        let account = await cloud.storedRecords().first { $0.recordType == "account" }
        XCTAssertEqual(account.flatMap(FieldSealing.keyId), DocumentCrypto.zoneKeyId(current))
    }

    /// Security review finding 3: a `zoneKeys.<zone>` row that doesn't decode as a step 3 keyring is the only local
    /// copy of whatever it holds, so it is set aside under another key (never deleted); nothing is stored or published.
    func testAnUndecodableStepThreeKeyringRowIsSetAsideNotDeleted() async throws {
        let garbage = Data("not a keyring".utf8)
        try a.write { db in try SyncImportGate.setState(garbage, key: "zoneKeys.\(zone)", db: db, now: Date()) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        XCTAssertTrue(try SyncZoneKeys.migrateLocalKeyring(zone: zone, db: a.queue, keyStore: keys, now: now))
        XCTAssertTrue(try keys.allKeys(zone: zone).isEmpty, "nothing stored")
        try a.read { db in
            XCTAssertNil(try Data.fetchOne(db, sql: "SELECT value FROM syncState WHERE key = ?", arguments: ["zoneKeys.\(zone)"]))
            XCTAssertNil(try SyncZoneKeys.local(zone: zone, db: db), "no marker from it")
            let rows = try Row.fetchAll(db, sql: "SELECT key, value FROM syncState WHERE key LIKE ?", arguments: ["zoneKeys.\(zone).unreadable-%"])
            XCTAssertEqual(rows.count, 1)
            XCTAssertEqual(rows.first?["key"] as String?, "zoneKeys.\(zone).unreadable-1800000000")
            XCTAssertEqual(rows.first?["value"] as Data?, garbage, "kept byte for byte")
        }
        // Once: the set-aside row isn't a keyring to move, and a start finds nothing more.
        XCTAssertFalse(try SyncZoneKeys.migrateLocalKeyring(zone: zone, db: a.queue, keyStore: keys, now: now))
        try await a.engine.pull()
        try a.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM syncState WHERE key LIKE ?", arguments: ["zoneKeys.\(zone).unreadable-%"]), 1)
        }
    }

    func testAStepThreeZoneKeyRecordOnTheServerIsReplacedByItsMarker() async throws {
        let current = DocumentCrypto.newZoneKey()
        try await cloud.createZone(zone)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let legacy = SyncWireRecord(recordType: SyncZoneKeys.recordType, recordName: SyncZoneKeys.recordName(zone: zone), zone: zone,
                                    encryptedFields: ["keys": try encoder.encode(legacyKeyring(current: current, retired: []))])
        _ = try await cloud.save([legacy], ifUnchanged: [:], atomic: false)

        try addAccount(a, "Synthetic Legacy Zone")
        let report = try await a.engine.syncNow()
        XCTAssertNil(report.push.keyWait)
        let awaited = await cloud.record(named: SyncZoneKeys.recordName(zone: zone))
        let record = try XCTUnwrap(awaited)
        XCTAssertEqual(Set(record.wire.encryptedFields.keys), ["keyId", "createdAt"], "the key material is gone from the server")
        XCTAssertEqual(try SyncZoneKeys.marker(from: record.wire).keyId, DocumentCrypto.zoneKeyId(current))
        XCTAssertEqual(try keys.key(zone: zone).map(DocumentCrypto.zoneKeyId), DocumentCrypto.zoneKeyId(current), "kept in the key store")
        XCTAssertEqual(report.pull.unreadable, 0)
    }
}
