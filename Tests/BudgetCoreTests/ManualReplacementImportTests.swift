import XCTest
import GRDB
@testable import BudgetCore
import struct BudgetCore.Category
import struct BudgetCore.Transaction

/// Spec §3: an imported row matching a manual entry (same account, amount and sign, ±3 days)
/// replaces it on Finish import.
final class ManualReplacementImportTests: XCTestCase {
    let july1 = Date(timeIntervalSince1970: 1_782_864_000) // 2026-07-01 00:00 UTC
    let day: TimeInterval = 86_400

    struct Fixture {
        let manager: DatabaseManager
        let coordinator: ImportCoordinator
        let joint: Int64
        let isa: Int64
        let profile: ImportProfile
        let savings: Int64
    }

    func makeFixture() throws -> Fixture {
        let m = try DatabaseManager(path: nil)
        try m.migrate()
        let (joint, isa, savings) = try m.dbQueue.write { db -> (Int64, Int64, Int64) in
            var joint = Account(name: "Lloyds Club Joint", currency: .gbp, kind: .cash, trackingMode: .imported)
            var isa = Account(name: "Lloyds Investment ISA", currency: .gbp, kind: .investment, trackingMode: .imported)
            try joint.insert(db); try isa.insert(db)
            var savings = Category(name: "Savings", type: .transfer)
            try savings.insert(db)
            return (joint.id!, isa.id!, savings.id!)
        }
        let profile = ImportProfile(accountId: isa, format: .csv, csvDelimiter: ",", csvDateColumnIndex: 0, csvDescriptionColumnIndex: 1,
                                    csvAmountColumnIndex: 2, csvDateFormat: "dd/MM/yyyy")
        let coordinator = ImportCoordinator(dbQueue: m.dbQueue, categorizationService: CategorizationService(categorizer: FakeCategorizer()))
        return Fixture(manager: m, coordinator: coordinator, joint: joint, isa: isa, profile: profile, savings: savings)
    }

    /// The Joint → ISA case: imported out in Joint, manual other side in the ISA.
    func makeLinkedManualEntry(_ f: Fixture, note: String? = "top-up") throws -> (out: Transaction, manual: Transaction) {
        try f.manager.dbQueue.write { db in
            var batch = ImportBatch(accountId: f.joint, sourceFileName: "joint.csv", importedAt: Date())
            try batch.insert(db)
            var out = Transaction(importBatchId: batch.id!, accountId: f.joint, date: july1, rawDescription: "TFR TO ISA", amountMinorUnits: -5000,
                                  categoryId: f.savings, status: .confirmed, categorizedBy: .manual, fingerprint: "j1")
            try out.insert(db)
            var manual = try ManualTransactions.addOtherSide(db: db, transactionId: out.id!, accountId: f.isa)
            manual.note = note
            try manual.update(db)
            return (out, manual)
        }
    }

    func stage(_ f: Fixture, _ rows: String) async throws -> StagedImport {
        try await f.coordinator.stageCSVImport(csvText: "Date,Description,Amount\n" + rows, profile: f.profile, accountId: f.isa)
    }

    func testStagingMarksARowMatchingAManualEntryAndPrefillsCategoryAndNote() async throws {
        let f = try makeFixture()
        let (_, manual) = try makeLinkedManualEntry(f)
        let staged = try await stage(f, "03/07/2026,FROM JOINT,50.00\n03/07/2026,INTEREST,1.00")
        let row = staged.staged[0]
        let replacement = try XCTUnwrap(row.replacesManual)
        XCTAssertEqual(replacement.transactionId, manual.id)
        XCTAssertEqual(replacement.date, july1)
        XCTAssertEqual(replacement.categoryId, f.savings)
        XCTAssertEqual(replacement.note, "top-up")
        XCTAssertEqual(row.suggestedCategoryId, f.savings)
        XCTAssertEqual(row.source, .manual)
        XCTAssertNil(row.transfer)
        XCTAssertNil(staged.staged[1].replacesManual)
    }

