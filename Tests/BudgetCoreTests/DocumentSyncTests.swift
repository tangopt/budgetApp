import XCTest
import GRDB
import CryptoKit
@testable import BudgetCore
import TestSupport

/// A device whose engine syncs evidence files (plan Task 7): its own database and its own evidence library
/// in a temporary folder (never the real Evidence folder), syncing through `transport`.
final class DocumentSyncTestDevice {
    let manager: DatabaseManager
    let root: URL
    let inbox: URL
    let library: EvidenceLibrary
    let engine: SyncEngineCore
    let keys: any SyncKeyStore
    var queue: DatabaseQueue { manager.dbQueue }

    init(_ user: String, transport: any SyncTransport, keys: any SyncKeyStore, policy: SyncDocumentFiles.Policy? = .eager) throws {
        manager = try TestDatabase.migratedManager()
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("DocumentSyncTests-\(UUID().uuidString)", isDirectory: true)
        root = base.appendingPathComponent("Evidence", isDirectory: true)
        inbox = base.appendingPathComponent("Inbox", isDirectory: true)
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        library = EvidenceLibrary(root: root, database: manager.dbQueue)
        try manager.dbQueue.write { db in try SyncChangeTracker.setWriter(user, db: db) }
        self.keys = keys
        engine = SyncEngineCore(db: manager.dbQueue, transport: transport, device: SyncDevice(id: "device-\(user)", name: user), keyStore: keys,
                                documents: policy.map { [root] in SyncDocumentFiles(root: root, policy: $0) })
    }

    deinit { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }

    func read<T>(_ body: (Database) throws -> T) throws -> T { try queue.read(body) }
    func write<T>(_ body: (Database) throws -> T) throws -> T { try queue.write(body) }

    /// Adds a synthetic file to the library; returns the document and its record UUID.
    func add(_ name: String, _ bytes: Data) throws -> (EvidenceDocument, String) {
        let url = inbox.appendingPathComponent(name)
        try bytes.write(to: url)
        let document = try library.add(url).document
        let uuid = try queue.read { db in try XCTUnwrap(SyncRecordStore.existingUUID(table: "document", localId: document.id!, db: db)) }
        return (document, uuid)
    }

    func document(uuid: String) throws -> EvidenceDocument? {
        try queue.read { db in
            guard let id = try SyncRecordStore.localId(table: "document", uuid: uuid, db: db) else { return nil }
            return try EvidenceDocument.fetchOne(db, key: id)
        }
    }

    /// The library file of the document `uuid` here, if it is there.
    func file(uuid: String) throws -> Data? {
        guard let document = try document(uuid: uuid) else { return nil }
        return try? Data(contentsOf: library.fileURL(for: document))
    }

    func conflicts(uuid: String) throws -> [SyncConflictRow] {
        try queue.read { db in try SyncConflictRow.filter(Column("uuid") == uuid).fetchAll(db) }
    }
}

/// Sees the zone key record as missing once, then lets `beforeAnswer` run (another device creating it)
/// before answering: the creation race of two devices that both found no zone key.
final class ZoneKeyRaceTransport: SyncTransport, @unchecked Sendable {
    let cloud: FakeCloud
    private let lock = NSLock()
    private var beforeAnswer: (@Sendable () async throws -> Void)?

    init(cloud: FakeCloud, beforeAnswer: @escaping @Sendable () async throws -> Void) {
        self.cloud = cloud
        self.beforeAnswer = beforeAnswer
    }

    private func takeHook() -> (@Sendable () async throws -> Void)? {
        lock.lock()
        defer { lock.unlock() }
        let hook = beforeAnswer
        beforeAnswer = nil
        return hook
    }

    func operationLimits() async -> SyncOperationLimits { await cloud.operationLimits() }
    func createZone(_ zone: String) async throws { try await cloud.createZone(zone) }
    func save(_ records: [SyncWireRecord], ifUnchanged: [String: Data], atomic: Bool) async throws -> [SaveResult] {
        try await cloud.save(records, ifUnchanged: ifUnchanged, atomic: atomic)
    }
    func changes(since token: Data?, zone: String) async throws -> SyncChanges { try await cloud.changes(since: token, zone: zone) }
    func delete(_ recordNames: [String], zone: String) async throws { try await cloud.delete(recordNames, zone: zone) }
    func fetch(_ recordName: String, zone: String) async throws -> SyncServerRecord? {
        let answer = try await cloud.fetch(recordName, zone: zone)
        if recordName == SyncZoneKeys.recordName(zone: zone), let hook = takeHook() { try await hook() }
        return answer
    }
    func serverTime() async throws -> Date? { try await cloud.serverTime() }
}

/// Evidence files through sync (sync spec §4.2, §5.7, §9.1): sealed per document under a random data key,
/// the data key wrapped with the zone key (in the key store, iCloud Keychain; the zone's `zoneKey` record is only
/// a marker naming it, ruling R15), the asset only ciphertext;
/// downloaded and checked against the record's SHA-256 on the way in; zone key rotation re-wraps without
/// re-uploading files. Synthetic files only.
final class DocumentSyncTests: XCTestCase {
    private var cloud: FakeCloud!
    private var keys: InMemorySyncKeyStore!
    private var a: DocumentSyncTestDevice!
    private var b: DocumentSyncTestDevice!
    private let zone = SyncRecordStore.householdZone

