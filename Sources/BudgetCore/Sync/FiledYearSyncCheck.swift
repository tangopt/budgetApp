import Foundation
import GRDB
import os

/// The filed and paid years' figures as stored before a sync applies anything (`FiledYearSyncCheck`), with
/// what taking them read, so the check after an apply works out again only what the apply could have moved.
public struct FiledYearBaseline {
    /// The years anyone filed or paid (start years, sorted); empty: nothing to protect, nothing taken.
    public let years: [Int]
    /// Their figures (`TaxFigures.snapshot(db:only: years)`), with every stored year's statuses.
    public let before: TaxFigures.Snapshot
    /// What taking `before` read, year by year (nil: not replayable, or no years).
    let reads: FiledYearGuard.YearReads?

    public var isEmpty: Bool { years.isEmpty }

    /// No baseline: nothing is checked.
    public static let none = FiledYearBaseline(years: [], before: TaxFigures.Snapshot(), reads: nil)
}

/// What an incoming sync would have changed on a filed or paid return, and the records held for it (sync
/// spec §5.4: "a banner naming the records and who changed them"; step 6 shows it). Never logged: the
/// impacts carry amounts and names.
public struct FiledYearSyncAlert: Equatable, Sendable {
    public struct Record: Equatable, Sendable {
        public var recordType: String
        public var recordName: String
        /// A deletion, not a save.
        public var isDelete: Bool
        /// Who last wrote the record (its `modifiedBy`, an app user's UUID); nil for a deletion, whose
        /// writer the change feed doesn't carry.
        public var writer: String?
        /// That app user's display name, when this device knows them.
        public var writerName: String?
        /// Why it is held (`FiledYearSyncCheck.heldReason`, `heldDeleteReason` or `heldAlongReason`).
        public var reason: String
    }

    /// Every record held by this pull.
    public var records: [Record]
    /// What applying the pull as received would change on each filed or paid return.
    public var impacts: [FiledYearImpact]
}

/// Sync spec §5.4, the second line behind the writer's `FiledYearGuard`: after a pull is applied, the filed
/// and paid years' figures are worked out again; an apply that would move any figure on one of those returns
/// is rolled back, and the records that cause it are held in `syncStaging` for attention (never retried),
/// named with their writer in a `FiledYearSyncAlert`. What else the pull brought still applies.
///
/// - **Which figures:** the Self Assessment return figures (`"SA …"`) of every (year, person) filed or paid,
///   as the importer's guard counts them (`FiledYearImpact.impacts`); figures that are information only (a
///   rental-account line not on the return) may change. In the real database these are 2020/21–2024/25.
/// - **Fast:** the baseline records what taking the figures read (`TaxFiguresReads`); after an apply only
///   the statements reading a table it wrote run again, and only the years one of whose statements returns
///   something else are worked out again (none: the apply moves nothing, the usual case).
/// - **Isolation** (`apply(_:baseline:db:deviceUser:now:)`, ruling recorded in the Task 6 report): when the
///   whole pull would move a filed figure, the records that do are found by bisection in feed order and held;
///   everything else applies. An import batch is all or nothing (§5.2): a held member, or the run's record,
///   holds the whole batch, and `SyncBatch` never applies a held batch (`runIsHeld`), not even at
///   `flushClosed`. A record that moves a figure only together with an earlier one is found too (the later
///   one is held). Past `maxIsolated` records, the remainder of the pull is held with them.
public enum FiledYearSyncCheck {
    private static let log = Logger(subsystem: "com.personal.budget", category: "Sync")

    public static let heldReason = SyncTranslator.needsAttention + "would change a filed tax year"
    public static let heldDeleteReason = SyncTranslator.needsAttention + "would change a filed tax year (delete)"
    /// A record held without being shown to move a figure itself: in a batch with one that does, or past
    /// `maxIsolated`.
    public static let heldAlongReason = SyncTranslator.needsAttention + "held with records that would change a filed tax year"
    /// How many records one pull isolates one by one before holding the rest of it with them.
    static let maxIsolated = 25

    // MARK: The check

    /// The figures of the years anyone filed or paid, as stored now, with what taking them read.
    public static func baseline(db: Database) throws -> FiledYearBaseline {
        let years = try FiledYearGuard.filedYears(db: db).sorted()
        guard !years.isEmpty else { return .none }
        let (before, reads) = try FiledYearGuard.recordedSnapshot(db: db, years: years)
        return FiledYearBaseline(years: years, before: before, reads: reads)
    }

