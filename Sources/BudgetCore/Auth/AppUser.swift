import Foundation
import GRDB

/// Someone who signs in to the app. One per `person`; created together with their `LocalCredential`
/// by the setup flow, never by the migration.
public struct AppUser: Codable, Equatable, Identifiable, FetchableRecord, MutablePersistableRecord, Sendable {
    public var id: Int64?
    public var personId: Int64
    /// Shown on the lock screen.
    public var displayName: String
    /// `CKContainer.userRecordID()`; nil until iCloud sync is on.
    public var cloudKitUserRecordName: String?
    public var isAdmin: Bool
    public var createdAt: Date
    /// Device-local meaning; not synced.
    public var lastSignInAt: Date?

    public init(id: Int64? = nil, personId: Int64, displayName: String, cloudKitUserRecordName: String? = nil,
                isAdmin: Bool = false, createdAt: Date, lastSignInAt: Date? = nil) {
        self.id = id
        self.personId = personId
        self.displayName = displayName
        self.cloudKitUserRecordName = cloudKitUserRecordName
        self.isAdmin = isAdmin
        self.createdAt = createdAt
        self.lastSignInAt = lastSignInAt
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }

    public static let databaseTableName = "appUser"
}

/// The password and recovery-key hashes of an app user on this Mac. Never synced, never leaves the Mac.
public struct LocalCredential: Codable, Equatable, FetchableRecord, PersistableRecord, Sendable {
    public var appUserId: Int64
    public var passwordHash: String
    public var recoveryKeyHash: String

    public init(appUserId: Int64, passwordHash: String, recoveryKeyHash: String) {
        self.appUserId = appUserId
        self.passwordHash = passwordHash
        self.recoveryKeyHash = recoveryKeyHash
    }

    public static let databaseTableName = "localCredential"
}

func registerAppUserMigration(_ migrator: inout DatabaseMigrator) {
    migrator.registerMigration("createAppUser") { db in
        try db.create(table: "appUser") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("personId", .integer).notNull().unique().references("person", onDelete: .restrict)
            t.column("displayName", .text).notNull()
            t.column("cloudKitUserRecordName", .text).unique()
            t.column("isAdmin", .boolean).notNull().defaults(to: false)
            t.column("createdAt", .datetime).notNull()
            t.column("lastSignInAt", .datetime)
        }
        try db.create(table: "localCredential") { t in
            t.primaryKey("appUserId", .integer).references("appUser", onDelete: .cascade)
            t.column("passwordHash", .text).notNull()
            t.column("recoveryKeyHash", .text).notNull()
        }
        // Settings that belong to this database file on this Mac and never sync (the database id).
        try db.create(table: "localSetting") { t in
            t.primaryKey("key", .text)
            t.column("value", .text).notNull()
        }
        try db.alter(table: "importRun") { t in
            t.add(column: "appUserId", .integer).references("appUser", onDelete: .setNull)
        }
        try db.alter(table: "importRule") { t in
            t.add(column: "createdByAppUserId", .integer).references("appUser", onDelete: .setNull)
            t.add(column: "lastLearntByAppUserId", .integer).references("appUser", onDelete: .setNull)
        }
    }
}

/// Values that belong to this database file and never sync (auth spec §3: device-local, like
/// `localCredential`).
public enum LocalSetting {
    static let databaseIdKey = "databaseId"

    /// A random id made the first time it's asked for. Touch ID enrolment on this Mac is keyed by it as well as
    /// by the app user id, so another database whose users share ids can't be unlocked by this enrolment.
    public static func databaseId(_ db: Database) throws -> String {
        if let id = try String.fetchOne(db, sql: "SELECT value FROM localSetting WHERE key = ?", arguments: [databaseIdKey]) {
            return id
        }
        let id = UUID().uuidString
        try db.execute(sql: "INSERT INTO localSetting (key, value) VALUES (?, ?)", arguments: [databaseIdKey, id])
        return id
    }
}
