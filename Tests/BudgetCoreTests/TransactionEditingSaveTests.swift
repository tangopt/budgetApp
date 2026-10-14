import XCTest
import GRDB
@testable import BudgetCore
import struct BudgetCore.Category
import struct BudgetCore.Transaction

/// Edit transaction's Save (`TransactionEditing.save`): the fields, then at most one transfer
/// change, in one write — a refusal anywhere leaves everything as it was.
final class TransactionEditingSaveTests: XCTestCase {
    struct Fixture {
        let manager: DatabaseManager
        let joint: Int64
        let isa: Int64
        let euro: Int64
        let groceries: Int64
        let savings: Int64
        let external: Int64
    }

    let july1 = Date(timeIntervalSince1970: 1_782_864_000) // 2026-07-01 00:00 UTC

    func makeFixture() throws -> Fixture {
        let m = try DatabaseManager(path: nil)
        try m.migrate()
        return try m.dbQueue.write { db in
            var joint = Account(name: "Lloyds Club Joint", currency: .gbp, kind: .cash, trackingMode: .imported, alias: "Joint")
            var isa = Account(name: "Lloyds Investment ISA", currency: .gbp, kind: .investment, trackingMode: .imported)
            var euro = Account(name: "Revolut EUR", currency: .eur, kind: .cash, trackingMode: .imported)
            try joint.insert(db); try isa.insert(db); try euro.insert(db)
            var groceries = Category(name: "Groceries", type: .expense)
            var savings = Category(name: "Savings", type: .transfer)
            var external = Category(name: "To Mum", type: .transfer, isExternalTransfer: true)
            try groceries.insert(db); try savings.insert(db); try external.insert(db)
            var rate = ExchangeRateSetting(eurToGbpRate: 0.8, updatedAt: Date())
            try rate.insert(db)
            return Fixture(manager: m, joint: joint.id!, isa: isa.id!, euro: euro.id!, groceries: groceries.id!,
                           savings: savings.id!, external: external.id!)
        }
    }

    func imported(_ f: Fixture, account: Int64, amount: Int, category: Int64? = nil) throws -> Transaction {
        try f.manager.dbQueue.write { db in
            var batch = ImportBatch(accountId: account, sourceFileName: "statement.csv", importedAt: Date())
            try batch.insert(db)
            var t = Transaction(importBatchId: batch.id!, accountId: account, date: july1, rawDescription: "TFR", amountMinorUnits: amount,
                                categoryId: category, status: category == nil ? .pendingReview : .confirmed,
                                categorizedBy: category == nil ? .none : .manual, fingerprint: UUID().uuidString)
            try t.insert(db)
            return t
        }
    }

    func save(_ f: Fixture, _ id: Int64, _ changes: TransactionEditChanges) throws {
        try f.manager.dbQueue.write { db in try TransactionEditing.save(db: db, id: id, changes: changes) }
    }

    func fetch(_ f: Fixture, _ id: Int64) throws -> Transaction? {
        try f.manager.dbQueue.read { db in try Transaction.fetchOne(db, key: id) }
    }

    func activeLinks(_ f: Fixture) throws -> [TransferLink] {
        try f.manager.dbQueue.read { db in try TransferLink.active.fetchAll(db) }
    }

    func transactionCount(_ f: Fixture) throws -> Int {
        try f.manager.dbQueue.read { db in try Transaction.fetchCount(db) }
    }

    // MARK: Fields only

    func testSaveWithoutATransferChangeSetsCategoryAndNote() throws {
        let f = try makeFixture()
        let t = try imported(f, account: f.joint, amount: -2250)
        try save(f, t.id!, TransactionEditChanges(categoryId: f.groceries, note: "  Weekly shop "))
        let saved = try XCTUnwrap(fetch(f, t.id!))
        XCTAssertEqual(saved.categoryId, f.groceries)
        XCTAssertEqual(saved.note, "Weekly shop")
        XCTAssertEqual(saved.status, .confirmed)
        XCTAssertEqual(saved.categorizedBy, .manual)
    }

