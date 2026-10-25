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
            try? SyncChangeTracker.setWriter(previousWriter, origin: previousOrigin, db: db)
            throw error
        }
        try SyncChangeTracker.setWriter(previousWriter, origin: previousOrigin, db: db)
        return result
    }
}
