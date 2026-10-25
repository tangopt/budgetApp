import XCTest
import GRDB
@testable import BudgetCore
import TestSupport

/// Step 6 Task 5: the engine syncs a zone set (household + the viewer's private zone), each sealed under its own
/// key; the push places every record by the router, moves records with markers, sends stubs with their
/// `accountDetails` companions and checks every save with the guard; pulls follow the zones. Two simulated people
/// over `FakeCloud` (`TwoPersonHousehold`); every test ends by auditing every household save.
final class SyncZonesEngineTests: XCTestCase {
    private func assertNoHouseholdLeak(_ h: TwoPersonHousehold, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(h.audit.householdViolations(router: h.adminRouter()), [], file: file, line: line)
    }

    private func names(_ h: TwoPersonHousehold, zone: String) -> Set<String> {
        Set((h.audit.savesByZone[zone] ?? []).map(\.recordName))
    }

    /// The record `name` as the server holds it in `zone`, opened with the admin's keys.
    private func stored(_ h: TwoPersonHousehold, _ name: String, in zone: String) async throws -> SyncPayload? {
        guard let record = try await h.cloud.fetch(name, zone: zone) else { return nil }
        return try SyncLargePayload.payload(from: record.wire, keys: try h.adminKeys.allKeys(zone: zone))
    }

    /// Synchronous access (async tests would otherwise pick GRDB's async overloads).
    private func read<T>(_ device: TwoPersonHousehold.Device, _ body: (Database) throws -> T) throws -> T { try device.db.read(body) }
    private func write<T>(_ device: TwoPersonHousehold.Device, _ body: (Database) throws -> T) throws -> T { try device.db.write(body) }

    private func count(_ device: TwoPersonHousehold.Device, _ sql: String, _ arguments: StatementArguments = []) throws -> Int {
        try read(device) { db in try Int.fetchOne(db, sql: sql, arguments: arguments) ?? 0 }
    }

    func testPrivateAccountUploadsToItsOwnZoneWithItsOwnKey() async throws {
        let h = try TwoPersonHousehold.make()
        let f = h.fixture
        try await h.syncAll()

        let household = names(h, zone: SyncZones.household)
        let privateA = names(h, zone: f.privateZone)
        for id in [f.privateTransaction, f.transferIn] {
            let uuid = try h.uuid("transaction_", id)
            XCTAssertTrue(privateA.contains(uuid), "the Private account's transaction \(id) went to A's zone")
            XCTAssertFalse(household.contains(uuid), "and never to the household")
        }
        XCTAssertTrue(household.contains(try h.uuid("transaction_", f.sharedTransaction)))
        // The stub went to the household, its details in a companion in A's zone.
        let account = try h.uuid("account", f.privateAccount)
        XCTAssertTrue(household.contains(account))
        XCTAssertTrue((h.audit.savesByZone[f.privateZone] ?? []).contains { $0.recordName == account && $0.recordType == SyncZoneRouter.companionRecordType })

        // Each zone sealed under its own key; the member never holds A's.
        let keyIds = { (zone: String) in
            Set((h.audit.savesByZone[zone] ?? []).filter { $0.recordType != SyncDocumentFile.recordType }.compactMap(FieldSealing.keyId(of:)))
        }
        XCTAssertEqual(keyIds(SyncZones.household).count, 1)
        XCTAssertEqual(keyIds(f.privateZone).count, 1)
        XCTAssertTrue(keyIds(SyncZones.household).isDisjoint(with: keyIds(f.privateZone)))
        XCTAssertEqual(try h.adminKeys.allKeys(zone: f.privateZone).keys.sorted(), keyIds(f.privateZone).sorted())
        XCTAssertTrue(try h.memberKeys.allKeys(zone: f.privateZone).isEmpty)
        assertNoHouseholdLeak(h)
    }