    override func setUp() async throws {
        cloud = FakeCloud()
        keys = InMemorySyncKeyStore()
        a = try DocumentSyncTestDevice("user-a", transport: cloud, keys: keys)
        b = try DocumentSyncTestDevice("user-b", transport: cloud, keys: keys)
    }

    private static func bytes(_ marker: String) -> Data {
        Data("Synthetic invoice \(marker) — amount 98.76 — never real".utf8) + Data((0..<8192).map { UInt8(($0 * 7) % 253) })
    }

    private func stored(type: String) async -> [SyncWireRecord] {
        await cloud.storedRecords().filter { $0.recordType == type }
    }

    private func documentPayload(_ uuid: String) async throws -> SyncPayload {
        let awaited1 = try await cloud.payload(named: uuid, keys: keys)
        return try XCTUnwrap(awaited1)
    }

    /// The zone's marker on the server, and the key it names (from the shared key store).
    private func zoneKeys() async throws -> (marker: SyncZoneKeys.Marker, key: SymmetricKey) {
        let awaited2 = await stored(type: SyncZoneKeys.recordType).first
        let marker = try SyncZoneKeys.marker(from: try XCTUnwrap(awaited2))
        return (marker, try XCTUnwrap(try keys.allKeys(zone: zone)[marker.keyId]))
    }

    private func fileSaves(since index: Int) async -> [String] {
        let calls = await cloud.calls
        return calls.dropFirst(index).flatMap { call -> [String] in
            if case .save(let names, _) = call { return names } else { return [] }
        }
    }

    // MARK: §9.1 through the engine

    func testUploadedAssetNeverContainsThePlaintext() async throws {
        let plaintext = Self.bytes("upload")
        let (_, uuid) = try a.add("invoice.pdf", plaintext)
        let report = try await a.engine.syncNow()
        XCTAssertEqual(report.push.documentsSealed, 1)

        let files = await stored(type: SyncDocumentFile.recordType)
        XCTAssertEqual(files.count, 1)
        let all = await cloud.storedRecords()
        let window = plaintext.prefix(24)
        for record in all {
            for (field, data) in record.assets {
                XCTAssertNil(data.range(of: window), "asset \(record.recordType).\(field) holds plaintext")
                XCTAssertNil(data.range(of: plaintext.suffix(24)), "asset \(record.recordType).\(field) holds plaintext")
            }
            for (field, data) in record.encryptedFields {
                XCTAssertNil(data.range(of: window), "\(record.recordType).\(field) holds the file")
            }
            XCTAssertTrue(record.unencryptedFields.isEmpty)
        }
        let unencrypted = await cloud.unencryptedFieldNames
        XCTAssertTrue(unencrypted.isEmpty)
        // The asset is exactly the ciphertext the document record's wrapped key opens.
        let payload = try await documentPayload(uuid)
        let reference = try XCTUnwrap(payload.documentFile)
        XCTAssertEqual(reference.recordName, files[0].recordName)
        let opened = try DocumentCrypto.open(try XCTUnwrap(files[0].assets[SyncDocumentFile.assetField]), wrappedKey: reference.wrappedKey,
                                             zoneKey: try XCTUnwrap(try self.keys.allKeys(zone: zone)[try DocumentCrypto.zoneKeyId(ofWrapped: reference.wrappedKey)]),
                                             authenticating: DocumentCrypto.documentContext(uuid: uuid, sha256: DocumentCrypto.sha256(plaintext)))
        XCTAssertEqual(opened, plaintext)
    }

    func testTheZoneKeyRecordIsOneMarkerWithoutKeyMaterial() async throws {
        _ = try a.add("one.pdf", Self.bytes("one"))
        try await a.engine.syncNow()
        _ = try b.add("two.pdf", Self.bytes("two"))
        try await b.engine.syncNow()
        try await a.engine.syncNow()

        let keyRecords = await stored(type: SyncZoneKeys.recordType)
        XCTAssertEqual(keyRecords.map(\.recordName), [SyncZoneKeys.recordName(zone: zone)])
        XCTAssertEqual(keyRecords.first?.zone, zone)
        XCTAssertTrue(keyRecords.first?.unencryptedFields.isEmpty ?? false)
        XCTAssertTrue(keyRecords.first?.assets.isEmpty ?? false)
        // Ruling R15: the record names the key (its id and creation time) and holds nothing of it.
        let record = try XCTUnwrap(keyRecords.first)
        XCTAssertEqual(Set(record.encryptedFields.keys), ["keyId", "createdAt"])
        let current = try await zoneKeys()
        XCTAssertEqual(record.encryptedFields["keyId"], Data(current.marker.keyId.utf8))
        let keyBytes = current.key.withUnsafeBytes { Data($0) }
        for data in record.encryptedFields.values { XCTAssertNil(data.range(of: keyBytes.prefix(8)), "no key material") }
        XCTAssertEqual(try keys.allKeys(zone: zone).count, 1, "one key, shared through the key store")
        // Both devices sealed under the same zone key.
        let awaited3 = await stored(type: SyncDocumentFile.recordType).count
        XCTAssertEqual(awaited3, 2)
        for record in await stored(type: "document") {
            XCTAssertEqual(FieldSealing.keyId(of: record), current.marker.keyId)
            let reference = try XCTUnwrap(try SyncLargePayload.payload(from: record, keys: keys.allKeys(zone: zone)).documentFile)
            XCTAssertEqual(try DocumentCrypto.zoneKeyId(ofWrapped: reference.wrappedKey), current.marker.keyId)
        }
    }

