import XCTest
import GRDB
@testable import BudgetCore
@testable import BudgetDemo
import TestSupport

/// One person per Mac user (`SharingSignIn`): nobody signs in to a database holding someone else's private records;
/// the household's shared view (stubs and summaries) lets anyone in.
final class SharingSignInTests: XCTestCase {
    func testTheOtherPersonIsRefusedOnTheOwnersDatabase() throws {
        let queue = try TestDatabase.demo()
        try queue.read { db in
            let a = try XCTUnwrap(try Int64.fetchOne(db, sql: "SELECT id FROM person WHERE name = ?", arguments: [DemoDatabase.personA]))
            let b = try XCTUnwrap(try Int64.fetchOne(db, sql: "SELECT id FROM person WHERE name = ?", arguments: [DemoDatabase.personB]))
            XCTAssertNil(try SharingSignIn.refusal(personId: a, db: db), "the owner")
            XCTAssertEqual(try SharingSignIn.refusal(personId: b, db: db),
                           "This Mac user holds someone else's private accounts. Sign in on your own Mac user.")
        }
    }

    func testEveryoneSignsInBeforeTheOwnersAreSetAndWhenAllIsShared() throws {
        let queue = try TestDatabase.demo()
        try queue.write { db in
            let b = try XCTUnwrap(try Int64.fetchOne(db, sql: "SELECT id FROM person WHERE name = ?", arguments: [DemoDatabase.personB]))
            try db.execute(sql: "UPDATE account SET sharingLevel = 'everything'")
            XCTAssertNil(try SharingSignIn.refusal(personId: b, db: db), "every account shared in full")
            try db.execute(sql: "UPDATE account SET ownerPersonId = NULL")
            XCTAssertNil(try SharingSignIn.refusal(personId: b, db: db), "no owners yet")
        }
    }

    /// The member's own device holds the admin's private accounts only as stubs and summaries (and §10 property
    /// money): she signs in there.
    func testTheMemberSignsInOnHerOwnDevice() async throws {
        let h = try TwoPersonHousehold.make()
        try await h.syncAll()
        let refusal = try await h.memberDevice.db.read { db -> String? in
            let b = try SyncRecordStore.localId(table: "person", uuid: h.personBUuid, db: db) ?? -1
            let stubs = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM account WHERE sharingLevel != 'everything'") ?? 0
            return stubs > 0 && b > 0 ? try SharingSignIn.refusal(personId: b, db: db) : "missing stubs or person"
        }
        XCTAssertNil(refusal, "the admin's private accounts are here as stubs, and she signs in")
        // On the admin's Mac she is refused.
        let onMac = try await h.adminMac.db.read { db in try SharingSignIn.refusal(personId: h.fixture.personB, db: db) }
        XCTAssertNotNil(onMac)
    }

    /// The demo with A's private records taken out is what B's own device holds: she signs in there, and A's
    /// accounts stay as stubs with their summaries.
    func testTakingOutTheOthersPrivateRecordsLetsThemIn() throws {
        let queue = try TestDatabase.demo()
        try queue.write { db in
            let b = try XCTUnwrap(try Int64.fetchOne(db, sql: "SELECT id FROM person WHERE name = ?", arguments: [DemoDatabase.personB]))
            let records = try SharingSignIn.othersPrivateRecords(personId: b, db: db)
            XCTAssertGreaterThan(records.count, 100)
            XCTAssertTrue(Set(records.map(\.table)).isSubset(of: ["balanceSnapshot", "forecastEntry", "importBatch", "importProfile", "transaction_", "balanceSnapshotArchive"]))
            for table in ["forecastEntry", "balanceSnapshot", "balanceSnapshotArchive", "transaction_", "importBatch", "importProfile"] {
                for record in records where record.table == table {
                    try db.execute(sql: "DELETE FROM \(table) WHERE id = ?", arguments: [record.id])
                }
            }
            XCTAssertNil(try SharingSignIn.refusal(personId: b, db: db))
            XCTAssertGreaterThan(try AccountSummaryMonth.fetchCount(db), 0, "the summaries stay")
        }
    }
}
