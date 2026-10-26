import XCTest
import GRDB
@testable import BudgetCore
import TestSupport

/// Step 7a Task 4: documents linked to nothing are placed by the rule (household for property documents, else their
/// inserter's private zone, else the admin's), and a full re-placement sweep queues every record whose placement
/// changed for any reason when what placement reads changed. Sync tests run over `TwoPersonHousehold` (the Macs
/// through `LossyTransport`) and end with every device's zone audit clean. Synthetic data only.
final class PlacementSweepTests: XCTestCase {
    private typealias Device = TwoPersonHousehold.Device

    private func read<T>(_ device: Device, _ body: (Database) throws -> T) throws -> T { try device.db.read(body) }
    private func write<T>(_ device: Device, _ body: (Database) throws -> T) throws -> T { try device.db.write(body) }

    private func count(_ device: Device, _ sql: String, _ arguments: StatementArguments = []) throws -> Int {
        try read(device) { db in try Int.fetchOne(db, sql: sql, arguments: arguments) ?? 0 }
    }

    /// Both Macs sync (twice, so each takes the other's work), then the phone and the member pull.
    private func syncEveryone(_ h: TwoPersonHousehold) async throws {
        for _ in 1...2 {
            _ = try await h.adminMac.engine.syncNow()
            _ = try await h.adminMac2.engine.syncNow()
        }
        _ = try await h.adminPhone.engine.pull()
        _ = try await h.memberDevice.engine.pull()
    }

    private func assertAuditsClean(_ h: TwoPersonHousehold, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(h.audit.householdViolations(router: h.adminRouter()), [], "Mac and phone", file: file, line: line)
        XCTAssertEqual(h.audit2.householdViolations(router: TwoPersonHousehold.router(h.adminMac2.db)), [], "Mac 2", file: file, line: line)
        XCTAssertEqual(h.memberAudit.householdViolations(router: TwoPersonHousehold.router(h.memberDevice.db)), [], "member", file: file, line: line)
    }

    /// Both Macs settled (nothing pending, no move unfinished, nothing needing attention); nothing staged elsewhere.
    private func assertSettled(_ h: TwoPersonHousehold, file: StaticString = #filePath, line: UInt = #line) throws {
        for (name, device) in [("Mac", h.adminMac), ("Mac 2", h.adminMac2)] {
            XCTAssertEqual(try count(device, "SELECT COUNT(*) FROM syncPending"), 0, "\(name): nothing pending", file: file, line: line)
            XCTAssertEqual(try read(device) { db in try SyncZoneMoves.unfinished(db: db) }, [], "\(name): no unfinished move", file: file, line: line)
            XCTAssertEqual(try count(device, "SELECT COUNT(*) FROM syncConflict WHERE losingValueJSON LIKE '%needs attention%'"), 0,
                           "\(name): nothing needs attention", file: file, line: line)
        }
        for (name, device) in [("phone", h.adminPhone), ("member", h.memberDevice)] {
            XCTAssertEqual(try count(device, "SELECT COUNT(*) FROM syncStaging"), 0, "\(name): nothing staged", file: file, line: line)
        }
    }

    /// The record `name` as the server holds it in `zone`.
    private func stored(_ h: TwoPersonHousehold, _ name: String, in zone: String) async throws -> SyncPayload? {
        guard let record = try await h.cloud.fetch(name, zone: zone) else { return nil }
        return try SyncLargePayload.payload(from: record.wire, keys: try h.adminKeys.allKeys(zone: zone))
    }

    /// The record left the household for A's zone: a marker over it in the household, its copy in A's zone, and the
    /// member no longer holds it.
    private func assertMovedToAdminZone(_ h: TwoPersonHousehold, _ table: String, _ uuid: String,
                                        file: StaticString = #filePath, line: UInt = #line) async throws {
        let marker = try await stored(h, uuid, in: SyncZones.household)
        XCTAssertEqual(marker?.movedTo, h.fixture.privateZone, "a marker in the household", file: file, line: line)
        let copy = try await stored(h, uuid, in: h.fixture.privateZone)
        XCTAssertNotNil(copy, "its copy in A's zone", file: file, line: line)
        XCTAssertNil(copy?.movedTo, file: file, line: line)
        XCTAssertNil(try h.localId(table, uuid: uuid, on: h.memberDevice), "the member dropped it", file: file, line: line)
        XCTAssertNotNil(try h.localId(table, uuid: uuid, on: h.adminPhone), "the admin's phone keeps it", file: file, line: line)
        XCTAssertNotNil(try h.localId(table, uuid: uuid, on: h.adminMac2), "the second Mac keeps it", file: file, line: line)
    }