    /// Runs `apply` in a savepoint and compares the filed figures with those before it: kept when nothing on
    /// a filed or paid return moved (nil), else rolled back and the alert returned (with its impacts; the
    /// records are the caller's to name).
    public static func after(apply: () throws -> Void, db: Database) throws -> FiledYearSyncAlert? {
        let base = try baseline(db: db)
        var impacts: [FiledYearImpact] = []
        try db.inSavepoint {
            impacts = try Self.impacts(db: db, baseline: base, apply: apply)
            return impacts.isEmpty ? .commit : .rollback
        }
        return impacts.isEmpty ? nil : FiledYearSyncAlert(records: [], impacts: impacts)
    }

    /// Runs `apply` (in the caller's savepoint) and returns what it changed on filed or paid returns.
    static func impacts(db: Database, baseline: FiledYearBaseline, apply: () throws -> Void) throws -> [FiledYearImpact] {
        guard !baseline.isEmpty else {
            try apply()
            return []
        }
        return try impacts(db: db, baseline: baseline, written: TaxFiguresReads.writtenTables(db: db, apply))
    }

    /// What differs now on filed or paid returns from `baseline`. `written`: the only tables written since it
    /// was taken (nil: can't tell, every recorded statement runs again).
    static func impacts(db: Database, baseline: FiledYearBaseline, written: Set<String>?) throws -> [FiledYearImpact] {
        guard !baseline.isEmpty else { return [] }
        let after: TaxFigures.Snapshot
        if let reads = baseline.reads, let changed = try reads.changedYears(db: db, written: written, fixedYears: true) {
            guard !changed.isEmpty else { return [] }
            // The returns and accounts of the years whose reads didn't change are reused.
            let part = try TaxFigures.snapshot(db: db, only: changed, memo: reads.memo.keeping(excluding: Set(changed)))
            let retaken = Set(changed)
            var composed = baseline.before
            composed.values = composed.values.filter { !retaken.contains($0.key.startYear) }.merging(part.values) { _, new in new }
            composed.statuses = part.statuses
            after = composed
        } else {
            after = try TaxFigures.snapshot(db: db, only: baseline.years)
        }
        return FiledYearImpact.impacts(before: baseline.before, after: after, causes: [])
    }

    // MARK: Isolation

    /// What `apply(_:baseline:db:deviceUser:now:)` applied and held.
    struct Outcome {
        /// The translator's results for the changes applied.
        var results: [String: IncomingResult] = [:]
        /// Nil when nothing was held.
        var alert: FiledYearSyncAlert?
    }

