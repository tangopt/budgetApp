import XCTest
import GRDB
@testable import BudgetCore
@testable import BudgetDemo

/// Timings of the post-sync filed-year check (step 3 Task 6) on the demo database (2023/24 paid, 2024/25
/// filed): a pull of 1,000 changed records applied without the check, with it (nothing held), and with one
/// record among them that moves a filed figure (isolated by bisection). Skipped unless `SYNC_PERF=1`.
final class FiledYearSyncCheckPerformanceTests: XCTestCase {
    private static let runs = 3

    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["SYNC_PERF"] == "1", "set SYNC_PERF=1 to time the filed-year check")
    }

    private func median(_ values: [TimeInterval]) -> TimeInterval { values.sorted()[values.count / 2] }

    private func time<T>(_ body: () throws -> T) rethrows -> (T, TimeInterval) {
        let start = Date()
        let value = try body()
        return (value, Date().timeIntervalSince(start))
    }

    private func unfetched(_ device: SyncEngineTestDevice, cloud: FakeCloud) async throws -> [SyncIncomingChange] {
        var token = try device.read { db in try SyncEngineCore.token(zone: SyncRecordStore.householdZone, db: db) }
        var changes: [SyncIncomingChange] = []
        while true {
            let page = try await cloud.changes(since: token, zone: SyncRecordStore.householdZone)
            for change in page.changes {
                switch change {
                case .record(let record):
                    guard !SyncEngineCore.reservedRecordTypes.contains(record.wire.recordType) else { continue }
                    changes.append(.save(try SyncLargePayload.payload(from: record.wire, keys: try device.keys.allKeys(zone: record.wire.zone))))
                case .deletion(let deletion):
                    changes.append(.delete(recordName: deletion.recordName, recordType: deletion.recordType))
                }
            }
            token = page.token
            if !page.moreComing { return changes }
        }
    }

    private func format(_ values: [TimeInterval]) -> String {
        "median=\(String(format: "%.3f", median(values)))s runs=\(values.map { String(format: "%.3f", $0) })"
    }

    func testCheckCostOnAThousandRecordPullOfTheDemoDatabase() async throws {
        let cloud = FakeCloud()
        let keys = InMemorySyncKeyStore()
        let a = try SyncEngineTestDevice("user-a", name: "Mac", cloud: cloud, keys: keys)
        let b = try SyncEngineTestDevice("user-b", name: "iPad", cloud: cloud, keys: keys)
        let evidence = FileManager.default.temporaryDirectory.appendingPathComponent("SyncFiledDemo-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: evidence) }
        try DemoDatabase.build(dbQueue: a.queue, evidenceRoot: evidence)
        try a.write { db in _ = try SyncRecordStore.backfill(db: db) }
        try await a.engine.syncNow()
        let (_, firstPull) = try await { () async throws -> (SyncPullReport, TimeInterval) in
            let start = Date()
            let report = try await b.engine.pull()
            return (report, Date().timeIntervalSince(start))
        }()
        let filedYears = try b.read { db in try FiledYearGuard.filedYears(db: db) }
        XCTAssertFalse(filedYears.isEmpty, "the demo has filed years")

        // 1,000 records changed on A: notes on transactions, every year (a note moves no figure).
        let ids = try a.read { db in try Int64.fetchAll(db, sql: "SELECT id FROM transaction_ ORDER BY id LIMIT 1000") }
        XCTAssertEqual(ids.count, 1000, "the demo has 1,000 transactions")
        // One that would move the filed 2024/25 return: a property-category row of that year.
        let offender = try a.write { db -> Int64? in
            let candidates = try Int64.fetchAll(db, sql: """
                SELECT t.id FROM transaction_ t JOIN taxExpenseTypeMap m ON m.categoryId = t.categoryId
                WHERE t.date >= '2024-04-06' AND t.date < '2025-04-06' ORDER BY t.id LIMIT 200
                """)
            for id in candidates {
                var moves = false
                try db.inSavepoint {
                    let raw = try TaxFigures.snapshot(db: db)
                    try db.execute(sql: "UPDATE transaction_ SET amountMinorUnits = amountMinorUnits - 12345 WHERE id = ?", arguments: [id])
                    moves = try !FiledYearGuard.filedChanges(db: db, from: raw).isEmpty
                    return .rollback
                }
                if moves { return id }
            }
            return nil
        }
        let offenderId = try XCTUnwrap(offender)
        try a.write { db in
            for id in ids where id != offenderId {
                try db.execute(sql: "UPDATE transaction_ SET note = 'Synced note' WHERE id = ?", arguments: [id])
            }
        }
        try await a.engine.syncNow()
        let notes = try await unfetched(b, cloud: cloud)
        try a.write { db in
            try db.execute(sql: "UPDATE transaction_ SET amountMinorUnits = amountMinorUnits - 12345 WHERE id = ?", arguments: [offenderId])
        }
        try await a.engine.syncNow()
        let withOffender = try await unfetched(b, cloud: cloud)
        let offenderUuid = try a.uuid("transaction_", offenderId)
        XCTAssertEqual(withOffender.count, notes.count + 1)
        let user = b.user
        let now = Date()

        func applyPull(_ db: Database) -> ([SyncIncomingChange]) throws -> [String: IncomingResult] {
            { changes in
                let results = try SyncTranslator.apply(changes, db: db, deviceUser: user, now: now)
                _ = try SyncBatch.flushClosed(db: db, deviceUser: user, now: now)
                return results
            }
        }

        var raw: [TimeInterval] = [], baselines: [TimeInterval] = [], checked: [TimeInterval] = [], isolated: [TimeInterval] = []
        var heldNames: [String] = []
        for _ in 0..<Self.runs {
            try b.write { db in
                try db.inSavepoint {
                    raw.append(try time { try applyPull(db)(withOffender) }.1)
                    return .rollback
                }
                try db.inSavepoint {
                    let (baseline, taken) = try time { try FiledYearSyncCheck.baseline(db: db) }
                    baselines.append(taken)
                    let (outcome, spent) = try time { try FiledYearSyncCheck.apply(notes, baseline: baseline, db: db, deviceUser: user, now: now) }
                    XCTAssertNil(outcome.alert)
                    checked.append(taken + spent)
                    return .rollback
                }
                try db.inSavepoint {
                    let (outcome, spent) = try time {
                        try FiledYearSyncCheck.apply(withOffender, baseline: try FiledYearSyncCheck.baseline(db: db), db: db,
                                                     deviceUser: user, now: now)
                    }
                    heldNames = outcome.alert?.records.map(\.recordName) ?? []
                    isolated.append(spent)
                    return .rollback
                }
            }
        }
        XCTAssertEqual(heldNames, [offenderUuid], "only the offender is held")
        // With a ValueObservation active on the database (as in the app): GRDB's hook can hide written tables
        // (`TaxFiguresReads.writtenTables` nil), and every recorded statement is replayed.
        let observation = ValueObservation.tracking { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM transaction_ WHERE note IS NOT NULL") ?? 0 }
        let cancellable = observation.start(in: b.queue, scheduling: .async(onQueue: DispatchQueue(label: "perf-observation")),
                                            onError: { _ in }, onChange: { _ in })
        defer { cancellable.cancel() }
        var observed: [TimeInterval] = [], observedIsolated: [TimeInterval] = []
        for _ in 0..<Self.runs {
            try b.write { db in
                try db.inSavepoint {
                    let (outcome, spent) = try time {
                        try FiledYearSyncCheck.apply(notes, baseline: try FiledYearSyncCheck.baseline(db: db), db: db, deviceUser: user, now: now)
                    }
                    XCTAssertNil(outcome.alert)
                    observed.append(spent)
                    return .rollback
                }
                try db.inSavepoint {
                    let (outcome, spent) = try time {
                        try FiledYearSyncCheck.apply(withOffender, baseline: try FiledYearSyncCheck.baseline(db: db), db: db,
                                                     deviceUser: user, now: now)
                    }
                    XCTAssertEqual(outcome.alert?.records.map(\.recordName), [offenderUuid])
                    observedIsolated.append(spent)
                    return .rollback
                }
            }
        }
        // And the real thing, end to end.
        let start = Date()
        let report = try await b.engine.pull()
        let engine = Date().timeIntervalSince(start)
        XCTAssertEqual(report.filedYearAlert?.records.map(\.recordName), [offenderUuid])
        print("SYNC_PERF filed-year check: first pull onto an empty device (checked, nothing protected there yet) \(String(format: "%.3f", firstPull))s; "
              + "pull of \(withOffender.count) records, filed years \(filedYears.sorted())")
        print("SYNC_PERF   apply without check \(format(raw))")
        print("SYNC_PERF   baseline \(format(baselines))")
        print("SYNC_PERF   checked apply incl. baseline, nothing held (\(notes.count) records) \(format(checked))")
        print("SYNC_PERF   checked apply incl. baseline, one offender isolated \(format(isolated))")
        print("SYNC_PERF   with a ValueObservation active: checked apply incl. baseline, nothing held \(format(observed)); one offender \(format(observedIsolated))")
        print("SYNC_PERF   engine pull end to end, one offender \(String(format: "%.3f", engine))s")
    }
}
