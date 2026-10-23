import XCTest
import GRDB
@testable import BudgetCore

final class SyncSchemaTests: XCTestCase {
    private func migrated() throws -> DatabaseManager {
        let manager = try DatabaseManager(path: nil)
        try manager.migrate()
        return manager
    }

    private func tableNames(_ db: Database) throws -> [String] {
        try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name")
    }

    /// Every way the database and `SyncSchema` disagree, each naming the table and column.
    private func classificationProblems(_ db: Database) throws -> [String] {
        var problems: [String] = []
        let existing = try tableNames(db)
        for table in existing {
            if SyncSchema.localOnlyTables.contains(table) { continue }
            guard let entry = SyncSchema.table(table) else {
                problems.append("table \(table) is neither synced nor local-only")
                continue
            }
            let columns = try db.columns(in: table).map(\.name)
            var listed = entry.syncedColumns + entry.localOnlyColumns
            if !entry.syncedColumns.contains(entry.localIdColumn) { listed.append(entry.localIdColumn) }
            for column in columns where !listed.contains(column) {
                problems.append("column \(table).\(column) is not classified")
            }
            for column in listed where !columns.contains(column) {
                problems.append("column \(table).\(column) is listed but doesn't exist")
            }
            for column in Set(listed) where listed.filter({ $0 == column }).count > 1 {
                problems.append("column \(table).\(column) is listed twice")
            }
            if entry.localOnlyColumns.contains(entry.localIdColumn) {
                problems.append("column \(table).\(entry.localIdColumn) is the local id and listed local-only")
            }
            if let batchKey = entry.batchKey, !entry.syncedColumns.contains(batchKey) {
                problems.append("batch key \(table).\(batchKey) is not a synced column")
            }
        }
        for entry in SyncSchema.tables where !existing.contains(entry.name) {
            problems.append("table \(entry.name) is listed but doesn't exist")
        }
        for name in SyncSchema.localOnlyTables where !existing.contains(name) {
            problems.append("local-only table \(name) doesn't exist")
        }
        return problems
    }

    func testEveryColumnIsClassified() throws {
        let manager = try migrated()
        let problems = try manager.dbQueue.read { try classificationProblems($0) }
        XCTAssertEqual(problems, [], problems.joined(separator: "\n"))
    }

    func testAnUnlistedColumnFailsByName() throws {
        let manager = try migrated()
        try manager.dbQueue.write { try $0.execute(sql: "ALTER TABLE account ADD COLUMN somethingNew TEXT") }
        let problems = try manager.dbQueue.read { try classificationProblems($0) }
        XCTAssertEqual(problems, ["column account.somethingNew is not classified"])
    }

    func testTableNamesAreUnique() {
        let names = SyncSchema.tables.map(\.name)
        XCTAssertEqual(names.count, Set(names).count)
        XCTAssertNotNil(SyncSchema.table("transaction_"))
        XCTAssertNil(SyncSchema.table("syncRecord"))
    }

    func testLocalOnlyTablesNeverListed() throws {
        let required: Set<String> = ["syncRecord", "syncStaging", "syncConflict", "syncTombstone", "syncState",
                                     "localCredential", "localSetting", "grdb_migrations", "sqlite_sequence",
                                     "sourceFolder", "sourceFile"]
        XCTAssertTrue(required.isSubset(of: SyncSchema.localOnlyTables),
                      "missing: \(required.subtracting(SyncSchema.localOnlyTables).sorted())")
        for entry in SyncSchema.tables {
            XCTAssertFalse(SyncSchema.localOnlyTables.contains(entry.name), "\(entry.name) is both synced and local-only")
            for (column, parent) in entry.foreignKeys {
                XCTAssertFalse(SyncSchema.localOnlyTables.contains(parent),
                               "\(entry.name).\(column) syncs a reference to local-only \(parent)")
            }
            // Secrets, paths and bookmarks stay on this device.
            for column in entry.syncedColumns {
                XCTAssertFalse(["passwordHash", "recoveryKeyHash", "bookmark", "path", "backupPath"].contains(column),
                               "\(entry.name).\(column) must not sync")
            }
        }
        XCTAssertEqual(SyncSchema.table("appUser")?.localOnlyColumns, ["lastSignInAt"])
        XCTAssertEqual(SyncSchema.table("importRun")?.localOnlyColumns, ["backupPath"])
        XCTAssertEqual(Set(SyncSchema.table("document")?.localOnlyColumns ?? []),
                       ["sourceFolderId", "sourceRelativePath", "sourceModifiedAt", "extractedText"])
        // Ruling R4: re-derived from the file on each device, and too large for a record.
        XCTAssertFalse(SyncSchema.table("document")?.syncedColumns.contains("extractedText") ?? true)
    }