    func testSaveAppliesManualFieldsToAManualTransaction() throws {
        let f = try makeFixture()
        let t = try f.manager.dbQueue.write { db in
            try ManualTransactions.add(db: db, accountId: f.joint, date: self.july1, description: "Cash", amountMinorUnits: -500,
                                       categoryId: nil, note: nil)
        }
        let later = july1.addingTimeInterval(86_400)
        try save(f, t.id!, TransactionEditChanges(categoryId: f.groceries, note: nil,
                                                  manual: .init(accountId: f.isa, date: later, description: " Market ", amountMinorUnits: -750)))
        let saved = try XCTUnwrap(fetch(f, t.id!))
        XCTAssertEqual(saved.accountId, f.isa)
        XCTAssertEqual(saved.date, later)
        XCTAssertEqual(saved.rawDescription, "Market")
        XCTAssertEqual(saved.amountMinorUnits, -750)
        XCTAssertEqual(saved.categoryId, f.groceries)
    }

    // MARK: Add the other side

    func testSaveSetsATransferCategoryThenAddsTheOtherSide() throws {
        let f = try makeFixture()
        let out = try imported(f, account: f.joint, amount: -10_000)
        try save(f, out.id!, TransactionEditChanges(categoryId: f.savings, note: "ISA top-up", transfer: .addOtherSide(accountId: f.euro)))
        let saved = try XCTUnwrap(fetch(f, out.id!))
        XCTAssertEqual(saved.categoryId, f.savings)
        XCTAssertEqual(saved.note, "ISA top-up")
        let links = try activeLinks(f)
        XCTAssertEqual(links.count, 1)
        XCTAssertEqual(links.first?.outTransactionId, out.id)
        let other = try XCTUnwrap(fetch(f, links.first!.inTransactionId))
        XCTAssertEqual(other.accountId, f.euro)
        XCTAssertEqual(other.amountMinorUnits, 12_500) // £100 at 0.8 = €125
        XCTAssertEqual(other.categoryId, f.savings, "the other side takes the newly saved category")
        XCTAssertTrue(other.isManual)
    }

    func testAnExternalCategoryRefusesTheOtherSideAndRollsBackTheFields() throws {
        let f = try makeFixture()
        let out = try imported(f, account: f.joint, amount: -10_000)
        XCTAssertThrowsError(try save(f, out.id!, TransactionEditChanges(categoryId: f.external, note: "gift",
                                                                         transfer: .addOtherSide(accountId: f.isa)))) { error in
            XCTAssertEqual(error as? ManualTransactionError, .externalTransferCategory)
        }
        let unchanged = try XCTUnwrap(fetch(f, out.id!))
        XCTAssertNil(unchanged.categoryId)
        XCTAssertNil(unchanged.note)
        XCTAssertEqual(unchanged.status, .pendingReview)
        XCTAssertEqual(try transactionCount(f), 1)
        XCTAssertTrue(try activeLinks(f).isEmpty)
    }

    func testAnExpenseCategoryRefusesTheOtherSide() throws {
        let f = try makeFixture()
        let out = try imported(f, account: f.joint, amount: -10_000, category: f.savings)
        XCTAssertThrowsError(try save(f, out.id!, TransactionEditChanges(categoryId: f.groceries, note: nil,
                                                                         transfer: .addOtherSide(accountId: f.isa)))) { error in
            XCTAssertEqual(error as? ManualTransactionError, .notATransfer)
        }
        XCTAssertEqual(try fetch(f, out.id!)?.categoryId, f.savings)
        XCTAssertEqual(try transactionCount(f), 1)
    }

    func testAnAlreadyLinkedTransactionRollsBackTheFields() throws {
        let f = try makeFixture()
        let out = try imported(f, account: f.joint, amount: -10_000, category: f.savings)
        let inLeg = try imported(f, account: f.isa, amount: 10_000, category: f.savings)
        try f.manager.dbQueue.write { db in _ = try TransferLinks.link(db: db, transactionId: out.id!, with: inLeg.id!) }
        XCTAssertThrowsError(try save(f, out.id!, TransactionEditChanges(categoryId: f.savings, note: "changed",
                                                                         transfer: .addOtherSide(accountId: f.euro)))) { error in
            XCTAssertEqual(error as? ManualTransactionError, .alreadyLinked)
        }
        XCTAssertNil(try fetch(f, out.id!)?.note)
        XCTAssertEqual(try transactionCount(f), 2)
    }

    // MARK: Unlink and link

