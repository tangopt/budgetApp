import XCTest
import GRDB
@testable import BudgetCore

final class AccountOrderingTests: XCTestCase {
    private func makeDB() throws -> DatabaseManager {
        let m = try DatabaseManager(path: nil)
        try m.migrate()
        return m
    }

    private func acct(_ id: Int64, _ name: String, order: Int? = nil, kind: AccountKind = .cash) -> Account {
        var a = Account(id: id, name: name, currency: .gbp, kind: kind, trackingMode: .manual)
        a.sortOrder = order
        return a
    }

    private func add(_ db: Database, _ name: String, kind: AccountKind = .cash) throws -> Int64 {
        try AccountEditing.add(db: db, name: name, currency: .gbp, kind: kind, trackingMode: .manual, openingBalanceEntered: nil, asOf: Date()).id!
    }

    private func orderedIds(_ m: DatabaseManager) throws -> [Int64] {
        try m.dbQueue.read { db in AccountOrdering.sorted(try Account.fetchAll(db)).compactMap(\.id) }
    }

    // MARK: sorted

    func testSortedWithoutOrderIsAlphabeticalByDisplayName() {
        var zeta = acct(1, "Zeta Bank")
        zeta.alias = "amex"
        let sorted = AccountOrdering.sorted([acct(2, "Card 10"), zeta, acct(3, "Barclays"), acct(4, "Card 9")])
        XCTAssertEqual(sorted.compactMap(\.id), [1, 3, 4, 2])
    }

    func testOrderedAccountsComeFirstThenUnorderedAlphabetically() {
        let sorted = AccountOrdering.sorted([acct(1, "Alpha"), acct(2, "Zulu", order: 1), acct(3, "Beta"), acct(4, "Mike", order: 0)])
        XCTAssertEqual(sorted.compactMap(\.id), [4, 2, 1, 3])
    }

    func testEqualSortOrderFallsBackToDisplayName() {
        let sorted = AccountOrdering.sorted([acct(1, "Zulu", order: 0), acct(2, "Alpha", order: 0)])
        XCTAssertEqual(sorted.compactMap(\.id), [2, 1])
    }

    // MARK: move

    func testFirstMoveAssignsOrderToAllInDisplayedOrderThenMoves() throws {
        let m = try makeDB()
        let (a, b, c) = try m.dbQueue.write { db in (try add(db, "A"), try add(db, "B"), try add(db, "C")) }
        // Displayed: A B C — drag C to the top.
        try m.dbQueue.write { db in try AccountOrdering.move(db: db, ids: [a, b, c], fromOffsets: IndexSet(integer: 2), toOffset: 0) }
        XCTAssertEqual(try orderedIds(m), [c, a, b])
        let orders = try m.dbQueue.read { db in try Account.fetchAll(db).sorted { $0.id! < $1.id! }.map(\.sortOrder) }
        XCTAssertEqual(orders, [1, 2, 0])
    }

    func testMoveRenumbersZeroToNMinusOne() throws {
        let m = try makeDB()
        let ids = try m.dbQueue.write { db in try ["A", "B", "C", "D"].map { try add(db, $0) } }
        try m.dbQueue.write { db in
            // Gappy stored order.
            for (i, id) in ids.enumerated() { try db.execute(sql: "UPDATE account SET sortOrder = ? WHERE id = ?", arguments: [i * 10 + 5, id]) }
            // A down below C (SwiftUI offset semantics: before index 3).
            try AccountOrdering.move(db: db, ids: ids, fromOffsets: IndexSet(integer: 0), toOffset: 3)
        }
        XCTAssertEqual(try orderedIds(m), [ids[1], ids[2], ids[0], ids[3]])
        let orders = try m.dbQueue.read { db in AccountOrdering.sorted(try Account.fetchAll(db)).map(\.sortOrder) }
        XCTAssertEqual(orders, [0, 1, 2, 3])
    }

