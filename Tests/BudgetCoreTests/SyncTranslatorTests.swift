import XCTest
import GRDB
@testable import BudgetCore
@testable import BudgetDemo

/// One simulated device: its own in-memory database, signed in as `user`.
final class SyncTestDevice {
    let manager: DatabaseManager
    let user: String
    var queue: DatabaseQueue { manager.dbQueue }

    init(_ user: String, path: String? = nil) throws {
        manager = try DatabaseManager(path: path)
        try manager.migrate()
        self.user = user
        try queue.write { db in try SyncChangeTracker.setWriter(user, db: db) }
    }

    /// Everything pending, as an upload the server accepted.
    func push() throws -> [SyncIncomingChange] {
        try queue.write { db in
            var sent: [SyncIncomingChange] = []
            var acknowledged: [PendingChange] = []
            // An outgoing payload can give a referenced row its first identity, which queues it too.
            while true {
                let pending = try SyncChangeTracker.pending(db: db).filter { change in !acknowledged.contains { $0.uuid == change.uuid && $0.revision == change.revision } }
                if pending.isEmpty { break }
                for change in pending {
                    if change.kind == .delete {
                        sent.append(.delete(recordName: change.uuid, recordType: change.table))
                    } else if let payload = try SyncTranslator.outgoing(change, db: db) {
                        sent.append(.save(payload))
                    }
                }
                acknowledged += pending
                try SyncChangeTracker.acknowledge(pending, db: db)
            }
            return sent
        }
    }

    @discardableResult
    func receive(_ changes: [SyncIncomingChange]) throws -> [String: IncomingResult] {
        try queue.write { db in try SyncTranslator.apply(changes, db: db, deviceUser: user) }
    }

    func uuid(_ table: String, _ id: Int64) throws -> String {
        try queue.read { db in try XCTUnwrap(SyncRecordStore.existingUUID(table: table, localId: id, db: db)) }
    }

    func localId(_ table: String, _ uuid: String) throws -> Int64? {
        try queue.read { db in try SyncRecordStore.localId(table: table, uuid: uuid, db: db) }
    }

    func pendingUUIDs() throws -> [String: PendingChange.Kind] {
        try queue.read { db in Dictionary(uniqueKeysWithValues: try SyncChangeTracker.pending(db: db).map { ($0.uuid, $0.kind) }) }
    }
}

final class SyncTranslatorTests: XCTestCase {
    private var a: SyncTestDevice!
    private var b: SyncTestDevice!

    override func setUpWithError() throws {
        a = try SyncTestDevice("user-a")
        b = try SyncTestDevice("user-b")
    }

    // MARK: Fixtures

    @discardableResult
    private func account(_ db: Database, _ name: String = "Current") throws -> Int64 {
        var account = Account(name: name, currency: .gbp, kind: .cash, trackingMode: .imported)
        try account.insert(db)
        return account.id!
    }

    private func batch(_ db: Database, account: Int64) throws -> Int64 {
        var batch = ImportBatch(accountId: account, sourceFileName: "synthetic.csv", importedAt: Date(timeIntervalSince1970: 1_700_000_000))
        try batch.insert(db)
        return batch.id!
    }

    @discardableResult
    private func transaction(_ db: Database, account: Int64, batch: Int64, _ description: String, id: Int64? = nil) throws -> Int64 {
        var transaction = Transaction(id: id, importBatchId: batch, accountId: account, date: Date(timeIntervalSince1970: 1_700_000_000),
                                      rawDescription: description, amountMinorUnits: -1234, categoryId: nil, status: .pendingReview,
                                      categorizedBy: .none, fingerprint: "fp-\(description)")
        try transaction.insert(db)
        return transaction.id!
    }

    /// One account with one transaction on A, synced to B. Returns the transaction's UUID.
    private func sharedTransaction() throws -> String {
        let id = try a.queue.write { db -> Int64 in
            let account = try account(db)
            return try transaction(db, account: account, batch: batch(db, account: account), "Synthetic shop")
        }
        try b.receive(try a.push())
        _ = try b.push()
        pause()
        return try a.uuid("transaction_", id)
    }

    /// Clocks are millisecond text: this keeps "since the last sync" strictly after it.
    private func pause() { Thread.sleep(forTimeInterval: 0.01) }

    private func note(_ device: SyncTestDevice, _ uuid: String) throws -> String? {
        let id = try XCTUnwrap(try device.localId("transaction_", uuid))
        return try device.queue.read { db in try String.fetchOne(db, sql: "SELECT note FROM transaction_ WHERE id = ?", arguments: [id]) }
    }

    private func setNote(_ device: SyncTestDevice, _ uuid: String, _ note: String) throws {
        let id = try XCTUnwrap(try device.localId("transaction_", uuid))
        try device.queue.write { db in try db.execute(sql: "UPDATE transaction_ SET note = ? WHERE id = ?", arguments: [note, id]) }
    }

    private func conflicts(_ device: SyncTestDevice) throws -> [SyncConflictRow] {
        try device.queue.read { db in try SyncConflictRow.order(Column("id")).fetchAll(db) }
    }

    /// Fills `count` rows of `table` on B so its next local id differs from A's.
    private func shift(_ device: SyncTestDevice, accounts: Int = 0, groups: Int = 0, properties: Int = 0, categories: Int = 0) throws {
        try device.queue.write { db in
            for i in 0..<accounts { try account(db, "Filler \(i)") }
            for i in 0..<groups { var g = CategoryGroup(name: "Filler group \(i)"); try g.insert(db) }
            for i in 0..<properties { var p = Property(name: "Filler property \(i)", country: "PT"); try p.insert(db) }
            for i in 0..<categories { var c = Category(name: "Filler category \(i)", type: .expense); try c.insert(db) }
        }
    }

    // MARK: Values

    func testSyncValueRoundTripsDatabaseValuesExactly() throws {
        let manager = try DatabaseManager(path: nil)
        try manager.migrate()
        let cases: [(DatabaseValue, String)] = [
            (.null, "TEXT"), ((Int64.min).databaseValue, "INTEGER"), ((Int64.max).databaseValue, "INTEGER"),
            ((-0.0 as Double).databaseValue, "DOUBLE"), (0.1.databaseValue, "DOUBLE"), ((1.0 / 3).databaseValue, "REAL"),
            ("text with ünïcode ✓".databaseValue, "TEXT"), (Data([0, 1, 255]).databaseValue, "BLOB"),
            ("2024-05-06 07:08:09.123".databaseValue, "DATETIME"), ("2024-05-06".databaseValue, "DATETIME"),
            ("not a date".databaseValue, "DATETIME"), ((1 as Int64).databaseValue, "BOOLEAN"), ((0 as Int64).databaseValue, "BOOLEAN"),
            ((2 as Int64).databaseValue, "BOOLEAN"), ((7 as Int64).databaseValue, "DATETIME"), ("1".databaseValue, "INTEGER"),
        ]
        for (value, type) in cases {
            let synced = SyncValue(value, declaredType: type)
            let decoded = try JSONDecoder().decode(SyncValue.self, from: JSONEncoder().encode(synced))
            XCTAssertEqual(decoded, synced, "\(value) as \(type)")
            XCTAssertTrue(SyncMerge.identical(decoded.databaseValue, value), "\(value) as \(type) came back as \(decoded.databaseValue)")
        }
        XCTAssertEqual(SyncValue("2024-05-06 07:08:09.123".databaseValue, declaredType: "DATETIME").isDate, true)
        XCTAssertEqual(SyncValue("2024-05-06".databaseValue, declaredType: "DATETIME"), .string("2024-05-06"))
        XCTAssertEqual(SyncValue((1 as Int64).databaseValue, declaredType: "BOOLEAN"), .bool(true))
        XCTAssertEqual(SyncValue((2 as Int64).databaseValue, declaredType: "BOOLEAN"), .int(2))
    }

