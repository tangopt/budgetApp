import Foundation
import GRDB
import os

/// The filed and paid years' figures as stored before a sync applies anything (`FiledYearSyncCheck`), with
/// what taking them read, so the check after an apply works out again only what the apply could have moved.
public struct FiledYearBaseline {
    /// The protected years (start years, sorted; ruling R13): 2020/21–2024/25 and any year stored filed or
    /// paid. Empty only for `none`.
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
        /// Why it is held (one of `FiledYearSyncCheck`'s held reasons).
        public var reason: String
    }

    /// Every record held (this pull's, and a held batch's records that waited here).
    public var records: [Record]
    /// What applying the pull as received would change on each filed or paid return.
    public var impacts: [FiledYearImpact]
}

/// Sync spec §5.4, the second line behind the writer's `FiledYearGuard`: whatever applies incoming records
/// (a pull, the merge of a refused save, a retry of staged records) does it through this check. The protected
/// years' figures are worked out again; an apply that would move a figure on one of those returns is rolled
/// back, and the records that cause it are held in `syncStaging` for attention (never retried), named with
/// their writer in a `FiledYearSyncAlert`. What else came still applies.
///
/// - **Protected** (ruling R13): 2020/21–2024/25, and any other year stored filed or paid; in the fixed range
///   every person who has figures here counts as filed. Figures: the Self Assessment return figures (`"SA …"`),
///   as the importer's guard counts them; information-only lines may change. A (year, person) that leaves
///   filed or paid (set back to preparing, deleted) counts as a move too.
/// - **Fast:** the baseline records what taking the figures read (`TaxFiguresReads`); after an apply only
///   the statements reading a table it wrote run again, and only the years one of whose statements returns
///   something else are worked out again (none: the apply moves nothing, the usual case).
/// - **Isolation** (`apply(_:baseline:db:deviceUser:now:retryAll:flush:)`): when the whole apply would move a
///   protected figure, the records that do are found by bisection in feed order and held; everything else
///   applies. A record that moves nothing itself but lets through a staged record or a waiting batch that
///   does (`SyncTranslator.apply(followOns: false)`) applies, and that staged record or batch is held
///   instead. An import batch is all or nothing (§5.2): it is held whole, and `SyncBatch` never applies a held
///   batch (`runIsHeld`), not even at `flushClosed`. Past `maxIsolated` offenders, the rest is held with them.
public enum FiledYearSyncCheck {
    private static let log = Logger(subsystem: "com.personal.budget", category: "Sync")

    public static let heldReason = SyncTranslator.needsAttention + "would change a filed tax year"
    public static let heldDeleteReason = SyncTranslator.needsAttention + "would change a filed tax year (delete)"
    /// A record of an import batch that would change a filed tax year: the batch waits whole.
    public static let heldBatchReason = SyncTranslator.needsAttention + "its import batch would change a filed tax year"
    /// A record held without being shown to move a figure: past `maxIsolated` offenders.
    public static let heldAlongReason = SyncTranslator.needsAttention + "held with records that would change a filed tax year"
    static let heldReasons = [heldReason, heldDeleteReason, heldBatchReason, heldAlongReason]
    /// How many offenders (records, staged records, batches) one apply isolates before holding the rest.
    static let maxIsolated = 25
    /// Ruling R13: the years filed in the real database, protected whatever their stored status.
    public static let fixedYears = 2020...2024

    /// Tables no tax figure reads, left out of the tables an apply wrote: files kept for later (plan Task 10).
    static let unprotectedTables: Set<String> = ["importWaitingFile"]

    /// The tables written that the check looks at (nil: can't tell, every recorded statement runs again).
    static func checkedWritten(_ written: Set<String>?) -> Set<String>? {
        written.map { $0.subtracting(unprotectedTables) }
    }

    // MARK: The check

    /// The protected years' figures as stored now, with what taking them read.
    public static func baseline(db: Database) throws -> FiledYearBaseline {
        let years = Set(fixedYears).union(try FiledYearGuard.filedYears(db: db)).sorted()
        let (before, reads) = try FiledYearGuard.recordedSnapshot(db: db, years: years)
        return FiledYearBaseline(years: years, before: before, reads: reads)
    }