    func testMemberSeesStubSummaryZoneOnly() async throws {
        let h = try TwoPersonHousehold.make()
        let f = h.fixture
        try await h.syncAll()
        let member = h.memberDevice

        let account = try XCTUnwrap(try h.localId("account", uuid: try h.uuid("account", f.privateAccount), on: member))
        let row = try XCTUnwrap(try read(member) { db in try Row.fetchOne(db, sql: "SELECT * FROM account WHERE id = ?", arguments: [account]) })
        XCTAssertEqual(row["name"] as String?, "Synthetic private", "the stub's name")
        for column in SyncZoneRouter.privateAccountColumns {
            XCTAssertTrue((row[column] as DatabaseValue).isNull, "\(column) stays private")
        }
        for id in [f.privateTransaction, f.transferIn] {
            XCTAssertNil(try h.localId("transaction_", uuid: try h.uuid("transaction_", id), on: member), "private transaction \(id)")
        }
        // §10: the property-category transaction (and the one a tax row pins) is shared.
        XCTAssertNotNil(try h.localId("transaction_", uuid: try h.uuid("transaction_", f.privatePropertyTransaction), on: member))
        XCTAssertNotNil(try h.localId("transaction_", uuid: try h.uuid("transaction_", f.privatePinnedTransaction), on: member))
        XCTAssertNil(try h.localId("importBatch", uuid: try h.uuid("importBatch", f.privateBatch), on: member))
        XCTAssertEqual(try count(member, "SELECT COUNT(*) FROM transaction_ WHERE accountId = ?", [account]), 2)
        assertNoHouseholdLeak(h)
    }

    func testAdminPhoneGetsEverything() async throws {
        let h = try TwoPersonHousehold.make()
        let f = h.fixture
        try await h.syncAll()
        let phone = h.adminPhone

        let account = try XCTUnwrap(try h.localId("account", uuid: try h.uuid("account", f.privateAccount), on: phone))
        let details = try read(phone) { db in try Row.fetchOne(db, sql: "SELECT sortCode, accountNumber FROM account WHERE id = ?", arguments: [account])! }
        XCTAssertEqual(details["sortCode"] as String?, "401234", "the companion's columns")
        XCTAssertEqual(details["accountNumber"] as String?, "81234567")
        let macTransactions = try read(h.adminMac) { db in
            try Set(String.fetchAll(db, sql: "SELECT uuid FROM syncRecord WHERE tableName = 'transaction_'"))
        }
        let phoneTransactions = try read(phone) { db in
            try Set(String.fetchAll(db, sql: "SELECT s.uuid FROM syncRecord s JOIN transaction_ t ON t.id = s.localId WHERE s.tableName = 'transaction_'"))
        }
        XCTAssertEqual(phoneTransactions, macTransactions, "every transaction")
        XCTAssertEqual(try count(phone, "SELECT COUNT(*) FROM transferLink"), 1)
        XCTAssertEqual(try count(phone, "SELECT COUNT(*) FROM documentLink"), 3)
        assertNoHouseholdLeak(h)
    }

    func testMemberNeverFetchesTheAdminsPrivateZone() async throws {
        let h = try TwoPersonHousehold.make()
        let f = h.fixture
        try await h.adminMac.engine.pushPending()
        let before = await h.cloud.calls.count
        try await h.memberDevice.engine.syncNow()
        _ = try await h.memberDevice.engine.pull()
        let calls = Array(await h.cloud.calls.dropFirst(before))
        XCTAssertTrue(calls.contains(.changes(zone: SyncZones.household, since: nil)), "the member pulls the household")
        XCTAssertTrue(calls.contains { if case .changes(h.memberZone, _) = $0 { return true } else { return false } }, "and her own zone")
        for call in calls {
            switch call {
            case .changes(let zone, _): XCTAssertNotEqual(zone, f.privateZone)
            case .createZone(let zone): XCTAssertNotEqual(zone, f.privateZone)
            case .fetch(let name): XCTAssertNotEqual(name, SyncZoneKeys.recordName(zone: f.privateZone))
            case .save, .delete: break
            }
        }
        assertNoHouseholdLeak(h)
    }

