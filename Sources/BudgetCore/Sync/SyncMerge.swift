import Foundation
import GRDB
import os

/// Field-level merge, last writer wins per field (sync spec §5.1).
///
/// - A field's time is its own clock, else the record's insert clock (`*`), else never (a row written before
///   tracking). The later time wins; equal times go to the greater writer, then the greater value, so every
///   device picks the same winner.
/// - Each record keeps a per-field **base**: the clocks the server held when this device last agreed with it
///   (taken from an incoming record, or the record's own clocks when the server acknowledged an upload). A
///   side changed a field when its clock differs from the base. Only one side changed: that side's value is
///   taken. Both changed and the values differ: a conflict, the winner by the rule above, and the loser in
///   `syncConflict`.
/// - Unique keys (`SyncSchema.uniqueKeys`): an identity key merges the two records under the smaller UUID
///   (the other is redirected, never deleted); any other collision keeps both records and logs what it held.
public enum SyncMerge {
    /// The field clock of a record's insert: fields without their own clock date from it.
    public static let insertClock = "*"
    /// Prefix of the base clock rows in `syncFieldClock` (`@base:note`, `@base:*`). Never sent.
    public static let basePrefix = "@base:"
    private static let log = Logger(subsystem: "com.personal.budget", category: "Sync")

    // MARK: Clocks and bases

    /// The record's field clocks as they travel (rows starting `@` are this device's own bookkeeping).
    static func clocks(table: String, localId: Int64, db: Database) throws -> [String: SyncClock] {
        try clockRows(table: table, localId: localId, db: db).filter { !$0.key.hasPrefix("@") }
    }

    /// The record's base clocks, by field.
    static func bases(table: String, localId: Int64, db: Database) throws -> [String: SyncClock] {
        var result: [String: SyncClock] = [:]
        for (field, clock) in try clockRows(table: table, localId: localId, db: db) where field.hasPrefix(basePrefix) {
            result[String(field.dropFirst(basePrefix.count))] = clock
        }
        return result
    }

    private static func clockRows(table: String, localId: Int64, db: Database) throws -> [String: SyncClock] {
        var result: [String: SyncClock] = [:]
        for row in try Row.fetchAll(db.cachedStatement(sql: "SELECT field, modifiedAt, modifiedBy FROM syncFieldClock WHERE tableName = ? AND localId = ?"),
                                    arguments: [table, localId]) {
            result[row["field"]] = SyncClock(at: row["modifiedAt"], by: row["modifiedBy"])
        }
        return result
    }

    static func setClock(_ clock: SyncClock, field: String, table: String, localId: Int64, db: Database) throws {
        try db.cachedStatement(sql: """
            INSERT INTO syncFieldClock(tableName, localId, field, modifiedAt, modifiedBy) VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(tableName, localId, field) DO UPDATE SET modifiedAt = excluded.modifiedAt, modifiedBy = excluded.modifiedBy
            """).execute(arguments: [table, localId, field, clock.at, clock.by])
    }

    /// Replaces the record's base with `clocks` (the server's).
    static func setBase(_ clocks: [String: SyncClock], table: String, localId: Int64, db: Database) throws {
        try db.execute(sql: "DELETE FROM syncFieldClock WHERE tableName = ? AND localId = ? AND substr(field, 1, ?) = ?",
                       arguments: [table, localId, basePrefix.count, basePrefix])
        for (field, clock) in clocks { try setClock(clock, field: basePrefix + field, table: table, localId: localId, db: db) }
    }

    /// The record's own clocks become its base (the server took them).
    static func setBase(toCurrentClocksOf table: String, localId: Int64, db: Database) throws {
        try setBase(clocks(table: table, localId: localId, db: db), table: table, localId: localId, db: db)
    }

