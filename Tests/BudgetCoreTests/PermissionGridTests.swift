import XCTest
import GRDB
@testable import BudgetCore
import TestSupport

/// Step 7b task 1: the admin's grid of a member's levels per area (spec §2.1): defaults shown without writing, saved
/// by the admin only, one write per changed area, and never deleting anything.
final class PermissionGridTests: XCTestCase {
    private static let day = Date(timeIntervalSince1970: 1_790_000_000)

    private struct Household {
        var personA: Int64
        var personB: Int64
        var admin: AccessActor
        var member: AccessActor
    }

    /// Person A is the admin, Person B the member. `people` false: the people already exist (the demo).
    private func household(_ db: Database, people: Bool = true) throws -> Household {
        if people {
            try db.execute(sql: "INSERT INTO person(name) VALUES ('Person A'), ('Person B')")
        }
        let personA = try XCTUnwrap(try Int64.fetchOne(db, sql: "SELECT id FROM person WHERE name = 'Person A'"))
        let personB = try XCTUnwrap(try Int64.fetchOne(db, sql: "SELECT id FROM person WHERE name = 'Person B'"))
        if try AppUser.filter(Column("isAdmin") == true).fetchCount(db) == 0 {
            var admin = AppUser(personId: personA, displayName: "A", isAdmin: true, createdAt: Self.day)
            try admin.insert(db)
        }
        var member = AppUser(personId: personB, displayName: "B", isAdmin: false, createdAt: Self.day)
        try member.insert(db)
        return Household(personA: personA, personB: personB, admin: try AccessActor.admin(db: db),
                         member: try AccessActor.load(appUserId: member.id!, db: db))
    }

    private func permissionCount(_ db: Database) throws -> Int { try MemberPermission.fetchCount(db) }

    private func pendingPermissionWrites(_ db: Database) throws -> Int {
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM syncPending WHERE tableName = 'memberPermission'") ?? 0
    }

    private func setting(_ grid: PermissionGrid, _ area: AccessArea, _ level: PermissionLevel) -> PermissionGrid {
        var grid = grid
        let index = grid.rows.firstIndex { $0.area == area }!
        grid.rows[index].level = level
        return grid
    }

    func testRowsAreFixedAreasPlusOneTaxRowPerPerson() throws {
        let queue = try TestDatabase.migrated()
        try queue.write { db in
            let h = try household(db)
            let grid = try PermissionGrid.load(db: db, appUserId: h.member.appUserId)
            XCTAssertEqual(grid.appUserId, h.member.appUserId)
            XCTAssertEqual(grid.memberName, "Person B")
            XCTAssertEqual(grid.rows.map(\.title), AccessArea.fixedAreas.map(\.title) + ["Tax — Person A", "Tax — Person B"])
            XCTAssertEqual(grid.rows.suffix(2).map(\.area), [try AccessArea.tax(ofPerson: h.personA, db: db),
                                                            try AccessArea.tax(ofPerson: h.personB, db: db)])
            XCTAssertEqual(grid.rows.map(\.id), grid.rows.map(\.area.storageKey))
        }
    }

    func testLoadShowsDefaultsWithoutWriting() throws {
        let queue = try TestDatabase.migrated()
        try queue.write { db in
            let h = try household(db)
            let before = try permissionCount(db)
            let grid = try PermissionGrid.load(db: db, appUserId: h.member.appUserId)
            for row in grid.rows {
                XCTAssertEqual(row.level, MemberPermissions.defaultLevel(row.area, isAdmin: false), row.id)
            }
            XCTAssertEqual(try permissionCount(db), before)
        }
    }

    func testStoredLevelWinsOverDefault() throws {
        let queue = try TestDatabase.migrated()
        try queue.write { db in
            let h = try household(db)
            var row = MemberPermission(appUserId: h.member.appUserId, area: AccessArea.forecast.storageKey, level: .none)
            try row.insert(db)
            let grid = try PermissionGrid.load(db: db, appUserId: h.member.appUserId)
            XCTAssertEqual(grid.rows.first { $0.area == .forecast }?.level, PermissionLevel.none)
            XCTAssertEqual(grid.rows.first { $0.area == .property }?.level, .edit)
        }
    }

    func testAdminHasNoGrid() throws {
        let queue = try TestDatabase.migrated()
        try queue.write { db in
            let h = try household(db)
            XCTAssertThrowsError(try PermissionGrid.load(db: db, appUserId: h.admin.appUserId)) { error in
                XCTAssertEqual(error as? PermissionGridError, .notAMember)
            }
            XCTAssertThrowsError(try PermissionGrid.load(db: db, appUserId: 999_999)) { error in
                XCTAssertEqual(error as? PermissionGridError, .notAMember)
            }
        }
    }

    func testHouseholdSettingsOffersNoneAndViewOnly() throws {
        let queue = try TestDatabase.migrated()
        try queue.write { db in
            let h = try household(db)
            let grid = try PermissionGrid.load(db: db, appUserId: h.member.appUserId)
            for row in grid.rows {
                XCTAssertEqual(row.choices, row.area == .householdSettings ? [.none, .view] : [.none, .view, .edit], row.id)
            }
        }
    }

