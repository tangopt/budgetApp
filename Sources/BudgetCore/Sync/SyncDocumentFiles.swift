import CryptoKit
import Foundation
import GRDB
import os

/// Where this device keeps the files that travel with records — evidence files and the copies of files kept
/// for later — and when it downloads them (sync spec §5.7): the Mac always keeps them (`eager`: every pull
/// downloads what is missing); the iPhone downloads a file when it is opened (`lazy`:
/// `SyncEngineCore.downloadDocument`).
public struct SyncDocumentFiles: Sendable {
    public enum Policy: Sendable, Equatable {
        case eager
        case lazy
    }

    /// The evidence library's root (`EvidenceLibrary.root`).
    public var root: URL
    /// The waiting list's root (`ImportWaitingList.root`).
    public var waitingRoot: URL
    public var policy: Policy

    /// `waitingRoot`: nil, `Waiting` beside the library's folder (where `ImportSession` keeps files).
    public init(root: URL, policy: Policy, waitingRoot: URL? = nil) {
        self.root = root
        self.policy = policy
        self.waitingRoot = waitingRoot ?? root.deletingLastPathComponent().appendingPathComponent("Waiting", isDirectory: true)
    }

    /// The file-bearing tables, with where each one's files go here.
    public var tables: [SyncFileTable] { SyncFileTables.standard(libraryRoot: root, waitingRoot: waitingRoot) }

    func table(_ name: String) -> SyncFileTable? { tables.first { $0.table == name } }
}

/// A synced table whose rows each carry one file (sync spec §9.1): the row's record holds the reference of a
/// sealed `documentFile` record; the file itself lives under `root`, at a path derived from its hash (a synced
/// path is never trusted as is). Both tables keep the file's hash in `sha256` and its path in `storedRelativePath`.
public struct SyncFileTable: Sendable {
    public let table: String
    public let root: URL

    init(table: String, root: URL) {
        self.table = table
        self.root = root
    }

    /// The path under `root` that `stored` must be for this hash, if it is (nil: unsafe, never read or written).
    /// - `document`: the library path (`EvidenceLibrary.storedRelativePath`).
    /// - `importWaitingFile`: `"<sha256>/<name>"`, the hash already 64 lowercase hex digits (never lowercased
    ///   here: a row in capitals is unsafe), the name one plain path component (not `.`/`..`, no leading dot, no
    ///   `/` or NUL, at most 255 UTF-8 bytes; `ImportWaitingList.storedPath`).
    public func safePath(stored: String, sha256: String) -> String? {
        switch table {
        case SyncFileTables.document:
            return SyncDocumentFile.libraryPath(stored: stored, sha256: sha256)
        case SyncFileTables.importWaitingFile:
            guard let slash = stored.firstIndex(of: "/") else { return nil }
            let name = String(stored[stored.index(after: slash)...])
            guard let path = ImportWaitingList.storedPath(sha256: sha256, name: name), path == stored else { return nil }
            return path
        default:
            return nil
        }
    }

    /// The authenticated context of a file of this table (`DocumentCrypto.fileContext`).
    func context(uuid: String, sha256: String) -> Data {
        DocumentCrypto.fileContext(table: table, uuid: uuid, sha256: sha256)
    }

    /// The message logged when the row's path is unsafe.
    var unsafePathMessage: String {
        table == SyncFileTables.document ? SyncDocumentFile.unsafePathMessage : SyncDocumentFile.unsafeWaitingPathMessage
    }
}

public enum SyncFileTables {
    static let document = "document"
    static let importWaitingFile = "importWaitingFile"
    /// Every file-bearing table (their file references are kept even on a device that doesn't sync files).
    public static let names: Set<String> = [document, importWaitingFile]

    /// Evidence documents in the library, files kept for later in the waiting folder.
    public static func standard(libraryRoot: URL, waitingRoot: URL) -> [SyncFileTable] {
        [SyncFileTable(table: document, root: libraryRoot), SyncFileTable(table: importWaitingFile, root: waitingRoot)]
    }

