import XCTest
import GRDB
@testable import BudgetCore
import TestSupport

/// Task 3 review fixes: conflicts by per-field base, unique keys that keep different records apart,
/// deleted parents by foreign-key action, and redirects instead of deletes when two records merge.
final class SyncConflictTests: XCTestCase {
    private var a: SyncTestDevice!
    private var b: SyncTestDevice!

    override func setUpWithError() throws {
        a = try SyncTestDevice("user-a")
        b = try SyncTestDevice("user-b")
    }

    // MARK: Fixtures

    @discardableResult
    private func account(_ db: Database, _ name: String, main: Bool = false) throws -> Int64 {
        var account = Account(name: name, currency: .gbp, kind: .cash, trackingMode: .imported)
        try account.insert(db)
        if main { try db.execute(sql: "UPDATE account SET isMain = 1 WHERE id = ?", arguments: [account.id!]) }
        return account.id!
    }

    private func sharedTransaction() throws -> String {
        let id = try a.queue.write { db -> Int64 in
            let account = try account(db, "Current")
            var batch = ImportBatch(accountId: account, sourceFileName: "s.csv", importedAt: Date(timeIntervalSince1970: 1_700_000_000))
            try batch.insert(db)
            var tx = Transaction(importBatchId: batch.id!, accountId: account, date: Date(timeIntervalSince1970: 1_700_000_000),
                                 rawDescription: "Synthetic shop", amountMinorUnits: -100, categoryId: nil, status: .pendingReview,
                                 categorizedBy: .none, fingerprint: "fp")
            try tx.insert(db)
            return tx.id!
        }
        try b.receive(try a.push())
        pause()
        return try a.uuid("transaction_", id)
    }

    private func pause() { Thread.sleep(forTimeInterval: 0.01) }

    private func column(_ device: SyncTestDevice, _ table: String, _ uuid: String, _ column: String) throws -> DatabaseValue {
        let id = try XCTUnwrap(try device.localId(table, uuid), "\(table) \(uuid)")
        return try device.queue.read { db in try XCTUnwrap(try Row.fetchOne(db, sql: "SELECT \(column) FROM \(table) WHERE id = ?", arguments: [id]))[0] }
    }

    private func set(_ device: SyncTestDevice, _ table: String, _ uuid: String, _ column: String, _ value: DatabaseValueConvertible?) throws {
        let id = try XCTUnwrap(try device.localId(table, uuid))
        try device.queue.write { db in try db.execute(sql: "UPDATE \(table) SET \(column) = ? WHERE id = ?", arguments: [value, id]) }
    }

    private func note(_ device: SyncTestDevice, _ uuid: String) throws -> String? {
        String.fromDatabaseValue(try column(device, "transaction_", uuid, "note"))
    }

    private func losing(_ device: SyncTestDevice) throws -> [String] {
        try device.queue.read { db in try String.fetchAll(db, sql: "SELECT losingValueJSON FROM syncConflict ORDER BY id") }
    }

    private func logged(_ text: String) -> String { SyncValue.string(text).json }

    // MARK: Conflicts by per-field base (review 1)

    /// (a) A's offline note survives a pull of an unrelated field; a later remote note is then a conflict.
    func testAnUnrelatedPullDoesNotHideALocalEdit() throws {
        let uuid = try sharedTransaction()
        try set(a, "transaction_", uuid, "note", "A's offline note")
        pause()
        try set(b, "transaction_", uuid, "rawDescription", "Renamed on B")
        XCTAssertEqual(try a.receive(try b.push())[uuid], .applied)
        XCTAssertEqual(try note(a, uuid), "A's offline note")
        pause()
        try set(b, "transaction_", uuid, "note", "B's later note")
        XCTAssertEqual(try a.receive(try b.push())[uuid], .conflicted(["note"]))
        XCTAssertEqual(try note(a, uuid), "B's later note")
        XCTAssertEqual(try losing(a), [logged("A's offline note")])
        XCTAssertEqual(try b.receive(try a.push())[uuid], .applied)
        XCTAssertEqual(try note(b, uuid), "B's later note")
    }

