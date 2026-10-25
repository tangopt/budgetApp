import XCTest
import GRDB
import CryptoKit
@testable import BudgetCore

/// A device keeping files for later and syncing them (plan Task 10): its own database, evidence library and
/// waiting folder in a temporary folder (never the real Application Support), syncing through `cloud`.
final class WaitingSyncTestDevice {
    let manager: DatabaseManager
    let base: URL
    let evidence: URL
    let waitingRoot: URL
    let inbox: URL
    let engine: SyncEngineCore
    let keys: any SyncKeyStore
    var queue: DatabaseQueue { manager.dbQueue }
    var list: ImportWaitingList { ImportWaitingList(root: waitingRoot, database: queue) }

    init(_ user: String, cloud: FakeCloud, keys: any SyncKeyStore, policy: SyncDocumentFiles.Policy = .eager) throws {
        manager = try DatabaseManager(path: nil)
        try manager.migrate()
        base = FileManager.default.temporaryDirectory.appendingPathComponent("WaitingFileSyncTests-\(UUID().uuidString)", isDirectory: true)
        evidence = base.appendingPathComponent("Evidence", isDirectory: true)
        waitingRoot = base.appendingPathComponent("Waiting", isDirectory: true)
        inbox = base.appendingPathComponent("Inbox", isDirectory: true)
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        try manager.dbQueue.write { db in try SyncChangeTracker.setWriter(user, db: db) }
        self.keys = keys
        engine = SyncEngineCore(db: manager.dbQueue, transport: cloud, device: SyncDevice(id: "device-\(user)", name: user), keyStore: keys,
                                documents: SyncDocumentFiles(root: evidence, policy: policy, waitingRoot: waitingRoot))
    }

    deinit { try? FileManager.default.removeItem(at: base) }

    func read<T>(_ body: (Database) throws -> T) throws -> T { try queue.read(body) }
    func write<T>(_ body: (Database) throws -> T) throws -> T { try queue.write(body) }

    /// Keeps a synthetic file for later; returns its row and its record UUID.
    @discardableResult
    func keep(_ name: String, _ bytes: Data, text: String? = nil, reason: String = "Not recognised") throws -> (ImportWaitingFile, String) {
        let folder = inbox.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name)
        try bytes.write(to: url)
        let file = SetAsideFile(url: url, fileName: name, sha256: DocumentCrypto.sha256(bytes), byteCount: Int64(bytes.count), text: text,
                                textStatus: text == nil ? .unknown : .text, reason: reason, recognisedAs: "Unknown")
        let result = try list.keep([file], now: Date(timeIntervalSince1970: 1_800_000_000))
        let row = try XCTUnwrap(result.kept.first, "\(result.failed)")
        let uuid = try queue.read { db in try XCTUnwrap(SyncRecordStore.existingUUID(table: "importWaitingFile", localId: row.id!, db: db)) }
        return (row, uuid)
    }

    func row(uuid: String) throws -> ImportWaitingFile? {
        try queue.read { db in
            guard let id = try SyncRecordStore.localId(table: "importWaitingFile", uuid: uuid, db: db) else { return nil }
            return try ImportWaitingFile.fetchOne(db, key: id)
        }
    }

    /// Every file under the waiting folder (relative paths).
    func waitingFiles() -> [String] {
        let manager = FileManager.default
        guard let paths = try? manager.subpathsOfDirectory(atPath: waitingRoot.path) else { return [] }
        return paths.filter { path in
            var folder: ObjCBool = false
            return manager.fileExists(atPath: waitingRoot.appendingPathComponent(path).path, isDirectory: &folder) && !folder.boolValue
        }.sorted()
    }

    func conflicts(uuid: String) throws -> [SyncConflictRow] {
        try queue.read { db in try SyncConflictRow.filter(Column("uuid") == uuid).fetchAll(db) }
    }
}

