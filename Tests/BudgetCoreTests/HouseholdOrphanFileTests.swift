import XCTest
import GRDB
@testable import BudgetCore
import TestSupport

/// Step 7a final review I-1: a household document's delete takes its sealed file record(s) with it, and file records
/// left behind before that (the step 6 era) are cleaned before the invite's audit and on the first push after install,
/// from what the server holds. A live household document's file is never touched. Synthetic data only.
final class HouseholdOrphanFileTests: XCTestCase {
    private let household = SyncZones.household

    // MARK: Fixture

    private struct Fixture {
        var h: TwoPersonHousehold
        var folder: URL
        var library: URL
    }

    /// The household with real sync on (stage done) and the Mac syncing files from a temporary library.
    private func make() throws -> Fixture {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("orphan-\(UUID().uuidString)", isDirectory: true)
        let library = folder.appendingPathComponent("Library", isDirectory: true)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        let h = try TwoPersonHousehold.make(macDocuments: SyncDocumentFiles(root: library, policy: .eager), memberInvited: false)
        try write(h.adminMac.db) { db in
            try SyncImportGate.setState(Data(SyncTurnOn.Stage.done.rawValue.utf8), key: SyncTurnOn.stageKey, db: db, now: Date())
        }
        return Fixture(h: h, folder: folder, library: library)
    }

