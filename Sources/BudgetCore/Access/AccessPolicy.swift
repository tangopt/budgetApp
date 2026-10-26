import Foundation
import GRDB

/// What an actor wants to do in an area (sync spec §6.3, Layer 2).
public enum AccessAction: Sendable {
    case view, edit
}

/// How far an app user may go in an area, lowest first.
public enum PermissionLevel: String, Codable, Comparable, Sendable {
    case none, view, edit

    private var rank: Int {
        switch self {
        case .none: return 0
        case .view: return 1
        case .edit: return 2
        }
    }

    public static func < (lhs: PermissionLevel, rhs: PermissionLevel) -> Bool { lhs.rank < rhs.rank }
}

/// The parts of the household a permission covers (sharing spec 2026-10-25 §2, §10). Tax is per person.
public enum AccessArea: Hashable, Sendable {
    case budgetAndAccounts, property, forecast, tax(personUuid: String), documents, `import`, rulesAndCategories, householdSettings

    /// Every area that isn't a person's tax, in the order the permissions are listed.
    public static let fixedAreas: [AccessArea] = [
        .budgetAndAccounts, .property, .forecast, .documents, .import, .rulesAndCategories, .householdSettings,
    ]

    private static let taxPrefix = "tax:"

    /// The value stored in `memberPermission.area`.
    public var storageKey: String {
        switch self {
        case .budgetAndAccounts: return "budgetAndAccounts"
        case .property: return "property"
        case .forecast: return "forecast"
        case .tax(let personUuid): return Self.taxPrefix + personUuid
        case .documents: return "documents"
        case .import: return "import"
        case .rulesAndCategories: return "rulesAndCategories"
        case .householdSettings: return "householdSettings"
        }
    }

    public init?(storageKey: String) {
        if storageKey.hasPrefix(Self.taxPrefix) {
            let personUuid = String(storageKey.dropFirst(Self.taxPrefix.count))
            guard !personUuid.isEmpty else { return nil }
            self = .tax(personUuid: personUuid)
            return
        }
        guard let area = Self.fixedAreas.first(where: { $0.storageKey == storageKey }) else { return nil }
        self = area
    }

    /// Person `personId`'s tax (their tax years and income), read without writing: a person not synced yet (no
    /// identity) has an area no member row names, so members get the default.
    public static func tax(ofPerson personId: Int64, db: Database) throws -> AccessArea {
        .tax(personUuid: try SyncRecordStore.existingUUID(table: "person", localId: personId, db: db) ?? "")
    }

    public var title: String {
        switch self {
        case .budgetAndAccounts: return "Budget & accounts"
        case .property: return "Property"
        case .forecast: return "Forecast"
        case .tax: return "Tax"
        case .documents: return "Documents"
        case .import: return "Import"
        case .rulesAndCategories: return "Rules & categories"
        case .householdSettings: return "Household settings"
        }
    }
}

/// One app user's level in one area (synced, household zone). An area without a row has the default
/// level (`MemberPermissions.defaultLevel`).
public struct MemberPermission: Codable, Equatable, FetchableRecord, MutablePersistableRecord, Sendable {
    public var id: Int64?
    public var appUserId: Int64
    /// `AccessArea.storageKey`.
    public var area: String
    public var level: PermissionLevel

    public init(id: Int64? = nil, appUserId: Int64, area: String, level: PermissionLevel) {
        self.id = id
        self.appUserId = appUserId
        self.area = area
        self.level = level
    }

    public static let databaseTableName = "memberPermission"

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

/// The default permissions (sharing spec 2026-10-25 §2): the admin edits everything; a member edits
/// Documents, Import and Property, and views everything else, each person's tax included.
public enum MemberPermissions {
    public static func defaultLevel(_ area: AccessArea, isAdmin: Bool) -> PermissionLevel {
        if isAdmin { return .edit }
        switch area {
        case .documents, .import, .property: return .edit
        case .budgetAndAccounts, .forecast, .tax, .rulesAndCategories, .householdSettings: return .view
        }
    }

