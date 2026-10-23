import Foundation
import GRDB

/// Field-level merge, last writer wins per field (sync spec §5.1).
///
/// - A field's time is its own clock, else the record's insert clock (`*`), else never (a row written before
///   tracking). The later time wins; equal times go to the greater writer, then the greater value, so every
///   device picks the same winner.
/// - A conflict is two different values for one field written on both sides since this device last synced
///   the record: the remote one wins over a local edit not yet sent, or a local edit wins over a remote edit
///   made since. The losing value goes to `syncConflict`. A remote value that simply replaces what this
///   device last synced isn't a conflict.
/// - When this device last synced a record is its `@synced` clock row, stamped when an incoming change is
///   applied and when the server acknowledges an upload (`SyncChangeTracker.acknowledge`).
public enum SyncMerge {
    /// The field clock of a record's insert: fields without their own clock date from it.
    public static let insertClock = "*"
    /// The pseudo-field holding when this device last synced the record. Never sent.
    public static let syncedClock = "@synced"

    // MARK: Clocks

    /// The record's field clocks as they travel (`@synced` is this device's own).
    static func clocks(table: String, localId: Int64, db: Database) throws -> [String: SyncClock] {
        var result: [String: SyncClock] = [:]
        for row in try Row.fetchAll(db.cachedStatement(sql: "SELECT field, modifiedAt, modifiedBy FROM syncFieldClock WHERE tableName = ? AND localId = ?"),
                                    arguments: [table, localId]) {
            let field: String = row["field"]
            guard field != syncedClock else { continue }
            result[field] = SyncClock(at: row["modifiedAt"], by: row["modifiedBy"])
        }
        return result
    }

    private static func setClock(_ clock: SyncClock, field: String, table: String, localId: Int64, db: Database) throws {
        try db.cachedStatement(sql: """
            INSERT INTO syncFieldClock(tableName, localId, field, modifiedAt, modifiedBy) VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(tableName, localId, field) DO UPDATE SET modifiedAt = excluded.modifiedAt, modifiedBy = excluded.modifiedBy
            """).execute(arguments: [table, localId, field, clock.at, clock.by])
    }

    /// Stamps the record as synced now (or at the latest remote time it just took, if that is later, so a
    /// fast remote clock doesn't make the fields it set look like local edits).
    private static func markSynced(table: String, localId: Int64, remote: [SyncClock], now: Date, db: Database) throws {
        let at = ([now] + remote.map(\.at)).max()!
        try setClock(SyncClock(at: at, by: nil), field: syncedClock, table: table, localId: localId, db: db)
    }

    // MARK: New records

    /// Writes the identity and clocks of a record that was just inserted from `payload`.
    static func recordIdentity(_ payload: SyncPayload, localId: Int64, table: String, db: Database, now: Date) throws {
        try db.execute(sql: """
            INSERT INTO syncRecord(tableName, localId, uuid, zone, systemFields, modifiedBy, modifiedAt) VALUES (?, ?, ?, ?, NULL, ?, ?)
            """, arguments: [table, localId, payload.recordName, payload.zone, payload.modifiedBy, payload.modifiedAt])
        try db.execute(sql: "DELETE FROM syncFieldClock WHERE tableName = ? AND localId = ?", arguments: [table, localId])
        for (field, clock) in payload.clocks {
            try setClock(clock, field: field, table: table, localId: localId, db: db)
        }
        try markSynced(table: table, localId: localId, remote: Array(payload.clocks.values), now: now, db: db)
    }

    // MARK: Merging into an existing record

    /// Merges `payload` (already translated to `values`) into this device's row of the same record.
    static func merge(_ payload: SyncPayload, into localId: Int64, values: [String: DatabaseValue], schema: SyncTableSchema,
                      db: Database, deviceUser: String?, now: Date) throws -> IncomingResult {
        let outcome = try mergeFields(payload, into: localId, values: values, schema: schema, db: db, deviceUser: deviceUser,
                                      uuid: payload.recordName, now: now)
        try db.execute(sql: """
            UPDATE syncRecord SET modifiedBy = ?, modifiedAt = ? WHERE tableName = ? AND localId = ?
                AND (modifiedAt IS NULL OR (? IS NOT NULL AND modifiedAt < ?))
            """, arguments: [payload.modifiedBy, payload.modifiedAt, schema.name, localId, payload.modifiedAt, payload.modifiedAt])
        if outcome.localWon, try !isPending(uuid: payload.recordName, db: db) {
            // This device holds a later value the sender hasn't seen: it goes out.
            try queue(uuid: payload.recordName, table: schema.name, localId: localId, kind: .update, db: db)
        }
        return outcome.conflicts.isEmpty ? .applied : .conflicted(outcome.conflicts)
    }