/// Files kept for later sync to the household with their copies (spec 2026-10-24 §1, plan Task 10): the row
/// sealed like every record (ruling R15), the copy as a sealed `documentFile` record authenticated with the
/// waiting table's own context, checked against its hash and its path on the way in; a discard removes the
/// copy everywhere; the text and the suggestion stay on each device; nothing of it reaches the filed-year check.
/// Synthetic files only.
final class WaitingFileSyncTests: XCTestCase {
    private var cloud: FakeCloud!
    private var keys: InMemorySyncKeyStore!
    private var a: WaitingSyncTestDevice!
    private var b: WaitingSyncTestDevice!
    private let zone = SyncRecordStore.householdZone

    override func setUp() async throws {
        cloud = FakeCloud()
        keys = InMemorySyncKeyStore()
        a = try WaitingSyncTestDevice("user-a", cloud: cloud, keys: keys)
        b = try WaitingSyncTestDevice("user-b", cloud: cloud, keys: keys)
    }

    private static func bytes(_ marker: String) -> Data {
        Data("Synthetic kept letter \(marker) - amount 12.34 - never real".utf8) + Data((0..<4096).map { UInt8(($0 * 11) % 251) })
    }

    private func currentKey() async throws -> SymmetricKey {
        let record = await cloud.record(named: SyncZoneKeys.recordName(zone: zone))
        let marker = try SyncZoneKeys.marker(from: try XCTUnwrap(record).wire)
        return try XCTUnwrap(try keys.allKeys(zone: zone)[marker.keyId])
    }

    /// Rewrites the record `uuid` on the server as another writer would (sealed correctly under the zone key).
    private func tamper(_ uuid: String, _ change: (inout SyncPayload) throws -> Void) async throws {
        let key = try await currentKey()
        let awaited = await cloud.record(named: uuid)
        let server = try XCTUnwrap(awaited)
        var payload = try SyncLargePayload.payload(from: server.wire, keys: keys.allKeys(zone: zone))
        try change(&payload)
        let results = try await cloud.save([try SyncLargePayload.wire(for: payload, key: key).0], ifUnchanged: [uuid: server.stamp.systemFields],
                                           atomic: false)
        guard case .saved = results.first?.outcome else { return XCTFail("tampered save refused") }
    }

    // MARK: Arrival

    func testAKeptFileArrivesOnTheOtherDeviceWithItsCopy() async throws {
        let plaintext = Self.bytes("arrives")
        let (row, uuid) = try a.keep("Synthetic letter.pdf", plaintext)
        let pushed = try await a.engine.syncNow()
        XCTAssertEqual(pushed.push.documentsSealed, 1)

        let pulled = try await b.engine.syncNow()
        XCTAssertEqual(pulled.pull.documentsDownloaded, 1)
        let listed = try b.list.waiting()
        XCTAssertEqual(listed.map(\.sha256), [row.sha256])
        let arrived = try XCTUnwrap(try b.row(uuid: uuid))
        XCTAssertEqual(arrived.storedRelativePath, "\(row.sha256)/Synthetic letter.pdf")
        let copy = b.waitingRoot.appendingPathComponent(row.sha256, isDirectory: true).appendingPathComponent("Synthetic letter.pdf")
        XCTAssertEqual(try Data(contentsOf: copy), plaintext)
        XCTAssertEqual(try EvidenceLibrary.sha256(of: copy), row.sha256)
        XCTAssertEqual(b.list.fileURL(arrived), copy)
        XCTAssertEqual(b.waitingFiles(), ["\(row.sha256)/Synthetic letter.pdf"], "no temporary copy left")
        let library = (try? FileManager.default.subpathsOfDirectory(atPath: b.evidence.path)) ?? []
        XCTAssertTrue(library.filter { !$0.hasPrefix(".") }.isEmpty, "nothing goes to the evidence library: \(library)")

        // Already there: the next pull fetches nothing.
        let calls = await cloud.calls.count
        let again = try await b.engine.syncNow()
        XCTAssertEqual(again.pull.documentsDownloaded, 0)
        let fetched = await cloud.calls.dropFirst(calls).contains { if case .fetch = $0 { return true } else { return false } }
        XCTAssertFalse(fetched)
    }

