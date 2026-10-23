import CryptoKit
import Foundation
import GRDB
import os

/// Where this device keeps evidence files, and when it downloads them (sync spec §5.7): the Mac always
/// keeps them (`eager`: every pull downloads what is missing); the iPhone downloads a document when it is
/// opened (`lazy`: `SyncEngineCore.downloadDocument`).
public struct SyncDocumentFiles: Sendable {
    public enum Policy: Sendable, Equatable {
        case eager
        case lazy
    }

    /// The evidence library's root (`EvidenceLibrary.root`).
    public var root: URL
    public var policy: Policy

    public init(root: URL, policy: Policy) {
        self.root = root
        self.policy = policy
    }
}

/// On a `document` record (sync spec §9.1): the record holding its sealed file, and its data key wrapped
/// with the zone key. It travels in the record's encrypted `meta` field; the file record's asset holds only
/// ciphertext.
public struct SyncDocumentFileReference: Codable, Equatable, Hashable, Sendable {
    public var recordName: String
    public var wrappedKey: Data

    public init(recordName: String, wrappedKey: Data) {
        self.recordName = recordName
        self.wrappedKey = wrappedKey
    }
}

public enum SyncDocumentError: Error, Equatable, Sendable {
    /// No such document here.
    case documentNotFound
    /// The document has no file on iCloud (its sender didn't have it).
    case noFile
    /// The decrypted file's SHA-256 isn't the record's: never written (needs attention).
    case hashMismatch
    /// The file record is gone, damaged, or doesn't open with the zone's keys (needs attention).
    case unreadable
    /// The record's stored path isn't the library path its hash gives (needs attention).
    case unsafePath
    /// The zone key couldn't be read or created now (offline): tried again later.
    case zoneKeyUnavailable
    /// The device doesn't sync files (no `SyncDocumentFiles`).
    case notConfigured
}

// MARK: Zone keys

/// The zone key (sync spec §9.1), held in one `zoneKey` record per zone, in an encrypted field: the current
/// 256-bit key, and the retired ones (so data keys still wrapped with one can be opened, and re-wrapped).
/// Created once per zone with compare-and-set on the fixed record name: of two devices creating it, the
/// server takes the first, and the other adopts it (it has sealed nothing yet: files are sealed only under
/// a published key). Rotation replaces it the same way, against the version last seen.
///
/// Each device keeps its copy in `syncState` (`zoneKeys.<zone>`), with the version it last saw.
public enum SyncZoneKeys {
    public static let recordType = "zoneKey"
    static let keysField = "keys"

    public static func recordName(zone: String) -> String { "zoneKey-" + zone }

    public struct Entry: Codable, Equatable, Sendable {
        public var id: String
        public var keyData: Data

        public var key: SymmetricKey { SymmetricKey(data: keyData) }

        public init(_ key: SymmetricKey) {
            id = DocumentCrypto.zoneKeyId(key)
            keyData = key.withUnsafeBytes { Data($0) }
        }
    }

    public struct Keyring: Codable, Equatable, Sendable {
        /// 1 when created, +1 on every rotation.
        public var generation: Int
        public var current: Entry
        public var retired: [Entry]

        public init(generation: Int, current: Entry, retired: [Entry]) {
            self.generation = generation
            self.current = current
            self.retired = retired
        }

        public func key(id: String) -> SymmetricKey? {
            ([current] + retired).first { $0.id == id }?.key
        }

        /// The next generation's keyring: a new key, the current one retired.
        func rotated() -> Keyring {
            Keyring(generation: generation + 1, current: Entry(DocumentCrypto.newZoneKey()), retired: [current] + retired)
        }
    }

    /// The keyring a `zoneKey` record holds.
    public static func keyring(from wire: SyncWireRecord) throws -> Keyring {
        guard wire.recordType == recordType, let data = wire.encryptedFields[keysField] else { throw SyncTransportError.unreadableRecord(wire.recordName) }
        let keyring = try JSONDecoder().decode(Keyring.self, from: data)
        // Only 256-bit keys: anything else is a damaged or foreign record, never used to wrap.
        guard ([keyring.current] + keyring.retired).allSatisfy({ $0.keyData.count == 32 }) else {
            throw SyncTransportError.unreadableRecord(wire.recordName)
        }
        return keyring
    }