    /// The file-bearing table and local id of the record `uuid` here, if it names such a row.
    static func row(uuid: String, db: Database) throws -> (table: String, localId: Int64)? {
        guard let row = try Row.fetchOne(db.cachedStatement(sql: "SELECT tableName, localId FROM syncRecord WHERE uuid = ?"),
                                         arguments: [uuid]) else { return nil }
        let table: String = row["tableName"]
        guard names.contains(table) else { return nil }
        return (table, row["localId"])
    }

    /// The record UUID of the document stored at `storedRelativePath` (the iPad's Documents screen opens a document by
    /// its stored path, `SyncEngineCore.downloadDocument` by its record); nil when no synced document is there.
    public static func documentUUID(storedRelativePath: String, db: Database) throws -> String? {
        guard let id = try Int64.fetchOne(db, sql: "SELECT id FROM document WHERE storedRelativePath = ? ORDER BY id LIMIT 1",
                                          arguments: [storedRelativePath]) else { return nil }
        return try SyncRecordStore.existingUUID(table: document, localId: id, db: db)
    }

    /// Whether `url` is a regular file (not a symbolic link, not a folder), as it is, without following a link.
    static func isRegularFile(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType) == .typeRegular
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

/// The record holding one sealed file (a document's, or a waiting file's copy): its asset is the ciphertext
/// and nothing else of the file. Written once (a new name per sealing); rotation never touches it. Each device
/// keeps the reference of every file-bearing row it knows in `syncState` (`documentFile.<uuid>`; UUIDs are
/// unique across tables), so an edit sends it unchanged.
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
    static let unsafeWaitingPathMessage = SyncTranslator.needsAttention + "the kept file's name or path can't be used; not saved"
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

    static func logAttention(table: String = SyncFileTables.document, uuid: String, message: String, db: Database, now: Date) throws {
        try SyncMerge.logConflict(table: table, uuid: uuid, field: conflictField, losing: .string(message), winner: nil, loser: nil,
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
    /// a document, sync spec §5.7); for a waiting file's record, its copy into the waiting folder. Returns where it is. A file whose SHA-256 isn't the record's is never
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
            keyTransportError = error
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
            // No marker on the server, none known here: an iPad (step 8) waits for the Mac to publish the key.
            guard let local else { throw mode.ownsZones ? SyncKeyError.unavailable : SyncKeyError.waitingForHouseholdKey }
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
            keyTransportError = error
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
        // Only the Mac makes keys (step 8).
        guard mode.ownsZones else { throw ReadOnlyError.readOnly }
        return try await serialized { try await self.rotateZoneKeyNow() }
    }

    /// `rotateZoneKey`'s work, inside an entry point already serialized (`finishKeyRevocation` runs it too).
    func rotateZoneKeyNow() async throws -> SyncZoneKeyRotation {
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

    /// Every data key known here that isn't wrapped with the zone's current key, and whose old key is held,
    /// re-wrapped with it; the records holding them here are queued to go again. Run after a rotation, after
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
            if let row = try SyncFileTables.row(uuid: uuid, db: db) {
                try SyncMerge.queue(uuid: uuid, table: row.table, localId: row.localId, kind: .update, db: db)
            }
            count += 1
        }
        return count
    }

    // MARK: Push

    /// A zone's file-bearing payloads with their file references, before anything is uploaded or stored.
    struct SealedFiles {
        /// The payloads, each file-bearing one carrying its reference (none when there is no file to give it).
        var payloads: [SyncPayload]
        /// File records to save first, by the row they belong to, with the reference each gives its row.
        var files: [(uuid: String, wire: SyncWireRecord, reference: SyncDocumentFileReference)] = []
        /// References to keep here once their rows' records are saved (new sealings and re-wrapped keys).
        var references: [String: SyncDocumentFileReference] = [:]
        /// Rows whose file at the hash's path doesn't match the hash (needs attention, never uploaded).
        var mismatched: [(uuid: String, table: String)] = []
        /// Rows that had to be sealed again (a move) and have no file anywhere (none here, none on the server): they go
        /// without one, as they came.
        var unsealable: [String] = []
        /// Moving rows whose file is on the server but couldn't be sealed for the new zone yet (not here, and the old
        /// zone's file record couldn't be fetched or opened): they wait, still pending, and their old file stays.
        var held: [String] = []
        /// An iPad's rows (step 8) with neither a file reference known here nor their file: never sent without one (the
        /// server's would be lost); they wait, still pending, for a pull to bring it.
        var waiting: [String] = []
    }

