import CryptoKit
import Foundation
import GRDB
import os

/// The Mac's demo tools beside `--sync-demo` (plan step 4 Task 13; DEBUG launches on the demo database only):
/// - `--sync-demo --sync-demo-reset` deletes the Development container's demo zone, removes the household key the
///   earlier demo runs kept under the **real** key-store scope (approved by the user 2026-10-24, so a later
///   Production bootstrap can never pick it up), forgets the zone in the demo database, and exits. The next
///   `--sync-demo` makes the zone again and uploads everything under a demo-scope key.
/// - `--sync-demo --seed-schema` (`SyncSchemaSeed`) saves one placeholder record of every record type into a
///   scratch zone of the Development container, so its schema can be deployed to Production, and exits.
/// - `--sync-demo --print-demo-key` prints the demo-scope household key (64 hex) to stderr once the first sync has
///   put its marker on the server, for the simulator's `MANGO_DEMO_HOUSEHOLD_KEY`.
///
/// The CloudKit and Keychain sides are passed in (the app's `CloudKitTransport.deleteZone`, the real scope's
/// `KeychainSyncKeyStore.remove`), so tests run it over `FakeCloud` and in-memory stores.
public enum SyncDemoReset {
    public static let resetArgument = "--sync-demo-reset"
    public static let printKeyArgument = "--print-demo-key"
    private static let log = Logger(subsystem: "com.personal.budget", category: "Sync")

    /// Why this launch's demo tool can't run, or nil (also nil when no demo tool was asked for). Each needs
    /// `--sync-demo` and `SyncActivation`'s yes; the reset and the key print are separate launches.
    public static func refusal(arguments: [String], decision: SyncActivation.Decision) -> String? {
        let asked = [resetArgument, printKeyArgument, SyncSchemaSeed.argument].filter(arguments.contains)
        guard let name = asked.first else { return nil }
        if asked.count > 1 {
            return asked.joined(separator: " and ") + " are separate launches."
        }
        guard arguments.contains(SyncActivation.demoArgument) else {
            return "\(name) works only together with \(SyncActivation.demoArgument), on the demo database."
        }
        return decision.allowed ? nil : decision.reason
    }

    public struct Outcome: Equatable, Sendable {
        /// The key ids the zone's marker (or this database's copy of it) named.
        public var keyIds: [String]
        /// Those found and removed from the real scope.
        public var removedRealScopeKeys: [String]
        /// False when the zone was already gone.
        public var zoneDeleted: Bool
    }

    /// Reads which keys the zone's marker names (on the server, and as this database last saw it), deletes the zone
    /// (already gone is fine), removes those keys from the real scope, then forgets the zone here: no token, not
    /// ready, no stamps, no marker, nothing staged from it, every record queued to go up again. A failed deletion
    /// changes nothing else.
    public static func run(zone: String = SyncRecordStore.householdZone, transport: any SyncTransport,
                           deleteZone: @Sendable (String) async throws -> Void,
                           removeRealScopeKey: (String) throws -> Bool,
                           db: any DatabaseWriter, now: Date) async throws -> Outcome {
        var ids: [String] = []
        func note(_ id: String) { if !ids.contains(id) { ids.append(id) } }
        do {
            if let server = try await transport.fetch(SyncZoneKeys.recordName(zone: zone), zone: zone) {
                if let marker = try? SyncZoneKeys.marker(from: server.wire) {
                    note(marker.keyId)
                } else if let legacy = SyncZoneKeys.legacyKeyring(from: server.wire) {
                    legacy.keys.forEach { note(DocumentCrypto.zoneKeyId($0)) }
                }
            }
        } catch SyncTransportError.zoneNotFound {}
        if let local = try await db.read({ db in try SyncZoneKeys.local(zone: zone, db: db) }) { note(local.marker.keyId) }

        var deleted = true
        do {
            try await deleteZone(zone)
        } catch SyncTransportError.zoneNotFound {
            deleted = false
        }
        var removed: [String] = []
        for id in ids where try removeRealScopeKey(id) { removed.append(id) }
        try await db.write { db in try forget(zone: zone, db: db, now: now) }
        log.info("Sync demo reset: zone \(deleted ? "deleted" : "already gone", privacy: .public), \(removed.count) real-scope key(s) removed")
        return Outcome(keyIds: ids, removedRealScopeKeys: removed, zoneDeleted: deleted)
    }