    static func wire(_ keyring: Keyring, zone: String) throws -> SyncWireRecord {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return SyncWireRecord(recordType: recordType, recordName: recordName(zone: zone), zone: zone,
                              encryptedFields: [keysField: try encoder.encode(keyring)])
    }

    /// This device's copy: the keyring, and the system fields of the version it was last seen at (nil:
    /// not on the server yet, or the zone was reset).
    struct Local: Codable, Equatable {
        var keyring: Keyring
        var systemFields: Data?
    }

    static func stateKey(_ zone: String) -> String { "zoneKeys." + zone }

    static func local(zone: String, db: Database) throws -> Local? {
        guard let data = try Data.fetchOne(db, sql: "SELECT value FROM syncState WHERE key = ?", arguments: [stateKey(zone)]) else { return nil }
        return try JSONDecoder().decode(Local.self, from: data)
    }

    static func store(_ local: Local, zone: String, db: Database, now: Date) throws {
        try SyncImportGate.setState(try JSONEncoder().encode(local), key: stateKey(zone), db: db, now: now)
    }

    /// Takes the server's keyring (its current key wins), keeping any key known here that it doesn't list
    /// as retired here, so nothing wrapped with one becomes unreadable.
    @discardableResult
    static func adopt(_ server: SyncServerRecord, zone: String, db: Database, now: Date) throws -> Keyring {
        var keyring = try keyring(from: server.wire)
        if let mine = try local(zone: zone, db: db)?.keyring {
            let known = Set(([keyring.current] + keyring.retired).map(\.id))
            keyring.retired += ([mine.current] + mine.retired).filter { !known.contains($0.id) }
        }
        try store(Local(keyring: keyring, systemFields: server.stamp.systemFields), zone: zone, db: db, now: now)
        return keyring
    }
}

// MARK: File records

/// The record holding one document's sealed file: its asset is the ciphertext and nothing else of the
/// file. Written once (a new name per sealing); rotation never touches it. Each device keeps the reference
/// of every document it knows in `syncState` (`documentFile.<uuid>`), so an edit sends it unchanged.
public enum SyncDocumentFile {
    public static let recordType = "documentFile"
    public static let assetField = "file"
    /// The conflict-log field of a document's file problems (needs attention, step 6 surfaces them).
    public static let conflictField = "file"

    static let referencePrefix = "documentFile."
    static let failedPrefix = "documentFileFailed."

    static let hashMismatchMessage = SyncTranslator.needsAttention + "the downloaded file doesn't match its hash; not saved"
    static let unreadableMessage = SyncTranslator.needsAttention + "the file on iCloud can't be opened; not saved"
    static let unsafePathMessage = SyncTranslator.needsAttention + "the file's library path doesn't match its hash; not saved"
    static let senderMismatchMessage = SyncTranslator.needsAttention + "the library file doesn't match its hash; not uploaded"

    static func reference(uuid: String, db: Database) throws -> SyncDocumentFileReference? {
        guard let data = try Data.fetchOne(db.cachedStatement(sql: "SELECT value FROM syncState WHERE key = ?"),
                                           arguments: [referencePrefix + uuid]) else { return nil }
        return try? JSONDecoder().decode(SyncDocumentFileReference.self, from: data)
    }

    static func setReference(_ reference: SyncDocumentFileReference?, uuid: String, db: Database, now: Date) throws {
        guard let reference else {
            try db.execute(sql: "DELETE FROM syncState WHERE key IN (?, ?)", arguments: [referencePrefix + uuid, failedPrefix + uuid])
            return
        }
        try SyncImportGate.setState(try JSONEncoder().encode(reference), key: referencePrefix + uuid, db: db, now: now)
    }

    static func references(db: Database) throws -> [String: SyncDocumentFileReference] {
        var result: [String: SyncDocumentFileReference] = [:]
        for row in try Row.fetchAll(db, sql: "SELECT key, value FROM syncState WHERE key LIKE ?", arguments: [referencePrefix + "%"]) {
            let key: String = row["key"]
            if let reference = try? JSONDecoder().decode(SyncDocumentFileReference.self, from: row["value"] as Data) {
                result[String(key.dropFirst(referencePrefix.count))] = reference
            }
        }
        return result
    }