    func testAdminNeverFetchesTheMembersPrivateZone() async throws {
        let h = try TwoPersonHousehold.make()
        try await h.memberDevice.engine.syncNow()
        let before = await h.cloud.calls.count
        try await h.adminMac.engine.syncNow()
        _ = try await h.adminPhone.engine.pull()
        let calls = Array(await h.cloud.calls.dropFirst(before))
        XCTAssertTrue(calls.contains { if case .changes(h.fixture.privateZone, _) = $0 { return true } else { return false } })
        for call in calls {
            switch call {
            case .changes(let zone, _): XCTAssertNotEqual(zone, h.memberZone)
            case .createZone(let zone): XCTAssertNotEqual(zone, h.memberZone)
            case .fetch(let name): XCTAssertNotEqual(name, SyncZoneKeys.recordName(zone: h.memberZone))
            case .save, .delete: break
            }
        }
        assertNoHouseholdLeak(h)
    }

    /// Review Focus 1: Shared goes from Everything to Balance only, so its transactions move into A's zone. The
    /// owner's phone keeps the rows (and what links to them) whichever half of the move it sees first; the member's
    /// device drops them, with no tombstone.
    func testOwnerDeviceKeepsAMovedRecordWhicheverZoneArrivesFirst() async throws {
        for markerFirst in [true, false] {
            let h = try TwoPersonHousehold.make()
            let f = h.fixture
            try await h.syncAll()
            let moved = try h.uuid("transaction_", f.transferOut)
            let sharedTransaction = try h.uuid("transaction_", f.sharedTransaction)
            let link = try h.uuid("transferLink", f.transferLink)
            XCTAssertNotNil(try h.localId("transaction_", uuid: moved, on: h.memberDevice))

            try write(h.adminMac) { db in _ = try SharingLevels.set(.balanceOnly, accountId: f.shared, actor: f.admin, db: db) }
        try h.requeueEverythingOnTheMac()
            try await h.adminMac.engine.pushPending()
            let storedMarker = try await stored(h, moved, in: SyncZones.household)
            let marker = try XCTUnwrap(storedMarker)
            XCTAssertEqual(marker.zone, SyncZones.household, "the household copy is a marker now")
            XCTAssertEqual(marker.movedTo, f.privateZone)
            XCTAssertTrue(marker.fields.isEmpty)
            XCTAssertTrue(names(h, zone: f.privateZone).contains(moved), "saved in A's zone")

            let phone = h.adminPhone
            let order = markerFirst ? [SyncZones.household, f.privateZone] : [f.privateZone, SyncZones.household]
            for zone in order {
                _ = try await phone.engine.pullZone(zone)
                for uuid in [moved, sharedTransaction] {
                    XCTAssertNotNil(try h.localId("transaction_", uuid: uuid, on: phone), "kept after the \(zone) pull (marker first: \(markerFirst))")
                }
                XCTAssertNotNil(try h.localId("transferLink", uuid: link, on: phone), "its transfer link too")
                XCTAssertEqual(try count(phone, "SELECT COUNT(*) FROM documentLink"), 3, "and its document links")
            }
            let zone = try read(phone) { db in try String.fetchOne(db, sql: "SELECT zone FROM syncRecord WHERE uuid = ?", arguments: [moved]) }
            XCTAssertEqual(zone, f.privateZone)

            _ = try await h.memberDevice.engine.pull()
            XCTAssertNil(try h.localId("transaction_", uuid: moved, on: h.memberDevice), "the member's copy goes")
            XCTAssertEqual(try count(h.memberDevice, "SELECT COUNT(*) FROM syncTombstone WHERE uuid = ?", [moved]), 0, "with no tombstone")
            XCTAssertEqual(try count(h.memberDevice, "SELECT COUNT(*) FROM syncStaging"), 0)
            assertNoHouseholdLeak(h)

            // Back to Everything: the record comes back to the member.
            try write(h.adminMac) { db in _ = try SharingLevels.set(.everything, accountId: f.shared, actor: f.admin, db: db) }
            try h.requeueEverythingOnTheMac()
            try await h.syncAll()
            XCTAssertNotNil(try h.localId("transaction_", uuid: moved, on: h.memberDevice), "a move back applies")
            XCTAssertNotNil(try h.localId("transaction_", uuid: moved, on: phone))
            assertNoHouseholdLeak(h)
        }
    }

