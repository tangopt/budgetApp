import XCTest
import GRDB
@testable import BudgetCore
import TestSupport

/// Step 8 Task 1: the iPad's writer mode (`SyncWriteMode.device(zones:)`). It pushes only to its zones, holding back
/// (and counting) anything placed elsewhere, and never makes a zone, a key or a lease, nor rebuilds summaries. The
/// member's iPad writes the household only (`TwoPersonHousehold.memberTabletMode`); the admin's (`adminTablet`) the
/// household and A's private zone. Every save goes through the zone audits. Synthetic data only.
final class SyncDeviceWriterModeTests: XCTestCase {
    private typealias Device = TwoPersonHousehold.Device

    // MARK: Helpers

    private func read<T>(_ device: Device, _ body: (Database) throws -> T) throws -> T { try device.db.read(body) }
    private func write<T>(_ device: Device, _ body: (Database) throws -> T) throws -> T { try device.db.write(body) }

    private func assertAuditsClean(_ h: TwoPersonHousehold, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(h.audit.householdViolations(router: h.adminRouter()), [], "admin", file: file, line: line)
        XCTAssertEqual(h.memberAudit.householdViolations(router: TwoPersonHousehold.router(h.memberDevice.db)), [], "member",
                       file: file, line: line)
    }

    private func isPending(_ device: Device, _ uuid: String) throws -> Bool {
        try read(device) { db in try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM syncPending WHERE uuid = ?)", arguments: [uuid])! }
    }

    /// The member as her iPad, everything synced to every device.
    private func memberTabletHousehold(memberDocuments: SyncDocumentFiles? = nil, macDocuments: SyncDocumentFiles? = nil,
                                       memberHasHouseholdKey: Bool = true) async throws -> TwoPersonHousehold {
        let h = try TwoPersonHousehold.make(macDocuments: macDocuments, memberHasHouseholdKey: memberHasHouseholdKey,
                                            memberMode: TwoPersonHousehold.memberTabletMode, memberDocuments: memberDocuments)
        try await h.syncAll()
        return h
    }

    // MARK: Zones, keys, leases

    func testDeviceModeNeverCreatesAZone() async throws {
        let cloud = FakeCloud(zones: [])
        let db = try TestDatabase.migrated()
        let fixture = try await db.write { db in try SharingFixture.build(db) }
        let keys = InMemorySyncKeyStore()
        try keys.store(DocumentCrypto.newZoneKey(), zone: SyncZones.household)
        let engine = SyncEngineCore(db: db, transport: cloud, device: SyncDevice(id: "tablet", name: "iPad"), keyStore: keys,
                                    mode: .device(zones: [SyncZones.household, fixture.privateZone]),
                                    viewer: SyncViewer(personUuid: fixture.personAUuid))
        let pendingBefore = try await db.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM syncPending")! }
        XCTAssertGreaterThan(pendingBefore, 0, "something to send")

        let pulled = try await engine.pull()
        let pushed = try await engine.pushPending()

        XCTAssertEqual(pulled, SyncPullReport(), "nothing to download yet")
        XCTAssertEqual(pushed, SyncPushReport(), "nothing sent")
        let calls = await cloud.calls
        XCTAssertFalse(calls.contains { if case .createZone = $0 { true } else { false } }, "no zone made: \(calls)")
        let stored = await cloud.storedRecords()
        XCTAssertEqual(stored.count, 0, "nothing on the server, no key marker either")
        XCTAssertTrue(try keys.allKeys(zone: fixture.privateZone).isEmpty, "no key made for A's zone")
        let pendingAfter = try await db.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM syncPending")! }
        XCTAssertEqual(pendingAfter, pendingBefore, "everything still waits")
    }

