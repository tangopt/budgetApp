import Foundation
import GRDB

/// Records that moved between zones (a level change, sharing spec 2026-10-25 §3 goal 4), as this device knows
/// them, in `syncZoneMove` (local only): one row per record and zone it left.
///
/// A move is two saves: the record in its new zone first, then a *move marker* (`SyncPayload.movedTo`, no fields)
/// over its old copy, so nothing readable stays behind there. Once the first save is acknowledged the record's
/// `syncRecord.zone` is the new zone and a pending row here names the old one (with the old copy's stamp); the
/// next push (or the rest of this one) saves the marker and acknowledges the row, which then keeps the marker's
/// stamp: a later move back into that zone saves over the marker with it.
public enum SyncZoneMoves {
    /// Markers still to save: the record, its table and the zone it left.
    public static func pending(db: Database) throws -> [(uuid: String, tableName: String, zone: String)] {
        try Row.fetchAll(db, sql: "SELECT uuid, tableName, zone FROM syncZoneMove WHERE pending = 1 ORDER BY rowid").map {
            (uuid: $0["uuid"], tableName: $0["tableName"], zone: $0["zone"])
        }
    }

    /// The record left `zone`, where its old copy is at the version `systemFields` names: a marker goes there.
    static func record(uuid: String, tableName: String, from zone: String, systemFields: Data?, db: Database) throws {
        try db.execute(sql: """
            INSERT INTO syncZoneMove(uuid, zone, tableName, systemFields, pending) VALUES (?, ?, ?, ?, 1)
            ON CONFLICT(uuid, zone) DO UPDATE SET tableName = excluded.tableName, systemFields = excluded.systemFields, pending = 1
            """, arguments: [uuid, zone, tableName, systemFields])
    }

    /// The marker in `zone` is on the server at `stamp` (nil: nothing is there any more, the old copy was
    /// deleted or its zone is gone).
    static func acknowledge(uuid: String, zone: String, stamp: SyncServerStamp?, db: Database) throws {
        try db.execute(sql: "UPDATE syncZoneMove SET pending = 0, systemFields = ? WHERE uuid = ? AND zone = ?",
                       arguments: [stamp?.systemFields, uuid, zone])
    }

    /// The server's marker in `zone` seen on a pull (or on a refused save): its stamp kept, so this device can
    /// save over it. A pending marker stays pending.
    static func takeServerStamp(uuid: String, tableName: String, zone: String, systemFields: Data, db: Database) throws {
        try db.execute(sql: """
            INSERT INTO syncZoneMove(uuid, zone, tableName, systemFields, pending) VALUES (?, ?, ?, ?, 0)
            ON CONFLICT(uuid, zone) DO UPDATE SET systemFields = excluded.systemFields
            """, arguments: [uuid, zone, tableName, systemFields])
    }

    /// The stamp of the marker this device knows in `zone` (what a save of the record back into it names).
    static func markerStamp(uuid: String, zone: String, db: Database) throws -> Data? {
        try Data.fetchOne(db.cachedStatement(sql: "SELECT systemFields FROM syncZoneMove WHERE uuid = ? AND zone = ?"),
                          arguments: [uuid, zone])
    }

    /// Whether this device knows of a marker for the record in `zone` (it left that zone).
    static func knowsMarker(uuid: String, zone: String, db: Database) throws -> Bool {
        try Bool.fetchOne(db.cachedStatement(sql: "SELECT EXISTS (SELECT 1 FROM syncZoneMove WHERE uuid = ? AND zone = ?)"),
                          arguments: [uuid, zone]) ?? false
    }

    /// The record is back in `zone`: its marker there is gone (the record's save replaced it).
    static func arrived(uuid: String, zone: String, db: Database) throws {
        try db.execute(sql: "DELETE FROM syncZoneMove WHERE uuid = ? AND zone = ?", arguments: [uuid, zone])
    }

    /// The marker saved over a moved record's old copy: no fields, sealed like any record of `zone`.
    static func marker(uuid: String, tableName: String, zone: String, movedTo: String) -> SyncPayload {
        var payload = SyncPayload(recordType: tableName, recordName: uuid, zone: zone, fields: [:])
        payload.movedTo = movedTo
        return payload
    }
}

/// The zones this device syncs (`SyncEngineCore.zones(db:)`), as its engine last stored them, so an apply (and a
/// retry from staging later) knows which zones it follows: a move marker into one of them is ignored, and a stub's
/// left-out fields are kept only when it holds the owner's private zone. Without one stored: `household` only.
enum SyncZoneSet {
    static let stateKey = "zoneSet"
    /// The zone of an identity this device made for itself (a placeholder): never fetched, never sent.
    static let deviceOnlyZone = "device"

    static func current(db: Database) throws -> Set<String> {
        guard let data = try Data.fetchOne(db.cachedStatement(sql: "SELECT value FROM syncState WHERE key = ?"), arguments: [stateKey]),
              let zones = try? JSONDecoder().decode([String].self, from: data) else { return [SyncZones.household] }
        return Set(zones)
    }

    static func store(_ zones: [String], db: Database, now: Date) throws {
        let data = try JSONEncoder().encode(zones)
        guard try Data.fetchOne(db, sql: "SELECT value FROM syncState WHERE key = ?", arguments: [stateKey]) != data else { return }
        try SyncImportGate.setState(data, key: stateKey, db: db, now: now)
    }
}

/// The server stamps of the companions this device saved or received (`syncCompanion`, local only): one per
/// account stub, an `accountDetails` record named by the account's UUID in its owner's private zone.
enum SyncCompanions {
    struct Stamp {
        var zone: String
        var systemFields: Data?
        var changeTag: String?
    }

    static func stamp(uuid: String, db: Database) throws -> Stamp? {
        try Row.fetchOne(db.cachedStatement(sql: "SELECT zone, systemFields, changeTag FROM syncCompanion WHERE recordType = ? AND uuid = ?"),
                         arguments: [SyncZoneRouter.companionRecordType, uuid])
            .map { Stamp(zone: $0["zone"], systemFields: $0["systemFields"], changeTag: $0["changeTag"]) }
    }

    static func store(uuid: String, zone: String, stamp: SyncServerStamp?, db: Database) throws {
        try db.execute(sql: """
            INSERT INTO syncCompanion(recordType, uuid, zone, systemFields, changeTag) VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(recordType, uuid) DO UPDATE SET zone = excluded.zone, systemFields = excluded.systemFields, changeTag = excluded.changeTag
            """, arguments: [SyncZoneRouter.companionRecordType, uuid, zone, stamp?.systemFields, stamp?.changeTag])
    }

    static func remove(uuid: String, db: Database) throws {
        try db.execute(sql: "DELETE FROM syncCompanion WHERE recordType = ? AND uuid = ?", arguments: [SyncZoneRouter.companionRecordType, uuid])
    }
}
