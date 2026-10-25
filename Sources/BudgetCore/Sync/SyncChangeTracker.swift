import CryptoKit
import Foundation
import GRDB
import os

/// One synced record waiting to be sent: its row, its UUID (which still names it after a delete, when
/// the local id no longer does) and what happened to it since the last upload.
public struct PendingChange: Codable, Equatable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case insert, update, delete
    }

    public var table: String
    public var localId: Int64
    public var uuid: String
    public var kind: Kind
    /// Higher than the record's previous revision every time it changes; `acknowledge` drops an entry
    /// only while its revision is the one that was sent, so an edit made during an upload stays pending.
    public var revision: Int64

    public init(table: String, localId: Int64, uuid: String, kind: Kind, revision: Int64 = 0) {
        self.table = table
        self.localId = localId
        self.uuid = uuid
        self.kind = kind
        self.revision = revision
    }
}

public enum SyncChangeTrackerError: Error, Equatable {
    /// `applyingIncoming` must run inside the transaction that applies the records.
    case notInTransaction
}

/// What made a write, as stored in `syncWriter.origin` and `syncRecord.origin` (step 6 task 2 names the values).
public typealias WriteOriginRaw = String

/// Change tracking by SQLite triggers generated from `SyncSchema` (ruling R5). Each insert, update and
/// delete of a synced table writes, in the same statement and so the same transaction:
/// - the row's identity in `syncRecord` (created on first sight), or its tombstone on delete;
/// - its `syncPending` entry;
/// - per-field clocks in `syncFieldClock`: `*` at insert, then each synced column an update changes.
///
/// So a change and its bookkeeping commit together or not at all, rolled-back savepoints and
/// transactions leave nothing, and every connection is covered, the one-off tools included, because
/// the triggers live in the database file. Local-only tables have no triggers.
///
/// Semantics:
/// - An update to a record not yet sent stays an insert; a delete replaces whatever was queued.
/// - An update that changes no synced column (only a local-only one, or nothing) isn't tracked.
/// - A delete retires the identity, so a row that later reuses the local id is a new record.
/// - A synced table's local id can't change: the `_key` trigger refuses it (delete and insert instead).
/// - `REPLACE` that removes a row with another rowid: SQLite fires delete triggers for it only with
///   `recursive_triggers` on, which `DatabaseManager` and the tools (`ToolDatabase`) set. For other connections,
///   `refreshSyncTriggers` sweeps identities whose row is gone into tombstones on every open.
/// - The writer (`modifiedBy`) is `syncWriter`'s user, which the app sets while someone is signed in.
///   A tool run while it is set is stamped with that user; otherwise tools leave it NULL. The write's
///   origin (`syncRecord.origin`) is copied from `syncWriter.origin` the same way.
public enum SyncChangeTracker {
    static let triggerPrefix = "syncTrack_"

    // MARK: Pending

    /// What is waiting to be sent, oldest first: one entry per record.
    public static func pending(db: Database) throws -> [PendingChange] {
        try Row.fetchAll(db, sql: "SELECT uuid, tableName, localId, kind, revision FROM syncPending ORDER BY rowid").map { row in
            PendingChange(table: row["tableName"], localId: row["localId"], uuid: row["uuid"],
                          kind: PendingChange.Kind(rawValue: row["kind"])!, revision: row["revision"])
        }
    }

    /// Removes the entries the server has taken, unless they changed again since they were read. A taken
    /// insert or update makes the record's clocks its per-field base (`SyncMerge.basePrefix`): what the
    /// server now holds, so the merge can tell a later local edit from it.
    public static func acknowledge(_ changes: [PendingChange], db: Database) throws {
        let statement = try db.cachedStatement(sql: "DELETE FROM syncPending WHERE uuid = ? AND revision = ?")
        for change in changes {
            try statement.execute(arguments: [change.uuid, change.revision])
            guard db.changesCount > 0, change.kind != .delete,
                  let record = try Row.fetchOne(db, sql: "SELECT tableName, localId FROM syncRecord WHERE uuid = ?", arguments: [change.uuid])
            else { continue }
            try SyncMerge.setBase(toCurrentClocksOf: record["tableName"], localId: record["localId"], db: db)
        }
    }

