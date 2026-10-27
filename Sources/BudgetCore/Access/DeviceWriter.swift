import Foundation
import GRDB

/// Why an iPad didn't write (step 8).
public enum DeviceWriteRefusal: Error, Equatable, LocalizedError {
    /// No app user is bound to this device's iCloud user yet: nothing is written, never as a default writer.
    case notLinkedYet
    /// The edit would move a figure on a filed or paid return; nothing was written. The Mac can still make it.
    case filedYear(FiledYearEditCheck.Question)

    public var errorDescription: String? {
        switch self {
        case .notLinkedYet: return DeviceWriteCopy.notLinkedYet
        case .filedYear(let question): return DeviceWriteCopy.filedYear(years: question.years.map(\.label))
        }
    }
}

/// Every iPad write (step 8). The actor is the app user bound to the device's iCloud user (`PhoneViewer`), resolved
/// at each write, so a household pull that names her lets the next write through. Each write runs in one
/// transaction through `ActorWrite.perform` with its area and origin: outside the actor's Edit areas it throws
/// `AccessDenied` and writes nothing, so nothing is queued for sync. `afterWrite` (ask the engine for a push) runs
/// after a write that committed, never after a refusal.
public struct DeviceWriter: Sendable {
    private let db: any DatabaseWriter
    private let viewer: @Sendable () -> PhoneViewer
    private let afterWrite: @Sendable () -> Void

    public init(db: any DatabaseWriter, viewer: @escaping @Sendable () -> PhoneViewer, afterWrite: @escaping @Sendable () -> Void) {
        self.db = db
        self.viewer = viewer
        self.afterWrite = afterWrite
    }

    /// Who writes: nil before an app user is bound to this device's iCloud user.
    public func actor() async throws -> AccessActor? {
        let viewer = viewer()
        return try await db.read { db in try Self.actor(viewer, db: db) }
    }

    /// Whether the actor has Edit on `area` (false with no actor, or when it can't be read).
    public func canEdit(_ area: AccessArea) async -> Bool {
        let viewer = viewer()
        return (try? await db.read { db in
            guard let actor = try Self.actor(viewer, db: db) else { return false }
            return try AccessPolicy.can(actor, .edit, area, db: db)
        }) ?? false
    }

    /// How many of the actor's own changes are still waiting to go up (`SyncChangeTracker.pending`, last written by
    /// them): after the user lost Edit the engine is read-only, so these are never sent (0 with no actor, or when it
    /// can't be read).
    public func unsentChanges() async -> Int {
        let viewer = viewer()
        return (try? await db.read { db -> Int in
            guard let actor = try Self.actor(viewer, db: db) else { return 0 }
            return try SyncChangeTracker.pending(db: db).filter { change in
                let by = try String.fetchOne(db, sql: """
                    SELECT COALESCE((SELECT modifiedBy FROM syncRecord WHERE uuid = ?), (SELECT deletedBy FROM syncTombstone WHERE uuid = ?))
                    """, arguments: [change.uuid, change.uuid])
                return by == actor.appUserUuid
            }.count
        }) ?? 0
    }

    /// Runs `body` as the actor in `area`, stamped with `origin`. Throws `DeviceWriteRefusal.notLinkedYet` with no
    /// actor, `AccessDenied` outside her Edit areas, and whatever `body` throws (an `EvidenceLinkGuard.Failure`
    /// stays as it is); each writes nothing.
    public func write<T: Sendable>(_ area: AccessArea, origin: WriteOrigin = .edit,
                                   _ body: @escaping @Sendable (Database) throws -> T) async throws -> T {
        let viewer = viewer()
        let result = try await db.write { db in
            try ActorWrite.perform(try Self.requireActor(viewer, db: db), area: area, origin: origin, db: db) { try body(db) }
        }
        afterWrite()
        return result
    }