    /// Two clocks are the same when their stored text and writer are (nil is never).
    static func same(_ a: SyncClock?, _ b: SyncClock?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case let (a?, b?): return a.by == b.by && a.at.databaseValue == b.at.databaseValue
        default: return false
        }
    }

    /// Step 7a: `payload` with no clock later than `serverTime`, when the server saved it. A version another iCloud user
    /// saved can't date a change after it reached the server (a future-dated clock would win every merge).
    static func clamped(_ payload: SyncPayload, to serverTime: Date) -> SyncPayload {
        var result = payload
        for (field, clock) in payload.clocks where clock.at > serverTime {
            result.clocks[field] = SyncClock(at: serverTime, by: clock.by)
        }
        if let at = payload.modifiedAt, at > serverTime { result.modifiedAt = serverTime }
        return result
    }

    // MARK: New records

    /// Writes the identity, clocks and base of a record that was just inserted from `payload`.
    static func recordIdentity(_ payload: SyncPayload, localId: Int64, table: String, db: Database) throws {
        try db.execute(sql: """
            INSERT INTO syncRecord(tableName, localId, uuid, zone, systemFields, modifiedBy, modifiedAt) VALUES (?, ?, ?, ?, NULL, ?, ?)
            """, arguments: [table, localId, payload.recordName, payload.zone, payload.modifiedBy, payload.modifiedAt])
        try db.execute(sql: "DELETE FROM syncFieldClock WHERE tableName = ? AND localId = ?", arguments: [table, localId])
        for (field, clock) in payload.clocks { try setClock(clock, field: field, table: table, localId: localId, db: db) }
        try setBase(payload.clocks, table: table, localId: localId, db: db)
    }

    // MARK: Merging into an existing record

    struct Outcome {
        var conflicts: [String] = []
        /// This device kept a value the server doesn't have: the record must go out.
        var localWon = false
        /// The remote clocks of the fields taken from the payload.
        var taken: [String: SyncClock] = [:]
    }

    /// Merges `payload` (already translated to `values`) into this device's row of the same record.
    /// `held` are fields the caller couldn't take (a reference to a parent deleted here): they keep the local
    /// value and are logged, with the remote value as it travelled.
    /// `adopted`: the payload is another record merged into this one (a save of a redirected UUID); its
    /// clocks aren't this record's server state, so every differing field is decided by `wins` and logged,
    /// and the base stays.
    static func merge(_ payload: SyncPayload, into localId: Int64, values: [String: DatabaseValue], held: [String: SyncValue] = [:],
                      schema: SyncTableSchema, db: Database, deviceUser: String?, adopted: Bool = false, now: Date) throws -> IncomingResult {
        let outcome = try mergeFields(payload, into: localId, values: values, held: held, schema: schema, db: db, deviceUser: deviceUser,
                                      uuid: payload.recordName, adopted: adopted, now: now)
        if !adopted { try setBase(payload.clocks, table: schema.name, localId: localId, db: db) }
        try db.execute(sql: """
            UPDATE syncRecord SET modifiedBy = ?, modifiedAt = ? WHERE tableName = ? AND localId = ?
                AND (modifiedAt IS NULL OR (? IS NOT NULL AND modifiedAt < ?))
            """, arguments: [payload.modifiedBy, payload.modifiedAt, schema.name, localId, payload.modifiedAt, payload.modifiedAt])
        if outcome.localWon, try !isPending(uuid: payload.recordName, db: db) {
            try queue(uuid: payload.recordName, table: schema.name, localId: localId, kind: .update, db: db)
        }
        return outcome.conflicts.isEmpty ? .applied : .conflicted(outcome.conflicts)
    }

    /// The field merge. `adopted`: the row is another record that a unique key says is the same thing, so
    /// the base means nothing and every differing field counts as changed on both sides.
    static func mergeFields(_ payload: SyncPayload, into localId: Int64, values: [String: DatabaseValue], held: [String: SyncValue],
                            schema: SyncTableSchema, db: Database, deviceUser: String?, uuid: String, adopted: Bool,
                            now: Date) throws -> Outcome {
        let fields = values.keys.filter { $0 != schema.localIdColumn }.sorted()
        guard let row = try fetchRow(schema, localId, db: db) else { return Outcome() }
        let local = try clocks(table: schema.name, localId: localId, db: db)
        let base = try bases(table: schema.name, localId: localId, db: db)

        var outcome = Outcome()
        var writes: [String: DatabaseValue] = [:]
        var taken: [String: SyncClock?] = [:]
        var losers: [(field: String, value: DatabaseValue, winner: String?, loser: String?)] = []
        for field in fields {
            let mine: DatabaseValue = row[field]
            let theirs = values[field]!
            let localClock = local[field] ?? local[insertClock]
            let remoteClock = payload.clock(field)
            let baseClock = base[field] ?? base[insertClock]
            let localChanged = adopted || !same(localClock, baseClock)
            let remoteWins = wins(remoteClock, theirs, over: localClock, mine)
            if identical(mine, theirs) {
                if remoteWins { taken[field] = remoteClock }
                continue
            }
            let takeRemote = takesRemote(local: localClock, remote: remoteClock, base: baseClock, remoteWins: remoteWins, adopted: adopted)
            if localChanged, adopted || !same(remoteClock, baseClock) {
                losers.append(takeRemote ? (field, mine, remoteClock?.by, localClock?.by ?? deviceUser)
                                         : (field, theirs, localClock?.by ?? deviceUser, remoteClock?.by))
            }
            if takeRemote {
                writes[field] = theirs
                taken[field] = remoteClock
            } else {
                outcome.localWon = true
            }
        }
        // A unique key the new values would break holds those fields at their local value (or, for an
        // exclusive flag the incoming record wins, clears it on the other row).
        let blocked = try update(schema, localId, writes: &writes, payload: payload, db: db, deviceUser: deviceUser, now: now)
        for field in blocked {
            // Held at the local value: only the remote value is lost.
            taken[field] = nil
            losers.removeAll { $0.field == field }
            losers.append((field, values[field]!, local[field]?.by ?? local[insertClock]?.by ?? deviceUser, payload.clock(field)?.by))
            outcome.localWon = true
        }
        for (field, clock) in taken {
            if let clock { try setClock(clock, field: field, table: schema.name, localId: localId, db: db) }
        }
        for loser in losers {
            try logConflict(table: schema.name, uuid: uuid, field: loser.field, losing: travelled(loser.value, column: loser.field, schema: schema, db: db),
                            winner: loser.winner, loser: loser.loser, db: db, now: now)
            outcome.conflicts.append(loser.field)
        }
        for (field, value) in held.sorted(by: { $0.key < $1.key }) {
            try logConflict(table: schema.name, uuid: uuid, field: field, losing: value, winner: deviceUser, loser: payload.clock(field)?.by, db: db, now: now)
            outcome.conflicts.append(field)
            outcome.localWon = true
        }
        outcome.conflicts = Array(Set(outcome.conflicts)).sorted()
        outcome.taken = taken.compactMapValues { $0 }
        return outcome
    }

    /// Whether the merge takes the incoming value of a field whose two values differ: the side that changed it
    /// since the base wins; both changed (or neither): the later clock (`wins`).
    static func takesRemote(local: SyncClock?, remote: SyncClock?, base: SyncClock?, remoteWins: Bool, adopted: Bool = false) -> Bool {
        let localChanged = adopted || !same(local, base)
        let remoteChanged = adopted || !same(remote, base)
        switch (localChanged, remoteChanged) {
        case (true, true): return remoteWins
        case (false, true): return true
        case (true, false): return false
        case (false, false): return remoteWins
        }
    }

    /// The fields of `payload` whose value differs from this device's (`local`, as it travels) and that a merge
    /// into row `localId` would take from the payload (step 6 Task 9 judges exactly those).
    static func remoteTakes(_ payload: SyncPayload, local: [String: SyncValue], table: String, localId: Int64,
                            db: Database) throws -> [String] {
        let clocks = try clocks(table: table, localId: localId, db: db)
        let base = try bases(table: table, localId: localId, db: db)
        var result: [String] = []
        for (field, theirs) in payload.fields {
            let mine = local[field] ?? .null
            guard mine != theirs else { continue }
            let localClock = clocks[field] ?? clocks[insertClock]
            let remoteClock = payload.clock(field)
            let remoteWins = wins(remoteClock, theirs.databaseValue, over: localClock, mine.databaseValue)
            if takesRemote(local: localClock, remote: remoteClock, base: base[field] ?? base[insertClock], remoteWins: remoteWins) {
                result.append(field)
            }
        }
        return result.sorted()
    }

    /// Writes `writes` to the row, dropping the fields a unique key refuses (returned). An exclusive flag the
    /// incoming record sets and wins is cleared on the row holding it instead.
    private static func update(_ schema: SyncTableSchema, _ localId: Int64, writes: inout [String: DatabaseValue], payload: SyncPayload,
                               db: Database, deviceUser: String?, now: Date) throws -> [String] {
        var blocked: [String] = []
        for _ in 0..<32 {
            guard !writes.isEmpty else { break }
            let names = writes.keys.sorted()
            let assignments = names.map { "\(SyncChangeTracker.quoted($0)) = ?" }.joined(separator: ", ")
            do {
                try db.execute(sql: "UPDATE \(SyncChangeTracker.quoted(schema.name)) SET \(assignments) WHERE \(SyncChangeTracker.quoted(schema.localIdColumn)) = ?",
                               arguments: StatementArguments(names.map { writes[$0]! } + [localId.databaseValue]))
                return blocked
            } catch let error as DatabaseError where SyncUniqueIndex.isUniqueViolation(error) {
                guard let index = try SyncUniqueIndex.violated(by: error, table: schema.name, db: db) else { throw error }
                let involved = index.involved(in: Set(names))
                if case .exclusiveFlag(let flag)? = index.key?.resolution, let value = writes[flag], Bool.fromDatabaseValue(value) == true,
                   var merged = try fetchValues(schema, localId, db: db) {
                    merged.merge(writes) { _, new in new }
                    if let other = try index.conflictingRow(values: merged, db: db), other != localId,
                       try flagWins(payload.clock(flag), payload.recordName, over: schema, other, flag, db: db) {
                        try localSet(schema, other, flag, false.databaseValue, db: db, deviceUser: deviceUser, now: now)
                        continue
                    }
                }
                guard !involved.isEmpty else { throw error }
                for field in involved {
                    writes[field] = nil
                    blocked.append(field)
                }
            }
        }
        return blocked
    }

    /// Whether `remote` (on record `name`) beats the other row's clock for `flag`; ties go to the smaller UUID.
    static func flagWins(_ remote: SyncClock?, _ name: String, over schema: SyncTableSchema, _ other: Int64, _ flag: String, db: Database) throws -> Bool {
        let theirs = try clocks(table: schema.name, localId: other, db: db)
        let otherClock = theirs[flag] ?? theirs[insertClock]
        let remoteAt = remote?.at ?? .distantPast, otherAt = otherClock?.at ?? .distantPast
        if remoteAt.databaseValue != otherAt.databaseValue { return remoteAt > otherAt }
        if (remote?.by ?? "") != (otherClock?.by ?? "") { return (remote?.by ?? "") > (otherClock?.by ?? "") }
        return name < (try SyncRecordStore.existingUUID(table: schema.name, localId: other, db: db) ?? "")
    }

    /// Whether the remote value (at `remote`) beats the local one (at `local`); nil is never.
    static func wins(_ remote: SyncClock?, _ remoteValue: DatabaseValue, over local: SyncClock?, _ localValue: DatabaseValue) -> Bool {
        let remoteAt = remote?.at ?? .distantPast, localAt = local?.at ?? .distantPast
        if remoteAt.databaseValue != localAt.databaseValue { return remoteAt > localAt }
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

    // MARK: Writes this device makes to resolve a collision

    /// Sets a column of another row, as a local edit: its clock is now, it is queued, and the value it
    /// had is logged.
    static func localSet(_ schema: SyncTableSchema, _ localId: Int64, _ column: String, _ value: DatabaseValue, db: Database,
                         deviceUser: String?, now: Date) throws {
        guard let row = try fetchRow(schema, localId, db: db) else { return }
        let old: DatabaseValue = row[column]
        try db.execute(sql: "UPDATE \(SyncChangeTracker.quoted(schema.name)) SET \(SyncChangeTracker.quoted(column)) = ? WHERE \(SyncChangeTracker.quoted(schema.localIdColumn)) = ?",
                       arguments: [value, localId])
        try recordLocalEdit(schema, localId, column, old: old, db: db, deviceUser: deviceUser, now: now)
    }

    /// Renames another row's `column` to the first free "<text> (n)", as a local edit.
    static func localSuffix(_ schema: SyncTableSchema, _ localId: Int64, _ column: String, db: Database, deviceUser: String?, now: Date) throws {
        guard let row = try fetchRow(schema, localId, db: db), let text = String.fromDatabaseValue(row[column]) else { return }
        for n in 2..<1_000 {
            do {
                try db.execute(sql: "UPDATE \(SyncChangeTracker.quoted(schema.name)) SET \(SyncChangeTracker.quoted(column)) = ? WHERE \(SyncChangeTracker.quoted(schema.localIdColumn)) = ?",
                               arguments: [suffixed(text, n), localId])
                try recordLocalEdit(schema, localId, column, old: text.databaseValue, db: db, deviceUser: deviceUser, now: now)
                return
            } catch let error as DatabaseError where SyncUniqueIndex.isUniqueViolation(error) {
                continue
            }
        }
    }

    static func suffixed(_ text: String, _ n: Int) -> String { "\(text) (\(n))" }

    /// A change this device made while applying: dated now, queued, and the value it replaced logged.
    static func recordLocalEdit(_ schema: SyncTableSchema, _ localId: Int64, _ column: String, old: DatabaseValue, db: Database,
                                deviceUser: String?, now: Date) throws {
        try setClock(SyncClock(at: now, by: deviceUser), field: column, table: schema.name, localId: localId, db: db)
        let uuid = try SyncRecordStore.existingUUID(table: schema.name, localId: localId, db: db)
            ?? SyncRecordStore.uuid(for: schema.name, localId: localId, db: db)
        try queue(uuid: uuid, table: schema.name, localId: localId, kind: .update, db: db)
        try logConflict(table: schema.name, uuid: uuid, field: column, losing: travelled(old, column: column, schema: schema, db: db),
                        winner: nil, loser: nil, db: db, now: now)
    }

    // MARK: The conflict log

    /// A value as it travels (references as UUIDs, so the log means the same on every device).
    static func travelled(_ value: DatabaseValue, column: String, schema: SyncTableSchema, db: Database) throws -> SyncValue {
        let columns = try Columns(table: schema.name, db: db)
        if let target = schema.foreignKeys[column] ?? SyncSchema.logicalReferences(of: schema.name)[column],
           let localId = Int64.fromDatabaseValue(value),
           let uuid = try SyncRecordStore.existingUUID(table: target, localId: localId, db: db) {
            return .string(uuid)
        }
        return SyncValue(value, declaredType: columns.declared[column] ?? "")
    }

    static func logConflict(table: String, uuid: String, field: String, losing: SyncValue, winner: String?, loser: String?,
                            db: Database, now: Date) throws {
        // One entry per lost value: the same record, field and value arriving again (or from a second
        // device) isn't logged twice.
        let json = losing.json
        if try Bool.fetchOne(db.cachedStatement(sql: """
            SELECT EXISTS (SELECT 1 FROM syncConflict WHERE uuid = ? AND tableName = ? AND field = ? AND losingValueJSON = ?)
            """), arguments: [uuid, table, field, json]) ?? false { return }
        var conflict = SyncConflictRow(tableName: table, uuid: uuid, field: field, losingValueJSON: losing.json,
                                       winningWriter: winner, losingWriter: loser, recordedAt: now)
        try conflict.insert(db)
    }

    // MARK: The same record made on two devices

    /// An incoming record that an identity key says is this device's row `localId` (both devices made it).
    /// Every differing field merges as a conflict. The record keeps the smaller UUID on every device; the
    /// other becomes a redirect (`mergedInto`), sent when it was this device's, so receivers re-key their
    /// row instead of deleting it, and references to it still resolve.
    static func adopt(_ payload: SyncPayload, into localId: Int64, values: [String: DatabaseValue], schema: SyncTableSchema,
                      db: Database, deviceUser: String?, now: Date) throws -> IncomingResult {
        let incoming = payload.recordName
        guard let current = try SyncRecordStore.existingUUID(table: schema.name, localId: localId, db: db), current != incoming else {
            // A row without an identity (written before tracking) simply takes the incoming one.
            if try SyncRecordStore.existingUUID(table: schema.name, localId: localId, db: db) == nil {
                try db.execute(sql: "INSERT INTO syncRecord(tableName, localId, uuid, zone) VALUES (?, ?, ?, ?)",
                               arguments: [schema.name, localId, incoming, payload.zone])
            }
            let outcome = try mergeFields(payload, into: localId, values: values, held: [:], schema: schema, db: db, deviceUser: deviceUser,
                                          uuid: incoming, adopted: true, now: now)
            try setBase(payload.clocks, table: schema.name, localId: localId, db: db)
            if outcome.localWon { try queue(uuid: incoming, table: schema.name, localId: localId, kind: .update, db: db) }
            return outcome.conflicts.isEmpty ? .applied : .conflicted(outcome.conflicts)
        }
        let outcome = try mergeFields(payload, into: localId, values: values, held: [:], schema: schema, db: db, deviceUser: deviceUser,
                                      uuid: current, adopted: true, now: now)
        let zone = try String.fetchOne(db, sql: "SELECT zone FROM syncRecord WHERE uuid = ?", arguments: [current]) ?? SyncRecordStore.householdZone
        if incoming < current {
            try rekey(from: current, to: incoming, db: db)
            try redirect(current, to: incoming, table: schema.name, localId: localId, zone: zone, by: deviceUser, now: now, db: db)
            // This device's name for it goes out as a redirect.
            try queue(uuid: current, table: schema.name, localId: localId, kind: .update, db: db)
            try setBase(payload.clocks, table: schema.name, localId: localId, db: db)
            for (table, id) in try referrers(table: schema.name, localId: localId, db: db) {
                if let uuid = try SyncRecordStore.existingUUID(table: table, localId: id, db: db) {
                    try queue(uuid: uuid, table: table, localId: id, kind: .update, db: db)
                }
            }
            try queue(uuid: incoming, table: schema.name, localId: localId, kind: .update, db: db)
        } else {
            // The incoming name is the redirected one: remembered (the device that made it redirects it).
            try redirect(incoming, to: current, table: schema.name, localId: 0, zone: zone, by: deviceUser, now: now, db: db)
            try queue(uuid: current, table: schema.name, localId: localId, kind: .update, db: db)
        }
        return outcome.conflicts.isEmpty ? .applied : .conflicted(outcome.conflicts)
    }

    /// Gives the row named `old` the name `new`, moving its log entries and its pending change.
    static func rekey(from old: String, to new: String, db: Database) throws {
        guard let record = try SyncRecordRow.fetchOne(db, sql: "SELECT * FROM syncRecord WHERE uuid = ?", arguments: [old]) else { return }
        try db.execute(sql: "UPDATE syncRecord SET uuid = ?, systemFields = NULL, changeTag = NULL WHERE uuid = ?", arguments: [new, old])
        try db.execute(sql: "UPDATE syncConflict SET uuid = ? WHERE uuid = ?", arguments: [new, old])
        if try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM syncPending WHERE uuid = ? AND kind <> 'delete')", arguments: [old]) ?? false {
            try queue(uuid: new, table: record.tableName, localId: record.localId, kind: .update, db: db)
        }
        try db.execute(sql: "DELETE FROM syncPending WHERE uuid = ?", arguments: [old])
    }

    /// Remembers that `old` is `new` now: a tombstone with `mergedInto`. `systemFields`: the server version of
    /// `old` this device last saw, when it had one, so the redirect can be saved over it.
    static func redirect(_ old: String, to new: String, table: String, localId: Int64, zone: String, by: String?, now: Date,
                         systemFields: Data? = nil, db: Database) throws {
        try db.execute(sql: """
            INSERT INTO syncTombstone(uuid, tableName, localId, zone, deletedBy, deletedAt, mergedInto, systemFields) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(uuid) DO UPDATE SET mergedInto = excluded.mergedInto, deletedAt = excluded.deletedAt,
                systemFields = COALESCE(excluded.systemFields, syncTombstone.systemFields)
            """, arguments: [old, table, localId, zone, by, now, new, systemFields])
    }

    /// Rows whose synced references (declared, logical, polymorphic, or ids inside JSON) name `table`'s row
    /// `localId`.
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
                guard case .rules(let rules) = json.content else { continue }
                // The text filter only narrows; the parse decides.
                for row in try Row.fetchAll(db, sql: "SELECT \(key) AS id, \(SyncChangeTracker.quoted(json.column)) AS text FROM \(childTable) WHERE instr(\(SyncChangeTracker.quoted(json.column)), ?) > 0",
                                            arguments: [String(localId)]) {
                    guard let text: String = row["text"], let root = SyncJSONNode.parse(text),
                          root.ids(of: table, rules: rules, text: text).contains(localId) else { continue }
                    found.append((child.name, row["id"]))
                }
            }
        }
        return found
    }

    // MARK: Bookkeeping

    static func fetchRow(_ schema: SyncTableSchema, _ localId: Int64, db: Database) throws -> Row? {
        try Row.fetchOne(db, sql: "SELECT * FROM \(SyncChangeTracker.quoted(schema.name)) WHERE \(SyncChangeTracker.quoted(schema.localIdColumn)) = ?",
                         arguments: [localId])
    }

    /// The row's columns except its local id, as values.
    static func fetchValues(_ schema: SyncTableSchema, _ localId: Int64, db: Database) throws -> [String: DatabaseValue]? {
        guard let row = try fetchRow(schema, localId, db: db) else { return nil }
        var values: [String: DatabaseValue] = [:]
        for column in row.columnNames where column != schema.localIdColumn { values[column] = row[column] }
        return values
    }

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

