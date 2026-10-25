import XCTest
import GRDB
@testable import BudgetCore
import TestSupport

final class ImportChangeCaptureTests: XCTestCase {
    private func manager() throws -> DatabaseManager {
        try TestDatabase.migratedManager()
    }

    func testCapturesInsertUpdateDeleteWithBeforeAndAfter() throws {
        let m = try manager()
        let changes = try m.dbQueue.write { db -> [ImportChange] in
            var cat0 = Category(name: "Existing", type: .expense); try cat0.insert(db)
            var rule = Rule(matchPattern: "ACME", matchType: .contains, categoryId: cat0.id!, priority: 1); try rule.insert(db)
            var run = ImportRun(confirmedAt: Date(), entryPoint: "Import…", summary: "s"); try run.insert(db)
            try ImportChangeCapture.begin(db: db)
            var cat = Category(name: "Cap", type: .expense); try cat.insert(db)
            cat.name = "Cap 2"; try cat.update(db)
            try rule.delete(db)
            return try ImportChangeCapture.finish(db: db, runId: run.id!)
        }
        XCTAssertEqual(changes.map(\.operation), [.insert, .update, .delete])
        XCTAssertNil(changes[0].beforeJSON)
        XCTAssertTrue(changes[0].afterJSON!.contains("\"name\":\"Cap\""))
        XCTAssertTrue(changes[1].beforeJSON!.contains("\"name\":\"Cap\""))
        XCTAssertTrue(changes[1].afterJSON!.contains("\"name\":\"Cap 2\""))
        XCTAssertTrue(changes[2].beforeJSON!.contains("ACME"))
        XCTAssertNil(changes[2].afterJSON)
        XCTAssertEqual(changes.map(\.seq), changes.map(\.seq).sorted())
        let stored = try m.dbQueue.read { try ImportChange.fetchCount($0) }
        XCTAssertEqual(stored, 3)
    }

    func testUntrackedTablesAreNotCaptured() throws {
        let m = try manager()
        try m.dbQueue.write { db in try CategorySeeder.seedDefaults(db) }
        try m.dbQueue.write { db in
            var account = Account(name: "A", currency: .gbp, kind: .cash, trackingMode: .imported); try account.insert(db)
            var batch = ImportBatch(accountId: account.id!, sourceFileName: "x.csv", importedAt: Date()); try batch.insert(db)
            let income = try Category.filter(Column("name") == "Income").fetchOne(db)!.id!
            var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
            for (i, month) in [4, 5, 6].enumerated() {
                let d = cal.date(from: DateComponents(year: 2026, month: month, day: 26))!
                var t = Transaction(importBatchId: batch.id!, accountId: account.id!, date: d, rawDescription: "T", amountMinorUnits: 280000, categoryId: income, status: .confirmed, categorizedBy: .manual, fingerprint: "f\(i)")
                try t.insert(db)
            }
        }
        let (changes, forecastRows) = try m.dbQueue.write { db -> ([ImportChange], Int) in
            var run = ImportRun(confirmedAt: Date(), entryPoint: "Import…", summary: "s"); try run.insert(db)
            try ImportChangeCapture.begin(db: db)
            try AutoForecastGenerator.refresh(db: db)
            return (try ImportChangeCapture.finish(db: db, runId: run.id!), try ForecastEntry.fetchCount(db))
        }
        XCTAssertGreaterThan(forecastRows, 0)
        XCTAssertTrue(changes.allSatisfy { !["forecastEntry", "forecastGroup"].contains($0.tableName) })
    }

    func testBlobColumnsAreHexEncoded() throws {
        let m = try manager()
        let change = try m.dbQueue.write { db -> ImportChange in
            var run = ImportRun(confirmedAt: Date(), entryPoint: "Import…", summary: "s"); try run.insert(db)
            try ImportChangeCapture.begin(db: db)
            var folder = SourceFolder(path: "/x", bookmark: Data([0xde, 0xad]), name: "x"); try folder.insert(db)
            let changes = try ImportChangeCapture.finish(db: db, runId: run.id!)
            XCTAssertEqual(try ImportChangeCapture.blobColumns(db: db, table: "sourceFolder"), ["bookmark"])
            XCTAssertEqual(try ImportChangeCapture.rowJSON(db: db, table: "sourceFolder", rowId: folder.id!), changes[0].afterJSON)
            return changes[0]
        }
        XCTAssertTrue(change.afterJSON!.contains("\"bookmark\":\"DEAD\""))
    }

    func testFinishRemovesTriggersAndLaterWritesAreNotCaptured() throws {
        let m = try manager()
        try m.dbQueue.write { db in
            var run = ImportRun(confirmedAt: Date(), entryPoint: "Import…", summary: "s"); try run.insert(db)
            try ImportChangeCapture.begin(db: db)
            _ = try ImportChangeCapture.finish(db: db, runId: run.id!)
            let before = try ImportChange.fetchCount(db)
            var cat = Category(name: "Later", type: .expense); try cat.insert(db)
            XCTAssertEqual(try ImportChange.fetchCount(db), before)
            let n = try Int.fetchOne(db, sql: "SELECT count(*) FROM sqlite_temp_master WHERE name LIKE 'importCapture%'")
            XCTAssertEqual(n, 0)
        }
    }

    func testCancelWritesNothing() throws {
        let m = try manager()
        try m.dbQueue.write { db in
            try ImportChangeCapture.begin(db: db)
            var cat = Category(name: "X", type: .expense); try cat.insert(db)
            try ImportChangeCapture.cancel(db: db)
            XCTAssertEqual(try ImportChange.fetchCount(db), 0)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM sqlite_temp_master WHERE name LIKE 'importCapture%'"), 0)
        }
    }
}