    /// (b) B's offline edit, made before A's acknowledged upload and A's later edit, is logged, not lost.
    func testAnEditMadeBeforeTheOtherSidesUploadIsNotLost() throws {
        let uuid = try sharedTransaction()
        try set(b, "transaction_", uuid, "note", "B offline")
        pause()
        try set(a, "transaction_", uuid, "rawDescription", "A's upload")
        _ = try a.push()  // acknowledged
        pause()
        try set(a, "transaction_", uuid, "note", "A later")
        let server = try a.push()
        XCTAssertEqual(try b.receive(server)[uuid], .conflicted(["note"]))
        XCTAssertEqual(try losing(b), [logged("B offline")])
        XCTAssertEqual(try note(b, uuid), "A later")
        XCTAssertEqual(String.fromDatabaseValue(try column(b, "transaction_", uuid, "rawDescription")), "A's upload")
        XCTAssertEqual(try a.receive(try b.push())[uuid], .applied)
        XCTAssertEqual(try note(a, uuid), "A later")
    }

    /// (b), the order that lost it: B takes A's acknowledged upload, A edits again, and B's upload goes
    /// through first. A keeps its later note and logs B's.
    func testAnEditMadeBeforeTheOtherSidesUploadIsLoggedWhenItArrivesFirst() throws {
        let uuid = try sharedTransaction()
        try set(b, "transaction_", uuid, "note", "B offline")
        pause()
        try set(a, "transaction_", uuid, "rawDescription", "A's upload")
        try b.receive(try a.push())  // acknowledged, and taken by B before its own upload
        pause()
        try set(a, "transaction_", uuid, "note", "A later")
        XCTAssertEqual(try a.receive(try b.push())[uuid], .conflicted(["note"]))
        XCTAssertEqual(try note(a, uuid), "A later")
        XCTAssertEqual(try losing(a), [logged("B offline")])
        XCTAssertEqual(try b.receive(try a.push())[uuid], .applied)
        XCTAssertEqual(try note(b, uuid), "A later")
    }

    /// Both devices edit the same field offline, in every order: the later edit wins on both, and the
    /// earlier value is in a conflict log exactly once.
    func testOfflineEditsOnBothDevicesAlwaysLogTheLoser() throws {
        for aPushesFirst in [true, false] {
            for laterOnA in [true, false] {
                a = try SyncTestDevice("user-a")
                b = try SyncTestDevice("user-b")
                let uuid = try sharedTransaction()
                let (earlier, later) = laterOnA ? (b!, a!) : (a!, b!)
                try set(earlier, "transaction_", uuid, "note", "earlier")
                try set(earlier, "transaction_", uuid, "amountMinorUnits", -200)
                pause()
                try set(later, "transaction_", uuid, "note", "later")
                let (first, second) = aPushesFirst ? (a!, b!) : (b!, a!)
                try second.receive(try first.push())
                try first.receive(try second.push())
                let label = "a first \(aPushesFirst), later on A \(laterOnA)"
                for device in [a!, b!] {
                    XCTAssertEqual(try note(device, uuid), "later", label)
                    XCTAssertEqual(Int64.fromDatabaseValue(try column(device, "transaction_", uuid, "amountMinorUnits")), -200, label)
                }
                XCTAssertEqual(try losing(a) + losing(b), [logged("earlier")], label)
            }
        }
    }

    // MARK: Unique keys that aren't identities (review 2)

    func testANewMainAccountDoesNotFuseWithTheLocalMain() throws {
        for joinedLater in [true, false] {
            a = try SyncTestDevice("user-a")
            b = try SyncTestDevice("user-b")
            if joinedLater {
                _ = try b.queue.write { db in try account(db, "Current", main: true) }
                pause()
                _ = try a.queue.write { db in try account(db, "Joint", main: true) }
            } else {
                _ = try a.queue.write { db in try account(db, "Joint", main: true) }
                pause()
                _ = try b.queue.write { db in try account(db, "Current", main: true) }
            }
            let joint = try a.uuid("account", 1)
            _ = try b.push()
            let result = try b.receive(try a.push())[joint]
            XCTAssertEqual(result, joinedLater ? .applied : .conflicted(["isMain"]))
            try b.queue.read { db in
                XCTAssertEqual(Set(try String.fetchAll(db, sql: "SELECT name FROM account")), ["Current", "Joint"], "two accounts, not one")
                XCTAssertEqual(try String.fetchAll(db, sql: "SELECT name FROM account WHERE isMain = 1"), [joinedLater ? "Joint" : "Current"])
                XCTAssertEqual(try String.fetchAll(db, sql: "SELECT losingValueJSON FROM syncConflict"), [SyncValue.bool(true).json])
            }
            if joinedLater {
                let current = try b.uuid("account", 1)
                XCTAssertEqual(try b.pendingUUIDs()[current], .update, "the cleared flag goes out")
            }
        }
    }