    func testStagingIgnoresOtherAccountsSignsAmountsAndDistantDates() async throws {
        let f = try makeFixture()
        _ = try makeLinkedManualEntry(f)
        let staged = try await stage(f, "05/07/2026,FROM JOINT,50.00\n01/07/2026,REFUND,-50.00\n01/07/2026,FROM JOINT,50.01")
        XCTAssertTrue(staged.staged.allSatisfy { $0.replacesManual == nil })
        // An imported (non-manual) transaction in the same account is never replaced.
        let other = try makeFixture()
        try await other.manager.dbQueue.write { db in
            var batch = ImportBatch(accountId: other.isa, sourceFileName: "isa-old.csv", importedAt: Date())
            try batch.insert(db)
            var t = Transaction(importBatchId: batch.id!, accountId: other.isa, date: self.july1, rawDescription: "OLD", amountMinorUnits: 5000,
                                categoryId: nil, status: .pendingReview, categorizedBy: .none, fingerprint: "old")
            try t.insert(db)
        }
        let staged2 = try await stage(other, "02/07/2026,FROM JOINT,50.00")
        XCTAssertNil(staged2.staged[0].replacesManual)
    }

    func testEachManualEntryIsReplacedByOneRowTheClosestInDate() async throws {
        let f = try makeFixture()
        let (_, manual) = try makeLinkedManualEntry(f)
        let staged = try await stage(f, "04/07/2026,FROM JOINT,50.00\n02/07/2026,FROM JOINT,50.00")
        XCTAssertNil(staged.staged[0].replacesManual)
        XCTAssertEqual(staged.staged[1].replacesManual?.transactionId, manual.id)
    }

    func testForcedDuplicatesDontClaimAManualEntryAlreadyClaimed() async throws {
        let f = try makeFixture()
        let (_, manual) = try makeLinkedManualEntry(f)
        let staged = try await stage(f, "02/07/2026,FROM JOINT,50.00")
        XCTAssertEqual(staged.staged[0].replacesManual?.transactionId, manual.id)
        let forced = try await f.coordinator.stageForcedDuplicates([ParsedTransaction(date: july1, rawDescription: "FROM JOINT", amountMinorUnits: 5000)],
                                                                   accountId: f.isa, alreadyStaged: staged.staged)
        XCTAssertNil(forced[0].replacesManual)
    }

    func testCommitReplacesTheManualEntryRepointingItsLinks() async throws {
        let f = try makeFixture()
        let (out, manual) = try makeLinkedManualEntry(f)
        let staged = try await stage(f, "02/07/2026,FROM JOINT,50.00")
        let row = staged.staged[0]
        try f.coordinator.commit(accountId: f.isa, sourceFileName: "isa.csv", staged: staged.staged,
                                 decisions: [ImportDecision(stagedId: row.id, finalCategoryId: row.suggestedCategoryId, note: row.replacesManual?.note)])
        let (all, links) = try await f.manager.dbQueue.read { db in (try Transaction.fetchAll(db), try TransferLink.fetchAll(db)) }
        XCTAssertNil(all.first { $0.id == manual.id })
        let imported = try XCTUnwrap(all.first { $0.accountId == f.isa })
        XCTAssertFalse(imported.isManual)
        XCTAssertEqual(imported.categoryId, f.savings)
        XCTAssertEqual(imported.note, "top-up")
        XCTAssertEqual(imported.rawDescription, "FROM JOINT")
        XCTAssertEqual(links.count, 1)
        XCTAssertEqual(links[0].outTransactionId, out.id)
        XCTAssertEqual(links[0].inTransactionId, imported.id)
        XCTAssertEqual(links[0].origin, .manual)
        // Balance: the ISA holds the imported £50 only once.
        XCTAssertEqual(all.filter { $0.accountId == f.isa }.map(\.amountMinorUnits).reduce(0, +), 5000)
        // Budget: the pair counts once, as sent.
        let budget = try await f.manager.dbQueue.read { db in try Transaction.budgetFacing.fetchAll(db) }
        XCTAssertEqual(budget.map(\.id), [out.id])
    }

