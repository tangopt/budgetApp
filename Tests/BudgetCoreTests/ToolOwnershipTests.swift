import XCTest
import GRDB
@testable import BudgetCore
import TestSupport

/// Step 7a Task 6: the one-off import tools create their accounts owned by the household's admin once ownership is
/// confirmed (F-2), and removing a person who owns accounts is refused with copy (F-5). Synthetic data only.
private enum OwnershipWorld {
    /// Admin "Person A" and member "Person B", ownership confirmed through the defaults (existing accounts go to A).
    static func confirm(_ db: Database) throws -> AccessActor {
        try db.execute(sql: "INSERT INTO person(name) VALUES ('Synthetic Person A')")
        let personA = db.lastInsertedRowID
        var user = AppUser(personId: personA, displayName: "Person A", isAdmin: true, createdAt: Date(timeIntervalSince1970: 1_790_000_000))
        try user.insert(db)
        let admin = try AccessActor.load(appUserId: user.id!, db: db)
        try SharingSetup.confirmDefaults(admin: admin, db: db, now: Date(timeIntervalSince1970: 1_790_000_000))
        return admin
    }

    static func createdAccounts(_ db: Database, named names: [String]) throws -> [Account] {
        try names.map { name in try XCTUnwrap(try Account.filter(Column("name") == name).fetchOne(db), name) }
    }
}

extension BBVAHistoryImportTests {
    func testHistoryImportOwnsAccountsByGivenOwner() throws {
        let m = try makeDB()
        try m.dbQueue.write { db in
            let admin = try OwnershipWorld.confirm(db)
            _ = try BBVAHistoryImport.apply(db: db, input: try input(), owner: admin)
            let created = try OwnershipWorld.createdAccounts(db, named: ["BBVA", BBVAHistoryImport.depositAccountName])
            for account in created {
                XCTAssertEqual(account.ownerPersonId, admin.personId, "\(account.name) is the admin's")
                XCTAssertEqual(account.sharingLevel, .balanceOnly, "at the default level")
            }
        }
    }

    func testNilOwnerKeepsJointEverything() throws {
        let m = try makeDB()
        try m.dbQueue.write { db in
            XCTAssertFalse(try SharingSetup.isConfirmed(db: db))
            _ = try BBVAHistoryImport.apply(db: db, input: try input(), owner: nil)
            for account in try OwnershipWorld.createdAccounts(db, named: ["BBVA", BBVAHistoryImport.depositAccountName]) {
                XCTAssertNil(account.ownerPersonId, account.name)
                XCTAssertEqual(account.sharingLevel, .everything, account.name)
            }
        }
        // The default parameter is the same: joint at Everything.
        let other = try makeDB()
        try other.dbQueue.write { db in
            _ = try BBVAHistoryImport.apply(db: db, input: try input())
            XCTAssertNil(try OwnershipWorld.createdAccounts(db, named: ["BBVA"])[0].ownerPersonId)
        }
    }
}

extension BBVAFundMortgageImportTests {
    func testFundMortgageImportOwnsAccountsByGivenOwner() throws {
        let m = try makeDB()
        try m.dbQueue.write { db in
            let admin = try OwnershipWorld.confirm(db)
            _ = try BBVAFundMortgageImport.apply(db: db, input: input(), owner: admin)
            let created = try OwnershipWorld.createdAccounts(db, named: [BBVAFundMortgageImport.fundAccountName, BBVAFundMortgageImport.loanAccountName])
            for account in created {
                XCTAssertEqual(account.ownerPersonId, admin.personId, "\(account.name) is the admin's")
                XCTAssertEqual(account.sharingLevel, .balanceOnly)
            }
        }
    }
}

final class PersonRemovalTests: XCTestCase {
    private func makeWorld(owning count: Int) throws -> (DatabaseManager, Int64) {
        let m = try TestDatabase.migratedManager()
        let personB = try m.dbQueue.write { db -> Int64 in
            _ = try OwnershipWorld.confirm(db)
            try db.execute(sql: "INSERT INTO person(name) VALUES ('Synthetic Person B')")
            let b = db.lastInsertedRowID
            for index in 0..<count {
                let account = try AccountEditing.add(db: db, name: "Synthetic B \(index)", currency: .gbp, kind: .cash, openingBalanceEntered: nil,
                                                     asOf: Date(timeIntervalSince1970: 1_790_000_000))
                try db.execute(sql: "UPDATE account SET ownerPersonId = ? WHERE id = ?", arguments: [b, account.id!])
            }
            return b
        }
        return (m, personB)
    }

    func testDeletingPersonWhoOwnsAccountsIsRefused() throws {
        let (m, personB) = try makeWorld(owning: 2)
        try m.dbQueue.write { db in
            XCTAssertThrowsError(try People.delete(db: db, id: personB)) { error in
                XCTAssertEqual(error as? PropertyError, .personOwnsAccounts(count: 2))
            }
            XCTAssertNotNil(try Person.fetchOne(db, key: personB), "still there")
        }
        // Without accounts the removal goes through.
        let (free, freeB) = try makeWorld(owning: 0)
        try free.dbQueue.write { db in XCTAssertTrue(try People.delete(db: db, id: freeB)) }
    }

    func testRefusalCopyCountsAccounts() {
        XCTAssertEqual(PropertyError.personOwnsAccounts(count: 1).message, "That person owns 1 account, so they can't be removed.")
        XCTAssertEqual(PropertyError.personOwnsAccounts(count: 3).message, "That person owns 3 accounts, so they can't be removed.")
    }
}

final class ToolOwnershipPromptTests: XCTestCase {
    func testPromptNamesTheAdminAndOnlyYesProceeds() throws {
        let m = try TestDatabase.migratedManager()
        try m.dbQueue.write { db in
            XCTAssertNil(try ToolOwnership.question(db: db), "nothing to confirm before ownership is")
            _ = try OwnershipWorld.confirm(db)
            XCTAssertEqual(try ToolOwnership.question(db: db)?.prompt, "Accounts this tool creates will be owned by Person A. Continue? [y/N] ")
        }
        XCTAssertTrue(ToolOwnership.isYes("y\n"))
        XCTAssertTrue(ToolOwnership.isYes("Y"))
        for answer in [nil, "", "n", "yes", "N"] { XCTAssertFalse(ToolOwnership.isYes(answer), answer ?? "nil") }
        XCTAssertEqual(ToolOwnership.declined, "Nothing imported.")
    }
}
