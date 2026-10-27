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
///   Columns a copy leaves out (`omittedFields`) that this device would clear count as set to null by its sender,
///   unless the Mac's own placement of the record leaves them out too (`revertsOfClears`).
/// - **Who wrote (step 7a):** the server says (`SyncPayload.serverWriter`, `attributedWriter`), never the payload:
///   a version the Mac's own iCloud user saved is never judged; one another appUser's iCloud user saved is judged
///   field by field as theirs, whatever its clocks claim (`by`, writerless, dated before ownership was confirmed),
///   and the fields it gives this device are stored as theirs (`attributing`); one an iCloud user this household
///   doesn't know saved, or one the server names no writer for (`SyncPayload.unnamedServerWriter`), has every field it
///   would change reverted. Only a record an older build kept in staging has no server writer at all: it is judged by
///   its clocks, as below (step 6).
/// - **Whose changes:** only other users'. The Mac's own user (its `syncWriter`, else the household's admin) is
///   never judged again: the ownership sheet's writes, read after ownership was confirmed, would be "denied".
///   A field with no clock, or a clock without a writer dated before ownership was confirmed, dates from
///   before tracking and counts as the household's; a writerless clock after that is judged as nobody's (the Mac's
///   own writes are never writerless: everything it writes outside `ActorWrite.perform` takes its default writer,
///   `ActorWrite.useDefaultWriter`).
/// - **Origins:** the payload's (never the Mac's `syncRecord.origin`). An `.import` origin counts only when the
///   record comes with an import batch known here (`importRunUuid` of a batch this device holds, or of a run
///   it has): otherwise it is judged as a hand edit. With a server writer, the run must also be that writer's (its
///   `importRun` insert clock's `by`): a tag reused from someone else's run is a hand edit.
/// - **Revert:** a field without permission keeps the Mac's value and is stamped again (now, the Mac's user), so
///   the Mac's value wins on every device after the next round; a new record without permission is not written,
///   its delete is queued and a tombstone keeps it from coming back. Nothing a filed year reads moves on the Mac
///   (the Mac's values stay), and `FiledYearSyncCheck` still judges the apply as a whole.
/// - **Logged** in `syncAccessRevert` (`recentReverts`: "Reverted a change by B: no permission for Property", or
///   "…: no permission: only the owner can change this");
///   the system log line names a table and an area, never a person or a value.
/// - **Deletes (step 7a):** a household delete travels as a deletion marker (`SyncPayload.deleted`), a save the server
///   attributes. One another app user (or an unknown iCloud user) had no permission for (`deleteVerdict`) keeps the row:
///   it is queued to go again over the marker (`resent`), and logged ("Reverted a delete by B: no permission for
///   Property"). A bare hard deletion in the household (an older build, a modified client: no writer) is undone the same
///   way, unless this Mac deleted the record itself. Private zones keep hard deletes, never judged: only their owner
///   writes there.
public enum AccessRevalidation {
    public enum Verdict: Equatable, Sendable {
        case allowed
        /// These fields (or, for a new record, the record) are reverted: the writer lacks `area`.
        case revert(fields: [String], area: AccessArea, writerAppUserUuid: String?)
    }

    /// Why a change was reverted.
    enum Reason: String, Equatable {
        /// The writer lacks Edit in the revert's area.
        case area
        /// Only the record's owner may make it (an account's level, a person's own sharing).
        case ownerOnly
        /// Nobody may (a joint account's level, an owner after set-up, a table no rule knows).
        case nobody
        /// A recharge statement's line, changed on another device after someone else sent the statement (step 8):
        /// a sent statement's lines are fixed.
        case statementSent
    }

    /// One writer's fields reverted for one area and reason.
    struct Revert: Equatable {
        var fields: [String]
        var area: AccessArea
        var writer: String?
        var reason: Reason = .area
    }

    /// What `syncAccessRevert.area` holds for the reasons that aren't an area.
    static let ownerOnlyKey = "ownerOnly"
    static let nobodyKey = "denied"
    static let statementSentKey = "statementSent"

