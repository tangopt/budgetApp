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
    /// Increases with every change queued on this database; `acknowledge` drops an entry only while
    /// its revision is the one that was sent, so an edit made during an upload stays pending.
    public var revision: Int64

    public init(table: String, localId: Int64, uuid: String, kind: Kind, revision: Int64 = 0) {
        self.table = table
        self.localId = localId
        self.uuid = uuid
        self.kind = kind
        self.revision = revision
    }
}

/// Watches the app's database connection and queues every committed insert, update and delete of a
/// synced table (`SyncSchema.tables`) as a `PendingChange`, kept in `syncState` so it survives a
/// relaunch. Local-only tables (the sync tables themselves among them) are not observed.
///
/// How it behaves, and why:
/// - **Only committed work counts.** GRDB holds a savepoint's events until it is released and drops
///   those of a savepoint rolled back, and the tracker drops its buffer on a rollback. So the
///   simulations that write and roll back on the app's own queue (`FiledYearGuard`, the undo conflict
///   check, the importer's passes) leave nothing pending. Plans run on a private copy
///   (`ImportPlanningCopy`, its own `DatabaseQueue`), which this tracker never sees.
/// - **Bookkeeping is written right after the commit**, in its own transaction on the same connection
///   (GRDB allows writes from `databaseDidCommit`; SQLite's commit hook does not, so it can't be inside
///   the user's transaction). A crash in between loses that commit's queue entries; the rows themselves
///   are safe. If the write fails, the events are kept and retried after the next commit.
/// - **Rows are identified by rowid** (the update hook's), which is every synced table's local id
///   (`SyncChangeTrackerTests.testEveryLocalIdIsTheRowId`).
/// - **A delete leaves a tombstone** and retires the row's identity, so a later row that reuses the
///   local id is a new record. A row that never had an identity has nothing to delete remotely.
/// - It sees only the connection it is installed on: other `DatabaseQueue`s on the same file (the
///   one-off tools) are not tracked.
public final class SyncChangeTracker: TransactionObserver, @unchecked Sendable {
    // @unchecked: mutable state is guarded by `lock`; GRDB calls the observer on the writer's queue.
    private struct Event {
        let table: String
        let rowId: Int64
        let kind: DatabaseEvent.Kind
    }

    private static let log = Logger(subsystem: "com.personal.budget", category: "Sync")
    static let pendingPrefix = "pending:"
    static let revisionKey = "pendingRevision"

    private let lock = NSLock()
    private let now: @Sendable () -> Date
    private var buffer: [Event] = []
    private var unsaved: [Event] = []
    private var ignoring = 0
    private var writer: String?

    public init(now: @escaping @Sendable () -> Date = { Date() }) {
        self.now = now
    }

    /// A tracker observing `writer` for as long as the database lives.
    @discardableResult
    public static func install(on writer: some DatabaseWriter, now: @escaping @Sendable () -> Date = { Date() }) throws -> SyncChangeTracker {
        let tracker = SyncChangeTracker(now: now)
        writer.add(transactionObserver: tracker, extent: .databaseLifetime)
        return tracker
    }

    /// The `appUser` UUID stamped on records this device writes (`syncRecord.modifiedBy`).
    public var modifiedBy: String? {
        get { lock.withLock { writer } }
        set { lock.withLock { writer = newValue } }
    }

    /// Runs `body` without tracking its writes: incoming records applied by the sync engine must not be
    /// queued to go back out. Call it on the writer's queue, around writes that aren't inside a
    /// savepoint opened outside `body` (GRDB delivers those events when the savepoint is released).
    public func ignoringChanges<T>(_ body: () throws -> T) rethrows -> T {
        lock.withLock { ignoring += 1 }
        defer { lock.withLock { ignoring -= 1 } }
        return try body()
    }

    // MARK: TransactionObserver

    public func observes(eventsOfKind eventKind: DatabaseEventKind) -> Bool {
        SyncSchema.table(eventKind.tableName) != nil
    }

    public func databaseDidChange(with event: DatabaseEvent) {
        lock.withLock {
            guard ignoring == 0 else { return }
            buffer.append(Event(table: event.tableName, rowId: event.rowID, kind: event.kind))
        }
    }

    public func databaseDidCommit(_ db: Database) {
        // The bookkeeping transaction below commits too and calls back here, with an empty buffer.
        let events: [Event] = lock.withLock {
            let taken = unsaved + buffer
            unsaved = []
            buffer = []
            return taken
        }
        guard !events.isEmpty else { return }
        let stamp = now()
        let by = modifiedBy
        do {
            try db.inTransaction {
                for event in events { try record(event, at: stamp, by: by, db: db) }
                return .commit
            }
        } catch {
            lock.withLock { unsaved = events + unsaved }
            Self.log.error("Sync change tracking failed for \(events.count) changes; will retry after the next commit")
        }
    }

