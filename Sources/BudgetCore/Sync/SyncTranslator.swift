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
        guard let record = try SyncRecordRow.fetchOne(db, sql: "SELECT * FROM syncRecord WHERE tableName = ? AND localId = ?",
                                                      arguments: [change.table, change.localId]),
              record.uuid == change.uuid else { return nil }
        let columns = try Columns(table: schema.name, db: db)
        guard let row = try Row.fetchOne(db, sql: "SELECT * FROM \(SyncChangeTracker.quoted(schema.name)) WHERE \(SyncChangeTracker.quoted(schema.localIdColumn)) = ?",
                                         arguments: [change.localId]) else { return nil }
        let resolver = SyncReferenceResolver(db: db)
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
        return SyncPayload(recordType: schema.name, recordName: record.uuid, zone: record.zone, fields: fields,
                           clocks: try SyncMerge.clocks(table: schema.name, localId: change.localId, db: db),
                           modifiedBy: record.modifiedBy, modifiedAt: record.modifiedAt)
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
    public static func incoming(_ payload: SyncPayload, db: Database, deviceUser: String?, now: Date = Date()) throws -> IncomingResult {
        try apply([.save(payload)], db: db, deviceUser: deviceUser, now: now)[payload.recordName] ?? .applied
    }

    /// Applies one incoming delete, in the caller's transaction.
    public static func incomingDelete(recordName: String, recordType: String? = nil, db: Database, deviceUser: String?,
                                      now: Date = Date()) throws -> IncomingResult {
        try apply([.delete(recordName: recordName, recordType: recordType)], db: db, deviceUser: deviceUser, now: now)[recordName] ?? .applied
    }

    /// Applies incoming changes in the caller's transaction, with tracking off: saves parents first, then
    /// deletes children first (so a document's links go before the document), then retries staging until
    /// nothing more applies. Rows removed by cascades and app triggers on the way lose their identity
    /// (retired, not sent: the sender removed them too). Results by record name; a record that left
    /// staging during the retries reports its final result.
    @discardableResult
    public static func apply(_ changes: [SyncIncomingChange], db: Database, deviceUser: String?, now: Date = Date()) throws -> [String: IncomingResult] {
        guard db.isInsideTransaction else { throw SyncTranslatorError.notInTransaction }
        return try SyncChangeTracker.applyingIncoming(db: db) {
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
            var applied = false
            for payload in saves {
                let result = try applySave(payload, db: db, deviceUser: deviceUser, now: now)
                results[payload.recordName] = result
                if case .staged = result {} else { applied = true }
            }
            let deleteTables = try deletes.map { delete in
                try delete.type ?? String.fetchOne(db, sql: "SELECT tableName FROM syncRecord WHERE uuid = ?", arguments: [delete.name])
            }
            for (delete, table) in zip(deletes, deleteTables).sorted(by: { (order[$0.1 ?? ""] ?? -1) > (order[$1.1 ?? ""] ?? -1) }) {
                results[delete.name] = try applyDelete(uuid: delete.name, recordType: table, db: db, deviceUser: deviceUser, now: now)
                applied = true
            }
            if applied {
                for (name, result) in try retryStaged(db: db, deviceUser: deviceUser, now: now) { results[name] = result }
            }
            try retireRemoved(db: db, now: now)
            return results
        }
    }

    /// Tries every staged record again (parents first) until a pass applies nothing. Returns the records
    /// that left staging and how.
    @discardableResult
    public static func retryStaged(db: Database, deviceUser: String?, now: Date = Date()) throws -> [String: IncomingResult] {
        try SyncChangeTracker.applyingIncoming(db: db) {
            var results: [String: IncomingResult] = [:]
            let order = Dictionary(uniqueKeysWithValues: SyncSchema.tables.enumerated().map { ($1.name, $0) })
            while true {
                let staged = try SyncStagingRow.filter(Column("importRunUuid") == nil).fetchAll(db)
                    .sorted { (order[$0.tableName] ?? Int.max, $0.id ?? 0) < (order[$1.tableName] ?? Int.max, $1.id ?? 0) }
                var progressed = false
                for row in staged {
                    guard let payload = try? JSONDecoder().decode(SyncPayload.self, from: Data(row.payloadJSON.utf8)) else { continue }
                    let result = try applySave(payload, db: db, deviceUser: deviceUser, now: now, fromStaging: true)
                    if case .staged = result { continue }
                    results[payload.recordName] = result
                    progressed = true
                }
                if !progressed { return results }
            }
        }
    }

    // MARK: Saves

    private static func applySave(_ payload: SyncPayload, db: Database, deviceUser: String?, now: Date,
                                  fromStaging: Bool = false) throws -> IncomingResult {
        guard let schema = SyncSchema.table(payload.recordType), try db.tableExists(schema.name) else {
            return try stage(payload, reason: "unknown record type", db: db, now: now, fromStaging: fromStaging)
        }
        let uuid = payload.recordName
        let existing = try SyncRecordStore.localId(table: schema.name, uuid: uuid, db: db)
        if existing == nil, try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM syncTombstone WHERE uuid = ?)", arguments: [uuid]) ?? false {
            // A delete wins over an edit made while offline, except that a document is sent again by a
            // device that kept it because a record links to it (`kept`): it comes back.
            guard schema.name == "document" else {
                try db.execute(sql: "DELETE FROM syncStaging WHERE uuid = ?", arguments: [uuid])
                return .discarded("deleted here")
            }
            try db.execute(sql: "DELETE FROM syncTombstone WHERE uuid = ?", arguments: [uuid])
        }
        let resolver = SyncReferenceResolver(db: db)
        let columns = try Columns(table: schema.name, db: db)
        let values = try localValues(payload, schema: schema, columns: columns, resolver: resolver)
        if !resolver.deletedParents.isEmpty || !resolver.missing.isEmpty {
            let reason = resolver.missing.isEmpty
                ? "parent deleted: " + resolver.deletedParents.sorted().joined(separator: ", ")
                : "waiting for " + resolver.missing.sorted().joined(separator: ", ")
            return try stage(payload, reason: reason, db: db, now: now, fromStaging: fromStaging)
        }
        // One payload's failure (a constraint this device's data refuses) mustn't undo the others: it is
        // staged with the SQLite code, never the values.
        let savepoint = "syncApplySave"
        try db.execute(sql: "SAVEPOINT \(savepoint)")
        do {
            let result: IncomingResult
            if let localId = existing {
                result = try SyncMerge.merge(payload, into: localId, values: values, schema: schema, db: db, deviceUser: deviceUser, now: now)
            } else {
                result = try insert(payload, values: values, schema: schema, db: db, deviceUser: deviceUser, now: now)
            }
            try db.execute(sql: "DELETE FROM syncStaging WHERE uuid = ?", arguments: [uuid])
            try db.execute(sql: "RELEASE \(savepoint)")
            return result
        } catch let error as DatabaseError {
            try db.execute(sql: "ROLLBACK TO \(savepoint)")
            try db.execute(sql: "RELEASE \(savepoint)")
            log.error("Sync apply of a \(schema.name, privacy: .public) record failed: SQLite \(error.extendedResultCode.rawValue)")
            return try stage(payload, reason: "apply failed: SQLite \(error.extendedResultCode.rawValue)", db: db, now: now, fromStaging: fromStaging)
        } catch {
            try db.execute(sql: "ROLLBACK TO \(savepoint)")
            try db.execute(sql: "RELEASE \(savepoint)")
            return try stage(payload, reason: "apply failed: \(type(of: error))", db: db, now: now, fromStaging: fromStaging)
        }
    }

    /// The payload's fields as this device's values, references translated (what's missing is noted on
    /// the resolver). Fields this device's schema doesn't have are ignored.
    static func localValues(_ payload: SyncPayload, schema: SyncTableSchema, columns: Columns,
                            resolver: SyncReferenceResolver) throws -> [String: DatabaseValue] {
        let json = SyncJSONTranslator(resolver: resolver, direction: .incoming)
        var values: [String: DatabaseValue] = [:]
        let logical = SyncSchema.logicalReferences(of: schema.name)
        for column in schema.syncedColumns where columns.declared[column] != nil {
            guard let value = payload.fields[column] else { continue }
            if let target = schema.foreignKeys[column] {
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
    /// is its property's (ruling R2). A row that a unique constraint says is the same record (both
    /// devices made it: a built-in category, one property's mortgage terms) is merged into instead.
    private static func insert(_ payload: SyncPayload, values: [String: DatabaseValue], schema: SyncTableSchema, db: Database,
                               deviceUser: String?, now: Date) throws -> IncomingResult {
        let names = values.keys.sorted()
        let table = SyncChangeTracker.quoted(schema.name)
        let key = SyncChangeTracker.quoted(schema.localIdColumn)
        let columnList = names.map(SyncChangeTracker.quoted).joined(separator: ", ")
        let marks = Array(repeating: "?", count: names.count).joined(separator: ", ")
        let arguments = StatementArguments(names.map { values[$0]! })
        let localId: Int64
        do {
            try db.execute(sql: "INSERT INTO \(table) (\(columnList)) VALUES (\(marks))", arguments: arguments)
            localId = schema.syncedColumns.contains(schema.localIdColumn)
                ? Int64.fromDatabaseValue(values[schema.localIdColumn] ?? .null) ?? db.lastInsertedRowID
                : db.lastInsertedRowID
        } catch let error as DatabaseError where [.SQLITE_CONSTRAINT_UNIQUE, .SQLITE_CONSTRAINT_PRIMARYKEY].contains(error.extendedResultCode) {
            // The row the constraint names: an upsert that changes nothing returns it.
            guard let same = try Int64.fetchOne(db, sql: """
                INSERT INTO \(table) (\(columnList)) VALUES (\(marks)) ON CONFLICT DO UPDATE SET \(key) = \(key) RETURNING \(key)
                """, arguments: arguments) else { throw error }
            return try SyncMerge.adopt(payload, into: same, values: values, schema: schema, db: db, deviceUser: deviceUser, now: now)
        }
        try SyncMerge.recordIdentity(payload, localId: localId, table: schema.name, db: db, now: now)
        return .applied
    }

    private static func stage(_ payload: SyncPayload, reason: String, db: Database, now: Date, fromStaging: Bool) throws -> IncomingResult {
        if !fromStaging {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let json = String(decoding: try encoder.encode(payload), as: UTF8.self)
            try db.execute(sql: """
                INSERT INTO syncStaging(tableName, uuid, payloadJSON, reason, importRunUuid, receivedAt) VALUES (?, ?, ?, ?, NULL, ?)
                ON CONFLICT(uuid) DO UPDATE SET tableName = excluded.tableName, payloadJSON = excluded.payloadJSON,
                    reason = excluded.reason, receivedAt = excluded.receivedAt
                """, arguments: [payload.recordType, payload.recordName, json, reason, now])
        } else {
            try db.execute(sql: "UPDATE syncStaging SET reason = ? WHERE uuid = ?", arguments: [reason, payload.recordName])
        }
        return .staged(reason)
    }

    // MARK: Deletes

    private static func applyDelete(uuid: String, recordType: String?, db: Database, deviceUser: String?, now: Date) throws -> IncomingResult {
        let staged = try SyncStagingRow.filter(Column("uuid") == uuid).fetchOne(db)
        try db.execute(sql: "DELETE FROM syncStaging WHERE uuid = ?", arguments: [uuid])
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
        try db.execute(sql: "DELETE FROM \(SyncChangeTracker.quoted(schema.name)) WHERE \(SyncChangeTracker.quoted(schema.localIdColumn)) = ?",
                       arguments: [record.localId])
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
