import GRDB
import Foundation

/// A scenario: a copy of the budget the user plays with on the Forecast screen (spec
/// 2026-10-08-scenario-lab-design.md). Its entries are `ForecastEntry` rows with this
/// `scenarioId`; deleting the scenario deletes them (and their exceptions).
public struct Scenario: Codable, Equatable, Identifiable, FetchableRecord, MutablePersistableRecord {
    public var id: Int64?
    public var name: String
    public var createdAt: Date
    /// When "Refresh from budget" last re-copied the budget; nil = never refreshed.
    public var refreshedAt: Date?

    public init(id: Int64? = nil, name: String, createdAt: Date, refreshedAt: Date? = nil) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.refreshedAt = refreshedAt
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    public static let databaseTableName = "scenario"
}

/// One "Apply to budget" of a scenario. `journal` (JSON) records what the apply did so
/// `undoneAt` can be set by an exact undo; only the latest un-undone one per scenario is undoable.
public struct ScenarioApplication: Codable, Equatable, Identifiable, FetchableRecord, MutablePersistableRecord {
    public var id: Int64?
    public var scenarioId: Int64
    public var appliedAt: Date
    public var undoneAt: Date?
    public var journal: String

    public init(id: Int64? = nil, scenarioId: Int64, appliedAt: Date, undoneAt: Date? = nil, journal: String) {
        self.id = id
        self.scenarioId = scenarioId
        self.appliedAt = appliedAt
        self.undoneAt = undoneAt
        self.journal = journal
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    public static let databaseTableName = "scenarioApplication"
}

/// Adds scenarios and converts legacy scenario groups (any group holding `.hypothetical`
/// entries): one scenario per such group, named after it, whose `.hypothetical` entries move
/// into it as `added` manual entries (their `groupId` is kept). No budget copy is made —
/// "Refresh from budget" brings the budget in.
func registerScenarioMigration(_ migrator: inout DatabaseMigrator) {
    migrator.registerMigration("createScenarios") { db in
        try db.create(table: "scenario") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("name", .text).notNull().unique()
            t.column("createdAt", .datetime).notNull()
            t.column("refreshedAt", .datetime)
        }
        try db.alter(table: "forecastEntry") { t in
            t.add(column: "scenarioId", .integer).references("scenario", onDelete: .cascade)
            t.add(column: "sourceEntryId", .integer) // no FK: the source may be deleted later
            t.add(column: "scenarioChange", .text)
        }
        try db.create(index: "forecastEntry_scenarioId", on: "forecastEntry", columns: ["scenarioId"])
        try db.create(table: "scenarioApplication") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("scenarioId", .integer).notNull().indexed().references("scenario", onDelete: .cascade)
            t.column("appliedAt", .datetime).notNull()
            t.column("undoneAt", .datetime)
            t.column("journal", .text).notNull()
        }

        // Legacy conversion. Group names aren't unique, scenario names are: a repeat gets " (2)", …
        let groups = try Row.fetchAll(db, sql: """
            SELECT id, name FROM forecastGroup
            WHERE id IN (SELECT groupId FROM forecastEntry WHERE status = 'hypothetical')
            ORDER BY id
            """)
        let now = Date()
        for group in groups {
            let groupId: Int64 = group["id"]
            let base: String = group["name"]
            var name = base
            var suffix = 2
            while try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM scenario WHERE name = ?", arguments: [name])! > 0 {
                name = "\(base) (\(suffix))"
                suffix += 1
            }
            try db.execute(sql: "INSERT INTO scenario (name, createdAt) VALUES (?, ?)", arguments: [name, now])
            try db.execute(sql: """
                UPDATE forecastEntry SET scenarioId = ?, scenarioChange = 'added', status = 'manual'
                WHERE groupId = ? AND status = 'hypothetical'
                """, arguments: [db.lastInsertedRowID, groupId])
        }
    }
}
