import Foundation
import GRDB

public enum ScenarioApplyError: Error, Equatable {
    /// The id isn't an `added`, `changed` or `removed` entry of the scenario.
    case notADifference(Int64)
    /// The scenario has no un-undone application.
    case nothingToUndo
}

/// What an apply did, stored as JSON in `ScenarioApplication.journal` so `undoLast` can put
/// the budget back exactly.
public struct ScenarioApplyJournal: Codable, Equatable {
    /// The two fields an apply changes on an existing budget entry.
    public struct EntryState: Codable, Equatable {
        public var endDate: Date?
        public var isEnabled: Bool

        public init(endDate: Date?, isEnabled: Bool) {
            self.endDate = endDate
            self.isEnabled = isEnabled
        }
    }

    /// An existing budget entry the apply changed: its state before, and a fingerprint of
    /// the whole entry (with its exceptions) right after, to tell whether it was edited since.
    public struct Modification: Codable, Equatable {
        public var entryId: Int64
        public var before: EntryState
        public var after: String
    }

    /// A budget entry the apply created, with its fingerprint right after the apply.
    public struct Creation: Codable, Equatable {
        public var entryId: Int64
        public var after: String
    }

    public struct Operation: Codable, Equatable {
        /// The scenario entry (= `ScenarioDifference.id`) applied.
        public var differenceId: Int64
        public var kind: ScenarioChange
        public var categoryName: String
        public var created: [Creation]
        public var modified: [Modification]
    }

    public var operations: [Operation]
    /// Groups the apply switched on (a disabled "Planned" group receiving an added item).
    public var enabledGroupIds: [Int64]
    /// What wasn't applied, in words: edits on occurrences the budget treats as confirmed,
    /// differences already applied, removals whose budget source is gone.
    public var skipped: [String]
}

extension ScenarioApplication {
    public var decodedJournal: ScenarioApplyJournal? {
        try? JSONDecoder().decode(ScenarioApplyJournal.self, from: Data(journal.utf8))
    }

    /// The apply's "not applied" list (`ScenarioApplyJournal.skipped`).
    public var skipped: [String] { decodedJournal?.skipped ?? [] }
}

/// What `undoLast` did.
public struct UndoReport: Equatable {
    /// Category names of the undone operations.
    public var restored: [String]
    /// Entries edited or deleted since the apply ("Rent was edited after applying; restored
    /// to before the apply").
    public var warnings: [String]

    public init(restored: [String] = [], warnings: [String] = []) {
        self.restored = restored
        self.warnings = warnings
    }
}

/// Apply to budget, with undo (spec 2026-10-08-scenario-lab-design.md). The boundary is the
/// current pay month (`calendar.current`): its calendar month's first day. Applied items are
/// ordinary `.manual` budget entries; the scenario itself is left as it is.
public enum ScenarioApply {
    private static let utc = MonthRange.calendar