    func testAccountsWithTheSameNameAreBothKept() throws {
        _ = try a.queue.write { db in try account(db, "Savings") }
        _ = try b.queue.write { db in try account(db, "Savings") }
        let aSavings = try a.uuid("account", 1), bSavings = try b.uuid("account", 1)
        let fromA = try a.push()
        try b.receive(fromA)
        try a.receive(try b.push())
        try b.receive(try a.push())
        let renamed = max(aSavings, bSavings), kept = min(aSavings, bSavings)
        for device in [a!, b!] {
            try device.queue.read { db in XCTAssertEqual(try Account.fetchCount(db), 2) }
            XCTAssertEqual(String.fromDatabaseValue(try column(device, "account", kept, "name")), "Savings")
            XCTAssertEqual(String.fromDatabaseValue(try column(device, "account", renamed, "name")), "Savings (2)")
        }
        XCTAssertFalse(try losing(a).isEmpty && losing(b).isEmpty, "the rename is logged")
    }

    func testARenameToATakenNameKeepsTheLocalNameAndAppliesTheRest() throws {
        try a.queue.write { db in
            try account(db, "One")
            try account(db, "Two")
        }
        try b.receive(try a.push())
        let one = try a.uuid("account", 1), two = try a.uuid("account", 2)
        try set(b, "account", one, "name", "Three")
        try set(a, "account", two, "name", "Three")
        try set(a, "account", two, "alias", "A's alias")
        XCTAssertEqual(try b.receive(try a.push())[two], .conflicted(["name"]))
        XCTAssertEqual(String.fromDatabaseValue(try column(b, "account", two, "name")), "Two")
        XCTAssertEqual(String.fromDatabaseValue(try column(b, "account", two, "alias")), "A's alias")
        XCTAssertEqual(String.fromDatabaseValue(try column(b, "account", one, "name")), "Three")
        XCTAssertEqual(try losing(b), [logged("Three")])
        try b.queue.read { db in XCTAssertEqual(try SyncStagingRow.fetchCount(db), 0, "nothing waits forever") }
    }

    // MARK: Deleted parents by foreign-key action (review 3)

    private func sharedEntryAndAccounts() throws -> (entry: String, keep: String, gone: String) {
        try a.queue.write { db in
            let keep = try account(db, "Keep")
            try account(db, "Gone")
            var group = ForecastGroup(name: "Planned", note: nil, isEnabled: true, isSystemManaged: false)
            try group.insert(db)
            var category = Category(name: "Plan category", type: .expense)
            try category.insert(db)
            var entry = ForecastEntry(groupId: group.id!, categoryId: category.id!, amountMinorUnits: -100, frequency: .monthly, interval: 1,
                                      startDate: Date(timeIntervalSince1970: 1_700_000_000), endDate: nil, isEnabled: true, status: .manual,
                                      note: nil, accountId: keep)
            try entry.insert(db)
        }
        try b.receive(try a.push())
        return (try a.uuid("forecastEntry", 1), try a.uuid("account", 1), try a.uuid("account", 2))
    }

    func testAReferenceToAParentDeletedHereWithSetNullTakesNull() throws {
        let (entry, _, gone) = try sharedEntryAndAccounts()
        try b.queue.write { db in _ = try Account.deleteOne(db, key: try XCTUnwrap(try SyncRecordStore.localId(table: "account", uuid: gone, db: db))) }
        try set(a, "forecastEntry", entry, "accountId", try XCTUnwrap(try a.localId("account", gone)))
        try set(a, "forecastEntry", entry, "note", "moved")
        XCTAssertEqual(try b.receive(try a.push())[entry], .applied)
        XCTAssertEqual(try column(b, "forecastEntry", entry, "accountId"), .null)
        XCTAssertEqual(String.fromDatabaseValue(try column(b, "forecastEntry", entry, "note")), "moved")
    }