    private struct Outcome {
        var conflicts: [String] = []
        var localWon = false
    }

    private static func mergeFields(_ payload: SyncPayload, into localId: Int64, values: [String: DatabaseValue], schema: SyncTableSchema,
                                    db: Database, deviceUser: String?, uuid: String, now: Date) throws -> Outcome {
        let fields = values.keys.filter { $0 != schema.localIdColumn }.sorted()
        let table = SyncChangeTracker.quoted(schema.name)
        let key = SyncChangeTracker.quoted(schema.localIdColumn)
        guard let row = try Row.fetchOne(db, sql: "SELECT * FROM \(table) WHERE \(key) = ?", arguments: [localId]) else { return Outcome() }
        let local = try clocks(table: schema.name, localId: localId, db: db)
        let synced = try Date.fetchOne(db, sql: "SELECT modifiedAt FROM syncFieldClock WHERE tableName = ? AND localId = ? AND field = ?",
                                       arguments: [schema.name, localId, syncedClock])
        let pending = try isPending(uuid: uuid, db: db)
        func since(_ clock: SyncClock?) -> Bool {
            guard let clock else { return false }
            return synced.map { clock.at > $0 } ?? true
        }

        var outcome = Outcome()
        var writes: [(String, DatabaseValue)] = []
        var taken: [SyncClock] = []
        for field in fields {
            let mine: DatabaseValue = row[field]
            let theirs = values[field]!
            let localClock = local[field] ?? local[insertClock]
            let remoteClock = payload.clock(field)
            let remoteWins = wins(remoteClock, theirs, over: localClock, mine)
            if identical(mine, theirs) {
                if remoteWins, let remoteClock {
                    try setClock(remoteClock, field: field, table: schema.name, localId: localId, db: db)
                    taken.append(remoteClock)
                }
                continue
            }
            if remoteWins {
                writes.append((field, theirs))
                if let remoteClock {
                    try setClock(remoteClock, field: field, table: schema.name, localId: localId, db: db)
                    taken.append(remoteClock)
                }
                if pending && since(localClock) {
                    try logConflict(table: schema.name, uuid: uuid, field: field, losing: mine, column: field, schema: schema, db: db,
                                    winner: remoteClock?.by, loser: localClock?.by ?? deviceUser, now: now)
                    outcome.conflicts.append(field)
                }
            } else {
                outcome.localWon = true
                if since(remoteClock) {
                    try logConflict(table: schema.name, uuid: uuid, field: field, losing: theirs, column: field, schema: schema, db: db,
                                    winner: localClock?.by ?? deviceUser, loser: remoteClock?.by, now: now)
                    outcome.conflicts.append(field)
                }
            }
        }
        if !writes.isEmpty {
            let assignments = writes.map { "\(SyncChangeTracker.quoted($0.0)) = ?" }.joined(separator: ", ")
            try db.execute(sql: "UPDATE \(table) SET \(assignments) WHERE \(key) = ?",
                           arguments: StatementArguments(writes.map(\.1) + [localId.databaseValue]))
        }
        try markSynced(table: schema.name, localId: localId, remote: taken, now: now, db: db)
        return outcome
    }

    /// Whether the remote value (at `remote`) beats the local one (at `local`); nil is never.
    static func wins(_ remote: SyncClock?, _ remoteValue: DatabaseValue, over local: SyncClock?, _ localValue: DatabaseValue) -> Bool {
        let remoteAt = remote?.at ?? .distantPast, localAt = local?.at ?? .distantPast
        if remoteAt != localAt { return remoteAt > localAt }
        let remoteBy = remote?.by ?? "", localBy = local?.by ?? ""
        if remoteBy != localBy { return remoteBy > localBy }
        return SyncValue(remoteValue, declaredType: "").json > SyncValue(localValue, declaredType: "").json
    }

