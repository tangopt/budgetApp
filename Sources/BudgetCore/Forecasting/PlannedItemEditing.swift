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
    /// Skip this occurrence (`editOccurrence`) or end the series here (`editFollowing`).
    public var remove: Bool = false

    public init(amountMinorUnits: Int? = nil, date: Date? = nil, categoryId: Int64? = nil, frequency: ForecastFrequency? = nil, interval: Int? = nil, remove: Bool = false) {
        self.amountMinorUnits = amountMinorUnits
        self.date = date
        self.categoryId = categoryId
        self.frequency = frequency
        self.interval = interval
        self.remove = remove
    }
}

public enum PlannedItemEditError: Error, Equatable {
    /// The occurrence's pay month is closed, or actuals already cover its category's plan.
    case occurrenceConfirmed
    /// The new date falls in a closed pay month.
    case invalidDate
    /// A frequency/interval change applies to the series: use `editFollowing`.
    case frequencyNeedsFollowing
    /// No such planned item, or `originalDate` isn't one of its occurrences.
    case notFound
}

/// Edits to planned items, Outlook-series style (spec 2026-10-07-budget-plan-design.md,
/// "Editing operations"). An occurrence is identified by `(entryId, originalDate)`, where
/// `originalDate` is the date the series generates (`FrequencyExpander`), never a moved date.
/// Each operation runs in its own savepoint: a thrown error leaves the database untouched.
public enum PlannedItemEditing {
    private static let utc = MonthRange.calendar

    /// Only this occurrence: upserts its exception (amount, date, category, skip). An exception
    /// left with no effect is removed. A `.auto` series becomes `.manual`.
    public static func editOccurrence(db: Database, entryId: Int64, originalDate: Date, change: OccurrenceChange, calendar: PayCalendar) throws {
        try db.inSavepoint {
            var entry = try plannedEntry(db: db, id: entryId, originalDate: originalDate)
            if let frequency = change.frequency, frequency != entry.frequency { throw PlannedItemEditError.frequencyNeedsFollowing }
            if let interval = change.interval, interval != entry.interval { throw PlannedItemEditError.frequencyNeedsFollowing }
            let existing = try exception(db: db, entryId: entryId, originalDate: originalDate)
            try requireUnconfirmed(db: db, entry: entry, originalDate: originalDate, existing: existing, calendar: calendar)
            if !change.remove, let date = change.date { try requireOpen(date, calendar: calendar) }

            var updated = existing ?? PlannedOccurrenceException(entryId: entryId, originalDate: originalDate)
            if change.remove { updated.isSkipped = true }
            if let amount = change.amountMinorUnits { updated.amountMinorUnits = amount == entry.amountMinorUnits ? nil : amount }
            if let date = change.date { updated.date = date == originalDate ? nil : date }
            if let categoryId = change.categoryId { updated.categoryId = categoryId == entry.categoryId ? nil : categoryId }
            try save(db: db, &updated)

            try makeManual(db: db, &entry)
            return .commit
        }
    }

    /// This and all following: splits the series at `originalDate`. The original ends the day
    /// before (or is deleted when `originalDate` is its first occurrence); unless the change
    /// removes all following, a new `.manual` entry in the same group (note kept) starts at
    /// `originalDate` — or the moved date — with the changes applied. Exceptions after
    /// `originalDate` move to the new entry, re-keyed to its occurrence dates, unless a date
    /// move or frequency change shifts the schedule, in which case they are dropped. The edited
    /// occurrence's own exception follows the new entry minus the fields the change sets.
    public static func editFollowing(db: Database, entryId: Int64, originalDate: Date, change: OccurrenceChange, calendar: PayCalendar) throws {
        try db.inSavepoint {
            var entry = try plannedEntry(db: db, id: entryId, originalDate: originalDate)
            let existing = try exception(db: db, entryId: entryId, originalDate: originalDate)
            try requireUnconfirmed(db: db, entry: entry, originalDate: originalDate, existing: existing, calendar: calendar)
            if !change.remove, let date = change.date { try requireOpen(date, calendar: calendar) }

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
                let shifted = newStart != originalDate || frequency != entry.frequency || interval != entry.interval
                var newEntry = ForecastEntry(groupId: entry.groupId, categoryId: change.categoryId ?? entry.categoryId,
                                             amountMinorUnits: change.amountMinorUnits ?? entry.amountMinorUnits,
                                             frequency: frequency, interval: interval, startDate: newStart, endDate: entry.endDate,
                                             isEnabled: entry.isEnabled, status: .manual, note: entry.note)
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
                    // Same schedule, new anchor: map each exception by its position in the old
                    // series to the new series' date at that position (month-end anchors can
                    // differ, e.g. 31 Dec from a 31 Oct start vs 30 Dec from 30 Nov).
                    let last = later.last!.originalDate
                    let oldDates = FrequencyExpander.occurrences(for: entry, in: PayPeriod(startDate: originalDate, endDate: last, type: .projected))
                    let horizon = utc.date(byAdding: .year, value: 1, to: last)!
                    let newDates = FrequencyExpander.occurrences(for: newEntry, in: PayPeriod(startDate: newStart, endDate: horizon, type: .projected))
                    for var exception in later {
                        guard let index = oldDates.firstIndex(of: exception.originalDate), index < newDates.count else {
                            _ = try exception.delete(db)
                            continue
                        }
                        exception.entryId = newId
                        exception.originalDate = newDates[index]
                        try exception.update(db)
                    }
                }
            }

            if originalDate == entry.startDate {
                _ = try entry.delete(db) // first occurrence: the new entry (if any) replaces the series
            } else {
                entry.endDate = utc.date(byAdding: .day, value: -1, to: originalDate)!
                if entry.status == .auto { entry.status = .manual }
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

    // MARK: - Helpers

    /// The planned item (never a hypothetical scenario entry) whose series generates `originalDate`.
    private static func plannedEntry(db: Database, id: Int64, originalDate: Date) throws -> ForecastEntry {
        guard let entry = try ForecastEntry.fetchOne(db, key: id), entry.status != .hypothetical else { throw PlannedItemEditError.notFound }
        let probe = PayPeriod(startDate: originalDate, endDate: originalDate, type: .projected)
        guard FrequencyExpander.occurrences(for: entry, in: probe).contains(originalDate) else { throw PlannedItemEditError.notFound }
        return entry
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
        let payRange = calendar.range(of: PayMonth(year: year, month: month))
        let transactions = try Transaction
            .filter(Column("date") >= payRange.start && Column("date") <= payRange.end && Column("status") == TransactionStatus.confirmed.rawValue)
            .fetchAll(db)
        let confirmed = isConfirmed(entry: entry, occurrence: occurrence, calendar: calendar,
                                    monthTotals: PayMonthTotals.lookup(transactions: transactions, calendar: calendar),
                                    entries: try ForecastEntry.fetchAll(db), groups: try ForecastGroup.fetchAll(db),
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

    private static func makeManual(db: Database, _ entry: inout ForecastEntry) throws {
        guard entry.status == .auto else { return }
        entry.status = .manual
        try entry.update(db)
    }
}
