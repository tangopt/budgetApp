import CryptoKit
import Foundation
import GRDB
import os

/// What happened to one incoming change.
public enum IncomingResult: Equatable, Hashable, Sendable {
    /// Written (a new record, a merge that changed nothing or only took remote values, or a delete).
    case applied
    /// Waiting in `syncStaging`; the reason names tables, never values.
    case staged(String)
    /// Merged, and these fields held a different value on both sides: the earlier one is in `syncConflict`.
    case conflicted([String])
    /// Not written: the record was deleted here, and a delete wins over an edit made while offline.
    case discarded(String)
    /// A delete that wasn't applied: a document another record still links to is never deleted. It is
    /// queued to be sent again.
    case kept(String)
}

/// One change from the cloud: a record saved, or a record deleted (by name; its type when known).
public enum SyncIncomingChange: Equatable, Sendable {
    case save(SyncPayload)
    case delete(recordName: String, recordType: String?)

    var recordName: String {
        switch self {
        case .save(let payload): return payload.recordName
        case .delete(let name, _): return name
        }
    }
}

public enum SyncTranslatorError: Error, Equatable {
    case notInTransaction
}

/// Translates between local rows and `SyncPayload`s (sync spec §4.1): local ids stay local, references
/// travel as UUIDs (declared foreign keys, `SyncSchema`'s logical and polymorphic references, and the ids
/// inside its JSON columns). Incoming records merge field by field (`SyncMerge`), wait in staging while
/// what they reference hasn't arrived, and are written with tracking off (`applyingIncoming`) so they
/// don't echo back.
public enum SyncTranslator {
    private static let log = Logger(subsystem: "com.personal.budget", category: "Sync")

    // MARK: Outgoing

    /// The payload for a pending insert or update; nil for a delete (the record name is all it needs) and
    /// for a row that is no longer there. A referenced row without an identity gets one (and is queued).
    public static func outgoing(_ change: PendingChange, db: Database) throws -> SyncPayload? {
        guard change.kind != .delete, let schema = SyncSchema.table(change.table) else { return nil }
        if let redirect = try SyncTombstoneRow.fetchOne(db, key: change.uuid), let target = redirect.mergedInto {
            // This device merged the record into another: it goes out as a redirect, never as a delete.
            return SyncPayload(recordType: schema.name, recordName: change.uuid, zone: redirect.zone, fields: [:], mergedInto: target)
        }
        guard let record = try SyncRecordRow.fetchOne(db, sql: "SELECT * FROM syncRecord WHERE tableName = ? AND localId = ?",
                                                      arguments: [change.table, change.localId]),
              record.uuid == change.uuid else { return nil }
        let columns = try Columns(table: schema.name, db: db)
        guard let row = try Row.fetchOne(db, sql: "SELECT * FROM \(SyncChangeTracker.quoted(schema.name)) WHERE \(SyncChangeTracker.quoted(schema.localIdColumn)) = ?",
                                         arguments: [change.localId]) else { return nil }
        let resolver = SyncReferenceResolver(db: db)
        resolver.history = SyncSchema.historyTables.contains(schema.name)
        let json = SyncJSONTranslator(resolver: resolver, direction: .outgoing)
        var fields: [String: SyncValue] = [:]
        for column in schema.syncedColumns where columns.declared[column] != nil {
            let value: DatabaseValue = row[column]
            if let target = schema.foreignKeys[column] ?? SyncSchema.logicalReferences(of: schema.name)[column] {
                fields[column] = try reference(value, table: target, nullable: columns.nullable(column), resolver: resolver)
            } else if let poly = SyncSchema.polymorphicReferences(of: schema.name).first(where: { $0.idColumn == column }) {
                fields[column] = try polymorphic(value, type: row[poly.typeColumn], reference: poly, resolver: resolver)
            } else if let reference = SyncSchema.jsonReferences(of: schema.name).first(where: { $0.column == column }),
                      case .string(let text) = value.storage {
                switch reference.content {
                case .rules(let rules):
                    fields[column] = .string(try json.translate(text, rules: rules, table: schema.name, column: column))
                case .rowOfTable(let typeColumn):
                    let table: String = row[typeColumn]
                    fields[column] = try json.translateRow(text, table: table, changeTable: schema.name, column: column).map(SyncValue.string) ?? .null
                }
            } else {
                fields[column] = SyncValue(value, declaredType: columns.declared[column] ?? "")
            }
        }
        var payload = SyncPayload(recordType: schema.name, recordName: record.uuid, zone: record.zone, fields: fields,
                                  clocks: try SyncMerge.clocks(table: schema.name, localId: change.localId, db: db),
                                  modifiedBy: record.modifiedBy, modifiedAt: record.modifiedAt,
                                  deletedReferences: resolver.deletedReferences.isEmpty ? nil : resolver.deletedReferences.sorted())
        try SyncBatch.decorate(&payload, db: db)
        return payload
    }

    private static func reference(_ value: DatabaseValue, table: String, nullable: Bool, resolver: SyncReferenceResolver) throws -> SyncValue {
        guard let localId = Int64.fromDatabaseValue(value) else { return value.isNull ? .null : SyncValue(value, declaredType: "") }
        if let uuid = try resolver.outgoing(table: table, localId: localId) { return .string(uuid) }
        return nullable ? .null : .int(0)
    }