    /// A household document (a deed) with a synthetic file in the library; its sync UUID.
    private func addDeed(_ f: Fixture) async throws -> (id: Int64, uuid: String) {
        let bytes = Data("Synthetic deed \(UUID().uuidString)".utf8)
        let sha = DocumentCrypto.sha256(bytes)
        let path = EvidenceLibrary.storedRelativePath(sha256: sha, fileExtension: "pdf")
        try FileManager.default.createDirectory(at: f.library.appendingPathComponent(path).deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try bytes.write(to: f.library.appendingPathComponent(path))
        let id = try await f.h.adminMac.db.write { db -> Int64 in
            try db.execute(sql: """
                INSERT INTO document(sha256, storedRelativePath, originalFileName, byteCount, addedAt, kind) VALUES (?, ?, 'synthetic.pdf', ?, ?, ?)
                """, arguments: [sha, path, bytes.count, Date(), DocumentKind.propertyDeed.rawValue])
            return db.lastInsertedRowID
        }
        return (id, try f.h.uuid("document", id))
    }

    /// Syncs until nothing is left to send.
    private func settle(_ h: TwoPersonHousehold) async throws {
        for _ in 0..<4 {
            _ = try await h.adminMac.engine.syncNow()
            let left = try read(h.adminMac.db) { db in
                try SyncChangeTracker.pending(db: db).count + SyncZoneMoves.unfinished(db: db).count + SyncCleanup.all(db: db).count
            }
            if left == 0 { return }
        }
    }

    private func files(_ h: TwoPersonHousehold, of uuid: String? = nil) async -> [SyncWireRecord] {
        await h.cloud.storedRecords().filter {
            $0.zone == household && $0.recordType == SyncDocumentFile.recordType && (uuid == nil || $0.recordName.hasPrefix(uuid! + "."))
        }
    }

    private func audit(_ h: TwoPersonHousehold) async throws -> [SyncZoneGuard.Violation] {
        try await HouseholdInvite.auditServer(transport: h.macTransport, keys: h.adminKeys, db: h.adminMac.db)
    }

    /// A copy of a live file record on the server under another owner's name (an orphan: that owner was never there).
    private func plantOrphan(_ h: TwoPersonHousehold, copying file: SyncWireRecord, owner: String = UUID().uuidString) async throws -> String {
        var orphan = file
        orphan.recordName = "\(owner).file.0rphan00"
        _ = try await h.cloud.save([orphan], ifUnchanged: [:], atomic: false)
        return orphan.recordName
    }

    private func markCleaned(_ h: TwoPersonHousehold) throws {
        try write(h.adminMac.db) { db in
            try SyncImportGate.setState(Data([1]), key: HouseholdOrphanFiles.doneKey, db: db, now: Date())
        }
    }

    // MARK: The delete takes its file

    func testDeletingHouseholdDocumentDeletesItsFile() async throws {
        let f = try make()
        defer { try? FileManager.default.removeItem(at: f.folder) }
        let deed = try await addDeed(f)
        try await settle(f.h)
        let before = await files(f.h, of: deed.uuid)
        XCTAssertEqual(before.count, 1, "file uploaded")
        try await f.h.adminMac.db.write { db in try db.execute(sql: "DELETE FROM document WHERE id = ?", arguments: [deed.id]) }
        try await settle(f.h)
        let after = await files(f.h, of: deed.uuid)
        XCTAssertEqual(after.count, 0, "file record left behind")
        let violations = try await audit(f.h)
        XCTAssertEqual(violations, [])
        let reference = try read(f.h.adminMac.db) { db in try SyncDocumentFile.reference(uuid: deed.uuid, db: db) }
        XCTAssertNil(reference, "the reference goes with the delete")
    }

    func testDeleteWithLostMarkerReplyStillTakesItsFile() async throws {
        let f = try make()
        defer { try? FileManager.default.removeItem(at: f.folder) }
        let deed = try await addDeed(f)
        let other = try await addDeed(f)
        try await settle(f.h)
        try await f.h.adminMac.db.write { db in try db.execute(sql: "DELETE FROM document WHERE id = ?", arguments: [deed.id]) }
        // The marker reaches the server, its reply doesn't: the delete is done again next time, and the file follows.
        f.h.macTransport.loseReply(to: deed.uuid, in: household)
        _ = try? await f.h.adminMac.engine.syncNow()
        f.h.macTransport.loseDeleteReply(in: household)
        _ = try? await f.h.adminMac.engine.syncNow()
        try await settle(f.h)
        let gone = await files(f.h, of: deed.uuid)
        XCTAssertEqual(gone.count, 0)
        let kept = await files(f.h, of: other.uuid)
        XCTAssertEqual(kept.count, 1, "the live document's file is untouched")
        let violations = try await audit(f.h)
        XCTAssertEqual(violations, [])
    }

    // MARK: Orphans already on the server

    func testStep6OrphansAreCleanedBeforeTheInvite() async throws {
        let f = try make()
        defer { try? FileManager.default.removeItem(at: f.folder) }
        let live = try await addDeed(f)
        let deleted = try await addDeed(f)
        try await settle(f.h)
        // Its own upload pulled back first, so nothing here learns the file again (an old build forgot it).
        _ = try await f.h.adminMac.engine.syncNow()
        try markCleaned(f.h)
        // Step 6 era: a file whose document was hard-deleted (absent on the server), and one whose document is a
        // deletion marker (deleted by a build that didn't take files).
        let liveFiles = await files(f.h, of: live.uuid)
        let liveFile = try XCTUnwrap(liveFiles.first)
        let absentOwner = try await plantOrphan(f.h, copying: liveFile)
        try await f.h.adminMac.db.write { db in
            try db.execute(sql: "DELETE FROM document WHERE id = ?", arguments: [deleted.id])
            try SyncDocumentFile.setReference(nil, uuid: deleted.uuid, db: db, now: Date())
        }
        try await settle(f.h)
        let markerOrphans = await files(f.h, of: deleted.uuid)
        XCTAssertEqual(markerOrphans.count, 1, "precondition: the old delete left its file")
        let blocked = try await audit(f.h)
        XCTAssertEqual(blocked.count, 2, "precondition: the audit blocks")

        let result = try await HouseholdInvite.invite(transport: f.h.macTransport, keys: f.h.adminKeys, db: f.h.adminMac.db,
                                                      title: "Synthetic household")
        guard case .share = result else { return XCTFail("expected a share, got \(result)") }
        let names = await files(f.h).map(\.recordName)
        XCTAssertFalse(names.contains(absentOwner))
        XCTAssertTrue(names.allSatisfy { !$0.hasPrefix(deleted.uuid) })
        XCTAssertEqual(names, [liveFile.recordName], "the live document's file stays")
        let violations = try await audit(f.h)
        XCTAssertEqual(violations, [])
    }

    func testFirstPushAfterInstallCleansOrphansOnce() async throws {
        let f = try make()
        defer { try? FileManager.default.removeItem(at: f.folder) }
        let live = try await addDeed(f)
        try await settle(f.h)
        let liveFiles = await files(f.h, of: live.uuid)
        let liveFile = try XCTUnwrap(liveFiles.first)
        try write(f.h.adminMac.db) { db in try db.execute(sql: "DELETE FROM syncState WHERE key = ?", arguments: [HouseholdOrphanFiles.doneKey]) }
        let orphan = try await plantOrphan(f.h, copying: liveFile)
        _ = try await f.h.adminMac.engine.syncNow()
        let names = await files(f.h).map(\.recordName)
        XCTAssertEqual(names, [liveFile.recordName])
        XCTAssertFalse(names.contains(orphan))
        let done = try read(f.h.adminMac.db) { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM syncState WHERE key = ?", arguments: [HouseholdOrphanFiles.doneKey])
        }
        XCTAssertEqual(done, 1)
        // Once: a later orphan waits for the invite's cleanup.
        let later = try await plantOrphan(f.h, copying: liveFile)
        _ = try await f.h.adminMac.engine.syncNow()
        let still = await files(f.h).map(\.recordName)
        XCTAssertTrue(still.contains(later))
    }

    func testLiveDocumentFilesAreNeverTouched() async throws {
        let f = try make()
        defer { try? FileManager.default.removeItem(at: f.folder) }
        let live = try await addDeed(f)
        try await settle(f.h)
        let liveFiles = await files(f.h, of: live.uuid)
        let liveFile = try XCTUnwrap(liveFiles.first)
        // A document whose file is up but whose record isn't yet (its upload under way here): not an orphan.
        let uploading = try await addDeed(f)
        let inFlight = try await plantOrphan(f.h, copying: liveFile, owner: uploading.uuid)
        let removed = try await HouseholdOrphanFiles.clean(transport: f.h.macTransport, keys: f.h.adminKeys, db: f.h.adminMac.db)
        XCTAssertEqual(removed, 0)
        let names = Set(await files(f.h).map(\.recordName))
        XCTAssertEqual(names, [liveFile.recordName, inFlight])
    }

    func testCleanupSurvivesALostReplyAndIsIdempotent() async throws {
        let f = try make()
        defer { try? FileManager.default.removeItem(at: f.folder) }
        let live = try await addDeed(f)
        try await settle(f.h)
        try markCleaned(f.h)
        let liveFiles = await files(f.h, of: live.uuid)
        let liveFile = try XCTUnwrap(liveFiles.first)
        _ = try await plantOrphan(f.h, copying: liveFile)
        f.h.macTransport.loseDeleteReply(in: household)
        do {
            _ = try await HouseholdOrphanFiles.clean(transport: f.h.macTransport, keys: f.h.adminKeys, db: f.h.adminMac.db)
            XCTFail("the lost reply is an error")
        } catch let error as SyncTransportError {
            XCTAssertTrue(error.isPassing)
        }
        let again = try await HouseholdOrphanFiles.clean(transport: f.h.macTransport, keys: f.h.adminKeys, db: f.h.adminMac.db)
        XCTAssertEqual(again, 0, "the server took the delete")
        let third = try await HouseholdOrphanFiles.clean(transport: f.h.macTransport, keys: f.h.adminKeys, db: f.h.adminMac.db)
        XCTAssertEqual(third, 0)
        let names = await files(f.h).map(\.recordName)
        XCTAssertEqual(names, [liveFile.recordName])
        let violations = try await audit(f.h)
        XCTAssertEqual(violations, [])
    }

    func testCleanupWithoutTheHouseholdKeyDeletesNothing() async throws {
        let f = try make()
        defer { try? FileManager.default.removeItem(at: f.folder) }
        let live = try await addDeed(f)
        try await settle(f.h)
        let liveFiles = await files(f.h, of: live.uuid)
        let liveFile = try XCTUnwrap(liveFiles.first)
        _ = try await plantOrphan(f.h, copying: liveFile)
        let removed = try await HouseholdOrphanFiles.clean(transport: f.h.macTransport, keys: InMemorySyncKeyStore(), db: f.h.adminMac.db)
        XCTAssertEqual(removed, 0, "nothing opens: nothing is judged an orphan")
        let count = await files(f.h).count
        XCTAssertEqual(count, 2)
    }

    // MARK: Helpers

    private func read<T>(_ db: any DatabaseReader, _ body: (Database) throws -> T) throws -> T { try db.read(body) }
    private func write<T>(_ db: any DatabaseWriter, _ body: (Database) throws -> T) throws -> T { try db.write(body) }
}
