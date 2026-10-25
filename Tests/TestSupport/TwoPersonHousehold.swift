import Foundation
import GRDB
import BudgetCore

/// Two simulated people over one `FakeCloud` (step 6): the admin A on a Mac (`adminMac`, the writer, holding the
/// `SharingFixture`) and an iPhone (`adminPhone`, read-only), and the member B on a device of her own
/// (`memberDevice`). The admin's devices share `adminKeys` (their iCloud Keychain: the household key and A's
/// private key); the member's `memberKeys` share only the household key. Every save goes through `audit`, so a
/// test can check that nothing placed privately reached the household. Synthetic data only.
public final class TwoPersonHousehold {
    public typealias Device = (db: DatabaseQueue, engine: SyncEngineCore)

    public let cloud: FakeCloud
    /// The admin's devices' transport: every household save they make is judged, as it is made, by the Mac's router.
    public let audit: ZoneAuditingTransport
    /// The member's device's transport, judged by her device's own router.
    public let memberAudit: ZoneAuditingTransport
    public let adminKeys: InMemorySyncKeyStore
    public let memberKeys: InMemorySyncKeyStore
    public let adminMac: Device
    public let adminPhone: Device
    public let memberDevice: Device
    public let fixture: SharingFixture
    /// Person B's `person` UUID and private zone.
    public let personBUuid: String
    public let memberZone: String

    private init(cloud: FakeCloud, audit: ZoneAuditingTransport, memberAudit: ZoneAuditingTransport, adminKeys: InMemorySyncKeyStore, memberKeys: InMemorySyncKeyStore,
                 adminMac: Device, adminPhone: Device, memberDevice: Device, fixture: SharingFixture, personBUuid: String) {
        self.cloud = cloud
        self.audit = audit
        self.memberAudit = memberAudit
        self.adminKeys = adminKeys
        self.memberKeys = memberKeys
        self.adminMac = adminMac
        self.adminPhone = adminPhone
        self.memberDevice = memberDevice
        self.fixture = fixture
        self.personBUuid = personBUuid
        memberZone = SyncZones.privateZone(personUuid: personBUuid)
    }

    /// The household, with `SharingFixture` on the admin's Mac; `levels` (account id to level) replace the
    /// fixture's, written as they are (no blockers checked). `macDocuments` / `phoneDocuments`: where those devices
    /// keep files, when a test syncs files.
    public static func make(levels: [Int64: SharingLevel] = [:], macDocuments: SyncDocumentFiles? = nil,
                            phoneDocuments: SyncDocumentFiles? = nil) throws -> TwoPersonHousehold {
        let cloud = FakeCloud()
        let adminKeys = InMemorySyncKeyStore()
        let memberKeys = InMemorySyncKeyStore()
        let householdKey = DocumentCrypto.newZoneKey()
        try adminKeys.store(householdKey, zone: SyncZones.household)
        try memberKeys.store(householdKey, zone: SyncZones.household)
        let audit = ZoneAuditingTransport(wrapping: cloud, keyStore: adminKeys)
        let memberAudit = ZoneAuditingTransport(wrapping: cloud, keyStore: memberKeys)

        let mac = try TestDatabase.migrated()
        let (fixture, adminUser, memberUser, personB) = try mac.write { db -> (SharingFixture, String, String, String) in
            let fixture = try SharingFixture.build(db)
            for (account, level) in levels {
                try db.execute(sql: "UPDATE account SET sharingLevel = ? WHERE id = ?", arguments: [level.rawValue, account])
            }
            let member = try Int64.fetchOne(db, sql: "SELECT id FROM appUser WHERE personId = ?", arguments: [fixture.personB])!
            let adminUser = try SyncRecordStore.uuid(for: "appUser", localId: fixture.admin.appUserId, db: db)
            let memberUser = try SyncRecordStore.uuid(for: "appUser", localId: member, db: db)
            let personB = try SyncRecordStore.uuid(for: "person", localId: fixture.personB, db: db)
            try SyncChangeTracker.setWriter(adminUser, db: db)
            return (fixture, adminUser, memberUser, personB)
        }
        let phone = try TestDatabase.migrated()
        try phone.write { db in try SyncChangeTracker.setWriter(adminUser, db: db) }
        let member = try TestDatabase.migrated()
        try member.write { db in try SyncChangeTracker.setWriter(memberUser, db: db) }

        let admin = SyncViewer(personUuid: fixture.personAUuid)
        let macEngine = SyncEngineCore(db: mac, transport: audit, device: SyncDevice(id: "admin-mac", name: "Mac"), keyStore: adminKeys,
                                       documents: macDocuments, viewer: admin)
        let phoneEngine = SyncEngineCore(db: phone, transport: audit, device: SyncDevice(id: "admin-phone", name: "iPhone"), keyStore: adminKeys,
                                         documents: phoneDocuments, readOnly: true, viewer: admin)
        let memberEngine = SyncEngineCore(db: member, transport: memberAudit, device: SyncDevice(id: "member-device", name: "iPad"), keyStore: memberKeys,
                                          viewer: SyncViewer(personUuid: personB))
        audit.judge(with: router(mac))
        memberAudit.judge(with: router(member))
        return TwoPersonHousehold(cloud: cloud, audit: audit, memberAudit: memberAudit, adminKeys: adminKeys, memberKeys: memberKeys,
                                  adminMac: (mac, macEngine), adminPhone: (phone, phoneEngine), memberDevice: (member, memberEngine),
                                  fixture: fixture, personBUuid: personB)
    }

