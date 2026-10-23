import XCTest
import GRDB
@testable import BudgetCore

/// Timings of change tracking (step 3 task 2, ruling R5): backfilling 20,000 rows and a 2,000-row
/// captured import, with the tracking triggers and without them. Skipped unless `SYNC_PERF=1`.
final class SyncTrackingPerformanceTests: XCTestCase {
    private static let runs = 5

    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["SYNC_PERF"] == "1", "set SYNC_PERF=1 to time sync tracking")
    }

    private func median(_ values: [TimeInterval]) -> TimeInterval { values.sorted()[values.count / 2] }

    private func time(_ body: () throws -> Void) rethrows -> TimeInterval {
        let start = Date()
        try body()
        return Date().timeIntervalSince(start)
    }

    private func dropTriggers(_ db: Database) throws {
        for name in try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'trigger' AND name LIKE 'syncTrack\\_%' ESCAPE '\\'") {
            try db.execute(sql: "DROP TRIGGER \"\(name)\"")
        }
    }

    private func insertTransactions(_ db: Database, count: Int, accountId: Int64, batchId: Int64) throws {
        let date = MonthRange.calendar.date(from: DateComponents(year: 2026, month: 3, day: 4))!
        for index in 0..<count {
            var t = Transaction(importBatchId: batchId, accountId: accountId, date: date, rawDescription: "SYNTHETIC \(index)",
                                amountMinorUnits: -100 - index, categoryId: nil, status: .pendingReview, categorizedBy: .none,
                                fingerprint: UUID().uuidString)
            try t.insert(db)
        }
    }

    private func accountAndBatch(_ db: Database) throws -> (Int64, Int64) {
        var account = Account(name: "Synthetic \(UUID().uuidString.prefix(6))", currency: .gbp, kind: .cash, trackingMode: .imported)
        try account.insert(db)
        var batch = ImportBatch(accountId: account.id!, sourceFileName: "x.csv", importedAt: Date())
        try batch.insert(db)
        return (account.id!, batch.id!)
    }

    func testBackfillTiming() throws {
        var timings: [TimeInterval] = []
        var assigned = 0
        for _ in 0..<Self.runs {
            let manager = try DatabaseManager(path: nil)
            try manager.migrate(upTo: "createAppUser")
            try manager.dbQueue.write { db in
                let (account, batch) = try accountAndBatch(db)
                try insertTransactions(db, count: 20_000, accountId: account, batchId: batch)
            }
            try manager.migrate()
            timings.append(try time { assigned = try manager.dbQueue.write { db in try SyncRecordStore.backfill(db: db) } })
        }
        print("SYNC_PERF backfill rows=\(assigned) median=\(String(format: "%.3f", median(timings)))s runs=\(timings.map { String(format: "%.3f", $0) })")
    }

    func testImportTiming() throws {
        for tracked in [false, true] {
            var timings: [TimeInterval] = []
            for _ in 0..<Self.runs {
                let manager = try DatabaseManager(path: nil)
                try manager.migrate()
                let (account, batch) = try manager.dbQueue.write { db -> (Int64, Int64) in
                    if !tracked { try dropTriggers(db) }
                    let ids = try accountAndBatch(db)
                    try insertTransactions(db, count: 20_000, accountId: ids.0, batchId: ids.1)
                    return ids
                }
                timings.append(try time {
                    try manager.dbQueue.write { db in
                        var run = ImportRun(confirmedAt: Date(), entryPoint: "Import…", summary: "s")
                        try run.insert(db)
                        try ImportChangeCapture.begin(db: db)
                        try insertTransactions(db, count: 2_000, accountId: account, batchId: batch)
                        _ = try ImportChangeCapture.finish(db: db, runId: run.id!)
                    }
                })
            }
            print("SYNC_PERF import2000 tracked=\(tracked) median=\(String(format: "%.3f", median(timings)))s runs=\(timings.map { String(format: "%.3f", $0) })")
        }
    }

    func testOpenTiming() throws {
        var fresh: [TimeInterval] = []
        var reopen: [TimeInterval] = []
        for _ in 0..<Self.runs {
            let manager = try DatabaseManager(path: nil)
            fresh.append(try time { try manager.migrate() })
            try manager.dbQueue.write { db in
                let (account, batch) = try accountAndBatch(db)
                try insertTransactions(db, count: 20_000, accountId: account, batchId: batch)
            }
            reopen.append(try time { try manager.migrate() })
        }
        print("SYNC_PERF migrateFresh median=\(String(format: "%.3f", median(fresh)))s reopenWith20000=\(String(format: "%.3f", median(reopen)))s")
    }
}