// MARK: Unique indexes

/// One unique index (or the primary key) of a synced table, with its declared resolution.
struct SyncUniqueIndex {
    let table: String
    let name: String?
    /// As `PRAGMA index_xinfo` lists them, `<expr>` for an expression.
    let columns: [String]
    /// The `ON CONFLICT(…)` target that names exactly this index (with its partial `WHERE`).
    let target: String
    /// Columns of the table the index reads (an expression's too).
    let reads: Set<String>

    var key: SyncUniqueKey? { SyncSchema.uniqueKey(table: table, columns: columns) }

    static func isUniqueViolation(_ error: DatabaseError) -> Bool {
        [.SQLITE_CONSTRAINT_UNIQUE, .SQLITE_CONSTRAINT_PRIMARYKEY].contains(error.extendedResultCode)
    }

    /// Every unique index of `table`, and its primary key when that is a synced column.
    static func all(table: String, db: Database) throws -> [SyncUniqueIndex] {
        var result: [SyncUniqueIndex] = []
        let tableColumns = try db.columns(in: table).map(\.name)
        for row in try Row.fetchAll(db, sql: "PRAGMA index_list(\(SyncChangeTracker.quoted(table)))") where (row["unique"] as Int) == 1 {
            let name: String = row["name"]
            guard (row["origin"] as String) != "pk" else { continue }
            let columns = try Row.fetchAll(db, sql: "PRAGMA index_xinfo(\(SyncChangeTracker.quoted(name)))")
                .filter { ($0["key"] as Int) == 1 }.map { ($0["name"] as String?) ?? "<expr>" }
            let sql = try String.fetchOne(db, sql: "SELECT sql FROM sqlite_master WHERE type = 'index' AND name = ?", arguments: [name])
            var target = "(" + columns.map(SyncChangeTracker.quoted).joined(separator: ", ") + ")"
            var reads = Set(columns.filter { $0 != "<expr>" })
            if let sql, let definition = indexDefinition(sql) {
                target = definition.list + (definition.whereClause.map { " WHERE " + $0 } ?? "")
                for column in tableColumns where sql.contains(column) { reads.insert(column) }
            }
            result.append(SyncUniqueIndex(table: table, name: name, columns: columns, target: target, reads: reads))
        }
        if let schema = SyncSchema.table(table), schema.syncedColumns.contains(schema.localIdColumn) {
            result.append(SyncUniqueIndex(table: table, name: nil, columns: [schema.localIdColumn],
                                          target: "(" + SyncChangeTracker.quoted(schema.localIdColumn) + ")", reads: [schema.localIdColumn]))
        }
        return result
    }