    // MARK: Review Focus 2 and 3

    func testSameLocalIdOnTwoDevicesStaysDistinct() throws {
        let accountId = try a.queue.write { db in try account(db) }
        try b.receive(try a.push())
        let accountUUID = try a.uuid("account", accountId)
        let bAccount = try XCTUnwrap(try b.localId("account", accountUUID))
        // Both offline, both create transaction 812.
        _ = try a.queue.write { db in try transaction(db, account: accountId, batch: batch(db, account: accountId), "Made on A", id: 812) }
        _ = try b.queue.write { db in try transaction(db, account: bAccount, batch: batch(db, account: bAccount), "Made on B", id: 812) }
        let fromA = try a.push(), fromB = try b.push()
        try b.receive(fromA)
        try a.receive(fromB)
        let aUUID = try a.uuid("transaction_", 812), bUUID = try b.uuid("transaction_", 812)
        XCTAssertNotEqual(aUUID, bUUID)
        for (device, own, other, ownText, otherText, account) in [(a!, aUUID, bUUID, "Made on A", "Made on B", accountId), (b!, bUUID, aUUID, "Made on B", "Made on A", bAccount)] {
            try device.queue.read { db in
                XCTAssertEqual(try Transaction.fetchCount(db), 2)
                XCTAssertEqual(try String.fetchOne(db, sql: "SELECT rawDescription FROM transaction_ WHERE id = 812"), ownText, "no overwrite")
                let otherId = try XCTUnwrap(try SyncRecordStore.localId(table: "transaction_", uuid: other, db: db))
                XCTAssertNotEqual(otherId, 812)
                XCTAssertEqual(try String.fetchOne(db, sql: "SELECT rawDescription FROM transaction_ WHERE id = ?", arguments: [otherId]), otherText)
                XCTAssertEqual(try Int64.fetchOne(db, sql: "SELECT accountId FROM transaction_ WHERE id = ?", arguments: [otherId]), account)
                XCTAssertEqual(try SyncRecordStore.localId(table: "transaction_", uuid: own, db: db), 812)
            }
        }
    }

    func testOrphanWaitsThenApplies() throws {
        let txId = try a.queue.write { db -> Int64 in
            let account = try account(db)
            return try transaction(db, account: account, batch: batch(db, account: account), "Before its account")
        }
        let changes = try a.push()
        let txUUID = try a.uuid("transaction_", txId)
        let child = changes.filter { if case .save(let p) = $0 { return p.recordType == "transaction_" || p.recordType == "importBatch" }; return false }
        let parent = changes.filter { if case .save(let p) = $0 { return p.recordType == "account" }; return false }
        XCTAssertEqual(child.count, 2)
        // The transaction (and its import batch) before the account.
        let first = try b.receive(child)
        XCTAssertEqual(first[txUUID], .staged("waiting for account, importBatch"))
        try b.queue.read { db in
            XCTAssertEqual(try Transaction.fetchCount(db), 0)
            XCTAssertEqual(try SyncStagingRow.fetchCount(db), 2)
            // No identity for a record that isn't applied: the orphan sweep would send its delete.
            XCTAssertEqual(try SyncRecordRow.fetchCount(db), 0)
            XCTAssertEqual(try SyncChangeTracker.pending(db: db), [])
        }
        try b.queue.write { db in try SyncChangeTracker.refreshSyncTriggers(db: db) }
        XCTAssertEqual(try b.pendingUUIDs(), [:], "an open's orphan sweep finds nothing to delete")
        let second = try b.receive(parent)
        XCTAssertEqual(second[txUUID], .applied)
        try b.queue.read { db in
            XCTAssertEqual(try SyncStagingRow.fetchCount(db), 0)
            let id = try XCTUnwrap(try SyncRecordStore.localId(table: "transaction_", uuid: txUUID, db: db))
            let account = try XCTUnwrap(try SyncRecordStore.localId(table: "account", uuid: a.uuid("account", 1), db: db))
            XCTAssertEqual(try Int64.fetchOne(db, sql: "SELECT accountId FROM transaction_ WHERE id = ?", arguments: [id]), account)
            XCTAssertEqual(try SyncChangeTracker.pending(db: db), [], "applied records don't echo back")
        }
    }

    func testEvidenceLinkWaitsForItsDocument() throws {
        let link = try a.queue.write { db -> Int64 in
            var person = Person(name: "Synthetic person")
            try person.insert(db)
            var document = EvidenceDocument(sha256: "abc", storedRelativePath: "ab/abc.pdf", originalFileName: "x.pdf", byteCount: 3,
                                            addedAt: Date(timeIntervalSince1970: 1_700_000_000))
            try document.insert(db)
            var link = DocumentLink(documentId: document.id!, entity: EvidenceEntity(type: .person, id: person.id!), role: nil,
                                    createdAt: Date(timeIntervalSince1970: 1_700_000_000))
            try link.insert(db)
            return link.id!
        }
        let changes = try a.push()
        let linkUUID = try a.uuid("documentLink", link)
        let isDocument = { (change: SyncIncomingChange) -> Bool in if case .save(let p) = change { return p.recordType == "document" }; return false }
        XCTAssertEqual(try b.receive(changes.filter { !isDocument($0) })[linkUUID], .staged("waiting for document"))
        XCTAssertEqual(try b.receive(changes.filter(isDocument))[linkUUID], .applied)
        try b.queue.read { db in
            XCTAssertEqual(try DocumentLink.fetchCount(db), 1)
            XCTAssertEqual(try SyncStagingRow.fetchCount(db), 0)
        }
    }

    // MARK: Merge