    /// Applies a pull (`SyncTranslator.apply`, then `SyncBatch.flushClosed`: the fetch has caught up) so that
    /// no filed or paid return moves, inside the caller's transaction:
    /// 1. the whole pull and the flush, kept when they move nothing (the usual case: one apply, one check);
    /// 2. else, in feed order, what moves nothing is kept and each record that moves a figure (on top of what
    ///    is kept) is found by bisection and held: the first half is applied and kept when it moves nothing,
    ///    else rolled back and halved again; each check is against the baseline, so whatever is kept is
    ///    verified as a whole;
    /// 3. then each closed batch is flushed on its own, and held whole when its flush would move a figure.
    static func apply(_ changes: [SyncIncomingChange], baseline: FiledYearBaseline, db: Database, deviceUser: String?,
                      now: Date) throws -> Outcome {
        func translate(_ subset: some Collection<SyncIncomingChange>) throws -> [String: IncomingResult] {
            subset.isEmpty ? [:] : try SyncTranslator.apply(Array(subset), db: db, deviceUser: deviceUser, now: now)
        }
        guard !baseline.isEmpty else {
            let results = try translate(changes)
            _ = try SyncBatch.flushClosed(db: db, deviceUser: deviceUser, now: now)
            return Outcome(results: results)
        }
        // The tables written since the baseline by what is kept (nil: can't tell).
        var written: Set<String>? = []
        /// `body` in a savepoint, kept when nothing on a filed return moves (empty), else rolled back.
        func attempt(_ body: () throws -> Void) throws -> [FiledYearImpact] {
            var moved: [FiledYearImpact] = []
            try db.inSavepoint {
                let wrote = try TaxFiguresReads.writtenTables(db: db, body)
                let all = written.flatMap { before in wrote.map { before.union($0) } }
                moved = try impacts(db: db, baseline: baseline, written: all)
                guard moved.isEmpty else { return .rollback }
                written = all
                return .commit
            }
            return moved
        }

        var results: [String: IncomingResult] = [:]
        let whole = try attempt {
            results = try translate(changes)
            _ = try SyncBatch.flushClosed(db: db, deviceUser: deviceUser, now: now)
        }
        guard !whole.isEmpty else { return Outcome(results: results) }
        results = [:]

        var held: [(change: SyncIncomingChange, reason: String)] = []
        var marked: [SyncStagingRow] = []
        var pending = changes[...]

        /// Applies `range` on top of what is kept, keeping what moves nothing; the index of the record that
        /// moves a figure (rolled back), or nil when all of it was kept. `next`: the first index not decided.
        var next = pending.startIndex
        func find(_ range: ArraySlice<SyncIncomingChange>) throws -> Int? {
            var applied: [String: IncomingResult] = [:]
            if range.count == 1 {
                next = range.endIndex
                if try attempt({ applied = try translate(range) }).isEmpty {
                    results.merge(applied) { _, new in new }
                    return nil
                }
                return range.startIndex
            }
            let middle = range.startIndex + range.count / 2
            let left = range[range.startIndex..<middle]
            if try attempt({ applied = try translate(left) }).isEmpty {
                results.merge(applied) { _, new in new }
                next = middle
                return try find(range[middle...])
            }
            return try find(left)
        }

        while !pending.isEmpty {
            var applied: [String: IncomingResult] = [:]
            if try attempt({ applied = try translate(pending) }).isEmpty {
                results.merge(applied) { _, new in new }
                break
            }
            if held.count >= maxIsolated {
                // Too many to isolate one by one: the rest of the pull waits with them.
                log.error("Sync filed-year check: holding the rest of a pull (\(pending.count) records)")
                for change in pending { held.append((change, heldAlongReason)) }
                break
            }
            next = pending.startIndex
            let offender = try find(pending)
            var rest = pending[next...]
            if let offender {
                log.error("Sync filed-year check: holding a record that would change a filed tax year")
                let change = pending[offender]
                held.append((change, reason(for: change)))
                if let run = run(of: change) {
                    // All or nothing: the batch waits whole, here and in staging.
                    rest = rest.filter { self.run(of: $0) != run }[...]
                    for member in pending[next...] where self.run(of: member) == run { held.append((member, heldAlongReason)) }
                    marked += try markHeld(run: run, db: db)
                }
            }
            pending = Array(rest)[...]
        }

        // Each closed batch flushed on its own (`flushClosed`), held whole when its flush moves a figure.
        for run in try String.fetchAll(db, sql: "SELECT runUuid FROM syncBatch WHERE state = 'closed' ORDER BY runUuid") {
            let moved = try attempt {
                _ = try SyncChangeTracker.applyingIncoming(db: db) {
                    try SyncBatch.flushIfComplete(run: run, db: db, deviceUser: deviceUser, now: now, force: true)
                }
            }
            if !moved.isEmpty {
                log.error("Sync filed-year check: holding an import batch that would change a filed tax year")
                marked += try markHeld(run: run, db: db)
            }
        }
        try stageHeld(held, db: db, now: now)
        return Outcome(results: results, alert: try alert(held, marked: marked, impacts: whole, db: db))
    }

    private static func reason(for change: SyncIncomingChange) -> String {
        if case .delete = change { return heldDeleteReason }
        return heldReason
    }

    /// The import run whose batch the change belongs to (a member, or the run's own record).
    private static func run(of change: SyncIncomingChange) -> String? {
        guard case .save(let payload) = change else { return nil }
        if let run = payload.importRunUuid { return run }
        return payload.recordType == ImportRun.databaseTableName && payload.manifest != nil ? payload.recordName : nil
    }

    /// The staged records of a held batch are marked held, so the batch can't apply without them. Returns them.
    private static func markHeld(run: String, db: Database) throws -> [SyncStagingRow] {
        let rows = try SyncStagingRow.fetchAll(db, sql: "SELECT * FROM syncStaging WHERE importRunUuid = ? AND reason NOT LIKE ? ORDER BY id",
                                               arguments: [run, SyncTranslator.needsAttention + "%"])
        try db.execute(sql: "UPDATE syncStaging SET reason = ? WHERE importRunUuid = ? AND reason NOT LIKE ?",
                       arguments: [heldAlongReason, run, SyncTranslator.needsAttention + "%"])
        return rows
    }

