import Foundation
import GRDB

public enum ScenarioError: Error, Equatable {
    case emptyName
    case duplicateName
    case notFound
}

/// What "Refresh from budget" did with the scenario's own changes.
public struct RefreshReport: Equatable {
    /// Category names of the `changed` / `removed` entries re-applied over the fresh copy.
    public var reapplied: [String]
    /// "<Category>: couldn't reapply: source no longer in the budget", one per change whose
    /// budget source has gone (a change is kept as `added`, a removal is dropped).
    public var couldNotReapply: [String]
    /// Category names of re-applied `changed` / `removed` entries whose budget source has
    /// since been cut short: it now ends before the scenario entry's span does, or another
    /// budget entry of the same category starts within that span (a budget split).
    public var sourceChanged: [String]

    public init(reapplied: [String] = [], couldNotReapply: [String] = [], sourceChanged: [String] = []) {
        self.reapplied = reapplied
        self.couldNotReapply = couldNotReapply
        self.sourceChanged = sourceChanged
    }
}

/// One way a scenario differs from the budget: an `added`, `changed` or `removed` entry.
public struct ScenarioDifference: Equatable, Identifiable {
    /// The scenario entry's id.
    public var id: Int64
    public var kind: ScenarioChange
    public var categoryName: String
    /// The series in words ("-£1,000.00 monthly from 28 Feb 2026"): the scenario entry's, or
    /// for `removed` the budget source's.
    public var summary: String
    /// `changed` only: field by field ("Amount: -£300.00 → -£350.00"), plus "N occurrences
    /// edited" when its exceptions differ from the source's.
    public var fieldChanges: [String]
    /// `changed` / `removed` only: the budget entry this one was copied from, while it still exists.
    public var sourceEntryId: Int64?
    /// `changed` / `removed` only: that budget entry's series in words.
    public var sourceSummary: String?

    public init(id: Int64, kind: ScenarioChange, categoryName: String, summary: String, fieldChanges: [String],
                sourceEntryId: Int64? = nil, sourceSummary: String? = nil) {
        self.sourceEntryId = sourceEntryId
        self.sourceSummary = sourceSummary
        self.id = id
        self.kind = kind
        self.categoryName = categoryName
        self.summary = summary
        self.fieldChanges = fieldChanges
    }
}

/// Scenario operations (spec 2026-10-08-scenario-lab-design.md, "Operations"). Each runs in
/// its own savepoint. Editing inside a scenario goes through `PlannedItemEditing` and
/// `PlannedItems.add(…, scenarioId:)`.
public enum Scenarios {
    /// A new scenario holding a copy of every budget entry (all groups, disabled ones too,
    /// `isEnabled` kept) with its `sourceEntryId`, and each entry's exceptions.
    @discardableResult
    public static func create(db: Database, name: String, now: Date = Date()) throws -> Scenario {
        var scenario = Scenario(name: try validatedName(db: db, name), createdAt: now)
        try db.inSavepoint {
            try scenario.insert(db)
            for entry in try ForecastEntry.budget(db) {
                try copy(db: db, entry, scenarioId: scenario.id!, sourceEntryId: entry.id, change: nil)
            }
            return .commit
        }
        return scenario
    }

    /// A new scenario with a copy of `scenarioId`'s entries (change markers and sources kept)
    /// and their exceptions.
    @discardableResult
    public static func duplicate(db: Database, scenarioId: Int64, name: String, now: Date = Date()) throws -> Scenario {
        guard try Scenario.fetchOne(db, key: scenarioId) != nil else { throw ScenarioError.notFound }
        var scenario = Scenario(name: try validatedName(db: db, name), createdAt: now)
        try db.inSavepoint {
            try scenario.insert(db)
            for entry in try ForecastEntry.inScenario(db, id: scenarioId) {
                try copy(db: db, entry, scenarioId: scenario.id!, sourceEntryId: entry.sourceEntryId, change: entry.scenarioChange)
            }
            return .commit
        }
        return scenario
    }

    public static func rename(db: Database, scenarioId: Int64, to name: String) throws {
        try db.inSavepoint {
            guard var scenario = try Scenario.fetchOne(db, key: scenarioId) else { throw ScenarioError.notFound }
            scenario.name = try validatedName(db: db, name, excluding: scenarioId)
            try scenario.update(db, columns: ["name"])
            return .commit
        }
    }