    func testSaveWritesOnlyChangedRowsAsTheAdmin() throws {
        let queue = try TestDatabase.migrated()
        try queue.write { db in
            let h = try household(db)
            let original = try PermissionGrid.load(db: db, appUserId: h.member.appUserId)
            let edited = setting(original, .forecast, .edit)
            XCTAssertEqual(edited.differences(from: original), [.forecast])
            try db.execute(sql: "DELETE FROM syncPending")
            try PermissionGrid.save(edited, actor: h.admin, db: db)
            XCTAssertEqual(try pendingPermissionWrites(db), 1)
            XCTAssertEqual(try permissionCount(db), 1)
            let stored = try XCTUnwrap(try MemberPermission.fetchOne(db))
            XCTAssertEqual(stored.area, AccessArea.forecast.storageKey)
            XCTAssertEqual(stored.level, .edit)
            let stamp = try XCTUnwrap(try Row.fetchOne(db, sql: "SELECT modifiedBy FROM syncRecord WHERE tableName = 'memberPermission' AND localId = ?",
                                                       arguments: [stored.id]))
            XCTAssertEqual(stamp["modifiedBy"] as String?, h.admin.appUserUuid)
            XCTAssertTrue(try AccessPolicy.can(h.member, .edit, .forecast, db: db))

            // Saving the same grid again writes nothing; back to the default writes the default (rows are never deleted).
            try db.execute(sql: "DELETE FROM syncPending")
            try PermissionGrid.save(try PermissionGrid.load(db: db, appUserId: h.member.appUserId), actor: h.admin, db: db)
            XCTAssertEqual(try pendingPermissionWrites(db), 0)
            try PermissionGrid.save(setting(edited, .forecast, .view), actor: h.admin, db: db)
            XCTAssertEqual(try pendingPermissionWrites(db), 1)
            XCTAssertEqual(try MemberPermission.fetchOne(db)?.level, .view)
            XCTAssertEqual(try permissionCount(db), 1)
        }
    }

    func testSaveByAMemberDenied() throws {
        let queue = try TestDatabase.migrated()
        try queue.write { db in
            let h = try household(db)
            let grid = setting(try PermissionGrid.load(db: db, appUserId: h.member.appUserId), .budgetAndAccounts, .edit)
            XCTAssertThrowsError(try PermissionGrid.save(grid, actor: h.member, db: db)) { error in
                XCTAssertEqual(error as? AccessDenied, AccessDenied(area: .householdSettings))
            }
            XCTAssertEqual(try permissionCount(db), 0)
        }
    }

    func testResetToDefaultsIsNotSavedUntilSave() throws {
        let queue = try TestDatabase.migrated()
        try queue.write { db in
            let h = try household(db)
            let loaded = try PermissionGrid.load(db: db, appUserId: h.member.appUserId)
            try PermissionGrid.save(setting(setting(loaded, .forecast, .none), .property, .view), actor: h.admin, db: db)
            let changed = try PermissionGrid.load(db: db, appUserId: h.member.appUserId)
            let reset = changed.resetToDefaults()
            for row in reset.rows {
                XCTAssertEqual(row.level, MemberPermissions.defaultLevel(row.area, isAdmin: false), row.id)
            }
            XCTAssertEqual(Set(reset.differences(from: changed)), [.forecast, .property])
            XCTAssertEqual(try PermissionGrid.load(db: db, appUserId: h.member.appUserId), changed, "not saved yet")
            try PermissionGrid.save(reset, actor: h.admin, db: db)
            XCTAssertEqual(try PermissionGrid.load(db: db, appUserId: h.member.appUserId), reset)
        }
    }

    func testLoweringALevelNeverDeletesData() throws {
        let queue = try TestDatabase.demo()
        try queue.write { db in
            let h = try household(db, people: false)
            let tables = ["utilityInvoice", "rechargeStatement", "transaction_", "property", "document"]
            func counts() throws -> [Int] {
                try tables.map { try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \($0)") ?? 0 }
            }
            let before = try counts()
            XCTAssertTrue(before[0] > 0 && before[1] > 0 && before[2] > 0, "the demo has property data")
            let grid = try PermissionGrid.load(db: db, appUserId: h.member.appUserId)
            try PermissionGrid.save(setting(grid, .property, .none), actor: h.admin, db: db)
            XCTAssertEqual(try counts(), before)
            XCTAssertFalse(try AccessPolicy.can(h.member, .edit, .property, db: db))
            XCTAssertFalse(try AccessPolicy.can(h.member, .view, .property, db: db))
        }
    }

    func testNewPersonGetsDefaultInGrid() throws {
        let queue = try TestDatabase.migrated()
        try queue.write { db in
            let h = try household(db)
            try MemberPermissions.ensureDefaults(appUserId: h.member.appUserId, db: db)
            try db.execute(sql: "INSERT INTO person(name) VALUES ('Person C')")
            let personC = db.lastInsertedRowID
            let grid = try PermissionGrid.load(db: db, appUserId: h.member.appUserId)
            let row = try XCTUnwrap(grid.rows.last)
            XCTAssertEqual(row.title, "Tax — Person C")
            XCTAssertEqual(row.area, try AccessArea.tax(ofPerson: personC, db: db))
            XCTAssertEqual(row.level, .view)
        }
    }

    func testGridCopy() {
        XCTAssertEqual(HouseholdCopy.gridTitle("Person B"), "What Person B can do")
        XCTAssertEqual([PermissionLevel.none, .view, .edit].map(HouseholdCopy.gridLevel), ["None", "View", "Edit"])
        XCTAssertEqual(HouseholdCopy.gridResetButton, "Reset to defaults")
        XCTAssertEqual(HouseholdCopy.gridLowerNote("Person B"),
                       "Lowering a level never removes anything. It limits what Person B can change and see from then on.")
    }
}
