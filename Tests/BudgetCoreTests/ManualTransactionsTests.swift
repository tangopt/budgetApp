import XCTest
import GRDB
@testable import BudgetCore
import struct BudgetCore.Category
import struct BudgetCore.Transaction

final class ManualTransactionsTests: XCTestCase {
    struct Fixture {
        let manager: DatabaseManager
        let joint: Int64
        let isa: Int64
        let euro: Int64
        let groceries: Int64
        let savings: Int64
        let external: Int64
        let reserve: Int64
    }

    static let day: TimeInterval = 86_400
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
            var reserve = Category(name: "Misc reserve", type: .expense, isReserved: true)
            try groceries.insert(db); try savings.insert(db); try external.insert(db); try reserve.insert(db)
            var rate = ExchangeRateSetting(eurToGbpRate: 0.8, updatedAt: Date())
            try rate.insert(db)
            return Fixture(manager: m, joint: joint.id!, isa: isa.id!, euro: euro.id!, groceries: groceries.id!,
                           savings: savings.id!, external: external.id!, reserve: reserve.id!)
        }
    }

    @discardableResult
    func add(_ f: Fixture, account: Int64? = nil, date: Date? = nil, description: String = "Cash at market", amount: Int = -1250,
             category: Int64? = nil, note: String? = nil) throws -> Transaction {
        try f.manager.dbQueue.write { db in
            try ManualTransactions.add(db: db, accountId: account ?? f.joint, date: date ?? july1, description: description,
                                       amountMinorUnits: amount, categoryId: category, note: note)
        }
    }

    func importedTransaction(_ f: Fixture, account: Int64, amount: Int, category: Int64? = nil, date: Date? = nil) throws -> Transaction {
        try f.manager.dbQueue.write { db in
            var batch = ImportBatch(accountId: account, sourceFileName: "statement.csv", importedAt: Date())
            try batch.insert(db)
            var t = Transaction(importBatchId: batch.id!, accountId: account, date: date ?? july1, rawDescription: "TFR", amountMinorUnits: amount,
                                categoryId: category, status: category == nil ? .pendingReview : .confirmed,
                                categorizedBy: category == nil ? .none : .manual, fingerprint: UUID().uuidString)
            try t.insert(db)
            return t
        }
    }

    func fetch(_ f: Fixture, _ id: Int64) throws -> Transaction? {
        try f.manager.dbQueue.read { db in try Transaction.fetchOne(db, key: id) }
    }

    func links(_ f: Fixture) throws -> [TransferLink] {
        try f.manager.dbQueue.read { db in try TransferLink.fetchAll(db) }
    }

    func assertThrows(_ expected: ManualTransactionError, file: StaticString = #filePath, line: UInt = #line, _ body: () throws -> Void) {
        XCTAssertThrowsError(try body(), file: file, line: line) { error in
            XCTAssertEqual(error as? ManualTransactionError, expected, file: file, line: line)
            XCTAssertNotNil((error as? LocalizedError)?.errorDescription, file: file, line: line)
        }
    }

    // MARK: Add

    func testAddCategorisedIsConfirmedManualWithTrimmedFields() throws {
        let f = try makeFixture()
        let t = try add(f, description: "  Cash at market ", category: f.groceries, note: "  eggs ")
        let saved = try XCTUnwrap(try fetch(f, t.id!))
        XCTAssertTrue(saved.isManual)
        XCTAssertEqual(saved.status, .confirmed)
        XCTAssertEqual(saved.categorizedBy, .manual)
        XCTAssertEqual(saved.rawDescription, "Cash at market")
        XCTAssertEqual(saved.note, "eggs")
        XCTAssertEqual(saved.amountMinorUnits, -1250)
        XCTAssertEqual(saved.date, july1)
        XCTAssertTrue(saved.fingerprint.hasPrefix("manual-"))
    }

    func testAddUncategorisedIsPendingReview() throws {
        let f = try makeFixture()
        let t = try add(f)
        XCTAssertEqual(t.status, .pendingReview)
        XCTAssertNil(t.categoryId)
        XCTAssertTrue(t.isManual)
    }

    func testAddRejectsReserveZeroAndEmptyDescription() throws {
        let f = try makeFixture()
        assertThrows(.reservedCategory) { try add(f, category: f.reserve) }
        assertThrows(.zeroAmount) { try add(f, amount: 0) }
        assertThrows(.emptyDescription) { try add(f, description: "   ") }
        assertThrows(.accountNotFound) { try add(f, account: 999) }
        assertThrows(.categoryNotFound) { try add(f, category: 999) }
        XCTAssertEqual(try f.manager.dbQueue.read { db in try Transaction.fetchCount(db) }, 0)
    }

    func testManualEntriesBatchIsCreatedOncePerAccountAndReused() throws {
        let f = try makeFixture()
        let a = try add(f)
        let b = try add(f, amount: -500)
        let c = try add(f, account: f.isa, amount: 500)
        XCTAssertEqual(a.importBatchId, b.importBatchId)
        XCTAssertNotEqual(a.importBatchId, c.importBatchId)
        let batches = try f.manager.dbQueue.read { db in try ImportBatch.fetchAll(db) }
        XCTAssertEqual(batches.count, 2)
        XCTAssertTrue(batches.allSatisfy { $0.sourceFileName == ManualTransactions.batchSourceFileName })
        XCTAssertEqual(ManualTransactions.batchSourceFileName, "Manual entries")
        XCTAssertEqual(Set(batches.map(\.accountId)), [f.joint, f.isa])
        XCTAssertNotEqual(a.fingerprint, b.fingerprint)
    }

    func testManualTransactionsCountInBalancesAndBudget() throws {
        let f = try makeFixture()
        let cash = try f.manager.dbQueue.write { db -> Int64 in
            var cash = Account(name: "Cash tin", currency: .gbp, kind: .cash, trackingMode: .manual)
            try cash.insert(db)
            for (account, amount) in [(f.joint, 10_000), (cash.id!, 3_000)] {
                var snapshot = BalanceSnapshot(accountId: account, date: july1.addingTimeInterval(-Self.day), balanceMinorUnits: amount, note: nil)
                try snapshot.insert(db)
            }
            return cash.id!
        }
        try add(f, amount: -1250, category: f.groceries)
        try add(f, account: cash, amount: -700, category: f.groceries)
        let budget = try f.manager.dbQueue.read { db in try Transaction.budgetFacing.fetchAll(db) }
        XCTAssertEqual(budget.map(\.amountMinorUnits).sorted(), [-1250, -700])
        let balances = try f.manager.dbQueue.read { db in
            NetWorthCalculator.accountBalances(accounts: try Account.fetchAll(db), snapshots: try BalanceSnapshot.fetchAll(db),
                                               transactions: try Transaction.fetchAll(db), rate: try ExchangeRateSetting.currentOrDefault(db: db))
        }
        let byId = Dictionary(uniqueKeysWithValues: balances.map { ($0.account.id!, $0.nativeBalanceMinorUnits) })
        // An imported account's computed balance includes the manual entry…
        XCTAssertEqual(byId[f.joint], 8_750)
        // …a manually tracked account's balance comes from its snapshots only.
        XCTAssertEqual(byId[cash], 3_000)
    }

    // MARK: Update

    func testUpdateChangesFieldsAndStatus() throws {
        let f = try makeFixture()
        let t = try add(f)
        let later = july1.addingTimeInterval(2 * Self.day)
        try f.manager.dbQueue.write { db in
            try ManualTransactions.update(db: db, id: t.id!, date: later, description: " Farm shop ", amountMinorUnits: -900,
                                          accountId: f.joint, categoryId: f.groceries, note: "veg")
        }
        let saved = try XCTUnwrap(try fetch(f, t.id!))
        XCTAssertEqual(saved.date, later)
        XCTAssertEqual(saved.rawDescription, "Farm shop")
        XCTAssertEqual(saved.amountMinorUnits, -900)
        XCTAssertEqual(saved.categoryId, f.groceries)
        XCTAssertEqual(saved.status, .confirmed)
        XCTAssertEqual(saved.note, "veg")
        XCTAssertEqual(saved.fingerprint, t.fingerprint)
        XCTAssertTrue(saved.isManual)

        try f.manager.dbQueue.write { db in
            try ManualTransactions.update(db: db, id: t.id!, date: later, description: "Farm shop", amountMinorUnits: -900,
                                          accountId: f.joint, categoryId: nil, note: " ")
        }
        let cleared = try XCTUnwrap(try fetch(f, t.id!))
        XCTAssertEqual(cleared.status, .pendingReview)
        XCTAssertNil(cleared.note)
    }

    func testUpdateValidates() throws {
        let f = try makeFixture()
        let t = try add(f)
        let imported = try importedTransaction(f, account: f.joint, amount: -100)
        func update(_ id: Int64, description: String = "x", amount: Int = -100, account: Int64? = nil, category: Int64? = nil) throws {
            try f.manager.dbQueue.write { db in
                try ManualTransactions.update(db: db, id: id, date: july1, description: description, amountMinorUnits: amount,
                                              accountId: account ?? f.joint, categoryId: category, note: nil)
            }
        }
        assertThrows(.notManual) { try update(imported.id!) }
        assertThrows(.transactionNotFound) { try update(999) }
        assertThrows(.reservedCategory) { try update(t.id!, category: f.reserve) }
        assertThrows(.zeroAmount) { try update(t.id!, amount: 0) }
        assertThrows(.emptyDescription) { try update(t.id!, description: "") }
        assertThrows(.accountNotFound) { try update(t.id!, account: 999) }
    }

    func testMovingToAnotherAccountMovesToThatAccountsManualBatch() throws {
        let f = try makeFixture()
        let existingIsa = try add(f, account: f.isa, amount: 100)
        let t = try add(f)
        try f.manager.dbQueue.write { db in
            try ManualTransactions.update(db: db, id: t.id!, date: july1, description: "Cash", amountMinorUnits: -1250,
                                          accountId: f.isa, categoryId: nil, note: nil)
        }
        let saved = try XCTUnwrap(try fetch(f, t.id!))
        XCTAssertEqual(saved.accountId, f.isa)
        XCTAssertEqual(saved.importBatchId, existingIsa.importBatchId)
    }

    func testUpdateKeepsALinkThatStillHolds() throws {
        let f = try makeFixture()
        let out = try importedTransaction(f, account: f.joint, amount: -5000, category: f.savings)
        let manualIn = try f.manager.dbQueue.write { db in try ManualTransactions.addOtherSide(db: db, transactionId: out.id!, accountId: f.isa) }
        try f.manager.dbQueue.write { db in
            try ManualTransactions.update(db: db, id: manualIn.id!, date: july1.addingTimeInterval(Self.day), description: "ISA top-up",
                                          amountMinorUnits: 4900, accountId: f.isa, categoryId: f.savings, note: nil)
        }
        XCTAssertEqual(try links(f).count, 1)
    }

    func testUpdateRemovesALinkWhenTheSignFlips() throws {
        let f = try makeFixture()
        let out = try importedTransaction(f, account: f.joint, amount: -5000, category: f.savings)
        let manualIn = try f.manager.dbQueue.write { db in try ManualTransactions.addOtherSide(db: db, transactionId: out.id!, accountId: f.isa) }
        try f.manager.dbQueue.write { db in
            try ManualTransactions.update(db: db, id: manualIn.id!, date: july1, description: "x", amountMinorUnits: -5000,
                                          accountId: f.isa, categoryId: f.savings, note: nil)
        }
        XCTAssertTrue(try links(f).isEmpty)
    }

    func testUpdateRemovesALinkWhenMovedIntoTheOtherLegsAccount() throws {
        let f = try makeFixture()
        let out = try importedTransaction(f, account: f.joint, amount: -5000, category: f.savings)
        let manualIn = try f.manager.dbQueue.write { db in try ManualTransactions.addOtherSide(db: db, transactionId: out.id!, accountId: f.isa) }
        try f.manager.dbQueue.write { db in
            try ManualTransactions.update(db: db, id: manualIn.id!, date: july1, description: "x", amountMinorUnits: 5000,
                                          accountId: f.joint, categoryId: f.savings, note: nil)
        }
        XCTAssertTrue(try links(f).isEmpty)
    }

    // MARK: Delete

    func testDeleteRemovesManualAndCascadesLinks() throws {
        let f = try makeFixture()
        let out = try importedTransaction(f, account: f.joint, amount: -5000, category: f.savings)
        let manualIn = try f.manager.dbQueue.write { db in try ManualTransactions.addOtherSide(db: db, transactionId: out.id!, accountId: f.isa) }
        try f.manager.dbQueue.write { db in try ManualTransactions.delete(db: db, id: manualIn.id!) }
        XCTAssertNil(try fetch(f, manualIn.id!))
        XCTAssertNotNil(try fetch(f, out.id!))
        XCTAssertTrue(try links(f).isEmpty)
    }

    func testDeleteRefusesImportedTransactions() throws {
        let f = try makeFixture()
        let imported = try importedTransaction(f, account: f.joint, amount: -100)
        assertThrows(.notManual) { try f.manager.dbQueue.write { db in try ManualTransactions.delete(db: db, id: imported.id!) } }
        assertThrows(.transactionNotFound) { try f.manager.dbQueue.write { db in try ManualTransactions.delete(db: db, id: 999) } }
        XCTAssertNotNil(try fetch(f, imported.id!))
    }

    // MARK: Add the other side

    func testAddOtherSideOfMoneySentCreatesTheIncomingLegAndLinksIt() throws {
        let f = try makeFixture()
        let out = try importedTransaction(f, account: f.joint, amount: -5000, category: f.savings)
        let other = try f.manager.dbQueue.write { db in try ManualTransactions.addOtherSide(db: db, transactionId: out.id!, accountId: f.isa) }
        XCTAssertEqual(other.accountId, f.isa)
        XCTAssertEqual(other.amountMinorUnits, 5000)
        XCTAssertEqual(other.date, out.date)
        XCTAssertEqual(other.categoryId, f.savings)
        XCTAssertEqual(other.status, .confirmed)
        XCTAssertTrue(other.isManual)
        XCTAssertEqual(other.rawDescription, "Transfer from Joint")
        let link = try XCTUnwrap(try links(f).first)
        XCTAssertEqual(link.outTransactionId, out.id)
        XCTAssertEqual(link.inTransactionId, other.id)
        XCTAssertEqual(link.origin, .manual)
        XCTAssertFalse(link.isDismissed)
        // Counts once, as sent.
        let budget = try f.manager.dbQueue.read { db in try Transaction.budgetFacing.fetchAll(db) }
        XCTAssertEqual(budget.map(\.id), [out.id])
    }

    func testAddOtherSideOfMoneyReceivedCreatesTheOutgoingLeg() throws {
        let f = try makeFixture()
        let inLeg = try importedTransaction(f, account: f.isa, amount: 5000)
        let other = try f.manager.dbQueue.write { db in try ManualTransactions.addOtherSide(db: db, transactionId: inLeg.id!, accountId: f.joint) }
        XCTAssertEqual(other.amountMinorUnits, -5000)
        XCTAssertNil(other.categoryId)
        XCTAssertEqual(other.status, .pendingReview)
        XCTAssertEqual(other.rawDescription, "Transfer to Lloyds Investment ISA")
        let link = try XCTUnwrap(try links(f).first)
        XCTAssertEqual(link.outTransactionId, other.id)
        XCTAssertEqual(link.inTransactionId, inLeg.id)
    }

    func testAddOtherSideConvertsAtTheStoredRate() throws {
        let f = try makeFixture()
        let out = try importedTransaction(f, account: f.joint, amount: -8000)
        let eur = try f.manager.dbQueue.write { db in try ManualTransactions.addOtherSide(db: db, transactionId: out.id!, accountId: f.euro) }
        XCTAssertEqual(eur.amountMinorUnits, 10000) // £80 at 0.8 = €100

        let eurOut = try importedTransaction(f, account: f.euro, amount: -1001)
        let gbp = try f.manager.dbQueue.write { db in try ManualTransactions.addOtherSide(db: db, transactionId: eurOut.id!, accountId: f.joint) }
        XCTAssertEqual(gbp.amountMinorUnits, 801) // €10.01 × 0.8 = £8.008 → £8.01
    }

    func testAddOtherSideRefusals() throws {
        let f = try makeFixture()
        let external = try importedTransaction(f, account: f.joint, amount: -5000, category: f.external)
        assertThrows(.externalTransferCategory) {
            try f.manager.dbQueue.write { db in _ = try ManualTransactions.addOtherSide(db: db, transactionId: external.id!, accountId: f.isa) }
        }
        let groceries = try importedTransaction(f, account: f.joint, amount: -5000, category: f.groceries)
        assertThrows(.notATransfer) {
            try f.manager.dbQueue.write { db in _ = try ManualTransactions.addOtherSide(db: db, transactionId: groceries.id!, accountId: f.isa) }
        }
        let out = try importedTransaction(f, account: f.joint, amount: -5000)
        assertThrows(.sameAccount) {
            try f.manager.dbQueue.write { db in _ = try ManualTransactions.addOtherSide(db: db, transactionId: out.id!, accountId: f.joint) }
        }
        assertThrows(.accountNotFound) {
            try f.manager.dbQueue.write { db in _ = try ManualTransactions.addOtherSide(db: db, transactionId: out.id!, accountId: 999) }
        }
        assertThrows(.transactionNotFound) {
            try f.manager.dbQueue.write { db in _ = try ManualTransactions.addOtherSide(db: db, transactionId: 999, accountId: f.isa) }
        }
        try f.manager.dbQueue.write { db in _ = try ManualTransactions.addOtherSide(db: db, transactionId: out.id!, accountId: f.isa) }
        assertThrows(.alreadyLinked) {
            try f.manager.dbQueue.write { db in _ = try ManualTransactions.addOtherSide(db: db, transactionId: out.id!, accountId: f.euro) }
        }
        XCTAssertEqual(try links(f).count, 1)
        // Only the one other side was created.
        XCTAssertEqual(try f.manager.dbQueue.read { db in try Transaction.filter(Column("isManual") == true).fetchCount(db) }, 1)
    }

    func testAddOtherSideIgnoresADismissedLink() throws {
        let f = try makeFixture()
        let out = try importedTransaction(f, account: f.joint, amount: -5000)
        let inLeg = try importedTransaction(f, account: f.euro, amount: 6250)
        try f.manager.dbQueue.write { db in
            var link = TransferLink(outTransactionId: out.id!, inTransactionId: inLeg.id!, origin: .auto, isDismissed: true)
            try link.insert(db)
        }
        let other = try f.manager.dbQueue.write { db in try ManualTransactions.addOtherSide(db: db, transactionId: out.id!, accountId: f.isa) }
        XCTAssertEqual(other.amountMinorUnits, 5000)
    }
}
