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

    /// `perform` as `actor`, or, for nil, as whoever an enclosing `perform` writes as, else the household's admin (a
    /// hub job, a tool: sharing plan "hub jobs stay the admin's"). A database with no admin yet (no app users: before
    /// sign-in was set up) has no permissions to check: `body` runs as it is.
    public static func perform<T>(orAdmin actor: AccessActor?, area: AccessArea, origin: WriteOrigin = .edit, db: Database,
                                  _ body: () throws -> T) throws -> T {
        if let actor { return try perform(actor, area: area, origin: origin, db: db, body) }
        if let outer = try Row.fetchOne(db, sql: "SELECT appUserUuid FROM syncWriter WHERE id = 1 AND origin IS NOT NULL"),
           let uuid: String = outer["appUserUuid"], let id = try SyncRecordStore.localId(table: "appUser", uuid: uuid, db: db) {
            return try perform(try AccessActor.load(appUserId: id, db: db), area: area, origin: origin, db: db, body)
        }
        guard try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM appUser WHERE isAdmin = 1)") == true else { return try body() }
        return try perform(try AccessActor.admin(db: db), area: area, origin: origin, db: db, body)
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