    /// The reference a download of `uuid` failed with (not tried again until another arrives).
    static func failed(uuid: String, db: Database) throws -> SyncDocumentFileReference? {
        guard let data = try Data.fetchOne(db, sql: "SELECT value FROM syncState WHERE key = ?", arguments: [failedPrefix + uuid]) else { return nil }
        return try? JSONDecoder().decode(SyncDocumentFileReference.self, from: data)
    }

    static func setFailed(_ reference: SyncDocumentFileReference, uuid: String, db: Database, now: Date) throws {
        try SyncImportGate.setState(try JSONEncoder().encode(reference), key: failedPrefix + uuid, db: db, now: now)
    }

    /// The library path a document's hash gives, if `stored` is it (a synced path is never trusted as is).
    static func libraryPath(stored: String, sha256: String) -> String? {
        let hex = sha256.lowercased()
        guard hex.count == 64, hex.allSatisfy({ $0.isHexDigit }) else { return nil }
        let expected = EvidenceLibrary.storedRelativePath(sha256: hex, fileExtension: (stored as NSString).pathExtension)
        return expected == stored ? expected : nil
    }

    static func logAttention(uuid: String, message: String, db: Database, now: Date) throws {
        try SyncMerge.logConflict(table: "document", uuid: uuid, field: conflictField, losing: .string(message), winner: nil, loser: nil,
                                  db: db, now: now)
    }

    /// The record name of a new sealing of `uuid`'s file.
    static func newRecordName(uuid: String) -> String { "\(uuid).file.\(UUID().uuidString.prefix(8).lowercased())" }
}

// MARK: The engine's document files

public struct SyncZoneKeyRotation: Equatable, Sendable {
    /// Data keys re-wrapped with the new zone key (no file uploaded again).
    public var rewrapped: Int
    /// The push that sent the re-wrapped document records.
    public var push: SyncPushReport
}

extension SyncEngineCore {
    private static let documentLog = Logger(subsystem: "com.personal.budget", category: "SyncDocuments")

    // MARK: Public

    /// Downloads, opens and checks the document's file, and writes it into the library (an iPhone opening
    /// a document, sync spec §5.7). Returns where it is. A file whose SHA-256 isn't the record's is never
    /// written: it is logged for attention and `hashMismatch` thrown.
    public func downloadDocument(uuid: String) async throws -> URL {
        try await serialized { try await self.download(uuid: uuid) }
    }

    /// A new zone key (a member removed, sync spec §9.1): saved over the version last seen; if another
    /// device changed it meanwhile, its key is adopted instead. Every data key known here is re-wrapped with
    /// the current key and its document record sent again; no file is uploaded again.
    @discardableResult
    public func rotateZoneKey() async throws -> SyncZoneKeyRotation {
        try await serialized {
            try await self.prepare()
            let zone = SyncRecordStore.householdZone
            let keyring = try await self.zoneKeyring(zone: zone)
            let systemFields = try await self.db.read { db in try SyncZoneKeys.local(zone: zone, db: db)?.systemFields }
            let next = keyring.rotated()
            let wire = try SyncZoneKeys.wire(next, zone: zone)
            let results = try await self.transport.save([wire], ifUnchanged: systemFields.map { [wire.recordName: $0] } ?? [:], atomic: false)
            let now = self.clock()
            switch results.first?.outcome {
            case .saved(let stamp):
                try await self.db.write { db in try SyncZoneKeys.store(.init(keyring: next, systemFields: stamp.systemFields), zone: zone, db: db, now: now) }
            case .changed(let server):
                // Another device rotated (or created) it first: its key is the zone's.
                Self.documentLog.error("Zone key changed on another device during rotation; adopting it")
                try await self.db.write { db in _ = try SyncZoneKeys.adopt(server, zone: zone, db: db, now: now) }
            case .deleted:
                try await self.db.write { db in try SyncZoneKeys.store(.init(keyring: next, systemFields: nil), zone: zone, db: db, now: now) }
                _ = try await self.zoneKeyring(zone: zone)
            default:
                throw SyncDocumentError.zoneKeyUnavailable
            }
            let rewrapped = try await self.db.write { db in try Self.rewrapStragglers(zone: zone, db: db, now: now) }
            return SyncZoneKeyRotation(rewrapped: rewrapped, push: try await self.pushAll())
        }
    }

