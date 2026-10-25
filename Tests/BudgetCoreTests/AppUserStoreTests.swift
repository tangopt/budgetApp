import XCTest
import GRDB
@testable import BudgetCore
import TestSupport

final class AppUserStoreTests: XCTestCase {
    private var manager: DatabaseManager!
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    /// Low rounds keep the tests fast; the one test about rounds says so.
    private let fast = 1_000

    override func setUpWithError() throws {
        manager = try TestDatabase.migratedManager()
    }

    private func person(_ db: Database, _ name: String) throws -> Int64 {
        var person = Person(name: name)
        try person.insert(db)
        return person.id!
    }

    @discardableResult
    private func make(_ db: Database, _ name: String, admin: Bool, password: String = "synthetic pass 1") throws -> (user: AppUser, key: String) {
        let created = try AppUserStore.create(db, personId: person(db, name), displayName: name, password: password,
                                              isAdmin: admin, now: now, rounds: fast)
        return (created.0, created.recoveryKey)
    }

    func testCreateWritesUserAndCredentialTogether() throws {
        try manager.dbQueue.write { db in
            let (user, key) = try make(db, "Alex", admin: true)
            XCTAssertEqual(try AppUserStore.appUsers(db).count, 1)
            XCTAssertNotNil(try LocalCredential.fetchOne(db, key: user.id!))
            XCTAssertEqual(key.count, 24)
            XCTAssertTrue(try AppUserStore.isSetUp(db))
        }
        // A failure while writing the credential leaves neither row.
        try manager.dbQueue.write { db in
            try db.execute(sql: """
                CREATE TRIGGER failCredential BEFORE INSERT ON localCredential
                BEGIN SELECT RAISE(ABORT, 'boom'); END
                """)
            let personId = try person(db, "Sam")
            XCTAssertThrowsError(try AppUserStore.create(db, personId: personId, displayName: "Sam",
                                                         password: "synthetic pass 1", isAdmin: false, now: now, rounds: fast))
            XCTAssertEqual(try AppUser.filter(Column("personId") == personId).fetchCount(db), 0)
            XCTAssertEqual(try AppUserStore.appUsers(db).count, 1)
        }
    }

    func testShortPasswordRejected() throws {
        try manager.dbQueue.write { db in
            let personId = try person(db, "Alex")
            XCTAssertThrowsError(try AppUserStore.create(db, personId: personId, displayName: "Alex", password: "123456789",
                                                         isAdmin: true, now: now, rounds: fast)) {
                XCTAssertEqual($0 as? AppUserStoreError, .passwordTooShort)
            }
            XCTAssertEqual(try AppUserStore.appUsers(db).count, 0)
            XCTAssertNoThrow(try AppUserStore.create(db, personId: personId, displayName: "Alex", password: "1234567890",
                                                     isAdmin: true, now: now, rounds: fast))
        }
    }

    func testOnePersonOneUser() throws {
        try manager.dbQueue.write { db in
            let first = try make(db, "Alex", admin: true).user
            XCTAssertThrowsError(try AppUserStore.create(db, personId: first.personId, displayName: "Again",
                                                         password: "synthetic pass 1", isAdmin: false, now: now, rounds: fast)) {
                XCTAssertEqual($0 as? AppUserStoreError, .personAlreadyHasUser)
            }
            let other = try person(db, "Sam")
            XCTAssertEqual(try AppUserStore.unclaimedPeople(db).map(\.id), [other])
        }
    }

    func testUserWithoutCredentialCannotSignIn() throws {
        try manager.dbQueue.write { db in
            let admin = try make(db, "Alex", admin: true).user
            var ghost = AppUser(personId: try person(db, "Sam"), displayName: "Sam", createdAt: now)
            try ghost.insert(db)
            XCTAssertEqual(try AppUserStore.appUsers(db).count, 2)
            XCTAssertEqual(try AppUserStore.signInCandidates(db).map(\.id), [admin.id])
            XCTAssertFalse(try AppUserStore.verifyPassword(db, appUserId: ghost.id!, password: "synthetic pass 1"))
            XCTAssertFalse(try AppUserStore.verifyRecoveryKey(db, appUserId: ghost.id!, key: RecoveryKey.generate()))
        }
    }

    func testSignInCandidatesAdminFirstThenByName() throws {
        try manager.dbQueue.write { db in
            try make(db, "Mo", admin: true)
            try make(db, "Zed", admin: false)
            try make(db, "Bea", admin: false)
            XCTAssertEqual(try AppUserStore.signInCandidates(db).map(\.displayName), ["Mo", "Bea", "Zed"])
        }
    }