    func testFieldLevelMergeKeepsBothDifferentFields() throws {
        let uuid = try sharedTransaction()
        try setNote(a, uuid, "Note from A")
        let bId = try XCTUnwrap(try b.localId("transaction_", uuid))
        try b.queue.write { db in try db.execute(sql: "UPDATE transaction_ SET rawDescription = 'Renamed on B' WHERE id = ?", arguments: [bId]) }
        // The server takes one upload; the other device takes that record before its own goes through.
        XCTAssertEqual(try b.receive(try a.push())[uuid], .applied)
        XCTAssertEqual(try a.receive(try b.push())[uuid], .applied)
        for device in [a!, b!] {
            let id = try XCTUnwrap(try device.localId("transaction_", uuid))
            try device.queue.read { db in
                let row = try XCTUnwrap(try Row.fetchOne(db, sql: "SELECT note, rawDescription FROM transaction_ WHERE id = ?", arguments: [id]))
                XCTAssertEqual(row["note"] as String?, "Note from A")
                XCTAssertEqual(row["rawDescription"] as String, "Renamed on B")
            }
            XCTAssertEqual(try conflicts(device), [])
        }
    }

    /// Two devices edit one field offline. The server takes only one upload (change tags); the other device
    /// must take that record first, which is where the merge happens: in either order, the later edit wins
    /// on both devices and the earlier value is in the merging device's conflict log.
    func testSameFieldLastWriterWinsAndLogsConflict() throws {
        for earlierPushesFirst in [true, false] {
            a = try SyncTestDevice("user-a")
            b = try SyncTestDevice("user-b")
            let uuid = try sharedTransaction()
            try setNote(a, uuid, "Earlier, on A")
            pause()
            try setNote(b, uuid, "Later, on B")
            let (first, second) = earlierPushesFirst ? (a!, b!) : (b!, a!)
            XCTAssertEqual(try second.receive(try first.push())[uuid], .conflicted(["note"]), "merging device, earlier first: \(earlierPushesFirst)")
            XCTAssertEqual(try first.receive(try second.push())[uuid], .applied, "the merged record is no news to the first device")
            for device in [a!, b!] { XCTAssertEqual(try note(device, uuid), "Later, on B") }
            XCTAssertEqual(try conflicts(first), [])
            let logged = try conflicts(second)
            XCTAssertEqual(logged.count, 1)
            XCTAssertEqual(logged.first?.uuid, uuid)
            XCTAssertEqual(logged.first?.field, "note")
            XCTAssertEqual(logged.first?.losingValueJSON, SyncValue.string("Earlier, on A").json)
            XCTAssertEqual(logged.first?.losingWriter, "user-a")
            XCTAssertEqual(logged.first?.winningWriter, "user-b")
            // A later edit that simply follows the last sync isn't a conflict.
            pause()
            try setNote(a, uuid, "Third, on A")
            XCTAssertEqual(try b.receive(try a.push())[uuid], .applied)
            XCTAssertEqual(try note(b, uuid), "Third, on A")
            XCTAssertEqual(try conflicts(b).count, earlierPushesFirst ? 1 : 0)
        }
    }

    func testIncomingWritesTheFieldClocksItTook() throws {
        let uuid = try sharedTransaction()
        try setNote(a, uuid, "Dated edit")
        let aId = try XCTUnwrap(try a.localId("transaction_", uuid))
        let aClock = try a.queue.read { db in try Date.fetchOne(db, sql: "SELECT modifiedAt FROM syncFieldClock WHERE tableName = 'transaction_' AND localId = ? AND field = 'note'", arguments: [aId]) }
        try b.receive(try a.push())
        let bId = try XCTUnwrap(try b.localId("transaction_", uuid))
        try b.queue.read { db in
            let row = try XCTUnwrap(try Row.fetchOne(db, sql: "SELECT modifiedAt, modifiedBy FROM syncFieldClock WHERE tableName = 'transaction_' AND localId = ? AND field = 'note'", arguments: [bId]))
            XCTAssertEqual(row["modifiedAt"] as Date?, aClock)
            XCTAssertEqual(row["modifiedBy"] as String?, "user-a")
            let star = try Date.fetchOne(db, sql: "SELECT modifiedAt FROM syncFieldClock WHERE tableName = 'transaction_' AND localId = ? AND field = '*'", arguments: [bId])
            XCTAssertNotNil(star, "the insert clock came with the record")
        }
    }

    func testRowWithoutClocksLosesToADatedEdit() throws {
        let uuid = try sharedTransaction()
        // B's copy predates tracking (backfilled): no clocks at all.
        let bId = try XCTUnwrap(try b.localId("transaction_", uuid))
        try b.queue.write { db in
            try SyncChangeTracker.applyingIncoming(db: db) {
                try db.execute(sql: "UPDATE transaction_ SET note = 'Undated' WHERE id = ?", arguments: [bId])
            }
            try db.execute(sql: "DELETE FROM syncFieldClock WHERE tableName = 'transaction_' AND localId = ?", arguments: [bId])
        }
        try setNote(a, uuid, "Dated")
        try b.receive(try a.push())
        XCTAssertEqual(try note(b, uuid), "Dated")
        // And an undated incoming value loses to a dated local one.
        let aId = try XCTUnwrap(try a.localId("transaction_", uuid))
        try a.queue.write { db in
            try db.execute(sql: "UPDATE transaction_ SET note = 'Local and dated' WHERE id = ?", arguments: [aId])
        }
        var undated = try XCTUnwrap(try b.queue.write { db in
            try SyncTranslator.outgoing(PendingChange(table: "transaction_", localId: bId, uuid: uuid, kind: .update), db: db)
        })
        undated.clocks = [:]
        undated.fields["note"] = .string("Undated remote")
        try a.receive([.save(undated)])
        XCTAssertEqual(try note(a, uuid), "Local and dated")
    }

    // MARK: Deletes

    func testDeleteBeatsOfflineEdit() throws {
        let uuid = try sharedTransaction()
        // A deletes; B, offline, edits.
        let aId = try XCTUnwrap(try a.localId("transaction_", uuid))
        try a.queue.write { db in _ = try Transaction.deleteOne(db, key: aId) }
        try setNote(b, uuid, "Edited offline")
        let fromA = try a.push(), fromB = try b.push()
        XCTAssertEqual(try a.receive(fromB)[uuid], .discarded("deleted here"))
        try a.queue.read { db in XCTAssertEqual(try Transaction.fetchCount(db), 0) }
        XCTAssertEqual(try b.receive(fromA)[uuid], .applied)
        try b.queue.read { db in
            XCTAssertEqual(try Transaction.fetchCount(db), 0)
            XCTAssertNil(try SyncRecordStore.localId(table: "transaction_", uuid: uuid, db: db))
            XCTAssertNotNil(try SyncTombstoneRow.fetchOne(db, key: uuid))
            XCTAssertEqual(try SyncChangeTracker.pending(db: db).filter { $0.uuid == uuid }, [], "the offline edit isn't sent")
        }
    }