    /// Whether a batch waits held (one of its staged records is): `SyncBatch` never applies it.
    static func runIsHeld(_ run: String, db: Database) throws -> Bool {
        try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM syncStaging WHERE importRunUuid = ? AND reason IN (?, ?, ?))",
                          arguments: [run, heldReason, heldDeleteReason, heldAlongReason]) ?? false
    }

    /// The held records, kept in staging for attention (never retried; a newer version arriving replaces one
    /// and is checked again). A batch's keep its run, so the batch stays together.
    private static func stageHeld(_ held: [(change: SyncIncomingChange, reason: String)], db: Database, now: Date) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        for (change, reason) in held {
            let payload: SyncPayload
            var tableName: String
            switch change {
            case .save(let saved):
                payload = saved
                tableName = saved.recordType
            case .delete(let name, let type):
                tableName = try type ?? String.fetchOne(db, sql: "SELECT tableName FROM syncRecord WHERE uuid = ?", arguments: [name]) ?? ""
                payload = SyncPayload(recordType: tableName, recordName: name, zone: SyncRecordStore.householdZone, fields: [:])
            }
            if tableName.isEmpty { tableName = payload.recordType }
            try db.execute(sql: """
                INSERT INTO syncStaging(tableName, uuid, payloadJSON, reason, importRunUuid, receivedAt, batchGeneration, firstSeenAt, attempts)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, 0)
                ON CONFLICT(uuid) DO UPDATE SET tableName = excluded.tableName, payloadJSON = excluded.payloadJSON, reason = excluded.reason,
                    importRunUuid = excluded.importRunUuid, receivedAt = excluded.receivedAt, batchGeneration = excluded.batchGeneration
                """, arguments: [tableName, payload.recordName, String(decoding: try encoder.encode(payload), as: UTF8.self), reason,
                                 run(of: change), now, payload.batchGeneration, now])
        }
    }

    private static func alert(_ held: [(change: SyncIncomingChange, reason: String)], marked: [SyncStagingRow], impacts: [FiledYearImpact],
                              db: Database) throws -> FiledYearSyncAlert? {
        guard !held.isEmpty || !marked.isEmpty else { return nil }
        var records = try held.map { change, reason -> FiledYearSyncAlert.Record in
            switch change {
            case .save(let payload):
                return FiledYearSyncAlert.Record(recordType: payload.recordType, recordName: payload.recordName, isDelete: false,
                                                 writer: payload.modifiedBy, writerName: try writerName(payload.modifiedBy, db: db), reason: reason)
            case .delete(let name, let type):
                let table = try type ?? String.fetchOne(db, sql: "SELECT tableName FROM syncRecord WHERE uuid = ?", arguments: [name]) ?? ""
                return FiledYearSyncAlert.Record(recordType: table, recordName: name, isDelete: true, writer: nil, writerName: nil, reason: reason)
            }
        }
        let named = Set(records.map(\.recordName))
        for row in marked where !named.contains(row.uuid) {
            let payload = try? JSONDecoder().decode(SyncPayload.self, from: Data(row.payloadJSON.utf8))
            records.append(FiledYearSyncAlert.Record(recordType: row.tableName, recordName: row.uuid, isDelete: false, writer: payload?.modifiedBy,
                                                     writerName: try writerName(payload?.modifiedBy, db: db), reason: heldAlongReason))
        }
        return FiledYearSyncAlert(records: records, impacts: impacts)
    }

    /// The display name of the app user whose record UUID is `writer`.
    private static func writerName(_ writer: String?, db: Database) throws -> String? {
        guard let writer, let id = try SyncRecordStore.localId(table: "appUser", uuid: writer, db: db) else { return nil }
        return try String.fetchOne(db, sql: "SELECT displayName FROM appUser WHERE id = ?", arguments: [id])
    }

    /// The records held by this check, oldest first (step 6 shows them with the alert).
    public static func held(db: Database) throws -> [SyncStagingRow] {
        try SyncStagingRow.fetchAll(db, sql: "SELECT * FROM syncStaging WHERE reason IN (?, ?, ?) ORDER BY id",
                                    arguments: [heldReason, heldDeleteReason, heldAlongReason])
    }
}