    private static let log = Logger(subsystem: "com.personal.budget", category: "Sync")

    /// How a log line names a writer this device doesn't know.
    public static let unknownWriterName = "someone not in this household"

    // MARK: Attribution (step 7a)

    /// Who the server says saved an incoming version.
    public enum Attribution: Equatable, Sendable {
        /// The Mac's own user (another device of the admin's, or this one).
        case selfUser
        /// Another app user of the household, by `appUser` UUID.
        case appUser(String)
        /// An iCloud user no app user here is bound to.
        case unknown
    }

    /// Who wrote `payload`, by the server's word (`serverWriter`, an iCloud user record name) matched against the
    /// app users' `cloudKitUserRecordName`. A version the server named no writer for is `.unknown` (fail closed). Nil
    /// only for a record an older build kept in staging (no `serverWriter` at all): judged by its clocks, as in step 6.
    /// `selfUser`: the Mac's own app user UUID (`selfUser(deviceUser:db:)`).
    public static func attributedWriter(_ payload: SyncPayload, selfUser: String?, db: Database) throws -> Attribution? {
        guard let writer = payload.serverWriter else { return nil }
        guard writer != SyncPayload.unnamedServerWriter,
              let id = try Int64.fetchOne(db, sql: "SELECT id FROM appUser WHERE cloudKitUserRecordName = ?", arguments: [writer]),
              let uuid = try SyncRecordStore.existingUUID(table: "appUser", localId: id, db: db) else { return .unknown }
        return uuid == selfUser ? .selfUser : .appUser(uuid)
    }

    /// Whether a Mac's engine re-validates incoming changes: only for the household's admin, signed in to Mango on a
    /// Mac whose iCloud user is the one bound to them (`cloudKitUserRecordName`). Anyone else, or an unknown iCloud
    /// user: no.
    public static func shouldRevalidate(signedInAppUserId: Int64?, iCloudUserRecordName: String?, db: Database) throws -> Bool {
        guard let signedInAppUserId, let iCloudUserRecordName,
              let row = try Row.fetchOne(db, sql: "SELECT isAdmin, cloudKitUserRecordName FROM appUser WHERE id = ?",
                                         arguments: [signedInAppUserId]) else { return false }
        let isAdmin: Bool = row["isAdmin"] ?? false
        let bound: String? = row["cloudKitUserRecordName"]
        return isAdmin && bound == iCloudUserRecordName
    }