    func testALazyDeviceDownloadsAWaitingFileWhenAsked() async throws {
        let phone = try WaitingSyncTestDevice("user-b", cloud: cloud, keys: keys, policy: .lazy)
        let plaintext = Self.bytes("lazy")
        let (row, uuid) = try a.keep("kept.txt", plaintext)
        try await a.engine.syncNow()
        let pulled = try await phone.engine.syncNow()
        XCTAssertEqual(pulled.pull.documentsDownloaded, 0)
        XCTAssertEqual(phone.waitingFiles(), [])

        let url = try await phone.engine.downloadDocument(uuid: uuid)
        XCTAssertEqual(url, phone.waitingRoot.appendingPathComponent(row.sha256).appendingPathComponent("kept.txt"))
        XCTAssertEqual(try Data(contentsOf: url), plaintext)
    }

    // MARK: Sealing

    func testTheWaitingRowAndItsFileAreSealed() async throws {
        let plaintext = Self.bytes("sealed")
        let (_, uuid) = try a.keep("Synthetic-kept-Omega.pdf", plaintext, reason: "Synthetic reason Omega")
        try await a.engine.syncNow()

        let awaited = await cloud.record(named: uuid)
        let record = try XCTUnwrap(awaited).wire
        XCTAssertEqual(record.recordType, "importWaitingFile")
        XCTAssertEqual(Set(record.encryptedFields.keys), [FieldSealing.sealedField, FieldSealing.keyIdField])
        XCTAssertTrue(record.unencryptedFields.isEmpty)
        XCTAssertTrue(record.assets.isEmpty)
        for needle in ["Synthetic-kept-Omega", "Synthetic reason Omega", "{\"string\"", "\"fields\""] {
            for data in record.encryptedFields.values {
                XCTAssertNil(data.range(of: Data(needle.utf8)), "\(needle) readable")
            }
        }

        let fetched = try await cloud.payload(named: uuid, keys: keys)
        let payload = try XCTUnwrap(fetched)
        let reference = try XCTUnwrap(payload.documentFile, "the row names its sealed copy")
        let fileAwaited = await cloud.record(named: reference.recordName)
        let file = try XCTUnwrap(fileAwaited).wire
        XCTAssertEqual(file.recordType, SyncDocumentFile.recordType)
        XCTAssertTrue(file.encryptedFields.isEmpty)
        XCTAssertTrue(file.unencryptedFields.isEmpty)
        XCTAssertEqual(Set(file.assets.keys), [SyncDocumentFile.assetField])
        let ciphertext = try XCTUnwrap(file.assets[SyncDocumentFile.assetField])
        XCTAssertNil(ciphertext.range(of: plaintext.prefix(32)), "the asset never holds the plaintext")
        XCTAssertNil(ciphertext.range(of: Data("Synthetic kept letter".utf8)))
        XCTAssertFalse(reference.recordName.contains("Omega"))
    }

    func testTheTextAndSuggestionNeverLeaveTheDevice() async throws {
        let (row, uuid) = try a.keep("letter.txt", Self.bytes("text"), text: "Synthetic secret text Sigma")
        try a.write { db in
            try db.execute(sql: "UPDATE importWaitingFile SET suggestion = ?, checkedSignature = ? WHERE id = ?",
                           arguments: ["Now recognised as Synthetic Kind Tau", "sig-synthetic", row.id])
        }
        try await a.engine.syncNow()

        let fetched = try await cloud.payload(named: uuid, keys: keys)
        let payload = try XCTUnwrap(fetched)
        for local in ["text", "textStatus", "suggestion", "checkedSignature"] {
            XCTAssertNil(payload.fields[local], "\(local) travels")
        }
        let encoded = try JSONEncoder().encode(payload)
        for needle in ["Synthetic secret text Sigma", "Synthetic Kind Tau", "sig-synthetic"] {
            XCTAssertNil(encoded.range(of: Data(needle.utf8)), needle)
        }

        try await b.engine.syncNow()
        let arrived = try XCTUnwrap(try b.row(uuid: uuid))
        XCTAssertNil(arrived.text)
        XCTAssertEqual(arrived.textStatus, .unknown)
        XCTAssertNil(arrived.suggestion)
        XCTAssertEqual(arrived.checkedSignature, "")
    }

    // MARK: Checked on the way in

