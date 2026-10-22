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
        let appliedBefore = try manager.migrationStatus().pending
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
        XCTAssertThrowsError(try MigrationBackup.backUpIfNeeded(manager: manager, databasePath: dbPath, now: Date()))
        XCTAssertEqual(try manager.migrationStatus().pending, appliedBefore)
        XCTAssertTrue(try backups().isEmpty)
    }

    func testNoBackupForNewDatabase() throws {
        let manager = try DatabaseManager(path: nil)
        let missing = dir.appendingPathComponent("nope.sqlite").path
        XCTAssertNil(try MigrationBackup.backUpIfNeeded(manager: manager, databasePath: missing, now: Date()))
        XCTAssertTrue(try backups().isEmpty)
    }
}