    /// Same storage class and bytes (GRDB's `==` treats 1 and 1.0 as equal).
    static func identical(_ a: DatabaseValue, _ b: DatabaseValue) -> Bool {
        switch (a.storage, b.storage) {
        case (.null, .null): return true
        case (.int64(let x), .int64(let y)): return x == y
        case (.double(let x), .double(let y)): return x.bitPattern == y.bitPattern
        case (.string(let x), .string(let y)): return Array(x.utf8) == Array(y.utf8)
        case (.blob(let x), .blob(let y)): return x == y
        default: return false
        }
    }

    /// The losing value, as it travels (references as UUIDs, so the log means the same on every device).
    private static func logConflict(table: String, uuid: String, field: String, losing: DatabaseValue, column: String,
                                    schema: SyncTableSchema, db: Database, winner: String?, loser: String?, now: Date) throws {
        let columns = try Columns(table: table, db: db)
        var value = SyncValue(losing, declaredType: columns.declared[column] ?? "")
        if let target = schema.foreignKeys[column] ?? SyncSchema.logicalReferences(of: table)[column],
           let localId = Int64.fromDatabaseValue(losing),
           let uuid = try SyncRecordStore.existingUUID(table: target, localId: localId, db: db) {
            value = .string(uuid)
        }
        var conflict = SyncConflictRow(tableName: table, uuid: uuid, field: field, losingValueJSON: value.json,
                                       winningWriter: winner, losingWriter: loser, recordedAt: now)
        try conflict.insert(db)
    }

    // MARK: The same record made on two devices

    /// An incoming record that a unique constraint says is this device's row `localId` (both devices made
    /// it). The fields merge as usual; the record keeps the smaller of the two UUIDs on every device, so
    /// they converge: when that is the incoming one, the local identity is retired (its delete is queued)
    /// and the row and every record pointing at it are queued to go out again under the new name.
    static func adopt(_ payload: SyncPayload, into localId: Int64, values: [String: DatabaseValue], schema: SyncTableSchema,
                      db: Database, deviceUser: String?, now: Date) throws -> IncomingResult {
        let incoming = payload.recordName
        guard let current = try SyncRecordStore.existingUUID(table: schema.name, localId: localId, db: db) else {
            // A row without an identity (written before tracking) simply takes the incoming one.
            try db.execute(sql: "INSERT INTO syncRecord(tableName, localId, uuid, zone) VALUES (?, ?, ?, ?)",
                           arguments: [schema.name, localId, incoming, payload.zone])
            return try merge(payload, into: localId, values: values, schema: schema, db: db, deviceUser: deviceUser, now: now)
        }
        let outcome = try mergeFields(payload, into: localId, values: values, schema: schema, db: db, deviceUser: deviceUser,
                                      uuid: current, now: now)
        if incoming < current {
            let zone = try String.fetchOne(db, sql: "SELECT zone FROM syncRecord WHERE uuid = ?", arguments: [current]) ?? SyncRecordStore.householdZone
            try db.execute(sql: "UPDATE syncRecord SET uuid = ?, systemFields = NULL WHERE uuid = ?", arguments: [incoming, current])
            try db.execute(sql: "UPDATE syncConflict SET uuid = ? WHERE uuid = ?", arguments: [incoming, current])
            try db.execute(sql: "DELETE FROM syncPending WHERE uuid = ?", arguments: [current])
            try db.execute(sql: """
                INSERT INTO syncTombstone(uuid, tableName, localId, zone, deletedBy, deletedAt) VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(uuid) DO UPDATE SET deletedAt = excluded.deletedAt
                """, arguments: [current, schema.name, localId, zone, deviceUser, now])
            try queue(uuid: current, table: schema.name, localId: localId, kind: .delete, db: db)
            for (table, id) in try referrers(table: schema.name, localId: localId, db: db) {
                if let uuid = try SyncRecordStore.existingUUID(table: table, localId: id, db: db) {
                    try queue(uuid: uuid, table: table, localId: id, kind: .update, db: db)
                }
            }
        }
        let survivor = min(incoming, current)
        if outcome.localWon || incoming < current {
            try queue(uuid: survivor, table: schema.name, localId: localId, kind: .update, db: db)
        }
        return outcome.conflicts.isEmpty ? .applied : .conflicted(outcome.conflicts)
    }