    /// Review Focus 2: the member's device ends a full pull with nothing staged: no household record waits for a
    /// private one.
    func testMemberDeviceHasNoStagedOrphansAfterFullPull() async throws {
        let h = try TwoPersonHousehold.make()
        try await h.syncAll()
        let staged = try read(h.memberDevice) { db in try String.fetchAll(db, sql: "SELECT tableName || ': ' || reason FROM syncStaging") }
        XCTAssertEqual(staged, [])
        XCTAssertEqual(try count(h.adminPhone, "SELECT COUNT(*) FROM syncStaging"), 0, "the owner's phone too")
        let foreignKeys = try read(h.memberDevice) { db in try Row.fetchAll(db, sql: "PRAGMA foreign_key_check") }
        XCTAssertEqual(foreignKeys.count, 0)
        assertNoHouseholdLeak(h)
    }

    /// N-5: an import into Private writing a property-category transaction: that transaction is shared and travels
    /// without the private run's tag, so the member applies it at once; the run's manifest counts only its own zone.
    func testPrivateRunsHouseholdRecordsTravelUntagged() async throws {
        let h = try TwoPersonHousehold.make()
        let f = h.fixture
        try await h.syncAll()
        let (run, transaction) = try write(h.adminMac) { db -> (Int64, Int64) in
            let mark = try SyncBatch.mark(db: db)
            try db.execute(sql: "INSERT INTO importRun(confirmedAt, entryPoint, summary) VALUES (?, 'documents', 'Synthetic private import')",
                           arguments: [Date(timeIntervalSince1970: 1_790_100_000)])
            let run = db.lastInsertedRowID
            try db.execute(sql: "INSERT INTO importBatch(accountId, sourceFileName, importedAt, importRunId) VALUES (?, 'synthetic-2.csv', ?, ?)",
                           arguments: [f.privateAccount, Date(timeIntervalSince1970: 1_790_100_000), run])
            let batch = db.lastInsertedRowID
            try db.execute(sql: """
                INSERT INTO transaction_(importBatchId, accountId, date, rawDescription, amountMinorUnits, categoryId, status, categorizedBy, fingerprint)
                VALUES (?, ?, ?, 'Synthetic rent', 61000, ?, 'confirmed', 'rule', 'fp-new-rent')
                """, arguments: [batch, f.privateAccount, Date(timeIntervalSince1970: 1_790_100_000), f.propertyCategory])
            let transaction = db.lastInsertedRowID
            try SyncBatch.open(runId: run, since: mark, db: db)
            return (run, transaction)
        }
        try await h.adminMac.engine.pushPending()
        let runUuid = try h.uuid("importRun", run)
        let transactionUuid = try h.uuid("transaction_", transaction)
        let storedSent = try await stored(h, transactionUuid, in: SyncZones.household)
        let sent = try XCTUnwrap(storedSent)
        XCTAssertEqual(sent.zone, SyncZones.household)
        XCTAssertNil(sent.importRunUuid, "no private run's tag")
        XCTAssertNil(sent.batchGeneration)
        XCTAssertNil(sent.fields["importBatchId"])
        XCTAssertEqual(sent.omittedFields, ["importBatchId"])
        let storedRun = try await stored(h, runUuid, in: f.privateZone)
        let runRecord = try XCTUnwrap(storedRun)
        XCTAssertEqual(runRecord.zone, f.privateZone)
        XCTAssertNil(runRecord.manifest?.counts["transaction_"], "the manifest counts only the run's own zone")
        XCTAssertEqual(runRecord.manifest?.counts["importBatch"], 1)

        _ = try await h.memberDevice.engine.pull()
        XCTAssertNotNil(try h.localId("transaction_", uuid: transactionUuid, on: h.memberDevice), "applied without waiting for a batch")
        XCTAssertEqual(try count(h.memberDevice, "SELECT COUNT(*) FROM syncStaging"), 0)
        _ = try await h.adminPhone.engine.pull()
        XCTAssertNotNil(try h.localId("transaction_", uuid: transactionUuid, on: h.adminPhone))
        XCTAssertEqual(try count(h.adminPhone, "SELECT COUNT(*) FROM syncStaging"), 0)
        assertNoHouseholdLeak(h)
    }

