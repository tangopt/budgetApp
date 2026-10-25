import Foundation
import GRDB

/// Records that moved between zones (a level change, sharing spec 2026-10-25 §3 goal 4), as this device knows
/// them, in `syncZoneMove` (local only): one row per record and zone it left.
///
/// A move is durable: the push decides it from the record's zone here and the router's, saves the record's new copy
/// (its row, with its file sealed again under the new zone's key) and only then, in the transaction that takes that
/// save in, writes the move: the zone it left (`zone`), where it went (`toZone`), the old copy's stamp and the file
/// record it left behind there (`oldFile`). Every push then saves a *marker* (`SyncPayload.movedTo`, no fields) over
/// the old copy and deletes the old file record, and keeps trying until the server has confirmed both. Nothing is
/// cleared before the server confirms it. A move that hasn't finished after `attentionAfter` pushes is logged for
/// attention and still retried. A finished row keeps the marker's stamp, so a later move back saves over it.
public enum SyncZoneMoves {
    /// Pushes after which an unfinished move is logged "needs attention" (it keeps being retried).
    static let attentionAfter = 5
    static let attentionMessage = SyncTranslator.needsAttention + "a move between zones hasn't finished; still retrying"

    /// An unfinished move: the record, its table, the zone it left, whether its marker is still to save and the file
    /// record still to delete there.
    public struct Unfinished: Equatable, Sendable {
        public var uuid: String
        public var tableName: String
        public var zone: String
        public var toZone: String?
        public var markerPending: Bool
        /// File records the record left in `zone`, each still to delete there.
        public var oldFiles: [String]
        /// The file record its copy in `toZone` names (to clean up if it comes back).
        public var toFile: String?
        public var attempts: Int
    }

    static func files(_ json: String?) -> [String] {
        json.flatMap { try? JSONDecoder().decode([String].self, from: Data($0.utf8)) } ?? []
    }

    static func json(_ files: [String]) -> String? {
        let unique = Array(Set(files)).sorted()
        guard !unique.isEmpty else { return nil }
        return String(decoding: (try? JSONEncoder().encode(unique)) ?? Data(), as: UTF8.self)
    }

    /// Moves still to finish (a marker to save or an old file record to delete), oldest first.
    public static func unfinished(db: Database) throws -> [Unfinished] {
        try Row.fetchAll(db, sql: """
            SELECT uuid, tableName, zone, toZone, toFile, pending, oldFile, attempts FROM syncZoneMove
            WHERE pending = 1 OR oldFile IS NOT NULL OR toZone IS NOT NULL ORDER BY rowid
            """).map {
            Unfinished(uuid: $0["uuid"], tableName: $0["tableName"], zone: $0["zone"], toZone: $0["toZone"],
                       markerPending: ($0["pending"] as Int) == 1, oldFiles: files($0["oldFile"]), toFile: $0["toFile"], attempts: $0["attempts"])
        }.filter { $0.markerPending || !$0.oldFiles.isEmpty || $0.toZone != nil }
    }

    /// Markers still to save: the record, its table and the zone it left.
    public static func pending(db: Database) throws -> [(uuid: String, tableName: String, zone: String)] {
        try unfinished(db: db).filter(\.markerPending).map { (uuid: $0.uuid, tableName: $0.tableName, zone: $0.zone) }
    }

    /// The record's new copy in `toZone` is saved (naming `toFile`): it left `zone`, where its old copy is at the
    /// version `systemFields` names and `oldFile` (if any) is a file record it left there. A marker and the deletes of
    /// every old file record still listed go next (an earlier one still to delete is kept).
    static func record(uuid: String, tableName: String, from zone: String, to toZone: String, systemFields: Data?, oldFile: String?,
                       toFile: String? = nil, db: Database) throws {
        let earlier = files(try String.fetchOne(db, sql: "SELECT oldFile FROM syncZoneMove WHERE uuid = ? AND zone = ?", arguments: [uuid, zone]))
        try db.execute(sql: """
            INSERT INTO syncZoneMove(uuid, zone, tableName, systemFields, pending, toZone, toFile, oldFile, attempts) VALUES (?, ?, ?, ?, 1, ?, ?, ?, 0)
            ON CONFLICT(uuid, zone) DO UPDATE SET tableName = excluded.tableName, systemFields = excluded.systemFields, pending = 1,
                toZone = excluded.toZone, toFile = excluded.toFile, oldFile = excluded.oldFile, attempts = 0
            """, arguments: [uuid, zone, tableName, systemFields, toZone, toFile, json(earlier + [oldFile].compactMap { $0 })])
    }