    /// Final review I2: a damaged zone key marker never rolls back a pull. It is staged as unreadable (with its
    /// type), the local marker stays (no longer taken as confirmed), the token moves on, the rest applies; a good
    /// version later is adopted.
    func testADamagedZoneKeyRecordDoesntBlockThePull() async throws {
        _ = try a.add("one.pdf", Self.bytes("one"))
        try await a.engine.syncNow()
        try await b.engine.syncNow()
        let good = try await zoneKeys().marker
        let keyName = SyncZoneKeys.recordName(zone: zone)
        let held = try b.read { db in try SyncZoneKeys.local(zone: zone, db: db)?.marker }
        XCTAssertEqual(held, good)

        // Sent before the marker is damaged (step 15: a push reads the server's marker first and waits on a damaged one).
        let (_, other) = try a.add("two.pdf", Self.bytes("two"))
        try await a.engine.pushPending()
        // Another build (or corruption) writes a marker that isn't readable here.
        let awaitedServer = await cloud.record(named: keyName)
        let server = try XCTUnwrap(awaitedServer)
        let damaged = SyncWireRecord(recordType: SyncZoneKeys.recordType, recordName: keyName, zone: zone,
                                     encryptedFields: ["keyId": Data("not a key id".utf8), "createdAt": Data(count: 8)])
        let saved = try await cloud.save([damaged], ifUnchanged: [keyName: server.stamp.systemFields], atomic: false)
        guard case .saved = saved.first?.outcome else { return XCTFail("damaged version saved") }

        let pulled = try await b.engine.pull()
        XCTAssertEqual(pulled.unreadable, 1)
        XCTAssertNotNil(try b.document(uuid: other), "the rest of the pull applied")
        try b.read { db in
            XCTAssertEqual(try SyncZoneKeys.local(zone: zone, db: db)?.marker, good, "the local marker stays")
            XCTAssertNil(try SyncZoneKeys.local(zone: zone, db: db)?.systemFields, "the next push asks the server again")
            let staged = try XCTUnwrap(try SyncStagingRow.filter(Column("uuid") == keyName).fetchOne(db))
            XCTAssertEqual(staged.tableName, SyncZoneKeys.recordType)
            XCTAssertTrue(staged.reason.hasPrefix(SyncTranslator.needsAttention))
        }
        // The token moved on: the next pull doesn't meet the damaged version again.
        let again = try await b.engine.pull()
        XCTAssertEqual(again.unreadable, 0)
        XCTAssertEqual(again.received, 0)

        // A good version later is adopted, and the attention row goes.
        let awaitedDamaged = await cloud.record(named: keyName)
        let current = try XCTUnwrap(awaitedDamaged)
        _ = try await cloud.save([SyncZoneKeys.wire(good, zone: zone)], ifUnchanged: [keyName: current.stamp.systemFields], atomic: false)
        let fixed = try await b.engine.pull()
        XCTAssertEqual(fixed.unreadable, 0)
        try b.read { db in
            XCTAssertEqual(try SyncZoneKeys.local(zone: zone, db: db)?.marker, good)
            XCTAssertNotNil(try SyncZoneKeys.local(zone: zone, db: db)?.systemFields)
            XCTAssertEqual(try SyncStagingRow.filter(Column("uuid") == keyName).fetchCount(db), 0)
        }
    }