    func testVerifyPassword() throws {
        try manager.dbQueue.write { db in
            let user = try make(db, "Alex", admin: true).user
            XCTAssertTrue(try AppUserStore.verifyPassword(db, appUserId: user.id!, password: "synthetic pass 1"))
            XCTAssertFalse(try AppUserStore.verifyPassword(db, appUserId: user.id!, password: "synthetic pass 2"))
        }
    }

    func testResetNeedsAdmin() throws {
        try manager.dbQueue.write { db in
            let admin = try make(db, "Alex", admin: true).user
            let member = try make(db, "Sam", admin: false).user
            XCTAssertThrowsError(try AppUserStore.resetPassword(db, of: admin.id!, by: member.id!,
                                                                newPassword: "another synthetic 1", rounds: fast)) {
                XCTAssertEqual($0 as? AppUserStoreError, .notAdmin)
            }
            XCTAssertTrue(try AppUserStore.verifyPassword(db, appUserId: admin.id!, password: "synthetic pass 1"))
            try AppUserStore.resetPassword(db, of: member.id!, by: admin.id!, newPassword: "another synthetic 1", rounds: fast)
            XCTAssertTrue(try AppUserStore.verifyPassword(db, appUserId: member.id!, password: "another synthetic 1"))
            XCTAssertThrowsError(try AppUserStore.resetPassword(db, of: member.id!, by: admin.id!, newPassword: "short", rounds: fast)) {
                XCTAssertEqual($0 as? AppUserStoreError, .passwordTooShort)
            }
        }
    }

    func testCannotRemoveLastAdmin() throws {
        try manager.dbQueue.write { db in
            let admin = try make(db, "Alex", admin: true).user
            let member = try make(db, "Sam", admin: false).user
            XCTAssertThrowsError(try AppUserStore.remove(db, admin.id!, by: admin.id!)) {
                XCTAssertEqual($0 as? AppUserStoreError, .cannotRemoveSelf)
            }
            XCTAssertThrowsError(try AppUserStore.remove(db, admin.id!, by: member.id!)) {
                XCTAssertEqual($0 as? AppUserStoreError, .notAdmin)
            }
            // A second admin without a credential does not count.
            var ghost = AppUser(personId: try person(db, "Kit"), displayName: "Kit", isAdmin: true, createdAt: now)
            try ghost.insert(db)
            // Removing an admin who has no credential here is fine: the invariant counts admins who can sign in.
            XCTAssertNoThrow(try AppUserStore.remove(db, ghost.id!, by: admin.id!))
        }
    }

    func testCannotRemoveLastAdminWithCredential() throws {
        try manager.dbQueue.write { db in
            let admin = try make(db, "Alex", admin: true).user
            var ghost = AppUser(personId: try person(db, "Kit"), displayName: "Kit", isAdmin: true, createdAt: now)
            try ghost.insert(db)
            let second = try make(db, "Sam", admin: true).user
            try AppUserStore.remove(db, second.id!, by: admin.id!)
            XCTAssertEqual(try AppUserStore.appUsers(db).map(\.id).contains(second.id), false)
            // Alex is now the only admin with a credential, so even another admin can't remove them.
            XCTAssertThrowsError(try AppUserStore.remove(db, admin.id!, by: ghost.id!)) {
                XCTAssertEqual($0 as? AppUserStoreError, .lastAdmin)
            }
        }
    }

    func testCannotDemoteLastAdmin() throws {
        try manager.dbQueue.write { db in
            let admin = try make(db, "Alex", admin: true).user
            let member = try make(db, "Sam", admin: false).user
            XCTAssertThrowsError(try AppUserStore.setAdmin(db, admin.id!, false, by: admin.id!)) {
                XCTAssertEqual($0 as? AppUserStoreError, .lastAdmin)
            }
            XCTAssertThrowsError(try AppUserStore.setAdmin(db, member.id!, true, by: member.id!)) {
                XCTAssertEqual($0 as? AppUserStoreError, .notAdmin)
            }
            try AppUserStore.setAdmin(db, member.id!, true, by: admin.id!)
            try AppUserStore.setAdmin(db, admin.id!, false, by: admin.id!)
            XCTAssertFalse(try AppUser.fetchOne(db, key: admin.id!)!.isAdmin)
            XCTAssertThrowsError(try AppUserStore.setAdmin(db, member.id!, false, by: member.id!)) {
                XCTAssertEqual($0 as? AppUserStoreError, .lastAdmin)
            }
        }
    }