    /// Applies the ticked differences (scenario entry ids) to the budget in one savepoint:
    /// - `added` → a new budget entry (group "Planned", or "Reserved" for a reserve) from the
    ///   entry's first occurrence on/after the boundary (anchor day kept), plus its exceptions
    ///   from there;
    /// - `removed` → the budget source ends the day before the boundary (disabled instead
    ///   when it hasn't started by then);
    /// - `changed` → the source ends as for `removed`, and a new entry with the scenario's
    ///   values (in the source's group) starts as for `added`. A `changed` entry whose source
    ///   is gone is applied as `added`.
    /// Scenario exceptions on occurrences the budget treats as confirmed
    /// (`PlannedItemEditing.isConfirmed`) aren't copied; they, differences already applied
    /// by an un-undone application, and removals whose source is gone are listed in `skipped`.
    @discardableResult
    public static func apply(db: Database, scenarioId: Int64, differenceIds: [Int64], calendar: PayCalendar, now: Date = Date()) throws -> ScenarioApplication {
        guard try Scenario.fetchOne(db, key: scenarioId) != nil else { throw ScenarioError.notFound }
        var application = ScenarioApplication(scenarioId: scenarioId, appliedAt: now, journal: "")
        try db.inSavepoint {
            let scenarioEntries = Dictionary(uniqueKeysWithValues: try ForecastEntry.inScenario(db, id: scenarioId).map { ($0.id!, $0) })
            let chosen = try differenceIds.map { id -> ForecastEntry in
                guard let entry = scenarioEntries[id], entry.scenarioChange != nil else { throw ScenarioApplyError.notADifference(id) }
                return entry
            }
            let categories = try Category.fetchAll(db)
            let names = Dictionary(uniqueKeysWithValues: categories.map { ($0.id!, $0.name) })
            let alreadyApplied = Set(try ScenarioApplication
                .filter(Column("scenarioId") == scenarioId && Column("undoneAt") == nil)
                .fetchAll(db)
                .flatMap { $0.decodedJournal?.operations.map(\.differenceId) ?? [] })

            // The budget as it stands before the apply, for the confirmation rule.
            let current = calendar.current
            let boundary = MonthRange.of(year: current.year, month: current.month).start
            let budget = try ForecastEntry.budget(db)
            let groups = try ForecastGroup.fetchAll(db)
            let budgetIds = budget.compactMap(\.id)
            let budgetExceptions = try PlannedOccurrenceException.filter(budgetIds.contains(Column("entryId"))).fetchAll(db)
            let payStart = calendar.range(of: current).start
            let transactions = try Transaction
                .filter(Column("date") >= payStart && Column("status") == TransactionStatus.confirmed.rawValue)
                .fetchAll(db)
            let monthTotals = PayMonthTotals.lookup(transactions: transactions, calendar: calendar)
            func confirmed(_ occurrence: PlannedOccurrence, of entry: ForecastEntry) -> Bool {
                PlannedItemEditing.isConfirmed(entry: entry, occurrence: occurrence, calendar: calendar, monthTotals: monthTotals,
                                               entries: budget, groups: groups, exceptions: budgetExceptions, categories: categories)
            }

            var journal = ScenarioApplyJournal(operations: [], enabledGroupIds: [], skipped: [])
            var budgetById = Dictionary(uniqueKeysWithValues: budget.map { ($0.id!, $0) })

            for scenarioEntry in chosen {
                let name = names[scenarioEntry.categoryId] ?? "?"
                if alreadyApplied.contains(scenarioEntry.id!) {
                    journal.skipped.append("\(name): already applied")
                    continue
                }
                var operation = ScenarioApplyJournal.Operation(differenceId: scenarioEntry.id!, kind: scenarioEntry.scenarioChange!,
                                                               categoryName: name, created: [], modified: [])
                let source = scenarioEntry.sourceEntryId.flatMap { budgetById[$0] }

                switch scenarioEntry.scenarioChange! {
                case .removed:
                    guard let source else {
                        journal.skipped.append("\(name): source no longer in the budget")
                        continue
                    }
                    if let modification = try end(db: db, source, before: boundary) {
                        operation.modified.append(modification)
                        budgetById[source.id!] = try ForecastEntry.fetchOne(db, key: source.id!)
                    }
                case .changed, .added:
                    if scenarioEntry.scenarioChange == .changed, let source {
                        if let modification = try end(db: db, source, before: boundary) {
                            operation.modified.append(modification)
                            budgetById[source.id!] = try ForecastEntry.fetchOne(db, key: source.id!)
                        }
                    }
                    let groupId: Int64
                    if let source, scenarioEntry.scenarioChange == .changed {
                        groupId = source.groupId
                    } else if categories.first(where: { $0.id == scenarioEntry.categoryId })?.isReserved == true {
                        groupId = try ReservedCategories.ensureGroup(db: db).id!
                    } else {
                        let wasDisabled = try ForecastGroup.filter(Column("name") == PlannedItems.groupName && Column("isEnabled") == false).fetchOne(db)
                        groupId = try PlannedItems.ensureGroup(db: db).id!
                        if let wasDisabled, !journal.enabledGroupIds.contains(wasDisabled.id!) { journal.enabledGroupIds.append(wasDisabled.id!) }
                    }
                    if let createdId = try create(db: db, from: scenarioEntry, groupId: groupId, boundary: boundary, name: name,
                                                  skipped: &journal.skipped, confirmed: confirmed) {
                        operation.created.append(ScenarioApplyJournal.Creation(entryId: createdId, after: ""))
                    }
                }
                journal.operations.append(operation)
            }

            // After-images, once every operation has run.
            for i in journal.operations.indices {
                for j in journal.operations[i].created.indices {
                    journal.operations[i].created[j].after = try fingerprint(db: db, entryId: journal.operations[i].created[j].entryId) ?? ""
                }
                for j in journal.operations[i].modified.indices {
                    journal.operations[i].modified[j].after = try fingerprint(db: db, entryId: journal.operations[i].modified[j].entryId) ?? ""
                }
            }

            application.journal = try encode(journal)
            try application.insert(db)
            return .commit
        }
        return application
    }