    func testMoveWithinSubsetKeepsOtherAccountsInPlace() throws {
        let m = try makeDB()
        // Displayed overall: A(cash) B(credit) C(cash) D(credit); the credit section shows [B, D].
        let (a, b, c, d) = try m.dbQueue.write { db in
            (try add(db, "A"), try add(db, "B", kind: .credit), try add(db, "C"), try add(db, "D", kind: .credit))
        }
        try m.dbQueue.write { db in try AccountOrdering.move(db: db, ids: [b, d], fromOffsets: IndexSet(integer: 1), toOffset: 0) }
        XCTAssertEqual(try orderedIds(m), [a, d, c, b])
    }

    func testMoveIgnoresUnknownIdsAndNoOpMoveKeepsOrder() throws {
        let m = try makeDB()
        let (a, b) = try m.dbQueue.write { db in (try add(db, "A"), try add(db, "B")) }
        try m.dbQueue.write { db in try AccountOrdering.move(db: db, ids: [a, 999, b], fromOffsets: IndexSet(integer: 0), toOffset: 1) }
        XCTAssertEqual(try orderedIds(m), [a, b])
    }

    func testMoveDedupesRepeatedIdsKeepingFirstOccurrence() throws {
        let m = try makeDB()
        let (a, b, c) = try m.dbQueue.write { db in (try add(db, "A"), try add(db, "B"), try add(db, "C")) }
        // A repeated: no account may be lost or listed twice.
        try m.dbQueue.write { db in try AccountOrdering.move(db: db, ids: [a, a, b, c], fromOffsets: IndexSet(integer: 3), toOffset: 1) }
        XCTAssertEqual(try orderedIds(m), [a, c, b])
        let orders = try m.dbQueue.read { db in AccountOrdering.sorted(try Account.fetchAll(db)).map(\.sortOrder) }
        XCTAssertEqual(orders, [0, 1, 2])
    }

    // MARK: new accounts

    func testNewAccountHasNoOrderUntilAnyOrderExists() throws {
        let m = try makeDB()
        let first = try m.dbQueue.write { db in try add(db, "M") }
        XCTAssertNil(try m.dbQueue.read { db in try Account.fetchOne(db, key: first)?.sortOrder })
    }

    func testNewAccountIsAppendedAtEndOnceOrdered() throws {
        let m = try makeDB()
        let (b, c) = try m.dbQueue.write { db in (try add(db, "B"), try add(db, "C")) }
        try m.dbQueue.write { db in try AccountOrdering.move(db: db, ids: [b, c], fromOffsets: IndexSet(integer: 1), toOffset: 0) }
        let a = try m.dbQueue.write { db in try add(db, "A") }
        XCTAssertEqual(try m.dbQueue.read { db in try Account.fetchOne(db, key: a)?.sortOrder }, 2)
        XCTAssertEqual(try orderedIds(m), [c, b, a])
    }

    func testUpdateKeepsSortOrder() throws {
        let m = try makeDB()
        let (a, b) = try m.dbQueue.write { db in (try add(db, "A"), try add(db, "B")) }
        try m.dbQueue.write { db in
            try AccountOrdering.move(db: db, ids: [a, b], fromOffsets: IndexSet(integer: 1), toOffset: 0)
            try AccountEditing.update(db: db, accountId: a, name: "A2", kind: .cash, trackingMode: .manual)
        }
        XCTAssertEqual(try orderedIds(m), [b, a])
    }

    // MARK: migration

    func testMigrationAddsNullableSortOrder() throws {
        let manager = try DatabaseManager(path: nil)
        try manager.migrate(upTo: "addAccountAliasAndDetails")
        try manager.dbQueue.write { db in
            try db.execute(sql: "INSERT INTO account (name, currency, kind, trackingMode) VALUES ('Old', 'gbp', 'cash', 'manual')")
        }
        try manager.migrate()
        let columns = try manager.dbQueue.read { db in try db.columns(in: "account").map(\.name) }
        XCTAssertTrue(columns.contains("sortOrder"))
        let old = try manager.dbQueue.read { db in try Account.fetchOne(db) }
        XCTAssertEqual(old?.name, "Old")
        XCTAssertNil(old?.sortOrder)
    }
}