    /// Deletes the scenario; its entries, their exceptions and its applications cascade.
    public static func delete(db: Database, scenarioId: Int64) throws {
        try db.inSavepoint {
            guard try Scenario.deleteOne(db, key: scenarioId) else { throw ScenarioError.notFound }
            return .commit
        }
    }

    /// Re-copies today's budget and re-applies the scenario's own changes: unchanged copies
    /// are deleted and every budget entry not covered by a `changed`/`removed` entry is copied
    /// afresh (with exceptions). A `changed`/`removed` entry whose source is still in the
    /// budget stands in for that source's copy; one whose source is gone is kept as `added`
    /// (changed) or dropped (removed) and reported. `added` entries are kept. Budget entries
    /// created by this scenario's own un-undone applies aren't copied (the scenario already
    /// holds them), nor are later budget entries continuing them (a split of an applied entry,
    /// `ownContinuations`); sources those applies ended aren't reported as `sourceChanged`.
    @discardableResult
    public static func refresh(db: Database, scenarioId: Int64, now: Date = Date()) throws -> RefreshReport {
        guard var scenario = try Scenario.fetchOne(db, key: scenarioId) else { throw ScenarioError.notFound }
        var report = RefreshReport()
        try db.inSavepoint {
            // What this scenario's own un-undone applies did to the budget: the entries they
            // created stand for scenario entries already here (not copied again), and the
            // sources they ended weren't cut short by anyone else (not reported).
            let ownApplications = try ScenarioApplication
                .filter(Column("scenarioId") == scenarioId && Column("undoneAt") == nil)
                .fetchAll(db)
                .compactMap { application in application.decodedJournal.map { (application, $0) } }
            let ownJournals = ownApplications.map(\.1)
            let ownCreated = Set(ownJournals.flatMap { $0.operations.flatMap { $0.created.map(\.entryId) } })
            let ownEnded = Set(ownJournals.flatMap { $0.operations.flatMap { $0.modified.map(\.entryId) } })
            let budget = try ownContinuations(db: db, applications: ownApplications, budget: ForecastEntry.budget(db).filter { !ownCreated.contains($0.id!) })
            let names = try categoryNames(db)
            var covered: Set<Int64> = []
            for var entry in try ForecastEntry.inScenario(db, id: scenarioId) {
                switch entry.scenarioChange {
                case nil:
                    _ = try entry.delete(db)
                case .added:
                    break
                case .changed, .removed:
                    let name = names[entry.categoryId] ?? "?"
                    if let sourceId = entry.sourceEntryId, let source = budget.first(where: { $0.id == sourceId }) {
                        covered.insert(sourceId)
                        report.reapplied.append(name)
                        if !ownEnded.contains(sourceId), sourceCutShort(source, of: entry, budget: budget) { report.sourceChanged.append(name) }
                    } else {
                        report.couldNotReapply.append("\(name): couldn't reapply: source no longer in the budget")
                        if entry.scenarioChange == .removed {
                            _ = try entry.delete(db)
                        } else {
                            entry.scenarioChange = .added
                            entry.sourceEntryId = nil
                            try entry.update(db)
                        }
                    }
                }
            }
            for entry in budget where !covered.contains(entry.id!) {
                try copy(db: db, entry, scenarioId: scenarioId, sourceEntryId: entry.id, change: nil)
            }
            scenario.refreshedAt = now
            try scenario.update(db, columns: ["refreshedAt"])
            return .commit
        }
        return report
    }

    /// `budget` without the entries that continue what this scenario's own applies created:
    /// a budget entry added after an apply (id above its `lastEntryId`) that starts after an
    /// own-created entry of its category has been ended, or the day after one of any
    /// category (a split moving the series to another category). Dropped entries chain, so
    /// a split of a split goes too. Genuinely new items (added while the applied entry is
    /// still open, or in the category of an applied removal) are kept.
    private static func ownContinuations(db: Database, applications: [(ScenarioApplication, ScenarioApplyJournal)], budget: [ForecastEntry]) throws -> [ForecastEntry] {
        // (entry, the lastEntryId of the apply it belongs to) for every own-created entry still there.
        var chain: [(entry: ForecastEntry, lastEntryId: Int64)] = []
        for (application, journal) in applications {
            let createdIds = journal.operations.filter { !$0.created.isEmpty }.flatMap { $0.created.map(\.entryId) }
            guard !createdIds.isEmpty, let lastId = application.laterThreshold(journal).lastEntryId else { continue }
            chain += try ForecastEntry.filter(keys: createdIds).fetchAll(db).map { ($0, lastId) }
        }
        guard !chain.isEmpty else { return budget }
        var dropped: Set<Int64> = []
        var grew = true
        while grew {
            grew = false
            for candidate in budget where !dropped.contains(candidate.id!) {
                let link = chain.first { link in
                    guard candidate.id! > link.lastEntryId, let end = link.entry.endDate else { return false }
                    let dayAfter = MonthRange.calendar.date(byAdding: .day, value: 1, to: end)!
                    return (candidate.categoryId == link.entry.categoryId && candidate.startDate > end) || candidate.startDate == dayAfter
                }
                if let link {
                    dropped.insert(candidate.id!)
                    chain.append((candidate, link.lastEntryId))
                    grew = true
                }
            }
        }
        return budget.filter { !dropped.contains($0.id!) }
    }