    func testAReferenceToAParentDeletedHereWithNoActionKeepsTheLocalValue() throws {
        let uuid = try sharedTransaction()
        let (c1, c2) = try a.queue.write { db -> (Int64, Int64) in
            var one = Category(name: "One", type: .expense), two = Category(name: "Two", type: .expense)
            try one.insert(db)
            try two.insert(db)
            return (one.id!, two.id!)
        }
        let txId = try XCTUnwrap(try a.localId("transaction_", uuid))
        try a.queue.write { db in try db.execute(sql: "UPDATE transaction_ SET categoryId = ? WHERE id = ?", arguments: [c1, txId]) }
        try b.receive(try a.push())
        let twoUUID = try a.uuid("category", c2)
        try b.queue.write { db in _ = try Category.deleteOne(db, key: try XCTUnwrap(try SyncRecordStore.localId(table: "category", uuid: twoUUID, db: db))) }
        try a.queue.write { db in try db.execute(sql: "UPDATE transaction_ SET categoryId = ?, note = 'recategorised' WHERE id = ?", arguments: [c2, txId]) }
        XCTAssertEqual(try b.receive(try a.push())[uuid], .conflicted(["categoryId"]))
        XCTAssertEqual(try column(b, "transaction_", uuid, "categoryId"), try XCTUnwrap(try b.localId("category", try a.uuid("category", c1))).databaseValue)
        XCTAssertEqual(try note(b, uuid), "recategorised")
        XCTAssertEqual(try losing(b), [SyncValue.string(twoUUID).json])
    }

    func testANewChildOfAParentDeletedHereIsDiscardedAndLogged() throws {
        try a.queue.write { db in
            var person = Person(name: "Owner")
            try person.insert(db)
            var property = Property(name: "Flat", country: "PT")
            try property.insert(db)
        }
        try b.receive(try a.push())
        let property = try a.uuid("property", 1)
        try b.queue.write { db in _ = try Property.deleteAll(db) }
        try a.queue.write { db in
            var owner = PropertyOwner(propertyId: 1, personId: 1, shareBasisPoints: 10_000)
            try owner.insert(db)
        }
        let owner = try a.uuid("propertyOwner", 1)
        let changes = try a.push().filter { if case .save(let p) = $0 { return p.recordType == "propertyOwner" }; return false }
        XCTAssertEqual(try b.receive(changes)[owner], .discarded("parent deleted: property"))
        try b.queue.read { db in
            XCTAssertEqual(try PropertyOwner.fetchCount(db), 0)
            XCTAssertEqual(try SyncStagingRow.fetchCount(db), 0, "not staged")
            XCTAssertEqual(try SyncConflictRow.filter(Column("uuid") == owner).fetchOne(db)?.field, "*")
        }
        XCTAssertNotNil(property)
    }

    // MARK: Redirects (review 4)