    /// Undoes the scenario's most recent un-undone application: deletes the entries it
    /// created (exceptions cascade), restores the before-images of the entries it changed and
    /// switches off groups it switched on, in reverse order. Entries edited since are still
    /// restored (or removed) but reported; ones deleted since are reported.
    @discardableResult
    public static func undoLast(db: Database, scenarioId: Int64, now: Date = Date()) throws -> UndoReport {
        guard var application = try latest(db: db, scenarioId: scenarioId) else { throw ScenarioApplyError.nothingToUndo }
        var report = UndoReport()
        try db.inSavepoint {
            let journal = try JSONDecoder().decode(ScenarioApplyJournal.self, from: Data(application.journal.utf8))
            for operation in journal.operations.reversed() {
                let name = operation.categoryName
                for created in operation.created.reversed() {
                    guard let entry = try ForecastEntry.fetchOne(db, key: created.entryId) else {
                        report.warnings.append("\(name): the item the apply added was already deleted")
                        continue
                    }
                    if try fingerprint(db: db, entryId: created.entryId) != created.after {
                        report.warnings.append("\(name): the item the apply added was edited since; removed anyway")
                    }
                    _ = try entry.delete(db)
                }
                for modified in operation.modified.reversed() {
                    guard var entry = try ForecastEntry.fetchOne(db, key: modified.entryId) else {
                        report.warnings.append("\(name) couldn't be restored: it's no longer in the budget")
                        continue
                    }
                    if try fingerprint(db: db, entryId: modified.entryId) != modified.after {
                        report.warnings.append("\(name) was edited after applying; restored to before the apply")
                    }
                    entry.endDate = modified.before.endDate
                    entry.isEnabled = modified.before.isEnabled
                    try entry.update(db, columns: ["endDate", "isEnabled"])
                }
                report.restored.append(name)
            }
            for groupId in journal.enabledGroupIds {
                try db.execute(sql: "UPDATE forecastGroup SET isEnabled = 0 WHERE id = ?", arguments: [groupId])
            }
            application.undoneAt = now
            try application.update(db, columns: ["undoneAt"])
            return .commit
        }
        return report
    }

    /// Whether the scenario has an application `undoLast` can undo.
    public static func canUndo(db: Database, scenarioId: Int64) throws -> Bool {
        try latest(db: db, scenarioId: scenarioId) != nil
    }

    // MARK: - Helpers

    private static func latest(db: Database, scenarioId: Int64) throws -> ScenarioApplication? {
        try ScenarioApplication
            .filter(Column("scenarioId") == scenarioId && Column("undoneAt") == nil)
            .order(Column("id").desc)
            .fetchOne(db)
    }

    /// Ends `source` the day before `boundary`, or disables it when it starts on/after it.
    /// Nil when it already ends before the boundary (or is disabled): nothing to change.
    private static func end(db: Database, _ source: ForecastEntry, before boundary: Date) throws -> ScenarioApplyJournal.Modification? {
        let before = ScenarioApplyJournal.EntryState(endDate: source.endDate, isEnabled: source.isEnabled)
        var entry = source
        if source.startDate >= boundary {
            guard entry.isEnabled else { return nil }
            entry.isEnabled = false
        } else {
            let dayBefore = utc.date(byAdding: .day, value: -1, to: boundary)!
            if let end = entry.endDate, end <= dayBefore { return nil }
            entry.endDate = dayBefore
        }
        try entry.update(db, columns: ["endDate", "isEnabled"])
        return ScenarioApplyJournal.Modification(entryId: source.id!, before: before, after: "")
    }