    /// `write`, through `FiledYearEditCheck.save` with no resolution: an edit that would move a figure on a filed
    /// or paid return throws `DeviceWriteRefusal.filedYear` and writes nothing (no "mark as not counted" or
    /// "save anyway" on the iPad). `edit` and `scope` are as `save` takes them.
    public func writeCheckingFiledYears<T: Sendable>(_ area: AccessArea, origin: WriteOrigin = .edit, edit: String,
                                                     scope: FiledYearEditCheck.Scope,
                                                     _ body: @escaping @Sendable (Database) throws -> T) async throws -> T {
        let viewer = viewer()
        let result = try await db.write { db -> T in
            let actor = try Self.requireActor(viewer, db: db)
            let outcome = try ActorWrite.perform(actor, area: area, origin: origin, db: db) {
                try FiledYearEditCheck.save(db: db, edit: edit, scope: scope, resolution: nil) { try body(db) }
            }
            switch outcome {
            case .saved(let value): return value
            case .asks(let question): throw DeviceWriteRefusal.filedYear(question)
            }
        }
        afterWrite()
        return result
    }

    private static func requireActor(_ viewer: PhoneViewer, db: Database) throws -> AccessActor {
        guard let actor = try actor(viewer, db: db) else { throw DeviceWriteRefusal.notLinkedYet }
        return actor
    }

    /// The actor `viewer` writes as, read without writing. `.iCloudUser`: the app user bound to that iCloud user,
    /// else nil (never the admin). `.demoAdmin` and `.everyone` (demo data, tests): the household's admin.
    static func actor(_ viewer: PhoneViewer, db: Database) throws -> AccessActor? {
        let user: AppUser?
        switch viewer {
        case .iCloudUser(let recordName):
            user = try AppUser.forCloudKitUser(recordName: recordName, db: db)
        case .demoAdmin, .everyone:
            user = try AppUser.filter(Column("isAdmin") == true).order(Column("id")).fetchOne(db)
        }
        // An app user arrives with its identity (a pull, or the tracking triggers); one without is no one yet.
        guard let user, let id = user.id,
              let uuid = try SyncRecordStore.existingUUID(table: "appUser", localId: id, db: db) else { return nil }
        return AccessActor(appUserId: id, appUserUuid: uuid, personId: user.personId, isAdmin: user.isAdmin)
    }
}

/// The sync engine's write mode on a phone or tablet (step 8). Read-only unless this is an iPad and the app user
/// bound to its iCloud user has Edit on some area. Then a member's iPad (`isMember`: it follows the admin's household
/// through her shared database) pushes the household only; the admin's iPad pushes the household and his own
/// private zone. Anything else (no bound user, a member's user on the admin's own database, an admin with no
/// person identity yet) is read-only: never a default writer.
public enum DeviceWriteMode {
    public static func decide(recordName: String?, isMember: Bool, isPad: Bool, db: Database) throws -> SyncWriteMode {
        guard isPad, let actor = try DeviceWriter.actor(.iCloudUser(recordName: recordName), db: db) else { return .readOnly }
        var areas = AccessArea.fixedAreas
        for personId in try Int64.fetchAll(db, sql: "SELECT id FROM person ORDER BY id") {
            guard let uuid = try SyncRecordStore.existingUUID(table: "person", localId: personId, db: db) else { continue }
            areas.append(.tax(personUuid: uuid))
        }
        guard try areas.contains(where: { try AccessPolicy.can(actor, .edit, $0, db: db) }) else { return .readOnly }
        if isMember { return .device(zones: [SyncZones.household]) }
        guard actor.isAdmin,
              let personUuid = try SyncRecordStore.existingUUID(table: "person", localId: actor.personId, db: db) else { return .readOnly }
        return .device(zones: [SyncZones.household, SyncZones.privateZone(personUuid: personUuid)])
    }

    /// The mode decided now, when it isn't `current`; nil when it is. After a sync (a pull may have brought a
    /// changed permission or membership), a non-nil answer makes the engine again with it: a user who lost Edit
    /// stops pushing, one who gained it starts. An iPhone is always read-only, so it never changes (and reads
    /// nothing).
    public static func changed(from current: SyncWriteMode, recordName: String?, isMember: Bool, isPad: Bool,
                               db: Database) throws -> SyncWriteMode? {
        let decided = isPad ? try decide(recordName: recordName, isMember: isMember, isPad: true, db: db) : .readOnly
        return decided == current ? nil : decided
    }
}
