import Foundation
import GRDB

public enum OfferScenarioError: Error, Equatable {
    /// The salary entry the offer replaces ends before the offer's start month.
    case startAfterSalaryEnds
    /// No salary entry to replace (none chosen, or deleted from the budget) and no income category to add the offer in.
    case noSalaryEntryOrNewIncomeCategory
}

extension OfferScenarioError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .startAfterSalaryEnds:
            return "This salary ends in your forecast before the offer starts. Pick an earlier start month or another salary."
        case .noSalaryEntryOrNewIncomeCategory:
            return "There's no salary in your forecast to replace. Choose an income category to add the offer as new income."
        }
    }
}

/// A budget pension entry the offer can change, and how (`OfferScenarioBuilder.pensionCandidates`).
public struct OfferPensionCandidate: Equatable, Identifiable, Sendable {
    public var entry: ForecastEntry
    /// A transfer into a pension account: it becomes the offer's employee plus employer contributions. Otherwise
    /// a pension expense: it changes by the difference in the employee's contribution only.
    public var isTransfer: Bool
    public var id: Int64 { entry.id ?? 0 }

    public init(entry: ForecastEntry, isTransfer: Bool) {
        self.entry = entry
        self.isTransfer = isTransfer
    }

    /// Whether it can go with `salary`: a transfer always; an expense only in the salary's group or account.
    public func fits(salary: ForecastEntry?) -> Bool {
        if isTransfer { return true }
        guard let salary else { return false }
        return entry.groupId == salary.groupId || (entry.accountId != nil && entry.accountId == salary.accountId)
    }
}

/// A job offer as a scenario (spec 2026-10-28-step14-job-offer-forecast-design.md): a copy of the budget
/// (`Scenarios.create`) where the salary entry's copy ends the day before the start month and the offer's
/// take-home pay follows it (after any notice-period gap), the pension entry's copy changes from the start
/// (`OfferPensionCandidate`), and the one-offs are added. Every write carries the scenario's id: the budget and
/// actuals are never touched. The spec is stored in `scenario.offerInputs`.
///
/// The entries the builder adds are listed in the stored spec (`addedEntryIds`); the copies it changes are the
/// copies of the spec's budget entries (`sourceEntryId`). `rebuild` puts exactly those back and applies a new spec.
public enum OfferScenarioBuilder {
    /// Notes of the entries the builder adds start with this (wording only: `addedEntryIds` says which they are).
    public static let notePrefix = "Offer: "

    private static let utc = MonthRange.calendar

    /// A new scenario named `name` (unique: `ScenarioError.duplicateName`) holding the offer. Nothing is
    /// created when it throws.
    @discardableResult
    public static func create(db: Database, name: String, spec: OfferScenarioSpec, now: Date = Date()) throws -> Scenario {
        var scenario: Scenario!
        try db.inSavepoint {
            let plan = try resolve(db: db, spec: spec, scenarioId: nil)
            scenario = try Scenarios.create(db: db, name: name, now: now)
            var stored = plan.spec
            stored.addedEntryIds = try apply(db: db, plan: plan, scenarioId: scenario.id!)
            scenario.offerInputs = try stored.json()
            try scenario.update(db, columns: ["offerInputs"])
            return .commit
        }
        return scenario
    }

    /// "Edit offer…" saved: the scenario's offer entries are put back (added ones deleted, changed copies
    /// re-copied from their budget source) and `spec` applied in their place. The scenario's id, name and
    /// every other entry are kept.
    public static func rebuild(db: Database, scenarioId: Int64, spec: OfferScenarioSpec) throws {
        try db.inSavepoint {
            guard var scenario = try Scenario.fetchOne(db, key: scenarioId) else { throw ScenarioError.notFound }
            let plan = try resolve(db: db, spec: spec, scenarioId: scenarioId)
            let previous = scenario.offerInputs.flatMap(OfferScenarioSpec.decode)
            let added = Set(previous?.addedEntryIds ?? [])
            for entry in try ForecastEntry.inScenario(db, id: scenarioId) {
                // A spec stored before the ids were kept: its entries are the ones with the builder's note.
                let isOffers = added.isEmpty ? entry.note?.hasPrefix(notePrefix) == true : entry.id.map(added.contains) == true
                if entry.scenarioChange == .added, isOffers {
                    _ = try entry.delete(db)
                } else if let previous, entry.scenarioChange == .changed || entry.scenarioChange == .removed,
                          let source = entry.sourceEntryId, source == previous.salaryEntryId || source == previous.pensionEntryId {
                    try Scenarios.revert(db: db, scenarioId: scenarioId, entryId: entry.id!)
                }
            }
            var stored = plan.spec
            stored.addedEntryIds = try apply(db: db, plan: plan, scenarioId: scenarioId)
            scenario.offerInputs = try stored.json()
            try scenario.update(db, columns: ["offerInputs"])
            return .commit
        }
    }

