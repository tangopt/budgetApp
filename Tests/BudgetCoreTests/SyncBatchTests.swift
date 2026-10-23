import XCTest
import GRDB
@testable import BudgetCore

/// Import batches (sync spec §5.2, plan Task 4): the records a confirmed import (or its Undo) writes go
/// out tagged with the run's UUID, the run carries a manifest of counts per record type, and a receiver
/// applies them only when the whole manifest is there, in one transaction. Ruling R7: the change log
/// carries the UUIDs of the rows a run deleted, so an Undo on another device brings them back under the
/// same identity. Synthetic data only.
final class SyncBatchTests: XCTestCase {
    private var a: SyncTestDevice!
    private var b: SyncTestDevice!
    private var folders: [URL] = []

    override func setUpWithError() throws {
        a = try SyncTestDevice("user-a")
        b = try SyncTestDevice("user-b")
    }

    override func tearDownWithError() throws {
        for folder in folders { try? FileManager.default.removeItem(at: folder) }
    }

    private func temporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("SyncBatchTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        folders.append(folder)
        return folder
    }

    // MARK: Fixtures

    private static let day = Date(timeIntervalSince1970: 1_700_000_000)

    /// An account with one batch and one manual transaction on `device`. Returns (account, batch, manual).
    private func base(_ device: SyncTestDevice) throws -> (Int64, Int64, Int64) {
        try device.queue.write { db in
            var account = Account(name: "Current", currency: .gbp, kind: .cash, trackingMode: .imported)
            try account.insert(db)
            var batch = ImportBatch(accountId: account.id!, sourceFileName: "earlier.csv", importedAt: Self.day)
            try batch.insert(db)
            var manual = Transaction(importBatchId: batch.id!, accountId: account.id!, date: Self.day, rawDescription: "Manual entry",
                                     amountMinorUnits: -500, categoryId: nil, status: .confirmed, categorizedBy: .manual,
                                     fingerprint: "fp-manual", isManual: true)
            try manual.insert(db)
            return (account.id!, batch.id!, manual.id!)
        }
    }

    /// A confirmed import on `device`, written the way `ImportApplier` writes one: the run, its captured
    /// changes (a batch of `count` transactions, and the removal of `removing`), its file record, then the
    /// sync batch. Returns the run's id.
    @discardableResult
    private func importRun(on device: SyncTestDevice, account: Int64, count: Int, removing: Int64? = nil, tag: String = "") throws -> Int64 {
        try device.queue.write { db in
            let mark = try SyncBatch.mark(db: db)
            var run = ImportRun(confirmedAt: Self.day, entryPoint: "Import…", summary: "")
            try run.insert(db)
            try ImportChangeCapture.begin(db: db)
            var batch = ImportBatch(accountId: account, sourceFileName: "statement\(tag).csv", importedAt: Self.day, importRunId: run.id)
            try batch.insert(db)
            for i in 0..<count {
                var t = Transaction(importBatchId: batch.id!, accountId: account, date: Self.day, rawDescription: "Shop \(tag)\(i)",
                                    amountMinorUnits: -100 * (i + 1), categoryId: nil, status: .pendingReview, categorizedBy: .none,
                                    fingerprint: "fp-\(tag)\(i)")
                try t.insert(db)
            }
            if let removing { try db.execute(sql: "DELETE FROM transaction_ WHERE id = ?", arguments: [removing]) }
            _ = try ImportChangeCapture.finish(db: db, runId: run.id!)
            var file = ImportRunFile(runId: run.id!, fileName: "statement\(tag).csv", sha256: "sha-\(tag)", outcome: .transactions, detail: "")
            try file.insert(db)
            run.summary = "\(count) transactions"
            try run.update(db)
            try SyncBatch.open(runId: run.id!, since: mark, db: db)
            return run.id!
        }
    }

