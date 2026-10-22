import XCTest
import GRDB
@testable import BudgetCore

final class MigrationBackupTests: XCTestCase {
    private var dir: URL!
    private var dbPath: String { dir.appendingPathComponent("budget.sqlite").path }

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("migration-backup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
        try? FileManager.default.removeItem(at: dir)
    }

    private func backups() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasPrefix(MigrationBackup.fileNamePrefix) }.sorted()
    }

    func testBacksUpOnlyWhenMigrationsPending() throws {
        let manager = try DatabaseManager(path: dbPath)
        try manager.migrate(upTo: "createPayMonthClose")
        let before = try manager.dbQueue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM account") }
        let url = try XCTUnwrap(try MigrationBackup.backUpIfNeeded(manager: manager, databasePath: dbPath, now: Date()))
        XCTAssertTrue(url.lastPathComponent.hasPrefix(MigrationBackup.fileNamePrefix))
        let copy = try DatabaseQueue(path: url.path)
        let after = try copy.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM account") }
        XCTAssertEqual(before, after)

        try manager.migrate()
        XCTAssertNil(try MigrationBackup.backUpIfNeeded(manager: manager, databasePath: dbPath, now: Date()))
    }

    func testKeepsNewestFive() throws {
        let manager = try DatabaseManager(path: dbPath)
        try manager.migrate(upTo: "createPayMonthClose")
        for day in 1...7 {
            let name = MigrationBackup.fileNamePrefix + String(format: "202601%02d-120000", day)
            try Data("x".utf8).write(to: dir.appendingPathComponent(name))
        }
        let other = dir.appendingPathComponent("budget.sqlite.pre-simar-totals-backup-20200101-000000")
        try Data("x".utf8).write(to: other)
        var parts = DateComponents(); parts.year = 2026; parts.month = 3; parts.day = 1; parts.hour = 9
        let now = Calendar(identifier: .gregorian).date(from: parts)!
        let url = try XCTUnwrap(try MigrationBackup.backUpIfNeeded(manager: manager, databasePath: dbPath, now: now))
        let kept = try backups()
        XCTAssertEqual(kept.count, 5)
        XCTAssertTrue(kept.contains(url.lastPathComponent))
        XCTAssertFalse(kept.contains(MigrationBackup.fileNamePrefix + "20260101-120000"))
        XCTAssertFalse(kept.contains(MigrationBackup.fileNamePrefix + "20260102-120000"))
        XCTAssertTrue(kept.contains(MigrationBackup.fileNamePrefix + "20260107-120000"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: other.path))
    }

    func testFailedBackupStopsMigration() throws {
        let manager = try DatabaseManager(path: dbPath)
        try manager.migrate(upTo: "createPayMonthClose")
        let pendingBefore = try manager.migrationStatus().pending
        XCTAssertThrowsError(try MigrationBackup.backUpThenMigrate(
            manager: manager, databasePath: dbPath, now: Date(), writeBackup: { _, _ in throw Boom() }))
        XCTAssertEqual(try manager.migrationStatus().pending, pendingBefore)
        XCTAssertTrue(try backups().isEmpty)
    }

    func testNoBackupForNewDatabase() throws {
        let manager = try DatabaseManager(path: nil)
        let missing = dir.appendingPathComponent("nope.sqlite").path
        XCTAssertNil(try MigrationBackup.backUpIfNeeded(manager: manager, databasePath: missing, now: Date()))
        XCTAssertTrue(try backups().isEmpty)
    }

    func testRetentionLeavesLookalikesAlone() throws {
        let manager = try DatabaseManager(path: dbPath)
        try manager.migrate(upTo: "createPayMonthClose")
        let lookalikes = ["20250101-120000-wal", "20250101-120000.partial", "20250101-120000-shm", "notes"]
            .map { MigrationBackup.fileNamePrefix + $0 }
        for name in lookalikes { try Data("x".utf8).write(to: dir.appendingPathComponent(name)) }
        for day in 1...6 {
            try Data("x".utf8).write(to: dir.appendingPathComponent(MigrationBackup.fileNamePrefix + String(format: "202601%02d-120000", day)))
        }
        _ = try MigrationBackup.backUpIfNeeded(manager: manager, databasePath: dbPath, now: Date())
        for name in lookalikes { XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent(name).path), name) }
    }

    func testSameSecondCollisionKeepsBoth() throws {
        let manager = try DatabaseManager(path: dbPath)
        try manager.migrate(upTo: "createPayMonthClose")
        let now = Date()
        let a = try XCTUnwrap(try MigrationBackup.backUpIfNeeded(manager: manager, databasePath: dbPath, now: now))
        let b = try XCTUnwrap(try MigrationBackup.backUpIfNeeded(manager: manager, databasePath: dbPath, now: now))
        XCTAssertNotEqual(a, b)
        XCTAssertTrue(FileManager.default.fileExists(atPath: a.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: b.path))
    }

    func testFailedWriteLeavesEarlierBackupAndNoPartial() throws {
        let manager = try DatabaseManager(path: dbPath)
        try manager.migrate(upTo: "createPayMonthClose")
        let first = try XCTUnwrap(try MigrationBackup.backUpIfNeeded(manager: manager, databasePath: dbPath, now: Date()))
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
        XCTAssertThrowsError(try MigrationBackup.backUpIfNeeded(manager: manager, databasePath: dbPath, now: Date()))
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.path))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: dir.path).contains { $0.contains(".partial") })
    }

    func testWalOnlyDataReachesTheCopy() throws {
        let manager = try DatabaseManager(path: dbPath)
        let queue = manager.dbQueue
        try queue.writeWithoutTransaction { try $0.execute(sql: "PRAGMA journal_mode = WAL") }
        try manager.migrate(upTo: "createPayMonthClose")
        try queue.write { try $0.execute(sql: "CREATE TABLE marker (v TEXT); INSERT INTO marker VALUES ('wal-row')") }
        XCTAssertTrue(FileManager.default.fileExists(atPath: dbPath + "-wal"))
        let url = try XCTUnwrap(try MigrationBackup.backUpIfNeeded(manager: manager, databasePath: dbPath, now: Date()))
        let copy = try DatabaseQueue(path: url.path)
        XCTAssertEqual(try copy.read { try String.fetchOne($0, sql: "SELECT v FROM marker") }, "wal-row")
    }

    private struct Boom: Error {}

    func testFailingBackupMeansMigrateIsNotCalled() throws {
        let manager = try DatabaseManager(path: dbPath)
        try manager.migrate(upTo: "createPayMonthClose")
        var migrateCalls = 0
        XCTAssertThrowsError(try MigrationBackup.backUpThenMigrate(
            manager: manager, databasePath: dbPath, now: Date(),
            writeBackup: { _, _ in throw Boom() }, migrate: { migrateCalls += 1 }))
        XCTAssertEqual(migrateCalls, 0)
        XCTAssertTrue(try backups().isEmpty)
    }

    func testMigrateRunsAfterASuccessfulBackup() throws {
        let manager = try DatabaseManager(path: dbPath)
        try manager.migrate(upTo: "createPayMonthClose")
        var backupExistedWhenMigrating = false
        var migrateCalls = 0
        let url = try MigrationBackup.backUpThenMigrate(manager: manager, databasePath: dbPath, now: Date(), migrate: {
            migrateCalls += 1
            backupExistedWhenMigrating = ((try? self.backups().count) ?? 0) == 1
            try manager.migrate()
        })
        XCTAssertNotNil(url)
        XCTAssertEqual(migrateCalls, 1)
        XCTAssertTrue(backupExistedWhenMigrating)
        XCTAssertTrue(try manager.migrationStatus().pending.isEmpty)
    }

    func testStalePartialAndSidecarsAreCleared() throws {
        let manager = try DatabaseManager(path: dbPath)
        try manager.migrate(upTo: "createPayMonthClose")
        let now = Date()
        let first = try XCTUnwrap(try MigrationBackup.backUpIfNeeded(manager: manager, databasePath: dbPath, now: now))
        try FileManager.default.removeItem(at: first)
        for suffix in [".partial", ".partial-wal", ".partial-shm", ".partial-journal"] {
            try Data("x".utf8).write(to: dir.appendingPathComponent(first.lastPathComponent + suffix))
        }
        _ = try MigrationBackup.backUpIfNeeded(manager: manager, databasePath: dbPath, now: now)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: dir.path).contains { $0.contains(".partial") })
    }
}