    func testSaveUnlinksAndSavesTheFields() throws {
        let f = try makeFixture()
        let out = try imported(f, account: f.joint, amount: -10_000, category: f.savings)
        let inLeg = try imported(f, account: f.isa, amount: 10_000, category: f.savings)
        let link = try f.manager.dbQueue.write { db in try TransferLinks.link(db: db, transactionId: out.id!, with: inLeg.id!) }
        try save(f, out.id!, TransactionEditChanges(categoryId: f.savings, note: "not a transfer", transfer: .unlink(linkIds: [link.id!])))
        XCTAssertTrue(try activeLinks(f).isEmpty)
        XCTAssertEqual(try fetch(f, out.id!)?.note, "not a transfer")
    }

    func testUnlinkingALinkThatDoesntInvolveTheTransactionRollsBack() throws {
        let f = try makeFixture()
        let out = try imported(f, account: f.joint, amount: -10_000, category: f.savings)
        let inLeg = try imported(f, account: f.isa, amount: 10_000, category: f.savings)
        let bystander = try imported(f, account: f.euro, amount: -300)
        let link = try f.manager.dbQueue.write { db in try TransferLinks.link(db: db, transactionId: out.id!, with: inLeg.id!) }
        XCTAssertThrowsError(try save(f, bystander.id!, TransactionEditChanges(categoryId: f.groceries, note: nil,
                                                                               transfer: .unlink(linkIds: [link.id!])))) { error in
            XCTAssertEqual(error as? TransferLinkError, .linkNotFound)
        }
        XCTAssertNil(try fetch(f, bystander.id!)?.categoryId)
        XCTAssertEqual(try activeLinks(f).count, 1)
    }

    func testSaveLinksAndSavesTheFields() throws {
        let f = try makeFixture()
        let out = try imported(f, account: f.joint, amount: -10_000)
        let inLeg = try imported(f, account: f.isa, amount: 10_000)
        try save(f, out.id!, TransactionEditChanges(categoryId: f.savings, note: nil, transfer: .link(transactionId: inLeg.id!)))
        let links = try activeLinks(f)
        XCTAssertEqual(links.map(\.outTransactionId), [out.id!])
        XCTAssertEqual(links.map(\.inTransactionId), [inLeg.id!])
        XCTAssertEqual(links.first?.origin, .manual)
        XCTAssertEqual(try fetch(f, out.id!)?.categoryId, f.savings)
    }

    func testAFailingLinkRollsBackTheFields() throws {
        let f = try makeFixture()
        let out = try imported(f, account: f.joint, amount: -10_000)
        let sameSign = try imported(f, account: f.isa, amount: -10_000)
        XCTAssertThrowsError(try save(f, out.id!, TransactionEditChanges(categoryId: f.savings, note: "x",
                                                                         transfer: .link(transactionId: sameSign.id!)))) { error in
            XCTAssertEqual(error as? TransferLinkError, .notOppositeAmounts)
        }
        let unchanged = try XCTUnwrap(fetch(f, out.id!))
        XCTAssertNil(unchanged.categoryId)
        XCTAssertNil(unchanged.note)
        XCTAssertTrue(try activeLinks(f).isEmpty)
    }

    func testAManualFieldRefusalLeavesEverythingAsItWas() throws {
        let f = try makeFixture()
        let t = try f.manager.dbQueue.write { db in
            try ManualTransactions.add(db: db, accountId: f.joint, date: self.july1, description: "Cash", amountMinorUnits: -500,
                                       categoryId: nil, note: nil)
        }
        XCTAssertThrowsError(try save(f, t.id!, TransactionEditChanges(categoryId: f.savings, note: nil,
                                                                       manual: .init(accountId: f.joint, date: july1, description: "  ", amountMinorUnits: -500),
                                                                       transfer: .addOtherSide(accountId: f.isa)))) { error in
            XCTAssertEqual(error as? ManualTransactionError, .emptyDescription)
        }
        XCTAssertEqual(try transactionCount(f), 1)
        XCTAssertNil(try fetch(f, t.id!)?.categoryId)
    }

    // MARK: Other side preview

    func testOtherSideAmountIsOppositeSignAndConverted() {
        XCTAssertEqual(ManualTransactions.otherSideAmount(-10_000, from: .gbp, to: .eur, rate: 0.8), 12_500)
        XCTAssertEqual(ManualTransactions.otherSideAmount(12_500, from: .eur, to: .gbp, rate: 0.8), -10_000)
        XCTAssertEqual(ManualTransactions.otherSideAmount(-1, from: .gbp, to: .gbp, rate: 0.8), 1)
    }
}