    func testDeviceModeDoesNotRecreateAMissingZone() async throws {
        let h = try TwoPersonHousehold.make()
        try await h.syncAll()
        try await h.adminTablet.engine.pull()
        let uuid = try h.uuid("transaction_", h.fixture.sharedTransaction)
        let local = try XCTUnwrap(h.localId("transaction_", uuid: uuid, on: h.adminTablet))
        try write(h.adminTablet) { db in try db.execute(sql: "UPDATE transaction_ SET note = 'iPad' WHERE id = ?", arguments: [local]) }
        await h.cloud.deleteZone(SyncZones.household)
        let callsBefore = await h.cloud.calls.count

        _ = try await h.adminTablet.engine.pushPending()

        let calls = await h.cloud.calls.dropFirst(callsBefore)
        XCTAssertFalse(calls.contains { if case .createZone = $0 { true } else { false } }, "the household is the Mac's to make again")
        XCTAssertTrue(try isPending(h.adminTablet, uuid), "the edit waits")
        assertAuditsClean(h)
    }

    /// Step 19: an iPad that pushes the household takes the household's import lease (to import a statement there),
    /// with the household key it already holds; it never makes one. One device at a time, in either direction.
    func testDeviceModeTakesTheLease() async throws {
        let h = try TwoPersonHousehold.make()
        try await h.syncAll()
        try await h.adminTablet.engine.pull()
        let callsBefore = await h.cloud.calls.count
        try await h.adminTablet.engine.acquireImportLease()
        XCTAssertNotNil(try read(h.adminTablet) { db in try SyncImportGate.heldLease(db: db) }, "held here")
        let seen = try await h.adminMac.engine.importLeaseHolder()
        XCTAssertEqual(seen?.holderName, "Admin iPad", "the Mac sees \"Importing on Admin iPad\"")
        do {
            try await h.adminMac.engine.acquireImportLease()
            XCTFail("the Mac took the lease the iPad holds")
        } catch let error as ImportLeaseError {
            XCTAssertEqual(error.message, "Importing on Admin iPad")
        }
        try await h.adminTablet.engine.releaseImportLease()
        XCTAssertNil(try read(h.adminTablet) { db in try SyncImportGate.heldLease(db: db) })
        let after = try await h.adminTablet.engine.importLeaseHolder()
        XCTAssertNil(after)

        // The reverse: the Mac holds it, the iPad is refused and sees who.
        try await h.adminMac.engine.acquireImportLease()
        do {
            try await h.adminTablet.engine.acquireImportLease()
            XCTFail("the iPad took the lease the Mac holds")
        } catch let error as ImportLeaseError {
            guard case .heldBy(let name, _) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(name, "Mac")
        }
        XCTAssertNil(try read(h.adminTablet) { db in try SyncImportGate.heldLease(db: db) }, "nothing held on the iPad")
        let calls = await h.cloud.calls.dropFirst(callsBefore)
        XCTAssertFalse(calls.contains { if case .createZone = $0 { true } else { false } }, "no zone made")
    }

    /// The member's iPad (household only) takes the lease too, on the household it follows.
    func testMemberTabletTakesTheLease() async throws {
        let h = try await memberTabletHousehold()
        try await h.memberDevice.engine.acquireImportLease()
        let seen = try await h.adminMac.engine.importLeaseHolder()
        XCTAssertEqual(seen?.holderName, "iPad")
        try await h.memberDevice.engine.releaseImportLease()
        let after = try await h.adminMac.engine.importLeaseHolder()
        XCTAssertNil(after)
    }

    /// The lease seam (`ImportLeasing`): the engine's device and the zones it pushes.
    func testEngineIsTheLeaseSeam() async throws {
        let h = try TwoPersonHousehold.make()
        let leasing: any ImportLeasing = h.adminTablet.engine
        XCTAssertEqual(leasing.leaseDevice.name, "Admin iPad")
        let zones = await leasing.importZones()
        XCTAssertEqual(Set(zones ?? []), [SyncZones.household, h.fixture.privateZone])
    }