    // MARK: Zone key

    /// The zone's keyring, from the server when this device hasn't seen it there: adopted if it exists,
    /// else created (compare-and-set: create only; a device that loses adopts the winner's).
    func zoneKeyring(zone: String) async throws -> SyncZoneKeys.Keyring {
        if let local = try await db.read({ db in try SyncZoneKeys.local(zone: zone, db: db) }), local.systemFields != nil {
            return local.keyring
        }
        return try await refreshZoneKeyring(zone: zone, create: true)
    }

    @discardableResult
    func refreshZoneKeyring(zone: String, create: Bool) async throws -> SyncZoneKeys.Keyring {
        let name = SyncZoneKeys.recordName(zone: zone)
        let server: SyncServerRecord?
        do {
            server = try await transport.fetch(name, zone: zone)
        } catch SyncTransportError.networkUnavailable {
            throw SyncDocumentError.zoneKeyUnavailable
        }
        if let server {
            let now = clock()
            return try await db.write { db in try SyncZoneKeys.adopt(server, zone: zone, db: db, now: now) }
        }
        let local = try await db.read { db in try SyncZoneKeys.local(zone: zone, db: db) }
        guard create else {
            guard let local else { throw SyncDocumentError.zoneKeyUnavailable }
            return local.keyring
        }
        // A keyring known here but not on the server (the zone was reset) is published again as it is, so
        // data keys wrapped with it stay readable everywhere.
        let keyring = local?.keyring ?? SyncZoneKeys.Keyring(generation: 1, current: .init(DocumentCrypto.newZoneKey()), retired: [])
        let wire = try SyncZoneKeys.wire(keyring, zone: zone)
        let results: [SaveResult]
        do {
            results = try await transport.save([wire], ifUnchanged: [:], atomic: false)
        } catch SyncTransportError.networkUnavailable {
            throw SyncDocumentError.zoneKeyUnavailable
        }
        let now = clock()
        switch results.first?.outcome {
        case .saved(let stamp):
            try await db.write { db in try SyncZoneKeys.store(.init(keyring: keyring, systemFields: stamp.systemFields), zone: zone, db: db, now: now) }
            return keyring
        case .changed(let winner):
            // Another device created it first: its key is the zone's (nothing was sealed with this one).
            Self.documentLog.error("Zone key created by another device first; adopting it")
            return try await db.write { db in try SyncZoneKeys.adopt(winner, zone: zone, db: db, now: now) }
        default:
            throw SyncDocumentError.zoneKeyUnavailable
        }
    }

    /// Every data key known here that isn't wrapped with the zone's current key, and whose old key is known,
    /// re-wrapped with it; the document records here are queued to go again. Run after a rotation, after
    /// adopting a newer key, and when a record arrives wrapped with a retired key (a device that uploaded
    /// before it saw the rotation): whoever sees it re-wraps it. Returns how many were re-wrapped.
    static func rewrapStragglers(zone: String, db: Database, now: Date) throws -> Int {
        guard let keyring = try SyncZoneKeys.local(zone: zone, db: db)?.keyring else { return 0 }
        var count = 0
        for (uuid, reference) in try SyncDocumentFile.references(db: db) {
            guard let id = try? DocumentCrypto.zoneKeyId(ofWrapped: reference.wrappedKey), id != keyring.current.id,
                  let old = keyring.key(id: id),
                  let wrapped = try? DocumentCrypto.rewrap(reference.wrappedKey, from: old, to: keyring.current.key) else { continue }
            try SyncDocumentFile.setReference(SyncDocumentFileReference(recordName: reference.recordName, wrappedKey: wrapped), uuid: uuid, db: db, now: now)
            if let localId = try SyncRecordStore.localId(table: "document", uuid: uuid, db: db) {
                try SyncMerge.queue(uuid: uuid, table: "document", localId: localId, kind: .update, db: db)
            }
            count += 1
        }
        return count
    }

