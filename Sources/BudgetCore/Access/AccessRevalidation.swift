import Foundation
import GRDB
import os

/// The Mac's re-validation of incoming changes (sync spec §6.2, sharing spec 2026-10-25 §10; step 6 Task 9).
///
/// Every write path checks its actor at the source (`ActorWrite.perform`); a device running a modified client
/// could still send a change its writer had no permission for. The admin's Mac, while it applies a pull or the
/// merge of a refused save (`SyncEngineCore.revalidatesAccess`), judges each incoming save again:
///
/// - **Only what the merge would take** from the incoming side (`SyncMerge.remoteTakes`: a value that differs
///   from the Mac's and that wins), each field by the writer of its own clock (`clock.by`) and the payload's
///   `origin`, field by field, as `AccessAreaMap` and `AccessPolicy.allows` decide (an owner's say included).
/// - **Whose changes:** only other users'. The Mac's own user (its `syncWriter`, else the household's admin) is
///   never judged again: the ownership sheet's writes, read after ownership was confirmed, would be "denied".
///   A field with no clock, or a clock without a writer dated before ownership was confirmed, dates from
///   before tracking and counts as the household's; a writerless clock after that is judged as nobody's.
/// - **Origins:** the payload's (never the Mac's `syncRecord.origin`). An `.import` origin counts only when the
///   record comes with an import batch known here (`importRunUuid` of a batch this device holds, or of a run
///   it has): otherwise it is judged as a hand edit.
/// - **Revert:** a field without permission keeps the Mac's value and is stamped again (now, the Mac's user), so
///   the Mac's value wins on every device after the next round; a new record without permission is not written,
///   its delete is queued and a tombstone keeps it from coming back. Nothing a filed year reads moves on the Mac
///   (the Mac's values stay), and `FiledYearSyncCheck` still judges the apply as a whole.
/// - **Logged** in `syncAccessRevert` (`recentReverts`: "Reverted a change by B: no permission for Property");
///   the system log line names a table and an area, never a person or a value.
/// - **Limit (step 6):** deletions carry no writer (a CloudKit delete has no fields), so they can't be judged:
///   they apply, and the Mac logs each one it applies while re-validating (step 7 attributes them).
public enum AccessRevalidation {
    public enum Verdict: Equatable, Sendable {
        case allowed
        /// These fields (or, for a new record, the record) are reverted: the writer lacks `area`.
        case revert(fields: [String], area: AccessArea, writerAppUserUuid: String?)
    }

    /// One writer's fields reverted for one area.
    struct Revert: Equatable {
        var fields: [String]
        var area: AccessArea
        var writer: String?
    }

    private static let log = Logger(subsystem: "com.personal.budget", category: "Sync")

    /// How a log line names a writer this device doesn't know.
    public static let unknownWriterName = "someone not in this household"

    // MARK: Scope

    /// The connections applying with re-validation on.
    private static let active = OSAllocatedUnfairLock(initialState: Set<ObjectIdentifier>())

    /// Runs `body` (an apply in `db`'s transaction) with re-validation on for every save it applies.
    static func revalidating<T>(db: Database, _ body: () throws -> T) throws -> T {
        let id = ObjectIdentifier(db)
        let outermost = active.withLock { $0.insert(id).inserted }
        defer { if outermost { _ = active.withLock { $0.remove(id) } } }
        return try body()
    }

    static func isOn(db: Database) -> Bool {
        let id = ObjectIdentifier(db)
        return active.withLock { $0.contains(id) }
    }

    // MARK: Judging

    /// What an incoming save may change. `local`: the record as this device holds it (as it travels: references
    /// as UUIDs), nil for a record new here.
    static func verdict(for payload: SyncPayload, local: [String: SyncValue]?, db: Database) throws -> Verdict {
        let reverts = try self.reverts(for: payload, local: local, selfUser: selfUser(deviceUser: nil, db: db), db: db)
        guard let first = reverts.first else { return .allowed }
        return .revert(fields: reverts.flatMap(\.fields).sorted(), area: first.area, writerAppUserUuid: first.writer)
    }

    /// The Mac's own user: its writer, else the household's admin.
    static func selfUser(deviceUser: String?, db: Database) throws -> String? {
        if let deviceUser { return deviceUser }
        if let writer = try String.fetchOne(db, sql: "SELECT appUserUuid FROM syncWriter WHERE id = 1") { return writer }
        return try? AccessActor.admin(db: db).appUserUuid
    }