    func testAnUnsafeWaitingPathNeedsAttentionAndWritesNothing() async throws {
        let names = ["../x", ".hidden", "a/b"]
        let kept = try names.indices.map { index in try a.keep("safe-\(index).txt", Self.bytes("unsafe \(index)")) }
        try await a.engine.syncNow()
        // Another writer renames them on the server (sealed correctly): the paths now leave the hash's folder.
        for ((row, uuid), name) in zip(kept, names) {
            try await tamper(uuid) { payload in
                payload.fields["originalFileName"] = .string(name)
                payload.fields["storedRelativePath"] = .string("\(row.sha256)/\(name)")
            }
        }
        let uuids = kept.map(\.1)

        let pulled = try await b.engine.syncNow()
        XCTAssertEqual(pulled.pull.documentsDownloaded, 0)
        XCTAssertEqual(pulled.pull.documentsNeedingAttention, 3)
        XCTAssertEqual(b.waitingFiles(), [], "nothing written under the waiting folder")
        let outside = (try? FileManager.default.subpathsOfDirectory(atPath: b.base.path)) ?? []
        XCTAssertFalse(outside.contains { $0 == "x" || $0.hasSuffix("/x") || $0.hasSuffix("/b") || $0.hasSuffix(".hidden") }, "\(outside)")
        for uuid in uuids {
            XCTAssertNotNil(try b.row(uuid: uuid), "the row applies")
            let logged = try b.conflicts(uuid: uuid)
            XCTAssertTrue(logged.contains { $0.field == SyncDocumentFile.conflictField && $0.losingValueJSON.contains("needs attention") }, "\(logged)")
        }

        // Logged once: the next pull doesn't try the same file again.
        let again = try await b.engine.syncNow()
        XCTAssertEqual(again.pull.documentsNeedingAttention, 0)
        do {
            _ = try await b.engine.downloadDocument(uuid: uuids[0])
            XCTFail("an unsafe path was accepted")
        } catch let error as SyncDocumentError {
            XCTAssertEqual(error, .unsafePath)
        }
        XCTAssertEqual(b.waitingFiles(), [])
    }

    func testAFileWhoseBytesDontMatchItsHashIsNeverWritten() async throws {
        let (row, uuid) = try a.keep("genuine.txt", Self.bytes("genuine"))
        try await a.engine.syncNow()

        // Other bytes sealed correctly for this waiting row: decryption succeeds, the hash doesn't match.
        let key = try await currentKey()
        let sealed = try DocumentCrypto.seal(Self.bytes("substituted"), zoneKey: key,
                                             authenticating: DocumentCrypto.fileContext(table: "importWaitingFile", uuid: uuid, sha256: row.sha256))
        _ = try await cloud.save([SyncWireRecord(recordType: SyncDocumentFile.recordType, recordName: "substitute", zone: zone,
                                                 assets: [SyncDocumentFile.assetField: sealed.ciphertext])], ifUnchanged: [:], atomic: false)
        try await tamper(uuid) { $0.documentFile = SyncDocumentFileReference(recordName: "substitute", wrappedKey: sealed.wrappedKey) }

        let pulled = try await b.engine.syncNow()
        XCTAssertEqual(pulled.pull.documentsDownloaded, 0)
        XCTAssertEqual(pulled.pull.documentsNeedingAttention, 1)
        XCTAssertNotNil(try b.row(uuid: uuid))
        XCTAssertEqual(b.waitingFiles(), [], "a file whose hash doesn't match is never written")
        XCTAssertTrue(try b.conflicts(uuid: uuid).contains { $0.field == SyncDocumentFile.conflictField })
        let leftovers = (try? FileManager.default.subpathsOfDirectory(atPath: b.waitingRoot.path)) ?? []
        XCTAssertFalse(leftovers.contains { $0.contains(EvidenceLibrary.temporaryPrefix) }, "\(leftovers)")
    }