    // MARK: Push

    /// The document payloads of a push, with their file reference: the stored one (re-wrapped first if its
    /// key is retired), or, for a document whose file was never uploaded, its library file sealed now and
    /// saved as a file record before the document record goes. Returns the payloads to send (a document
    /// whose file couldn't be uploaded now waits: in `deferred`) and how many files were sealed.
    /// A device that doesn't sync files (no `SyncDocumentFiles`) still sends the references it holds, so an
    /// edit never drops a document's file from its record.
    func attachDocumentFiles(_ payloads: [SyncPayload]) async throws -> (payloads: [SyncPayload], deferred: Set<String>, sealed: Int) {
        guard payloads.contains(where: { $0.recordType == "document" && $0.mergedInto == nil }) else {
            return (payloads, [], 0)
        }
        let zone = SyncRecordStore.householdZone
        let now = clock()
        var references = try await db.read { db in
            try payloads.reduce(into: [String: SyncDocumentFileReference]()) { result, payload in
                if payload.recordType == "document", let reference = try SyncDocumentFile.reference(uuid: payload.recordName, db: db) {
                    result[payload.recordName] = reference
                }
            }
        }
        var toSeal: [(uuid: String, plaintext: Data, sha256: String)] = []
        var mismatched: [String] = []
        for payload in payloads where payload.recordType == "document" && payload.mergedInto == nil && references[payload.recordName] == nil {
            guard let documents, case .string(let sha) = payload.fields["sha256"], case .string(let stored) = payload.fields["storedRelativePath"],
                  let path = SyncDocumentFile.libraryPath(stored: stored, sha256: sha),
                  let plaintext = try? Data(contentsOf: documents.root.appendingPathComponent(path)) else {
                // No library file here: the record goes without one, as it came.
                continue
            }
            guard DocumentCrypto.sha256(plaintext) == sha.lowercased() else {
                mismatched.append(payload.recordName)
                continue
            }
            toSeal.append((payload.recordName, plaintext, sha.lowercased()))
        }
        if !mismatched.isEmpty {
            Self.documentLog.error("Sync didn't upload \(mismatched.count) library files that don't match their hash")
            let logged = mismatched
            try await db.write { db in
                for uuid in logged { try SyncDocumentFile.logAttention(uuid: uuid, message: SyncDocumentFile.senderMismatchMessage, db: db, now: now) }
            }
        }
        var deferred: Set<String> = []
        var sealed = 0
        // Files are sealed only under a key the server holds (created or adopted now); references already
        // held are checked against the keyring known here.
        var keyring = try await db.read { db in try SyncZoneKeys.local(zone: zone, db: db)?.keyring }
        if !toSeal.isEmpty {
            do {
                keyring = try await zoneKeyring(zone: zone)
            } catch SyncDocumentError.zoneKeyUnavailable {
                deferred.formUnion(toSeal.map(\.uuid))
                toSeal = []
            }
        }
        if let keyring, !toSeal.isEmpty {
            var wires: [SyncWireRecord] = []
            var pending: [String: (uuid: String, reference: SyncDocumentFileReference)] = [:]
            for item in toSeal {
                let box = try DocumentCrypto.seal(item.plaintext, zoneKey: keyring.current.key,
                                                  authenticating: DocumentCrypto.documentContext(uuid: item.uuid, sha256: item.sha256))
                let name = SyncDocumentFile.newRecordName(uuid: item.uuid)
                wires.append(SyncWireRecord(recordType: SyncDocumentFile.recordType, recordName: name, zone: zone,
                                            assets: [SyncDocumentFile.assetField: box.ciphertext]))
                pending[name] = (item.uuid, SyncDocumentFileReference(recordName: name, wrappedKey: box.wrappedKey))
            }
            let limits = await transport.operationLimits()
            var saved: [String: SyncDocumentFileReference] = [:]
            for operation in Self.operations(wires, limits: limits) {
                let results: [SaveResult]
                do {
                    results = try await transport.save(operation, ifUnchanged: [:], atomic: false)
                } catch SyncTransportError.networkUnavailable {
                    results = []
                }
                for result in results {
                    if case .saved = result.outcome, let item = pending[result.recordName] { saved[item.uuid] = item.reference }
                }
            }
            for item in toSeal where saved[item.uuid] == nil { deferred.insert(item.uuid) }
            sealed = saved.count
            let taken = saved
            try await db.write { db in
                for (uuid, reference) in taken { try SyncDocumentFile.setReference(reference, uuid: uuid, db: db, now: now) }
            }
            references.merge(saved) { _, new in new }
        }
        if let keyring {
            // A data key still wrapped with a retired zone key goes re-wrapped with the current one.
            var rewrapped: [String: SyncDocumentFileReference] = [:]
            for (uuid, reference) in references {
                guard let id = try? DocumentCrypto.zoneKeyId(ofWrapped: reference.wrappedKey), id != keyring.current.id,
                      let old = keyring.key(id: id), let wrapped = try? DocumentCrypto.rewrap(reference.wrappedKey, from: old, to: keyring.current.key)
                else { continue }
                rewrapped[uuid] = SyncDocumentFileReference(recordName: reference.recordName, wrappedKey: wrapped)
            }
            if !rewrapped.isEmpty {
                let updated = rewrapped
                try await db.write { db in
                    for (uuid, reference) in updated { try SyncDocumentFile.setReference(reference, uuid: uuid, db: db, now: now) }
                }
                references.merge(rewrapped) { _, new in new }
            }
        }
        let result = payloads.compactMap { payload -> SyncPayload? in
            guard payload.recordType == "document", payload.mergedInto == nil else { return payload }
            if deferred.contains(payload.recordName) { return nil }
            var payload = payload
            payload.documentFile = references[payload.recordName]
            return payload
        }
        return (result, deferred, sealed)
    }

