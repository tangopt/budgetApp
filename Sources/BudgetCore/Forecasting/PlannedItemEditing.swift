import Foundation
import GRDB

/// What an edit changes on an occurrence (or on it and all following). `nil` = unchanged.
public struct OccurrenceChange: Equatable {
    public var amountMinorUnits: Int?
    public var date: Date?
    public var categoryId: Int64?
    /// Series-level: only `editFollowing` accepts a frequency or interval change.
    public var frequency: ForecastFrequency?
    public var interval: Int?
    /// Series-level, `editFollowing` only: nil leaves the end as it is, `.some(nil)` removes it,
    /// `.some(date)` sets it.
    public var endDate: Date??
    /// Skip this occurrence (`editOccurrence`) or end the series here (`editFollowing`).
    public var remove: Bool = false

    public init(amountMinorUnits: Int? = nil, date: Date? = nil, categoryId: Int64? = nil, frequency: ForecastFrequency? = nil, interval: Int? = nil, endDate: Date?? = nil, remove: Bool = false) {
        self.amountMinorUnits = amountMinorUnits
        self.date = date
        self.categoryId = categoryId
        self.frequency = frequency
        self.interval = interval
        self.endDate = endDate
        self.remove = remove
    }
}

public enum PlannedItemEditError: Error, Equatable {
    /// The occurrence's pay month is closed, or actuals already cover its category's plan.
    case occurrenceConfirmed
    /// The new date falls in a closed pay month, or past a neighbouring occurrence of the
    /// series (only this occurrence: strictly between the previous and next; this and all
    /// following: strictly after the previous).
    case invalidDate
    /// An interval below 1.
    case invalidInterval
    /// A frequency/interval/end-date change applies to the series: use `editFollowing`.
    case frequencyNeedsFollowing
    /// No such planned item (an enabled, non-hypothetical entry in an enabled group, as
    /// `ForecastCalculator.planEntries` — budget or scenario, not a `removed` tombstone), or
    /// `originalDate` isn't one of its occurrences.
    case notFound
}

/// Edits to planned items, Outlook-series style (spec 2026-10-07-budget-plan-design.md,
/// "Editing operations"). An occurrence is identified by `(entryId, originalDate)`, where
/// `originalDate` is the date the series generates (`FrequencyExpander`), never a moved date.
/// Each operation runs in its own savepoint: a thrown error leaves the database untouched.
///
/// Scenario entries (spec 2026-10-08-scenario-lab-design.md, "Operations") are edited the same
/// way, scoped by the edited entry: an edit only ever touches entries of the entry's own scope
/// (the budget, or its scenario). In a scenario only closed pay months are confirmed (actuals
/// don't confirm an open month), category flags are never set, and edits set change markers:
/// an unchanged copy becomes `changed`; a split's new entry is `added` (or, replacing a copy
/// from its first occurrence, the copy's `changed` successor with its `sourceEntryId`); and
/// removing a copy from its first occurrence leaves a disabled `removed` tombstone.
public enum PlannedItemEditing {
    private static let utc = MonthRange.calendar

    /// Only this occurrence: upserts its exception (amount, date, category, skip). Changing a
    /// value without `remove` also un-skips a skipped occurrence. An exception left with no
    /// effect is removed. A legacy `.auto` series (a database from before the migration that
    /// made detected items `.manual`) becomes `.manual`.
    public static func editOccurrence(db: Database, entryId: Int64, originalDate: Date, change: OccurrenceChange, calendar: PayCalendar) throws {
        try db.inSavepoint {
            var entry = try plannedEntry(db: db, id: entryId, originalDate: originalDate)
            if let interval = change.interval, interval < 1 { throw PlannedItemEditError.invalidInterval }
            if let frequency = change.frequency, frequency != entry.frequency { throw PlannedItemEditError.frequencyNeedsFollowing }
            if let interval = change.interval, interval != entry.interval { throw PlannedItemEditError.frequencyNeedsFollowing }
            if change.endDate != nil { throw PlannedItemEditError.frequencyNeedsFollowing }
            let existing = try exception(db: db, entryId: entryId, originalDate: originalDate)
            try requireUnconfirmed(db: db, entry: entry, originalDate: originalDate, existing: existing, calendar: calendar)
            if !change.remove, let date = change.date {
                try requireOpen(date, calendar: calendar)
                let (previous, next) = neighbours(of: originalDate, in: entry)
                if let previous, date <= previous { throw PlannedItemEditError.invalidDate }
                if let next, date >= next { throw PlannedItemEditError.invalidDate }
            }

            var updated = existing ?? PlannedOccurrenceException(entryId: entryId, originalDate: originalDate)
            if change.remove {
                updated.isSkipped = true
            } else if change.amountMinorUnits != nil || change.date != nil || change.categoryId != nil {
                updated.isSkipped = false // editing a skipped occurrence brings it back
            }
            if let amount = change.amountMinorUnits { updated.amountMinorUnits = amount == entry.amountMinorUnits ? nil : amount }
            if let date = change.date { updated.date = date == originalDate ? nil : date }
            if let categoryId = change.categoryId { updated.categoryId = categoryId == entry.categoryId ? nil : categoryId }
            try save(db: db, &updated)

            try makeManual(db: db, &entry)
            try markChanged(db: db, &entry)
            return .commit
        }
    }

