import Foundation
import GRDB
import os

/// The Mac's demo tools beside `--sync-demo` (plan step 4 Task 13; DEBUG launches on the demo database only):
/// - `--sync-demo --sync-demo-reset` deletes the Development container's demo zone, removes the household key the
///   earlier demo runs kept under the **real** key-store scope (approved by the user 2026-10-24, so a later
///   Production bootstrap can never pick it up), forgets the zone in the demo database, and exits. The next
///   `--sync-demo` makes the zone again and uploads everything under a demo-scope key.
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
        let reset = arguments.contains(resetArgument)
        let print = arguments.contains(printKeyArgument)
        guard reset || print else { return nil }
        let name = reset ? resetArgument : printKeyArgument
        if reset && print {
            return "\(resetArgument) and \(printKeyArgument) are separate launches."
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