    func testLinkedDocumentIsNotDeleted() throws {
        let documentId = try a.queue.write { db -> Int64 in
            var document = EvidenceDocument(sha256: "def", storedRelativePath: "de/def.pdf", originalFileName: "receipt.pdf", byteCount: 3,
                                            addedAt: Date(timeIntervalSince1970: 1_700_000_000))
            try document.insert(db)
            return document.id!
        }
        let shared = try a.push()
        let txUUID = try sharedTransaction()
        try b.receive(shared)
        let documentUUID = try a.uuid("document", documentId)
        // B links the document to a transaction while A deletes it.
        let bDocument = try XCTUnwrap(try b.localId("document", documentUUID))
        let bTx = try XCTUnwrap(try b.localId("transaction_", txUUID))
        try b.queue.write { db in
            var link = DocumentLink(documentId: bDocument, entity: .transaction(bTx), role: nil, createdAt: Date(timeIntervalSince1970: 1_700_000_000))
            try link.insert(db)
        }
        try a.queue.write { db in _ = try EvidenceDocument.deleteOne(db, key: documentId) }
        XCTAssertEqual(try b.receive(try a.push())[documentUUID], .kept("linked document"))
        try b.queue.read { db in
            XCTAssertEqual(try EvidenceDocument.fetchCount(db), 1)
            XCTAssertEqual(try DocumentLink.fetchCount(db), 1)
        }
        XCTAssertEqual(try b.pendingUUIDs()[documentUUID], .insert, "sent again")
        // A takes it back, with the link.
        let results = try a.receive(try b.push())
        XCTAssertEqual(results[documentUUID], .applied)
        try a.queue.read { db in
            XCTAssertEqual(try EvidenceDocument.fetchCount(db), 1)
            XCTAssertEqual(try DocumentLink.fetchCount(db), 1)
        }
    }

    func testUnlinkedDocumentDeletesWithItsLinksInOneBatch() throws {
        try a.queue.write { db in
            var person = Person(name: "Synthetic person")
            try person.insert(db)
            var document = EvidenceDocument(sha256: "ghi", storedRelativePath: "gh/ghi.pdf", originalFileName: "x.pdf", byteCount: 3,
                                            addedAt: Date(timeIntervalSince1970: 1_700_000_000))
            try document.insert(db)
            var link = DocumentLink(documentId: document.id!, entity: EvidenceEntity(type: .person, id: person.id!), role: nil)
            try link.insert(db)
        }
        try b.receive(try a.push())
        try a.queue.write { db in _ = try EvidenceDocument.deleteAll(db) }  // the link cascades
        let deletes = try a.push()
        XCTAssertEqual(deletes.count, 2)
        // Deletes apply children first, so the document has no link left when its own delete applies.
        let results = try b.receive(deletes.reversed())
        XCTAssertEqual(Set(results.values), [.applied])
        try b.queue.read { db in
            XCTAssertEqual(try EvidenceDocument.fetchCount(db), 0)
            XCTAssertEqual(try DocumentLink.fetchCount(db), 0)
        }
    }

    func testCascadedRowsLoseTheirIdentityWithoutBeingSent() throws {
        let ownerId = try a.queue.write { db -> Int64 in
            var person = Person(name: "Synthetic owner")
            try person.insert(db)
            var property = Property(name: "Synthetic property", country: "PT")
            try property.insert(db)
            var owner = PropertyOwner(propertyId: property.id!, personId: person.id!, shareBasisPoints: 10_000)
            try owner.insert(db)
            return owner.id!
        }
        try b.receive(try a.push())
        let ownerUUID = try a.uuid("propertyOwner", ownerId)
        try a.queue.write { db in _ = try Property.deleteAll(db) }
        // Only the property's delete reaches B: its owner row cascades there.
        let propertyDelete = try a.push().filter { if case .delete(_, let type) = $0 { return type == "property" }; return false }
        XCTAssertEqual(propertyDelete.count, 1)
        try b.receive(propertyDelete)
        try b.queue.read { db in
            XCTAssertEqual(try PropertyOwner.fetchCount(db), 0)
            XCTAssertNil(try SyncRecordStore.localId(table: "propertyOwner", uuid: ownerUUID, db: db))
            XCTAssertNotNil(try SyncTombstoneRow.fetchOne(db, key: ownerUUID))
            XCTAssertEqual(try SyncChangeTracker.pending(db: db), [], "retired, not sent")
            XCTAssertEqual(try SyncConflictRow.filter(Column("uuid") == ownerUUID).fetchOne(db)?.field, "*", "the loss is logged")
        }
    }

    func testDeleteOfARecordNeverSeenLetsWhatWaitsForItResolve() throws {
        // A requirement whose excluded account was deleted before B ever saw the account.
        let (accountId, requirementId) = try a.queue.write { db -> (Int64, Int64) in
            let account = try account(db)
            var requirement = EvidenceRequirement(name: "Synthetic", scope: .transactionsMatching(categoryIds: [], accountIds: [], descriptionContains: "x"),
                                                  kinds: [], excludedAccountIds: [account], createdAt: Date(timeIntervalSince1970: 1_700_000_000))
            try requirement.insert(db)
            return (account, requirement.id!)
        }
        let accountUUID = try a.uuid("account", accountId)
        let requirementUUID = try a.uuid("evidenceRequirement", requirementId)
        let saves = try a.push().filter { if case .save(let p) = $0 { return p.recordType == "evidenceRequirement" }; return false }
        XCTAssertEqual(try b.receive(saves)[requirementUUID], .staged("waiting for account"))
        XCTAssertEqual(try b.receive([.delete(recordName: accountUUID, recordType: nil)])[requirementUUID], .applied)
        let bId = try XCTUnwrap(try b.localId("evidenceRequirement", requirementUUID))
        try b.queue.read { db in
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT excludedAccountIds FROM evidenceRequirement WHERE id = ?", arguments: [bId]), "[0]")
        }
    }

    // MARK: The same record made on both devices

    func testRecordMadeOnBothDevicesMergesUnderOneName() throws {
        // Both devices seed the built-in categories; both give them identities.
        _ = try a.queue.write { db in try SyncRecordStore.backfill(db: db) }
        _ = try b.queue.write { db in try SyncRecordStore.backfill(db: db) }
        let fromA = try a.push(), fromB = try b.push()
        let seeded = try a.queue.read { db in try Category.fetchCount(db) }
        XCTAssertGreaterThan(seeded, 0)
        try b.receive(fromA)
        try a.receive(fromB)
        // And once more, so each side's re-keyed or merged rows reach the other.
        try b.receive(try a.push())
        try a.receive(try b.push())
        for device in [a!, b!] {
            try device.queue.read { db in XCTAssertEqual(try Category.fetchCount(db), seeded, "no duplicate") }
        }
        let names = { (device: SyncTestDevice) in
            try device.queue.read { db in
                Dictionary(uniqueKeysWithValues: try Row.fetchAll(db, sql: """
                    SELECT c.builtInRole, s.uuid FROM category c JOIN syncRecord s ON s.tableName = 'category' AND s.localId = c.id
                    """).map { ($0["builtInRole"] as String, $0["uuid"] as String) })
            }
        }
        XCTAssertEqual(try names(a), try names(b))
        XCTAssertEqual(try names(a).count, seeded)
    }

