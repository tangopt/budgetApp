import Foundation
import GRDB

public enum AppUserStoreError: Error, Equatable, Sendable {
    case notAdmin
    /// The change would leave no admin who can sign in on this Mac.
    case lastAdmin
    case cannotRemoveSelf
    /// Fewer than `AppUserStore.minimumPasswordLength` characters.
    case passwordTooShort
    case personAlreadyHasUser
    /// The user has no password on this Mac (a user synced from another device).
    case noCredential
}

/// Everything that creates, checks or changes app users and their local credentials. The "at least one
/// admin with a credential" rule is enforced here and nowhere else.
public enum AppUserStore {
    public static let minimumPasswordLength = 10

    // MARK: Reading

    /// True once someone has a password on this Mac. A migrated database with no app users is "not set up".
    public static func isSetUp(_ db: Database) throws -> Bool {
        try LocalCredential.fetchCount(db) > 0
    }

    public static func appUsers(_ db: Database) throws -> [AppUser] {
        try AppUser.order(Column("displayName"), Column("id")).fetchAll(db)
    }

    /// Users who can sign in on this Mac (they have a credential): admins first, then by name.
    public static func signInCandidates(_ db: Database) throws -> [AppUser] {
        try AppUser.fetchAll(db, sql: """
            SELECT appUser.* FROM appUser
            JOIN localCredential ON localCredential.appUserId = appUser.id
            ORDER BY appUser.isAdmin DESC, appUser.displayName COLLATE NOCASE, appUser.id
            """)
    }

    public static func unclaimedPeople(_ db: Database) throws -> [Person] {
        try Person.fetchAll(db, sql: """
            SELECT * FROM person WHERE id NOT IN (SELECT personId FROM appUser) ORDER BY name COLLATE NOCASE
            """)
    }

    // MARK: Creating

    /// Writes the user and its credential together. `rounds` is for tests; the app uses today's.
    public static func create(_ db: Database, personId: Int64, displayName: String, password: String, isAdmin: Bool,
                              now: Date, rounds: Int = PasswordHasher.currentRounds) throws -> (AppUser, recoveryKey: String) {
        try requireValid(password)
        guard try AppUser.filter(Column("personId") == personId).fetchCount(db) == 0 else {
            throw AppUserStoreError.personAlreadyHasUser
        }
        let recoveryKey = RecoveryKey.generate()
        let passwordHash = PasswordHasher.hash(password, rounds: rounds)
        let recoveryKeyHash = PasswordHasher.hash(recoveryKey, rounds: rounds)
        var user = AppUser(personId: personId, displayName: displayName, isAdmin: isAdmin, createdAt: now)
        try db.inSavepoint {
            try user.insert(db)
            try LocalCredential(appUserId: user.id!, passwordHash: passwordHash, recoveryKeyHash: recoveryKeyHash).insert(db)
            return .commit
        }
        return (user, recoveryKey)
    }

    // MARK: Checking

    /// Also upgrades a hash made with fewer rounds than today's. A failed upgrade (a read-only connection)
    /// never fails the sign-in.
    public static func verifyPassword(_ db: Database, appUserId: Int64, password: String) throws -> Bool {
        guard var credential = try LocalCredential.fetchOne(db, key: appUserId),
              PasswordHasher.verify(password, against: credential.passwordHash) else { return false }
        if PasswordHasher.needsRehash(credential.passwordHash) {
            credential.passwordHash = PasswordHasher.hash(password)
            try? credential.update(db)
        }
        return true
    }

    public static func verifyRecoveryKey(_ db: Database, appUserId: Int64, key: String) throws -> Bool {
        guard let normalised = RecoveryKey.normalised(key),
              let credential = try LocalCredential.fetchOne(db, key: appUserId) else { return false }
        return PasswordHasher.verify(normalised, against: credential.recoveryKeyHash)
    }