    /// `(list)` and the partial `WHERE` of a `CREATE UNIQUE INDEX … ON t(list) [WHERE …]`.
    private static func indexDefinition(_ sql: String) -> (list: String, whereClause: String?)? {
        guard let on = sql.range(of: " ON ", options: .caseInsensitive), let open = sql[on.upperBound...].firstIndex(of: "(") else { return nil }
        var depth = 0
        var index = open
        while index < sql.endIndex {
            if sql[index] == "(" { depth += 1 }
            if sql[index] == ")" {
                depth -= 1
                if depth == 0 { break }
            }
            index = sql.index(after: index)
        }
        guard index < sql.endIndex else { return nil }
        let list = String(sql[open...index])
        let rest = sql[sql.index(after: index)...].trimmingCharacters(in: .whitespaces)
        let whereClause = rest.uppercased().hasPrefix("WHERE ") ? String(rest.dropFirst(6)) : nil
        return (list, whereClause)
    }

    /// The index a UNIQUE failure names: `index 'x'`, or `t.a, t.b`.
    static func violated(by error: DatabaseError, table: String, db: Database) throws -> SyncUniqueIndex? {
        let message = error.message ?? ""
        let indexes = try all(table: table, db: db)
        if let start = message.range(of: "index '"), let end = message[start.upperBound...].firstIndex(of: "'") {
            let name = String(message[start.upperBound..<end])
            return indexes.first { $0.name == name }
        }
        guard let start = message.range(of: "failed: ") else { return nil }
        let columns = message[start.upperBound...].split(separator: ",").map {
            String($0.trimmingCharacters(in: .whitespaces).split(separator: ".").last ?? "")
        }
        return indexes.first { $0.columns == columns }
    }