    /// The household exists, but the Mac hasn't published its key yet (no marker) and none is held here: the device
    /// waits for it, and makes none (for the household nor for A's zone).
    func testDeviceModeWithoutKeyWaits() async throws {
        let cloud = FakeCloud(zones: [SyncZones.household])
        let db = try TestDatabase.migrated()
        let fixture = try await db.write { db in try SharingFixture.build(db) }
        let keys = InMemorySyncKeyStore()
        let engine = SyncEngineCore(db: db, transport: cloud, device: SyncDevice(id: "tablet", name: "iPad"), keyStore: keys,
                                    mode: .device(zones: [SyncZones.household, fixture.privateZone]),
                                    viewer: SyncViewer(personUuid: fixture.personAUuid))

        let report = try await engine.pushPending()

        XCTAssertEqual(report.keyWait, .waitingForHouseholdKey)
        XCTAssertEqual(report.saved, 0)
        XCTAssertTrue(try keys.allKeys(zone: SyncZones.household).isEmpty, "no household key made")
        XCTAssertTrue(try keys.allKeys(zone: fixture.privateZone).isEmpty, "nor one for A's zone")
        let stored = await cloud.storedRecords()
        XCTAssertEqual(stored.count, 0, "no key marker published, nothing sent")
        let calls = await cloud.calls
        XCTAssertFalse(calls.contains { if case .createZone = $0 { true } else { false } })
    }

    // MARK: Pushing

    /// A utility invoice on the flat (a household record), made on the Mac and synced everywhere.
    private func invoice(_ h: TwoPersonHousehold) async throws -> String {
        let id = try write(h.adminMac) { db -> Int64 in
            try db.execute(sql: "INSERT INTO utilityProvider(propertyId, name, kind) VALUES (?, 'Synthetic Power', 'electricity')",
                           arguments: [h.fixture.propertyId])
            try db.execute(sql: """
                INSERT INTO utilityInvoice(providerId, invoiceNumber, issueDate, amountMinorUnits, notes)
                VALUES (?, 'INV-1', '2025-02-10 00:00:00.000', 4200, 'from the Mac')
                """, arguments: [db.lastInsertedRowID])
            return db.lastInsertedRowID
        }
        try await h.syncAll()
        return try h.uuid("utilityInvoice", id)
    }

    func testMemberDevicePushesHouseholdEditAttributedToHer() async throws {
        let h = try await memberTabletHousehold()
        let uuid = try await invoice(h)
        let local = try XCTUnwrap(h.localId("utilityInvoice", uuid: uuid, on: h.memberDevice), "her iPad holds the invoice")
        try write(h.memberDevice) { db in
            try db.execute(sql: "UPDATE utilityInvoice SET notes = 'checked on the iPad' WHERE id = ?", arguments: [local])
        }

        let report = try await h.memberDevice.engine.pushPending()

        XCTAssertEqual(report.saved, 1)
        XCTAssertEqual(report.heldBack, 0)
        let server = await h.cloud.record(named: uuid)
        XCTAssertEqual(server?.lastModifiedBy, TwoPersonHousehold.memberICloudUser, "the server says she wrote it")
        XCTAssertEqual(Set(h.memberAudit.savesByZone.keys), [SyncZones.household], "her iPad writes the household only")
        try await h.adminMac.engine.pull()
        let notes = try read(h.adminMac) { db in
            try String.fetchOne(db, sql: "SELECT notes FROM utilityInvoice WHERE id = ?", arguments: [try SyncRecordStore.localId(table: "utilityInvoice", uuid: uuid, db: db)])
        }
        XCTAssertEqual(notes, "checked on the iPad")
        assertAuditsClean(h)
    }

    func testDeviceModeHoldsBackRecordsOutsideItsZones() async throws {
        let h = try await memberTabletHousehold()
        let uuid = try await invoice(h)
        let local = try XCTUnwrap(h.localId("utilityInvoice", uuid: uuid, on: h.memberDevice))
        try write(h.memberDevice) { db in
            try db.execute(sql: "UPDATE utilityInvoice SET notes = 'placed privately' WHERE id = ?", arguments: [local])
        }
        let memberZone = h.memberZone
        await h.memberDevice.engine.setAssignmentOverride { table, id in
            table == "utilityInvoice" && id == local ? ZoneAssignment(zone: memberZone) : nil
        }
        let savesBefore = h.memberAudit.savesByZone.values.flatMap { $0 }.count

        let report = try await h.memberDevice.engine.pushPending()

        XCTAssertEqual(report.heldBack, 1, "counted")
        XCTAssertEqual(report.saved, 0)
        XCTAssertEqual(h.memberAudit.savesByZone.values.flatMap { $0 }.count, savesBefore, "nothing saved anywhere")
        XCTAssertNil(h.memberAudit.savesByZone[memberZone], "never her private zone")
        XCTAssertTrue(try isPending(h.memberDevice, uuid), "still to send")
        let calls = await h.cloud.calls
        XCTAssertFalse(calls.contains(.createZone(memberZone)), "her zone isn't made either")

        // Placed in the household again: it goes.
        await h.memberDevice.engine.setAssignmentOverride(nil)
        let again = try await h.memberDevice.engine.pushPending()
        XCTAssertEqual(again.heldBack, 0)
        XCTAssertEqual(again.saved, 1)
        XCTAssertFalse(try isPending(h.memberDevice, uuid))
        assertAuditsClean(h)
    }