    private func count(_ device: SyncTestDevice, _ table: String) throws -> Int {
        try device.queue.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)")! }
    }

    private func descriptions(_ device: SyncTestDevice) throws -> [String] {
        try device.queue.read { db in try String.fetchAll(db, sql: "SELECT rawDescription FROM transaction_ ORDER BY rawDescription") }
    }

    /// What B holds of the import: transactions, runs, change log entries, run files, import batches.
    private func imported(_ device: SyncTestDevice) throws -> [Int] {
        try ["transaction_", "importRun", "importChange", "importRunFile", "importBatch"].map { try count(device, $0) }
    }

    private func runUuid(_ device: SyncTestDevice, _ runId: Int64) throws -> String { try device.uuid("importRun", runId) }

    private func payload(_ changes: [SyncIncomingChange], _ name: String) -> SyncPayload? {
        for case .save(let payload) in changes where payload.recordName == name { return payload }
        return nil
    }

    // MARK: Tagging and the manifest

    func testRecordsWrittenByAConfirmedImportCarryTheRunAndTheRunCarriesTheManifest() throws {
        let (account, _, manual) = try base(a)
        let manualUuid = try a.uuid("transaction_", manual)
        try b.receive(try a.push())
        let runId = try importRun(on: a, account: account, count: 3, removing: manual)
        let run = try runUuid(a, runId)
        let sent = try a.push()

        let header = try XCTUnwrap(payload(sent, run))
        XCTAssertNil(header.importRunUuid, "the run is the batch's header, not one of its members")
        let manifest = try XCTUnwrap(header.manifest)
        XCTAssertEqual(manifest.generation, 1)
        XCTAssertTrue(manifest.isOpen)
        XCTAssertEqual(manifest.counts["transaction_"], 3)
        XCTAssertEqual(manifest.counts["importBatch"], 1)
        XCTAssertEqual(manifest.counts["importRunFile"], 1)
        // The change log: the batch, 3 transactions and the removal.
        XCTAssertEqual(manifest.counts["importChange"], 5)
        XCTAssertEqual(manifest.deletes, [manualUuid])
        XCTAssertNil(manifest.counts["importRun"])

        var members = 0
        for case .save(let payload) in sent where payload.recordName != run {
            XCTAssertEqual(payload.importRunUuid, run, payload.recordType)
            XCTAssertEqual(payload.batchGeneration, 1)
            members += 1
        }
        XCTAssertEqual(members, manifest.counts.values.reduce(0, +))
    }

    func testRecordsOutsideAnyImportCarryNoRun() throws {
        _ = try base(a)
        for case .save(let payload) in try a.push() {
            XCTAssertNil(payload.importRunUuid)
            XCTAssertNil(payload.manifest)
        }
    }

    // MARK: Review Focus 4

    func testPartialManifestNeverApplies() throws {
        let (account, _, manual) = try base(a)
        let shared = try a.push()
        let runId = try importRun(on: a, account: account, count: 3, removing: manual)
        let run = try runUuid(a, runId)
        let sent = try a.push()
        // The batch as it may arrive: in upload order, and with its header last.
        // (The sender queues the run first, and the receiver holds the batch's deletes once it knows it.)
        let saves = sent.filter { if case .save = $0 { return true } else { return false } }
        let deletes = sent.filter { if case .delete = $0 { return true } else { return false } }
        let headerLast = saves.filter { payload([$0], run) == nil } + saves.filter { payload([$0], run) != nil } + deletes
        for order in [sent, headerLast] {
            for split in 1..<order.count {
                let device = try SyncTestDevice("user-b")
                try device.receive(shared)
                let before = try imported(device)
                try device.receive(Array(order[..<split]))
                if isSave(order[split...]).isEmpty {
                    // Every record saved is there; the manifest names the removal, which applies with them
                    // (the plain delete still to come is then a no-op).
                    XCTAssertEqual(try descriptions(device), ["Shop 0", "Shop 1", "Shop 2"], "split \(split)")
                } else {
                    // Nothing of the batch: not a transaction, not the run, not its log, and the removal waits too.
                    XCTAssertEqual(try imported(device), before, "split \(split)")
                    XCTAssertEqual(try descriptions(device), ["Manual entry"], "split \(split)")
                    XCTAssertFalse(try device.queue.write { db in try SyncBatch.applyIfComplete(runUuid: run, db: db) }, "split \(split)")
                }

                try device.receive(Array(order[split...]))
                XCTAssertEqual(try descriptions(device), ["Shop 0", "Shop 1", "Shop 2"], "split \(split)")
                XCTAssertEqual(try imported(device), [3, 1, 5, 1, 2], "split \(split)")
                XCTAssertEqual(try device.queue.read { db in try SyncStagingRow.fetchCount(db) }, 0, "split \(split)")
            }
        }
    }

    func testACompleteBatchAppliesInOneTransaction() throws {
        let (account, _, _) = try base(a)
        try b.receive(try a.push())
        let runId = try importRun(on: a, account: account, count: 2)
        let sent = try a.push()
        try b.receive(Array(sent.dropLast()))
        let commits = CommitCounter()
        b.queue.add(transactionObserver: commits)
        try b.receive([sent.last!])
        XCTAssertEqual(commits.count, 1)
        XCTAssertEqual(try descriptions(b), ["Manual entry", "Shop 0", "Shop 1"])
        XCTAssertTrue(try b.queue.write { db in try SyncBatch.applyIfComplete(runUuid: try self.runUuid(self.a, runId), db: db) },
                      "an applied batch is complete")
    }

    func testResumeAfterQuitCompletesBatch() throws {
        let folder = try temporaryFolder()
        var sender: SyncTestDevice? = try SyncTestDevice("user-a", path: folder.appendingPathComponent("a.sqlite").path)
        var receiver: SyncTestDevice? = try SyncTestDevice("user-b", path: folder.appendingPathComponent("b.sqlite").path)
        let (account, _, manual) = try base(sender!)
        try receiver!.receive(try sender!.push())
        let runId = try importRun(on: sender!, account: account, count: 4, removing: manual)
        let run = try runUuid(sender!, runId)
        let pending = try sender!.queue.read { db in try SyncChangeTracker.pending(db: db).count }

        // The upload stops halfway (a network drop), and both apps quit.
        let first = try sender!.push(limit: pending / 2)
        try receiver!.receive(first)
        XCTAssertEqual(try descriptions(receiver!), ["Manual entry"])
        XCTAssertGreaterThan(try receiver!.queue.read { db in try SyncStagingRow.filter(Column("importRunUuid") == run).fetchCount(db) }, 0)
        sender = nil
        receiver = nil

        // Both open again: the receiver still holds the part it got and applies none of it (the retry at
        // open leaves batches alone); the sender resumes the upload where it stopped.
        sender = try SyncTestDevice("user-a", path: folder.appendingPathComponent("a.sqlite").path)
        receiver = try SyncTestDevice("user-b", path: folder.appendingPathComponent("b.sqlite").path)
        XCTAssertEqual(try descriptions(receiver!), ["Manual entry"])
        let rest = try sender!.push()
        XCTAssertFalse(rest.isEmpty)
        try receiver!.receive(rest)
        XCTAssertEqual(try descriptions(receiver!), ["Shop 0", "Shop 1", "Shop 2", "Shop 3"])
        XCTAssertEqual(try receiver!.queue.read { db in try SyncStagingRow.fetchCount(db) }, 0)
    }

    // MARK: Closing a batch

    func testAClosedBatchWaitsForItsFinalCountsOrForFlushClosed() throws {
        let (account, _, _) = try base(a)
        let shared = try a.push()
        try b.receive(shared)
        let runId = try importRun(on: a, account: account, count: 3)
        let run = try runUuid(a, runId)
        let sent = try a.push()
        // Everything uploaded: the sender closes the batch, which sends the run once more with its final
        // counts: every member on the server.
        XCTAssertEqual(try a.queue.write { db in try SyncBatch.closeUploaded(db: db) }, [run])
        let close = try a.push()
        XCTAssertEqual(close.count, 1)
        let header = try XCTUnwrap(payload(close, run)?.manifest)
        XCTAssertFalse(header.isOpen)
        XCTAssertEqual(header.generation, 1)
        XCTAssertEqual(header.counts, ["transaction_": 3, "importBatch": 1, "importChange": 4, "importRunFile": 1])

        // A receiver with part of the batch, then the close: still nothing; the rest completes it.
        let members = sent.filter { payload([$0], run) == nil }
        try b.receive(Array(members.prefix(3)))
        try b.receive(close)
        XCTAssertEqual(try descriptions(b), ["Manual entry"])
        XCTAssertEqual(try count(b, "importRun"), 0)
        try b.receive(Array(members.dropFirst(3)))
        XCTAssertEqual(try descriptions(b), ["Manual entry", "Shop 0", "Shop 1", "Shop 2"])
        XCTAssertEqual(try b.queue.read { db in try SyncStagingRow.fetchCount(db) }, 0)

        // A receiver whose counts can't be met (the rest was edited since by a device that didn't tag it):
        // once the fetch has caught up, `flushClosed` applies what it has, all at once.
        let c = try SyncTestDevice("user-c")
        try c.receive(shared)
        try c.receive(Array(members.prefix(3)) + close)
        XCTAssertEqual(try count(c, "importRun"), 0)
        XCTAssertEqual(try c.queue.write { db in try SyncBatch.flushClosed(db: db) }, [run])
        XCTAssertEqual(try count(c, "importRun"), 1)
        XCTAssertEqual(try c.queue.read { db in try SyncStagingRow.filter(Column("importRunUuid") != nil).fetchCount(db) }, 0)

        // The sender's later edits keep the tag (so the server's copy still counts), and apply at once where
        // the batch already applied.
        try a.queue.write { db in try db.execute(sql: "UPDATE transaction_ SET note = 'later' WHERE rawDescription = 'Shop 0'") }
        let edit = try a.push()
        XCTAssertEqual(edit.count, 1)
        guard case .save(let later) = edit[0] else { return XCTFail("expected a save") }
        XCTAssertEqual(later.importRunUuid, run)
        XCTAssertEqual(try b.receive(edit)[later.recordName], .applied)
    }

    func testADeviceThatJoinsLaterNeverHoldsPartOfABatch() throws {
        let (account, _, manual) = try base(a)
        var server = TestServer()
        server.upload(try a.push())
        let runId = try importRun(on: a, account: account, count: 3, removing: manual)
        let run = try runUuid(a, runId)
        server.upload(try a.push())
        _ = try a.queue.write { db in try SyncBatch.closeUploaded(db: db) }
        server.upload(try a.push())

        // A device offline for the whole upload sees only the latest records: the run closed, its members
        // still tagged, and everything else, over fetch pages in any order.
        let everything = server.everything
        let batchNames = Set(everything.compactMap { change -> String? in
            guard case .save(let payload) = change, payload.recordName == run || payload.importRunUuid == run else { return nil }
            return payload.recordName
        })
        XCTAssertEqual(batchNames.count, 11, "the run and its 10 members")
        let isRun = { (change: SyncIncomingChange) in self.payload([change], run) != nil }
        let isMember = { (change: SyncIncomingChange) in batchNames.contains(change.recordName) && !isRun(change) }
        var random = SeededRandom(seed: 0x5eed)
        for trial in 0..<24 {
            var order = everything.shuffled(using: &random)
            switch trial % 3 {
            case 0: order = order.filter(isRun) + order.filter { !isRun($0) }        // the run first
            case 1: order = order.filter(isMember) + order.filter { !isMember($0) }  // its members first
            default: break                                                            // interleaved
            }
            let device = try SyncTestDevice("user-b")
            var rest = order[...]
            while !rest.isEmpty {
                let size = Int.random(in: 1...4, using: &random)
                try device.receive(Array(rest.prefix(size)))
                rest = rest.dropFirst(size)
                let present = try device.queue.read { db in
                    try batchNames.filter { try String.fetchOne(db, sql: "SELECT uuid FROM syncRecord WHERE uuid = ?", arguments: [$0]) != nil }.count
                }
                XCTAssertTrue(present == 0 || present == batchNames.count, "trial \(trial): \(present) of \(batchNames.count) records of the batch")
            }
            XCTAssertEqual(try descriptions(device), ["Shop 0", "Shop 1", "Shop 2"], "trial \(trial)")
            XCTAssertEqual(try device.queue.read { db in try SyncStagingRow.fetchCount(db) }, 0, "trial \(trial)")
        }
    }

    func testANewerGenerationKeepsTheDeletesAnOlderOneHeld() throws {
        let (account, _, manual) = try base(a)
        let manualUuid = try a.uuid("transaction_", manual)
        try b.receive(try a.push())
        let runId = try importRun(on: a, account: account, count: 2, removing: manual)
        let run = try runUuid(a, runId)
        let sent = try a.push()
        let first = try XCTUnwrap(payload(sent, run))
        XCTAssertEqual(first.manifest?.deletes, [manualUuid])
        // B gets the open run and its plain delete, which it holds for the batch.
        XCTAssertEqual(try b.receive([.save(first), .delete(recordName: manualUuid, recordType: "transaction_")])[manualUuid],
                       .staged(SyncBatch.waitingForBatch))
        XCTAssertEqual(try descriptions(b), ["Manual entry"])
        // Then a newer generation of the run replaces it before the first applied: the removal it held still
        // applies, with the newer batch.
        var second = first
        second.manifest = SyncBatchManifest(generation: 2, isOpen: true)
        try b.receive([.save(second)])
        XCTAssertEqual(try descriptions(b), [])
        XCTAssertEqual(try count(b, "importRun"), 1)
    }

    func testAMemberThatArrivesAfterItsBatchAppliedAppliesAtOnce() throws {
        let (account, _, _) = try base(a)
        try b.receive(try a.push())
        let runId = try importRun(on: a, account: account, count: 2)
        try b.receive(try a.push())
        // An edit made while the batch is still open on the sender goes tagged; the receiver already
        // applied the batch, so it applies at once.
        try a.queue.write { db in try db.execute(sql: "UPDATE transaction_ SET note = 'edited' WHERE rawDescription = 'Shop 1'") }
        let edit = try a.push()
        guard case .save(let payload) = try XCTUnwrap(edit.first) else { return XCTFail("expected a save") }
        XCTAssertEqual(payload.importRunUuid, try runUuid(a, runId))
        XCTAssertEqual(try b.receive(edit)[payload.recordName], .applied)
        XCTAssertEqual(try b.queue.read { db in try String.fetchOne(db, sql: "SELECT note FROM transaction_ WHERE rawDescription = 'Shop 1'") }, "edited")
    }

    // MARK: Undo (sync spec §5.2) and ruling R7

    func testImportChangeCarriesTheUUIDsOfTheRowsItDeleted() throws {
        let (account, _, manual) = try base(a)
        let manualUuid = try a.uuid("transaction_", manual)
        try b.receive(try a.push())
        try importRun(on: a, account: account, count: 1, removing: manual)
        let sent = try a.push()
        let removal = try XCTUnwrap(sent.compactMap { change -> SyncPayload? in
            guard case .save(let payload) = change, payload.recordType == "importChange", payload.fields["operation"] == .string("delete") else { return nil }
            return payload
        }.first)
        XCTAssertEqual(removal.fields["rowId"], .string(manualUuid), "not 0: the row is gone, its identity isn't")
        guard case .string(let before) = removal.fields["beforeJSON"] else { return XCTFail("no before") }
        XCTAssertTrue(before.contains("\"id\":\"\(manualUuid)\""), before)
        XCTAssertEqual(removal.deletedReferences, [manualUuid])

        // On B, which applied the removal, the log names B's own (deleted) row.
        try b.receive(sent)
        let bManual = try b.queue.read { db in
            try Int64.fetchOne(db, sql: "SELECT localId FROM syncTombstone WHERE uuid = ?", arguments: [manualUuid])
        }
        XCTAssertNotNil(bManual)
        XCTAssertEqual(try b.queue.read { db in
            try Int64.fetchOne(db, sql: "SELECT rowId FROM importChange WHERE operation = 'delete'")
        }, bManual)
    }

    func testUndoOnTheImportingDeviceKeepsTheDeletedRowsIdentity() throws {
        let (account, _, manual) = try base(a)
        let manualUuid = try a.uuid("transaction_", manual)
        try b.receive(try a.push())
        let runId = try importRun(on: a, account: account, count: 2, removing: manual)
        try b.receive(try a.push())
        XCTAssertEqual(try descriptions(b), ["Shop 0", "Shop 1"])

        let library = EvidenceLibrary(root: try temporaryFolder(), database: a.queue)
        _ = try ImportUndo.undo(dbQueue: a.queue, library: library, runId: runId)
        XCTAssertEqual(try a.uuid("transaction_", manual), manualUuid, "re-inserted under its own identity")
        XCTAssertNil(try a.queue.read { db in try SyncTombstoneRow.fetchOne(db, key: manualUuid) })

        try b.receive(try a.push())
        XCTAssertEqual(try descriptions(b), ["Manual entry"])
        XCTAssertNotNil(try b.localId("transaction_", manualUuid))
    }

    func testUndoRestoresTheIdentityTheImportDeletedEvenWhenItsIdWasReusedSince() throws {
        let (account, batch, manual) = try base(a)
        let manualUuid = try a.uuid("transaction_", manual)
        let runId = try importRun(on: a, account: account, count: 1, removing: manual)
        XCTAssertEqual(try a.queue.read { db in try String.fetchOne(db, sql: "SELECT rowUuid FROM importChange WHERE operation = 'delete'") },
                       manualUuid, "the change log keeps the identity the run deleted")
        // Since the import, another row took the same id and was deleted again: a later tombstone at that id.
        let other = try a.queue.write { db -> String in
            var t = Transaction(id: manual, importBatchId: batch, accountId: account, date: Self.day, rawDescription: "Another",
                                amountMinorUnits: -1, categoryId: nil, status: .confirmed, categorizedBy: .manual, fingerprint: "fp-other")
            try t.insert(db)
            let uuid = try XCTUnwrap(SyncRecordStore.existingUUID(table: "transaction_", localId: manual, db: db))
            try db.execute(sql: "DELETE FROM transaction_ WHERE id = ?", arguments: [manual])
            return uuid
        }
        Thread.sleep(forTimeInterval: 0.01)
        let library = EvidenceLibrary(root: try temporaryFolder(), database: a.queue)
        _ = try ImportUndo.undo(dbQueue: a.queue, library: library, runId: runId)
        XCTAssertEqual(try a.uuid("transaction_", manual), manualUuid)
        XCTAssertNotNil(try a.queue.read { db in try SyncTombstoneRow.fetchOne(db, key: other) }, "the other row stays deleted")
    }

    func testUndoIsABatchToo() throws {
        let (account, _, manual) = try base(a)
        let manualUuid = try a.uuid("transaction_", manual)
        try b.receive(try a.push())
        let runId = try importRun(on: a, account: account, count: 3, removing: manual)
        let run = try runUuid(a, runId)
        try b.receive(try a.push())
        _ = try a.queue.write { db in try SyncBatch.closeUploaded(db: db) }
        try b.receive(try a.push())

        // Undo needs the lease: B takes it, so A can't confirm or undo meanwhile.
        let store = InMemoryLeaseStore()
        let mac = SyncDevice(id: "device-a", name: "Mac"), ipad = SyncDevice(id: "device-b", name: "iPad")
        let lease = try awaitResult { try await ImportLease.acquire(device: ipad, now: Self.day, transport: store) }
        XCTAssertThrowsError(try awaitResult { try await ImportLease.acquire(device: mac, now: Self.day, transport: store) }) { error in
            XCTAssertEqual(error as? ImportLeaseError, .heldBy(deviceName: "iPad", until: Self.day.addingTimeInterval(ImportLease.duration)))
        }

        // B undoes the run A imported: B's own copy of the change log, translated, is what it reverts.
        let bRun = try XCTUnwrap(try b.localId("importRun", run))
        let library = EvidenceLibrary(root: try temporaryFolder(), database: b.queue)
        _ = try ImportUndo.undo(dbQueue: b.queue, library: library, runId: bRun)
        XCTAssertEqual(try descriptions(b), ["Manual entry"])
        XCTAssertEqual(try b.uuid("transaction_", try XCTUnwrap(try b.localId("transaction_", manualUuid))), manualUuid)

        let undo = try b.push()
        let header = try XCTUnwrap(payload(undo, run)?.manifest)
        XCTAssertEqual(header.generation, 2)
        XCTAssertTrue(header.isOpen)
        XCTAssertEqual(header.deletes.count, 4, "the statement batch and the 3 transactions the import added")
        XCTAssertEqual(header.revives, [manualUuid])
        for case .save(let payload) in undo where payload.recordName != run {
            XCTAssertEqual(payload.importRunUuid, run)
            XCTAssertEqual(payload.batchGeneration, 2)
        }

        // A applies the Undo as one batch: nothing of it until all of it.
        for split in 1..<undo.count {
            let device = try SyncTestDevice("user-a2")
            for changes in try replay(on: a) { try device.receive(changes) }
            XCTAssertEqual(try descriptions(device), ["Shop 0", "Shop 1", "Shop 2"])
            try device.receive(Array(undo[..<split]))
            if isSave(undo[split...]).isEmpty {
                XCTAssertEqual(try descriptions(device), ["Manual entry"], "split \(split): whole but for its plain deletes")
            } else {
                XCTAssertEqual(try descriptions(device), ["Shop 0", "Shop 1", "Shop 2"], "split \(split)")
                XCTAssertNil(try device.queue.read { db in try ImportRun.fetchOne(db, sql: "SELECT * FROM importRun") }?.undoneAt, "split \(split)")
            }
            try device.receive(Array(undo[split...]))
            XCTAssertEqual(try descriptions(device), ["Manual entry"], "split \(split)")
            XCTAssertNotNil(try device.localId("transaction_", manualUuid), "split \(split)")
        }
        try a.receive(undo)
        XCTAssertEqual(try descriptions(a), ["Manual entry"])
        XCTAssertNotNil(try a.queue.read { db in try ImportRun.fetchOne(db, key: runId) }?.undoneAt)
        XCTAssertNotNil(try a.localId("transaction_", manualUuid))

        // B releases the lease once the Undo is uploaded; then A may import again.
        _ = try b.queue.write { db in try SyncBatch.closeUploaded(db: db) }
        try awaitResult { try await ImportLease.release(lease, transport: store) }
        XCTAssertNoThrow(try awaitResult { try await ImportLease.acquire(device: mac, now: Self.day, transport: store) })
    }

    func testCrossDeviceUndoOfARowNeverSeenHereIsRefusedClearly() throws {
        // A makes a manual entry and imports a statement that replaces it before anything reaches B: B
        // never had the row, so it can't put it back.
        let (account, _, manual) = try base(a)
        let runId = try importRun(on: a, account: account, count: 1, removing: manual)
        let run = try runUuid(a, runId)
        try b.receive(try a.push())
        XCTAssertEqual(try descriptions(b), ["Shop 0"])
        let bRun = try XCTUnwrap(try b.localId("importRun", run))
        let library = EvidenceLibrary(root: try temporaryFolder(), database: b.queue)
        XCTAssertThrowsError(try ImportUndo.undo(dbQueue: b.queue, library: library, runId: bRun)) { error in
            guard case ImportUndoError.refused(let conflicts) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(conflicts, [.removedElsewhere(table: "transaction_")])
            XCTAssertEqual(conflicts.first?.message,
                           "This import removed a transaction on another device that was never on this one: undo it on the device that imported it")
        }
        XCTAssertEqual(try descriptions(b), ["Shop 0"], "nothing written")
        // On A it undoes.
        let aLibrary = EvidenceLibrary(root: try temporaryFolder(), database: a.queue)
        XCTAssertNoThrow(try ImportUndo.undo(dbQueue: a.queue, library: aLibrary, runId: runId))
    }

    // MARK: Helpers

    private func isSave(_ changes: ArraySlice<SyncIncomingChange>) -> [SyncIncomingChange] {
        changes.filter { if case .save = $0 { return true } else { return false } }
    }

    /// Everything `device` holds, as a first sync would deliver it (all records, latest state).
    private func replay(on device: SyncTestDevice) throws -> [[SyncIncomingChange]] {
        let copy = try device.queue.write { db -> [SyncIncomingChange] in
            var changes: [SyncIncomingChange] = []
            for record in try SyncRecordRow.fetchAll(db, sql: "SELECT * FROM syncRecord ORDER BY rowid") {
                let change = PendingChange(table: record.tableName, localId: record.localId, uuid: record.uuid, kind: .update)
                if let payload = try SyncTranslator.outgoing(change, db: db) { changes.append(.save(payload)) }
            }
            return changes
        }
        return [copy]
    }

    private func awaitResult<T: Sendable>(_ body: @escaping @Sendable () async throws -> T) throws -> T {
        let box = ResultBox<T>()
        let done = expectation(description: "async")
        Task {
            do { box.result = .success(try await body()) } catch { box.result = .failure(error) }
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        return try XCTUnwrap(box.result).get()
    }
}