    /// The admin's Mac pushes, then the admin's phone and the member's device pull.
    public func syncAll() async throws {
        try await adminMac.engine.pushPending()
        try await adminPhone.engine.pull()
        try await memberDevice.engine.pull()
    }

    /// Where the admin's Mac places each record now (by UUID; nil for one it doesn't hold), for
    /// `audit.householdViolations`.
    public func adminRouter() -> @Sendable (String) -> ZoneAssignment? {
        Self.router(adminMac.db)
    }

    /// Where `device` places each record now (by UUID; nil for one it doesn't hold or can't place).
    static func router(_ mac: DatabaseQueue) -> @Sendable (String) -> ZoneAssignment? {
        { uuid in
            try? mac.read { db -> ZoneAssignment? in
                guard let row = try Row.fetchOne(db, sql: "SELECT tableName, localId FROM syncRecord WHERE uuid = ?", arguments: [uuid]) else {
                    return nil
                }
                return try SyncZoneRouter(db: db).assignment(table: row["tableName"], localId: row["localId"])
            }
        }
    }

    /// Queues every record on the admin's Mac to be sent again (no data written): what a level change does for the
    /// records it moves (step 6 Task 8), so the next push places each one again.
    public func requeueEverythingOnTheMac() throws {
        try adminMac.db.write { db in
            let base = try Int64.fetchOne(db, sql: "SELECT COALESCE(MAX(revision), 0) FROM syncPending") ?? 0
            try db.execute(sql: """
                INSERT INTO syncPending(uuid, tableName, localId, kind, revision)
                SELECT uuid, tableName, localId, 'update', ? + rowid FROM syncRecord ORDER BY rowid
                ON CONFLICT(uuid) DO NOTHING
                """, arguments: [base])
        }
    }

    /// The record's UUID on the admin's Mac.
    public func uuid(_ table: String, _ id: Int64) throws -> String {
        try adminMac.db.write { db in try SyncRecordStore.uuid(for: table, localId: id, db: db) }
    }

    /// The local id of the record on `device`, if it holds it.
    public func localId(_ table: String, uuid: String, on device: Device) throws -> Int64? {
        try device.db.read { db in try SyncRecordStore.localId(table: table, uuid: uuid, db: db) }
    }
}