    // MARK: Pull

    /// What a pull (or a refused save's merge) brought for document files: zone key records adopted, each
    /// document record's file reference kept (a deleted document's dropped), stragglers re-wrapped.
    static func takeDocumentFiles(zoneKeys: [SyncServerRecord], saves: [SyncPayload], deletions: [String], zone: String,
                                  db: Database, now: Date) throws {
        // The latest version of the zone key record (a feed lists it once).
        for record in zoneKeys { try SyncZoneKeys.adopt(record, zone: zone, db: db, now: now) }
        for payload in saves where payload.recordType == "document" && payload.mergedInto == nil {
            if let reference = payload.documentFile {
                try SyncDocumentFile.setReference(reference, uuid: payload.recordName, db: db, now: now)
            }
        }
        // Only once the row is gone here (a document linked by another record is never deleted, §5.3).
        for uuid in deletions where try SyncRecordStore.localId(table: "document", uuid: uuid, db: db) == nil {
            try SyncDocumentFile.setReference(nil, uuid: uuid, db: db, now: now)
        }
        _ = try rewrapStragglers(zone: zone, db: db, now: now)
    }

    /// The Mac keeps every file (sync spec §5.7): downloads each document's file missing from the library.
    func downloadMissingDocuments() async throws -> (downloaded: Int, needingAttention: Int) {
        guard let documents, documents.policy == .eager else { return (0, 0) }
        let candidates = try await db.read { db -> [String] in
            let rows = try Row.fetchAll(db, sql: """
                SELECT r.uuid, d.sha256, d.storedRelativePath FROM document d
                JOIN syncRecord r ON r.tableName = 'document' AND r.localId = d.id
                ORDER BY d.id
                """)
            var result: [String] = []
            for row in rows {
                let uuid: String = row["uuid"]
                guard let reference = try SyncDocumentFile.reference(uuid: uuid, db: db),
                      try SyncDocumentFile.failed(uuid: uuid, db: db) != reference else { continue }
                let path: String = row["storedRelativePath"]
                if let safe = SyncDocumentFile.libraryPath(stored: path, sha256: row["sha256"]),
                   FileManager.default.fileExists(atPath: documents.root.appendingPathComponent(safe).path) { continue }
                result.append(uuid)
            }
            return result
        }
        var downloaded = 0
        var attention = 0
        for uuid in candidates {
            do {
                _ = try await download(uuid: uuid)
                downloaded += 1
            } catch SyncDocumentError.hashMismatch, SyncDocumentError.unreadable, SyncDocumentError.unsafePath {
                attention += 1
            } catch {
                // Offline, or the disk refused the write: the rest waits for the next pull (the records applied).
                Self.documentLog.error("Sync document downloads stopped: \(String(describing: type(of: error)), privacy: .public)")
                break
            }
        }
        return (downloaded, attention)
    }

