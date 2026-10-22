import XCTest
import GRDB
@testable import BudgetCore

final class AuthModelTests: XCTestCase {
    private func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }

    func testPBKDF2KnownVector() {
        let derived = PasswordHasher.pbkdf2(password: "password", salt: Data("salt".utf8), rounds: 1)
        XCTAssertEqual(hex(derived), "120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b")
    }

    func testHashRoundTripAndFormat() {
        let first = PasswordHasher.hash("correct horse battery")
        let second = PasswordHasher.hash("correct horse battery")
        XCTAssertTrue(first.hasPrefix("pbkdf2-sha256$600000$"))
        XCTAssertEqual(first.split(separator: "$").count, 4)
        XCTAssertTrue(PasswordHasher.verify("correct horse battery", against: first))
        XCTAssertFalse(PasswordHasher.verify("correct horse batterz", against: first))
        XCTAssertFalse(PasswordHasher.verify("anything", against: "not-a-hash"))
        XCTAssertNotEqual(first, second)
    }

    func testNeedsRehashBelowCurrentRounds() {
        XCTAssertTrue(PasswordHasher.needsRehash(PasswordHasher.hash("a long password", rounds: 1_000)))
        XCTAssertFalse(PasswordHasher.needsRehash(PasswordHasher.hash("a long password")))
        XCTAssertTrue(PasswordHasher.needsRehash("garbage"))
    }

    func testRecoveryKeyShapeAndNormalise() {
        let alphabet = Set("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        let key = RecoveryKey.generate()
        XCTAssertEqual(key.count, 24)
        XCTAssertTrue(key.allSatisfy { alphabet.contains($0) })
        let formatted = RecoveryKey.formatted(key)
        XCTAssertEqual(formatted.split(separator: "-").count, 6)
        XCTAssertTrue(formatted.split(separator: "-").allSatisfy { $0.count == 4 })
        let sloppy = formatted.lowercased().replacingOccurrences(of: "-", with: " ")
        XCTAssertEqual(RecoveryKey.normalised(sloppy), key)
        XCTAssertNil(RecoveryKey.normalised("O000" + String(key.dropFirst(4))))
        XCTAssertNil(RecoveryKey.normalised(String(key.dropLast())))
    }

    func testMalformedHashesAreRejectedWithoutCrashing() {
        let good = PasswordHasher.hash("a long password", rounds: 1_000)
        let tail = good.split(separator: "$").dropFirst(2).joined(separator: "$")
        for bad in ["pbkdf2-sha256$99999999999$\(tail)", "pbkdf2-sha256$0$\(tail)", "pbkdf2-sha256$-5$\(tail)",
                    "pbkdf2-sha512$1000$\(tail)", "pbkdf2-sha256$1000$AAAA", "pbkdf2-sha256$1000$!!!$!!!", ""] {
            XCTAssertFalse(PasswordHasher.verify("a long password", against: bad), bad)
            XCTAssertTrue(PasswordHasher.needsRehash(bad), bad)
        }
    }

    func testEmptyPasswordDoesNotCrash() {
        XCTAssertFalse(PasswordHasher.verify("", against: PasswordHasher.hash("a long password", rounds: 1_000)))
        XCTAssertTrue(PasswordHasher.verify("", against: PasswordHasher.hash("", rounds: 1_000)))
    }

    func testRecoveryKeyNormalisedStripsAllWhitespace() {
        let key = RecoveryKey.generate()
        XCTAssertEqual(RecoveryKey.normalised(" " + RecoveryKey.formatted(key) + "\n"), key)
        XCTAssertEqual(RecoveryKey.normalised("\t" + key.lowercased() + "\r\n"), key)
    }

    func testMigrationAddsTablesAndLeavesRowsUnchanged() throws {
        let manager = try DatabaseManager(path: nil)
        try manager.migrate(upTo: "createImportRule")
        try manager.dbQueue.write { db in
            try db.execute(sql: "INSERT INTO person (id, name) VALUES (1, 'Sample Person')")
            try db.execute(sql: """
                INSERT INTO importRun (id, confirmedAt, entryPoint, summary) VALUES (1, '2026-01-02 03:04:05.000', 'folder', 'Imported 3 files')
                """)
            try db.execute(sql: """
                INSERT INTO importRule (id, kind, matchKey, matchLabel, actionJSON, actionLabel, isEnabled, createdAt, useCount)
                VALUES (1, 'issuer', 'acme', 'Acme', '{}', 'Name: Acme', 1, '2026-01-02 03:04:05.000', 2)
                """)
        }
        let oldRun = try manager.dbQueue.read { try Row.fetchOne($0, sql: "SELECT * FROM importRun")! }
        let oldRule = try manager.dbQueue.read { try Row.fetchOne($0, sql: "SELECT * FROM importRule")! }
        try manager.migrate()
        try manager.dbQueue.read { db in
            let run = try Row.fetchOne(db, sql: "SELECT * FROM importRun")!
            for column in oldRun.columnNames { XCTAssertEqual(run[column] as DatabaseValue, oldRun[column] as DatabaseValue, column) }
            XCTAssertTrue((run["appUserId"] as DatabaseValue).isNull)
            let rule = try Row.fetchOne(db, sql: "SELECT * FROM importRule")!
            for column in oldRule.columnNames { XCTAssertEqual(rule[column] as DatabaseValue, oldRule[column] as DatabaseValue, column) }
            XCTAssertTrue((rule["createdByAppUserId"] as DatabaseValue).isNull)
            XCTAssertTrue((rule["lastLearntByAppUserId"] as DatabaseValue).isNull)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM appUser"), 0)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM localCredential"), 0)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM person"), 1)
        }
    }

    func testPersonDeleteRestrictedWhileAppUserExists() throws {
        let manager = try DatabaseManager(path: nil)
        try manager.migrate()
        try manager.dbQueue.write { db in
            try db.execute(sql: "INSERT INTO person (id, name) VALUES (1, 'Sample Person')")
            var user = AppUser(personId: 1, displayName: "Sample", isAdmin: true, createdAt: Date())
            try user.insert(db)
            XCTAssertNotNil(user.id)
            try LocalCredential(appUserId: user.id!, passwordHash: "h1", recoveryKeyHash: "h2").insert(db)
            XCTAssertThrowsError(try db.execute(sql: "DELETE FROM person WHERE id = 1"))
            // Deleting the app user cascades to its credential, and the person can then go.
            try db.execute(sql: "DELETE FROM appUser WHERE id = ?", arguments: [user.id])
            XCTAssertEqual(try LocalCredential.fetchCount(db), 0)
            try db.execute(sql: "DELETE FROM person WHERE id = 1")
        }
    }

    func testAttributionColumnsRoundTripAndSetNullOnUserDelete() throws {
        let manager = try DatabaseManager(path: nil)
        try manager.migrate()
        try manager.dbQueue.write { db in
            try db.execute(sql: "INSERT INTO person (id, name) VALUES (1, 'Sample Person')")
            var user = AppUser(personId: 1, displayName: "Sample", createdAt: Date())
            try user.insert(db)
            var run = ImportRun(confirmedAt: Date(), entryPoint: "folder", summary: "s", appUserId: user.id)
            try run.insert(db)
            var rule = ImportRule(kind: .issuer, matchKey: "k", matchLabel: "l", actionJSON: "{}", actionLabel: "a",
                                  createdAt: Date(), createdByAppUserId: user.id, lastLearntByAppUserId: user.id)
            try rule.insert(db)
            XCTAssertEqual(try ImportRun.fetchOne(db, key: run.id!)?.appUserId, user.id)
            XCTAssertEqual(try ImportRule.fetchOne(db, key: rule.id!)?.createdByAppUserId, user.id)
            try db.execute(sql: "DELETE FROM appUser WHERE id = ?", arguments: [user.id])
            XCTAssertNil(try ImportRun.fetchOne(db, key: run.id!)?.appUserId)
            XCTAssertNil(try ImportRule.fetchOne(db, key: rule.id!)?.lastLearntByAppUserId)
        }
    }
}