    /// Two devices import the same file. The one holding the larger UUID merges it into the smaller and
    /// sends a redirect; a third device that has the loser re-keys, in either arrival order, never deleting it.
    func testAMergedRecordRedirectsInEitherOrder() throws {
        let add = { (device: SyncTestDevice, note: String) in
            try device.queue.write { db in
                var person = Person(name: "Person \(note)")
                try person.insert(db)
                var document = EvidenceDocument(sha256: "same-file", storedRelativePath: "sa/same.pdf", originalFileName: "same.pdf", byteCount: 1,
                                                addedAt: Date(timeIntervalSince1970: 1_700_000_000), note: note)
                try document.insert(db)
                var link = DocumentLink(documentId: document.id!, entity: EvidenceEntity(type: .person, id: person.id!), role: nil)
                try link.insert(db)
            }
        }
        try add(a, "from A")
        try add(b, "from B")
        let aDoc = try a.uuid("document", 1), bDoc = try b.uuid("document", 1)
        let (survivorDevice, loserDevice) = aDoc < bDoc ? (a!, b!) : (b!, a!)
        let survivor = min(aDoc, bDoc), loser = max(aDoc, bDoc)
        let loserFirst = try loserDevice.push()
        let survivorChanges = try survivorDevice.push()
        // Third devices have the loser's document (and its link).
        let c1 = try SyncTestDevice("user-c1"), c2 = try SyncTestDevice("user-c2")
        for c in [c1, c2] { try c.receive(loserFirst) }
        let rowBefore = try XCTUnwrap(try c1.localId("document", loser))
        // The loser's device takes the survivor and redirects its own name.
        try loserDevice.receive(survivorChanges)
        XCTAssertEqual(try loserDevice.localId("document", survivor), 1)
        let merged = try loserDevice.push()
        let redirect = merged.filter { if case .save(let p) = $0 { return p.mergedInto != nil }; return false }
        XCTAssertEqual(redirect.count, 1)
        XCTAssertFalse(merged.contains { if case .delete = $0 { return true }; return false }, "no delete is sent")
        let saves = merged.filter { if case .save(let p) = $0 { return p.mergedInto == nil }; return false }
        try c1.receive(redirect)
        try c1.receive(saves + survivorChanges)
        try c2.receive(saves + survivorChanges)
        try c2.receive(redirect)
        for c in [c1, c2] {
            try c.queue.read { db in
                XCTAssertEqual(try EvidenceDocument.fetchCount(db), 1)
                XCTAssertEqual(try SyncRecordStore.localId(table: "document", uuid: survivor, db: db), rowBefore, "re-keyed, never deleted")
                XCTAssertEqual(try SyncReferenceResolver(db: db).incoming(table: "document", uuid: loser), .local(rowBefore), "the old name resolves")
                XCTAssertEqual(try DocumentLink.filter(Column("documentId") == rowBefore).fetchCount(db), 2, "both devices' links")
            }
        }
    }