    /// The scenario's `added`, `changed` and `removed` entries, by entry id.
    public static func differences(db: Database, scenarioId: Int64) throws -> [ScenarioDifference] {
        let names = try categoryNames(db)
        let entries = try ForecastEntry.inScenario(db, id: scenarioId).filter { $0.scenarioChange != nil }
        let sourceIds = entries.compactMap(\.sourceEntryId)
        let sources = Dictionary(uniqueKeysWithValues: try ForecastEntry.budgetEntries.filter(keys: sourceIds).fetchAll(db).map { ($0.id!, $0) })
        let exceptionIds = entries.compactMap(\.id) + sourceIds
        let exceptions = Dictionary(grouping: try PlannedOccurrenceException.filter(exceptionIds.contains(Column("entryId"))).fetchAll(db), by: \.entryId)

        return entries.map { entry in
            let source = entry.sourceEntryId.flatMap { sources[$0] }
            let kind = entry.scenarioChange!
            var fieldChanges: [String] = []
            if kind == .changed, source == nil {
                fieldChanges = ["Source no longer in the budget"]
            } else if kind == .changed, let source {
                fieldChanges = changes(from: source, to: entry, names: names)
                let edited = editedOccurrences(entry: entry, own: exceptions[entry.id!] ?? [], source: exceptions[source.id!] ?? [])
                if edited > 0 { fieldChanges.append("\(edited) occurrence\(edited == 1 ? "" : "s") edited") }
            }
            let described = kind == .removed ? (source ?? entry) : entry
            return ScenarioDifference(id: entry.id!, kind: kind, categoryName: names[entry.categoryId] ?? "?",
                                      summary: summary(described), fieldChanges: fieldChanges,
                                      sourceEntryId: source?.id, sourceSummary: source.map(summary))
        }
    }

    /// Puts one scenario item back to the budget's version: the entry is deleted (exceptions
    /// cascade) and, for `changed`/`removed` entries whose budget source still exists, replaced
    /// by a fresh unchanged copy of it (with its exceptions), as `create`/`refresh` copy.
    public static func revert(db: Database, scenarioId: Int64, entryId: Int64) throws {
        try db.inSavepoint {
            guard let entry = try ForecastEntry.fetchOne(db, key: entryId), entry.scenarioId == scenarioId else { throw ScenarioError.notFound }
            _ = try entry.delete(db)
            if entry.scenarioChange == .changed || entry.scenarioChange == .removed,
               let sourceId = entry.sourceEntryId,
               let source = try ForecastEntry.budgetEntries.filter(key: sourceId).fetchOne(db) {
                try copy(db: db, source, scenarioId: scenarioId, sourceEntryId: sourceId, change: nil)
            }
            return .commit
        }
    }

    // MARK: - Helpers

    /// Copies `entry` (all values, `anchorDay`/`note`/`isEnabled`/`status`/`groupId` included)
    /// into the scenario, with its exceptions re-keyed to the copy (same `originalDate`).
    private static func copy(db: Database, _ entry: ForecastEntry, scenarioId: Int64, sourceEntryId: Int64?, change: ScenarioChange?) throws {
        var copy = entry
        copy.id = nil
        copy.scenarioId = scenarioId
        copy.sourceEntryId = sourceEntryId
        copy.scenarioChange = change
        try copy.insert(db)
        for var exception in try PlannedOccurrenceException.filter(Column("entryId") == entry.id!).order(Column("id")).fetchAll(db) {
            exception.id = nil
            exception.entryId = copy.id!
            try exception.insert(db)
        }
    }

