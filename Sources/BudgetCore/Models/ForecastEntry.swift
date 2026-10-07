import GRDB
import Foundation

public enum ForecastFrequency: String, Codable, CaseIterable, Sendable {
    case once
    case weekly
    case monthly
    case annually
}

public enum ForecastEntryStatus: String, Codable, CaseIterable, Sendable {
    case auto
    case manual
    case hypothetical
    case confirmed
}

/// How a scenario entry differs from the budget entry it was copied from (`sourceEntryId`).
/// NULL in the database = an unchanged copy.
public enum ScenarioChange: String, Codable, CaseIterable, Sendable {
    case added
    case changed
    /// A tombstone (kept disabled) for a budget entry the scenario removes.
    case removed
}

public struct ForecastEntry: Codable, Equatable, Identifiable, FetchableRecord, MutablePersistableRecord, Sendable {
    public var id: Int64?
    public var groupId: Int64
    public var categoryId: Int64
    public var amountMinorUnits: Int
    public var frequency: ForecastFrequency
    public var interval: Int
    public var startDate: Date
    public var endDate: Date?
    public var isEnabled: Bool
    public var status: ForecastEntryStatus
    public var note: String?
    /// Day of month monthly/annual occurrences fall on (clamped to the month's length);
    /// nil = `startDate`'s UTC day. Lets a series split at 28 Feb keep 31 Mar, 30 Apr, …
    public var anchorDay: Int?
    /// nil = a budget entry; otherwise the scenario holding it (budget loads use `budget(_:)`).
    public var scenarioId: Int64?
    /// A scenario entry's budget source (no FK: the source may since have been deleted).
    public var sourceEntryId: Int64?
    /// nil = unchanged copy of its source (or a budget entry).
    public var scenarioChange: ScenarioChange?

    public init(id: Int64? = nil, groupId: Int64, categoryId: Int64, amountMinorUnits: Int, frequency: ForecastFrequency, interval: Int, startDate: Date, endDate: Date?, isEnabled: Bool, status: ForecastEntryStatus, note: String?, anchorDay: Int? = nil, scenarioId: Int64? = nil, sourceEntryId: Int64? = nil, scenarioChange: ScenarioChange? = nil) {
        self.id = id
        self.groupId = groupId
        self.categoryId = categoryId
        self.amountMinorUnits = amountMinorUnits
        self.frequency = frequency
        self.interval = interval
        self.startDate = startDate
        self.endDate = endDate
        self.isEnabled = isEnabled
        self.status = status
        self.note = note
        self.anchorDay = anchorDay
        self.scenarioId = scenarioId
        self.sourceEntryId = sourceEntryId
        self.scenarioChange = scenarioChange
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    public static let databaseTableName = "forecastEntry"

    /// The budget's entries (`scenarioId IS NULL`). Every load of entries for the budget
    /// (Dashboard, Budget grid, projection, detection, editing) goes through this.
    public static var budgetEntries: QueryInterfaceRequest<ForecastEntry> {
        filter(Column("scenarioId") == nil)
    }

    /// The budget's entries, by id.
    public static func budget(_ db: Database) throws -> [ForecastEntry] {
        try budgetEntries.order(Column("id")).fetchAll(db)
    }

    /// A scenario's entries (including `removed` tombstones), by id.
    public static func inScenario(_ db: Database, id scenarioId: Int64) throws -> [ForecastEntry] {
        try filter(Column("scenarioId") == scenarioId).order(Column("id")).fetchAll(db)
    }
}

func registerForecastEntryMigration(_ migrator: inout DatabaseMigrator) {
    migrator.registerMigration("createForecastEntry") { db in
        try db.create(table: "forecastEntry") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("groupId", .integer).notNull().references("forecastGroup")
            t.column("categoryId", .integer).notNull().references("category")
            t.column("amountMinorUnits", .integer).notNull()
            t.column("frequency", .text).notNull()
            t.column("interval", .integer).notNull().defaults(to: 1)
            t.column("startDate", .datetime).notNull()
            t.column("endDate", .datetime)
            t.column("isEnabled", .boolean).notNull().defaults(to: true)
            t.column("status", .text).notNull()
            t.column("note", .text)
        }
    }
}

func registerForecastEntryAnchorDayMigration(_ migrator: inout DatabaseMigrator) {
    migrator.registerMigration("addForecastEntryAnchorDay") { db in
        try db.alter(table: "forecastEntry") { t in
            t.add(column: "anchorDay", .integer)
        }
    }
}