    /// The file-bearing payloads of `zone` (`SyncFileTables`: documents, waiting files) with their file reference:
    /// the stored one (re-wrapped if its key is retired), or, for a row whose file was never uploaded (or that must be
    /// sealed again, `reseal`: a record moving to another zone, by the zone it leaves), its file (at the path its hash
    /// gives, a regular file) sealed now under its table's context and the zone's key. A moving row whose file isn't
    /// here is sealed from the old zone's file record (this device holds both zones' keys): fetched, opened and checked
    /// against the hash, never deleted before its new copy exists. Nothing is uploaded or stored here: the caller checks
    /// the payloads, uploads `files` (`uploadFileRecords`) and keeps `references` once the records are saved.
    /// A device that doesn't sync files (no `SyncDocumentFiles`) still sends the references it holds, so an edit
    /// never drops a file from its record.
    func sealDocumentFiles(_ payloads: [SyncPayload], key: HouseholdKey, keys: [String: SymmetricKey], zone: String,
                           reseal: [String: String] = [:]) async throws -> SealedFiles {
        @Sendable func carriesFile(_ payload: SyncPayload) -> Bool {
            SyncFileTables.names.contains(payload.recordType) && payload.mergedInto == nil && payload.movedTo == nil
        }
        var result = SealedFiles(payloads: payloads)
        guard payloads.contains(where: carriesFile) else { return result }
        let stored = try await db.read { db in
            try payloads.reduce(into: [String: SyncDocumentFileReference]()) { result, payload in
                if carriesFile(payload), reseal[payload.recordName] == nil,
                   let reference = try SyncDocumentFile.reference(uuid: payload.recordName, db: db) {
                    result[payload.recordName] = reference
                }
            }
        }
        var references = stored
        for payload in payloads where carriesFile(payload) && references[payload.recordName] == nil {
            let leaving = reseal[payload.recordName]
            guard case .string(let sha) = payload.fields["sha256"] else {
                if leaving != nil { result.unsealable.append(payload.recordName) }
                continue
            }
            var plaintext: Data?
            if let table = documents?.table(payload.recordType), case .string(let path) = payload.fields["storedRelativePath"],
               let safe = table.safePath(stored: path, sha256: sha) {
                let url = table.root.appendingPathComponent(safe)
                if SyncFileTables.isRegularFile(url), let data = try? Data(contentsOf: url) {
                    if DocumentCrypto.sha256(data) == sha.lowercased() {
                        plaintext = data
                    } else {
                        result.mismatched.append((payload.recordName, table.table))
                    }
                }
            }
            if plaintext == nil, let leaving {
                // Not here: the file the record leaves behind is sealed again from the old zone's copy.
                switch try await fileLeftBehind(uuid: payload.recordName, table: payload.recordType, sha256: sha, zone: leaving) {
                case .opened(let data): plaintext = data
                case .none: result.unsealable.append(payload.recordName)
                case .unavailable: result.held.append(payload.recordName)
                }
            }
            guard let plaintext else {
                // A stored reference goes unchanged and a file not here is never uploaded again (step 8): an iPad without
                // either sends nothing of the row rather than a record with no file.
                if !mode.ownsZones, leaving == nil { result.waiting.append(payload.recordName) }
                continue
            }
            // Sealed under the zone's current key (the push confirmed it with the server's marker).
            let box = try DocumentCrypto.seal(plaintext, zoneKey: key.key,
                                              authenticating: DocumentCrypto.fileContext(table: payload.recordType, uuid: payload.recordName,
                                                                                         sha256: sha.lowercased()))
            let name = SyncDocumentFile.newRecordName(uuid: payload.recordName)
            let reference = SyncDocumentFileReference(recordName: name, wrappedKey: box.wrappedKey)
            result.files.append((payload.recordName,
                                 SyncWireRecord(recordType: SyncDocumentFile.recordType, recordName: name, zone: zone,
                                                assets: [SyncDocumentFile.assetField: box.ciphertext]),
                                 reference))
            references[payload.recordName] = reference
            result.references[payload.recordName] = reference
        }
        // A data key still wrapped with a retired zone key goes re-wrapped with the current one.
        for (uuid, reference) in stored {
            guard let id = try? DocumentCrypto.zoneKeyId(ofWrapped: reference.wrappedKey), id != key.id,
                  let old = keys[id], let wrapped = try? DocumentCrypto.rewrap(reference.wrappedKey, from: old, to: key.key)
            else { continue }
            let rewrapped = SyncDocumentFileReference(recordName: reference.recordName, wrappedKey: wrapped)
            references[uuid] = rewrapped
            result.references[uuid] = rewrapped
        }
        result.payloads = payloads.map { payload in
            guard carriesFile(payload) else { return payload }
            var payload = payload
            payload.documentFile = references[payload.recordName]
            return payload
        }
        return result
    }

