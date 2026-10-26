import XCTest
import GRDB
@testable import BudgetCore
@testable import BudgetDemo
import TestSupport

/// Settings ▸ Sharing's reads (`SharingOverview`) and the viewer's account rules the screens use (lock badges, Hidden
/// absent, net worth's note), on the demo (`DemoSharing`: A the admin, one joint account, one at Category totals).
final class SharingOverviewTests: XCTestCase {
    private func ids(_ db: Database) throws -> (a: Int64, b: Int64, accounts: [String: Account]) {
        let a = try XCTUnwrap(try Int64.fetchOne(db, sql: "SELECT id FROM person WHERE name = ?", arguments: [DemoDatabase.personA]))
        let b = try XCTUnwrap(try Int64.fetchOne(db, sql: "SELECT id FROM person WHERE name = ?", arguments: [DemoDatabase.personB]))
        return (a, b, Dictionary(uniqueKeysWithValues: try Account.fetchAll(db).map { ($0.name, $0) }))
    }

    func testTheAdminSeesTheirAccountsAndTheJointOnes() throws {
        let queue = try TestDatabase.demo()
        try queue.write { db in
            let (_, _, accounts) = try ids(db)
            let overview = try SharingOverview.load(actor: try AccessActor.admin(db: db), db: db)
            XCTAssertTrue(overview.isConfirmed)
            XCTAssertTrue(overview.isAdmin)
            XCTAssertFalse(overview.canSetOwners, "once only")
            XCTAssertEqual(overview.joint.map(\.displayName), [DemoSharing.jointAccount])
            XCTAssertEqual(overview.joint.map(\.level), [.everything])
            XCTAssertEqual(Set(overview.own.map(\.id)), Set(accounts.values.filter { $0.ownerPersonId != nil }.compactMap(\.id)))
            XCTAssertEqual(overview.own.first { $0.displayName == DemoSharing.categoryTotalsAccount }?.level, .categoryTotals)
            XCTAssertEqual(overview.own.map(\.id), AccountOrdering.sorted(accounts.values.filter { $0.ownerPersonId != nil }).compactMap(\.id))
            XCTAssertEqual(overview.taxIncomeLevel, .everything)
            XCTAssertEqual(overview.otherName, DemoDatabase.personB, "no app user for B: the person's name")
        }
    }

    func testAMemberSeesOnlyTheirOwnAndNoSetUp() throws {
        let queue = try TestDatabase.demo()
        try queue.write { db in
            let (_, b, _) = try ids(db)
            var user = AppUser(personId: b, displayName: "B", isAdmin: false, createdAt: Date(timeIntervalSince1970: 0))
            try user.insert(db)
            let overview = try SharingOverview.load(actor: try AccessActor.load(appUserId: user.id!, db: db), db: db)
            XCTAssertFalse(overview.isAdmin)
            XCTAssertFalse(overview.canSetOwners)
            XCTAssertEqual(overview.own, [])
            XCTAssertEqual(overview.joint.map(\.displayName), [DemoSharing.jointAccount])
            XCTAssertEqual(overview.otherName, DemoSharing.adminDisplayName)
        }
    }

    func testBeforeTheSheetOnlyTheAdminCanSetOwners() throws {
        let queue = try TestDatabase.demo()
        try queue.write { db in
            try db.execute(sql: "UPDATE personSharing SET ownershipConfirmedAt = NULL")
            let overview = try SharingOverview.load(actor: try AccessActor.admin(db: db), db: db)
            XCTAssertFalse(overview.isConfirmed)
            XCTAssertTrue(overview.canSetOwners)
            XCTAssertEqual(overview.own, [], "levels wait for the sheet")
            XCTAssertEqual(overview.joint, [])
        }
    }

    func testPreviewCountsTheMovesAndNamesWhatBlocksHidden() throws {
        let queue = try TestDatabase.demo()
        try queue.write { db in
            let (_, _, accounts) = try ids(db)
            let euro = try XCTUnwrap(accounts["Euro Current"]?.id)
            let hidden = try SharingOverview.preview(accountId: euro, to: .hidden, db: db)
            XCTAssertTrue(hidden.isBlocked)
            XCTAssertTrue(hidden.blockers.contains(.propertyLink(propertyName: DemoDatabase.propertyName)))
            XCTAssertEqual(hidden.affectedCount, 0)

            let lowering = try SharingOverview.preview(accountId: euro, to: .balanceOnly, db: db)
            XCTAssertEqual(lowering.from, .everything)
            XCTAssertTrue(lowering.isLowering)
            XCTAssertFalse(lowering.isBlocked)
            XCTAssertGreaterThan(lowering.affectedCount, 10)
            XCTAssertEqual(lowering.affectedCount, try SharingLevels.affectedCount(accountId: euro, to: .balanceOnly, db: db))

            let card = try XCTUnwrap(accounts[DemoSharing.categoryTotalsAccount]?.id)
            let raising = try SharingOverview.preview(accountId: card, to: .everything, db: db)
            XCTAssertFalse(raising.isLowering)
            XCTAssertGreaterThan(raising.affectedCount, 0)
        }
    }

    func testTheViewersAccountRules() throws {
        let queue = try TestDatabase.demo()
        try queue.write { db in
            let (a, b, accounts) = try ids(db)
            let card = try XCTUnwrap(accounts[DemoSharing.categoryTotalsAccount])
            let joint = try XCTUnwrap(accounts[DemoSharing.jointAccount])
            let euro = try XCTUnwrap(accounts["Euro Current"])
            let owner = SharingViewer(personId: a), member = SharingViewer(personId: b), anyone = SharingViewer(personId: nil)
            // The lock badge: the owner's own accounts below Everything only.
            XCTAssertEqual(owner.badgeLevel(card), .categoryTotals)
            XCTAssertNil(owner.badgeLevel(joint))
            XCTAssertNil(owner.badgeLevel(euro))
            XCTAssertNil(member.badgeLevel(card), "not hers")
            XCTAssertNil(anyone.badgeLevel(card))

            // Hidden: absent for the other person, there for its owner.
            try db.execute(sql: "UPDATE account SET sharingLevel = 'hidden' WHERE id = ?", arguments: [card.id!])
            let hiddenCard = try XCTUnwrap(try Account.fetchOne(db, key: card.id!))
            XCTAssertTrue(owner.shows(hiddenCard))
            XCTAssertFalse(member.shows(hiddenCard))
            XCTAssertTrue(member.shows(euro))
            let today = DemoDatabase.defaultAsOf
            XCTAssertFalse(try SharedActualsSource(viewer: member, today: today).accounts(db).contains { $0.id == card.id })
            XCTAssertEqual(try SharedActualsSource(viewer: owner, today: today).accounts(db).count, accounts.count)
            XCTAssertFalse(try DashboardInput.load(db: db, today: today, actuals: SharedActualsSource(viewer: member, today: today))
                .accounts.contains { $0.id == card.id })

            // Net worth's note: only for a viewer who sees some account partly or not at all.
            let all = try Account.fetchAll(db)
            XCTAssertTrue(member.seesOnlyPart(of: all))
            XCTAssertFalse(owner.seesOnlyPart(of: all))
            XCTAssertFalse(anyone.seesOnlyPart(of: all))
        }
    }
}