    func testGuardStopsAPushThatWouldLeak() async throws {
        let h = try TwoPersonHousehold.make()
        let f = h.fixture
        try await h.syncAll()
        let leaking = try h.uuid("transaction_", f.privateTransaction)
        // A stale zone here, and a router that gets it wrong.
        try write(h.adminMac) { db in
            try db.execute(sql: "UPDATE transaction_ SET note = 'Synthetic edit' WHERE id = ?", arguments: [f.privateTransaction])
            try db.execute(sql: "UPDATE syncRecord SET zone = ? WHERE uuid = ?", arguments: [SyncZones.household, leaking])
        }
        let privateTransaction = f.privateTransaction
        await h.adminMac.engine.setAssignmentOverride { table, id in
            table == "transaction_" && id == privateTransaction ? .household : nil
        }
        let stored = await h.cloud.storedRecords()
        let saves = h.audit.savesByZone.values.map(\.count).reduce(0, +)

        do {
            try await h.adminMac.engine.pushPending()
            XCTFail("the push must stop")
        } catch let violation as SyncZoneGuard.Violation {
            XCTAssertEqual(violation.recordName, leaking)
            XCTAssertEqual(violation.actual, SyncZones.household)
        }
        let after = await h.cloud.storedRecords()
        XCTAssertEqual(after, stored, "FakeCloud holds nothing new")
        XCTAssertEqual(h.audit.savesByZone.values.map(\.count).reduce(0, +), saves, "nothing was even sent")
        let logged = try read(h.adminMac) { db in
            try String.fetchAll(db, sql: "SELECT losingValueJSON FROM syncConflict WHERE uuid = ?", arguments: [leaking])
        }
        XCTAssertTrue(logged.contains { $0.contains("needs attention") }, "logged for attention")
        let pending = try read(h.adminMac) { db in try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM syncPending WHERE uuid = ?)", arguments: [leaking])! }
        XCTAssertTrue(pending, "still to send")
        assertNoHouseholdLeak(h)
    }

    /// A document moving from the household to A's zone (its only transaction went private): its file is sealed
    /// again under A's key, in A's zone, and the household's file record goes.
    func testDocumentFileReSealedOnMove() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("zones-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let macLibrary = folder.appendingPathComponent("mac/Library", isDirectory: true)
        let phoneLibrary = folder.appendingPathComponent("phone/Library", isDirectory: true)
        let bytes = Data("Synthetic receipt for the shared account".utf8)
        let sha = DocumentCrypto.sha256(bytes)
        let path = EvidenceLibrary.storedRelativePath(sha256: sha, fileExtension: "pdf")
        try FileManager.default.createDirectory(at: macLibrary.appendingPathComponent(path).deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: macLibrary.appendingPathComponent(path))

        let h = try TwoPersonHousehold.make(macDocuments: SyncDocumentFiles(root: macLibrary, policy: .eager),
                                            phoneDocuments: SyncDocumentFiles(root: phoneLibrary, policy: .lazy))
        let f = h.fixture
        let document = try write(h.adminMac) { db -> Int64 in
            try db.execute(sql: """
                INSERT INTO document(sha256, storedRelativePath, originalFileName, byteCount, addedAt) VALUES (?, ?, 'receipt.pdf', ?, ?)
                """, arguments: [sha, path, bytes.count, Date(timeIntervalSince1970: 1_790_000_000)])
            let id = db.lastInsertedRowID
            try db.execute(sql: "INSERT INTO documentLink(documentId, entityType, entityId, createdAt) VALUES (?, 'transaction', ?, ?)",
                           arguments: [id, f.sharedTransaction, Date(timeIntervalSince1970: 1_790_000_000)])
            return id
        }
        try await h.syncAll()
        let uuid = try h.uuid("document", document)
        let filesIn = { (zone: String) async -> [String] in
            await h.cloud.storedRecords().filter { $0.zone == zone && $0.recordType == SyncDocumentFile.recordType && $0.recordName.hasPrefix(uuid) }
                .map(\.recordName)
        }
        let householdFiles = await filesIn(SyncZones.household)
        XCTAssertEqual(householdFiles.count, 1, "first sealed for the household")
        let privateBefore = await filesIn(f.privateZone)
        XCTAssertEqual(privateBefore, [])

        try write(h.adminMac) { db in _ = try SharingLevels.set(.balanceOnly, accountId: f.shared, actor: f.admin, db: db) }
        try h.requeueEverythingOnTheMac()
        try await h.syncAll()
        let storedRecord = try await stored(h, uuid, in: f.privateZone)
        let record = try XCTUnwrap(storedRecord)
        let left = try await stored(h, uuid, in: SyncZones.household)
        XCTAssertEqual(left?.movedTo, f.privateZone)
        XCTAssertEqual(record.zone, f.privateZone, "the document moved")
        let privateFiles = await filesIn(f.privateZone)
        XCTAssertEqual(privateFiles.count, 1, "sealed again in A's zone")
        XCTAssertEqual(record.documentFile?.recordName, privateFiles.first)
        XCTAssertEqual(try DocumentCrypto.zoneKeyId(ofWrapped: try XCTUnwrap(record.documentFile).wrappedKey),
                       DocumentCrypto.zoneKeyId(try XCTUnwrap(h.adminKeys.key(zone: f.privateZone))), "under A's key")
        let householdAfter = await filesIn(SyncZones.household)
        XCTAssertEqual(householdAfter, [], "the household's file record went")
        let downloaded = try await h.adminPhone.engine.downloadDocument(uuid: uuid)
        XCTAssertEqual(try Data(contentsOf: downloaded), bytes, "and the owner's phone opens it")
        XCTAssertNil(try h.localId("document", uuid: uuid, on: h.memberDevice))
        assertNoHouseholdLeak(h)
    }