    /// The move's new copy names `file` now (taken from the server's copy).
    static func setToFile(uuid: String, zone: String, file: String?, db: Database) throws {
        try db.execute(sql: "UPDATE syncZoneMove SET toFile = ? WHERE uuid = ? AND zone = ?", arguments: [file, uuid, zone])
    }

    /// The move's destination is dealt with (the record left it again, or came back): nothing more to follow there.
    static func forgetDestination(uuid: String, zone: String, db: Database) throws {
        try db.execute(sql: "UPDATE syncZoneMove SET toZone = NULL, toFile = NULL WHERE uuid = ? AND zone = ?", arguments: [uuid, zone])
    }

    /// The marker in `zone` is on the server at `stamp` (nil: nothing is there any more, the old copy was deleted or its
    /// zone is gone).
    static func acknowledge(uuid: String, zone: String, stamp: SyncServerStamp?, db: Database) throws {
        try db.execute(sql: "UPDATE syncZoneMove SET pending = 0, systemFields = ? WHERE uuid = ? AND zone = ?",
                       arguments: [stamp?.systemFields, uuid, zone])
    }

    /// These old file records in `zone` need no delete any more: the server took it, or the record's copy there names
    /// the file again.
    static func filesDone(_ done: [String], uuid: String, zone: String, db: Database) throws {
        let left = files(try String.fetchOne(db, sql: "SELECT oldFile FROM syncZoneMove WHERE uuid = ? AND zone = ?", arguments: [uuid, zone]))
            .filter { !done.contains($0) }
        try db.execute(sql: "UPDATE syncZoneMove SET oldFile = ? WHERE uuid = ? AND zone = ?", arguments: [json(left), uuid, zone])
    }

    /// A push tried to finish the move and couldn't: counted; logged for attention once it has taken too long.
    static func tried(uuid: String, zone: String, tableName: String, db: Database, now: Date) throws {
        try db.execute(sql: "UPDATE syncZoneMove SET attempts = attempts + 1 WHERE uuid = ? AND zone = ?", arguments: [uuid, zone])
        if try Int.fetchOne(db, sql: "SELECT attempts FROM syncZoneMove WHERE uuid = ? AND zone = ?", arguments: [uuid, zone]) == attentionAfter {
            try SyncMerge.logConflict(table: tableName, uuid: uuid, field: "*", losing: .string(attentionMessage), winner: nil, loser: nil,
                                      db: db, now: now)
        }
    }

    /// Someone else's version is over the old copy in `zone` (an edit there, seen on a pull or a refused save): the
    /// marker goes again over it.
    static func markerAgain(uuid: String, tableName: String, zone: String, systemFields: Data?, db: Database) throws {
        try db.execute(sql: """
            INSERT INTO syncZoneMove(uuid, zone, tableName, systemFields, pending, attempts) VALUES (?, ?, ?, ?, 1, 0)
            ON CONFLICT(uuid, zone) DO UPDATE SET systemFields = excluded.systemFields, pending = 1
            """, arguments: [uuid, zone, tableName, systemFields])
    }

    /// The server's marker in `zone` seen on a pull (or on a refused save): its stamp kept, so this device can save
    /// over it. A pending marker stays pending.
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

    /// The record is back in `zone`: its marker there is gone (the record's save replaced it). Old file records still
    /// to delete there, and where the record had gone, stay for `finishMoves` to settle against its copy now.
    static func arrived(uuid: String, zone: String, db: Database) throws {
        try db.execute(sql: "DELETE FROM syncZoneMove WHERE uuid = ? AND zone = ? AND oldFile IS NULL AND toZone IS NULL", arguments: [uuid, zone])
        try db.execute(sql: "UPDATE syncZoneMove SET pending = 0, systemFields = NULL WHERE uuid = ? AND zone = ?", arguments: [uuid, zone])
    }

    /// The marker saved over a moved record's old copy: no fields, sealed like any record of `zone`.
    static func marker(uuid: String, tableName: String, zone: String, movedTo: String) -> SyncPayload {
        var payload = SyncPayload(recordType: tableName, recordName: uuid, zone: zone, fields: [:])
        payload.movedTo = movedTo
        return payload
    }
}

/// Where each record is on the server (`syncPresence`, local only): a zone holding its copy or a marker over it,
/// learnt from this device's acknowledged saves and from pulls. A delete goes to exactly those zones, and nowhere for
/// a record the server never had.
enum SyncPresence {
    static func add(uuid: String, zone: String, db: Database) throws {
        try db.cachedStatement(sql: "INSERT INTO syncPresence(uuid, zone) VALUES (?, ?) ON CONFLICT DO NOTHING").execute(arguments: [uuid, zone])
    }