    func testAWaitingFileSealedAsADocumentDoesntOpen() async throws {
        let plaintext = Self.bytes("cross")
        let (row, uuid) = try a.keep("cross.txt", plaintext)
        try await a.engine.syncNow()

        // The right bytes, but sealed under the document context: another table's file can't pass as this one.
        let key = try await currentKey()
        let sealed = try DocumentCrypto.seal(plaintext, zoneKey: key,
                                             authenticating: DocumentCrypto.documentContext(uuid: uuid, sha256: row.sha256))
        _ = try await cloud.save([SyncWireRecord(recordType: SyncDocumentFile.recordType, recordName: "as-document", zone: zone,
                                                 assets: [SyncDocumentFile.assetField: sealed.ciphertext])], ifUnchanged: [:], atomic: false)
        try await tamper(uuid) { $0.documentFile = SyncDocumentFileReference(recordName: "as-document", wrappedKey: sealed.wrappedKey) }

        let pulled = try await b.engine.syncNow()
        XCTAssertEqual(pulled.pull.documentsNeedingAttention, 1)
        XCTAssertEqual(b.waitingFiles(), [])
    }

    // MARK: Discard and import

    func testDiscardOnOneDeviceRemovesTheCopyOnTheOther() async throws {
        let (row, uuid) = try a.keep("discard.txt", Self.bytes("discard"))
        let (kept, _) = try a.keep("stays.txt", Self.bytes("stays"))
        try await a.engine.syncNow()
        try await b.engine.syncNow()
        XCTAssertEqual(b.waitingFiles().count, 2)

        try a.list.discard([row.id!])
        try await a.engine.syncNow()
        try await b.engine.syncNow()

        XCTAssertNil(try b.row(uuid: uuid))
        XCTAssertEqual(try b.list.waiting().map(\.sha256), [kept.sha256])
        XCTAssertFalse(FileManager.default.fileExists(atPath: b.waitingRoot.appendingPathComponent(row.sha256).path), "the copy folder goes")
        XCTAssertEqual(b.waitingFiles(), ["\(kept.sha256)/stays.txt"])
        let reference = try b.read { db in try SyncDocumentFile.reference(uuid: uuid, db: db) }
        XCTAssertNil(reference, "the file reference goes with the row")
    }

    func testImportingAWaitingFileHidesItOnTheOtherDevice() async throws {
        let (row, _) = try a.keep("imported.txt", Self.bytes("imported"))
        let (other, _) = try a.keep("still.txt", Self.bytes("still"))
        try await a.engine.syncNow()
        try await b.engine.syncNow()
        XCTAssertEqual(Set(try b.list.waiting().map(\.sha256)), [row.sha256, other.sha256])

        // A run confirmed on A (the lease taken), marking the file imported inside its batch as the applier does.
        try await a.engine.acquireImportLease()
        try a.write { db in
            try SyncImportGate.require(db: db)
            let mark = try SyncBatch.mark(db: db)
            var run = ImportRun(confirmedAt: Date(timeIntervalSince1970: 1_800_000_100), entryPoint: "Waiting list", summary: "")
            try run.insert(db)
            try ImportChangeCapture.begin(db: db)
            _ = try ImportChangeCapture.finish(db: db, runId: run.id!)
            try ImportWaitingList.markImported(db: db, runId: run.id!, sha256s: [row.sha256])
            try SyncBatch.open(runId: run.id!, since: mark, db: db)
        }
        try await a.engine.syncNow()
        try await b.engine.syncNow()

        XCTAssertEqual(try b.list.waiting().map(\.sha256), [other.sha256])
        XCTAssertTrue(FileManager.default.fileExists(atPath: b.waitingRoot.appendingPathComponent(row.sha256).path),
                      "the copy stays while the run can be undone")
    }

    // MARK: Documents unchanged