    private func addDocument(_ db: Database, _ hash: String, kind: String = DocumentKind.other.rawValue, customKindId: Int64? = nil,
                             path: String? = nil, byteCount: Int = 1) throws -> Int64 {
        let sha = String(repeating: hash, count: 64)
        try db.execute(sql: """
            INSERT INTO document(sha256, storedRelativePath, originalFileName, byteCount, addedAt, kind, customKindId) VALUES (?, ?, 'synthetic.pdf', ?, ?, ?, ?)
            """, arguments: [sha, path ?? "aa/\(sha).pdf", byteCount, Date(timeIntervalSince1970: 1_790_000_000), kind, customKindId])
        return db.lastInsertedRowID
    }

    private func link(_ db: Database, _ document: Int64, _ type: String, _ entity: Int64) throws {
        try db.execute(sql: "INSERT INTO documentLink(documentId, entityType, entityId, createdAt) VALUES (?, ?, ?, ?)",
                       arguments: [document, type, entity, Date(timeIntervalSince1970: 1_790_000_000)])
    }

    // MARK: The rule

    func testUnlinkedNonPropertyDocumentIsPrivateToItsInserter() throws {
        let queue = try TestDatabase.migrated()
        try queue.write { db in
            let f = try SharingFixture.build(db)
            let adminUser = try SyncRecordStore.uuid(for: "appUser", localId: f.admin.appUserId, db: db)
            let member = try XCTUnwrap(try Int64.fetchOne(db, sql: "SELECT id FROM appUser WHERE personId = ?", arguments: [f.personB]))
            let memberUser = try SyncRecordStore.uuid(for: "appUser", localId: member, db: db)
            let memberZone = SyncZones.privateZone(personUuid: try SyncRecordStore.uuid(for: "person", localId: f.personB, db: db))

            try SyncChangeTracker.setWriter(adminUser, db: db)
            let admins = try addDocument(db, "a", kind: DocumentKind.p60.rawValue)
            try SyncChangeTracker.setWriter(memberUser, db: db)
            let hers = try addDocument(db, "b")
            try SyncChangeTracker.setWriter(nil, db: db)
            let nobodys = try addDocument(db, "c", kind: DocumentKind.bankStatement.rawValue)

            let router = try SyncZoneRouter(db: db)
            XCTAssertEqual(try router.assignment(table: "document", localId: admins), ZoneAssignment(zone: f.privateZone))
            XCTAssertEqual(try router.assignment(table: "document", localId: hers), ZoneAssignment(zone: memberZone), "her own: her zone")
            XCTAssertEqual(try router.assignment(table: "document", localId: nobodys), ZoneAssignment(zone: f.privateZone), "no inserter: the admin's")

            // Hers was in the household (as under step 6): the admin's Mac can't put it in her zone, so the sweep logs it
            // for attention and never queues it.
            let hersUuid = try SyncRecordStore.uuid(for: "document", localId: hers, db: db)
            try SyncPresence.add(uuid: hersUuid, zone: SyncZones.household, db: db)
            try db.execute(sql: "DELETE FROM syncPending")
            let misplaced = try SyncPlacementSweep.misplaced(zones: [SyncZones.household, f.privateZone], db: db).map(\.uuid)
            XCTAssertEqual(misplaced, [hersUuid], "returned although outside the zones")
            XCTAssertEqual(try SyncPlacementSweep.run(zones: [SyncZones.household, f.privateZone], db: db, now: Date()), 0)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM syncPending"), 0, "nothing queued")
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM syncConflict WHERE uuid = ? AND losingValueJSON LIKE ?",
                                            arguments: [hersUuid, "%" + SyncPlacementSweep.outsideZonesMessage + "%"]), 1)
        }
    }

    func testUnlinkedPropertyKindDocumentIsHousehold() throws {
        let queue = try TestDatabase.migrated()
        try queue.write { db in
            let f = try SharingFixture.build(db)
            let receipt = try addDocument(db, "a", kind: DocumentKind.rentReceipt.rawValue)
            let deed = try addDocument(db, "b", kind: DocumentKind.propertyDeed.rawValue)
            let letter = try addDocument(db, "c", kind: DocumentKind.hmrcLetter.rawValue)
            // Linked to the property: a referrer, household whatever its kind.
            let aboutTheFlat = try addDocument(db, "d", kind: DocumentKind.other.rawValue)
            try link(db, aboutTheFlat, "property", f.propertyId)
            let router = try SyncZoneRouter(db: db)
            XCTAssertEqual(try router.assignment(table: "document", localId: receipt), .household)
            XCTAssertEqual(try router.assignment(table: "document", localId: deed), .household)
            XCTAssertEqual(try router.assignment(table: "document", localId: letter), ZoneAssignment(zone: f.privateZone))
            XCTAssertEqual(try router.assignment(table: "document", localId: aboutTheFlat), .household)
        }
    }

    func testUnlinkedCustomPropertyKindDocumentIsHousehold() throws {
        let queue = try TestDatabase.migrated()
        try queue.write { db in
            let f = try SharingFixture.build(db)
            var flat = CustomDocumentKind(name: "Synthetic boiler service", area: .property)
            try flat.insert(db)
            var tax = CustomDocumentKind(name: "Synthetic tax note", area: .tax)
            try tax.insert(db)
            let service = try addDocument(db, "a", customKindId: flat.id)
            let note = try addDocument(db, "b", customKindId: tax.id)
            // The custom kind decides, not the built-in kind left on the row.
            let filedAsTax = try addDocument(db, "c", kind: DocumentKind.rentReceipt.rawValue, customKindId: tax.id)
            let router = try SyncZoneRouter(db: db)
            XCTAssertEqual(try router.assignment(table: "document", localId: service), .household)
            XCTAssertEqual(try router.assignment(table: "document", localId: note), ZoneAssignment(zone: f.privateZone))
            XCTAssertEqual(try router.assignment(table: "document", localId: filedAsTax), ZoneAssignment(zone: f.privateZone))

            // A custom kind moved to Property: its document goes with it.
            try db.execute(sql: "UPDATE customDocumentKind SET area = 'property' WHERE id = ?", arguments: [tax.id])
            XCTAssertEqual(try SyncZoneRouter(db: db).assignment(table: "document", localId: note), .household)
        }
    }

    func testGuardRefusesUnlinkedNonPropertyDocumentInHousehold() throws {
        let queue = try TestDatabase.migrated()
        try queue.write { db in
            let f = try SharingFixture.build(db)
            try SyncChangeTracker.setWriter(try SyncRecordStore.uuid(for: "appUser", localId: f.admin.appUserId, db: db), db: db)
            var flat = CustomDocumentKind(name: "Synthetic boiler service", area: .property)
            try flat.insert(db)
            let loose = try addDocument(db, "a")
            let receipt = try addDocument(db, "b", kind: DocumentKind.rentReceipt.rawValue)
            let service = try addDocument(db, "c", customKindId: flat.id)
            let linked = try addDocument(db, "d")
            try link(db, linked, "transaction", f.sharedTransaction)
            func household(_ id: Int64) throws -> SyncPayload {
                SyncPayload(recordType: "document", recordName: try SyncRecordStore.uuid(for: "document", localId: id, db: db),
                            zone: SyncZones.household, fields: ["kind": .string("other")])
            }
            let guardian = try SyncZoneGuard(db: db)
            XCTAssertThrowsError(try guardian.check([try household(loose)])) { error in
                XCTAssertEqual((error as? SyncZoneGuard.Violation)?.expected, f.privateZone, "the admin inserted it")
            }
            XCTAssertNoThrow(try guardian.check([try household(receipt)]))
            XCTAssertNoThrow(try guardian.check([try household(service)]))
            XCTAssertNoThrow(try guardian.check([try household(linked)]))
            // In its private zone it is fine.
            var own = try household(loose)
            own.zone = f.privateZone
            XCTAssertNoThrow(try guardian.check([own]))
        }
    }

    // MARK: The sweep

    func testDocumentLaterLinkedOnlyToPrivateRecordLeavesHousehold() async throws {
        let h = try TwoPersonHousehold.make()
        let f = h.fixture
        let document = try write(h.adminMac) { db -> Int64 in
            let id = try addDocument(db, "e")
            try link(db, id, "transaction", f.sharedTransaction)
            return id
        }
        let uuid = try h.uuid("document", document)
        try await syncEveryone(h)
        XCTAssertNotNil(try h.localId("document", uuid: uuid, on: h.memberDevice), "shared while linked to a shared record")

        try write(h.adminMac) { db in
            try db.execute(sql: "DELETE FROM documentLink WHERE documentId = ?", arguments: [document])
            try link(db, document, "transaction", f.privateTransaction)
        }
        try await syncEveryone(h)
        try await assertMovedToAdminZone(h, "document", uuid)
        try assertSettled(h)
        assertAuditsClean(h)
    }

    func testLostPinMovesTransactionOut() async throws {
        let h = try TwoPersonHousehold.make()
        let f = h.fixture
        let uuid = try h.uuid("transaction_", f.privatePinnedTransaction)
        try await syncEveryone(h)
        XCTAssertNotNil(try h.localId("transaction_", uuid: uuid, on: h.memberDevice), "pinned by a tax owner: property money")

        try write(h.adminMac) { db in try db.execute(sql: "DELETE FROM taxTransactionOwner WHERE id = ?", arguments: [f.taxTransactionOwner]) }
        try await syncEveryone(h)
        try await assertMovedToAdminZone(h, "transaction_", uuid)
        try assertSettled(h)
        assertAuditsClean(h)
    }

    func testCategoryMovedOutOfPropertyGroupMovesItsTransactionsOut() async throws {
        let h = try TwoPersonHousehold.make()
        let f = h.fixture
        let rent = try write(h.adminMac) { db -> Int64 in
            try db.execute(sql: """
                INSERT INTO transaction_(importBatchId, accountId, date, rawDescription, amountMinorUnits, categoryId, status, categorizedBy, fingerprint)
                VALUES (?, ?, ?, 'Synthetic rent', 70000, ?, 'confirmed', 'rule', 'fp-sweep')
                """, arguments: [f.privateBatch, f.privateAccount, Date(timeIntervalSince1970: 1_790_000_000), f.propertyCategory])
            return db.lastInsertedRowID
        }
        let uuid = try h.uuid("transaction_", rent)
        let pinned = try h.uuid("transaction_", f.privatePropertyTransaction)
        try await syncEveryone(h)
        XCTAssertNotNil(try h.localId("transaction_", uuid: uuid, on: h.memberDevice), "property money")

        try write(h.adminMac) { db in
            try db.execute(sql: "UPDATE category SET groupId = (SELECT groupId FROM category WHERE id = ?) WHERE id = ?",
                           arguments: [f.plainCategory, f.propertyCategory])
        }
        try await syncEveryone(h)
        try await assertMovedToAdminZone(h, "transaction_", uuid)
        XCTAssertNotNil(try h.localId("transaction_", uuid: pinned, on: h.memberDevice), "paid by a rent receipt: still property money")
        try assertSettled(h)
        assertAuditsClean(h)
    }

    // MARK: Review focus 2: the upgrade over live data

    private func fileRecords(_ h: TwoPersonHousehold, of uuid: String, in zone: String) async -> [String] {
        await h.cloud.storedRecords().filter { $0.zone == zone && $0.recordType == SyncDocumentFile.recordType && $0.recordName.hasPrefix(uuid) }
            .map(\.recordName).sorted()
    }

    /// Whether `device` opens the document's file from the server with `keys`, in `zone`.
    private func opensFile(_ h: TwoPersonHousehold, uuid: String, sha: String, on device: Device, keys: InMemorySyncKeyStore,
                           zone: String) async throws -> Bool {
        guard let reference = try read(device, { db in try SyncDocumentFile.reference(uuid: uuid, db: db) }),
              let record = try await h.cloud.fetch(reference.recordName, zone: zone),
              let ciphertext = record.wire.assets[SyncDocumentFile.assetField],
              let id = try? DocumentCrypto.zoneKeyId(ofWrapped: reference.wrappedKey),
              let key = try keys.allKeys(zone: zone)[id],
              let plaintext = try? DocumentCrypto.open(ciphertext, wrappedKey: reference.wrappedKey, zoneKey: key,
                                                      authenticating: DocumentCrypto.fileContext(table: "document", uuid: uuid, sha256: sha))
        else { return false }
        return DocumentCrypto.sha256(plaintext) == sha
    }

    /// A household synced under the step 6 rule (unlinked documents in the household, with their files, held by the
    /// member) upgrades: the first push sweeps (nothing stored yet) and moves the non-property one, and its file, to the
    /// admin's private zone, durably (the new copy's reply is lost once); the property one stays; the member drops the
    /// row and its file reference with nothing left staged; the admin's other devices open the file under A's key.
    func testSweepMovesUnlinkedNonPropertyDocumentOutAndMemberDropsIt() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("sweep-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let macLibrary = folder.appendingPathComponent("mac/Library", isDirectory: true)
        func file(_ text: String) throws -> (sha: String, path: String, size: Int) {
            let bytes = Data("Synthetic \(text) \(UUID().uuidString)".utf8)
            let sha = DocumentCrypto.sha256(bytes)
            let path = EvidenceLibrary.storedRelativePath(sha256: sha, fileExtension: "pdf")
            try FileManager.default.createDirectory(at: macLibrary.appendingPathComponent(path).deletingLastPathComponent(), withIntermediateDirectories: true)
            try bytes.write(to: macLibrary.appendingPathComponent(path))
            return (sha, path, bytes.count)
        }
        let looseFile = try file("letter")
        let deedFile = try file("deed")
        let h = try TwoPersonHousehold.make(macDocuments: SyncDocumentFiles(root: macLibrary, policy: .eager))
        let f = h.fixture
        let (loose, deed) = try write(h.adminMac) { db -> (Int64, Int64) in
            func insert(_ file: (sha: String, path: String, size: Int), kind: DocumentKind) throws -> Int64 {
                try db.execute(sql: """
                    INSERT INTO document(sha256, storedRelativePath, originalFileName, byteCount, addedAt, kind) VALUES (?, ?, 'synthetic.pdf', ?, ?, ?)
                    """, arguments: [file.sha, file.path, file.size, Date(timeIntervalSince1970: 1_790_000_000), kind.rawValue])
                return db.lastInsertedRowID
            }
            let loose = try insert(looseFile, kind: .other)
            let deed = try insert(deedFile, kind: .propertyDeed)
            for document in [loose, deed] { try link(db, document, "transaction", f.sharedTransaction) }
            return (loose, deed)
        }
        let looseUuid = try h.uuid("document", loose)
        let deedUuid = try h.uuid("document", deed)
        try await syncEveryone(h)

        // The step 6 build: the links go, the documents stay in the household (no sweep: its inputs as stored).
        try write(h.adminMac) { db in
            try db.execute(sql: "DELETE FROM documentLink WHERE documentId IN (?, ?)", arguments: [loose, deed])
            try SyncImportGate.setState(try SyncPlacementSweep.fingerprint(db: db), key: SyncPlacementSweep.fingerprintKey, db: db, now: Date())
        }
        _ = try await h.adminMac.engine.syncNow()
        _ = try await h.adminPhone.engine.pull()
        _ = try await h.memberDevice.engine.pull()
        let stillShared = try await stored(h, looseUuid, in: SyncZones.household)
        XCTAssertNotNil(stillShared?.fields["sha256"], "under step 6 the unlinked document is in the household")
        XCTAssertNotNil(try h.localId("document", uuid: looseUuid, on: h.memberDevice), "and the member holds it")
        XCTAssertNotNil(try read(h.memberDevice) { db in try SyncDocumentFile.reference(uuid: looseUuid, db: db) }, "with its file")
        XCTAssertEqual(try count(h.memberDevice, "SELECT COUNT(*) FROM documentLink"), 0)

        // The upgrade: nothing stored yet. The new copy's reply is lost on the first push (as if the Mac quit).
        try write(h.adminMac) { db in try db.execute(sql: "DELETE FROM syncState WHERE key = ?", arguments: [SyncPlacementSweep.fingerprintKey]) }
        h.macTransport.loseReply(to: looseUuid, in: f.privateZone)
        _ = try? await h.adminMac.engine.pushPending()
        try await syncEveryone(h)

        try await assertMovedToAdminZone(h, "document", looseUuid)
        let householdFiles = await fileRecords(h, of: looseUuid, in: SyncZones.household)
        XCTAssertEqual(householdFiles, [], "no file record left in the household")
        let privateFiles = await fileRecords(h, of: looseUuid, in: f.privateZone)
        XCTAssertEqual(privateFiles.count, 1, "exactly one, in A's zone")
        let copy = try await stored(h, looseUuid, in: f.privateZone)
        XCTAssertEqual(copy?.documentFile?.recordName, privateFiles.first, "A's copy names it")
        for device in [h.adminMac, h.adminMac2, h.adminPhone] {
            let opens = try await opensFile(h, uuid: looseUuid, sha: looseFile.sha, on: device, keys: h.adminKeys, zone: f.privateZone)
            XCTAssertTrue(opens, "the admin's devices open it under A's key")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: macLibrary.appendingPathComponent(looseFile.path).path), "the Mac's file is kept")
        XCTAssertNil(try read(h.memberDevice) { db in try SyncDocumentFile.reference(uuid: looseUuid, db: db) }, "her file reference went with the row")

        // The property document stays shared, file and all.
        let deedCopy = try await stored(h, deedUuid, in: SyncZones.household)
        XCTAssertNil(deedCopy?.movedTo)
        XCTAssertNotNil(try h.localId("document", uuid: deedUuid, on: h.memberDevice))
        let memberOpensDeed = try await opensFile(h, uuid: deedUuid, sha: deedFile.sha, on: h.memberDevice, keys: h.memberKeys, zone: SyncZones.household)
        XCTAssertTrue(memberOpensDeed)
        try assertSettled(h)
        assertAuditsClean(h)
    }

    func testUnchangedInputsRouteNothing() async throws {
        let h = try TwoPersonHousehold.make()
        try await syncEveryone(h)
        for device in [h.adminMac, h.adminMac2, h.memberDevice] { _ = try await device.engine.syncNow() }
        let routings = SyncPlacementSweep.routings.withLock { $0 }
        for _ in 1...3 {
            _ = try await h.adminMac.engine.syncNow()
            _ = try await h.adminMac2.engine.syncNow()
            _ = try await h.memberDevice.engine.syncNow()
        }
        XCTAssertEqual(SyncPlacementSweep.routings.withLock { $0 }, routings, "no push routed anything")
        let started = Date()
        let queued = try write(h.adminMac) { db in try SyncPlacementSweep.run(zones: [SyncZones.household, h.fixture.privateZone], db: db, now: Date()) }
        let seconds = Date().timeIntervalSince(started)
        print("PlacementSweepTests: one unchanged sweep check \(String(format: "%.4f", seconds)) s")
        XCTAssertEqual(queued, 0)
        XCTAssertEqual(SyncPlacementSweep.routings.withLock { $0 }, routings)
        XCTAssertLessThan(seconds, 0.05)

        // A changed input routes once.
        try write(h.adminMac) { db in
            let document = try addDocument(db, "f")
            try link(db, document, "transaction", h.fixture.sharedTransaction)
        }
        _ = try await h.adminMac.engine.syncNow()
        XCTAssertEqual(SyncPlacementSweep.routings.withLock { $0 }, routings + 1)
        try assertSettled(h)
    }
}