    // MARK: References (ruling R1, R2)

    func testLogicalReferenceRoundTrips() throws {
        let categoryId = try a.queue.write { db -> Int64 in
            var group = CategoryGroup(name: "Synthetic group")
            try group.insert(db)
            var category = Category(name: "Synthetic category", type: .expense, groupId: group.id)
            try category.insert(db)
            return category.id!
        }
        try shift(b, groups: 3)
        try b.receive(try a.push())
        let bCategory = try XCTUnwrap(try b.localId("category", try a.uuid("category", categoryId)))
        try b.queue.read { db in
            let groupId = try XCTUnwrap(try Int64.fetchOne(db, sql: "SELECT groupId FROM category WHERE id = ?", arguments: [bCategory]))
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT name FROM categoryGroup WHERE id = ?", arguments: [groupId]), "Synthetic group")
        }
    }

    func testPolymorphicReferencesRoundTrip() throws {
        let (linkId, otherLinkId, waiverId) = try a.queue.write { db -> (Int64, Int64, Int64) in
            let account = try account(db)
            let tx = try transaction(db, account: account, batch: batch(db, account: account), "Linked")
            var document = EvidenceDocument(sha256: "poly", storedRelativePath: "po/poly.pdf", originalFileName: "p.pdf", byteCount: 1,
                                            addedAt: Date(timeIntervalSince1970: 1_700_000_000))
            try document.insert(db)
            var link = DocumentLink(documentId: document.id!, entity: .transaction(tx), role: "receipt")
            try link.insert(db)
            var other = DocumentLink(documentId: document.id!, entity: EvidenceEntity(type: .other, id: 4242), role: nil)
            try other.insert(db)
            var requirement = EvidenceRequirement(name: "Req", scope: .transactionsInCategory(categoryId: 1), kinds: [],
                                                  createdAt: Date(timeIntervalSince1970: 1_700_000_000))
            try requirement.insert(db)
            var waiver = EvidenceWaiver(requirementId: requirement.id!, entity: .transaction(tx), reason: .notAvailable)
            try waiver.insert(db)
            return (link.id!, other.id!, waiver.id!)
        }
        try shift(b, accounts: 2)
        try b.queue.write { db in
            let account = try account(db, "Filler tx account")
            for i in 0..<5 { try transaction(db, account: account, batch: batch(db, account: account), "Filler \(i)") }
        }
        try b.receive(try a.push())
        try b.queue.read { db in
            let link = try XCTUnwrap(try DocumentLink.fetchOne(db, key: try XCTUnwrap(try SyncRecordStore.localId(table: "documentLink", uuid: a.uuid("documentLink", linkId), db: db))))
            XCTAssertEqual(link.entityType, .transaction)
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT rawDescription FROM transaction_ WHERE id = ?", arguments: [link.entityId]), "Linked")
            let other = try XCTUnwrap(try DocumentLink.fetchOne(db, key: try XCTUnwrap(try SyncRecordStore.localId(table: "documentLink", uuid: a.uuid("documentLink", otherLinkId), db: db))))
            XCTAssertEqual(other.entityId, 4242, "an `other` id isn't a row id: it travels as it is")
            let waiver = try XCTUnwrap(try EvidenceWaiver.fetchOne(db, key: try XCTUnwrap(try SyncRecordStore.localId(table: "evidenceWaiver", uuid: a.uuid("evidenceWaiver", waiverId), db: db))))
            XCTAssertEqual(waiver.entityId, link.entityId)
        }
    }

