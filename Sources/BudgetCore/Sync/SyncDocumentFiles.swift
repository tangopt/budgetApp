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
/// with the zone key. It travels inside the record's sealed fields (`meta`); the file record's asset holds only
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
    /// The zone key the file needs isn't held here yet (iCloud Keychain hasn't delivered it): tried again later.
    case zoneKeyUnavailable
    /// The device doesn't sync files (no `SyncDocumentFiles`).
    case notConfigured
}

// MARK: Zone keys

/// The zone key's marker (ruling R15, sync spec §9.1). The key itself lives only in the key store (iCloud
/// Keychain, `SyncKeyStore`); the zone's `zoneKey` record names which key is current (its id) and when it was
/// made, neither of them secret, so every device seals under the same key. Created once per zone with
/// compare-and-set on the fixed record name: of two devices creating it, the server takes the first and the other
/// adopts it (it has sealed nothing yet). Rotation replaces it the same way, against the version last seen.
///
/// Each device keeps the marker in `syncState` (`zoneKeyMarker.<zone>`) with the version it last saw: no key
/// material. A step 3 keyring (`zoneKeys.<zone>`, key material) moves into the key store once and is deleted.
public enum SyncZoneKeys {
    private static let log = Logger(subsystem: "com.personal.budget", category: "Sync")
    public static let recordType = "zoneKey"
    static let keyIdField = "keyId"
    static let createdAtField = "createdAt"
    /// The step 3 record's field holding the keyring itself (key material): read only to migrate it.
    static let legacyKeysField = "keys"

    public static func recordName(zone: String) -> String { "zoneKey-" + zone }

    public struct Marker: Codable, Equatable, Sendable {
        /// The current zone key's id (`DocumentCrypto.zoneKeyId`).
        public var keyId: String
        public var createdAt: Date

        public init(keyId: String, createdAt: Date) {
            self.keyId = keyId
            self.createdAt = createdAt
        }
    }

    /// The marker a `zoneKey` record holds: exactly a key id (16 hex digits) and an 8-byte creation time, a
    /// finite number of seconds (a NaN or infinite bit pattern makes a `Date` that can't be stored, security review
    /// finding 1). The only error thrown is `SyncTransportError.unreadableRecord`, which every reader stages.
    public static func marker(from wire: SyncWireRecord) throws -> Marker {
        guard wire.recordType == recordType, wire.unencryptedFields.isEmpty, wire.assets.isEmpty,
              Set(wire.encryptedFields.keys) == [keyIdField, createdAtField],
              let idData = wire.encryptedFields[keyIdField], let id = String(data: idData, encoding: .utf8),
              id.count == 16, id.allSatisfy({ $0.isHexDigit && !$0.isUppercase }),
              let time = wire.encryptedFields[createdAtField], time.count == 8 else {
            throw SyncTransportError.unreadableRecord(wire.recordName)
        }
        let seconds = Double(bitPattern: time.reduce(UInt64(0)) { $0 << 8 | UInt64($1) })
        guard seconds.isFinite, abs(seconds) < 1e11 else { throw SyncTransportError.unreadableRecord(wire.recordName) }
        return Marker(keyId: id, createdAt: Date(timeIntervalSinceReferenceDate: seconds))
    }

    public static func wire(_ marker: Marker, zone: String) -> SyncWireRecord {
        var bits = marker.createdAt.timeIntervalSinceReferenceDate.bitPattern.bigEndian
        return SyncWireRecord(recordType: recordType, recordName: recordName(zone: zone), zone: zone,
                              encryptedFields: [keyIdField: Data(marker.keyId.utf8), createdAtField: Data(bytes: &bits, count: 8)])
    }

    /// This device's copy of the marker, and the system fields of the version it was last seen at (nil: not on
    /// the server yet, the zone was reset, or the server's version couldn't be read).
    struct Local: Codable, Equatable {
        var marker: Marker
        var systemFields: Data?
    }

    static func stateKey(_ zone: String) -> String { "zoneKeyMarker." + zone }