    /// Sync spec §5.4 on a private zone: a change pulled from A's zone that would move a filed return is held, as
    /// one from the household is. The flat's account is Hidden here (set as data, past its blockers), so its
    /// repair in A's filed 2024/25 is in A's zone.
    func testFiledYearCheckRunsOnPrivatePulls() async throws {
        let base = try TwoPersonHousehold.make()
        let h = try TwoPersonHousehold.make(levels: [base.fixture.lisbon: .hidden])
        let f = h.fixture
        let repair = try write(h.adminMac) { db -> Int64 in
            try db.execute(sql: "UPDATE property SET currency = ? WHERE id = ?", arguments: [Currency.gbp.rawValue, f.propertyId])
            _ = try Properties.setOwners(db: db, propertyId: f.propertyId, [PropertyOwner(propertyId: f.propertyId, personId: f.personA, shareBasisPoints: 10_000)])
            let group = try Int64.fetchOne(db, sql: "SELECT groupId FROM category WHERE id = ?", arguments: [f.propertyCategory])
            var repairs = Category(name: "Repairs", type: .expense, groupId: group)
            try repairs.insert(db)
            _ = try TaxExpenseTypeMap.seed(db: db, propertyId: f.propertyId)
            var year = TaxYear(startYear: 2024, personId: f.personA, status: .filed)
            try year.insert(db)
            let batch = try Int64.fetchOne(db, sql: "SELECT importBatchId FROM transaction_ WHERE id = ?", arguments: [f.lisbonTransaction])!
            var repair = Transaction(importBatchId: batch, accountId: f.lisbon,
                                     date: MonthRange.calendar.date(from: DateComponents(year: 2024, month: 7, day: 1))!,
                                     rawDescription: "PLUMBER", amountMinorUnits: -10_000, categoryId: repairs.id, status: .confirmed,
                                     categorizedBy: .manual, fingerprint: "fp-plumber")
            try repair.insert(db)
            return repair.id!
        }
        try await h.syncAll()
        let rent = try h.uuid("transaction_", repair)
        XCTAssertTrue(names(h, zone: f.privateZone).contains(rent), "a Hidden account's repair is in A's zone")
        // Changing it would move the filed return.
        let moves = try write(h.adminMac) { db -> Bool in
            var impacts: [FiledYearImpact] = []
            try db.inSavepoint {
                let raw = try TaxFigures.snapshot(db: db)
                try db.execute(sql: "UPDATE transaction_ SET amountMinorUnits = -20000 WHERE id = ?", arguments: [repair])
                impacts = try FiledYearGuard.filedChanges(db: db, from: raw)
                return .rollback
            }
            return !impacts.isEmpty
        }
        XCTAssertTrue(moves, "precondition: the repair is on the filed return")

        try write(h.adminMac) { db in
            try db.execute(sql: "UPDATE transaction_ SET amountMinorUnits = -20000 WHERE id = ?", arguments: [repair])
        }
        try await h.adminMac.engine.pushPending()
        let report = try await h.adminPhone.engine.pull()
        XCTAssertEqual(report.held, 1)
        XCTAssertEqual(report.filedYearAlert?.records.map(\.recordName), [rent])
        let amount = try read(h.adminPhone) { db in
            try Int.fetchOne(db, sql: "SELECT amountMinorUnits FROM transaction_ WHERE id = ?",
                             arguments: [try SyncRecordStore.localId(table: "transaction_", uuid: rent, db: db)])
        }
        XCTAssertEqual(amount, -10_000, "the phone's filed figures stay")
        assertNoHouseholdLeak(h)
    }

