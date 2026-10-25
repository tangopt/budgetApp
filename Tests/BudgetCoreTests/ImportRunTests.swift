import XCTest
import GRDB
@testable import BudgetCore
import TestSupport

final class ImportRunTests: XCTestCase {
    func testMigrationCreatesRunTablesAndBatchColumn() throws {
        let m = try DatabaseManager(path: nil); try m.migrate()
        try m.dbQueue.read { db in
            XCTAssertTrue(try db.tableExists("importRun"))
            XCTAssertTrue(try db.tableExists("importChange"))
            XCTAssertTrue(try db.tableExists("importRunFile"))
            XCTAssertTrue(try db.columns(in: "importBatch").contains { $0.name == "importRunId" })
        }
    }

    func testRunFileAndChangeRoundTrip() throws {
        let m = try TestDatabase.migratedManager()
        try m.dbQueue.write { db in
            var run = ImportRun(confirmedAt: Date(), entryPoint: "Import…", summary: "1 document filed")
            try run.insert(db)
            var file = ImportRunFile(runId: run.id!, fileName: "a.pdf", sha256: "ab", documentId: nil, outcome: .filed, detail: "Filed as …")
            try file.insert(db)
            var change = ImportChange(runId: run.id!, seq: 1, tableName: "document", rowId: 7, operation: .insert, beforeJSON: nil, afterJSON: "{}")
            try change.insert(db)
            let r = try XCTUnwrap(try ImportRun.fetchOne(db, key: run.id!))
            XCTAssertEqual(r.entryPoint, "Import…")
            XCTAssertNil(r.undoneAt)
            let f = try XCTUnwrap(try ImportRunFile.fetchOne(db, key: file.id!))
            XCTAssertEqual(f.outcome, .filed)
            let c = try XCTUnwrap(try ImportChange.fetchOne(db, key: change.id!))
            XCTAssertEqual(c.operation, .insert)
            XCTAssertEqual(c.rowId, 7)
        }
    }

    func testExistingBatchesKeepNilRunId() throws {
        let m = try DatabaseManager(path: nil)
        try m.migrate(upTo: "taxPolicyReceiptItems")
        try m.dbQueue.write { db in
            var account = Account(name: "A", currency: .gbp, kind: .cash, trackingMode: .imported)
            try account.insert(db)
            try db.execute(sql: "INSERT INTO importBatch (accountId, sourceFileName, importedAt) VALUES (?, 'old.csv', ?)",
                           arguments: [account.id!, Date()])
        }
        try m.migrate()
        try m.dbQueue.read { db in
            let batch = try XCTUnwrap(try ImportBatch.fetchOne(db))
            XCTAssertNil(batch.importRunId)
        }
    }
}