    func testForeignKeysMatchTheDatabase() throws {
        let manager = try migrated()
        try manager.dbQueue.read { db in
            for entry in SyncSchema.tables {
                var actual: [String: String] = [:]
                for row in try Row.fetchAll(db, sql: "PRAGMA foreign_key_list(\(entry.name))") {
                    let column: String = row["from"]
                    let parent: String = row["table"]
                    // A local-only column may point at a local-only table (document.sourceFolderId).
                    if entry.localOnlyColumns.contains(column) { continue }
                    actual[column] = parent
                }
                XCTAssertEqual(entry.foreignKeys, actual, "foreign keys of \(entry.name)")
                for column in entry.foreignKeys.keys {
                    XCTAssertTrue(entry.syncedColumns.contains(column), "\(entry.name).\(column) is a foreign key but doesn't sync")
                }
                for parent in entry.foreignKeys.values {
                    XCTAssertNotNil(SyncSchema.table(parent), "\(entry.name) references \(parent), which doesn't sync")
                }
            }
        }
    }

    /// Applying, backfilling and staging walk the tables in this order.
    func testTablesAreListedParentsFirst() {
        var seen: Set<String> = []
        for entry in SyncSchema.tables {
            for parent in entry.foreignKeys.values where parent != entry.name {
                XCTAssertTrue(seen.contains(parent), "\(entry.name) is listed before its parent \(parent)")
            }
            seen.insert(entry.name)
        }
    }

    func testSyncTablesRoundTrip() throws {
        let manager = try migrated()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        try manager.dbQueue.write { db in
            try SyncRecordRow(tableName: "account", localId: 3, uuid: "U-1", zone: "household",
                              systemFields: Data([1, 2]), modifiedBy: "W", modifiedAt: now).insert(db)
            var staged = SyncStagingRow(tableName: "transaction_", uuid: "U-2", payloadJSON: "{}", reason: "missing parent account",
                                        importRunUuid: nil, receivedAt: now)
            try staged.insert(db)
            var conflict = SyncConflictRow(tableName: "account", uuid: "U-1", field: "name", losingValueJSON: "\"Old\"",
                                           winningWriter: "A", losingWriter: "B", recordedAt: now)
            try conflict.insert(db)
            try SyncTombstoneRow(uuid: "U-3", tableName: "category", localId: 9, zone: "household",
                                 deletedBy: "A", deletedAt: now).insert(db)
            try SyncStateRow(key: "engine", value: Data([7]), updatedAt: now).insert(db)
            XCTAssertNotNil(staged.id)
            XCTAssertNotNil(conflict.id)
        }
        try manager.dbQueue.read { db in
            XCTAssertEqual(try SyncRecordRow.fetchOne(db)?.uuid, "U-1")
            XCTAssertEqual(try SyncRecordRow.fetchOne(db)?.systemFields, Data([1, 2]))
            XCTAssertEqual(try SyncStagingRow.fetchOne(db)?.reason, "missing parent account")
            XCTAssertEqual(try SyncConflictRow.fetchOne(db)?.losingValueJSON, "\"Old\"")
            XCTAssertEqual(try SyncTombstoneRow.fetchOne(db)?.localId, 9)
            XCTAssertEqual(try SyncStateRow.fetchOne(db, key: "engine")?.value, Data([7]))
        }
        // One identity per UUID and per local row.
        XCTAssertThrowsError(try manager.dbQueue.write { db in
            try SyncRecordRow(tableName: "category", localId: 1, uuid: "U-1", zone: "household",
                              systemFields: nil, modifiedBy: nil, modifiedAt: nil).insert(db)
        })
        XCTAssertThrowsError(try manager.dbQueue.write { db in
            try SyncRecordRow(tableName: "account", localId: 3, uuid: "U-9", zone: "household",
                              systemFields: nil, modifiedBy: nil, modifiedAt: nil).insert(db)
        })
    }