    private static func polymorphic(_ value: DatabaseValue, type: String?, reference: SyncPolymorphicReference,
                                    resolver: SyncReferenceResolver) throws -> SyncValue {
        guard let type, let localId = Int64.fromDatabaseValue(value) else { return SyncValue(value, declaredType: "") }
        if let table = reference.targets[type] {
            return try resolver.outgoing(table: table, localId: localId).map(SyncValue.string) ?? .int(0)
        }
        switch reference.unlisted {
        case .dangling: return .int(0)
        case .passThrough(let types):
            guard types.contains(type) else {
                throw SyncReferenceError.unclassifiedType(table: reference.table, column: reference.typeColumn, type: type)
            }
            return .int(localId)
        }
    }

    // MARK: Incoming

    /// Applies one incoming record (and then whatever in staging it unblocks), in the caller's
    /// transaction. Same as `apply([.save(payload)])`.
    static func incoming(_ payload: SyncPayload, db: Database, deviceUser: String?, now: Date = Date()) throws -> IncomingResult {
        try apply([.save(payload)], db: db, deviceUser: deviceUser, now: now)[payload.recordName] ?? .applied
    }

    /// Applies one incoming delete, in the caller's transaction.
    static func incomingDelete(recordName: String, recordType: String? = nil, db: Database, deviceUser: String?,
                                      now: Date = Date()) throws -> IncomingResult {
        try apply([.delete(recordName: recordName, recordType: recordType)], db: db, deviceUser: deviceUser, now: now)[recordName] ?? .applied
    }

    /// Applies incoming changes in the caller's transaction, with tracking off: saves parents first, then
    /// deletes children first (so a document's links go before the document), then retries staging until
    /// nothing more applies. Rows removed by cascades and app triggers on the way lose their identity
    /// (retired, not sent: the sender removed them too). Results by record name; a record that left
    /// staging during the retries reports its final result.
    ///
    /// Records of an import batch (sync spec §5.2) wait in staging until their whole batch is here, then
    /// apply together (`SyncBatch`).
    @discardableResult
    /// `retryAll`: retry every staged record, not only those the changes unblock (after an upgrade).
    /// `followOns`: false — only the changes themselves: no staged record is retried and no waiting batch
    /// applies (the filed-year check uses it to tell what a record does from what it lets through).
    static func apply(_ changes: [SyncIncomingChange], db: Database, deviceUser: String?, now: Date = Date(),
                             retryAll: Bool = false, followOns: Bool = true) throws -> [String: IncomingResult] {
        guard db.isInsideTransaction else { throw SyncTranslatorError.notInTransaction }
        return try SyncChangeTracker.applyingIncoming(db: db) {
            let routed = try SyncBatch.route(changes, db: db, now: now)
            var results = routed.results
            for (name, result) in try applyChanges(routed.direct, db: db, deviceUser: deviceUser, now: now, retryAll: retryAll,
                                                   retry: followOns) {
                results[name] = result
            }
            guard followOns else { return results }
            // Any batch waiting here may be complete now: its last records arrived, or a parent one of them
            // waited for.
            for run in try SyncBatch.waitingRuns(db: db) {
                for (name, result) in try SyncBatch.flushIfComplete(run: run, db: db, deviceUser: deviceUser, now: now).results {
                    results[name] = result
                }
            }
            return results
        }
    }

    /// `apply` without batch routing: what `SyncBatch` applies once a batch is complete. `revivals`: records
    /// an Undo brings back (deleted here; ruling R7), by UUID, with the local id they had here.
    static func applyChanges(_ changes: [SyncIncomingChange], db: Database, deviceUser: String?, now: Date,
                             retryAll: Bool = false, retry: Bool = true, revivals: [String: Int64] = [:]) throws -> [String: IncomingResult] {
        try SyncChangeTracker.applyingIncoming(db: db) {
            var results: [String: IncomingResult] = [:]
            let order = Dictionary(uniqueKeysWithValues: SyncSchema.tables.enumerated().map { ($1.name, $0) })
            var saves: [SyncPayload] = []
            var deletes: [(name: String, type: String?)] = []
            for change in changes {
                switch change {
                case .save(let payload): saves.append(payload)
                case .delete(let name, let type): deletes.append((name, type))
                }
            }
            saves.sort { (order[$0.recordType] ?? Int.max) < (order[$1.recordType] ?? Int.max) }
            var arrived: Set<String> = []
            var unknownArrived = false
            for payload in saves {
                let result = try applySave(payload, db: db, deviceUser: deviceUser, now: now, revivals: revivals)
                results[payload.recordName] = result
                if case .staged = result {} else { arrived.insert(payload.recordType) }
            }
            let deleteTables = try deletes.map { delete in
                try delete.type ?? String.fetchOne(db, sql: "SELECT tableName FROM syncRecord WHERE uuid = ?", arguments: [delete.name])
            }
            for (delete, table) in zip(deletes, deleteTables).sorted(by: { (order[$0.1 ?? ""] ?? -1) > (order[$1.1 ?? ""] ?? -1) }) {
                results[delete.name] = try applyDelete(uuid: delete.name, recordType: table, db: db, deviceUser: deviceUser, now: now)
                // A delete of a record of unknown type may be what anything waits for.
                if let table { arrived.insert(table) } else { unknownArrived = true }
            }
            if !retry {
                // The caller retries staging itself.
            } else if unknownArrived || retryAll {
                for (name, result) in try retryStaged(db: db, deviceUser: deviceUser, now: now) { results[name] = result }
            } else if !arrived.isEmpty {
                for (name, result) in try retryStaged(db: db, deviceUser: deviceUser, now: now, arrived: arrived) { results[name] = result }
            }
            try retireRemoved(db: db, now: now)
            // Custom kinds merged into a built-in kind (here or elsewhere): what still names them is re-filed.
            try CustomDocumentKinds.settleRetired(db: db)
            return results
        }
    }