    /// Fetches, opens and checks one document's file, and places it in the library. Problems that need a
    /// person are logged (once per reference) and thrown.
    func download(uuid: String) async throws -> URL {
        guard let documents else { throw SyncDocumentError.notConfigured }
        let zone = SyncRecordStore.householdZone
        let found = try await db.read { db -> (String, String, SyncDocumentFileReference?)? in
            guard let id = try SyncRecordStore.localId(table: "document", uuid: uuid, db: db),
                  let row = try Row.fetchOne(db, sql: "SELECT sha256, storedRelativePath FROM document WHERE id = ?", arguments: [id])
            else { return nil }
            return (row["sha256"], row["storedRelativePath"], try SyncDocumentFile.reference(uuid: uuid, db: db))
        }
        guard let (sha, stored, reference) = found else { throw SyncDocumentError.documentNotFound }
        guard let reference else { throw SyncDocumentError.noFile }
        func attention(_ error: SyncDocumentError, _ message: String) async throws -> Never {
            let now = clock()
            try await db.write { db in
                try SyncDocumentFile.logAttention(uuid: uuid, message: message, db: db, now: now)
                try SyncDocumentFile.setFailed(reference, uuid: uuid, db: db, now: now)
            }
            Self.documentLog.error("Sync document file not saved: \(String(describing: error), privacy: .public)")
            throw error
        }
        guard let path = SyncDocumentFile.libraryPath(stored: stored, sha256: sha) else {
            try await attention(.unsafePath, SyncDocumentFile.unsafePathMessage)
        }
        let destination = documents.root.appendingPathComponent(path)
        if let existing = try? Data(contentsOf: destination), DocumentCrypto.sha256(existing) == sha.lowercased() { return destination }

        guard let record = try await transport.fetch(reference.recordName, zone: zone),
              let ciphertext = record.wire.assets[SyncDocumentFile.assetField],
              let id = try? DocumentCrypto.zoneKeyId(ofWrapped: reference.wrappedKey) else {
            try await attention(.unreadable, SyncDocumentFile.unreadableMessage)
        }
        var zoneKey = try await db.read { db in try SyncZoneKeys.local(zone: zone, db: db)?.keyring.key(id: id) }
        if zoneKey == nil {
            // A key this device hasn't seen yet (rotated elsewhere): read the zone's keyring again.
            zoneKey = try await refreshZoneKeyring(zone: zone, create: false).key(id: id)
        }
        guard let zoneKey,
              let plaintext = try? DocumentCrypto.open(ciphertext, wrappedKey: reference.wrappedKey, zoneKey: zoneKey,
                                                      authenticating: DocumentCrypto.documentContext(uuid: uuid, sha256: sha)) else {
            try await attention(.unreadable, SyncDocumentFile.unreadableMessage)
        }
        // Checked before anything is written: a file that isn't the record's never reaches the library.
        guard DocumentCrypto.sha256(plaintext) == sha.lowercased() else {
            try await attention(.hashMismatch, SyncDocumentFile.hashMismatchMessage)
        }
        // Placed the way the library places an added file: a timestamped temporary copy (removed as stale if a
        // crash leaves it), moved in; the same content already there counts as placed.
        let now = clock()
        try FileManager.default.createDirectory(at: documents.root, withIntermediateDirectories: true)
        EvidenceLibrary.removeStaleTemporaryFiles(in: documents.root, now: now)
        let temporary = documents.root.appendingPathComponent(
            "\(EvidenceLibrary.temporaryPrefix)\(Int(now.timeIntervalSince1970))-\(UUID().uuidString)")
        do {
            try plaintext.write(to: temporary)
            _ = try EvidenceLibrary.place(temporary, at: destination, sha256: sha.lowercased(), byteCount: Int64(plaintext.count))
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
        return destination
    }
}