    /// `payload` as `writer` (another app user, the server's writer) sent it: the clocks of the fields this device would
    /// take from it are theirs (`local`: the record as this device holds it, `localId` its row; nil: a record new
    /// here, every clock theirs), so what is applied is stored as theirs whatever the payload claimed.
    static func attributing(_ payload: SyncPayload, to writer: String, local: [String: SyncValue]?, localId: Int64?,
                            db: Database) throws -> SyncPayload {
        var result = payload
        result.modifiedBy = writer
        guard let local, let localId else {
            for (field, clock) in payload.clocks { result.clocks[field] = SyncClock(at: clock.at, by: writer) }
            return result
        }
        for field in try SyncMerge.remoteTakes(payload, local: local, table: payload.recordType, localId: localId, db: db) {
            guard let clock = payload.clock(field) else { continue }
            result.clocks[field] = SyncClock(at: clock.at, by: writer)
        }
        return result
    }

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
        // A copy leaving columns out clears them as its sender's change.
        if !(payload.omittedFields ?? []).isEmpty, payload.modifiedBy != selfUser { return true }
        return payload.clocks[SyncMerge.insertClock] == nil && payload.modifiedBy != nil && payload.modifiedBy != selfUser
    }

    /// The reverts an incoming save needs, by writer and area (empty: allowed).
    static func reverts(for payload: SyncPayload, local: [String: SyncValue]?, selfUser: String?, db: Database) throws -> [Revert] {
        let table = payload.recordType
        let attribution = try attributedWriter(payload, selfUser: selfUser, db: db)
        if attribution == .selfUser { return [] }
        if let revert = try sentStatementRevert(payload, local: local, attribution: attribution, db: db) { return [revert] }
        let origin = try judgedOrigin(payload, attribution: attribution, db: db)
        guard let local else {
            // A record new here: judged as made by whoever inserted it (the server's writer, when it names one).
            let clock = payload.clocks[SyncMerge.insertClock]
            let (writer, judged) = try judge(clock?.by ?? payload.modifiedBy, clock: clock, attribution: attribution, selfUser: selfUser, db: db)
            guard let actor = judged else { return [] }
            let decision = try decide(table: table, origin: origin, change: .insert, fields: Set(payload.fields.keys), row: payload.fields, db: db)
            if try allows(actor, decision, db: db) { return [] }
            let (area, reason) = try failure(actor, decision, table: table, db: db)
            return [Revert(fields: payload.fields.keys.sorted(), area: area, writer: writer, reason: reason)]
        }
        guard let localId = try SyncRecordStore.localId(table: table, uuid: payload.recordName, db: db) else { return [] }
        let taken = try SyncMerge.remoteTakes(payload, local: local, table: table, localId: localId, db: db)
        guard !taken.isEmpty else { return [] }
        let after = local.merging(payload.fields) { $1 }
        var reverts: [Revert] = []
        for field in taken {
            let clock = payload.clock(field)
            let (writer, judged) = try judge(clock?.by, clock: clock, attribution: attribution, selfUser: selfUser, db: db)
            guard let actor = judged else { continue }
            let decision = try decide(table: table, origin: origin, change: .update(before: local), fields: [field], row: after, db: db)
            if try allows(actor, decision, db: db) { continue }
            let (area, reason) = try failure(actor, decision, table: table, db: db)
            add(field, writer: writer, area: area, reason: reason, to: &reverts)
        }
        return reverts
    }

    // MARK: Sent statements (step 8)

    /// A `rechargeLine` change (a new line, or fields the merge would take) for a statement this Mac holds as sent or
    /// paid, whose status someone other than the line's writer set: reverted, whoever wrote it (a sent statement's
    /// lines are fixed; the iPad offers line edits on drafts only, but an offline edit can cross the Mac's "sent").
    /// The writer's own "sent" (a line added, then the statement sent, on one device) stands. Nil: not such a change.
    static func sentStatementRevert(_ payload: SyncPayload, local: [String: SyncValue]?, attribution: Attribution?,
                                    db: Database) throws -> Revert? {
        guard payload.recordType == "rechargeLine", !payload.isDeletionMarker else { return nil }
        let localId = try SyncRecordStore.localId(table: "rechargeLine", uuid: payload.recordName, db: db)
        var statementId = try localId.flatMap { try Int64.fetchOne(db, sql: "SELECT statementId FROM rechargeLine WHERE id = ?", arguments: [$0]) }
        if statementId == nil, case .string(let uuid)? = payload.fields["statementId"] {
            statementId = try SyncRecordStore.localId(table: "rechargeStatement", uuid: uuid, db: db)
        }
        let writer: String?
        switch attribution {
        case .appUser(let user)?: writer = user
        case .unknown?: writer = nil
        case .selfUser?: return nil
        case nil: writer = payload.clocks[SyncMerge.insertClock]?.by ?? payload.modifiedBy
        }
        guard let statementId, try sentBySomeoneElse(statementId: statementId, writer: writer, db: db) else { return nil }
        let fields: [String]
        if let local, let localId {
            fields = try SyncMerge.remoteTakes(payload, local: local, table: "rechargeLine", localId: localId, db: db).sorted()
            guard !fields.isEmpty else { return nil }
        } else {
            fields = payload.fields.keys.sorted()
        }
        return Revert(fields: fields, area: .property, writer: writer, reason: .statementSent)
    }

    /// Whether statement `statementId` is sent or paid here, its status set by someone other than `writer`.
    static func sentBySomeoneElse(statementId: Int64, writer: String?, db: Database) throws -> Bool {
        guard let status = try String.fetchOne(db, sql: "SELECT status FROM rechargeStatement WHERE id = ?", arguments: [statementId]),
              status != RechargeStatementStatus.draft.rawValue else { return false }
        let setBy = try SyncMerge.clocks(table: "rechargeStatement", localId: statementId, db: db)["status"]?.by
        return writer == nil || setBy != writer
    }

    private static func add(_ field: String, writer: String?, area: AccessArea, reason: Reason, to reverts: inout [Revert]) {
        if let index = reverts.firstIndex(where: { $0.writer == writer && $0.area == area && $0.reason == reason }) {
            reverts[index].fields.append(field)
        } else {
            reverts.append(Revert(fields: [field], area: area, writer: writer, reason: reason))
        }
    }

    /// Columns an incoming copy leaves out that this device would clear (`SyncTranslator.leftOut`), judged once the
    /// merge is in: a column the Mac's own placement of the record leaves out too is cleared (a level lowered, a
    /// private batch); any other clear is a change by the copy's sender, judged as setting the column to null. Returns
    /// the reverts (those columns keep the Mac's value).
    static func revertsOfClears(_ cleared: [String], payload: SyncPayload, local: [String: SyncValue], table: String, localId: Int64,
                                selfUser: String?, db: Database) throws -> [Revert] {
        let candidates = cleared.filter { (local[$0] ?? .null) != .null }
        guard !candidates.isEmpty else { return [] }
        let placed = Set((try? SyncZoneRouter(db: db).assignment(table: table, localId: localId))?.omittedFields ?? [])
        let attribution = try attributedWriter(payload, selfUser: selfUser, db: db)
        if attribution == .selfUser { return [] }
        let origin = try judgedOrigin(payload, attribution: attribution, db: db)
        var reverts: [Revert] = []
        for field in candidates where !placed.contains(field) {
            let claimed = payload.clocks[field]?.by ?? payload.modifiedBy
            let clock = payload.clocks[field] ?? payload.modifiedAt.map { SyncClock(at: $0, by: claimed) }
            let (writer, judged) = try judge(claimed, clock: clock, attribution: attribution, selfUser: selfUser, db: db)
            guard let actor = judged else { continue }
            var after = local.merging(payload.fields) { $1 }
            after[field] = .null
            let decision = try decide(table: table, origin: origin, change: .update(before: local), fields: [field], row: after, db: db)
            if try allows(actor, decision, db: db) { continue }
            let (area, reason) = try failure(actor, decision, table: table, db: db)
            add(field, writer: writer, area: area, reason: reason, to: &reverts)
        }
        return reverts
    }

    /// Who a change is judged as, and the writer its revert names. With a server writer, that writer, whatever the
    /// clock claims (an unknown iCloud user: nobody this household knows, named by no app user); without one, the
    /// clock's (step 6, `writerActor`).
    private static func judge(_ claimed: String?, clock: SyncClock?, attribution: Attribution?, selfUser: String?,
                              db: Database) throws -> (writer: String?, actor: AccessActor??) {
        switch attribution {
        case nil: return (claimed, try writerActor(claimed, clock: clock, selfUser: selfUser, db: db))
        case .selfUser?: return (nil, nil)
        case .appUser(let writer)?: return (writer, try writerActor(writer, clock: clock, selfUser: selfUser, db: db))
        case .unknown?: return (nil, .some(nil))
        }
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
    /// hand edit's; with a server writer (step 7a), so is one whose run that writer didn't make.
    private static func judgedOrigin(_ payload: SyncPayload, attribution: Attribution?, db: Database) throws -> WriteOrigin? {
        guard let origin = payload.origin.flatMap(WriteOrigin.init(rawValue:)) else { return nil }
        guard origin == .import else { return origin }
        if payload.recordType == ImportRun.databaseTableName { return origin }
        guard let run = payload.importRunUuid else { return nil }
        switch attribution {
        case nil:
            if try SyncBatch.batch(run: run, db: db) != nil { return origin }
            if try SyncRecordStore.localId(table: ImportRun.databaseTableName, uuid: run, db: db) != nil { return origin }
            return nil
        case .appUser(let writer)?:
            return try runMaker(run, db: db) == writer ? origin : nil
        case .selfUser?, .unknown?:
            return nil
        }
    }

    /// Who made import run `run` (its insert clock's writer): as held here, else as its record waits in staging.
    private static func runMaker(_ run: String, db: Database) throws -> String? {
        let table = ImportRun.databaseTableName
        if let localId = try SyncRecordStore.localId(table: table, uuid: run, db: db) {
            return try SyncMerge.clocks(table: table, localId: localId, db: db)[SyncMerge.insertClock]?.by
        }
        guard let json = try String.fetchOne(db, sql: "SELECT payloadJSON FROM syncStaging WHERE uuid = ? AND tableName = ?", arguments: [run, table]),
              let staged = try? JSONDecoder().decode(SyncPayload.self, from: Data(json.utf8)) else { return nil }
        switch try attributedWriter(staged, selfUser: nil, db: db) {
        case nil: return staged.clocks[SyncMerge.insertClock]?.by
        case .appUser(let writer)?: return writer
        case .selfUser?, .unknown?: return nil
        }
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

    /// Why `decision` fails for the writer: the first area they lack; else an owner's say they don't have, or nobody's,
    /// under the table's own area.
    private static func failure(_ actor: AccessActor?, _ decision: AccessDecision, table: String, db: Database) throws -> (AccessArea, Reason) {
        for area in decision.areas {
            guard let actor else { return (area, .area) }
            if try !AccessPolicy.can(actor, .edit, area, db: db) { return (area, .area) }
        }
        let area = AccessAreaMap.tableArea(table) ?? decision.areas.first ?? .budgetAndAccounts
        return (area, decision.containsNobody ? .nobody : .ownerOnly)
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
                """, arguments: [now, revert.writer, storedReason(revert), table, uuid, revert.fields.sorted().joined(separator: ",")])
            log.notice("Reverted an incoming change to a \(table, privacy: .public) record: \(reasonText(storedReason(revert)), privacy: .public)")
        }
    }

    private static func storedReason(_ revert: Revert) -> String {
        switch revert.reason {
        case .area: return revert.area.storageKey
        case .ownerOnly: return ownerOnlyKey
        case .nobody: return nobodyKey
        case .statementSent: return statementSentKey
        }
    }

    /// The log's reason for a stored `syncAccessRevert.area`.
    static func reasonText(_ stored: String) -> String {
        switch stored {
        case ownerOnlyKey: return "no permission: only the owner can change this"
        case nobodyKey: return "no permission: nobody can change this"
        case statementSentKey: return "Statement already sent"
        default: return "no permission for \(AccessArea(storageKey: stored)?.title ?? "this area")"
        }
    }

    // MARK: Deletes (step 7a)

    /// What `syncAccessRevert.fields` holds for a reverted delete.
    static let deleteFields = "*"

    /// Whether a delete of the record `uuid` (a `table` row) by `attribution`'s writer stands: judged on the record as
    /// this device holds it (`AccessAreaMap.area(… change: .delete, row: …)`). A record not held here has nothing to judge.
    public static func deleteVerdict(uuid: String, table: String, attribution: Attribution, db: Database) throws -> Verdict {
        guard let revert = try deleteRevert(uuid: uuid, table: table, attribution: attribution, origin: nil, db: db) else { return .allowed }
        return .revert(fields: revert.fields, area: revert.area, writerAppUserUuid: revert.writer)
    }

    /// The revert a delete needs (nil: it stands). `origin`: the marker's, as far as it is believed (`judgedOrigin`).
    static func deleteRevert(uuid: String, table: String, attribution: Attribution, origin: WriteOrigin?, db: Database) throws -> Revert? {
        let writer: String?
        let actor: AccessActor?
        switch attribution {
        case .selfUser:
            return nil
        case .appUser(let user):
            writer = user
            actor = try SyncRecordStore.localId(table: "appUser", uuid: user, db: db).map { try AccessActor.load(appUserId: $0, db: db) }
        case .unknown:
            writer = nil
            actor = nil
        }
        guard let localId = try SyncRecordStore.localId(table: table, uuid: uuid, db: db),
              let row = try SyncTranslator.outgoing(PendingChange(table: table, localId: localId, uuid: uuid, kind: .update), db: db)?.fields
        else { return nil }
        // A line taken off a statement someone else sent (step 8): its lines are fixed.
        if table == "rechargeLine",
           let statementId = try Int64.fetchOne(db, sql: "SELECT statementId FROM rechargeLine WHERE id = ?", arguments: [localId]),
           try sentBySomeoneElse(statementId: statementId, writer: writer, db: db) {
            return Revert(fields: [deleteFields], area: .property, writer: writer, reason: .statementSent)
        }
        let decision = try decide(table: table, origin: origin, change: .delete, fields: [], row: row, db: db)
        if try allows(actor, decision, db: db) { return nil }
        let (area, reason) = try failure(actor, decision, table: table, db: db)
        return Revert(fields: [deleteFields], area: area, writer: writer, reason: reason)
    }

    /// An incoming delete of a record held here, judged on the Mac (while re-validating). `marker`: the deletion marker
    /// it came as (its server writer says who); nil: a bare hard deletion, which in the household no app user of this
    /// household can have made with this build (undone, unless this Mac's own tombstone holds the record), and in a
    /// private zone is its owner's (it stands). Returns whether the delete was refused: the row stays, queued to go up
    /// again as `resent` (over the marker's version, which the pull keeps as its stamp; afresh after a hard deletion),
    /// and the revert is logged.
    static func refusesDelete(uuid: String, table: String, zone: String, marker: SyncPayload?, deviceUser: String?,
                              db: Database, now: Date) throws -> Bool {
        let selfUser = try selfUser(deviceUser: deviceUser, db: db)
        let attribution: Attribution
        var origin: WriteOrigin?
        if let marker {
            // A marker from an older build's staging has no server writer: nobody this household knows (fail closed).
            attribution = try attributedWriter(marker, selfUser: selfUser, db: db) ?? .unknown
            origin = try judgedOrigin(marker, attribution: attribution, db: db)
        } else {
            guard zone == SyncZones.household else { return false }
            let tombstone = try SyncTombstoneRow.fetchOne(db, key: uuid)
            if let selfUser, tombstone?.deletedBy == selfUser { return false }
            attribution = .unknown
        }
        guard let localId = try SyncRecordStore.localId(table: table, uuid: uuid, db: db),
              let revert = try deleteRevert(uuid: uuid, table: table, attribution: attribution, origin: origin, db: db) else { return false }
        if marker == nil {
            // Gone from the server: it goes again as new (no stamp).
            try db.execute(sql: "UPDATE syncRecord SET systemFields = NULL, changeTag = NULL WHERE uuid = ?", arguments: [uuid])
        }
        try SyncMerge.queue(uuid: uuid, table: table, localId: localId, kind: marker == nil ? .insert : .update, db: db)
        try db.execute(sql: "UPDATE syncPending SET resent = ? WHERE uuid = ?", arguments: [SyncTranslator.resentReconciled, uuid])
        try record([revert], table: table, uuid: uuid, db: db, now: now)
        return true
    }

    // MARK: The log

    /// The latest reverts, newest first: "Reverted a change by B: no permission for Budget & accounts", "Reverted a
    /// delete by B: …".
    public static func recentReverts(limit: Int, db: Database) throws -> [String] {
        try Row.fetchAll(db, sql: "SELECT writerAppUserUuid, area, fields FROM syncAccessRevert ORDER BY id DESC LIMIT ?", arguments: [limit]).map { row in
            let writer: String? = row["writerAppUserUuid"]
            let name = try writer.flatMap { uuid -> String? in
                guard let id = try SyncRecordStore.localId(table: "appUser", uuid: uuid, db: db) else { return nil }
                return try String.fetchOne(db, sql: "SELECT displayName FROM appUser WHERE id = ?", arguments: [id])
            } ?? unknownWriterName
            let fields: String? = row["fields"]
            return "Reverted a \(fields == deleteFields ? "delete" : "change") by \(name): \(reasonText(row["area"]))"
        }
    }
}