    /// This and all following: splits the series at `originalDate`. The original ends the day
    /// before (or is deleted when `originalDate` is its first occurrence); unless the change
    /// removes all following, a new `.manual` entry in the same group (note kept) starts at
    /// `originalDate` — or the moved date, which must be after the previous occurrence — with
    /// the changes applied. Between monthly/annual schedules the new series keeps the original's
    /// anchor day (so a split at 28 Feb of a series on the 31st still gives 31 Mar), unless the
    /// date moves; otherwise (date move, or to/from weekly or once) the new start's day applies. Exceptions after `originalDate` move to the new entry with the same keys,
    /// unless a date move or frequency change shifts the schedule, in which case they are
    /// dropped. The edited occurrence's own exception follows the new entry minus the fields
    /// the change sets, and un-skipped (the edit brings the occurrence back). Removing from
    /// the first occurrence deletes the whole series and, unless it is a one-off (`.once`),
    /// also sets the category's `excludeFromAutoForecast`, so auto-forecast detection doesn't
    /// add it straight back.
    public static func editFollowing(db: Database, entryId: Int64, originalDate: Date, change: OccurrenceChange, calendar: PayCalendar) throws {
        try db.inSavepoint {
            var entry = try plannedEntry(db: db, id: entryId, originalDate: originalDate)
            if let interval = change.interval, interval < 1 { throw PlannedItemEditError.invalidInterval }
            let existing = try exception(db: db, entryId: entryId, originalDate: originalDate)
            try requireUnconfirmed(db: db, entry: entry, originalDate: originalDate, existing: existing, calendar: calendar)
            let previous = neighbours(of: originalDate, in: entry).previous
            if !change.remove, let date = change.date {
                try requireOpen(date, calendar: calendar)
                if let previous, date <= previous { throw PlannedItemEditError.invalidDate }
            }

            let later = try PlannedOccurrenceException
                .filter(Column("entryId") == entryId && Column("originalDate") > originalDate)
                .order(Column("originalDate"))
                .fetchAll(db)

            if change.remove {
                if let existing { _ = try existing.delete(db) }
                for exception in later { _ = try exception.delete(db) }
            } else {
                let newStart = change.date ?? originalDate
                let frequency = change.frequency ?? entry.frequency
                let interval = change.interval ?? entry.interval
                let endDate = change.endDate ?? entry.endDate
                if let endDate, endDate < newStart { throw PlannedItemEditError.invalidDate }
                let shifted = newStart != originalDate || frequency != entry.frequency || interval != entry.interval
                var newEntry = ForecastEntry(groupId: entry.groupId, categoryId: change.categoryId ?? entry.categoryId,
                                             amountMinorUnits: change.amountMinorUnits ?? entry.amountMinorUnits,
                                             frequency: frequency, interval: interval, startDate: newStart, endDate: endDate,
                                             isEnabled: entry.isEnabled, status: .manual, note: entry.note,
                                             scenarioId: entry.scenarioId)
                if entry.scenarioId != nil {
                    // From a copy's first occurrence the new entry replaces the copy, so it
                    // inherits its source; otherwise it's a new series of the scenario.
                    let replacesCopy = previous == nil && entry.sourceEntryId != nil && entry.scenarioChange != .added
                    newEntry.sourceEntryId = replacesCopy ? entry.sourceEntryId : nil
                    newEntry.scenarioChange = replacesCopy ? .changed : .added
                }
                // Inherit the day-of-month anchor only between day-of-month schedules (monthly /
                // annual); a weekly series never used one, so the new start's day applies.
                let dayOfMonth: Set<ForecastFrequency> = [.monthly, .annually]
                if change.date == nil, dayOfMonth.contains(entry.frequency), dayOfMonth.contains(frequency) {
                    let anchor = entry.anchorDay ?? utc.component(.day, from: entry.startDate)
                    newEntry.anchorDay = anchor == utc.component(.day, from: newStart) ? nil : anchor
                }
                try newEntry.insert(db)
                let newId = newEntry.id!

                if var own = existing {
                    own.entryId = newId
                    own.originalDate = newStart
                    own.isSkipped = false
                    if change.amountMinorUnits != nil { own.amountMinorUnits = nil }
                    if change.categoryId != nil { own.categoryId = nil }
                    if change.date != nil { own.date = nil }
                    try save(db: db, &own)
                }

                if shifted || later.isEmpty {
                    for exception in later { _ = try exception.delete(db) }
                } else {
                    // Same schedule and anchor: the new series generates the same dates, so
                    // the keys stay; anything it doesn't generate (defensive) is dropped.
                    for var exception in later {
                        let probe = PayPeriod(startDate: exception.originalDate, endDate: exception.originalDate, type: .projected)
                        guard FrequencyExpander.occurrences(for: newEntry, in: probe).contains(exception.originalDate) else {
                            _ = try exception.delete(db)
                            continue
                        }
                        exception.entryId = newId
                        try exception.update(db)
                    }
                }
            }

            if previous == nil, change.remove, entry.scenarioId != nil, entry.sourceEntryId != nil, entry.scenarioChange != .added {
                // A copy removed outright stays as a tombstone, so Refresh and Apply know the
                // scenario removes its budget source.
                entry.isEnabled = false
                entry.scenarioChange = .removed
                try entry.update(db)
            } else if previous == nil {
                _ = try entry.delete(db) // first occurrence: the new entry (if any) replaces the series
                if change.remove && entry.frequency != .once && entry.scenarioId == nil {
                    // The series is gone outright: stop detection re-adding it. A one-off
                    // (e.g. a bonus) says nothing about the category's pattern.
                    try db.execute(sql: "UPDATE category SET excludeFromAutoForecast = 1 WHERE id = ?", arguments: [entry.categoryId])
                }
            } else {
                entry.endDate = utc.date(byAdding: .day, value: -1, to: originalDate)!
                if entry.status == .auto { entry.status = .manual } // legacy (pre-migration) `.auto` row
                if entry.scenarioId != nil && entry.scenarioChange == nil { entry.scenarioChange = .changed }
                try entry.update(db)
            }
            return .commit
        }
    }