    /// Security review finding 1: a marker whose `createdAt` bits aren't a finite number (NaN, an infinity) is
    /// unreadable like any other damaged marker: staged, the pull applies the rest and its token moves on, and the
    /// push waits (`keyWait`) instead of throwing. Nothing else about the marker can roll the pull back.
    func testAMarkerWithANonFiniteCreationTimeIsStagedAndNeverRollsBackOrThrows() async throws {
        _ = try a.add("one.pdf", Self.bytes("one"))
        try await a.engine.syncNow()
        try await b.engine.syncNow()
        let good = try await zoneKeys().marker
        let keyName = SyncZoneKeys.recordName(zone: zone)

        // Sent before the marker is damaged (step 15: a push reads the server's marker first and waits on a damaged one).
        let (_, other) = try a.add("two.pdf", Self.bytes("two"))
        try await a.engine.pushPending()
        // A valid key id with a NaN creation time (0x7ff8000000000000): a Date JSONEncoder refuses.
        let awaitedServer = await cloud.record(named: keyName)
        let server = try XCTUnwrap(awaitedServer)
        let nan = SyncWireRecord(recordType: SyncZoneKeys.recordType, recordName: keyName, zone: zone,
                                 encryptedFields: ["keyId": Data(good.keyId.utf8), "createdAt": Data([0x7f, 0xf8, 0, 0, 0, 0, 0, 0])])
        let saved = try await cloud.save([nan], ifUnchanged: [keyName: server.stamp.systemFields], atomic: false)
        guard case .saved = saved.first?.outcome else { return XCTFail("damaged version saved") }

        let pulled = try await b.engine.pull()
        XCTAssertEqual(pulled.unreadable, 1)
        XCTAssertNotNil(try b.document(uuid: other), "the rest of the pull applied")
        try b.read { db in
            XCTAssertEqual(try SyncZoneKeys.local(zone: zone, db: db)?.marker, good, "the local marker stays")
            XCTAssertNil(try SyncZoneKeys.local(zone: zone, db: db)?.systemFields, "the next push asks the server again")
            XCTAssertEqual(try SyncStagingRow.filter(Column("uuid") == keyName).fetchCount(db), 1)
        }
        let again = try await b.engine.pull()
        XCTAssertEqual(again.unreadable, 0, "the token moved on")
        XCTAssertEqual(again.received, 0)

        // The push asks the server again, meets the damaged marker, and waits rather than throwing.
        let (_, uuid) = try b.add("three.pdf", Self.bytes("three"))
        let report = try await b.engine.pushPending()
        XCTAssertEqual(report.keyWait, .unavailable)
        XCTAssertEqual(report.saved, 0)
        let pending = try b.read { db in try SyncChangeTracker.pending(db: db).map(\.uuid) }
        XCTAssertTrue(pending.contains(uuid), "it waits, still pending")
        let awaitedKeys = await stored(type: SyncZoneKeys.recordType)
        XCTAssertEqual(awaitedKeys.first?.encryptedFields, nan.encryptedFields, "never replaced from here")

        // Infinity is refused the same way by the parser itself.
        let inf = SyncWireRecord(recordType: SyncZoneKeys.recordType, recordName: keyName, zone: zone,
                                 encryptedFields: ["keyId": Data(good.keyId.utf8), "createdAt": Data([0xff, 0xf0, 0, 0, 0, 0, 0, 0])])
        XCTAssertThrowsError(try SyncZoneKeys.marker(from: inf)) { error in
            guard case SyncTransportError.unreadableRecord(let name) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(name, keyName)
        }
    }

    /// Final review I2: a push that needs the zone key while the server's marker is unreadable waits (ruling R15:
    /// every record is sealed under the key the marker names) instead of failing, and never replaces the marker.
    func testADamagedZoneKeyMarkerMakesThePushWaitInsteadOfFailing() async throws {
        let keyName = SyncZoneKeys.recordName(zone: zone)
        try await a.engine.pull()
        let damaged = ["keyId": Data("not a key id".utf8), "createdAt": Data(count: 8)]
        _ = try await cloud.save([SyncWireRecord(recordType: SyncZoneKeys.recordType, recordName: keyName, zone: zone,
                                                 encryptedFields: damaged)], ifUnchanged: [:], atomic: false)
        let (_, uuid) = try a.add("later.pdf", Self.bytes("later"))
        let report = try await a.engine.pushPending()
        XCTAssertEqual(report.keyWait, .unavailable)
        XCTAssertEqual(report.saved, 0)
        XCTAssertEqual(report.documentsSealed, 0)
        let pending = try a.read { db in try SyncChangeTracker.pending(db: db).map(\.uuid) }
        XCTAssertTrue(pending.contains(uuid), "it waits, still pending")
        let awaitedKeys = await stored(type: SyncZoneKeys.recordType)
        XCTAssertEqual(awaitedKeys.first?.encryptedFields, damaged, "never replaced from here")
        XCTAssertEqual(try keys.allKeys(zone: zone).count, 0, "no key made while a marker exists")
    }

    func testDocumentArrivesOnTheMacDecryptedWithItsHashUnchanged() async throws {
        let plaintext = Self.bytes("arrives")
        let (document, uuid) = try a.add("rent.pdf", plaintext)
        try await a.engine.syncNow()
        let pulled = try await b.engine.syncNow()

        XCTAssertEqual(pulled.pull.documentsDownloaded, 1)
        let arrived = try XCTUnwrap(try b.document(uuid: uuid))
        XCTAssertEqual(arrived.sha256, document.sha256, "the evidence hash is unchanged")
        XCTAssertEqual(arrived.sha256, DocumentCrypto.sha256(plaintext))
        XCTAssertEqual(arrived.storedRelativePath, document.storedRelativePath)
        XCTAssertEqual(try b.file(uuid: uuid), plaintext, "kept on the Mac, decrypted into the library")
        XCTAssertEqual(try EvidenceLibrary.sha256(of: b.library.fileURL(for: arrived)), document.sha256)

        // Already there: the next pull fetches nothing.
        let calls = await cloud.calls.count
        let again = try await b.engine.syncNow()
        XCTAssertEqual(again.pull.documentsDownloaded, 0)
        let fetched = await cloud.calls.dropFirst(calls).contains { if case .fetch = $0 { return true } else { return false } }
        XCTAssertFalse(fetched)
    }