    static func local(zone: String, db: Database) throws -> Local? {
        guard let data = try Data.fetchOne(db, sql: "SELECT value FROM syncState WHERE key = ?", arguments: [stateKey(zone)]) else { return nil }
        return try JSONDecoder().decode(Local.self, from: data)
    }

    static func store(_ local: Local, zone: String, db: Database, now: Date) throws {
        try SyncImportGate.setState(try JSONEncoder().encode(local), key: stateKey(zone), db: db, now: now)
    }

    /// Takes the server's marker as this device's.
    @discardableResult
    static func adopt(_ server: SyncServerRecord, zone: String, db: Database, now: Date) throws -> Marker {
        let marker = try marker(from: server.wire)
        try store(Local(marker: marker, systemFields: server.stamp.systemFields), zone: zone, db: db, now: now)
        return marker
    }

    // MARK: Step 3 keyrings (migration)

    /// The step 3 keyring: the current key and the retired ones, as key material.
    struct LegacyKeyring: Codable, Equatable {
        struct Entry: Codable, Equatable {
            var id: String
            var keyData: Data
        }
        var generation: Int
        var current: Entry
        var retired: [Entry]

        /// Oldest first, so the current key is the newest one stored.
        var keys: [SymmetricKey] {
            ([current] + retired).reversed().filter { $0.keyData.count == 32 }.map { SymmetricKey(data: $0.keyData) }
        }
    }

    struct LegacyLocal: Codable {
        var keyring: LegacyKeyring
        var systemFields: Data?
    }

    static func legacyStateKey(_ zone: String) -> String { "zoneKeys." + zone }

    /// A step 3 `zoneKey` record's keyring (key material on the server), if that is what `wire` is.
    static func legacyKeyring(from wire: SyncWireRecord) -> LegacyKeyring? {
        guard wire.recordType == recordType, let data = wire.encryptedFields[legacyKeysField] else { return nil }
        return try? JSONDecoder().decode(LegacyKeyring.self, from: data)
    }