    func testJSONReferencesRoundTrip() throws {
        let ids = try a.queue.write { db -> [String: Int64] in
            let account = try account(db)
            var group = CategoryGroup(name: "JSON group")
            try group.insert(db)
            var category = Category(name: "JSON category", type: .expense, groupId: group.id)
            try category.insert(db)
            var property = Property(name: "JSON property", country: "PT")
            try property.insert(db)
            var forecastGroup = ForecastGroup(name: "Planned", note: nil, isEnabled: true, isSystemManaged: false)
            try forecastGroup.insert(db)
            var entry = ForecastEntry(groupId: forecastGroup.id!, categoryId: category.id!, amountMinorUnits: -100, frequency: .monthly, interval: 1,
                                      startDate: Date(timeIntervalSince1970: 1_700_000_000), endDate: nil, isEnabled: true, status: .manual, note: nil)
            try entry.insert(db)
            var scenario = Scenario(name: "S", createdAt: Date(timeIntervalSince1970: 1_700_000_000))
            try scenario.insert(db)
            var requirements: [EvidenceRequirement] = [
                EvidenceRequirement(name: "a", scope: .transactionsInCategory(categoryId: category.id!), kinds: [], excludedAccountIds: [account]),
                EvidenceRequirement(name: "b", scope: .transactionsInCategoryGroup(groupId: group.id!), kinds: []),
                EvidenceRequirement(name: "c", scope: .transactionsMatching(categoryIds: [category.id!], accountIds: [account], descriptionContains: nil), kinds: []),
                EvidenceRequirement(name: "d", scope: .periodic(entity: EvidenceEntity(type: .property, id: property.id!), every: .quarter), kinds: []),
                EvidenceRequirement(name: "e", scope: .single(entity: EvidenceEntity(type: .account, id: account)), kinds: []),
                EvidenceRequirement(name: "f", scope: .recordsOfProperty(propertyId: property.id!, recordType: .rentReceipt), kinds: []),
            ]
            for i in requirements.indices { try requirements[i].insert(db) }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            func json(_ value: some Encodable) throws -> String { String(decoding: try encoder.encode(value), as: UTF8.self) }
            var accountRule = ImportRule(kind: .statementAccount, matchKey: "k1", matchLabel: "l", actionJSON: try json(StatementAccountAction(accountId: account)),
                                         actionLabel: "a", createdAt: Date(timeIntervalSince1970: 1_700_000_000))
            try accountRule.insert(db)
            var linkRule = ImportRule(kind: .link, matchKey: "k2", matchLabel: "l", actionJSON: try json(LinkAction(entity: EvidenceEntity(type: .property, id: property.id!), role: "deed")),
                                      actionLabel: "a", createdAt: Date(timeIntervalSince1970: 1_700_000_000))
            try linkRule.insert(db)
            let fingerprint = "\(forecastGroup.id!)|\(category.id!)|-100|monthly|1|1700000000.0|-|true|manual|a | note|-|account:\(account)|[1700000000.0|false|-|-|\(category.id!)]|[1702592000.0|true|-|-|-]"
            let journal = ScenarioApplyJournal(
                operations: [.init(differenceId: entry.id!, kind: .added, categoryName: "JSON category",
                                   created: [.init(entryId: entry.id!, after: fingerprint)],
                                   modified: [.init(entryId: entry.id!, before: .init(endDate: Date(timeIntervalSince1970: 1_700_000_000), isEnabled: true), after: fingerprint)],
                                   categoryIds: [category.id!])],
                enabledGroupIds: [forecastGroup.id!], createdGroupIds: [forecastGroup.id!], skipped: ["x"],
                boundary: Date(timeIntervalSince1970: 1_700_000_000), lastEntryId: entry.id!)
            var application = ScenarioApplication(scenarioId: scenario.id!, appliedAt: Date(timeIntervalSince1970: 1_700_000_000), journal: try json(journal))
            try application.insert(db)
            return ["account": account, "group": group.id!, "category": category.id!, "property": property.id!, "forecastGroup": forecastGroup.id!,
                    "entry": entry.id!, "rule1": accountRule.id!, "rule2": linkRule.id!, "application": application.id!,
                    "req0": requirements[0].id!]
        }
        try shift(b, accounts: 3, groups: 2, properties: 4, categories: 5)
        try b.queue.write { db in
            var g = ForecastGroup(name: "Filler", note: nil, isEnabled: true, isSystemManaged: false)
            try g.insert(db)
        }
        let changes = try a.push()
        let results = try b.receive(changes)
        XCTAssertTrue(results.values.allSatisfy { $0 == .applied }, "\(results.values.filter { $0 != .applied })")
        // On B, every JSON column is what B's own code would write for B's ids.
        let local = { (key: String, table: String) throws -> Int64 in try XCTUnwrap(try self.b.localId(table, try self.a.uuid(table, ids[key]!))) }
        let account = try local("account", "account"), category = try local("category", "category"), group = try local("group", "categoryGroup")
        let property = try local("property", "property"), forecastGroup = try local("forecastGroup", "forecastGroup"), entry = try local("entry", "forecastEntry")
        XCTAssertNotEqual(account, ids["account"])
        XCTAssertNotEqual(property, ids["property"])
        try b.queue.read { db in
            let scopes = Set(try String.fetchAll(db, sql: "SELECT scope FROM evidenceRequirement"))
            XCTAssertEqual(scopes, [
                "{\"transactionsInCategory\":{\"categoryId\":\(category)}}",
                "{\"transactionsInCategoryGroup\":{\"groupId\":\(group)}}",
                "{\"transactionsMatching\":{\"accountIds\":[\(account)],\"categoryIds\":[\(category)]}}",
                "{\"periodic\":{\"entity\":{\"id\":\(property),\"type\":\"property\"},\"every\":\"quarter\"}}",
                "{\"single\":{\"entity\":{\"id\":\(account),\"type\":\"account\"}}}",
                "{\"recordsOfProperty\":{\"propertyId\":\(property),\"recordType\":\"rentReceipt\"}}",
            ])
            let req0 = try XCTUnwrap(try SyncRecordStore.localId(table: "evidenceRequirement", uuid: a.uuid("evidenceRequirement", ids["req0"]!), db: db))
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT excludedAccountIds FROM evidenceRequirement WHERE id = ?", arguments: [req0]), "[\(account)]")
            XCTAssertEqual(Set(try String.fetchAll(db, sql: "SELECT actionJSON FROM importRule")),
                           ["{\"accountId\":\(account)}", "{\"entity\":{\"id\":\(property),\"type\":\"property\"},\"role\":\"deed\"}"])
            let journal = try XCTUnwrap(try ScenarioApplication.fetchOne(db)?.decodedJournal)
            let fingerprint = "\(forecastGroup)|\(category)|-100|monthly|1|1700000000.0|-|true|manual|a | note|-|account:\(account)|[1700000000.0|false|-|-|\(category)]|[1702592000.0|true|-|-|-]"
            XCTAssertEqual(journal.operations.first?.differenceId, entry)
            XCTAssertEqual(journal.operations.first?.created.first?.entryId, entry)
            XCTAssertEqual(journal.operations.first?.created.first?.after, fingerprint)
            XCTAssertEqual(journal.operations.first?.modified.first?.entryId, entry)
            XCTAssertEqual(journal.operations.first?.modified.first?.after, fingerprint)
            XCTAssertEqual(journal.operations.first?.categoryIds, [category])
            XCTAssertEqual(journal.enabledGroupIds, [forecastGroup])
            XCTAssertEqual(journal.createdGroupIds, [forecastGroup])
            XCTAssertEqual(journal.lastEntryId, entry)
            XCTAssertEqual(journal.boundary, Date(timeIntervalSince1970: 1_700_000_000))
        }
        // Going out, the same JSON carries UUIDs only.
        let scope = changes.compactMap { change -> String? in
            if case .save(let p) = change, p.recordType == "evidenceRequirement", case .string(let s) = p.fields["scope"]!, s.contains("transactionsInCategory\"") { return s }
            return nil
        }
        XCTAssertEqual(scope, ["{\"transactionsInCategory\":{\"categoryId\":\"\(try a.uuid("category", ids["category"]!))\"}}"])
    }

    func testJSONIdOfADeletedRowNamesNoRow() throws {
        let journalId = try a.queue.write { db -> Int64 in
            var scenario = Scenario(name: "S", createdAt: Date(timeIntervalSince1970: 1_700_000_000))
            try scenario.insert(db)
            let journal = ScenarioApplyJournal(operations: [], enabledGroupIds: [], createdGroupIds: [987_654], skipped: [], lastEntryId: nil)
            var application = ScenarioApplication(scenarioId: scenario.id!, appliedAt: Date(timeIntervalSince1970: 1_700_000_000),
                                                  journal: String(decoding: try JSONEncoder().encode(journal), as: UTF8.self))
            try application.insert(db)
            return application.id!
        }
        try b.receive(try a.push())
        let bId = try XCTUnwrap(try b.localId("scenarioApplication", try a.uuid("scenarioApplication", journalId)))
        let journal = try b.queue.read { db in try XCTUnwrap(try ScenarioApplication.fetchOne(db, key: bId)?.decodedJournal) }
        XCTAssertEqual(journal.createdGroupIds, [0])
    }