    public func databaseDidRollback(_ db: Database) {
        lock.withLock { buffer = [] }
    }

    private func record(_ event: Event, at stamp: Date, by: String?, db: Database) throws {
        switch event.kind {
        case .insert, .update:
            let known = try SyncRecordStore.existingUUID(table: event.table, localId: event.rowId, db: db)
            let uuid = try known ?? SyncRecordStore.uuid(for: event.table, localId: event.rowId, db: db)
            // A row new to sync is an insert; an insert event on a known row is a REPLACE of it.
            let kind: PendingChange.Kind = known == nil ? .insert : .update
            try db.cachedStatement(sql: "UPDATE syncRecord SET modifiedAt = ?, modifiedBy = ? WHERE tableName = ? AND localId = ?")
                .execute(arguments: [stamp, by, event.table, event.rowId])
            try Self.enqueue(PendingChange(table: event.table, localId: event.rowId, uuid: uuid, kind: kind), db: db)
        case .delete:
            guard let row = try SyncRecordRow.fetchOne(
                db.cachedStatement(sql: "SELECT * FROM syncRecord WHERE tableName = ? AND localId = ?"),
                arguments: [event.table, event.rowId]) else { return }
            try SyncTombstoneRow(uuid: row.uuid, tableName: row.tableName, localId: row.localId, zone: row.zone,
                                 deletedBy: by, deletedAt: stamp).save(db)
            try db.cachedStatement(sql: "DELETE FROM syncRecord WHERE tableName = ? AND localId = ?")
                .execute(arguments: [event.table, event.rowId])
            try Self.enqueue(PendingChange(table: event.table, localId: event.rowId, uuid: row.uuid, kind: .delete), db: db)
        }
    }

    // MARK: The pending queue (syncState rows `pending:<uuid>`, in the order first queued)

    /// What is waiting to be sent, oldest first: one entry per record.
    public static func pending(db: Database) throws -> [PendingChange] {
        let decoder = JSONDecoder()
        return try Data.fetchAll(db, sql: "SELECT value FROM syncState WHERE key >= ? AND key < ? ORDER BY rowid",
                                 arguments: [pendingPrefix, pendingUpperBound])
            .map { try decoder.decode(PendingChange.self, from: $0) }
    }

    /// Removes the entries the server has taken, unless they changed again since they were read.
    public static func acknowledge(_ changes: [PendingChange], db: Database) throws {
        let decoder = JSONDecoder()
        for change in changes {
            let key = pendingPrefix + change.uuid
            guard let data = try Data.fetchOne(db.cachedStatement(sql: "SELECT value FROM syncState WHERE key = ?"), arguments: [key]),
                  try decoder.decode(PendingChange.self, from: data).revision == change.revision else { continue }
            try db.cachedStatement(sql: "DELETE FROM syncState WHERE key = ?").execute(arguments: [key])
        }
    }

    /// Queues `change`, merged with what is already queued for the record: an update to a record not
    /// yet sent stays an insert, and a delete replaces anything before it.
    static func enqueue(_ change: PendingChange, db: Database) throws {
        let key = pendingPrefix + change.uuid
        var merged = change
        if let data = try Data.fetchOne(db.cachedStatement(sql: "SELECT value FROM syncState WHERE key = ?"), arguments: [key]),
           let queued = try? JSONDecoder().decode(PendingChange.self, from: data),
           queued.kind == .insert, change.kind == .update {
            merged.kind = .insert
        }
        merged.revision = try nextRevision(db: db)
        let stamp = Date()
        // An upsert keeps the row (and its rowid, so its place in the queue).
        try db.cachedStatement(sql: """
            INSERT INTO syncState(key, value, updatedAt) VALUES (?, ?, ?)
            ON CONFLICT(key) DO UPDATE SET value = excluded.value, updatedAt = excluded.updatedAt
            """).execute(arguments: [key, try JSONEncoder().encode(merged), stamp])
    }

    private static func nextRevision(db: Database) throws -> Int64 {
        let current = try Data.fetchOne(db.cachedStatement(sql: "SELECT value FROM syncState WHERE key = ?"), arguments: [revisionKey])
            .flatMap { Int64(String(decoding: $0, as: UTF8.self)) } ?? 0
        let next = current + 1
        try db.cachedStatement(sql: """
            INSERT INTO syncState(key, value, updatedAt) VALUES (?, ?, ?)
            ON CONFLICT(key) DO UPDATE SET value = excluded.value, updatedAt = excluded.updatedAt
            """).execute(arguments: [revisionKey, Data(String(next).utf8), Date()])
        return next
    }

    /// The first key after every `pending:` key (`;` follows `:`).
    private static let pendingUpperBound = "pending;"
}