    /// Rows whose synced references (declared, logical, polymorphic, or ids inside JSON, by a text match
    /// that may over-include) name `table`'s row `localId`.
    static func referrers(table: String, localId: Int64, db: Database) throws -> [(String, Int64)] {
        var found: [(String, Int64)] = []
        for child in SyncSchema.tables where try db.tableExists(child.name) {
            let childTable = SyncChangeTracker.quoted(child.name)
            let key = SyncChangeTracker.quoted(child.localIdColumn)
            let references = child.foreignKeys.merging(SyncSchema.logicalReferences(of: child.name)) { first, _ in first }
            for (column, target) in references where target == table {
                for id in try Int64.fetchAll(db, sql: "SELECT \(key) FROM \(childTable) WHERE \(SyncChangeTracker.quoted(column)) = ?", arguments: [localId]) {
                    found.append((child.name, id))
                }
            }
            for poly in SyncSchema.polymorphicReferences(of: child.name) {
                for (type, target) in poly.targets where target == table {
                    for id in try Int64.fetchAll(db, sql: """
                        SELECT \(key) FROM \(childTable) WHERE \(SyncChangeTracker.quoted(poly.typeColumn)) = ? AND \(SyncChangeTracker.quoted(poly.idColumn)) = ?
                        """, arguments: [type, localId]) {
                        found.append((child.name, id))
                    }
                }
            }
            for json in SyncSchema.jsonReferences(of: child.name) {
                for id in try Int64.fetchAll(db, sql: "SELECT \(key) FROM \(childTable) WHERE \(SyncChangeTracker.quoted(json.column)) LIKE ?",
                                             arguments: ["%\(localId)%"]) {
                    found.append((child.name, id))
                }
            }
        }
        return found
    }

    // MARK: Bookkeeping

    static func isPending(uuid: String, db: Database) throws -> Bool {
        try Bool.fetchOne(db.cachedStatement(sql: "SELECT EXISTS (SELECT 1 FROM syncPending WHERE uuid = ? AND kind <> 'delete')"),
                          arguments: [uuid]) ?? false
    }

    /// Queues the record to be sent, as the triggers would: an insert not yet sent stays an insert.
    static func queue(uuid: String, table: String, localId: Int64, kind: PendingChange.Kind, db: Database) throws {
        try db.cachedStatement(sql: """
            INSERT INTO syncPending(uuid, tableName, localId, kind, revision)
            VALUES (?, ?, ?, ?, (SELECT COALESCE(MAX(revision), 0) + 1 FROM syncPending))
            ON CONFLICT(uuid) DO UPDATE SET
                kind = CASE WHEN excluded.kind = 'update' AND syncPending.kind = 'insert' THEN 'insert' ELSE excluded.kind END,
                revision = excluded.revision
            """).execute(arguments: [uuid, table, localId, kind.rawValue])
    }

    /// Removes a deleted record's identity, clocks and pending entry, keeping a tombstone so a late edit
    /// doesn't bring it back. Nothing is queued: the delete came from (or was made by) the other side.
    static func retire(uuid: String, table: String, localId: Int64, zone: String, deletedBy: String?, now: Date, db: Database) throws {
        try db.execute(sql: """
            INSERT INTO syncTombstone(uuid, tableName, localId, zone, deletedBy, deletedAt) VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(uuid) DO UPDATE SET deletedAt = excluded.deletedAt
            """, arguments: [uuid, table, localId, zone, deletedBy, now])
        try db.execute(sql: "DELETE FROM syncPending WHERE uuid = ?", arguments: [uuid])
        try db.execute(sql: "DELETE FROM syncFieldClock WHERE tableName = ? AND localId = ?", arguments: [table, localId])
        try db.execute(sql: "DELETE FROM syncRecord WHERE uuid = ?", arguments: [uuid])
    }
}