    func testImportChangeRowsRoundTrip() throws {
        let runId = try a.queue.write { db -> Int64 in
            var run = ImportRun(confirmedAt: Date(timeIntervalSince1970: 1_700_000_000), entryPoint: "test", summary: "synthetic run")
            try run.insert(db)
            let account = try account(db)
            var folder = SourceFolder(path: "/synthetic/folder", bookmark: nil, name: "Synthetic", lastScanAt: nil)
            try folder.insert(db)
            try ImportChangeCapture.begin(db: db)
            let tx = try transaction(db, account: account, batch: batch(db, account: account), "Imported")
            var document = EvidenceDocument(sha256: "imp", storedRelativePath: "im/imp.pdf", originalFileName: "imp.pdf", byteCount: 1,
                                            extractedText: "SYNTHETIC TEXT", sourceFolderId: folder.id, sourceRelativePath: "inbox/imp.pdf",
                                            addedAt: Date(timeIntervalSince1970: 1_700_000_000))
            try document.insert(db)
            var link = DocumentLink(documentId: document.id!, entity: .transaction(tx), role: nil, createdAt: Date(timeIntervalSince1970: 1_700_000_000))
            try link.insert(db)
            var file = SourceFile(folderId: folder.id!, relativePath: "inbox/imp.pdf", size: 1, modifiedAt: Date(timeIntervalSince1970: 1_700_000_000),
                                  sha256: "imp", documentId: document.id, lastSeenAt: Date(timeIntervalSince1970: 1_700_000_000))
            try file.insert(db)
            try ImportRuleStore.learn(db: db, kind: .statementAccount, key: "sig", matchLabel: "l", action: StatementAccountAction(accountId: account),
                                      actionLabel: "a", now: Date(timeIntervalSince1970: 1_700_000_000))
            try db.execute(sql: "UPDATE transaction_ SET note = 'edited in the run' WHERE id = ?", arguments: [tx])
            _ = try ImportChangeCapture.finish(db: db, runId: run.id!)
            return run.id!
        }
        try shift(b, accounts: 2)
        try b.queue.write { db in
            let account = try account(db, "Filler")
            for i in 0..<3 { try transaction(db, account: account, batch: batch(db, account: account), "Filler \(i)") }
        }
        let results = try b.receive(try a.push())
        XCTAssertTrue(results.values.allSatisfy { $0 == .applied }, "\(results.values.filter { $0 != .applied })")
        let runUUID = try a.uuid("importRun", runId)
        let bRun = try XCTUnwrap(try b.localId("importRun", runUUID))
        try b.queue.read { db in
            let changes = try ImportChange.filter(Column("runId") == bRun).order(Column("seq")).fetchAll(db)
            XCTAssertEqual(changes.map(\.tableName), ["importBatch", "transaction_", "document", "documentLink", "sourceFile", "importRule", "transaction_"])
            // A synced table's row: exactly what this device's capture would record of its own row now.
            for change in changes where ["importBatch", "documentLink", "importRule"].contains(change.tableName) {
                XCTAssertEqual(change.afterJSON, try ImportChangeCapture.rowJSON(db: db, table: change.tableName, rowId: change.rowId), change.tableName)
            }
            let txChanges = changes.filter { $0.tableName == "transaction_" }
            XCTAssertEqual(txChanges.last?.afterJSON, try ImportChangeCapture.rowJSON(db: db, table: "transaction_", rowId: txChanges[0].rowId))
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT rawDescription FROM transaction_ WHERE id = ?", arguments: [txChanges[0].rowId]), "Imported")
            // The document's local-only columns (its text, where it lies on A) don't travel.
            let document = try XCTUnwrap(changes.first { $0.tableName == "document" }?.afterJSON)
            XCTAssertFalse(document.contains("SYNTHETIC TEXT"))
            XCTAssertFalse(document.contains("inbox/imp.pdf"))
            XCTAssertFalse(document.contains("sourceFolderId"))
            XCTAssertTrue(document.contains("\"sha256\":\"imp\""))
            // A change to a table that doesn't sync names no row here.
            let sourceFile = try XCTUnwrap(changes.first { $0.tableName == "sourceFile" })
            XCTAssertEqual(sourceFile.rowId, 0)
            XCTAssertNil(sourceFile.beforeJSON)
            XCTAssertNil(sourceFile.afterJSON)
            // The nested action JSON of the learnt rule names B's account.
            let rule = try XCTUnwrap(changes.first { $0.tableName == "importRule" }?.afterJSON)
            let account = try XCTUnwrap(try SyncRecordStore.localId(table: "account", uuid: a.uuid("account", 1), db: db))
            XCTAssertTrue(rule.contains("\"actionJSON\":\"{\\\"accountId\\\":\(account)}\""), rule)
        }
    }

    func testMortgageTermsTakeTheirPropertysLocalId() throws {
        let propertyId = try a.queue.write { db -> Int64 in
            var property = Property(name: "Mortgaged", country: "PT")
            try property.insert(db)
            let terms = PropertyMortgageTerms(propertyId: property.id!, revisionMonths: [3, 9])
            try terms.insert(db)
            return property.id!
        }
        try shift(b, properties: 3)
        let termsUUID = try a.uuid("propertyMortgageTerms", propertyId)
        try b.receive(try a.push())
        let bProperty = try XCTUnwrap(try b.localId("property", try a.uuid("property", propertyId)))
        XCTAssertNotEqual(bProperty, propertyId)
        XCTAssertEqual(try b.localId("propertyMortgageTerms", termsUUID), bProperty)
        try b.queue.read { db in
            XCTAssertEqual(try Int64.fetchAll(db, sql: "SELECT propertyId FROM propertyMortgageTerms"), [bProperty])
        }
    }

    // MARK: The demo database