    func testCommitRepointsAnOutgoingLink() async throws {
        let f = try makeFixture()
        // Manual money sent from the ISA, linked to an imported receipt in Joint.
        let (inLeg, manual) = try await f.manager.dbQueue.write { db -> (Transaction, Transaction) in
            var batch = ImportBatch(accountId: f.joint, sourceFileName: "joint.csv", importedAt: Date())
            try batch.insert(db)
            var inLeg = Transaction(importBatchId: batch.id!, accountId: f.joint, date: self.july1, rawDescription: "FROM ISA", amountMinorUnits: 2000,
                                    categoryId: nil, status: .pendingReview, categorizedBy: .none, fingerprint: "j2")
            try inLeg.insert(db)
            let manual = try ManualTransactions.addOtherSide(db: db, transactionId: inLeg.id!, accountId: f.isa)
            return (inLeg, manual)
        }
        let staged = try await stage(f, "01/07/2026,TO JOINT,-20.00")
        XCTAssertEqual(staged.staged[0].replacesManual?.transactionId, manual.id)
        try f.coordinator.commit(accountId: f.isa, sourceFileName: "isa.csv", staged: staged.staged, decisions: [])
        let (all, links) = try await f.manager.dbQueue.read { db in (try Transaction.fetchAll(db), try TransferLink.fetchAll(db)) }
        let imported = try XCTUnwrap(all.first { $0.accountId == f.isa })
        XCTAssertNil(all.first { $0.id == manual.id })
        XCTAssertEqual(links.map(\.outTransactionId), [imported.id])
        XCTAssertEqual(links.map(\.inTransactionId), [inLeg.id])
    }

    func testCommitWithoutDecisionsKeepsTheManualNote() async throws {
        let f = try makeFixture()
        _ = try makeLinkedManualEntry(f)
        let staged = try await stage(f, "02/07/2026,FROM JOINT,50.00")
        try f.coordinator.commit(accountId: f.isa, sourceFileName: "isa.csv", staged: staged.staged, decisions: [])
        let imported = try await f.manager.dbQueue.read { db in try Transaction.filter(Column("accountId") == f.isa).fetchAll(db) }
        XCTAssertEqual(imported.map(\.note), ["top-up"])
        XCTAssertEqual(imported.map(\.isManual), [false])
    }

    func testLeavingTheRowOutKeepsTheManualEntry() async throws {
        let f = try makeFixture()
        let (_, manual) = try makeLinkedManualEntry(f)
        let staged = try await stage(f, "02/07/2026,FROM JOINT,50.00\n02/07/2026,INTEREST,1.00")
        // The matching row is left out: only the other row is committed.
        try f.coordinator.commit(accountId: f.isa, sourceFileName: "isa.csv", staged: [staged.staged[1]], decisions: [])
        let (stillThere, links) = try await f.manager.dbQueue.read { db in (try Transaction.fetchOne(db, key: manual.id!), try TransferLink.fetchAll(db)) }
        XCTAssertNotNil(stillThere)
        XCTAssertEqual(links.map(\.inTransactionId), [manual.id])
    }

    func testStagingAloneChangesNothing() async throws {
        let f = try makeFixture()
        let (_, manual) = try makeLinkedManualEntry(f)
        _ = try await stage(f, "02/07/2026,FROM JOINT,50.00")
        let stillThere = try await f.manager.dbQueue.read { db in try Transaction.fetchOne(db, key: manual.id!) }
        XCTAssertNotNil(stillThere)
    }

    func testAFailedCommitLeavesTheManualEntry() async throws {
        let f = try makeFixture()
        let (_, manual) = try makeLinkedManualEntry(f)
        let staged = try await stage(f, "02/07/2026,FROM JOINT,50.00")
        // Two rows sharing a fingerprint violate the unique key: the whole write rolls back.
        let row = staged.staged[0]
        let clash = StagedTransaction(parsed: row.parsed, suggestedCategoryId: nil, source: .none, confidence: 0, fingerprint: row.fingerprint)
        XCTAssertThrowsError(try f.coordinator.commit(accountId: f.isa, sourceFileName: "isa.csv", staged: [row, clash], decisions: []))
        let stillThere = try await f.manager.dbQueue.read { db in try Transaction.fetchOne(db, key: manual.id!) }
        XCTAssertNotNil(stillThere)
    }

    func testAManualEntryDeletedBeforeFinishIsSkipped() async throws {
        let f = try makeFixture()
        let (_, manual) = try makeLinkedManualEntry(f)
        let staged = try await stage(f, "02/07/2026,FROM JOINT,50.00")
        try await f.manager.dbQueue.write { db in try ManualTransactions.delete(db: db, id: manual.id!) }
        try f.coordinator.commit(accountId: f.isa, sourceFileName: "isa.csv", staged: staged.staged, decisions: [])
        let count = try await f.manager.dbQueue.read { db in try Transaction.filter(Column("accountId") == f.isa).fetchCount(db) }
        XCTAssertEqual(count, 1)
    }
}