    /// The written columns this index reads.
    func involved(in written: Set<String>) -> [String] { reads.intersection(written).sorted() }

    /// The row holding `values`' key in this index, found by an upsert that changes nothing (rolled back).
    func conflictingRow(values: [String: DatabaseValue], db: Database) throws -> Int64? {
        guard let schema = SyncSchema.table(table) else { return nil }
        let names = values.keys.filter { $0 != schema.localIdColumn || name == nil }.sorted()
        let key = SyncChangeTracker.quoted(schema.localIdColumn)
        let tableName = SyncChangeTracker.quoted(table)
        try db.execute(sql: "SAVEPOINT syncConflictingRow")
        let id = try? Int64.fetchOne(db, sql: """
            INSERT INTO \(tableName) (\(names.map(SyncChangeTracker.quoted).joined(separator: ", ")))
            VALUES (\(Array(repeating: "?", count: names.count).joined(separator: ", ")))
            ON CONFLICT\(target) DO UPDATE SET \(key) = \(key) RETURNING \(key)
            """, arguments: StatementArguments(names.map { values[$0]! }))
        try db.execute(sql: "ROLLBACK TO syncConflictingRow")
        try db.execute(sql: "RELEASE syncConflictingRow")
        // After the rollback only a row that was already there exists.
        guard let id, try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM \(tableName) WHERE \(key) = ?)", arguments: [id]) == true
        else { return nil }
        return id
    }
}