    func testLazyDeviceDownloadsWhenOpened() async throws {
        let phone = try DocumentSyncTestDevice("user-b", transport: cloud, keys: keys, policy: .lazy)
        let plaintext = Self.bytes("lazy")
        let (_, uuid) = try a.add("bill.pdf", plaintext)
        try await a.engine.syncNow()
        let pulled = try await phone.engine.syncNow()

        XCTAssertEqual(pulled.pull.documentsDownloaded, 0)
        XCTAssertNotNil(try phone.document(uuid: uuid))
        XCTAssertNil(try phone.file(uuid: uuid), "not downloaded until opened")

        let url = try await phone.engine.downloadDocument(uuid: uuid)
        XCTAssertEqual(try Data(contentsOf: url), plaintext)
        XCTAssertEqual(try phone.file(uuid: uuid), plaintext)
    }

    /// The iPad's Documents screen opens a document by its stored path (step 8 Task 5): that path names the document's
    /// record, whose file is then downloaded into the library.
    func testLazyDeviceFindsTheDocumentByItsStoredPath() async throws {
        let phone = try DocumentSyncTestDevice("user-b", transport: cloud, keys: keys, policy: .lazy)
        let (document, uuid) = try a.add("lease.pdf", Self.bytes("by path"))
        try await a.engine.syncNow()
        try await phone.engine.syncNow()

        try await phone.queue.read { db in
            XCTAssertEqual(try SyncFileTables.documentUUID(storedRelativePath: document.storedRelativePath, db: db), uuid)
            XCTAssertNil(try SyncFileTables.documentUUID(storedRelativePath: "00/missing.pdf", db: db))
        }
        let url = try await phone.engine.downloadDocument(uuid: uuid)
        XCTAssertEqual(try Data(contentsOf: url), Self.bytes("by path"))
        XCTAssertTrue(url.path.hasPrefix(phone.root.path), "decrypted into the library only")
    }

    func testDownloadWhoseBytesDontMatchTheHashNeedsAttentionAndIsNeverWritten() async throws {
        let (_, uuid) = try a.add("statement.pdf", Self.bytes("genuine"))
        try await a.engine.syncNow()

        // Another writer (a bug, or tampering by someone holding the zone key) replaces the file with other
        // bytes, sealed correctly for this document: decryption succeeds, the hash doesn't match.
        let current = try await zoneKeys()
        let awaited4 = await cloud.record(named: uuid)
        let server = try XCTUnwrap(awaited4)
        var payload = try SyncLargePayload.payload(from: server.wire, keys: keys.allKeys(zone: zone))
        guard case .string(let sha) = payload.fields["sha256"] else { return XCTFail("no hash") }
        let other = Self.bytes("substituted")
        let sealed = try DocumentCrypto.seal(other, zoneKey: current.key, authenticating: DocumentCrypto.documentContext(uuid: uuid, sha256: sha))
        let fileRecord = SyncWireRecord(recordType: SyncDocumentFile.recordType, recordName: "substitute", zone: zone,
                                        assets: [SyncDocumentFile.assetField: sealed.ciphertext])
        _ = try await cloud.save([fileRecord], ifUnchanged: [:], atomic: false)
        payload.documentFile = SyncDocumentFileReference(recordName: "substitute", wrappedKey: sealed.wrappedKey)
        let results = try await cloud.save([try SyncLargePayload.wire(for: payload, key: current.key).0], ifUnchanged: [uuid: server.stamp.systemFields],
                                           atomic: false)
        guard case .saved = results.first?.outcome else { return XCTFail("tampered save refused") }

        let pulled = try await b.engine.syncNow()
        XCTAssertEqual(pulled.pull.documentsDownloaded, 0)
        XCTAssertEqual(pulled.pull.documentsNeedingAttention, 1)
        XCTAssertNotNil(try b.document(uuid: uuid), "the record applies")
        XCTAssertNil(try b.file(uuid: uuid), "a file whose hash doesn't match is never written")
        let logged = try b.conflicts(uuid: uuid)
        XCTAssertTrue(logged.contains { $0.field == SyncDocumentFile.conflictField && $0.losingValueJSON.contains("needs attention") }, "\(logged)")
        let leftovers = (try? FileManager.default.subpathsOfDirectory(atPath: b.root.path)) ?? []
        XCTAssertFalse(leftovers.contains { $0.hasSuffix(".pdf") || $0.contains(EvidenceLibrary.temporaryPrefix) }, "\(leftovers)")

        // The lazy path refuses the same way.
        do {
            _ = try await b.engine.downloadDocument(uuid: uuid)
            XCTFail("a mismatching file was accepted")
        } catch let error as SyncDocumentError {
            XCTAssertEqual(error, .hashMismatch)
        }
        XCTAssertNil(try b.file(uuid: uuid))
    }