    /// A budget entry with `scenarioEntry`'s values from its first occurrence on/after
    /// `boundary` (monthly/annual keep the day-of-month anchor), plus its exceptions from
    /// there that the budget hasn't confirmed. Nil when it has no occurrence from the boundary.
    private static func create(db: Database, from scenarioEntry: ForecastEntry, groupId: Int64, boundary: Date, name: String,
                               skipped: inout [String], confirmed: (PlannedOccurrence, ForecastEntry) -> Bool) throws -> Int64? {
        let horizon = utc.date(byAdding: .day, value: 400 * max(1, scenarioEntry.interval), to: boundary)!
        guard let newStart = FrequencyExpander.occurrences(for: scenarioEntry, in: PayPeriod(startDate: boundary, endDate: horizon, type: .projected)).first
        else { return nil }

        var entry = scenarioEntry
        entry.id = nil
        entry.groupId = groupId
        entry.status = .manual
        entry.scenarioId = nil
        entry.sourceEntryId = nil
        entry.scenarioChange = nil
        if newStart != scenarioEntry.startDate {
            entry.startDate = newStart
            if [.monthly, .annually].contains(scenarioEntry.frequency) {
                let anchor = scenarioEntry.anchorDay ?? utc.component(.day, from: scenarioEntry.startDate)
                entry.anchorDay = anchor == utc.component(.day, from: newStart) ? nil : anchor
            }
        }
        try entry.insert(db)

        let exceptions = try PlannedOccurrenceException
            .filter(Column("entryId") == scenarioEntry.id! && Column("originalDate") >= newStart)
            .order(Column("originalDate"))
            .fetchAll(db)
        for var exception in exceptions {
            let probe = PayPeriod(startDate: exception.originalDate, endDate: exception.originalDate, type: .projected)
            guard FrequencyExpander.occurrences(for: entry, in: probe).contains(exception.originalDate) else { continue }
            let occurrence = PlannedOccurrence(entryId: entry.id!, originalDate: exception.originalDate, date: exception.date ?? exception.originalDate,
                                               categoryId: exception.categoryId ?? entry.categoryId,
                                               amountMinorUnits: exception.amountMinorUnits ?? entry.amountMinorUnits, isException: true)
            if confirmed(occurrence, entry) {
                skipped.append("\(name): the \(day(exception.originalDate)) edit wasn't applied (already confirmed in the budget)")
                continue
            }
            exception.id = nil
            exception.entryId = entry.id!
            try exception.insert(db)
        }
        return entry.id
    }

    /// Every stored field of the entry and of its exceptions; nil when the entry is gone.
    private static func fingerprint(db: Database, entryId: Int64) throws -> String? {
        guard let e = try ForecastEntry.fetchOne(db, key: entryId) else { return nil }
        func d(_ date: Date?) -> String { date.map { "\($0.timeIntervalSince1970)" } ?? "-" }
        var parts = ["\(e.groupId)", "\(e.categoryId)", "\(e.amountMinorUnits)", e.frequency.rawValue, "\(e.interval)", d(e.startDate), d(e.endDate),
                     "\(e.isEnabled)", e.status.rawValue, e.note ?? "-", e.anchorDay.map(String.init) ?? "-"]
        for x in try PlannedOccurrenceException.filter(Column("entryId") == entryId).order(Column("originalDate")).fetchAll(db) {
            parts.append("[\(d(x.originalDate))|\(x.isSkipped)|\(x.amountMinorUnits.map(String.init) ?? "-")|\(d(x.date))|\(x.categoryId.map(String.init) ?? "-")]")
        }
        return parts.joined(separator: "|")
    }

    private static func encode(_ journal: ScenarioApplyJournal) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(journal), as: UTF8.self)
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