    /// Runs `apply` in a savepoint and compares the protected figures with those before it: kept when nothing
    /// moved (nil), else rolled back and the alert returned (with its impacts; the records are the caller's to
    /// name).
    public static func after(apply: () throws -> Void, db: Database) throws -> FiledYearSyncAlert? {
        let base = try baseline(db: db)
        var impacts: [FiledYearImpact] = []
        try db.inSavepoint {
            impacts = try Self.impacts(db: db, baseline: base, apply: apply)
            return impacts.isEmpty ? .commit : .rollback
        }
        return impacts.isEmpty ? nil : FiledYearSyncAlert(records: [], impacts: impacts)
    }

    /// Runs `apply` (in the caller's savepoint) and returns what it changed on protected returns.
    static func impacts(db: Database, baseline: FiledYearBaseline, apply: () throws -> Void) throws -> [FiledYearImpact] {
        guard !baseline.isEmpty else {
            try apply()
            return []
        }
        return try impacts(db: db, baseline: baseline, written: TaxFiguresReads.writtenTables(db: db, apply))
    }

    /// What differs now on protected returns from `baseline`. `written`: the only tables written since it was
    /// taken (nil: can't tell, every recorded statement runs again).
    static func impacts(db: Database, baseline: FiledYearBaseline, written: Set<String>?) throws -> [FiledYearImpact] {
        guard !baseline.isEmpty else { return [] }
        let after: TaxFigures.Snapshot
        // The years are the baseline's own (`fixedYears`): a tax year added or removed since shows in the reads
        // of the years it reaches (each year's return works out the earlier ones it carries from).
        if let reads = baseline.reads, let changed = try reads.changedYears(db: db, written: checkedWritten(written), fixedYears: true) {
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
        return protectedImpacts(before: baseline.before, after: after)
    }

    /// `FiledYearImpact.impacts` over the protected (year, person)s (ruling R13): those filed or paid, and in
    /// `fixedYears` everyone with figures here before; a (year, person) not here before (a person arriving,
    /// a first sync) isn't. Plus a "Status" line for each (year, person) that leaves filed or paid.
    static func protectedImpacts(before: TaxFigures.Snapshot, after: TaxFigures.Snapshot) -> [FiledYearImpact] {
        func closed(_ status: TaxYearStatus?) -> Bool { status == .filed || status == .paid }
        var present: Set<YearPerson> = Set(before.values.keys.map { YearPerson(year: $0.startYear, person: $0.person) })
        for (year, people) in before.statuses { for person in people.keys { present.insert(YearPerson(year: year, person: person)) } }
        var protectedBefore = before, protectedAfter = after
        for key in present where fixedYears.contains(key.year) && !closed(before.statuses[key.year]?[key.person]) {
            protectedBefore.statuses[key.year, default: [:]][key.person] = .filed
            protectedAfter.statuses[key.year, default: [:]][key.person] = .filed
        }
        var result = FiledYearImpact.impacts(before: protectedBefore, after: protectedAfter, causes: [])
            .filter { present.contains(YearPerson(year: $0.startYear, person: $0.person)) }
        for (year, people) in before.statuses.sorted(by: { $0.key < $1.key }) {
            for (person, status) in people.sorted(by: { $0.key < $1.key }) where closed(status) {
                let now = after.statuses[year]?[person]
                guard !closed(now) else { continue }
                let line = FiledYearImpact.Line(label: "Status", before: status.displayName, after: now?.displayName ?? "—")
                if let index = result.firstIndex(where: { $0.startYear == year && $0.person == person }) {
                    result[index].returnChanges.insert(line, at: 0)
                } else {
                    result.append(FiledYearImpact(startYear: year, person: person, isPaid: status == .paid, returnChanges: [line],
                                                  informationChanges: [], taxDifferenceMinorUnits: 0, causes: []))
                }
            }
        }
        return result.sorted { ($0.startYear, $0.person) < ($1.startYear, $1.person) }
    }

    private struct YearPerson: Hashable {
        let year: Int
        let person: String
    }

    // MARK: Isolation

    /// What `apply` applied and held.
    struct Outcome {
        /// The translator's results for the changes applied.
        var results: [String: IncomingResult] = [:]
        /// Nil when nothing was held.
        var alert: FiledYearSyncAlert?
    }

    /// Applies incoming changes (`SyncTranslator.apply`; with `flush`, then `SyncBatch.flushClosed`: a pull that
    /// has caught up) so that no protected return moves, inside the caller's transaction:
    /// 1. all of it at once, kept when it moves nothing (the usual case: one apply, one check);
    /// 2. else, in feed order, what moves nothing is kept and each record that moves a figure on top of what is
    ///    kept is found by bisection: the first half is applied and kept when it moves nothing, else rolled
    ///    back and halved again. A record that moves a figure only with what it lets through (staged records it
    ///    unblocks, a batch it completes) applies on its own, and those are tried one by one and held when
    ///    they move one. Every check is against the baseline, so what is kept is verified as a whole;
    /// 3. then staged records and waiting batches are tried one by one (all of them with `retryAll`), and with
    ///    `flush` each closed batch is flushed on its own; what would move a figure is held.
    static func apply(_ changes: [SyncIncomingChange], baseline: FiledYearBaseline, db: Database, deviceUser: String?,
                      now: Date, retryAll: Bool = false, flush: Bool = true) throws -> Outcome {
        func translate(_ subset: some Collection<SyncIncomingChange>, followOns: Bool = true,
                       retryAll: Bool = false) throws -> [String: IncomingResult] {
            subset.isEmpty && !retryAll ? [:]
                : try SyncTranslator.apply(Array(subset), db: db, deviceUser: deviceUser, now: now, retryAll: retryAll, followOns: followOns)
        }
        func flushClosed() throws {
            if flush { _ = try SyncBatch.flushClosed(db: db, deviceUser: deviceUser, now: now) }
        }
        guard !baseline.isEmpty else {
            let results = try translate(changes, retryAll: retryAll)
            try flushClosed()
            return Outcome(results: results)
        }
        // The tables written since the baseline by what is kept (nil: can't tell).
        var written: Set<String>? = []
        /// `body` in a savepoint, kept when nothing protected moves (empty), else rolled back.
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
            results = try translate(changes, retryAll: retryAll)
            try flushClosed()
        }
        guard !whole.isEmpty else { return Outcome(results: results) }
        results = [:]

        var held: [(change: SyncIncomingChange, reason: String)] = []
        var marked: [(row: SyncStagingRow, reason: String)] = []
        var heldRuns: Set<String> = []
        var isolated = 0

        func holdRun(_ run: String) throws {
            heldRuns.insert(run)
            marked += try markHeld(run: run, db: db).map { ($0, heldBatchReason) }
        }

        /// Staged records and waiting batches tried one by one on top of what is kept (until a round applies
        /// nothing more); what moves a figure is held.
        func isolateStaging() throws {
            let order = Dictionary(uniqueKeysWithValues: SyncSchema.tables.enumerated().map { ($1.name, $0) })
            while true {
                var progressed = false
                let rows = try SyncStagingRow.filter(Column("importRunUuid") == nil).fetchAll(db)
                    .filter { !$0.reason.hasPrefix(SyncTranslator.needsAttention) }
                    .sorted { (order[$0.tableName] ?? Int.max, $0.id ?? 0) < (order[$1.tableName] ?? Int.max, $1.id ?? 0) }
                for row in rows {
                    var applied: [String: IncomingResult] = [:]
                    if try attempt({ applied = try SyncTranslator.retryStaged(db: db, deviceUser: deviceUser, now: now, only: [row.uuid]) }).isEmpty {
                        if !applied.isEmpty { progressed = true }
                        results.merge(applied) { _, new in new }
                    } else {
                        log.error("Sync filed-year check: holding a staged record that would change a filed tax year")
                        try db.execute(sql: "UPDATE syncStaging SET reason = ? WHERE id = ?", arguments: [heldReason, row.id])
                        marked.append((row, heldReason))
                        isolated += 1
                    }
                }
                for run in try SyncBatch.waitingRuns(db: db) where try !runIsHeld(run, db: db) {
                    var applied: [String: IncomingResult] = [:]
                    let moved = try attempt {
                        applied = try SyncChangeTracker.applyingIncoming(db: db) {
                            try SyncBatch.flushIfComplete(run: run, db: db, deviceUser: deviceUser, now: now).results
                        }
                    }
                    if moved.isEmpty {
                        if !applied.isEmpty { progressed = true }
                        results.merge(applied) { _, new in new }
                    } else {
                        log.error("Sync filed-year check: holding an import batch that would change a filed tax year")
                        try holdRun(run)
                        isolated += 1
                    }
                }
                if !progressed { return }
            }
        }

        var pending = changes[...]
        var next = pending.startIndex
        /// Applies `range` on top of what is kept, keeping what moves nothing; the index of the record that moves
        /// a figure itself (rolled back), or nil when all of it was kept. `next`: the first index not decided.
        func find(_ range: ArraySlice<SyncIncomingChange>) throws -> Int? {
            var applied: [String: IncomingResult] = [:]
            if range.count == 1 {
                next = range.endIndex
                if try attempt({ applied = try translate(range) }).isEmpty {
                    results.merge(applied) { _, new in new }
                    return nil
                }
                // On its own, without what it lets through: if that moves nothing, the blame is elsewhere.
                if try attempt({ applied = try translate(range, followOns: false) }).isEmpty {
                    results.merge(applied) { _, new in new }
                    try isolateStaging()
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
            if isolated >= maxIsolated {
                // Too many to isolate one by one: the rest waits with them.
                log.error("Sync filed-year check: holding the rest of an apply (\(pending.count) records)")
                for change in pending { held.append((change, heldAlongReason)) }
                break
            }
            next = pending.startIndex
            let offender = try find(pending)
            var rest = Array(pending[next...])
            if let offender {
                log.error("Sync filed-year check: holding a record that would change a filed tax year")
                let change = pending[offender]
                isolated += 1
                if let run = run(of: change) {
                    // All or nothing: the batch waits whole, here and in staging.
                    held.append((change, heldBatchReason))
                    for member in rest where self.run(of: member) == run { held.append((member, heldBatchReason)) }
                    rest = rest.filter { self.run(of: $0) != run }
                    try holdRun(run)
                } else {
                    held.append((change, reason(for: change)))
                }
            }
            pending = rest[...]
        }
        // What the kept records left waiting, or everything staged when asked (`retryAll`), one by one.
        try isolateStaging()
        if flush {
            // Each closed batch flushed on its own (`flushClosed`), held whole when its flush moves a figure.
            for run in try String.fetchAll(db, sql: "SELECT runUuid FROM syncBatch WHERE state = 'closed' ORDER BY runUuid")
            where try !runIsHeld(run, db: db) {
                let moved = try attempt {
                    _ = try SyncChangeTracker.applyingIncoming(db: db) {
                        try SyncBatch.flushIfComplete(run: run, db: db, deviceUser: deviceUser, now: now, force: true)
                    }
                }
                if !moved.isEmpty {
                    log.error("Sync filed-year check: holding an import batch that would change a filed tax year")
                    try holdRun(run)
                }
            }
        }
        try stageHeld(held, db: db, now: now)
        // Members of held batches staged meanwhile are held with them.
        for run in heldRuns.sorted() { marked += try markHeld(run: run, db: db).map { ($0, heldBatchReason) } }
        return Outcome(results: results.filter { name, _ in !held.contains { $0.change.recordName == name } },
                       alert: try alert(held, marked: marked, impacts: whole, db: db))
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
                       arguments: [heldBatchReason, run, SyncTranslator.needsAttention + "%"])
        return rows
    }

    /// Whether a batch waits held (one of its staged records is): `SyncBatch` never applies it.
    static func runIsHeld(_ run: String, db: Database) throws -> Bool {
        try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM syncStaging WHERE importRunUuid = ? AND reason IN (?, ?, ?, ?))",
                          arguments: StatementArguments([run] + heldReasons)) ?? false
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

    private static func alert(_ held: [(change: SyncIncomingChange, reason: String)], marked: [(row: SyncStagingRow, reason: String)],
                              impacts: [FiledYearImpact], db: Database) throws -> FiledYearSyncAlert? {
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
        var named = Set(records.map(\.recordName))
        for (row, reason) in marked where !named.contains(row.uuid) {
            named.insert(row.uuid)
            let payload = try? JSONDecoder().decode(SyncPayload.self, from: Data(row.payloadJSON.utf8))
            records.append(FiledYearSyncAlert.Record(recordType: row.tableName, recordName: row.uuid, isDelete: false, writer: payload?.modifiedBy,
                                                     writerName: try writerName(payload?.modifiedBy, db: db), reason: reason))
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
        try SyncStagingRow.fetchAll(db, sql: "SELECT * FROM syncStaging WHERE reason IN (?, ?, ?, ?) ORDER BY id",
                                    arguments: StatementArguments(heldReasons))
    }
}