    /// The zone as if this database had never synced it, its records all pending (as `recoverMissingZone`, without
    /// making the zone and without keeping the marker).
    static func forget(zone: String, db: Database, now: Date) throws {
        try db.execute(sql: "DELETE FROM syncState WHERE key IN (?, ?, ?)",
                       arguments: [SyncEngineCore.tokenKey(zone), SyncEngineCore.zoneKey(zone), SyncZoneKeys.stateKey(zone)])
        try db.execute(sql: "DELETE FROM syncState WHERE key LIKE ? OR key LIKE ? OR key = ?",
                       arguments: [SyncDocumentFile.referencePrefix + "%", SyncDocumentFile.failedPrefix + "%",
                                   SyncEngineCore.retryStagedKey])
        try SyncImportGate.setHeldLease(nil, db: db, now: now)
        // Every staged record came from this zone (the only one) and may be sealed under the key just removed.
        try db.execute(sql: "DELETE FROM syncStaging")
        try db.execute(sql: "UPDATE syncRecord SET systemFields = NULL, changeTag = NULL WHERE zone = ?", arguments: [zone])
        let base = try Int64.fetchOne(db, sql: "SELECT COALESCE(MAX(revision), 0) FROM syncPending") ?? 0
        try db.execute(sql: """
            INSERT INTO syncPending(uuid, tableName, localId, kind, revision)
            SELECT uuid, tableName, localId, 'insert', ? + rowid FROM syncRecord WHERE zone = ? ORDER BY rowid
            ON CONFLICT(uuid) DO NOTHING
            """, arguments: [base, zone])
    }
}

/// The Development container's schema, made from placeholders (step 6 Task 13): CloudKit creates a record type and its
/// fields the first time a record of it is saved in Development, and Production only gets them when the developer
/// deploys that schema (CloudKit Console ▸ Deploy Schema Changes). A record type Production lacks makes every save of it
/// fail, so before the real first upload `--sync-demo --seed-schema` saves one record of every type the engine can
/// save into a scratch zone (`zone`), then deletes the zone.
///
/// The records are placeholders: no data from any database (nothing from the demo either), each shaped exactly as the
/// engine sends that type (R15), so every field the type ever carries exists:
/// - each synced table, each `accountDetails` companion and the `importLease`: `sealed` + `keyId`, with the large-payload
///   asset (`payload`) as well (any record may be packed into it);
/// - `zoneKey`: exactly a key marker (`keyId`, `createdAt`);
/// - `documentFile`: exactly its `file` asset;
/// - the key exchange's `keyOffer` (exactly `publicKey`) and `keyGrant` (exactly `sealed` + `keyId`), and, on the public
///   database when a board is given, its `keyRequest` (plain `requestId`, `commitment`, `publicKey`, `nonce`).
/// Move markers are records of their table's type, so the tables cover them.
public enum SyncSchemaSeed {
    public static let argument = "--seed-schema"
    /// The scratch zone, deleted again once the records are saved. Never a zone the engine syncs.
    public static let zone = "schema-seed"
    private static let log = Logger(subsystem: "com.personal.budget", category: "Sync")

    /// Every record type the engine can save.
    public static var recordTypes: [String] {
        SyncSchema.tables.map(\.name) + [SyncZoneRouter.companionRecordType, TransportLeaseStore.recordType,
                                          SyncZoneKeys.recordType, SyncDocumentFile.recordType,
                                          SyncKeyExchange.offerRecordType, SyncKeyExchange.grantRecordType]
    }

    /// The public database's placeholders: the key exchange's request, with every field it ever carries (none secret;
    /// placeholders hold zeros).
    public static var publicRecords: [SyncPublicRecord] {
        [SyncPublicRecord(recordType: SyncKeyExchange.requestRecordType, recordName: "schema-seed-" + SyncKeyExchange.requestRecordType,
                          fields: [SyncKeyExchange.requestIdField: Data("00000000-0000-0000-0000-000000000000".utf8),
                                   SyncKeyExchange.commitmentField: Data(count: 32), SyncKeyExchange.publicKeyField: Data(count: 32),
                                   SyncKeyExchange.nonceField: Data(count: 32)])]
    }