    // MARK: Carried from Task 4's reviews

    /// A deleted private record's delete goes to its private zone, never the household.
    func testPrivateDeletesGoToTheirZone() async throws {
        let h = try TwoPersonHousehold.make()
        let f = h.fixture
        try await h.syncAll()
        let deleted = try h.uuid("transaction_", f.privateTransaction)
        try write(h.adminMac) { db in
            try db.execute(sql: "DELETE FROM documentLink WHERE entityType = 'transaction' AND entityId = ?", arguments: [f.privateTransaction])
            try db.execute(sql: "DELETE FROM transaction_ WHERE id = ?", arguments: [f.privateTransaction])
        }
        try await h.adminMac.engine.pushPending()
        XCTAssertTrue((h.audit.deletesByZone[f.privateZone] ?? []).contains(deleted))
        XCTAssertFalse((h.audit.deletesByZone[SyncZones.household] ?? []).contains(deleted), "never named in the household")
        let left = try await h.cloud.fetch(deleted, zone: f.privateZone)
        XCTAssertNil(left)
        _ = try await h.adminPhone.engine.pull()
        XCTAssertNil(try h.localId("transaction_", uuid: deleted, on: h.adminPhone), "the owner's phone deletes it")
        assertNoHouseholdLeak(h)
    }

    /// A file kept for later lives in its keeper's private zone (`keptByAppUserId`), its copy sealed there too.
    func testKeptFilesAndTheirCopiesStayInTheKeepersZone() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("zones-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let library = folder.appendingPathComponent("Library", isDirectory: true)
        let waiting = folder.appendingPathComponent("Waiting", isDirectory: true)
        let bytes = Data("Synthetic letter kept for later".utf8)
        let sha = DocumentCrypto.sha256(bytes)
        let path = try XCTUnwrap(ImportWaitingList.storedPath(sha256: sha, name: "letter.pdf"))
        try FileManager.default.createDirectory(at: waiting.appendingPathComponent(sha, isDirectory: true), withIntermediateDirectories: true)
        try bytes.write(to: waiting.appendingPathComponent(path))
        let h = try TwoPersonHousehold.make(macDocuments: SyncDocumentFiles(root: library, policy: .eager, waitingRoot: waiting))
        let f = h.fixture
        let kept = try write(h.adminMac) { db -> Int64 in
            var row = ImportWaitingFile(sha256: sha, originalFileName: "letter.pdf", byteCount: Int64(bytes.count), storedRelativePath: path,
                                        text: nil, textStatus: .unknown, reason: "Not recognised", recognisedAs: "Unknown",
                                        keptAt: Date(timeIntervalSince1970: 1_790_000_000), keptByAppUserId: f.admin.appUserId)
            try row.insert(db)
            return row.id!
        }
        try await h.syncAll()
        let uuid = try h.uuid("importWaitingFile", kept)
        let record = try await stored(h, uuid, in: f.privateZone)
        XCTAssertNotNil(record, "the kept file's row is in A's zone")
        let files = await h.cloud.storedRecords().filter { $0.recordType == SyncDocumentFile.recordType && $0.recordName.hasPrefix(uuid) }
        XCTAssertEqual(files.map(\.zone), [f.privateZone], "and its copy")
        XCTAssertEqual(record?.documentFile?.recordName, files.first?.recordName)
        XCTAssertFalse(names(h, zone: SyncZones.household).contains(uuid))
        XCTAssertNil(try h.localId("importWaitingFile", uuid: uuid, on: h.memberDevice))
        XCTAssertNotNil(try h.localId("importWaitingFile", uuid: uuid, on: h.adminPhone))
        assertNoHouseholdLeak(h)
    }