    /// N1: a save of a redirected UUID (from a device that hasn't merged yet) merges by the rule, field by
    /// field, on the merging device, the survivor's device and a third device alike.
    func testALaterSaveOfARedirectedRecordMergesByTheRuleEverywhere() throws {
        for (device, note) in [(a!, "from A"), (b!, "from B")] {
            try device.queue.write { db in
                var document = EvidenceDocument(sha256: "same-file", storedRelativePath: "sa/same.pdf", originalFileName: "same.pdf", byteCount: 1,
                                                addedAt: Date(timeIntervalSince1970: 1_700_000_000), note: note)
                try document.insert(db)
            }
        }
        let aDoc = try a.uuid("document", 1), bDoc = try b.uuid("document", 1)
        let (survivorDevice, loserDevice) = aDoc < bDoc ? (a!, b!) : (b!, a!)
        let loserNote = aDoc < bDoc ? "from B" : "from A"
        let stale = try loserDevice.push()
        pause()
        try survivorDevice.queue.write { db in try db.execute(sql: "UPDATE document SET note = 'survivor wins' WHERE id = 1") }
        let survivorChanges = try survivorDevice.push()
        let c = try SyncTestDevice("user-c")
        try c.receive(survivorChanges)
        try loserDevice.receive(survivorChanges)
        let merged = try loserDevice.push()
        try survivorDevice.receive(merged)
        try c.receive(merged)
        // The loser's old save turns up late, everywhere.
        for device in [loserDevice, survivorDevice, c] {
            try device.receive(stale)
            try device.queue.read { db in
                XCTAssertEqual(try String.fetchAll(db, sql: "SELECT note FROM document"), ["survivor wins"], device.user)
                XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM syncConflict WHERE field = 'note' AND losingValueJSON = ?",
                                                arguments: [SyncValue.string(loserNote).json]), 1, "\(device.user) logs the loser once")
            }
        }
    }

    /// N2 as asked (set the base of fields an adoption took from the incoming record) would make a later
    /// pull of the unchanged server record revert them silently. This pins the behaviour kept: the
    /// merged value survives such a pull.
    func testAValueAnAdoptionTookSurvivesAPullOfTheUnchangedServerRecord() throws {
        for (device, note) in [(a!, "from A"), (b!, "from B")] {
            try device.queue.write { db in
                var document = EvidenceDocument(sha256: "same-file", storedRelativePath: "sa/same.pdf", originalFileName: "same.pdf", byteCount: 1,
                                                addedAt: Date(timeIntervalSince1970: 1_700_000_000), note: note)
                try document.insert(db)
            }
        }
        let aDoc = try a.uuid("document", 1), bDoc = try b.uuid("document", 1)
        let (survivorDevice, loserDevice) = aDoc < bDoc ? (a!, b!) : (b!, a!)
        let serverCopy = try survivorDevice.push()
        // A third device edits another field of the survivor and that upload reaches the server first.
        let c = try SyncTestDevice("user-c")
        try c.receive(serverCopy)
        pause()
        // The loser's note is newer, so adoption on the survivor's device takes it (the else branch).
        try loserDevice.queue.write { db in try db.execute(sql: "UPDATE document SET note = 'newer, from the loser' WHERE id = 1") }
        try survivorDevice.receive(try loserDevice.push())
        XCTAssertEqual(try survivorDevice.queue.read { db in try String.fetchOne(db, sql: "SELECT note FROM document") }, "newer, from the loser")
        let cId = try XCTUnwrap(try c.localId("document", min(aDoc, bDoc)))
        try c.queue.write { db in try db.execute(sql: "UPDATE document SET canonicalName = 'renamed on C' WHERE id = ?", arguments: [cId]) }
        try survivorDevice.receive(try c.push())
        try survivorDevice.queue.read { db in
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT note FROM document"), "newer, from the loser", "not reverted")
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT canonicalName FROM document"), "renamed on C")
        }
    }

    // MARK: Natural keys are identities (ruling R9)

    func testTheSameStatementRowsReceiptAndInvoiceOnTwoDevicesAreOneEach() throws {
        try a.queue.write { db in
            try account(db, "Current")
            var property = Property(name: "Flat", country: "PT")
            try property.insert(db)
            try db.execute(sql: "INSERT INTO tenancy(propertyId, referenceLabel, contractNumber, startDate) VALUES (1, 'T', 'C-1', '2024-01-01 00:00:00.000')")
            try db.execute(sql: "INSERT INTO utilityProvider(propertyId, name, kind) VALUES (1, 'Power', 'electricity')")
        }
        try b.receive(try a.push())
        let ids = { (device: SyncTestDevice, table: String) in try XCTUnwrap(try device.localId(table, try self.a.uuid(table, 1))) }
        for (device, note) in [(a!, "on A"), (b!, "on B")] {
            let account = try ids(device, "account"), tenancy = try ids(device, "tenancy"), provider = try ids(device, "utilityProvider")
            try device.queue.write { db in
                var batch = ImportBatch(accountId: account, sourceFileName: "same.csv", importedAt: Date(timeIntervalSince1970: 1_700_000_000))
                try batch.insert(db)
                for (fingerprint, amount) in [("fp-1", -1_000), ("fp-2", -250)] {
                    var tx = Transaction(importBatchId: batch.id!, accountId: account, date: Date(timeIntervalSince1970: 1_700_000_000),
                                         rawDescription: "Shop", amountMinorUnits: amount, categoryId: nil, status: .pendingReview,
                                         categorizedBy: .none, fingerprint: fingerprint, note: note)
                    try tx.insert(db)
                }
                try db.execute(sql: """
                    INSERT INTO rentReceipt(tenancyId, receiptNumber, periodStart, periodEnd, amountMinorUnits, amountReceivedMinorUnits)
                    VALUES (?, 'R-7', '2024-02-01 00:00:00.000', '2024-02-29 00:00:00.000', 90000, 90000)
                    """, arguments: [tenancy])
                try db.execute(sql: "INSERT INTO utilityInvoice(providerId, invoiceNumber, issueDate, amountMinorUnits, notes) VALUES (?, 'INV-1', '2024-02-10 00:00:00.000', 4200, ?)",
                               arguments: [provider, note])
            }
        }
        try b.receive(try a.push())
        try a.receive(try b.push())
        try b.receive(try a.push())
        for device in [a!, b!] {
            try device.queue.read { db in
                XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM transaction_"), 2, device.user)
                XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT SUM(amountMinorUnits) FROM transaction_"), -1_250, "spending counted once")
                XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM rentReceipt"), 1)
                XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT SUM(amountMinorUnits) FROM rentReceipt"), 90_000, "rent counted once")
                XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM utilityInvoice"), 1)
                XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT SUM(amountMinorUnits) FROM utilityInvoice"), 4_200)
                XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tenancy"), 1)
            }
        }
        // The differing notes merged to one value on both devices, the other logged.
        let notes = { (device: SyncTestDevice) in try device.queue.read { db in try String.fetchAll(db, sql: "SELECT note FROM transaction_ ORDER BY fingerprint") } }
        XCTAssertEqual(try notes(a), try notes(b))
        XCTAssertFalse(try losing(a).isEmpty && losing(b).isEmpty)
    }

    // MARK: Fix round 2 minors

    func testStagedRecordsAreRetriedOnTheFirstPullAfterOpen() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("SyncOpen-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        _ = try a.queue.write { db in try account(db, "From A") }
        let payload = try XCTUnwrap(try a.push().compactMap { change -> SyncPayload? in if case .save(let p) = change { return p }; return nil }.first)
        let path = folder.appendingPathComponent("db.sqlite").path
        do {
            let manager = try TestDatabase.migratedManager(path: path)
            try manager.dbQueue.write { db in
                // As an older build would have left it: a record type it didn't know.
                var row = SyncStagingRow(tableName: "account", uuid: payload.recordName, payloadJSON: try SyncTranslator.json(payload),
                                         reason: "unknown record type", receivedAt: Date())
                try row.insert(db)
            }
        }
        let reopened = try DatabaseManager(path: path)
        try reopened.migrate()
        try reopened.dbQueue.read { db in
            // Not applied at open (it would bypass the filed-year check): the next pull retries it.
            XCTAssertEqual(try SyncStagingRow.fetchCount(db), 1)
            XCTAssertTrue(try SyncEngineCore.retryStagedRequested(db: db))
        }
        let engine = SyncEngineCore(db: reopened.dbQueue, transport: FakeCloud(), device: SyncDevice(id: "device-b", name: "iPad"),
                                    keyStore: InMemorySyncKeyStore())
        let pulled = expectation(description: "pull")
        Task {
            do { _ = try await engine.pull() } catch { XCTFail("\(error)") }
            pulled.fulfill()
        }
        wait(for: [pulled], timeout: 60)
        try reopened.dbQueue.read { db in
            XCTAssertFalse(try SyncEngineCore.retryStagedRequested(db: db))
            XCTAssertEqual(try SyncStagingRow.fetchCount(db), 0)
            XCTAssertEqual(try String.fetchAll(db, sql: "SELECT name FROM account"), ["From A"])
            // (Pending again only as ruling R12's resend: this first fetch of an empty server didn't list it.)
            XCTAssertTrue(try SyncChangeTracker.pending(db: db).allSatisfy { $0.kind == .insert })
        }
    }

    func testADeleteOfAParentStillReferencedHereIsKeptAndTheRestApplies() throws {
        let uuid = try sharedTransaction()
        _ = try a.queue.write { db in try account(db, "Other") }
        try b.receive(try a.push())
        let current = try a.uuid("account", 1), other = try a.uuid("account", 2)
        try set(a, "account", other, "alias", "edited")
        let edit = try a.push()
        // The account's delete arrives while B's transactions (NO ACTION) still point at it.
        let results = try b.receive(edit + [.delete(recordName: current, recordType: "account")])
        XCTAssertEqual(results[current], .kept("still referenced"))
        XCTAssertEqual(results[other], .applied)
        XCTAssertEqual(String.fromDatabaseValue(try column(b, "account", other, "alias")), "edited")
        XCTAssertNotNil(try b.localId("account", current))
        XCTAssertNotNil(try b.localId("transaction_", uuid))
        try b.queue.read { db in XCTAssertEqual(try SyncConflictRow.filter(Column("uuid") == current).fetchOne(db)?.field, "*") }
    }

    func testARedirectToAnotherRowHereIsLoggedForAttention() throws {
        try b.queue.write { db in
            try account(db, "One")
            try account(db, "Two")
        }
        let one = try b.uuid("account", 1), two = try b.uuid("account", 2)
        let result = try b.receive([.save(SyncPayload(recordType: "account", recordName: one, zone: "household", fields: [:], mergedInto: two))])
        XCTAssertEqual(result[one], .kept("both records are rows here"))
        try b.queue.read { db in
            XCTAssertEqual(try Account.fetchCount(db), 2)
            XCTAssertTrue(try XCTUnwrap(try SyncConflictRow.filter(Column("uuid") == one).fetchOne(db)).losingValueJSON.contains("needs attention"))
        }
    }

    func testAConflictIsLoggedOncePerLostValue() throws {
        let uuid = try sharedTransaction()
        try set(a, "transaction_", uuid, "note", "A")
        pause()
        try set(b, "transaction_", uuid, "note", "B")
        let fromB = try b.push()
        try a.receive(fromB)
        try a.receive(fromB)
        XCTAssertEqual(try losing(a), [logged("A")])
    }

    // MARK: Minors

    func testSeededBuiltInCategoriesHaveTheSameUUIDOnEveryDevice() throws {
        _ = try a.queue.write { db in try SyncRecordStore.backfill(db: db) }
        _ = try b.queue.write { db in try SyncRecordStore.backfill(db: db) }
        let sql = "SELECT c.builtInRole || '=' || s.uuid FROM category c JOIN syncRecord s ON s.tableName = 'category' AND s.localId = c.id WHERE c.builtInRole IS NOT NULL ORDER BY 1"
        let fromA = try a.queue.read { db in try String.fetchAll(db, sql: sql) }
        XCTAssertFalse(fromA.isEmpty)
        XCTAssertEqual(fromA, try b.queue.read { db in try String.fetchAll(db, sql: sql) })
        try b.receive(try a.push())
        try b.queue.read { db in XCTAssertEqual(try SyncTombstoneRow.fetchCount(db), 0, "nothing re-keyed") }
    }

    func testAnUnreadableStagingRowIsMarkedForAttention() throws {
        try b.queue.write { db in
            var row = SyncStagingRow(tableName: "account", uuid: "u-broken", payloadJSON: "{not json", reason: "waiting for account", receivedAt: Date())
            try row.insert(db)
            try SyncTranslator.retryStaged(db: db, deviceUser: nil)
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT reason FROM syncStaging WHERE uuid = 'u-broken'"), "needs attention: unreadable payload")
        }
    }

    func testRetriesOnlyWhatTheArrivalsUnblock() {
        XCTAssertEqual(SyncTranslator.waitedFor("waiting for account, importBatch"), ["account", "importBatch"])
        XCTAssertEqual(SyncTranslator.waitedFor("apply failed: SQLite 2067"), [])
    }

    func testLocalOnlyMembersAreStrippedWithoutOverlap() throws {
        try a.queue.write { db in
            let json = SyncJSONTranslator(resolver: SyncReferenceResolver(db: db), direction: .outgoing)
            XCTAssertEqual(try json.translateRow(#"{"sourceFolderId":null,"sourceRelativePath":"x","sha256":"a","extractedText":"t","note":null}"#,
                                                 table: "document", changeTable: "importChange", column: "afterJSON"),
                           #"{"sha256":"a","note":null}"#)
            XCTAssertEqual(try json.translateRow(#"{"sourceFolderId":null,"extractedText":"t"}"#, table: "document", changeTable: "importChange", column: "afterJSON"), "{}")
            XCTAssertEqual(try json.translateRow(#"{"sha256":"a","sourceFolderId":null,"sourceModifiedAt":null}"#, table: "document", changeTable: "importChange", column: "afterJSON"),
                           #"{"sha256":"a"}"#)
        }
        var edits = SyncTextEdits()
        edits.replace(0..<4, with: "")
        edits.replace(2..<6, with: "")
        XCTAssertTrue(edits.overlap)
    }
}