    /// Tries staged records again (parents first) until a pass applies nothing: with `arrived`, only those
    /// waiting on one of those tables (a record that arrives or goes away there may be what they wait for)
    /// and those whose apply failed; without it, every one. A staged row that can't be read is marked for
    /// attention and left. Returns the records that left staging and how.
    @discardableResult
    /// `only`: just these records (by UUID), once each.
    static func retryStaged(db: Database, deviceUser: String?, now: Date = Date(), arrived: Set<String>? = nil,
                                   only: Set<String>? = nil) throws -> [String: IncomingResult] {
        try SyncChangeTracker.applyingIncoming(db: db) {
            var results: [String: IncomingResult] = [:]
            var arrived = arrived
            let order = Dictionary(uniqueKeysWithValues: SyncSchema.tables.enumerated().map { ($1.name, $0) })
            while true {
                let staged = try SyncStagingRow.filter(Column("importRunUuid") == nil).fetchAll(db)
                    .filter { !$0.reason.hasPrefix(needsAttention) && $0.reason != waitingForHouseholdKey }
                    .filter { row in only.map { $0.contains(row.uuid) } ?? true }
                    .filter { row in
                        guard let arrived else { return true }
                        if row.reason.hasPrefix(applyFailed) { return true }
                        return !waitedFor(row.reason).isDisjoint(with: arrived)
                    }
                    .sorted { (order[$0.tableName] ?? Int.max, $0.id ?? 0) < (order[$1.tableName] ?? Int.max, $1.id ?? 0) }
                var progressed = false
                for row in staged {
                    guard let payload = try? JSONDecoder().decode(SyncPayload.self, from: Data(row.payloadJSON.utf8)) else {
                        log.error("Sync staging row for a \(row.tableName, privacy: .public) record can't be read; marked for attention")
                        try db.execute(sql: "UPDATE syncStaging SET reason = ? WHERE id = ?", arguments: [needsAttention + "unreadable payload", row.id])
                        continue
                    }
                    let result = try applySave(payload, db: db, deviceUser: deviceUser, now: now, fromStaging: true)
                    if case .staged = result { continue }
                    results[payload.recordName] = result
                    arrived?.insert(payload.recordType)
                    progressed = true
                }
                if !progressed || only != nil { return results }
            }
        }
    }

    /// Ruling R12's conflict log entries.
    public static let reconciledSent = "needs attention: was missing on iCloud; sent again"
    public static let reconciledHere = "needs attention: deleted here, sent again by another device; brought back"
    public static let reconciledEdit = "needs attention: deleted on iCloud; your edit brought it back"

    /// `syncPending.resent`: 1 sent again by reconciliation; 2 a save was answered "deleted on the server"
    /// and the edit is still to go (logged and sent as resent if no deletion arrives first).
    static let resentReconciled = 1
    static let resentAfterServerDelete = 2