    /// Whether anyone but the Mac's own user may have written part of `payload` (else nothing in it is judged).
    static func mayNeedJudging(_ payload: SyncPayload, selfUser: String?) -> Bool {
        guard let selfUser else { return true }
        if payload.clocks.values.contains(where: { $0.by != selfUser }) { return true }
        return payload.clocks[SyncMerge.insertClock] == nil && payload.modifiedBy != nil && payload.modifiedBy != selfUser
    }

    /// The reverts an incoming save needs, by writer and area (empty: allowed).
    static func reverts(for payload: SyncPayload, local: [String: SyncValue]?, selfUser: String?, db: Database) throws -> [Revert] {
        let table = payload.recordType
        let origin = try judgedOrigin(payload, db: db)
        guard let local else {
            // A record new here: judged as made by whoever inserted it.
            let clock = payload.clocks[SyncMerge.insertClock]
            let writer = clock?.by ?? payload.modifiedBy
            guard let actor = try writerActor(writer, clock: clock, selfUser: selfUser, db: db) else { return [] }
            let decision = try decide(table: table, origin: origin, change: .insert, fields: Set(payload.fields.keys), row: payload.fields, db: db)
            if try allows(actor, decision, db: db) { return [] }
            return [Revert(fields: payload.fields.keys.sorted(), area: try failingArea(actor, decision, table: table, db: db), writer: writer)]
        }
        guard let localId = try SyncRecordStore.localId(table: table, uuid: payload.recordName, db: db) else { return [] }
        let taken = try SyncMerge.remoteTakes(payload, local: local, table: table, localId: localId, db: db)
        guard !taken.isEmpty else { return [] }
        let after = local.merging(payload.fields) { $1 }
        var reverts: [Revert] = []
        for field in taken {
            let clock = payload.clock(field)
            guard let actor = try writerActor(clock?.by, clock: clock, selfUser: selfUser, db: db) else { continue }
            let decision = try decide(table: table, origin: origin, change: .update(before: local), fields: [field], row: after, db: db)
            if try allows(actor, decision, db: db) { continue }
            let area = try failingArea(actor, decision, table: table, db: db)
            if let index = reverts.firstIndex(where: { $0.writer == clock?.by && $0.area == area }) {
                reverts[index].fields.append(field)
            } else {
                reverts.append(Revert(fields: [field], area: area, writer: clock?.by))
            }
        }
        return reverts
    }

    /// Who a change is judged as. Nil: not judged (the Mac's own user; a change from before tracking). `.some(nil)`:
    /// nobody this household knows, who may change nothing.
    private static func writerActor(_ writer: String?, clock: SyncClock?, selfUser: String?, db: Database) throws -> AccessActor?? {
        if let writer {
            if writer == selfUser { return nil }
            guard let id = try SyncRecordStore.localId(table: "appUser", uuid: writer, db: db) else { return .some(nil) }
            return .some(try AccessActor.load(appUserId: id, db: db))
        }
        guard let clock else { return nil }
        // A clock without a writer: from before tracking, unless it is later than ownership was confirmed.
        guard let confirmed = try confirmedAt(db: db), clock.at > confirmed else { return nil }
        return .some(nil)
    }

    private static func confirmedAt(db: Database) throws -> Date? {
        try Date.fetchOne(db, sql: """
            SELECT personSharing.ownershipConfirmedAt FROM personSharing
            WHERE personSharing.personId = (SELECT personId FROM appUser WHERE isAdmin = 1 ORDER BY id LIMIT 1)
            """)
    }

    /// The payload's origin, as far as it is believed: an import origin without an import batch known here is a
    /// hand edit's.
    private static func judgedOrigin(_ payload: SyncPayload, db: Database) throws -> WriteOrigin? {
        guard let origin = payload.origin.flatMap(WriteOrigin.init(rawValue:)) else { return nil }
        guard origin == .import else { return origin }
        if payload.recordType == ImportRun.databaseTableName { return origin }
        guard let run = payload.importRunUuid else { return nil }
        if try SyncBatch.batch(run: run, db: db) != nil { return origin }
        if try SyncRecordStore.localId(table: ImportRun.databaseTableName, uuid: run, db: db) != nil { return origin }
        return nil
    }