    func testDamagedCiphertextNeedsAttentionAndIsNeverWritten() async throws {
        let (_, uuid) = try a.add("damaged.pdf", Self.bytes("damaged"))
        try await a.engine.syncNow()
        let awaited5 = await stored(type: SyncDocumentFile.recordType).first
        let file = try XCTUnwrap(awaited5)
        await cloud.corruptAsset(of: file.recordName, field: SyncDocumentFile.assetField)

        let pulled = try await b.engine.syncNow()
        XCTAssertEqual(pulled.pull.documentsNeedingAttention, 1)
        XCTAssertNil(try b.file(uuid: uuid))
        XCTAssertTrue(try b.conflicts(uuid: uuid).contains { $0.field == SyncDocumentFile.conflictField })
    }

    func testSenderNeverUploadsAFileThatDoesntMatchItsHash() async throws {
        let (document, uuid) = try a.add("changed.pdf", Self.bytes("before"))
        // The library copy is damaged on disk after it was added.
        try Self.bytes("after").write(to: a.library.fileURL(for: document))
        let report = try await a.engine.syncNow()

        XCTAssertEqual(report.push.documentsSealed, 0)
        let files = await stored(type: SyncDocumentFile.recordType)
        XCTAssertTrue(files.isEmpty)
        let awaited6 = try await documentPayload(uuid).documentFile
        XCTAssertNil(awaited6)
        XCTAssertTrue(try a.conflicts(uuid: uuid).contains { $0.field == SyncDocumentFile.conflictField })
    }

    func testMetadataEditDoesntUploadTheFileAgain() async throws {
        let (document, uuid) = try a.add("note.pdf", Self.bytes("note"))
        try await a.engine.syncNow()
        let before = try await documentPayload(uuid).documentFile
        let mark = await cloud.calls.count
        try a.write { db in try db.execute(sql: "UPDATE document SET note = 'Synthetic note' WHERE id = ?", arguments: [document.id!]) }
        let report = try await a.engine.syncNow()

        XCTAssertEqual(report.push.saved, 1)
        XCTAssertEqual(report.push.documentsSealed, 0)
        let awaited7 = await fileSaves(since: mark)
        XCTAssertEqual(awaited7, [uuid], "only the document record")
        let awaited8 = try await documentPayload(uuid).documentFile
        XCTAssertEqual(awaited8, before, "the record keeps its file and wrapped key")
        // An edit on the other device keeps them too.
        try await b.engine.syncNow()
        try b.write { db in
            let id = try XCTUnwrap(SyncRecordStore.localId(table: "document", uuid: uuid, db: db))
            try db.execute(sql: "UPDATE document SET note = 'Edited elsewhere' WHERE id = ?", arguments: [id])
        }
        try await b.engine.syncNow()
        let awaited9 = try await documentPayload(uuid).documentFile
        XCTAssertEqual(awaited9, before)
    }

    func testADeviceThatDoesntSyncFilesKeepsTheFileReferenceWhenItEdits() async throws {
        let (_, uuid) = try a.add("kept.pdf", Self.bytes("kept"))
        try await a.engine.syncNow()
        let before = try await documentPayload(uuid).documentFile
        XCTAssertNotNil(before)
        let other = try DocumentSyncTestDevice("user-c", transport: cloud, keys: keys, policy: nil)
        try await other.engine.syncNow()
        try other.write { db in
            let id = try XCTUnwrap(SyncRecordStore.localId(table: "document", uuid: uuid, db: db))
            try db.execute(sql: "UPDATE document SET note = 'From a device without files' WHERE id = ?", arguments: [id])
        }
        try await other.engine.syncNow()
        let after = try await documentPayload(uuid)
        XCTAssertEqual(after.fields["note"], .string("From a device without files"))
        XCTAssertEqual(after.documentFile, before)
        XCTAssertNil(try other.file(uuid: uuid))
    }