    /// Whether an occurrence is confirmed (and so can't be edited): it belongs to the calendar
    /// month named on its (possibly moved) date, whose pay month (`PayMonth(year:month:)`) is
    /// closed; or its (possibly re-filed) category's pay-month actual for that month already
    /// covers the category's planned total for the calendar month (`PlanStatus` envelope:
    /// expense spend ≥ plan, income ≥ plan, transfers by the plan's sign). A month with no
    /// plan in a direction leaves the occurrence unconfirmed until the month closes.
    public static func isConfirmed(entry: ForecastEntry, occurrence: PlannedOccurrence, calendar: PayCalendar, monthTotals: [Int64: [Int: [Int: Int]]], entries: [ForecastEntry], groups: [ForecastGroup], exceptions: [PlannedOccurrenceException], categories: [Category]) -> Bool {
        let (year, month) = MonthRange.components(of: occurrence.date)
        if calendar.isClosed(PayMonth(year: year, month: month)) { return true }
        let type = categories.first { $0.id == occurrence.categoryId }?.type
            ?? categories.first { $0.id == entry.categoryId }?.type
            ?? .expense
        let range = MonthRange.of(year: year, month: month)
        let planned = ForecastCalculator.confirmedTotal(categoryId: occurrence.categoryId,
                                                        period: PayPeriod(startDate: range.start, endDate: range.end, type: .projected),
                                                        entries: entries, groups: groups, exceptions: exceptions)
        let actual = monthTotals[occurrence.categoryId]?[year]?[month] ?? 0
        let open = PlanStatus.cell(actual: actual, planned: planned, categoryType: type, monthClass: .blended)
        let hasPlan = PlanStatus.cell(actual: 0, planned: planned, categoryType: type, monthClass: .blended).pending != 0
        return hasPlan && open.pending == 0
    }

    /// Whether an occurrence can no longer be edited, by its entry's scope (the same rule
    /// `editOccurrence` / `editFollowing` enforce): a budget occurrence when `isConfirmed`; a
    /// scenario occurrence only when the calendar month named on its date has a closed pay
    /// month (a scenario has no confirmation restriction for open months). `entries`,
    /// `groups` and `exceptions` are the budget's (a scenario occurrence doesn't read them).
    public static func isLocked(entry: ForecastEntry, occurrence: PlannedOccurrence, calendar: PayCalendar, monthTotals: [Int64: [Int: [Int: Int]]], entries: [ForecastEntry], groups: [ForecastGroup], exceptions: [PlannedOccurrenceException], categories: [Category]) -> Bool {
        guard entry.scenarioId != nil else {
            return isConfirmed(entry: entry, occurrence: occurrence, calendar: calendar, monthTotals: monthTotals, entries: entries, groups: groups, exceptions: exceptions, categories: categories)
        }
        let (year, month) = MonthRange.components(of: occurrence.date)
        return calendar.isClosed(PayMonth(year: year, month: month))
    }

    // MARK: - Helpers