    /// The spec a scenario was built from; nil for a scenario that isn't a job offer.
    public static func spec(db: Database, scenarioId: Int64) throws -> OfferScenarioSpec? {
        try Scenario.fetchOne(db, key: scenarioId)?.offerInputs.flatMap(OfferScenarioSpec.decode)
    }

    /// The budget entries an offer can replace: enabled monthly income entries, the most recent start first.
    public static func salaryCandidates(db: Database) throws -> [ForecastEntry] {
        try ForecastEntry.fetchAll(db, sql: """
            SELECT forecastEntry.* FROM forecastEntry JOIN category ON category.id = forecastEntry.categoryId
            WHERE forecastEntry.scenarioId IS NULL AND forecastEntry.isEnabled = 1
              AND forecastEntry.frequency = ? AND category.type = ?
            ORDER BY forecastEntry.startDate DESC, forecastEntry.id DESC
            """, arguments: [ForecastFrequency.monthly.rawValue, CategoryType.income.rawValue])
    }

    /// The budget pension entries an offer can change: enabled monthly outgoings that are either a transfer into
    /// a pension account (an account whose name says "pension") or a pension expense (category name). Which
    /// expense fits a salary is `OfferPensionCandidate.fits`. Most recent start first.
    public static func pensionCandidates(db: Database) throws -> [OfferPensionCandidate] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT forecastEntry.id AS entryId, category.type AS categoryType, category.name AS categoryName,
                   account.name AS accountName
            FROM forecastEntry JOIN category ON category.id = forecastEntry.categoryId
            LEFT JOIN account ON account.id = category.transferAccountId
            WHERE forecastEntry.scenarioId IS NULL AND forecastEntry.isEnabled = 1 AND forecastEntry.frequency = ?
              AND forecastEntry.amountMinorUnits < 0
            ORDER BY forecastEntry.startDate DESC, forecastEntry.id DESC
            """, arguments: [ForecastFrequency.monthly.rawValue])
        var result: [OfferPensionCandidate] = []
        for row in rows {
            let type: String = row["categoryType"]
            let isTransfer: Bool
            if type == CategoryType.transfer.rawValue, let account: String = row["accountName"], account.localizedCaseInsensitiveContains("pension") {
                isTransfer = true
            } else if type == CategoryType.expense.rawValue, (row["categoryName"] as String).localizedCaseInsensitiveContains("pension") {
                isTransfer = false
            } else {
                continue
            }
            guard let entry = try ForecastEntry.fetchOne(db, key: row["entryId"] as Int64) else { continue }
            result.append(OfferPensionCandidate(entry: entry, isTransfer: isTransfer))
        }
        return result
    }

    /// Whether `entry` is a transfer into a pension account (its category is linked to an account named "pension").
    private static func isPensionTransfer(db: Database, _ entry: ForecastEntry) throws -> Bool {
        guard let category = try Category.fetchOne(db, key: entry.categoryId), category.type == .transfer,
              let accountId = category.transferAccountId, let account = try Account.fetchOne(db, key: accountId) else { return false }
        return account.name.localizedCaseInsensitiveContains("pension")
    }

    // MARK: - Plan

    /// What `apply` writes, worked out (and checked) before anything is written.
    private struct Plan {
        var spec: OfferScenarioSpec
        /// The budget salary entry, when it still exists.
        var salary: ForecastEntry?
        var pension: ForecastEntry?
        var incomeCategoryId: Int64
        /// The group and account the new entries go in: the salary's, else the Planned group / Automatic.
        var groupId: Int64?
        var accountId: Int64?
        var anchorDay: Int?
        var startMonth: Date
        var offerStart: Date
        var takeHomeMonthly: Int
        /// A transfer into a pension account: the offer's employee plus employer pension a month.
        var pensionTransferMonthly: Int
        /// A pension expense: how much more (or less) the employee pays a month with the offer.
        var employeePensionChangeMonthly: Int
        var pensionIsTransfer: Bool

        /// The pension entry's new amount from `amount` (its sign kept; an expense that would cross zero stops at 0).
        func pensionAmount(from amount: Int) -> Int {
            let sign = amount < 0 ? -1 : 1
            if pensionIsTransfer { return sign * pensionTransferMonthly }
            return sign * max(0, abs(amount) + employeePensionChangeMonthly)
        }
    }

    private static func resolve(db: Database, spec input: OfferScenarioSpec, scenarioId: Int64?) throws -> Plan {
        var spec = input
        spec.startMonth = firstOfMonth(spec.startMonth)
        spec.noticeGapMonths = max(0, spec.noticeGapMonths)
        spec.oneOffs = spec.oneOffs.map { var oneOff = $0; oneOff.month = firstOfMonth(oneOff.month); return oneOff }

        let salary = try spec.salaryEntryId.flatMap { try ForecastEntry.budgetEntries.filter(key: $0).fetchOne(db) }
        if let salary, let end = salary.endDate, end < spec.startMonth { throw OfferScenarioError.startAfterSalaryEnds }
        let pension = try spec.pensionEntryId.flatMap { try ForecastEntry.budgetEntries.filter(key: $0).fetchOne(db) }

        let categoryId: Int64
        if let salary {
            categoryId = salary.categoryId
        } else if let id = spec.newIncomeCategoryId, let category = try Category.fetchOne(db, key: id), category.type == .income {
            categoryId = id
        } else if let scenarioId, let earlier = try previousOfferSalary(db: db, scenarioId: scenarioId) {
            // "Edit offer…" after the salary entry left the budget: the offer stays where it was.
            categoryId = earlier.categoryId
        } else {
            throw OfferScenarioError.noSalaryEntryOrNewIncomeCategory
        }

        let offer = SalaryCalculator.calculate(spec.offer)
        let current = SalaryCalculator.calculate(spec.current)
        let pensionIsTransfer = try pension.map { try isPensionTransfer(db: db, $0) } ?? false
        let offerStart = utc.date(byAdding: .month, value: spec.noticeGapMonths, to: spec.startMonth)!
        let salaryAnchor = salary.map { $0.anchorDay ?? utc.component(.day, from: $0.startDate) }
        return Plan(spec: spec, salary: salary, pension: pension, incomeCategoryId: categoryId,
                    groupId: salary?.groupId, accountId: salary?.accountId,
                    anchorDay: salaryAnchor == 1 ? nil : salaryAnchor,
                    startMonth: spec.startMonth, offerStart: offerStart, takeHomeMonthly: offer.takeHomeMonthly,
                    pensionTransferMonthly: SalaryCalculator.roundHalfUp(offer.employeePension + offer.employerPension, 12),
                    employeePensionChangeMonthly: SalaryCalculator.roundHalfUp(offer.employeePension, 12)
                        - SalaryCalculator.roundHalfUp(current.employeePension, 12),
                    pensionIsTransfer: pensionIsTransfer)
    }

    /// The offer salary an earlier build of this scenario added (the first of its added entries), if any.
    private static func previousOfferSalary(db: Database, scenarioId: Int64) throws -> ForecastEntry? {
        guard let first = try spec(db: db, scenarioId: scenarioId)?.addedEntryIds.first else {
            return try ForecastEntry.inScenario(db, id: scenarioId).first { $0.scenarioChange == .added && $0.note == salaryNote }
        }
        return try ForecastEntry.fetchOne(db, key: first).flatMap { $0.scenarioId == scenarioId ? $0 : nil }
    }

    private static let salaryNote = notePrefix + "salary"
    private static let pensionNote = notePrefix + "pension"

    // MARK: - Apply

    /// Writes the plan; returns the ids of the entries it added.
    private static func apply(db: Database, plan: Plan, scenarioId: Int64) throws -> [Int64] {
        var added: [Int64] = []
        // Salary: the copy ends the day before the start month (or, starting on or after it, the whole
        // series is replaced), and the offer's take-home follows after the gap.
        if let salary = plan.salary, var copy = try copy(of: salary, db: db, scenarioId: scenarioId) {
            try endOrRemove(db: db, &copy, before: plan.startMonth)
        }
        added.append(try add(db: db, scenarioId: scenarioId, categoryId: plan.incomeCategoryId, groupId: plan.groupId,
                             accountId: plan.accountId, amount: plan.takeHomeMonthly, frequency: .monthly, start: plan.offerStart,
                             anchorDay: plan.anchorDay, note: salaryNote))

        // Pension: a transfer becomes the offer's contributions, an expense moves by the employee's change.
        if let pension = plan.pension, var copy = try copy(of: pension, db: db, scenarioId: scenarioId),
           copy.endDate.map({ $0 >= plan.startMonth }) ?? true {
            let amount = plan.pensionAmount(from: copy.amountMinorUnits)
            if copy.startDate >= plan.startMonth {
                // Starts within the new job: the copy itself takes the new amount (from the offer's salary on).
                try dropExceptions(db: db, entryId: copy.id!, from: plan.startMonth)
                copy.amountMinorUnits = amount
                if copy.startDate < plan.offerStart {
                    copy.anchorDay = copy.anchorDay ?? utc.component(.day, from: copy.startDate)
                    copy.startDate = plan.offerStart
                    if copy.anchorDay == 1 { copy.anchorDay = nil }
                }
                copy.scenarioChange = .changed
                try copy.update(db)
            } else {
                try endOrRemove(db: db, &copy, before: plan.startMonth)
                if amount != 0 {
                    let anchor = pension.anchorDay ?? utc.component(.day, from: pension.startDate)
                    added.append(try add(db: db, scenarioId: scenarioId, categoryId: copy.categoryId, groupId: copy.groupId,
                                         accountId: copy.accountId, amount: amount, frequency: copy.frequency, start: plan.offerStart,
                                         anchorDay: anchor == 1 ? nil : anchor, note: pensionNote, interval: copy.interval))
                }
            }
        }

        for oneOff in plan.spec.oneOffs {
            added.append(try add(db: db, scenarioId: scenarioId, categoryId: plan.incomeCategoryId, groupId: plan.groupId,
                                 accountId: plan.accountId, amount: oneOff.amountMinorUnits, frequency: .once, start: oneOff.month,
                                 anchorDay: nil, note: notePrefix + oneOff.label))
        }
        return added
    }

    /// The scenario's copy of a budget entry: its unchanged copy if any, else a changed one; nil when the
    /// scenario has none (a budget entry added since and not yet refreshed in) or removes it.
    private static func copy(of entry: ForecastEntry, db: Database, scenarioId: Int64) throws -> ForecastEntry? {
        let copies = try ForecastEntry.inScenario(db, id: scenarioId).filter { $0.sourceEntryId == entry.id && $0.scenarioChange != .added }
        return copies.first { $0.scenarioChange == nil } ?? copies.first { $0.scenarioChange == .changed }
    }

    /// Ends `copy` the day before `month` (marked `changed`), or, when it doesn't start before `month`,
    /// leaves it as a disabled `removed` tombstone, as `PlannedItemEditing.editFollowing` does. Its
    /// exceptions from `month` on go with the series they belonged to.
    private static func endOrRemove(db: Database, _ copy: inout ForecastEntry, before month: Date) throws {
        try dropExceptions(db: db, entryId: copy.id!, from: month)
        if copy.startDate >= month {
            copy.isEnabled = false
            copy.scenarioChange = .removed
        } else {
            let dayBefore = utc.date(byAdding: .day, value: -1, to: month)!
            copy.endDate = min(copy.endDate ?? dayBefore, dayBefore)
            copy.scenarioChange = .changed
        }
        try copy.update(db)
    }

    private static func dropExceptions(db: Database, entryId: Int64, from date: Date) throws {
        _ = try PlannedOccurrenceException.filter(Column("entryId") == entryId && Column("originalDate") >= date).deleteAll(db)
    }

    /// An `added` confirmed entry in the scenario: in `groupId` when known, else through `PlannedItems.add`
    /// (the Planned group).
    private static func add(db: Database, scenarioId: Int64, categoryId: Int64, groupId: Int64?, accountId: Int64?,
                            amount: Int, frequency: ForecastFrequency, start: Date, anchorDay: Int?, note: String,
                            interval: Int = 1) throws -> Int64 {
        var entry: ForecastEntry
        if let groupId {
            entry = ForecastEntry(groupId: groupId, categoryId: categoryId, amountMinorUnits: amount, frequency: frequency,
                                  interval: interval, startDate: start, endDate: nil, isEnabled: true, status: .confirmed,
                                  note: note, anchorDay: anchorDay, scenarioId: scenarioId, scenarioChange: .added, accountId: accountId)
            try entry.insert(db)
        } else {
            entry = try PlannedItems.add(db: db, categoryId: categoryId, amountMinorUnits: amount, frequency: frequency, interval: interval,
                                         startDate: start, endDate: nil, scenarioId: scenarioId, accountId: accountId)
            entry.note = note
            entry.anchorDay = anchorDay
            try entry.update(db)
        }
        return entry.id!
    }

    private static func firstOfMonth(_ date: Date) -> Date {
        let (year, month) = MonthRange.components(of: date)
        return utc.date(from: DateComponents(year: year, month: month, day: 1))!
    }
}