    func testACrashLeftoverIsRemovedAndAStaleCopyReplacedByTheNextDownload() async throws {
        let phone = try DocumentSyncTestDevice("user-b", transport: cloud, keys: keys, policy: .lazy)
        let plaintext = Self.bytes("crash")
        let (document, uuid) = try a.add("crash.pdf", plaintext)
        try await a.engine.syncNow()
        try await phone.engine.syncNow()

        // A download interrupted by a crash two hours ago left its decrypted temporary copy; one in progress
        // now is left alone. A wrong copy sits where the file goes.
        try FileManager.default.createDirectory(at: phone.root, withIntermediateDirectories: true)
        let stale = phone.root.appendingPathComponent("\(EvidenceLibrary.temporaryPrefix)\(Int(Date().timeIntervalSince1970) - 7200)-crash")
        let fresh = phone.root.appendingPathComponent("\(EvidenceLibrary.temporaryPrefix)\(Int(Date().timeIntervalSince1970))-busy")
        try plaintext.write(to: stale)
        try plaintext.write(to: fresh)
        let destination = phone.root.appendingPathComponent(document.storedRelativePath)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.bytes("wrong").write(to: destination)

        let url = try await phone.engine.downloadDocument(uuid: uuid)
        XCTAssertEqual(try Data(contentsOf: url), plaintext)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path), "the crash leftover is removed")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.path), "a copy in progress is left alone")
        let temporaries = try FileManager.default.contentsOfDirectory(atPath: phone.root.path).filter { $0.hasPrefix(EvidenceLibrary.temporaryPrefix) }
        XCTAssertEqual(temporaries, [fresh.lastPathComponent], "the download's own temporary copy is gone")

        // The same content already in place counts as downloaded.
        let again = try await phone.engine.downloadDocument(uuid: uuid)
        XCTAssertEqual(again, url)
    }

    func testAZoneKeyMarkerIsExactlyAKeyIdAndACreationTime() throws {
        let marker = SyncZoneKeys.Marker(keyId: DocumentCrypto.zoneKeyId(DocumentCrypto.newZoneKey()), createdAt: Date(timeIntervalSinceReferenceDate: 800_000_123.5))
        XCTAssertEqual(try SyncZoneKeys.marker(from: SyncZoneKeys.wire(marker, zone: zone)), marker)
        func refused(_ change: (inout SyncWireRecord) -> Void) {
            var wire = SyncZoneKeys.wire(marker, zone: zone)
            change(&wire)
            XCTAssertThrowsError(try SyncZoneKeys.marker(from: wire)) { error in
                XCTAssertEqual(error as? SyncTransportError, .unreadableRecord(SyncZoneKeys.recordName(zone: self.zone)))
            }
        }
        refused { $0.encryptedFields["keys"] = Data("{}".utf8) }  // key material beside it (a step 3 record)
        refused { $0.encryptedFields["keyId"] = Data("ABCDEF0123456789".utf8) }
        refused { $0.encryptedFields["keyId"] = Data("0123".utf8) }
        refused { $0.encryptedFields["createdAt"] = Data(count: 7) }
        refused { $0.assets["file"] = Data([1]) }
    }

    /// Creates the zone's key and marker on `device` (as its first push would), so a test can fail what follows.
    private func establishKey(_ device: DocumentSyncTestDevice) async throws {
        _ = try await device.engine.householdKey(zone: zone, create: true)
    }

    func testADocumentWhoseFileCantBeUploadedNowIsDeferredNotRefused() async throws {
        let (_, uuid) = try a.add("later.pdf", Self.bytes("later"))
        try await a.engine.pull()
        try await establishKey(a)
        await cloud.failSaveOperations(after: 0)
        let report = try await a.engine.pushPending()
        XCTAssertGreaterThan(report.documentsDeferred, 0)
        XCTAssertEqual(report.refused, 0)
        XCTAssertEqual(report.documentsSealed, 0)
        let pending = try a.read { db in try SyncChangeTracker.pending(db: db).map(\.uuid) }
        XCTAssertTrue(pending.contains(uuid), "it waits, still pending")

        await cloud.restoreConnection()
        let retried = try await a.engine.pushPending()
        XCTAssertEqual(retried.documentsSealed, 1)
        XCTAssertEqual(retried.documentsDeferred, 0)
        let payload = try await documentPayload(uuid)
        XCTAssertNotNil(payload.documentFile)
    }

    /// CloudKit's busy or rate-limited server (`unavailable` with a retry-after) defers like no connection.
    func testADocumentIsDeferredWhileTheServiceIsUnavailable() async throws {
        let (_, uuid) = try a.add("busy.pdf", Self.bytes("busy"))
        try await a.engine.pull()
        try await establishKey(a)
        await cloud.failSaveOperations(after: 0, with: .unavailable(retryAfter: 30))
        let report = try await a.engine.pushPending()
        XCTAssertGreaterThan(report.documentsDeferred, 0)
        XCTAssertEqual(report.documentsSealed, 0)
        let pending = try a.read { db in try SyncChangeTracker.pending(db: db).map(\.uuid) }
        XCTAssertTrue(pending.contains(uuid))
        await cloud.restoreConnection()
        let retried = try await a.engine.pushPending()
        XCTAssertEqual(retried.documentsSealed, 1)
    }

    // MARK: Rotation

    func testRotationRewrapsDataKeysWithoutReuploadingFiles() async throws {
        let first = Self.bytes("first")
        let second = Self.bytes("second")
        let (_, one) = try a.add("one.pdf", first)
        let (_, two) = try a.add("two.pdf", second)
        try await a.engine.syncNow()
        try await b.engine.syncNow()
        let oldKeys = try await zoneKeys()
        let filesBefore = await stored(type: SyncDocumentFile.recordType)
        let mark = await cloud.calls.count

        let rotation = try await a.engine.rotateZoneKey()
        XCTAssertEqual(rotation.rewrapped, 2)

        let newKeys = try await zoneKeys()
        XCTAssertNotEqual(newKeys.marker.keyId, oldKeys.marker.keyId)
        XCTAssertEqual(try keys.allKeys(zone: zone).count, 2, "the retired key stays in the key store")
        let saved = await fileSaves(since: mark)
        XCTAssertEqual(Set(saved), [SyncZoneKeys.recordName(zone: zone), one, two], "no file record saved again")
        let awaited10 = await stored(type: SyncDocumentFile.recordType)
        XCTAssertEqual(awaited10, filesBefore, "the ciphertext assets are untouched")
        for uuid in [one, two] {
            let awaited11 = try await documentPayload(uuid).documentFile
            let reference = try XCTUnwrap(awaited11)
            XCTAssertEqual(try DocumentCrypto.zoneKeyId(ofWrapped: reference.wrappedKey), newKeys.marker.keyId)
            let file = try XCTUnwrap(filesBefore.first { $0.recordName == reference.recordName }?.assets[SyncDocumentFile.assetField])
            XCTAssertThrowsError(try DocumentCrypto.open(file, wrappedKey: reference.wrappedKey, zoneKey: oldKeys.key))
        }

        // The other device takes the new key and opens the re-wrapped files.
        try await b.engine.syncNow()
        for (uuid, plaintext) in [(one, first), (two, second)] {
            let document = try XCTUnwrap(try b.document(uuid: uuid))
            try FileManager.default.removeItem(at: b.library.fileURL(for: document))
            let url = try await b.engine.downloadDocument(uuid: uuid)
            XCTAssertEqual(try Data(contentsOf: url), plaintext)
            XCTAssertEqual(document.sha256, DocumentCrypto.sha256(plaintext), "the hash is unchanged by rotation")
        }
    }

    func testConcurrentRotationLoserAdoptsTheWinnersKeyAndRewrapsUnderIt() async throws {
        let (_, mine) = try a.add("a.pdf", Self.bytes("a"))
        let (_, theirs) = try b.add("b.pdf", Self.bytes("b"))
        try await a.engine.syncNow()
        try await b.engine.syncNow()
        try await a.engine.syncNow()

        // A rotates; B, not having pulled since, rotates too: its compare-and-set loses.
        try await a.engine.rotateZoneKey()
        let winner = try await zoneKeys()
        let filesBefore = await stored(type: SyncDocumentFile.recordType)
        try await b.engine.rotateZoneKey()
        try await a.engine.syncNow()

        let after = try await zoneKeys()
        XCTAssertEqual(after.marker.keyId, winner.marker.keyId, "the loser adopted the winner's key")
        let awaited12 = await stored(type: SyncDocumentFile.recordType)
        XCTAssertEqual(awaited12, filesBefore)
        for uuid in [mine, theirs] {
            let awaited13 = try await documentPayload(uuid).documentFile
            let reference = try XCTUnwrap(awaited13)
            XCTAssertEqual(try DocumentCrypto.zoneKeyId(ofWrapped: reference.wrappedKey), winner.marker.keyId)
        }
        for device in [a!, b!] {
            for uuid in [mine, theirs] {
                let document = try XCTUnwrap(try device.document(uuid: uuid))
                try? FileManager.default.removeItem(at: device.library.fileURL(for: document))
                _ = try await device.engine.downloadDocument(uuid: uuid)
            }
        }
    }

    func testAStragglerWrappedUnderARetiredKeyIsRewrappedByWhoeverSeesIt() async throws {
        _ = try a.add("a.pdf", Self.bytes("a"))
        try await a.engine.syncNow()
        try await b.engine.syncNow()
        // B adds a document and uploads it without having seen A's rotation (its key is still the old one).
        try await a.engine.rotateZoneKey()
        let (_, late) = try b.add("late.pdf", Self.bytes("late"))
        try await b.engine.pushPending()
        let current = try await zoneKeys().marker.keyId
        try await a.engine.syncNow()
        try await b.engine.syncNow()
        try await a.engine.syncNow()

        let awaited14 = try await documentPayload(late).documentFile
        let reference = try XCTUnwrap(awaited14)
        XCTAssertEqual(try DocumentCrypto.zoneKeyId(ofWrapped: reference.wrappedKey), current)
        XCTAssertNotNil(try a.file(uuid: late))
    }

    // MARK: The zone key's creation race

    func testZoneKeyCreationRaceLoserAdoptsTheWinnersKey() async throws {
        let first = try DocumentSyncTestDevice("user-a", transport: cloud, keys: keys)
        let (_, winnerDoc) = try first.add("w.pdf", Self.bytes("winner"))
        // B looks for the zone key, finds none, and before it creates its own, A creates one and seals with it.
        let race = ZoneKeyRaceTransport(cloud: cloud) { [first] in try await first.engine.syncNow() }
        let second = try DocumentSyncTestDevice("user-b", transport: race, keys: keys)
        let (_, loserDoc) = try second.add("l.pdf", Self.bytes("loser"))
        try await second.engine.syncNow()
        try await first.engine.syncNow()
        try await second.engine.syncNow()

        let keyRecords = await stored(type: SyncZoneKeys.recordType)
        XCTAssertEqual(keyRecords.count, 1)
        let current = try await zoneKeys()
        XCTAssertEqual(try keys.allKeys(zone: zone).count, 1, "no second key")
        for uuid in [winnerDoc, loserDoc] {
            let awaited15 = try await documentPayload(uuid).documentFile
            let reference = try XCTUnwrap(awaited15)
            XCTAssertEqual(try DocumentCrypto.zoneKeyId(ofWrapped: reference.wrappedKey), current.marker.keyId)
        }
        XCTAssertNotNil(try first.file(uuid: loserDoc))
        XCTAssertNotNil(try second.file(uuid: winnerDoc))
    }
}