    enum FileLeftBehind {
        case opened(Data)
        /// The record names no file there: nothing to move.
        case none
        /// It names one this device can't fetch or open now.
        case unavailable
    }

    /// The file a moving row's copy in `zone` names (its stored reference), fetched from there and opened with that
    /// zone's key, checked against the row's hash.
    func fileLeftBehind(uuid: String, table: String, sha256 sha: String, zone: String) async throws -> FileLeftBehind {
        guard let reference = try await db.read({ db in try SyncDocumentFile.reference(uuid: uuid, db: db) }) else { return .none }
        let record: SyncServerRecord?
        do {
            record = try await transport.fetch(reference.recordName, zone: zone)
        } catch let error as SyncTransportError where error.isPassing {
            return .unavailable
        }
        guard let ciphertext = record?.wire.assets[SyncDocumentFile.assetField],
              let id = try? DocumentCrypto.zoneKeyId(ofWrapped: reference.wrappedKey),
              let zoneKey = try keyStore.allKeys(zone: zone)[id],
              let plaintext = try? DocumentCrypto.open(ciphertext, wrappedKey: reference.wrappedKey, zoneKey: zoneKey,
                                                      authenticating: DocumentCrypto.fileContext(table: table, uuid: uuid, sha256: sha.lowercased())),
              DocumentCrypto.sha256(plaintext) == sha.lowercased()
        else { return .unavailable }
        return .opened(plaintext)
    }

    /// Saves file records (create only); returns the rows whose file record the server took. A passing failure
    /// takes none of that operation.
    func uploadFileRecords(_ files: [(uuid: String, wire: SyncWireRecord, reference: SyncDocumentFileReference)]) async throws -> Set<String> {
        guard !files.isEmpty else { return [] }
        let byName = Dictionary(files.map { ($0.wire.recordName, $0.uuid) }, uniquingKeysWith: { a, _ in a })
        let limits = await transport.operationLimits()
        var saved: Set<String> = []
        for operation in Self.operations(files.map(\.wire), limits: limits) {
            let results: [SaveResult]
            do {
                results = try await transport.save(operation, ifUnchanged: [:], atomic: false)
            } catch let error as SyncTransportError where error.isPassing {
                results = []
            }
            for result in results {
                if case .saved = result.outcome, let uuid = byName[result.recordName] { saved.insert(uuid) }
            }
        }
        return saved
    }

    /// Logs the rows whose file doesn't match its hash (needs attention; never uploaded).
    func logMismatchedFiles(_ mismatched: [(uuid: String, table: String)]) async throws {
        guard !mismatched.isEmpty else { return }
        Self.documentLog.error("Sync didn't upload \(mismatched.count) files that don't match their hash")
        let now = clock()
        try await db.write { db in
            for item in mismatched {
                try SyncDocumentFile.logAttention(table: item.table, uuid: item.uuid, message: SyncDocumentFile.senderMismatchMessage, db: db, now: now)
            }
        }
    }