    /// Writes a member's default rows: one per fixed area and one `.tax` row per person. A row that
    /// already exists is kept as it is. The admin gets none (they edit everywhere whatever is stored).
    public static func ensureDefaults(appUserId: Int64, db: Database) throws {
        guard let user = try AppUser.fetchOne(db, key: appUserId) else { throw AccessActorError.noSuchUser(appUserId) }
        guard !user.isAdmin else { return }
        var areas = AccessArea.fixedAreas
        for personId in try Int64.fetchAll(db, sql: "SELECT id FROM person ORDER BY id") {
            areas.append(.tax(personUuid: try SyncRecordStore.uuid(for: "person", localId: personId, db: db)))
        }
        for area in areas {
            try db.execute(sql: """
                INSERT INTO memberPermission(appUserId, area, level) VALUES (?, ?, ?)
                ON CONFLICT(appUserId, area) DO NOTHING
                """, arguments: [appUserId, area.storageKey, defaultLevel(area, isAdmin: false).rawValue])
        }
    }
}

public enum AccessActorError: Error, Equatable {
    case noSuchUser(Int64)
    /// The household has no admin app user yet.
    case noAdmin
}

/// Who is writing: a signed-in app user, with the person they are and their identity as the writer
/// stamped on synced rows. Hub jobs act as the admin (`admin(db:)`).
public struct AccessActor: Equatable, Sendable {
    public var appUserId: Int64
    public var appUserUuid: String
    public var personId: Int64
    public var isAdmin: Bool

    public init(appUserId: Int64, appUserUuid: String, personId: Int64, isAdmin: Bool) {
        self.appUserId = appUserId
        self.appUserUuid = appUserUuid
        self.personId = personId
        self.isAdmin = isAdmin
    }

    public static func load(appUserId: Int64, db: Database) throws -> AccessActor {
        guard let user = try AppUser.fetchOne(db, key: appUserId) else { throw AccessActorError.noSuchUser(appUserId) }
        return AccessActor(appUserId: appUserId,
                           appUserUuid: try SyncRecordStore.uuid(for: "appUser", localId: appUserId, db: db),
                           personId: user.personId, isAdmin: user.isAdmin)
    }

    /// The household's admin (the first admin app user), as whom hub jobs write.
    public static func admin(db: Database) throws -> AccessActor {
        guard let id = try Int64.fetchOne(db, sql: "SELECT id FROM appUser WHERE isAdmin = 1 ORDER BY id LIMIT 1") else {
            throw AccessActorError.noAdmin
        }
        return try load(appUserId: id, db: db)
    }
}

/// Layer 2 checks (sync spec §6.3): the admin edits everywhere; a member has their stored level for an
/// area, else the default.
public enum AccessPolicy {
    public static func level(_ actor: AccessActor, _ area: AccessArea, db: Database) throws -> PermissionLevel {
        // The admin edits everywhere (spec §2); stored rows are members' only.
        if actor.isAdmin { return .edit }
        if let stored = try MemberPermission
            .filter(Column("appUserId") == actor.appUserId && Column("area") == area.storageKey)
            .fetchOne(db) {
            return stored.level
        }
        return MemberPermissions.defaultLevel(area, isAdmin: actor.isAdmin)
    }

    public static func can(_ actor: AccessActor, _ action: AccessAction, _ area: AccessArea, db: Database) throws -> Bool {
        let level = try level(actor, area, db: db)
        switch action {
        case .view: return level >= .view
        case .edit: return level >= .edit
        }
    }

    /// Whether `actor` meets what a change needs (`AccessAreaMap.area`).
    public static func allows(_ actor: AccessActor, _ decision: AccessDecision, db: Database) throws -> Bool {
        switch decision {
        case .area(let area): return try can(actor, .edit, area, db: db)
        case .ownerOnly(let personId): return personId != nil && personId == actor.personId
        case .allOf(let parts): return try parts.allSatisfy { try allows(actor, $0, db: db) }
        case .denied: return false
        }
    }

    /// Only the account's owner sets its level (spec "Owner rule"); a joint account (no owner) has no
    /// one who can, so it stays at Everything. The admin is no exception.
    public static func canSetLevel(_ actor: AccessActor, accountId: Int64, db: Database) throws -> Bool {
        guard let owner = try Int64.fetchOne(db, sql: "SELECT ownerPersonId FROM account WHERE id = ?", arguments: [accountId]) else {
            return false
        }
        return owner == actor.personId
    }
}