    private static func decide(table: String, origin: WriteOrigin?, change: AccessChange, fields: Set<String>,
                               row: [String: SyncValue], db: Database) throws -> AccessDecision {
        do {
            return try AccessAreaMap.area(table: table, origin: origin, change: change, changedFields: fields, row: row, db: db)
        } catch is AccessAreaMapError {
            return .denied
        }
    }

    private static func allows(_ actor: AccessActor?, _ decision: AccessDecision, db: Database) throws -> Bool {
        guard let actor else { return false }
        return try AccessPolicy.allows(actor, decision, db: db)
    }

    /// The first area of `decision` the writer lacks; else (an owner's say, nobody's) the table's own area.
    private static func failingArea(_ actor: AccessActor?, _ decision: AccessDecision, table: String, db: Database) throws -> AccessArea {
        for area in decision.areas {
            guard let actor else { return area }
            if try !AccessPolicy.can(actor, .edit, area, db: db) { return area }
        }
        return AccessAreaMap.tableArea(table) ?? decision.areas.first ?? .budgetAndAccounts
    }

    // MARK: Reverting

    /// Reverted fields of an existing row: stamped again as the Mac's (now, its user; never earlier than the
    /// incoming clock), so they win on every device, and the record queued to go up again.
    static func restamp(_ reverts: [Revert], payload: SyncPayload, table: String, localId: Int64, selfUser: String?,
                        db: Database, now: Date) throws {
        for field in reverts.flatMap(\.fields) {
            var at = now
            if let incoming = payload.clock(field)?.at, incoming >= at { at = incoming.addingTimeInterval(0.001) }
            try SyncMerge.setClock(SyncClock(at: at, by: selfUser), field: field, table: table, localId: localId, db: db)
        }
        try SyncMerge.queue(uuid: payload.recordName, table: table, localId: localId, kind: .update, db: db)
        try record(reverts, table: table, uuid: payload.recordName, db: db, now: now)
    }

    /// A new record without permission: not written; its delete goes up, and a tombstone keeps a later copy out.
    static func remove(_ revert: Revert, payload: SyncPayload, selfUser: String?, db: Database, now: Date) throws {
        try db.execute(sql: "DELETE FROM syncStaging WHERE uuid = ?", arguments: [payload.recordName])
        try SyncMerge.retire(uuid: payload.recordName, table: payload.recordType, localId: 0, zone: payload.zone, deletedBy: selfUser,
                             now: now, db: db)
        try SyncMerge.queue(uuid: payload.recordName, table: payload.recordType, localId: 0, kind: .delete, db: db)
        try record([revert], table: payload.recordType, uuid: payload.recordName, db: db, now: now)
    }

    private static func record(_ reverts: [Revert], table: String, uuid: String, db: Database, now: Date) throws {
        for revert in reverts {
            try db.execute(sql: """
                INSERT INTO syncAccessRevert(at, writerAppUserUuid, area, tableName, uuid, fields) VALUES (?, ?, ?, ?, ?, ?)
                """, arguments: [now, revert.writer, revert.area.storageKey, table, uuid, revert.fields.sorted().joined(separator: ",")])
            log.notice("Reverted an incoming change to a \(table, privacy: .public) record: no permission for \(revert.area.title, privacy: .public)")
        }
    }

    /// An incoming delete applied while re-validating: it carries no writer, so it can't be judged (step 7).
    static func logUnjudgedDelete(table: String?) {
        log.notice("Applied an incoming delete of a \(table ?? "unknown", privacy: .public) record without judging it: deletes carry no writer")
    }

    // MARK: The log

    /// The latest reverts, newest first: "Reverted a change by B: no permission for Budget & accounts".
    public static func recentReverts(limit: Int, db: Database) throws -> [String] {
        try Row.fetchAll(db, sql: "SELECT writerAppUserUuid, area FROM syncAccessRevert ORDER BY id DESC LIMIT ?", arguments: [limit]).map { row in
            let writer: String? = row["writerAppUserUuid"]
            let name = try writer.flatMap { uuid -> String? in
                guard let id = try SyncRecordStore.localId(table: "appUser", uuid: uuid, db: db) else { return nil }
                return try String.fetchOne(db, sql: "SELECT displayName FROM appUser WHERE id = ?", arguments: [id])
            } ?? unknownWriterName
            let area = AccessArea(storageKey: row["area"])?.title ?? "this area"
            return "Reverted a change by \(name): no permission for \(area)"
        }
    }
}
