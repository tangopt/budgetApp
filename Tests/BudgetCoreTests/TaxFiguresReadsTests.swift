import XCTest
import GRDB
@testable import BudgetCore

/// `TaxFiguresReads`: what a figures snapshot read, replayed to show a later state reads the
/// same (the filed-year guard's shortcut), and the tables a change wrote.
final class TaxFiguresReadsTests: XCTestCase {
    private var queue: DatabaseQueue!

    override func setUpWithError() throws {
        queue = try DatabaseQueue()
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE item (id INTEGER PRIMARY KEY, name TEXT, amount INTEGER);
                CREATE TABLE other (id INTEGER PRIMARY KEY, note TEXT);
                INSERT INTO item (name, amount) VALUES ('a', 1), ('b', 2);
                INSERT INTO other (note) VALUES ('x');
                """)
        }
    }

    func testRealLiteralsOutsideQuotesAreFound() {
        XCTAssertTrue(TaxFiguresReads.hasRealLiteral("SELECT * FROM item WHERE amount > 1.5"))
        XCTAssertTrue(TaxFiguresReads.hasRealLiteral("SELECT * FROM item WHERE amount > 1e10"))
        XCTAssertTrue(TaxFiguresReads.hasRealLiteral("SELECT * FROM item WHERE amount > .5"))
        XCTAssertFalse(TaxFiguresReads.hasRealLiteral("SELECT * FROM item WHERE amount > 15 AND id IN (1,2)"))
        XCTAssertFalse(TaxFiguresReads.hasRealLiteral("SELECT * FROM item WHERE name = '1.5' AND note = 'it''s 2.5'"))
        XCTAssertFalse(TaxFiguresReads.hasRealLiteral("SELECT t1.amount, \"col.1\", [x.2] FROM item t1 WHERE t1.id = 0x1E"))
    }

    func testAStatementWhoseRowsChangedIsChanged() throws {
        try queue.write { db in
            var reads = TaxFiguresReads()
            let (sum, read) = try reads.record(db: db) {
                try Int.fetchOne(db, sql: "SELECT SUM(amount) FROM item WHERE name <> ?", arguments: ["z"])
            }
            XCTAssertEqual(sum, 3)
            XCTAssertEqual(read, [0])
            XCTAssertEqual(reads.changed(), [])
            try db.execute(sql: "UPDATE item SET amount = 5 WHERE name = 'a'")
            XCTAssertEqual(reads.changed(), [0])
            try db.execute(sql: "UPDATE item SET amount = 1 WHERE name = 'a'")
            XCTAssertEqual(reads.changed(), [])
        }
    }

    func testOnlyStatementsReadingAWrittenTableAreReplayed() throws {
        try queue.write { db in
            var reads = TaxFiguresReads()
            _ = try reads.record(db: db) {
                _ = try Row.fetchAll(db, sql: "SELECT * FROM item")
                _ = try Row.fetchAll(db, sql: "SELECT * FROM other")
            }
            let written = try TaxFiguresReads.writtenTables(db: db) {
                try db.execute(sql: "INSERT INTO other (note) VALUES ('y')")
            }
            XCTAssertEqual(written, ["other"])
            XCTAssertEqual(reads.changed(written: written), [1])
            XCTAssertEqual(reads.changed(), [1])
        }
    }

    func testARecordingWithARealArgumentCantVouch() throws {
        try queue.write { db in
            var reads = TaxFiguresReads()
            let (_, read) = try reads.record(db: db) {
                try Row.fetchAll(db, sql: "SELECT * FROM item WHERE amount > ?", arguments: [0.5])
            }
            XCTAssertNil(read)
        }
    }

    func testAWritingStatementCantBeReplayed() throws {
        try queue.write { db in
            var reads = TaxFiguresReads()
            let (_, read) = try reads.record(db: db) { try db.execute(sql: "UPDATE item SET amount = amount WHERE id = 1") }
            XCTAssertNil(read)
        }
    }

    func testWritesSQLiteDoesntReportCantBeTold() throws {
        try queue.write { db in
            // A table emptied at once (no WHERE, no trigger) isn't reported row by row.
            XCTAssertNil(try TaxFiguresReads.writtenTables(db: db) { try db.execute(sql: "DELETE FROM other") })
            // A schema change isn't a row written.
            XCTAssertNil(try TaxFiguresReads.writtenTables(db: db) { try db.execute(sql: "CREATE TABLE extra (id INTEGER PRIMARY KEY)") })
            XCTAssertEqual(try TaxFiguresReads.writtenTables(db: db) { try db.execute(sql: "DELETE FROM item WHERE id = 1") }, ["item"])
            XCTAssertEqual(try TaxFiguresReads.writtenTables(db: db) {}, [])
        }
    }

    func testWritesInsideARolledBackSavepointAreReported() throws {
        try queue.write { db in
            var written: Set<String>?
            try db.inSavepoint {
                written = try TaxFiguresReads.writtenTables(db: db) {
                    try db.execute(sql: "INSERT INTO item (name, amount) VALUES ('c', 3)")
                }
                return .rollback
            }
            XCTAssertEqual(written, ["item"])
        }
    }
}