    /// One placeholder record of each of `recordTypes` in `zone`, sealed under `keys`' key for that zone (made and
    /// stored there when it holds none: pass a store of its own, never the real data's).
    public static func records(keys: any SyncKeyStore) throws -> [SyncWireRecord] {
        let key: SymmetricKey
        if let held = try keys.key(zone: zone) {
            key = held
        } else {
            key = DocumentCrypto.newZoneKey()
            try keys.store(key, zone: zone)
        }
        let sealedTypes = SyncSchema.tables.map(\.name) + [SyncZoneRouter.companionRecordType, TransportLeaseStore.recordType]
        var records: [SyncWireRecord] = []
        for type in sealedTypes {
            let payload = SyncPayload(recordType: type, recordName: "schema-seed-" + type, zone: zone, fields: [:])
            // Packed (threshold 0): `sealed` + `keyId` and the `payload` asset, every field the type ever has.
            records.append(try SyncLargePayload.wire(for: payload, key: key, threshold: 0).0)
        }
        records.append(SyncZoneKeys.wire(SyncZoneKeys.Marker(keyId: DocumentCrypto.zoneKeyId(key), createdAt: Date(timeIntervalSinceReferenceDate: 0)),
                                         zone: zone))
        let box = try DocumentCrypto.seal(Data("schema seed".utf8), zoneKey: key)
        records.append(SyncWireRecord(recordType: SyncDocumentFile.recordType, recordName: "schema-seed-" + SyncDocumentFile.recordType,
                                      zone: zone, assets: [SyncDocumentFile.assetField: box.ciphertext]))
        records.append(SyncWireRecord(recordType: SyncKeyExchange.offerRecordType, recordName: "schema-seed-" + SyncKeyExchange.offerRecordType,
                                      zone: zone, encryptedFields: [SyncKeyExchange.publicKeyField: Data(count: 32)]))
        records.append(SyncWireRecord(recordType: SyncKeyExchange.grantRecordType, recordName: "schema-seed-" + SyncKeyExchange.grantRecordType,
                                      zone: zone, encryptedFields: [SyncKeyExchange.sealedField: Data(count: 32 + 12 + 16 + 32),
                                                                    SyncKeyExchange.keyIdField: Data(SyncKeyExchange.keyId.utf8)]))
        return records
    }

    public enum SeedError: Error, Equatable {
        /// Some records weren't saved (their record types, never values).
        case notSaved([String])
    }

    /// Makes `zone`, saves `records(keys:)` there, then deletes the zone (also when a save failed); with `board`, also
    /// posts `publicRecords` to the public database and deletes them again. Returns how many record types were saved;
    /// throws `notSaved` naming the types the server refused.
    @discardableResult
    public static func run(transport: any SyncTransport, keys: any SyncKeyStore, board: (any SyncPublicBoard)? = nil,
                           deleteZone: @Sendable (String) async throws -> Void) async throws -> Int {
        var publicSaved = 0
        var publicRefused: [String] = []
        if let board {
            for record in publicRecords {
                do {
                    try await board.postPublic(record)
                    try await board.deletePublic(record.recordName)
                    publicSaved += 1
                } catch {
                    publicRefused.append(record.recordType)
                }
            }
        }
        let records = try records(keys: keys)
        try await transport.createZone(zone)
        let results: [SaveResult]
        do {
            results = try await transport.save(records, ifUnchanged: [:], atomic: false)
        } catch {
            try? await deleteZone(zone)
            throw error
        }
        try await deleteZone(zone)
        let saved = Set(results.compactMap { result -> String? in
            if case .saved = result.outcome { return result.recordName } else { return nil }
        })
        let refused = records.filter { !saved.contains($0.recordName) }.map(\.recordType) + publicRefused
        log.info("Schema seed: \(records.count - refused.count + publicSaved + publicRefused.count, privacy: .public) of \(records.count + publicSaved + publicRefused.count, privacy: .public) record types saved")
        guard refused.isEmpty else { throw SeedError.notSaved(refused) }
        return records.count + publicSaved
    }
}