    static func remove(uuid: String, zone: String, db: Database) throws {
        try db.cachedStatement(sql: "DELETE FROM syncPresence WHERE uuid = ? AND zone = ?").execute(arguments: [uuid, zone])
    }

    static func zones(uuid: String, db: Database) throws -> [String] {
        try String.fetchAll(db.cachedStatement(sql: "SELECT zone FROM syncPresence WHERE uuid = ? ORDER BY zone"), arguments: [uuid])
    }

    /// What this device saved or saw on the server before `syncPresence` existed: every record with a server stamp (in
    /// its zone) and every marker it knows. Idempotent.
    static func backfill(db: Database) throws {
        try db.execute(sql: """
            INSERT OR IGNORE INTO syncPresence(uuid, zone)
            SELECT uuid, zone FROM syncRecord WHERE systemFields IS NOT NULL OR changeTag IS NOT NULL
            """)
        try db.execute(sql: "INSERT OR IGNORE INTO syncPresence(uuid, zone) SELECT uuid, zone FROM syncZoneMove")
    }

    static func isIn(uuid: String, zone: String, db: Database) throws -> Bool {
        try Bool.fetchOne(db.cachedStatement(sql: "SELECT EXISTS (SELECT 1 FROM syncPresence WHERE uuid = ? AND zone = ?)"),
                          arguments: [uuid, zone]) ?? false
    }
}

/// Records to delete on the server (`syncZoneCleanup`, local only): a file record sealed for a save that didn't go, a
/// companion no longer needed. Every push tries them; a row goes once the server has taken the delete.
enum SyncCleanup {
    static func add(zone: String, recordName: String, db: Database) throws {
        try db.execute(sql: "INSERT INTO syncZoneCleanup(zone, recordName) VALUES (?, ?) ON CONFLICT DO NOTHING", arguments: [zone, recordName])
    }

    static func all(db: Database) throws -> [String: [String]] {
        var result: [String: [String]] = [:]
        for row in try Row.fetchAll(db, sql: "SELECT zone, recordName FROM syncZoneCleanup ORDER BY zone, recordName") {
            result[row["zone"], default: []].append(row["recordName"])
        }
        return result
    }

    static func done(zone: String, recordNames: [String], db: Database) throws {
        for name in recordNames {
            try db.execute(sql: "DELETE FROM syncZoneCleanup WHERE zone = ? AND recordName = ?", arguments: [zone, name])
        }
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

/// The server stamps of the companions this device saved or received (`syncCompanion`, local only), by companion
/// record name (`SyncZoneRouter.companionRecordName`): one per account stub, an `accountDetails` record in its owner's
/// private zone.
enum SyncCompanions {
    struct Stamp {
        var zone: String
        var systemFields: Data?
        var changeTag: String?
    }

    static func stamp(name: String, db: Database) throws -> Stamp? {
        try Row.fetchOne(db.cachedStatement(sql: "SELECT zone, systemFields, changeTag FROM syncCompanion WHERE recordType = ? AND uuid = ?"),
                         arguments: [SyncZoneRouter.companionRecordType, name])
            .map { Stamp(zone: $0["zone"], systemFields: $0["systemFields"], changeTag: $0["changeTag"]) }
    }

    static func store(name: String, zone: String, stamp: SyncServerStamp?, db: Database) throws {
        try db.execute(sql: """
            INSERT INTO syncCompanion(recordType, uuid, zone, systemFields, changeTag) VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(recordType, uuid) DO UPDATE SET zone = excluded.zone, systemFields = excluded.systemFields, changeTag = excluded.changeTag
            """, arguments: [SyncZoneRouter.companionRecordType, name, zone, stamp?.systemFields, stamp?.changeTag])
    }

    static func remove(name: String, db: Database) throws {
        try db.execute(sql: "DELETE FROM syncCompanion WHERE recordType = ? AND uuid = ?", arguments: [SyncZoneRouter.companionRecordType, name])
    }

    /// The account (by local id and UUID) a companion record names, when it is here.
    static func account(named name: String, db: Database) throws -> (id: Int64, uuid: String)? {
        for row in try Row.fetchAll(db, sql: "SELECT localId, uuid FROM syncRecord WHERE tableName = 'account'")
        where SyncZoneRouter.companionRecordName(accountUuid: row["uuid"]) == name {
            return (row["localId"], row["uuid"])
        }
        return nil
    }
}