    func testRemoveDeletesUserAndCredential() throws {
        try manager.dbQueue.write { db in
            let admin = try make(db, "Alex", admin: true).user
            let member = try make(db, "Sam", admin: false).user
            try AppUserStore.remove(db, member.id!, by: admin.id!)
            XCTAssertNil(try AppUser.fetchOne(db, key: member.id!))
            XCTAssertNil(try LocalCredential.fetchOne(db, key: member.id!))
        }
    }

    func testRecoveryKeyResetsPasswordWithoutAnotherAdmin() throws {
        try manager.dbQueue.write { db in
            let (admin, key) = try make(db, "Alex", admin: true)
            XCTAssertTrue(try AppUserStore.verifyRecoveryKey(db, appUserId: admin.id!, key: RecoveryKey.formatted(key).lowercased()))
            XCTAssertFalse(try AppUserStore.verifyRecoveryKey(db, appUserId: admin.id!, key: RecoveryKey.generate()))
            XCTAssertFalse(try AppUserStore.verifyRecoveryKey(db, appUserId: admin.id!, key: "nonsense"))
            try AppUserStore.changePassword(db, appUserId: admin.id!, newPassword: "brand new synthetic", rounds: fast)
            XCTAssertTrue(try AppUserStore.verifyPassword(db, appUserId: admin.id!, password: "brand new synthetic"))
            XCTAssertFalse(try AppUserStore.verifyPassword(db, appUserId: admin.id!, password: "synthetic pass 1"))
            // The key still works afterwards.
            XCTAssertTrue(try AppUserStore.verifyRecoveryKey(db, appUserId: admin.id!, key: key))
        }
    }

    func testRegenerateInvalidatesOldKey() throws {
        try manager.dbQueue.write { db in
            let (admin, oldKey) = try make(db, "Alex", admin: true)
            let newKey = try AppUserStore.regenerateRecoveryKey(db, appUserId: admin.id!, rounds: fast)
            XCTAssertNotEqual(newKey, oldKey)
            XCTAssertFalse(try AppUserStore.verifyRecoveryKey(db, appUserId: admin.id!, key: oldKey))
            XCTAssertTrue(try AppUserStore.verifyRecoveryKey(db, appUserId: admin.id!, key: newKey))
            XCTAssertTrue(try AppUserStore.verifyPassword(db, appUserId: admin.id!, password: "synthetic pass 1"))
        }
    }

    func testChangeAndRegenerateNeedCredential() throws {
        try manager.dbQueue.write { db in
            var ghost = AppUser(personId: try person(db, "Sam"), displayName: "Sam", createdAt: now)
            try ghost.insert(db)
            XCTAssertThrowsError(try AppUserStore.changePassword(db, appUserId: ghost.id!, newPassword: "synthetic pass 1", rounds: fast)) {
                XCTAssertEqual($0 as? AppUserStoreError, .noCredential)
            }
            XCTAssertThrowsError(try AppUserStore.regenerateRecoveryKey(db, appUserId: ghost.id!, rounds: fast)) {
                XCTAssertEqual($0 as? AppUserStoreError, .noCredential)
            }
        }
    }

    func testRehashOnVerifyWhenRoundsLow() throws {
        try manager.dbQueue.write { db in
            let user = try make(db, "Alex", admin: true).user
            var credential = try LocalCredential.fetchOne(db, key: user.id!)!
            credential.passwordHash = PasswordHasher.hash("synthetic pass 1", rounds: 1_000)
            try credential.update(db)
            XCTAssertTrue(try AppUserStore.verifyPassword(db, appUserId: user.id!, password: "synthetic pass 1"))
            let stored = try LocalCredential.fetchOne(db, key: user.id!)!.passwordHash
            XCTAssertTrue(stored.hasPrefix("pbkdf2-sha256$600000$"))
            XCTAssertTrue(PasswordHasher.verify("synthetic pass 1", against: stored))
            // A wrong password never rehashes.
            credential.passwordHash = PasswordHasher.hash("synthetic pass 1", rounds: 1_000)
            try credential.update(db)
            XCTAssertFalse(try AppUserStore.verifyPassword(db, appUserId: user.id!, password: "wrong wrong wrong"))
            XCTAssertTrue(try LocalCredential.fetchOne(db, key: user.id!)!.passwordHash.hasPrefix("pbkdf2-sha256$1000$"))
        }
    }