    /// Ruling R12: after a full fetch of `zone`, every synced row of it here that the fetch didn't list, and
    /// that isn't pending or staged, is queued to go up again as an insert (`resent`), with no stamp, and
    /// logged. A delete missed while a token was expired comes back rather than diverging; a zone reset
    /// elsewhere gets this device's rows back. Returns the UUIDs queued.
    @discardableResult
    public static func reconcile(zone: String, listed: Set<String>, db: Database, now: Date) throws -> [String] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT uuid, tableName, localId FROM syncRecord
            WHERE zone = ? AND uuid NOT IN (SELECT uuid FROM syncPending) AND uuid NOT IN (SELECT uuid FROM syncStaging)
            ORDER BY rowid
            """, arguments: [zone])
        var queued: [String] = []
        for row in rows {
            let uuid: String = row["uuid"]
            guard !listed.contains(uuid) else { continue }
            let table: String = row["tableName"]
            try SyncMerge.queue(uuid: uuid, table: table, localId: row["localId"], kind: .insert, db: db)
            try db.execute(sql: "UPDATE syncPending SET resent = ? WHERE uuid = ?", arguments: [resentReconciled, uuid])
            try db.execute(sql: "UPDATE syncRecord SET systemFields = NULL, changeTag = NULL WHERE uuid = ?", arguments: [uuid])
            try SyncMerge.logConflict(table: table, uuid: uuid, field: "*", losing: .string(reconciledSent), winner: nil, loser: nil, db: db, now: now)
            queued.append(uuid)
        }
        if !queued.isEmpty { log.error("Sync reconciliation queued \(queued.count) records missing on the server") }
        return queued
    }

    static let waitingFor = "waiting for "
    static let applyFailed = "apply failed"
    static let needsAttention = "needs attention: "

    /// The tables a staging reason waits for.
    static func waitedFor(_ reason: String) -> Set<String> {
        guard reason.hasPrefix(waitingFor) else { return [] }
        return Set(reason.dropFirst(waitingFor.count).split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
    }

    // MARK: Saves

    private static func applySave(_ payload: SyncPayload, db: Database, deviceUser: String?, now: Date,
                                  fromStaging: Bool = false, revivals: [String: Int64] = [:]) throws -> IncomingResult {
        guard let schema = SyncSchema.table(payload.recordType), try db.tableExists(schema.name) else {
            return try stage(payload, reason: "unknown record type", db: db, now: now, fromStaging: fromStaging)
        }
        if let target = payload.mergedInto {
            return try applyRedirect(payload.recordName, to: target, schema: schema, db: db, deviceUser: deviceUser, now: now)
        }
        var payload = payload
        var redirected = false
        if try SyncRecordStore.localId(table: schema.name, uuid: payload.recordName, db: db) == nil,
           let tombstone = try SyncTombstoneRow.fetchOne(db, key: payload.recordName), let target = tombstone.mergedInto {
            // A save of a record merged into another here (from a device that hasn't merged yet) is that one.
            try db.execute(sql: "DELETE FROM syncStaging WHERE uuid = ?", arguments: [payload.recordName])
            if schema.name == CustomDocumentKind.databaseTableName, try !CustomDocumentKinds.isSameKind(payload, as: target, db: db) {
                // Except a custom kind merged into another kind (Kinds sheet): its name and area are the merged
                // one's, not the target's (what was filed under it follows the redirect). A kind merged by identity
                // (the same name made on two devices) is the same kind: its edits merge.
                return .discarded("merged into another kind here")
            }
            payload.recordName = target
            redirected = true
        }
        let uuid = payload.recordName
        let existing = try SyncRecordStore.localId(table: schema.name, uuid: uuid, db: db)
        var reviveAt: Int64?
        // Ruling R12: a record sent again (missing on the server) that was deleted here; taken back only once it
        // has been written.
        var takeBack = false
        if existing == nil, let tombstone = try SyncTombstoneRow.fetchOne(db, key: uuid), tombstone.mergedInto == nil,
           let localId = revivals[uuid] {
            // An Undo (on another device) brought back a row its import deleted: the same record comes back,
            // at the local id it had here when that is free (ruling R7).
            try db.execute(sql: "DELETE FROM syncTombstone WHERE uuid = ?", arguments: [uuid])
            reviveAt = localId
        } else if existing == nil, let tombstone = try SyncTombstoneRow.fetchOne(db, key: uuid), tombstone.mergedInto == nil {
            // A delete wins over an edit made while offline, except that a document is sent again by a
            // device that kept it because a record links to it (`kept`): it comes back.
            // Ruling R12: a record sent again because it was missing on the server comes back too, visibly
            // (a resurrected row is preferred to silent divergence; step 6 asks a person to confirm).
            if schema.name == "document" {
                try db.execute(sql: "DELETE FROM syncTombstone WHERE uuid = ?", arguments: [uuid])
            } else if payload.resent == true {
                takeBack = true
            } else {
                try db.execute(sql: "DELETE FROM syncStaging WHERE uuid = ?", arguments: [uuid])
                return .discarded("deleted here")
            }
        }
        let resolver = SyncReferenceResolver(db: db)
        resolver.history = SyncSchema.historyTables.contains(schema.name)
        resolver.incomingDeleted = Set(payload.deletedReferences ?? [])
        let columns = try Columns(table: schema.name, db: db)
        var deletedParents: [String: String] = [:]
        var values = try localValues(payload, schema: schema, columns: columns, resolver: resolver, deletedParents: &deletedParents)
        if !resolver.missing.isEmpty {
            return try stage(payload, reason: waitingFor + resolver.missing.sorted().joined(separator: ", "), db: db, now: now, fromStaging: fromStaging)
        }
        // A reference to a parent deleted here, by the foreign key's action: SET NULL takes null; otherwise a
        // new record can't exist (the delete wins: discarded and logged) and an existing one keeps its value.
        var held: [String: SyncValue] = [:]
        if !deletedParents.isEmpty, payload.resent == true, existing == nil {
            // A record sent again (ruling R12) whose parent was deleted here waits for that parent, which its
            // sender sends again too, rather than being dropped.
            let tables = Set(deletedParents.keys.map { column in
                schema.foreignKeys[column] ?? SyncSchema.logicalReferences(of: schema.name)[column] ?? column
            })
            return try stage(payload, reason: waitingFor + tables.sorted().joined(separator: ", "), db: db, now: now, fromStaging: fromStaging)
        }
        if !deletedParents.isEmpty {
            let actions = try foreignKeyActions(schema.name, db: db)
            for (column, parent) in deletedParents.sorted(by: { $0.key < $1.key }) {
                if actions[column] == "SET NULL" {
                    values[column] = .null
                } else if existing != nil {
                    values[column] = nil
                    held[column] = .string(parent)
                } else {
                    try db.execute(sql: "DELETE FROM syncStaging WHERE uuid = ?", arguments: [uuid])
                    try SyncMerge.logConflict(table: schema.name, uuid: uuid, field: "*", losing: .string(try json(payload)),
                                              winner: deviceUser, loser: payload.modifiedBy, db: db, now: now)
                    return .discarded("parent deleted: " + (schema.foreignKeys[column] ?? column))
                }
            }
        }
        // One payload's failure (a constraint this device's data refuses) mustn't undo the others: it is
        // staged with the SQLite code, never the values.
        let savepoint = "syncApplySave"
        try db.execute(sql: "SAVEPOINT \(savepoint)")
        do {
            let result: IncomingResult
            if let localId = existing {
                result = try SyncMerge.merge(payload, into: localId, values: values, held: held, schema: schema, db: db, deviceUser: deviceUser,
                                             adopted: redirected, now: now)
            } else {
                result = try insert(payload, values: values, schema: schema, db: db, deviceUser: deviceUser, now: now, at: reviveAt)
                if takeBack, try SyncRecordStore.localId(table: schema.name, uuid: uuid, db: db) != nil {
                    // Written: the delete made here gives way, visibly (step 6 asks a person to confirm).
                    try db.execute(sql: "DELETE FROM syncTombstone WHERE uuid = ?", arguments: [uuid])
                    try db.execute(sql: "DELETE FROM syncPending WHERE uuid = ? AND kind = 'delete'", arguments: [uuid])
                    try SyncMerge.logConflict(table: schema.name, uuid: uuid, field: "*", losing: .string(reconciledHere),
                                              winner: payload.modifiedBy, loser: deviceUser, db: db, now: now)
                }
            }
            try db.execute(sql: "DELETE FROM syncStaging WHERE uuid = ?", arguments: [uuid])
            try db.execute(sql: "RELEASE \(savepoint)")
            return result
        } catch let error as DatabaseError {
            try db.execute(sql: "ROLLBACK TO \(savepoint)")
            try db.execute(sql: "RELEASE \(savepoint)")
            log.error("Sync apply of a \(schema.name, privacy: .public) record failed: SQLite \(error.extendedResultCode.rawValue)")
            return try stage(payload, reason: applyFailed + ": SQLite \(error.extendedResultCode.rawValue)", db: db, now: now, fromStaging: fromStaging)
        } catch {
            try db.execute(sql: "ROLLBACK TO \(savepoint)")
            try db.execute(sql: "RELEASE \(savepoint)")
            return try stage(payload, reason: applyFailed + ": \(type(of: error))", db: db, now: now, fromStaging: fromStaging)
        }
    }

    /// `old` was merged into `target` on another device: this device's row re-keys to it (never deleted),
    /// and `old` stays a redirect so references to it resolve.
    private static func applyRedirect(_ old: String, to target: String, schema: SyncTableSchema, db: Database, deviceUser: String?,
                                      now: Date) throws -> IncomingResult {
        try db.execute(sql: "DELETE FROM syncStaging WHERE uuid = ?", arguments: [old])
        let row = try SyncRecordStore.localId(table: schema.name, uuid: old, db: db)
        if row != nil {
            if try SyncRecordStore.localId(table: schema.name, uuid: target, db: db) == nil {
                try SyncMerge.rekey(from: old, to: target, db: db)
            } else if schema.name == CustomDocumentKind.databaseTableName, let oldId = row,
                      let targetId = try SyncRecordStore.localId(table: schema.name, uuid: target, db: db) {
                // A custom kind merged into another elsewhere: what this device files under it moves to the target.
                try CustomDocumentKinds.absorbIncomingMerge(db: db, from: oldId, into: targetId, oldUUID: old, targetUUID: target,
                                                            deviceUser: deviceUser, now: now)
                return .applied
            } else {
                // Both records are rows here: they can't be fused by a redirect; both stay.
                log.error("Sync redirect of a \(schema.name, privacy: .public) record whose target is another row here; both kept")
                try SyncMerge.logConflict(table: schema.name, uuid: old, field: "*",
                                          losing: .string(needsAttention + "merged into \(target) elsewhere, but both are rows here"),
                                          winner: nil, loser: nil, db: db, now: now)
                return .kept("both records are rows here")
            }
        }
        try SyncMerge.redirect(old, to: target, table: schema.name, localId: row ?? 0, zone: SyncRecordStore.householdZone,
                               by: nil, now: now, db: db)
        return .applied
    }

    /// `onDelete` of each foreign key column (`CASCADE`, `SET NULL`, `RESTRICT`, `NO ACTION`).
    static func foreignKeyActions(_ table: String, db: Database) throws -> [String: String] {
        var actions: [String: String] = [:]
        for row in try Row.fetchAll(db, sql: "PRAGMA foreign_key_list(\(SyncChangeTracker.quoted(table)))") {
            actions[row["from"]] = (row["on_delete"] as String).uppercased()
        }
        return actions
    }

    static func json(_ payload: SyncPayload) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(payload), as: UTF8.self)
    }

    /// The payload's fields as this device's values, references translated (what's missing is noted on
    /// the resolver). Fields this device's schema doesn't have are ignored.
    static func localValues(_ payload: SyncPayload, schema: SyncTableSchema, columns: Columns,
                            resolver: SyncReferenceResolver, deletedParents: inout [String: String]) throws -> [String: DatabaseValue] {
        let json = SyncJSONTranslator(resolver: resolver, direction: .incoming)
        var values: [String: DatabaseValue] = [:]
        let logical = SyncSchema.logicalReferences(of: schema.name)
        for column in schema.syncedColumns where columns.declared[column] != nil {
            guard let value = payload.fields[column] else { continue }
            if let target = schema.foreignKeys[column] {
                if case .string(let uuid) = value, try resolver.incoming(table: target, uuid: uuid) == .deleted {
                    deletedParents[column] = uuid
                    values[column] = .null
                    continue
                }
                values[column] = try incomingReference(value, nullable: columns.nullable(column)) { try resolver.incomingStrong(table: target, uuid: $0) }
            } else if let target = logical[column] {
                values[column] = try incomingReference(value, nullable: columns.nullable(column)) { try resolver.incomingWeak(table: target, uuid: $0) }
            } else if let poly = SyncSchema.polymorphicReferences(of: schema.name).first(where: { $0.idColumn == column }) {
                guard case .string(let type) = payload.fields[poly.typeColumn] ?? .null, let table = poly.targets[type] else {
                    values[column] = value.databaseValue
                    continue
                }
                values[column] = try incomingReference(value, nullable: false) { try resolver.incomingWeak(table: table, uuid: $0) }
            } else if let reference = SyncSchema.jsonReferences(of: schema.name).first(where: { $0.column == column }),
                      case .string(let text) = value {
                switch reference.content {
                case .rules(let rules):
                    values[column] = try json.translate(text, rules: rules, table: schema.name, column: column).databaseValue
                case .rowOfTable(let typeColumn):
                    guard case .string(let table) = payload.fields[typeColumn] ?? .null else {
                        values[column] = value.databaseValue
                        continue
                    }
                    values[column] = (try json.translateRow(text, table: table, changeTable: schema.name, column: column) ?? text).databaseValue
                }
            } else {
                values[column] = value.databaseValue
            }
        }
        return values
    }

    private static func incomingReference(_ value: SyncValue, nullable: Bool, resolve: (String) throws -> Int64?) throws -> DatabaseValue {
        guard case .string(let uuid) = value else { return value.databaseValue }
        if let localId = try resolve(uuid) { return localId.databaseValue }
        return nullable ? .null : (0 as Int64).databaseValue
    }

    /// A record new to this device. Its local id is a fresh one, except `propertyMortgageTerms`, whose id
    /// is its property's (ruling R2). A unique key it collides on resolves as `SyncSchema.uniqueKeys`
    /// declares: an identity key merges into the existing row; any other keeps both rows (suffix, exclusive
    /// flag, yield), every other field applying, and logs what it changed.
    private static func insert(_ payload: SyncPayload, values: [String: DatabaseValue], schema: SyncTableSchema, db: Database,
                               deviceUser: String?, now: Date, at preferred: Int64? = nil) throws -> IncomingResult {
        var values = values
        let original = values
        if let preferred, preferred != 0, !schema.syncedColumns.contains(schema.localIdColumn),
           try !Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM \(SyncChangeTracker.quoted(schema.name)) WHERE \(SyncChangeTracker.quoted(schema.localIdColumn)) = ?)",
                              arguments: [preferred])! {
            values[schema.localIdColumn] = preferred.databaseValue
        }
        var changed: [String] = []
        var suffixes: [String: Int] = [:]
        let table = SyncChangeTracker.quoted(schema.name)
        for _ in 0..<64 {
            let names = values.keys.sorted()
            do {
                try db.execute(sql: "INSERT INTO \(table) (\(names.map(SyncChangeTracker.quoted).joined(separator: ", "))) VALUES (\(Array(repeating: "?", count: names.count).joined(separator: ", ")))",
                               arguments: StatementArguments(names.map { values[$0]! }))
            } catch let error as DatabaseError where SyncUniqueIndex.isUniqueViolation(error) {
                guard let index = try SyncUniqueIndex.violated(by: error, table: schema.name, db: db), let key = index.key,
                      let other = try index.conflictingRow(values: values, db: db) else { throw error }
                let otherName = try SyncRecordStore.existingUUID(table: schema.name, localId: other, db: db) ?? ""
                let incomingLoses = payload.recordName > otherName
                switch key.resolution {
                case .identity:
                    return try SyncMerge.adopt(payload, into: other, values: original, schema: schema, db: db, deviceUser: deviceUser, now: now)
                case .suffix(let column):
                    if incomingLoses {
                        guard let text = String.fromDatabaseValue(original[column] ?? .null) else { throw error }
                        let n = (suffixes[column] ?? 1) + 1
                        suffixes[column] = n
                        values[column] = SyncMerge.suffixed(text, n).databaseValue
                        changed.append(column)
                    } else {
                        try SyncMerge.localSuffix(schema, other, column, db: db, deviceUser: deviceUser, now: now)
                    }
                case .exclusiveFlag(let column):
                    if try SyncMerge.flagWins(payload.clock(column), payload.recordName, over: schema, other, column, db: db) {
                        try SyncMerge.localSet(schema, other, column, false.databaseValue, db: db, deviceUser: deviceUser, now: now)
                    } else {
                        values[column] = false.databaseValue
                        changed.append(column)
                    }
                case .yield(let column, let value):
                    if incomingLoses {
                        values[column] = value.databaseValue
                        changed.append(column)
                    } else {
                        try SyncMerge.localSet(schema, other, column, value.databaseValue, db: db, deviceUser: deviceUser, now: now)
                    }
                }
                continue
            }
            let localId = schema.syncedColumns.contains(schema.localIdColumn)
                ? Int64.fromDatabaseValue(values[schema.localIdColumn] ?? .null) ?? db.lastInsertedRowID
                : db.lastInsertedRowID
            try SyncMerge.recordIdentity(payload, localId: localId, table: schema.name, db: db)
            // What this device changed to make room is a local edit of the incoming record, logged and sent.
            let fields = Array(Set(changed)).sorted()
            for field in fields {
                try SyncMerge.recordLocalEdit(schema, localId, field, old: original[field] ?? .null, db: db, deviceUser: deviceUser, now: now)
            }
            return fields.isEmpty ? .applied : .conflicted(fields)
        }
        throw DatabaseError(resultCode: .SQLITE_CONSTRAINT, message: "unique collisions unresolved")
    }

    /// Ruling R8: a record SQLite refuses is tried this many times (each apply that tries it counts), then
    /// waits marked "needs attention" and is no longer retried (step 6 surfaces it).
    public static let maxApplyAttempts = 5
    /// Ruling R8: a record waiting longer than this is listed by `stagingAttention`.
    public static let stagingMaxAge: TimeInterval = 7 * 86_400

    private static func stage(_ payload: SyncPayload, reason: String, db: Database, now: Date, fromStaging: Bool) throws -> IncomingResult {
        let failed = reason.hasPrefix(applyFailed)
        if !fromStaging {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let json = String(decoding: try encoder.encode(payload), as: UTF8.self)
            // A newer version of a waiting record keeps its first-seen time, and starts its attempts again.
            try db.execute(sql: """
                INSERT INTO syncStaging(tableName, uuid, payloadJSON, reason, importRunUuid, receivedAt, firstSeenAt, attempts)
                    VALUES (?, ?, ?, ?, NULL, ?, ?, ?)
                ON CONFLICT(uuid) DO UPDATE SET tableName = excluded.tableName, payloadJSON = excluded.payloadJSON,
                    reason = excluded.reason, receivedAt = excluded.receivedAt, attempts = excluded.attempts
                """, arguments: [payload.recordType, payload.recordName, json, reason, now, now, failed ? 1 : 0])
            return .staged(reason)
        }
        let attempts = (try Int.fetchOne(db, sql: "SELECT attempts FROM syncStaging WHERE uuid = ?", arguments: [payload.recordName]) ?? 0)
            + (failed ? 1 : 0)
        var stored = reason
        if failed, attempts >= maxApplyAttempts {
            log.error("Sync staging: a \(payload.recordType, privacy: .public) record failed \(attempts) times; marked for attention")
            stored = needsAttention + reason
        }
        try db.execute(sql: "UPDATE syncStaging SET reason = ?, attempts = ? WHERE uuid = ?", arguments: [stored, attempts, payload.recordName])
        return .staged(stored)
    }

    /// Staged records that need someone (ruling R8, surfaced in step 6): those marked "needs attention",
    /// those that have waited longer than `maxAge` (a parent or a batch that never came), and those that
    /// hold back a local edit of the same record (it isn't sent while the server's version waits here).
    public static func stagingAttention(db: Database, now: Date = Date(), maxAge: TimeInterval = stagingMaxAge) throws -> [SyncStagingRow] {
        try SyncStagingRow.fetchAll(db, sql: """
            SELECT * FROM syncStaging WHERE reason LIKE ? OR COALESCE(firstSeenAt, receivedAt) < ?
                OR uuid IN (SELECT uuid FROM syncPending WHERE kind <> 'delete') ORDER BY id
            """, arguments: [needsAttention + "%", now.addingTimeInterval(-maxAge)])
    }

    /// A record from the cloud that can't be read (its asset damaged, or its encoding unknown): kept in
    /// staging for attention and never retried, so one bad record doesn't hold up the rest of a pull. A
    /// readable version arriving later replaces it.
    public static func stageUnreadable(recordType: String, recordName: String, db: Database, now: Date) throws {
        log.error("Sync received a \(recordType, privacy: .public) record that can't be read; marked for attention")
        try db.execute(sql: """
            INSERT INTO syncStaging(tableName, uuid, payloadJSON, reason, importRunUuid, receivedAt, firstSeenAt, attempts)
                VALUES (?, ?, '{}', ?, NULL, ?, ?, 0)
            ON CONFLICT(uuid) DO UPDATE SET tableName = excluded.tableName, payloadJSON = excluded.payloadJSON,
                reason = excluded.reason, importRunUuid = NULL, receivedAt = excluded.receivedAt
            """, arguments: [recordType, recordName, needsAttention + "unreadable payload", now, now])
    }

    // MARK: Waiting for the household key (ruling R15)

    /// The reason of a record sealed under a zone key this device doesn't hold yet. Not "needs attention": it opens
    /// by itself once iCloud Keychain delivers the key.
    public static let waitingForHouseholdKey = "waiting for the household key"

    /// A sealed record kept while its key hasn't arrived: the record as the server holds it, with its stamp.
    struct SealedRecord: Codable {
        var recordType: String
        var recordName: String
        var zone: String
        var encryptedFields: [String: Data]
        var assets: [String: Data]
        var systemFields: Data
        var changeTag: String
        var modifiedAt: Date

        init(_ record: SyncServerRecord) {
            recordType = record.wire.recordType
            recordName = record.wire.recordName
            zone = record.wire.zone
            encryptedFields = record.wire.encryptedFields
            assets = record.wire.assets
            systemFields = record.stamp.systemFields
            changeTag = record.stamp.changeTag
            modifiedAt = record.stamp.modifiedAt
        }

        var server: SyncServerRecord {
            SyncServerRecord(wire: SyncWireRecord(recordType: recordType, recordName: recordName, zone: zone,
                                                  encryptedFields: encryptedFields, assets: assets),
                             stamp: SyncServerStamp(systemFields: systemFields, changeTag: changeTag, modifiedAt: modifiedAt))
        }
    }

    /// Keeps a record sealed under a key not held here, sealed, until the key arrives (a newer version replaces it).
    static func stageWaitingForKey(_ record: SyncServerRecord, db: Database, now: Date) throws {
        let json = String(decoding: try JSONEncoder().encode(SealedRecord(record)), as: UTF8.self)
        try db.execute(sql: """
            INSERT INTO syncStaging(tableName, uuid, payloadJSON, reason, importRunUuid, receivedAt, firstSeenAt, attempts)
                VALUES (?, ?, ?, ?, NULL, ?, ?, 0)
            ON CONFLICT(uuid) DO UPDATE SET tableName = excluded.tableName, payloadJSON = excluded.payloadJSON,
                reason = excluded.reason, importRunUuid = NULL, receivedAt = excluded.receivedAt, attempts = 0
            """, arguments: [record.wire.recordType, record.wire.recordName, json, waitingForHouseholdKey, now, now])
    }

    /// The records waiting for a key that `keys` now opens, in the order they arrived, with their stamps; their
    /// staging rows are removed (the caller applies them as if just received). A row that doesn't open for another
    /// reason (damaged) is marked for attention; one whose key is still missing stays.
    static func takeWaitingForKey(keys: [String: SymmetricKey], db: Database, now: Date) throws -> [(SyncPayload, SyncServerStamp)] {
        let rows = try SyncStagingRow.filter(Column("reason") == waitingForHouseholdKey).order(Column("id")).fetchAll(db)
        var opened: [(SyncPayload, SyncServerStamp)] = []
        for row in rows {
            guard let sealed = try? JSONDecoder().decode(SealedRecord.self, from: Data(row.payloadJSON.utf8)) else {
                try db.execute(sql: "UPDATE syncStaging SET reason = ? WHERE id = ?", arguments: [needsAttention + "unreadable payload", row.id])
                continue
            }
            let server = sealed.server
            do {
                let payload = try SyncLargePayload.payload(from: server.wire, keys: keys)
                try db.execute(sql: "DELETE FROM syncStaging WHERE id = ?", arguments: [row.id])
                opened.append((payload, server.stamp))
            } catch FieldSealing.SealingError.keyMissing {
                continue
            } catch {
                log.error("Sync received a \(row.tableName, privacy: .public) record that can't be read; marked for attention")
                try db.execute(sql: "UPDATE syncStaging SET payloadJSON = '{}', reason = ? WHERE id = ?",
                               arguments: [needsAttention + "unreadable payload", row.id])
            }
        }
        return opened
    }

    // MARK: Deletes

    private static func applyDelete(uuid: String, recordType: String?, db: Database, deviceUser: String?, now: Date) throws -> IncomingResult {
        let staged = try SyncStagingRow.filter(Column("uuid") == uuid).fetchOne(db)
        try db.execute(sql: "DELETE FROM syncStaging WHERE uuid = ?", arguments: [uuid])
        if try SyncTombstoneRow.fetchOne(db, key: uuid)?.mergedInto != nil {
            // Merged into another record here: its row belongs to that one and is never deleted for it.
            return .applied
        }
        guard let record = try SyncRecordRow.fetchOne(db, sql: "SELECT * FROM syncRecord WHERE uuid = ?", arguments: [uuid]),
              let schema = SyncSchema.table(record.tableName) else {
            // Never seen here (or only staged): remembered, so a reference to it names no row and a late
            // edit doesn't bring it back.
            try db.execute(sql: """
                INSERT INTO syncTombstone(uuid, tableName, localId, zone, deletedBy, deletedAt) VALUES (?, ?, 0, ?, NULL, ?)
                ON CONFLICT(uuid) DO NOTHING
                """, arguments: [uuid, recordType ?? staged?.tableName ?? "", SyncRecordStore.householdZone, now])
            return .applied
        }
        if schema.name == "document",
           try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM documentLink WHERE documentId = ?", arguments: [record.localId]) ?? 0 > 0 {
            // The evidence library never deletes a document a record links to: it is sent again.
            try SyncMerge.queue(uuid: uuid, table: schema.name, localId: record.localId, kind: .insert, db: db)
            return .kept("linked document")
        }
        // A parent whose children here still point at it (NO ACTION, RESTRICT) refuses the delete: it is
        // kept and logged, and the rest of the apply goes on.
        try db.execute(sql: "SAVEPOINT syncApplyDelete")
        do {
            try db.execute(sql: "DELETE FROM \(SyncChangeTracker.quoted(schema.name)) WHERE \(SyncChangeTracker.quoted(schema.localIdColumn)) = ?",
                           arguments: [record.localId])
            try db.execute(sql: "RELEASE syncApplyDelete")
        } catch let error as DatabaseError where error.extendedResultCode == .SQLITE_CONSTRAINT_FOREIGNKEY || error.resultCode == .SQLITE_CONSTRAINT {
            try db.execute(sql: "ROLLBACK TO syncApplyDelete")
            try db.execute(sql: "RELEASE syncApplyDelete")
            try SyncMerge.logConflict(table: schema.name, uuid: uuid, field: "*", losing: .string("delete refused: records here still point at it"),
                                      winner: deviceUser, loser: nil, db: db, now: now)
            return .kept("still referenced")
        }
        try SyncMerge.retire(uuid: uuid, table: schema.name, localId: record.localId, zone: record.zone, deletedBy: nil, now: now, db: db)
        return .applied
    }

    /// Identities whose row went during the apply (cascades, app triggers): retired with a tombstone, not
    /// sent, because the sender's own delete removed them there too.
    static func retireRemoved(db: Database, now: Date) throws {
        for table in SyncSchema.tables where try db.tableExists(table.name) {
            let gone = "s.tableName = ? AND NOT EXISTS (SELECT 1 FROM \(SyncChangeTracker.quoted(table.name)) t WHERE t.\(SyncChangeTracker.quoted(table.localIdColumn)) = s.localId)"
            let orphans = try SyncRecordRow.fetchAll(db, sql: "SELECT s.* FROM syncRecord s WHERE \(gone)", arguments: [table.name])
            for record in orphans {
                // Removed by a cascade or an app trigger of an incoming delete: logged, so the loss isn't silent
                // (with what this device still had to send of it).
                let pending = try String.fetchOne(db, sql: "SELECT kind FROM syncPending WHERE uuid = ?", arguments: [record.uuid])
                try SyncMerge.logConflict(table: table.name, uuid: record.uuid, field: "*",
                                          losing: .string(pending.map { "removed with its parent; unsent \($0)" } ?? "removed with its parent"),
                                          winner: nil, loser: nil, db: db, now: now)
                try SyncMerge.retire(uuid: record.uuid, table: table.name, localId: record.localId, zone: record.zone, deletedBy: nil, now: now, db: db)
            }
        }
    }
}

/// A table's declared column types and nullability.
struct Columns {
    let declared: [String: String]
    private let notNull: Set<String>

    init(table: String, db: Database) throws {
        let columns = try db.columns(in: table)
        declared = Dictionary(uniqueKeysWithValues: columns.map { ($0.name, $0.type) })
        notNull = Set(columns.filter(\.isNotNull).map(\.name))
    }

    func nullable(_ column: String) -> Bool { !notNull.contains(column) }
}