    public static func recordSignIn(_ db: Database, appUserId: Int64, now: Date) throws {
        try db.execute(sql: "UPDATE appUser SET lastSignInAt = ? WHERE id = ?", arguments: [now, appUserId])
    }

    // MARK: Changing

    /// The caller has already proved who they are (old password, Touch ID or recovery key).
    public static func changePassword(_ db: Database, appUserId: Int64, newPassword: String,
                                      rounds: Int = PasswordHasher.currentRounds) throws {
        try requireValid(newPassword)
        guard var credential = try LocalCredential.fetchOne(db, key: appUserId) else { throw AppUserStoreError.noCredential }
        credential.passwordHash = PasswordHasher.hash(newPassword, rounds: rounds)
        try credential.update(db)
    }

    public static func resetPassword(_ db: Database, of appUserId: Int64, by actorId: Int64, newPassword: String,
                                     rounds: Int = PasswordHasher.currentRounds) throws {
        try requireAdmin(db, actorId)
        try changePassword(db, appUserId: appUserId, newPassword: newPassword, rounds: rounds)
    }

    /// Invalidates the old key.
    public static func regenerateRecoveryKey(_ db: Database, appUserId: Int64,
                                             rounds: Int = PasswordHasher.currentRounds) throws -> String {
        guard var credential = try LocalCredential.fetchOne(db, key: appUserId) else { throw AppUserStoreError.noCredential }
        let key = RecoveryKey.generate()
        credential.recoveryKeyHash = PasswordHasher.hash(key, rounds: rounds)
        try credential.update(db)
        return key
    }

    public static func remove(_ db: Database, _ appUserId: Int64, by actorId: Int64) throws {
        try requireAdmin(db, actorId)
        guard appUserId != actorId else { throw AppUserStoreError.cannotRemoveSelf }
        guard try AppUser.fetchOne(db, key: appUserId) != nil else { return }
        guard try otherAdminsWithCredential(db, besides: appUserId) > 0 || !isAdminWithCredential(db, appUserId) else {
            throw AppUserStoreError.lastAdmin
        }
        try db.inSavepoint {
            try db.execute(sql: "DELETE FROM localCredential WHERE appUserId = ?", arguments: [appUserId])
            try db.execute(sql: "DELETE FROM appUser WHERE id = ?", arguments: [appUserId])
            return .commit
        }
    }

    public static func setAdmin(_ db: Database, _ appUserId: Int64, _ isAdmin: Bool, by actorId: Int64) throws {
        try requireAdmin(db, actorId)
        guard try AppUser.fetchOne(db, key: appUserId) != nil else { return }
        if !isAdmin, try isAdminWithCredential(db, appUserId), try otherAdminsWithCredential(db, besides: appUserId) == 0 {
            throw AppUserStoreError.lastAdmin
        }
        try db.execute(sql: "UPDATE appUser SET isAdmin = ? WHERE id = ?", arguments: [isAdmin, appUserId])
    }

    // MARK: Rules

    private static func requireValid(_ password: String) throws {
        guard password.count >= minimumPasswordLength else { throw AppUserStoreError.passwordTooShort }
    }

    private static func requireAdmin(_ db: Database, _ appUserId: Int64) throws {
        guard try AppUser.fetchOne(db, key: appUserId)?.isAdmin == true else { throw AppUserStoreError.notAdmin }
    }

    private static func isAdminWithCredential(_ db: Database, _ appUserId: Int64) throws -> Bool {
        try Bool.fetchOne(db, sql: """
            SELECT EXISTS (SELECT 1 FROM appUser JOIN localCredential ON appUserId = id WHERE id = ? AND isAdmin)
            """, arguments: [appUserId]) ?? false
    }

    private static func otherAdminsWithCredential(_ db: Database, besides appUserId: Int64) throws -> Int {
        try Int.fetchOne(db, sql: """
            SELECT COUNT(*) FROM appUser JOIN localCredential ON appUserId = id WHERE isAdmin AND id <> ?
            """, arguments: [appUserId]) ?? 0
    }
}