    func testMigrationOnlyAdds() throws {
        let manager = try DatabaseManager(path: nil)
        try manager.migrate(upTo: "createAppUser")
        // One synthetic row in every table, every column filled (except where a CHECK wants exactly one of
        // them); every row has id 1000, clear of seeded rows, so references hold.
        let leftNull: Set<String> = ["taxNotClaimed.manualItemId", "taxNotClaimed.policyReceiptId"]
        try manager.dbQueue.write { db in
            // References are checked at commit, once every table has its row.
            try db.execute(sql: "PRAGMA defer_foreign_keys = ON")
            for table in try tableNames(db) where !["sqlite_sequence", "grdb_migrations"].contains(table) {
                let columns = try db.columns(in: table)
                let values: [DatabaseValueConvertible?] = columns.map { column in
                    if leftNull.contains("\(table).\(column.name)") { return nil }
                    if column.name == "id" || column.name.hasSuffix("Id") { return 1000 }
                    switch column.type.uppercased() {
                    case "INTEGER": return 7
                    case "BOOLEAN": return false  // true would make the category reserved, which triggers refuse
                    case "DOUBLE": return 1.25
                    case "DATETIME": return "2024-05-06 07:08:09.000"
                    case "BLOB": return Data([0, 1, 2, 255])
                    default: return "synthetic \(table).\(column.name)"
                    }
                }
                let names = columns.map { "\"\($0.name)\"" }.joined(separator: ", ")
                let marks = Array(repeating: "?", count: columns.count).joined(separator: ", ")
                try db.execute(sql: "INSERT INTO \"\(table)\" (\(names)) VALUES (\(marks))", arguments: StatementArguments(values))
            }
        }
        func snapshot() throws -> [String: [String]] {
            try manager.dbQueue.read { db in
                var result: [String: [String]] = [:]
                for table in try tableNames(db) where table != "grdb_migrations" {
                    let columns = try db.columns(in: table).map { "quote(\"\($0.name)\")" }.joined(separator: " || '|' || ")
                    result[table] = try String.fetchAll(db, sql: "SELECT \(columns) FROM \"\(table)\" ORDER BY rowid")
                }
                result["schema"] = try String.fetchAll(db, sql: "SELECT type || ' ' || name || ' ' || IFNULL(sql, '') FROM sqlite_master ORDER BY name")
                return result
            }
        }
        let before = try snapshot()
        XCTAssertEqual(before["transaction_"]?.count, 1)
        try manager.migrate(upTo: "createSync")
        var after = try snapshot()
        let added = Set(after.keys).subtracting(before.keys)
        XCTAssertEqual(added, ["syncRecord", "syncStaging", "syncConflict", "syncTombstone", "syncState",
                               "syncPending", "syncFieldClock", "syncWriter", "syncApplying"])
        for table in added where table != "syncState" { XCTAssertEqual(after[table], [], "\(table) starts empty") }
        XCTAssertEqual(after["syncState"]?.count, 1, "only the installed trigger schema's stamp")
        XCTAssertTrue(after["syncState"]?.first?.hasPrefix("'triggerSchema'|") ?? false)
        // Every old schema object is unchanged; only the new tables, their indexes and the sync tracking
        // triggers (`syncTrack_*`) appear.
        let newObjects = Set(after["schema"]!).subtracting(before["schema"]!)
        XCTAssertTrue(Set(before["schema"]!).isSubset(of: Set(after["schema"]!)))
        for object in newObjects {
            XCTAssertTrue(object.contains("sync"), "unexpected new schema object: \(object)")
        }
        after["schema"] = before["schema"]
        for table in added { after[table] = nil }
        XCTAssertEqual(after, before)
    }
}