    /// Ruling R15 decision 6: a step 3 keyring kept in `syncState` moves into the key store once (every key, the
    /// current one last), becomes this device's marker (unconfirmed: the server is asked again before sealing),
    /// and is deleted. Returns whether there was one. If the key store refuses, nothing is deleted.
    @discardableResult
    static func migrateLocalKeyring(zone: String, db: any DatabaseWriter, keyStore: any SyncKeyStore, now: Date) throws -> Bool {
        guard let data = try db.read({ db in
            try Data.fetchOne(db, sql: "SELECT value FROM syncState WHERE key = ?", arguments: [legacyStateKey(zone)])
        }) else { return false }
        if let legacy = try? JSONDecoder().decode(LegacyLocal.self, from: data) {
            for key in legacy.keyring.keys { try keyStore.store(key, zone: zone) }
            let marker = Marker(keyId: legacy.keyring.current.id, createdAt: now)
            try db.write { db in
                if try local(zone: zone, db: db) == nil { try store(Local(marker: marker, systemFields: nil), zone: zone, db: db, now: now) }
                try db.execute(sql: "DELETE FROM syncState WHERE key = ?", arguments: [legacyStateKey(zone)])
            }
        } else {
            // Not a keyring this build can read, and possibly the only copy of key material: set aside under another
            // key (never deleted; security review finding 3), so the next start finds nothing to move.
            Self.log.error("Sync step 3 keyring in syncState can't be read; set aside")
            try db.write { db in
                try db.execute(sql: "UPDATE syncState SET key = ? WHERE key = ?",
                               arguments: [legacyStateKey(zone) + ".unreadable-\(Int(now.timeIntervalSince1970))", legacyStateKey(zone)])
            }
        }
        return true
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

    // MARK: Household key

    /// The zone's current key and its id.
    struct HouseholdKey: Sendable {
        var id: String
        var key: SymmetricKey
    }

    /// The zone's current key (ruling R15): the one the marker names, from the key store. The server's marker is
    /// read when this device hasn't confirmed one there: adopted if it exists, else (with `create`) published, for
    /// a new key stored in the key store first (or the newest one held, after a zone reset). Throws
    /// `SyncKeyError.waitingForHouseholdKey` when the marker names a key not held here (nothing is created then),
    /// `SyncKeyError.unavailable` when the marker can't be read or published now.
    func householdKey(zone: String, create: Bool) async throws -> HouseholdKey {
        if let local = try await db.read({ db in try SyncZoneKeys.local(zone: zone, db: db) }), local.systemFields != nil {
            return try heldKey(local.marker.keyId, zone: zone)
        }
        return try await refreshHouseholdKey(zone: zone, create: create)
    }

    /// The key `id` from the key store, or "waiting" for it.
    func heldKey(_ id: String, zone: String) throws -> HouseholdKey {
        guard let key = try keyStore.allKeys(zone: zone)[id] else { throw SyncKeyError.waitingForHouseholdKey }
        return HouseholdKey(id: id, key: key)
    }

    func refreshHouseholdKey(zone: String, create: Bool) async throws -> HouseholdKey {
        let name = SyncZoneKeys.recordName(zone: zone)
        let server: SyncServerRecord?
        do {
            server = try await transport.fetch(name, zone: zone)
        } catch let error as SyncTransportError where error.isPassing {
            throw SyncKeyError.unavailable
        }
        let now = clock()
        if let server {
            if (try? SyncZoneKeys.marker(from: server.wire)) != nil {
                let marker = try await db.write { db in try SyncZoneKeys.adopt(server, zone: zone, db: db, now: now) }
                return try heldKey(marker.keyId, zone: zone)
            }
            if let legacy = SyncZoneKeys.legacyKeyring(from: server.wire) {
                // A step 3 record holding the keyring itself: its keys go to the key store, and the record is replaced
                // by the marker of its current key, so no key material stays on the server.
                for key in legacy.keys { try keyStore.store(key, zone: zone) }
                return try await publish(SyncZoneKeys.Marker(keyId: legacy.current.id, createdAt: now), over: server.stamp.systemFields, zone: zone)
            }
            // The server's marker can't be read here (final review I2): never replaced from here; sealing waits.
            Self.documentLog.error("Sync zone key marker on the server can't be read; waiting")
            throw SyncKeyError.unavailable
        }
        let local = try await db.read { db in try SyncZoneKeys.local(zone: zone, db: db) }
        let held = try keyStore.allKeys(zone: zone)
        guard create else {
            guard let local else { throw SyncKeyError.unavailable }
            return try heldKey(local.marker.keyId, zone: zone)
        }
        // Not on the server (a new zone, or a reset): the key known here is published again, so what it sealed stays
        // readable; else the newest key held; else a new one, kept in the key store before the marker names it.
        let marker: SyncZoneKeys.Marker
        if let local, held[local.marker.keyId] != nil {
            marker = local.marker
        } else if let newest = try keyStore.key(zone: zone) {
            marker = SyncZoneKeys.Marker(keyId: DocumentCrypto.zoneKeyId(newest), createdAt: now)
        } else {
            let key = DocumentCrypto.newZoneKey()
            try keyStore.store(key, zone: zone)
            marker = SyncZoneKeys.Marker(keyId: DocumentCrypto.zoneKeyId(key), createdAt: now)
        }
        return try await publish(marker, over: nil, zone: zone)
    }

    /// Saves `marker` over the version `systemFields` names (nil: create only). A device that loses adopts the
    /// server's marker (it sealed nothing with its own key).
    private func publish(_ marker: SyncZoneKeys.Marker, over systemFields: Data?, zone: String) async throws -> HouseholdKey {
        let wire = SyncZoneKeys.wire(marker, zone: zone)
        let results: [SaveResult]
        do {
            results = try await transport.save([wire], ifUnchanged: systemFields.map { [wire.recordName: $0] } ?? [:], atomic: false)
        } catch let error as SyncTransportError where error.isPassing {
            throw SyncKeyError.unavailable
        }
        let now = clock()
        switch results.first?.outcome {
        case .saved(let stamp):
            try await db.write { db in try SyncZoneKeys.store(.init(marker: marker, systemFields: stamp.systemFields), zone: zone, db: db, now: now) }
            return try heldKey(marker.keyId, zone: zone)
        case .changed(let winner):
            Self.documentLog.error("Zone key marker written by another device first; adopting it")
            guard let adopted = try? SyncZoneKeys.marker(from: winner.wire) else { throw SyncKeyError.unavailable }
            try await db.write { db in try SyncZoneKeys.store(.init(marker: adopted, systemFields: winner.stamp.systemFields), zone: zone, db: db, now: now) }
            return try heldKey(adopted.keyId, zone: zone)
        default:
            throw SyncKeyError.unavailable
        }
    }

    /// A new zone key (a member removed, sync spec §9.1): stored in the key store, then its marker saved over the
    /// version last seen; if another device changed it meanwhile, its marker is adopted instead. Every data key
    /// known here is re-wrapped with the current key and its document record sent again; no file is uploaded again.
    @discardableResult
    public func rotateZoneKey() async throws -> SyncZoneKeyRotation {
        try await serialized {
            try await self.prepare()
            let zone = SyncRecordStore.householdZone
            _ = try await self.householdKey(zone: zone, create: true)
            let systemFields = try await self.db.read { db in try SyncZoneKeys.local(zone: zone, db: db)?.systemFields }
            let key = DocumentCrypto.newZoneKey()
            try self.keyStore.store(key, zone: zone)
            let marker = SyncZoneKeys.Marker(keyId: DocumentCrypto.zoneKeyId(key), createdAt: self.clock())
            let wire = SyncZoneKeys.wire(marker, zone: zone)
            let results = try await self.transport.save([wire], ifUnchanged: systemFields.map { [wire.recordName: $0] } ?? [:], atomic: false)
            let now = self.clock()
            switch results.first?.outcome {
            case .saved(let stamp):
                try await self.db.write { db in try SyncZoneKeys.store(.init(marker: marker, systemFields: stamp.systemFields), zone: zone, db: db, now: now) }
            case .changed(let server):
                // Another device rotated (or created) it first: its key is the zone's.
                Self.documentLog.error("Zone key changed on another device during rotation; adopting it")
                guard let adopted = try? SyncZoneKeys.marker(from: server.wire) else { throw SyncKeyError.unavailable }
                try await self.db.write { db in try SyncZoneKeys.store(.init(marker: adopted, systemFields: server.stamp.systemFields), zone: zone, db: db, now: now) }
            case .deleted:
                try await self.db.write { db in try SyncZoneKeys.store(.init(marker: marker, systemFields: nil), zone: zone, db: db, now: now) }
                _ = try await self.householdKey(zone: zone, create: true)
            default:
                throw SyncKeyError.unavailable
            }
            let keys = try self.keyStore.allKeys(zone: zone)
            let rewrapped = try await self.db.write { db in try Self.rewrapStragglers(zone: zone, keys: keys, db: db, now: now) }
            return SyncZoneKeyRotation(rewrapped: rewrapped, push: try await self.pushAll())
        }
    }

    /// Every data key known here that isn't wrapped with the zone's current key, and whose old key is held,
    /// re-wrapped with it; the document records here are queued to go again. Run after a rotation, after
    /// adopting a newer marker, and when a record arrives wrapped with a retired key (a device that uploaded
    /// before it saw the rotation): whoever sees it re-wraps it. Returns how many were re-wrapped.
    static func rewrapStragglers(zone: String, keys: [String: SymmetricKey], db: Database, now: Date) throws -> Int {
        guard let currentId = try SyncZoneKeys.local(zone: zone, db: db)?.marker.keyId, let current = keys[currentId] else { return 0 }
        var count = 0
        for (uuid, reference) in try SyncDocumentFile.references(db: db) {
            guard let id = try? DocumentCrypto.zoneKeyId(ofWrapped: reference.wrappedKey), id != currentId,
                  let old = keys[id],
                  let wrapped = try? DocumentCrypto.rewrap(reference.wrappedKey, from: old, to: current) else { continue }
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
    func attachDocumentFiles(_ payloads: [SyncPayload], key: HouseholdKey, keys: [String: SymmetricKey]) async throws
        -> (payloads: [SyncPayload], deferred: Set<String>, sealed: Int) {
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
        // Files are sealed under the zone's current key (the push confirmed it with the server's marker).
        if !toSeal.isEmpty {
            var wires: [SyncWireRecord] = []
            var pending: [String: (uuid: String, reference: SyncDocumentFileReference)] = [:]
            for item in toSeal {
                let box = try DocumentCrypto.seal(item.plaintext, zoneKey: key.key,
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
                } catch let error as SyncTransportError where error.isPassing {
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
        do {
            // A data key still wrapped with a retired zone key goes re-wrapped with the current one.
            var rewrapped: [String: SyncDocumentFileReference] = [:]
            for (uuid, reference) in references {
                guard let id = try? DocumentCrypto.zoneKeyId(ofWrapped: reference.wrappedKey), id != key.id,
                      let old = keys[id], let wrapped = try? DocumentCrypto.rewrap(reference.wrappedKey, from: old, to: key.key)
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

    /// What a pull (or a refused save's merge) brought for document files: the zone key marker adopted, each
    /// document record's file reference kept (a deleted document's dropped), stragglers re-wrapped.
    /// Returns how many zone key records couldn't be read (staged for attention).
    @discardableResult
    static func takeDocumentFiles(zoneKeys: [SyncServerRecord], saves: [SyncPayload], deletions: [String], zone: String,
                                  keyStore: any SyncKeyStore, db: Database, now: Date) throws -> Int {
        // The latest version of the marker (a feed lists it once). One that can't be read never rolls back the
        // pull (final review I2): it is staged for attention with its type, and the marker here is no longer taken
        // as confirmed (follow-up: the next push asks the server again, and waits while it can't read it); a
        // readable version arriving later is adopted and clears it.
        var unreadable = 0
        for record in zoneKeys {
            // Only the parse can refuse (and it only throws `unreadableRecord`); a database error still rolls back.
            if let marker = try? SyncZoneKeys.marker(from: record.wire) {
                try SyncZoneKeys.store(.init(marker: marker, systemFields: record.stamp.systemFields), zone: zone, db: db, now: now)
                try db.execute(sql: "DELETE FROM syncStaging WHERE uuid = ? AND tableName = ?",
                               arguments: [record.wire.recordName, SyncZoneKeys.recordType])
            } else {
                if let legacy = SyncZoneKeys.legacyKeyring(from: record.wire) {
                    // A step 3 record: its keys are kept (what they sealed stays readable); the next push replaces it.
                    for key in legacy.keys { try keyStore.store(key, zone: zone) }
                } else {
                    try SyncTranslator.stageUnreadable(recordType: SyncZoneKeys.recordType, recordName: record.wire.recordName, db: db, now: now)
                    unreadable += 1
                }
                if var local = try SyncZoneKeys.local(zone: zone, db: db) {
                    local.systemFields = nil
                    try SyncZoneKeys.store(local, zone: zone, db: db, now: now)
                }
            }
        }
        for payload in saves where payload.recordType == "document" && payload.mergedInto == nil {
            if let reference = payload.documentFile {
                try SyncDocumentFile.setReference(reference, uuid: payload.recordName, db: db, now: now)
            }
        }
        // Only once the row is gone here (a document linked by another record is never deleted, §5.3).
        for uuid in deletions where try SyncRecordStore.localId(table: "document", uuid: uuid, db: db) == nil {
            try SyncDocumentFile.setReference(nil, uuid: uuid, db: db, now: now)
        }
        _ = try rewrapStragglers(zone: zone, keys: try keyStore.allKeys(zone: zone), db: db, now: now)
        return unreadable
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
        guard let zoneKey = try keyStore.allKeys(zone: zone)[id] else {
            // A key iCloud Keychain hasn't delivered here yet (made or rotated on another device): tried again later.
            throw SyncDocumentError.zoneKeyUnavailable
        }
        guard let plaintext = try? DocumentCrypto.open(ciphertext, wrappedKey: reference.wrappedKey, zoneKey: zoneKey,
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