    /// The planned item (per `ForecastCalculator.planEntries`: enabled, not hypothetical, not a
    /// scenario tombstone, in an enabled group — budget or scenario) whose series generates
    /// `originalDate`.
    private static func plannedEntry(db: Database, id: Int64, originalDate: Date) throws -> ForecastEntry {
        guard let entry = try ForecastEntry.fetchOne(db, key: id),
              !ForecastCalculator.planEntries(entries: [entry], groups: try ForecastGroup.filter(key: entry.groupId).fetchAll(db)).isEmpty
        else { throw PlannedItemEditError.notFound }
        let probe = PayPeriod(startDate: originalDate, endDate: originalDate, type: .projected)
        guard FrequencyExpander.occurrences(for: entry, in: probe).contains(originalDate) else { throw PlannedItemEditError.notFound }
        return entry
    }

    /// The series' generated occurrences either side of `originalDate` (nil at either end).
    private static func neighbours(of originalDate: Date, in entry: ForecastEntry) -> (previous: Date?, next: Date?) {
        let before = FrequencyExpander.occurrences(for: entry, in: PayPeriod(startDate: entry.startDate, endDate: originalDate.addingTimeInterval(-1), type: .projected))
        // One step of any frequency is under 400 days per unit of interval.
        let horizon = utc.date(byAdding: .day, value: 400 * max(1, entry.interval), to: originalDate)!
        let after = FrequencyExpander.occurrences(for: entry, in: PayPeriod(startDate: originalDate.addingTimeInterval(1), endDate: horizon, type: .projected))
        return (before.last, after.first)
    }

    private static func exception(db: Database, entryId: Int64, originalDate: Date) throws -> PlannedOccurrenceException? {
        try PlannedOccurrenceException.filter(Column("entryId") == entryId && Column("originalDate") == originalDate).fetchOne(db)
    }

    private static func requireUnconfirmed(db: Database, entry: ForecastEntry, originalDate: Date, existing: PlannedOccurrenceException?, calendar: PayCalendar) throws {
        let occurrence = PlannedOccurrence(entryId: entry.id!, originalDate: originalDate, date: existing?.date ?? originalDate,
                                           categoryId: existing?.categoryId ?? entry.categoryId,
                                           amountMinorUnits: existing?.amountMinorUnits ?? entry.amountMinorUnits,
                                           isException: existing != nil)
        let (year, month) = MonthRange.components(of: occurrence.date)
        if entry.scenarioId != nil {
            // A scenario has no confirmation restriction for open months; closed ones stay closed.
            if calendar.isClosed(PayMonth(year: year, month: month)) { throw PlannedItemEditError.occurrenceConfirmed }
            return
        }
        let payRange = calendar.range(of: PayMonth(year: year, month: month))
        let transactions = try Transaction
            .filter(Column("date") >= payRange.start && Column("date") <= payRange.end && Column("status") == TransactionStatus.confirmed.rawValue)
            .fetchAll(db)
        let confirmed = isConfirmed(entry: entry, occurrence: occurrence, calendar: calendar,
                                    monthTotals: PayMonthTotals.lookup(transactions: transactions, calendar: calendar),
                                    entries: try ForecastEntry.budget(db), groups: try ForecastGroup.fetchAll(db),
                                    exceptions: try PlannedOccurrenceException.fetchAll(db), categories: try Category.fetchAll(db))
        if confirmed { throw PlannedItemEditError.occurrenceConfirmed }
    }

    /// A date may only land in a calendar month whose pay month is still open.
    private static func requireOpen(_ date: Date, calendar: PayCalendar) throws {
        let (year, month) = MonthRange.components(of: date)
        if calendar.isClosed(PayMonth(year: year, month: month)) { throw PlannedItemEditError.invalidDate }
    }

    /// Inserts or updates the exception, or deletes it when it no longer changes anything.
    private static func save(db: Database, _ exception: inout PlannedOccurrenceException) throws {
        let hasEffect = exception.isSkipped || exception.amountMinorUnits != nil || exception.date != nil || exception.categoryId != nil
        if hasEffect {
            try exception.save(db)
        } else if exception.id != nil {
            _ = try exception.delete(db)
        }
    }

    /// A scenario's unchanged copy becomes `changed` once edited.
    private static func markChanged(db: Database, _ entry: inout ForecastEntry) throws {
        guard entry.scenarioId != nil, entry.scenarioChange == nil else { return }
        entry.scenarioChange = .changed
        try entry.update(db)
    }

    /// Legacy: only databases not yet migrated still hold `.auto` entries (the migration in
    /// `PlannedOccurrenceException` turns them `.manual`); kept for those.
    private static func makeManual(db: Database, _ entry: inout ForecastEntry) throws {
        guard entry.status == .auto else { return }
        entry.status = .manual
        try entry.update(db)
    }
}