    /// A delete the server has in a zone the iPad doesn't push to (her private zone, as far as her device knows)
    /// waits whole: nothing of it goes, not even the household's marker.
    func testDeviceModeHoldsBackDeletesOutsideItsZones() async throws {
        let h = try await memberTabletHousehold()
        let uuid = try await invoice(h)
        let local = try XCTUnwrap(h.localId("utilityInvoice", uuid: uuid, on: h.memberDevice))
        let memberZone = h.memberZone
        try write(h.memberDevice) { db in
            try SyncPresence.add(uuid: uuid, zone: memberZone, db: db)
            try db.execute(sql: "DELETE FROM utilityInvoice WHERE id = ?", arguments: [local])
        }
        let savesBefore = h.memberAudit.savesByZone.values.flatMap { $0 }.count

        let report = try await h.memberDevice.engine.pushPending()

        XCTAssertEqual(report.heldBack, 1)
        XCTAssertEqual(report.deleted, 0)
        XCTAssertEqual(h.memberAudit.savesByZone.values.flatMap { $0 }.count, savesBefore, "no marker saved")
        XCTAssertTrue(h.memberAudit.deletesByZone.isEmpty, "nothing deleted")
        XCTAssertTrue(try isPending(h.memberDevice, uuid))
        let server = await h.cloud.record(named: uuid)
        XCTAssertNotNil(server, "still on the server")
        assertAuditsClean(h)
    }

    /// The admin's iPad writes the household and A's private zone, each record where the Mac places it.
    func testAdminTabletPushesToBothItsZones() async throws {
        let h = try TwoPersonHousehold.make()
        try await h.syncAll()
        try await h.adminTablet.engine.pull()
        let f = h.fixture
        let shared = try h.uuid("transaction_", f.sharedTransaction)
        let privateOne = try h.uuid("transaction_", f.privateTransaction)
        for uuid in [shared, privateOne] {
            let local = try XCTUnwrap(h.localId("transaction_", uuid: uuid, on: h.adminTablet))
            try write(h.adminTablet) { db in try db.execute(sql: "UPDATE transaction_ SET note = 'from the iPad' WHERE id = ?", arguments: [local]) }
        }

        let report = try await h.adminTablet.engine.pushPending()

        XCTAssertEqual(report.saved, 2)
        XCTAssertEqual(report.heldBack, 0)
        let inHousehold = (h.audit.savesByZone[SyncZones.household] ?? []).map(\.recordName)
        let inPrivate = (h.audit.savesByZone[f.privateZone] ?? []).map(\.recordName)
        XCTAssertTrue(inHousehold.contains(shared))
        XCTAssertTrue(inPrivate.contains(privateOne))
        XCTAssertFalse(inHousehold.contains(privateOne), "never the household")
        try await h.adminMac.engine.pull()
        let notes = try read(h.adminMac) { db in
            try String.fetchAll(db, sql: "SELECT note FROM transaction_ WHERE id IN (?, ?)", arguments: [f.sharedTransaction, f.privateTransaction])
        }
        XCTAssertEqual(notes, ["from the iPad", "from the iPad"])
        assertAuditsClean(h)
    }

