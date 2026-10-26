import XCTest
import GRDB
@testable import BudgetCore
import TestSupport

/// A row deleted right after its upload, before this device pulls its own upload back: the pull must not take the
/// returning version as someone else's (bringing the row back, or dropping the delete's tombstone), and the delete must
/// reach the server. Any table, not only documents. Synthetic data only.
final class DeleteAfterUploadTests: XCTestCase {
    private let household = SyncZones.household

    private func serverPayload(_ h: TwoPersonHousehold, _ uuid: String) async throws -> SyncPayload? {
        guard let server = try await h.cloud.fetch(uuid, zone: household) else { return nil }
        return try SyncLargePayload.payload(from: server, keys: try h.adminKeys.allKeys(zone: household))
    }

    private func check(_ h: TwoPersonHousehold, table: String, insert: @escaping @Sendable (Database) throws -> Int64,
                       file: StaticString = #filePath, line: UInt = #line) async throws {
        let id = try await h.adminMac.db.write { db in try insert(db) }
        let uuid = try h.uuid(table, id)
        // Uploaded; nothing pulled back yet.
        try await h.adminMac.engine.pushPending()
        let up = try await serverPayload(h, uuid)
        XCTAssertNotNil(up, "precondition: uploaded", file: file, line: line)
        try await h.adminMac.db.write { db in
            try db.execute(sql: "DELETE FROM \(SyncChangeTracker.quoted(table)) WHERE id = ?", arguments: [id])
        }
        for _ in 0..<3 { _ = try await h.adminMac.engine.syncNow() }
        let pending = try await h.adminMac.db.read { db in try SyncChangeTracker.pending(db: db).filter { $0.uuid == uuid }.count }
        XCTAssertEqual(pending, 0, "\(table): the delete went", file: file, line: line)
        let row = try await h.adminMac.db.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(SyncChangeTracker.quoted(table)) WHERE id = ?", arguments: [id])
        }
        XCTAssertEqual(row, 0, "\(table): not brought back", file: file, line: line)
        let back = try await h.adminMac.db.read { db in try SyncRecordStore.localId(table: table, uuid: uuid, db: db) }
        XCTAssertNil(back, "\(table): not brought back under another id", file: file, line: line)
        let staged = try await h.adminMac.db.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM syncStaging WHERE uuid = ?", arguments: [uuid]) }
        XCTAssertEqual(staged, 0, "\(table): nothing staged", file: file, line: line)
        let server = try await serverPayload(h, uuid)
        XCTAssertEqual(server?.isDeletionMarker, true, "\(table): a deletion marker on the server", file: file, line: line)
        let conflicts = try await h.adminMac.db.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM syncConflict WHERE uuid = ?", arguments: [uuid]) }
        XCTAssertEqual(conflicts, 0, "\(table): nothing needs attention", file: file, line: line)
    }

    /// A new row copied from `id` (every column but the id; a name made unique).
    private static func copy(_ table: String, _ id: Int64, db: Database) throws {
        let columns = try db.columns(in: table).map(\.name).filter { $0 != "id" }
        let list = columns.map { SyncChangeTracker.quoted($0) }.joined(separator: ", ")
        let values = columns.map { ["name", "fingerprint"].contains($0) ? "\(SyncChangeTracker.quoted($0)) || ' copy'" : SyncChangeTracker.quoted($0) }.joined(separator: ", ")
        try db.execute(sql: "INSERT INTO \(SyncChangeTracker.quoted(table)) (\(list)) SELECT \(values) FROM \(SyncChangeTracker.quoted(table)) WHERE id = ?",
                       arguments: [id])
    }

    func testDocumentDeletedBeforeItsUploadComesBack() async throws {
        let h = try TwoPersonHousehold.make(memberInvited: false)
        try await h.adminMac.engine.syncNow()
        try await check(h, table: "document") { db in
            try db.execute(sql: "INSERT INTO document(sha256, storedRelativePath, originalFileName, byteCount, addedAt, kind) VALUES (?, 'x.pdf', 'x.pdf', 1, ?, ?)",
                           arguments: [String(repeating: "a", count: 64), Date(), DocumentKind.propertyDeed.rawValue])
            return db.lastInsertedRowID
        }
    }

    func testTransactionDeletedBeforeItsUploadComesBack() async throws {
        let h = try TwoPersonHousehold.make(memberInvited: false)
        try await h.adminMac.engine.syncNow()
        let f = h.fixture
        try await check(h, table: "transaction_") { db in
            try Self.copy("transaction_", f.sharedTransaction, db: db)
            return db.lastInsertedRowID
        }
    }

    func testCategoryDeletedBeforeItsUploadComesBack() async throws {
        let h = try TwoPersonHousehold.make(memberInvited: false)
        try await h.adminMac.engine.syncNow()
        let f = h.fixture
        try await check(h, table: "category") { db in
            try Self.copy("category", f.plainCategory, db: db)
            return db.lastInsertedRowID
        }
    }
}