    /// The guard knows move markers (nothing but where the record went) and left-out fields.
    func testGuardKnowsMarkersAndLeftOutFields() throws {
        let h = try TwoPersonHousehold.make()
        let f = h.fixture
        let privateTransaction = try h.uuid("transaction_", f.privateTransaction)
        let account = try h.uuid("account", f.privateAccount)
        try write(h.adminMac) { db in
            let guardian = try SyncZoneGuard(db: db)
            let marker = SyncZoneMoves.marker(uuid: privateTransaction, tableName: "transaction_", zone: SyncZones.household, movedTo: f.privateZone)
            XCTAssertTrue(guardian.review([marker]).isClear, "a marker over a private record's old household copy")
            var carrying = marker
            carrying.fields["note"] = .string("Synthetic")
            XCTAssertEqual(guardian.review([carrying]).violations.map(\.reason), ["a move marker carrying more than where the record went"])
            var tagged = marker
            tagged.importRunUuid = try SyncRecordStore.uuid(for: "importRun", localId: f.privateRun, db: db)
            XCTAssertFalse(guardian.review([tagged]).isClear)
            let nowhere = SyncZoneMoves.marker(uuid: privateTransaction, tableName: "transaction_", zone: SyncZones.household, movedTo: "private-nobody")
            XCTAssertFalse(guardian.review([nowhere]).isClear, "only to a zone of this household")

            var stub = try XCTUnwrap(try SyncTranslator.outgoing(PendingChange(table: "account", localId: f.privateAccount, uuid: account, kind: .update), db: db))
            stub.zone = SyncZones.household
            for column in SyncZoneRouter.privateAccountColumns {
                stub.fields[column] = nil
                stub.clocks[column] = nil
            }
            stub.omittedFields = SyncZoneRouter.privateAccountColumns
            XCTAssertTrue(guardian.review([stub]).isClear, "a stub without its private columns")
            var clocked = stub
            clocked.clocks["sortCode"] = SyncClock(at: Date(timeIntervalSince1970: 1_790_000_000), by: nil)
            XCTAssertEqual(guardian.review([clocked]).violations.map(\.reason), ["carries sortCode, which it leaves out"])
            var unknown = stub
            unknown.omittedFields = ["notAColumn"]
            XCTAssertEqual(guardian.review([unknown]).violations.map(\.reason), ["leaves out notAColumn, which isn't a synced column"])
        }
    }

    /// The read-only phone pulls its zone set, makes nothing, and takes a missing private zone as nothing yet.
    func testReadOnlyPhoneTakesAMissingPrivateZoneAsNothingYet() async throws {
        let h = try TwoPersonHousehold.make()
        try await h.cloud.createZone(SyncZones.household)
        let before = await h.cloud.calls.count
        let report = try await h.adminPhone.engine.syncNow()
        XCTAssertEqual(report.pull.received, 0)
        let calls = Array(await h.cloud.calls.dropFirst(before))
        XCTAssertTrue(calls.contains(.changes(zone: h.fixture.privateZone, since: nil)), "it asked")
        XCTAssertTrue(calls.contains(.changes(zone: SyncZones.household, since: nil)))
        for call in calls {
            switch call {
            case .createZone, .save, .delete: XCTFail("the phone wrote: \(call)")
            case .changes, .fetch: break
            }
        }
        XCTAssertEqual(try count(h.adminPhone, "SELECT COUNT(*) FROM syncStaging"), 0)
    }
}