    func testDeviceModeDoesNotRebuildSummaries() async throws {
        let h = try TwoPersonHousehold.make()
        try await h.syncAll()
        try await h.adminTablet.engine.pull()
        let snapshot = {
            try self.read(h.adminTablet) { db in
                try String.fetchAll(db, sql: """
                    SELECT 'm:' || accountId || ':' || amountMinorUnits FROM accountSummaryMonth
                    UNION ALL SELECT 'b:' || accountId || ':' || balanceMinorUnits FROM accountBalancePoint ORDER BY 1
                    """)
            }
        }
        let before = try snapshot()
        let now = Date()
        try write(h.adminTablet) { db in try SyncImportGate.setState(Data([1]), key: AccountSummaryBuilder.dirtyKey, db: db, now: now) }

        _ = try await h.adminTablet.engine.pushPending()

        XCTAssertEqual(try snapshot(), before, "no summary changed")
        XCTAssertTrue(try read(h.adminTablet) { db in try AccountSummaryBuilder.isDirty(db: db) }, "they stay the Mac's to rebuild")
        assertAuditsClean(h)
    }

    func testDeviceWithoutFileKeepsDocumentFileReferenceOnPush() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("device-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let macLibrary = folder.appendingPathComponent("mac/Library", isDirectory: true)
        let tabletLibrary = folder.appendingPathComponent("tablet/Library", isDirectory: true)
        let bytes = Data("Synthetic electricity invoice".utf8)
        let sha = DocumentCrypto.sha256(bytes)
        let path = EvidenceLibrary.storedRelativePath(sha256: sha, fileExtension: "pdf")
        let macFile = macLibrary.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: macFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: macFile)
        let h = try await memberTabletHousehold(memberDocuments: SyncDocumentFiles(root: tabletLibrary, policy: .lazy),
                                                macDocuments: SyncDocumentFiles(root: macLibrary, policy: .eager))
        let f = h.fixture
        let document = try write(h.adminMac) { db -> Int64 in
            try db.execute(sql: """
                INSERT INTO document(sha256, storedRelativePath, originalFileName, byteCount, addedAt) VALUES (?, ?, 'invoice.pdf', ?, ?)
                """, arguments: [sha, path, bytes.count, Date(timeIntervalSince1970: 1_790_000_000)])
            let id = db.lastInsertedRowID
            try db.execute(sql: "INSERT INTO documentLink(documentId, entityType, entityId, createdAt) VALUES (?, 'transaction', ?, ?)",
                           arguments: [id, f.sharedTransaction, Date(timeIntervalSince1970: 1_790_000_000)])
            return id
        }
        try await h.syncAll()
        let uuid = try h.uuid("document", document)
        let first = try await h.cloud.payload(named: uuid, keys: h.adminKeys)
        let reference = try XCTUnwrap(first?.documentFile, "sealed and uploaded by the Mac")
        let local = try XCTUnwrap(h.localId("document", uuid: uuid, on: h.memberDevice), "her iPad holds the document")
        XCTAssertFalse(FileManager.default.fileExists(atPath: tabletLibrary.appendingPathComponent(path).path), "its file never downloaded")
        let filesBefore = await h.cloud.storedRecords().filter { $0.recordType == SyncDocumentFile.recordType }.map(\.recordName)

        try write(h.memberDevice) { db in
            try db.execute(sql: "UPDATE document SET kind = ? WHERE id = ?", arguments: [DocumentKind.condominioReceipt.rawValue, local])
        }
        let report = try await h.memberDevice.engine.pushPending()

        XCTAssertEqual(report.saved, 1)
        XCTAssertEqual(report.documentsSealed, 0, "never uploaded again")
        let pushed = try await h.cloud.payload(named: uuid, keys: h.adminKeys)
        XCTAssertEqual(pushed?.fields["kind"], .string(DocumentKind.condominioReceipt.rawValue))
        XCTAssertEqual(pushed?.documentFile, reference, "the same file reference went")
        let filesAfter = await h.cloud.storedRecords().filter { $0.recordType == SyncDocumentFile.recordType }.map(\.recordName)
        XCTAssertEqual(filesAfter, filesBefore, "no file record added or removed")

