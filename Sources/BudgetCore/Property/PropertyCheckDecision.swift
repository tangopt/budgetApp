import GRDB
import Foundation

/// One recurring series of a property: a category's payee (`PropertyRecurringSeries.keys`), or a
/// mortgage account's instalments. What a check decision is about.
public struct PropertyRecurringSeriesRef: Hashable, Sendable {
    /// The category of a cost's series; nil for a mortgage's instalments.
    public var categoryId: Int64?
    /// The mortgage account of instalments; nil for a cost's series.
    public var accountId: Int64?
    /// The payee within the category (`PropertyRecurringSeries.keys`); "" for the whole category
    /// or a mortgage account.
    public var key: String

    public init(categoryId: Int64?, accountId: Int64?, key: String) {
        self.categoryId = categoryId
        self.accountId = accountId
        self.key = key
    }
}

/// A decision on a property check, kept as a log (2026-10-24): rows are only appended, the
/// latest per series is what holds, and undoing appends the opposite. Synced, so two devices'
/// decisions merge by their time with no unique key to collide on.
public struct PropertyCheckDecision: Codable, Equatable, Identifiable, FetchableRecord, MutablePersistableRecord, Sendable {
    public enum Decision: String, Codable, Sendable {
        /// "Not expected any more": the series has stopped; its overdue item goes.
        case notExpected
        /// Expected again (the undo of `notExpected`).
        case expected
    }

    public var id: Int64?
    public var propertyId: Int64
    public var categoryId: Int64?
    public var accountId: Int64?
    public var seriesKey: String
    /// The series' last payment when the decision was made: a later payment means the series
    /// carries on, and the decision no longer holds.
    public var lastSeenDate: Date
    public var decision: Decision
    public var createdAt: Date

    public init(id: Int64? = nil, propertyId: Int64, series: PropertyRecurringSeriesRef, lastSeenDate: Date, decision: Decision, createdAt: Date) {
        self.id = id
        self.propertyId = propertyId
        self.categoryId = series.categoryId
        self.accountId = series.accountId
        self.seriesKey = series.key
        self.lastSeenDate = lastSeenDate
        self.decision = decision
        self.createdAt = createdAt
    }

    public var series: PropertyRecurringSeriesRef { .init(categoryId: categoryId, accountId: accountId, key: seriesKey) }

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
    public static let databaseTableName = "propertyCheckDecision"
}

public enum PropertyCheckDecisions {
    /// "Not expected any more": stops expecting the pattern's series (it leaves the checks and
    /// the calendar) until it's paid again or `expectAgain`.
    public static func stopExpecting(db: Database, propertyId: Int64, pattern: PropertyRecurringPattern, now: Date = Date()) throws {
        var row = PropertyCheckDecision(propertyId: propertyId, series: pattern.series, lastSeenDate: pattern.lastDate,
                                        decision: .notExpected, createdAt: now)
        try row.insert(db)
    }

    /// Undoes "Not expected any more": the series is expected again.
    public static func expectAgain(db: Database, propertyId: Int64, series: PropertyRecurringSeriesRef, now: Date = Date()) throws {
        let lastSeen = try latest(db: db, propertyId: propertyId)[series]?.lastSeenDate ?? now
        var row = PropertyCheckDecision(propertyId: propertyId, series: series, lastSeenDate: lastSeen, decision: .expected, createdAt: now)
        try row.insert(db)
    }

    /// The latest decision of each series of the property (by time, then insertion).
    public static func latest(db: Database, propertyId: Int64) throws -> [PropertyRecurringSeriesRef: PropertyCheckDecision] {
        var result: [PropertyRecurringSeriesRef: PropertyCheckDecision] = [:]
        for row in try PropertyCheckDecision.filter(Column("propertyId") == propertyId)
            .order(Column("createdAt"), Column("id")).fetchAll(db) {
            result[row.series] = row
        }
        return result
    }

    /// The "Not expected any more" decisions that hold: the latest of their series, made after
    /// its last payment so far.
    static func notExpected(db: Database, propertyId: Int64) throws -> [PropertyRecurringSeriesRef: PropertyCheckDecision] {
        try latest(db: db, propertyId: propertyId).filter { $0.value.decision == .notExpected }
    }

    /// Whether a not-expected decision holds for the pattern (no payment since it was made).
    static func holds(_ decision: PropertyCheckDecision?, for pattern: PropertyRecurringPattern) -> Bool {
        guard let decision, decision.decision == .notExpected else { return false }
        return pattern.lastDate <= PropertyDates.day(decision.lastSeenDate)
    }
}

func registerPropertyCheckDecisionMigration(_ migrator: inout DatabaseMigrator) {
    migrator.registerMigration("addPropertyCheckDecision") { db in
        try db.create(table: "propertyCheckDecision") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("propertyId", .integer).notNull().indexed().references("property", onDelete: .cascade)
            t.column("categoryId", .integer).indexed().references("category", onDelete: .cascade)
            t.column("accountId", .integer).indexed().references("account", onDelete: .cascade)
            t.column("seriesKey", .text).notNull()
            t.column("lastSeenDate", .datetime).notNull()
            t.column("decision", .text).notNull()
            t.column("createdAt", .datetime).notNull()
        }
    }
}
