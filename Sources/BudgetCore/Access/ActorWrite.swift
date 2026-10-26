import Foundation
import GRDB

/// What made a write (sharing spec 2026-10-25 §10). The tracking triggers copy it into `syncRecord.origin`
/// and the payload carries it, so the Mac's re-validation can judge each incoming change by it.
public enum WriteOrigin: String, Codable, Sendable {
    /// A person editing a record by hand.
    case edit
    /// Rows an import batch wrote (its confirm or its Undo).
    case `import`
    /// Recharge, rent-receipt and invoice matching.
    case propertyMatching
    /// Linking a document to a record.
    case documentLink
    /// The app's own upkeep (summaries, seeded rows).
    case system
}

/// A write the actor's permissions don't allow.
public struct AccessDenied: Error, Equatable, LocalizedError {
    public var area: AccessArea

    public init(area: AccessArea) { self.area = area }

    public var errorDescription: String? { "You can't change \(area.title) in this household." }
}

/// Every write made on someone's behalf goes through `perform`: it checks the actor may edit the area,
/// then stamps the actor as the writer and the write's origin on what the body changes.
public enum ActorWrite {
    /// Runs `body` as `actor`, after checking `can(.edit, area)` (else throws `AccessDenied` and runs
    /// nothing). While it runs, `syncWriter` holds the actor's UUID and the origin; afterwards (also when
    /// `body` throws) the previous writer and origin are back. Inside another `perform`, an `.edit` origin
    /// keeps the outer call's origin (an edit made during an import is part of the import); any other
    /// origin replaces it for the inner body.
    public static func perform<T>(_ actor: AccessActor, area: AccessArea, origin: WriteOrigin = .edit, db: Database,
                                  _ body: () throws -> T) throws -> T {
        guard try AccessPolicy.can(actor, .edit, area, db: db) else { throw AccessDenied(area: area) }
        return try stamped(actor, origin: origin, db: db, body)
    }

    /// `perform` as `actor`, or, for nil, as the writer the database has now (an enclosing `perform`'s, or the default
    /// writer: the signed-in user, else the admin, `useDefaultWriter`), else the household's admin (a hub job, a tool:
    /// sharing plan "hub jobs stay the admin's"). A database with no admin yet (no app users: before sign-in was set
    /// up) has no permissions to check: `body` runs as it is.
    public static func perform<T>(orAdmin actor: AccessActor?, area: AccessArea, origin: WriteOrigin = .edit, db: Database,
                                  _ body: () throws -> T) throws -> T {
        if let actor { return try perform(actor, area: area, origin: origin, db: db, body) }
        if let uuid = try String.fetchOne(db, sql: "SELECT appUserUuid FROM syncWriter WHERE id = 1"),
           let id = try SyncRecordStore.localId(table: "appUser", uuid: uuid, db: db) {
            return try perform(try AccessActor.load(appUserId: id, db: db), area: area, origin: origin, db: db, body)
        }
        guard try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM appUser WHERE isAdmin = 1)") == true else { return try body() }
        return try perform(try AccessActor.admin(db: db), area: area, origin: origin, db: db, body)
    }

    /// Every write a database takes outside `perform` is stamped with its default writer (step 6 Task 9 fix round 1):
    /// app user `appUserId` (the signed-in user), else the household's admin (as hub jobs and tools write), else none
    /// (before sign-in is set up). The app sets it when the session changes; `DatabaseManager` and `ToolDatabase` at
    /// every open. So nothing the Mac writes after ownership is confirmed is writerless, which re-validation would
    /// take for nobody's (`AccessRevalidation`). Nothing if the database has no sync tables yet.
    public static func useDefaultWriter(appUserId: Int64?, db: Database) throws {
        guard try db.tableExists("syncWriter"), try db.tableExists("appUser") else { return }
        var uuid: String?
        if let appUserId, try AppUser.fetchOne(db, key: appUserId) != nil {
            uuid = try SyncRecordStore.uuid(for: "appUser", localId: appUserId, db: db)
        } else if try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM appUser WHERE isAdmin = 1)") == true {
            uuid = try AccessActor.admin(db: db).appUserUuid
        }
        // Unchanged: nothing written (a tool's dry run on a copy writes nothing at open).
        let current = try Row.fetchOne(db, sql: "SELECT appUserUuid, origin FROM syncWriter WHERE id = 1")
        if let current, (current["appUserUuid"] as String?) == uuid, (current["origin"] as String?) == nil { return }
        if current == nil, uuid == nil { return }
        try SyncChangeTracker.setWriter(uuid, db: db)
    }

    /// The actor of app user `appUserId`, or nil for nil (`perform(orAdmin:)` then writes as the admin).
    public static func actor(appUserId: Int64?, db: Database) throws -> AccessActor? {
        try appUserId.map { try AccessActor.load(appUserId: $0, db: db) }
    }

    /// `perform` without the area check, for writes whose rule isn't an area: the caller has already
    /// checked it (an owner setting their own account's level, `SharingLevels`).
    static func stamped<T>(_ actor: AccessActor, origin: WriteOrigin, db: Database, _ body: () throws -> T) throws -> T {
        let previous = try Row.fetchOne(db, sql: "SELECT appUserUuid, origin FROM syncWriter WHERE id = 1")
        let previousWriter: String? = previous?["appUserUuid"]
        let previousOrigin: String? = previous?["origin"]
        // An outer `perform` is running when an origin is set: `setWriter` without one clears it, and every
        // open clears a stale one (`refreshSyncTriggers`).
        let effective = origin == .edit ? (previousOrigin ?? origin.rawValue) : origin.rawValue
        try SyncChangeTracker.setWriter(actor.appUserUuid, origin: effective, db: db)
        let result: T
        do {
            result = try body()
        } catch {
            // A failed restore would leave this actor and origin on later writes: that error wins.
            try SyncChangeTracker.setWriter(previousWriter, origin: previousOrigin, db: db)
            throw error
        }
        try SyncChangeTracker.setWriter(previousWriter, origin: previousOrigin, db: db)
        return result
    }
}