    func testEveryColumnRoundTrips() throws {
        let demo = try SyncTestDevice("user-demo")
        let evidence = FileManager.default.temporaryDirectory.appendingPathComponent("SyncDemo-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: evidence) }
        try DemoDatabase.build(dbQueue: demo.queue, evidenceRoot: evidence)
        _ = try demo.queue.write { db in try SyncRecordStore.backfill(db: db) }
        let exported = try demo.push()
        let rows = try demo.queue.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM syncRecord")! }
        XCTAssertEqual(exported.count, rows, "one payload per synced row")
        let empty = try SyncTestDevice("user-empty")
        // Its local ids start elsewhere, so a reference that travelled untranslated would point at the
        // wrong row (or none) and show up below.
        try empty.queue.write { db in
            for (index, table) in SyncSchema.tables.enumerated() {
                try db.execute(sql: "INSERT OR REPLACE INTO sqlite_sequence(name, seq) VALUES (?, ?)", arguments: [table.name, 5_000 + 37 * index])
            }
        }
        let results = try empty.receive(exported)
        XCTAssertEqual(results.count, exported.count)
        XCTAssertEqual(results.values.filter { $0 != .applied }.count, 0, "\(Set(results.values.filter { $0 != .applied }))")
        // Every record comes back out of the empty database as the same payload: identical rows apart from
        // local ids (references compare by UUID).
        let original = Dictionary(uniqueKeysWithValues: exported.compactMap { change -> (String, SyncPayload)? in
            if case .save(let p) = change { return (p.recordName, p) }
            return nil
        })
        let copied = try empty.queue.write { db -> [String: SyncPayload] in
            var result: [String: SyncPayload] = [:]
            for record in try SyncRecordRow.fetchAll(db) {
                let payload = try XCTUnwrap(try SyncTranslator.outgoing(PendingChange(table: record.tableName, localId: record.localId, uuid: record.uuid, kind: .update), db: db))
                result[record.uuid] = payload
            }
            return result
        }
        XCTAssertEqual(Set(copied.keys), Set(original.keys))
        let sameIds = try demo.queue.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM syncRecord")! }
        let moved = try empty.queue.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM syncRecord WHERE localId >= 5000")! }
        XCTAssertGreaterThan(moved, sameIds * 9 / 10, "most records have a different local id there")
        var differences: [String] = []
        for (name, payload) in original where copied[name] != payload {
            let other = copied[name]
            let fields = payload.fields.keys.filter { payload.fields[$0] != other?.fields[$0] }.sorted()
            differences.append("\(payload.recordType) \(fields)")
        }
        XCTAssertEqual(differences, [])
        // Every reference names the same record on both sides, looked up directly (not through the translator).
        XCTAssertEqual(try referenceView(empty), try referenceView(demo))
        XCTAssertGreaterThan(try referenceView(demo).values.reduce(0) { $0 + $1.count }, 4_000)
        // Same row counts in every synced table, and every non-reference column byte-identical as a multiset.
        for table in SyncSchema.tables {
            let references = Set(table.foreignKeys.keys).union(SyncSchema.logicalReferences(of: table.name).keys)
                .union(SyncSchema.polymorphicReferences(of: table.name).map(\.idColumn))
                .union(SyncSchema.jsonReferences(of: table.name).map(\.column))
            let plain = table.syncedColumns.filter { !references.contains($0) && $0 != table.localIdColumn }
            let select = plain.isEmpty ? "1" : plain.map { "quote(\"\($0)\")" }.joined(separator: " || '|' || ")
            let sql = "SELECT \(select) FROM \"\(table.name)\""
            let before = try demo.queue.read { db in try String.fetchAll(db, sql: sql).sorted() }
            let after = try empty.queue.read { db in try String.fetchAll(db, sql: sql).sorted() }
            XCTAssertEqual(before, after, table.name)
        }
        try empty.queue.read { db in
            XCTAssertEqual(try SyncStagingRow.fetchCount(db), 0)
            XCTAssertEqual(try SyncChangeTracker.pending(db: db), [])
            // Local-only columns don't travel.
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM document WHERE extractedText IS NOT NULL OR sourceRelativePath IS NOT NULL"), 0)
        }
        let byType = Dictionary(grouping: original.values, by: \.recordType).mapValues(\.count)
        let total = byType.values.reduce(0, +)
        print("Demo round trip: \(total) records exported and imported, \(byType.count) record types")
    }

    /// For each record (by UUID), every reference it holds as `place=UUID of the row named` (`-` for none),
    /// read from the device's own rows and `syncRecord`.
    private func referenceView(_ device: SyncTestDevice) throws -> [String: [String]] {
        try device.queue.read { db in
            var names: [String: String] = [:]
            for record in try SyncRecordRow.fetchAll(db) { names["\(record.tableName)#\(record.localId)"] = record.uuid }
            func name(_ table: String, _ id: Int64?) -> String { id.map { names["\(table)#\($0)"] ?? "missing:\($0)" } ?? "-" }
            var view: [String: [String]] = [:]
            for table in SyncSchema.tables {
                let logical = Dictionary(uniqueKeysWithValues: SyncSchema.logicalReferences.compactMap { key, target -> (String, String)? in
                    let parts = key.split(separator: ".").map(String.init)
                    return parts[0] == table.name ? (parts[1], target) : nil
                })
                let polymorphic = SyncSchema.polymorphicReferences(of: table.name)
                let json = SyncSchema.jsonReferences(of: table.name)
                for row in try Row.fetchAll(db, sql: "SELECT * FROM \"\(table.name)\"") {
                    let own = name(table.name, row[table.localIdColumn])
                    var places: [String] = []
                    for (column, target) in table.foreignKeys.merging(logical, uniquingKeysWith: { a, _ in a }) {
                        places.append("\(column)=\(name(target, row[column]))")
                    }
                    for reference in polymorphic {
                        let type: String = row[reference.typeColumn]
                        let id: Int64 = row[reference.idColumn]
                        places.append("\(reference.idColumn)=\(reference.targets[type].map { name($0, id) } ?? "\(type):\(id)")")
                    }
                    for reference in json {
                        guard case .rules(let rules) = reference.content, let text: String = row[reference.column],
                              let root = SyncJSONNode.parse(text) else { continue }
                        let bytes = Array(text.utf8)
                        func visit(_ node: SyncJSONNode, _ path: String) {
                            if let rule = rules.first(where: { $0.path == path }) {
                                switch (rule.target, node.kind) {
                                case (.row(let target), .number):
                                    places.append("\(reference.column).\(path)=\(name(target, Int64(String(decoding: bytes[node.range], as: UTF8.self))))")
                                case (.evidenceEntity, .object(let members)):
                                    if case .string(let type)? = members.first(where: { $0.key == "type" })?.value.kind,
                                       let idNode = members.first(where: { $0.key == "id" })?.value {
                                        let id = Int64(String(decoding: bytes[idNode.range], as: UTF8.self))
                                        places.append("\(reference.column).\(path)=\(SyncSchema.evidenceEntityTables[type].map { name($0, id) } ?? "\(type)")")
                                    }
                                default: break
                                }
                                return
                            }
                            switch node.kind {
                            case .object(let members): for m in members { visit(m.value, path.isEmpty ? m.key : path + "." + m.key) }
                            case .array(let elements): for e in elements { visit(e, path + "[]") }
                            default: break
                            }
                        }
                        visit(root, "")
                    }
                    view[own] = places.sorted()
                }
            }
            return view
        }
    }

    // MARK: Staging bookkeeping

    func testAStagedRecordIsReplacedByANewerArrival() throws {
        let txId = try a.queue.write { db -> Int64 in
            let account = try account(db)
            return try transaction(db, account: account, batch: batch(db, account: account), "Waiting")
        }
        let first = try a.push()
        let txUUID = try a.uuid("transaction_", txId)
        let onlyChild = first.filter { if case .save(let p) = $0 { return p.recordType == "transaction_" }; return false }
        try b.receive(onlyChild)
        try a.queue.write { db in try db.execute(sql: "UPDATE transaction_ SET note = 'newer' WHERE id = ?", arguments: [txId]) }
        try b.receive(try a.push())
        try b.queue.read { db in XCTAssertEqual(try SyncStagingRow.fetchCount(db), 1) }
        XCTAssertEqual(try b.receive(first.filter { if case .save(let p) = $0 { return p.recordType != "transaction_" }; return false })[txUUID], .applied)
        XCTAssertEqual(try note(b, txUUID), "newer")
    }
}

extension SyncValue {
    var isDate: Bool { if case .date = self { return true } else { return false } }
}
