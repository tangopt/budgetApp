import Foundation
import GRDB

/// One line of a member's permission grid: an area, the member's level in it and the levels the admin may pick.
public struct PermissionGridRow: Equatable, Identifiable, Sendable {
    public var area: AccessArea
    /// `area.title`; a person's tax names the person ("Tax — Person A").
    public var title: String
    public var level: PermissionLevel
    /// None, View and Edit; Household settings offers no Edit (step 7b spec §2.1).
    public var choices: [PermissionLevel]

    public var id: String { area.storageKey }

    public init(area: AccessArea, title: String, level: PermissionLevel, choices: [PermissionLevel]) {
        self.area = area
        self.title = title
        self.level = level
        self.choices = choices
    }
}

public enum PermissionGridError: Error, Equatable {
    /// The app user is the admin (who edits everywhere) or doesn't exist.
    case notAMember
    /// A row asks for a level its area doesn't offer (`PermissionGrid.choices(for:)`): Edit on Household settings.
    case levelNotOffered(AccessArea)
}

/// What one member may do, area by area (step 7b spec §2.1): the admin's Settings ▸ Household grid. Loading reads
/// only (an area without a stored row shows its default); only `save`, as the admin, writes, and only the rows that
/// changed. Lowering a level never deletes anything: it only limits what the member changes and sees from then on.
public struct PermissionGrid: Equatable, Sendable {
    public var appUserId: Int64
    public var memberName: String
    public var rows: [PermissionGridRow]

    public init(appUserId: Int64, memberName: String, rows: [PermissionGridRow]) {
        self.appUserId = appUserId
        self.memberName = memberName
        self.rows = rows
    }

    /// The fixed areas, then one tax row per person (by `person.id`), each at its stored level, else the default.
    /// Throws `notAMember` for the admin or an unknown app user. Writes nothing.
    public static func load(db: Database, appUserId: Int64) throws -> PermissionGrid {
        guard let user = try AppUser.fetchOne(db, key: appUserId), !user.isAdmin else { throw PermissionGridError.notAMember }
        let memberName = try String.fetchOne(db, sql: "SELECT name FROM person WHERE id = ?", arguments: [user.personId]) ?? user.displayName
        let stored = try storedLevels(appUserId: appUserId, db: db)
        var areas = AccessArea.fixedAreas.map { ($0, $0.title) }
        for person in try Row.fetchAll(db, sql: "SELECT id, name FROM person ORDER BY id") {
            // A person with no identity yet (not synced) has no area a row could name: they appear once synced.
            guard let uuid = try SyncRecordStore.existingUUID(table: "person", localId: person["id"], db: db) else { continue }
            areas.append((.tax(personUuid: uuid), "Tax — \(person["name"] as String)"))
        }
        let rows = areas.map { area, title in
            PermissionGridRow(area: area, title: title,
                              level: stored[area.storageKey] ?? MemberPermissions.defaultLevel(area, isAdmin: false),
                              choices: choices(for: area))
        }
        return PermissionGrid(appUserId: appUserId, memberName: memberName, rows: rows)
    }

    /// The levels the admin may give in `area`: None, View and Edit; Household settings offers no Edit (spec §2.1).
    public static func choices(for area: AccessArea) -> [PermissionLevel] {
        area == .householdSettings ? [.none, .view] : [.none, .view, .edit]
    }

    /// The areas whose level differs from `original`'s, in row order.
    public func differences(from original: PermissionGrid) -> [AccessArea] {
        let before = Dictionary(original.rows.map { ($0.area, $0.level) }, uniquingKeysWith: { first, _ in first })
        return rows.filter { before[$0.area] != $0.level }.map(\.area)
    }

    /// This grid with every row at its default level. Nothing is saved until `save`.
    public func resetToDefaults() -> PermissionGrid {
        var grid = self
        for index in grid.rows.indices {
            grid.rows[index].level = MemberPermissions.defaultLevel(grid.rows[index].area, isAdmin: false)
        }
        return grid
    }

    /// Saves `grid` as `actor`, who needs Edit on Household settings (the admin; else `AccessDenied`, nothing written).
    /// Upserts only the rows whose level differs from what is stored (else the default), so sync sees one record per
    /// changed area; a row back at its default is written as that default. No row is ever deleted. A level its area
    /// doesn't offer (`choices(for:)`) throws `levelNotOffered` before anything is written.
    public static func save(_ grid: PermissionGrid, actor: AccessActor, db: Database) throws {
        try ActorWrite.perform(actor, area: .householdSettings, origin: .edit, db: db) {
            guard let user = try AppUser.fetchOne(db, key: grid.appUserId), !user.isAdmin else { throw PermissionGridError.notAMember }
            // Judged by the area, not the row's own `choices` (which a caller can change): nothing is written if one fails.
            if let refused = grid.rows.first(where: { !choices(for: $0.area).contains($0.level) }) {
                throw PermissionGridError.levelNotOffered(refused.area)
            }
            let stored = try storedLevels(appUserId: grid.appUserId, db: db)
            for row in grid.rows where row.level != (stored[row.id] ?? MemberPermissions.defaultLevel(row.area, isAdmin: false)) {
                try db.execute(sql: """
                    INSERT INTO memberPermission(appUserId, area, level) VALUES (?, ?, ?)
                    ON CONFLICT(appUserId, area) DO UPDATE SET level = excluded.level
                    """, arguments: [grid.appUserId, row.id, row.level.rawValue])
            }
        }
    }

    /// The member's stored levels by `AccessArea.storageKey`, read once.
    private static func storedLevels(appUserId: Int64, db: Database) throws -> [String: PermissionLevel] {
        let rows = try MemberPermission.filter(Column("appUserId") == appUserId).fetchAll(db)
        return Dictionary(rows.map { ($0.area, $0.level) }, uniquingKeysWith: { first, _ in first })
    }
}