private final class ResultBox<T>: @unchecked Sendable {
    var result: Result<T, Error>?
}

/// Counts the commits of a connection.
private final class CommitCounter: TransactionObserver, @unchecked Sendable {
    var count = 0
    func observes(eventsOfKind eventKind: DatabaseEventKind) -> Bool { true }
    func databaseDidChange(with event: DatabaseEvent) {}
    func databaseDidCommit(_ db: Database) { count += 1 }
    func databaseDidRollback(_ db: Database) {}
}

/// The server's latest state: one record per name, deletes removing it.
struct TestServer {
    private var records: [String: SyncIncomingChange] = [:]
    private var order: [String] = []

    mutating func upload(_ changes: [SyncIncomingChange]) {
        for change in changes {
            switch change {
            case .save(let payload):
                if records[payload.recordName] == nil { order.append(payload.recordName) }
                records[payload.recordName] = change
            case .delete(let name, _):
                records[name] = nil
                order.removeAll { $0 == name }
            }
        }
    }

    var everything: [SyncIncomingChange] { order.compactMap { records[$0] } }
}

extension SyncTestDevice {
    /// The first `limit` pending records as one upload the server accepted (a CloudKit operation that
    /// went through before the connection dropped).
    func push(limit: Int) throws -> [SyncIncomingChange] {
        try queue.write { db in
            let pending = Array(try SyncChangeTracker.pending(db: db).prefix(limit))
            var sent: [SyncIncomingChange] = []
            for change in pending {
                if change.kind == .delete {
                    sent.append(.delete(recordName: change.uuid, recordType: change.table))
                } else if let payload = try SyncTranslator.outgoing(change, db: db) {
                    sent.append(.save(payload))
                }
            }
            try SyncChangeTracker.acknowledge(pending, db: db)
            return sent
        }
    }
}

/// A deterministic random source (SplitMix64), so shuffled orders repeat run to run.
struct SeededRandom: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