    /// Whether the budget cut `source` short within `entry`'s span: it ends earlier, or a
    /// later budget entry of its category starts inside the span (the budget split it).
    private static func sourceCutShort(_ source: ForecastEntry, of entry: ForecastEntry, budget: [ForecastEntry]) -> Bool {
        if let sourceEnd = source.endDate, entry.endDate.map({ sourceEnd < $0 }) ?? true { return true }
        return budget.contains { other in
            other.id != source.id && other.categoryId == source.categoryId && other.startDate > source.startDate
                && other.startDate >= entry.startDate && (entry.endDate.map { other.startDate <= $0 } ?? true)
        }
    }

    private static func validatedName(db: Database, _ name: String, excluding scenarioId: Int64? = nil) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ScenarioError.emptyName }
        var request = Scenario.filter(Column("name") == trimmed)
        if let scenarioId { request = request.filter(Column("id") != scenarioId) }
        guard try request.fetchCount(db) == 0 else { throw ScenarioError.duplicateName }
        return trimmed
    }

    private static func categoryNames(_ db: Database) throws -> [Int64: String] {
        Dictionary(uniqueKeysWithValues: try Category.fetchAll(db).map { ($0.id!, $0.name) })
    }

    private static func changes(from source: ForecastEntry, to entry: ForecastEntry, names: [Int64: String]) -> [String] {
        var result: [String] = []
        if source.amountMinorUnits != entry.amountMinorUnits {
            result.append("Amount: \(money(source.amountMinorUnits)) → \(money(entry.amountMinorUnits))")
        }
        if source.frequency != entry.frequency || source.interval != entry.interval {
            result.append("Frequency: \(frequency(source)) → \(frequency(entry))")
        }
        if source.startDate != entry.startDate {
            result.append("Start: \(day(source.startDate)) → \(day(entry.startDate))")
        }
        if source.endDate != entry.endDate {
            result.append("End: \(source.endDate.map(day) ?? "none") → \(entry.endDate.map(day) ?? "none")")
        }
        if source.categoryId != entry.categoryId {
            result.append("Category: \(names[source.categoryId] ?? "?") → \(names[entry.categoryId] ?? "?")")
        }
        return result
    }

    /// Occurrences within the scenario entry's span whose exception differs from the source's
    /// (same `originalDate` key), or exists on one side only.
    private static func editedOccurrences(entry: ForecastEntry, own: [PlannedOccurrenceException], source: [PlannedOccurrenceException]) -> Int {
        func inSpan(_ date: Date) -> Bool { date >= entry.startDate && (entry.endDate.map { date <= $0 } ?? true) }
        func key(_ e: PlannedOccurrenceException) -> String { "\(e.isSkipped)|\(String(describing: e.amountMinorUnits))|\(String(describing: e.date))|\(String(describing: e.categoryId))" }
        let mine = Dictionary(own.filter { inSpan($0.originalDate) }.map { ($0.originalDate, key($0)) }, uniquingKeysWith: { a, _ in a })
        let theirs = Dictionary(source.filter { inSpan($0.originalDate) }.map { ($0.originalDate, key($0)) }, uniquingKeysWith: { a, _ in a })
        return Set(mine.keys).union(theirs.keys).filter { mine[$0] != theirs[$0] }.count
    }

    static func summary(_ entry: ForecastEntry) -> String {
        if entry.frequency == .once { return "\(money(entry.amountMinorUnits)) once on \(day(entry.startDate))" }
        var text = "\(money(entry.amountMinorUnits)) \(frequency(entry)) from \(day(entry.startDate))"
        if let end = entry.endDate { text += " until \(day(end))" }
        return text
    }

    private static func money(_ minorUnits: Int) -> String { Money.format(minorUnits, currency: .gbp) }

    private static func frequency(_ entry: ForecastEntry) -> String {
        let units: (one: String, many: String)
        switch entry.frequency {
        case .once: return "once"
        case .weekly: units = ("weekly", "weeks")
        case .monthly: units = ("monthly", "months")
        case .annually: units = ("annually", "years")
        }
        return entry.interval == 1 ? units.one : "every \(entry.interval) \(units.many)"
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "d MMM yyyy"
        return formatter
    }()

    private static func day(_ date: Date) -> String { dayFormatter.string(from: date) }
}