    func testDocumentFilesStillOpenWithTheirOldContext() async throws {
        // The context documents were sealed with before waiting files synced, byte for byte.
        XCTAssertEqual(DocumentCrypto.documentContext(uuid: "U-1", sha256: "ABCDEF"), Data("mango.document.v1|U-1|abcdef".utf8))
        XCTAssertEqual(DocumentCrypto.fileContext(table: "document", uuid: "U-1", sha256: "ABCDEF"), Data("mango.document.v1|U-1|abcdef".utf8))
        XCTAssertNotEqual(DocumentCrypto.fileContext(table: "importWaitingFile", uuid: "U-1", sha256: "abcdef"),
                          DocumentCrypto.documentContext(uuid: "U-1", sha256: "abcdef"))

        // A document whose file was sealed by an earlier build (the literal context) still opens on the other device.
        let inbox = a.inbox.appendingPathComponent("document.pdf")
        let plaintext = Self.bytes("old document")
        try plaintext.write(to: inbox)
        let library = EvidenceLibrary(root: a.evidence, database: a.queue)
        let document = try library.add(inbox).document
        let uuid = try a.read { db in try XCTUnwrap(SyncRecordStore.existingUUID(table: "document", localId: document.id!, db: db)) }
        try await a.engine.syncNow()
        let key = try await currentKey()
        let old = try DocumentCrypto.seal(plaintext, zoneKey: key, authenticating: Data("mango.document.v1|\(uuid)|\(document.sha256)".utf8))
        _ = try await cloud.save([SyncWireRecord(recordType: SyncDocumentFile.recordType, recordName: "\(uuid).file.oldbuild", zone: zone,
                                                 assets: [SyncDocumentFile.assetField: old.ciphertext])], ifUnchanged: [:], atomic: false)
        try await tamper(uuid) { $0.documentFile = SyncDocumentFileReference(recordName: "\(uuid).file.oldbuild", wrappedKey: old.wrappedKey) }

        let pulled = try await b.engine.syncNow()
        XCTAssertEqual(pulled.pull.documentsDownloaded, 1)
        XCTAssertEqual(pulled.pull.documentsNeedingAttention, 0)
        XCTAssertEqual(try Data(contentsOf: b.evidence.appendingPathComponent(document.storedRelativePath)), plaintext)
        XCTAssertEqual(b.waitingFiles(), [], "a document never lands in the waiting folder")
    }

    // MARK: The filed-year check

    func testWaitingFilesNeverTriggerTheFiledYearCheck() async throws {
        XCTAssertTrue(FiledYearSyncCheck.unprotectedTables.contains("importWaitingFile"))
        XCTAssertEqual(FiledYearSyncCheck.checkedWritten(["importWaitingFile", "transaction_"]), ["transaction_"])
        XCTAssertEqual(FiledYearSyncCheck.checkedWritten(["importWaitingFile"]), [])
        XCTAssertNil(FiledYearSyncCheck.checkedWritten(nil))

        // What applying incoming waiting rows writes, as the check sees it.
        let (_, uuid) = try a.keep("filed.txt", Self.bytes("filed"))
        let (_, second) = try a.keep("filed-2.txt", Self.bytes("filed 2"))
        try await a.engine.syncNow()
        var payloads: [SyncPayload] = []
        for name in [uuid, second] {
            let fetched = try await cloud.payload(named: name, keys: keys)
            payloads.append(try XCTUnwrap(fetched))
        }
        // Applied after a baseline: with only the waiting table written, no recorded statement of the protected
        // years runs again and nothing moves.
        try b.write { db in
            let baseline = try FiledYearSyncCheck.baseline(db: db)
            XCTAssertFalse(baseline.isEmpty)
            _ = try SyncTranslator.apply(payloads.map { .save($0) }, db: db, deviceUser: nil, now: Date())
            XCTAssertEqual(try ImportWaitingFile.fetchCount(db), 2)
            let reads = try XCTUnwrap(baseline.reads)
            XCTAssertEqual(reads.reads.changed(written: FiledYearSyncCheck.checkedWritten(["importWaitingFile"])), [])
            XCTAssertEqual(try FiledYearSyncCheck.impacts(db: db, baseline: baseline, written: ["importWaitingFile"]), [])
        }

        // Through the engine: incoming waiting rows never raise an alert nor hold anything.
        let c = try WaitingSyncTestDevice("user-c", cloud: cloud, keys: keys)
        let pulled = try await c.engine.syncNow()
        XCTAssertNil(pulled.pull.filedYearAlert)
        XCTAssertEqual(pulled.pull.held, 0)
        XCTAssertEqual(pulled.pull.staged, 0)
        XCTAssertEqual(try c.list.waiting().count, 2)
    }
}