    func testRecordSignIn() throws {
        try manager.dbQueue.write { db in
            let user = try make(db, "Alex", admin: true).user
            let later = now.addingTimeInterval(60)
            try AppUserStore.recordSignIn(db, appUserId: user.id!, now: later)
            XCTAssertEqual(try AppUser.fetchOne(db, key: user.id!)?.lastSignInAt, later)
        }
    }

    func testFirstUserIsForcedAdmin() throws {
        try manager.dbQueue.write { db in
            let first = try make(db, "Alex", admin: false).user
            XCTAssertTrue(first.isAdmin)
            XCTAssertTrue(try AppUser.fetchOne(db, key: first.id!)!.isAdmin)
            // With an admin present, a non-admin stays one.
            XCTAssertFalse(try make(db, "Sam", admin: false).user.isAdmin)
        }
        // An admin who has no credential doesn't count.
        try manager.dbQueue.write { db in
            let other = try TestDatabase.migratedManager()
            try other.dbQueue.write { db2 in
                var ghost = AppUser(personId: try person(db2, "Kit"), displayName: "Kit", isAdmin: true, createdAt: now)
                try ghost.insert(db2)
                XCTAssertTrue(try make(db2, "Lee", admin: false).user.isAdmin)
            }
        }
    }

    func testCreateRejectsBlankNameAndUnknownPerson() throws {
        try manager.dbQueue.write { db in
            let personId = try person(db, "Alex")
            XCTAssertThrowsError(try AppUserStore.create(db, personId: personId, displayName: "  \n", password: "synthetic pass 1",
                                                         isAdmin: true, now: now, rounds: fast)) {
                XCTAssertEqual($0 as? AppUserStoreError, .emptyName)
            }
            XCTAssertThrowsError(try AppUserStore.create(db, personId: 9_999, displayName: "Ghost", password: "synthetic pass 1",
                                                         isAdmin: true, now: now, rounds: fast)) {
                XCTAssertEqual($0 as? AppUserStoreError, .unknownPerson)
            }
        }
    }

    func testMissingTargetThrowsNoSuchUser() throws {
        try manager.dbQueue.write { db in
            let admin = try make(db, "Alex", admin: true).user
            XCTAssertThrowsError(try AppUserStore.remove(db, 9_999, by: admin.id!)) {
                XCTAssertEqual($0 as? AppUserStoreError, .noSuchUser)
            }
            XCTAssertThrowsError(try AppUserStore.setAdmin(db, 9_999, true, by: admin.id!)) {
                XCTAssertEqual($0 as? AppUserStoreError, .noSuchUser)
            }
        }
    }

    func testDemoteWhenOtherAdminHasNoCredentialIsLastAdmin() throws {
        try manager.dbQueue.write { db in
            let admin = try make(db, "Alex", admin: true).user
            var ghost = AppUser(personId: try person(db, "Kit"), displayName: "Kit", isAdmin: true, createdAt: now)
            try ghost.insert(db)
            XCTAssertThrowsError(try AppUserStore.setAdmin(db, admin.id!, false, by: admin.id!)) {
                XCTAssertEqual($0 as? AppUserStoreError, .lastAdmin)
            }
        }
    }

    func testRemoveNullsImportRunAttribution() throws {
        try manager.dbQueue.write { db in
            let admin = try make(db, "Alex", admin: true).user
            let member = try make(db, "Sam", admin: false).user
            var run = ImportRun(confirmedAt: now, entryPoint: "test", summary: "s", appUserId: member.id)
            try run.insert(db)
            try AppUserStore.remove(db, member.id!, by: admin.id!)
            XCTAssertNil(try ImportRun.fetchOne(db, key: run.id!)!.appUserId)
        }
    }

    func testRehashLeavesRecoveryKeyHashAlone() throws {
        try manager.dbQueue.write { db in
            let (user, key) = try make(db, "Alex", admin: true)
            try db.execute(sql: "UPDATE localCredential SET passwordHash = ? WHERE appUserId = ?",
                           arguments: [PasswordHasher.hash("synthetic pass 1", rounds: 1_000), user.id!])
            let before = try LocalCredential.fetchOne(db, key: user.id!)!.recoveryKeyHash
            XCTAssertTrue(try AppUserStore.verifyPassword(db, appUserId: user.id!, password: "synthetic pass 1"))
            XCTAssertEqual(try LocalCredential.fetchOne(db, key: user.id!)!.recoveryKeyHash, before)
            XCTAssertTrue(try AppUserStore.verifyRecoveryKey(db, appUserId: user.id!, key: key))
        }
    }
}