    // MARK: Writer and incoming applies

    /// The `appUser` UUID stamped on what this connection's writes change, or nil (signed out), and the
    /// origin of those writes (what made them: an import, an edit, ...), which the triggers copy into
    /// `syncRecord.origin`; nil when unknown.
    public static func setWriter(_ appUserUuid: String?, origin: WriteOriginRaw? = nil, db: Database) throws {
        try db.execute(sql: """
            INSERT INTO syncWriter(id, appUserUuid, origin) VALUES (1, ?, ?)
            ON CONFLICT(id) DO UPDATE SET appUserUuid = excluded.appUserUuid, origin = excluded.origin
            """, arguments: [appUserUuid, origin])
    }

    /// Runs `body`, which applies incoming records, without tracking its writes: they came from the
    /// cloud and must not be queued to go back. The marker row is removed before `body`'s transaction
    /// can commit (on success and on a throw), so it can't outlive it.
    static func applyingIncoming<T>(db: Database, _ body: () throws -> T) throws -> T {
        guard db.isInsideTransaction else { throw SyncChangeTrackerError.notInTransaction }
        let outermost = try !Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM syncApplying)")!
        guard outermost else { return try body() }
        try db.execute(sql: "INSERT INTO syncApplying(id) VALUES (1)")
        let result: T
        do {
            result = try body()
        } catch {
            try? db.execute(sql: "DELETE FROM syncApplying")
            throw error
        }
        // On success a failed removal must fail the transaction rather than leave tracking off.
        try db.execute(sql: "DELETE FROM syncApplying")
        return result
    }

    /// Runs `body` with tracking on even inside `applyingIncoming`: for a write an incoming change makes
    /// this device do on its own rows (re-filing what still named a merged kind), which the other devices
    /// must hear about because only this one had those rows that way.
    /// On a read-only device (`readOnlyApply`) the writes stay untracked: nothing there is ever sent, so queueing
    /// them would only leave pending rows behind for good.
    static func trackingWrites<T>(db: Database, _ body: () throws -> T) throws -> T {
        let applying = try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM syncApplying)") ?? false
        guard applying, try !inReadOnlyApply(db: db) else { return try body() }
        try db.execute(sql: "DELETE FROM syncApplying")
        let result: T
        do {
            result = try body()
        } catch {
            try? db.execute(sql: "INSERT OR IGNORE INTO syncApplying(id) VALUES (1)")
            throw error
        }
        try db.execute(sql: "INSERT OR IGNORE INTO syncApplying(id) VALUES (1)")
        return result
    }

    static let readOnlyApplyKey = "readOnlyApply"

    /// Runs `body` (a read-only engine's apply) so that `trackingWrites` inside it tracks nothing. The marker
    /// (a `syncState` row) is removed before `body`'s transaction can commit, on success and on a throw.
    static func readOnlyApply<T>(db: Database, _ body: () throws -> T) throws -> T {
        guard db.isInsideTransaction else { throw SyncChangeTrackerError.notInTransaction }
        try db.execute(sql: "INSERT OR REPLACE INTO syncState(key, value, updatedAt) VALUES (?, X'01', ?)",
                       arguments: [readOnlyApplyKey, Date()])
        let result: T
        do {
            result = try body()
        } catch {
            try? db.execute(sql: "DELETE FROM syncState WHERE key = ?", arguments: [readOnlyApplyKey])
            throw error
        }
        try db.execute(sql: "DELETE FROM syncState WHERE key = ?", arguments: [readOnlyApplyKey])
        return result
    }

    static func inReadOnlyApply(db: Database) throws -> Bool {
        try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM syncState WHERE key = ?)", arguments: [readOnlyApplyKey]) ?? false
    }

    // MARK: Triggers

    /// The schema version and hash whose triggers are installed (`syncState` key `triggerSchema`).
    public struct InstalledSchema: Codable, Equatable, Sendable {
        public var version: Int
        public var hash: String
    }

    static let installedSchemaKey = "triggerSchema"
    private static let log = Logger(subsystem: "com.personal.budget", category: "Sync")

    public static func installedSchema(db: Database) throws -> InstalledSchema? {
        try Data.fetchOne(db, sql: "SELECT value FROM syncState WHERE key = ?", arguments: [installedSchemaKey])
            .map { try JSONDecoder().decode(InstalledSchema.self, from: $0) }
    }

    /// SHA-256 of every trigger `schema` calls for: it changes with the schema and with the template.
    public static func schemaHash(_ schema: [SyncTableSchema]) -> String {
        let text = schema.flatMap { triggers(for: $0) }.map { $0.0 + "\n" + $0.1 }.joined(separator: "\n\n")
        return SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Makes the database's tracking triggers exactly those `schema` calls for: creates missing ones,
    /// replaces changed ones, drops stale ones, and leaves the schema untouched when they already match.
    /// - A listed table or column the database doesn't have (yet) is skipped and logged, so a database
    ///   migrated part of the way still takes writes.
    /// - Triggers a newer `version` installed are left as they are (logged): an older build must not
    ///   take tracking away from columns it doesn't know.
    /// Also clears a stale incoming-apply marker and sweeps identities whose row is gone (a delete no
    /// trigger saw) into tombstones. `DatabaseManager.migrate` runs it on every open.
    public static func refreshSyncTriggers(db: Database, schema: [SyncTableSchema] = SyncSchema.tables,
                                           version: Int = SyncSchema.version) throws {
        let present = try present(schema, db: db)
        if let installed = try installedSchema(db: db), installed.version > version {
            log.error("Sync triggers were installed by schema version \(installed.version), newer than this build's \(version); left as they are")
        } else {
            // A database migrated only part of the way (tests' `migrate(upTo:)`) has no origin columns yet.
            let stampOrigin = try db.columns(in: "syncRecord").contains { $0.name == "origin" }
                && db.columns(in: "syncWriter").contains { $0.name == "origin" }
            let expected = Dictionary(uniqueKeysWithValues: present.flatMap { triggers(for: $0, stampOrigin: stampOrigin) })
            let installed = try Row.fetchAll(db, sql: "SELECT name, sql FROM sqlite_master WHERE type = 'trigger' AND name LIKE ? ESCAPE '\\'",
                                             arguments: [triggerPrefix.replacingOccurrences(of: "_", with: "\\_") + "%"])
            var current: [String: String] = [:]
            for row in installed { current[row["name"]] = row["sql"] }
            for (name, sql) in current where expected[name] != sql {
                try db.execute(sql: "DROP TRIGGER \(quoted(name))")
            }
            for (name, sql) in expected.sorted(by: { $0.key < $1.key }) where current[name] != sql {
                try db.execute(sql: sql)
            }
            let stamp = InstalledSchema(version: version, hash: schemaHash(schema))
            if try installedSchema(db: db) != stamp {
                try db.execute(sql: """
                    INSERT INTO syncState(key, value, updatedAt) VALUES (?, ?, \(now))
                    ON CONFLICT(key) DO UPDATE SET value = excluded.value, updatedAt = excluded.updatedAt
                    """, arguments: [installedSchemaKey, try JSONEncoder().encode(stamp)])
            }
        }
        try db.execute(sql: "DELETE FROM syncApplying")
        for table in present { try sweepOrphans(table, db: db) }
    }

    /// `schema` cut down to the tables and columns the database has; what is missing is logged.
    private static func present(_ schema: [SyncTableSchema], db: Database) throws -> [SyncTableSchema] {
        try schema.compactMap { table in
            guard try db.tableExists(table.name) else {
                log.error("Sync tracking skips table \(table.name, privacy: .public): not in the database")
                return nil
            }
            let columns = Set(try db.columns(in: table.name).map(\.name))
            guard columns.contains(table.localIdColumn) else {
                log.error("Sync tracking skips table \(table.name, privacy: .public): no column \(table.localIdColumn, privacy: .public)")
                return nil
            }
            let missing = table.syncedColumns.filter { !columns.contains($0) }
            guard !missing.isEmpty else { return table }
            log.error("Sync tracking skips columns not in the database: \(missing.map { table.name + "." + $0 }.joined(separator: ", "), privacy: .public)")
            return SyncTableSchema(table.name, localIdColumn: table.localIdColumn, synced: table.syncedColumns.filter(columns.contains),
                                   foreignKeys: table.foreignKeys.filter { columns.contains($0.key) },
                                   localOnly: table.localOnlyColumns.filter(columns.contains), batchKey: table.batchKey)
        }
    }

    /// The tracking triggers for one table, by name. `stampOrigin` false leaves out `syncRecord.origin`, for
    /// a database whose migrations haven't added it yet.
    static func triggers(for table: SyncTableSchema, stampOrigin: Bool = true) -> [(String, String)] {
        let t = literal(table.name)
        let tq = quoted(table.name)
        let key = quoted(table.localIdColumn)
        let notApplying = "NOT EXISTS (SELECT 1 FROM syncApplying)"
        let name = { (suffix: String) in triggerPrefix + table.name + "_" + suffix }
        let fields = table.syncedColumns.filter { $0 != table.localIdColumn }

        func touch(_ row: String) -> String {
            let id = "\(row).\(key)"
            return """
                INSERT INTO syncPending(uuid, tableName, localId, kind, revision)
                    SELECT uuid, \(t), \(id), 'update', \(revision) FROM syncRecord WHERE tableName = \(t) AND localId = \(id)
                    ON CONFLICT(uuid) DO UPDATE SET kind = CASE syncPending.kind WHEN 'insert' THEN 'insert' ELSE 'update' END,
                        revision = excluded.revision;
                INSERT INTO syncRecord(tableName, localId, uuid, zone)
                    SELECT \(t), \(id), \(SyncRecordStore.uuidSQL), \(literal(SyncRecordStore.householdZone))
                    WHERE NOT EXISTS (SELECT 1 FROM syncRecord WHERE tableName = \(t) AND localId = \(id));
                INSERT INTO syncPending(uuid, tableName, localId, kind, revision)
                    SELECT s.uuid, \(t), \(id), 'insert', \(revision) FROM syncRecord s
                    WHERE s.tableName = \(t) AND s.localId = \(id) AND NOT EXISTS (SELECT 1 FROM syncPending p WHERE p.uuid = s.uuid);
                UPDATE syncRecord SET modifiedAt = \(now), modifiedBy = \(writer)\(stampOrigin ? ", origin = \(origin)" : "") WHERE tableName = \(t) AND localId = \(id);
                """
        }
        let clockUpsert = "ON CONFLICT(tableName, localId, field) DO UPDATE SET modifiedAt = excluded.modifiedAt, modifiedBy = excluded.modifiedBy"

        var result: [(String, String)] = []
        result.append((name("ins"), """
            CREATE TRIGGER \(quoted(name("ins"))) AFTER INSERT ON \(tq) WHEN \(notApplying)
            BEGIN
            \(touch("NEW"))
            DELETE FROM syncFieldClock WHERE tableName = \(t) AND localId = NEW.\(key) AND field <> '*';
            INSERT INTO syncFieldClock(tableName, localId, field, modifiedAt, modifiedBy) VALUES (\(t), NEW.\(key), '*', \(now), \(writer))
                \(clockUpsert);
            END
            """))
        if !fields.isEmpty {
            // BINARY: a column's own collation (NOCASE on names) would hide a case-only change.
            let changed = fields.map { "NEW.\(quoted($0)) IS NOT OLD.\(quoted($0)) COLLATE BINARY" }
            let which = fields.map { "SELECT \(literal($0)) AS field WHERE NEW.\(quoted($0)) IS NOT OLD.\(quoted($0)) COLLATE BINARY" }
            result.append((name("upd"), """
                CREATE TRIGGER \(quoted(name("upd"))) AFTER UPDATE ON \(tq) WHEN \(notApplying) AND (\(changed.joined(separator: " OR ")))
                BEGIN
                \(touch("NEW"))
                INSERT INTO syncFieldClock(tableName, localId, field, modifiedAt, modifiedBy)
                    SELECT \(t), NEW.\(key), field, \(now), \(writer) FROM (\(which.joined(separator: " UNION ALL "))) WHERE true
                    \(clockUpsert);
                END
                """))
        }
        result.append((name("del"), """
            CREATE TRIGGER \(quoted(name("del"))) AFTER DELETE ON \(tq) WHEN \(notApplying)
            BEGIN
            INSERT INTO syncTombstone(uuid, tableName, localId, zone, deletedBy, deletedAt)
                SELECT uuid, tableName, localId, zone, \(writer), \(now) FROM syncRecord WHERE tableName = \(t) AND localId = OLD.\(key)
                ON CONFLICT(uuid) DO UPDATE SET deletedBy = excluded.deletedBy, deletedAt = excluded.deletedAt;
            INSERT INTO syncPending(uuid, tableName, localId, kind, revision)
                SELECT uuid, \(t), OLD.\(key), 'delete', \(revision) FROM syncRecord WHERE tableName = \(t) AND localId = OLD.\(key)
                ON CONFLICT(uuid) DO UPDATE SET kind = 'delete', revision = excluded.revision;
            DELETE FROM syncFieldClock WHERE tableName = \(t) AND localId = OLD.\(key);
            DELETE FROM syncRecord WHERE tableName = \(t) AND localId = OLD.\(key);
            END
            """))
        let message = "\(table.name).\(table.localIdColumn) is a sync identity and cannot change: delete the row and insert a new one"
        result.append((name("key"), """
            CREATE TRIGGER \(quoted(name("key"))) BEFORE UPDATE OF \(key) ON \(tq) WHEN NEW.\(key) IS NOT OLD.\(key)
            BEGIN
            SELECT RAISE(ABORT, \(literal(message)));
            END
            """))
        return result
    }

    /// Identities of `table` whose row no longer exists (removed where no trigger saw it): tombstoned,
    /// queued as deletes and retired.
    private static func sweepOrphans(_ table: SyncTableSchema, db: Database) throws {
        let gone = "s.tableName = ? AND NOT EXISTS (SELECT 1 FROM \(quoted(table.name)) t WHERE t.\(quoted(table.localIdColumn)) = s.localId)"
        let orphans = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM syncRecord s WHERE \(gone)", arguments: [table.name]) ?? 0
        guard orphans > 0 else { return }
        try db.execute(sql: """
            INSERT INTO syncTombstone(uuid, tableName, localId, zone, deletedBy, deletedAt)
                SELECT s.uuid, s.tableName, s.localId, s.zone, NULL, \(now) FROM syncRecord s WHERE \(gone)
                ON CONFLICT(uuid) DO UPDATE SET deletedAt = excluded.deletedAt
            """, arguments: [table.name])
        try db.execute(sql: """
            INSERT INTO syncPending(uuid, tableName, localId, kind, revision)
                SELECT s.uuid, s.tableName, s.localId, 'delete', \(revision) FROM syncRecord s WHERE \(gone)
                ON CONFLICT(uuid) DO UPDATE SET kind = 'delete', revision = excluded.revision
            """, arguments: [table.name])
        try db.execute(sql: """
            DELETE FROM syncFieldClock WHERE tableName = ? AND localId IN (SELECT s.localId FROM syncRecord s WHERE \(gone))
            """, arguments: [table.name, table.name])
        try db.execute(sql: "DELETE FROM syncRecord AS s WHERE \(gone)", arguments: [table.name])
    }

    // MARK: SQL pieces

    /// GRDB's own date format (UTC, milliseconds), so `Date` columns decode.
    static let now = "strftime('%Y-%m-%d %H:%M:%f', 'now')"
    private static let writer = "(SELECT appUserUuid FROM syncWriter WHERE id = 1)"
    private static let origin = "(SELECT origin FROM syncWriter WHERE id = 1)"
    /// One more than any queued revision: above the record's own, which is still queued if not sent.
    private static let revision = "(SELECT COALESCE(MAX(revision), 0) + 1 FROM syncPending)"

    static func quoted(_ name: String) -> String {
        "\"" + name.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    static func literal(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "''") + "'"
    }
}