    /// Moving rows whose file couldn't be sealed for their new zone (they wait): logged for attention once each.
    func logHeldFiles(_ held: [String], tables: [String: String]) async throws {
        guard !held.isEmpty else { return }
        Self.documentLog.error("Sync held back \(held.count) moving records whose files couldn't be moved yet")
        let now = clock()
        let message = SyncEngineCore.fileNotMovedMessage
        try await db.write { db in
            for uuid in held {
                let logged = try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM syncConflict WHERE uuid = ? AND losingValueJSON LIKE ?)",
                                               arguments: [uuid, "%" + message + "%"]) ?? false
                if !logged {
                    try SyncDocumentFile.logAttention(table: tables[uuid] ?? SyncFileTables.document, uuid: uuid, message: message, db: db, now: now)
                }
            }
        }
    }

    // MARK: Pull

    /// What a pull (or a refused save's merge) brought for files: the zone key marker adopted, each file-bearing
    /// record's file reference kept (a deleted row's dropped), stragglers re-wrapped.
    /// Returns how many zone key records couldn't be read (staged for attention).
    @discardableResult
    /// `cleansFiles` (a device that writes `zone`): a deleted row's sealed file record is deleted there too (final
    /// review I-1: the delete came back on a pull before its push heard of it, or another device of the owner's made it).
    static func takeDocumentFiles(zoneKeys: [SyncServerRecord], saves: [SyncPayload], deletions: [String], zone: String,
                                  keyStore: any SyncKeyStore, db: Database, now: Date, cleansFiles: Bool = false) throws -> Int {
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
        for payload in saves where SyncFileTables.names.contains(payload.recordType) && payload.mergedInto == nil {
            if let reference = payload.documentFile {
                try SyncDocumentFile.setReference(reference, uuid: payload.recordName, db: db, now: now)
            } else if payload.movedTo != nil, try SyncFileTables.row(uuid: payload.recordName, db: db) == nil {
                // A move marker took the row out of view here (a zone this device doesn't follow): its file reference goes too.
                try SyncDocumentFile.setReference(nil, uuid: payload.recordName, db: db, now: now)
            }
        }
        // Only once the row is gone here (a document linked by another record is never deleted, §5.3).
        for uuid in deletions {
            guard try SyncFileTables.row(uuid: uuid, db: db) == nil else {
                // Kept here (a linked document is sent again, §5.3): the deleting device takes the file it knew, so
                // what goes from here is sealed again, never a reference to a file record that may be gone.
                if cleansFiles { try SyncDocumentFile.setReference(nil, uuid: uuid, db: db, now: now) }
                continue
            }
            if cleansFiles, let file = try SyncDocumentFile.reference(uuid: uuid, db: db) {
                try SyncCleanup.add(zone: zone, recordName: file.recordName, db: db)
            }
            try SyncDocumentFile.setReference(nil, uuid: uuid, db: db, now: now)
        }
        _ = try rewrapStragglers(zone: zone, keys: try keyStore.allKeys(zone: zone), db: db, now: now)
        return unreadable
    }

    /// The Mac keeps every file (sync spec §5.7): downloads each file-bearing row's file missing here (documents
    /// into the library, waiting files into the waiting folder).
    func downloadMissingDocuments() async throws -> (downloaded: Int, needingAttention: Int) {
        guard let documents, documents.policy == .eager else { return (0, 0) }
        let tables = documents.tables
        let candidates = try await db.read { db -> [String] in
            var result: [String] = []
            for table in tables {
                let name = SyncChangeTracker.quoted(table.table)
                let rows = try Row.fetchAll(db, sql: """
                    SELECT r.uuid, t.sha256, t.storedRelativePath FROM \(name) t
                    JOIN syncRecord r ON r.tableName = ? AND r.localId = t.id
                    ORDER BY t.id
                    """, arguments: [table.table])
                for row in rows {
                    let uuid: String = row["uuid"]
                    guard let reference = try SyncDocumentFile.reference(uuid: uuid, db: db),
                          try SyncDocumentFile.failed(uuid: uuid, db: db) != reference else { continue }
                    let path: String = row["storedRelativePath"]
                    if let safe = table.safePath(stored: path, sha256: row["sha256"]),
                       SyncFileTables.isRegularFile(table.root.appendingPathComponent(safe)) { continue }
                    result.append(uuid)
                }
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

    /// Fetches, opens and checks one row's file (a document's, or a waiting file's copy), and places it under
    /// its table's root. Problems that need a person are logged (once per reference) and thrown.
    func download(uuid: String) async throws -> URL {
        guard let documents else { throw SyncDocumentError.notConfigured }
        let tables = documents.tables
        // The file record is in its row's zone (step 6), sealed with that zone's key.
        let found = try await db.read { db -> (SyncFileTable, String, String, SyncDocumentFileReference?, String)? in
            guard let (name, id) = try SyncFileTables.row(uuid: uuid, db: db), let table = tables.first(where: { $0.table == name }),
                  let row = try Row.fetchOne(db, sql: "SELECT sha256, storedRelativePath FROM \(SyncChangeTracker.quoted(name)) WHERE id = ?",
                                             arguments: [id])
            else { return nil }
            let zone = try String.fetchOne(db, sql: "SELECT zone FROM syncRecord WHERE uuid = ?", arguments: [uuid]) ?? SyncRecordStore.householdZone
            return (table, row["sha256"], row["storedRelativePath"], try SyncDocumentFile.reference(uuid: uuid, db: db), zone)
        }
        guard let (table, sha, stored, reference, zone) = found else { throw SyncDocumentError.documentNotFound }
        guard let reference else { throw SyncDocumentError.noFile }
        func attention(_ error: SyncDocumentError, _ message: String) async throws -> Never {
            let now = clock()
            try await db.write { db in
                try SyncDocumentFile.logAttention(table: table.table, uuid: uuid, message: message, db: db, now: now)
                try SyncDocumentFile.setFailed(reference, uuid: uuid, db: db, now: now)
            }
            Self.documentLog.error("Sync file not saved: \(String(describing: error), privacy: .public)")
            throw error
        }
        guard let path = table.safePath(stored: stored, sha256: sha) else {
            try await attention(.unsafePath, table.unsafePathMessage)
        }
        let destination = table.root.appendingPathComponent(path)
        if table.table == SyncFileTables.importWaitingFile,
           !ImportWaitingList.isOwnFolder(destination.deletingLastPathComponent(), root: table.root) {
            // The hash folder is a symbolic link (or not a folder, or leads outside the waiting folder): nothing is
            // written through it, nothing removed from it.
            try await attention(.unsafePath, table.unsafePathMessage)
        }
        if SyncFileTables.isRegularFile(destination), let existing = try? Data(contentsOf: destination),
           DocumentCrypto.sha256(existing) == sha.lowercased() { return destination }

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
                                                      authenticating: table.context(uuid: uuid, sha256: sha)) else {
            try await attention(.unreadable, SyncDocumentFile.unreadableMessage)
        }
        // Checked before anything is written: a file that isn't the record's never reaches the library (or the
        // waiting folder).
        guard DocumentCrypto.sha256(plaintext) == sha.lowercased() else {
            try await attention(.hashMismatch, SyncDocumentFile.hashMismatchMessage)
        }
        // Placed the way the library places an added file: a timestamped temporary copy (removed as stale if a
        // crash leaves it), moved in; the same content already there counts as placed.
        let now = clock()
        let manager = FileManager.default
        try manager.createDirectory(at: table.root, withIntermediateDirectories: true)
        EvidenceLibrary.removeStaleTemporaryFiles(in: table.root, now: now)
        // Something there that isn't a regular file (a symbolic link) is never written through.
        if (try? manager.attributesOfItem(atPath: destination.path)) != nil, !SyncFileTables.isRegularFile(destination) {
            try manager.removeItem(at: destination)
        }
        let temporary = table.root.appendingPathComponent(
            "\(EvidenceLibrary.temporaryPrefix)\(Int(now.timeIntervalSince1970))-\(UUID().uuidString)")
        do {
            try plaintext.write(to: temporary)
            _ = try EvidenceLibrary.place(temporary, at: destination, sha256: sha.lowercased(), byteCount: Int64(plaintext.count))
        } catch {
            try? manager.removeItem(at: temporary)
            throw error
        }
        if table.table == SyncFileTables.importWaitingFile {
            // Kept again under another name: the copy under the old name goes (as `ImportWaitingList.keep` does).
            ImportWaitingList.removeOtherFiles(in: destination.deletingLastPathComponent(), keeping: destination.lastPathComponent)
        }
        return destination
    }
}