        try await h.adminMac.engine.syncNow()
        let macReference = try read(h.adminMac) { db in try SyncDocumentFile.reference(uuid: uuid, db: db) }
        XCTAssertEqual(macReference, reference, "the Mac keeps the reference")
        XCTAssertEqual(try Data(contentsOf: macFile), bytes, "and the file")
        let macKind = try read(h.adminMac) { db in try String.fetchOne(db, sql: "SELECT kind FROM document WHERE id = ?", arguments: [document]) }
        XCTAssertEqual(macKind, DocumentKind.condominioReceipt.rawValue)
        assertAuditsClean(h)
    }

    /// A document whose file reference isn't known here and whose file isn't here either (none in this device's
    /// library): an iPad never sends it without one (the server's would be lost); it waits, still pending.
    func testDeviceWithoutFileOrReferenceWaits() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("device-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let macLibrary = folder.appendingPathComponent("mac/Library", isDirectory: true)
        let bytes = Data("Synthetic water invoice".utf8)
        let sha = DocumentCrypto.sha256(bytes)
        let path = EvidenceLibrary.storedRelativePath(sha256: sha, fileExtension: "pdf")
        try FileManager.default.createDirectory(at: macLibrary.appendingPathComponent(path).deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: macLibrary.appendingPathComponent(path))
        let h = try await memberTabletHousehold(memberDocuments: SyncDocumentFiles(root: folder.appendingPathComponent("tablet/Library"), policy: .lazy),
                                                macDocuments: SyncDocumentFiles(root: macLibrary, policy: .eager))
        let document = try write(h.adminMac) { db -> Int64 in
            try db.execute(sql: """
                INSERT INTO document(sha256, storedRelativePath, originalFileName, byteCount, addedAt) VALUES (?, ?, 'water.pdf', ?, ?)
                """, arguments: [sha, path, bytes.count, Date(timeIntervalSince1970: 1_790_000_000)])
            let id = db.lastInsertedRowID
            try db.execute(sql: "INSERT INTO documentLink(documentId, entityType, entityId, createdAt) VALUES (?, 'transaction', ?, ?)",
                           arguments: [id, h.fixture.sharedTransaction, Date(timeIntervalSince1970: 1_790_000_000)])
            return id
        }
        try await h.syncAll()
        let uuid = try h.uuid("document", document)
        let reference = try await h.cloud.payload(named: uuid, keys: h.adminKeys)?.documentFile
        XCTAssertNotNil(reference)
        let local = try XCTUnwrap(h.localId("document", uuid: uuid, on: h.memberDevice))
        let now = Date()
        try write(h.memberDevice) { db in
            try SyncDocumentFile.setReference(nil, uuid: uuid, db: db, now: now)
            try db.execute(sql: "UPDATE document SET kind = ? WHERE id = ?", arguments: [DocumentKind.condominioReceipt.rawValue, local])
        }

        let report = try await h.memberDevice.engine.pushPending()

        XCTAssertEqual(report.saved, 0)
        XCTAssertGreaterThan(report.documentsDeferred, 0, "it waits for its file reference")
        XCTAssertEqual(report.documentsSealed, 0)
        let server = try await h.cloud.payload(named: uuid, keys: h.adminKeys)
        XCTAssertEqual(server?.documentFile, reference, "the server's reference stays")
        XCTAssertTrue(try isPending(h.memberDevice, uuid))
        assertAuditsClean(h)
    }

    // MARK: Modes

    func testReadOnlyFlagStillMeansReadOnly() throws {
        let db = try TestDatabase.migrated()
        let cloud = FakeCloud()
        let make = { (readOnly: Bool, mode: SyncWriteMode?) in
            SyncEngineCore(db: db, transport: cloud, device: SyncDevice(id: "d", name: "D"), keyStore: InMemorySyncKeyStore(),
                           readOnly: readOnly, mode: mode)
        }
        XCTAssertEqual(make(true, nil).mode, .readOnly)
        XCTAssertTrue(make(true, nil).readOnly)
        XCTAssertEqual(make(false, nil).mode, .full)
        XCTAssertFalse(make(false, nil).readOnly)
        let device = make(false, .device(zones: [SyncZones.household]))
        XCTAssertEqual(device.mode, .device(zones: [SyncZones.household]))
        XCTAssertFalse(device.readOnly, "a device writes")
        XCTAssertEqual(make(true, .full).mode, .full, "the mode wins")
    }
}
